# Leo's Profiles

Leo's Profiles is a personal shell/bootstrap repository centered around a Fish shell setup, an
AI-driven cross-platform quick installer, and a few utility scripts for day-to-day workstation
maintenance.

The repository is designed to bootstrap a new machine into a usable command-line environment with:

- a Fish-based interactive shell setup
- package installation for macOS, Debian/Ubuntu, Fedora, and Arch Linux
- pyenv, rbenv, Bun, Yarn, and Node LTS bootstrap helpers
- terminal quality-of-life functions and completions
- a couple of local utility scripts for file cleanup and cloud sync

## What This Repo Contains

### Fish shell environment

The Fish configuration lives under [`fish/`](./fish) and is loaded through [`fish/start.fish`](./fish/start.fish). It sets up:

- terminal environment variables and color defaults
- helper functions such as `puts`, `puts-err`, `add-path`, and `entry`
- PATH initialization for tools such as Homebrew, pyenv, rbenv, nvm, Go, Flutter, gcloud, GPG, and local user binaries
- interactive utility commands like `mkcdir`, `hidden-on`, `hidden-off`, `clear-history`, `bye`, and `upgrade-leos-profiles`

### Quick installer

Installation is **AI-driven and natural-language**. Instead of running a script, you point an AI
coding agent at [`QUICK-INSTALL.md`](./QUICK-INSTALL.md) and it performs the entire setup by reading
and executing that document.

Open an AI coding agent with **full/unrestricted permissions** — Claude Code
(`--dangerously-skip-permissions`), Codex (`--dangerously-bypass-approvals-and-sandbox`), or OpenCode
in bypass mode — and tell it:

> Set up my dev environment by following
> https://raw.githubusercontent.com/foxhatleo/leos-profiles/refs/heads/master/QUICK-INSTALL.md

The agent asks you a handful of decisions up front (SSH vs HTTPS, GPG-signed commits, which steps and
package groups to run), then works autonomously: it detects your OS, installs a minimal toolchain,
provisions Git (an SSH key and/or a GPG signing key, uploaded to GitHub via the `gh` CLI), clones the
repo to `~/.leos-profiles`, and runs the selected setup steps — verifying each and self-recovering
from errors. The runbook is idempotent, so re-running resumes wherever it left off.

The quick installer sets up:

- clone the repo into `~/.leos-profiles`
- optionally provision an SSH key and/or a GPG signing key on GitHub via `gh`
- install a curated package set for the current OS
- install local helper binaries
- set up `pyenv` and `rbenv`
- install `bun` and global `yarn`
- install the latest Node.js LTS with `nvm.fish`
- install Fish plugins and configure the Tide prompt
- write `~/.config/fish/config.fish`
- optionally install Nerd Fonts on desktop systems
- optionally switch the default shell to Fish

There is no non-AI install mode — the setup is driven entirely by an agent reading `QUICK-INSTALL.md`.

### Utility scripts

- [`util/rmdsstore.py`](./util/rmdsstore.py): recursively removes `.DS_Store`, `Thumbs.db`, `desktop.ini`, and `$RECYCLE.BIN` artifacts
- [`res/adblock-hosts`](./res/adblock-hosts): hosts-style blocklist resource file

## Repository Layout

```text
.
├── fish/
│   ├── commands.fish
│   ├── entries.fish
│   ├── start.fish
│   ├── terminal.fish
│   └── path/
├── res/
│   └── adblock-hosts
├── util/
│   └── rmdsstore.py
└── QUICK-INSTALL.md
```

## Supported Platforms

The quick installer currently has package bootstrap logic for:

- macOS via Homebrew
- Debian-based systems via `apt`
- Fedora via `dnf`
- Arch Linux via `pacman`

Notes:

- Fedora support intentionally uses RPM Fusion for `ffmpeg` when needed.
- Nerd Fonts installation is skipped automatically on non-desktop environments, or when you decline it in the setup questions.

## Quick Start

1. Install and open an AI coding agent (Claude Code, Codex, or OpenCode) with full/unrestricted permissions.
2. Tell it to follow the raw `QUICK-INSTALL.md` URL (see [Quick installer](#quick-installer) above).
3. Answer the up-front questions; the agent does the rest.

If you prefer HTTPS cloning over SSH, say so when the agent asks (or tell it to skip SSH
provisioning); it will clone `https://github.com/foxhatleo/leos-profiles` instead.

## What The Installer Does

The agent works in two phases, both idempotent:

**Phase 1 — prereq core (always runs):** detect the OS; ensure a minimal toolchain (Homebrew on
macOS, Node.js + npm everywhere); if you opted into SSH or GPG signing, install and authenticate the
GitHub CLI (`gh`), provision the key(s), and upload them to GitHub; clone the repo to
`~/.leos-profiles`.

**Phase 2 — selected steps (in order):** install local bins, OS packages, `pyenv`, `rbenv`, `bun`,
`yarn`, Node LTS via `nvm`, Fish plugins + Tide prompt, Nerd Fonts (desktop only), write the Fish
config, and set the default shell to Fish — running only the steps and package groups you selected.

Before each step the agent checks whether it is already done and skips it if so, so an interrupted run
resumes cleanly on the next attempt. If a step fails, the agent diagnoses and fixes it with full shell
access, then continues. On Linux the agent primes `sudo` early, so you may be prompted for your
password once.

## Installer Choices

All decisions are asked up front, before any work begins:

- **SSH for GitHub** (default: yes) — provision an SSH key and add it to GitHub, then clone over SSH.
  Decline to clone over HTTPS instead.
- **GPG-signed commits** (default: yes) — generate or reuse a GPG key, configure git to sign commits,
  and upload the public key to GitHub. Commits show as **Verified** when the signing email is a
  verified email on your GitHub account.
- **Git identity** — asked only if `user.name` / `user.email` are not already set.
- **Steps** (default: all) — any subset of the Phase 2 steps above.
- **Package groups** (default: all) — `core-utils`, `shell`, `dev-tools`, `languages`, `media`,
  `network`, `system`.
- **Nerd Fonts** — default on for desktops, off on headless machines.

Tell the agent to "use the defaults" to skip the questions and run the full default plan.

## Fish Setup

The quick installer writes this config to `~/.config/fish/config.fish`:

```fish
if status is-interactive
    source "$HOME/.leos-profiles/fish/start.fish"
    set fish_greeting
end
```

If you are setting things up manually, placing the same snippet in your Fish config is the easiest way to load the profile.

## Included Fish Commands

After loading the profile, the repo provides several convenience commands.

Common examples:

- `mkcdir <dir>`: create a directory and immediately `cd` into it
- `upgrade-leos-profiles`: pull the latest changes into `~/.leos-profiles`
- `hidden-on` / `hidden-off`: show or hide hidden files in Finder on macOS
- `clear-history`: remove shell and related history files
- `bye`: cleanup-oriented shell exit helper
- `apt-checkup`, `dnf-checkup`, `brew-checkup`: package-manager maintenance helpers when those tools are available
- `ai-checkup`: update the AI coding CLIs (Claude Code, Codex) via `npm update -g`
- `brew-china-enable` / `brew-china-disable`: switch Homebrew remotes and bottle mirror settings
- `enable-gnu` / `disable-gnu`: toggle GNU tool precedence on macOS
- `rmdsstore`: scan standard macOS filesystem roots and remove Finder/Windows metadata files

## Utility Script Usage

### Remove metadata files

To clean a specific directory tree:

```bash
python3 util/rmdsstore.py /path/to/scan
```

The Fish helper `rmdsstore` wraps this script and scans a set of predefined macOS filesystem roots.

## Manual Installation

If you do not want to use the AI-driven bootstrap flow, a minimal manual setup usually looks like this:

1. Clone the repository to `~/.leos-profiles`.
2. Install Fish and any package-manager dependencies you care about.
3. Add the Fish startup snippet shown above to `~/.config/fish/config.fish`.
4. Optionally run selected utilities directly from `util/`.

## Development Notes

- Installation is defined entirely by [`QUICK-INSTALL.md`](./QUICK-INSTALL.md); there is no installer script to maintain.
- This repository appears to be an actively reorganized personal dotfiles/workstation repo, so paths may evolve over time. The current layout is reflected in this README.

## Troubleshooting

- If SSH cloning fails, tell the agent to use HTTPS (decline SSH provisioning), or verify that your SSH key was added to GitHub.
- If Fish reports missing tools such as `pyenv` or `rbenv`, the profile can silence those warnings with marker files like `~/.lp-nopyenv` and `~/.lp-norbenv`.
- If a setup run is interrupted, have the agent follow `QUICK-INSTALL.md` again — every step is idempotent and already-completed work is skipped.
- If you do not want Nerd Fonts, or you are on a headless machine, decline the Nerd Fonts step.
- On Linux, some steps need `sudo`; the agent primes it early and you may be prompted for your password once.

## License

This project is licensed under the GNU General Public License v3.0. See [`LICENSE`](./LICENSE) for the full text.
