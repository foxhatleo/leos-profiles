#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

resolve_config_path() {
  local path=$1 link directory hops=0
  while [[ -L $path ]]; do
    (( hops += 1 ))
    (( hops <= 40 )) || die "Too many symbolic-link hops while resolving $1"
    link=$(readlink "$path")
    if [[ $link == /* ]]; then
      path=$link
    else
      directory=$(CDPATH='' cd -- "$(dirname -- "$path")" && pwd -P)
      path="$directory/$link"
    fi
  done
  printf '%s\n' "$path"
}

managed_block_well_formed() {
  local file=$1 marker=$2
  [[ ! -e $file ]] && return 0
  awk -v begin="# >>> leos-profiles ${marker} >>>" -v end="# <<< leos-profiles ${marker} <<<" '
    $0 == begin {
      begins++
      if (open || begins > 1) invalid=1
      open=1
      next
    }
    $0 == end {
      ends++
      if (!open || ends > 1) invalid=1
      open=0
      next
    }
    END { exit invalid || open || begins != ends }
  ' "$file"
}

managed_block_equals() {
  local file=$1 marker=$2 expected=$3 actual
  file=$(resolve_config_path "$file")
  managed_block_well_formed "$file" "$marker" || return 1
  [[ -e $file ]] || return 1
  actual=$(awk -v begin="# >>> leos-profiles ${marker} >>>" -v end="# <<< leos-profiles ${marker} <<<" '
    $0 == begin { capture=1; found=1; next }
    $0 == end { capture=0; next }
    capture { print }
    END { if (!found) exit 1 }
  ' "$file") || return 1
  [[ $actual == "$expected" ]]
}

install_managed_block() {
  local file=$1 marker=$2 content=$3 tmp mode backup separator=""
  [[ $DRY_RUN -eq 1 ]] && { say "Would install managed block in $file"; return 0; }
  file=$(resolve_config_path "$file")
  mkdir -p "$(dirname -- "$file")"
  managed_block_well_formed "$file" "$marker" || die "Refusing to rewrite malformed managed block in $file"
  managed_block_equals "$file" "$marker" "$content" && return 0
  backup="$file.leos-profiles.bak"
  if [[ -e $file && ! -e $backup ]]; then
    cp -p "$file" "$backup"
  fi
  touch "$file"
  mode=$(file_mode "$file")
  tmp=$(mktemp "$(dirname -- "$file")/.$(basename -- "$file").leos-profiles.tmp.XXXXXX")
  track_temp "$tmp"
  awk -v begin="# >>> leos-profiles ${marker} >>>" -v end="# <<< leos-profiles ${marker} <<<" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$file" > "$tmp"
  if [[ -s $tmp ]] && [[ -n $(tail -n 1 "$tmp") ]]; then separator=$'\n'; fi
  printf '%s# >>> leos-profiles %s >>>\n%s\n# <<< leos-profiles %s <<<\n' "$separator" "$marker" "$content" "$marker" >> "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$file"
}

zshrc_managed_content() {
  local quoted_target
  printf -v quoted_target '%q' "$TARGET"
  printf '%s\n' "if [[ -z \${LEOS_PROFILES_HOME:-} ]]; then
  LEOS_PROFILES_HOME=$quoted_target
fi
if [[ -o interactive ]]; then
  source \"\$LEOS_PROFILES_HOME/zsh/start.zsh\"
fi"
}

zshenv_managed_content() {
  # These are intentional zsh runtime expansions.
  # shellcheck disable=SC2016
  printf '%s\n' 'typeset -U path
path=("$HOME/.local/bin" "$HOME/.local/npm/bin" $path)
export PATH'
}

# Strip a managed block, leaving the rest of the user's file alone.
#
# This is the supported way to undo the loader, and is strictly safer than
# restoring $file.leos-profiles.bak: that backup is only written the first time a
# block is installed, so months of later edits are not in it.
remove_managed_block() {
  local file=$1 marker=$2 tmp mode
  file=$(resolve_config_path "$file")
  if [[ ! -e $file ]]; then
    say "$file does not exist; nothing to remove"
    return 0
  fi
  managed_block_well_formed "$file" "$marker" || die "Refusing to rewrite malformed managed block in $file"
  if ! grep -qF "# >>> leos-profiles ${marker} >>>" "$file"; then
    say "No leos-profiles $marker block in $file"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would remove the leos-profiles $marker block from $file"
    return 0
  fi
  mode=$(file_mode "$file")
  tmp=$(mktemp "$(dirname -- "$file")/.$(basename -- "$file").leos-profiles.tmp.XXXXXX")
  track_temp "$tmp"
  awk -v begin="# >>> leos-profiles ${marker} >>>" -v end="# <<< leos-profiles ${marker} <<<" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$file" > "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$file"
  say "Removed the leos-profiles $marker block from $file"
}

remove_managed_blocks() {
  remove_managed_block "$HOME/.zshrc" loader
  remove_managed_block "$HOME/.zshenv" environment
  say "Packages, plugins and credentials are left untouched; remove those manually if wanted."
}

install_zsh_config() {
  local zshrc_content zshenv_content
  zshrc_content=$(zshrc_managed_content)
  zshenv_content=$(zshenv_managed_content)
  install_managed_block "$HOME/.zshrc" loader "$zshrc_content"
  install_managed_block "$HOME/.zshenv" environment "$zshenv_content"
}

current_login_shell() {
  local current_shell
  current_shell=$(getent passwd "$USER" 2>/dev/null | awk -F: '{print $7}' || true)
  [[ -n $current_shell ]] || current_shell=$(dscl . -read /Users/"$USER" UserShell 2>/dev/null | awk '{print $2}' || true)
  printf '%s\n' "$current_shell"
}

set_default_shell() {
  [[ $CHANGE_DEFAULT_SHELL == no ]] && { say "Skipping default shell (--default-shell no)"; return 0; }
  local zsh_path
  zsh_path=$(command -v zsh || true)
  if [[ -z $zsh_path && $DRY_RUN -eq 1 ]]; then
    say "Would configure the zsh path installed by the package step as the login shell"
    return 0
  fi
  [[ -n $zsh_path ]] || die "zsh is not installed"
  if [[ $CHANGE_DEFAULT_SHELL == auto ]]; then
    local current_shell
    current_shell=$(current_login_shell)
    [[ ${current_shell##*/} == zsh ]] && { say "Default shell is already zsh"; return 0; }
  fi
  # Identical on both families, so it is hoisted above the branch. The path is
  # passed as an argument rather than interpolated into the program text: this is
  # the one place that would otherwise regress from the argv-safe `run` used
  # everywhere else, and string-built commands are invisible to shellcheck.
  if ! grep -qxF "$zsh_path" /etc/shells; then
    # "$1" is expanded by the inner bash, not here — that is the whole point.
    # shellcheck disable=SC2016
    run_shell "Add $zsh_path to /etc/shells" \
      'printf "%s\n" "$1" | sudo tee -a /etc/shells >/dev/null' "$zsh_path"
  fi
  if [[ $OS_FAMILY == macos ]]; then
    run sudo chsh -s "$zsh_path" "$USER"
  else
    run chsh -s "$zsh_path"
  fi
}

