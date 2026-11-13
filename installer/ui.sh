#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
#
# Terminal UI primitives for `install.sh setup`. With a terminal and gum
# (charmbracelet/gum) they are gum's prompts; otherwise (no gum, TERM=dumb,
# UI_PLAIN=1) plain numbered prompts. Either way:
#   - answers are read from UI_TTY (/dev/tty by default; tests point it at a
#     file of answers) through fd 7, which ui_init opens once;
#   - prompts are drawn on stderr, so stdout stays the run's own output;
#   - results come back in UI_REPLY and UI_INDEX, never through $(...), so a
#     stage that calls a primitive can set the installer's globals.
# Cancelling a gum prompt (Esc, Ctrl-C) ends setup with status 130.
# shellcheck disable=SC2034

UI_TTY=${UI_TTY:-/dev/tty}
UI_MODE=plain
GUM=""
UI_REPLY=""
UI_INDEX=0
UI_LINE=""
UI_BOLD=""
UI_DIM=""
UI_RESET=""
# Set once setup starts changing the host, for the cancel message.
SETUP_APPLYING=0

# ui_terminal_available: UI_TTY can be opened for reading.
ui_terminal_available() { { : <"$UI_TTY"; } 2>/dev/null; }

# ui_init: open UI_TTY on fd 7 and choose gum or plain prompts. gum needs the
# input and stderr to be a terminal and TERM not dumb; ensure_gum then finds
# or fetches it.
ui_init() {
  ui_terminal_available || die "setup needs a terminal to ask its questions (could not open $UI_TTY). For an unattended install run: bash $TARGET/install.sh apply --yes"
  exec 7<"$UI_TTY"
  UI_MODE=plain
  if [[ -t 2 && ${TERM:-dumb} != dumb ]]; then
    UI_BOLD=$'\033[1m' UI_DIM=$'\033[2m' UI_RESET=$'\033[0m'
  fi
  if [[ ${UI_PLAIN:-0} == 1 || ${TERM:-dumb} == dumb ]] || ! [[ -t 7 && -t 2 ]]; then
    return 0
  fi
  if ensure_gum; then
    UI_MODE=gum
  else
    warn "gum is not available; using plain prompts"
  fi
}

# ensure_gum: GUM becomes a working gum: the one on PATH; on macOS with
# Homebrew, `brew install gum` (not in a dry run); otherwise the newest gum
# release at least MIN_RELEASE_AGE days old, downloaded into a temporary
# directory and checked like every release artifact (github_release_pick:
# GitHub's SHA-256 digest and, when gh is logged in, the attestation).
# Fails when none works; setup then uses plain prompts.
ensure_gum() {
  local candidate
  GUM=""
  if candidate=$(command -v gum 2>/dev/null) && "$candidate" --version >/dev/null 2>&1; then
    GUM=$candidate
    return 0
  fi
  if [[ $OS_FAMILY == macos && $DRY_RUN -eq 0 ]] && command -v brew >/dev/null 2>&1; then
    say "Installing gum (the setup's terminal UI) with Homebrew"
    if brew install gum >&2; then
      candidate=$(command -v gum 2>/dev/null) || candidate="$(brew --prefix 2>/dev/null || true)/bin/gum"
      if [[ -x $candidate ]] && "$candidate" --version >/dev/null 2>&1; then
        GUM=$candidate
        return 0
      fi
    fi
    warn "brew install gum did not give a working gum"
  fi
  ensure_gum_release
}

# ensure_gum_release: download gum's release into a temporary directory (in a
# subshell, so a failed pick or check falls back instead of ending setup).
ensure_gum_release() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/leos-gum.XXXXXX") || return 1
  track_temp "$dir"
  say "Downloading gum (the setup's terminal UI) from github.com/$GUM_REPOSITORY"
  if ! (gum_release_fetch "$dir") >/dev/null 2>"$dir/log"; then
    sed 's/^/  /' "$dir/log" >&2 || true
    return 1
  fi
  "$dir/bin/gum" --version >/dev/null 2>&1 || return 1
  GUM="$dir/bin/gum"
}

# gum_release_fetch <dir>: install gum's picked release as <dir>/bin/gum,
# keeping every temporary file under <dir>. Downloads even in a dry run: gum
# is the UI, not a change to the host.
gum_release_fetch() {
  local -x TMPDIR=$1
  local DRY_RUN=0
  github_release_pick "$GUM_REPOSITORY" "$GUM_RELEASE_ASSET" || return 1
  install_archive_binary gum tar.gz "$RELEASE_URL" "$RELEASE_SHA" "$1/bin/gum" "$GUM_REPOSITORY" || return 1
}

ui_cancelled() {
  if [[ $SETUP_APPLYING -eq 1 ]]; then
    printf '%s\n' "Setup cancelled. Finish later with: bash $TARGET/install.sh setup (choose the saved choices)" >&2
  else
    printf '%s\n' "Setup cancelled; nothing was changed." >&2
  fi
  exit 130
}

# ui_read_line: UI_LINE becomes the next answer.
ui_read_line() {
  UI_LINE=""
  IFS= read -r UI_LINE <&7 || {
    [[ -n $UI_LINE ]] || { printf '\n%s\n' "setup: no more input from $UI_TTY" >&2; ui_cancelled; }
  }
  UI_LINE=${UI_LINE%$'\r'}
}

# ui_header <title> <subtitle>
ui_header() {
  if [[ $UI_MODE == gum ]]; then
    "$GUM" style --border rounded --border-foreground 212 --padding '0 2' --margin '1 0' \
      "$("$GUM" style --bold --foreground 212 "$1")" "$2" >&2
  else
    printf '\n%s\n%s\n%s\n' "${UI_BOLD}== $1 ==${UI_RESET}" "$2" "" >&2
  fi
}

# ui_section <title>
ui_section() {
  if [[ $UI_MODE == gum ]]; then
    printf '\n' >&2
    "$GUM" style --bold --foreground 212 "$1" >&2
  else
    printf '\n%s\n' "${UI_BOLD}-- $1 --${UI_RESET}" >&2
  fi
}

# ui_note <text>: an explanation under a section.
ui_note() {
  if [[ $UI_MODE == gum ]]; then
    "$GUM" style --foreground 245 --width 78 "$1" >&2
  else
    printf '%s\n' "$1" | fold -s -w 78 >&2
  fi
}

# ui_choose <prompt> <default index> <option...>: UI_INDEX (0-based) and
# UI_REPLY (the option) become the choice.
ui_choose() {
  local prompt=$1 default=$2 out i
  shift 2
  local -a options=("$@")
  if [[ $UI_MODE == gum ]]; then
    out=$("$GUM" choose --header "$prompt" --selected "${options[default]}" "${options[@]}" <&7) || ui_cancelled
    for i in "${!options[@]}"; do
      if [[ ${options[i]} == "$out" ]]; then UI_INDEX=$i; UI_REPLY=$out; return 0; fi
    done
    ui_cancelled
  fi
  printf '\n%s\n' "${UI_BOLD}$prompt${UI_RESET}" >&2
  for i in "${!options[@]}"; do
    if (( i == default )); then
      printf '  %d) %s  %s\n' "$((i + 1))" "${options[i]}" "${UI_DIM}(default)${UI_RESET}" >&2
    else
      printf '  %d) %s\n' "$((i + 1))" "${options[i]}" >&2
    fi
  done
  while :; do
    printf 'Choose 1-%d [%d]: ' "${#options[@]}" "$((default + 1))" >&2
    ui_read_line
    if [[ -z $UI_LINE ]]; then
      UI_INDEX=$default
    elif [[ $UI_LINE =~ ^[0-9]{1,4}$ ]] && (( 10#$UI_LINE >= 1 && 10#$UI_LINE <= ${#options[@]} )); then
      UI_INDEX=$((10#$UI_LINE - 1))
    else
      printf 'Please enter a number from 1 to %d.\n' "${#options[@]}" >&2
      continue
    fi
    UI_REPLY=${options[UI_INDEX]}
    return 0
  done
}

# ui_multi <prompt> <default indices (space-separated)> <option...>: UI_REPLY
# becomes the chosen indices, space-separated, in option order (empty for
# none). Options must not contain commas (gum's --selected splits on them).
ui_multi() {
  local prompt=$1 defaults=$2 out i token selected="" line bad
  shift 2
  local -a options=("$@") flags=()
  for i in "${!options[@]}"; do
    flags[i]=0
    [[ " $defaults " != *" $i "* ]] || flags[i]=1
  done
  if [[ $UI_MODE == gum ]]; then
    for i in "${!options[@]}"; do
      [[ ${flags[i]} -eq 0 ]] || selected="${selected:+$selected,}${options[i]}"
    done
    local -a args=(choose --no-limit --header "$prompt")
    [[ -z $selected ]] || args+=(--selected "$selected")
    out=$("$GUM" "${args[@]}" "${options[@]}" <&7) || ui_cancelled
    UI_REPLY=""
    for i in "${!options[@]}"; do
      while IFS= read -r line; do
        if [[ $line == "${options[i]}" ]]; then UI_REPLY="${UI_REPLY:+$UI_REPLY }$i"; break; fi
      done <<< "$out"
    done
    return 0
  fi
  while :; do
    printf '\n%s\n' "${UI_BOLD}$prompt${UI_RESET}" >&2
    for i in "${!options[@]}"; do
      if [[ ${flags[i]} -eq 1 ]]; then token='[x]'; else token='[ ]'; fi
      printf '  %2d) %s %s\n' "$((i + 1))" "$token" "${options[i]}" >&2
    done
    printf 'Numbers to toggle (e.g. "2 5"), "all", "none", or Enter to accept: ' >&2
    ui_read_line
    [[ -n ${UI_LINE//[[:space:]]/} ]] || break
    bad=""
    for token in $UI_LINE; do
      case $token in
        all) for i in "${!options[@]}"; do flags[i]=1; done ;;
        none) for i in "${!options[@]}"; do flags[i]=0; done ;;
        *)
          if [[ $token =~ ^[0-9]{1,4}$ ]] && (( 10#$token >= 1 && 10#$token <= ${#options[@]} )); then
            i=$((10#$token - 1))
            flags[i]=$((1 - flags[i]))
          else
            bad="$bad $token"
          fi ;;
      esac
    done
    [[ -z $bad ]] || printf 'Ignored:%s (use numbers from 1 to %d)\n' "$bad" "${#options[@]}" >&2
  done
  UI_REPLY=""
  for i in "${!options[@]}"; do
    [[ ${flags[i]} -eq 0 ]] || UI_REPLY="${UI_REPLY:+$UI_REPLY }$i"
  done
}

# ui_confirm <prompt> <yes|no default>: succeeds for yes.
ui_confirm() {
  local prompt=$1 default=$2 status=0
  if [[ $UI_MODE == gum ]]; then
    "$GUM" confirm --default="$([[ $default == yes ]] && printf true || printf false)" "$prompt" <&7 || status=$?
    case $status in
      0) return 0 ;;
      1) return 1 ;;
      *) ui_cancelled ;;
    esac
  fi
  while :; do
    if [[ $default == yes ]]; then printf '%s [Y/n]: ' "$prompt" >&2; else printf '%s [y/N]: ' "$prompt" >&2; fi
    ui_read_line
    case $UI_LINE in
      '') if [[ $default == yes ]]; then return 0; fi; return 1 ;;
      y|Y|yes|Yes|YES) return 0 ;;
      n|N|no|No|NO) return 1 ;;
      *) printf 'Please answer y or n.\n' >&2 ;;
    esac
  done
}

# ui_input <prompt> <default>: UI_REPLY becomes the answer (the default for
# an empty one).
ui_input() {
  local prompt=$1 default=$2 out
  if [[ $UI_MODE == gum ]]; then
    out=$("$GUM" input --prompt "$prompt: " --value "$default" <&7) || ui_cancelled
    UI_REPLY=${out:-$default}
    return 0
  fi
  if [[ -n $default ]]; then printf '%s [%s]: ' "$prompt" "$default" >&2; else printf '%s: ' "$prompt" >&2; fi
  ui_read_line
  UI_REPLY=${UI_LINE:-$default}
}
