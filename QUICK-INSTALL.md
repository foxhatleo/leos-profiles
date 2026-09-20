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

`apply` and `reconcile` never ask *setup* questions, but they are not unattended:
depending on the selection they can still pause for the Homebrew installer's own
confirmation and `sudo` prompt, `sudo` authentication and re-prompts on Linux,
`chsh` asking for the user's password on Linux, and an
`ssh-keygen`/`gpg` passphrase prompt when passphrase mode is `prompt`. Tell the
user this before invoking apply so they know to stay at the keyboard.

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
   imply `packages` plus `shell`. Yarn and pnpm also imply fnm; install fnm
   before either npm tool.
6. Ask conditional choices in later stages of no more than three questions:
   fonts; full initial host upgrade; default-shell policy; SSH; GPG; missing
   Git identity; and exact key selection. SSH and GPG must have **Skip**
   preselected. Reuse must select one specifically discovered key. Never pick
   a key for the user. For generation, explain both passphrase policies:
   `empty` (supported default, unencrypted) and `prompt`. The default new SSH
   path is `~/.ssh/id_ed25519`; a different unused absolute path can be chosen.
   Never replace or silently reuse an existing key.
7. For GPG, ensure the selected Git email is verified on the authenticated
   GitHub account. Missing login or `user:email` access is a manual step: show
   the engine's guidance and let the user authenticate or grant scope. Do not
   execute login, key uploads, or SSH identity/protocol changes for the user.
8. Run the checkout's `bash install.sh inspect ...` with the explicit choices.
   Parse its typed TSV; do not expose the CLI as a second questionnaire. Use
   the engine's internal `none` value for an empty component/package
   multi-select.
9. Before approval, present one complete resolved plan showing:
   - selected and implied component, package, bootstrap, SSH, and GPG groups;
   - every package member and the full-upgrade effect; explain that
     `--no-full-upgrade` requests only missing selected packages but dependency
     resolution may still upgrade dependencies;
   - external repositories/taps and locked direct artifacts;
   - the preserved fnm default, adopted existing Node version, or resolved LTS
     fallback, with its compatibility against selected tools;
   - credential actions, selected references, and manual GitHub registration
     or SSH configuration steps;
   - any schema-1 to schema-2 profile migration reported by inspection;
   - files and managed blocks, global Git settings, shell changes, and every
     irreversible or privileged action.
10. Obtain one explicit approval. Then invoke `bash install.sh apply --yes ...`
    with the same normalized choices. Do not reimplement provisioning commands.
11. The checkout containing `install.sh` is authoritative and is installed in
    place. Local edits are valid. Do not add release, ref, origin, commit,
    ownership, or signature checks for that checkout.
12. Exit 3 means manual action is required, not successful completion. Parse
    `manual-action` records, show the public-key path and destination, and wait
    for the user to complete that action. Never upload keys or configure SSH
    identities automatically. Resume with `reconcile --yes` after completion;
    saved references are reused. If another initially selected generation had
    not yet run, resume the originally approved apply choices, changing already
    created keys to reuse their saved references. Obtain new approval only if
    the requested choices change. Reconciliation never creates keys. For
    failure exits, report the actual failure; do not guess registration.
13. On success, summarize verified outcomes, saved local state, any skips, and
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
sudo pacman -Syu --needed --noconfirm git curl ca-certificates
```

Stop on an unrecognized existing target instead of overwriting it. After the
clone, execute only the `install.sh` inside that checkout. The engine saves the
approved normalized profile before provisioning, so rerunning or reconciling
can safely repair a partial failure.

## Inspection and resume contract

The inspection stream starts with `meta<TAB>schema<TAB>1`; this identifies the
inspection format, not the saved profile schema. Saved profiles use schema 2.
Read records by their type and preserve empty fields:

- `policy<TAB>node<TAB>preserve-compatible` describes runtime selection.
- `runtime<TAB>node<TAB>VERSION<TAB>ORIGIN` identifies `preserved-fnm`,
  `adopted-existing`, or `current-lts`; an unresolved preview is labeled as such.
- `migration<TAB>profile-schema<TAB>1<TAB>2` announces automatic migration on
  the next approved execution; inspection does not migrate files.
- `manual-action<TAB>ACTION<TAB>PUBLIC_PATH<TAB>DESTINATION` accompanies exit 3.
  Some actions, such as login, have no public-key path.

Preserve a compatible fnm default, otherwise adopt the exact compatible Node
version found on PATH, otherwise resolve current LTS. Compatibility is based on
locked Yarn/pnpm engine metadata, not simply the newest available runtime.
Read [docs/development.md](./docs/development.md) for the full engine contract.
