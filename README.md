# Leo's Profiles

Leo's Profiles sets up a Zsh workstation on macOS or Linux: the packages and
developer tools, the newest Node, Python and Ruby, a Zsh configuration with
plugins and the Starship prompt, and a handful of maintenance commands. One
command asks a few questions, shows you the complete plan, and applies it once
you approve. Afterwards, one command keeps it all up to date.

## Install

On the machine to set up, in a terminal:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/bootstrap.sh)"
```

[`bootstrap.sh`](./bootstrap.sh) installs Git if needed (on macOS through
Apple's Command Line Tools installer), clones this repository into
`~/.leos-profiles` (or `$LEOS_PROFILES_HOME`), and starts the setup wizard,
`bash ~/.leos-profiles/install.sh setup`. Run again later, it fast-forwards a
clean checkout instead; it refuses one with local changes.

Stay at the keyboard: sudo asks for your password once, near the start, and
any GitHub steps you choose wait for you.

### What the wizard asks

1. **Recommended** or **Customize** (and, once you have set up, **the saved
   choices**).
2. Customize only: which components and package groups, the Nerd Font, the
   full package upgrade, Homebrew cask upgrades (macOS), the login shell, and
   the minimum release age (7 days).
3. Whether to set up an SSH key for GitHub and GPG commit signing. Both
   default to **Skip**; you can reuse a key it finds or generate one.
4. Your Git name and email, only for GPG signing and only if Git has none.
5. If you already have a `~/.rbenv` the profile does not manage: keep it (and
   skip the rbenv component) or stop so you can move it.

The saved choices skip straight to whether to run the full upgrade.

Then it shows the plan: packages, runtimes, where each tool comes from,
everything that runs as root, what cannot be undone, files it touches, and
each component as "to do" or "done". One confirmation applies exactly that.
`bash ~/.leos-profiles/install.sh setup --dry-run` shows the same plan and
changes nothing.

### What Recommended does to your machine

- **Upgrades every installed package** (Homebrew, apt, dnf or pacman), within
  your current OS release. It never moves you to a new release.
- **Installs packages**: GNU core utilities, zsh, git, gh, jq, ripgrep, fd,
  fzf, bat, eza (not on Debian or Ubuntu), direnv, zoxide, a compiler
  toolchain, ffmpeg, ImageMagick, wget, rclone, smartmontools and friends.
- **Installs runtimes from version managers, never the system's**: the newest
  Node LTS (fnm), the newest Python (uv, as `python3` in `~/.local/bin`), the
  newest Ruby (rbenv, compiled from source), plus pnpm and Yarn through
  Corepack. Bun and uv come along too.
- **Configures Zsh**: adds small marked blocks to `.zshrc` and `.zshenv` (and
  `.zprofile` on macOS) that load this profile, installs the plugins
  (autosuggestions, syntax highlighting, completions, fzf-tab), Starship and,
  on a desktop, a Nerd Font for the prompt icons.
- **Makes zsh your login shell** if it is not already.

Tools come from upstream, but only releases that have been public for at
least 7 days, so a broken or compromised release has time to be pulled.
Compiling Ruby takes several minutes on its own; a first run can take a while.

When it finishes, open a new terminal and set its font to the Nerd Font
(JetBrainsMono by default). Under WSL, install the font on Windows too.

### Unattended, Codespaces and dev containers

`bash install.sh apply --yes` installs Recommended without asking; options
pick another selection (`bash install.sh --help`). Without a terminal it
cannot type a sudo password, so it needs passwordless sudo; otherwise it stops
before changing anything (exit 3) and prints the command to run yourself.

`install.sh` with no arguments runs the wizard at a terminal. In GitHub
Codespaces or a dev container without one, it installs a lean profile (the Zsh
configuration, plugins and Starship; no upgrade, fonts, login shell or keys),
so this repository works as your Codespaces dotfiles repository as it is.

## Supported platforms

- macOS 15 and later on Apple silicon (Homebrew's
  [Tier 1](https://docs.brew.sh/Support-Tiers)). macOS 14 and Intel Macs get a
  warning: Homebrew no longer publishes bottles there, so builds take hours or
  fail.
- Ubuntu 22.04, 24.04 and 26.04 LTS, on x86_64 and arm64.
- Debian 12 and 13, on x86_64 and arm64.
- Fedora 44 and 45, on x86_64 and aarch64.
- Arch Linux on x86_64 (Arch Linux ARM on a best-effort basis).
- WSL, best effort, when its distribution is one of the above.

CI provisions each Linux release in real containers and macOS 15 and 26 on
hosted runners; see [docs/development.md](./docs/development.md#ci-layout).

## Day to day

| Task | Command |
| --- | --- |
| Update the profile and repair anything missing | `upgrade-leos-profiles` |
| ...and also upgrade packages, tools and runtimes | `upgrade-leos-profiles --full-upgrade` |
| Check the setup without changing anything | `leos-doctor` |
| Repair without pulling | `bash ~/.leos-profiles/install.sh reconcile --yes` |
| See the plan for your saved setup (as TSV) | `bash ~/.leos-profiles/install.sh inspect --saved` |
| Change your choices | `bash ~/.leos-profiles/install.sh setup` (Customize) |

`upgrade-leos-profiles` fetches the checkout's upstream, lists the incoming
commits and asks before fast-forwarding, because those commits then run with
sudo. Add `--yes` to skip the question (required without a terminal) and
`--verify-signatures` to accept only signed commits Git can verify. Without
`--full-upgrade` installed versions stay where they are; with it, packages
are upgraded and every tool, plugin and runtime moves to its newest release
that is old enough.

The release age (7 days by default) is saved with your choices. Change it in
the wizard's Customize, or with `--min-release-age <days>` (0 to 365) on
`setup` or `apply`.

## Customizing

Put your own settings in the checkout's `local/` directory, which Git ignores:

- `local/private.zsh` loads after the profile's commands, before plugins and
  the prompt: environment variables, PATH additions, aliases.
- `local/private-interactive.zsh` loads last, after completion, plugins and
  the prompt: `compdef`, key bindings, widget overrides.

While these files load they can use `puts` and `puts-err` (print a message),
`add-path <dir>` (prepend to PATH if it exists and is not there yet) and
`entry <name>` (load `zsh/<name>.zsh`). Those helpers are removed afterwards,
so a function you define that runs later should use `print` instead. Keep both
files private (`chmod 600`); the shell warns otherwise.

Settings you can put in `local/private.zsh` (or the environment):

| Setting | Effect |
| --- | --- |
| `LEOS_DISABLE_ALIASES=1` | No `ls`, `cat` or `grep` wrappers (or `unfunction ls` to drop one) |
| `LEOS_PLAIN_PROMPT=1` | The plain ASCII prompt, no Nerd Font needed (automatic on the Linux console) |
| `STARSHIP_CONFIG=<file>` | Your own Starship configuration instead of the profile's |
| `LEOS_ENABLE_ITERM2_INTEGRATION=1` | Load iTerm2's shell integration, if you installed it |
| `LEOS_WARN_OPTIONAL_TOOLS=1` | Warn when rbenv is missing |

Tools the installer does not provide (Flutter, the Google Cloud SDK) are
yours to wire up, for example:

```zsh
# local/private.zsh
add-path "$HOME/.flutter/bin"
```

## What the shell changes

- `ls` runs eza when the output is a terminal and the options mean the same
  to both; anything else (`ls -ltr`, a pipe) gets the real `ls`. `cat` runs
  bat for a terminal and no options. `grep` adds `--color=auto`. Man pages use
  bat unless you set `MANPAGER`.
- `z <words>` jumps to the best-matching directory you have visited, `zi`
  picks one interactively (zoxide); `cd` is unchanged.
- Emacs key bindings (even if `EDITOR` is vim). Home, End, Delete and
  Ctrl-Left/Right work; Up/Down search history for what you have typed.
  Ctrl-R, Ctrl-T and Alt-C are fzf's history, file and directory pickers; Tab
  completion opens fzf-tab's menu.
- `AUTO_CD` (type a directory name to go there), case-insensitive completion
  and globbing. Extended globbing is on, but `^` and `#` are not glob
  operators, so `git reset HEAD^` and `nix run nixpkgs#hello` work unquoted.
- History is shared between shells, deduplicated, 100,000 lines, in
  `${ZDOTDIR:-~}/.zsh_history`.
- The prompt shows your user name, with `@host` over SSH, in red for root.
- Scripts and `ssh host cmd` (non-interactive shells) see `~/.local/bin`, the
  Corepack shims and fnm's default Node, but not Homebrew or rbenv.

## Commands

`leos-help` prints this list in the shell.

| Command | What it does |
| --- | --- |
| `upgrade-leos-profiles` | Pull the profile and reconcile your saved setup (`--full-upgrade`, `--yes`, `--verify-signatures`) |
| `leos-doctor` | Check the saved setup without changing anything, and say how to repair |
| `leos-refresh-init-cache` | Drop the cached tool init scripts and recompile the profile; the checkups run it for you |
| `leos-help` | List these commands |
| `bye` | Run the package checkups and `ai-checkup`, sweep macOS metadata and restart Finder, Dock and SystemUIServer, then exit. `--no-exit` stays; `--wipe-history` also clears history (`--aggressive-history` more of it); `--non-interactive`, `--purge-recycle-bins`, `--shutdown-wsl` |
| `brew-checkup` | `brew update`, upgrade formulae and casks, `brew cleanup` |
| `apt-checkup` | apt update, upgrade, autoremove and clean (sudo) |
| `dnf-checkup` | dnf upgrade, autoremove and clean (sudo) |
| `pacman-checkup` | `pacman -Syu`, remove orphans, clean the cache (sudo) |
| `ai-checkup` | Update installed AI CLIs: Claude Code, Codex, and opencode unless Homebrew manages it |
| `clear-history` | Delete shell and REPL history files (`--aggressive` adds more, such as completion dumps) |
| `rmdsstore` | macOS: delete `.DS_Store`, `Thumbs.db` and `desktop.ini` files across the data volume and mounted volumes, or under the given roots (sudo; `--dry-run`, `--purge-recycle-bins`) |
| `mkcdir <dir>` | Make a directory and `cd` into it |
| `hidden-on`, `hidden-off` | macOS: show or hide hidden files in Finder |
| `enable-gnu`, `disable-gnu` | macOS: put GNU coreutils, sed, grep and friends ahead of the BSD tools, or not (next shell) |
| `brew-china-enable`, `brew-china-disable` | Use the USTC Homebrew mirror (asks first, or `--yes`), or go back to the official one |
| `gui-start`, `gui-stop` | Linux: start or stop the display manager (gdm, sddm or lightdm) |
| `gui-enable`, `gui-disable` | Linux: boot to the desktop or to text mode, and start or stop it now |

The checkups only exist where their package manager is installed.

## Uninstall

1. `bash ~/.leos-profiles/install.sh remove-blocks` (add `--dry-run` to
   preview) removes the profile's blocks from your zsh startup files and
   leaves the rest of them alone. Open a new shell.
2. `bash ~/.leos-profiles/install.sh inventory` lists everything the installer
   created or manages, with paths: tools in `~/.local/bin`, the npm prefix,
   plugin checkouts, `~/.rbenv`, fonts, the init cache, `local/`, and the
   global Git settings it may have written. Delete what you no longer want,
   then the checkout itself.
3. By hand, if you want them back: your login shell (`chsh -s /bin/bash`, or
   whatever you used), the zsh line it may have added to `/etc/shells`, the
   global Git identity and signing settings, and SSH or GPG keys on GitHub.
   Packages stay installed: they may be shared, and upgrades cannot be undone.

## Troubleshooting

- **Exit status 3** means something needs you. In the wizard, choosing "Stop
  here" ends with a checklist; do the steps, then run setup again and pick the
  saved choices. Elsewhere, follow the printed `manual-action` lines (or the
  `run-in-terminal` command) and run `install.sh reconcile --yes`.
- **GitHub rate limits**: release lookups use GitHub's API, which allows 60
  anonymous requests an hour. Log in with `gh auth login` or export
  `GITHUB_TOKEN`. A tool that is already installed is kept when GitHub cannot
  be reached.
- **sudo prompts**: setup asks once and keeps the login alive through the Ruby
  compile. Some Homebrew cask installers ask on their own, which is why cask
  upgrades are opt-in.
- **Fedora**: the media group enables RPM Fusion (free) for the full ffmpeg.
  Leave `media` out in Customize if you do not want that repository.
- **Behind a proxy**: the proxy variables are kept through sudo;
  `FNM_NODE_DIST_MIRROR` serves Node downloads, and on macOS
  `--brew-mirror china` uses the USTC Homebrew mirror.
- **A Ruby compile failed**: the run warns and carries on; the next full
  upgrade tries again.
- **oh-my-zsh, powerlevel10k, nvm, asdf or mise** already set up: the plan
  lists them. They keep working, but prompts, completions and version managers
  overlap; keep one of each (details in
  [docs/development.md](./docs/development.md#existing-setups)).

## Development

[docs/development.md](./docs/development.md) explains how the installer works
and why it is built this way, the plan format, the tests and CI.
[AGENTS.md](./AGENTS.md) has the rules and checks in short.

## License

GPL-3.0; see [LICENSE](./LICENSE).
