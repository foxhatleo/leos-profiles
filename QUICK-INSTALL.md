# Leo's Profiles master setup prompt

Copy this entire file into your AI coding tool.

- **Claude Code:** submit it in a session that can display single-select and
  multi-select question boxes.
- **Codex:** enter **Plan mode before submitting this prompt**. The setup uses
  Plan mode's question UI.
- If the current session cannot display select boxes, stop. Explain how to
  restart in the correct mode and do not replace the UI with typed questions
  or make the user operate `install.sh` directly.

Prerequisites are a supported macOS/Linux host, network access, an interactive
AI terminal session, and permission to use the host package manager (`sudo` on
Linux and for privileged maintenance). Git is preferred but can be bootstrapped
with the OS-native commands below. GitHub credential setup additionally needs
an account that can authenticate through GitHub CLI.

---

You are setting up Leo's Profiles. You own the guided experience; the shell
installer is only your deterministic execution engine.

## Rules

1. Inspect the host and any existing checkout before asking questions. Use
   select-box UI only, in stages containing at most three questions.
2. First ask one single-select question: **Recommended full setup** (default)
   or **Customize**.
3. Recommended selects every current default component and package group,
   except optional `bins`/rpatool. Credentials default to Skip, fonts to Auto,
   default shell to Auto, and the initial package pass performs a full host
   upgrade.
4. For Customize, ask two multi-select questions together:
   - Components: `bins`, `packages`, `pyenv`, `rbenv`, `bun`, `yarn`, `pnpm`,
     `fnm`, `plugins`, `fonts`, `zsh-config`, `default-shell`.
   - Package groups: `core-utils`, `shell`, `dev-tools`, `languages`, `media`,
     `network`, `system`.
5. A selected group means every member. Preserve dependency closure: rpatool,
   Bun, fnm, Yarn, and pnpm imply `packages` plus `languages`; pyenv/rbenv
   imply `packages` plus `dev-tools`; plugins, Zsh config, and default shell
   imply `packages` plus `shell`.
6. Ask conditional choices in later stages of no more than three questions:
   fonts; full initial host upgrade; default-shell policy; SSH; GPG; missing
   Git identity; and exact key selection. SSH and GPG must have **Skip**
   preselected. Reuse must select one specifically discovered key. Never pick
   a key for the user.
7. For GPG, ensure the selected Git email is verified on the authenticated
   GitHub account. If `gh` lacks `user:email`, explain and request approval to
   run `gh auth refresh -s user:email` before continuing.
8. Run the checkout's `bash install.sh inspect ...` with the explicit choices.
   Parse its typed TSV; do not expose the CLI as a second questionnaire. Use
   the engine's internal `none` value for an empty component/package
   multi-select.
9. Before approval, present one complete resolved plan showing:
   - selected and implied component, package, bootstrap, SSH, and GPG groups;
   - every package member and the full-upgrade effect;
   - external repositories/taps and locked direct artifacts;
   - the resolved current Node LTS for this run;
   - credential actions and selected references;
   - files and managed blocks, global Git settings, shell changes, and every
     irreversible or privileged action.
10. Obtain one explicit approval. Then invoke `bash install.sh apply --yes ...`
    with the same normalized choices. Do not reimplement provisioning commands.
11. The checkout containing `install.sh` is authoritative and is installed in
    place. Local edits are valid. Do not add release, ref, origin, commit,
    ownership, or signature checks for that checkout.
12. On success, summarize verified outcomes, saved local state, any skips, and
    that a new login is needed if the default shell changed.

## Obtaining the checkout

Use `~/.leos-profiles` unless the user already requested another directory.
If that path is an existing Leo's Profiles checkout, use it in place and do
not pull during setup. If it is absent, install the minimum Git bootstrap for
the detected OS, then clone the current GitHub default branch directly there:

```bash
git clone https://github.com/foxhatleo/leos-profiles.git "$HOME/.leos-profiles"
```

If both Git and curl are absent, these OS-native commands avoid a curl/Git
deadlock:

```bash
# macOS: complete the displayed Command Line Tools installation, then retry Git
xcode-select --install

# Ubuntu or Debian
sudo apt-get update && sudo apt-get install -y git curl ca-certificates

# Fedora
sudo dnf install -y git curl ca-certificates

# Arch Linux
sudo pacman -Sy --needed --noconfirm git curl ca-certificates
```

Stop on an unrecognized existing target instead of overwriting it. After the
clone, execute only the `install.sh` inside that checkout. The engine saves the
approved normalized profile before provisioning, so rerunning or reconciling
can safely repair a partial failure.
