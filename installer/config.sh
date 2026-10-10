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

# Keep the user's version from before the installer first touched the file.
# Written once only: later runs must not replace it with an installer-edited copy.
backup_config_once() {
  local file=$1 backup="$1.leos-profiles.bak"
  if [[ -e $file && ! -e $backup ]]; then
    cp -p "$file" "$backup"
  fi
}

install_managed_block() {
  local file=$1 marker=$2 content=$3 tmp mode separator=""
  [[ $DRY_RUN -eq 1 ]] && { say "Would install managed block in $file"; return 0; }
  file=$(resolve_config_path "$file")
  mkdir -p "$(dirname -- "$file")"
  managed_block_well_formed "$file" "$marker" || die "Refusing to rewrite malformed managed block in $file"
  managed_block_equals "$file" "$marker" "$content" && return 0
  backup_config_once "$file"
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
  # These are intentional zsh runtime expansions. skip_global_compinit stops
  # Debian/Ubuntu's /etc/zsh/zshrc from running compinit before the profile has
  # put zsh-completions and rbenv on fpath; the profile's own `compinit -C`
  # would otherwise trust that reduced dump for a day.
  # shellcheck disable=SC2016
  printf '%s\n' 'skip_global_compinit=1
typeset -U path
path=("$HOME/.local/bin" "$HOME/.local/npm/bin" $path)
export PATH'
}

# macOS login shells run /etc/zprofile after ~/.zshenv, and its path_helper
# moves every inherited entry behind the system paths, so ~/.local/bin would
# lose to Homebrew's node. ~/.zprofile runs after it and restores the order.
zprofile_managed_content() {
  # shellcheck disable=SC2016
  printf '%s\n' 'typeset -U path
path=("$HOME/.local/bin" "$HOME/.local/npm/bin" $path)
export PATH'
}

# Directories zsh reads its startup files from, cached per HOME/ZDOTDIR.
#
# ZSH_RC_DIR holds .zshrc and .zprofile: ZDOTDIR when the installer's own
# environment sets it, otherwise whatever zsh reports after reading .zshenv
# (XDG-style setups usually set ZDOTDIR there).
#
# ZSH_ENV_DIR holds .zshenv, which zsh reads BEFORE that file can change
# ZDOTDIR. When ~/.zshenv itself sets ZDOTDIR, a new zsh always reads
# ~/.zshenv, even if this installer inherited the exported value; only a
# ZDOTDIR that comes from outside the startup files (launchd, PAM, a terminal
# profile) moves .zshenv as well.
ZSH_DOTDIRS_KEY=""
ZSH_RC_DIR=""
ZSH_ENV_DIR=""
resolve_zsh_dotdirs() {
  local key="$HOME|${ZDOTDIR-}" reported=""
  [[ $ZSH_DOTDIRS_KEY != "$key" ]] || return 0
  if command -v zsh >/dev/null 2>&1; then
    # Single quotes: zsh, not this shell, expands the parameter. The last line
    # only, in case the user's .zshenv prints something itself.
    # shellcheck disable=SC2016
    reported=$(env -u ZDOTDIR zsh -c 'print -r -- ${ZDOTDIR:-$HOME}' </dev/null 2>/dev/null | tail -n 1) || reported=""
  fi
  [[ $reported == /* ]] || reported=$HOME
  [[ $reported == / ]] || reported=${reported%/}
  if [[ $reported != "$HOME" ]]; then
    ZSH_ENV_DIR=$HOME
    ZSH_RC_DIR=${ZDOTDIR:-$reported}
  else
    ZSH_ENV_DIR=${ZDOTDIR:-$HOME}
    ZSH_RC_DIR=${ZDOTDIR:-$HOME}
  fi
  ZSH_DOTDIRS_KEY=$key
}

# Legacy loaders: the pre-installer QUICK-INSTALL appended an unmarked
#   if [[ -o interactive ]]; then
#       source "$HOME/.leos-profiles/zsh/start.zsh"
#   fi
# to .zshrc, and a "# leos-profiles zshenv" header plus a PATH snippet to
# .zshenv. Next to the managed block, the profile would load twice.
#
# legacy_loader_filter <loader|environment> <detect|strip> <file>
# detect: exit 0 when the file has a legacy loader outside managed blocks.
# strip:  print the file without it. The three-line wrapper is removed whole;
#         any other unmarked line sourcing .../zsh/start.zsh is replaced by a
#         no-op, so an enclosing if/function body stays syntactically valid.
legacy_loader_filter() {
  local kind=$1 mode=$2 file=$3 quote="'" path_re loader_re
  path_re="(\"[^\"]*/zsh/start[.]zsh\"|${quote}[^${quote}]*/zsh/start[.]zsh${quote}|[^[:space:]\"${quote};&|]*/zsh/start[.]zsh)"
  loader_re="^[[:space:]]*([[][[][^]]*[]][]][[:space:]]*&&[[:space:]]*)?(source|[.])[[:space:]]+${path_re}[[:space:]]*(#.*)?$"
  awk -v kind="$kind" -v mode="$mode" -v loader_re="$loader_re" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function emit(s) { if (mode == "strip") print s }
    { line[NR] = $0 }
    END {
      inside = 0; found = 0
      for (i = 1; i <= NR; i++) {
        s = line[i]
        if (s ~ /^# >>> leos-profiles [^ ]+ >>>$/) { inside = 1; emit(s); continue }
        if (s ~ /^# <<< leos-profiles [^ ]+ <<<$/) { inside = 0; emit(s); continue }
        if (inside) { emit(s); continue }
        if (kind == "loader") {
          if (trim(s) ~ /^if[ \t]+[[][[][ \t]+-o[ \t]+interactive[ \t]+[]][]][ \t]*;[ \t]*then$/ &&
              i + 2 <= NR && line[i + 1] ~ loader_re && trim(line[i + 2]) == "fi") {
            found = 1; i += 2; continue
          }
          if (s ~ loader_re) {
            found = 1; emit(": # leos-profiles: removed a legacy unmarked start.zsh loader"); continue
          }
        } else if (trim(s) == "# leos-profiles zshenv") {
          found = 1
          if (i + 1 <= NR && trim(line[i + 1]) == "typeset -U path") i++
          if (i + 1 <= NR && trim(line[i + 1]) == "path=(\"$HOME/.local/bin\" $path)") i++
          if (i + 1 <= NR && trim(line[i + 1]) == "export PATH") i++
          continue
        }
        emit(s)
      }
      if (mode == "detect") exit(found ? 0 : 1)
    }
  ' "$file"
}

legacy_loader_present() {
  local file
  file=$(resolve_config_path "$1")
  [[ -f $file ]] && legacy_loader_filter "$2" detect "$file"
}

# Remove a legacy loader in place, preserving mode and symlinks, after taking
# the same one-time backup install_managed_block takes.
strip_legacy_loader() {
  local file=$1 kind=$2 tmp mode
  file=$(resolve_config_path "$file")
  [[ -f $file ]] && legacy_loader_filter "$kind" detect "$file" || return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would remove the legacy unmarked leos-profiles $kind from $file"
    return 0
  fi
  backup_config_once "$file"
  mode=$(file_mode "$file")
  tmp=$(mktemp "$(dirname -- "$file")/.$(basename -- "$file").leos-profiles.tmp.XXXXXX")
  track_temp "$tmp"
  legacy_loader_filter "$kind" strip "$file" > "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$file"
  say "Removed the legacy unmarked leos-profiles $kind from $file"
}

# Inspection records for a pending legacy-loader migration.
report_legacy_loaders() {
  resolve_zsh_dotdirs
  if legacy_loader_present "$ZSH_RC_DIR/.zshrc" loader; then
    printf 'migration\tlegacy-loader\t%s\tloader\n' "$ZSH_RC_DIR/.zshrc"
  fi
  if legacy_loader_present "$ZSH_ENV_DIR/.zshenv" environment; then
    printf 'migration\tlegacy-environment\t%s\tenvironment\n' "$ZSH_ENV_DIR/.zshenv"
  fi
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
  # install_managed_block puts one blank separator line between non-empty user
  # content and the block, so drop exactly that shape too: a single blank line
  # directly after a non-empty line and directly before the begin marker. Any
  # other blank line is printed unchanged. (A user's own trailing blank line
  # before the block looks identical and is also dropped; that loses one empty
  # line, never content, and does not accumulate.)
  awk -v begin="# >>> leos-profiles ${marker} >>>" -v end="# <<< leos-profiles ${marker} <<<" '
    $0 == begin { skip=1; held=0; next }
    $0 == end { skip=0; next }
    skip { next }
    held { print ""; held=0 }
    $0 == "" && last != "" { held=1; last=$0; next }
    { print; last=$0 }
    END { if (held) print "" }
  ' "$file" > "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$file"
  say "Removed the leos-profiles $marker block from $file"
}

remove_managed_blocks() {
  resolve_zsh_dotdirs
  remove_managed_block "$ZSH_RC_DIR/.zshrc" loader
  remove_managed_block "$ZSH_ENV_DIR/.zshenv" environment
  # Only macOS installs this block, but remove it wherever it exists.
  if [[ -e $ZSH_RC_DIR/.zprofile ]]; then
    remove_managed_block "$ZSH_RC_DIR/.zprofile" login-path
  fi
  strip_legacy_loader "$ZSH_RC_DIR/.zshrc" loader
  strip_legacy_loader "$ZSH_ENV_DIR/.zshenv" environment
  say "Packages, plugins and credentials are left untouched; remove those manually if wanted."
}

# Compile the profile and plugin sources to .zwc beside them (see
# __leos_zcompile_profile in zsh/cache.zsh), about 7 ms off every startup.
# main() runs this after the plugins or zsh-config step on every apply and
# reconcile, including when those steps were already verified: a pull changes
# the sources without changing any step's signature. Best effort: Zsh ignores
# a missing, older or other-version .zwc, so a failure only costs that time.
# The login shell's Zsh compiles when it is one, so its version matches.
compile_zsh_sources() {
  local shell_bin=""
  [[ -f $TARGET/zsh/cache.zsh ]] || return 0
  if [[ ${SHELL:-} == */zsh && -x ${SHELL:-} ]]; then
    shell_bin=$SHELL
  else
    shell_bin=$(command -v zsh 2>/dev/null) || return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would compile the profile's Zsh sources with $shell_bin"
    return 0
  fi
  # shellcheck disable=SC2016  # expanded by zsh, not here
  "$shell_bin" -df -c 'source "$1/zsh/cache.zsh" && __leos_zcompile_profile "$1/zsh" && print -r -- "$REPLY"' \
    zsh "$TARGET" >/dev/null 2>&1 ||
    warn "Could not compile the profile's Zsh sources; startup is a few milliseconds slower."
  return 0
}

install_zsh_config() {
  local zshrc_content zshenv_content zprofile_content
  resolve_zsh_dotdirs
  zshrc_content=$(zshrc_managed_content)
  zshenv_content=$(zshenv_managed_content)
  zprofile_content=$(zprofile_managed_content)
  # Migrate first, so the one-time backup holds the user's file as it was.
  strip_legacy_loader "$ZSH_RC_DIR/.zshrc" loader
  strip_legacy_loader "$ZSH_ENV_DIR/.zshenv" environment
  install_managed_block "$ZSH_RC_DIR/.zshrc" loader "$zshrc_content"
  install_managed_block "$ZSH_ENV_DIR/.zshenv" environment "$zshenv_content"
  if [[ $OS_FAMILY == macos ]]; then
    install_managed_block "$ZSH_RC_DIR/.zprofile" login-path "$zprofile_content"
  fi
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

