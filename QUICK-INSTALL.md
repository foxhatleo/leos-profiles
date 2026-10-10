# Leo's Profiles: AI-assisted setup (optional)

You do not need an AI to install Leo's Profiles. The supported path is the
setup wizard in your own terminal (see the README's "Start here"):

```bash
git clone https://github.com/foxhatleo/leos-profiles.git ~/.leos-profiles
~/.leos-profiles/install.sh setup
```

If you would like an assistant (Claude Code, Codex, or any agent that can run
shell commands) to look at the machine first, explain the choices and the
plan in plain language, and then give you the exact command, give it this
file. The assistant never runs the installation itself: sudo, Homebrew's
installer, `chsh` and key passphrases need your terminal.

---

## Instructions for the assistant

You are helping the user set up Leo's Profiles. The shell installer in the
checkout is a deterministic engine; you inspect, explain and advise, and the
user runs every command that changes the machine in their own terminal.

### Rules

1. You may run read-only commands: `bash ~/.leos-profiles/install.sh inspect
   …` (with or without options), `inspect --saved`, `inventory`, `--help`, and
   `git clone` of the checkout (ask first). Never run `apply`, `reconcile`,
   `setup` or `remove-blocks` yourself: without a terminal they cannot ask for
   passwords or passphrases (apply stops with a `run-in-terminal` manual
   action and exit 3, having changed nothing).
2. Ask for the user's choices in whatever interface you have: select boxes,
   a numbered list, or plain questions. Use the engine's flag values; `none`
   means an empty component or package-group selection.
3. Never pick an SSH or GPG key for the user, never upload keys, log in to
   GitHub, or change SSH settings on their behalf.
4. Hand over one exact command (below), then help interpret its output.

### 1. Get the checkout

Use `~/.leos-profiles`; an existing checkout there is used in place (do not
pull during setup). Stop on an unrecognised existing directory. If Git is
missing, install it with the OS's own tools first:

```bash
# macOS: complete the Command Line Tools installation it opens, then retry
xcode-select --install

# Debian or Ubuntu
sudo apt-get update && sudo apt-get install -y git curl ca-certificates

# Fedora
sudo dnf install -y git curl ca-certificates

# Arch Linux
sudo pacman -Syu --needed --noconfirm git curl ca-certificates
```

These need the user's password: give them to the user to run.

### 2. Inspect and explain

Run `bash ~/.leos-profiles/install.sh inspect` (the Recommended plan), or
`inspect --saved` when `~/.leos-profiles/local/install-profile.tsv` exists
(a saved setup: suggest reconciling it). The output is tab-separated
records. Read them by their first column and keep empty columns; never treat
other output as records. Every record type is listed in
[docs/development.md](./docs/development.md#state-and-tsv-contract). Explain
in plain language, in particular:

- `warning`: an unsupported Mac (Intel, or macOS before 15) builds from
  source or fails; a missing locked build for this platform.
- `conflict`: an existing `~/.pyenv` or `~/.rbenv` that is not the pinned
  checkout. Apply stops on it unless the user keeps it with
  `--skip-existing-version-managers` (that component is then skipped).
  `homebrew-install` is informational.
- `existing` (oh-my-zsh, powerlevel10k, nvm, conda, asdf, mise) and
  `shadow` (Homebrew copies the pinned tools will shadow): what coexists and
  how; the README's "Existing setups" has the details.
- `group` (selected and implied), `package`, `artifact`, `file`, `global`,
  `action`, `privileged` (runs as root), `irreversible`, `behaviour`,
  `migration`, `runtime` (the Node version) and `postcondition` (already
  verified or still needed).

### 3. Ask the choices

Recommended (the default) selects every component except `bins` (rpatool),
every package group except `python` and `heroku`, a full in-release host
upgrade, no SSH/GPG keys or signing, and fonts and default shell on `auto`.
Customize covers:

- Components (`--groups`): `packages`, `bins`, `pyenv`, `rbenv`, `bun`,
  `fnm`, `yarn`, `pnpm`, `uv`, `plugins`, `fonts`, `zsh-config`,
  `default-shell`. Package groups (`--package-groups`): `core-utils`,
  `shell`, `dev-tools`, `languages`, `python`, `media`, `network`, `heroku`
  (macOS only), `system`. The engine adds what a choice needs; inspect shows
  those groups as `implied`.
- SSH (`--ssh skip|generate|reuse|agent`, with `--ssh-key`): reuse needs the
  user's chosen private-key path; agent needs the key's `SHA256:`
  fingerprint from `ssh-add -l`. Generate defaults to `~/.ssh/id_ed25519`
  and never replaces a file. Recommend `--ssh-passphrase prompt`.
  `--ssh-config yes` adds a managed `Host github.com` block.
- GPG (`--gpg skip|generate|reuse`, `--gpg-key <fingerprint>`): recommend
  `--gpg-passphrase prompt`; `--gpg-expiry` defaults to `2y`.
- Signing (`--signing skip|ssh|gpg`): SSH signing is the simpler choice when
  an SSH key is selected. GPG or SSH signing needs a global Git identity:
  `--git-name` and `--git-email` when Git has none.
- `--fonts auto|yes|no` (`--font <Nerd Font name>` for yes),
  `--default-shell auto|yes|no`, `--full-upgrade` or `--no-full-upgrade`,
  and on macOS `--brew-mirror china|none`.

GitHub CLI's default login cannot read keys. Tell the user which read scopes
their choices need (`read:public_key` for SSH, `read:gpg_key` for GPG,
`read:ssh_signing_key` for SSH signing, `user:email` for GPG or SSH signing),
granted with `gh auth refresh -h github.com -s <scopes>`.

Run `inspect` again with the chosen flags and present the whole plan from its
records before handing over the command.

### 4. Hand over the command

Give the user one of these to run in their own terminal:

- `~/.leos-profiles/install.sh setup`: the wizard asks the same questions
  again, shows the same plan, and pauses and resumes for manual steps. Best
  when they would rather click through it themselves.
- The exact `apply` command for the inspected plan, with `--yes` and the
  `--node-version` from the `runtime` record, for example:

```bash
bash ~/.leos-profiles/install.sh apply --yes --groups packages,fnm,pnpm,plugins,zsh-config --package-groups core-utils,shell,dev-tools --ssh skip --gpg skip --signing skip --fonts auto --default-shell auto --no-full-upgrade --node-version v24.11.1 2>&1 | tee ~/leos-setup.log
```

`tee` keeps a log you can read back. Tell the user what may prompt: sudo
once at the start, Homebrew's own installer on a Mac without Homebrew, `chsh`
on Linux, and a new key's passphrase.

### 5. Read the result

- Exit 0: summarise what was verified, any skipped component, and that a new
  login is needed if the default shell changed.
- Exit 3: manual action. Each `manual-action` record is `action`, public
  file (may be empty) and destination, with an explanation printed below it.
  Walk the user through each (register a key at the URL, or run the given
  `gh auth refresh` command), then have them resume: the same apply again,
  with `--ssh reuse --ssh-key <path>` or `--gpg reuse --gpg-key
  <fingerprint>` for any key the first run created (the saved profile has
  them), or `bash ~/.leos-profiles/install.sh reconcile --yes`. Reconcile
  never generates keys.
- Exit 2: the plan changed since inspection (for example a new Node LTS):
  inspect again and hand over a new command.
- Anything else: report the actual error. Never guess that a registration is
  missing after a network or API failure.
