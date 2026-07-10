# Leo's Profiles

Leo's Profiles is a portable, Zsh-centred workstation profile for macOS,
Debian/Ubuntu, Fedora, and Arch Linux. It combines a relocatable interactive
shell setup with a deterministic provisioning driver for a new machine.

It is intentionally a **power-user setup**. A full installation can install
packages, upgrade the host, configure Git credentials, change the login shell,
and write managed blocks to `~/.zshrc` and `~/.zshenv`. Read the plan before
applying it.

## Trust and installation model

The AI runbook remains the recommended front door, but it delegates machine
changes to [`install.sh`](./install.sh). The driver is versioned, prints one
complete plan before mutation, records state atomically, and validates existing
profile checkouts before it repairs them.

Do not give an agent a mutable `master` URL and ask it to execute it. Start
from a GitHub release or another reviewed **full 40-character commit hash**.
The corresponding release's `QUICK-INSTALL.md` gives an agent-safe procedure.
It downloads only `install.sh` and `installer/lock.sh` at that immutable ref,
then the driver checks out the same ref for the profile.

The lock file pins every direct third-party executable source used by the
driver: Git dependencies are checked out at fixed commits; script/archive
downloads are SHA-256 verified. OS packages remain governed by the selected
package manager. A direct-source digest mismatch fails closed. Updating a
locked dependency is a reviewed repository change, not an incidental
install-time update.

## Quick start

Pick a reviewed release commit, set it as `REF`, and have the agent follow the
release copy of [`QUICK-INSTALL.md`](./QUICK-INSTALL.md). The core command is:

```bash
bash install.sh --ref "$REF" --target "$HOME/.leos-profiles" --plan
```

After reviewing the resolved plan, run the same command with `--yes` and the
choices you made up front. Typical optional choices are:

```bash
bash install.sh --ref "$REF" --target "$HOME/.leos-profiles" --yes \
  --ssh generate --gpg generate --gpg-passphrase empty \
  --fonts yes --font JetBrainsMono --default-shell yes
```

`--ssh reuse` requires an explicit `--ssh-key /path/to/private-key`; the
installer never picks an arbitrary key. New SSH keys support
`--ssh-passphrase empty|prompt`. GPG provisioning requires an existing Git
identity or `--git-name` and `--git-email`; new GPG keys support an empty
passphrase (the historic Leo default) or an interactive passphrase.

The installer defaults to all package groups and includes full package-manager
upgrades. This is intentional. Use `--steps`, `--package-groups`, and
`--plan` to narrow scope. `--dry-run` performs no mutation. Re-run with
`--repair` only after reviewing an existing, clean target checkout.

## What is installed

The package groups are `core-utils`, `shell`, `dev-tools`, `languages`,
`media`, `network`, and `system`. Their exact package names are resolved in
`install.sh` for the selected OS; there is no second hand-maintained package
table in the documentation.

The optional profile components include pyenv, rbenv + ruby-build, Bun, fnm +
Node LTS, Yarn, pnpm, Starship, and four Zsh plugins. Bun, fnm, Starship, and
the plugins are installed from locked releases/commits. `rpatool` remains
available through the explicit `bins` step, but is not selected by default
because its upstream has no stable release artifact. On Debian and Fedora,
`eza` is not forced from an unreviewed third-party repository; the shell uses
the normal `ls` fallback when it is unavailable.

Nerd Fonts are not bulk-installed. Select a named font with
`--fonts yes --font <name>` when you want the complete themed prompt. The
established themed prompt remains the default; terminals without Nerd Font
support can opt into the readable ASCII fallback by setting
`LEOS_PLAIN_PROMPT=1`, which uses
[`zsh/starship-plain.toml`](./zsh/starship-plain.toml).

## Zsh profile

The profile root is derived from the sourced `zsh/start.zsh` file and can be
overridden with `LEOS_PROFILES_HOME`. `~/.leos-profiles` is only the installer
default. The installer writes replaceable managed blocks, preserving the rest
of the user's Zsh files.

For a manual setup, source the profile only from interactive `~/.zshrc`:

```zsh
if [[ -o interactive ]]; then
  source "${LEOS_PROFILES_HOME:-$HOME/.leos-profiles}/zsh/start.zsh"
fi
```

`~/.zshenv` should put `~/.local/bin` and `~/.local/npm/bin` on `PATH` for
non-interactive Zsh invocations. The installer manages this block for you.

Optional tool warnings are off by default; set `LEOS_WARN_OPTIONAL_TOOLS=1` to
see missing pyenv/rbenv warnings. iTerm2 integration is also opt-in: install it
through iTerm2, then set `LEOS_ENABLE_ITERM2_INTEGRATION=1` to source its local
file. Private profile additions may live in ignored `zsh/_private.zsh`.

## Maintenance commands

- `bye [--keep-history] [--non-interactive] [--no-exit]` runs Leo's full
  maintenance routine. It authenticates sudo, updates the active package
  manager and AI CLIs, clears history unless retained, and on macOS performs a
  privileged metadata sweep before restarting Finder, Dock, and SystemUIServer.
  It is intentionally not a simple alias for `exit`.
- `rmdsstore [--dry-run] [root ...]` cleans metadata. With no root it scans the
  standard macOS data-volume roots; it does not run on non-macOS systems. The
  underlying utility rejects invalid roots, does not cross mounted filesystems,
  reports failures, and supports dry-run.
- `upgrade-leos-profiles` updates only a normal branch checkout with
  `--ff-only`. A release-pinned checkout must be upgraded through a reviewed
  new ref using `install.sh --repair`.
- `gui-enable`, `gui-disable`, `gui-start`, and `gui-stop` require systemd and
  detect `gdm3`, `gdm`, `sddm`, or `lightdm` rather than assuming one distro.

## Static hosts list

[`res/adblock-hosts`](./res/adblock-hosts) is a vendored convenience list. It
is not automatically applied, updated, or represented as a curated security
feed. Before using it in a system hosts file, review it for your network and
keep a backup of the original file.

## Supported platforms and limits

The provisioning driver supports macOS via Homebrew, Debian/Ubuntu via apt,
Fedora via dnf, and Arch via pacman, on x86_64 and arm64/aarch64 where a locked
release asset exists. Linux package operations use `sudo`; macOS Homebrew may
also request privileged access during its own setup. Windows is not supported
as a host OS; WSL is only supported to the extent that its Linux distribution
matches the supported package-manager rules.

No installer can make a package-manager upgrade reversible. Keep backups and
use `--plan` before applying the full default selection on a machine with
important state.

## Development and validation

Run the local checks before publishing a release:

```bash
zsh -n zsh/*.zsh zsh/path/*.zsh
bash -n install.sh installer/lock.sh tests/install-test.sh
bash tests/install-test.sh
python3 -m py_compile util/rmdsstore.py
python3 tests/rmdsstore_test.py
```

CI additionally validates the Starship TOML and installer blocks. The project
is licensed under GPL-3.0; see [`LICENSE`](./LICENSE).
