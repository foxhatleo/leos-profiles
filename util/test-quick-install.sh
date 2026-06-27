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
  OPT_YES=""
  OPT_FRESH=""
  OPT_ONLY=""
  OPT_SKIP=""
  OPT_PACKAGES=""
  OPT_SKIP_PACKAGES=""
  OPT_NO_FONTS=""
  OPT_HTTPS=""
  OPT_STATE_FILE=""
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
assert_word_present "install_ai_tools pulls in setup_nvm_default_node" "setup_nvm_default_node" "$STATE_ENABLED_STEPS"

_reset_opts; _reset_state
args_parse --only=install_ai_tools
capture_env
resolve_plan 2>/dev/null
assert_word_present "install_ai_tools pulls in install_os_packages transitively" "install_os_packages" "$STATE_ENABLED_STEPS"

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
  _tmpfile=$(mktemp "/private/tmp/claude-501/-Users-leoliang--leos-profiles/fdc5f7ed-5c82-4b03-b034-1a82e5f17335/scratchpad/tui_test_XXXXXX")
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
  _tmpfile=$(mktemp "/private/tmp/claude-501/-Users-leoliang--leos-profiles/fdc5f7ed-5c82-4b03-b034-1a82e5f17335/scratchpad/tui_test_XXXXXX")
  # BSD script (macOS): script -q outputfile command  (stdin piped in)
  printf 'q' | script -q "$_tmpfile" /bin/bash "$INSTALLER" --silent >/dev/null 2>&1 || true
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
# Summary
# ---------------------------------------------------------------------------
printf '\n================================================\n'
printf 'Results: %d total, %d passed, %d failed, %d skipped\n' \
  "$(( _PASS + _FAIL + _SKIP ))" "$_PASS" "$_FAIL" "$_SKIP"

if [ "$_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
