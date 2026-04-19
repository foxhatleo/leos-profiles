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

The quick installer can:

- clone the repo into `~/.leos-profiles`
- install a curated package set for the current OS
- install local helper binaries
- set up `pyenv` and `rbenv`
- install `bun` and global `yarn`
- install the latest Node.js LTS with `nvm.fish`
- install Fish plugins and configure the Tide prompt
- write `~/.config/fish/config.fish`
- optionally install Nerd Fonts on desktop systems
- optionally switch the default shell to Fish

### Utility scripts

- [`util/rmdsstore.py`](./util/rmdsstore.py): recursively removes `.DS_Store`, `Thumbs.db`, `desktop.ini`, and `$RECYCLE.BIN` artifacts
- [`util/verify-quick-install-packages.py`](./util/verify-quick-install-packages.py): checks whether packages referenced by the installer exist in official/default package sources across supported platforms
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

The installer is step-based and records progress in `~/.leos-profiles/quick-install.state` so an interrupted run can resume from the failed step.

Default step flow:

1. Prepare and clone repo
2. Install local bins
3. Install OS packages
4. Install `pyenv`
5. Install `rbenv`
6. Install `bun`
7. Install `yarn`
8. Install latest Node.js LTS with `nvm`
9. Set up Fish plugins and prompt
10. Install Nerd Fonts when appropriate
11. Write Fish config
12. Set default shell to Fish

In an interactive terminal, the script prompts you step-by-step so you can skip pieces you do not want.

## Installer Configuration

The installer recognizes a few useful environment variables:

- `USE_HTTPS=1`: clone the repo via HTTPS instead of SSH
- `NO_FONTS=1`: skip Nerd Fonts installation
- `PF=/custom/path`: change the target installation path from the default `~/.leos-profiles`
- `QUICK_INSTALL_STATE_FILE=/custom/file`: override the resume state file path

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

- If remote bootstrap fails during SSH cloning, rerun with `USE_HTTPS=1`.
- If Fish reports missing tools such as `pyenv` or `rbenv`, the profile can silence those warnings with marker files like `~/.lp-nopyenv` and `~/.lp-norbenv`.
- If a quick-install run is interrupted, rerun the installer and it should offer to continue from the failed step.
- If Nerd Fonts are not wanted or you are running on a headless machine, use `NO_FONTS=1`.

## License

This project is licensed under the GNU General Public License v3.0. See [`LICENSE`](./LICENSE) for the full text.
