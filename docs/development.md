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
not treat prose progress output during apply as inspection records. Every
record type the installer emits is listed below; "Columns" counts the record
type itself, so `meta` has three tab-separated fields. `tests/readonly-test.sh`
reads this table and fails on an undocumented type or a different count, so
update it together with the emitter in `install.sh`.

| Record | Columns | Remaining columns | Meaning |
| --- | --- | --- | --- |
| `meta` | 3 | `schema`, `1` | Inspection format version |
| `platform` | 3 | `family`, value | Selected OS package family |
| `profile` | 3 | `root`, path | Authoritative local checkout |
| `policy` | 3 | `node` or `full-upgrade`, value | Node selection policy; `yes`/`no` host upgrade |
| `channel` | 3 | source, channel | Moving sources: `packages`, `node`, `ai-cli-updates` |
| `migration` | 4 | `profile-schema`, `1`, `2` | Pending profile migration |
| `group` | 4 | category, name, status | Selected, implied or internal group |
| `package` | 3 | OS family, name | Exact OS package member |
| `action` | 3 | step, description | Planned effect of a step or bootstrap |
| `artifact` | 5 | source kind, name, URL/repository, digest/commit | Locked executable dependency |
| `external` | 3 | service, description or URL | External service the plan contacts |
| `file` | 3 | name, path | File the plan reads or writes |
| `global` | 3 | `git`, keys | Global Git settings the plan configures |
| `irreversible` | 3 | effect, explanation | Effect that cannot be automatically undone |
| `runtime` | 4 | `node`, version, origin | `preserved-fnm`, `adopted-existing`, or `current-lts` |
| `postcondition` | 3 | component, status | Current `verified` or `needed` result |
| `manual-action` | 4 | action, public path, destination | Manual intervention required; process exits 3 |

A runtime preview may report `unresolved` / `resolve-during-apply`.

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
/bin/bash tests/install-test.sh  # macOS: the system Bash 3.2 a fresh Mac runs
bash tests/apply-dryrun-test.sh
bash tests/readonly-test.sh
bash tests/node-test.sh
bash tests/credentials-test.sh
zsh tests/profile-test.zsh
zsh tests/runtime-cache-test.zsh
/usr/bin/python3 -I tests/rmdsstore_test.py  # macOS; elsewhere python3
```

These suites use fixtures and are safe on a provisioned workstation: they
redirect HOME, XDG state and Git configuration, and the CLI-level tests
(`apply-dryrun-test.sh`, `readonly-test.sh`) run a temporary copy of the public
checkout so your `local/` state is never read or written. `install-test.sh`
runs every test in its own subshell, reports each failing test by name and
removes the temporary files the code under test tracked. `readonly-test.sh`
snapshots the fixture HOME and checkout around `inspect`, `apply --dry-run` and
`reconcile --dry-run` through the real CLI, with package managers and network
clients replaced by PATH fakes, and checks every inspect record against the
table above. `profile-test.zsh` runs each Zsh block through `run_block`, which
fails unless the block reaches an appended sentinel: a shell error inside a
block (an unmatched glob, an unset parameter) otherwise ends `zsh -c` with
status 0 and silently skips the remaining assertions.

CI also lints the workflows and Python. With the same pinned versions:

```bash
actionlint                                  # 1.7.12; uses shellcheck from PATH
zizmor --no-progress .github                # 1.30.1
ruff check --no-cache util tests            # 0.16.10; ruff.toml targets Python 3.9
shfmt -d -i 2 -ci install.sh installer/*.sh tests/*.sh  # informational only
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

## CI layout

Two workflows split fast feedback from real provisioning:

- `.github/workflows/ci.yml` runs on every push to `master`, every pull request
  and on demand: Zsh syntax and profile tests, lint (ShellCheck, actionlint,
  zizmor, ruff; shfmt informational), installer/credential/Node/cache/util
  suites, locked artifacts, package-map availability on macOS, apt and
  containers, the dry-run smoke test and the read-only test. The macOS jobs run
  the Bash suites under `/bin/bash` (3.2) and `rmdsstore_test.py` under
  `/usr/bin/python3 -I`, the interpreters the installer and `rmdsstore`
  actually use there. Jobs whose names end in "(gating)" are the branch
  ruleset's required checks; keep those names stable. The workflow has no
  paths filter on purpose: a required check that never runs blocks a docs-only
  pull request. A startup-benchmark job reports timings in its job summary and
  never fails the run.
- `.github/workflows/provision.yml` runs the real provisioning matrix weekly
  (Monday 08:23 UTC), on demand (Actions, "Provision", "Run workflow"), and on
  pull requests that carry the `provision` label. Add the label when a change
  affects package maps, provisioning or bootstrap behaviour; every later push
  to the labelled pull request re-runs it. Docs-only changes do not trigger it.
  Only `macos-15` runs the recommended scenario with the full `brew upgrade`;
  the other macOS runners set `LEOS_CI_FULL_UPGRADE=0`, which makes
  `tests/provisioning-test.sh` pass `--no-full-upgrade` for that scenario.
  Linux containers keep the full upgrade. These jobs are not required checks.

Both workflows cancel superseded pull-request runs but never cancel runs on
`master`. Actions are pinned by commit SHA with the exact release in a comment,
checkouts do not persist credentials, and Dependabot proposes action updates
weekly. Container images stay on tags on purpose: CI tests each distro's
current image, which is what a new user installs.

## Real provisioning coverage

`tests/provisioning-test.sh` performs real host package installations and
upgrades. A fresh HOME does not isolate those system mutations. Run it only on
disposable CI hosts; its guard rejects ordinary local execution. Do not bypass
the guard on a workstation.

Linux CI invokes `tests/provisioning-container.sh` inside native-architecture
containers with the source checkout mounted read-only. Ubuntu 22.04/24.04/26.04,
Debian 12/13, and Fedora 43/44 run on x86_64 and arm64; Arch runs on x86_64.
The containers create a non-root test user and exercise actual package managers.
macOS CI uses fresh HOME directories on hosted Apple-silicon macOS 15 and 26
runners (Homebrew Tier 1; macOS 14 and Intel Macs are unsupported). Those images already have developer tools and Homebrew: the
matrix does not establish factory-fresh macOS bootstrap coverage.

Scenarios exercise minimal Zsh setup, pnpm-only dependency resolution,
Yarn/pnpm execution, recommended provisioning, repeat reconciliation and repair.
They skip credentials, disable login-shell changes, and explicitly install
fonts. Unit and credential fixture tests cover the excluded interactive flows;
manual end-to-end GitHub registration remains outside automated CI.

The configured matrix is a coverage target. Claim a particular platform passed
only with that run's evidence, and report failures or unexecuted jobs separately.
See [the provisioning workflow](../.github/workflows/provision.yml) for exact
runner labels and triggers.

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
zsh tests/startup-benchmark.zsh "$HOME/.leos-profiles"        # non-terminal exit time
zsh tests/startup-benchmark.zsh --pty "$HOME/.leos-profiles"  # first prompt and command lag
```

Each mode measures three scenarios: cold (no init cache, no completion dump),
warm, and aged-dump (warm caches with `~/.zcompdump` backdated two days, which
takes the full `compinit` path instead of `compinit -C`, as the first shell of
each day does). The default mode times `zsh -dfi -c 'source start.zsh'` without
a terminal. `--pty` starts an interactive shell on a pseudo-terminal, as
[zsh-bench](https://github.com/romkatv/zsh-bench) does, with a wrapper
`.zshrc` whose ZLE `line-init` hook marks each prompt that is ready for input.
It reports time to the first prompt and command lag: Enter on an empty line
until the next prompt is ready, which includes every precmd hook and the
prompt itself. Where `strace` is available (Linux), the default mode also counts
process creations and execs in one warm startup; macOS has no unprivileged
equivalent, so the count is reported as unavailable there. Set
`LEOS_BENCH_SAMPLES` to change the ten samples per scenario. CI runs both modes
on Ubuntu and macOS in a non-gating job and writes the results to the job
summary; hosted runners lack most workstation tools, so read those numbers as
trends for the same runner image, not as workstation latency.

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

A run on 2026-10-10 on the same macOS 27.0 arm64 machine (Zsh 5.9.2, installed
checkout `7b08822` with its plugins, Homebrew 7.0.9, fnm 1.39.0, Node 24.18.0,
pnpm 12.10.1, Bun 1.3.11, Starship 1.26.0, same pyenv/rbenv; ten samples)
measured, without a terminal: cold **1984.2 ms**, warm **364.4 ms**, aged-dump
**452.1 ms**; and with `--pty`: first prompt cold **2042.8 ms**, warm
**407.8 ms**, aged-dump **493.6 ms**, command lag **36.0 ms** (20 presses).
Against zsh-bench's perceptibility thresholds (50 ms first prompt, 10 ms
command lag) both warm startup and per-prompt cost are well above the target.

The cache hashes binary path, arguments, HOME and version-manager roots. It
checks ownership, write permissions and symlinks before executing persisted
scripts or compiled files, and creates private directories/files. Launcher
mtime controls freshness; use `leos-refresh-init-cache` after updates to other
implementation files. Homebrew shellenv and fnm env run per shell rather than
being cached. Test both a clean PATH and an already-configured PATH, and verify
that different shells receive different fnm multishell directories.
