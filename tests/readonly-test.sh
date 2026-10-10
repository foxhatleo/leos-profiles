#!/usr/bin/env bash
# Prove the documented read-only contract through the real CLI: `inspect`,
# `apply --dry-run` and `reconcile --dry-run` change nothing in HOME, in the
# checkout (including its local/ state) or in TMPDIR. Each command runs against
# a fixture HOME and a temporary copy of the public checkout, with a minimal
# environment and PATH fakes standing in for package managers, network clients
# and privilege escalation, so the result is hermetic on macOS and Linux and
# independent of what the host has installed or provisioned.
#
# Every inspect line must also be a documented record type with the column
# count given in docs/development.md ("State and TSV contract").
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# Physical path: install.sh records its own `pwd -P` root.
FIXTURE=$(CDPATH='' cd -- "$(mktemp -d "${TMPDIR:-/tmp}/leos-readonly.XXXXXX")" && pwd -P)
trap 'rm -rf -- "$FIXTURE"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

FIXTURE_HOME="$FIXTURE/home"
PROFILE="$FIXTURE/profile"
FAKEBIN="$FIXTURE/fakebin"
SCRATCH_TMP="$FIXTURE/tmp"
CALLS="$FIXTURE/calls.log"
mkdir -p "$FIXTURE_HOME" "$PROFILE/local" "$FAKEBIN" "$SCRATCH_TMP"
: > "$CALLS"

# Only the public files install.sh reads. No developer local/ state, plugin
# clones, legacy private override or VCS metadata.
cp -R "$ROOT/install.sh" "$ROOT/installer" "$ROOT/zsh" "$ROOT/util" "$PROFILE/"
rm -rf -- "$PROFILE/zsh/plugins" "$PROFILE/zsh/_private.zsh"

# Existing user and installer state that a real run would rewrite or migrate:
# shell startup files, a legacy marker, legacy XDG state and a schema-1 saved
# profile (whose migration inspect reports but must not write).
# The startup files carry the legacy unmarked loader and zshenv snippet the
# pre-installer instructions appended, which inspect reports as migrations.
# shellcheck disable=SC2016
printf '%s\n' 'echo user rc' 'if [[ -o interactive ]]; then' \
  '    source "$HOME/.leos-profiles/zsh/start.zsh"' 'fi' > "$FIXTURE_HOME/.zshrc"
# shellcheck disable=SC2016
printf '%s\n' 'export USER_ENV=1' '# leos-profiles zshenv' 'typeset -U path' \
  'path=("$HOME/.local/bin" $path)' 'export PATH' > "$FIXTURE_HOME/.zshenv"
printf '%s\n' 'legacy' > "$FIXTURE_HOME/.lp-no-gnu"
# Existing setups inspect discloses (oh-my-zsh, nvm).
mkdir -p "$FIXTURE_HOME/.oh-my-zsh" "$FIXTURE_HOME/.nvm"
mkdir -p "$FIXTURE_HOME/.local/state/leos-profiles"
printf 'packages\t%064d\t2020-01-01T00:00:00Z\t\n' 0 > "$FIXTURE_HOME/.local/state/leos-profiles/install-state.tsv"
printf '%s\t%s\n' schema 1 groups zsh-config,fnm package-groups shell full-upgrade no \
  fonts no font '' default-shell no git-name '' git-email '' ssh skip ssh-key '' \
  ssh-passphrase empty gpg skip gpg-key '' gpg-passphrase empty node-channel current-lts \
  ai-cli-update-channel native package-channel system > "$PROFILE/local/install-profile.tsv"
chmod 600 "$PROFILE/local/install-profile.tsv"

# One fake, linked under every name. Queries answer "not installed" or "no
# network" (the read-only fallbacks); anything else is recorded as a mutation
# attempt and fails. Fakes mirror the host's package manager so the installer
# still detects the same OS family.
cat > "$FAKEBIN/fake" <<'FAKE'
#!/bin/sh
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$LEOS_READONLY_CALLS"
case "$name" in
  brew)
    case "$1" in
      list|info|--prefix|--version) exit 1 ;;
      shellenv) exit 0 ;;
    esac ;;
  dpkg-query) exit 1 ;;
  rpm)
    case "$1" in
      -q) exit 1 ;;
      -E) printf '0\n'; exit 0 ;;
    esac ;;
  pacman)
    case "$1" in -Q*) exit 1 ;; esac ;;
  curl|wget|fnm|node) exit 7 ;;
esac
printf 'MUTATION %s %s\n' "$name" "$*" >> "$LEOS_READONLY_CALLS"
exit 97
FAKE
chmod 755 "$FAKEBIN/fake"
fakes=(sudo chsh curl wget gh ssh-keyscan fnm node npm)
if [[ $(uname -s) == Darwin ]]; then
  fakes+=(brew)
else
  if command -v apt-get >/dev/null 2>&1; then fakes+=(apt-get dpkg-query); fi
  if command -v dnf >/dev/null 2>&1; then fakes+=(dnf rpm); fi
  if command -v pacman >/dev/null 2>&1; then fakes+=(pacman); fi
fi
for name in "${fakes[@]}"; do ln -s fake "$FAKEBIN/$name"; done

# Run the CLI with only the fixture environment. The interpreter running this
# test also runs the installer (macOS CI runs both under the system Bash 3.2).
# No terminal on stdin, as when an AI agent runs the installer. No USER either:
# the installer must find the account itself (ONB-12).
installer() {
  env -i HOME="$FIXTURE_HOME" LANG=C \
    PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$SCRATCH_TMP" \
    XDG_STATE_HOME="$FIXTURE_HOME/.local/state" XDG_CONFIG_HOME="$FIXTURE_HOME/.config" \
    XDG_CACHE_HOME="$FIXTURE_HOME/.cache" XDG_DATA_HOME="$FIXTURE_HOME/.local/share" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$FIXTURE_HOME/.gitconfig" LEOS_READONLY_CALLS="$CALLS" \
    "${BASH:-bash}" "$PROFILE/install.sh" "$@" </dev/null
}

# Type, permissions, size and mtime of every entry (directory mtimes catch a
# file created and deleted again), plus a checksum of every regular file.
snapshot() {
  local root=$1
  if [[ $(uname -s) == Darwin ]]; then
    find "$root" -exec /usr/bin/stat -f '%N|%HT|%Lp|%z|%m|%Y' {} +
  else
    find "$root" -exec stat -c '%n|%F|%a|%s|%Y|%N' {} +
  fi
  find "$root" -type f -exec cksum {} +
}
snapshot_all() { { snapshot "$FIXTURE_HOME"; snapshot "$PROFILE"; } | LC_ALL=C sort; }

# Record type -> total column count, read from the documented table so the
# contract and this check cannot drift apart.
documented_columns() {
  awk -F '|' '
    /^\| `[a-z-]+` \| [0-9]+ \|/ {
      type = $2; count = $3
      gsub(/[ `]/, "", type); gsub(/ /, "", count)
      print type ":" count
    }
  ' "$ROOT/docs/development.md"
}
COLUMNS_SPEC=$(documented_columns | tr '\n' ' ')
[[ $COLUMNS_SPEC == *meta:3* && $COLUMNS_SPEC == *postcondition:3* ]] ||
  fail "could not read the record table from docs/development.md: $COLUMNS_SPEC"

check_tsv() {
  local label=$1 output=$2
  [[ -n $output ]] || fail "$label printed no records"
  awk -F '\t' -v spec="$COLUMNS_SPEC" -v label="$label" '
    BEGIN {
      n = split(spec, items, " ")
      for (i = 1; i <= n; i++) { split(items[i], kv, ":"); want[kv[1]] = kv[2] }
    }
    !($1 in want) { printf "%s line %d: undocumented record type: %s\n", label, NR, $0; bad = 1; next }
    NF != want[$1] {
      printf "%s line %d: %s has %d columns, documented %d: %s\n", label, NR, $1, NF, want[$1], $0
      bad = 1
    }
    END { exit bad }
  ' <<< "$output" >&2 || fail "$label emitted TSV that does not match the documented contract"
  [[ $(sed -n '1p' <<< "$output") == $'meta\tschema\t1' ]] || fail "$label does not start with the schema record"
  grep -qxF $'profile\troot\t'"$PROFILE" <<< "$output" || fail "$label did not inspect the fixture checkout"
}

# run_read_only <label> <expected exit> <args...>: run the CLI, then prove that
# nothing changed and nothing attempted a mutation. Output goes to $OUTPUT.
run_read_only() {
  local label=$1 expected=$2 before after status=0
  shift 2
  before=$(snapshot_all)
  OUTPUT=$(installer "$@" 2> "$FIXTURE/stderr") || status=$?
  # Compare only after the process exits: the apply lock lives in local/ only
  # while a (non-dry) run holds it.
  after=$(snapshot_all)
  [[ $status == "$expected" ]] ||
    fail "$label exited $status, expected $expected: $(cat "$FIXTURE/stderr")"
  if [[ $after != "$before" ]]; then
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
    fail "$label changed the fixture HOME or checkout"
  fi
  [[ -z $(ls -A "$SCRATCH_TMP") ]] || fail "$label left temporary files: $(ls -A "$SCRATCH_TMP")"
  ! grep '^MUTATION ' "$CALLS" >&2 || fail "$label invoked a mutating command"
}

run_read_only 'inspect (recommended)' 0 inspect
check_tsv 'inspect (recommended)' "$OUTPUT"
grep -qxF $'migration\tprofile-schema\t1\t2' <<< "$OUTPUT" || fail 'inspect did not report the pending profile migration'
grep -q $'^postcondition\tzsh-config\tneeded$' <<< "$OUTPUT" || fail 'inspect did not report zsh-config as needed'
grep -qxF $'migration\tlegacy-loader\t'"$FIXTURE_HOME/.zshrc"$'\tloader' <<< "$OUTPUT" ||
  fail 'inspect did not report the legacy .zshrc loader'
grep -qxF $'migration\tlegacy-environment\t'"$FIXTURE_HOME/.zshenv"$'\tenvironment' <<< "$OUTPUT" ||
  fail 'inspect did not report the legacy .zshenv snippet'
grep -qxF $'file\tzshrc\t'"$FIXTURE_HOME/.zshrc" <<< "$OUTPUT" || fail 'inspect did not disclose the .zshrc path'
grep -q $'^existing\toh-my-zsh\t'"$FIXTURE_HOME/.oh-my-zsh"$'\t' <<< "$OUTPUT" || fail 'inspect did not disclose oh-my-zsh'
grep -q $'^existing\tnvm\t'"$FIXTURE_HOME/.nvm"$'\t' <<< "$OUTPUT" || fail 'inspect did not disclose nvm'
if [[ $(uname -s) == Darwin ]]; then
  grep -qxF $'file\tzprofile\t'"$FIXTURE_HOME/.zprofile" <<< "$OUTPUT" || fail 'inspect did not disclose the .zprofile path'
fi

run_read_only 'inspect (credentials and every component)' 0 inspect \
  --groups bins,pyenv,rbenv,bun,yarn,pnpm,plugins,fonts,zsh-config,default-shell \
  --fonts yes --font JetBrainsMono --ssh generate --gpg generate \
  --git-name 'Fixture User' --git-email fixture@example.invalid
check_tsv 'inspect (credentials and every component)' "$OUTPUT"
for record in artifact external file global irreversible runtime; do
  grep -q "^$record"$'\t' <<< "$OUTPUT" || fail "full inspect emitted no $record record"
done

run_read_only 'apply --dry-run' 0 apply --yes --dry-run
grep -q 'Profile apply complete' <<< "$OUTPUT" || fail 'dry-run apply did not complete'
grep -q 'Would move .*\.lp-no-gnu' <<< "$OUTPUT" || fail 'dry-run apply did not detect the legacy marker'
grep -q 'Would remove the legacy unmarked leos-profiles loader' <<< "$OUTPUT" ||
  fail 'dry-run apply did not plan the legacy loader migration'

run_read_only 'reconcile --dry-run' 0 reconcile --yes --dry-run
grep -q 'Profile reconciliation complete' <<< "$OUTPUT" || fail 'dry-run reconcile did not complete'

# inspect --saved: the saved profile's selection, as reconcile would use it.
run_read_only 'inspect --saved' 0 inspect --saved
check_tsv 'inspect --saved' "$OUTPUT"
grep -qxF $'policy\tselection\tsaved' <<< "$OUTPUT" || fail 'inspect --saved did not say it used the saved selection'
grep -qxF $'group\tcomponent\tfnm\tselected' <<< "$OUTPUT" || fail 'inspect --saved did not use the saved components'
! grep -q $'^group\tcomponent\tpyenv\t' <<< "$OUTPUT" || fail 'inspect --saved used the default selection'

# inventory, in both formats.
run_read_only 'inventory --tsv' 0 inventory --tsv
check_tsv 'inventory --tsv' "$OUTPUT"
grep -qxF $'item\tlocal\tinstall-profile.tsv\t'"$PROFILE/local/install-profile.tsv"$'\tpresent' <<< "$OUTPUT" ||
  fail 'inventory did not list the saved profile'
run_read_only 'inventory' 0 inventory
grep -q '^present  local  ' <<< "$OUTPUT" || fail 'human inventory did not list present items'

# An existing non-Git ~/.pyenv: disclosed, and apply stops before any change
# unless asked to keep it (ONB-5).
mkdir -p "$FIXTURE_HOME/.pyenv"
run_read_only 'inspect (existing ~/.pyenv)' 0 inspect --groups pyenv
check_tsv 'inspect (existing ~/.pyenv)' "$OUTPUT"
grep -qxF $'conflict\tpyenv\t'"$FIXTURE_HOME/.pyenv"$'\tnot-a-git-checkout' <<< "$OUTPUT" ||
  fail 'inspect did not report the existing ~/.pyenv'
run_read_only 'apply --dry-run (existing ~/.pyenv)' 1 apply --yes --dry-run --groups pyenv
grep -q -- '--skip-existing-version-managers' "$FIXTURE/stderr" || fail 'the pyenv conflict did not name the option'
run_read_only 'apply --dry-run --skip-existing-version-managers' 0 apply --yes --dry-run --groups pyenv --skip-existing-version-managers
grep -q 'Skipping pyenv: keeping the existing installation' <<< "$OUTPUT" || fail 'the existing pyenv was not kept'
rmdir "$FIXTURE_HOME/.pyenv"

# Without a terminal, a choice that must prompt stops before any change with
# the exact command to run yourself (ONB-1).
run_read_only 'apply without a terminal' 3 apply --yes --groups zsh-config --package-groups none \
  --default-shell no --ssh generate --ssh-passphrase prompt
grep -q $'^manual-action\trun-in-terminal\t\tbash '"$PROFILE"'/install.sh apply --yes ' <<< "$OUTPUT" ||
  fail "no run-in-terminal action: $OUTPUT"
[[ ! -e $PROFILE/local/.install.lock ]] || fail 'the stopped run left its lock'

printf 'read-only inspect/dry-run (%s): PASS\n' "$(uname -s)"
