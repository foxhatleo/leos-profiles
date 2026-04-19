#!/usr/bin/env python3
"""
Verify that packages referenced by the quick-install implementation exist in
official/default package sources, without needing to boot each target OS.

What this checks:
- Homebrew core formulae (official default tap)
- Ubuntu latest LTS official archive components
- Debian current stable "main"
- Fedora latest stable official repos
- Arch Linux official package repos

What this intentionally does not check:
- Third-party repos/taps such as RPM Fusion or custom brew taps

The script parses package names directly from the quick-install implementation
script so it stays in sync with the installer.

Python dependency note:
- Only Python standard-library modules are imported
- Fedora metadata decompression may call a local zstd-compatible binary
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import io
import json
import lzma
import re
import shlex
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence, Set, Tuple


TIMEOUT_SECONDS = 60
USER_AGENT = "leos-profiles verify-default-sources/1.0"
DEFAULT_BOOTSTRAP_SCRIPT = Path("util/quick-install.sh")
RPM_PACKAGE_NS = {
    "common": "http://linux.duke.edu/metadata/common",
    "repo": "http://linux.duke.edu/metadata/repo",
    "rpm": "http://linux.duke.edu/metadata/rpm",
}


@dataclass
class FunctionPackages:
    manager: str
    packages: List[str] = field(default_factory=list)
    external_sources: List[str] = field(default_factory=list)


@dataclass
class VerificationResult:
    label: str
    release: str
    present: Dict[str, List[str]]
    missing: List[str]
    notes: List[str] = field(default_factory=list)


def fetch_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return response.read()


def fetch_text(url: str, encoding: str = "utf-8") -> str:
    return fetch_bytes(url).decode(encoding, errors="replace")


def parse_shell_commands(block: str) -> List[str]:
    commands: List[str] = []
    current: List[str] = []
    for raw_line in block.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.endswith("\\"):
            current.append(stripped[:-1].rstrip())
            continue
        current.append(stripped)
        commands.append(" ".join(current))
        current = []
    if current:
        commands.append(" ".join(current))
    return commands


def extract_function_block(script_text: str, function_name: str, script_path: Path) -> str:
    pattern = re.compile(
        rf"(?ms)^{re.escape(function_name)}\(\)\s*\{{\n(.*?)^\}}"
    )
    match = pattern.search(script_text)
    if not match:
        raise ValueError(f"Could not find function {function_name} in installer script {script_path}")
    return match.group(1)


def packages_after_install(tokens: Sequence[str], keyword: str) -> List[str]:
    try:
        idx = list(tokens).index(keyword)
    except ValueError as exc:
        raise ValueError(f"Could not find {keyword!r} in command: {' '.join(tokens)}") from exc
    return [token for token in tokens[idx + 1 :] if not token.startswith("-")]


def has_exact_token(tokens: Sequence[str], expected: str) -> bool:
    return any(token == expected for token in tokens)


def first_url_token(tokens: Sequence[str]) -> str | None:
    for token in tokens:
        if token.startswith("http://") or token.startswith("https://"):
            return token
    return None


def extend_unique(items: List[str], additions: Sequence[str]) -> None:
    for addition in additions:
        if addition not in items:
            items.append(addition)


def parse_quick_install(path: Path) -> Dict[str, FunctionPackages]:
    script_text = path.read_text(encoding="utf-8")
    function_map = {
        "macos": ("install_packages_macos", "brew"),
        "apt": ("install_packages_apt", "apt"),
        "fedora": ("install_packages_fedora", "dnf"),
        "pacman": ("install_packages_pacman", "pacman"),
    }

    results: Dict[str, FunctionPackages] = {}

    for key, (function_name, manager) in function_map.items():
        block = extract_function_block(script_text, function_name, path)
        commands = parse_shell_commands(block)
        parsed = FunctionPackages(manager=manager)

        for command in commands:
            tokens = shlex.split(command)

            if manager == "brew" and command.startswith("brew tap "):
                parsed.external_sources.append(command[len("brew tap ") :].strip())
                continue

            if "rpmfusion.org/" in command:
                url = first_url_token(tokens)
                if url:
                    parsed.external_sources.append(url)
                continue

            if manager == "brew" and command.startswith("brew install "):
                extend_unique(parsed.packages, packages_after_install(tokens, "install"))
            elif manager == "apt" and has_exact_token(tokens, "apt") and has_exact_token(tokens, "install"):
                extend_unique(parsed.packages, packages_after_install(tokens, "install"))
            elif (
                manager == "dnf"
                and has_exact_token(tokens, "dnf")
                and has_exact_token(tokens, "install")
                and not has_exact_token(tokens, "group")
            ):
                extend_unique(parsed.packages, packages_after_install(tokens, "install"))
            elif manager == "pacman" and has_exact_token(tokens, "pacman") and has_exact_token(tokens, "-S"):
                extend_unique(parsed.packages, packages_after_install(tokens, "-S"))

        if not parsed.packages:
            raise ValueError(f"Could not parse package list from {function_name}")

        results[key] = parsed

    return results


def latest_ubuntu_lts() -> Tuple[str, str]:
    text = fetch_text("https://changelogs.ubuntu.com/meta-release-lts")
    blocks = [block.strip() for block in text.split("\n\n") if block.strip()]
    latest: Dict[str, str] = {}
    for block in blocks:
        entry: Dict[str, str] = {}
        for line in block.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            entry[key.strip()] = value.strip()
        if entry:
            latest = entry
    if not latest:
        raise RuntimeError("Failed to parse Ubuntu meta-release-lts")
    return latest["Dist"], latest["Version"]


def debian_stable() -> Tuple[str, str]:
    text = fetch_text("https://deb.debian.org/debian/dists/stable/Release")
    codename = None
    version = None
    for line in text.splitlines():
        if line.startswith("Codename: "):
            codename = line.split(": ", 1)[1].strip()
        elif line.startswith("Version: "):
            version = line.split(": ", 1)[1].strip()
    if not codename or not version:
        raise RuntimeError("Failed to parse Debian stable Release metadata")
    return codename, version


def latest_fedora_release() -> str:
    text = fetch_text("https://dl.fedoraproject.org/pub/fedora/linux/releases/")
    versions = {int(match) for match in re.findall(r'href="(\d+)/"', text)}
    if not versions:
        raise RuntimeError("Failed to discover Fedora release versions")
    return str(max(versions))


def check_homebrew_core(packages: Sequence[str]) -> VerificationResult:
    data = json.loads(fetch_text("https://formulae.brew.sh/api/formula.json"))
    lookup: Dict[str, str] = {}
    for entry in data:
        canonical = entry["name"]
        lookup[canonical] = canonical
        for alias in entry.get("aliases", []):
            lookup.setdefault(alias, canonical)
        for oldname in entry.get("oldnames", []):
            lookup.setdefault(oldname, canonical)

    present: Dict[str, List[str]] = {}
    for package in packages:
        canonical = lookup.get(package)
        if not canonical:
            continue
        if canonical == package:
            present[package] = ["homebrew/core"]
        else:
            present[package] = [f"homebrew/core (alias for {canonical})"]

    missing = sorted(pkg for pkg in packages if pkg not in present)
    return VerificationResult(
        label="Homebrew",
        release="core (rolling)",
        present=present,
        missing=missing,
        notes=["Counts Homebrew aliases and old formula names as present."],
    )


def apt_repo_presence(
    base_url: str,
    suite: str,
    components: Sequence[str],
    packages: Sequence[str],
) -> Dict[str, List[str]]:
    wanted = set(packages)
    found: Dict[str, Set[str]] = {}

    for component in components:
        url = f"{base_url}/dists/{suite}/{component}/binary-amd64/Packages.gz"
        try:
            compressed = fetch_bytes(url)
        except Exception:
            continue

        with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as gz:
            for raw_line in gz:
                if not raw_line.startswith(b"Package: "):
                    continue
                name = raw_line[9:].decode("utf-8", errors="replace").strip()
                if name in wanted:
                    found.setdefault(name, set()).add(component)

    return {name: sorted(found.get(name, set())) for name in packages if name in found}


def check_ubuntu(packages: Sequence[str]) -> VerificationResult:
    suite, version = latest_ubuntu_lts()
    present = apt_repo_presence(
        base_url="https://archive.ubuntu.com/ubuntu",
        suite=suite,
        components=["main", "restricted", "universe", "multiverse"],
        packages=packages,
    )
    missing = sorted(pkg for pkg in packages if pkg not in present)
    notes = [
        "Matches packages against the Ubuntu official archive for amd64.",
        "Components are reported so you can decide whether 'universe' or 'multiverse' counts as default enough for your use case.",
    ]
    return VerificationResult(
        label="Ubuntu",
        release=f"{version} ({suite})",
        present=present,
        missing=missing,
        notes=notes,
    )


def check_debian(packages: Sequence[str]) -> VerificationResult:
    suite, version = debian_stable()
    present = apt_repo_presence(
        base_url="https://deb.debian.org/debian",
        suite=suite,
        components=["main"],
        packages=packages,
    )
    missing = sorted(pkg for pkg in packages if pkg not in present)
    notes = [
        "Checks Debian stable 'main' only, which is the conservative interpretation of default sources.",
        "If you want contrib or non-free packages counted, expand the components list in this script.",
    ]
    return VerificationResult(
        label="Debian",
        release=f"{version} ({suite})",
        present=present,
        missing=missing,
        notes=notes,
    )


def decompress_maybe(data: bytes, href: str) -> bytes:
    if href.endswith(".gz"):
        return gzip.decompress(data)
    if href.endswith(".xz"):
        return lzma.decompress(data)
    if href.endswith(".zst"):
        zstd_bin = shutil.which("zstd") or shutil.which("unzstd") or shutil.which("zstdcat")
        if not zstd_bin:
            raise RuntimeError(
                "Fedora metadata is compressed with zstd, but no zstd-compatible binary was found in PATH"
            )
        completed = subprocess.run(
            [zstd_bin, "-dc"],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return completed.stdout
    return data


def fedora_repo_presence(repo_base: str, packages: Sequence[str], repo_label: str) -> Dict[str, List[str]]:
    wanted = set(packages)
    repomd_url = f"{repo_base}/repodata/repomd.xml"
    repomd = fetch_text(repomd_url)
    root = ET.fromstring(repomd)
    primary_href = None
    for data_node in root.findall("repo:data", RPM_PACKAGE_NS):
        if data_node.get("type") != "primary":
            continue
        location = data_node.find("repo:location", RPM_PACKAGE_NS)
        if location is not None:
            primary_href = location.get("href")
            break
    if not primary_href:
        raise RuntimeError(f"Could not find primary metadata for {repo_label}")

    primary_bytes = fetch_bytes(f"{repo_base}/{primary_href}")
    xml_bytes = decompress_maybe(primary_bytes, primary_href)

    found: Dict[str, Set[str]] = {}
    for _event, elem in ET.iterparse(io.BytesIO(xml_bytes)):
        if elem.tag.endswith("package"):
            name_elem = elem.find("common:name", RPM_PACKAGE_NS)
            if name_elem is not None:
                package_name = name_elem.text
                if package_name in wanted:
                    found.setdefault(package_name, set()).add(repo_label)

                format_elem = elem.find("common:format", RPM_PACKAGE_NS)
                if format_elem is not None:
                    for provide_elem in format_elem.findall("rpm:provides/rpm:entry", RPM_PACKAGE_NS):
                        provide_name = provide_elem.get("name")
                        if provide_name not in wanted:
                            continue
                        if provide_name == package_name:
                            found.setdefault(provide_name, set()).add(repo_label)
                        else:
                            found.setdefault(provide_name, set()).add(
                                f"{repo_label} (provided by {package_name})"
                            )
            elem.clear()

    return {name: sorted(found.get(name, set())) for name in packages if name in found}


def merge_presence(*presence_maps: Dict[str, List[str]]) -> Dict[str, List[str]]:
    merged: Dict[str, Set[str]] = {}
    for presence in presence_maps:
        for name, labels in presence.items():
            merged.setdefault(name, set()).update(labels)
    return {name: sorted(labels) for name, labels in merged.items()}


def check_fedora(packages: Sequence[str]) -> VerificationResult:
    version = latest_fedora_release()
    release_repo = f"https://dl.fedoraproject.org/pub/fedora/linux/releases/{version}/Everything/x86_64/os"
    updates_repo = f"https://dl.fedoraproject.org/pub/fedora/linux/updates/{version}/Everything/x86_64"

    present = merge_presence(
        fedora_repo_presence(release_repo, packages, f"fedora-{version}"),
        fedora_repo_presence(updates_repo, packages, f"updates-{version}"),
    )
    missing = sorted(pkg for pkg in packages if pkg not in present)
    notes = [
        "Checks Fedora release and updates repos only.",
        "Counts Fedora virtual provides when a requested name is satisfied by a differently named package.",
        "This does not count RPM Fusion.",
    ]
    return VerificationResult(
        label="Fedora",
        release=version,
        present=present,
        missing=missing,
        notes=notes,
    )


def check_arch(packages: Sequence[str]) -> VerificationResult:
    present: Dict[str, List[str]] = {}
    missing: List[str] = []
    for package in packages:
        url = (
            "https://archlinux.org/packages/search/json/?name="
            + urllib.parse.quote(package)
        )
        payload = json.loads(fetch_text(url))
        repos = sorted(
            {
                result["repo"]
                for result in payload.get("results", [])
                if result.get("pkgname") == package
            }
        )
        if repos:
            present[package] = repos
        else:
            missing.append(package)

    return VerificationResult(
        label="Arch Linux",
        release="rolling",
        present=present,
        missing=missing,
        notes=["Checks the official Arch package index JSON API."],
    )


def render_result(result: VerificationResult) -> str:
    lines = [f"{result.label} [{result.release}]"]
    if result.present:
        lines.append("  Present:")
        for package in sorted(result.present):
            locations = ", ".join(result.present[package])
            lines.append(f"    - {package}: {locations}")
    else:
        lines.append("  Present: none")

    if result.missing:
        lines.append("  Missing:")
        for package in result.missing:
            lines.append(f"    - {package}")
    else:
        lines.append("  Missing: none")

    if result.notes:
        lines.append("  Notes:")
        for note in result.notes:
            lines.append(f"    - {note}")

    return "\n".join(lines)


def markdown_escape(value: str) -> str:
    return value.replace("|", r"\|")


def render_markdown_report(
    parsed: Dict[str, FunctionPackages],
    results: Dict[str, VerificationResult],
    script_path: Path,
) -> str:
    lines: List[str] = [
        "# Default Source Verification Report",
        "",
        f"- Generated (UTC): {dt.datetime.now(dt.UTC).strftime('%Y-%m-%d %H:%M:%S %Z')}",
        f"- Installer script: `{script_path}`",
        "- Python dependencies: standard library only",
        "- External binaries: may use a local `zstd`/`unzstd`/`zstdcat` binary for Fedora metadata decompression",
        "- Temporary files: none created by this script",
        "",
        f"## External Sources Referenced By `{script_path}`",
        "",
        "These are intentionally excluded from the availability checks below.",
        "",
    ]

    found_external = False
    for key in ["macos", "apt", "fedora"]:
        sources = parsed[key].external_sources
        if not sources:
            continue
        found_external = True
        lines.append(f"### {key}")
        lines.append("")
        for source in sources:
            lines.append(f"- `{source}`")
        lines.append("")
    if not found_external:
        lines.append("- None")
        lines.append("")

    ordered_results = ["homebrew", "ubuntu", "debian", "fedora", "arch"]
    for key in ordered_results:
        result = results[key]
        lines.append(f"## {result.label} [{result.release}]")
        lines.append("")
        lines.append("| Package | Exists | Source |")
        lines.append("| --- | --- | --- |")
        ordered_packages = list(result.present) + result.missing
        seen = set()
        for package in ordered_packages:
            if package in seen:
                continue
            seen.add(package)
            if package in result.present:
                source = ", ".join(result.present[package])
                exists = "yes"
            else:
                source = "-"
                exists = "no"
            lines.append(
                f"| `{markdown_escape(package)}` | {exists} | {markdown_escape(source)} |"
            )
        lines.append("")
        if result.notes:
            lines.append("Notes:")
            for note in result.notes:
                lines.append(f"- {note}")
            lines.append("")

    return "\n".join(lines)


def print_external_sources(parsed: Dict[str, FunctionPackages], script_path: Path) -> None:
    print(f"External Sources Referenced By {script_path}")
    for key in ["macos", "apt", "fedora"]:
        sources = parsed[key].external_sources
        if not sources:
            continue
        print(f"  {key}:")
        for source in sources:
            print(f"    - {source}")
    print("  note:")
    print("    - The presence report below ignores these extras on purpose.")
    print()


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify package availability in official/default sources."
    )
    parser.add_argument(
        "--script",
        type=Path,
        default=DEFAULT_BOOTSTRAP_SCRIPT,
        help="Path to the quick-install implementation script",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON instead of text",
    )
    parser.add_argument(
        "--markdown-out",
        type=Path,
        default=Path("verify-quick-install-packages-report.md"),
        help="Write a Markdown report to this path",
    )
    return parser.parse_args(argv)


def result_to_jsonable(result: VerificationResult) -> Dict[str, object]:
    return {
        "label": result.label,
        "release": result.release,
        "present": result.present,
        "missing": result.missing,
        "notes": result.notes,
    }


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    parsed = parse_quick_install(args.script)

    results = {
        "homebrew": check_homebrew_core(parsed["macos"].packages),
        "ubuntu": check_ubuntu(parsed["apt"].packages),
        "debian": check_debian(parsed["apt"].packages),
        "fedora": check_fedora(parsed["fedora"].packages),
        "arch": check_arch(parsed["pacman"].packages),
    }

    report = render_markdown_report(parsed, results, args.script)
    args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
    args.markdown_out.write_text(report + "\n", encoding="utf-8")

    if args.json:
        payload = {
            "external_sources": {
                key: value.external_sources for key, value in parsed.items() if value.external_sources
            },
            "markdown_report": str(args.markdown_out),
            "results": {key: result_to_jsonable(value) for key, value in results.items()},
        }
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0

    print_external_sources(parsed, args.script)
    print(f"Markdown report: {args.markdown_out}")
    print()
    for key in ["homebrew", "ubuntu", "debian", "fedora", "arch"]:
        print(render_result(results[key]))
        print()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        raise SystemExit(130)
