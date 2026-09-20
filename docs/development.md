# Development guide

## Installer structure

`install.sh` owns argument parsing, validation, inspection, and orchestration.
Sourced modules share its context and do not invoke provisioning when loaded.
The implementation stays compatible with macOS Bash 3.2.

| File | Responsibility |
| --- | --- |
| `installer/registry.sh` | Ordered component registry, dependency closure, handler validation |
| `installer/state.sh` | Saved profiles, schema migration, state signatures, locking and cleanup |
| `installer/packages.sh` | Platform bootstrap, package maps and package-manager operations |
| `installer/tools.sh` | Locked tools, dependency checkouts and Node selection/activation |
| `installer/config.sh` | Managed shell blocks, symlink-aware rewrites and default-shell changes |
| `installer/credentials.sh` | Local key preparation, read-only GitHub checks and manual-action pauses |
| `installer/verification.sh` | Component postconditions |
| `installer/signatures.sh` | Inputs that invalidate each component's recorded state |
| `installer/lock.sh` | Reviewed versions, URLs, commits, digests and npm engine requirements |

Add a component to the registry and supply its install, verification and
signature handlers. Registry validation rejects missing handlers or unknown
dependencies. Tests should check behavior and repair, not just matching names.
A recorded successful step is only a hint: verification must detect a missing,
wrong-version, or damaged artifact before skipping it.

Use `LEOS_PROFILES_INSTALL_LIB_ONLY=1` when sourcing the engine for isolated
unit tests. Stub package managers, credential APIs and host-changing commands;
redirect HOME, XDG state, Git configuration and temporary files into a fixture.
Clean up using the original fixture variable, never `rm -rf "$HOME"`.

## State and TSV contract

Inspection format and saved profile schema are independently versioned. The
inspection stream uses `meta<TAB>schema<TAB>1`. Saved profiles use schema 2 and
include `node-policy<TAB>preserve-compatible` and the `current-lts` fallback
channel. Schema-1 profiles remain readable and are migrated by an approved
apply/reconcile. Inspection and dry-run must not write the migration.

The parser must preserve empty TSV columns and dispatch by record type; it must
not treat prose progress output during apply as inspection records. Relevant
records include:

| Record | Remaining columns | Meaning |
| --- | --- | --- |
| `meta` | `schema`, `1` | Inspection format version |
| `platform` | `family`, value | Selected OS package family |
| `profile` | `root`, path | Authoritative local checkout |
| `group` | category, name, status | Selected, implied or internal group |
| `package` | OS family, name | Exact OS package member |
| `artifact` | source kind, name, URL/repository, digest/commit | Locked executable dependency |
| `policy` | `node`, `preserve-compatible` | Node selection policy |
| `runtime` | `node`, version, origin | `preserved-fnm`, `adopted-existing`, or `current-lts` |
| `migration` | `profile-schema`, `1`, `2` | Pending profile migration |
| `postcondition` | component, status | Current `verified` or `needed` result |
| `manual-action` | action, public path, destination | Manual intervention required; process exits 3 |

Other `channel`, `external`, `action`, `file`, and `global` records describe the
plan's sources and effects. Read the emitter in `install.sh` when extending the
contract. A runtime preview may report `unresolved` / `resolve-during-apply`.

Manual-action names cover registration, login, email-read scope, key selection,
and SSH identity configuration. An empty public-path field is valid for actions
such as login. Only public artifacts are referenced: never emit private key
contents, tokens or passphrases. On registration pauses, save the explicit
reference first and retain the public artifact after EXIT cleanup. Reconciliation
must never generate a replacement. Pending initial generation resumes the
originally approved apply; API/network failures must not be interpreted as
missing registration. Enabling global GPG commit signing follows successful
local signing and confirmed GitHub registration.

## Node and package invariants

Yarn and pnpm each depend on fnm. Preserve a compatible existing fnm default;
otherwise adopt the exact version of compatible Node on PATH into fnm. Resolve
one current LTS only when no compatible existing runtime is available. Record
and verify the actual selected version, including the default fnm executable.
Run npm tool installation and verification with explicit `fnm exec` so a
non-interactive installer does not accidentally use an older system Node.

Compatibility uses the selected locked package manifests. Current ranges are
Yarn `>=4.0.0` and pnpm `>=22.13`; when both are selected, satisfy both.
A newer available LTS alone does not invalidate a compatible saved default.

`--no-full-upgrade` requests only missing selected OS packages, while normal
package-manager dependency resolution can still upgrade dependencies. Keep
this distinction in planning output and tests. Full upgrades stay within the
configured OS release/repositories; they do not run distribution-upgrade tools.

## Local regression checks

Run these from the repository root:

```bash
for file in install.sh installer/*.sh tests/*.sh; do bash -n "$file" || exit; done
for file in zsh/*.zsh zsh/path/*.zsh tests/*.zsh; do zsh -n "$file" || exit; done
shellcheck -s bash -x install.sh installer/*.sh tests/*.sh
bash tests/install-test.sh
bash tests/apply-dryrun-test.sh
bash tests/node-test.sh
bash tests/credentials-test.sh
zsh tests/profile-test.zsh
zsh tests/runtime-cache-test.zsh
python3 tests/rmdsstore_test.py
```

Credential tests mock all GitHub and SSH connections. Where GPG, gpgconf and
ssh-keygen are installed, they also generate disposable local keys and sign a
real Git commit with isolated HOME, GNUPGHOME and Git configuration. GPG needs
permission to create its local agent socket; a restrictive sandbox can block
that part. The fixture cleans up its own agent and keys. These tests neither
upload keys nor use the developer's GitHub account.

Network-backed checks verify pinned dependencies and package availability:

```bash
bash tests/locked-plugins-test.sh
bash tests/locked-artifacts-test.sh
bash tests/package-map-availability.sh macos  # or apt, fedora, arch
```

The artifact checks execute downloaded binaries appropriate to the host and
verify npm package engine declarations. Plugin checks load the combined real
Zsh plugin integration. CI also checks TOML and fenced Bash in the runbook.
None of these alone substitutes for actual package installation.

## Real provisioning coverage

`tests/provisioning-test.sh` performs real host package installations and
upgrades. A fresh HOME does not isolate those system mutations. Run it only on
disposable CI hosts; its guard rejects ordinary local execution. Do not bypass
the guard on a workstation.

Linux CI invokes `tests/provisioning-container.sh` inside native-architecture
containers with the source checkout mounted read-only. Ubuntu 22.04/24.04/26.04,
Debian 12/13, and Fedora 43/44 run on x86_64 and arm64; Arch runs on x86_64.
The containers create a non-root test user and exercise actual package managers.
macOS CI uses fresh HOME directories on hosted macOS 14/15/26 ARM/Intel runners
where available. Those images already have developer tools and Homebrew: the
matrix does not establish factory-fresh macOS bootstrap coverage.

Scenarios exercise minimal Zsh setup, pnpm-only dependency resolution,
Yarn/pnpm execution, recommended provisioning, repeat reconciliation and repair.
They skip credentials, disable login-shell changes, and explicitly install
fonts. Unit and credential fixture tests cover the excluded interactive flows;
manual end-to-end GitHub registration remains outside automated CI.

The configured matrix is a coverage target. Claim a particular platform passed
only with that run's evidence, and report failures or unexecuted jobs separately.
See [the workflow](../.github/workflows/ci.yml) for exact runner labels and gates.

## Updating dependencies

1. Read upstream release metadata and the exact candidate artifact's manifest.
   Update URLs, versions, immutable commits and SHA-256 digests together in
   `installer/lock.sh`. Download candidates for verification; do not execute an
   unverified replacement installer.
2. For Yarn/pnpm, compare `package.json`'s `engines.node` with the declared lock
   range. Update engine requirements and selection tests together. Do not infer
   runtime support solely from the package's major version.
3. Verify each OS/architecture artifact and the real executable's version.
   Test locked plugins together, not just their Git revisions. Preserve dirty
   dependency-checkout refusal and equivalent trusted-origin normalization.
4. Run focused regressions and the real provisioning matrix. When changing
   dependency closure, verify the minimal selection that newly implies a tool.
   Reconciliation must repair removed artifacts without unnecessary reinstalls.
5. Include the source metadata, platform coverage and any remaining validation
   gaps in the change description. OS package channels and Node's fallback LTS
   channel remain moving dependencies; do not describe the whole machine as
   reproducibly locked.

## Startup benchmark

Measure the actual installed public checkout with the benchmark helper:

```bash
zsh tests/startup-benchmark.zsh "$HOME/.leos-profiles"
```

Record the OS/architecture, Zsh version, checkout revision, installed tools and
number of samples alongside the output. Compare cold initialization with warm
cache runs on the same machine. A fixture or synthetic generator can isolate a
regression but cannot establish workstation startup latency. Do not publish a
universal 0.1-second claim or compare results with different tool selections as
though they were equivalent.

An implementation-validation run on 2026-09-20 used macOS 27.0 arm64 and Zsh
5.9 at checkout `05a4188-dirty`, with ten samples per condition: cold median
**1568.1 ms**, warm median **189.9 ms**. Detected tools were Homebrew 7.0.4,
fnm 1.39.0, Node 26.9.0, npm 11.19.1, pnpm 11.10.0, Bun 1.3.11,
pyenv 2.7.3-10-g790bedd8, rbenv 1.3.2-22-g7f984a7, and Starship 1.26.0.
The helper prints the checkout and detected tool versions with each run.
It copies the public profile into temporary state, uses
real detected PATH tools, excludes private overrides and background rehashes,
and captures output without a terminal. That run reported a ZLE-option
diagnostic in the captured environment. These are harness measurements, not a
claim about every workstation or the supported macOS CI matrix.

The cache hashes binary path, arguments, HOME and version-manager roots. It
checks ownership, write permissions and symlinks before executing persisted
scripts or compiled files, and creates private directories/files. Launcher
mtime controls freshness; use `leos-refresh-init-cache` after updates to other
implementation files. Homebrew shellenv and fnm env run per shell rather than
being cached. Test both a clean PATH and an already-configured PATH, and verify
that different shells receive different fnm multishell directories.
