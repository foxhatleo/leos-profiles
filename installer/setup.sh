#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
#
# The `install.sh setup` wizard. Each stage asks with the ui.sh primitives and
# only sets the installer's existing globals (SELECTED_STEPS, SELECTED_GROUPS,
# INSTALL_FONTS, SSH_MODE, ...), exactly as the matching apply options would,
# so validation, dependency closure, inspection and apply are the engine's
# own. setup_main (install.sh) runs the wizard, inspects the selection into a
# file, renders it with render_plan, asks once and applies it in the same
# process.
# shellcheck disable=SC2034

# recommended, customize or saved.
SETUP_MODE=""

setup_wizard() {
  setup_mode
  case $SETUP_MODE in
    saved)
      setup_full_upgrade ;;
    customize)
      setup_components
      setup_package_groups
      setup_fonts
      setup_full_upgrade
      setup_casks
      setup_default_shell
      setup_release_age ;;
  esac
  if [[ $SETUP_MODE != saved ]]; then
    setup_ssh
    setup_gpg
  fi
  setup_git_identity
  setup_conflicts
}

setup_mode() {
  local default=0
  local -a options=(
    "Recommended: the full workstation (every component but rpatool; full package upgrade)"
    "Customize: choose components and package groups and options"
  )
  if [[ -f $PROFILE_FILE ]]; then
    options+=("Use the saved choices (local/install-profile.tsv)")
    default=2
  fi
  ui_choose "How do you want to set up this machine?" "$default" "${options[@]}"
  case $UI_INDEX in
    0) SETUP_MODE=recommended ;;
    1) SETUP_MODE=customize ;;
    *) SETUP_MODE=saved; read_profile ;;
  esac
}

component_summary() {
  case $1 in
    packages) printf 'OS packages from the selected package groups' ;;
    bins) printf 'rpatool (a pinned download; optional)' ;;
    rbenv) printf 'rbenv and the newest stable Ruby (compiled; takes minutes)' ;;
    bun) printf 'Bun' ;;
    fnm) printf 'fnm and the newest Node LTS' ;;
    corepack) printf 'pnpm and Yarn through Corepack (adds fnm)' ;;
    uv) printf 'uv and uvx' ;;
    cpython) printf 'the newest stable Python from uv (adds uv)' ;;
    starship) printf 'the Starship prompt' ;;
    plugins) printf 'zsh plugins: autosuggestions; syntax highlighting; completions; fzf-tab' ;;
    fonts) printf 'a Nerd Font for the prompt icons' ;;
    zsh-config) printf 'the managed blocks in .zshrc and .zshenv that load the profile' ;;
    default-shell) printf 'make zsh your login shell' ;;
    *) printf '%s' "$1" ;;
  esac
}

package_group_summary() {
  case $1 in
    core-utils) printf 'GNU core utilities; less; nano' ;;
    shell) printf 'zsh' ;;
    dev-tools) printf 'git; gh; jq; ripgrep; fd; fzf; bat; direnv; zoxide; build tools' ;;
    python) printf 'the OS python3 (rpatool runs on it)' ;;
    media) printf 'ffmpeg; ImageMagick' ;;
    network) printf 'wget; rclone' ;;
    heroku) printf 'the Heroku CLI (macOS only)' ;;
    system) printf 'smartmontools' ;;
    *) printf '%s' "$1" ;;
  esac
}

# setup_pick_csv <variable> <all csv> <summary function> <prompt>: a
# multi-select over the csv's items, preselecting the variable's current
# items; the variable becomes the chosen items.
setup_pick_csv() {
  local variable=$1 all=$2 summary=$3 prompt=$4 item defaults="" i=0 index chosen=""
  local -a names=() labels=()
  csv_split names "$all"
  for item in "${names[@]}"; do
    labels+=("$(printf '%-14s %s' "$item" "$("$summary" "$item")")")
    if has_csv_item "${!variable}" "$item"; then defaults="$defaults $i"; fi
    i=$((i + 1))
  done
  ui_multi "$prompt" "$defaults" "${labels[@]}"
  for index in $UI_REPLY; do chosen="${chosen:+$chosen,}${names[index]}"; done
  printf -v "$variable" '%s' "$chosen"
}

setup_components() {
  ui_section "Components"
  ui_note "Recommended is preselected. What a component needs (fnm for Corepack, uv for Python, OS packages) is added for you."
  setup_pick_csv SELECTED_STEPS "$CANONICAL_STEPS" component_summary "Components to install"
}

setup_package_groups() {
  local groups=$CANONICAL_GROUPS
  # Only Homebrew packages the Heroku CLI.
  [[ $OS_FAMILY == macos ]] || groups=${groups/,heroku/}
  ui_section "Package groups"
  ui_note "OS packages, installed with $(package_manager_name). A component adds the groups it needs (rbenv: dev-tools; the zsh components: shell)."
  setup_pick_csv SELECTED_GROUPS "$groups" package_group_summary "Package groups to install"
}

setup_fonts() {
  local default=0
  has_csv_item "$SELECTED_STEPS" fonts || return 0
  case $INSTALL_FONTS in yes) default=1 ;; no) default=2 ;; esac
  ui_section "Nerd Font"
  ui_choose "Install a Nerd Font (the themed prompt's icons need one in your terminal)?" "$default" \
    "Auto: only on a desktop (not over SSH or in a container)" \
    "Yes: install it here" \
    "No"
  case $UI_INDEX in
    0) INSTALL_FONTS=auto ;;
    1) INSTALL_FONTS=yes ;;
    *) INSTALL_FONTS=no; return 0 ;;
  esac
  while :; do
    ui_input "Font (a Nerd Fonts archive name such as JetBrainsMono, FiraCode or Hack)" "${FONT_NAME:-JetBrainsMono}"
    if [[ $UI_REPLY =~ ^[A-Za-z0-9_-]+$ ]]; then FONT_NAME=$UI_REPLY; return 0; fi
    ui_note "A Nerd Fonts archive name has only letters, digits, - and _."
  done
}

setup_full_upgrade() {
  local default=yes
  if [[ $SETUP_MODE == saved && $SAVED_FULL_UPGRADE == no ]]; then default=no; fi
  ui_section "Package upgrade"
  ui_note "A full upgrade also upgrades the packages already installed (within this OS release, never to a new one) and moves every tool to its newest release old enough. Without it, only what is missing is installed."
  if ui_confirm "Run a full upgrade?" "$default"; then FULL_UPGRADE=1; else FULL_UPGRADE=0; fi
}

setup_casks() {
  [[ $OS_FAMILY == macos && $FULL_UPGRADE -eq 1 ]] || return 0
  if ui_confirm "Also upgrade Homebrew casks (GUI apps; some installers ask for sudo)?" no; then
    UPGRADE_CASKS=1
  else
    UPGRADE_CASKS=0
  fi
}

setup_default_shell() {
  local default=0
  has_csv_item "$SELECTED_STEPS" default-shell || return 0
  case $CHANGE_DEFAULT_SHELL in yes) default=1 ;; no) default=2 ;; esac
  ui_section "Login shell"
  ui_choose "Make zsh your login shell?" "$default" \
    "Auto: only if the login shell is not zsh already" \
    "Yes: make the profile's zsh the login shell" \
    "No: leave the login shell alone"
  case $UI_INDEX in
    0) CHANGE_DEFAULT_SHELL=auto ;;
    1) CHANGE_DEFAULT_SHELL=yes ;;
    *) CHANGE_DEFAULT_SHELL=no ;;
  esac
}

setup_release_age() {
  ui_section "Release age"
  ui_note "Tools from GitHub releases and Git checkouts install only once a release has been public this long, so a broken or compromised one has time to be pulled."
  ui_choose "Minimum release age" 0 "Keep $MIN_RELEASE_AGE days (recommended)" "Change it"
  [[ $UI_INDEX -eq 1 ]] || return 0
  while :; do
    ui_input "Days (0 to 365)" "$MIN_RELEASE_AGE"
    if min_release_age_ok "$UI_REPLY"; then MIN_RELEASE_AGE=$UI_REPLY; return 0; fi
    ui_note "Enter a whole number of days from 0 to 365."
  done
}

# setup_ssh_keys: the private keys in ~/.ssh with a public key beside them.
setup_ssh_keys() {
  local public
  for public in "$HOME"/.ssh/*.pub; do
    [[ -f $public && -f ${public%.pub} ]] || continue
    printf '%s\n' "${public%.pub}"
  done
}

setup_ssh() {
  local key path line
  local -a keys=() labels=()
  while IFS= read -r key; do [[ -z $key ]] || keys+=("$key"); done < <(setup_ssh_keys)
  ui_section "SSH key for GitHub"
  ui_note "Setup prepares the key and checks GitHub; you add the public key to your GitHub account yourself, and setup waits while you do."
  local -a options=("Skip" "Generate a new key")
  (( ${#keys[@]} == 0 )) || options+=("Use an existing key")
  ui_choose "SSH key" 0 "${options[@]}"
  case $UI_INDEX in
    0) SSH_MODE=skip; return 0 ;;
    1)
      SSH_MODE=generate
      while :; do
        ui_input "Path for the new key" "${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
        path=$UI_REPLY
        if [[ $path != /* ]]; then
          ui_note "Give an absolute path."
        elif [[ -e $path || -L $path || -e $path.pub || -L $path.pub ]]; then
          ui_note "$path (or $path.pub) exists; choose \"Use an existing key\" or another path."
        else
          break
        fi
      done
      SSH_KEY_PATH=$path
      ui_choose "Passphrase for the new key" 0 \
        "Ask me for one (ssh-keygen prompts)" \
        "No passphrase (anyone who can read the file can use the key)"
      if [[ $UI_INDEX -eq 0 ]]; then SSH_PASSPHRASE_MODE=prompt; else SSH_PASSPHRASE_MODE=empty; fi ;;
    *)
      for key in "${keys[@]}"; do
        line=$(awk 'NF >= 2 { print $1 " " $3; exit }' "$key.pub" 2>/dev/null || true)
        line="$key  ($line)"
        labels+=("${line//,/ }")
      done
      ui_choose "Which key?" 0 "${labels[@]}"
      SSH_MODE=reuse
      SSH_KEY_PATH=${keys[UI_INDEX]} ;;
  esac
}

# setup_gpg_keys: "<fingerprint><TAB><first user ID>" for each secret key.
setup_gpg_keys() {
  command -v gpg >/dev/null 2>&1 || return 0
  gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '
    $1 == "sec" { want = 1; fpr = ""; next }
    $1 == "fpr" && want { fpr = $10; want = 0; next }
    $1 == "uid" && fpr != "" { print fpr "\t" $10; fpr = "" }
  ' || true
}

setup_gpg() {
  local fingerprint uid
  local -a fingerprints=() labels=()
  while IFS=$'\t' read -r fingerprint uid; do
    [[ -n $fingerprint ]] || continue
    fingerprints+=("$fingerprint")
    labels+=("${uid//,/ } ($fingerprint)")
  done < <(setup_gpg_keys)
  ui_section "Git commit signing (GPG)"
  ui_note "Setup checks the key signs, then you add the public key to GitHub yourself; commit signing is turned on once GitHub has it."
  local -a options=("Skip" "Generate a new signing key")
  (( ${#fingerprints[@]} == 0 )) || options+=("Use an existing secret key")
  ui_choose "GPG signing key" 0 "${options[@]}"
  case $UI_INDEX in
    0) GPG_MODE=skip ;;
    1)
      GPG_MODE=generate
      ui_choose "Passphrase for the new key" 0 \
        "Ask me for one (gpg prompts)" \
        "No passphrase (anyone who can read your keyring can sign as you)"
      if [[ $UI_INDEX -eq 0 ]]; then GPG_PASSPHRASE_MODE=prompt; else GPG_PASSPHRASE_MODE=empty; fi ;;
    *)
      ui_choose "Which key?" 0 "${labels[@]}"
      GPG_MODE=reuse
      GPG_KEY_ID=${fingerprints[UI_INDEX]} ;;
  esac
}

# setup_git_identity: GPG signing needs a global Git name and email; ask only
# for what is missing.
setup_git_identity() {
  [[ $GPG_MODE != skip ]] || return 0
  if [[ -z $(git config --global user.name 2>/dev/null || true) && -z $GIT_NAME ]]; then
    ui_section "Git identity"
    while :; do
      ui_input "Your name for Git commits" ""
      [[ -z $UI_REPLY ]] || break
    done
    GIT_NAME=$UI_REPLY
  fi
  if [[ -z $(git config --global user.email 2>/dev/null || true) && -z $GIT_EMAIL ]]; then
    while :; do
      ui_input "Your email for Git commits (verified on GitHub)" ""
      [[ ! $UI_REPLY =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || break
      ui_note "Enter an email address."
    done
    GIT_EMAIL=$UI_REPLY
  fi
}

# setup_conflicts: an existing ~/.rbenv in the way (preflight would stop on
# it) becomes the --skip-existing-version-managers choice.
setup_conflicts() {
  local path reason found=""
  has_csv_item "$SELECTED_STEPS" rbenv || return 0
  [[ $SKIP_EXISTING_VERSION_MANAGERS -eq 0 ]] || return 0
  while IFS=$'\t' read -r path reason; do
    case $reason in
      not-a-git-checkout) found="$path exists but is not a Git checkout (a Homebrew rbenv root, say)." ;;
      unexpected-origin) found="$path is a checkout of another repository." ;;
      local-changes) found="$path has local changes." ;;
    esac
  done < <(version_manager_conflicts rbenv)
  [[ -n $found ]] || return 0
  ui_section "Existing rbenv"
  ui_note "$found"
  ui_choose "What should setup do?" 0 \
    "Keep it and skip the rbenv component" \
    "Stop so I can move it away first"
  if [[ $UI_INDEX -eq 0 ]]; then
    SKIP_EXISTING_VERSION_MANAGERS=1
    return 0
  fi
  printf '%s\n' "Nothing was changed. Move ~/.rbenv away (or commit its changes), then run setup again." >&2
  exit 1
}

# warm_release_picks: pick each selected release artifact's tag in this shell
# before inspecting, so inspect (whose lookups run in subshells) shows, and
# apply installs, the same release.
warm_release_picks() {
  local step name record repository asset
  local -a steps=()
  [[ $OS_FAMILY != macos ]] || return 0
  csv_split steps "$SELECTED_STEPS"
  for step in ${steps[@]+"${steps[@]}"}; do
    while IFS= read -r name; do
      [[ $(artifact_source "$name") == release ]] || continue
      record=$(artifact_release_asset "$name") || continue
      IFS=$'\t' read -r repository asset <<< "$record"
      github_release_tag_pick "$repository" || true
    done < <(component_handler "$step" artifacts)
  done
}

# render_plan <inspect TSV file>: the plan as a person reads it, grouped by
# record type, ending with a per-component summary in the inventory's
# STATE/NAME layout. Every record type in docs/development.md's table is
# shown somewhere except meta.
render_plan() {
  awk -F '\t' -v bold="$UI_BOLD" -v dim="$UI_DIM" -v reset="$UI_RESET" '
    function head(title) { printf "\n%s%s%s\n", bold, title, reset }
    function item(text) { printf "  - %s\n", text }
    function count(type) { return (type in n) ? n[type] : 0 }
    function field(type, i, f,   parts) { split(row[type, i], parts, "\t"); return parts[f] }
    {
      n[$1]++
      row[$1, n[$1]] = $0
    }
    END {
      head("Selection")
      for (i = 1; i <= count("platform"); i++) item("platform: " field("platform", i, 3))
      for (i = 1; i <= count("profile"); i++) item("profile checkout: " field("profile", i, 3))
      components = ""; groups = ""; credentials = ""; internal = ""
      for (i = 1; i <= count("group"); i++) {
        category = field("group", i, 2); name = field("group", i, 3); status = field("group", i, 4)
        label = name (status == "implied" ? " (implied)" : "")
        if (category == "component") components = components (components == "" ? "" : ", ") label
        else if (category == "package") groups = groups (groups == "" ? "" : ", ") label
        else if (category == "credential") credentials = credentials (credentials == "" ? "" : ", ") name ": " status
        else internal = internal (internal == "" ? "" : ", ") name
      }
      item("components: " (components == "" ? "none" : components))
      item("package groups: " (groups == "" ? "none" : groups))
      item("credentials: " credentials)
      if (internal != "") item("always: " internal)
      for (i = 1; i <= count("policy"); i++) item("policy " field("policy", i, 2) ": " field("policy", i, 3))
      channels = ""
      for (i = 1; i <= count("channel"); i++)
        channels = channels (channels == "" ? "" : ", ") field("channel", i, 2) "=" field("channel", i, 3)
      if (channels != "") item("channels: " channels)

      head("Packages (" count("package") ")")
      if (count("package") == 0) item("none")
      else {
        line = ""
        for (i = 1; i <= count("package"); i++) {
          word = field("package", i, 3)
          if (length(line) + length(word) > 72) { printf "    %s\n", line; line = "" }
          line = line (line == "" ? "" : " ") word
        }
        if (line != "") printf "    %s\n", line
      }

      if (count("action") > 0) {
        head("What runs")
        for (i = 1; i <= count("action"); i++) item(field("action", i, 2) ": " field("action", i, 3))
      }
      if (count("runtime") > 0) {
        head("Runtimes")
        for (i = 1; i <= count("runtime"); i++)
          item(field("runtime", i, 2) " " field("runtime", i, 3) " (" field("runtime", i, 4) ")")
      }
      if (count("release") + count("artifact") + count("external") > 0) {
        head("Releases and sources")
        for (i = 1; i <= count("release"); i++) {
          if (field("release", i, 3) == "unresolved") item(field("release", i, 2) ": release not resolved yet (apply picks it)")
          else item(field("release", i, 2) " " field("release", i, 3) ", published " field("release", i, 4) ", checked by " field("release", i, 5))
        }
        for (i = 1; i <= count("artifact"); i++)
          item(field("artifact", i, 3) ": " field("artifact", i, 2) " " field("artifact", i, 4) " " field("artifact", i, 5))
        for (i = 1; i <= count("external"); i++) item("contacts " field("external", i, 2) ": " field("external", i, 3))
      }
      if (count("privileged") > 0) {
        head("Runs as root (sudo)")
        for (i = 1; i <= count("privileged"); i++) item(field("privileged", i, 2) ": " field("privileged", i, 3))
      }
      if (count("irreversible") > 0) {
        head("Cannot be undone automatically")
        for (i = 1; i <= count("irreversible"); i++) item(field("irreversible", i, 2) ": " field("irreversible", i, 3))
      }
      if (count("behaviour") + count("global") > 0) {
        head("Side effects")
        for (i = 1; i <= count("behaviour"); i++) item(field("behaviour", i, 2) ": " field("behaviour", i, 3))
        for (i = 1; i <= count("global"); i++) item("global " field("global", i, 2) " settings: " field("global", i, 3))
      }
      if (count("file") > 0) {
        head("Files")
        for (i = 1; i <= count("file"); i++) item(field("file", i, 2) ": " field("file", i, 3))
      }
      if (count("conflict") > 0) {
        head("Conflicts")
        for (i = 1; i <= count("conflict"); i++)
          item(field("conflict", i, 2) ": " field("conflict", i, 3) " (" field("conflict", i, 4) ")")
      }
      if (count("existing") > 0) {
        head("Existing setups (left in place)")
        for (i = 1; i <= count("existing"); i++)
          item(field("existing", i, 2) " at " field("existing", i, 3) ": " field("existing", i, 4))
      }
      if (count("migration") > 0) {
        head("Moves off an older layout")
        for (i = 1; i <= count("migration"); i++)
          item(field("migration", i, 2) " " field("migration", i, 3) ": " field("migration", i, 4))
      }
      if (count("shadow") > 0) {
        head("Shadowed copies")
        for (i = 1; i <= count("shadow"); i++)
          item(field("shadow", i, 2) ": " field("shadow", i, 4) " comes before " field("shadow", i, 3))
      }
      if (count("manual-action") > 0) {
        head("Manual actions")
        for (i = 1; i <= count("manual-action"); i++) item(field("manual-action", i, 2) ": " field("manual-action", i, 4))
      }
      if (count("item") > 0) {
        head("Inventory")
        for (i = 1; i <= count("item"); i++) item(field("item", i, 5) " " field("item", i, 2) " " field("item", i, 4))
      }
      if (count("warning") > 0) {
        head("Warnings")
        for (i = 1; i <= count("warning"); i++) item(field("warning", i, 2) ": " field("warning", i, 3))
      }

      head("Summary")
      printf "  %-10s %s\n", "STATE", "COMPONENT"
      todo = 0; done = 0
      for (i = 1; i <= count("postcondition"); i++) {
        status = field("postcondition", i, 3)
        if (status == "verified") { state = "done"; done++ }
        else if (status == "skipped") state = "skipped"
        else { state = "to do"; todo++ }
        printf "  %-10s %s\n", state, field("postcondition", i, 2)
      }
      printf "\n  %d to do, %d already done; %d packages; %d root actions; %d irreversible; %d warnings\n",
        todo, done, count("package"), count("privileged"), count("irreversible"), count("warning")
    }
  ' "$1"
}
