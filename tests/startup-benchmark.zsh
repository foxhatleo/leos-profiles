#!/usr/bin/env zsh
# Informational public-profile timing with real detected tools and isolated state.
# Private overrides and background shim maintenance are deliberately excluded.
emulate -L zsh
setopt err_return no_unset pipe_fail
root=${1:-${0:A:h:h}}
[[ $# -le 1 && -f $root/zsh/start.zsh ]] || {
  print -u2 'Usage: zsh tests/startup-benchmark.zsh [profile-checkout]'; exit 2
}
python3 - "$root" "${commands[zsh]}" "$PATH" <<'PY'
import os
import pathlib
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

source = pathlib.Path(sys.argv[1]).resolve()
shell, tool_path = sys.argv[2:]
with tempfile.TemporaryDirectory(prefix="leos-startup-") as fixture:
    base = pathlib.Path(fixture)
    profile = base / "profile"
    shutil.copytree(source / "zsh", profile / "zsh")
    # The public runtime references its utility path but never runs maintenance.
    shutil.copytree(source / "util", profile / "util")
    with (profile / "zsh/cache.zsh").open("a") as cache:
        cache.write("\n__leos_rehash_daily() { :; }\n")
    home = base / "home"
    home.mkdir(mode=0o700)
    env = {
        "HOME": str(home), "ZDOTDIR": str(home), "PATH": tool_path,
        "LEOS_PROFILES_HOME": str(profile), "TERM": "xterm-256color",
        "SHELL": shell, "USER": os.environ.get("USER", "benchmark"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_STATE_HOME": str(home / ".local/state"),
        "FNM_DIR": str(home / ".local/share/fnm"),
        "PYENV_ROOT": str(home / ".pyenv"), "RBENV_ROOT": str(home / ".rbenv"),
    }
    command = [shell, "-dfi", "-c", 'source "$LEOS_PROFILES_HOME/zsh/start.zsh"']
    samples = {"cold": [], "warm": []}
    warnings = set()
    for state in samples:
        for _ in range(10):
            if state == "cold":
                shutil.rmtree(home / ".cache", ignore_errors=True)
                for dump in home.glob(".zcompdump*"):
                    dump.unlink()
            started = time.perf_counter()
            result = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, check=True)
            samples[state].append(1000 * (time.perf_counter() - started))
            warnings.update(result.stderr.splitlines())
    print(platform.platform(), platform.machine())
    print(subprocess.check_output([shell, "--version"], text=True).strip())
    print("Isolated public profile; real PATH tools; no private overrides or rehash.")
    revision = subprocess.run(["git", "-C", str(source), "describe", "--always", "--dirty"],
                              capture_output=True, text=True)
    print("Checkout:", revision.stdout.strip() or "unversioned")
    for tool in ("brew", "fnm", "node", "npm", "pnpm", "bun", "pyenv", "rbenv", "starship"):
        executable = shutil.which(tool, path=tool_path)
        if executable:
            try:
                version = subprocess.run([executable, "--version"], env=env,
                                         capture_output=True, text=True, timeout=10)
                lines = version.stdout.strip().splitlines()
                print(f"{tool}: {executable}: {lines[0] if lines else 'version unavailable'}")
            except (OSError, subprocess.TimeoutExpired):
                print(f"{tool}: {executable}: version unavailable")
    for state, values in samples.items():
        print(f"{state}: n=10 median={statistics.median(values):.1f} ms "
              f"min={min(values):.1f} ms max={max(values):.1f} ms")
    if warnings:
        print("Runtime diagnostics (may explain timing differences):", file=sys.stderr)
        for warning in sorted(warnings):
            print(warning, file=sys.stderr)
PY
