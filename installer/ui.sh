#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
#
# Terminal UI primitives for `install.sh setup`. With a terminal and gum
# (charmbracelet/gum) the wizard is full screen; otherwise (no gum, TERM=dumb,
# UI_PLAIN=1) it is plain numbered prompts. Either way:
#   - answers are read from UI_TTY (/dev/tty by default; tests point it at a
#     file of answers) through fd 7, which ui_init opens once;
#   - prompts are drawn on stderr, so stdout stays the run's own output;
#   - results come back in UI_REPLY and UI_INDEX, never through $(...), so a
#     stage that calls a primitive can set the installer's globals.
# Cancelling a gum prompt (Esc, Ctrl-C) ends setup with status 130.
#
# Full screen (gum): ui_section starts a page and ui_note adds to it; each
# prompt redraws the whole page on the alternate screen, laid out for the
# terminal's size at that moment, and draws it again when the terminal is
# resized. While the wizard owns the screen the run's own stdout and stderr go
# to a log that ui_screen_end replays on the normal screen, so a warning or
# error is never drawn over a page or lost with it. Once the wizard has left
# the screen (setup is applying), prompts are drawn inline instead.
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

# The theme: indexes into the terminal's own 16-colour palette, so the wizard
# follows the user's colour scheme (light or dark) instead of fixing colours.
UI_ACCENT=6     # cyan: the page title, the current step, the cursor
UI_ATTENTION=3  # yellow: a hint after a bad answer, a warning

# Full screen. UI_SCREEN is 1 while the wizard owns the alternate screen;
# UI_SCREEN_USED once it has left it (later prompts are inline). fd 8 and 9
# are the terminal's stderr and stdout meanwhile.
UI_SCREEN=0
UI_SCREEN_USED=0
UI_SCREEN_OWNER=0
UI_LOG_OUT=""
UI_LOG_ERR=""
UI_LOG_SEEN=0
UI_GUM_FILE=""
UI_RESIZED=0
UI_TRAPPED=0
UI_GUM_STATUS=0
# The page: the header's title and steps, then the page's title, notes, a
# preformatted block and a message (a hint after a bad answer, or a warning
# the run printed), then the question and its prompt.
UI_APP_TITLE=""
UI_STEPS=""
UI_STEP=""
UI_PAGE_TITLE=""
UI_PAGE_NOTES=""
UI_PAGE_BLOCK=""
UI_PAGE_MESSAGE=""
UI_PAGE_PROMPTED=0
# The layout, from ui_size and ui_render: the terminal, the centred column's
# width and left margin, and the rows left under the page for the prompt.
UI_NL=$'\n'
UI_ROWS=24
UI_COLS=80
UI_WIDTH=76
UI_MARGIN=2
UI_FREE=0

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
  ui_screen_end
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

# --- Layout and drawing (gum)

# ui_fullscreen: prompts redraw a full-screen page (gum, until the wizard
# leaves the screen); otherwise gum prompts are drawn inline.
ui_fullscreen() { [[ $UI_MODE == gum && $UI_SCREEN_USED -eq 0 ]]; }

# ui_size: UI_ROWS and UI_COLS become the terminal's size (stty on fd 7, else
# LINES and COLUMNS, else 24x80); UI_WIDTH and UI_MARGIN the text column:
# at most 80 wide, centred.
ui_size() {
  local rows="" cols=""
  read -r rows cols <<< "$(stty size <&7 2>/dev/null || true)" || true
  [[ $rows =~ ^[1-9][0-9]*$ ]] || rows=${LINES:-24}
  [[ $cols =~ ^[1-9][0-9]*$ ]] || cols=${COLUMNS:-80}
  [[ $rows =~ ^[1-9][0-9]*$ ]] || rows=24
  [[ $cols =~ ^[1-9][0-9]*$ ]] || cols=80
  UI_ROWS=$rows UI_COLS=$cols
  if (( cols >= 84 )); then UI_WIDTH=80; elif (( cols >= 24 )); then UI_WIDTH=$((cols - 4)); else UI_WIDTH=$((cols > 12 ? cols - 2 : 10)); fi
  UI_MARGIN=$(( (cols - UI_WIDTH) / 2 ))
  (( UI_MARGIN >= 0 )) || UI_MARGIN=0
}

# ui_sgr <colour>: the SGR parameter for a palette colour as foreground.
ui_sgr() {
  if (( $1 < 8 )); then printf '3%d' "$1"; elif (( $1 < 16 )); then printf '9%d' $(($1 - 8)); else printf '38;5;%d' "$1"; fi
}

# ui_wrap <width> <text>: the text wrapped at spaces to the width.
ui_wrap() {
  [[ -n $2 ]] || return 0
  printf '%s\n' "$2" | fold -s -w "$1" | sed 's/[[:space:]]*$//'
}

# ui_lines <text>: how many lines the text has.
ui_lines() {
  if [[ -z $1 ]]; then printf '0'; else printf '%s\n' "$1" | awk 'END { print NR }'; fi
}

# ui_cut <text> <lines>: at most that many lines of the text; when lines are
# left out, the last one shown is an ellipsis (and nothing at all rather
# than an ellipsis alone).
ui_cut() {
  local total
  total=$(ui_lines "$1")
  if (( $2 <= 0 || ($2 == 1 && total > 1) )); then return 0; fi
  if (( total <= $2 )); then printf '%s\n' "$1"; return 0; fi
  printf '%s\n' "$1" | head -n $(($2 - 1))
  printf '%s\n' '...'
}

# ui_screen_begin: take the alternate screen. The run's stdout and stderr go
# to logs (replayed by ui_screen_end); fd 8 and 9 keep the terminal's. A
# resize (WINCH) interrupts the prompt so the page can be drawn again.
ui_screen_begin() {
  [[ $UI_SCREEN -eq 0 ]] || return 0
  UI_LOG_OUT=$(mktemp "${TMPDIR:-/tmp}/leos-setup-out.XXXXXX")
  UI_LOG_ERR=$(mktemp "${TMPDIR:-/tmp}/leos-setup-err.XXXXXX")
  UI_GUM_FILE=$(mktemp "${TMPDIR:-/tmp}/leos-setup-gum.XXXXXX")
  track_temp "$UI_LOG_OUT"
  track_temp "$UI_LOG_ERR"
  track_temp "$UI_GUM_FILE"
  UI_LOG_SEEN=0
  exec 8>&2 9>&1
  exec 1>>"$UI_LOG_OUT" 2>>"$UI_LOG_ERR"
  UI_SCREEN=1
  UI_SCREEN_OWNER=${BASH_SUBSHELL:-0}
  trap 'UI_RESIZED=1; UI_TRAPPED=1' WINCH
  printf '\033[?1049h\033[H\033[2J' >&8
}

# ui_screen_end: leave the alternate screen and replay what the run printed
# meanwhile. Safe to call at any time (cleanup does, at exit); only the shell
# that took the screen gives it back, never a subshell of it.
ui_screen_end() {
  [[ $UI_SCREEN -eq 1 && ${BASH_SUBSHELL:-0} -eq $UI_SCREEN_OWNER ]] || return 0
  trap - WINCH
  printf '\033[?1049l' >&8
  exec 1>&9 2>&8 8>&- 9>&-
  UI_SCREEN=0
  UI_SCREEN_USED=1
  if [[ -s $UI_LOG_OUT ]]; then cat "$UI_LOG_OUT"; fi
  if [[ -s $UI_LOG_ERR ]]; then cat "$UI_LOG_ERR" >&2; fi
  : > "$UI_LOG_OUT"
  : > "$UI_LOG_ERR"
}

# ui_log_news: the last lines the run printed on stderr since the page was
# last drawn become part of the page's message.
ui_log_news() {
  local total news
  [[ -s $UI_LOG_ERR ]] || return 0
  total=$(awk 'END { print NR }' "$UI_LOG_ERR")
  (( total > UI_LOG_SEEN )) || return 0
  news=$(sed -n "$((UI_LOG_SEEN + 1)),\$p" "$UI_LOG_ERR" | tail -n 3)
  UI_LOG_SEEN=$total
  UI_PAGE_MESSAGE="${UI_PAGE_MESSAGE:+$UI_PAGE_MESSAGE$UI_NL}$news"
}

# ui_page <title>: start a page.
ui_page() {
  UI_PAGE_TITLE=$1 UI_PAGE_NOTES="" UI_PAGE_BLOCK="" UI_PAGE_MESSAGE="" UI_PAGE_PROMPTED=0
}

# ui_steps <step...>: the wizard's steps, shown in the header.
ui_steps() { UI_STEPS="$*"; }

# ui_step <step>: the step the following pages belong to.
ui_step() { UI_STEP=$1; }

# ui_header_line <width>: the header: the title, and the steps on the right
# with the current one highlighted; as much of the steps as fits.
ui_header_line() {
  local width=$1 accent step text="" plain="" index=0 current=0 total=0 room
  accent=$(ui_sgr "$UI_ACCENT")
  for step in $UI_STEPS; do
    total=$((total + 1))
    [[ $step != "$UI_STEP" ]] || current=$total
    plain="${plain:+$plain   }$step"
  done
  room=$((width - ${#UI_APP_TITLE} - 2))
  if (( total > 0 && ${#plain} <= room )); then
    for step in $UI_STEPS; do
      index=$((index + 1))
      [[ -z $text ]] || text="$text   "
      if (( index == current )); then text="$text"$'\033[1;'"${accent}m$step"$'\033[0m'
      else text="$text"$'\033[2m'"$step"$'\033[0m'; fi
    done
  elif (( current > 0 && ${#UI_STEP} + 8 <= room )); then
    plain="$UI_STEP  $current/$total"
    text=$'\033[1;'"${accent}m$UI_STEP"$'\033[0m\033[2m'"  $current/$total"$'\033[0m'
  elif (( current > 0 && 5 <= room )); then
    plain="$current/$total"
    text=$'\033[2m'"$plain"$'\033[0m'
  else
    plain="" text=""
  fi
  printf '\033[1;%sm%s\033[0m%*s%s' "$accent" "$UI_APP_TITLE" $((width - ${#UI_APP_TITLE} - ${#plain})) '' "$text"
}

# ui_render <question> <rows the prompt needs>: draw the page on the
# alternate screen for the terminal's current size, then the question;
# UI_FREE becomes the rows left under it. Where the page does not fit, the
# block gives way first (ending in an ellipsis), then the notes, then the
# message; on a very short terminal the header goes too.
ui_render() {
  local question=$1 need=$2 accent attention width notes block message asked
  local n_notes n_block n_message n_asked fixed room header=1 top=1 line used=0
  ui_screen_begin
  ui_size
  ui_log_news
  width=$UI_WIDTH
  accent=$(ui_sgr "$UI_ACCENT")
  attention=$(ui_sgr "$UI_ATTENTION")
  notes=$(ui_wrap "$width" "$UI_PAGE_NOTES")
  block=$(printf '%s\n' "$UI_PAGE_BLOCK" | cut -c "1-$width")
  [[ -n $UI_PAGE_BLOCK ]] || block=""
  message=$(ui_wrap "$width" "$UI_PAGE_MESSAGE")
  asked=$(ui_wrap "$width" "$question")
  n_notes=$(ui_lines "$notes") n_block=$(ui_lines "$block")
  n_message=$(ui_lines "$message") n_asked=$(ui_lines "$asked")
  (( UI_ROWS >= 20 )) || top=0
  # header + rule + blank, title + blank, the question and a blank before it.
  fixed=$((top + 3 + 2 + n_asked + (n_asked > 0 ? 1 : 0) + need))
  if (( fixed > UI_ROWS )); then header=0 top=0 fixed=$((fixed - 3)); fi
  room=$((UI_ROWS - fixed))
  (( room >= 0 )) || room=0
  # The body's parts, each after a blank line, in order of what gives way.
  if (( n_message > 0 )); then
    (( n_message + 1 <= room )) || { n_message=$(( room > 1 ? room - 1 : 0 )); message=$(ui_cut "$message" "$n_message"); }
    n_message=$(ui_lines "$message")
    room=$((room - (n_message > 0 ? n_message + 1 : 0)))
  fi
  if (( n_notes > 0 )); then
    (( n_notes + 1 <= room )) || { n_notes=$(( room > 1 ? room - 1 : 0 )); notes=$(ui_cut "$notes" "$n_notes"); }
    n_notes=$(ui_lines "$notes")
    room=$((room - (n_notes > 0 ? n_notes + 1 : 0)))
  fi
  if (( n_block > 0 )); then
    (( n_block + 1 <= room )) || { n_block=$(( room > 1 ? room - 1 : 0 )); block=$(ui_cut "$block" "$n_block"); }
    n_block=$(ui_lines "$block")
  fi
  {
    printf '\033[H\033[2J'
    if (( top )); then printf '\n'; used=$((used + 1)); fi
    if (( header )); then
      printf '%*s%s\n' "$UI_MARGIN" '' "$(ui_header_line "$width")"
      printf '%*s\033[2;4m%*s\033[0m\n\n' "$UI_MARGIN" '' "$width" ''
      used=$((used + 3))
    fi
    printf '%*s\033[1;%sm%s\033[0m\n' "$UI_MARGIN" '' "$accent" "$UI_PAGE_TITLE"
    used=$((used + 1))
    if (( n_notes > 0 )); then
      printf '\n'; used=$((used + 1))
      while IFS= read -r line; do printf '%*s%s\n' "$UI_MARGIN" '' "$line"; used=$((used + 1)); done <<< "$notes"
    fi
    if (( n_block > 0 )); then
      printf '\n'; used=$((used + 1))
      while IFS= read -r line; do printf '%*s%s\n' "$UI_MARGIN" '' "$line"; used=$((used + 1)); done <<< "$block"
    fi
    if (( n_message > 0 )); then
      printf '\n'; used=$((used + 1))
      while IFS= read -r line; do printf '%*s\033[%sm%s\033[0m\n' "$UI_MARGIN" '' "$attention" "$line"; used=$((used + 1)); done <<< "$message"
    fi
    if (( n_asked > 0 )); then
      printf '\n'; used=$((used + 1))
      while IFS= read -r line; do printf '%*s\033[1m%s\033[0m\n' "$UI_MARGIN" '' "$line"; used=$((used + 1)); done <<< "$asked"
    fi
  } >&8
  UI_FREE=$((UI_ROWS - used))
}

# ui_inline_question <question>: inline gum: the question, wrapped to the
# terminal.
ui_inline_question() {
  local line
  ui_size
  printf '\n' >&2
  while IFS= read -r line; do
    printf '\033[1m%s\033[0m\n' "$line" >&2
  done <<< "$(ui_wrap $((UI_COLS > 82 ? 80 : (UI_COLS > 12 ? UI_COLS - 2 : 10))) "$1")"
}

# ui_gum <gum argument...>: run a gum prompt on the terminal; its answer goes
# to UI_GUM_FILE and its status to UI_GUM_STATUS. Full screen, gum runs in
# the background so a resize (the WINCH trap) can interrupt the wait: the
# prompt is stopped and ui_gum fails, and the caller draws the page again
# and asks again.
ui_gum() {
  local pid status
  if [[ -z $UI_GUM_FILE ]]; then
    UI_GUM_FILE=$(mktemp "${TMPDIR:-/tmp}/leos-setup-gum.XXXXXX")
    track_temp "$UI_GUM_FILE"
  fi
  : > "$UI_GUM_FILE"
  UI_RESIZED=0
  if [[ $UI_SCREEN -eq 1 ]]; then
    "$GUM" "$@" <&7 >"$UI_GUM_FILE" 2>&8 &
  else
    "$GUM" "$@" <&7 >"$UI_GUM_FILE" &
  fi
  pid=$!
  while :; do
    UI_TRAPPED=0
    status=0
    wait "$pid" 2>/dev/null || status=$?
    [[ $UI_TRAPPED -eq 1 ]] || break
    kill "$pid" 2>/dev/null || true
  done
  UI_GUM_STATUS=$status
  [[ $UI_RESIZED -eq 0 ]]
}

# ui_gum_left: gum's padding that lines a prompt up with the page's column.
ui_gum_left() {
  if [[ $UI_SCREEN -eq 1 ]]; then printf '0 0 0 %d' "$UI_MARGIN"; else printf '0 0'; fi
}

# ui_gum_choose <question> <limit: 1 or 0 for any> <selected csv> <option...>:
# a themed gum choose, sized to the rows the page leaves; the chosen options
# end up one per line in UI_GUM_FILE.
ui_gum_choose() {
  local question=$1 limit=$2 selected=$3 count height need accent
  shift 3
  count=$#
  accent=$UI_ACCENT
  while :; do
    # The list, a blank and gum's key help; when the list scrolls, gum adds
    # a page indicator and a blank.
    need=$((count + 2))
    (( need <= 8 )) || need=8
    if ui_fullscreen; then
      ui_render "$question" "$need"
      if (( count + 2 <= UI_FREE )); then height=$count; else height=$((UI_FREE - 4)); fi
    else
      ui_inline_question "$question"
      ui_size
      height=$((UI_ROWS - 8))
      (( height < count )) || height=$count
    fi
    (( height >= 1 )) || height=1
    local -a args=(choose --header "" --height "$height" --padding "$(ui_gum_left)"
      --cursor "> " --cursor-prefix "[ ] " --selected-prefix "[x] " --unselected-prefix "[ ] "
      --cursor.foreground "$accent" --selected.foreground ""
      --header.foreground "$accent" --item.foreground "")
    if [[ $limit -eq 0 ]]; then args+=(--no-limit); fi
    [[ -z $selected ]] || args+=(--selected "$selected")
    if ui_gum "${args[@]}" "$@"; then break; fi
  done
  [[ $UI_GUM_STATUS -eq 0 ]] || ui_cancelled
  UI_PAGE_PROMPTED=1 UI_PAGE_MESSAGE=""
}

# --- Pages

# ui_header <title> <subtitle>: the wizard's title, and its first page.
ui_header() {
  if [[ $UI_MODE == gum ]]; then
    UI_APP_TITLE=$1
    ui_page "Set up this machine"
    UI_PAGE_NOTES=$2
  else
    printf '\n%s\n%s\n%s\n' "${UI_BOLD}== $1 ==${UI_RESET}" "$2" "" >&2
  fi
}

# ui_section <title>: a new page (inline: a heading).
ui_section() {
  if ui_fullscreen; then
    ui_page "$1"
  elif [[ $UI_MODE == gum ]]; then
    printf '\n\033[1;%sm%s\033[0m\n' "$(ui_sgr "$UI_ACCENT")" "$1" >&2
  else
    printf '\n%s\n' "${UI_BOLD}-- $1 --${UI_RESET}" >&2
  fi
}

# ui_note <text>: an explanation on the page. After the page's first prompt,
# it is a hint for the next one (shown once, highlighted).
ui_note() {
  if ui_fullscreen; then
    if [[ $UI_PAGE_PROMPTED -eq 0 ]]; then
      UI_PAGE_NOTES="${UI_PAGE_NOTES:+$UI_PAGE_NOTES$UI_NL$UI_NL}$1"
    else
      UI_PAGE_MESSAGE="${UI_PAGE_MESSAGE:+$UI_PAGE_MESSAGE$UI_NL}$1"
    fi
  elif [[ $UI_MODE == gum ]]; then
    ui_size
    ui_wrap $((UI_COLS > 82 ? 80 : (UI_COLS > 12 ? UI_COLS - 2 : 10))) "$1" >&2
  else
    printf '%s\n' "$1" | fold -s -w 78 >&2
  fi
}

# ui_status <title> <text>: a page with nothing to answer, shown while setup
# works (inline and plain: a heading and the text).
ui_status() {
  ui_section "$1"
  ui_note "$2"
  if ui_fullscreen; then ui_render "" 0; fi
}

# ui_review <title> <summary file> <full file> <question> [warnings]: show a
# summary and ask whether to go ahead; succeeds for yes. The summary is a
# line of prose, a blank line, then preformatted lines; the warnings, one per
# line, are highlighted. Full screen, the full text opens in
# a pager on request, and the wizard leaves the screen either way, the
# summary staying on the normal screen as a record. Plain and inline, the
# full text is printed on stdout before the question.
ui_review() {
  local title=$1 summary=$2 full=$3 question=$4 warnings=${5:-}
  if ! ui_fullscreen; then
    cat "$full"
    printf '\n'
    ui_confirm "$question" yes
    return
  fi
  while :; do
    ui_page "$title"
    UI_PAGE_NOTES="$(sed -n '1p' "$summary")"$'\n\n'"Nothing has changed yet. The full plan lists every package, file, release and root action."
    UI_PAGE_BLOCK=$(sed '1,2d' "$summary")
    UI_PAGE_MESSAGE=$warnings
    ui_gum_choose "$question" 1 "Yes: apply it" "Yes: apply it" "Read the full plan" "No: change nothing"
    case $(sed -n '1p' "$UI_GUM_FILE") in
      "Read the full plan")
        # The pager leaves the alternate screen when it quits; take it back.
        "$GUM" pager --soft-wrap --show-line-numbers=false --border-foreground 8 \
          --match.foreground "$UI_ACCENT" --match-highlight.foreground 0 \
          --match-highlight.background "$UI_ACCENT" --help.foreground "" \
          "$(cat "$full")" <&7 >&8 2>&8 || true
        printf '\033[?1049h' >&8 ;;
      "Yes: apply it")
        ui_screen_end
        printf '\n%s\n' "${UI_BOLD}$UI_APP_TITLE: applying this plan${UI_RESET}"
        cat "$summary"
        return 0 ;;
      *)
        ui_screen_end
        return 1 ;;
    esac
  done
}

# --- Prompts

# ui_choose <prompt> <default index> <option...>: UI_INDEX (0-based) and
# UI_REPLY (the option) become the choice.
ui_choose() {
  local prompt=$1 default=$2 out i
  shift 2
  local -a options=("$@")
  if [[ $UI_MODE == gum ]]; then
    ui_gum_choose "$prompt" 1 "${options[default]}" "${options[@]}"
    out=$(sed -n '1p' "$UI_GUM_FILE")
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
  local prompt=$1 defaults=$2 i token selected="" line bad
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
    ui_gum_choose "$prompt" 0 "$selected" "${options[@]}"
    UI_REPLY=""
    for i in "${!options[@]}"; do
      while IFS= read -r line; do
        if [[ $line == "${options[i]}" ]]; then UI_REPLY="${UI_REPLY:+$UI_REPLY }$i"; break; fi
      done < "$UI_GUM_FILE"
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

# ui_confirm <prompt> <yes|no default>: succeeds for yes. With gum, a Yes/No
# list like every other question.
ui_confirm() {
  local prompt=$1 default=$2
  if [[ $UI_MODE == gum ]]; then
    if [[ $default == yes ]]; then ui_gum_choose "$prompt" 1 Yes Yes No; else ui_gum_choose "$prompt" 1 No Yes No; fi
    [[ $(sed -n '1p' "$UI_GUM_FILE") == Yes ]]
    return
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
  local prompt=$1 default=$2 width
  if [[ $UI_MODE == gum ]]; then
    while :; do
      if ui_fullscreen; then
        ui_render "$prompt" 3
        width=$((UI_WIDTH - 2))
      else
        ui_inline_question "$prompt"
        width=$((UI_COLS > 82 ? 78 : (UI_COLS > 14 ? UI_COLS - 4 : 10)))
      fi
      if ui_gum input --prompt "> " --value "$default" --placeholder "" --width "$width" \
        --padding "$(ui_gum_left)" --prompt.foreground "$UI_ACCENT" --cursor.foreground "$UI_ACCENT"; then
        break
      fi
    done
    [[ $UI_GUM_STATUS -eq 0 ]] || ui_cancelled
    UI_PAGE_PROMPTED=1 UI_PAGE_MESSAGE=""
    UI_REPLY=$(cat "$UI_GUM_FILE")
    UI_REPLY=${UI_REPLY:-$default}
    return 0
  fi
  if [[ -n $default ]]; then printf '%s [%s]: ' "$prompt" "$default" >&2; else printf '%s: ' "$prompt" >&2; fi
  ui_read_line
  UI_REPLY=${UI_LINE:-$default}
}
