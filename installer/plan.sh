#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
#
# What a plan does beyond installing the selection: the inspect records that
# disclose root actions, side effects, conflicts, existing setups, shadowed
# copies and platform support; the preflight that apply and reconcile run
# before their first change; and the read-only inventory.
# shellcheck disable=SC2034

is_wsl() { [[ -r /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; }

# A function so tests can stand in for a terminal.
stdin_is_terminal() { [[ -t 0 ]]; }

# ---------------------------------------------------------------------------
# Platform support (R5): Leo's Profiles supports Apple-silicon macOS 15 and
# later, Homebrew's Tier 1. Print why this Mac is outside it, or fail.
macos_support_problem() {
  local version major
  version=$(sw_vers -productVersion 2>/dev/null) || return 1
  major=${version%%.*}
  # hw.optional.arm64 is 1 on Apple silicon even under Rosetta, where uname -m
  # says x86_64.
  if [[ $(sysctl -n hw.optional.arm64 2>/dev/null || true) != 1 ]]; then
    printf 'Intel Mac (macOS %s) is unsupported: Homebrew supports Intel Macs only at Tier 2/3, without bottles for packages this setup installs, so installs build from source or fail. Supported: Apple-silicon macOS 15 and later.\n' "$version"
    return 0
  fi
  if [[ $major =~ ^[0-9]+$ ]] && (( major < 15 )); then
    printf 'macOS %s is unsupported: Homebrew supports it only at Tier 2/3, without bottles for packages this setup installs, so installs build from source or fail. Supported: Apple-silicon macOS 15 and later.\n' "$version"
    return 0
  fi
  return 1
}

platform_support_problem() {
  [[ $OS_FAMILY == macos ]] || return 1
  macos_support_problem
}

# ---------------------------------------------------------------------------
# Homebrew prefixes present on this host, for shadow and conflict checks.
homebrew_prefixes() {
  local prefix seen=" "
  local -a candidates=("${HOMEBREW_PREFIX:-}" /opt/homebrew /home/linuxbrew/.linuxbrew)
  [[ $OS_FAMILY != macos ]] || candidates+=(/usr/local)
  for prefix in "${candidates[@]}"; do
    [[ -n $prefix && $seen != *" $prefix "* && -d $prefix/bin ]] || continue
    seen+="$prefix "
    printf '%s\n' "$prefix"
  done
}

# version_manager_conflicts <rbenv>: "<path><TAB><reason>" for each existing
# installation the profile's checkout would collide with (ONB-5). Blocking
# reasons stop apply in preflight unless --skip-existing-version-managers
# keeps the existing installation:
#   not-a-git-checkout  the root exists but is no Git checkout (a Homebrew
#                       rbenv root, a copied directory)
#   unexpected-origin   a checkout of another repository
#   local-changes       a checkout with uncommitted changes
# homebrew-install (a Homebrew rbenv) is informational: both would be
# installed, and the profile prefers its own checkout. (pyenv is no longer
# installed; report_existing_setups discloses an existing one.)
# The components whose checkout can collide with an existing installation.
VERSION_MANAGERS=rbenv

version_manager_conflicts() {
  local tool=$1 root="$HOME/.$1" repository=$RBENV_REPOSITORY prefix origin
  [[ $tool == rbenv ]] || die "No version-manager conflicts for: $tool"
  if [[ -e $root || -L $root ]]; then
    if [[ ! -d $root/.git ]]; then
      printf '%s\tnot-a-git-checkout\n' "$root"
    else
      origin=$(git -C "$root" remote get-url origin 2>/dev/null || true)
      if ! github_origins_equivalent "$origin" "$repository"; then
        printf '%s\tunexpected-origin\n' "$root"
      elif [[ -n $(git -C "$root" status --porcelain 2>/dev/null) ]]; then
        printf '%s\tlocal-changes\n' "$root"
      fi
    fi
  fi
  while IFS= read -r prefix; do
    if [[ -d $prefix/opt/$tool ]]; then
      printf '%s\thomebrew-install\n' "$prefix/opt/$tool"
      break
    fi
  done < <(homebrew_prefixes)
}

version_manager_blocked() {
  version_manager_conflicts "$1" | awk -F '\t' '$2 != "homebrew-install" { found = 1 } END { exit !found }'
}

# The component is selected but kept out of this run: an existing installation
# is in the way and the user chose to keep it.
component_skipped_for_existing() {
  [[ $SKIP_EXISTING_VERSION_MANAGERS -eq 1 ]] || return 1
  case $1 in
    rbenv) [[ -n $(version_manager_conflicts "$1") ]] ;;
    *) return 1 ;;
  esac
}

report_conflicts() {
  local tool path reason
  for tool in $VERSION_MANAGERS; do
    has_csv_item "$SELECTED_STEPS" "$tool" || continue
    while IFS=$'\t' read -r path reason; do
      printf 'conflict\t%s\t%s\t%s\n' "$tool" "$path" "$reason"
    done < <(version_manager_conflicts "$tool")
  done
}

# ---------------------------------------------------------------------------
# Existing shell frameworks and version managers (ONB-6). README's
# "Existing setups" section explains how each coexists with the profile.
report_existing_setups() {
  local path prefix
  local -a candidates=()
  existing() { printf 'existing\t%s\t%s\t%s\n' "$1" "$2" "$3"; }
  for path in "${ZSH:-}" "$HOME/.oh-my-zsh"; do
    if [[ -n $path && -d $path ]]; then
      existing oh-my-zsh "$path" "loads from .zshrc before the profile's block: compinit runs twice and Starship replaces its theme"
      break
    fi
  done
  candidates=("$HOME/.p10k.zsh" "$HOME/powerlevel10k" "${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}/themes/powerlevel10k")
  while IFS= read -r prefix; do candidates+=("$prefix/opt/powerlevel10k"); done < <(homebrew_prefixes)
  for path in "${candidates[@]}"; do
    if [[ -e $path ]]; then
      existing powerlevel10k "$path" "the profile's Starship prompt replaces it; keep one prompt"
      break
    fi
  done
  # pyenv was the profile's Python manager before schema 4; an existing one is
  # left as it is, and zsh/path/pyenv.zsh still activates it.
  path=${PYENV_ROOT:-$HOME/.pyenv}
  if [[ -d $path ]]; then
    existing pyenv "$path" "no longer installed or updated; it stays, and in interactive shells its shims come before uv's python3 in ~/.local/bin: pyenv global system hands python3 to uv's, or remove the directory"
  fi
  path=${NVM_DIR:-$HOME/.nvm}
  if [[ -d $path ]]; then
    existing nvm "$path" "fnm's default Node comes first in new shells; nvm still switches when you run nvm use"
  fi
  for path in "$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniforge3" "$HOME/mambaforge" "$(command -v conda 2>/dev/null || true)"; do
    if [[ -n $path && -e $path ]]; then
      existing conda "$path" "conda activate puts that environment's python ahead of uv's python3 in ~/.local/bin; an auto-activated base does so in every shell"
      break
    fi
  done
  for path in "${ASDF_DATA_DIR:-$HOME/.asdf}" "$(command -v asdf 2>/dev/null || true)"; do
    if [[ -n $path && -e $path ]]; then
      existing asdf "$path" "its shims and the profile's fnm, uv Python and rbenv both provide node, python and ruby; whichever comes first on PATH wins"
      break
    fi
  done
  for path in "$(command -v mise 2>/dev/null || true)" "${XDG_DATA_HOME:-$HOME/.local/share}/mise"; do
    if [[ -n $path && -e $path ]]; then
      existing mise "$path" "mise activate rewrites PATH per directory after the profile; tools it manages win over fnm, uv's Python and rbenv there"
      break
    fi
  done
  unset -f existing
}

# ---------------------------------------------------------------------------
# Linux: release artifacts in ~/.local/bin that will shadow a Homebrew
# (Linuxbrew) copy of the same tool (MI-3): ~/.local/bin comes first on PATH,
# so `brew upgrade <tool>` no longer changes what the shell runs. macOS takes
# these tools from Homebrew itself.
report_shadowed_artifacts() {
  local name executable prefix
  local -a executables=()
  [[ $OS_FAMILY != macos ]] || return 0
  while IFS= read -r name; do
    artifact_row "$name"
    has_csv_item "$SELECTED_STEPS" "$ARTIFACT_COMPONENT" || continue
    IFS=' ' read -r -a executables <<< "$ARTIFACT_EXECUTABLES"
    for executable in "${executables[@]}"; do
      while IFS= read -r prefix; do
        if [[ -x $prefix/bin/$executable ]]; then
          printf 'shadow\t%s\t%s\t%s\n' "$executable" "$prefix/bin/$executable" "$HOME/.local/bin/$executable"
          break
        fi
      done < <(homebrew_prefixes)
    done
  done < <(artifact_names)
}

# ---------------------------------------------------------------------------
# What this run moves off an older layout: on macOS, the ~/.local/bin copies
# of the pinned installs before 2026-10, which Homebrew's formulae replace;
# the retired yarn and pnpm components' npm packages in ~/.local/npm and, on
# macOS, the Homebrew formulae they installed, which Corepack replaces; and
# Git checkouts on a branch (the default-branch layout of 2026-10), which move
# to their release, detached. The release named is what the checkout's refs
# give as of its last fetch; the step fetches first.
report_tool_migrations() {
  local name path step directory label prefix mode release tool
  if [[ $OS_FAMILY == macos ]]; then
    while IFS= read -r name; do
      artifact_row "$name"
      has_csv_item "$SELECTED_STEPS" "$ARTIFACT_COMPONENT" || continue
      while IFS= read -r path; do
        printf 'migration\tlocal-bin\t%s\tremoved: Homebrew'"'"'s %s formula replaces it\n' "$path" "$ARTIFACT_FORMULA"
      done < <(legacy_local_copy "$name")
    done < <(artifact_names)
  fi
  if has_csv_item "$SELECTED_STEPS" corepack; then
    for tool in $COREPACK_TOOLS; do
      if legacy_npm_copy_present "$tool"; then
        printf 'migration\tnpm-prefix\t%s\tremoved: Corepack'"'"'s %s replaces it\n' "$(corepack_prefix)/bin/$tool" "$tool"
      fi
      if retired_formula_installed "$tool"; then
        printf 'migration\thomebrew-formula\t%s\tuninstalled: the profile installed it; Corepack'"'"'s %s replaces it\n' \
          "$(brew_prefix)/opt/$tool" "$tool"
      fi
    done
  fi
  while IFS='|' read -r step prefix directory label; do
    has_csv_item "$SELECTED_STEPS" "$step" || continue
    [[ -d $directory/.git ]] || continue
    git -C "$directory" symbolic-ref --quiet HEAD >/dev/null 2>&1 || continue
    mode=${prefix}_FOLLOW
    mode=${!mode}
    if release_checkout_target "$directory" "$mode"; then
      if [[ $mode == commit ]]; then release="commit $FOLLOW_TARGET_NAME"; else release="tag $FOLLOW_TARGET_NAME"; fi
    else
      release="its release"
    fi
    printf 'migration\tgit-checkout\t%s\t%s moves from origin'"'"'s default branch to %s (%s), detached\n' \
      "$directory" "$label" "$release" "$(follow_mode_description "$mode")"
  done <<EOF
rbenv|RBENV|$HOME/.rbenv|rbenv
rbenv|RUBY_BUILD|$HOME/.rbenv/plugins/ruby-build|ruby-build
plugins|ZSH_AUTOSUGGESTIONS|$TARGET/zsh/plugins/zsh-autosuggestions|zsh-autosuggestions
plugins|ZSH_SYNTAX_HIGHLIGHTING|$TARGET/zsh/plugins/zsh-syntax-highlighting|zsh-syntax-highlighting
plugins|ZSH_COMPLETIONS|$TARGET/zsh/plugins/zsh-completions|zsh-completions
plugins|FZF_TAB|$TARGET/zsh/plugins/fzf-tab|fzf-tab
EOF
}

# What --min-release-age does not cover (a `warning` record): Homebrew
# installs formulae at its current version on macOS, and on every OS npm's
# Corepack is its latest release, as are the pnpm and Yarn Corepack installs.
# OS packages come from the distribution's own repositories in either case.
report_release_age_scope() {
  local step names=""
  if [[ $OS_FAMILY == macos ]]; then
    for step in bun fnm uv starship; do
      has_csv_item "$SELECTED_STEPS" "$step" || continue
      names+="${names:+, }$step"
    done
    [[ -z $names ]] ||
      printf 'warning\trelease-age-homebrew\tHomebrew formulae (%s) install at Homebrew'"'"'s current version; --min-release-age applies to GitHub releases, Git checkouts and new runtime lines only\n' "$names"
  fi
  if has_csv_item "$SELECTED_STEPS" corepack; then
    printf 'warning\trelease-age-npm\tnpm installs the latest corepack, and Corepack the latest pnpm and Yarn'"'"'s stable release; --min-release-age applies to GitHub releases, Git checkouts and new runtime lines only\n'
  fi
}

# report_prompt_scope: zsh-config without the starship component: the
# interactive prompt is the profile's built-in fallback unless a Starship is
# on PATH already (a `warning` record).
report_prompt_scope() {
  has_csv_item "$SELECTED_STEPS" zsh-config || return 0
  has_csv_item "$SELECTED_STEPS" starship && return 0
  printf 'warning\tfallback-prompt\tzsh-config without the starship component: interactive shells use the built-in fallback prompt unless Starship is already on PATH; add starship to --groups for the themed prompt\n'
}

# ---------------------------------------------------------------------------
# Root actions (R1): "<name><TAB><description>" for every action this plan
# runs as root, through sudo or directly when the installer is root. Inspect
# prints them as `privileged` records; preflight asks for sudo once if any.
default_shell_change_needed() {
  has_csv_item "$SELECTED_STEPS" default-shell || return 1
  [[ $CHANGE_DEFAULT_SHELL != no ]] || return 1
  ! verify_default_shell
}

packages_need_package_manager() {
  has_csv_item "$SELECTED_STEPS" packages || return 1
  collect_selected_packages
  (( ${#SELECTED_PACKAGES[@]} > 0 )) || return 1
  [[ $FULL_UPGRADE -eq 1 ]] || ! selected_packages_installed
}

# cask_upgrade_planned: this run's packages step runs `brew upgrade --cask`
# (macOS, a full upgrade, --upgrade-casks).
cask_upgrade_planned() {
  [[ $OS_FAMILY == macos && $UPGRADE_CASKS -eq 1 && $FULL_UPGRADE -eq 1 ]] && packages_need_package_manager
}

privileged_plan() {
  local root=${SUDO:+sudo } zsh_path missing
  if [[ $OS_FAMILY == macos ]]; then
    if ! command -v brew >/dev/null 2>&1 && [[ ! -x /opt/homebrew/bin/brew && ! -x /usr/local/bin/brew ]]; then
      printf 'homebrew-bootstrap\tthe pinned Homebrew installer runs sudo to create the Homebrew prefix\n'
    fi
    if cask_upgrade_planned; then
      printf 'cask-upgrade\tbrew upgrade --cask: some casks run installers that ask for sudo\n'
    fi
  else
    missing=$(bootstrap_missing)
    [[ -z $missing ]] || printf 'bootstrap\t%s%s install %s\n' "$root" "$(package_manager_name)" "$missing"
    if packages_need_package_manager; then
      case $OS_FAMILY in
        apt)
          printf 'package-manager\t%sapt-get update, %sinstall of the selected packages (noninteractive; changed configuration files are kept)\n' \
            "$root" "$([[ $FULL_UPGRADE -eq 1 ]] && printf 'upgrade and ')" ;;
        fedora)
          printf 'package-manager\t%sdnf %sinstall of the selected packages\n' "$root" "$([[ $FULL_UPGRADE -eq 1 ]] && printf 'upgrade and ')"
          if has_csv_item "$SELECTED_GROUPS" media; then
            printf 'repository\t%sdnf install of the RPM Fusion free release package\n' "$root"
            printf 'dnf-swap\t%s%s: replaces Fedora'"'"'s ffmpeg-free with RPM Fusion'"'"'s ffmpeg and may remove packages that conflict with it\n' \
              "$root" "${FEDORA_FFMPEG_SWAP[*]}"
          fi ;;
        arch)
          printf 'pacman-sync\t%spacman -Syu --needed --noconfirm: installing any missing package syncs the databases and upgrades the whole system (Arch has no partial upgrades)\n' "$root" ;;
      esac
    fi
    missing=$(credential_prerequisites_missing)
    [[ -z $missing ]] || printf 'credential-packages\t%s%s install %s\n' "$root" "$(package_manager_name)" "$missing"
  fi
  if default_shell_change_needed; then
    zsh_path=$(preferred_zsh_path 2>/dev/null || printf 'zsh')
    if [[ ! -r $ETC_SHELLS ]] || ! grep -qxF "$zsh_path" "$ETC_SHELLS"; then
      printf 'etc-shells\t%sappend %s to %s\n' "$root" "$zsh_path" "$ETC_SHELLS"
    fi
    printf 'login-shell\t%schsh -s %s %s\n' "$root" "$zsh_path" "$(login_user)"
  fi
}

package_manager_name() {
  case $OS_FAMILY in
    apt) printf 'apt-get' ;;
    fedora) printf 'dnf' ;;
    arch) printf 'pacman -Syu --needed' ;;
    *) printf 'brew' ;;
  esac
}

# Side effects beyond the listed files and packages (R1).
report_behaviour() {
  if [[ $OS_FAMILY == apt ]] && has_csv_item "$SELECTED_STEPS" packages && has_csv_item "$SELECTED_GROUPS" dev-tools; then
    printf 'behaviour\tcompat-symlinks\t~/.local/bin/fd and ~/.local/bin/bat link to Debian'"'"'s fdfind and batcat when fd and bat are not on PATH\n'
  fi
  if [[ $OS_FAMILY == macos ]] && has_csv_item "$SELECTED_GROUPS" core-utils; then
    printf 'behaviour\tgnu-tools\tinteractive shells put the GNU coreutils, findutils, sed, tar, grep, awk and which ahead of the BSD tools; disable-gnu (local/flags/no-gnu) keeps BSD\n'
  fi
  if [[ $GPG_MODE != skip ]]; then
    printf 'behaviour\tgit-identity\twrites global user.name and user.email when either is unset (from --git-name/--git-email)\n'
  fi
  if cask_upgrade_planned; then
    printf 'behaviour\tcask-upgrade\tfull upgrade also upgrades every Homebrew cask (GUI apps; some ask for sudo)\n'
  fi
  if [[ $OS_FAMILY == macos && $(brew_mirror_effective) == china ]]; then
    printf 'behaviour\tbrew-mirror\tHomebrew'"'"'s own code (brew.git), metadata and bottles come from the USTC mirror in this run and later shells\n'
  fi
  if default_shell_change_needed && [[ $OS_FAMILY == macos ]]; then
    printf 'behaviour\tlogin-shell\tthe login shell becomes the system /bin/zsh, not a Homebrew zsh\n'
  fi
}

# ---------------------------------------------------------------------------
# Preflight (ONB-1): everything apply and reconcile need from the user is
# checked before the first change. Without a terminal, a run that would need
# a sudo password, a passphrase prompt or chsh's password prompt stops with a
# `manual-action run-in-terminal` record carrying the exact command, and exit
# 3, having changed nothing. With a terminal, sudo asks once, up front. chsh
# runs as root (see set_default_shell), so it is covered by the sudo check.

# The command that started this run, for run-in-terminal.
INVOCATION=""

preflight() {
  local tool path reason reasons="" privileged
  for tool in $VERSION_MANAGERS; do
    has_csv_item "$SELECTED_STEPS" "$tool" || continue
    if [[ $SKIP_EXISTING_VERSION_MANAGERS -eq 1 ]]; then
      if component_skipped_for_existing "$tool"; then
        say "Keeping the existing $tool; the $tool component is skipped (--skip-existing-version-managers)"
      fi
      continue
    fi
    while IFS=$'\t' read -r path reason; do
      case $reason in
        not-a-git-checkout) die "$tool: $path exists but is not a Git checkout (for example a Homebrew $tool root). Move it away, or rerun with --skip-existing-version-managers to keep it and skip the $tool component." ;;
        unexpected-origin) die "$tool: $path is a checkout of another repository. Move it away, or rerun with --skip-existing-version-managers to keep it." ;;
        local-changes) die "$tool: $path has local changes. Commit or remove them, or rerun with --skip-existing-version-managers to keep it as it is." ;;
      esac
    done < <(version_manager_conflicts "$tool")
  done
  check_approved_node_version
  if ! stdin_is_terminal; then
    if [[ $SSH_MODE == generate && $SSH_PASSPHRASE_MODE == prompt ]]; then
      reasons+="ssh-keygen must ask for the new SSH key's passphrase (--ssh-passphrase prompt). "
    fi
    if [[ $GPG_MODE == generate && $GPG_PASSPHRASE_MODE == prompt ]]; then
      reasons+="gpg must ask for the new key's passphrase (--gpg-passphrase prompt). "
    fi
  fi
  privileged=$(privileged_plan)
  if [[ -n $privileged && -n $SUDO ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would run as root (sudo): $(cut -f1 <<< "$privileged" | paste -sd, -)"
    else
      command -v sudo >/dev/null 2>&1 || die "This plan needs root ($(cut -f1 <<< "$privileged" | paste -sd, -)); install sudo or run as root"
      if sudo -n true 2>/dev/null; then
        :
      elif stdin_is_terminal; then
        say "Root is needed for: $(cut -f1 <<< "$privileged" | paste -sd, -). sudo asks for your password once, now."
        sudo -v || die "sudo authentication failed"
      else
        reasons+="sudo needs a password for $(cut -f1 <<< "$privileged" | paste -sd, -) and there is no terminal to ask in. "
      fi
    fi
  fi
  if [[ -n $reasons ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would stop before any change, because this is not a terminal: ${reasons% }"
      return 0
    fi
    queue_manual_action run-in-terminal '' "$INVOCATION" \
      "Nothing was changed. ${reasons}Run this command yourself, in a terminal: $INVOCATION"
    finish_manual_actions
  fi
  if [[ $DRY_RUN -eq 0 ]] && has_csv_item "$SELECTED_STEPS" fonts && font_should_install &&
    ! { state_done fonts && verify_step fonts; }; then
    # Reject a mistyped font now, not after the packages have installed.
    NERD_FONTS_CHECKSUMS_FILE=$(mktemp "${TMPDIR:-/tmp}/leos-nerd-fonts-sha256.XXXXXX")
    track_temp "$NERD_FONTS_CHECKSUMS_FILE"
    fetch_nerd_font_checksums "$NERD_FONTS_CHECKSUMS_FILE"
    require_known_nerd_font "$NERD_FONTS_CHECKSUMS_FILE" "${FONT_NAME:-JetBrainsMono}"
  fi
}

# ---------------------------------------------------------------------------
# --node-version (SEC-5): apply installs the Node version inspect resolved and
# the user approved. If this run would choose a different one (the current LTS
# moved, or the host's Node changed), it stops with status 2 instead.
NODE_VERSION_APPROVED=""
check_approved_node_version() {
  [[ -n $NODE_VERSION_APPROVED ]] || return 0
  has_csv_item "$SELECTED_STEPS" fnm || die "--node-version applies only when fnm is selected"
  local kept
  if kept=$(node_default_kept); then
    [[ $kept == "$NODE_VERSION_APPROVED" ]] && return 0
    printf '%s\n' "ERROR: the approved plan uses Node $NODE_VERSION_APPROVED, but this run keeps the installed default $kept. Nothing was changed; run inspect again and approve the new plan." >&2
    exit 2
  fi
  if resolve_node_version; then
    if [[ $RESOLVED_NODE_VERSION != "$NODE_VERSION_APPROVED" ]]; then
      printf '%s\n' "ERROR: the approved plan uses Node $NODE_VERSION_APPROVED, but the current LTS is now $RESOLVED_NODE_VERSION. Nothing was changed; run inspect again and approve the new plan." >&2
      exit 2
    fi
    return 0
  fi
  # Offline: the approved LTS is still the reviewed choice.
  RESOLVED_NODE_VERSION=$NODE_VERSION_APPROVED
  NODE_SELECTION="current-lts"
}

# ---------------------------------------------------------------------------
# inventory (ONB-13): everything the installer creates or manages, with its
# path and whether it is present. Read-only; needs no supported platform.
inventory_records() {
  local name path marker file
  item() {
    local state=absent
    if [[ -e $4 || -L $4 ]]; then state=present; fi
    printf 'item\t%s\t%s\t%s\t%s\n' "$1" "$2" "$4" "${5:-$state}"
  }
  printf 'meta\tschema\t1\n'
  printf 'profile\troot\t%s\n' "$TARGET"
  resolve_zsh_dotdirs
  for marker in loader environment login-path; do
    case $marker in
      loader) file="$ZSH_RC_DIR/.zshrc" ;;
      environment) file="$ZSH_ENV_DIR/.zshenv" ;;
      login-path) file="$ZSH_RC_DIR/.zprofile" ;;
    esac
    block_markers "$marker"
    if [[ -f $file ]] && grep -qxF "$BLOCK_BEGIN" "$(resolve_config_path "$file")" 2>/dev/null; then
      item managed-block "$marker" - "$file" present
    else
      item managed-block "$marker" - "$file" absent
    fi
    item backup "${file##*/}" - "$file.leos-profiles.bak"
  done
  while IFS= read -r name; do
    artifact_row "$name"
    for file in $ARTIFACT_EXECUTABLES; do
      item local-bin "$file" - "$HOME/.local/bin/$file"
    done
  done < <(artifact_names)
  for name in fd bat; do
    if [[ -L $HOME/.local/bin/$name ]]; then item local-bin "$name" - "$HOME/.local/bin/$name"; fi
  done
  for name in corepack pnpm yarn; do
    item npm-prefix "$name" - "$HOME/.local/npm/bin/$name"
  done
  item runtime python3 - "$HOME/.local/bin/python3"
  item runtime cpython - "${UV_PYTHON_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/python}"
  item runtime ruby - "$HOME/.rbenv/versions"
  for name in zsh-autosuggestions zsh-syntax-highlighting zsh-completions fzf-tab; do
    item plugin "$name" - "$TARGET/zsh/plugins/$name"
  done
  # Installed by releases before schema 4; no longer updated.
  item version-manager pyenv - "$HOME/.pyenv"
  item version-manager rbenv - "$HOME/.rbenv"
  item version-manager ruby-build - "$HOME/.rbenv/plugins/ruby-build"
  item fonts nerd-fonts - "$(nerd_font_directory)"
  item cache init-cache - "${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles"
  for name in install-profile.tsv install-state.tsv private.zsh private-interactive.zsh; do
    item local "$name" - "$LOCAL_DIR/$name"
  done
  for name in brew-china no-gnu no-brew no-pyenv no-rbenv no-starship-warning; do
    item flag "$name" - "$LOCAL_DIR/flags/$name"
  done
  for file in "$LOCAL_DIR"/gpg-public-*.asc; do
    [[ -e $file ]] || continue
    item local "${file##*/}" - "$file"
  done
  for name in user.name user.email user.signingkey gpg.format commit.gpgsign; do
    if git config --global --get "$name" >/dev/null 2>&1; then
      printf 'item\tgit-global\t%s\t%s\tpresent\n' "$name" "${GIT_CONFIG_GLOBAL:-~/.gitconfig}"
    else
      printf 'item\tgit-global\t%s\t%s\tabsent\n' "$name" "${GIT_CONFIG_GLOBAL:-~/.gitconfig}"
    fi
  done
  unset -f item
}

inventory() {
  local records
  records=$(inventory_records)
  if [[ $INVENTORY_FORMAT == tsv ]]; then
    printf '%s\n' "$records"
    return 0
  fi
  printf 'Leo'"'"'s Profiles inventory for %s\n' "$TARGET"
  printf '%-8s %-16s %-26s %s\n' STATE KIND NAME PATH
  awk -F '\t' '$1 == "item" { printf "%-8s %-16s %-26s %s\n", $5, $2, $3, $4 }' <<< "$records"
  printf '\n%s\n' "Removal: bash install.sh remove-blocks removes the managed blocks; everything else above is left for you to delete. Packages are not listed: they may be shared, so uninstalling them stays manual."
}
