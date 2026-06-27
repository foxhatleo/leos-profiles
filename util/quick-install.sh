#!/usr/bin/env bash
#
# Leo's Profiles — Quick install implementation
#
# Public entrypoint:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)"
#
# This file is a single, self-contained bootstrap. It must run correctly when
# piped as text (curl | bash) BEFORE the repo is cloned, so it never sources
# any sibling/library file. Internal structure is provided by sectioning:
#
#   §0  shebang, colors, set -e, umask, version
#   §1  config + env-var capture (PF, USE_HTTPS, NO_FONTS, state file, SILENT)
#   §2  arg parser            args_parse / OPT_* / handle_immediate_flags
#   §3  word-list helpers     contains_word, append_unique_word, remove_word
#   §4  step engine           STEP_IDS, step_label, step_dependencies,
#                             step_default_enabled, run_step, state file I/O,
#                             capture_env, resolve_plan
#   §5  package registry      pkg_* functions + literal install_packages_*
#   §6  TUI primitives        tui_* (ANSI, raw key read, menu render)
#   §7  wizard screens        wizard_*_screen, run_wizard, interaction channel
#   §8  step bodies           prepare_and_clone_repo ... set_default_shell_fish
#   §9  main()                resolve config -> (wizard | non-interactive) -> run
#
# bash 3.2 floor (macOS 3.2.57): NO associative arrays, NO mapfile/readarray,
# NO ${var^^}. Indexed arrays + newline/space string tables only.

# =============================================================================
# §0  Terminal colors (only if connected to a TTY that supports them)
# =============================================================================
if which tput >/dev/null 2>&1; then
  ncolors=$(tput colors 2>/dev/null)
fi
if [ -t 1 ] && [ -n "${ncolors:-}" ] && [ "$ncolors" -ge 8 ]; then
  RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"
  BOLD="$(tput bold)"
  NORMAL="$(tput sgr0)"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  BOLD=""
  NORMAL=""
fi

# Exit on error (after non-critical color setup)
set -e

# Insecure umask can cause compinit/compdef errors; restrict group/other write
umask g-w,o-w

# Installer version string (printed by --version)
QUICK_INSTALL_VERSION="1.0.0"

# =============================================================================
# §1  Configuration + environment capture
# =============================================================================
: "${PF:=$HOME/.leos-profiles}"
: "${QUICK_INSTALL_STATE_FILE:=$PF/quick-install.state}"
# Set USE_HTTPS=1 to skip SSH and clone via HTTPS (e.g. in CI or if you prefer)

STEP_IDS=(
  prepare_and_clone_repo
  install_local_bins
  install_min_toolchain
  install_ai_tools
  install_os_packages
  install_pyenv
  install_rbenv
  install_bun
  install_yarn
  setup_nvm_default_node
  setup_fish
  install_nerd_fonts
  apply_fish_config
  set_default_shell_fish
)

STATE_ENABLED_STEPS=""
STATE_COMPLETED_STEPS=""
STATE_SKIPPED_STEPS=""
STATE_CURRENT_STEP=""
STATE_LAST_FAILED_STEP=""
STATE_LAST_STATUS=""
STATE_RUN_STARTED_AT=""
STATE_UPDATED_AT=""
STATE_PKG_SKIP=""
INSTALLED_NVM_VERSION=""

# Set of canonical package ids the user chose to skip (space-delimited).
# Persisted as STATE_PKG_SKIP; consumed by pkg_filter_for_os.
PKG_SKIP=""

# Interaction mode, resolved by open_interaction_channel: wizard | silent.
MODE=""
# PID of the background sudo keep-alive loop (interactive only). Empty when none.
KEEPALIVE_PID=""
# Whether the wizard actually ran (so resolve_plan knows to honor its toggles).
WIZARD_RAN=0

# =============================================================================
# §2  Argument parser
# =============================================================================
# OPT_* hold parsed flag state. Unset/empty means "flag not given".
OPT_SILENT=""
OPT_YES=""
OPT_FRESH=""
OPT_ONLY=""
OPT_SKIP=""
OPT_PACKAGES=""
OPT_SKIP_PACKAGES=""
OPT_NO_FONTS=""
OPT_HTTPS=""
OPT_STATE_FILE=""
OPT_EXEC_STEPS=""
OPT_SILENT_DRIVER=""
OPT_PRINT_RUNBOOK=""
# Immediate (short-circuit) actions; handle_immediate_flags acts on these.
OPT_HELP=""
OPT_VERSION=""
OPT_LIST_STEPS=""
OPT_LIST_PACKAGES=""

# Convert a comma-separated list to a space-separated list.
commas_to_spaces() {
  printf '%s\n' "$1" | tr ',' ' '
}

args_synopsis() {
  printf 'Usage: quick-install.sh [OPTIONS]  (try --help)\n' >&2
}

args_error() {
  printf "${RED}Error: %s${NORMAL}\n" "$1" >&2
  args_synopsis
  exit 2
}

print_help() {
  cat <<'EOF'
Leo's Profiles quick-install

USAGE:
  quick-install.sh [OPTIONS]
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)"

By default, on an interactive terminal, a setup wizard lets you choose steps and
packages and confirm before anything runs. With no terminal (e.g. piped) or with
--silent, sensible defaults run non-interactively.

OPTIONS:
  -h, --help                 Show this help and exit
  -s, --silent[=claude|codex],
      --non-interactive      Skip the wizard; run the resolved plan with defaults
                             Optionally drive non-interactive steps via an AI CLI
                             (requires an already-authenticated claude or codex CLI)
      --print-runbook        Print the AI runbook for the resolved plan, then exit
  -y, --yes                  Don't show the confirm screen; proceed once resolved
      --fresh                Ignore any saved resume state; start a clean run
      --only=IDS             Run ONLY these steps (comma-separated step ids)
      --skip=IDS             Skip these steps (comma-separated step ids)
      --packages=SEL         Install ONLY these package groups/items (see below)
      --skip-packages=SEL    Skip these package groups/items
      --no-fonts             Skip nerd-font install (same as NO_FONTS=1)
      --https                Clone via HTTPS instead of SSH (same as USE_HTTPS=1)
      --state-file=PATH      Resume-state file (same as QUICK_INSTALL_STATE_FILE)
      --list-steps           Print all step ids with labels and defaults, then exit
      --list-packages        Print package groups and per-OS members, then exit
      --version              Print version and exit

PACKAGE SELECTION (SEL):
  Comma-separated. A bare name selects a whole group (e.g. dev-tools).
  Use group:item to select one package (e.g. media:ffmpeg).
  Groups: core-utils, shell, dev-tools, languages, media, network, system

ENVIRONMENT (still honored; flags take precedence):
  PF                         Install/clone target (default: $HOME/.leos-profiles)
  USE_HTTPS                  Non-empty => clone via HTTPS
  NO_FONTS                   Non-empty => skip nerd fonts
  QUICK_INSTALL_STATE_FILE   Resume-state file path
  QUICK_INSTALL_SILENT       Non-empty => same as --silent

EXAMPLES:
  quick-install.sh --silent --skip=install_nerd_fonts
  quick-install.sh --only=prepare_and_clone_repo,install_os_packages
  quick-install.sh --silent --packages=core-utils,shell,network --no-fonts
  USE_HTTPS=1 quick-install.sh --silent
EOF
}

# Parse "$@" into OPT_* variables. Supports --flag=value and --flag value.
args_parse() {
  while [ "$#" -gt 0 ]; do
    local arg="$1" val="" has_val=0
    case "$arg" in
      --*=*)
        val="${arg#*=}"
        arg="${arg%%=*}"
        has_val=1
        ;;
    esac

    case "$arg" in
      -h|--help) OPT_HELP=1 ;;
      -s|--non-interactive) OPT_SILENT=1 ;;
      --silent)
        OPT_SILENT=1
        if [ "$has_val" -eq 1 ]; then
          OPT_SILENT_DRIVER="$val"
          case "$OPT_SILENT_DRIVER" in
            claude|codex) ;;
            *) printf 'Error: --silent driver must be claude or codex\n' >&2; args_synopsis; exit 2 ;;
          esac
        fi
        ;;
      -y|--yes) OPT_YES=1 ;;
      --fresh) OPT_FRESH=1 ;;
      --no-fonts) OPT_NO_FONTS=1 ;;
      --https) OPT_HTTPS=1 ;;
      --list-steps) OPT_LIST_STEPS=1 ;;
      --list-packages) OPT_LIST_PACKAGES=1 ;;
      --version) OPT_VERSION=1 ;;
      --only)
        if [ "$has_val" -eq 0 ]; then val="$2"; shift; fi
        OPT_ONLY=$(commas_to_spaces "$val")
        ;;
      --skip)
        if [ "$has_val" -eq 0 ]; then val="$2"; shift; fi
        OPT_SKIP=$(commas_to_spaces "$val")
        ;;
      --packages)
        if [ "$has_val" -eq 0 ]; then val="$2"; shift; fi
        OPT_PACKAGES=$(commas_to_spaces "$val")
        ;;
      --skip-packages)
        if [ "$has_val" -eq 0 ]; then val="$2"; shift; fi
        OPT_SKIP_PACKAGES=$(commas_to_spaces "$val")
        ;;
      --state-file)
        if [ "$has_val" -eq 0 ]; then val="$2"; shift; fi
        OPT_STATE_FILE="$val"
        ;;
      --exec-steps)
        if [ "$has_val" -eq 0 ]; then val="$2"; shift; fi
        OPT_EXEC_STEPS="$val"
        ;;
      --print-runbook) OPT_PRINT_RUNBOOK=1 ;;
      --)
        shift
        break
        ;;
      -*)
        args_error "unknown option: $arg"
        ;;
      *)
        args_error "unexpected argument: $arg"
        ;;
    esac
    shift
  done

  # Mutual-exclusion checks.
  if [ -n "$OPT_ONLY" ] && [ -n "$OPT_SKIP" ]; then
    args_error "--only and --skip are mutually exclusive"
  fi
  if [ -n "$OPT_PACKAGES" ] && [ -n "$OPT_SKIP_PACKAGES" ]; then
    args_error "--packages and --skip-packages are mutually exclusive"
  fi
}

# --list-steps body: step ids + labels + default-enabled.
list_steps() {
  local step_id default
  for step_id in "${STEP_IDS[@]}"; do
    if step_default_enabled "$step_id"; then
      default="on"
    else
      default="off"
    fi
    printf '%-26s %-3s %s\n' "$step_id" "$default" "$(step_label "$step_id")"
  done
}

# --list-packages body: each group, its label, and per-OS resolved members.
list_packages() {
  local group os member real out
  for group in $(pkg_groups); do
    printf '%s  (%s)\n' "$group" "$(pkg_group_label "$group")"
    for os in macos apt fedora pacman; do
      out=""
      for member in $(pkg_group_members "$group"); do
        real=$(pkg_resolve "$os" "$member")
        if [ -n "$real" ]; then
          if [ -n "$out" ]; then
            out="$out $real"
          else
            out="$real"
          fi
        fi
      done
      printf '  %-7s %s\n' "$os" "$out"
    done
  done
}

# Act on short-circuit flags that print and exit before any work happens.
handle_immediate_flags() {
  if [ -n "$OPT_HELP" ]; then
    print_help
    exit 0
  fi
  if [ -n "$OPT_VERSION" ]; then
    printf 'quick-install.sh %s\n' "$QUICK_INSTALL_VERSION"
    exit 0
  fi
  if [ -n "$OPT_LIST_STEPS" ]; then
    list_steps
    exit 0
  fi
  if [ -n "$OPT_LIST_PACKAGES" ]; then
    list_packages
    exit 0
  fi
  if [ -n "$OPT_PRINT_RUNBOOK" ]; then
    # Resolve a default plan (flags already captured; no wizard) then print.
    resolve_plan
    generate_runbook "$(detect_os_key)"
    exit 0
  fi
}

# =============================================================================
# §3  Word-list helpers (space-delimited string tables; bash 3.2 safe)
# =============================================================================

contains_word() {
  local needle="$1"
  shift
  local item
  # Intentional word-splitting over a space-delimited word list (bash 3.2 idiom).
  # shellcheck disable=SC2048,SC2086
  for item in $*; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

append_unique_word() {
  local var_name="$1"
  local value="$2"
  local current
  eval "current=\${$var_name}"
  if contains_word "$value" "$current"; then
    return 0
  fi
  if [ -n "$current" ]; then
    eval "$var_name=\"\$current $value\""
  else
    eval "$var_name=\"$value\""
  fi
}

remove_word() {
  local var_name="$1"
  local value="$2"
  local current updated item
  eval "current=\${$var_name}"
  updated=""
  for item in $current; do
    if [ "$item" = "$value" ]; then
      continue
    fi
    if [ -n "$updated" ]; then
      updated="$updated $item"
    else
      updated="$item"
    fi
  done
  eval "$var_name=\"\$updated\""
}

# =============================================================================
# §4  Step engine: state I/O, dependency closure, run_step, capture_env,
#     resolve_plan (precedence engine)
# =============================================================================

# Echo a space-delimited list with one value removed (does not mutate a var).
# $1=list, $2=value to drop.
remove_word_inline() {
  local list="$1" drop="$2" item out=""
  for item in $list; do
    if [ "$item" = "$drop" ]; then
      continue
    fi
    if [ -n "$out" ]; then
      out="$out $item"
    else
      out="$item"
    fi
  done
  printf '%s\n' "$out"
}

reset_state_tracking() {
  STATE_ENABLED_STEPS=""
  STATE_COMPLETED_STEPS=""
  STATE_SKIPPED_STEPS=""
  STATE_CURRENT_STEP=""
  STATE_LAST_FAILED_STEP=""
  STATE_LAST_STATUS=""
  STATE_RUN_STARTED_AT=""
  STATE_UPDATED_AT=""
}

state_persistence_available() {
  [ -d "$PF" ]
}

save_state_file() {
  if ! state_persistence_available; then
    return 0
  fi
  STATE_UPDATED_AT=$(date +%s)
  cat > "$QUICK_INSTALL_STATE_FILE" <<EOF
STATE_ENABLED_STEPS="$STATE_ENABLED_STEPS"
STATE_COMPLETED_STEPS="$STATE_COMPLETED_STEPS"
STATE_SKIPPED_STEPS="$STATE_SKIPPED_STEPS"
STATE_CURRENT_STEP="$STATE_CURRENT_STEP"
STATE_LAST_FAILED_STEP="$STATE_LAST_FAILED_STEP"
STATE_LAST_STATUS="$STATE_LAST_STATUS"
STATE_RUN_STARTED_AT="$STATE_RUN_STARTED_AT"
STATE_UPDATED_AT="$STATE_UPDATED_AT"
STATE_PKG_SKIP="$PKG_SKIP"
EOF
}

load_state_file() {
  if state_persistence_available && [ -f "$QUICK_INSTALL_STATE_FILE" ]; then
    # Older state files predate STATE_PKG_SKIP; default it so sourcing an old
    # file leaves PKG_SKIP empty (backward compatible).
    STATE_PKG_SKIP=""
    # shellcheck disable=SC1090
    . "$QUICK_INSTALL_STATE_FILE"
    PKG_SKIP="$STATE_PKG_SKIP"
    return 0
  fi
  return 1
}

clear_state_file() {
  if state_persistence_available; then
    rm -f "$QUICK_INSTALL_STATE_FILE"
  fi
}

record_interrupted_run() {
  if [ -n "$STATE_CURRENT_STEP" ]; then
    STATE_LAST_FAILED_STEP="$STATE_CURRENT_STEP"
    STATE_CURRENT_STEP=""
    STATE_LAST_STATUS="failed"
    save_state_file
  fi
}

# Unified trap dispatcher so the terminal is always restored AND the interrupted
# run is recorded, regardless of which phase (wizard vs install) is active.
# $1 = signal name (INT|TERM|EXIT).
on_signal() {
  local sig="$1"
  # Always restore the terminal first (no-op if the wizard never entered).
  tui_leave
  # Never leak the background sudo keep-alive loop, whatever phase we're in.
  if [ -n "${KEEPALIVE_PID:-}" ]; then
    kill "$KEEPALIVE_PID" 2>/dev/null || true
    KEEPALIVE_PID=""
  fi
  case "$sig" in
    INT|TERM)
      record_interrupted_run
      exit 130
      ;;
    EXIT)
      : # nothing extra; teardown already done.
      ;;
  esac
}

step_label() {
  case "$1" in
    prepare_and_clone_repo) echo "Prepare and clone repo" ;;
    install_local_bins) echo "Install local bins" ;;
    install_min_toolchain) echo "Install minimal toolchain (brew, node, npm)" ;;
    install_os_packages) echo "Install OS packages" ;;
    install_pyenv) echo "Install pyenv" ;;
    install_rbenv) echo "Install rbenv" ;;
    install_bun) echo "Install bun" ;;
    install_yarn) echo "Install yarn" ;;
    setup_fish) echo "Set up fish plugins and prompt" ;;
    setup_nvm_default_node) echo "Install latest Node.js LTS with nvm" ;;
    install_ai_tools) echo "Install AI coding tools (Claude Code, Codex)" ;;
    install_nerd_fonts) echo "Install nerd fonts" ;;
    set_default_shell_fish) echo "Set default shell to fish" ;;
    apply_fish_config) echo "Write fish config" ;;
    *) echo "$1" ;;
  esac
}

step_dependencies() {
  case "$1" in
    install_local_bins) echo "prepare_and_clone_repo" ;;
    install_min_toolchain) echo "prepare_and_clone_repo" ;;
    install_yarn) echo "install_os_packages" ;;
    setup_fish) echo "install_os_packages" ;;
    setup_nvm_default_node) echo "install_os_packages" ;;
    install_ai_tools) echo "install_min_toolchain" ;;
    set_default_shell_fish) echo "install_os_packages" ;;
    apply_fish_config) echo "prepare_and_clone_repo" ;;
  esac
}

step_default_enabled() {
  case "$1" in
    install_nerd_fonts)
      # NO_FONTS / --no-fonts are enforced by resolve_plan (env + flag layers)
      # and the install_nerd_fonts runtime guard; the default here is the
      # desktop-environment gate only (single source of truth for the override).
      is_desktop_environment
      return $?
      ;;
    *)
      return 0
      ;;
  esac
}

prompt_yes_no() {
  local message="$1"
  local default_answer="$2"
  local prompt answer

  if ! [ -t 0 ]; then
    [ "$default_answer" = "yes" ]
    return $?
  fi

  if [ "$default_answer" = "yes" ]; then
    prompt="[Y/n]"
  else
    prompt="[y/N]"
  fi

  while true; do
    printf "%s %s: " "$message" "$prompt"
    if ! read -r answer; then
      answer=""
    fi
    case "$answer" in
      "")
        [ "$default_answer" = "yes" ]
        return $?
        ;;
      y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
    esac
  done
}

configure_steps_interactively() {
  local step_id default answer

  printf "${BOLD}Select quick-install steps.${NORMAL}\n"
  printf "${BLUE}Press Enter to accept the default for each step.${NORMAL}\n"

  STATE_ENABLED_STEPS=""
  STATE_SKIPPED_STEPS=""

  for step_id in "${STEP_IDS[@]}"; do
    if step_default_enabled "$step_id"; then
      default="yes"
    else
      default="no"
    fi

    if prompt_yes_no "Run step: $(step_label "$step_id")" "$default"; then
      append_unique_word STATE_ENABLED_STEPS "$step_id"
    else
      append_unique_word STATE_SKIPPED_STEPS "$step_id"
    fi
  done
}

ensure_step_dependencies_selected() {
  local changed=1 step_id dep
  while [ "$changed" -eq 1 ]; do
    changed=0
    for step_id in $STATE_ENABLED_STEPS; do
      for dep in $(step_dependencies "$step_id"); do
        if contains_word "$dep" "$STATE_ENABLED_STEPS"; then
          continue
        fi
        append_unique_word STATE_ENABLED_STEPS "$dep"
        remove_word STATE_SKIPPED_STEPS "$dep"
        printf "${YELLOW}Enabling prerequisite step: %s${NORMAL}\n" "$(step_label "$dep")"
        changed=1
      done
    done
  done
}

# Capture environment variables into ENV_* shadow vars so resolve_plan can apply
# them as a precedence layer. Honors existing semantics (PF/USE_HTTPS/NO_FONTS/
# QUICK_INSTALL_STATE_FILE) and the new QUICK_INSTALL_SILENT.
ENV_NO_FONTS=""
ENV_USE_HTTPS=""
ENV_SILENT=""
capture_env() {
  ENV_NO_FONTS="${NO_FONTS:-}"
  ENV_USE_HTTPS="${USE_HTTPS:-}"
  ENV_SILENT="${QUICK_INSTALL_SILENT:-}"
  # --state-file flag overrides QUICK_INSTALL_STATE_FILE.
  if [ -n "$OPT_STATE_FILE" ]; then
    QUICK_INSTALL_STATE_FILE="$OPT_STATE_FILE"
  fi
}

# Expand a package selection token (group id or group:item or bare canonical)
# into canonical member ids. Appends to the named accumulator var.
pkg_expand_selection() {
  local acc_var="$1" token="$2" group member
  case "$token" in
    *:*)
      # group:item -> the item (canonical) directly.
      append_unique_word "$acc_var" "${token#*:}"
      ;;
    *)
      # A whole group id -> all its members; else treat as a bare canonical id.
      if contains_word "$token" "$(pkg_groups)"; then
        for member in $(pkg_group_members "$token"); do
          append_unique_word "$acc_var" "$member"
        done
      else
        append_unique_word "$acc_var" "$token"
      fi
      ;;
  esac
}

# Every canonical package id across all groups (space-delimited).
pkg_all_canonicals() {
  local group member out=""
  for group in $(pkg_groups); do
    for member in $(pkg_group_members "$group"); do
      if [ -n "$out" ]; then
        out="$out $member"
      else
        out="$member"
      fi
    done
  done
  printf '%s\n' "$out"
}

# resolve_plan: single source of truth for the final plan. Precedence order
# (low to high): defaults < wizard < env < flags. Produces STATE_ENABLED_STEPS,
# STATE_SKIPPED_STEPS, PKG_SKIP, then runs dependency closure last.
resolve_plan() {
  local step_id

  # --- Steps ---------------------------------------------------------------
  # 1. defaults (+ wizard): if the wizard ran it already seeded STATE_* from
  #    defaults and applied user toggles; otherwise compute defaults fresh.
  if [ "$WIZARD_RAN" -ne 1 ]; then
    STATE_ENABLED_STEPS=""
    STATE_SKIPPED_STEPS=""
    for step_id in "${STEP_IDS[@]}"; do
      if step_default_enabled "$step_id"; then
        append_unique_word STATE_ENABLED_STEPS "$step_id"
      else
        append_unique_word STATE_SKIPPED_STEPS "$step_id"
      fi
    done
  fi

  # 2. env layer: NO_FONTS forces install_nerd_fonts off (over wizard).
  if [ -n "$ENV_NO_FONTS" ]; then
    remove_word STATE_ENABLED_STEPS install_nerd_fonts
    append_unique_word STATE_SKIPPED_STEPS install_nerd_fonts
  fi

  # 3. flags layer (highest): --only / --skip / --no-fonts.
  if [ -n "$OPT_ONLY" ]; then
    STATE_ENABLED_STEPS=""
    STATE_SKIPPED_STEPS=""
    for step_id in "${STEP_IDS[@]}"; do
      if contains_word "$step_id" "$OPT_ONLY"; then
        append_unique_word STATE_ENABLED_STEPS "$step_id"
      else
        append_unique_word STATE_SKIPPED_STEPS "$step_id"
      fi
    done
  fi
  if [ -n "$OPT_SKIP" ]; then
    for step_id in $OPT_SKIP; do
      remove_word STATE_ENABLED_STEPS "$step_id"
      append_unique_word STATE_SKIPPED_STEPS "$step_id"
    done
  fi
  if [ -n "$OPT_NO_FONTS" ]; then
    remove_word STATE_ENABLED_STEPS install_nerd_fonts
    append_unique_word STATE_SKIPPED_STEPS install_nerd_fonts
  fi

  # --- Packages ------------------------------------------------------------
  # Defaults: skip nothing. Wizard may have pre-populated PKG_SKIP. Env: no
  # package layer. Flags: --packages (install ONLY these) / --skip-packages.
  if [ -n "$OPT_PACKAGES" ]; then
    # Install only the listed selections => skip the complement.
    local keep="" token canon
    for token in $OPT_PACKAGES; do
      pkg_expand_selection keep "$token"
    done
    PKG_SKIP=""
    for canon in $(pkg_all_canonicals); do
      if ! contains_word "$canon" "$keep"; then
        append_unique_word PKG_SKIP "$canon"
      fi
    done
  elif [ -n "$OPT_SKIP_PACKAGES" ]; then
    local token
    for token in $OPT_SKIP_PACKAGES; do
      pkg_expand_selection PKG_SKIP "$token"
    done
  fi

  # --- Dependency closure (correctness, applied last) ----------------------
  ensure_step_dependencies_selected
}

start_new_run() {
  reset_state_tracking
  STATE_RUN_STARTED_AT=$(date +%s)
  INSTALLED_NVM_VERSION=""
  if [ -t 0 ]; then
    configure_steps_interactively
    ensure_step_dependencies_selected
  else
    local step_id
    for step_id in "${STEP_IDS[@]}"; do
      if step_default_enabled "$step_id"; then
        append_unique_word STATE_ENABLED_STEPS "$step_id"
      else
        append_unique_word STATE_SKIPPED_STEPS "$step_id"
      fi
    done
  fi
  STATE_LAST_STATUS="pending"
  save_state_file
}

# Whether the current run is resuming a previously-failed run. When set, the
# wizard is skipped and the loaded plan (steps + package choices) is reused.
RESUMING=0

# Decide whether to resume a failed run or start fresh. Honors --fresh (which
# discards any saved state). Sets RESUMING=1 when resuming. Does NOT compute the
# fresh plan itself (resolve_plan / run_wizard do that in main).
prepare_run_plan() {
  RESUMING=0

  if [ -n "$OPT_FRESH" ]; then
    clear_state_file
    reset_state_tracking
    return 1
  fi

  if load_state_file && [ "$STATE_LAST_STATUS" = "running" ] && [ -n "$STATE_CURRENT_STEP" ]; then
    STATE_LAST_FAILED_STEP="$STATE_CURRENT_STEP"
    STATE_CURRENT_STEP=""
    STATE_LAST_STATUS="failed"
    save_state_file
  fi

  if load_state_file && [ "$STATE_LAST_STATUS" = "failed" ] && [ -n "$STATE_LAST_FAILED_STEP" ]; then
    printf "${YELLOW}A previous quick-install run failed at: %s${NORMAL}\n" "$(step_label "$STATE_LAST_FAILED_STEP")"
    if resume_prompt_continue; then
      RESUMING=1
      return 0
    fi
    printf "${BLUE}Starting a fresh quick-install run.${NORMAL}\n"
    clear_state_file
    reset_state_tracking
  fi

  return 1
}

# Ask whether to continue from the failed step, via the fd-3 terminal if
# available, else stdin, else default yes (non-interactive resume).
resume_prompt_continue() {
  local answer
  if tty_available; then
    while true; do
      printf "${BOLD}Continue from that failed step? [Y/n]: ${NORMAL}"
      answer=""
      tty_read answer || { return 0; }
      case "$answer" in
        ""|y|Y|yes|YES) return 0 ;;
        n|N|no|NO) return 1 ;;
      esac
    done
  fi
  prompt_yes_no "Continue from that failed step" "yes"
}

mark_step_skipped() {
  local step_id="$1"
  append_unique_word STATE_SKIPPED_STEPS "$step_id"
  remove_word STATE_COMPLETED_STEPS "$step_id"
}

run_step() {
  local step_id="$1"

  if contains_word "$step_id" "$STATE_COMPLETED_STEPS"; then
    printf "${GREEN}Skipping completed step: %s${NORMAL}\n" "$(step_label "$step_id")"
    return 0
  fi

  if ! contains_word "$step_id" "$STATE_ENABLED_STEPS"; then
    printf "${YELLOW}Skipping disabled step: %s${NORMAL}\n" "$(step_label "$step_id")"
    mark_step_skipped "$step_id"
    save_state_file
    return 0
  fi

  while true; do
    printf "${BOLD}Running step: %s${NORMAL}\n" "$(step_label "$step_id")"
    STATE_CURRENT_STEP="$step_id"
    STATE_LAST_STATUS="running"
    save_state_file

    if "$step_id"; then
      append_unique_word STATE_COMPLETED_STEPS "$step_id"
      remove_word STATE_SKIPPED_STEPS "$step_id"
      STATE_CURRENT_STEP=""
      STATE_LAST_FAILED_STEP=""
      STATE_LAST_STATUS="running"
      save_state_file
      return 0
    fi

    STATE_CURRENT_STEP=""
    STATE_LAST_FAILED_STEP="$step_id"
    STATE_LAST_STATUS="failed"
    save_state_file
    printf "${RED}Step failed: %s${NORMAL}\n" "$(step_label "$step_id")"

    # Interactive recovery via the fd-3 controlling terminal only. Silent /
    # non-interactive runs keep the original fail-and-exit (resumable) behavior.
    if tty_available; then
      local _choice=""
      while true; do
        printf "${YELLOW}[R]etry / [S]kip / [A]bort? ${NORMAL}"
        _choice=""
        tty_read _choice || _choice="a"
        case "$_choice" in
          r|R) break ;;                 # retry: loop again
          s|S)
            mark_step_skipped "$step_id"
            STATE_LAST_FAILED_STEP=""
            STATE_LAST_STATUS="running"
            save_state_file
            printf "${YELLOW}Skipped step: %s${NORMAL}\n" "$(step_label "$step_id")"
            return 0
            ;;
          a|A)
            printf "${YELLOW}Re-run quick-install to continue from this point.${NORMAL}\n"
            return 1
            ;;
        esac
      done
      # fell through with R -> retry the while-true loop.
      continue
    fi

    printf "${YELLOW}Re-run quick-install to continue from this point.${NORMAL}\n"
    return 1
  done
}

# Internal: run specific step bodies deterministically (used by the AI runbook
# and by tests). Comma-separated ids, executed in given order.
exec_steps_run() {
  local ids="$1" id rc=0 _r oldifs="$IFS"
  IFS=,
  for id in $ids; do
    # Attempt every listed step (matching the deterministic loop's behavior),
    # but return the FIRST non-zero status, preserving its real exit code.
    run_step "$id"; _r=$?
    if [ "$_r" -ne 0 ] && [ "$rc" -eq 0 ]; then rc=$_r; fi
  done
  IFS="$oldifs"
  return "$rc"
}

# =============================================================================
# §3b  AI CLI probe helpers (bash 3.2 safe; testable with PATH-shim stubs)
# =============================================================================

# True if the named AI CLI is on PATH.
cli_is_installed() {
  case "$1" in
    claude|codex) command -v "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# True if the named AI CLI reports an authenticated session.
# claude: `claude auth status` exits 0 when signed in.
# codex:  `codex login status` exits 0 when signed in.
cli_is_authenticated() {
  case "$1" in
    claude) claude auth status >/dev/null 2>&1 ;;
    codex)  codex login status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Resolve which AI CLI drives silent/unattended setup. Sets DRIVER and returns 0
# on success, or prints an error to STDERR and returns 1 if no usable driver.
# Never installs or logs in. Candidates: $OPT_SILENT_DRIVER if set, else
# "claude codex" in that order (word-split; bash 3.2 idiom).
resolve_silent_driver() {
  local candidates c
  if [ -n "$OPT_SILENT_DRIVER" ]; then candidates="$OPT_SILENT_DRIVER"; else candidates="claude codex"; fi
  for c in $candidates; do
    if cli_is_installed "$c" && cli_is_authenticated "$c"; then DRIVER="$c"; return 0; fi
  done
  if [ -n "$OPT_SILENT_DRIVER" ]; then
    printf "${RED}%s is not installed/authenticated.${NORMAL}\n" "$OPT_SILENT_DRIVER" >&2
  else
    printf "${RED}Neither Claude nor Codex is set up; cannot run unattended.${NORMAL}\n" >&2
  fi
  return 1
}

# Real interactive login for a named CLI via the controlling terminal (fd 3).
# This is a seam: tests override AUTH_LOGIN_CMD as a function to avoid real logins.
AUTH_LOGIN_CMD() {
  case "$1" in
    claude) claude auth login <&3 >&3 2>&3 ;;
    codex)  codex login        <&3 >&3 2>&3 ;;
  esac
}

# Ask which CLI drives setup when both are authenticated. Reads via fd 3.
# This is a seam: tests override _pick_driver to return a fixed value.
_pick_driver() {
  local ans
  printf "Which should drive setup? [claude/codex] (claude): " >&3
  IFS= read -r ans <&3 2>/dev/null || ans=""
  case "$ans" in codex) echo codex ;; *) echo claude ;; esac
}

# Detect or obtain authentication for claude and codex, then set DRIVER.
# Sets AUTHED_CLAUDE / AUTHED_CODEX to "1" or "".
# Returns 0 with DRIVER set, or 10 when neither CLI is authenticated.
run_auth_flow() {
  AUTHED_CLAUDE=""; AUTHED_CODEX=""
  local cli
  for cli in claude codex; do
    if cli_is_authenticated "$cli"; then
      printf "${GREEN}%s already authenticated.${NORMAL}\n" "$cli"
      # eval is the bash 3.2 safe way to set a variable whose name is dynamic
      # (no ${var^^} available); the tr produces a safe uppercase ASCII name.
      # shellcheck disable=SC2046
      eval "AUTHED_$(printf '%s' "$cli" | tr 'a-z' 'A-Z')=1"
    elif prompt_yes_no "Authenticate $cli now?" "yes"; then
      if AUTH_LOGIN_CMD "$cli"; then
        # shellcheck disable=SC2046
        eval "AUTHED_$(printf '%s' "$cli" | tr 'a-z' 'A-Z')=1"
      fi
    fi
  done
  if [ -n "$AUTHED_CLAUDE" ] && [ -n "$AUTHED_CODEX" ]; then
    DRIVER="$(_pick_driver)"
  elif [ -n "$AUTHED_CLAUDE" ]; then
    DRIVER=claude
  elif [ -n "$AUTHED_CODEX" ]; then
    DRIVER=codex
  else
    return 10
  fi
  return 0
}

# =============================================================================
# §3c  Agent invocation (run_agent / run_agent_with_fallback)
# =============================================================================

# run_agent <driver> <runbook>
# Build the exact argv for the given driver and run it (or RUN_AGENT_CMD if set).
run_agent() {
  local driver="$1" runbook="$2"
  case "$driver" in
    claude) set -- claude -p "$runbook" --dangerously-skip-permissions ;;
    codex)  set -- codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$runbook" ;;
    *) printf "${RED}Unknown driver: %s${NORMAL}\n" "$driver" >&2; return 2 ;;
  esac
  if command -v RUN_AGENT_CMD >/dev/null 2>&1; then RUN_AGENT_CMD "$@"; return $?; fi
  "$@"
}

# run_agent_with_fallback <runbook>
# Try DRIVER; on failure, if OPT_SILENT_DRIVER is set return the failure code
# (no fallback). Otherwise try the other authed candidate if available.
run_agent_with_fallback() {
  local runbook="$1" first="$DRIVER" other rc
  run_agent "$first" "$runbook" && return 0
  rc=$?
  [ -n "$OPT_SILENT_DRIVER" ] && return "$rc"        # explicit driver: no fallback
  case "$first" in claude) other=codex ;; codex) other=claude ;; *) return "$rc" ;; esac
  if cli_is_installed "$other" && cli_is_authenticated "$other"; then
    printf "${YELLOW}%s run failed; retrying with %s...${NORMAL}\n" "$first" "$other" >&2
    run_agent "$other" "$runbook"; return $?
  fi
  return "$rc"
}

# =============================================================================
# §3d  Sudo keep-alive + AI orchestration (main_ai_flow)
# =============================================================================

# Prime sudo and keep the timestamp warm in the background (interactive only).
# Silent runs cannot prompt, so they rely on cached/passwordless sudo instead.
# Sets KEEPALIVE_PID when a keep-alive loop is launched.
sudo_keepalive_start() {
  [ -n "$OPT_SILENT" ] && return 0            # cannot prompt unattended
  sudo -v 2>/dev/null || { printf "${YELLOW}No sudo; sudo steps may fail.${NORMAL}\n"; return 0; }
  ( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &
  KEEPALIVE_PID=$!
}

# Stop the background sudo keep-alive loop. No-op (and never errors) when unset.
sudo_keepalive_stop() {
  [ -n "${KEEPALIVE_PID:-}" ] && kill "$KEEPALIVE_PID" 2>/dev/null
  KEEPALIVE_PID=""
}

# Orchestrate the AI-driven install: resolve the plan, run the deterministic
# prereq core (skip-aware), select/verify the driver, then hand the generated
# runbook to the agent. Returns the agent's exit code, or 0 when the interactive
# auth flow finds no authenticated CLI (guidance printed; nothing installed).
main_ai_flow() {
  resolve_plan                                  # wizard (interactive) or defaults+flags
  prepare_and_clone_repo
  install_min_toolchain
  if [ "$MODE" = interactive ]; then
    install_ai_tools
    local rc
    run_auth_flow; rc=$?
    if [ "$rc" -eq 10 ]; then
      printf "No AI CLI authenticated. Re-run to authenticate, or --silent=<cli> once set up.\n"
      return 0
    fi
  else
    resolve_silent_driver || return 1
  fi
  sudo_keepalive_start
  local os rb; os="$(detect_os_key)"; rb="$(generate_runbook "$os")"
  if [ "$MODE" = silent ]; then run_agent_with_fallback "$rb"; else run_agent "$DRIVER" "$rb"; fi
  local rc=$?
  sudo_keepalive_stop
  return "$rc"
}

# =============================================================================
# §8  Step bodies (unchanged behavior)
# =============================================================================

# Print path of first existing SSH public key (id_ed25519, id_rsa, id_ecdsa, etc.)
find_ssh_public_key() {
  local key
  for key in id_ed25519 id_rsa id_ecdsa id_ecdsa_sk id_ed25519_sk; do
    if [ -f "$HOME/.ssh/${key}.pub" ]; then
      echo "$HOME/.ssh/${key}.pub"
      return 0
    fi
  done
  return 1
}

# Ensure ~/.ssh exists and user has at least one SSH public key; create one if not.
# Prefers ed25519, falls back to RSA for older ssh-keygen.
ensure_ssh_key() {
  local keypath="$HOME/.ssh/id_ed25519"
  find_ssh_public_key >/dev/null && return 0

  printf "${BLUE}No SSH public key found. Generating one...${NORMAL}\n"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  if ssh-keygen -t ed25519 -f "$keypath" -N "" -q 2>/dev/null; then
    return 0
  fi

  keypath="$HOME/.ssh/id_rsa"
  printf "${YELLOW}ed25519 not available, generating RSA 4096 key.${NORMAL}\n"
  ssh-keygen -t rsa -b 4096 -f "$keypath" -N "" -q
}

# Print public key and ask user to add it to GitHub, then wait for Enter (if interactive).
prompt_ssh_key_added_to_github() {
  local pubkey
  pubkey=$(find_ssh_public_key) || return 1
  printf "\n${BOLD}Add this SSH key to GitHub (https://github.com/settings/keys):${NORMAL}\n\n"
  cat "$pubkey"
  printf "\n${BLUE}Then press Enter to continue (or set USE_HTTPS=1 and re-run to clone via HTTPS instead).${NORMAL}\n"
  # Prefer the fd-3 controlling terminal (works under curl | bash); fall back to
  # stdin if it is a TTY.
  if tty_available; then
    local _ack
    tty_read _ack
  elif [ -t 0 ]; then
    read -r
  fi
}

find_brew_bin() {
  local brew_bin

  if brew_bin=$(command -v brew 2>/dev/null); then
    printf '%s\n' "$brew_bin"
    return 0
  fi

  for brew_bin in \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew \
    "$HOME/.linuxbrew/bin/brew" \
    /home/linuxbrew/.linuxbrew/bin/brew; do
    if [ -x "$brew_bin" ]; then
      printf '%s\n' "$brew_bin"
      return 0
    fi
  done

  return 1
}

setup_brew_env() {
  local brew_bin

  brew_bin=$(find_brew_bin) || {
    echo "Error: Homebrew was not found after installation"
    exit 1
  }

  eval "$("$brew_bin" shellenv)"
}

apply_fish_config() {
  printf "${BLUE}Installing fish config...${NORMAL}\n"
  FISH_CONFIG_PATH="$HOME/.config/fish/config.fish"
  mkdir -p "$(dirname "$FISH_CONFIG_PATH")"
  cat << EOF > "$FISH_CONFIG_PATH"
if status is-interactive
    source "$HOME/.leos-profiles/fish/start.fish"
    set fish_greeting
end
EOF
}

# Clone repo. Pass use_ssh=1 for SSH, 0 for HTTPS.
clone_repo() {
  local use_ssh="${1:-1}"
  if [ -d "$PF" ]; then
    printf "${YELLOW}You already have Leo's Profiles cloned.${NORMAL}\n"
    return 0
  fi
  command -v git >/dev/null 2>&1 || {
    echo "Error: git is not installed"
    exit 1
  }
  if [ "$use_ssh" = "1" ]; then
    printf "${BLUE}Cloning Leo's Profiles (SSH)...${NORMAL}\n"
    env git clone git@github.com:foxhatleo/leos-profiles.git "$PF" || {
      printf "Error: git clone via SSH failed. Try again or run with USE_HTTPS=1 to use HTTPS.\n"
      exit 1
    }
  else
    printf "${BLUE}Cloning Leo's Profiles (HTTPS)...${NORMAL}\n"
    env git clone https://github.com/foxhatleo/leos-profiles "$PF" || {
      printf "Error: git clone of Leo's Profiles repo failed\n"
      exit 1
    }
  fi
}

# Ensure SSH key exists, prompt user to add to GitHub, then clone. Or use HTTPS if skipped.
prepare_and_clone_repo() {
  local use_ssh=1
  if [ -d "$PF" ]; then
    clone_repo 1
    return 0
  fi

  if [ -n "${USE_HTTPS:-}" ] || [ -n "$OPT_HTTPS" ]; then
    use_ssh=0
  elif tty_available; then
    printf "${BLUE}Clone with SSH? (recommended; requires this machine's SSH key on GitHub) [Y/n]: ${NORMAL}"
    answer=""
    tty_read answer
    case "$answer" in
      n|N|no|NO) use_ssh=0 ;;
    esac
  elif [ -t 0 ]; then
    printf "${BLUE}Clone with SSH? (recommended; requires this machine's SSH key on GitHub) [Y/n]: ${NORMAL}"
    read -r answer
    case "$answer" in
      n|N|no|NO) use_ssh=0 ;;
    esac
  else
    use_ssh=0
  fi

  if [ "$use_ssh" = "1" ]; then
    ensure_ssh_key
    prompt_ssh_key_added_to_github
  fi

  clone_repo "$use_ssh"
}

install_local_bins() {
  printf "${BLUE}Install local bins...${NORMAL}\n"
  mkdir -p "$HOME/.local/bin"
  curl -o "$HOME/.local/bin/rpatool" https://raw.githubusercontent.com/shizmob/rpatool/master/rpatool
  chmod u+x "$HOME/.local/bin/rpatool"
}

# Return 0 (needs install) when node is absent; 1 when already present.
min_toolchain_needs_node() { ! command -v node >/dev/null 2>&1; }
# Return 0 (needs install) when npm is absent; 1 when already present.
min_toolchain_needs_npm()  { ! command -v npm  >/dev/null 2>&1; }

# Install only nodejs+npm for the current Linux distro, mirroring the package
# names used in install_packages_apt/fedora/pacman.
install_os_node_npm() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get -y install nodejs npm
  elif command -v dnf >/dev/null 2>&1 && is_fedora; then
    sudo dnf -y install nodejs
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm nodejs npm
  else
    printf "${RED}Unsupported OS: cannot install nodejs/npm.${NORMAL}\n"
    exit 1
  fi
}

# Minimal path to a working npm: brew (macOS) + node. Skips anything present.
install_min_toolchain() {
  printf "${BLUE}Ensuring minimal toolchain (brew, node, npm)...${NORMAL}\n"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if ! find_brew_bin >/dev/null 2>&1; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    setup_brew_env
    if min_toolchain_needs_node; then brew install node; fi
  else
    if min_toolchain_needs_node || min_toolchain_needs_npm; then
      install_os_node_npm
    fi
  fi
}

# =============================================================================
# §5  Package registry + literal install_packages_* functions
#     (literal lists are parsed by verify-quick-install-packages.py — do NOT
#      alter the literal package-name lists)
# =============================================================================
#
# The registry is an additive UI/filtering layer. Canonical (logical) ids are
# usually the Homebrew name. pkg_resolve maps canonical -> the real per-OS name
# (or "" when the package does not exist on that OS). The union of resolved
# members per OS exactly equals that OS's literal install list (parity-tested).

# Group ids in render order.
pkg_groups() {
  printf '%s\n' core-utils shell dev-tools languages media network system
}

# Group id -> human label.
pkg_group_label() {
  case "$1" in
    core-utils) echo "Core CLI utilities" ;;
    shell)      echo "Shell (fish, zsh)" ;;
    dev-tools)  echo "Developer tools & build" ;;
    languages)  echo "Languages & runtimes" ;;
    media)      echo "Media (ffmpeg, imagemagick, yt-dlp)" ;;
    network)    echo "Network & transfer (wget, rclone)" ;;
    system)     echo "System & disk (smartmontools)" ;;
    *) echo "$1" ;;
  esac
}

# Group id -> canonical member ids (space-delimited).
pkg_group_members() {
  case "$1" in
    core-utils) echo "bash coreutils diffutils ed findutils gnu-indent gnu-sed gnu-tar gnu-which grep gawk gzip less nano" ;;
    shell)      echo "fish zsh" ;;
    dev-tools)  echo "git vim build-essential clang gcc base-devel" ;;
    languages)  echo "node python ruby" ;;
    media)      echo "ffmpeg imagemagick yt-dlp" ;;
    network)    echo "wget rclone gnutls heroku ssh-copy-id" ;;
    system)     echo "smartmontools" ;;
    *) echo "" ;;
  esac
}

# $1=os (macos|apt|fedora|pacman)  $2=canonical id
# Echo the real per-OS package name(s), or nothing if absent on that OS.
pkg_resolve() {
  local os="$1" id="$2"
  case "$os:$id" in
    # Homebrew-only extras.
    macos:gnu-indent)  echo gnu-indent ;;
    *:gnu-indent)      : ;;
    macos:gnu-sed)     echo gnu-sed ;;
    *:gnu-sed)         : ;;
    macos:gnu-tar)     echo gnu-tar ;;
    *:gnu-tar)         : ;;
    macos:gnu-which)   echo gnu-which ;;
    *:gnu-which)       : ;;
    macos:gnutls)      echo gnutls ;;
    *:gnutls)          : ;;
    macos:ssh-copy-id) echo ssh-copy-id ;;
    *:ssh-copy-id)     : ;;
    macos:heroku)      echo heroku ;;
    *:heroku)          : ;;
    # Build toolchains (each OS has its own meta/packages).
    apt:build-essential) echo build-essential ;;
    *:build-essential)   : ;;
    apt:clang)           echo clang ;;
    *:clang)             : ;;
    apt:gcc)             echo gcc ;;
    *:gcc)               : ;;
    pacman:base-devel)   echo base-devel ;;
    *:base-devel)        : ;;
    # Node.
    macos:node)   echo node ;;
    apt:node)     echo nodejs ;;
    fedora:node)  echo nodejs ;;
    pacman:node)  echo "nodejs npm" ;;
    # Python.
    macos:python)  echo python ;;
    pacman:python) echo python ;;
    apt:python)    echo python-is-python3 ;;
    fedora:python) echo python-is-python3 ;;
    # ImageMagick (capitalized on Fedora).
    fedora:imagemagick) echo ImageMagick ;;
    *:imagemagick)      echo imagemagick ;;
    # Default: same name on every OS.
    *) echo "$id" ;;
  esac
}

# Reverse-map a real per-OS package name to its canonical id.
# Echoes the canonical id, or the name itself if it is not a registry member.
pkg_canonical_for() {
  local os="$1" name="$2" group member real
  for group in $(pkg_groups); do
    for member in $(pkg_group_members "$group"); do
      for real in $(pkg_resolve "$os" "$member"); do
        if [ "$real" = "$name" ]; then
          echo "$member"
          return 0
        fi
      done
    done
  done
  echo "$name"
}

# Filter a literal space-delimited package list for one OS, dropping any name
# whose canonical id is in PKG_SKIP. $1=os, $2=literal list. Echoes kept list.
pkg_filter_for_os() {
  local os="$1" list="$2" name canon out
  out=""
  for name in $list; do
    canon=$(pkg_canonical_for "$os" "$name")
    if contains_word "$canon" "$PKG_SKIP"; then
      continue
    fi
    if [ -n "$out" ]; then
      out="$out $name"
    else
      out="$name"
    fi
  done
  printf '%s\n' "$out"
}

# Full resolved package list for an OS (union of all groups, parity-locked to
# the literal install lists). $1=os. Echoes space-delimited real names.
pkg_list_for_os() {
  local os="$1" group member real out=""
  for group in $(pkg_groups); do
    for member in $(pkg_group_members "$group"); do
      for real in $(pkg_resolve "$os" "$member"); do
        if [ -n "$out" ]; then
          out="$out $real"
        else
          out="$real"
        fi
      done
    done
  done
  printf '%s\n' "$out"
}

# True if any package skip is in effect (gate for the filtered install path).
pkg_skip_active() {
  [ -n "$PKG_SKIP" ]
}

install_packages_macos() {
  printf "${BLUE}You are on macOS!${NORMAL}\n"
  printf "${BLUE}Installing Homebrew...${NORMAL}\n"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  setup_brew_env
  printf "${BLUE}Installing packages...${NORMAL}\n"
  brew tap heroku/brew
  if pkg_skip_active; then
    # Filtered install via the parity-locked registry. Uses an indirected
    # subcommand so verify-quick-install-packages.py ignores this line and only
    # parses the literal `brew install ...` below.
    local _bi="install" _bp
    _bp=$(pkg_filter_for_os macos "$(pkg_list_for_os macos)")
    brew "$_bi" $_bp
    return 0
  fi
  brew install bash coreutils diffutils ed ffmpeg findutils fish heroku \
    imagemagick git gnu-indent gnu-sed gnu-tar gnu-which gnutls grep gawk \
    gzip less nano node python rclone ruby smartmontools ssh-copy-id \
    vim wget yt-dlp zsh
}

install_packages_apt() {
  printf "${BLUE}You are on Debian-based!${NORMAL}\n"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  sudo apt -y update
  sudo apt -y upgrade
  if pkg_skip_active; then
    local _ai="install" _ap
    _ap=$(pkg_filter_for_os apt "$(pkg_list_for_os apt)")
    sudo apt -y "$_ai" $_ap
    return 0
  fi
  sudo apt -y install bash build-essential clang coreutils diffutils ed ffmpeg \
    findutils fish imagemagick gcc git grep gawk gzip less nano nodejs \
    python-is-python3 rclone ruby smartmontools vim wget yt-dlp zsh
}

install_packages_fedora() {
  printf "${BLUE}You are on Fedora!${NORMAL}\n"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  sudo dnf -y update
  sudo dnf -y group install "development-tools"
  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    sudo dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
  fi
  if pkg_skip_active; then
    # Filtered install of the main package set (ffmpeg is handled by the swap
    # special lines below and is intentionally excluded here). Indirected
    # subcommand keeps this line out of the verify parser.
    local _di="install" _dp
    _dp=$(pkg_filter_for_os fedora "$(remove_word_inline "$(pkg_list_for_os fedora)" ffmpeg)")
    sudo dnf -y "$_di" $_dp
  else
  sudo dnf -y install bash coreutils diffutils ed findutils fish \
    ImageMagick git grep gawk gzip less nano nodejs python-is-python3 rclone \
    ruby smartmontools vim wget yt-dlp zsh
  fi
  if rpm -q ffmpeg-free >/dev/null 2>&1; then
    sudo dnf -y swap ffmpeg-free ffmpeg --allowerasing
  else
    sudo dnf -y install ffmpeg
  fi
}

install_packages_pacman() {
  printf "${BLUE}You are on Arch Linux!${NORMAL}\n"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  sudo pacman -Syu --noconfirm
  if pkg_skip_active; then
    local _ps="-S" _pp
    _pp=$(pkg_filter_for_os pacman "$(pkg_list_for_os pacman)")
    sudo pacman "$_ps" --noconfirm $_pp
    return 0
  fi
  sudo pacman -S --noconfirm base-devel bash coreutils diffutils ed ffmpeg \
    findutils fish imagemagick git grep gawk gzip less nano nodejs npm python \
    rclone ruby smartmontools vim wget yt-dlp zsh
}

is_fedora() {
  [ -r /etc/os-release ] || return 1
  grep -Eq '^ID="?fedora"?$' /etc/os-release
}

install_os_packages() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    install_packages_macos
  elif command -v apt-get &>/dev/null; then
    install_packages_apt
  elif command -v dnf &>/dev/null && is_fedora; then
    install_packages_fedora
  elif command -v pacman &>/dev/null; then
    install_packages_pacman
  else
    printf "${RED}Unsupported OS for quick-install package bootstrap.${NORMAL}\n"
    exit 1
  fi
}

# --- §8 step bodies continue ---------------------------------------------

install_pyenv() {
  printf "${BLUE}Installing pyenv...${NORMAL}\n"
  if [ -d "$HOME/.pyenv" ]; then
    printf "${YELLOW}You already have pyenv cloned.${NORMAL}\n"
  else
    git clone https://github.com/pyenv/pyenv.git "$HOME/.pyenv"
    (cd "$HOME/.pyenv" && src/configure && make -C src)
  fi
  cd "$HOME"
}

install_rbenv() {
  printf "${BLUE}Installing rbenv...${NORMAL}\n"
  if [ -d "$HOME/.rbenv" ]; then
    printf "${YELLOW}You already have rbenv cloned.${NORMAL}\n"
  else
    git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
    mkdir -p "$("$HOME/.rbenv/bin/rbenv" root)"/plugins
    git clone https://github.com/rbenv/ruby-build.git "$("$HOME/.rbenv/bin/rbenv" root)/plugins/ruby-build"
  fi
}

install_bun() {
  printf "${BLUE}Installing bun...${NORMAL}\n"
  curl -fsSL https://bun.com/install | bash
}

install_yarn() {
  printf "${BLUE}Installing yarn...${NORMAL}\n"
  npm install --global yarn
}

ensure_fisher_and_nvm_fish() {
  fish -c "curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher"
  fish -c "fisher install jorgebucaran/nvm.fish"
}

setup_fish() {
  printf "${BLUE}Setting up fish...${NORMAL}\n"
  ensure_fisher_and_nvm_fish
  fish -c "fisher install PatrickF1/fzf.fish"
  fish -c "fisher install franciscolourenco/done"
  fish -c "fisher install decors/fish-colored-man"
  fish -c "fisher install gazorby/fish-abbreviation-tips"
  fish -c "fisher install jorgebucaran/autopair.fish"
  fish -c "fisher install IlanCosman/tide@v6"
  fish -c "fisher install lgathy/google-cloud-sdk-fish-completion"
  fish -c "tide configure --auto --style=Rainbow --prompt_colors='True color' --show_time=No --rainbow_prompt_separators=Angled --powerline_prompt_heads=Sharp --powerline_prompt_tails=Flat --powerline_prompt_style='Two lines, character' --prompt_connection=Dotted --powerline_right_prompt_frame=No --prompt_connection_andor_frame_color=Light --prompt_spacing=Sparse --icons='Few icons' --transient=No"
  fish -c "fish_update_completions"
  curl -LsS https://iterm2.com/shell_integration/fish -o "$HOME/.iterm2_shell_integration.fish"
  # Reduce Tide icons that conflict with IntelliJ terminals
  fish -c "set -U tide_distrobox_icon"
  fish -c "set -U tide_gcloud_icon"
  fish -c "set -U tide_kubectl_icon"
  fish -c "set -U tide_private_mode_icon"
  fish -c "set -U tide_python_icon"
  fish -c "set -U tide_terraform_icon"
  fish -c "set -U tide_right_prompt_items status cmd_duration context jobs direnv node python rustc java php ruby go"
  fish -c "set -U fish_key_bindings fish_default_key_bindings"

  if [ -n "$INSTALLED_NVM_VERSION" ]; then
    fish -c "set -U nvm_default_version $INSTALLED_NVM_VERSION"
  else
    # current_version is a fish-local variable inside this fish -c program, not a
    # bash variable; shellcheck cannot see across the language boundary.
    # shellcheck disable=SC2154
    fish -c "if set -l current_version (nvm current 2>/dev/null); and test -n \"$current_version\"; and test \"$current_version\" != \"none\"; set -U nvm_default_version $current_version; else; set -Ue nvm_default_version; end"
  fi
}

setup_nvm_default_node() {
  printf "${BLUE}Installing latest Node.js LTS with nvm...${NORMAL}\n"
  ensure_fisher_and_nvm_fish
  INSTALLED_NVM_VERSION=$(fish -c 'nvm install lts >/dev/null; set -l current_version (nvm current 2>/dev/null); if test -n "$current_version"; and test "$current_version" != "none"; printf "%s\n" "$current_version"; end' | tr -d '[:space:]')
}

# Copy a starter config into place only if the target does not already exist.
# $1 = template path relative to the repo, $2 = absolute destination path.
seed_one_ai_config() {
  local src="$PF/$1" dst="$2"
  [ -f "$src" ] || return 0
  if [ -f "$dst" ]; then
    printf "${YELLOW}Keeping existing %s${NORMAL}\n" "$dst"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  printf "${GREEN}Seeded %s${NORMAL}\n" "$dst"
}

seed_ai_config() {
  seed_one_ai_config res/ai/claude-settings.json "$HOME/.claude/settings.json"
  seed_one_ai_config res/ai/codex-config.toml "$HOME/.codex/config.toml"
}

setup_ai_tools_node() {
  ensure_fisher_and_nvm_fish
  fish -c "npm install -g @anthropic-ai/claude-code @openai/codex"
}

install_ai_tools() {
  if cli_is_installed claude && cli_is_installed codex; then
    printf "${YELLOW}Claude Code and Codex already installed; skipping npm install.${NORMAL}\n"
    seed_ai_config
    return 0
  fi
  printf "${BLUE}Installing AI coding tools (Claude Code, Codex)...${NORMAL}\n"
  setup_ai_tools_node
  seed_ai_config
}

# True if we're on a desktop (macOS or Linux with X/Wayland/DE). Skip nerd fonts on servers.
is_desktop_environment() {
  [[ "$OSTYPE" == "darwin"* ]] && return 0
  [[ -n "${DISPLAY:-}" ]] && return 0
  [[ -n "${WAYLAND_DISPLAY:-}" ]] && return 0
  [[ -n "${XDG_CURRENT_DESKTOP:-}" ]] && return 0
  return 1
}

install_nerd_fonts() {
  if [ -n "${NO_FONTS:-}" ]; then
    printf "${YELLOW}Skipping nerd font install because NO_FONTS is set.${NORMAL}\n"
    return 0
  fi
  if ! is_desktop_environment; then
    printf "${YELLOW}Skipping nerd font install (server/no desktop detected).${NORMAL}\n"
    return 0
  fi
  printf "${BLUE}Installing nerd fonts...${NORMAL}\n"
  git clone https://github.com/ryanoasis/nerd-fonts.git --depth=1
  (cd nerd-fonts && ./install.sh)
  rm -rf nerd-fonts fonts
}

set_default_shell_fish() {
  FISH_PATH=$(which fish 2>/dev/null || true)
  if [ -z "$FISH_PATH" ]; then
    echo "Fish shell is not installed. Exiting."
    exit 1
  fi
  if ! grep -qxFe "$FISH_PATH" /etc/shells 2>/dev/null; then
    echo "Adding $FISH_PATH to /etc/shells"
    echo "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
  else
    echo "Fish shell is already listed in /etc/shells."
  fi
  echo "Changing default shell to Fish..."
  chsh -s "$FISH_PATH"
}

# =============================================================================
# §8b  Runbook generation
#      detect_os_key / runbook_step_block / generate_runbook / --print-runbook
# =============================================================================

# Steps done deterministically in the prereq core — excluded from the runbook.
PREREQ_STEPS="prepare_and_clone_repo install_min_toolchain install_ai_tools"

# Complex / multi-command / state-sharing steps delegated via --exec-steps.
DELEGATED_STEPS="setup_nvm_default_node setup_fish set_default_shell_fish"

# Echo macos|apt|fedora|pacman using the same dispatch as install_os_packages.
detect_os_key() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo macos
  elif command -v apt-get >/dev/null 2>&1; then
    echo apt
  elif command -v dnf >/dev/null 2>&1 && is_fedora; then
    echo fedora
  elif command -v pacman >/dev/null 2>&1; then
    echo pacman
  else
    echo macos
  fi
}

# runbook_step_block <id> <os>
# Emit one STEP block for the given step id on the given OS.
# Inlined steps show exact commands; delegated steps show --exec-steps=.
runbook_step_block() {
  local id="$1" os="$2" label cmd already_done success_check

  label="$(step_label "$id")"

  # Determine if this step is delegated (show --exec-steps) or inlined.
  if contains_word "$id" "$DELEGATED_STEPS"; then
    # Group setup_nvm_default_node and setup_fish together when both are enabled,
    # because setup_fish reads INSTALLED_NVM_VERSION set by setup_nvm_default_node.
    if [ "$id" = "setup_nvm_default_node" ] && contains_word "setup_fish" "$STATE_ENABLED_STEPS"; then
      # Emit a combined block for both nvm+fish; setup_fish block will be suppressed.
      cmd="bash \"\$PF/util/quick-install.sh\" --exec-steps=setup_nvm_default_node,setup_fish"
      already_done="nvm current >/dev/null 2>&1 && fish -c 'tide --version' >/dev/null 2>&1"
      success_check="fish -c 'nvm current' && fish -c 'tide --version'"
      printf 'STEP %s — %s\n' "$id" "$label"
      printf '  Run exactly:\n    %s\n' "$cmd"
      printf '  Also covers: setup_fish — Set up fish plugins and prompt\n'
      printf '  Already-done check: %s\n' "$already_done"
      printf '  Success check: %s\n\n' "$success_check"
      return
    elif [ "$id" = "setup_fish" ] && contains_word "setup_nvm_default_node" "$STATE_ENABLED_STEPS"; then
      # Suppressed: already emitted as part of the nvm+fish combined block above.
      return
    else
      # Delegated individually.
      cmd="bash \"\$PF/util/quick-install.sh\" --exec-steps=${id}"
    fi
    case "$id" in
      setup_fish)
        already_done="fish -c 'tide --version' >/dev/null 2>&1"
        success_check="fish -c 'tide --version'"
        ;;
      setup_nvm_default_node)
        already_done="fish -c 'nvm current' >/dev/null 2>&1"
        success_check="fish -c 'nvm current'"
        ;;
      set_default_shell_fish)
        already_done="[ \"\$(basename \"\$SHELL\")\" = fish ]"
        success_check="echo \$SHELL | grep -q fish"
        ;;
      *)
        already_done="true  # inspect manually"
        success_check="true  # inspect manually"
        ;;
    esac
  else
    # Inlined: emit the exact command for this step on this OS.
    case "$id" in
      install_os_packages)
        case "$os" in
          macos)
            if pkg_skip_active; then
              local _pkgs
              _pkgs="$(pkg_filter_for_os macos "$(pkg_list_for_os macos)")"
              cmd="brew tap heroku/brew && brew install ${_pkgs}"
            else
              cmd="brew tap heroku/brew && brew install bash coreutils diffutils ed ffmpeg findutils fish heroku imagemagick git gnu-indent gnu-sed gnu-tar gnu-which gnutls grep gawk gzip less nano node python rclone ruby smartmontools ssh-copy-id vim wget yt-dlp zsh"
            fi
            already_done="brew list bash >/dev/null 2>&1"
            success_check="brew list fish >/dev/null 2>&1"
            ;;
          apt)
            if pkg_skip_active; then
              local _pkgs
              _pkgs="$(pkg_filter_for_os apt "$(pkg_list_for_os apt)")"
              cmd="sudo apt -y update && sudo apt -y upgrade && sudo apt -y install ${_pkgs}"
            else
              cmd="sudo apt -y update && sudo apt -y upgrade && sudo apt -y install bash build-essential clang coreutils diffutils ed ffmpeg findutils fish imagemagick gcc git grep gawk gzip less nano nodejs python-is-python3 rclone ruby smartmontools vim wget yt-dlp zsh"
            fi
            already_done="dpkg -l bash >/dev/null 2>&1"
            success_check="dpkg -l fish | grep -q '^ii'"
            ;;
          fedora)
            if pkg_skip_active; then
              local _pkgs
              _pkgs="$(pkg_filter_for_os fedora "$(remove_word_inline "$(pkg_list_for_os fedora)" ffmpeg)")"
              cmd="sudo dnf -y update && sudo dnf -y group install development-tools && sudo dnf -y install ${_pkgs} && sudo dnf -y install ffmpeg"
            else
              cmd="sudo dnf -y update && sudo dnf -y group install development-tools && sudo dnf -y install bash coreutils diffutils ed findutils fish ImageMagick git grep gawk gzip less nano nodejs python-is-python3 rclone ruby smartmontools vim wget yt-dlp zsh && sudo dnf -y install ffmpeg"
            fi
            already_done="rpm -q bash >/dev/null 2>&1"
            success_check="rpm -q fish"
            ;;
          pacman)
            if pkg_skip_active; then
              local _pkgs
              _pkgs="$(pkg_filter_for_os pacman "$(pkg_list_for_os pacman)")"
              cmd="sudo pacman -Syu --noconfirm && sudo pacman -S --noconfirm ${_pkgs}"
            else
              cmd="sudo pacman -Syu --noconfirm && sudo pacman -S --noconfirm base-devel bash coreutils diffutils ed ffmpeg findutils fish imagemagick git grep gawk gzip less nano nodejs npm python rclone ruby smartmontools vim wget yt-dlp zsh"
            fi
            already_done="pacman -Q bash >/dev/null 2>&1"
            success_check="pacman -Q fish"
            ;;
        esac
        ;;
      install_local_bins)
        cmd="mkdir -p \"\$HOME/.local/bin\" && curl -o \"\$HOME/.local/bin/rpatool\" https://raw.githubusercontent.com/shizmob/rpatool/master/rpatool && chmod u+x \"\$HOME/.local/bin/rpatool\""
        already_done="[ -x \"\$HOME/.local/bin/rpatool\" ]"
        success_check="[ -x \"\$HOME/.local/bin/rpatool\" ]"
        ;;
      install_pyenv)
        cmd="git clone https://github.com/pyenv/pyenv.git \"\$HOME/.pyenv\" && (cd \"\$HOME/.pyenv\" && src/configure && make -C src)"
        already_done="[ -d \"\$HOME/.pyenv\" ]"
        success_check="[ -d \"\$HOME/.pyenv\" ] && \"\$HOME/.pyenv/bin/pyenv\" --version"
        ;;
      install_rbenv)
        cmd="git clone https://github.com/rbenv/rbenv.git \"\$HOME/.rbenv\" && mkdir -p \"\$(\"\$HOME/.rbenv/bin/rbenv\" root)\"/plugins && git clone https://github.com/rbenv/ruby-build.git \"\$(\"\$HOME/.rbenv/bin/rbenv\" root)/plugins/ruby-build\""
        already_done="[ -d \"\$HOME/.rbenv\" ]"
        success_check="[ -d \"\$HOME/.rbenv\" ] && \"\$HOME/.rbenv/bin/rbenv\" --version"
        ;;
      install_bun)
        cmd="curl -fsSL https://bun.com/install | bash"
        already_done="command -v bun >/dev/null 2>&1"
        success_check="bun --version"
        ;;
      install_yarn)
        cmd="npm install --global yarn"
        already_done="command -v yarn >/dev/null 2>&1"
        success_check="yarn --version"
        ;;
      install_nerd_fonts)
        cmd="git clone https://github.com/ryanoasis/nerd-fonts.git --depth=1 && (cd nerd-fonts && ./install.sh) && rm -rf nerd-fonts fonts"
        already_done="[ -d \"\$HOME/.local/share/fonts\" ] && ls \"\$HOME/.local/share/fonts/\" | grep -qi nerd"
        success_check="ls \"\$HOME/.local/share/fonts/\" | grep -qi nerd"
        ;;
      apply_fish_config)
        cmd="mkdir -p \"\$HOME/.config/fish\" && printf '%s\\n' 'if status is-interactive' \"    source \\\"\$HOME/.leos-profiles/fish/start.fish\\\"\" '    set fish_greeting' 'end' > \"\$HOME/.config/fish/config.fish\""
        already_done="[ -f \"\$HOME/.config/fish/config.fish\" ]"
        success_check="grep -q leos-profiles \"\$HOME/.config/fish/config.fish\""
        ;;
      *)
        cmd="bash \"\$PF/util/quick-install.sh\" --exec-steps=${id}"
        already_done="true  # inspect manually"
        success_check="true  # inspect manually"
        ;;
    esac
  fi

  printf 'STEP %s — %s\n' "$id" "$label"
  printf '  Run exactly:\n    %s\n' "$cmd"
  printf '  Already-done check: %s\n' "$already_done"
  printf '  Success check: %s\n\n' "$success_check"
}

# generate_runbook <os>
# Emit the full AI runbook for the resolved plan (STATE_ENABLED_STEPS / PKG_SKIP).
# Preamble is verbatim from spec §4.1 with <os> and <PF> substituted.
# Steps appear in STEP_IDS order; prereq steps are excluded.
generate_runbook() {
  local os="$1" id

  # Preamble — verbatim from spec §4.1.
  printf 'You are setting up this machine. Some steps may ALREADY be complete — this machine may be\n'
  printf 'partially set up. Before running each step, check whether it is already done; if so,\n'
  printf 'verify and move on. Every command below is safe to re-run (idempotent). Execute the plan\n'
  printf 'IN ORDER. After each step verify it succeeded. If a command fails, diagnose and fix it\n'
  printf 'using your full shell access, then continue. Do not improvise beyond making each step'"'"'s\n'
  printf 'end-state match. Do not re-authenticate, change unrelated config, or install anything not\n'
  printf 'listed. The target OS is %s. The repo is already cloned at %s.\n\n' "$os" "$PF"

  # One block per enabled step not in the prereq core, in STEP_IDS order.
  for id in "${STEP_IDS[@]}"; do
    # Skip if not enabled.
    if ! contains_word "$id" "$STATE_ENABLED_STEPS"; then
      continue
    fi
    # Skip prereq-core steps.
    if contains_word "$id" "$PREREQ_STEPS"; then
      continue
    fi
    runbook_step_block "$id" "$os"
  done

  printf 'When all steps succeed (or were already complete), print: SETUP-COMPLETE.\n'
}

# =============================================================================
# §6  TUI primitives (pure bash + ANSI, bash 3.2 safe)
# =============================================================================
# All wizard input/output goes through fd 3 (the controlling terminal). These
# primitives assume a VT100/xterm-ish terminal. open_interaction_channel (§7)
# wires fd 3; tests can point fd 3 at a here-string for tui_read_key.

# Extra display attributes (set when colors are available).
DIM=""
REV=""
CYAN=""
if [ -t 1 ] && [ -n "${ncolors:-}" ] && [ "$ncolors" -ge 8 ]; then
  DIM="$(tput dim 2>/dev/null || true)"
  REV="$(tput rev 2>/dev/null || true)"
  CYAN="$(tput setaf 6 2>/dev/null || true)"
fi

# Saved stty state for restore.
TUI_STTY_SAVED=""
# Whether the alternate screen is currently active (for trap-safe teardown).
TUI_ACTIVE=0
# Caret glyphs (downgraded to ASCII when the terminal/locale is poor).
TUI_CARET_EXPANDED="▾"
TUI_CARET_COLLAPSED="▸"

# Return 0 only if an interactive wizard is possible: TTY present (fd 3 or
# stdin), TERM not dumb, and at least 8 colors.
tui_supported() {
  case "${TERM:-}" in
    ""|dumb) return 1 ;;
  esac
  if [ -z "${ncolors:-}" ] || [ "$ncolors" -lt 8 ]; then
    return 1
  fi
  return 0
}

# Downgrade carets to ASCII when the terminal looks limited.
tui_pick_carets() {
  case "${TERM:-}" in
    *256color*|xterm*|screen*|tmux*|rxvt*|alacritty*|kitty*) ;;
    *) TUI_CARET_EXPANDED="-"; TUI_CARET_COLLAPSED="+" ;;
  esac
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) ;;
    *) TUI_CARET_EXPANDED="-"; TUI_CARET_COLLAPSED="+" ;;
  esac
}

# Enter alternate screen, hide cursor, put terminal in raw-ish mode.
tui_enter() {
  tui_pick_carets
  TUI_STTY_SAVED=$(stty -g <&3 2>/dev/null || true)
  stty -echo -icanon min 1 time 0 <&3 2>/dev/null || true
  printf '\033[?1049h\033[?25l' >&3
  TUI_ACTIVE=1
}

# Restore terminal: show cursor, leave alt screen, restore stty. Idempotent.
tui_leave() {
  if [ "$TUI_ACTIVE" -ne 1 ]; then
    return 0
  fi
  printf '\033[?25h\033[?1049l' >&3 2>/dev/null || true
  if [ -n "$TUI_STTY_SAVED" ]; then
    stty "$TUI_STTY_SAVED" <&3 2>/dev/null || true
  fi
  TUI_ACTIVE=0
}

# Read terminal size into LINES/COLS with sane fallbacks (re-read per render).
tui_size() {
  LINES=$(tput lines 2>/dev/null || echo 24)
  COLS=$(tput cols 2>/dev/null || echo 80)
  LINES=${LINES:-24}
  COLS=${COLS:-80}
}

tui_clear() {
  printf '\033[2J\033[H' >&3
}

# Move cursor to row $1, col $2 (1-based).
tui_move() {
  printf '\033[%s;%sH' "$1" "$2" >&3
}

tui_color() {
  printf '%s' "$1" >&3
}

tui_reset() {
  printf '%s' "$NORMAL" >&3
}

# Read one normalized key token from fd 3. Echoes one of:
#   UP DOWN LEFT RIGHT SPACE ENTER QUIT TOGGLE_ALL HELP CHAR:<x>
tui_read_key() {
  local c rest
  IFS= read -rsn1 c <&3 2>/dev/null || { echo ENTER; return 0; }
  case "$c" in
    "$(printf '\033')")
      # Possible escape sequence (arrow). Follow-up read for the "[A" tail.
      # NOTE: bash 3.2 rejects fractional -t timeouts, so use an integer 1s
      # cap. Arrow bursts arrive together and return instantly; a lone ESC on a
      # real TTY waits up to 1s then maps to QUIT.
      IFS= read -rsn2 -t 1 rest <&3 2>/dev/null || rest=""
      case "$rest" in
        "[A") echo UP ;;
        "[B") echo DOWN ;;
        "[C") echo RIGHT ;;
        "[D") echo LEFT ;;
        *)    echo QUIT ;;
      esac
      ;;
    " ")  echo SPACE ;;
    "")   echo ENTER ;;
    k|K)  echo UP ;;
    j|J)  echo DOWN ;;
    h|H)  echo LEFT ;;
    l|L)  echo RIGHT ;;
    q|Q)  echo QUIT ;;
    a|A)  echo TOGGLE_ALL ;;
    "?")  echo HELP ;;
    *)    printf 'CHAR:%s\n' "$c" ;;
  esac
}

# --- Generic menu render -----------------------------------------------------
# Parallel indexed arrays (bash 3.2 safe). Populated by the wizard screens.
MENU_LABEL=()
MENU_STATE=()    # on | off | forced-on | partial | group | child
MENU_INDENT=()   # 0 group/step, 1 expanded child
MENU_EXPANDED=() # yes | no | - (groups only)
MENU_TOP=0       # scroll-window top index

# Glyph for a row state.
tui_state_glyph() {
  case "$1" in
    on)        echo "[x]" ;;
    off)       echo "[ ]" ;;
    partial)   echo "[~]" ;;
    forced-on) echo "[*]" ;;
    *)         echo "   " ;;
  esac
}

# Render the menu. $1=selected index, $2=title, $3=footer.
# Uses the MENU_* arrays and MENU_TOP. Full repaint of the content region.
tui_render_menu() {
  local sel="$1" title="$2" footer="$3"
  tui_size
  tui_clear

  local header_rows=2 footer_rows=2
  local window=$(( LINES - header_rows - footer_rows ))
  [ "$window" -lt 1 ] && window=1

  local count=${#MENU_LABEL[@]}
  # Adjust scroll window so sel is visible.
  if [ "$sel" -lt "$MENU_TOP" ]; then
    MENU_TOP="$sel"
  fi
  if [ "$sel" -ge $(( MENU_TOP + window )) ]; then
    MENU_TOP=$(( sel - window + 1 ))
  fi
  [ "$MENU_TOP" -lt 0 ] && MENU_TOP=0

  # Header.
  tui_move 1 1
  printf '%s%s%s' "$BOLD" "$title" "$NORMAL" >&3
  tui_move 2 1
  printf '%s%s%s' "$DIM" "(↑↓ move · space toggle · → expand · ← collapse · enter next · a all · q quit)" "$NORMAL" >&3

  # Rows.
  local i row=$(( header_rows + 1 ))
  i="$MENU_TOP"
  while [ "$i" -lt "$count" ] && [ "$i" -lt $(( MENU_TOP + window )) ]; do
    tui_move "$row" 1
    local glyph caret indent="" gutter="  "
    glyph=$(tui_state_glyph "${MENU_STATE[$i]}")
    if [ "${MENU_INDENT[$i]}" = "1" ]; then
      indent="    "
    fi
    caret=" "
    case "${MENU_EXPANDED[$i]}" in
      yes) caret="$TUI_CARET_EXPANDED" ;;
      no)  caret="$TUI_CARET_COLLAPSED" ;;
    esac
    if [ "$i" -eq "$sel" ]; then
      gutter="> "
      printf '%s%s%s%s %s %s%s' "$REV" "$gutter" "$indent" "$caret" "$glyph" "${MENU_LABEL[$i]}" "$NORMAL" >&3
    else
      printf '%s%s%s %s %s' "$gutter" "$indent" "$caret" "$glyph" "${MENU_LABEL[$i]}" >&3
    fi
    row=$(( row + 1 ))
    i=$(( i + 1 ))
  done

  # Footer.
  tui_move "$LINES" 1
  printf '%s%s%s' "$CYAN" "$footer" "$NORMAL" >&3
}

# =============================================================================
# §7  Interaction channel + wizard screens
# =============================================================================

# True once fd 3 is wired to a usable terminal.
TTY_OPEN=0

# Resolve the interaction channel and set MODE (wizard|silent).
# Resolution order (spec §3):
#   1. --silent / QUICK_INSTALL_SILENT  -> silent, never open a TTY.
#   2. else open fd 3 = /dev/tty.
#   3. if /dev/tty opened AND tui_supported -> wizard.
#   4. else -> silent.
open_interaction_channel() {
  MODE="silent"
  TTY_OPEN=0

  if [ -n "$OPT_SILENT" ] || [ -n "$ENV_SILENT" ]; then
    MODE="silent"
    return 0
  fi

  if exec 3<>/dev/tty 2>/dev/null; then
    TTY_OPEN=1
    if tui_supported; then
      MODE="wizard"
    else
      MODE="silent"
    fi
  else
    MODE="silent"
  fi
}

# Decide the run mode based on OPT_SILENT and TTY_OPEN.
# Sets MODE=silent|interactive and returns 0, or prints guidance to stderr
# and returns 2 when no TTY is available and --silent was not requested.
select_mode() {
  if [ -n "$OPT_SILENT" ]; then MODE=silent; return 0; fi
  if [ "${TTY_OPEN:-0}" -eq 1 ]; then MODE=interactive; return 0; fi
  printf "${RED}No terminal available for interactive setup.${NORMAL}\n" >&2
  printf "Re-run with --silent[=claude|codex] for an unattended install (needs an authed CLI).\n" >&2
  return 2
}

# True if fd 3 is a usable terminal for interactive reads.
tty_available() {
  [ "$TTY_OPEN" -eq 1 ]
}

# Read a line from fd 3 (interactive terminal) into the named variable.
# Returns nonzero if no terminal is available.
tty_read() {
  local __var="$1" __line
  if ! tty_available; then
    return 1
  fi
  if IFS= read -r __line <&3; then
    eval "$__var=\$__line"
    return 0
  fi
  return 1
}

# Recompute forced-on (dependency-locked) steps for the current enabled set.
# Echoes a space-delimited list of step ids that are pulled in as deps.
wizard_forced_steps() {
  local saved_enabled="$STATE_ENABLED_STEPS" saved_skipped="$STATE_SKIPPED_STEPS"
  local before="$STATE_ENABLED_STEPS" step_id forced=""
  # Run closure on a copy (suppress its printf output).
  ensure_step_dependencies_selected >/dev/null 2>&1
  for step_id in $STATE_ENABLED_STEPS; do
    if ! contains_word "$step_id" "$before"; then
      if [ -n "$forced" ]; then
        forced="$forced $step_id"
      else
        forced="$step_id"
      fi
    fi
  done
  STATE_ENABLED_STEPS="$saved_enabled"
  STATE_SKIPPED_STEPS="$saved_skipped"
  printf '%s\n' "$forced"
}

# --- Screen 1: steps ---------------------------------------------------------
# Selections live in WIZ_STEP_ON (space list of enabled step ids) and
# WIZ_STEP_LOCK (forced-on by flags/env/deps). Returns:
#   0 = Next, 1 = Back (n/a on first screen -> treated as stay), 2 = Quit
WIZ_STEP_ON=""
WIZ_STEP_LOCK=""

# Seed step selections from defaults + env + flags (pre-locked rows).
wizard_seed_steps() {
  local step_id
  WIZ_STEP_ON=""
  WIZ_STEP_LOCK=""
  for step_id in "${STEP_IDS[@]}"; do
    if step_default_enabled "$step_id"; then
      append_unique_word WIZ_STEP_ON "$step_id"
    fi
  done
  # env: NO_FONTS forces fonts off + locked.
  if [ -n "$ENV_NO_FONTS" ]; then
    remove_word WIZ_STEP_ON install_nerd_fonts
    append_unique_word WIZ_STEP_LOCK install_nerd_fonts
  fi
  # flags: --only forces exactly that set; --skip forces those off; --no-fonts.
  if [ -n "$OPT_ONLY" ]; then
    WIZ_STEP_ON=""
    for step_id in $OPT_ONLY; do
      append_unique_word WIZ_STEP_ON "$step_id"
      append_unique_word WIZ_STEP_LOCK "$step_id"
    done
  fi
  if [ -n "$OPT_SKIP" ]; then
    for step_id in $OPT_SKIP; do
      remove_word WIZ_STEP_ON "$step_id"
      append_unique_word WIZ_STEP_LOCK "$step_id"
    done
  fi
  if [ -n "$OPT_NO_FONTS" ]; then
    remove_word WIZ_STEP_ON install_nerd_fonts
    append_unique_word WIZ_STEP_LOCK install_nerd_fonts
  fi
}

wizard_steps_screen() {
  local sel=0 key i step_id forced
  while true; do
    # Compute dependency-forced rows for display (locked-on).
    STATE_ENABLED_STEPS="$WIZ_STEP_ON"
    STATE_SKIPPED_STEPS=""
    forced=$(wizard_forced_steps)

    MENU_LABEL=(); MENU_STATE=(); MENU_INDENT=(); MENU_EXPANDED=()
    i=0
    for step_id in "${STEP_IDS[@]}"; do
      MENU_LABEL[$i]="$(step_label "$step_id")"
      MENU_INDENT[$i]=0
      MENU_EXPANDED[$i]="-"
      if contains_word "$step_id" "$WIZ_STEP_LOCK" || contains_word "$step_id" "$forced"; then
        if contains_word "$step_id" "$WIZ_STEP_ON" || contains_word "$step_id" "$forced"; then
          MENU_STATE[$i]="forced-on"
        else
          MENU_STATE[$i]="off"
        fi
      elif contains_word "$step_id" "$WIZ_STEP_ON"; then
        MENU_STATE[$i]="on"
      else
        MENU_STATE[$i]="off"
      fi
      i=$(( i + 1 ))
    done

    tui_render_menu "$sel" "Select steps  [1/3]" "space toggle · a all/none · enter Next · q quit"
    key=$(tui_read_key)
    case "$key" in
      UP)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( ${#MENU_LABEL[@]} - 1 )) ;;
      DOWN) sel=$(( sel + 1 )); [ "$sel" -ge ${#MENU_LABEL[@]} ] && sel=0 ;;
      SPACE)
        step_id="${STEP_IDS[$sel]}"
        # Cannot toggle locked or dep-forced rows.
        if contains_word "$step_id" "$WIZ_STEP_LOCK" || contains_word "$step_id" "$forced"; then
          :
        elif contains_word "$step_id" "$WIZ_STEP_ON"; then
          remove_word WIZ_STEP_ON "$step_id"
        else
          append_unique_word WIZ_STEP_ON "$step_id"
        fi
        ;;
      TOGGLE_ALL)
        # If every unlocked step is on, turn all off; else turn all on.
        local all_on=1
        for step_id in "${STEP_IDS[@]}"; do
          contains_word "$step_id" "$WIZ_STEP_LOCK" && continue
          contains_word "$step_id" "$WIZ_STEP_ON" || { all_on=0; break; }
        done
        for step_id in "${STEP_IDS[@]}"; do
          contains_word "$step_id" "$WIZ_STEP_LOCK" && continue
          if [ "$all_on" -eq 1 ]; then
            remove_word WIZ_STEP_ON "$step_id"
          else
            append_unique_word WIZ_STEP_ON "$step_id"
          fi
        done
        ;;
      ENTER) return 0 ;;
      QUIT)  return 2 ;;
    esac
  done
}

# --- Screen 2: packages (grouped, expandable) --------------------------------
# WIZ_PKG_SKIP holds canonical ids skipped. WIZ_PKG_EXPANDED holds expanded
# group ids. WIZ_OS is the detected package OS.
WIZ_PKG_SKIP=""
WIZ_PKG_EXPANDED=""
WIZ_OS=""

# Detect the package OS (mirrors install_os_packages dispatch).
wizard_detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo macos
  elif command -v apt-get >/dev/null 2>&1; then
    echo apt
  elif command -v dnf >/dev/null 2>&1 && is_fedora; then
    echo fedora
  elif command -v pacman >/dev/null 2>&1; then
    echo pacman
  else
    echo macos
  fi
}

# Members of a group that exist on the detected OS (canonical ids).
wizard_group_os_members() {
  local group="$1" member out=""
  for member in $(pkg_group_members "$group"); do
    if [ -n "$(pkg_resolve "$WIZ_OS" "$member")" ]; then
      if [ -n "$out" ]; then out="$out $member"; else out="$member"; fi
    fi
  done
  printf '%s\n' "$out"
}

# Group tri-state for display: on | off | partial.
wizard_group_state() {
  local group="$1" member any_on=0 any_off=0
  for member in $(wizard_group_os_members "$group"); do
    if contains_word "$member" "$WIZ_PKG_SKIP"; then
      any_off=1
    else
      any_on=1
    fi
  done
  if [ "$any_on" -eq 1 ] && [ "$any_off" -eq 1 ]; then
    echo partial
  elif [ "$any_on" -eq 1 ]; then
    echo on
  else
    echo off
  fi
}

# Seed package skip from flags (--packages/--skip-packages) for pre-lock.
WIZ_PKG_LOCK=0
wizard_seed_packages() {
  WIZ_PKG_SKIP=""
  WIZ_PKG_EXPANDED=""
  WIZ_PKG_LOCK=0
  WIZ_OS=$(wizard_detect_os)
  if [ -n "$OPT_PACKAGES" ] || [ -n "$OPT_SKIP_PACKAGES" ]; then
    # Flags decided packages; reflect resolved PKG_SKIP and lock the screen.
    WIZ_PKG_SKIP="$PKG_SKIP"
    WIZ_PKG_LOCK=1
  fi
}

# Build the flattened menu rows (groups + expanded children) into MENU_* and a
# parallel WIZ_ROW_KIND/WIZ_ROW_ID for action dispatch.
WIZ_ROW_KIND=()
WIZ_ROW_ID=()
wizard_packages_build_rows() {
  local i=0 group member gstate cstate
  MENU_LABEL=(); MENU_STATE=(); MENU_INDENT=(); MENU_EXPANDED=()
  WIZ_ROW_KIND=(); WIZ_ROW_ID=()
  for group in $(pkg_groups); do
    gstate=$(wizard_group_state "$group")
    MENU_LABEL[$i]="$(pkg_group_label "$group")"
    MENU_STATE[$i]="$gstate"
    MENU_INDENT[$i]=0
    if contains_word "$group" "$WIZ_PKG_EXPANDED"; then
      MENU_EXPANDED[$i]="yes"
    else
      MENU_EXPANDED[$i]="no"
    fi
    WIZ_ROW_KIND[$i]="group"
    WIZ_ROW_ID[$i]="$group"
    i=$(( i + 1 ))
    if contains_word "$group" "$WIZ_PKG_EXPANDED"; then
      for member in $(wizard_group_os_members "$group"); do
        if contains_word "$member" "$WIZ_PKG_SKIP"; then
          cstate="off"
        else
          cstate="on"
        fi
        MENU_LABEL[$i]="$(pkg_resolve "$WIZ_OS" "$member")"
        MENU_STATE[$i]="$cstate"
        MENU_INDENT[$i]=1
        MENU_EXPANDED[$i]="-"
        WIZ_ROW_KIND[$i]="child"
        WIZ_ROW_ID[$i]="$member"
        i=$(( i + 1 ))
      done
    fi
  done
}

# Toggle a whole group on/off (all its OS members).
wizard_toggle_group() {
  local group="$1" member gstate
  gstate=$(wizard_group_state "$group")
  if [ "$gstate" = "off" ]; then
    # turn all on => remove from skip
    for member in $(wizard_group_os_members "$group"); do
      remove_word WIZ_PKG_SKIP "$member"
    done
  else
    # turn all off => add all to skip
    for member in $(wizard_group_os_members "$group"); do
      append_unique_word WIZ_PKG_SKIP "$member"
    done
  fi
}

wizard_packages_screen() {
  local sel=0 key kind id
  while true; do
    wizard_packages_build_rows
    [ "$sel" -ge ${#MENU_LABEL[@]} ] && sel=$(( ${#MENU_LABEL[@]} - 1 ))
    [ "$sel" -lt 0 ] && sel=0
    if [ "$WIZ_PKG_LOCK" -eq 1 ]; then
      tui_render_menu "$sel" "Select packages  [2/3]  (locked by --packages/--skip-packages)" "enter Next · b Back · q quit"
    else
      tui_render_menu "$sel" "Select packages  [2/3]" "space toggle · → expand · ← collapse · enter Next · b Back · q quit"
    fi
    key=$(tui_read_key)
    kind="${WIZ_ROW_KIND[$sel]}"
    id="${WIZ_ROW_ID[$sel]}"
    case "$key" in
      UP)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( ${#MENU_LABEL[@]} - 1 )) ;;
      DOWN) sel=$(( sel + 1 )); [ "$sel" -ge ${#MENU_LABEL[@]} ] && sel=0 ;;
      RIGHT)
        if [ "$kind" = "group" ] && ! contains_word "$id" "$WIZ_PKG_EXPANDED"; then
          append_unique_word WIZ_PKG_EXPANDED "$id"
        fi
        ;;
      LEFT)
        if [ "$kind" = "group" ]; then
          remove_word WIZ_PKG_EXPANDED "$id"
        elif [ "$kind" = "child" ]; then
          : # children collapse via their group
        fi
        ;;
      SPACE)
        if [ "$WIZ_PKG_LOCK" -eq 1 ]; then
          :
        elif [ "$kind" = "group" ]; then
          wizard_toggle_group "$id"
        elif [ "$kind" = "child" ]; then
          if contains_word "$id" "$WIZ_PKG_SKIP"; then
            remove_word WIZ_PKG_SKIP "$id"
          else
            append_unique_word WIZ_PKG_SKIP "$id"
          fi
        fi
        ;;
      ENTER) return 0 ;;
      QUIT)  return 2 ;;
      CHAR:b|CHAR:B) return 1 ;;
    esac
  done
}

# --- Screen 3: confirm -------------------------------------------------------
wizard_confirm_screen() {
  local key group total kept skipped_names member real clone_method font_decision
  while true; do
    tui_size
    tui_clear
    tui_move 1 1
    printf '%sReview & confirm  [3/3]%s' "$BOLD" "$NORMAL" >&3

    local row=3
    tui_move "$row" 1; printf '%sSteps to run:%s' "$BOLD" "$NORMAL" >&3; row=$(( row + 1 ))
    local step_id
    for step_id in "${STEP_IDS[@]}"; do
      if contains_word "$step_id" "$WIZ_STEP_ON"; then
        tui_move "$row" 3; printf '%s %s' "[x]" "$(step_label "$step_id")" >&3; row=$(( row + 1 ))
      fi
    done

    row=$(( row + 1 ))
    tui_move "$row" 1; printf '%sPackages:%s' "$BOLD" "$NORMAL" >&3; row=$(( row + 1 ))
    for group in $(pkg_groups); do
      total=0; kept=0; skipped_names=""
      for member in $(wizard_group_os_members "$group"); do
        total=$(( total + 1 ))
        if contains_word "$member" "$WIZ_PKG_SKIP"; then
          real=$(pkg_resolve "$WIZ_OS" "$member")
          if [ -n "$skipped_names" ]; then skipped_names="$skipped_names $real"; else skipped_names="$real"; fi
        else
          kept=$(( kept + 1 ))
        fi
      done
      [ "$total" -eq 0 ] && continue
      tui_move "$row" 3
      if [ -n "$skipped_names" ]; then
        printf '%s: %s/%s selected (skipping %s)' "$group" "$kept" "$total" "$skipped_names" >&3
      else
        printf '%s: %s/%s selected' "$group" "$kept" "$total" >&3
      fi
      row=$(( row + 1 ))
    done

    # Clone method + fonts.
    if [ -n "$OPT_HTTPS" ] || [ -n "$ENV_USE_HTTPS" ]; then
      clone_method="HTTPS"
    else
      clone_method="SSH (interactive)"
    fi
    if contains_word install_nerd_fonts "$WIZ_STEP_ON"; then
      font_decision="install nerd fonts"
    else
      font_decision="skip nerd fonts"
    fi
    row=$(( row + 1 ))
    tui_move "$row" 1; printf '%sClone:%s %s    %sFonts:%s %s' "$BOLD" "$NORMAL" "$clone_method" "$BOLD" "$NORMAL" "$font_decision" >&3

    tui_move "$LINES" 1
    printf '%senter Execute · b Back · q quit%s' "$CYAN" "$NORMAL" >&3

    key=$(tui_read_key)
    case "$key" in
      ENTER) return 0 ;;
      QUIT)  return 2 ;;
      CHAR:b|CHAR:B|LEFT) return 1 ;;
    esac
  done
}

# Drive the three-screen wizard. On Execute, copies wizard selections into the
# resolve_plan inputs (STATE_ENABLED_STEPS, PKG_SKIP) and sets WIZARD_RAN=1.
# Returns 0 to proceed, nonzero to abort.
run_wizard() {
  local screen=1 rc
  wizard_seed_steps
  wizard_seed_packages

  tui_enter
  while true; do
    case "$screen" in
      1)
        wizard_steps_screen; rc=$?
        case "$rc" in
          0) screen=2 ;;
          2) tui_leave; return 1 ;;
        esac
        ;;
      2)
        # Skip packages screen if install_os_packages is disabled.
        if ! contains_word install_os_packages "$WIZ_STEP_ON"; then
          screen=3
          continue
        fi
        wizard_packages_screen; rc=$?
        case "$rc" in
          0) screen=3 ;;
          1) screen=1 ;;
          2) tui_leave; return 1 ;;
        esac
        ;;
      3)
        if [ -n "$OPT_YES" ]; then
          rc=0
        else
          wizard_confirm_screen; rc=$?
        fi
        case "$rc" in
          0) break ;;
          1) screen=2; contains_word install_os_packages "$WIZ_STEP_ON" || screen=1 ;;
          2) tui_leave; return 1 ;;
        esac
        ;;
    esac
  done
  tui_leave

  # Commit wizard selections as resolve_plan inputs.
  STATE_ENABLED_STEPS="$WIZ_STEP_ON"
  STATE_SKIPPED_STEPS=""
  local step_id
  for step_id in "${STEP_IDS[@]}"; do
    contains_word "$step_id" "$STATE_ENABLED_STEPS" || append_unique_word STATE_SKIPPED_STEPS "$step_id"
  done
  PKG_SKIP="$WIZ_PKG_SKIP"
  WIZARD_RAN=1
  return 0
}

# =============================================================================
# §9  main()
# =============================================================================
main() {
  args_parse "$@"
  capture_env
  handle_immediate_flags          # --help/--version/--list-steps/--list-packages/--print-runbook exit here

  if [ -n "$OPT_EXEC_STEPS" ]; then
    # Internal primitive: deterministic per-step run, no wizard/AI/auth.
    STATE_ENABLED_STEPS="$(printf '%s' "$OPT_EXEC_STEPS" | tr ',' ' ')"
    exec_steps_run "$OPT_EXEC_STEPS"
    exit $?
  fi

  open_interaction_channel        # wires fd 3, sets TTY_OPEN (MODE refined below)
  select_mode || exit 2           # MODE=silent|interactive, or exit 2 with guidance

  cd "$HOME"

  STATE_RUN_STARTED_AT=$(date +%s)
  INSTALLED_NVM_VERSION=""

  # Interactive + a capable TTY: let the wizard customize the plan before it is
  # resolved (resolve_plan honors WIZARD_RAN). Silent mode resolves from
  # defaults+env+flags inside main_ai_flow.
  if [ "$MODE" = interactive ] && tui_supported; then
    if ! run_wizard; then
      printf "${YELLOW}Wizard cancelled. Nothing was installed.${NORMAL}\n"
      exit 130
    fi
  fi

  main_ai_flow
  exit $?
}

# Single trap dispatcher (composes terminal restore + interrupted-run record).
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal EXIT' EXIT

# Sourced-guard: when sourced for tests (QUICK_INSTALL_SOURCED=1), define every
# function but do not auto-run main. Otherwise run normally.
case "${QUICK_INSTALL_SOURCED:-}" in
  1) : ;;
  *) main "$@" ;;
esac
