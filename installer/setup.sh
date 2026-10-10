#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
#
# `install.sh setup`: the interactive front end, run in the user's own
# terminal (ONB-1, ONB-7). It asks the questions, shows the complete plan and
# runs `install.sh apply --yes` (or `reconcile --yes`) with explicit flags.
# It holds no provisioning logic of its own: the plan, the implied groups,
# the packages and every finding come from `install.sh inspect` (parsed by
# record type, keeping empty columns) and from the engine functions inspect
# uses (normalise_dependencies, validate_options, package_list_for_group);
# running the plan is the same apply path any other caller uses.
#
# Bash 3.2: plain `read` and `printf`, no associative arrays, no TUI tools.
# shellcheck disable=SC2034

SETUP_PRINT_COMMAND=0
SETUP_DRY_RUN=0
SETUP_MODE=apply            # apply (a new selection) or reconcile (the saved one)
SETUP_PLAN=""               # inspect records for the current choices
SETUP_PLAN_KEY=""           # the inspect argv that produced SETUP_PLAN
SETUP_LOG=""
SETUP_CHANGED=0             # set once an apply/reconcile has run
SETUP_CONFLICT_ASKED=0
SETUP_RECONCILE_FULL_UPGRADE=0
SETUP_ARGS=()
SETUP_ATTEMPT=""
SETUP_STATUS=0
SETUP_REPLAN=0
W_BOLD="" W_WARN="" W_RESET=""
W_WIDTH=78
# Records are re-split on this separator before `read`: a tab in IFS is
# whitespace, so read would merge empty TSV columns (development.md: keep
# empty columns).
US=$'\037'

# The wizard's choices. Defaults are the engine's own (Recommended): the
# component and group selection install.sh starts with.
setup_reset_choices() {
  S_STEPS=$SETUP_RECOMMENDED_STEPS
  S_GROUPS=$SETUP_RECOMMENDED_GROUPS
  S_SSH=skip S_SSH_KEY="" S_SSH_PASS=prompt S_SSH_CONFIG=no
  S_GPG=skip S_GPG_KEY="" S_GPG_PASS=prompt S_GPG_EXPIRY=2y
  S_SIGNING=skip S_FONTS=auto S_FONT="" S_SHELL=auto S_FULL_UPGRADE=yes
  S_BREW_MIRROR="" S_GIT_NAME="" S_GIT_EMAIL="" S_SKIP_EXISTING=0
  S_NODE_VERSION=""
}

# ---------------------------------------------------------------------------
# Output: plain text wrapped to the terminal (at most 78 columns), with bold
# and colour only on a terminal that wants them (NO_COLOR, TERM=dumb).
setup_init_terminal() {
  local cols=""
  if [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    W_BOLD=$'\033[1m' W_WARN=$'\033[33m' W_RESET=$'\033[0m'
  fi
  cols=$(stty size 2>/dev/null | awk '{ print $2 }') || cols=""
  if [[ $cols =~ ^[0-9]+$ ]] && (( cols >= 40 && cols < 80 )); then W_WIDTH=$((cols - 2)); fi
}

# w_wrap <width> <text>: text folded at spaces, HOME shortened to ~ so paths
# stay readable in 80 columns.
w_wrap() {
  local home=$HOME/
  [[ ${#HOME} -gt 1 ]] || home=""
  # awk's index(), not ${text//...}: pattern substitution treats the path as
  # a pattern, and Bash 3.2 mishandles a quoted one.
  printf '%s\n' "$2" | awk -v home="$home" '
    home != "" { line = $0; out = ""
      while ((i = index(line, home)) > 0) { out = out substr(line, 1, i - 1) "~/"; line = substr(line, i + length(home)) }
      $0 = out line }
    { print }' | fold -s -w "$1" | sed 's/ *$//'
}

# w_para <indent> <text>: a wrapped paragraph.
w_para() {
  local indent=$1 pad
  shift
  pad=$(printf '%*s' "$indent" '')
  w_wrap $((W_WIDTH - indent)) "$*" | awk -v pad="$pad" '{ print pad $0 }'
}

# w_item <indent> <text>: a wrapped "- " list item with a hanging indent.
w_item() {
  local indent=$1 pad
  shift
  pad=$(printf '%*s' "$indent" '')
  w_wrap $((W_WIDTH - indent - 2)) "$*" |
    awk -v pad="$pad" 'NR == 1 { print pad "- " $0; next } { print pad "  " $0 }'
}

# w_field <label> <text>: "Label: text", continuation lines under the text.
w_field() {
  local label=$1
  shift
  [[ -n $* ]] || return 0
  w_wrap $((W_WIDTH - 19)) "$*" |
    awk -v label="$label:" 'NR == 1 { printf "%-18s %s\n", label, $0; next } { printf "%19s%s\n", "", $0 }'
}

w_heading() { printf '\n%s== %s ==%s\n' "$W_BOLD" "$1" "$W_RESET"; }
w_warn() { printf '%s' "$W_WARN"; w_para 0 "$*"; printf '%s' "$W_RESET"; }

# setup_join [separator]: stdin lines joined on one line.
setup_join() { awk -v sep="${1:-, }" 'NF { printf "%s%s", s, $0; s = sep } END { if (s != "") printf "\n" }'; }

# ---------------------------------------------------------------------------
# Input. Every answer is one line; end of input (Ctrl-D) or `q` quits.
setup_quit() {
  printf '\n'
  if [[ $SETUP_CHANGED -eq 0 ]]; then
    w_para 0 "Setup cancelled. Nothing was changed."
  else
    w_para 0 "Setup stopped. To finish later, run: bash $TARGET/install.sh setup${SETUP_LOG:+ (output so far: $SETUP_LOG)}"
  fi
  exit 1
}

# setup_read <variable>: one trimmed line from the terminal.
setup_read() {
  local __line
  if ! IFS= read -r __line; then setup_quit; fi
  __line=${__line#"${__line%%[![:space:]]*}"}
  __line=${__line%"${__line##*[![:space:]]}"}
  printf -v "$1" '%s' "$__line"
}

# setup_choose <variable> <question> <default> <option>...: a numbered
# single-select; the default is marked with *. Sets the variable to the
# chosen number. A default of 0 means there is none: a number is required.
setup_choose() {
  local __var=$1 __question=$2 __default=$3 __answer __i=1 __option __mark __hint
  shift 3
  printf '\n%s' "$W_BOLD"; w_para 0 "$__question"; printf '%s' "$W_RESET"
  for __option in "$@"; do
    __mark=' '
    [[ $__i != "$__default" ]] || __mark='*'
    w_wrap $((W_WIDTH - 7)) "$__option" |
      awk -v n="$__i" -v mark="$__mark" 'NR == 1 { printf " %s%2d) %s\n", mark, n, $0; next } { print "       " $0 }'
    __i=$((__i + 1))
  done
  __hint="[$__default]"
  [[ $__default != 0 ]] || __hint=""
  while :; do
    printf 'Choose 1-%s%s, q to quit: ' "$#" "${__hint:+ $__hint}"
    setup_read __answer
    [[ -n $__answer || $__default == 0 ]] || __answer=$__default
    [[ $__answer != q ]] || setup_quit
    if [[ $__answer =~ ^[0-9]+$ ]] && (( __answer >= 1 && __answer <= $# )); then
      printf -v "$__var" '%s' "$__answer"
      return 0
    fi
    printf 'Type a number from 1 to %s.\n' "$#"
  done
}

# setup_yesno <variable> <question> <y|n>: sets the variable to y or n.
setup_yesno() {
  local __var=$1 __question=$2 __default=$3 __answer __hint="[y/N]"
  [[ $__default == n ]] || __hint="[Y/n]"
  while :; do
    printf '%s %s: ' "$__question" "$__hint"
    setup_read __answer
    case $__answer in
      '') printf -v "$__var" '%s' "$__default"; return 0 ;;
      y|Y|yes|YES|Yes) printf -v "$__var" y; return 0 ;;
      n|N|no|NO|No) printf -v "$__var" n; return 0 ;;
      q) setup_quit ;;
      *) printf 'Answer y or n.\n' ;;
    esac
  done
}

# setup_text <variable> <prompt> [default]: free text; Enter takes the default.
setup_text() {
  local __var=$1 __prompt=$2 __default=${3:-} __answer __shown
  __shown=$__default
  # shellcheck disable=SC2088 # a literal ~ for display
  if [[ ${#HOME} -gt 1 && $__shown == "$HOME"/* ]]; then __shown="~/${__shown:$((${#HOME} + 1))}"; fi
  printf '%s%s: ' "$__prompt" "${__shown:+ [$__shown]}"
  setup_read __answer
  [[ -n $__answer ]] || __answer=$__default
  printf -v "$__var" '%s' "$__answer"
}

# setup_path <variable> <prompt> [default]: setup_text for a path; a leading
# ~/ means HOME (the engine wants absolute paths).
setup_path() {
  local __path
  setup_text __path "$2" "${3:-}"
  # shellcheck disable=SC2088 # matching a typed ~/
  if [[ $__path == '~/'* ]]; then __path="$HOME/${__path:2}"; fi
  printf -v "$1" '%s' "$__path"
}

# setup_engine_rejects <variable> <value> [<variable> <value>...]: run the
# engine's validate_options with these values (in a subshell) and print its
# complaint, if any. Exit status 0 means the engine rejected them.
setup_engine_rejects() {
  local message
  message=$(
    while (( $# >= 2 )); do printf -v "$1" '%s' "$2"; shift 2; done
    validate_options 2>&1 >/dev/null
  ) && return 1
  printf '%s\n' "${message#ERROR: }"
}

# ---------------------------------------------------------------------------
# Multi-select: a numbered toggle list. [x] selected, [+] included anyway
# because another choice needs it (the engine's dependency closure).

# setup_closure <steps> <groups>: "<steps><TAB><groups>" after the engine's
# normalise_dependencies, in canonical order.
setup_closure() {
  # Locals shadow the engine's globals for the functions called here.
  local SELECTED_STEPS=$1 SELECTED_GROUPS=$2
  normalise_dependencies
  order_selected_steps
  printf '%s\t%s\n' "$SELECTED_STEPS" "$SELECTED_GROUPS"
}

# setup_csv_minus <csv> <csv>: items of the first not in the second.
setup_csv_minus() {
  local item out=""
  local -a items=()
  csv_split items "$1"
  for item in ${items[@]+"${items[@]}"}; do
    has_csv_item "$2" "$item" || out="${out:+$out,}$item"
  done
  printf '%s\n' "$out"
}

# setup_csv_order <csv> <canonical csv>: the items in canonical order.
setup_csv_order() {
  local item out=""
  local -a items=()
  csv_split items "$2"
  for item in ${items[@]+"${items[@]}"}; do
    has_csv_item "$1" "$item" && out="${out:+$out,}$item"
  done
  printf '%s\n' "$out"
}

setup_component_description() {
  case $1 in
    packages) printf 'OS packages from the package groups (next screen)' ;;
    bins) printf 'rpatool (optional; upstream has no stable release)' ;;
    pyenv) printf 'pyenv, a pinned checkout in ~/.pyenv' ;;
    rbenv) printf 'rbenv and ruby-build in ~/.rbenv' ;;
    bun) printf 'Bun, a pinned binary in ~/.local/bin' ;;
    fnm) printf 'fnm with a compatible Node (yours, or the LTS)' ;;
    yarn) printf "Yarn, run on fnm's Node" ;;
    pnpm) printf "pnpm, run on fnm's Node" ;;
    uv) printf 'uv and uvx in ~/.local/bin' ;;
    plugins) printf 'Starship prompt and the zsh plugins' ;;
    fonts) printf "a Nerd Font for the prompt's icons" ;;
    zsh-config) printf 'managed blocks that load the profile in zsh' ;;
    default-shell) printf 'make zsh your login shell' ;;
  esac
}

# A package group's exact members on this OS, from the engine's package map,
# shortened to fit one line.
setup_group_description() {
  local package text="" count=0 more=0
  for package in $(package_list_for_group "$1"); do
    count=$((count + 1))
    if (( ${#text} + ${#package} + 1 <= 40 )); then text="${text:+$text }$package"; else more=$((more + 1)); fi
  done
  if (( more > 0 )); then printf '%s +%s more' "$text" "$more"; else printf '%s' "$text"; fi
}

# setup_multi <variable> <title> <items csv> <selected csv> <kind>: kind is
# components or groups. Sets the variable to the selected csv.
setup_multi() {
  local __var=$1 __title=$2 __items_csv=$3 __selected=$4 __kind=$5
  local __answer __token __i __item __mark __implied __closure __bad __tab=$'\t'
  local -a __items=() __tokens=()
  csv_split __items "$__items_csv"
  while :; do
    if [[ $__kind == components ]]; then
      __closure=$(setup_closure "$__selected" "")
      __implied=$(setup_csv_minus "${__closure%%"$__tab"*}" "$__selected")
    else
      __closure=$(setup_closure "$S_STEPS" "$__selected")
      __implied=$(setup_csv_minus "${__closure#*"$__tab"}" "$__selected")
    fi
    printf '\n%s%s%s\n' "$W_BOLD" "$__title" "$W_RESET"
    __i=1
    for __item in "${__items[@]}"; do
      if has_csv_item "$__selected" "$__item"; then __mark='[x]'
      elif has_csv_item "$__implied" "$__item"; then __mark='[+]'
      else __mark='[ ]'; fi
      if [[ $__kind == components ]]; then
        printf ' %2d %s %-14s %s\n' "$__i" "$__mark" "$__item" "$(setup_component_description "$__item")"
      else
        printf ' %2d %s %-11s %s\n' "$__i" "$__mark" "$__item" "$(setup_group_description "$__item")"
      fi
      __i=$((__i + 1))
    done
    printf '%s\n' '[x] selected  [+] included because another choice needs it'
    printf '%s' 'Numbers toggle (e.g. 3 5), a = all, n = none, Enter = done, q = quit: '
    setup_read __answer
    case $__answer in
      '') break ;;
      q) setup_quit ;;
      a) __selected=$__items_csv; continue ;;
      n) __selected=""; continue ;;
    esac
    IFS=' ,' read -r -a __tokens <<< "$__answer"
    __bad=""
    for __token in ${__tokens[@]+"${__tokens[@]}"}; do
      if [[ $__token =~ ^[0-9]+$ ]] && (( __token >= 1 && __token <= ${#__items[@]} )); then
        __item=${__items[$((__token - 1))]}
        if has_csv_item "$__selected" "$__item"; then
          __selected=$(setup_csv_minus "$__selected" "$__item")
        else
          __selected=$(setup_csv_order "$__selected,$__item" "$__items_csv")
        fi
      else
        __bad="$__bad $__token"
      fi
    done
    [[ -z $__bad ]] || printf 'Ignored:%s (type numbers from 1 to %s)\n' "$__bad" "${#__items[@]}"
  done
  printf -v "$__var" '%s' "$(setup_csv_order "$__selected" "$__items_csv")"
  if [[ -n $__implied ]]; then
    w_para 0 "Also included, because your choices need them: ${__implied//,/, }"
  fi
}

# ---------------------------------------------------------------------------
# The plan, from inspect.

# setup_build_args: SETUP_ARGS for the current choices, without the command.
setup_build_args() {
  SETUP_ARGS=(--groups "${S_STEPS:-none}" --package-groups "${S_GROUPS:-none}" --ssh "$S_SSH")
  case $S_SSH in
    reuse|agent) SETUP_ARGS+=(--ssh-key "$S_SSH_KEY") ;;
    generate) SETUP_ARGS+=(--ssh-key "$S_SSH_KEY" --ssh-passphrase "$S_SSH_PASS") ;;
  esac
  [[ $S_SSH == skip ]] || SETUP_ARGS+=(--ssh-config "$S_SSH_CONFIG")
  SETUP_ARGS+=(--gpg "$S_GPG")
  case $S_GPG in
    reuse) SETUP_ARGS+=(--gpg-key "$S_GPG_KEY") ;;
    generate) SETUP_ARGS+=(--gpg-passphrase "$S_GPG_PASS" --gpg-expiry "$S_GPG_EXPIRY") ;;
  esac
  SETUP_ARGS+=(--signing "$S_SIGNING")
  [[ -z $S_GIT_NAME ]] || SETUP_ARGS+=(--git-name "$S_GIT_NAME")
  [[ -z $S_GIT_EMAIL ]] || SETUP_ARGS+=(--git-email "$S_GIT_EMAIL")
  SETUP_ARGS+=(--fonts "$S_FONTS")
  [[ -z $S_FONT ]] || SETUP_ARGS+=(--font "$S_FONT")
  SETUP_ARGS+=(--default-shell "$S_SHELL")
  if [[ $S_FULL_UPGRADE == yes ]]; then SETUP_ARGS+=(--full-upgrade); else SETUP_ARGS+=(--no-full-upgrade); fi
  [[ -z $S_BREW_MIRROR ]] || SETUP_ARGS+=(--brew-mirror "$S_BREW_MIRROR")
  [[ $S_SKIP_EXISTING -eq 0 ]] || SETUP_ARGS+=(--skip-existing-version-managers)
}

# setup_inspect_args: the inspect argv for the current mode and choices.
setup_inspect_args() {
  if [[ $SETUP_MODE == reconcile ]]; then
    SETUP_ARGS=(inspect --saved)
    [[ $SETUP_RECONCILE_FULL_UPGRADE -eq 0 ]] || SETUP_ARGS+=(--full-upgrade)
  else
    setup_build_args
    SETUP_ARGS=(inspect "${SETUP_ARGS[@]}")
  fi
}

# setup_run_args: the apply/reconcile argv for the current mode and choices.
setup_run_args() {
  if [[ $SETUP_MODE == reconcile ]]; then
    SETUP_ARGS=(reconcile --yes)
    [[ $SETUP_RECONCILE_FULL_UPGRADE -eq 0 ]] || SETUP_ARGS+=(--full-upgrade)
  else
    setup_build_args
    SETUP_ARGS=(apply --yes "${SETUP_ARGS[@]}")
    [[ -z $S_NODE_VERSION ]] || SETUP_ARGS+=(--node-version "$S_NODE_VERSION")
  fi
  [[ $SETUP_DRY_RUN -eq 0 ]] || SETUP_ARGS+=(--dry-run)
}

setup_engine() { "${BASH:-bash}" "$SCRIPT_DIR/install.sh" "$@"; }

# setup_inspect: refresh SETUP_PLAN for the current choices (cached by argv).
# Prints the engine's error and fails when inspect refuses the choices.
setup_inspect() {
  local key errors status=0 plan
  setup_inspect_args
  key=$(printf '%q ' "${SETUP_ARGS[@]}")
  [[ $key != "$SETUP_PLAN_KEY" ]] || return 0
  errors=$(mktemp "${TMPDIR:-/tmp}/leos-setup-inspect.XXXXXX")
  track_temp "$errors"
  printf '%s\n' 'Checking this machine (read-only)...'
  plan=$(setup_engine "${SETUP_ARGS[@]}" 2> "$errors" < /dev/null) || status=$?
  if (( status != 0 )); then
    w_warn "The installer did not accept this plan (inspect exited $status):"
    sed 's/^/  /' "$errors"
    return 1
  fi
  SETUP_PLAN=$plan
  SETUP_PLAN_KEY=$key
  OS_FAMILY=$(plan_values platform family)
  S_NODE_VERSION=$(awk -F '\t' '$1 == "runtime" && $2 == "node" && $3 ~ /^v[0-9]/ { print $3; exit }' <<< "$SETUP_PLAN")
}

# plan_values <type> [<second column>]: the next column of matching records,
# one per line. plan_records <type>: whole matching records.
plan_values() {
  awk -F '\t' -v t="$1" -v k="${2:-}" '$1 == t && (k == "" || $2 == k) { print (k == "" ? $2 : $3) }' <<< "$SETUP_PLAN"
}
plan_records() { awk -F '\t' -v t="$1" '$1 == t' <<< "$SETUP_PLAN"; }

# plan_groups <category> <selected|implied>
plan_groups() {
  awk -F '\t' -v c="$1" -v s="$2" '$1 == "group" && $2 == c && $4 == s { print $3 }' <<< "$SETUP_PLAN" | setup_join
}

setup_platform_name() {
  case $1 in
    macos) printf 'macOS' ;;
    apt) printf 'Debian/Ubuntu (apt)' ;;
    fedora) printf 'Fedora (dnf)' ;;
    arch) printf 'Arch Linux (pacman)' ;;
    *) printf '%s' "$1" ;;
  esac
}

setup_conflict_reason() {
  case $1 in
    not-a-git-checkout) printf 'exists but is not a Git checkout (for example a Homebrew root); apply stops here unless you keep it' ;;
    unexpected-origin) printf 'is a checkout of another repository; apply stops here unless you keep it' ;;
    local-changes) printf 'has local changes; apply stops here unless you keep it' ;;
    homebrew-install) printf 'Homebrew copy; both stay installed and the profile prefers its pinned checkout' ;;
    *) printf '%s' "$1" ;;
  esac
}

# The findings worth knowing before choosing: platform support, existing
# installations in the way, setups the profile sits next to, shadowed tools
# and pending migrations. One line of explanation each.
setup_show_findings() {
  local type a b c d count=0 text
  w_heading 'This machine'
  w_field Platform "$(setup_platform_name "$OS_FAMILY")"
  w_field Checkout "$TARGET"
  while IFS=$US read -r type a b c d; do
    text=$(setup_finding_text "$type" "$a" "$b" "$c")
    [[ -n $text ]] || continue
    w_item 0 "$text"
    count=$((count + 1))
  done < <(tr '\t' "$US" <<< "$SETUP_PLAN")
  (( count > 0 )) || w_para 0 'Nothing in the way was found.'
}

# setup_finding_text <type> <columns...>: one line for a finding record, or
# nothing for other records.
setup_finding_text() {
  local type=$1 a=$2 b=$3 c=$4
  case $type in
    warning) printf 'Warning (%s): %s' "$a" "$b" ;;
    conflict)
      if [[ $c != homebrew-install ]] && awk -F '\t' -v t="$a" '$1 == "postcondition" && $2 == t && $3 == "skipped" { found = 1 } END { exit !found }' <<< "$SETUP_PLAN"; then
        printf 'In the way of %s: %s is kept as it is; the %s component is skipped.' "$a" "$b" "$a"
      else
        printf 'In the way of %s: %s %s.' "$a" "$b" "$(setup_conflict_reason "$c")"
      fi ;;
    existing) printf 'Found %s (%s): %s.' "$a" "$b" "$c" ;;
    shadow) printf "Homebrew's %s (%s) will be shadowed by the pinned %s; brew upgrade no longer changes it." "$a" "$b" "$c" ;;
    migration)
      case $a in
        profile-schema) printf 'The saved profile (schema %s) is upgraded to schema %s on the next run.' "$b" "$c" ;;
        *) printf 'An old unmarked loader in %s is replaced by the managed block.' "$b" ;;
      esac ;;
  esac
}

# The approved plan, all from the inspect records.
setup_show_plan() {
  local text type a b c
  w_heading "The plan ($([[ $SETUP_MODE == reconcile ]] && printf 'reconcile the saved setup' || printf 'apply'))"
  w_field Platform "$(setup_platform_name "$OS_FAMILY")"
  w_field Components "$(plan_groups component selected)"
  w_field '  also needed' "$(plan_groups component implied)"
  w_field 'Package groups' "$(plan_groups package selected)"
  w_field '  also needed' "$(plan_groups package implied)"
  text=$(awk -F '\t' '$1 == "package" && !seen[$3]++ { print $3 }' <<< "$SETUP_PLAN" | setup_join ' ')
  if [[ -n $text ]]; then w_field "OS packages ($(wc -w <<< "$text" | tr -d ' '))" "$text"; fi
  w_field Credentials "$(awk -F '\t' '$1 == "group" && $2 == "credential" { n[$3] = $4 }
    END { printf "SSH %s, GPG %s, commit signing %s\n", n["ssh"], n["gpg"], n["signing"] }' <<< "$SETUP_PLAN")"
  text=$(awk -F '\t' '$1 == "runtime" && $2 == "node" { if ($3 == "unresolved") print "resolved during apply"; else print $3 " (" $4 ")" }' <<< "$SETUP_PLAN")
  w_field Node "$text"
  if [[ $(plan_values policy full-upgrade) == yes ]]; then
    w_field 'Host upgrade' 'yes: upgrade the installed packages within this OS release'
  else
    w_field 'Host upgrade' 'no: install only what is missing'
  fi
  text=$(awk -F '\t' '$1 == "artifact" { print $3 }' <<< "$SETUP_PLAN" | awk '!seen[$0]++' | setup_join)
  w_field 'Locked downloads' "${text:+$text (pinned by SHA-256 digest or commit)}"
  setup_plan_section 'What runs' action
  setup_plan_section 'Files written or read' file
  setup_plan_section 'Global Git settings' global
  setup_plan_section 'External services' external
  if [[ -n $(plan_records privileged) ]]; then
    setup_plan_section 'Runs as root (sudo asks once, at the start)' privileged
  else
    printf '\n%s\n' 'Runs as root: nothing.'
  fi
  setup_plan_section 'Cannot be undone automatically' irreversible
  setup_plan_section 'Side effects' behaviour
  text=""
  while IFS=$US read -r type a b c; do
    a=$(setup_finding_text "$type" "$a" "$b" "$c")
    [[ -n $a ]] || continue
    [[ -n $text ]] || printf '\n%s\n' 'Findings:'
    text=1
    w_item 2 "$a"
  done < <(tr '\t' "$US" <<< "$SETUP_PLAN")
  printf '\n'
  w_field 'Already done' "$(awk -F '\t' '$1 == "postcondition" && $3 == "verified" { print $2 }' <<< "$SETUP_PLAN" | setup_join)"
  w_field 'To do' "$(awk -F '\t' '$1 == "postcondition" && $3 == "needed" { print $2 }' <<< "$SETUP_PLAN" | setup_join)"
  w_field 'Kept as is' "$(awk -F '\t' '$1 == "postcondition" && $3 == "skipped" { print $2 }' <<< "$SETUP_PLAN" | setup_join)"
  setup_expected_manual_actions
}

# setup_plan_section <title> <record type>: "name: description" items.
setup_plan_section() {
  local records name value
  records=$(plan_records "$2")
  [[ -n $records ]] || return 0
  printf '\n%s:\n' "$1"
  while IFS=$US read -r _ name value; do
    w_item 2 "$name: $value"
  done < <(tr '\t' "$US" <<< "$records")
}

# What the user will be asked to do by hand, from the credential choices in
# the plan (README "GitHub access").
setup_expected_manual_actions() {
  local ssh gpg signing scopes="" listed=0
  ssh=$(awk -F '\t' '$1 == "group" && $2 == "credential" && $3 == "ssh" { print $4 }' <<< "$SETUP_PLAN")
  gpg=$(awk -F '\t' '$1 == "group" && $2 == "credential" && $3 == "gpg" { print $4 }' <<< "$SETUP_PLAN")
  signing=$(awk -F '\t' '$1 == "group" && $2 == "credential" && $3 == "signing" { print $4 }' <<< "$SETUP_PLAN")
  [[ ${ssh:-skip} == skip ]] || scopes="read:public_key"
  [[ ${gpg:-skip} == skip ]] || scopes="${scopes:+$scopes,}read:gpg_key"
  [[ ${signing:-skip} != ssh ]] || scopes="${scopes:+$scopes,}read:ssh_signing_key"
  if [[ ${gpg:-skip} != skip || ${signing:-skip} == ssh ]]; then scopes="${scopes:+$scopes,}user:email"; fi
  if [[ -n $scopes ]]; then
    printf '\n%s\n' 'You will be asked to do by hand (the run pauses with exit 3 and resumes here):'
    w_item 2 "Log in with GitHub CLI if needed (gh auth login) and grant the read scopes the key checks use: gh auth refresh -h github.com -s $scopes"
    [[ ${ssh:-skip} == skip ]] || w_item 2 'Register the SSH public key on GitHub as an authentication key.'
    [[ ${signing:-skip} != ssh ]] || w_item 2 'Register the same SSH key again as a signing key.'
    [[ ${gpg:-skip} == skip ]] || w_item 2 'Register the GPG public key on GitHub.'
    listed=1
  fi
  if is_wsl && has_csv_item "$(awk -F '\t' '$1 == "group" && $2 == "component" { print $3 }' <<< "$SETUP_PLAN" | setup_join ,)" fonts; then
    [[ $listed -eq 1 ]] || printf '\n%s\n' 'You will be asked to do by hand:'
    w_item 2 'Install the Nerd Font on Windows too: the terminal is a Windows program.'
  fi
}

# ---------------------------------------------------------------------------
# Questions.

setup_choose_mode() {
  local choice
  setup_choose choice 'How do you want to set up?' 1 \
    'Recommended: every default component and package group (not rpatool, python or heroku), a full in-release host upgrade, no SSH/GPG keys, fonts and default shell on Auto' \
    'Customize: choose components, package groups, keys, signing and policies'
  if [[ $choice == 1 ]]; then
    setup_reset_choices
  else
    setup_customize
  fi
}

setup_customize() {
  local groups_csv=$CANONICAL_GROUPS choice
  setup_multi S_STEPS 'Components (each one installs as a whole)' "$CANONICAL_STEPS" "$S_STEPS" components
  [[ $OS_FAMILY == macos ]] || groups_csv=$(setup_csv_minus "$CANONICAL_GROUPS" heroku)
  [[ $OS_FAMILY == macos ]] || S_GROUPS=$(setup_csv_minus "$S_GROUPS" heroku)
  setup_multi S_GROUPS 'Package groups (exact members on this OS)' "$groups_csv" "$S_GROUPS" groups
  setup_ask_ssh
  setup_ask_gpg
  setup_ask_signing
  setup_ask_git_identity
  if has_csv_item "$S_STEPS" fonts; then setup_ask_fonts; fi
  if has_csv_item "$S_STEPS" default-shell; then
    setup_choose choice 'Make zsh your login shell?' "$(setup_index "$S_SHELL" auto yes no)" \
      'Auto: change it unless it is already a zsh' \
      "Yes: always use the profile's zsh" \
      'No: leave the login shell alone'
    S_SHELL=$(setup_pick "$choice" auto yes no)
  fi
  setup_choose choice 'Upgrade the installed OS packages too?' "$(setup_index "$S_FULL_UPGRADE" yes no)" \
    'Yes: a full upgrade within this OS release (never a release upgrade)' \
    'No: only install what is missing (dependencies may still update)'
  S_FULL_UPGRADE=$(setup_pick "$choice" yes no)
  if [[ $OS_FAMILY == macos ]]; then setup_ask_brew_mirror; fi
}

# setup_index <value> <option>...: the 1-based position of value (default 1).
setup_index() {
  local value=$1 i=1
  shift
  while (( $# )); do
    [[ $1 != "$value" ]] || { printf '%s' "$i"; return 0; }
    i=$((i + 1)); shift
  done
  printf 1
}
# setup_pick <n> <option>...: the nth option.
setup_pick() { local n=$1; shift; shift $((n - 1)); printf '%s' "$1"; }

setup_ask_ssh() {
  local choice path default
  while :; do
    setup_choose choice 'SSH key for GitHub' "$(setup_index "$S_SSH" skip generate reuse agent)" \
      'Skip: no SSH key setup' \
      'Generate a new ed25519 key' \
      'Reuse a key file you already have' \
      'Use a key held by your SSH agent (ssh-agent, 1Password, Secretive)'
    case $choice in
      1) S_SSH=skip S_SSH_KEY=""; S_SSH_CONFIG=no; return 0 ;;
      2)
        default=$S_SSH_KEY
        [[ $S_SSH == generate && -n $default ]] || default="$HOME/.ssh/id_ed25519"
        while :; do
          setup_path path 'Path for the new key' "$default"
          [[ $path != q ]] || setup_quit
          if setup_engine_rejects SSH_MODE generate SSH_KEY_PATH "$path"; then continue; fi
          if [[ -e $path || -e $path.pub ]]; then
            w_para 0 "$path already exists and is never replaced. Choose another path, or go back and reuse it."
            default=""
            setup_yesno choice 'Choose another path?' y
            [[ $choice == y ]] || continue 2
            continue
          fi
          break
        done
        S_SSH=generate S_SSH_KEY=$path
        setup_ask_passphrase S_SSH_PASS 'SSH key'
        ;;
      3) setup_pick_ssh_file || continue; S_SSH=reuse ;;
      4) setup_pick_agent_key || continue; S_SSH=agent ;;
    esac
    break
  done
  w_para 0 "The installer changes no SSH configuration unless you ask: a managed 'Host github.com' block in ~/.ssh/config sets AddKeysToAgent$([[ $OS_FAMILY != macos ]] || printf ' and UseKeychain (a passphrase is then asked once)')$([[ $S_SSH == agent ]] || printf ', and IdentityFile for the key')."
  setup_yesno choice 'Add that block to ~/.ssh/config?' "$([[ $S_SSH_CONFIG == yes ]] && printf y || printf n)"
  if [[ $choice == y ]]; then S_SSH_CONFIG=yes; else S_SSH_CONFIG=no; fi
}

# setup_ask_passphrase <variable> <what>
setup_ask_passphrase() {
  local choice
  setup_choose choice "Passphrase for the new $2" 1 \
    'Ask me for one when the key is created (recommended)' \
    'None: the key file is unencrypted, so anything running as you can use it'
  if [[ $choice == 1 ]]; then printf -v "$1" prompt; else
    printf -v "$1" empty
    w_warn 'Warning: an empty passphrase leaves the private key readable by anything that runs as you.'
  fi
}

# A private key file the user picks: candidates are files in ~/.ssh with a
# matching .pub; any absolute path can be typed instead.
setup_pick_ssh_file() {
  local file choice path
  local -a keys=() options=()
  for file in "$HOME"/.ssh/*; do
    [[ -f $file && $file != *.pub && -f $file.pub ]] || continue
    keys+=("$file")
    options+=("$file")
  done
  options+=('Type a path' 'Back')
  setup_choose choice 'Which private key? (never chosen for you)' 0 "${options[@]}"
  if (( choice == ${#options[@]} )); then return 1; fi
  if (( choice <= ${#keys[@]} )); then
    path=${keys[$((choice - 1))]}
  else
    while :; do
      setup_path path 'Path of the private key'
      [[ $path != q ]] || setup_quit
      if setup_engine_rejects SSH_MODE reuse SSH_KEY_PATH "$path"; then continue; fi
      [[ -f $path ]] || { printf 'No such file: %s\n' "$path"; continue; }
      break
    done
  fi
  S_SSH_KEY=$path
}

# An agent key the user picks, by its SHA256 fingerprint (ssh-add -l).
setup_pick_agent_key() {
  local listing status=0 choice line
  local -a fingerprints=() options=()
  if [[ -z ${SSH_AUTH_SOCK:-} ]]; then
    w_para 0 'No SSH agent in this shell (SSH_AUTH_SOCK is not set). Start or unlock your agent and run setup again, or choose another option.'
    return 1
  fi
  listing=$(ssh-add -l -E sha256 2>/dev/null) || status=$?
  if (( status != 0 )) || [[ -z $listing ]]; then
    w_para 0 "The SSH agent at $SSH_AUTH_SOCK lists no keys (ssh-add -l exited $status). Add or unlock the key, or choose another option."
    return 1
  fi
  while IFS= read -r line; do
    [[ $line == *SHA256:* ]] || continue
    fingerprints+=("$(awk '{ print $2 }' <<< "$line")")
    options+=("$(awk '{ $1 = ""; sub(/^ /, ""); print }' <<< "$line")")
  done <<< "$listing"
  (( ${#options[@]} > 0 )) || { w_para 0 'The agent listed no usable keys.'; return 1; }
  options+=('Back')
  setup_choose choice 'Which agent key? (never chosen for you)' 0 "${options[@]}"
  (( choice < ${#options[@]} )) || return 1
  S_SSH_KEY=${fingerprints[$((choice - 1))]}
}

setup_ask_gpg() {
  local choice line uid
  local -a fingerprints=() options=()
  while :; do
    setup_choose choice 'GPG key' "$(setup_index "$S_GPG" skip generate reuse)" \
      'Skip: no GPG key setup' \
      'Generate a new key (never a second one)' \
      'Reuse a secret key you already have'
    case $choice in
      1) S_GPG=skip S_GPG_KEY=""; return 0 ;;
      2)
        S_GPG=generate S_GPG_KEY=""
        setup_ask_passphrase S_GPG_PASS 'GPG key'
        while :; do
          setup_text S_GPG_EXPIRY 'Key lifetime: Ny, Nm, Nw or Nd, or never' "$S_GPG_EXPIRY"
          setup_engine_rejects GPG_EXPIRY "$S_GPG_EXPIRY" || break
          S_GPG_EXPIRY=2y
        done
        return 0 ;;
      3)
        fingerprints=() options=()
        if command -v gpg >/dev/null 2>&1; then
          while IFS=$'\t' read -r line uid; do
            [[ -n $line ]] || continue
            fingerprints+=("$line")
            options+=("$line $uid")
          done < <(gpg --list-secret-keys --with-colons 2>/dev/null |
            awk -F ':' '$1 == "sec" { want = 1; next } $1 == "fpr" && want { fpr = $10; want = 0; next }
              $1 == "uid" && fpr != "" { print fpr "\t" $10; fpr = "" }')
        fi
        options+=('Type a fingerprint' 'Back')
        setup_choose choice 'Which secret key? (never chosen for you)' 0 "${options[@]}"
        (( choice < ${#options[@]} )) || continue
        if (( choice <= ${#fingerprints[@]} )); then
          S_GPG_KEY=${fingerprints[$((choice - 1))]}
        else
          while :; do
            setup_text S_GPG_KEY 'Full fingerprint (40 or 64 hex digits)'
            [[ $S_GPG_KEY =~ ^[A-Fa-f0-9]{40}$ || $S_GPG_KEY =~ ^[A-Fa-f0-9]{64}$ ]] && break
            printf '%s\n' 'That is not a full fingerprint.'
          done
        fi
        S_GPG=reuse
        return 0 ;;
    esac
  done
}

setup_ask_signing() {
  local choice default=1
  local -a options=() values=()
  options=('Skip: leave Git signing settings as they are')
  values=(skip)
  if [[ $S_SSH == skip && $S_GPG == skip ]]; then S_SIGNING=skip; return 0; fi
  if [[ $S_SSH != skip ]]; then
    options+=('Sign with the SSH key (recommended: simpler, no GPG needed)')
    values+=(ssh)
  fi
  if [[ $S_GPG != skip ]]; then
    options+=('Sign with the GPG key')
    values+=(gpg)
    # --gpg without --signing means gpg signing; keep that the default.
    [[ $S_SSH != skip ]] || default=2
  fi
  for choice in "${!values[@]}"; do
    [[ ${values[$choice]} != "$S_SIGNING" ]] || default=$((choice + 1))
  done
  setup_choose choice 'Sign your Git commits?' "$default" "${options[@]}"
  S_SIGNING=${values[$((choice - 1))]}
}

# GPG keys and signing write a global Git identity when it is missing.
setup_ask_git_identity() {
  local current
  [[ $S_GPG != skip || $S_SIGNING == ssh ]] || { S_GIT_NAME="" S_GIT_EMAIL=""; return 0; }
  current=$(git config --global --get user.name 2>/dev/null || true)
  if [[ -z $current ]]; then
    printf '\n'
    w_para 0 'Git has no global user.name yet; the key and signature need one.'
    while :; do
      setup_text S_GIT_NAME 'Git user.name' "$S_GIT_NAME"
      [[ -n $S_GIT_NAME ]] && ! setup_engine_rejects GIT_NAME "$S_GIT_NAME" && break
    done
  else
    S_GIT_NAME=""
  fi
  current=$(git config --global --get user.email 2>/dev/null || true)
  if [[ -z $current ]]; then
    w_para 0 'Git has no global user.email yet; use one verified on your GitHub account.'
    while :; do
      setup_text S_GIT_EMAIL 'Git user.email' "$S_GIT_EMAIL"
      [[ $S_GIT_EMAIL == ?*@?* ]] && ! setup_engine_rejects GIT_EMAIL "$S_GIT_EMAIL" && break
    done
  else
    S_GIT_EMAIL=""
  fi
}

setup_ask_fonts() {
  local choice name status
  setup_choose choice 'Install a Nerd Font?' "$(setup_index "$S_FONTS" auto yes no)" \
    'Auto: JetBrainsMono on a desktop session, nothing on a server' \
    'Yes: choose the font' \
    'No'
  S_FONTS=$(setup_pick "$choice" auto yes no)
  if [[ $S_FONTS != yes ]]; then S_FONT=""; return 0; fi
  while :; do
    setup_text name 'Nerd Font name (as on nerdfonts.com)' "${S_FONT:-JetBrainsMono}"
    if setup_engine_rejects INSTALL_FONTS yes FONT_NAME "$name"; then continue; fi
    printf '%s\n' 'Checking the name against the pinned Nerd Fonts release...'
    status=0
    setup_known_font "$name" || status=$?
    case $status in
      0) break ;;
      1) printf 'Nerd Fonts %s has no font named %s.\n' "$NERD_FONTS_VERSION" "$name" ;;
      *) w_para 0 "Could not download the release's checksum list now; apply checks the name again before it changes anything."; break ;;
    esac
  done
  S_FONT=$name
}

# setup_known_font <name>: 0 known, 1 unknown, 2 could not check. The
# engine's own checks: the pinned checksum list and its font lookup.
setup_known_font() {
  local dir status=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/leos-setup-font.XXXXXX")
  track_temp "$dir"
  setup_fetch_font_list "$dir/SHA-256.txt" >/dev/null 2>&1 || status=2
  if (( status == 0 )); then
    nerd_font_archive_digest "$dir/SHA-256.txt" "$1" >/dev/null 2>&1 || status=1
  fi
  rm -rf -- "$dir"
  return "$status"
}

# The engine's checksum download, as a real (not dry) run does it.
setup_fetch_font_list() {
  local DRY_RUN=0
  fetch_nerd_font_checksums "$1"
}

# Whether the mirror is on now, without this run's choice.
setup_current_brew_mirror() {
  local BREW_MIRROR=""
  brew_mirror_effective
}

setup_ask_brew_mirror() {
  local choice current
  current=$(setup_current_brew_mirror)
  setup_choose choice 'Where should Homebrew download from?' "$([[ $current == china ]] && printf 2 || printf 1)" \
    'Official Homebrew' \
    "USTC mirror in China (brew.git, metadata and bottles; also for later shells)"
  S_BREW_MIRROR=""
  if [[ $choice == 2 && $current != china ]]; then S_BREW_MIRROR=china; fi
  if [[ $choice == 1 && $current == china ]]; then S_BREW_MIRROR=none; fi
}

# A blocking pyenv/rbenv conflict: offer to keep the existing installation.
setup_offer_conflicts() {
  local records answer tool path reason
  [[ $SETUP_MODE == apply && $S_SKIP_EXISTING -eq 0 && $SETUP_CONFLICT_ASKED -eq 0 ]] || return 0
  records=$(awk -F '\t' '$1 == "conflict" && $4 != "homebrew-install"' <<< "$SETUP_PLAN")
  [[ -n $records ]] || return 0
  SETUP_CONFLICT_ASKED=1
  w_heading 'Existing installation in the way'
  while IFS=$US read -r _ tool path reason; do
    w_item 0 "$tool: $path $(setup_conflict_reason "$reason")."
  done < <(tr '\t' "$US" <<< "$records")
  setup_yesno answer 'Keep it and skip that component (--skip-existing-version-managers)?' y
  if [[ $answer == y ]]; then
    S_SKIP_EXISTING=1
  else
    w_warn 'Apply will stop before changing anything until you move it away.'
  fi
}

# ---------------------------------------------------------------------------
# Running the plan.

# setup_quote <word>...: the words as one shell command line. Plain words
# stay as they are and anything else is single-quoted, the same in every Bash
# (printf %q differs between versions and escapes commas).
setup_quote() {
  local word line="" squote="'" escaped="'\\''"
  for word in "$@"; do
    if [[ -n $word && $word =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
      line+=" $word"
    else
      line+=" '${word//$squote/$escaped}'"
    fi
  done
  printf '%s\n' "${line# }"
}

setup_print_command() {
  printf '\n%s\n\n%s\n' 'The equivalent command (run it in your own terminal):' \
    "$(setup_quote bash "$SCRIPT_DIR/install.sh" "${SETUP_ARGS[@]}")"
}

# setup_run_engine: run SETUP_ARGS, streaming the output and keeping a copy
# in SETUP_LOG (one per wizard run) and in SETUP_ATTEMPT (this attempt only).
setup_run_engine() {
  local status=0
  if [[ -z $SETUP_LOG ]]; then
    SETUP_LOG=$(mktemp "${TMPDIR:-/tmp}/leos-setup-log.XXXXXX")
    chmod 600 "$SETUP_LOG"
  fi
  if [[ -z ${SETUP_ATTEMPT:-} ]]; then
    SETUP_ATTEMPT=$(mktemp "${TMPDIR:-/tmp}/leos-setup-attempt.XXXXXX")
    track_temp "$SETUP_ATTEMPT"
  fi
  : > "$SETUP_ATTEMPT"
  printf '\n%s\n' "Running: $(setup_quote bash "$SCRIPT_DIR/install.sh" "${SETUP_ARGS[@]}")"
  printf '$ %s\n' "$(setup_quote bash "$SCRIPT_DIR/install.sh" "${SETUP_ARGS[@]}")" >> "$SETUP_LOG"
  SETUP_CHANGED=1
  # A passphrase prompt from gpg's curses pinentry needs to know the terminal.
  if [[ -z ${GPG_TTY:-} ]]; then GPG_TTY=$(tty 2>/dev/null || true); export GPG_TTY; fi
  setup_engine "${SETUP_ARGS[@]}" 2>&1 | tee -a "$SETUP_LOG" "$SETUP_ATTEMPT" || status=$?
  SETUP_STATUS=$status
}

# The manual actions of the last attempt, numbered: the engine's own
# explanation for each, then the record's file and destination.
setup_show_manual_actions() {
  local log=$1 n=0 action path destination explanation
  local -a explanations=()
  while IFS= read -r explanation; do explanations+=("$explanation"); done < <(
    awk '/^WARNING: Manual action required \(exit 3\)/ { on = 1; next }
      on && /^  - / { sub(/^  - /, ""); print; next } on { on = 0 }' "$log")
  w_heading 'Manual steps (the run paused with exit 3)'
  while IFS=$US read -r action path destination; do
    n=$((n + 1))
    printf '%s%d. %s%s\n' "$W_BOLD" "$n" "$action" "$W_RESET"
    if (( n <= ${#explanations[@]} )); then w_para 3 "${explanations[$((n - 1))]}"; fi
    [[ -z $path ]] || w_para 3 "File: $path"
    [[ -z $destination ]] || w_para 3 "Where: $destination"
  done < <(awk -F '\t' -v us="$US" '$1 == "manual-action" && !seen[$0]++ { print $2 us $3 us $4 }' "$log")
  (( n > 0 )) || w_para 0 'The run exited 3 without a manual-action record; read the output above.'
}

# After a pause: keys this run generated are reused on resume, never
# generated twice (README "GitHub access"); the saved profile names them.
setup_resume_choices() {
  local mode key
  [[ $SETUP_MODE == apply ]] || return 0
  if [[ $S_SSH == generate ]]; then
    mode=$(saved_profile_value ssh)
    key=$(saved_profile_value ssh-key)
    if [[ $mode == reuse && -n $key ]]; then S_SSH=reuse S_SSH_KEY=$key
    elif [[ -n $S_SSH_KEY && -f $S_SSH_KEY ]]; then S_SSH=reuse; fi
    [[ $S_SSH != reuse ]] || printf 'Resuming with the SSH key created above: --ssh reuse --ssh-key %s\n' "$S_SSH_KEY"
  fi
  if [[ $S_GPG == generate ]]; then
    mode=$(saved_profile_value gpg)
    key=$(saved_profile_value gpg-key)
    if [[ $mode == reuse && -n $key ]]; then
      S_GPG=reuse S_GPG_KEY=$key
      printf 'Resuming with the GPG key created above: --gpg reuse --gpg-key %s\n' "$S_GPG_KEY"
    fi
  fi
}

# Run until done: exit 3 shows the manual steps and resumes on Enter.
setup_execute() {
  local answer
  while :; do
    setup_run_args
    setup_run_engine
    case $SETUP_STATUS in
      0)
        printf '\n'
        if [[ $SETUP_DRY_RUN -eq 1 ]]; then
          w_para 0 "Dry run finished: nothing was changed. The full output is in $SETUP_LOG."
        else
          w_para 0 "Setup finished. Open a new terminal to use the profile; a login-shell change applies at the next login. The full output is in $SETUP_LOG."
        fi
        return 0 ;;
      3)
        setup_show_manual_actions "$SETUP_ATTEMPT"
        printf '\n'
        w_para 0 "Do these yourself, then come back. The full output is in $SETUP_LOG."
        printf '%s' 'When done, press Enter to resume (q to stop here): '
        setup_read answer
        [[ $answer != q ]] || setup_quit
        setup_resume_choices ;;
      2)
        w_warn 'The plan changed since it was shown (for example a new Node LTS). Nothing was changed by this run; here is the plan again.'
        SETUP_REPLAN=1
        return 0 ;;
      *)
        printf '\n'
        w_warn "The installer stopped with exit $SETUP_STATUS; see the message above. Fix the cause and run setup again: completed steps are verified and skipped. The full output is in $SETUP_LOG."
        exit "$SETUP_STATUS" ;;
    esac
  done
}

# ---------------------------------------------------------------------------

setup_requires_terminal() {
  [[ -t 0 && -t 1 ]] && return 0
  cat >&2 <<EOF
install.sh setup is interactive: it needs a terminal on stdin and stdout.
Without one, use the deterministic commands it runs for you:

  bash $TARGET/install.sh inspect [options]       read-only plan, TSV records
  bash $TARGET/install.sh apply --yes [options]   run an approved plan
  bash $TARGET/install.sh reconcile --yes         repair the saved setup

Options: bash $TARGET/install.sh --help. To get the exact apply command for
your choices, run this in a terminal: bash $TARGET/install.sh setup --print-command
EOF
  exit 2
}

setup_intro() {
  printf '%sLeo'"'"'s Profiles setup%s\n' "$W_BOLD" "$W_RESET"
  w_para 0 "This asks what to install, shows the complete plan, and then runs the installer with exactly those choices. Nothing changes until you confirm."
  w_para 0 "Type a number and press Enter; Enter alone takes the default (marked *); q quits."
  if [[ $SETUP_PRINT_COMMAND -eq 1 ]]; then
    w_para 0 "--print-command: at the end the command is printed instead of run."
  else
    w_para 0 "When it runs, sudo asks for your password once, at the start, if anything needs root. A new key's passphrase and chsh may ask too: stay at the keyboard until it finishes."
  fi
  [[ $SETUP_DRY_RUN -eq 0 ]] || w_para 0 "--dry-run: the installer only prints what it would do."
}

setup_wizard() {
  local choice
  setup_requires_terminal
  setup_init_terminal
  SETUP_RECOMMENDED_STEPS=$SELECTED_STEPS
  SETUP_RECOMMENDED_GROUPS=$SELECTED_GROUPS
  setup_reset_choices
  setup_intro
  if [[ -f $PROFILE_FILE ]]; then SETUP_MODE=reconcile; fi
  if ! setup_inspect; then
    [[ $SETUP_MODE == reconcile ]] || exit 1
    w_warn 'The saved profile could not be read; starting a new selection instead.'
    SETUP_MODE=apply
    setup_inspect || exit 1
  fi
  setup_show_findings
  if [[ $SETUP_MODE == reconcile ]]; then
    printf '\n'
    w_para 0 "A saved setup exists ($PROFILE_FILE)."
    setup_choose choice 'What do you want to do?' 1 \
      'Reconcile the saved setup: install what is missing and repair what drifted' \
      'Change the selection' \
      'Quit'
    case $choice in
      1)
        setup_yesno choice 'Also upgrade the installed OS packages (full in-release upgrade)?' n
        [[ $choice == n ]] || SETUP_RECONCILE_FULL_UPGRADE=1 ;;
      2) SETUP_MODE=apply; setup_seed_from_profile; setup_choose_mode ;;
      3) setup_quit ;;
    esac
  else
    setup_choose_mode
  fi
  while :; do
    setup_inspect || { setup_after_decline; continue; }
    setup_offer_conflicts
    setup_inspect || { setup_after_decline; continue; }
    setup_show_plan
    if [[ $SETUP_PRINT_COMMAND -eq 1 ]]; then
      setup_run_args
      setup_print_command
      exit 0
    fi
    printf '\n'
    setup_yesno choice 'Proceed?' n
    if [[ $choice != y ]]; then setup_after_decline; continue; fi
    SETUP_REPLAN=0
    setup_execute
    [[ $SETUP_REPLAN -eq 1 ]] || exit 0
    # Exit 2: the plan changed under us; inspect it again.
    SETUP_PLAN_KEY=""
  done
}

setup_after_decline() {
  local choice
  setup_choose choice 'Nothing was run. What now?' 1 'Change the selection' 'Quit'
  [[ $choice == 1 ]] || setup_quit
  if [[ $SETUP_MODE == reconcile ]]; then
    SETUP_MODE=apply
    setup_seed_from_profile
  fi
  setup_choose_mode
}

# The saved choices, one per line, as the engine reads and normalises them
# (an old profile without `signing` maps a GPG key to gpg, for example).
setup_saved_choices() {
  local SELECTED_STEPS="" SELECTED_GROUPS="" SSH_MODE=skip SSH_KEY_PATH="" SSH_PASSPHRASE_MODE=empty
  local SSH_CONFIG=no GPG_MODE=skip GPG_KEY_ID="" GPG_PASSPHRASE_MODE=empty GPG_EXPIRY=2y
  local SIGNING_MODE="" INSTALL_FONTS=auto FONT_NAME="" CHANGE_DEFAULT_SHELL=auto
  local SAVED_FULL_UPGRADE=yes SKIP_EXISTING_VERSION_MANAGERS=0 GIT_NAME="" GIT_EMAIL=""
  local NODE_CHANNEL=current-lts NODE_POLICY=preserve-compatible AI_CLI_UPDATE_CHANNEL=native
  local PACKAGE_CHANNEL=system PROFILE_SCHEMA=2 BREW_MIRROR="" NODE_VERSION_APPROVED=""
  read_profile
  validate_options
  printf '%s\n' "$SELECTED_STEPS" "$SELECTED_GROUPS" "$SSH_MODE" "$SSH_KEY_PATH" "$SSH_PASSPHRASE_MODE" \
    "$SSH_CONFIG" "$GPG_MODE" "$GPG_KEY_ID" "$GPG_PASSPHRASE_MODE" "$GPG_EXPIRY" "$SIGNING_MODE" \
    "$INSTALL_FONTS" "$FONT_NAME" "$CHANGE_DEFAULT_SHELL" "$SAVED_FULL_UPGRADE" "$SKIP_EXISTING_VERSION_MANAGERS"
}

# Change the selection: start from the saved choices (the engine reads them).
setup_seed_from_profile() {
  local values
  # A subshell: read_profile dies on a profile it cannot use.
  values=$(setup_saved_choices 2>/dev/null) || return 0
  {
    IFS= read -r S_STEPS; IFS= read -r S_GROUPS; IFS= read -r S_SSH; IFS= read -r S_SSH_KEY
    IFS= read -r S_SSH_PASS; IFS= read -r S_SSH_CONFIG; IFS= read -r S_GPG; IFS= read -r S_GPG_KEY
    IFS= read -r S_GPG_PASS; IFS= read -r S_GPG_EXPIRY; IFS= read -r S_SIGNING; IFS= read -r S_FONTS
    IFS= read -r S_FONT; IFS= read -r S_SHELL; IFS= read -r S_FULL_UPGRADE; IFS= read -r S_SKIP_EXISTING
  } <<< "$values"
}
