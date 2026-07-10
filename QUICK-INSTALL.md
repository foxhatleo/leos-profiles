# Leo's Profiles — AI-guided installation runbook

This document is for an AI coding agent. It keeps the convenient AI-led setup,
but the agent must execute the deterministic [`install.sh`](./install.sh)
driver rather than reimplement provisioning from prose.

## Non-negotiable trust rules

1. **Require a reviewed release reference first.** Ask the human for a GitHub
   release tag or full 40-character commit hash (`REF`). Resolve a tag to its
   commit, show the resulting full hash, and use that exact hash everywhere.
   Do not fetch or execute `master`, `main`, `HEAD`, or any mutable raw URL.
2. **Use only the release-pinned driver.** Download or clone `install.sh` and
   `installer/lock.sh` at `$REF`, then run the driver with `--ref "$REF"`.
   Never replace its locked sources with a curl-pipe-shell command or a newer
   upstream branch.
3. **Ask every decision before mutation.** Do not ask for per-command approval
   after that plan is accepted, but do not infer credential, font, package, or
   destructive-maintenance choices.
4. **Do not improvise recovery.** The driver distinguishes a valid target,
   repairable target, and a conflicting target. Show its error to the human;
   use `--repair` only after they explicitly approve the clean checkout state.
5. **Stay within scope.** The approved scope is the selected profile target,
   managed Zsh blocks, selected packages, and explicit credential/default-shell
   choices. Do not alter unrelated configuration.
6. **Obtain the required execution scope.** The accepted plan necessarily
   writes outside the checkout (`~/.zshrc`, `~/.zshenv`, user tool directories,
   package-manager state, and possibly the login shell). Ask for the terminal
   or filesystem permission needed for that exact plan; do not claim the setup
   can succeed inside a project-only sandbox.

## Ask these decisions in one batch

- Release reference: a reviewed tag or full commit hash. Resolve tags to the
  full commit and show it back.
- Target directory: use `~/.leos-profiles` without adding a question unless the
  human has already requested another absolute path. The profile remains
  relocatable; this is only the provisioning default.
- Steps and package groups: default all except the optional `bins` (`rpatool`)
  step. Explain that the full package step upgrades the operating system and,
  for selected Fedora media packages, enables RPM Fusion.
- Git identity: only if missing and GPG signing was selected.
- SSH: skip, reuse one explicitly named private key, or generate a new
  ed25519 key and add it to GitHub. For a new key ask whether it should use
  Leo's empty-passphrase default or an interactive passphrase.
- GPG: skip, reuse a matching secret key, or generate one. For a new key ask
  whether it should use Leo's empty-passphrase default or an interactive
  passphrase. Reuse requires the exact fingerprint (`--gpg-key`); show
  `gpg --list-secret-keys --keyid-format=long` if the human needs to choose.
- Fonts: auto (the default: install `JetBrainsMono` on a desktop, skip on a
  headless Linux host), no, or install one named Nerd Font.
- Default shell: no, yes, or auto (change only when the login shell is not
  already Zsh).

Tell the human that `bye` is a separate full cleanup/optimization command; it
is not run during installation.

## Bootstrap the driver

If Git is available, use a temporary checkout:

```bash
work="$(mktemp -d)"
git clone https://github.com/foxhatleo/leos-profiles.git "$work/leos-profiles"
git -C "$work/leos-profiles" checkout --detach "$REF"
driver="$work/leos-profiles/install.sh"
bash "$driver" --ref "$REF" --target "$HOME/.leos-profiles" --plan
```

If Git is not available, download only these two immutable-ref files into a
temporary directory, then let `install.sh` bootstrap Git and clone the target:

```bash
work="$(mktemp -d)"
mkdir -p "$work/installer"
curl --fail --location --proto '=https' --tlsv1.2 \
  "https://raw.githubusercontent.com/foxhatleo/leos-profiles/$REF/install.sh" \
  -o "$work/install.sh"
curl --fail --location --proto '=https' --tlsv1.2 \
  "https://raw.githubusercontent.com/foxhatleo/leos-profiles/$REF/installer/lock.sh" \
  -o "$work/installer/lock.sh"
driver="$work/install.sh"
bash "$driver" --ref "$REF" --target "$HOME/.leos-profiles" --plan
```

For a tag, resolve `$REF` to a full commit before either path. A signed GitHub
release is the preferred human-facing distribution mechanism.

## Apply the approved plan

Translate the decisions into flags, run `--plan`, show its output, then run the
same command with `--yes`. Example:

```bash
bash "$driver" --ref "$REF" --target "$HOME/.leos-profiles" --yes \
  --ssh generate --ssh-passphrase empty --gpg generate --gpg-passphrase empty \
  --fonts yes --font JetBrainsMono --default-shell yes
```

For a reused SSH key, include `--ssh reuse --ssh-key /absolute/path/to/key`.
For reused GPG, include `--gpg reuse --gpg-key <fingerprint>`. Include
`--git-name` only when global `user.name` is missing and `--git-email` only
when global `user.email` is missing. If SSH or GPG was selected, authenticate
`gh` when the driver requests it; do not silently continue without GitHub
verification. GitHub CLI initially authenticates over HTTPS so it cannot
silently select a different SSH key; the driver tests the exact chosen key
before switching GitHub's Git protocol to SSH.

The driver prints every mutation, verifies locked downloads, uses a state file
under `${XDG_STATE_HOME:-$HOME/.local/state}/leos-profiles`, and fails on incomplete
or conflicting targets instead of treating them as complete. A state row is
only a resume hint: its input signature and the installed result are both
verified before a step is skipped.

After success, tell the human to restart their terminal. A default-shell
change applies at the next login. Confirm that the themed Starship prompt is
active unless the human explicitly set `LEOS_PLAIN_PROMPT=1`. The first managed
write preserves existing Zsh files as `.leos-profiles.bak`; point the human to
the README rollback section. Keep the temporary checkout only if it is useful
for auditing; otherwise remove it.
