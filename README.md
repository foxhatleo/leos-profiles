# Leo's Profiles

Leo's Profiles is a personal shell/bootstrap repository centered around a Fish shell setup, a cross-platform quick installer, and a few utility scripts for day-to-day workstation maintenance.

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

There are two installer entrypoints:

- [`quick-install.sh`](./quick-install.sh): lightweight bootstrap entrypoint intended for local use or one-line remote install
- [`util/quick-install.sh`](./util/quick-install.sh): the full installer implementation

Every install is **AI-driven**: the installer bootstraps a minimal prereq core deterministically (clone the repo, ensure Homebrew on macOS, install Node/npm, install and authenticate Claude Code and Codex on interactive runs), then hands the rest of the setup to the chosen AI agent (Claude Code or Codex) running in bypass/no-approval mode. The agent uses a precise runbook generated from your resolved plan, so it knows exactly what to do and can self-recover from errors without improvising.

The quick installer sets up:

- clone the repo into `~/.leos-profiles`
- install a curated package set for the current OS
- install local helper binaries
- set up `pyenv` and `rbenv`
- install `bun` and global `yarn`
- install the latest Node.js LTS with `nvm.fish`
- install AI coding CLIs (Claude Code and Codex) and seed starter config
- install Fish plugins and configure the Tide prompt
- write `~/.config/fish/config.fish`
- optionally install Nerd Fonts on desktop systems
- optionally switch the default shell to Fish

On an interactive terminal the installer shows a **fullscreen setup wizard** (pure bash + ANSI, zero extra dependencies) that lets you choose which steps and package groups to include and review a confirmation screen before anything runs. You are then prompted to authenticate the AI CLIs, and the authenticated agent drives the rest. It accepts CLI flags for scripted and CI use. Run `util/quick-install.sh --help` for the full flag reference.

**An authenticated Claude Code or Codex installation is required.** There is no non-AI install mode.

### Utility scripts

- [`util/rmdsstore.py`](./util/rmdsstore.py): recursively removes `.DS_Store`, `Thumbs.db`, `desktop.ini`, and `$RECYCLE.BIN` artifacts
- [`util/verify-quick-install-packages.py`](./util/verify-quick-install-packages.py): checks whether packages referenced by the installer exist in official/default package sources across supported platforms
- [`res/adblock-hosts`](./res/adblock-hosts): hosts-style blocklist resource file
- [`res/ai/`](./res/ai): starter config templates for the AI coding CLIs, seeded into `~/.claude/` and `~/.codex/` only when those files do not already exist (the installer handles auth interactively or requires it to already be in place for silent runs)

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
│   ├── adblock-hosts
│   └── ai/
├── util/
│   ├── quick-install.sh
│   ├── rmdsstore.py
│   └── verify-quick-install-packages.py
└── quick-install.sh
```

## Supported Platforms

The quick installer currently has package bootstrap logic for:

- macOS via Homebrew
- Debian-based systems via `apt`
- Fedora via `dnf`
- Arch Linux via `pacman`

Notes:

- Fedora support intentionally uses RPM Fusion for `ffmpeg` when needed.
- Nerd Fonts installation is skipped automatically on non-desktop environments, or when `NO_FONTS=1` is set.

## Quick Start

### Remote bootstrap

Run the public bootstrap entrypoint:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)"
```

On an interactive terminal (including `curl | bash` via `/dev/tty`) this opens the setup wizard, installs Claude Code and Codex, prompts you to authenticate them, then lets the chosen agent drive the rest. If you already have an authenticated Claude Code or Codex and want to run unattended:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)" -- --silent
```

Running without a terminal and without `--silent` is an error — the installer will print guidance and exit rather than guess at an unattended run.

If you prefer HTTPS cloning instead of SSH:

```bash
USE_HTTPS=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)"
```

### Local bootstrap

From a local checkout:

```bash
/bin/bash ./quick-install.sh
```

or invoke the full implementation directly:

```bash
/bin/bash ./util/quick-install.sh
```

## What The Installer Does

The installer is step-based and records progress in `~/.leos-profiles/quick-install.state` so an interrupted run can resume from the failed step. The flow has two phases:

### Phase 1 — Prereq core (deterministic, skips work already present)

Run unconditionally before the AI agent takes over:

1. Prepare and clone repo
2. Ensure minimal toolchain: Homebrew (macOS), Node.js, npm
3. *(Interactive only)* Install AI coding CLIs (Claude Code, Codex)
4. *(Interactive only)* Authenticate CLIs — see [Auth flow](#auth-flow) below

### Phase 2 — AI-driven setup

After the prereq core, the installer generates a precise runbook from your resolved plan and hands it to the chosen agent (Claude Code or Codex) running in bypass mode. The agent executes each step in order, verifies success, and self-recovers from errors. Default steps driven by the agent:

5. Install local bins
6. Install OS packages
7. Install `pyenv`
8. Install `rbenv`
9. Install `bun`
10. Install `yarn`
11. Install latest Node.js LTS with `nvm`
12. Set up Fish plugins and prompt
13. Install Nerd Fonts when appropriate
14. Write Fish config
15. Set default shell to Fish

On an interactive terminal the wizard lets you toggle steps and package groups before anything runs, then shows a read-only confirmation screen. The wizard pre-seeds its selections from your flags and environment so forced-on or locked choices are clearly marked. The wizard output feeds the runbook — anything you deselect never appears in the plan the agent receives.

### Auth flow

After installing the AI CLIs, the installer checks whether each is already authenticated. Any already-authed CLI is used as-is. For any that are not, you are asked whether to authenticate now. The result determines which agent drives setup:

- **Neither authenticated:** the installer exits with guidance to re-run after authenticating, or to use `--silent=<cli>` once a CLI is set up.
- **One authenticated:** that CLI drives.
- **Both authenticated:** you are prompted to choose which drives.

In silent/unattended mode (`--silent`) the installer never installs or authenticates — it only verifies that a suitable CLI is ready and uses it.

If a step fails during an interactive run, the installer offers `[R]etry / [S]kip / [A]bort` so you can recover without restarting from scratch. Package selections are saved to the resume state, so a re-run after failure restores your previous choices without re-prompting the wizard. Pass `--fresh` to discard saved state and restart cleanly.

## Installer Configuration

### CLI flags

`util/quick-install.sh` accepts flags directly. Run `util/quick-install.sh --help` for the full reference. Key flags:

| Flag | Effect |
| --- | --- |
| `-h, --help` | Print help and exit |
| `-s, --silent[=claude\|codex], --non-interactive` | Unattended AI install (requires an already-authenticated CLI); optionally pin the driver |
| `--print-runbook` | Print the AI runbook for the resolved plan, then exit |
| `-y, --yes` | Skip the confirm screen; proceed once the plan is resolved |
| `--fresh` | Ignore saved resume state; start a clean run |
| `--only=IDS` | Run only the listed step ids (comma-separated) |
| `--skip=IDS` | Skip the listed step ids |
| `--packages=SEL` | Install only the listed package groups or items |
| `--skip-packages=SEL` | Skip the listed package groups or items |
| `--no-fonts` | Skip Nerd Fonts (same as `NO_FONTS=1`) |
| `--https` | Clone via HTTPS (same as `USE_HTTPS=1`) |
| `--state-file=PATH` | Override the resume-state file path |
| `--list-steps` | Print all step ids with labels and defaults, then exit |
| `--list-packages` | Print package groups and per-OS members, then exit |
| `--version` | Print installer version and exit |

`--only` and `--skip` are mutually exclusive, as are `--packages` and `--skip-packages`.

#### Silent / unattended mode

`--silent` (or `-s`, or `QUICK_INSTALL_SILENT=1`) runs unattended without the wizard. It assumes Claude Code and/or Codex are **already installed and authenticated** — it never installs or logs in during a silent run.

- **`--silent`** (bare): tries Claude Code first; if unavailable or unauthenticated, falls back to Codex. If neither is ready, exits with an error.
- **`--silent=claude`**: uses Claude Code exclusively; fails immediately if it is not installed and authenticated.
- **`--silent=codex`**: uses Codex exclusively; fails immediately if it is not installed and authenticated.

In bare `--silent` mode, if the first agent's run fails, the installer retries with the other authenticated candidate using the same idempotent runbook.

Running with no terminal and without `--silent` is always an error — the installer exits with guidance rather than silently guessing at a mode.

#### Sudo handling

- **Interactive:** the installer runs `sudo -v` once (prompting via the terminal) and keeps the credential alive in the background so the agent does not need to re-prompt mid-run.
- **Silent / unattended:** no sudo prompt is possible. Rely on cached credentials or passwordless sudo. On Linux, unattended installs that require root (e.g. changing the default shell) need passwordless sudo configured.

#### `--print-runbook`

Prints the runbook the installer would hand to the agent for the resolved plan, then exits — useful for inspecting or auditing what the agent will do before committing to a run.

**Package selection syntax (`SEL`):** comma-separated group names (e.g. `dev-tools`) or `group:item` for a single package (e.g. `media:ffmpeg`). Available groups:

| Group | Contents |
| --- | --- |
| `core-utils` | Core CLI utilities (bash, coreutils, grep, gawk, sed, tar, …) |
| `shell` | Shell packages (fish, zsh) |
| `dev-tools` | Developer tools and build (git, vim, gcc, clang, build-essential) |
| `languages` | Languages and runtimes (node, python, ruby) |
| `media` | Media tools (ffmpeg, imagemagick, yt-dlp) |
| `network` | Network and transfer (wget, rclone, gnutls, heroku, ssh-copy-id) |
| `system` | System and disk tools (smartmontools) |

**Examples:**

```bash
# Unattended AI install using whichever CLI is authenticated, skip Nerd Fonts
util/quick-install.sh --silent --no-fonts

# Pin to Claude Code for an unattended run
util/quick-install.sh --silent=claude

# Install only the repo clone and OS packages steps
util/quick-install.sh --only=prepare_and_clone_repo,install_os_packages

# Unattended install with a specific package subset driven by Codex
util/quick-install.sh --silent=codex --packages=core-utils,shell,network --no-fonts

# Preview the runbook before running
util/quick-install.sh --print-runbook

# See what steps are available
util/quick-install.sh --list-steps

# See package groups and per-OS members
util/quick-install.sh --list-packages
```

### Precedence

When the same setting is specified in more than one place, the order of precedence is (highest wins):

```
flags  >  environment variables  >  wizard selections  >  built-in defaults
```

### Environment variables

All existing env vars are still honored. Flags take precedence over them.

- `USE_HTTPS=1`: clone the repo via HTTPS instead of SSH
- `NO_FONTS=1`: skip Nerd Fonts installation
- `PF=/custom/path`: change the target installation path from the default `~/.leos-profiles`
- `QUICK_INSTALL_STATE_FILE=/custom/file`: override the resume state file path
- `QUICK_INSTALL_SILENT=1`: same as bare `--silent` — unattended AI install with Claude-then-Codex fallback

The script also applies a restrictive `umask` to avoid Fish completion permission issues and writes a resume-state file after each step.

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

### Verify installer package availability

This script checks that packages referenced by the quick installer exist in official/default repositories.

Example:

```bash
python3 util/verify-quick-install-packages.py
```

Useful options:

- `--script`: point to a different installer script to parse
- `--json`: emit machine-readable JSON instead of plain text
- `--markdown-out`: choose where to write the Markdown report

By default it writes `verify-quick-install-packages-report.md`.

This verification script:

- uses only the Python standard library
- performs live network checks against package sources
- may require a local `zstd`, `unzstd`, or `zstdcat` binary to inspect Fedora metadata

## Manual Installation

If you do not want to use the full bootstrap flow, a minimal manual setup usually looks like this:

1. Clone the repository to `~/.leos-profiles`.
2. Install Fish and any package-manager dependencies you care about.
3. Add the Fish startup snippet shown above to `~/.config/fish/config.fish`.
4. Optionally run selected utilities directly from `util/`.

## Development Notes

- The top-level [`quick-install.sh`](./quick-install.sh) is intentionally small and delegates to [`util/quick-install.sh`](./util/quick-install.sh).
- The verification script parses package names directly from the installer implementation so the report stays aligned with the actual bootstrap logic.
- This repository appears to be an actively reorganized personal dotfiles/workstation repo, so paths may evolve over time. The current layout is reflected in this README.

## Troubleshooting

- If remote bootstrap fails during SSH cloning, rerun with `USE_HTTPS=1` or pass `--https`.
- If Fish reports missing tools such as `pyenv` or `rbenv`, the profile can silence those warnings with marker files like `~/.lp-nopyenv` and `~/.lp-norbenv`.
- If a quick-install run is interrupted, rerun the installer and it will pick up where the AI agent left off — prereq steps are idempotent and already-done steps are skipped. In an interactive terminal each failing prereq step also offers `[R]etry / [S]kip / [A]bort` inline.
- To discard a saved partial run and start over, pass `--fresh`.
- If Nerd Fonts are not wanted or you are running on a headless machine, use `NO_FONTS=1` or pass `--no-fonts`.
- In CI or unattended environments, use `--silent[=claude|codex]`. A run with no terminal and no `--silent` flag is always an error — the installer will print guidance and exit rather than guessing at a mode. The `--silent` mode requires Claude Code or Codex to already be installed and authenticated.
- If a silent run fails because neither CLI is authenticated, authenticate Claude Code (`claude auth login`) or Codex (`codex login`) on an interactive terminal first, then re-run with `--silent`.
- On Linux, unattended (`--silent`) runs that require root (e.g. changing the default shell) need passwordless or pre-cached sudo since the installer cannot prompt for a password.

## License

This project is licensed under the GNU General Public License v3.0. See [`LICENSE`](./LICENSE) for the full text.
