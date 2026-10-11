# Development guide

## Installer structure

`install.sh` owns argument parsing, validation, inspection, and orchestration.
Sourced modules share its context and do not invoke provisioning when loaded.
The implementation stays compatible with macOS Bash 3.2. Users reach it
through the interactive `setup` wizard; `inspect`, `apply` and `reconcile`
are the deterministic, non-interactive contract underneath (the wizard, an
optional AI assistant following QUICK-INSTALL.md, and automation all use it).

| File | Responsibility |
| --- | --- |
| `installer/registry.sh` | Ordered component registry, dependency closure, handler validation, and the direct-artifact table |
| `installer/state.sh` | Saved profiles, schema migration, state signatures, locking and cleanup |
| `installer/packages.sh` | Platform bootstrap, package maps and package-manager operations |
| `installer/tools.sh` | Locked tools, dependency checkouts and Node selection/activation |
| `installer/config.sh` | Managed shell blocks, symlink-aware rewrites and default-shell changes |
| `installer/credentials.sh` | Local key preparation, read-only GitHub checks and manual-action pauses |
| `installer/verification.sh` | Component postconditions |
| `installer/signatures.sh` | Inputs that invalidate each component's recorded state |
| `installer/lock.sh` | Reviewed versions, URLs, commits, digests and npm engine requirements |
| `installer/plan.sh` | Disclosure records beyond the selection, the preflight before any change, and the inventory |
| `installer/setup.sh` | The interactive `setup` wizard: questions, plan display, running apply/reconcile and resuming after manual actions |

Add a component to the registry and supply its install, verification and
signature handlers. Registry validation rejects missing handlers or unknown
dependencies. A tool downloaded as a pinned file or archive into `~/.local/bin`
is one row in `artifact_registry` (owning component, lock prefix, archive kind,
executables, expected `--version` line) plus its `<PREFIX>_VERSION` and
per-platform `<PREFIX>_<DARWIN|LINUX>_<AARCH64|X64>_URL`/`_SHA256` values in
`lock.sh`; its handlers then just call `artifact_install`, `artifact_verify`
and `artifact_signature`, and inspect, the inventory, the shadow check and
`tests/locked-artifacts-test.sh` pick it up from the table. Tests should check behavior and repair, not just matching names.
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
| `warning` | 3 | name, message | `unsupported-platform` (an Intel Mac or macOS before 15: Homebrew Tier 2/3), `no-locked-artifact` (no locked build for this platform), `node-version` (the given `--node-version` is not what the plan resolves now) |
| `profile` | 3 | `root`, path | Authoritative local checkout |
| `policy` | 3 | `node`, `full-upgrade` or `selection`, value | Node selection policy; `yes`/`no` host upgrade; `saved` when `inspect --saved` read the selection from the saved profile |
| `channel` | 3 | source, channel | Moving sources: `packages`, `node`, `ai-cli-updates` |
| `migration` | 4 | `profile-schema`, `1`, `2`; or `legacy-loader` / `legacy-environment`, file path, managed marker | Pending profile migration; or a legacy unmarked loader (`.zshrc`) or zshenv snippet (`.zshenv`) that `zsh-config` and `remove-blocks` remove |
| `group` | 4 | category, name, status | Selected, implied or internal group; `credential` groups are `ssh` (`skip`/`reuse`/`generate`/`agent`), `gpg` (`skip`/`reuse`/`generate`) and `signing` (`skip`/`ssh`/`gpg`) |
| `package` | 3 | OS family, name | Exact OS package member; also the pinentry package GPG signing installs |
| `action` | 3 | step, description | Planned effect of a step or bootstrap; credentials add `ssh`, `ssh-config` (`--ssh-config yes`), `gpg`, `signing` (`--signing ssh`) and `pinentry` |
| `artifact` | 5 | source kind, name, URL/repository, digest/commit | Locked executable dependency; the digest of a Nerd Font archive is `SHA-256.txt`, read from the pinned checksum list at apply time |
| `external` | 3 | service, description or URL | External service the plan contacts |
| `file` | 3 | name, path | File the plan reads or writes; `zshrc`, `zshenv` and (macOS) `zprofile` give the resolved zsh startup files; credentials add `ssh-known-hosts`, `ssh-reference` (a key file), `ssh-agent-public-key`, `ssh-config`, `allowed-signers` and `gpg-agent-conf` |
| `global` | 3 | `git`, keys | Global Git settings the plan configures: `user.signingkey,gpg.format,commit.gpgsign` (`--signing gpg`), plus `gpg.ssh.allowedSignersFile` (`--signing ssh`); none for `--signing skip` |
| `irreversible` | 3 | effect, explanation | Effect that cannot be automatically undone: `host-upgrade` (package upgrades), `login-shell` (chsh) |
| `privileged` | 3 | action, command or description | An action run as root (through sudo, or directly when root): `homebrew-bootstrap`, `bootstrap`, `package-manager`, `repository`, `dnf-swap`, `pacman-sync`, `credential-packages`, `etc-shells`, `login-shell` |
| `behaviour` | 3 | name, description | A side effect beyond the listed files and packages: `compat-symlinks` (apt fd/bat links), `gnu-tools` (GNU tools ahead of BSD on macOS), `git-identity` (global name/email writes), `ssh-agent` (`--ssh agent` lists the agent's keys), `brew-mirror`, `login-shell` (macOS uses `/bin/zsh`) |
| `conflict` | 4 | component, path, reason | An existing installation in the way of `pyenv`/`rbenv`: `not-a-git-checkout`, `unexpected-origin`, `local-changes` (apply stops unless `--skip-existing-version-managers`), or `homebrew-install` (informational) |
| `existing` | 4 | name, path, effect | A shell framework or version manager the profile coexists with: `oh-my-zsh`, `powerlevel10k`, `nvm`, `conda`, `asdf`, `mise` |
| `shadow` | 4 | executable, other copy, pinned copy | A Homebrew copy of a locked artifact that the pinned `~/.local/bin` copy will shadow |
| `runtime` | 4 | `node`, version, origin | `preserved-fnm`, `adopted-existing`, or `current-lts` |
| `postcondition` | 3 | component, status | Current `verified` or `needed` result; `skipped` when `--skip-existing-version-managers` keeps an existing pyenv/rbenv |
| `manual-action` | 4 | action, public path, destination | Manual intervention required; process exits 3 |
| `item` | 5 | kind, name, path, `present`/`absent` | `inventory --tsv` only: something the installer creates or manages |

A runtime preview may report `unresolved` / `resolve-during-apply`.

Manual-action names cover registration (`register-ssh-key`,
`register-gpg-key`, `register-ssh-signing-key`), login (`github-login`),
read scopes (`github-email-scope`; `github-key-scope`, whose destination is the
exact `gh auth refresh -h github.com -s ...` command naming the
`read:public_key`, `read:gpg_key` and `read:ssh_signing_key` scopes the
selected modes need), key selection (`select-ssh-key`, `select-gpg-key`), SSH
verification and configuration (`verify-ssh-key`, `configure-ssh-key`),
`run-in-terminal` (the destination is the exact
command to run in a terminal; see "Apply flow" below), `set-login-shell`
(chsh is missing) and `install-windows-font` (WSL). gh exits 1 for every API
failure; `github_list` maps an HTTP 403/404 whose message names a scope (or a
fine-grained token's "Resource not accessible") to a scope action and keeps
every other failure (network, 5xx, rate limit) an error. An empty public-path field is valid for actions
such as login. Only public artifacts are referenced: never emit private key
contents, tokens or passphrases. On registration pauses, save the explicit
reference first and retain the public artifact after EXIT cleanup. Reconciliation
must never generate a replacement. Pending initial generation resumes the
originally approved apply; API/network failures must not be interpreted as
missing registration. Enabling global commit signing (GPG or SSH) follows a
successful local test signature (SSH: also `git verify-commit`) and confirmed
GitHub registration; `--signing skip` changes no signing setting.

Credentials are not registry components and record no state: every apply and
reconcile re-runs and re-verifies them, so a changed `--signing`,
`--ssh-config` or key takes effect on the next run without a signature
handler. Their optional profile keys (`signing`, `ssh-config`, `gpg-expiry`)
may be missing from older profiles: `signing` then resolves to `gpg` when a GPG
key is selected, else `skip`, the same rule as a command line without
`--signing`. A `--gpg generate` is refused in preflight while the profile's
saved `gpg-key` is still in the keyring. Tests stub gh, ssh, ssh-add,
ssh-keygen, gpg, gpgconf and git in `tests/credentials-test.sh` (toggles for
each refusal and manual-action branch); its real-key block signs and verifies
real SSH and GPG commits in a disposable HOME, GNUPGHOME and Git config.

## Apply flow

`main` runs, in order: argument parsing; `setup` (the wizard, which runs
`inspect` and `apply` as child processes of the same script); `remove-blocks`
and `inventory` (dispatched before platform detection, so they work anywhere); the saved
profile for `reconcile` and `inspect --saved`; validation, dependency closure
and `detect_os`; `inspect` stops here. Apply and reconcile then warn about an
unsupported platform, capture the existing Node, and run `preflight`; only
after it do they take the lock, migrate local state, write the profile, apply
the Homebrew mirror, bootstrap, resolve Node, run each component, compile the
Zsh sources, and last provision credentials (the SSH key, the GPG key, then SSH signing). `finish_manual_actions` prints
every queued `manual-action` and exits 3; a credential pause calls it at
once.

`preflight` (installer/plan.sh) changes nothing. It stops on a blocking
pyenv/rbenv conflict (unless `--skip-existing-version-managers`), checks
`--node-version` against a live resolution (exit 2 when they differ), refuses a second `--gpg generate` and an `--ssh agent` without an agent socket, and
collects what the run needs from the user: when stdin is not a terminal, a
passphrase prompt, chsh's password prompt (Linux, non-root) or a sudo password
(`privileged_plan` is not empty and `sudo -n true` fails) ends the run with
`manual-action run-in-terminal` carrying the exact command line, exit 3, before
the lock exists. With a terminal, `sudo -v` asks once up front. Dry runs never
call sudo; they report what would stop. Last, it downloads the pinned Nerd
Fonts checksum list and rejects an unknown font name. Tests stub
`stdin_is_terminal`, `sudo` and `privileged_plan`.

A component that needs the user (a missing chsh) calls `queue_manual_action`
and sets `STEP_AWAITS_MANUAL_ACTION`: `run_step` then leaves it unrecorded and
the run continues.

## Setup wizard

`install.sh setup [--print-command] [--dry-run]` (`installer/setup.sh`) is the
primary user interface. It needs a terminal on stdin and stdout (otherwise it
prints the non-interactive commands and exits 2) and keeps to plain `read`
and `printf`: numbered single-selects, numbered toggle lists for components
and package groups, at most 78 columns, colour only without `NO_COLOR` and
`TERM=dumb`, and `q` or end of input to quit.

It must not grow its own provisioning logic. Its rules:

- The plan, findings, packages, implied groups and Node version come from
  `install.sh inspect` (or `inspect --saved`) run as a child process with the
  wizard's explicit flags, parsed by record type with empty columns kept
  (records are re-split on a non-whitespace separator before `read`). While
  the user toggles, implied groups come from the engine's own
  `normalise_dependencies`; group members from `package_list_for_group`;
  free-text values (key path, font name, GPG expiry, Git identity) are
  checked with `validate_options` in a subshell, and a font name also against
  the pinned Nerd Fonts checksum list (`fetch_nerd_font_checksums`).
- It applies by running `install.sh apply --yes` with every choice as an
  explicit flag plus `--node-version` from the inspected `runtime` record (or
  `reconcile --yes [--full-upgrade]` for a saved setup), streaming the output
  through `tee` into a log it names at the end; stdin stays the terminal, so
  the engine's preflight asks for sudo once.
- Exit 3: it lists the attempt's `manual-action` records with the engine's
  explanations and, on Enter, runs the same command again, switching a key
  the first attempt generated to `reuse` from the saved profile. Exit 2 (the
  Node version moved): it inspects again and asks again.
- `--print-command` prints the equivalent command (words quoted only when
  needed) instead of running it; `--dry-run` adds `--dry-run`.
- Its functions are sourced into the engine, so they use the `setup_`, `w_`
  and `plan_` prefixes; `tests/setup-wizard-test.sh` fails if one replaces an
  engine function.

`tests/setup-wizard-test.sh` drives the real CLI on a pseudo-terminal through
`python3 -I` (an expect-style driver it writes into the fixture), in a
fixture HOME and checkout copy with the same PATH fakes as `readonly-test.sh`:
Recommended and Customize with `--print-command` (the exact argv), no
terminal, a non-Git `~/.pyenv`, a saved profile, and one `--dry-run` through
apply. It also checks that every line fits 80 columns and that `NO_COLOR`
output has no escape sequences, plus unit checks of the manual-action screen
and the resume rules.

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
bash tests/setup-wizard-test.sh
/bin/bash tests/setup-wizard-test.sh  # macOS: the setup wizard under Bash 3.2
bash tests/node-test.sh
bash tests/credentials-test.sh
zsh tests/profile-test.zsh
zsh tests/runtime-cache-test.zsh
/usr/bin/python3 -I tests/rmdsstore_test.py  # macOS; elsewhere python3
```

These suites use fixtures and are safe on a provisioned workstation: they
redirect HOME, XDG state and Git configuration, and the CLI-level tests
(`apply-dryrun-test.sh`, `readonly-test.sh`, `setup-wizard-test.sh`) run a
temporary copy of the public checkout so your `local/` state is never read or
written. `install-test.sh`
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

Network-backed checks verify pinned dependencies and package availability:

```bash
bash tests/locked-plugins-test.sh
bash tests/locked-artifacts-test.sh
bash tests/package-map-availability.sh macos  # or apt, fedora, arch
```

The artifact checks execute downloaded binaries appropriate to the host and
verify npm package engine declarations. Plugin checks load the combined real
Zsh plugin integration. CI also checks TOML and the fenced Bash blocks in
QUICK-INSTALL.md.
None of these alone substitutes for actual package installation.

## CI layout

Two workflows split fast feedback from real provisioning:

- `.github/workflows/ci.yml` runs on every push to `master`, every pull request
  and on demand: Zsh syntax and profile tests, lint (ShellCheck, actionlint,
  zizmor, ruff; shfmt informational), installer/credential/Node/cache/util
  suites, locked artifacts, package-map availability on macOS, apt and
  containers, the dry-run smoke test, the read-only test and the setup wizard
  on a pty. The macOS jobs run
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
Yarn/pnpm execution, recommended provisioning, repeat reconciliation, repair
(of bun, Starship, the `.zshenv` managed block, a drifted plugin checkout and
the font) and the refusal to discard a locally edited plugin.
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
   unverified replacement installer. GitHub publishes each release asset's
   SHA-256: `gh api repos/<owner>/<repo>/releases/tags/<tag> --jq
   '.assets[]|[.name,.digest]|@tsv'`. For Nerd Fonts, pin the release and the
   digest of its `SHA-256.txt`; font archives are checked against that list.
   `LEOS_ARTIFACT_ALL_PLATFORMS=1 bash tests/locked-artifacts-test.sh`
   downloads and digest-checks every platform's artifact from one machine.
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
