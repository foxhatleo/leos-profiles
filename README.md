# Leo's Profiles

Leo's Profiles is a portable, Zsh-centered workstation setup for macOS and
Linux. The intended setup experience is AI-first: the AI inspects the machine,
presents controlled selection boxes, resolves dependencies, explains the whole
plan, gets approval, and delegates execution to the repository's deterministic
shell engine.

Recommended is intentionally broad. A first installation installs the full
default workstation selection and performs a full package-manager/host upgrade.
It can write shell configuration, install packages and tools, prepare credentials
for manual GitHub registration, and change the login shell. Optional rpatool
(`bins`) and the opt-in `python` and `heroku` package groups are excluded;
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

The dotfile surface here is deliberately tiny — two managed blocks (three on
macOS) plus a `STARSHIP_CONFIG` pointer — so templating and symlink-farm tools solve very
little of the actual problem. What `install.sh` mostly does is *machine
provisioning*: OS packages across four distribution families, SHA-256-pinned
bun/fnm/starship/uv/yarn/pnpm artifacts, commit-pinned pyenv/rbenv/plugin clones,
local SSH/GPG preparation and read-only GitHub verification, a verified Nerd
Fonts release archive, and `chsh`. chezmoi covers that only through `run_once_` escape hatches, which
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
`pnpm`, `fnm`, `uv`, `plugins`, `fonts`, `zsh-config`, and `default-shell`.
Package groups are `core-utils`, `shell`, `dev-tools`, `languages`, `python`,
`media`, `network`, `heroku`, and `system`. Internal `bootstrap`, `ssh`, and
`gpg` groups make the remaining mutations visible in the approved plan.

Groups are atomic: selecting one selects every member. A component implies a
package group only when it needs its members: rpatool (`bins`) implies the
small `python` group (python3 alone); pyenv/rbenv imply `dev-tools`, which
carries every build dependency ruby-build suggests for Ruby 3 (OpenSSL,
readline, zlib, libyaml, libffi) besides the GitHub CLI and jq; plugins, Zsh
configuration, and default-shell setup imply `shell`. Bun, fnm, Yarn, pnpm and
uv imply no OS runtimes: they are self-contained, and Yarn/pnpm run on fnm's
Node, so selecting them never installs a system Node, Python or Ruby that
non-interactive shells would then pick up. Yarn and pnpm imply fnm, which runs
before their installation. The AI shows all selected and implied groups plus
exact OS package membership before asking for approval.

`languages` (system node, python and ruby) stays its own group. `heroku` is
macOS-only and opt-in: the Heroku CLI comes from Heroku's third-party Homebrew
tap, which is added (and shown in the plan) only when this group is selected.

Recommended selects every component except `bins`, and every package group
except `python` and `heroku`. Customize allows whole-group selection. The initial package pass keeps
the broad full-upgrade default, but the AI offers a no-full-upgrade choice.
With `--no-full-upgrade`, only missing selected packages are requested from the
package manager. Dependency resolution can still install or upgrade dependencies;
this does not freeze the host package set.

## Deterministic engine and local state

`install.sh` derives the profile root only from its own physical directory.
It provides a typed TSV inspection stream, an explicit approved apply,
reconciliation from the saved local profile, and managed-block removal. It is not a
second wizard and never asks setup questions.

The entire ignored `local/` directory is machine-owned:

- `local/install-profile.tsv` records the normalized groups, upgrade/font/shell
  policies, Git identity, selected SSH path, GPG fingerprint, and moving-tool
  channel choices. Schema 2 records `node-policy=preserve-compatible`; an
  existing schema-1 profile migrates on approved apply/reconcile. Inspection
  reports the migration without writing it.
- `local/install-state.tsv` records verified step signatures, timestamps, and
  resolved moving versions such as Node LTS.
- `local/private.zsh` contains private machine overrides and loads after public
  commands but before the interactive layer; `local/private-interactive.zsh`
  loads last, after completion, plugins and the prompt, for `compdef` and ZLE
  overrides.
- `local/flags/` stores GNU preference, Homebrew mirror, and optional-tool
  warning choices.

The installer stores no passphrases, tokens, private keys, or exported
secret-key material there. User-managed `private.zsh` may contain secrets.
Public GPG exports awaiting manual registration are also kept under `local/`. The directory uses mode 700 and files mode 600 as ordinary local
hygiene. On first use, legacy XDG installer state, `zsh/_private.zsh`, and the
old home-directory markers are migrated. Conflicting old/new values stop with
both paths for the AI to resolve.

Apply/reconcile uses an atomic `local/.install.lock`, secure temporary paths,
cleanup traps, atomic profile/state/config writes, and first-write managed-block
backups. A saved state row is only a resume hint: postconditions are checked,
so missing or corrupt tools are repaired.

### What a plan discloses, and what apply checks first

Besides the selection, packages, artifacts and files, `inspect` reports every
action that runs as root (`privileged`: package-manager runs, Arch's
`pacman -Syu`, Fedora's ffmpeg swap, the `/etc/shells` edit, macOS
`sudo chsh`), side effects (`behaviour`: Debian's fd/bat links, GNU tools ahead
of BSD on macOS, global Git identity writes, the Homebrew mirror), effects that
cannot be undone automatically (`irreversible`), existing installations in the
way (`conflict`), shell setups the profile coexists with (`existing`), Homebrew
copies the pinned tools will shadow (`shadow`), and `warning`s such as an
unsupported Mac. `docs/development.md` lists every record type.

Before its first change, apply (and reconcile) checks what the run needs from
you. Run without a terminal (as an AI agent does), a plan that needs a sudo
password, a passphrase prompt or chsh's password prompt stops at once with a
`manual-action run-in-terminal` record that carries the exact command, exit
status 3, having changed nothing: run that command in your own terminal. With
passwordless sudo it proceeds. In a terminal, sudo asks once, up front. A
mistyped Nerd Font name is rejected at this point too, and an existing
`~/.pyenv` or `~/.rbenv` that is not the pinned Git checkout (for example
Homebrew's pyenv root) stops the run unless `--skip-existing-version-managers`
keeps it and skips that component; reconcile remembers the choice.

Pass the Node version `inspect` resolved with `--node-version vX.Y.Z`: apply
then installs exactly that one and stops with status 2 if it would now choose
another (a new LTS since the plan was approved). `inspect --saved` inspects
the saved profile's selection, as reconcile would run it, without writing
anything. Components install before credentials, so a first SSH or GPG
registration pause no longer holds back the rest; every manual action is
listed at the end, and the run exits 3.

## Installed channels and credentials

Direct tool archives and managed plugin/dependency checkouts are locked to
reviewed URLs, commits, and SHA-256 digests. Equivalent GitHub HTTPS/SSH origins
are accepted and normalized; dirty installer-managed dependency checkouts are
refused. This locked-direct-artifact promise intentionally excludes OS package
manager channels and Node.

uv and uvx install as one locked artifact into `~/.local/bin` (the static musl
builds on Linux, as for Starship), with their completions cached like the
other tools'. Nerd Fonts come from one font's archive in the pinned release,
checked against that release's `SHA-256.txt`, whose own digest is pinned; an
unknown font name is refused before anything is downloaded. Fonts go to
`~/Library/Fonts/NerdFonts` on macOS and
`${XDG_DATA_HOME:-~/.local/share}/fonts/NerdFonts` on Linux (then `fc-cache`).
After the run, set your terminal's font to that Nerd Font, or set
`LEOS_PLAIN_PROMPT=1` in `local/private.zsh` for the plain prompt. Under WSL
the terminal is a Windows program: install the font on Windows too (the run
ends with an `install-windows-font` manual action saying so).

Behind a proxy or a slow route: the proxy variables (`http_proxy`,
`https_proxy`, `no_proxy`, `ALL_PROXY` and their uppercase forms) are kept
through sudo; `FNM_NODE_DIST_MIRROR` (an https URL) serves the Node LTS lookup
as well as fnm's downloads; and on macOS `--brew-mirror china` uses the USTC
Homebrew mirror (Homebrew's own code, metadata and bottles) for the run,
including a Homebrew bootstrap, and for later shells, exactly like
`brew-china-enable`. `--brew-mirror none` turns it off again.

Node uses the saved `preserve-compatible` policy. The installer first preserves
a compatible fnm default; otherwise it adopts the exact version of a compatible
Node already on PATH into fnm. Only if neither is compatible does it resolve
one current LTS version from the `current-lts` fallback channel. Compatibility
uses the selected locked tools' engine ranges: currently pnpm requires Node
`>=22.13`, and Yarn requires `>=4.0.0`. A reconciliation does not advance an
already-compatible default merely because another LTS exists. Yarn/pnpm install
and verification commands run through explicit `fnm exec`, so they do not depend
on an interactive shell's PATH.

SSH/GPG default to Skip. Reuse requires a specifically selected SSH private-key
path or full GPG fingerprint; existing keys are never silently chosen. New SSH
keys default to `~/.ssh/id_ed25519`, or an explicitly chosen unused absolute
path. Existing files are not replaced. Both `empty` and `prompt` passphrase
policies are supported; `empty` is the default and is warned about explicitly.

GitHub operations are read-only. The installer never uploads keys, logs into
GitHub for you, or changes SSH identity configuration or GitHub CLI's Git
protocol. Missing registration produces a `manual-action` TSV record and exits
with status **3**, including the public-key file and destination URL. The
selected reference is saved first, and a public GPG export remains available
after cleanup. Register it yourself, then run the guided reconciliation again.
Missing login, email-read permission, or ordinary SSH configuration similarly
produces manual guidance. A network/API failure remains an error, not evidence
that a key is missing.

SSH derives matching public material, compares GitHub host keys with the API,
and verifies both the selected identity and ordinary SSH against the same
GitHub account. GPG requires a verified email, signs a real temporary commit,
and enables global **commit** signing only after registration is confirmed.
The independent `tag.gpgsign` preference is preserved. Reconciliation never
generates credentials. If an initial run paused before another requested key
was generated, resume the originally approved apply choices while reusing keys
already created; do not expect reconciliation to create the pending key.

## Existing setups

The installer appends its loader to your `.zshrc`; it never rewrites the rest.
`inspect` lists what it found (`existing` records). How each coexists:

- **oh-my-zsh**: its loader runs first, then the profile, so `compinit` runs
  twice and the profile's Starship prompt replaces the oh-my-zsh theme. Set
  `ZSH_THEME=""` and drop plugins the profile already provides
  (autosuggestions, syntax highlighting), or remove the oh-my-zsh lines.
- **powerlevel10k**: Starship sets the prompt after it. Keep one: remove the
  p10k source line and its instant-prompt block, or skip the `plugins`
  component and keep p10k.
- **nvm**: fnm's default Node comes first in new shells; `nvm use` still
  switches. Remove nvm's loader to save its startup time once fnm has your
  versions (the installer adopts a compatible existing Node into fnm).
- **conda**: at startup pyenv's shims come first, even ahead of the base
  environment `conda init` activates; `conda activate` then puts that
  environment's python ahead of them, as intended.
- **asdf / mise**: their shims and fnm/pyenv/rbenv's all provide node, python
  and ruby, and whichever activates last wins. Use one manager per language,
  or skip the overlapping components (`fnm`, `pyenv`, `rbenv`).
- **Homebrew copies of fnm, bun, Starship or uv**: the pinned copies in
  `~/.local/bin` come first (`shadow` records), so `brew upgrade` of those no
  longer changes what your shell runs; uninstall the Homebrew copies or keep
  them for other users.
- **Homebrew pyenv/rbenv**: reported as `conflict … homebrew-install`. The
  profile uses the pinned `~/.pyenv`/`~/.rbenv` when present and otherwise the
  one on PATH; `--skip-existing-version-managers` keeps Homebrew's alone.

## Zsh runtime

The installer adds managed, replaceable blocks to `.zshrc` and `.zshenv`, and
on macOS a third one to `.zprofile`. Those files are found the way zsh finds
them: in `ZDOTDIR` when the installer's environment sets it, otherwise in the
directory zsh reports after reading `~/.zshenv` (XDG-style setups usually set
`ZDOTDIR` there, in which case `.zshenv` itself stays in HOME). `inspect`
lists the resolved paths as `file` records. The first changed version of each
file is preserved beside it as `.leos-profiles.bak`; symlink targets are
updated without replacing the link. The profile remains relocatable via
`LEOS_PROFILES_HOME`.

Machines set up with the old pre-installer instructions carry an unmarked
`source …/zsh/start.zsh` loader in `.zshrc` and a `# leos-profiles zshenv`
snippet in `.zshenv`. `inspect` reports them as `migration` records, and the
`zsh-config` step (or `remove-blocks`) removes them; verification fails while
one remains. `start.zsh` also loads only once per shell, so a leftover loader
cannot double startup time in the meantime.

The `.zshrc` block is interactive-only and the `.zshenv` and `.zprofile`
blocks are silent, so `scp`, `rsync` and non-interactive `ssh` cannot break on
startup output. The `.zshenv` block also sets `skip_global_compinit=1`, which
stops Debian and Ubuntu's global `compinit` from building a completion dump
before the profile has its full `fpath`. The trade-off: a **non-interactive**
shell (`ssh host cmd`, cron, scripts) sees only `~/.local/bin` and
`~/.local/npm/bin` in front of the system PATH — no Homebrew, fnm, pyenv, rbenv
or Go — so remote one-liners that need those tools should use absolute paths or
activate just the required tool explicitly. On macOS, a login shell's
`/etc/zprofile` runs `path_helper`, which would push those two directories
behind the system and Homebrew paths; the managed `.zprofile` block puts them
back in front, so `zsh -l -c` sees the same order. A non-interactive login
shell alone does not source the interactive profile. For example, after fnm
setup:

```bash
"$HOME/.local/bin/fnm" exec --using=default -- node --version
```

`start.zsh` loads, in order: the PATH and environment layer (`entries.zsh`:
tool paths, `env.zsh`, `commands.zsh`), `local/private.zsh`, the interactive
layer (`interactive.zsh`: key bindings, `compinit`, completion-registering
tools, fzf-tab, zsh-autosuggestions, custom completions,
zsh-syntax-highlighting as the last plugin, then the Starship prompt) and
finally `local/private-interactive.zsh`. Both private files are sourced at the
top level of `start.zsh`, so plain `typeset`, `local` and `typeset -A`
declarations in them stay global, and both get a warning when they are
readable by anyone but their owner. With `TERM=dumb` (Emacs TRAMP and similar)
the shell stops after `local/private.zsh`: PATH and environment are set, but
there is no line editor, plugin or themed prompt, just `$ `. A root shell that
kept another user's HOME (`sudo -s`) does not load the profile at all, so it
cannot leave root-owned files in that HOME.

Deterministic initialization scripts for pyenv/rbenv, direnv, zoxide, fzf,
Starship, and npm/pnpm/Bun/uv/uvx completions are cached under
`${XDG_CACHE_HOME:-~/.cache}/leos-profiles/init`. Each entry's first line
records its full identity: the key, the resolved binary path, the arguments,
HOME, and the version-manager roots, each field quoted so no value can fake a
boundary. An entry is used only when that line matches; zoxide's identity also
covers `_ZO_ECHO` and `_ZO_RESOLVE_SYMLINKS`, which change its generated code.
Newly created directories are private; ownership, permissions, ancestors, and
symlinks are checked before cached code or compiled siblings are used. The
directory is validated in full once per shell; later lookups in the same shell
re-check only the cache root and its two profile-owned levels, and any change
there triggers full validation again. Unsafe storage falls back to fresh
initialization without trusting its contents. Failed generators'
partial output is not evaluated. The completion dump lives beside that cache
as `zcompdump-<zsh version>` (falling back to `${ZDOTDIR:-~}/.zcompdump` if
the cache root is unsafe); `.zcompdump*` files earlier versions left in the
home directory are removed once.

Homebrew runs `brew shellenv zsh` directly in each shell because its output
depends on the current environment; empty successful output is valid. `fnm env`
also runs per shell because it creates a unique `FNM_MULTISHELL_PATH`; a nested
shell drops the multishell directory it inherited first, and once a day a
background job deletes multishell links older than a day whose shell has
exited (fnm itself never removes them).
Cache freshness follows launcher mtimes. After an update changes only a separate
implementation file, run `leos-refresh-init-cache`; `brew-checkup` does this
automatically. pyenv/rbenv use `--no-rehash` and refresh their shims in the
background at most once a day. Yarn uses the bundled `_yarn` completion.

Startup latency depends on the host and installed tools. See the reproducible
[benchmark procedure](./docs/development.md#startup-benchmark); no universal
startup-time guarantee is claimed.

Performance notes:

- A warm shell runs no cache bookkeeping forks: the cache directory is
  validated once per shell and entries are named and checked in-process.
- The completion system is audited and rebuilt at most once a day, or when
  the completion search path changes; other shells load the dump with
  `compinit -C`.
- pyenv starts without forking bash to rewrite PATH and without its legacy
  `compctl` completion; `zsh/completions/_pyenv` completes pyenv through the
  completion system instead.
- zsh-autosuggestions wraps its widgets once, at the first prompt; lines
  starting with commands whose completers start a Node, Ruby or Bash program
  (brew, npm, pnpm, yarn, bun, heroku, pyenv, rbenv, gcloud, ref-taking git
  subcommands) get history suggestions only.
- The installer and `leos-refresh-init-cache` compile the profile and plugin
  sources to `.zwc` files beside them. Zsh ignores a `.zwc` that is older than
  its source or from another Zsh version, so an edit or a pull is never
  shadowed; reconcile (or `leos-refresh-init-cache`) recompiles them.
- Starship's right prompt only runs when the configuration defines a
  `right_format`, and its continuation prompt is computed when shown.
- `brew shellenv` is deliberately **not** cached (won't fix, audit PERF-6,
  about 20 ms). Its output depends on the shell that runs it: it returns
  nothing when the Homebrew paths are already on PATH, and its variables follow
  the Homebrew prefix in use. A cache would replay one shell's answer (such
  as that empty one) into every later shell; an earlier version cached it,
  and commit 36e6ab1 went back to running it per shell for that reason.

PATH precedence is deliberate: version-manager shims come first, then
`~/.local/bin`, then Go workspace bins, then Homebrew — so a stale binary in
`~/.local/bin` or `$GOPATH/bin` cannot shadow the Node/Python/Ruby a project
selected. Locale fallback validates `C.UTF-8`, then `en_US.UTF-8`, and
otherwise uses `C`. `LS_COLORS`, `LSCOLORS`, `MANPAGER` and `MANROFFOPT` are
only set when the environment does not already define them. fnm alone
constructs its runtime PATH.

Command wrappers stay compatible with the commands they replace:

- `ls` runs eza (with `--group-directories-first`) only when every argument
  means the same to eza as to ls: operands, `-1 -l -a -A -d -R` in any
  combination, and long options that only eza has (`--git`, `--tree`,
  `--icons`, …) or that GNU ls spells the same way. Anything else, such as
  `ls -ltr`, `ls -lh` or `ls --sort=time`, runs the real `ls` with the
  platform's colour flag. The full routing table is in `zsh/env.zsh`.
- `cat` runs `bat --style=plain --paging=never` only when its output is a
  terminal and it has no options; `cat -v`, `cat -n` and every pipe or
  redirection get the real `cat`.
- `grep`, `egrep` and `fgrep` add `--color=auto` (the latter two as
  `grep -E`/`grep -F`, since GNU grep warns that egrep/fgrep are obsolescent).
- With bat installed and no `MANPAGER` of your own, man pages use bat.

Set `LEOS_DISABLE_ALIASES=1` to disable all of these, or `unfunction ls` (or
`cat`) in `local/private.zsh` to drop one. `EXTENDED_GLOB` is on, but its `^`
negation is disabled so `git reset HEAD^` works; `~` still excludes. Set
`LEOS_PLAIN_PROMPT=1` for the ASCII prompt, or `LEOS_WARN_OPTIONAL_TOOLS=1` for
optional pyenv/rbenv warnings. Both prompts show `user@host` over SSH and just
the user name locally.

Interactive conveniences: the keymap is always emacs (even when `EDITOR` is
vim); Home, End, Delete and Ctrl-Left/Right work; Up/Down search history for
lines starting with what is already typed. When fd (or Debian's `fdfind`) is
installed, fzf's Ctrl-T, Alt-C and `**<Tab>` use it, so they honour
`.gitignore`; with bat, Ctrl-T previews files. Existing `FZF_*` settings win.
fzf-tab's `cd` preview uses eza, or `ls` where eza is not packaged.

### Optional integrations

The profile no longer wires up tools the installer does not provide. Add the
ones you use to `local/private.zsh` (or, for completions, to
`local/private-interactive.zsh`, which loads after `compinit`):

```zsh
# Flutter SDK on PATH
[[ -d $HOME/.flutter/bin ]] && path=("$HOME/.flutter/bin" $path)

# thefuck, initialised lazily on first use (it starts Python)
if (( $+commands[thefuck] )); then
  fuck() { unfunction fuck; eval "$(thefuck --alias)"; eval "fuck ${(j: :)${(q)@}}"; }
fi

# Google Cloud SDK PATH (Homebrew cask on macOS; the Linux packages put gcloud
# on PATH already)
if [[ -r ${HOMEBREW_PREFIX:-/opt/homebrew}/share/google-cloud-sdk/path.zsh.inc ]]; then
  source "${HOMEBREW_PREFIX:-/opt/homebrew}/share/google-cloud-sdk/path.zsh.inc"
fi
```

```zsh
# local/private-interactive.zsh: Google Cloud SDK completions. The script only
# runs its own compinit when compdef is missing, which it is not here.
for gcloud_completion in \
    "${HOMEBREW_PREFIX:-/opt/homebrew}/share/google-cloud-sdk/completion.zsh.inc" \
    /usr/share/google-cloud-sdk/completion.zsh.inc \
    /usr/lib/google-cloud-sdk/completion.zsh.inc; do
  if [[ -r $gcloud_completion ]]; then source "$gcloud_completion"; break; fi
done
unset gcloud_completion
```

## Updating and maintenance

`upgrade-leos-profiles [--full-upgrade] [--yes] [--verify-signatures]` needs a
saved setup (it says so before touching the checkout), a branch with an
upstream, and no tracked or non-ignored untracked checkout changes (`local/`
remains intentionally ignored). It fetches that configured upstream (official
or otherwise), lists the incoming commits (`git log --oneline HEAD..@{u}`) and
asks before fast-forwarding to them; without a terminal it requires `--yes`.
The new commits then run, with sudo, as `install.sh reconcile`, so read the
list. `--verify-signatures` fast-forwards only over commits with good
signatures Git can check: set `gpg.ssh.allowedSignersFile` for SSH-signed
commits, or have gpg and the signer's key. Reconcile installs missing selected
packages and repairs locked tools, plugins, configuration, fonts, and the
selected Node runtime without a full host upgrade. It checks saved credential
references and pauses for any required manual registration or configuration.
`--full-upgrade` opts into the saved broad package-manager upgrade behavior.

`leos-doctor` checks the saved setup without changing anything: it runs
`install.sh inspect --saved` and lists each component as ok, NEEDED or
skipped, with any warnings, conflicts, pending migrations and shadowed tools,
and says how to repair.

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
On Linux, it reads `/proc/self/mountinfo` to preserve same-device bind mounts;
an unreadable mount table aborts the scan before deletion.
Recycle-bin directory removal is opt-in. The privileged wrapper uses the system
Python interpreter in isolated mode, but executes the script from this
user-owned checkout. Trust changes to the checkout before running maintenance
with sudo.

`brew-china-enable` remains an explicitly confirmed USTC mirror option (the
installer's `--brew-mirror china` sets the same flag); the mirror serves
Homebrew's own code (brew.git) as well as metadata and bottles. Its flag lives
under `local/flags/`. `brew-china-disable` restores the official Homebrew
remote and environment.

## Support and validation matrix

- macOS 15 and later on Apple silicon, matching Homebrew's
  [Tier 1 support](https://docs.brew.sh/Support-Tiers). macOS 14 and Intel
  Macs are unsupported: Homebrew no longer publishes bottles there for
  packages this setup installs (node, python, ruby), so installs fail or build
  from source for hours. `inspect` reports such a Mac with an
  `unsupported-platform` warning and apply repeats it; there is no locked uv
  for Intel Macs.
- Ubuntu 22.04, 24.04, and 26.04 LTS on x86_64 and arm64, aligned with
  [Canonical's standard-support lifecycle](https://ubuntu.com/about/release-cycle).
- Debian 12 and 13 on x86_64 and arm64, following Debian's
  [oldstable/stable release table](https://www.debian.org/releases/index).
- Fedora 43 and 44 on x86_64 and aarch64, following Fedora's approximately N
  and N-1 [release lifecycle](https://docs.fedoraproject.org/en-US/releases/).
- Arch Linux rolling on x86_64. Arch Linux ARM uses compatible assets on a
  best-effort basis without a gating promise.
- WSL is best-effort when its guest matches a supported Linux family.

CI is configured to run actual provisioning in native x86_64 and arm64 Linux
containers for each listed Ubuntu, Debian, and Fedora release, plus Arch
x86_64. macOS jobs cover the hosted Apple-silicon macOS 15 and 26 runners with a
fresh HOME on the runner's existing OS and Homebrew installation. This is not
a factory-fresh macOS VM or proof of a clean Command Line Tools/Homebrew
bootstrap. The workflow tests minimal and recommended selections, pnpm-only
and Yarn/pnpm installation, repeated reconciliation, and repair after removing
artifacts. Credentials are skipped, default-shell changes are disabled, and
fonts are explicitly exercised. Separate isolated tests cover credentials.

Package availability, locked digests, real plugin integration, unit tests, and
syntax checks remain separate gates; availability alone is not installation
coverage. The weekly workflow repeats these checks. See the
[workflow](./.github/workflows/ci.yml) for exact jobs and runner labels, and
[development guide](./docs/development.md) for scope and reproduction.

## Hosts list and removal

[`res/adblock-hosts`](./res/adblock-hosts) remains a vendored convenience list.
It is not automatically applied or updated and its original provenance is not
recorded; review it before use and keep a backup.

`bash install.sh inventory` lists everything the installer creates or manages,
with its path and whether it is present: the managed blocks and their
backups, the `~/.local/bin` executables, the npm prefix, plugin checkouts,
pyenv/rbenv roots, the font directory, the init cache, `local/` files and
flags, and the global Git settings it may write (`--tsv` for typed records).
It, and `remove-blocks`, also run on hosts the installer does not support.

To stop loading the profile, run `bash install.sh remove-blocks` (add
`--dry-run` to preview). It deletes only the managed blocks from `.zshrc`,
`.zshenv` and (macOS) `.zprofile`, plus any legacy unmarked loader, and leaves
the rest of those files untouched, which is safer than
restoring `*.leos-profiles.bak`: that backup is written only the first time a
block is installed, so any later edits are not in it. Then start a fresh shell,
and delete the profile directory if desired. Package uninstall remains
deliberately manual because packages may be shared and upgrades are not safely
reversible. Git identity, signing preferences, and GitHub keys are likewise left
for explicit review.

## Development

See [docs/development.md](./docs/development.md) for module boundaries, the TSV
contract, regression tests, dependency updates, real provisioning, and startup
benchmarking. All machine-owned `local/` data stays ignored. Other local files
under `docs/` remain ignored; only this development guide is public.

The project is GPL-3.0; see [LICENSE](./LICENSE).
