# Leo's Profiles

Leo's Profiles is a portable, Zsh-centered workstation setup for macOS and
Linux. The intended setup experience is AI-first: the AI inspects the machine,
presents controlled selection boxes, resolves dependencies, explains the whole
plan, gets approval, and delegates execution to the repository's deterministic
shell engine.

Recommended is intentionally broad. A first installation installs the full
default workstation selection and performs a full package-manager/host upgrade.
It can write shell configuration, install packages and tools, configure GitHub
credentials, and change the login shell. Optional rpatool (`bins`) is excluded;
SSH and GPG default to Skip; fonts and the Zsh default-shell policy are Auto.

## Start here

- **Claude Code:** give it [`QUICK-INSTALL.md`](./QUICK-INSTALL.md) in a
  session with its single-select/multi-select question-box UI.
- **Codex:** enter **Plan mode first**, then submit
  [`QUICK-INSTALL.md`](./QUICK-INSTALL.md). The question UI used by this setup
  is currently available there.

If the UI is unavailable, restart in the correct mode. The setup deliberately
does not fall back to a typed questionnaire, and users should not need to learn
installer flags.

The default installation directory is `~/.leos-profiles`. A new setup clones
the current GitHub default branch there and runs that checkout in place. The
local checkout is authoritative: local edits take effect immediately and the
installer does not enforce a particular release, commit, origin, owner, or
signature. The updater is stricter only about pulling: it requires a clean
branch checkout with a configured upstream, then uses `git pull --ff-only`.

### Why not chezmoi or GNU stow

The dotfile surface here is deliberately tiny — two managed blocks plus a
`STARSHIP_CONFIG` pointer — so templating and symlink-farm tools solve very
little of the actual problem. What `install.sh` mostly does is *machine
provisioning*: OS packages across four distribution families, SHA-256-pinned
bun/fnm/starship/yarn/pnpm artifacts, commit-pinned pyenv/rbenv/plugin clones,
SSH and GPG provisioning against the GitHub API, a sparse Nerd Fonts checkout,
and `chsh`. chezmoi covers that only through `run_once_` escape hatches, which
would leave the same amount of shell to maintain plus a second tool to learn.

The engine also exists to serve the AI-first flow: `inspect` emits typed TSV for
an agent to turn into selection boxes, and `apply` is a non-interactive executor
with per-step signatures and postcondition verification. That contract is the
product, not an accident of not knowing chezmoi exists.

The cost is honest: a bespoke idempotency/state/locking engine to keep correct,
which is why it carries a test suite and a per-OS CI matrix. If the dotfile
surface ever grows beyond a couple of managed blocks, revisit this.

## Selection model

Component groups are `bins`, `packages`, `pyenv`, `rbenv`, `bun`, `yarn`,
`pnpm`, `fnm`, `plugins`, `fonts`, `zsh-config`, and `default-shell`. Package
groups are `core-utils`, `shell`, `dev-tools`, `languages`, `media`, `network`,
and `system`. Internal `bootstrap`, `ssh`, and `gpg` groups make the remaining
mutations visible in the approved plan.

Groups are atomic: selecting one selects every member. rpatool, Bun, fnm, Yarn,
and pnpm imply the full `languages` package group; pyenv/rbenv imply `dev-tools`;
plugins, Zsh configuration, and default-shell setup imply `shell`. The AI shows
all selected and implied groups plus exact OS package membership before asking
for approval.

Recommended selects all current default component and package groups except
`bins`. Customize allows whole-group selection. The initial package pass keeps
the broad full-upgrade default, but the AI offers a no-full-upgrade choice.

## Deterministic engine and local state

`install.sh` derives the profile root only from its own physical directory.
It has three internal operations: a typed TSV inspection stream, an explicit
approved apply, and reconciliation from the saved local profile. It is not a
second wizard and never asks setup questions.

The entire ignored `local/` directory is machine-owned:

- `local/install-profile.tsv` records the normalized groups, upgrade/font/shell
  policies, Git identity, selected SSH path, GPG fingerprint, and moving-tool
  channel choices.
- `local/install-state.tsv` records verified step signatures, timestamps, and
  resolved moving versions such as Node LTS.
- `local/private.zsh` contains private machine overrides and loads after public
  commands but before the interactive layer.
- `local/flags/` stores GNU preference, Homebrew mirror, and optional-tool
  warning choices.

No passphrases, tokens, private keys, or exported secret-key material are
stored there. The directory uses mode 700 and files mode 600 as ordinary local
hygiene. On first use, legacy XDG installer state, `zsh/_private.zsh`, and the
old home-directory markers are migrated. Conflicting old/new values stop with
both paths for the AI to resolve.

Apply/reconcile uses an atomic `local/.install.lock`, secure temporary paths,
cleanup traps, atomic profile/state/config writes, and first-write managed-block
backups. A saved state row is only a resume hint: postconditions are checked,
so missing or corrupt tools are repaired.

## Installed channels and credentials

Direct tool archives and managed plugin/dependency checkouts are locked to
reviewed URLs, commits, and SHA-256 digests. Equivalent GitHub HTTPS/SSH origins
are accepted and normalized; dirty installer-managed dependency checkouts are
refused. This locked-direct-artifact promise intentionally excludes OS package
manager channels and Node.

Node is an explicit moving `current-lts` channel. Each initial apply or later
reconciliation resolves one exact current LTS version for that run, installs
and makes it default, records it, and verifies the actual default Node
executable/version. A later reconciliation advances to the then-current LTS.

SSH/GPG are AI-selected and default to Skip. Reuse requires an exact selected
key. Reconciliation checks the saved reference and automatically re-uploads
its public key if it is missing from the authenticated GitHub account; it never
generates a replacement. SSH derives public material from the private key,
matches GitHub host keys against GitHub's API metadata, and tests the explicit
key. GPG requires a verified GitHub email, verifies a real signed temporary
commit, and enables global **commit** signing only. It does not set or unset the
independent `tag.gpgsign` preference.

## Zsh runtime

The installer adds managed, replaceable blocks to `~/.zshrc` and `~/.zshenv`.
The first changed version is preserved beside the file as
`.leos-profiles.bak`; symlink targets are updated without replacing the link.
The profile remains relocatable via `LEOS_PROFILES_HOME`.

The `~/.zshrc` block is interactive-only and the `~/.zshenv` block is silent, so
`scp`, `rsync` and non-interactive `ssh` cannot break on startup output. The
trade-off: a **non-interactive** shell (`ssh host cmd`, cron, scripts) sees only
`~/.local/bin` and `~/.local/npm/bin` on PATH — no Homebrew, fnm, pyenv, rbenv or
Go — so remote one-liners that need those tools should use absolute paths or
start a login shell explicitly.

Starship and custom completions initialize before zsh-syntax-highlighting,
which is the final interactive plugin action.

Tool initialization that is deterministic — `brew shellenv`, `pyenv`/`rbenv`
`init`, `direnv hook`, `zoxide init`, `fzf --zsh`, `starship init`, and the
npm/pnpm/bun completion generators — is cached under
`${XDG_CACHE_HOME:-~/.cache}/leos-profiles/init`, keyed by the resolved binary
path and regenerated only when that binary changes, then `zcompile`d. This is
what keeps startup near 0.1s. Freshness is keyed on the *launcher* binary, so an
upgrade that rewrites a tool's init logic without touching that binary is not
detected automatically: run `leos-refresh-init-cache` (which `brew-checkup`
already does for you) or delete the directory. `fnm env`
is deliberately never cached because it mints a per-process
`FNM_MULTISHELL_PATH`. pyenv and rbenv are initialized with `--no-rehash` and
their shims are refreshed in the background at most once a day, so a console
script installed by `pip install`/`gem install` still appears without paying a
~240ms rehash on every shell. Yarn ships no completion generator, so it uses the
bundled zsh-completions `_yarn`.

PATH precedence is deliberate: version-manager shims come first, then
`~/.local/bin`, then Homebrew — so a stale binary in `~/.local/bin` cannot shadow
the Node/Python/Ruby a project selected. Locale fallback validates
`C.UTF-8`, then `en_US.UTF-8`, and otherwise uses `C`. fnm alone constructs its
runtime PATH. Set `LEOS_PLAIN_PROMPT=1` for the ASCII prompt,
`LEOS_DISABLE_ALIASES=1` to disable command aliases, or
`LEOS_WARN_OPTIONAL_TOOLS=1` for optional pyenv/rbenv warnings.

## Updating and maintenance

`upgrade-leos-profiles [--full-upgrade]` requires a branch with an upstream and
refuses tracked or non-ignored untracked checkout changes (`local/` remains
intentionally ignored). It fast-forwards from
that configured upstream—official or otherwise—then launches the newly pulled
`install.sh reconcile`. By default it installs missing selected packages and
repairs locked tools, plugins, configuration, fonts, Node LTS, and saved
credential references without a full host upgrade. `--full-upgrade` opts into
the saved broad package-manager upgrade behavior.

A full upgrade—here and in `bye`'s package checkups—upgrades installed packages
within the current OS release only (`apt-get upgrade`, `dnf upgrade`,
`pacman -Syu`, `brew upgrade`). It never performs a distribution/release
upgrade such as `do-release-upgrade` or `dnf system-upgrade`. Arch is rolling,
so `pacman -Syu` is inherently in-release.

`bye` remains the full maintenance-and-exit command. By default it runs package
maintenance, uses native `claude update`/`codex update` only for detected
installed AI CLIs, safely clears known history files, performs the intended
system-wide macOS metadata scan, restarts Finder/Dock/SystemUIServer, and exits
the current shell.

Options:

- `--keep-history`: preserve history.
- `--aggressive-history`: add legacy broad history/HSTS file and symlink
  matches; directories are never recursively removed.
- `--purge-recycle-bins`: explicitly allow `$RECYCLE.BIN` directory removal.
- `--shutdown-wsl`: shut down WSL after maintenance; normal WSL behavior exits
  only the current shell.
- `--non-interactive`: suppress supported package-manager prompts.
- `--no-exit`: perform maintenance without exiting. It conflicts with
  `--shutdown-wsl`.

`rmdsstore [--dry-run] [--purge-recycle-bins] [root ...]` deletes only named
metadata files by default. With no root it intentionally scans standard
system-wide macOS roots: the complete writable APFS data volume and every
mounted volume directly under `/Volumes`. It rejects symlink roots, does not
follow symlinks or implicitly cross nested mount boundaries, supports multiple
roots/dry-run, and reports failures. Cloud-storage directories are included.
Recycle-bin directory removal is opt-in.

`brew-china-enable` remains an explicitly confirmed USTC mirror option; its
flag now lives under `local/flags/`. `brew-china-disable` restores the official
Homebrew remote and environment.

## Support matrix (2026-07-10)

- macOS 14, 15, and 26 on currently supported Intel/Apple Silicon
  combinations, following [Homebrew's current support tiers](https://docs.brew.sh/Support-Tiers).
- Ubuntu 22.04, 24.04, and 26.04 LTS on x86_64 and arm64, aligned with
  [Canonical's standard-support lifecycle](https://ubuntu.com/about/release-cycle).
- Debian 12 and 13 on x86_64 and arm64, following Debian's
  [oldstable/stable release table](https://www.debian.org/releases/index).
- Fedora 43 and 44 on x86_64 and aarch64, following Fedora's approximately N
  and N-1 [release lifecycle](https://docs.fedoraproject.org/en-US/releases/).
- Arch Linux rolling on x86_64. Arch Linux ARM uses compatible assets on a
  best-effort basis without a gating promise.
- WSL is best-effort when its guest matches a supported Linux family.

CI gates Ubuntu 22.04/24.04/26.04 x64, Linux arm64 locked artifacts, Debian
12/13, Fedora 43/44, Arch latest x86_64, and available macOS ARM/Intel runner
combinations. A weekly schedule repeats dependency/package availability checks.
[GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
is the source for runner labels.

## Hosts list and removal

[`res/adblock-hosts`](./res/adblock-hosts) remains a vendored convenience list.
It is not automatically applied or updated and its original provenance is not
recorded; review it before use and keep a backup.

To stop loading the profile, run `bash install.sh remove-blocks` (add
`--dry-run` to preview). It deletes only the two managed blocks from `~/.zshrc`
and `~/.zshenv` and leaves the rest of those files untouched, which is safer than
restoring `*.leos-profiles.bak`: that backup is written only the first time a
block is installed, so any later edits are not in it. Then start a fresh shell,
and delete the profile directory if desired. Package uninstall remains
deliberately manual because packages may be shared and upgrades are not safely
reversible. Git identity, signing preferences, and GitHub keys are likewise left
for explicit review.

## Development

```bash
zsh -n zsh/*.zsh zsh/path/*.zsh
bash -n install.sh installer/lock.sh tests/*.sh
bash tests/install-test.sh
bash tests/apply-dryrun-test.sh
zsh tests/profile-test.zsh
python3 -m py_compile util/rmdsstore.py
python3 tests/rmdsstore_test.py
shellcheck -s bash -x install.sh installer/lock.sh tests/*.sh
bash tests/locked-plugins-test.sh
bash tests/locked-artifacts-test.sh
bash tests/package-map-availability.sh macos   # or apt | fedora | arch
```

CI also validates Starship TOML, package maps, locked artifacts, and the
runbook's fenced Bash snippets. Everything under `local/` must remain ignored.
The project is GPL-3.0; see [`LICENSE`](./LICENSE).
