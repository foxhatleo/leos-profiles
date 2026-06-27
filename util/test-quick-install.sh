#!/bin/bash
# util/test-quick-install.sh
# Test harness for util/quick-install.sh.
# Run: bash util/test-quick-install.sh (from repo root, or any cwd)
# Requires only /bin/bash (3.2+). No external test framework.

set -u

# ---------------------------------------------------------------------------
# Locate the installer relative to this script's directory.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$SCRIPT_DIR/quick-install.sh"

if [ ! -f "$INSTALLER" ]; then
  printf 'FATAL: installer not found at %s\n' "$INSTALLER" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Tiny assertion framework
# ---------------------------------------------------------------------------
_PASS=0
_FAIL=0
_SKIP=0

_pass() {
  _PASS=$(( _PASS + 1 ))
  printf '  PASS  %s\n' "$1"
}

_fail() {
  _FAIL=$(( _FAIL + 1 ))
  printf '  FAIL  %s\n    %s\n' "$1" "$2"
}

_skip() {
  _SKIP=$(( _SKIP + 1 ))
  printf '  SKIP  %s\n    Reason: %s\n' "$1" "$2"
}

# assert_eq <test_name> <got> <expected>
assert_eq() {
  local name="$1" got="$2" expected="$3"
  if [ "$got" = "$expected" ]; then
    _pass "$name"
  else
    _fail "$name" "expected $(printf '%q' "$expected"), got $(printf '%q' "$got")"
  fi
}

# assert_contains <test_name> <haystack> <needle>
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) _pass "$name" ;;
    *) _fail "$name" "output does not contain $(printf '%q' "$needle")" ;;
  esac
}

# assert_word_present <test_name> <word> <list>
assert_word_present() {
  local name="$1" word="$2" list="$3"
  if contains_word "$word" "$list"; then
    _pass "$name"
  else
    _fail "$name" "'$word' not found in '$list'"
  fi
}

# assert_word_absent <test_name> <word> <list>
assert_word_absent() {
  local name="$1" word="$2" list="$3"
  if contains_word "$word" "$list"; then
    _fail "$name" "'$word' unexpectedly present in '$list'"
  else
    _pass "$name"
  fi
}

# ---------------------------------------------------------------------------
# Source the installer with the guard (defines functions, skips main).
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
QUICK_INSTALL_SOURCED=1 source "$INSTALLER" 2>/dev/null

# Reset all OPT_* vars to a clean slate before each args_parse call.
_reset_opts() {
  OPT_SILENT=""
  OPT_SILENT_DRIVER=""
  OPT_PRINT_RUNBOOK=""
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
  OPT_HELP=""
  OPT_VERSION=""
  OPT_LIST_STEPS=""
  OPT_LIST_PACKAGES=""
}

_reset_state() {
  STATE_ENABLED_STEPS=""
  STATE_SKIPPED_STEPS=""
  PKG_SKIP=""
  WIZARD_RAN=0
  ENV_NO_FONTS=""
  ENV_USE_HTTPS=""
  ENV_SILENT=""
}

# Sort a space-delimited word list, one word per line.
_sort_words() {
  printf '%s\n' $1 | sort
}

# ---------------------------------------------------------------------------
# §1  args_parse tests
# ---------------------------------------------------------------------------
printf '\n=== 1. args_parse ===\n'

_reset_opts; args_parse --silent
assert_eq "--silent sets OPT_SILENT" "$OPT_SILENT" "1"

_reset_opts; args_parse --non-interactive
assert_eq "--non-interactive sets OPT_SILENT" "$OPT_SILENT" "1"

_reset_opts; args_parse --fresh
assert_eq "--fresh sets OPT_FRESH" "$OPT_FRESH" "1"

_reset_opts; args_parse --no-fonts
assert_eq "--no-fonts sets OPT_NO_FONTS" "$OPT_NO_FONTS" "1"

_reset_opts; args_parse --https
assert_eq "--https sets OPT_HTTPS" "$OPT_HTTPS" "1"

_reset_opts; args_parse --only=install_os_packages,install_yarn
assert_eq "--only=a,b sets OPT_ONLY (space-separated)" "$OPT_ONLY" "install_os_packages install_yarn"

_reset_opts; args_parse --only install_os_packages,install_yarn
assert_eq "--only a,b (space form) sets OPT_ONLY" "$OPT_ONLY" "install_os_packages install_yarn"

_reset_opts; args_parse --skip=install_nerd_fonts
assert_eq "--skip=x sets OPT_SKIP" "$OPT_SKIP" "install_nerd_fonts"

_reset_opts; args_parse --skip install_nerd_fonts
assert_eq "--skip x (space form) sets OPT_SKIP" "$OPT_SKIP" "install_nerd_fonts"

_reset_opts; args_parse --packages=core-utils,shell
assert_eq "--packages= sets OPT_PACKAGES" "$OPT_PACKAGES" "core-utils shell"

_reset_opts; args_parse --packages core-utils
assert_eq "--packages (space form) sets OPT_PACKAGES" "$OPT_PACKAGES" "core-utils"

_reset_opts; args_parse --state-file=/tmp/mystate
assert_eq "--state-file= sets OPT_STATE_FILE" "$OPT_STATE_FILE" "/tmp/mystate"

_reset_opts; args_parse --state-file /tmp/mystate
assert_eq "--state-file (space form) sets OPT_STATE_FILE" "$OPT_STATE_FILE" "/tmp/mystate"

# --only + --skip mutual exclusion: must exit 2
_rc=0
( _reset_opts; args_parse --only=install_yarn --skip=install_nerd_fonts ) >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -eq 2 ]; then _pass "--only+--skip together exits 2"
else _fail "--only+--skip together exits 2" "expected exit 2, got $_rc"; fi

# --packages + --skip-packages mutual exclusion: must exit 2
_rc=0
( _reset_opts; args_parse --packages=shell --skip-packages=media ) >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -eq 2 ]; then _pass "--packages+--skip-packages together exits 2"
else _fail "--packages+--skip-packages together exits 2" "expected exit 2, got $_rc"; fi

# Unknown flag: must exit 2
_rc=0
( _reset_opts; args_parse --badflag ) >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -eq 2 ]; then _pass "unknown flag exits 2"
else _fail "unknown flag exits 2" "expected exit 2, got $_rc"; fi

# ---------------------------------------------------------------------------
# §2  Immediate flags (subprocess tests)
# ---------------------------------------------------------------------------
printf '\n=== 2. Immediate flags (subprocess) ===\n'

_rc=0; /bin/bash "$INSTALLER" --help    >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -eq 0 ]; then _pass "--help exits 0"; else _fail "--help exits 0" "got $_rc"; fi

_out=$( /bin/bash "$INSTALLER" --help 2>/dev/null )
assert_contains "--help prints usage anchor" "$_out" "quick-install"

_rc=0; /bin/bash "$INSTALLER" --version >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -eq 0 ]; then _pass "--version exits 0"; else _fail "--version exits 0" "got $_rc"; fi

_out=$( /bin/bash "$INSTALLER" --version 2>/dev/null )
assert_contains "--version prints version string" "$_out" "quick-install.sh"

_rc=0; /bin/bash "$INSTALLER" --list-steps >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -eq 0 ]; then _pass "--list-steps exits 0"; else _fail "--list-steps exits 0" "got $_rc"; fi

_out=$( /bin/bash "$INSTALLER" --list-steps 2>/dev/null )
assert_contains "--list-steps prints step id anchor" "$_out" "install_os_packages"

_rc=0; /bin/bash "$INSTALLER" --list-packages >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -eq 0 ]; then _pass "--list-packages exits 0"; else _fail "--list-packages exits 0" "got $_rc"; fi

_out=$( /bin/bash "$INSTALLER" --list-packages 2>/dev/null )
assert_contains "--list-packages prints group anchor" "$_out" "media"

# ---------------------------------------------------------------------------
# §3  resolve_plan precedence matrix
# ---------------------------------------------------------------------------
printf '\n=== 3. resolve_plan precedence ===\n'

# --skip removes a step from enabled
_reset_opts; _reset_state
args_parse --skip=install_yarn
capture_env
resolve_plan 2>/dev/null
assert_word_absent "--skip=install_yarn removes it from enabled" "install_yarn" "$STATE_ENABLED_STEPS"

_reset_opts; _reset_state
args_parse --skip=install_yarn
capture_env
resolve_plan 2>/dev/null
assert_word_present "--skip=install_yarn adds it to skipped" "install_yarn" "$STATE_SKIPPED_STEPS"

# NO_FONTS=1 env disables install_nerd_fonts
_reset_opts; _reset_state
NO_FONTS=1 capture_env
resolve_plan 2>/dev/null
assert_word_absent "NO_FONTS=1 env disables install_nerd_fonts" "install_nerd_fonts" "$STATE_ENABLED_STEPS"

# NO_FONTS=1 overrides wizard enable (WIZARD_RAN=1 with nerd fonts on)
_reset_opts; _reset_state
WIZARD_RAN=1
append_unique_word STATE_ENABLED_STEPS install_nerd_fonts
remove_word STATE_SKIPPED_STEPS install_nerd_fonts
NO_FONTS=1 capture_env
resolve_plan 2>/dev/null
assert_word_absent "NO_FONTS=1 env overrides wizard enable" "install_nerd_fonts" "$STATE_ENABLED_STEPS"

# --no-fonts flag disables install_nerd_fonts
_reset_opts; _reset_state
args_parse --no-fonts
capture_env
resolve_plan 2>/dev/null
assert_word_absent "--no-fonts flag disables install_nerd_fonts" "install_nerd_fonts" "$STATE_ENABLED_STEPS"

# --only=install_os_packages: that step is in enabled
_reset_opts; _reset_state
args_parse --only=install_os_packages
capture_env
resolve_plan 2>/dev/null
assert_word_present "--only=install_os_packages: step is in enabled" "install_os_packages" "$STATE_ENABLED_STEPS"

# --only=install_os_packages: unrelated steps disabled
_reset_opts; _reset_state
args_parse --only=install_os_packages
capture_env
resolve_plan 2>/dev/null
assert_word_absent "--only=install_os_packages: install_yarn disabled" "install_yarn" "$STATE_ENABLED_STEPS"

# --skip flag overrides wizard enable
_reset_opts; _reset_state
WIZARD_RAN=1
append_unique_word STATE_ENABLED_STEPS install_yarn
args_parse --skip=install_yarn
capture_env
resolve_plan 2>/dev/null
assert_word_absent "--skip flag overrides wizard enable" "install_yarn" "$STATE_ENABLED_STEPS"

# ---------------------------------------------------------------------------
# §4  Dependency closure
# ---------------------------------------------------------------------------
printf '\n=== 4. Dependency closure ===\n'

_reset_opts; _reset_state
args_parse --only=install_ai_tools
capture_env
resolve_plan 2>/dev/null
assert_word_present "install_ai_tools pulls in install_min_toolchain" "install_min_toolchain" "$STATE_ENABLED_STEPS"

_reset_opts; _reset_state
args_parse --only=install_ai_tools
capture_env
resolve_plan 2>/dev/null
assert_word_present "install_ai_tools pulls in prepare_and_clone_repo transitively" "prepare_and_clone_repo" "$STATE_ENABLED_STEPS"

_reset_opts; _reset_state
args_parse --only=setup_nvm_default_node
capture_env
resolve_plan 2>/dev/null
assert_word_present "setup_nvm_default_node pulls in install_os_packages" "install_os_packages" "$STATE_ENABLED_STEPS"

# ---------------------------------------------------------------------------
# §5  pkg_resolve per-OS spot checks
# ---------------------------------------------------------------------------
printf '\n=== 5. pkg_resolve spot checks ===\n'

assert_eq "apt node -> nodejs"                       "$(pkg_resolve apt    node)"         "nodejs"
assert_eq "macos node -> node"                       "$(pkg_resolve macos  node)"         "node"
assert_eq "fedora node -> nodejs"                    "$(pkg_resolve fedora node)"         "nodejs"
assert_eq "pacman node -> nodejs npm"                "$(pkg_resolve pacman node)"         "nodejs npm"
assert_eq "fedora imagemagick -> ImageMagick"        "$(pkg_resolve fedora imagemagick)"  "ImageMagick"
assert_eq "apt imagemagick -> imagemagick"           "$(pkg_resolve apt    imagemagick)"  "imagemagick"
assert_eq "macos python -> python"                   "$(pkg_resolve macos  python)"       "python"
assert_eq "pacman python -> python"                  "$(pkg_resolve pacman python)"       "python"
assert_eq "apt python -> python-is-python3"          "$(pkg_resolve apt    python)"       "python-is-python3"
assert_eq "fedora python -> python-is-python3"       "$(pkg_resolve fedora python)"       "python-is-python3"
assert_eq "macos gnu-sed -> gnu-sed (brew-only)"     "$(pkg_resolve macos  gnu-sed)"      "gnu-sed"
assert_eq "apt gnu-sed -> empty (brew-only absent)"  "$(pkg_resolve apt    gnu-sed)"      ""
assert_eq "fedora gnu-sed -> empty"                  "$(pkg_resolve fedora gnu-sed)"      ""
assert_eq "pacman gnu-sed -> empty"                  "$(pkg_resolve pacman gnu-sed)"      ""

# ---------------------------------------------------------------------------
# §6  pkg_filter_for_os: skipping group 'media' drops expected packages
# ---------------------------------------------------------------------------
printf '\n=== 6. pkg_filter_for_os: media group skip ===\n'

# Build PKG_SKIP from all members of the media group.
_set_media_skip() {
  PKG_SKIP=""
  local m
  for m in $(pkg_group_members media); do
    append_unique_word PKG_SKIP "$m"
  done
}

# Helper: assert a real OS package name is absent from the filtered list.
_assert_pkg_absent_after_filter() {
  local test_name="$1" os="$2" pkg="$3"
  _set_media_skip
  local full filtered
  full=$(pkg_list_for_os "$os")
  filtered=$(pkg_filter_for_os "$os" "$full")
  PKG_SKIP=""
  case " $filtered " in
    *" $pkg "*) _fail "$test_name" "'$pkg' still present in $os filtered list" ;;
    *) _pass "$test_name" ;;
  esac
}

# Helper: assert a real OS package name is present in the filtered list.
_assert_pkg_present_after_filter() {
  local test_name="$1" os="$2" pkg="$3"
  _set_media_skip
  local full filtered
  full=$(pkg_list_for_os "$os")
  filtered=$(pkg_filter_for_os "$os" "$full")
  PKG_SKIP=""
  case " $filtered " in
    *" $pkg "*) _pass "$test_name" ;;
    *) _fail "$test_name" "'$pkg' unexpectedly absent from $os filtered list" ;;
  esac
}

_assert_pkg_absent_after_filter  "media skip: ffmpeg absent from macos list"      macos  ffmpeg
_assert_pkg_absent_after_filter  "media skip: imagemagick absent from macos list"  macos  imagemagick
_assert_pkg_absent_after_filter  "media skip: yt-dlp absent from macos list"       macos  yt-dlp
_assert_pkg_absent_after_filter  "media skip: ffmpeg absent from apt list"         apt    ffmpeg
_assert_pkg_absent_after_filter  "media skip: imagemagick absent from apt list"    apt    imagemagick
_assert_pkg_absent_after_filter  "media skip: yt-dlp absent from apt list"         apt    yt-dlp
_assert_pkg_absent_after_filter  "media skip: ffmpeg absent from fedora list"      fedora ffmpeg
_assert_pkg_absent_after_filter  "media skip: ImageMagick absent from fedora list" fedora ImageMagick
_assert_pkg_absent_after_filter  "media skip: yt-dlp absent from fedora list"      fedora yt-dlp
_assert_pkg_absent_after_filter  "media skip: ffmpeg absent from pacman list"      pacman ffmpeg
_assert_pkg_absent_after_filter  "media skip: imagemagick absent from pacman list" pacman imagemagick
_assert_pkg_absent_after_filter  "media skip: yt-dlp absent from pacman list"      pacman yt-dlp
_assert_pkg_present_after_filter "media skip: bash intact in apt list"             apt    bash
_assert_pkg_present_after_filter "media skip: bash intact in macos list"           macos  bash
_assert_pkg_present_after_filter "media skip: nodejs intact in apt list"           apt    nodejs

# ---------------------------------------------------------------------------
# §7  Registry/literal parity (drift guard)
# ---------------------------------------------------------------------------
# For each OS, the set resolved by pkg_list_for_os must equal the literal
# package list in the install_packages_<os> function.
# We parse the literal lists from the installer source.
# ---------------------------------------------------------------------------
printf '\n=== 7. Registry/literal parity (drift guard) ===\n'

# Extract the literal brew install list from install_packages_macos.
_literal_macos() {
  awk '/^  brew install /,/[^\\]$/' "$INSTALLER" \
    | sed 's/.*brew install//' \
    | tr -d '\\' \
    | tr '\n' ' ' \
    | tr -s ' ' \
    | sed 's/^ //;s/ $//'
}

# Extract the literal apt install list from install_packages_apt.
_literal_apt() {
  awk '/^  sudo apt -y install /,/[^\\]$/' "$INSTALLER" \
    | sed 's/.*sudo apt -y install//' \
    | tr -d '\\' \
    | tr '\n' ' ' \
    | tr -s ' ' \
    | sed 's/^ //;s/ $//'
}

# Extract the literal dnf install list from install_packages_fedora.
# ffmpeg is handled via swap but is a real installed package; add it.
_literal_fedora() {
  local base
  base=$(awk '/^  sudo dnf -y install bash /,/[^\\]$/' "$INSTALLER" \
    | sed 's/.*sudo dnf -y install//' \
    | tr -d '\\' \
    | tr '\n' ' ' \
    | tr -s ' ' \
    | sed 's/^ //;s/ $//')
  printf '%s ffmpeg\n' "$base"
}

# Extract the literal pacman install list from install_packages_pacman.
_literal_pacman() {
  awk '/^  sudo pacman -S --noconfirm /,/[^\\]$/' "$INSTALLER" \
    | sed 's/.*sudo pacman -S --noconfirm//' \
    | tr -d '\\' \
    | tr '\n' ' ' \
    | tr -s ' ' \
    | sed 's/^ //;s/ $//'
}

_parity_check() {
  local test_name="$1" os="$2" literal="$3"
  PKG_SKIP=""
  local registry_list
  registry_list=$(pkg_list_for_os "$os")
  local rs ls
  rs=$(_sort_words "$registry_list")
  ls=$(_sort_words "$literal")
  if [ "$rs" = "$ls" ]; then
    _pass "$test_name"
  else
    # Show what differs (comm needs sorted input, available on bash 3.2 macOS)
    local only_reg only_lit
    only_reg=$(comm -23 <(printf '%s\n' $registry_list | sort) <(printf '%s\n' $literal | sort) 2>/dev/null || echo "?")
    only_lit=$(comm -13  <(printf '%s\n' $registry_list | sort) <(printf '%s\n' $literal | sort) 2>/dev/null || echo "?")
    _fail "$test_name" "drift detected. Only in registry: [${only_reg}]  Only in literal: [${only_lit}]"
  fi
}

_parity_check "parity: macos registry == literal brew install list"   macos  "$(_literal_macos)"
_parity_check "parity: apt registry == literal apt install list"       apt    "$(_literal_apt)"
_parity_check "parity: fedora registry == literal dnf install list"    fedora "$(_literal_fedora)"
_parity_check "parity: pacman registry == literal pacman install list" pacman "$(_literal_pacman)"

# ---------------------------------------------------------------------------
# §8  tui_read_key decode (fd 3 here-string)
# ---------------------------------------------------------------------------
printf '\n=== 8. tui_read_key decode ===\n'

# ESC [ A -> UP
_result=$(tui_read_key 3<<< "$(printf '\033[A')")
assert_eq "ESC[A -> UP"       "$_result" "UP"

# ESC [ B -> DOWN
_result=$(tui_read_key 3<<< "$(printf '\033[B')")
assert_eq "ESC[B -> DOWN"     "$_result" "DOWN"

# space -> SPACE
_result=$(tui_read_key 3<<< " ")
assert_eq "space -> SPACE"    "$_result" "SPACE"

# newline (EOF on read -rsn1) -> ENTER
# Feeding an empty string: read returns "" which maps to ENTER
_result=$(printf '' | tui_read_key 3<&0)
assert_eq "EOF read -> ENTER" "$_result" "ENTER"

# q -> QUIT
_result=$(tui_read_key 3<<< "q")
assert_eq "q -> QUIT"         "$_result" "QUIT"

# k -> UP (vim binding)
_result=$(tui_read_key 3<<< "k")
assert_eq "k -> UP (vim)"     "$_result" "UP"

# j -> DOWN (vim binding)
_result=$(tui_read_key 3<<< "j")
assert_eq "j -> DOWN (vim)"   "$_result" "DOWN"

# ---------------------------------------------------------------------------
# §9  Terminal-restoration (PTY-driven; skip if neither script nor expect)
# ---------------------------------------------------------------------------
printf '\n=== 9. Terminal-restoration (PTY) ===\n'

_TNAME="alt-screen leave and cursor-show emitted on quit"
_have_expect=0; _have_script=0
command -v expect >/dev/null 2>&1 && _have_expect=1
command -v script >/dev/null 2>&1 && _have_script=1

if [ "$_have_expect" -eq 1 ]; then
  _tmpfile=$(mktemp "${TMPDIR:-/tmp}/tui_test_XXXXXX")
  INSTALLER="$INSTALLER" expect -f /dev/stdin >"$_tmpfile" 2>&1 <<'EXPECT_EOF'
set timeout 10
set inst $env(INSTALLER)
spawn /bin/bash -c "QUICK_INSTALL_SOURCED=1 source \"$inst\"; open_interaction_channel; run_wizard"
expect -re "." {}
send "q"
expect eof
EXPECT_EOF
  _out=$(cat "$_tmpfile"); rm -f "$_tmpfile"
  _ok=0
  case "$_out" in *$'\033[?1049l'*) _ok=$(( _ok + 1 )) ;; esac
  case "$_out" in *$'\033[?25h'*)   _ok=$(( _ok + 1 )) ;; esac
  if [ "$_ok" -eq 2 ]; then _pass "$_TNAME"
  else _fail "$_TNAME" "missing \\e[?1049l and/or \\e[?25h in output"; fi
elif [ "$_have_script" -eq 1 ]; then
  _tmpfile=$(mktemp "${TMPDIR:-/tmp}/tui_test_XXXXXX")
  # BSD script (macOS): script -q outputfile command  (stdin piped in).
  # Drive the wizard directly (NOT --silent, which is now an unattended AI run that
  # would clone/install before failing) so this only exercises terminal restoration.
  printf 'q' | script -q "$_tmpfile" /bin/bash -c "QUICK_INSTALL_SOURCED=1 source \"$INSTALLER\"; open_interaction_channel; run_wizard" >/dev/null 2>&1 || true
  _out=$(cat "$_tmpfile" 2>/dev/null || true); rm -f "$_tmpfile"
  _ok=0
  case "$_out" in *$'\033[?1049l'*) _ok=$(( _ok + 1 )) ;; esac
  case "$_out" in *$'\033[?25h'*)   _ok=$(( _ok + 1 )) ;; esac
  if [ "$_ok" -eq 2 ]; then _pass "$_TNAME"
  else _fail "$_TNAME" "missing \\e[?1049l and/or \\e[?25h in output (script-driven)"; fi
else
  _skip "$_TNAME" "neither 'expect' nor 'script' available on this system"
fi

# ---------------------------------------------------------------------------
# §10  Word-list helper regression tests
# ---------------------------------------------------------------------------
printf '\n=== 10. Word-list helpers ===\n'

if contains_word "foo" "alpha foo beta"; then _pass "contains_word finds existing word"
else _fail "contains_word finds existing word" "'foo' not found in 'alpha foo beta'"; fi

_rc=0; contains_word "missing" "alpha foo beta" || _rc=$?
if [ "$_rc" -ne 0 ]; then _pass "contains_word returns false for absent word"
else _fail "contains_word returns false for absent word" "'missing' incorrectly matched"; fi

_rc=0; contains_word "fo" "alpha foo beta" || _rc=$?
if [ "$_rc" -ne 0 ]; then _pass "contains_word does not match partial substring"
else _fail "contains_word does not match partial substring" "'fo' incorrectly matched 'foo'"; fi

_LIST="alpha beta"
append_unique_word _LIST "gamma"
assert_eq "append_unique_word adds new word"              "$_LIST" "alpha beta gamma"

_LIST="alpha beta"
append_unique_word _LIST "beta"
assert_eq "append_unique_word does not duplicate"         "$_LIST" "alpha beta"

_LIST="alpha beta gamma"
remove_word _LIST "beta"
assert_eq "remove_word removes target word"               "$_LIST" "alpha gamma"

_LIST="alpha beta"
remove_word _LIST "missing"
assert_eq "remove_word is no-op when word absent"         "$_LIST" "alpha beta"

# ---------------------------------------------------------------------------
# Task 1: --exec-steps
# ---------------------------------------------------------------------------
printf '\n=== Task 1: --exec-steps ===\n'

_reset_opts; args_parse --exec-steps=install_bun,install_yarn
assert_eq "exec-steps parses list" "$OPT_EXEC_STEPS" "install_bun,install_yarn"

# ---------------------------------------------------------------------------
# GENUINE C1+C3 coverage: keep run_step REAL so the IFS-leak and set -e bugs
# are actually exercised. The false-passing predecessors stubbed run_step AND
# ran exec_steps_run inside $(...) (which suppresses errexit-abort); both hid
# the bugs. Here run_step is real, only the step BODIES are stubbed, state
# writes are redirected to a temp file, and exec_steps_run runs as a bare
# statement inside a subshell that has set -e ON.
# ---------------------------------------------------------------------------

# C1: multi-id under real run_step. STATE_ENABLED_STEPS is a SPACE-delimited
# list; if IFS=, leaks into run_step->contains_word it collapses to one token
# and every step is judged disabled and skipped -> bodies never run. We assert
# BOTH bodies ran. (Buggy code: bodies skipped -> NO_BUN/NO_YARN -> FAIL.)
_exec_state="$(mktemp "${TMPDIR:-/tmp}/qi_exec_state.XXXXXX")"
_exec_sig="$(mktemp "${TMPDIR:-/tmp}/qi_exec_sig.XXXXXX")"
(
  set -e
  QUICK_INSTALL_STATE_FILE="$_exec_state"
  STATE_ENABLED_STEPS="install_bun install_yarn"
  STATE_COMPLETED_STEPS=""
  STATE_SKIPPED_STEPS=""
  PKG_SKIP=""
  _ran=""
  install_bun()  { _ran="$_ran bun"; }
  install_yarn() { _ran="$_ran yarn"; }
  # Bare statement (NOT inside $(...)) so set -e really applies.
  exec_steps_run "install_bun,install_yarn"
  printf '%s' "$_ran" > "$_exec_sig"
) >/dev/null 2>&1 || true   # don't let a buggy-code abort kill the suite
_exec_ran="$(cat "$_exec_sig" 2>/dev/null || true)"
if [ "$_exec_ran" = " bun yarn" ]; then
  _pass "exec_steps_run runs every step body (real run_step, no IFS leak)"
else
  _fail "exec_steps_run runs every step body (real run_step, no IFS leak)" \
    "expected ' bun yarn', got '$_exec_ran'"
fi
rm -f "$_exec_state" "$_exec_sig"

# C3: first-non-zero under failure, with real run_step + a failing body for the
# first id. Under set -e the buggy `run_step "$id"; _r=$?` aborts exec_steps_run
# mid-loop, so the second body never runs. We assert BOTH bodies were attempted,
# the return is the FIRST non-zero (run_step yields 1 for a failed step on a
# non-tty run), AND exec_steps_run did NOT abort the caller (DONE must print).
# run_step's own diagnostics go to a scratch file so only our sentinel is read.
_exec_state="$(mktemp "${TMPDIR:-/tmp}/qi_exec_state.XXXXXX")"
_exec_sig="$(mktemp "${TMPDIR:-/tmp}/qi_exec_sig.XXXXXX")"
(
  set -e
  QUICK_INSTALL_STATE_FILE="$_exec_state"
  STATE_ENABLED_STEPS="install_bun install_yarn"
  STATE_COMPLETED_STEPS=""
  STATE_SKIPPED_STEPS=""
  PKG_SKIP=""
  tty_available() { return 1; }   # force non-interactive fail-and-return path
  _ran=""
  install_bun()  { _ran="$_ran bun";  return 7; }   # first id fails
  install_yarn() { _ran="$_ran yarn"; return 0; }   # second id succeeds
  _rc=0
  exec_steps_run "install_bun,install_yarn" >/dev/null 2>&1 || _rc=$?
  # If exec_steps_run aborted the caller under set -e, DONE never prints.
  printf 'ran=%s rc=%d DONE' "$_ran" "$_rc" > "$_exec_sig"
) >/dev/null 2>&1 || true   # don't let a buggy-code abort kill the suite
_exec_res="$(cat "$_exec_sig" 2>/dev/null || true)"
rm -f "$_exec_state" "$_exec_sig"
assert_eq "exec_steps_run: attempts all, returns first failure, no set -e abort" \
  "$_exec_res" "ran= bun yarn rc=1 DONE"

# ---------------------------------------------------------------------------
# Task 2: --silent=driver + --print-runbook
# ---------------------------------------------------------------------------
printf '\n=== Task 2: --silent driver + --print-runbook ===\n'

_reset_opts; args_parse --silent
assert_eq "bare --silent sets flag"   "$OPT_SILENT" "1"
assert_eq "bare --silent no driver"   "$OPT_SILENT_DRIVER" ""
_reset_opts; args_parse --silent=codex
assert_eq "--silent=codex flag"       "$OPT_SILENT" "1"
assert_eq "--silent=codex driver"     "$OPT_SILENT_DRIVER" "codex"
_rc=0
( _reset_opts; args_parse --silent=bogus ) >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -eq 2 ]; then _pass "--silent=bogus rejected"
else _fail "--silent=bogus rejected" "expected exit 2, got $_rc"; fi
_reset_opts; args_parse --print-runbook
assert_eq "--print-runbook flag"      "$OPT_PRINT_RUNBOOK" "1"

# ---------------------------------------------------------------------------
# Task 3: cli_is_installed / cli_is_authenticated
# ---------------------------------------------------------------------------
printf '\n=== Task 3: cli_is_installed / cli_is_authenticated ===\n'

# assert_exit <name> <expected_rc> <cmd-string>
# Runs cmd-string in a subshell and compares its exit code to expected_rc.
assert_exit() {
  local name="$1" expected_rc="$2" cmd="$3" actual_rc
  actual_rc=0
  ( eval "$cmd" ) >/dev/null 2>&1 || actual_rc=$?
  if [ "$actual_rc" -eq "$expected_rc" ]; then
    _pass "$name"
  else
    _fail "$name" "expected exit $expected_rc, got $actual_rc"
  fi
}

_stubdir="$(mktemp -d)"; _oldpath="$PATH"
# stub: claude authed (auth status exit 0), codex present but unauthed (login status exit 1)
printf '#!/bin/sh\ncase "$1 $2" in "auth status") exit 0;; esac\nexit 0\n' > "$_stubdir/claude"
printf '#!/bin/sh\ncase "$1 $2" in "login status") exit 1;; esac\nexit 0\n' > "$_stubdir/codex"
chmod +x "$_stubdir/claude" "$_stubdir/codex"; PATH="$_stubdir:$PATH"
assert_exit "claude installed"      0 'cli_is_installed claude'
assert_exit "claude authed"         0 'cli_is_authenticated claude'
assert_exit "codex installed"       0 'cli_is_installed codex'
assert_exit "codex unauthed -> 1"   1 'cli_is_authenticated codex'
# Unknown CLI name must be rejected (non-zero) by both probes — the case
# statements fall through to `*) return 1`, never shelling out to a bogus name.
assert_exit "cli_is_installed unknown -> 1"     1 'cli_is_installed bogus'
assert_exit "cli_is_authenticated unknown -> 1" 1 'cli_is_authenticated bogus'
PATH="$_oldpath"; rm -rf "$_stubdir"

# ---------------------------------------------------------------------------
# Task 4: install_min_toolchain skip-aware
# ---------------------------------------------------------------------------
printf '\n=== Task 4: install_min_toolchain skip-aware ===\n'

assert_eq "min_toolchain in STEP_IDS" \
  "$(printf '%s\n' "${STEP_IDS[@]}" | grep -c '^install_min_toolchain$')" "1"
assert_eq "min_toolchain label" \
  "$(step_label install_min_toolchain)" "Install minimal toolchain (brew, node, npm)"
assert_eq "ai_tools depends on min_toolchain" \
  "$(step_dependencies install_ai_tools)" "install_min_toolchain"
# skip logic: with node+npm present, needs_* return 1 (false)
_stubdir="$(mktemp -d)"; _oldpath="$PATH"
printf '#!/bin/sh\nexit 0\n' > "$_stubdir/node"; printf '#!/bin/sh\nexit 0\n' > "$_stubdir/npm"
chmod +x "$_stubdir/node" "$_stubdir/npm"; PATH="$_stubdir:$PATH"
assert_exit "node present -> no need" 1 'min_toolchain_needs_node'
assert_exit "npm present -> no need"  1 'min_toolchain_needs_npm'
PATH="$_oldpath"; rm -rf "$_stubdir"

# ---------------------------------------------------------------------------
# Task 5: select_mode
# ---------------------------------------------------------------------------
printf '\n=== Task 5: select_mode ===\n'

OPT_SILENT=1; TTY_OPEN=0; MODE=""; select_mode; assert_eq "silent flag -> silent" "$MODE" "silent"
OPT_SILENT="";  TTY_OPEN=1; MODE=""; select_mode; assert_eq "tty -> interactive"  "$MODE" "interactive"
OPT_SILENT="";  TTY_OPEN=0; MODE=""
_rc=0; ( select_mode ) >/dev/null 2>&1 || _rc=$?
assert_eq "no tty no silent -> exit 2" "$_rc" "2"

# ---------------------------------------------------------------------------
# Task 6: resolve_silent_driver
# ---------------------------------------------------------------------------
printf '\n=== Task 6: resolve_silent_driver ===\n'

# Each case is run in a subshell with locally-defined stubs so the overrides
# do not persist into subsequent tests (bash 3.2 safe: no function-scoped
# overrides; subshell isolation is the only reliable containment).

# bare silent: both installed, only codex authed -> picks codex
_t6_out=$(
  cli_is_installed() { return 0; }
  cli_is_authenticated() { [ "$1" = codex ]; }
  OPT_SILENT_DRIVER=""; DRIVER=""
  resolve_silent_driver
  printf '%s' "$DRIVER"
)
assert_eq "bare silent picks authed codex" "$_t6_out" "codex"

# explicit claude driver, unauthed -> fail (rc 1)
_rc=0
( cli_is_installed() { return 0; }
  cli_is_authenticated() { [ "$1" = codex ]; }
  OPT_SILENT_DRIVER="claude"; DRIVER=""
  resolve_silent_driver ) >/dev/null 2>&1 || _rc=$?
assert_eq "explicit claude unauthed -> fail" "$_rc" "1"

# explicit codex driver, authed -> ok, DRIVER set
_t6_out=$(
  cli_is_installed() { return 0; }
  cli_is_authenticated() { [ "$1" = codex ]; }
  OPT_SILENT_DRIVER="codex"; DRIVER=""
  resolve_silent_driver
  printf '%s' "$DRIVER"
)
assert_eq "explicit codex authed -> ok" "$_t6_out" "codex"

# ---------------------------------------------------------------------------
# Task 7: run_auth_flow
# ---------------------------------------------------------------------------
printf '\n=== Task 7: run_auth_flow ===\n'

# Case 1: both already authenticated -> ask which drives; stub driver pick.
# Run in subshell to contain stub overrides; suppress run_auth_flow stdout so
# only the final printf (the DRIVER value) reaches the command-substitution.
_t7_both_authed=$(
  AUTH_LOGIN_CMD() { return 0; }
  prompt_yes_no()  { return 0; }
  cli_is_authenticated() { return 0; }
  _pick_driver() { echo claude; }
  DRIVER=""
  run_auth_flow >/dev/null 2>/dev/null
  printf '%s' "$DRIVER"
)
assert_eq "both authed -> driver from pick" "$_t7_both_authed" "claude"

# Case 2: neither authed and user declines -> return 10.
# Run in subshell; capture exit code without aborting the suite.
_t7_rc=0
(
  AUTH_LOGIN_CMD() { return 0; }
  prompt_yes_no()  { return 1; }    # user declines both
  cli_is_authenticated() { return 1; }
  _pick_driver() { echo claude; }
  DRIVER=""
  run_auth_flow
) >/dev/null 2>&1 || _t7_rc=$?
assert_eq "neither authed -> rc 10" "$_t7_rc" "10"

# Case 3: login-SUCCESS branch. Neither pre-authed; user says yes; AUTH_LOGIN_CMD
# succeeds for claude (returns 0) -> AUTHED_CLAUDE set -> DRIVER=claude, rc 0.
# codex login fails so only claude is authed (exercises the single-driver path
# off a successful interactive login, not a pre-existing auth). Subshell-contained.
_t7_login="$(
  cli_is_authenticated() { return 1; }            # nothing pre-authenticated
  prompt_yes_no()  { return 0; }                  # user agrees to authenticate
  AUTH_LOGIN_CMD() { [ "$1" = claude ] && return 0; return 1; }  # claude login ok
  _pick_driver() { echo SHOULD_NOT_RUN; }
  DRIVER=""; _rc=0
  run_auth_flow >/dev/null 2>/dev/null || _rc=$?
  printf 'driver=%s rc=%d' "$DRIVER" "$_rc"
)"
assert_eq "login success -> authed, driver set" "$_t7_login" "driver=claude rc=0"

# ---------------------------------------------------------------------------
# Task 8: generate_runbook
# ---------------------------------------------------------------------------
printf '\n=== Task 8: generate_runbook ===\n'

STATE_ENABLED_STEPS="install_os_packages install_bun setup_fish"
PKG_SKIP=""
RB="$(generate_runbook macos)"
assert_contains "runbook has preamble" "$RB" "Some steps may ALREADY be complete"
assert_contains "runbook inlines bun"  "$RB" "STEP install_bun"
assert_contains "runbook delegates fish" "$RB" "--exec-steps=setup_fish"
assert_contains "runbook ends sentinel" "$RB" "SETUP-COMPLETE"
assert_eq "prereqs excluded" \
  "$(printf '%s' "$RB" | grep -c 'STEP install_min_toolchain')" "0"

# Reset state after task 8 tests
_reset_state

# ---------------------------------------------------------------------------
# Task 9: runbook/step parity drift guard
# ---------------------------------------------------------------------------
printf '\n=== Task 9: runbook/step parity drift guard ===\n'

# §9a  Every enabled non-prereq step appears exactly once in the runbook.
# Prereq steps (prepare_and_clone_repo, install_min_toolchain,
# install_ai_tools) must appear zero times.
#
# Counting strategy: match "^STEP <id> " (the STEP header line, space-anchored
# so set_default_shell_fish's exec-steps command line is not double-counted)
# OR "Also covers: <id> " (for setup_fish when grouped with nvm).
# This avoids false double-counts from the --exec-steps=<id> command text.
_t9_enabled=""
for _s in "${STEP_IDS[@]}"; do
  append_unique_word _t9_enabled "$_s"
done
STATE_ENABLED_STEPS="$_t9_enabled"
PKG_SKIP=""
_t9_rb="$(generate_runbook macos)"

_t9_prereqs=" prepare_and_clone_repo install_min_toolchain install_ai_tools "
for _s in $STATE_ENABLED_STEPS; do
  _t9_n="$(printf '%s' "$_t9_rb" | grep -cE "(^STEP $_s |Also covers: $_s )" || true)"
  case "$_t9_prereqs" in
    *" $_s "*)
      assert_eq "runbook parity: prereq $_s appears 0 times" "$_t9_n" "0"
      ;;
    *)
      assert_eq "runbook parity: step $_s appears 1 time" "$_t9_n" "1"
      ;;
  esac
done
_reset_state

# §9b  Package token parity: the runbook's install line contains exactly the
# packages that pkg_list_for_os (and pkg_filter_for_os) would produce.
# Strategy: extract every word token from the runbook's install command, then
# compare sorted sets with the sorted resolved package list.  Any dropped or
# added token fails the assertion — non-tautological because the runbook's
# literal list is separate from the registry computation.

# Helper: extract package tokens from an install command line in the runbook.
# For fedora: the runbook puts all packages on one line as
#   "... && sudo dnf -y install <main-pkgs> && sudo dnf -y install ffmpeg"
# We strip the trailing " && sudo dnf -y install ffmpeg" suffix first so that
# the greedy "##" strips correctly to the main package list, then add ffmpeg.
_runbook_pkg_tokens() {
  local rb="$1" os="$2" install_line tokens
  case "$os" in
    macos)
      install_line="$(printf '%s' "$rb" | grep 'brew install')"
      tokens="${install_line##*brew install}"
      ;;
    apt)
      install_line="$(printf '%s' "$rb" | grep 'apt -y install')"
      tokens="${install_line##*apt -y install}"
      ;;
    fedora)
      # One long line: "... dnf -y install <main> && sudo dnf -y install ffmpeg"
      # Strip trailing ffmpeg append, extract main tokens, then add ffmpeg.
      install_line="$(printf '%s' "$rb" | grep 'dnf -y install')"
      local _main_part
      _main_part="${install_line% && sudo dnf -y install ffmpeg*}"
      tokens="${_main_part##*dnf -y install } ffmpeg"
      ;;
    pacman)
      install_line="$(printf '%s' "$rb" | grep 'pacman -S --noconfirm')"
      tokens="${install_line##*pacman -S --noconfirm}"
      ;;
  esac
  # Normalize whitespace
  printf '%s' "$tokens" | tr -s ' \t' ' ' | sed 's/^ //;s/ $//'
}

# Compare sorted word lists for parity; report first-direction diffs on fail.
_assert_pkg_parity() {
  local test_name="$1" resolved="$2" from_runbook="$3"
  local rs fs
  rs="$(printf '%s\n' $resolved | sort | tr '\n' ' ' | sed 's/ $//')"
  fs="$(printf '%s\n' $from_runbook | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$rs" = "$fs" ]; then
    _pass "$test_name"
  else
    local only_reg only_rb
    only_reg="$(comm -23 <(printf '%s\n' $resolved | sort) <(printf '%s\n' $from_runbook | sort) 2>/dev/null || echo '?')"
    only_rb="$(comm -13 <(printf '%s\n' $resolved | sort) <(printf '%s\n' $from_runbook | sort) 2>/dev/null || echo '?')"
    _fail "$test_name" "drift: only in registry=[${only_reg}] only in runbook=[${only_rb}]"
  fi
}

for _os in macos apt fedora pacman; do
  STATE_ENABLED_STEPS="install_os_packages"
  PKG_SKIP=""
  _t9_rb="$(generate_runbook "$_os")"
  _t9_resolved="$(pkg_list_for_os "$_os")"
  _t9_rb_tokens="$(_runbook_pkg_tokens "$_t9_rb" "$_os")"
  _assert_pkg_parity "runbook pkg parity: $_os" "$_t9_resolved" "$_t9_rb_tokens"
  _reset_state
done

# §9c  nvm+fish grouping: both enabled → combined block appears exactly once;
# setup_fish is NOT emitted as a standalone block.
# Only setup_fish enabled → standalone --exec-steps=setup_fish block.

STATE_ENABLED_STEPS="setup_nvm_default_node setup_fish"
PKG_SKIP=""
_t9_rb="$(generate_runbook macos)"

# Combined block must appear once
_t9_n="$(printf '%s' "$_t9_rb" | grep -c 'exec-steps=setup_nvm_default_node,setup_fish' || true)"
assert_eq "nvm+fish: combined --exec-steps block appears once" "$_t9_n" "1"

# Standalone setup_fish block must NOT appear when nvm is also enabled.
# A standalone block has --exec-steps=setup_fish with no other id after it
# (the combined block has ",setup_fish" at the end which is different).
_t9_n="$(printf '%s' "$_t9_rb" | grep -cE 'exec-steps=setup_fish([^_,]|$)' || true)"
assert_eq "nvm+fish: no standalone setup_fish block when both enabled" "$_t9_n" "0"

_reset_state

# fish-only: standalone block appears
STATE_ENABLED_STEPS="setup_fish"
PKG_SKIP=""
_t9_rb="$(generate_runbook macos)"
_t9_n="$(printf '%s' "$_t9_rb" | grep -cE 'exec-steps=setup_fish([^_,]|$)' || true)"
assert_eq "fish-only: standalone --exec-steps=setup_fish appears" "$_t9_n" "1"
_reset_state

# §9d  PKG_SKIP path: skipping media group removes those tokens from the
# runbook install line; a non-skipped token (bash) remains.

STATE_ENABLED_STEPS="install_os_packages"
PKG_SKIP=""
for _m in $(pkg_group_members media); do
  append_unique_word PKG_SKIP "$_m"
done
# PKG_SKIP now contains canonical ids: ffmpeg imagemagick yt-dlp

for _os in macos apt; do
  _t9_rb="$(generate_runbook "$_os")"
  _t9_rb_tokens="$(_runbook_pkg_tokens "$_t9_rb" "$_os")"

  # Each media package (resolved for this OS) must be ABSENT from the install line
  for _m in $(pkg_group_members media); do
    _resolved_m="$(pkg_resolve "$_os" "$_m")"
    for _rm in $_resolved_m; do
      case " $_t9_rb_tokens " in
        *" $_rm "*)
          _fail "pkg_skip: $_rm absent from $_os runbook after media skip" \
            "'$_rm' still present in runbook install line"
          ;;
        *) _pass "pkg_skip: $_rm absent from $_os runbook after media skip" ;;
      esac
    done
  done

  # A non-skipped package (bash) must remain present
  _bash_pkg="$(pkg_resolve "$_os" bash)"
  case " $_t9_rb_tokens " in
    *" $_bash_pkg "*)
      _pass "pkg_skip: bash still present in $_os runbook after media skip"
      ;;
    *)
      _fail "pkg_skip: bash still present in $_os runbook after media skip" \
        "'$_bash_pkg' unexpectedly absent from runbook install line"
      ;;
  esac
done

_reset_state

# ---------------------------------------------------------------------------
# Task 10: run_agent + run_agent_with_fallback
# ---------------------------------------------------------------------------
printf '\n=== Task 10: run_agent + run_agent_with_fallback ===\n'

# run_agent: exact argv for claude and codex (RUN_AGENT_CMD seam)
_t10_out=$(
  _AGENT_ARGV=""
  RUN_AGENT_CMD() { _AGENT_ARGV="$*"; return 0; }
  run_agent claude "RB-TEXT"
  printf '%s' "$_AGENT_ARGV"
)
assert_eq "claude argv" "$_t10_out" "claude -p RB-TEXT --dangerously-skip-permissions"

_t10_out=$(
  _AGENT_ARGV=""
  RUN_AGENT_CMD() { _AGENT_ARGV="$*"; return 0; }
  run_agent codex "RB-TEXT"
  printf '%s' "$_AGENT_ARGV"
)
assert_eq "codex argv" "$_t10_out" \
  "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check RB-TEXT"

# run_agent: unknown driver -> exit 2
_t10_rc=0
( RUN_AGENT_CMD() { return 0; }
  run_agent bogus "RB-TEXT" ) >/dev/null 2>&1 || _t10_rc=$?
assert_eq "unknown driver exits 2" "$_t10_rc" "2"

# run_agent_with_fallback: first driver fails, OPT_SILENT_DRIVER empty -> fallback to other
_t10_fallback=$(
  _CALLS=""
  run_agent() { _CALLS="$_CALLS $1"; [ "$1" = claude ] && return 7; return 0; }
  cli_is_installed() { return 0; }
  cli_is_authenticated() { return 0; }
  DRIVER=claude OPT_SILENT_DRIVER=""
  run_agent_with_fallback "RB-TEXT" >/dev/null 2>&1
  _rc=$?
  printf 'calls=%s rc=%d' "$_CALLS" "$_rc"
)
assert_eq "fallback: calls+rc on first-fail" "$_t10_fallback" "calls= claude codex rc=0"

# run_agent_with_fallback: OPT_SILENT_DRIVER set -> no fallback, returns failure code
_t10_nofallback_rc=0
(
  run_agent() { [ "$1" = claude ] && return 5; return 0; }
  cli_is_installed() { return 0; }
  cli_is_authenticated() { return 0; }
  DRIVER=claude OPT_SILENT_DRIVER=claude
  run_agent_with_fallback "RB-TEXT"
) >/dev/null 2>&1 || _t10_nofallback_rc=$?
assert_eq "explicit driver: no fallback returns failure" "$_t10_nofallback_rc" "5"

# ---------------------------------------------------------------------------
# Task 11: sudo keep-alive + main_ai_flow orchestration
# ---------------------------------------------------------------------------
printf '\n=== Task 11: sudo keep-alive + main_ai_flow ===\n'

# sudo_keepalive_stop is a no-op when KEEPALIVE_PID is unset (must not error).
_t11_rc=0
(
  unset KEEPALIVE_PID
  sudo_keepalive_stop
) >/dev/null 2>&1 || _t11_rc=$?
assert_eq "keepalive stop no-op when unset" "$_t11_rc" "0"

# main_ai_flow, silent + codex: all heavy ops stubbed; assert codex drove.
# Subshell-contained so stub overrides don't leak into later tests.
_t11_silent=$(
  MODE=silent; OPT_SILENT=1; OPT_SILENT_DRIVER=codex; DRIVER=""
  cli_is_installed() { return 0; }
  cli_is_authenticated() { return 0; }
  prepare_and_clone_repo() { return 0; }
  install_min_toolchain() { return 0; }
  generate_runbook() { echo RB; }
  detect_os_key() { echo macos; }
  resolve_plan() { STATE_ENABLED_STEPS="install_bun"; }
  open_interaction_channel() { TTY_OPEN=0; }
  sudo_keepalive_start() { return 0; }
  sudo_keepalive_stop() { return 0; }
  _RAN=""
  RUN_AGENT_CMD() { _RAN="$*"; return 0; }
  main_ai_flow >/dev/null 2>&1
  printf '%s' "$_RAN"
)
assert_contains "silent codex drove run_agent" "$_t11_silent" "codex exec"

# C2 (GENUINE): main_ai_flow, interactive + run_auth_flow rc 10 -> graceful
# return 0 without running the agent.
#
# run_auth_flow returns 10 BY DESIGN when no CLI is authenticated. The buggy
# `run_auth_flow; rc=$?` runs as a bare statement under set -e, so the failing
# return aborts main_ai_flow BEFORE rc is captured: the "No AI CLI authenticated"
# guidance is dead and the run aborts. The fix is `rc=0; run_auth_flow || rc=$?`.
#
# This MUST run at the TOP LEVEL of a freshly-spawned bash that sources the
# installer normally (its own `set -e` takes effect). errexit-abort of a function
# return is suppressed when the call is nested inside another function context
# (as in this harness), so an in-harness subshell would NOT reproduce the abort
# and would pass falsely (the predecessor's $(...) wrapper had the same blind
# spot). We spawn a real top-level script and detect the abort two ways:
#   (1) a POST-main_ai_flow sentinel line that the abort prevents from printing
#   (2) an agent-marker file that must stay empty (agent never runs)
_c2_script="$(mktemp "${TMPDIR:-/tmp}/qi_c2_script.XXXXXX")"
_c2_marker="$(mktemp "${TMPDIR:-/tmp}/qi_c2_marker.XXXXXX")"
_c2_out="$(mktemp "${TMPDIR:-/tmp}/qi_c2_out.XXXXXX")"
: > "$_c2_marker"
cat > "$_c2_script" <<C2EOF
QUICK_INSTALL_SOURCED=1 source "$INSTALLER" 2>/dev/null
MODE=interactive; OPT_SILENT=""; DRIVER=""
resolve_plan() { STATE_ENABLED_STEPS="install_bun"; }
prepare_and_clone_repo() { return 0; }
install_min_toolchain() { return 0; }
install_ai_tools() { return 0; }
run_auth_flow() { return 10; }            # neither CLI authed (by design)
detect_os_key() { echo macos; }
generate_runbook() { echo RB; }
sudo_keepalive_start() { return 0; }
sudo_keepalive_stop() { return 0; }
# Agent seams: if any fires, the install proceeded past the auth gate (a bug).
run_agent() { echo ran > "$_c2_marker"; return 0; }
run_agent_with_fallback() { echo ran > "$_c2_marker"; return 0; }
RUN_AGENT_CMD() { echo ran > "$_c2_marker"; return 0; }
main_ai_flow
# Buggy code aborts main_ai_flow under set -e, so this sentinel never prints.
echo "SENTINEL rc=\$?"
C2EOF
bash "$_c2_script" > "$_c2_out" 2>/dev/null || true
_c2_sentinel="$(grep -c '^SENTINEL rc=0$' "$_c2_out" 2>/dev/null || echo 0)"
_c2_agent="$(cat "$_c2_marker" 2>/dev/null || true)"
rm -f "$_c2_script" "$_c2_marker" "$_c2_out"
if [ "$_c2_sentinel" -eq 1 ] && [ -z "$_c2_agent" ]; then
  _pass "interactive auth-gate: rc 10 -> graceful return 0, agent never runs (real set -e)"
else
  _fail "interactive auth-gate: rc 10 -> graceful return 0, agent never runs (real set -e)" \
    "sentinel_rc0=$_c2_sentinel (want 1), agent_marker='$_c2_agent' (want empty)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n================================================\n'
printf 'Results: %d total, %d passed, %d failed, %d skipped\n' \
  "$(( _PASS + _FAIL + _SKIP ))" "$_PASS" "$_FAIL" "$_SKIP"

if [ "$_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
