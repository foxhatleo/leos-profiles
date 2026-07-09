# Leo's Profiles — Quick Install

This document *is* the installer. It is a runbook for an AI coding agent to set up a machine with
Leo's Profiles (a Zsh dev environment). There is no script to run — an agent reads this file
and does the work.

---

## For humans only

**STOP — this guide is written for an AI agent, not for you to run by hand.**

To quick-install, open an AI coding agent with **full/unrestricted permissions** (Claude Code with
`--dangerously-skip-permissions`, Codex with `--dangerously-bypass-approvals-and-sandbox`, or
OpenCode in bypass mode), then tell it:

> Set up my dev environment by following
> https://raw.githubusercontent.com/foxhatleo/leos-profiles/refs/heads/master/QUICK-INSTALL.md

The agent will ask you a handful of setup questions up front, then do everything else on its own.
Stay nearby: a couple of steps (authenticating the GitHub CLI, entering your `sudo` password on
Linux) may need you for a moment.

---

## For the AI agent — operating rules

You are setting up this machine. Read this whole file first, then execute it.

- **You have full permissions.** Act autonomously. Do not ask for per-command approval.
- **The machine may be partially set up.** Before each step, run its *already-done check*. If it
  passes, verify and move on — do not redo work. Every command here is safe to re-run (idempotent).
  This is how you resume an interrupted run; there is no state file.
- **Execute in order.** Do the prereq core first, then the selected steps in the order given. After
  each step, run its *success check* before continuing.
- **Self-recover.** If a command fails, diagnose and fix it with your full shell access, then
  continue. Do not improvise beyond making each step's end-state match what is described. Do not
  change unrelated configuration or install anything not listed here.
- **Detect the OS once, up front** and use the matching commands throughout:
  - **macOS** — `[[ "$OSTYPE" == darwin* ]]` (uses Homebrew, no `sudo` for packages)
  - **Debian/Ubuntu** — `command -v apt-get` succeeds (`apt`)
  - **Fedora** — `command -v dnf` succeeds **and** `grep -Eq '^ID="?fedora"?$' /etc/os-release`
  - **Arch** — `command -v pacman` succeeds
- **`sudo`** — on Linux, run `sudo -v` once early so later package steps don't stall; the human may be
  prompted for their password. macOS Homebrew needs no `sudo`.
- **Target path:** clone into `~/.leos-profiles`. **Repo:** `foxhatleo/leos-profiles`.
- When every selected step has succeeded or was already complete, tell the human what you did and to
  restart their shell (and note if the default shell was changed).

---

## Step 0 — Ask the human these decisions up front

Ask **all** of the following **before doing any work**, in one batch. Present the defaults; the human
can accept them wholesale ("use the defaults") — in that case skip the questions and use every
default below. Anything the human deselects is simply never executed.

1. **SSH for GitHub?** (default: **yes**) — Provision an SSH key on this machine and add it to your
   GitHub account, then clone over SSH. If no, clone over HTTPS instead. *(Skip the question and keep
   the existing setup if `ssh -T git@github.com` already authenticates.)*

2. **Sign commits with GPG?** (default: **yes**) — Generate (or reuse) a GPG key, configure git to
   sign all commits, and upload the public key to GitHub. *(Skip if `git config --global commit.gpgsign`
   is already `true` and a `user.signingkey` is set.)*

3. **Git identity** — only ask if missing. If `git config --global user.name` or
   `git config --global user.email` is empty, ask for the name and email to use, then write them
   immediately with `git config --global user.name "<name>"` and `git config --global user.email
   "<email>"` (P5 and later steps read them back). Required if signing
   is enabled. Use the same email for the GPG key so GitHub can show commits as **Verified** (the
   email must also be a verified email on the GitHub account).

4. **Which steps to run?** (default: **all checked**) — multi-select:
   - Install local helper bins (`rpatool`)
   - Install OS packages (curated set for your OS)
   - Install `pyenv`
   - Install `rbenv`
   - Install `bun`
   - Install global `yarn`
   - Install global `pnpm`
   - Install **fnm** + latest Node.js LTS
   - Set up zsh plugins + Starship prompt
   - Install Nerd Fonts *(default off on a headless/server machine — see the desktop gate)*
   - Write `~/.zshrc`
   - Set the default shell to zsh

5. **Which package groups?** (default: **all checked**, only relevant if "Install OS packages" is on)
   — multi-select: `core-utils`, `shell`, `dev-tools`, `languages`, `media`, `network`, `system`.

**Dependency rule (enforce silently):** some steps need earlier ones. If the human selects a step but
deselects its prerequisite, run the prerequisite anyway:
- local bins, zsh config → need the repo cloned (always happens in the prereq core)
- global `yarn`/`pnpm`, zsh plugins, Node LTS, default-shell → need OS packages (they rely on `node`/`zsh`)

---

## Prereq core (always runs, in this order)

Everything else depends on the prereq core, so treat failures here seriously: make a best-effort
self-correction and diagnosis before giving up — retry the command, check network/DNS, permissions,
and disk space, and try an alternate path where one exists (e.g. HTTPS clone if SSH fails, GitHub's
official `gh` repo if the distro package is missing, `sudo -v` if a privileged step is refused). Note
briefly what you tried. Only stop and report to the human if you genuinely cannot proceed.

### P1 — Detect the OS
Determine macOS / apt / fedora / pacman using the rules above. If none match, stop and tell the human
the OS is unsupported.

### P2 — Minimal toolchain (Homebrew on macOS, Node + npm everywhere)
Skip whatever is already present.

- **macOS** — if `brew` is not on `PATH` and not at `/opt/homebrew/bin/brew`, `/usr/local/bin/brew`,
  `~/.linuxbrew/bin/brew`, or `/home/linuxbrew/.linuxbrew/bin/brew`, install it, then load its env,
  then install Node if missing:
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # load brew from whichever prefix it installed to (Apple Silicon, Intel, or linuxbrew):
  BREW="$(command -v brew || true)"
  for c in /opt/homebrew/bin/brew /usr/local/bin/brew "$HOME/.linuxbrew/bin/brew" /home/linuxbrew/.linuxbrew/bin/brew; do
    [ -n "$BREW" ] && break; [ -x "$c" ] && BREW="$c"
  done
  eval "$("$BREW" shellenv)"
  command -v node >/dev/null 2>&1 || brew install node
  ```
- **Linux** — if `node` or `npm` is missing, install via the distro package manager:
  ```bash
  # apt
  sudo apt-get -y install nodejs npm
  # fedora
  sudo dnf -y install nodejs
  # pacman
  sudo pacman -S --noconfirm nodejs npm
  ```
- **Already-done check:** `command -v node && command -v npm` (and `brew` on macOS).

### P3 — GitHub CLI (`gh`) — only if SSH provisioning or GPG signing was chosen
Skip entirely if the human chose neither SSH nor signing.

- Install `gh` if missing: `brew install gh` (macOS) / `sudo apt-get -y install gh` /
  `sudo dnf -y install gh` / `sudo pacman -S --noconfirm github-cli`. If the distro has no `gh`
  package, use GitHub's official apt/dnf repository instructions from
  https://github.com/cli/cli/blob/trunk/docs/install_linux.md.
- Authenticate if needed: `gh auth status || gh auth login`. This may open a browser / device flow —
  guide the human through it. Prefer `gh auth login --hostname github.com --git-protocol ssh --web`
  when SSH was chosen.
- **Already-done check:** `gh auth status` exits 0.

### P4 — SSH key provisioning — only if SSH was chosen
Skip if `ssh -o StrictHostKeyChecking=accept-new -T git@github.com` already authenticates (it exits
non-zero but prints `Hi <user>! You've successfully authenticated`).

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# Reuse an existing key if present (regenerating a missing .pub from its private half); never overwrite:
PUB=""
for k in id_ed25519 id_rsa id_ecdsa id_ecdsa_sk id_ed25519_sk; do
  if [ -f ~/.ssh/"$k".pub ]; then PUB=~/.ssh/"$k".pub; break; fi
  if [ -f ~/.ssh/"$k" ]; then ssh-keygen -y -f ~/.ssh/"$k" > ~/.ssh/"$k".pub && { PUB=~/.ssh/"$k".pub; break; }; fi
done
if [ -z "$PUB" ]; then
  if ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q; then PUB=~/.ssh/id_ed25519.pub
  else ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q; PUB=~/.ssh/id_rsa.pub; fi
fi
# Idempotent upload: ignore "key already exists" on re-runs.
gh ssh-key add "$PUB" --title "$(hostname)" 2>/dev/null || echo "SSH key already present on GitHub (or add skipped)."
```
If `gh ssh-key add` reports a missing scope, run `gh auth refresh -s admin:public_key` and retry.
**Success check:** `ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q 'successfully authenticated'`.

### P5 — GPG signed commits — only if signing was chosen
Ensure `gnupg` is installed (`brew install gnupg` / `sudo apt-get -y install gnupg` /
`sudo dnf -y install gnupg2` / `sudo pacman -S --noconfirm gnupg`). Ensure git identity is set
(from Step 0). Reuse an existing secret key whose UID email matches the git email; otherwise generate
one bound to that email.

```bash
NAME="$(git config --global user.name)"
EMAIL="$(git config --global user.email)"
# Reuse ONLY a secret key whose UID email EXACTLY matches the git email ("<$EMAIL>" is gpg's
# exact-email match, avoiding substring hits); otherwise generate one non-interactively:
KEYID="$(gpg --list-secret-keys --keyid-format=long --with-colons "<$EMAIL>" 2>/dev/null | awk -F: '/^sec:/{print $5; exit}')"
if [ -z "$KEYID" ]; then
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-generate-key "$NAME <$EMAIL>" ed25519 sign never
  KEYID="$(gpg --list-secret-keys --keyid-format=long --with-colons "<$EMAIL>" | awk -F: '/^sec:/{print $5; exit}')"
fi
git config --global user.signingkey "$KEYID"
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global gpg.program "$(command -v gpg)"
# Idempotent upload: ignore "key already exists" on re-runs.
gpg --armor --export "$KEYID" | gh gpg-key add - 2>/dev/null || echo "GPG key already present on GitHub (or add skipped)."
```
If `gh gpg-key add` reports a missing scope, run `gh auth refresh -s admin:gpg_key` and retry.
**Success check:** `git config --global commit.gpgsign` is `true` and `user.signingkey` is set.
Note to the human: commits show as **Verified** on GitHub only if `$EMAIL` is a verified email on
their account.

### P6 — Clone the repo
Skip if `~/.leos-profiles` already exists.
```bash
# SSH was chosen:
git clone git@github.com:foxhatleo/leos-profiles.git ~/.leos-profiles
# otherwise HTTPS:
git clone https://github.com/foxhatleo/leos-profiles ~/.leos-profiles
```
**Success check:** `~/.leos-profiles/zsh/start.zsh` exists.

---

## Selected steps (run the ones chosen in Step 0, in this order)

For each: check *already-done* first; run the command(s); then run the *success check*.

### 1. Install local bins
Install `rpatool` into `~/.local/bin`.
```bash
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/rpatool https://codeberg.org/shiz/rpatool/raw/branch/master/rpatool
chmod u+x ~/.local/bin/rpatool
```
- **Already-done / success:** `[ -x ~/.local/bin/rpatool ]`

### 2. Install OS packages
Install the curated set for the detected OS. If the human deselected any package **groups**, drop
that group's members from the command (group→member map and per-OS name resolution are at the bottom
of this file). If all groups are selected, use the full list verbatim:

- **macOS:**
  ```bash
  brew tap heroku/brew
  brew install bash bat coreutils diffutils direnv ed eza fd ffmpeg findutils fzf heroku imagemagick git gnu-indent gnu-sed gnu-tar gnu-which gnutls grep gawk gzip less nano node python rclone ripgrep ruby smartmontools ssh-copy-id vim wget yt-dlp zoxide zsh
  ```
  Success: `brew list zsh`
- **Debian/Ubuntu (apt):**
  ```bash
  sudo apt -y update && sudo DEBIAN_FRONTEND=noninteractive apt -y upgrade
  sudo DEBIAN_FRONTEND=noninteractive apt -y install bash bat build-essential clang coreutils diffutils direnv ed fd-find ffmpeg findutils fzf imagemagick gcc git grep gawk gzip less nano nodejs python-is-python3 rclone ripgrep ruby smartmontools vim wget yt-dlp zoxide zsh
  # Debian/Ubuntu ship fd/bat under renamed binaries (name clashes with unrelated packages);
  # symlink the canonical names into ~/.local/bin (already on PATH via ~/.zshenv):
  mkdir -p ~/.local/bin
  command -v fd >/dev/null 2>&1 || { command -v fdfind >/dev/null 2>&1 && ln -sf "$(command -v fdfind)" ~/.local/bin/fd; }
  command -v bat >/dev/null 2>&1 || { command -v batcat >/dev/null 2>&1 && ln -sf "$(command -v batcat)" ~/.local/bin/bat; }
  # eza isn't in every release's default apt repos (may need a third-party repo); best-effort:
  sudo apt -y install eza 2>/dev/null || echo "eza not available via apt on this release — skipping."
  ```
  Success: `dpkg -l zsh | grep -q '^ii'`
- **Fedora (dnf):**
  ```bash
  sudo dnf -y update
  sudo dnf -y group install development-tools
  rpm -q rpmfusion-free-release >/dev/null 2>&1 || sudo dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
  sudo dnf -y install bash bat coreutils diffutils direnv ed fd-find findutils fzf ImageMagick git grep gawk gzip less nano nodejs python-unversioned-command rclone ripgrep ruby smartmontools vim wget yt-dlp zoxide zsh
  # eza packaging has come and gone across Fedora releases; best-effort:
  sudo dnf -y install eza 2>/dev/null || echo "eza not available via dnf on this release — skipping."
  # ffmpeg via RPM Fusion (swap the stripped -free build if present):
  if rpm -q ffmpeg-free >/dev/null 2>&1; then sudo dnf -y swap ffmpeg-free ffmpeg --allowerasing; else sudo dnf -y install ffmpeg; fi
  ```
  Success: `rpm -q zsh`
- **Arch (pacman):**
  ```bash
  sudo pacman -Syu --noconfirm
  sudo pacman -S --noconfirm base-devel bash bat coreutils diffutils direnv ed eza fd ffmpeg findutils fzf imagemagick git grep gawk gzip less nano nodejs npm python rclone ripgrep ruby smartmontools vim wget yt-dlp zoxide zsh
  ```
  Success: `pacman -Q zsh`
- **Already-done check (any OS):** these installs are idempotent. The per-OS "Success" query (zsh
  present) is a cheap proxy; if you cannot confirm the *entire* selected set is installed, just re-run
  the install command — re-running is safe and cheap.

### 3. Install pyenv
```bash
[ -d ~/.pyenv ] || git clone https://github.com/pyenv/pyenv.git ~/.pyenv
# Build pyenv's optional native extension. `make` no-ops when already up to date, so this is
# safe to re-run; keep it UNCONDITIONAL — pyenv works uncompiled, so a `pyenv --version` gate
# here would skip the build on every fresh clone (the extension would never get built).
(cd ~/.pyenv && src/configure && make -C src)
```
- **Already-done:** `~/.pyenv/bin/pyenv --version` succeeds (better than `[ -d ~/.pyenv ]`, which is
  also true for an empty/half-cloned dir and would skip the re-clone) · **Success:** `~/.pyenv/bin/pyenv --version`

### 4. Install rbenv
```bash
[ -d ~/.rbenv ] || git clone https://github.com/rbenv/rbenv.git ~/.rbenv
mkdir -p "$(~/.rbenv/bin/rbenv root)/plugins"
[ -d "$(~/.rbenv/bin/rbenv root)/plugins/ruby-build" ] || git clone https://github.com/rbenv/ruby-build.git "$(~/.rbenv/bin/rbenv root)/plugins/ruby-build"
```
- **Already-done:** `~/.rbenv/bin/rbenv --version` succeeds AND the `ruby-build` plugin dir exists
  (NOT just `[ -d ~/.rbenv ]` — a run interrupted before ruby-build was cloned looks "done" but
  can't install Rubies) · **Success:** `~/.rbenv/bin/rbenv --version`

### 5. Install bun
```bash
curl -fsSL https://bun.com/install | bash
```
- **Already-done / success:** `~/.bun/bin/bun --version` (bun installs to `~/.bun/bin`, which is not on `PATH` until a new shell).

### 6. Install yarn
```bash
npm install --global yarn
```
- **Already-done / success:** `command -v yarn && yarn --version`

### 7. Install pnpm
```bash
npm install --global pnpm
```
- **Already-done / success:** `command -v pnpm && pnpm --version`

### 8. Install fnm + latest Node.js LTS
Install fnm (fast Node version manager), then the latest LTS, and pin it as the default:
```bash
command -v fnm >/dev/null 2>&1 || { command -v brew >/dev/null 2>&1 && brew install fnm; } \
  || curl -fsSL https://fnm.vercel.app/install | bash
# make fnm available in THIS shell for the install below:
[ -d "$HOME/.local/share/fnm" ] && export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env)" 2>/dev/null || true
fnm install --lts
# `fnm current` prints `none` right after install (nothing active yet), so `fnm default
# "$(fnm current)"` would fail. Use the built-in lts-latest alias, with a version fallback.
fnm default lts-latest 2>/dev/null || fnm default "$(fnm ls | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1)"
```
- **Already-done / success:** `fnm current` prints a version (not `none`). fnm reads `.nvmrc` /
  `.node-version` and (via `--use-on-cd`, wired in the zsh config) auto-switches per directory.

### 9. Set up zsh plugins and Starship prompt
Install Starship, clone the zsh plugins into the repo, and fetch the iTerm2 zsh integration. This step
is self-contained (it needs nothing from the fnm/Node step):
```bash
# Starship prompt (package where available, else the official installer):
command -v starship >/dev/null 2>&1 || { command -v brew >/dev/null 2>&1 && brew install starship; } \
  || sudo apt-get -y install starship 2>/dev/null || sudo dnf -y install starship 2>/dev/null \
  || sudo pacman -S --noconfirm starship 2>/dev/null \
  || curl -fsSL https://starship.rs/install.sh | sh -s -- -y
# Plain clone-and-source plugins into the repo-managed dir (idempotent):
mkdir -p ~/.leos-profiles/zsh/plugins
for repo in zsh-users/zsh-autosuggestions zsh-users/zsh-syntax-highlighting zsh-users/zsh-completions Aloxaf/fzf-tab; do
  dst=~/.leos-profiles/zsh/plugins/"${repo##*/}"
  [ -d "$dst" ] || git clone --depth=1 "https://github.com/$repo" "$dst"
done
# iTerm2 zsh shell integration:
curl -LsS https://iterm2.com/shell_integration/zsh -o "$HOME/.iterm2_shell_integration.zsh"
```
- **Already-done / success:** `command -v starship && [ -d ~/.leos-profiles/zsh/plugins/zsh-syntax-highlighting ]`

### 10. Install Nerd Fonts
**Desktop gate:** run only on a desktop. macOS always counts as desktop; on Linux, only if any of
`DISPLAY`, `WAYLAND_DISPLAY`, or `XDG_CURRENT_DESKTOP` is set. Skip on a headless/server machine.
```bash
tmp="$(mktemp -d)"
git clone --depth=1 https://github.com/ryanoasis/nerd-fonts.git "$tmp/nerd-fonts"
(cd "$tmp/nerd-fonts" && ./install.sh)
rm -rf "$tmp"
```
- **Already-done / success:** a Nerd font is present — macOS: `ls ~/Library/Fonts 2>/dev/null | grep -qi nerd`; Linux: `ls ~/.local/share/fonts 2>/dev/null | grep -qi nerd`.

### 11. Write zsh config
Write `~/.zshrc` (loads the profile on interactive shells) and a minimal `~/.zshenv`:
```bash
# ~/.zshrc — append our loader only if absent; never overwrite an existing user config:
grep -q 'leos-profiles/zsh/start.zsh' ~/.zshrc 2>/dev/null || cat >> ~/.zshrc <<'EOF'
if [[ -o interactive ]]; then
    source "$HOME/.leos-profiles/zsh/start.zsh"
fi
EOF
# ~/.zshenv — minimal PATH for login/non-interactive shells:
grep -q 'leos-profiles zshenv' ~/.zshenv 2>/dev/null || cat >> ~/.zshenv <<'EOF'
# leos-profiles zshenv
typeset -U path
path=("$HOME/.local/bin" $path)
export PATH
EOF
```
- **Already-done / success:** `grep -q leos-profiles ~/.zshrc`

### 12. Set the default shell to zsh
```bash
ZSH_PATH="$(command -v zsh)"
[ -n "$ZSH_PATH" ] || { echo "zsh is not installed — run the OS packages step first"; exit 1; }
grep -qxF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
sudo chsh -s "$ZSH_PATH" "$USER"   # sudo uses the primed credential, avoiding an interactive password prompt
```
- **Already-done / success:** the login shell is zsh — `getent passwd "$USER" 2>/dev/null | cut -d: -f7 | grep -q zsh` (Linux) or `dscl . -read /Users/"$USER" UserShell 2>/dev/null | grep -q zsh` (macOS). (`$SHELL` only reflects the change on next login; macOS often defaults to zsh already.)

---

## Finishing up

Re-run each selected step's success check. If all pass (or were already complete), print a concise
**summary of what you actually did this run** — which steps ran, what was installed or upgraded, what
was skipped and why (already present, deselected, or gated off), and any self-corrections you made.

Then tell the human:

- Restart your terminal (or log out/in) to load zsh and the new profile. If the default shell was
  changed, it applies on the next login.
- To also set up Leo's own flavors of AI coding environments, see
  [`foxhatleo/leos-claude`](https://github.com/foxhatleo/leos-claude) (Claude Code) and
  [`foxhatleo/leos-codex`](https://github.com/foxhatleo/leos-codex) (Codex).

---

## Reference — package groups

If the human deselected groups in Step 0, drop those members from the OS-packages command. Canonical
members per group:

| Group | Canonical members |
| --- | --- |
| `core-utils` | bash coreutils diffutils ed findutils gnu-indent gnu-sed gnu-tar gnu-which grep gawk gzip less nano |
| `shell` | zsh |
| `dev-tools` | git vim fzf direnv bat eza fd ripgrep zoxide build-essential clang gcc base-devel |
| `languages` | node python ruby |
| `media` | ffmpeg imagemagick yt-dlp |
| `network` | wget rclone gnutls heroku ssh-copy-id |
| `system` | smartmontools |

**Per-OS name resolution** (a canonical member maps to a real package name, or nothing if absent on
that OS):
- **macOS-only** members: `gnu-indent`, `gnu-sed`, `gnu-tar`, `gnu-which`, `gnutls`, `ssh-copy-id`, `heroku`.
- **Build toolchain:** `build-essential` → apt only; `clang` → apt only; `gcc` → apt only;
  `base-devel` → pacman only. (macOS/Fedora get build tooling from `brew`/`development-tools`.)
- **node** → `node` (macOS) / `nodejs` (apt, fedora) / `nodejs npm` (pacman).
- **python** → `python` (macOS, pacman) / `python-is-python3` (apt) / `python-unversioned-command` (fedora — provides `/usr/bin/python`; `python-is-python3` is Debian-only).
- **imagemagick** → `ImageMagick` (Fedora) / `imagemagick` (everywhere else).
- **fd** → `fd` (macOS, Arch) / `fd-find` (apt, Fedora — apt's binary is renamed `fdfind`, symlinked to
  `fd` by the install step; Fedora's `fd-find` package installs the `fd` binary directly).
- **bat** → `bat` (same package name everywhere), but apt renames the binary to `batcat`, symlinked to
  `bat` by the install step.
- **eza** → `eza` (macOS, Arch — official repos); on apt/Fedora it is installed best-effort as a
  separate command since availability varies by release (may be absent or need a third-party repo).
- Everything else uses the same name on every OS.
