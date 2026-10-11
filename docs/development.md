# Development guide

## Installer structure

`install.sh` owns argument parsing, validation, inspection, and orchestration.
Sourced modules share its context and do not invoke provisioning when loaded.
The implementation stays compatible with macOS Bash 3.2.

| File | Responsibility |
| --- | --- |
| `installer/registry.sh` | Ordered component registry, dependency closure, handler validation, the tool-artifact table, and which steps a full upgrade re-runs |
| `installer/state.sh` | Saved profiles, schema migration, state signatures, locking and cleanup |
| `installer/packages.sh` | Platform bootstrap, package maps and package-manager operations |
| `installer/tools.sh` | Tool installs (Homebrew formulae, latest GitHub releases, npm), default-branch checkouts and Node LTS activation |
| `installer/config.sh` | Managed shell blocks, symlink-aware rewrites and default-shell changes |
| `installer/credentials.sh` | Local key preparation, read-only GitHub checks and manual-action pauses |
| `installer/verification.sh` | Component postconditions |
| `installer/signatures.sh` | Inputs that invalidate each component's recorded state |
| `installer/sources.sh` | Upstream repositories and Linux release asset names, plus the two pinned downloads (Homebrew's installer, rpatool) |
| `installer/plan.sh` | Disclosure records beyond the selection, the preflight before any change, and the inventory |

Add a component to the registry and supply its install, verification and
signature handlers. Registry validation rejects missing handlers or unknown
dependencies. A tool the installer puts on PATH itself is one row in
`artifact_registry` (owning component, source prefix, archive kind,
executables, expected `--version` line, Homebrew formula) plus its
`<PREFIX>_REPOSITORY` and `<PREFIX>_LINUX_<AARCH64|X64>_ASSET` values in
`sources.sh`. On macOS it installs as the formula; on Linux as the latest
GitHub release, checked against the SHA-256 digest GitHub publishes for the
asset. A `file` row is the exception: a pinned `<PREFIX>_URL`/`_SHA256`. Its
handlers then just call `artifact_install`, `artifact_verify` and
`artifact_signature`, and inspect, the inventory, the shadow and migration
checks and `tests/release-artifacts-test.sh` pick it up from the table. Add a
component that follows upstream to `step_follows_upstream`, so a full upgrade
moves it forward. Tests should check behavior and repair, not just matching
names. A recorded successful step is only a hint: verification must detect a
missing or damaged artifact before skipping it. Signatures record where a tool
comes from, never its version, so a new upstream release does not by itself
make a step look undone.

Use `LEOS_PROFILES_INSTALL_LIB_ONLY=1` when sourcing the engine for isolated
unit tests. Stub package managers, credential APIs and host-changing commands;
redirect HOME, XDG state, Git configuration and temporary files into a fixture.
Clean up using the original fixture variable, never `rm -rf "$HOME"`.

## State and TSV contract

Inspection format and saved profile schema are independently versioned. The
inspection stream uses `meta<TAB>schema<TAB>1`. Saved profiles use schema 3 and
include `node-policy<TAB>current-lts` and the `current-lts` channel. Schema-1
and schema-2 (`preserve-compatible`) profiles remain readable and are migrated
by an approved apply/reconcile. Inspection and dry-run must not write the
migration.

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
| `warning` | 3 | name, message | `unsupported-platform` (an Intel Mac or macOS before 15: Homebrew Tier 2/3), `no-release-build` (upstream publishes no Linux build for this CPU), `node-version` (the given `--node-version` is not what the plan resolves now) |
| `profile` | 3 | `root`, path | Authoritative local checkout |
| `policy` | 3 | `node`, `full-upgrade` or `selection`, value | Node selection policy; `yes`/`no` host upgrade; `saved` when `inspect --saved` read the selection from the saved profile |
| `channel` | 3 | source, channel | Moving sources: `packages`, `node`, `ai-cli-updates` |
| `migration` | 4 | `profile-schema`, old schema, `3`; `legacy-loader` / `legacy-environment`, file path, managed marker; or `local-bin` / `npm-prefix` / `git-checkout`, path, what happens | Pending profile migration; a legacy unmarked loader (`.zshrc`) or zshenv snippet (`.zshenv`) that `zsh-config` and `remove-blocks` remove; or a copy from the pinned layout: a macOS `~/.local/bin` or `~/.local/npm` copy removed once Homebrew's formula is in place, or a checkout detached at a pinned commit that moves onto its default branch |
| `group` | 4 | category, name, status | Selected, implied or internal group |
| `package` | 3 | OS family, name | Exact OS package member |
| `action` | 3 | step, description | Planned effect of a step or bootstrap |
| `artifact` | 5 | source kind, name, source, revision | Where a tool comes from. `formula`: Homebrew formula, `latest`; `release`: `github.com/<repo>` and the asset name (for a Nerd Font, its archive URL and `SHA-256.txt`, the list its digest is read from); `npm`: registry package, `latest`; `git`: repository, `default-branch`; `direct`: pinned URL and SHA-256 |
| `external` | 3 | service, description or URL | External service the plan contacts |
| `file` | 3 | name, path | File the plan reads or writes; `zshrc`, `zshenv` and (macOS) `zprofile` give the resolved zsh startup files |
| `global` | 3 | `git`, keys | Global Git settings the plan configures |
| `irreversible` | 3 | effect, explanation | Effect that cannot be automatically undone: `host-upgrade` (package upgrades), `login-shell` (chsh) |
| `privileged` | 3 | action, command or description | An action run as root (through sudo, or directly when root): `homebrew-bootstrap`, `bootstrap`, `package-manager`, `repository`, `dnf-swap`, `pacman-sync`, `credential-packages`, `etc-shells`, `login-shell` |
| `behaviour` | 3 | name, description | A side effect beyond the listed files and packages: `compat-symlinks` (apt fd/bat links), `gnu-tools` (GNU tools ahead of BSD on macOS), `git-identity` (global name/email writes), `brew-mirror`, `login-shell` (macOS uses `/bin/zsh`) |
| `conflict` | 4 | component, path, reason | An existing installation in the way of `pyenv`/`rbenv`: `not-a-git-checkout`, `unexpected-origin`, `local-changes` (apply stops unless `--skip-existing-version-managers`), or `homebrew-install` (informational) |
| `existing` | 4 | name, path, effect | A shell framework or version manager the profile coexists with: `oh-my-zsh`, `powerlevel10k`, `nvm`, `conda`, `asdf`, `mise` |
| `shadow` | 4 | executable, other copy, profile copy | Linux: a Homebrew copy of a tool that the profile's `~/.local/bin` copy will shadow |
| `runtime` | 4 | `node`, version, origin | `current-lts` (what fnm will install), `installed` (a working default kept without a full upgrade), or `unresolved`/`resolve-during-apply` |
| `postcondition` | 3 | component, status | Current `verified` or `needed` result; `skipped` when `--skip-existing-version-managers` keeps an existing pyenv/rbenv |
| `manual-action` | 4 | action, public path, destination | Manual intervention required; process exits 3 |
| `item` | 5 | kind, name, path, `present`/`absent` | `inventory --tsv` only: something the installer creates or manages |

A runtime preview may report `unresolved` / `resolve-during-apply`.

Manual-action names cover registration, login, email-read scope, key selection,
SSH identity configuration, `run-in-terminal` (the destination is the exact
command to run in a terminal; see "Apply flow" below), `set-login-shell`
(chsh is missing) and `install-windows-font` (WSL). An empty public-path field is valid for actions
such as login. Only public artifacts are referenced: never emit private key
contents, tokens or passphrases. On registration pauses, save the explicit
reference first and retain the public artifact after EXIT cleanup. Reconciliation
must never generate a replacement. Pending initial generation resumes the
originally approved apply; API/network failures must not be interpreted as
missing registration. Enabling global GPG commit signing follows successful
local signing and confirmed GitHub registration.

## Apply flow

`main` runs, in order: argument parsing; `remove-blocks` and `inventory`
(dispatched before platform detection, so they work anywhere); the saved
profile for `reconcile` and `inspect --saved`; validation, dependency closure
and `detect_os`; `inspect` stops here. Apply and reconcile then warn about an
unsupported platform, capture the existing Node, and run `preflight`; only
after it do they take the lock, migrate local state, write the profile, apply
the Homebrew mirror, bootstrap, resolve Node, run each component, compile the
Zsh sources, and last provision credentials. `finish_manual_actions` prints
every queued `manual-action` and exits 3; a credential pause calls it at
once.

`preflight` (installer/plan.sh) changes nothing. It stops on a blocking
pyenv/rbenv conflict (unless `--skip-existing-version-managers`), checks
`--node-version` against a live resolution (exit 2 when they differ), and
collects what the run needs from the user: when stdin is not a terminal, a
passphrase prompt, chsh's password prompt (Linux, non-root) or a sudo password
(`privileged_plan` is not empty and `sudo -n true` fails) ends the run with
`manual-action run-in-terminal` carrying the exact command line, exit 3, before
the lock exists. With a terminal, `sudo -v` asks once up front. Dry runs never
call sudo; they report what would stop. Last, it downloads the latest Nerd
Fonts release's checksum list and rejects an unknown font name. Tests stub
`stdin_is_terminal`, `sudo` and `privileged_plan`.

A component that needs the user (a missing chsh) calls `queue_manual_action`
and sets `STEP_AWAITS_MANUAL_ACTION`: `run_step` then leaves it unrecorded and
the run continues.

## Zsh startup files

The `zsh-config` step owns up to three managed blocks, each between
`# >>> leos-profiles <marker> >>>` and `# <<< leos-profiles <marker> <<<`:

| Marker | File | Content |
| --- | --- | --- |
| `loader` | `.zshrc` | `LEOS_PROFILES_HOME` default and the interactive-only `source …/zsh/start.zsh` |
| `environment` | `.zshenv` | `skip_global_compinit=1` and `~/.local/bin`, `~/.local/npm/bin` in front of PATH |
| `login-path` | `.zprofile` (macOS only) | the same PATH entries again, after `/etc/zprofile`'s `path_helper` |

`resolve_zsh_dotdirs` in `installer/config.sh` decides where those files are:
`.zshrc`/`.zprofile` in `ZDOTDIR` from the installer's environment, otherwise
in whatever `zsh -c 'print -r -- ${ZDOTDIR:-$HOME}'` reports (with `ZDOTDIR`
removed from its environment). `.zshenv` stays in HOME when `~/.zshenv` is what
sets `ZDOTDIR`, because zsh reads it before the change takes effect. This probe
runs the user's own `.zshenv`, including during `inspect`; it must stay
read-only. `install_zsh_config`, `remove_managed_blocks`, `verify_zsh_config`
and the inspect `file` records all use the same resolution.

Legacy loaders from the pre-installer instructions (an unmarked `.zshrc` line
sourcing `…/zsh/start.zsh`, usually wrapped in `if [[ -o interactive ]]`, and a
`# leos-profiles zshenv` snippet) are detected only outside managed blocks.
Inspect reports them as `migration` records; apply and `remove-blocks` remove
them after the one-time `.leos-profiles.bak` backup, and verification fails
while one remains. The three-line wrapper is removed whole; any other matching
line becomes a `:` no-op so an enclosing block still parses.

## Node and package invariants

Yarn and pnpm each depend on fnm. Node policy is `current-lts`: installing fnm
resolves the current LTS (from `index.tab`, or `fnm list-remote --lts`),
installs it and makes it the default; another Node on PATH is not adopted.
Verification only requires a working default, so a newer LTS alone does not
make the step look undone: a full upgrade re-runs the step and moves the
default, while a repair leaves it. The state file's diagnostic column records
the version installed. Run npm tool installation and verification with
explicit `fnm exec --using=default` so a non-interactive installer does not
accidentally use an older system Node.

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
status 0 and silently skips the remaining assertions. Where a behaviour depends
on a terminal (TERM=dumb output, the `cat` wrapper) the suite drives an
interactive shell on a pseudo-terminal through `python3 -I`; it also checks
that `zsh -ic` without one writes nothing to stderr. Command wrappers are tested
with fake `eza`/`bat`/`ls`/`cat` executables that record their argv.

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

Network-backed checks resolve upstream sources and package availability:

```bash
bash tests/plugins-test.sh
GITHUB_TOKEN=$(gh auth token) bash tests/release-artifacts-test.sh
bash tests/package-map-availability.sh macos  # or apt, fedora, arch
```

The release check resolves every Linux release asset for both CPUs (from any
host), verifies the two pinned digests and the latest Nerd Fonts archive, and
then, on Linux, installs and runs each latest release (a second install must
find it current) plus npm's Yarn and pnpm on the current LTS; on macOS it
checks that each Homebrew formula exists. Plugin checks clone each default
branch and load the combined real Zsh plugin integration. CI also checks TOML and fenced Bash in the runbook.
None of these alone substitutes for actual package installation.

## CI layout

Two workflows split fast feedback from real provisioning:

- `.github/workflows/ci.yml` runs on every push to `master`, every pull request
  and on demand: Zsh syntax and profile tests, lint (ShellCheck, actionlint,
  zizmor, ruff; shfmt informational), installer/credential/Node/cache/util
  suites, release artifacts, package-map availability on macOS, apt and
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
  Jobs that look up GitHub releases get the workflow's read-only
  `GITHUB_TOKEN`, so many jobs behind one address stay under the API's
  anonymous rate limit.

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
Yarn/pnpm execution, recommended provisioning, repeat reconciliation, a
full-upgrade reconcile that re-runs the tools and finds them current (Linux),
repair (of bun, Starship, the `.zshenv` managed block, a plugin checkout left
detached as the pinned installs did, and the font) and the refusal to discard
a locally edited plugin.
They skip credentials, disable login-shell changes, and explicitly install
fonts. Unit and credential fixture tests cover the excluded interactive flows;
manual end-to-end GitHub registration remains outside automated CI.

The configured matrix is a coverage target. Claim a particular platform passed
only with that run's evidence, and report failures or unexecuted jobs separately.
See [the provisioning workflow](../.github/workflows/provision.yml) for exact
runner labels and triggers.

## Upstream sources

Tools are not pinned, so there is no routine dependency bump. What needs care:

1. A renamed release asset, a dropped CPU build or a project that moves breaks
   installs. `tests/release-artifacts-test.sh` resolves every asset for both
   Linux CPUs on every CI run; fix `installer/sources.sh` when it fails.
2. GitHub must publish a SHA-256 digest for the asset (it does for every asset
   uploaded since mid-2025); the installer refuses an asset without one.
3. Keep the version line in `artifact_registry` matching what the tool prints;
   verification accepts any version but checks that shape.
4. The two pinned downloads change deliberately: update the URL and SHA-256
   together in `installer/sources.sh` (Homebrew's installer at a reviewed
   commit; rpatool's repository is archived, so it should never change).
5. Behaviour changes upstream (a new major pnpm, a Node LTS that a tool does
   not support yet) reach users on their next full upgrade. Run the real
   provisioning matrix when a failure points there, and say in the change
   description which upstream versions it was tested with.

## Startup benchmark

Measure the actual installed public checkout with the benchmark helper:

```bash
zsh tests/startup-benchmark.zsh "$HOME/.leos-profiles"        # non-terminal exit time
zsh tests/startup-benchmark.zsh --pty "$HOME/.leos-profiles"  # first prompt and command lag
# Fixture under HOME instead of the system temporary directory (see below):
mkdir -p ~/.cache/leos-bench && TMPDIR=~/.cache/leos-bench/ zsh tests/startup-benchmark.zsh --pty "$HOME/.leos-profiles"
```

Each mode measures three scenarios: cold (no init cache, no completion dump),
warm, and aged-dump (warm caches with the completion dump backdated two days, which
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

The performance pass (audit PR 4) was measured on 2026-10-10 on the same
machine (Zsh 5.9.2, Homebrew 7.0.9, fnm 1.39.0, Node 24.18.0, pnpm 12.11.2,
Bun 1.3.11, Starship 1.26.0, same pyenv/rbenv; installed plugins; ten samples,
20 Enter presses; run from a Git checkout, so Starship's Git modules are part
of every prompt). "Before" is `origin/fix/zsh-runtime` at `9a85aa7`; "after"
is `perf/startup`, with and without the `.zwc` files the installer now writes.
The load on the machine varied between runs, so compare columns of one table.

On this Mac the helper's default temporary directory (`/var/folders/...`)
makes file-system-heavy work (fpath globs, compaudit, plugin loading) about
twice as slow as the same files under HOME, where the real profile lives. Both
locations are reported; `TMPDIR=<dir under HOME>/` selects the second.

| Scenario (median ms) | Before | After | After, compiled |
| --- | --- | --- | --- |
| HOME: first prompt, warm | 296.2 | 130.8 | 127.1 |
| HOME: first prompt, aged dump | 302.4 | 160.7 | 154.4 |
| HOME: first prompt, cold | 1793.5 | 1661.2 | 1651.3 |
| HOME: command lag | 44.9 | 29.4 | 29.7 |
| HOME: exit time, warm / aged / cold | 228.3 / 237.5 / 1679.1 | 86.1 / 113.2 / 1568.5 | 79.8 / 107.9 / 1565.7 |
| default TMPDIR: first prompt, warm | 533.6 | 239.2 | 227.5 |
| default TMPDIR: first prompt, aged dump | 627.8 | 599.1 | 571.2 |
| default TMPDIR: first prompt, cold | 2267.6 | 2409.0 | 2327.3 |
| default TMPDIR: command lag | 51.6 | 32.8 | 31.2 |
| default TMPDIR: exit time, warm / aged / cold | 429.8 / 510.7 / 2180.6 | 188.3 / 538.4 / 2252.6 | 173.5 / 510.9 / 2120.9 |

An earlier, quieter "before" run with the default TMPDIR measured first prompt
453.3 (warm), 537.2 (aged), 2193.8 (cold), lag 39.6, and exit time 393.8 /
481.7 / 2089.4. Before, every shell ran compaudit; now only the first shell of
a day (the aged-dump scenario) does. With the default TMPDIR, where compaudit
alone costs a few hundred milliseconds, the aged-dump time therefore barely
moves while the warm time halves. Cold startup is dominated by the generators
themselves (heroku and the Node completions start Node) and is noise-bound.

What remains, from zprof and the pty runs: `brew shellenv` (about 20 ms, kept
per shell on purpose), `fnm env` (about 5 ms), sourcing the plugins and cached
scripts, and on every prompt Starship (10 to 20 ms, more in a large Git
repository), the direnv hook (about 6 ms) and the plugin hooks. The 110 ms
first-prompt and 20 ms lag goals are not met in this harness; reaching them
needs deferred loading or fewer per-prompt tools, outside this pass.

Each cache entry starts with a `# leos-id:` line holding its identity: key,
resolved binary path, HOME, version-manager roots, the optional output filter
(`__leos_init_filter`, which pyenv and Starship use) and the arguments, each
field `(q+)`-quoted so newlines or NULs cannot forge it, plus any
generator-specific variables the caller folds into the key (zoxide's
`_ZO_ECHO` and `_ZO_RESOLVE_SYMLINKS`). The file name is the `%XX`-encoded key
and a 32-bit FNV-1a digest of that line, computed in-process; the line itself,
read with `read` (no fork), decides whether an entry is used. Bump the key when
a filter's behaviour changes. The cache checks ownership, write permissions and
symlinks before executing persisted scripts or compiled files, and creates
private directories/files. `__leos_cache_dir` validates every ancestor once per
shell and memoizes the result (success or failure) keyed on the cache root and
EUID; repeat calls lstat the root and the two profile-owned levels and validate
in full again if their owner, mode or inode changed. Tests that change
permissions mid-shell call `__leos_cache_forget`. A warm cache hit costs about
0.4 ms, against 3 to 6 ms for running the cached generators directly (zoxide,
direnv, Starship, fzf), so every generator stays cached. Launcher mtime controls
freshness; use `leos-refresh-init-cache` after updates to other implementation
files. It also recompiles the profile and plugin sources (`.zwc`), as the
installer does after the plugins or zsh-config step.

Startup files test for tools with `whence -p tool >/dev/null` and then read
`$commands[tool]`; a `$+commands[tool]` miss fills zsh's whole command table
(2 to 3 ms) and every PATH edit empties it again. A profile test keeps
`$+commands` out of `zsh/*.zsh` and `zsh/path/*.zsh`.

Homebrew shellenv and fnm env run per shell rather than
being cached. Test both a clean PATH and an already-configured PATH, and verify
that different shells receive different fnm multishell directories. Daily
background jobs (shim rehash, fnm multishell pruning) share the
`__leos_daily_due` stamp helper in `zsh/cache.zsh`, which answers "not due"
from a stamp younger than a day without validating anything (a stamp can only
suppress a job) and validates the directory before a due job runs; test
fixtures stub `__leos_rehash_daily` and `__leos_fnm_prune_daily` so no
detached process outlives a test. The completion dump is `zcompdump-$ZSH_VERSION`
in the same private cache root, with `zcompdump-$ZSH_VERSION.fpath` recording
the fpath it was built from: a dump younger than a day built from the same
fpath takes `compinit -C`; otherwise compaudit and a full compinit run and the
dump is touched (with its `.zwc` when compinit left the dump unchanged).
