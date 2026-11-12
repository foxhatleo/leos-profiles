# Development guide

The [README](../README.md) is the guide for people installing and using the
profile. This file is the reference for how it works and why, for anyone
changing it; `AGENTS.md` summarises its rules and checks.

## Design notes

### Why not chezmoi or GNU stow

The dotfile surface here is deliberately tiny: two managed blocks (three on
macOS) plus a `STARSHIP_CONFIG` pointer, so templating and symlink-farm tools
solve very little of the actual problem. What `install.sh` mostly does is
*machine provisioning*: OS packages across four distribution families,
bun/fnm/starship/uv from Homebrew or age-gated, digest-checked releases,
Corepack's pnpm and Yarn, the newest Node LTS, CPython and Ruby lines,
rbenv/plugin checkouts at age-gated releases, local SSH/GPG preparation and
read-only GitHub verification, a verified Nerd Fonts release archive, and
`chsh`. chezmoi covers that only through `run_once_` escape hatches, which
would leave the same amount of shell to maintain plus a second tool to learn.

The engine is built around a plan you can read before anything changes:
`inspect` emits typed TSV that setup renders, and `apply` is a non-interactive
executor with per-step signatures and postcondition verification. The cost is
a bespoke idempotency/state/locking engine to keep correct, which is why it
carries a test suite and a per-OS CI matrix. If the dotfile surface ever grows
beyond a couple of managed blocks, revisit this.

`install.sh` derives the profile root only from its own physical directory.
The local checkout is authoritative: local edits take effect immediately and
the installer does not enforce a particular release, commit, origin, owner or
signature. Only `upgrade-leos-profiles` is stricter, and only about pulling
(a clean branch checkout with an upstream, `git merge --ff-only` after showing
the incoming commits). Only `setup` asks questions; `apply` and `reconcile`
never do.

### Selection model

Component groups are `bins`, `packages`, `rbenv`, `bun`, `fnm`, `corepack`,
`uv`, `cpython`, `starship`, `plugins`, `fonts`, `zsh-config` and
`default-shell`. Package groups are `core-utils`, `shell`, `dev-tools`,
`python`, `media`, `network`, `heroku` and `system`. Internal `bootstrap`,
`ssh` and `gpg` groups make the remaining mutations visible in the plan.

Groups are atomic: selecting one selects every member. A component implies a
package group only when it needs its members: rpatool (`bins`) implies the
small `python` group (the OS python3 alone); rbenv implies `dev-tools`, which
carries what ruby-build suggests for building a current Ruby (a C toolchain,
autoconf, OpenSSL, libyaml, zlib, libffi, GMP, and rustc for YJIT) besides the
GitHub CLI and jq; plugins, Zsh configuration and default-shell setup imply
`shell`. Bun, fnm, Corepack, uv's CPython and Starship imply no OS runtimes:
they are self-contained, and Corepack's pnpm and Yarn run on fnm's Node, so
selecting them never installs a system Node, Python or Ruby. `corepack`
implies `fnm`, and `cpython` implies `uv`, which run before them.

Recommended (`RECOMMENDED_GROUPS` in `install.sh`) selects every component
except `bins`, and every package group except `python` and `heroku`, with a
full upgrade, fonts and the login shell on `auto`, and SSH and GPG on `skip`.
`heroku` is macOS-only and opt-in: the Heroku CLI is a homebrew/core formula
(no tap is added), and no Linux distribution packages it. A Mac that tapped
`heroku/brew` for an older installer can `brew untap heroku/brew` once
`brew info heroku` names homebrew/core. There is no `languages` group any more;
`--package-groups languages` stops with that explanation.

With `--no-full-upgrade`, only missing selected packages are requested from
the package manager. Dependency resolution can still install or upgrade
dependencies; this does not freeze the host package set. A full upgrade (here
and in the `*-checkup` commands) stays within the current OS release
(`apt-get upgrade`, `dnf upgrade`, `pacman -Syu`, `brew upgrade`) and never
runs `do-release-upgrade` or `dnf system-upgrade`.

### Local state

The ignored `local/` directory is machine-owned (mode 700, files 600):

- `local/install-profile.tsv`: the normalized groups, upgrade/font/shell
  policies, Git identity, selected SSH path, GPG fingerprint, release age and
  moving-tool channels (see "State and TSV contract").
- `local/install-state.tsv`: verified step signatures, timestamps and resolved
  moving versions such as the Node LTS and the Ruby rbenv compiled (or that its
  compile failed).
- `local/private.zsh` and `local/private-interactive.zsh`: the user's own
  overrides (see "Zsh runtime").
- `local/flags/`: GNU preference (`no-gnu`), Homebrew mirror (`brew-china`)
  and optional-tool warning (`no-brew`, `no-rbenv`) choices.
- Public GPG exports awaiting manual registration.

The installer stores no passphrases, tokens, private keys or exported secret
key material there; a user's `private.zsh` may contain secrets. On first use,
legacy XDG installer state, `zsh/_private.zsh` and the old home-directory
markers are migrated (`migrate_local_state`); conflicting old and new values
stop with both paths for the user to resolve.

Apply and reconcile use an atomic `local/.install.lock`, secure temporary
paths, cleanup traps, atomic profile/state/config writes and first-write
managed-block backups. A saved state row is only a resume hint:
postconditions are checked, so missing or corrupt tools are repaired.

### What a plan discloses

Besides the selection, packages, artifacts and files, `inspect` reports every
action that runs as root (`privileged`: package-manager runs, Arch's
`pacman -Syu`, Fedora's RPM Fusion and ffmpeg swap, the GitHub CLI apt
repository on Debian/Ubuntu, the `/etc/shells` edit, `sudo chsh`, cask
upgrades), side effects (`behaviour`), effects that cannot be undone
automatically (`irreversible`), existing installations in the way
(`conflict`), shell setups the profile coexists with (`existing`), on Linux
Homebrew copies the profile's tools will shadow (`shadow`), what moves off an
older layout (`migration`) and `warning`s such as an unsupported Mac. The
record table under "State and TSV contract" lists them all; `render_plan` in
`installer/setup.sh` shows each type (all but `meta`) under a heading.

Pass the Node version `inspect` resolved with `--node-version vX.Y.Z`: apply
then installs exactly that one and stops with status 2 if it would now choose
another. Components install before credentials, so a first SSH or GPG
registration pause does not hold back the rest; every manual action is listed
at the end and the run exits 3.

### Where tools come from

Tools follow upstream rather than reviewed pins, held back by the minimum
release age (see "Release age"):

| Source | macOS | Linux |
|---|---|---|
| bun, fnm, Starship, uv (and uvx) | Homebrew formula | the newest GitHub release at least that old (never a draft or prerelease) into `~/.local/bin`, checked against GitHub's SHA-256 digest for the asset and, when gh is logged in and the project publishes one, its attestation |
| Corepack (pnpm, Yarn) | npm's latest Corepack into `~/.local/npm`, installed with fnm's Node; it installs pnpm's latest and Yarn's stable release | the same |
| rbenv, zsh-completions, fzf-tab | Git checkout of the newest version tag at least that old | the same |
| zsh-autosuggestions, zsh-syntax-highlighting | Git checkout of the newest default-branch commit at least that old (their tags are years old) | the same |
| ruby-build | Git checkout of its newest version tag, without delay (new tags are how new Ruby releases become installable) | the same |
| Nerd Fonts | the newest release at least that old, checked against its `SHA-256.txt` | the same |
| Node, Python, Ruby | see "Runtime and package invariants" | the same |

Homebrew formulae, OS packages, and Corepack with the pnpm and Yarn it
installs are not held back (inspect warns). Checkouts are left detached at
their release; one may move back to an older release when the newest is not
old enough yet. A full upgrade re-runs the steps in `step_follows_upstream`,
which install the release that is now old enough (skipping the download when
it is already installed), upgrade an outdated formula and move each checkout;
without one a run only repairs what is missing or broken. When GitHub cannot
be reached, or refuses at the anonymous rate limit (60 requests an hour; the
installer uses `GITHUB_TOKEN`, or gh's token when gh is logged in), a tool that
is already installed and works is kept with a warning; only a missing or
broken one stops the run.

On macOS the full upgrade runs `brew update` and `brew upgrade` (formulae),
and upgrades casks only with `--upgrade-casks` (saved for reconcile);
`brew-checkup` always upgrades casks. Two downloads stay pinned to a reviewed
URL and SHA-256: Homebrew's installer script (it runs once, on a Mac without
Homebrew, and is re-pinned when a new macOS ships) and rpatool (its archived
GitHub repository's final commit; development moved to
codeberg.org/shiz/rpatool).

On Debian and Ubuntu, dev-tools takes gh from GitHub CLI's own apt repository
(`https://cli.github.com/packages`), because the distributions' gh is years
old (2.4 on Ubuntu 22.04, 2.23 on Debian 12). The packages step installs its
keyring, checked against the SHA-256 GitHub publishes, as
`/etc/apt/keyrings/githubcli-archive-keyring.gpg` and its source line as
`/etc/apt/sources.list.d/github-cli.list`, before the apt install; the plan
lists both as a root action. An existing correct setup, or any other apt
source for that repository, is left alone. A gh installed earlier from the
distribution moves to the repository's version on the next full upgrade. On
Fedora the media group enables RPM Fusion (free) for the full ffmpeg and swaps
out `ffmpeg-free` (`fedora_install_media`).

Equivalent GitHub HTTPS/SSH origins are accepted and normalized; dirty
installer-managed checkouts, and checkouts at a commit made locally, are
refused rather than overwritten. uv and uvx install as one artifact (the
static musl builds on Linux, as for Starship). Nerd Fonts come from one font's
archive in the picked release; an unknown font name is refused before
anything is downloaded. Fonts go to `~/Library/Fonts/NerdFonts` on macOS and
`${XDG_DATA_HOME:-~/.local/share}/fonts/NerdFonts` on Linux (then
`fc-cache`); under WSL the run ends with an `install-windows-font` manual
action.

Proxies: the proxy variables (`http_proxy`, `https_proxy`, `no_proxy`,
`ALL_PROXY` and their uppercase forms) are kept through sudo;
`FNM_NODE_DIST_MIRROR` (an https URL) serves the Node LTS lookup as well as
fnm's downloads; on macOS `--brew-mirror china` uses the USTC Homebrew mirror
(Homebrew's own code, metadata and bottles) for the run, including a Homebrew
bootstrap, and for later shells, exactly like `brew-china-enable`.

### Migrations from older layouts

Each is reported by inspect as a `migration` record and done by the next
approved run:

- Saved profiles before schema 4 (see "State and TSV contract"): `pyenv`
  becomes `cpython`, `yarn` and `pnpm` become `corepack`, `plugins` gains
  `starship`, and the `languages` package group is dropped (its packages stay
  installed).
- Machines set up before 2026-10 carry pinned copies: on macOS the
  `~/.local/bin` copies are removed once the Homebrew formula is installed
  (they come first on PATH and would shadow it). Checkouts on their default
  branch (the 2026-10 layout) move to their release, detached.
- Machines set up before 2026-11 had `yarn` and `pnpm` components: the
  `corepack` step removes their npm packages from `~/.local/npm` (Corepack's
  shims take those names) and, on macOS, uninstalls the Homebrew `yarn` and
  `pnpm` formulae only when the state file shows the profile installed them.
  pyenv is no longer installed or updated: an existing `~/.pyenv` stays and
  `zsh/path/pyenv.zsh` still activates it.
- Pre-installer loaders (see "Zsh startup files").

### Credentials

SSH and GPG default to Skip. Reuse requires a specifically selected SSH
private-key path or full GPG fingerprint; existing keys are never silently
chosen. New SSH keys default to `~/.ssh/id_ed25519`, or an explicitly chosen
unused absolute path; existing files are not replaced. Both `empty` and
`prompt` passphrase policies are supported; `empty` is the default and is
warned about.

GitHub operations are read-only. The installer never uploads keys, logs into
GitHub without asking (setup offers to run `gh auth login`, which the user
answers), or changes SSH identity configuration or GitHub CLI's Git protocol.
SSH derives matching public material, compares GitHub host keys with the API,
and verifies both the selected identity and ordinary SSH against the same
GitHub account. GPG requires a verified email, signs a real temporary commit,
and enables global **commit** signing only after registration is confirmed;
`tag.gpgsign` is left alone. Reconciliation never generates credentials. If
an initial run paused before another requested key was generated, resume the
originally approved apply choices while reusing keys already created. A
network/API failure remains an error, not evidence that a key is missing.

### Existing setups

The installer appends its loader to `.zshrc`; it never rewrites the rest.
`report_existing_setups` (`installer/plan.sh`) emits an `existing` record for
each of these; the README gives the short advice.

- **oh-my-zsh**: its loader runs first, then the profile, so `compinit` runs
  twice and Starship replaces the oh-my-zsh theme. Set `ZSH_THEME=""` and drop
  plugins the profile already provides, or remove the oh-my-zsh lines.
- **powerlevel10k**: Starship sets the prompt after it. Keep one: remove the
  p10k source line and its instant-prompt block, or skip `starship`.
- **nvm**: fnm's default Node comes first in new shells; `nvm use` still
  switches.
- **pyenv**: no longer installed or updated, and left in place;
  `zsh/path/pyenv.zsh` still activates it, so in interactive shells its shims
  come before uv's `python3`. `pyenv global system` hands `python3` to uv's.
- **conda**: `conda activate` puts that environment's python ahead of uv's; a
  base environment `conda init` auto-activates does so in every shell.
- **asdf / mise**: they and fnm, uv's Python and rbenv all provide node,
  python and ruby; whichever comes first on PATH wins. Use one manager per
  language, or skip the overlapping components.
- **Linuxbrew copies of fnm, bun, Starship or uv**: on Linux the profile's
  copies in `~/.local/bin` come first (`shadow` records). On macOS the profile
  uses Homebrew's.
- **Homebrew rbenv**: `conflict … homebrew-install`. The profile uses its own
  `~/.rbenv` checkout when present and otherwise the one on PATH;
  `--skip-existing-version-managers` keeps Homebrew's alone.

### Zsh runtime

`start.zsh` loads, in order: the PATH and environment layer (`entries.zsh`:
tool paths, `env.zsh`, `commands.zsh`), `local/private.zsh`, the interactive
layer (`interactive.zsh`: key bindings, `compinit`, completion-registering
tools, fzf-tab, zsh-autosuggestions, custom completions,
zsh-syntax-highlighting as the last plugin, then the Starship prompt) and
finally `local/private-interactive.zsh`. Both private files are sourced at the
top level of `start.zsh`, so plain `typeset`, `local` and `typeset -A` in them
stay global, and both get a warning when they are readable by anyone but
their owner. While they load they can call `puts`, `puts-err`,
`add-path <dir>` and `entry <name>`; those names are removed once the profile
has loaded (unless an override file defined one itself), so code that runs
later uses `__leos_puts`, `__leos_puts_err`, `__leos_add_path`,
`__leos_entry` or plain `print`. With `TERM=dumb` (Emacs TRAMP and similar)
the shell stops after `local/private.zsh`: PATH and environment are set, but
there is no line editor, plugin or themed prompt. A root shell that kept
another user's HOME (`sudo -s`) does not load the profile at all, so it cannot
leave root-owned files in that HOME. `start.zsh` loads only once per shell.

The `.zshrc` block is interactive-only and the `.zshenv` and `.zprofile`
blocks are silent, so `scp`, `rsync` and non-interactive `ssh` cannot break on
startup output. The trade-off: a non-interactive shell (`ssh host cmd`, cron,
scripts) sees only `~/.local/bin`, `~/.local/npm/bin` and fnm's default Node in
front of the system PATH; no Homebrew, rbenv or Go. Remote one-liners that need
those use absolute paths or activate the tool explicitly, for example
`"$HOME/.local/bin/fnm" exec --using=default -- node --version`. On macOS, a
login shell's `/etc/zprofile` runs `path_helper`, which would push those
directories behind the system and Homebrew paths; the `.zprofile` block puts
them back in front, so `zsh -l -c` sees the same order.

PATH precedence in interactive shells is deliberate: version-manager shims
first, then `~/.local/bin`, then Go workspace bins, then Homebrew, so a stale
binary in `~/.local/bin` or `$GOPATH/bin` cannot shadow the Node/Python/Ruby a
project selected. fnm alone constructs its runtime PATH. Locale fallback
validates `C.UTF-8`, then `en_US.UTF-8`, and otherwise uses `C`. `LS_COLORS`,
`LSCOLORS`, `MANPAGER` and `MANROFFOPT` are set only when the environment does
not define them already.

Command wrappers stay compatible with the commands they replace. `ls` runs
eza (with `--group-directories-first`) only when its output is a terminal and
every argument means the same to eza as to ls: operands, `-1 -l -a -A -d -R`
in any combination, and long options that only eza has (`--git`, `--tree`,
`--icons`, ...) or that GNU ls spells the same way; anything else (`ls -ltr`,
`ls --sort=time`, a pipe) runs the real `ls` with the platform's colour flag.
The routing table is in `zsh/env.zsh`. `cat` runs
`bat --style=plain --paging=never` only for a terminal and no options. `egrep`
and `fgrep` become `grep -E`/`grep -F` with `--color=auto`, since GNU grep
warns that they are obsolescent. `EXTENDED_GLOB` is on with `^` and `#`
disabled as pattern characters (`disable -p`), so `git reset HEAD^` and
`nix run nixpkgs#hello` work; functions under `emulate -L zsh` get every
pattern back. The themed prompt leaves out Java and Kotlin versions: reading
them starts a JVM on every prompt.

Deterministic initialization scripts (rbenv, an existing pyenv, direnv,
zoxide, fzf, Starship, and npm/pnpm/Bun/uv/uvx completions) are cached under
`${XDG_CACHE_HOME:-~/.cache}/leos-profiles/init`; see "Startup benchmark" for
the identity line and trust checks. Homebrew's `brew shellenv` runs in each
shell because its output depends on the current environment (it prints
nothing when the Homebrew paths are already on PATH, and its variables follow
the prefix in use); an earlier version cached it and commit 36e6ab1 went back
to running it per shell (about 20 ms). `fnm env` also runs per shell because
it creates a unique `FNM_MULTISHELL_PATH`; a nested shell drops the multishell
directory it inherited, and once a day a background job deletes multishell
links older than a day whose shell has exited. rbenv (and an existing pyenv)
use `--no-rehash` and refresh their shims in the background at most once a
day. Yarn uses the `_yarn` completion bundled with zsh-completions.

Performance notes:

- A warm shell runs no cache bookkeeping forks: the cache directory is
  validated once per shell and entries are named and checked in-process.
- The completion system is audited and rebuilt at most once a day, or when the
  completion search path changes; other shells load the dump with
  `compinit -C`. `.zcompdump*` files earlier versions left in the home
  directory are removed once.
- An existing pyenv starts without forking bash to rewrite PATH and without
  its legacy `compctl` completion; `zsh/completions/_pyenv` completes it
  through the completion system instead.
- zsh-autosuggestions wraps its widgets once, at the first prompt; lines
  starting with commands whose completers start a Node, Ruby or Bash program
  (brew, npm, pnpm, yarn, bun, heroku, pyenv, rbenv, gcloud, ref-taking git
  subcommands) get history suggestions only.
- The installer and `leos-refresh-init-cache` compile the profile and plugin
  sources to `.zwc` files beside them. Zsh ignores a `.zwc` older than its
  source or from another Zsh version, so an edit or a pull is never shadowed.
- Starship's right prompt runs only when the configuration defines a
  `right_format`, and its continuation prompt is computed when shown.

### Maintenance commands

`bye` runs every package checkup defined in the shell (`brew-checkup`,
`apt-checkup`, `dnf-checkup`, `pacman-checkup`, each with autoremove, cache
cleanup or orphan removal), `ai-checkup` (native `claude update`,
`codex update`, and `opencode upgrade` for a copy Homebrew does not manage),
and on macOS `rmdsstore` plus a Finder/Dock/SystemUIServer restart, then exits
the shell. `--keep-history` is still accepted for old aliases; keeping history
is the default. The checkups run `leos-refresh-init-cache` afterwards, since a
package upgrade can change a tool's init logic in a file other than the
launcher the cache is keyed on.

`rmdsstore` (`util/rmdsstore.py`) deletes only named metadata files. With no
root it scans the complete writable APFS data volume and every volume mounted
directly under `/Volumes`. It rejects symlink roots, does not follow symlinks
or implicitly cross nested mount boundaries, includes cloud-storage
directories, and reports failures. On Linux, where only the tests run it, it
reads `/proc/self/mountinfo` to preserve same-device bind mounts; an
unreadable mount table aborts before deletion. Recycle-bin directory removal is opt-in
(`--purge-recycle-bins`). The wrapper runs it under sudo with the system
Python in isolated mode (`/usr/bin/python3 -I`), never a PATH-resolved one,
but the script itself lives in the user-owned checkout: trust changes to the
checkout before running maintenance with sudo. The same applies to
`upgrade-leos-profiles`, which is why it lists the incoming commits and asks
before running them through `reconcile` (with sudo).

## Installer structure

`install.sh` owns argument parsing, validation, inspection, and orchestration.
Sourced modules share its context and do not invoke provisioning when loaded.
The implementation stays compatible with macOS Bash 3.2, and so does
`bootstrap.sh`.

| File | Responsibility |
| --- | --- |
| `bootstrap.sh` | The curl entry point: installs Git, clones or fast-forwards the checkout, execs `install.sh setup` on `/dev/tty` (see "Setup") |
| `installer/setup.sh` | The setup wizard's stages, the release-tag warm-up and `render_plan` |
| `installer/ui.sh` | Prompt primitives (gum or plain numbered prompts) and `ensure_gum` |
| `installer/registry.sh` | Ordered component registry, dependency closure, handler validation, the tool-artifact table, and which steps a full upgrade re-runs |
| `installer/state.sh` | Saved profiles, schema migration, state signatures, locking and cleanup |
| `installer/packages.sh` | Platform bootstrap, package maps, package-manager operations and the extra repositories they need (RPM Fusion, GitHub CLI's apt repository) |
| `installer/tools.sh` | Tool installs (Homebrew formulae, age-gated GitHub releases with digest and attestation checks, Corepack from npm), release checkouts and the runtimes: Node LTS activation, uv's CPython, rbenv's Ruby |
| `installer/config.sh` | Managed shell blocks, symlink-aware rewrites and default-shell changes |
| `installer/credentials.sh` | Local key preparation, read-only GitHub checks and manual-action pauses |
| `installer/verification.sh` | Component postconditions |
| `installer/signatures.sh` | Inputs that invalidate each component's recorded state |
| `installer/sources.sh` | Upstream repositories, each Git source's follow mode and the Linux release asset names, plus the two pinned downloads (Homebrew's installer, rpatool) |
| `installer/plan.sh` | Disclosure records beyond the selection, the preflight before any change, and the inventory |

Add a component to the registry and supply its install, verification and
signature handlers. Registry validation rejects missing handlers or unknown
dependencies. A tool the installer puts on PATH itself is one row in
`artifact_registry` (owning component, source prefix, archive kind,
executables, expected `--version` line, Homebrew formula) plus its
`<PREFIX>_REPOSITORY` and `<PREFIX>_LINUX_<AARCH64|X64>_ASSET` values in
`sources.sh`. On macOS it installs as the formula; on Linux as the newest
GitHub release at least the minimum release age old (see "Release age"
below), checked against the SHA-256 digest GitHub publishes for the asset
and, when gh is logged in, the project's attestation. A `file` row is the exception: a pinned `<PREFIX>_URL`/`_SHA256`. Its
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
inspection stream uses `meta<TAB>schema<TAB>1`. Saved profiles use schema 4 and
include `node-policy<TAB>current-lts` and the `current-lts` channel. Schema-1,
schema-2 (`preserve-compatible`) and schema-3 profiles remain readable and are
migrated by an approved apply/reconcile. Inspection and dry-run must not write
the migration. Schema 4 (2026-11) retired components: read_profile's
`migrate_profile_selection` maps an older selection (`pyenv` to `cpython`,
`yarn` and `pnpm` to `corepack`, `plugins` to `plugins` plus `starship`) and
drops the `languages` package group, whose installed packages stay (inspect:
`migration package-group languages`). A retired name on the command line, or
in a schema-4 profile, stops the run with its replacement
(`reject_retired_selection`). `migrate_local_state` drops pyenv's state rows;
the corepack step drops yarn's and pnpm's once it has removed what they
installed (on macOS it reads them to know the Homebrew formulae were the
profile's). Keys added since schema 3 are optional and need no schema bump:
the reader takes their absence as the old behaviour (`version-managers`
install, `upgrade-casks` no, `release-age` 7, no `gpg-generated` key).

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
| `warning` | 3 | name, message | `unsupported-platform` (an Intel Mac or macOS before 15: Homebrew Tier 2/3), `no-release-build` (upstream publishes no Linux build for this CPU), `node-version` (the given `--node-version` is not what the plan resolves now), `release-age-homebrew` (macOS: the selected Homebrew formulae install at Homebrew's current version, not age-gated), `release-age-npm` (npm's latest Corepack, and the pnpm and Yarn it installs, not age-gated), `fallback-prompt` (zsh-config without the starship component), `zoxide-outdated` (Debian/Ubuntu dev-tools whose apt zoxide predates 0.8) |
| `profile` | 3 | `root`, path | Authoritative local checkout |
| `policy` | 3 | `node`, `full-upgrade`, `selection` or `release-age`, value | Node selection policy; `yes`/`no` host upgrade; `saved` when `inspect --saved` read the selection from the saved profile; the minimum release age in days |
| `channel` | 3 | source, channel | Moving sources: `packages`, `node`, `ai-cli-updates` |
| `migration` | 4 | `profile-schema`, old schema, `4`; `package-group`, `languages`, what happens; `legacy-loader` / `legacy-environment`, file path, managed marker; or `local-bin` / `npm-prefix` / `homebrew-formula` / `git-checkout`, path, what happens | Pending profile migration (and the retired `languages` group it drops); a legacy unmarked loader (`.zshrc`) or zshenv snippet (`.zshenv`) that `zsh-config` and `remove-blocks` remove; or an older layout: a macOS `~/.local/bin` copy removed once Homebrew's formula is in place, the retired yarn/pnpm components' npm package in `~/.local/npm` (`npm-prefix`) or, on macOS, Homebrew formula the profile installed (`homebrew-formula`), which the corepack step removes, or a checkout on its default branch (the 2026-10 layout) that moves to its release, detached, naming the tag or commit its refs give as of its last fetch |
| `group` | 4 | category, name, status | Selected, implied or internal group |
| `package` | 3 | OS family, name | Exact OS package member |
| `action` | 3 | step, description | Planned effect of a step or bootstrap |
| `artifact` | 5 | source kind, name, source, revision | Where a tool comes from. `formula`: Homebrew formula, `latest`; `release`: `github.com/<repo>` and the asset name (a Nerd Font's `<Font>.tar.xz` is checked against its release's `SHA-256.txt`); `npm`: registry package (Corepack), `latest`; `corepack`: what Corepack installs for use outside projects, as a package spec (`pnpm@latest`, `yarn@stable`) and its tag; `git`: repository and follow mode (`tag`, `commit` or `tag-now`, see "Release age"); `direct`: pinned URL and SHA-256 |
| `release` | 5 | name, tag, published_at, `digest` or `attestation` | The GitHub release a `release` artifact resolves to now (Linux tools, and the Nerd Font): the newest that is not a draft or prerelease, has a plain version tag and was published at least the minimum release age ago. `attestation` when gh is logged in and the project publishes an attestation for the asset, otherwise GitHub's SHA-256 digest (a Nerd Font: always `digest`, from `SHA-256.txt`). `unresolved`, `-`, `resolve-during-apply` when GitHub cannot be read or the release is unusable |
| `external` | 3 | service, description or URL | External service the plan contacts: `node-lts-index`, `python-release-dates` (python.org's release API, for a new Python line's age), `ruby-sources` (what `rbenv install` downloads), the Homebrew mirror, GitHub |
| `file` | 3 | name, path | File the plan reads or writes; `zshrc`, `zshenv` and (macOS) `zprofile` give the resolved zsh startup files |
| `global` | 3 | `git`, keys | Global Git settings the plan configures |
| `irreversible` | 3 | effect, explanation | Effect that cannot be automatically undone: `host-upgrade` (package upgrades), `login-shell` (chsh) |
| `privileged` | 3 | action, command or description | An action run as root (through sudo, or directly when root): `homebrew-bootstrap`, `bootstrap`, `package-manager`, `repository`, `dnf-swap`, `pacman-sync`, `credential-packages`, `etc-shells`, `login-shell`, `cask-upgrade` (macOS `--upgrade-casks`: some cask installers ask for sudo) |
| `behaviour` | 3 | name, description | A side effect beyond the listed files and packages: `compat-symlinks` (apt fd/bat links), `gnu-tools` (GNU tools ahead of BSD on macOS), `git-identity` (global name/email writes), `github-cli-apt` (Debian/Ubuntu dev-tools take gh from GitHub CLI's apt repository), `brew-mirror`, `login-shell` (macOS uses `/bin/zsh`), `cask-upgrade` (the full upgrade also runs `brew upgrade --cask`; only with `--upgrade-casks`) |
| `conflict` | 4 | component, path, reason | An existing installation in the way of `rbenv`: `not-a-git-checkout`, `unexpected-origin`, `local-changes` (apply stops unless `--skip-existing-version-managers`), or `homebrew-install` (informational) |
| `existing` | 4 | name, path, effect | A shell framework or version manager the profile coexists with: `oh-my-zsh`, `powerlevel10k`, `pyenv` (no longer installed or updated; its shims come before uv's python3), `nvm`, `conda`, `asdf`, `mise` |
| `shadow` | 4 | executable, other copy, profile copy | Linux: a Homebrew copy of a tool that the profile's `~/.local/bin` copy will shadow |
| `runtime` | 4 | `node`, `python` or `ruby`, version, origin | Node: `current-lts` (what fnm will install); Python (the line, such as `3.14`) and Ruby (the version): `latest-stable` (the newest stable line at least the minimum release age old), or `release-date-unknown` (the newest line's age could not be read, so the previous line); any: `installed` (a working runtime kept without a full upgrade), or `unresolved`/`resolve-during-apply` (Python before uv is installed, Ruby before ruby-build is) |
| `postcondition` | 3 | component, status | Current `verified` or `needed` result; `skipped` when `--skip-existing-version-managers` keeps an existing rbenv |
| `manual-action` | 4 | action, public path, destination | Manual intervention required; process exits 3 |
| `item` | 5 | kind, name, path, `present`/`absent` | `inventory --tsv` only: something the installer creates or manages |

A runtime preview may report `unresolved` / `resolve-during-apply`.

Manual-action names cover registration, login, email-read scope,
`github-key-scope` (gh's token cannot list SSH/GPG keys; the destination is
the exact `gh auth refresh -h github.com -s read:public_key,read:gpg_key`
command, with the scopes the selected keys need), key selection,
SSH identity configuration, `run-in-terminal` (the destination is the exact
command to run in a terminal; see "Apply flow" below; never in setup), `set-login-shell`
(chsh is missing) and `install-windows-font` (WSL). An empty public-path field is valid for actions
such as login. Only public artifacts are referenced: never emit private key
contents, tokens or passphrases. On registration pauses, save the explicit
reference first and retain the public artifact after EXIT cleanup. Reconciliation
must never generate a replacement. Pending initial generation resumes the
originally approved apply; a retried `--gpg generate` reuses the key an
earlier run generated (the profile's optional `gpg-generated` row, carried
over apply's profile rewrite) while its secret key is still in the keyring; API/network failures must not be interpreted as
missing registration. Enabling global GPG commit signing follows successful
local signing and confirmed GitHub registration.

## Apply flow

`main` runs, in order: argument parsing; `remove-blocks` and `inventory`
(dispatched before platform detection, so they work anywhere); `setup` (see
"Setup" below); the saved profile for `reconcile` and `inspect --saved`;
`prepare_selection` (validation, dependency closure, `detect_os` and the
OS-specific refusals); `inspect` stops here. Apply and reconcile need `--yes`
and then run `apply_selection`: warn about an unsupported platform and run
`preflight`; only after it take the lock, migrate local state, write the
profile, apply the Homebrew mirror, bootstrap, resolve Node, run each
component, compile the Zsh sources, and last provision credentials.
`finish_manual_actions` prints every queued `manual-action` and exits 3; a
credential pause calls it at once.

`install.sh` with no arguments (`bare_invocation`) is `setup` when stdin is a
terminal and `/dev/tty` opens. Without a terminal, when `CODESPACES`,
`REMOTE_CONTAINERS` or `DEVCONTAINER` is set (Codespaces and dev containers
run a dotfiles repository's executable `install.sh` that way), it is
`apply --yes` with the lean profile: `LEAN_STEPS` (`zsh-config,plugins,starship`),
no package groups beyond what they imply, no full upgrade, fonts `no`,
default shell `no`, SSH and GPG `skip`. Anywhere else it prints the usage and
exits 2. `install.sh` is committed with mode 100755.

The Homebrew installer runs as `NONINTERACTIVE=1 /bin/bash install.sh`:
the plan was approved already and preflight validated sudo, which the
installer then uses with `sudo -n`. Preflight sets `SUDO_PLANNED` when the
plan runs anything through sudo; `run_step` then renews a cached sudo login
(`sudo -n -v`, never a prompt) before each step, and around the Ruby compile
`refresh_sudo` (`sudo -n -v`, else `sudo -v` at a terminal) and a background
keepalive (`sudo_keepalive_start`/`_stop`, killed by `cleanup` too) keep it
from expiring before chsh or the credential packages.

`preflight` (installer/plan.sh) changes nothing. It stops on a blocking
rbenv conflict (unless `--skip-existing-version-managers`), checks
`--node-version` against a live resolution (exit 2 when they differ), and
collects what the run needs from the user: when stdin is not a terminal, a
passphrase prompt or a sudo password (chsh runs as root, so it counts here)
(`privileged_plan` is not empty and `sudo -n true` fails) ends the run with
`manual-action run-in-terminal` carrying the exact command line, exit 3, before
the lock exists. With a terminal, `sudo -v` asks once up front. Dry runs never
call sudo; they report what would stop. Last, it picks the Nerd Fonts release
(once: the archive later comes from the same tag), downloads that release's
checksum list and rejects an unknown font name. Tests stub
`stdin_is_terminal`, `sudo` and `privileged_plan`.

`main` installs an ERR trap (`on_unexpected_error`; `set -E` carries it into
functions). A command that fails where `set -e` would stop the run, outside
`die` and the deliberate exits, prints `ERROR: unexpected failure (status N)
at <file>:<line>` and exits with that status, except that 2 and 3 become 1:
they are contract statuses (plan changed, manual action). The trap does
nothing inside subshells; their status reaches the main shell. A helper that
must return a status is called with `||` (as `github_release_pick` is,
returning 4 when GitHub is unreachable, 5 when it refuses: 403/429, the
anonymous rate limit, and 7 when no recent release is old enough), so the trap
never sees it. Code inside such a call runs without `set -e`: check each
status explicitly.

A component that needs the user (a missing chsh) calls `queue_manual_action`
and sets `STEP_AWAITS_MANUAL_ACTION`: `run_step` then leaves it unrecorded and
the run continues.

## Setup

`setup_main` (install.sh) is the interactive front end. It requires a
terminal: `UI_TTY` (default `/dev/tty`; tests point it at a file of answers)
must open, and when it is `/dev/tty` and stdin is not a terminal, stdin is
moved to it, so sudo, ssh-keygen, gpg and gh can prompt and preflight's
`run-in-terminal` stop never fires inside setup (preflight dies instead,
which cannot happen at a terminal). Then:

1. `detect_os`, `ui_init` (installer/ui.sh): fd 7 reads `UI_TTY`; gum is
   used when fd 7 and stderr are terminals, `TERM` is not `dumb`, `--plain`
   (`UI_PLAIN=1`) is not given and `ensure_gum` finds one: gum on PATH, else
   on macOS `brew install gum` (not in a dry run), else
   `github_release_pick charmbracelet/gum 'gum_{version}_{os}_{arch}.tar.gz'`
   installed by `install_archive_binary` into a tracked temporary directory
   (in a subshell with `TMPDIR` there, so a failure falls back to the plain
   prompts; downloaded in a dry run too, since it changes nothing on the
   host).
2. `setup_wizard` (installer/setup.sh): `setup_mode` (Recommended,
   Customize, or the saved choices through `read_profile` when the profile
   exists), then for Customize `setup_components`, `setup_package_groups`
   (heroku on macOS only), `setup_fonts`, `setup_full_upgrade`,
   `setup_casks` (macOS, with a full upgrade), `setup_default_shell`,
   `setup_release_age`; for all but the saved choices `setup_ssh` and
   `setup_gpg`; then `setup_git_identity` (GPG only, missing values only) and
   `setup_conflicts` (a blocking `version_manager_conflicts rbenv` becomes
   `SKIP_EXISTING_VERSION_MANAGERS=1` or a stop). Each stage only sets the
   globals the matching apply option sets; validation stays
   `validate_options`'s.
3. `prepare_selection`, `INTERACTIVE_MANUAL=1`, `warm_release_picks` (each
   selected release artifact's tag is picked in this shell, so inspect's
   subshells and apply see the same one), `inspect_tsv` into a temporary
   file in this shell (globals such as the resolved Node and runtime lines
   do not survive `$(...)`), `render_plan` on it (grouped by record type,
   every type but `meta`, a release tool's `artifact` and `release` records
   joined on one line, ending with each `postcondition` as to do / done /
   skipped and the counts), and one `ui_confirm`.
4. `apply_selection` in the same process, with `COMMAND=setup` (it writes
   the profile as apply does).

The UI primitives (`ui_choose`, `ui_multi`, `ui_confirm`, `ui_input`, plus
`ui_header`, `ui_section`, `ui_note`) draw on stderr and return in
`UI_REPLY`/`UI_INDEX`, never through `$(...)`. The plain prompts re-ask on a
bad answer; end of input (or cancelling a gum prompt) exits 130. Option
labels contain no commas (gum's `--selected` splits on them).

Manual actions: with `INTERACTIVE_MANUAL=1`, `credential_manual_action` calls
`await_manual_action`, which shows the explanation (with its "then rerun"
ending pointed at the choice below, `waiting_explanation`) and offers "Run it for
me now" (when the caller set `MANUAL_ACTION_OFFER`: `gh auth login
--hostname github.com --scopes <what the checks need>`, or the
`gh auth refresh` for a missing scope), "Done: check again" and "Stop here".
The callers loop (`until <check>; do credential_manual_action ...; done`):
`ensure_github_auth`, `github_key_list`, `github_email_is_verified`, and in
`provision_ssh`/`provision_gpg` registration and the SSH probes. Stopping
falls back to the queued action and exit 3. In setup,
`finish_manual_actions` prints a checklist instead of TSV records, and at
the end of a run (`finish_manual_actions final`) lists the component actions
(chsh missing, the WSL font) and returns 0. Outside setup
(`INTERACTIVE_MANUAL=0`) nothing waits.

`bootstrap.sh` runs every statement inside `main`, called on its last line,
so a truncated download runs nothing (a test runs each truncation). `bs_os`
picks macos, apt, fedora or arch; `bs_install_git` (only when `git` does not
run; on macOS when `xcode-select -p` fails) runs `xcode-select --install`
and polls (`BS_POLL_SECONDS`, `BS_POLL_LIMIT`), or installs git and
ca-certificates through sudo (Arch: `pacman -Syu --needed`). `bs_checkout`
clones `https://github.com/foxhatleo/leos-profiles.git` into
`${LEOS_PROFILES_HOME:-~/.leos-profiles}`, or for an existing directory
requires a Git checkout whose raw `remote.origin.url` names this repository
(HTTPS or SSH), a clean `git status --porcelain` and a successful
`git pull --ff-only`. `bs_start_setup` execs `bash <dir>/install.sh setup
"$@" </dev/tty`. Tests set `LEOS_BOOTSTRAP_LIB_ONLY=1` to source it.

## Zsh startup files

The `zsh-config` step owns up to three managed blocks, each between
`# >>> leos-profiles <marker> >>>` and `# <<< leos-profiles <marker> <<<`:

| Marker | File | Content |
| --- | --- | --- |
| `loader` | `.zshrc` | `LEOS_PROFILES_HOME` default and the interactive-only `source …/zsh/start.zsh` |
| `environment` | `.zshenv` | `skip_global_compinit=1`, and `~/.local/bin`, `~/.local/npm/bin` and fnm's default-alias bin (`${FNM_DIR:-${XDG_DATA_HOME:-~/.local/share}/fnm}/aliases/default/bin`, or macOS's `~/Library/Application Support/fnm/...` when that is fnm's directory; only when it exists), in that order, in front of PATH when missing (never moved, so a child shell keeps its parent's shims first; not for root with a foreign HOME). Non-interactive shells get Node, and with it Corepack's shims, from the alias |
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

## Runtime and package invariants

Node, Python and Ruby are the newest line on every OS, from fnm, uv and rbenv;
no package group installs a system runtime (the `languages` group is gone).
Each resolver (`resolve_node_version`, `resolve_python_line`,
`resolve_ruby_version` in installer/tools.sh) holds a new major/minor line
back until it is `MIN_RELEASE_AGE` days old and takes its newest patch at once:

- Node: `node_lts_pick` reads `index.tab` (newest first) and takes the newest
  release of the newest LTS major whose first LTS-codenamed row is dated on
  or before the cutoff. `fnm list-remote --lts`, the fallback when the index
  cannot be read, has no dates and is not gated.
- Python: `uv python list --only-downloads --output-format json`, CPython's
  default variant, plain x.y.z versions (`uv_cpython_versions`,
  `stable_version_lines`); the newest line's x.y.0 date comes from python.org
  (`PYTHON_RELEASE_API`). Without a date the previous line is used, with a
  warning, unless `~/.local/bin/python3` is already on the newest line
  (`pick_runtime_line` never moves it back for want of a date). The cpython
  step runs `uv python install --default <x.y>` with `UV_PYTHON_BIN_DIR` set to
  `~/.local/bin` (`uv_python` repeats it with `--preview` when uv asks for it,
  as uv before 0.8 did), and on a full upgrade `uv python upgrade <x.y>`.
  `verify_cpython` requires `~/.local/bin/python3` to resolve into
  `uv python dir` and run.
- Ruby: ruby-build follows its newest tag (`tag-now`), so its definitions are
  current; the newest line's age is when its `share/ruby-build/x.y.0` was
  added (`git log --diff-filter=A`, `ruby_line_added`). `install_ruby` runs
  `rbenv install --skip-existing` and `rbenv global`. A failed compile warns
  and sets `RUBY_RESULT=ruby-failed:<v>`, which `mark_done` records in the
  state file's diagnostic column; `verify_rbenv` accepts it (the newest
  recorded outcome, `ruby_compile_failed`), so a reconcile does not compile
  again, and a full upgrade (rbenv follows upstream) retries.

Corepack depends on fnm. Node policy is `current-lts`: installing fnm
resolves the LTS as above, installs it and makes it the default; another Node
on PATH is not adopted. Verification only requires a working runtime, so a
newer line alone does not make a step look undone: a full upgrade re-runs the
step and moves it, while a repair leaves it. The state file's diagnostic
column records the Node version installed and the Ruby outcome. The corepack
step installs npm's Corepack into `~/.local/npm` on every OS (Homebrew's
formula would pull in Homebrew's node), runs `corepack enable
--install-directory ~/.local/npm/bin` and `corepack install --global
pnpm@latest yarn@stable` (with `COREPACK_ENABLE_DOWNLOAD_PROMPT=0`), and first
removes what the retired yarn/pnpm steps left: their npm packages
(`legacy_npm_copy_present` never mistakes Corepack's own shims for one) and, on
macOS, the Homebrew formulae their state rows show the profile installed.
The step then runs each shim once with the network allowed (current pnpm
releases fetch their native binary on first use); `verify_corepack` runs each
with `COREPACK_ENABLE_NETWORK=0`, so inspect downloads nothing. Both run from
`/`, so no project's `packageManager` field picks another version. Run npm and Corepack commands and verification with
explicit `fnm exec --using=default` so a non-interactive installer does not
accidentally use an older system Node.

`--no-full-upgrade` requests only missing selected OS packages, while normal
package-manager dependency resolution can still upgrade dependencies. Keep
this distinction in planning output and tests. Full upgrades stay within the
configured OS release/repositories; they do not run distribution-upgrade tools.

## Local regression checks

Run these from the repository root:

```bash
for file in install.sh bootstrap.sh installer/*.sh tests/*.sh; do bash -n "$file" || exit; done
for file in zsh/*.zsh zsh/path/*.zsh tests/*.zsh; do zsh -n "$file" || exit; done
shellcheck -s bash -x install.sh bootstrap.sh installer/*.sh tests/*.sh
bash tests/install-test.sh
/bin/bash tests/install-test.sh  # macOS: the system Bash 3.2 a fresh Mac runs
bash tests/apply-dryrun-test.sh
bash tests/readonly-test.sh
bash tests/node-test.sh
bash tests/credentials-test.sh
bash tests/migration-test.sh
zsh tests/profile-test.zsh
zsh tests/runtime-cache-test.zsh
/usr/bin/python3 -I tests/rmdsstore_test.py  # macOS; elsewhere python3
```

These suites use fixtures and are safe on a provisioned workstation: they
redirect HOME, XDG state and Git configuration, and the CLI-level tests
(`apply-dryrun-test.sh`, `readonly-test.sh`) run a temporary copy of the public
checkout so your `local/` state is never read or written. `install-test.sh`
runs every test in its own subshell, reports each failing test by name and
removes the temporary files the code under test tracked; it unsets proxy, XDG,
tool-root, Homebrew and Git variables first, so its exact command-line
assertions do not depend on the caller's environment.
`migration-test.sh` runs the destructive macOS legacy-copy migrations in a
fixture HOME and checks that they remove nothing else. `readonly-test.sh`
snapshots the fixture HOME and checkout around `inspect`, `apply --dry-run`,
`reconcile --dry-run` and `setup --dry-run` through the real CLI, with package
managers and network clients replaced by PATH fakes, and checks every inspect
record against the table above. The setup tests (in `install-test.sh` and
both CLI suites) answer the plain prompts from a file named by `UI_TTY` with
`UI_PLAIN=1`; the bootstrap tests run the real git against a local upstream
(`url.<path>.insteadOf` in a fixture `GIT_CONFIG_GLOBAL`). `profile-test.zsh` runs each Zsh block through `run_block`, which
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
shfmt -d -i 2 -ci install.sh bootstrap.sh installer/*.sh tests/*.sh  # informational only
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

The release check picks every Linux release asset for both CPUs (from any
host) with the default minimum release age, verifies the two pinned digests
and the picked Nerd Fonts archive, and then, on Linux, installs and runs each
picked release (a second install must find it current) plus npm's Corepack
with its pnpm and Yarn on the current LTS; on macOS it checks that each Homebrew formula
exists. Plugin checks check out each plugin's release and load the combined
real Zsh plugin integration. CI also checks the Starship TOML and that the
README's bootstrap one-liner names `bootstrap.sh` on master.
None of these alone substitutes for actual package installation.

## CI layout

Two workflows split fast feedback from real provisioning:

- `.github/workflows/ci.yml` runs on every push to `master`, every pull request
  and on demand: Zsh syntax and profile tests, lint (ShellCheck, actionlint,
  zizmor, ruff; shfmt informational), installer/credential/Node/cache/util/
  migration suites, package-map availability on macOS, apt and containers, the
  dry-run smoke test and the read-only test. The macOS jobs run the Bash suites
  under `/bin/bash` (3.2) and `rmdsstore_test.py` under `/usr/bin/python3 -I`,
  the interpreters the installer and `rmdsstore` actually use there. The final
  "All gating checks" job needs every "(gating)" job and fails unless all of
  them succeeded; the branch ruleset requires only that check, so renaming a
  job or a matrix entry never orphans a required check. Add each new gating
  job to its `needs:`. The gate never installs or clones what upstream
  published today: `release-artifacts-test.sh` and `plugins-test.sh` run in a
  non-blocking "(informational)" job and weekly in provision.yml, so an
  upstream release cannot block an unrelated pull request (the gate keeps
  their fixture-based counterparts in `install-test.sh`). The workflow has no
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
  Linux containers keep the full upgrade. On the same triggers it runs the
  live upstream checks (latest releases and plugin default branches) and
  reports, without failing, where a CI tool pin (ShellCheck, actionlint,
  shfmt, zizmor, ruff) is behind its latest release; Dependabot covers only
  the actions. A failed scheduled run opens or updates one tracking issue.
  These jobs are not required checks.
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
Debian 12/13, and Fedora 44/45 run on x86_64 and arm64; Arch runs on x86_64.
The containers create a non-root test user and exercise actual package managers.
macOS CI uses fresh HOME directories on hosted Apple-silicon macOS 15 and 26
runners (Homebrew Tier 1; macOS 14 and Intel Macs are unsupported). Those images already have developer tools and Homebrew: the
matrix does not establish factory-fresh macOS bootstrap coverage.

Scenarios exercise minimal Zsh setup, corepack-only dependency resolution
with pnpm and Yarn execution, recommended provisioning (then `node`, `pnpm`,
`yarn` and `python3` in a non-interactive `zsh -c`, and Ruby in an interactive
shell), repeat reconciliation, a
full-upgrade reconcile that re-runs the tools and finds them current (Linux),
repair (of bun, Starship, the `.zshenv` managed block, a plugin checkout left
on its default branch as the 2026-10 installs did, and the font) and the refusal to discard
a locally edited plugin.
They skip credentials, disable login-shell changes, and explicitly install
fonts. Unit and credential fixture tests cover the excluded interactive flows;
manual end-to-end GitHub registration remains outside automated CI.

The configured matrix is a coverage target. Claim a particular platform passed
only with that run's evidence, and report failures or unexecuted jobs separately.
See [the provisioning workflow](../.github/workflows/provision.yml) for exact
runner labels and triggers.

## Release age

Nothing is pinned to a version, but nothing installs the moment upstream
publishes it either. `--min-release-age <days>` (0 to 365, default 7; apply
and inspect, saved as the profile's `release-age` row for reconcile) holds
GitHub releases and Git checkouts back until they have been public that long,
so a compromised or broken release has time to be noticed and pulled.
`release_age_cutoff` computes the cutoff once per run, as epoch seconds and as
an ISO-8601 UTC string that compares with GitHub's `published_at` as text
(Bash 3.2 has no date arithmetic; `date` converts with GNU `-d @N` or BSD
`-r N`).

- **GitHub releases** (`github_release_pick <repo> <asset|template>`): reads
  `releases?per_page=30`, skips drafts, prereleases and tags that are not a
  plain version (`bun-v1.3.2` and `0.9.1` are; `v1.0.0-rc1` and `canary` are
  not), takes the newest published at or before the cutoff, then reads
  `releases/tags/<tag>` for the asset's URL and digest. `{version}`, `{os}`
  (`Linux`, `Darwin`) and `{arch}` (`x86_64`, `arm64`) in the asset name are
  filled in. Results are cached per repository (and asset) in globals for the
  run, so call it in the current shell, with `||`. API requests send
  `GITHUB_TOKEN`, or gh's token when gh is logged in, on curl's stdin.
- **Attestations**: after the digest check, when gh is logged in,
  `release_attestation_check` asks GitHub for attestations of the asset's
  digest. None (404) leaves the digest check alone; otherwise
  `gh attestation verify --repo <repo>` must pass, and any other answer stops
  the install.
- **Git checkouts** (`follow_release_checkout <PREFIX> <dir> <label>`) end
  detached, by `<PREFIX>_FOLLOW` in `sources.sh`: `tag` (the newest tag
  matching `^v?[0-9]+(\.[0-9]+)*$` whose creator date is at or before the
  cutoff: rbenv, zsh-completions, fzf-tab), `commit`
  (`rev-list -1 --before=<cutoff> origin/HEAD`: zsh-autosuggestions and
  zsh-syntax-highlighting, whose last tags are from 2024 and 2023) or
  `tag-now` (the newest stable tag, no delay: ruby-build, so a Ruby security
  release is installable at once; a new Ruby line still waits, see "Runtime
  and package invariants"). A checkout may move backwards. Before
  fetching, it refuses uncommitted changes and a checked-out commit that no
  remote-tracking branch or tag contains (work made locally); a commit upstream
  later force-pushed away is not local work, and the step says upstream
  rewrote its history and moves on. The fetch prunes tags, so a tag upstream
  deleted is not picked.
- **Runtimes**: a new Node LTS major, Python minor or Ruby minor line waits
  the same number of days; their patch releases do not (see "Runtime and
  package invariants").
- **Not gated**: Homebrew formulae and OS packages (their package managers'
  current versions; inspect warns about formulae), and npm's Corepack with
  the pnpm and Yarn it installs. The bootstrap and raw URLs on `master` are
  not releases.

Signatures never contain the age or a tag (`release` for Git sources), so a
new upstream release, or a different `--min-release-age`, re-runs nothing;
a full upgrade moves the tools forward.

## Upstream sources

Tools are not pinned, so there is no routine dependency bump. What needs care:

1. A renamed release asset, a dropped CPU build or a project that moves breaks
   installs. `tests/release-artifacts-test.sh` resolves every asset for both
   Linux CPUs in CI's informational job and the weekly provisioning run; fix
   `installer/sources.sh` when it fails.
2. GitHub must publish a SHA-256 digest for the asset (it does for every asset
   uploaded since mid-2025); the installer refuses an asset without one.
3. Keep the version line in `artifact_registry` matching what the tool prints;
   verification accepts any version but checks that shape.
4. The pinned downloads change deliberately: update the URL and SHA-256
   together in `installer/sources.sh` (Homebrew's installer at a reviewed
   commit, re-pinned when a new macOS ships: its `MACOS_NEWEST_UNSUPPORTED`
   must be above the newest macOS; rpatool at its archived GitHub
   repository's final commit, which codeberg.org/shiz/rpatool, where it
   moved, also carries).
   GitHub CLI's apt keyring (`GH_APT_KEYRING_SHA256` in
   `installer/packages.sh`) follows the SHA-256 listed in cli/cli's
   `docs/install_linux.md`; when GitHub rotates or re-signs its keys the
   live check fails, and the new digest must come from that page and the
   fingerprints from `gpg --show-keys` on the new file.
5. A Git source whose tags stop (or start) tracking its branch: change its
   `<PREFIX>_FOLLOW` in `installer/sources.sh`.
6. Behaviour changes upstream (a new major pnpm, a Node LTS, Python or Ruby
   line that a tool does not support yet) reach users on their next full
   upgrade, a week after the line's first release. Run the real
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
`_ZO_ECHO` and `_ZO_RESOLVE_SYMLINKS`). After a TAB, the line ends with
`stat=` and the device, inode, size and mtime (`zstat`, no fork) of the
launcher and of any implementation file the caller names in
`__leos_init_deps` (rbenv's and pyenv's `libexec/*-init`). The file name is the
`%XX`-encoded key and a 32-bit FNV-1a digest of the identity without the stat
part, computed in-process, so an upgraded launcher replaces its entry in place;
the whole line, read with `read` (no fork), decides whether an entry is used.
A generator that exits non-zero or prints nothing leaves a `.failed` marker
with the same line: the first shell reports it (status 1 from
`leos-source-cached`), later ones skip it quietly (status 2) until the
launcher changes. Bump the key when
a filter's behaviour changes. The cache checks ownership, write permissions and
symlinks before executing persisted scripts or compiled files, and creates
private directories/files. `__leos_cache_dir` validates every ancestor once per
shell and memoizes the result (success or failure) keyed on the cache root and
EUID; repeat calls lstat the root and the two profile-owned levels and validate
in full again if their owner, mode or inode changed. Tests that change
permissions mid-shell call `__leos_cache_forget`. A warm cache hit costs about
0.4 ms, against 3 to 6 ms for running the cached generators directly (zoxide,
direnv, Starship, fzf), so every generator stays cached. The launcher's stat,
compared for equality, controls freshness: dpkg and rpm keep build-time
mtimes, so a newer-than test misses upgrades. Use `leos-refresh-init-cache`
after updates to other implementation files; the package checkups do. It also recompiles the profile and plugin sources (`.zwc`), as the
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
