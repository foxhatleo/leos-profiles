#!/usr/bin/env bash
# Isolated credential workflows: all API, SSH and GPG operations are simulated.
# Installer variables are consumed by the sourced module.
# shellcheck disable=SC1091,SC2034,SC2030,SC2031,SC2329
set -Eeuo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../installer/credentials.sh
source "$ROOT/installer/credentials.sh"
# pkg_install and the root prefix used by the credential prerequisites.
# shellcheck source=../installer/packages.sh
source "$ROOT/installer/packages.sh"
# Managed blocks and symlink resolution (known_hosts, ~/.ssh/config,
# gpg-agent.conf); file_mode lives in install.sh.
# shellcheck source=../installer/config.sh
source "$ROOT/installer/config.sh"
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
fixture=$(mktemp -d /tmp/leos-credentials.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export HOME="$fixture/home"
export TMPDIR="$fixture"
mkdir -p "$HOME" "$fixture/local"
LOCAL_DIR="$fixture/local"
PROFILE_FILE="$LOCAL_DIR/profile"
TARGET="$fixture/profile"
DRY_RUN=0 COMMAND=apply SSH_MODE=reuse SSH_PASSPHRASE_MODE=empty
GPG_MODE=reuse GPG_PASSPHRASE_MODE=empty GPG_EXPIRY=2y SIGNING_MODE=skip
SSH_KEY_PATH="$fixture/custom-key"
GPG_KEY_ID=0123456789ABCDEF0123456789ABCDEF01234567
GIT_NAME='Test User' GIT_EMAIL=test@example.com
TEMP_PATHS=()
say() { :; }
warn() { printf '%s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
run() { "$@"; }
track_temp() { TEMP_PATHS+=("$1"); }
prepare_local_dir() { mkdir -p "$LOCAL_DIR"; }
write_profile() { printf '%s\t%s\n%s\t%s\n' "$SSH_MODE" "$SSH_KEY_PATH" "$GPG_MODE" "$GPG_KEY_ID" > "$PROFILE_FILE"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
api_keys='' api_gpg='' ordinary_login=tester selected_login=tester auth_ok=yes api_ok=yes signing_ok=yes
# Toggles for the refusal and manual-action branches (CI-9): the login the
# API reports, the verified emails, and a failure of one endpoint, which gh
# reports on stderr with exit status 1:
#   404   a missing OAuth scope (gh adds the scope hint)
#   403   a fine-grained token without the permission
#   rate  a 403 rate limit (no scope involved)
#   500   a server error
#   net   no connection
api_login=tester verified_emails=test@example.com gh_fail_endpoint='' gh_fail_kind=''
ssh_keygen_calls="$fixture/keygen-calls"
gh() {
  local IFS=' '
  printf '%s\n' "$*" >> "$fixture/gh-calls"
  [[ $api_ok == yes || $1 != api ]] || return 1
  if [[ -n $gh_fail_endpoint && " $* " == *" $gh_fail_endpoint "* ]]; then
    case $gh_fail_kind in
      404) printf '%s\n' 'gh: Not Found (HTTP 404)' \
        'This API operation needs the "admin:public_key" scope. To request it, run:  gh auth refresh -h github.com -s admin:public_key' >&2 ;;
      403) printf '%s\n' 'gh: Resource not accessible by personal access token (HTTP 403)' >&2 ;;
      rate) printf '%s\n' 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2 ;;
      500) printf '%s\n' 'gh: Server Error (HTTP 502)' >&2 ;;
      net) printf '%s\n' 'error connecting to api.github.com' 'check your internet connection or https://githubstatus.com' >&2 ;;
    esac
    return 1
  fi
  case "$*" in
    'auth status --hostname github.com') [[ $auth_ok == yes ]] ;;
    'api --hostname github.com user --jq .login') printf '%s\n' "$api_login" ;;
    'api --hostname github.com --paginate user/keys --jq .[].key') printf '%s' "$api_keys" ;;
    'api --hostname github.com --paginate user/gpg_keys --jq .[].key_id') printf '%s' "$api_gpg" ;;
    'api --hostname github.com --paginate user/ssh_signing_keys --jq .[].key') printf '%s' "$api_signing_keys" ;;
    'api --hostname github.com --paginate user/emails --jq .[] | select(.verified == true) | .email') printf '%s\n' "$verified_emails" ;;
    'api --hostname github.com meta --jq .ssh_keys[]') echo 'ssh-ed25519 AAAATEST' ;;
    *) fail "unexpected gh mutation or request: $*" ;;
  esac
}
api_signing_keys=''
# ssh_key_encrypted=yes: the key file has a passphrase, so an empty one
# (-y -P '') does not open it. A fingerprint is "SHA256:" and the key's
# base64 field without its AAAA prefix.
ssh_key_encrypted=no
ssh-keygen() {
  printf '%s\n' "$*" >> "$ssh_keygen_calls"
  if [[ $1 == -y && ${2:-} == -P ]]; then [[ $ssh_key_encrypted == no ]] || return 1; fi
  if [[ $1 == -y ]]; then echo 'ssh-ed25519 AAAATEST'; return; fi
  if [[ $1 == -lf ]]; then
    awk '{ fingerprint = $2; sub(/^AAAA/, "", fingerprint); print "256 SHA256:" fingerprint " public fixture (ED25519)"; exit }' "$2"
    return
  fi
  if [[ $1 == -F ]]; then awk -v host="$2" '$1 == host { print }' "$4"; return; fi
  if [[ $1 == -R ]]; then
    cp "$4" "$4.old"
    awk -v host="$2" '$1 != host' "$4.old" > "$4"
    return
  fi
  local output=''
  while (( $# )); do
    if [[ $1 == -f ]]; then output=$2; shift; fi
    shift
  done
  printf 'fake private test fixture\n' > "$output"
  printf 'ssh-ed25519 AAAATEST\n' > "$output.pub"
}
ensure_github_known_hosts() { :; }
# No terminal unless a test says so (plan.sh's stdin_is_terminal).
fixture_terminal=no
stdin_is_terminal() { [[ $fixture_terminal == yes ]]; }
# The running agent's identities (ssh-add -L) and its exit status.
agent_keys='' agent_status=0
ssh-add() {
  printf '%s\n' "$*" >> "$fixture/ssh-add-calls"
  [[ $1 == -L ]] || fail "unexpected ssh-add call: $*"
  [[ $agent_status == 0 ]] || return "$agent_status"
  printf '%s\n' "$agent_keys"
}
ssh() {
  printf '%s\n' "$*" >> "$fixture/ssh-calls"
  if [[ $1 == -G ]]; then
    printf '%s\n' 'identityfile ~/.ssh/wrong-key' 'identitiesonly no' 'hostname github.com' 'user git' 'proxycommand PRIVATE_SETTING_MUST_NOT_PRINT'
    return
  fi
  local login=$ordinary_login
  [[ $1 != -i ]] || login=$selected_login
  printf "Hi %s! You've successfully authenticated, but GitHub does not provide shell access.\n" "$login"
  return 1
}
# GPG toggles: the fingerprint the keyring reports (empty: no such secret
# key, as gpg exits 2), the user ID, and an export that wrongly contains
# private material.
gpg_listed_fingerprint=same gpg_uid='Test User <test@example.com>' gpg_export_private=no
gpg() {
  local IFS=' '
  printf '%s\n' "$*" >> "$fixture/gpg-calls"
  case "$*" in
    *--list-secret-keys*)
      case $gpg_listed_fingerprint in
        same) printf 'fpr:::::::::%s:\n' "$GPG_KEY_ID" ;;
        '') return 2 ;;
        *) printf 'fpr:::::::::%s:\n' "$gpg_listed_fingerprint" ;;
      esac ;;
    *--list-keys*) printf 'uid:::::::::%s:\n' "$gpg_uid" ;;
    '--armor --export '*)
      printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'PUBLIC FIXTURE' '-----END PGP PUBLIC KEY BLOCK-----'
      [[ $gpg_export_private == no ]] || printf '%s\n' '-----BEGIN PGP PRIVATE KEY BLOCK-----' ;;
    *--quick-generate-key*) printf '[GNUPG:] KEY_CREATED P %s\n' "$GPG_KEY_ID" ;;
    *) fail "unexpected gpg call: $*" ;;
  esac
}
git() {
  local IFS=' '
  printf '%s\n' "$*" >> "$fixture/git-calls"
  case "$*" in
    'config --global user.name') echo 'Test User' ;;
    'config --global user.email') echo test@example.com ;;
    '-C '*commit*) [[ $signing_ok == yes ]] ;;
    '-C '*) return 0 ;;
    'config --global user.signingkey '*|'config --global gpg.format openpgp'|'config --global commit.gpgsign true') return 0 ;;
    *) fail "unexpected git call: $*" ;;
  esac
}
expect_exit() {
  local expected=$1 actual=0
  shift
  # A child shell retains errexit, unlike a function invoked in an if/|| list.
  set +e
  (set -e; "$@") > "$fixture/output" 2> "$fixture/error"
  actual=$?
  set -e
  [[ $actual == "$expected" ]] || fail "expected exit $expected, got $actual: $(cat "$fixture/error")"
}
for api_gpg in '' 'null' ' ' '01234567' 'GGGGGGGGGGGGGGGG'; do
  expect_exit 1 github_gpg_key_present "$GPG_KEY_ID"
done
api_gpg=89ABCDEF01234567
expect_exit 0 github_gpg_key_present "$GPG_KEY_ID"
api_gpg=''
api_ok=no
expect_exit 1 github_gpg_key_present "$GPG_KEY_ID"
api_ok=yes
printf 'fake private test fixture\n' > "$SSH_KEY_PATH"
expect_exit 3 provision_ssh
grep -q $'^manual-action\tregister-ssh-key\t' "$fixture/output" || fail 'SSH registration action missing'
[[ -f $SSH_KEY_PATH.pub && -s $PROFILE_FILE ]] || fail 'SSH reference/public material not saved'
grep -q 'ssh-ed25519 AAAATEST' "$fixture/error" || fail 'SSH public material missing'
grep -q 'SHA256:TEST' "$fixture/error" || fail 'SSH fingerprint missing'
api_keys='ssh-ed25519 AAAATEST'
selected_login=other_account
expect_exit 3 provision_ssh
grep -q $'^manual-action\tverify-ssh-key\t' "$fixture/output" || fail 'selected SSH wrong account accepted'
selected_login=tester
ordinary_login=other_account
expect_exit 3 provision_ssh
grep -q $'^manual-action\tconfigure-ssh-key\t' "$fixture/output" || fail 'ordinary SSH wrong-account failure missing'
grep -q 'identityfile ~/.ssh/wrong-key' "$fixture/error" || fail 'effective identity not shown'
! grep -q PRIVATE_SETTING_MUST_NOT_PRINT "$fixture/error" || fail 'unrelated SSH settings leaked'
ordinary_login=tester
expect_exit 0 provision_ssh
grep -q '^-o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o BatchMode=yes -T git@github.com$' "$fixture/ssh-calls" || fail 'ordinary SSH was not tested in batch mode'
grep -qxF -- "-i $SSH_KEY_PATH -F /dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o BatchMode=yes -T git@github.com" "$fixture/ssh-calls" ||
  fail "selected-key SSH was not tested in batch mode: $(cat "$fixture/ssh-calls")"
# A passphrase-protected key file on a terminal may ask; elsewhere BatchMode stays.
ssh_key_encrypted=yes fixture_terminal=yes
: > "$fixture/ssh-calls"
expect_exit 0 provision_ssh
! grep -q BatchMode "$fixture/ssh-calls" || fail 'BatchMode kept ssh from asking for the passphrase on a terminal'
fixture_terminal=no
: > "$fixture/ssh-calls"
expect_exit 0 provision_ssh
[[ $(grep -c 'BatchMode=yes' "$fixture/ssh-calls") == 2 ]] || fail 'verification without a terminal could wait for input'
ssh_key_encrypted=no
SSH_MODE=generate
expect_exit 1 provision_ssh
SSH_KEY_PATH="$fixture/new-custom-key"
api_keys=''
expect_exit 3 provision_ssh
[[ -f $SSH_KEY_PATH && -f $SSH_KEY_PATH.pub ]] || fail 'custom generation path ignored'
COMMAND=reconcile
SSH_KEY_PATH="$fixture/must-not-generate"
expect_exit 3 provision_ssh
[[ ! -e $SSH_KEY_PATH ]] || fail 'reconcile generated SSH key'
GPG_MODE=generate
expect_exit 3 provision_gpg
[[ ! -e $fixture/gpg-calls ]] || fail 'reconcile touched GPG generation'
COMMAND=apply GPG_MODE=reuse
signing_ok=no
expect_exit 1 provision_gpg
[[ ! -e $LOCAL_DIR/gpg-public-$GPG_KEY_ID.asc ]] || fail 'failed signing produced registration artifact'
signing_ok=yes
expect_exit 3 provision_gpg
grep -q $'^manual-action\tregister-gpg-key\t' "$fixture/output" || fail 'GPG registration action missing'
[[ -s $LOCAL_DIR/gpg-public-$GPG_KEY_ID.asc ]] || fail 'public GPG export did not survive pause'
grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$fixture/error" || fail 'GPG public material missing'
grep -q "$GPG_KEY_ID" "$fixture/error" || fail 'GPG fingerprint missing'
! grep -q '^config --global commit.gpgsign true$' "$fixture/git-calls" || fail 'global signing enabled before registration'
api_gpg=89ABCDEF01234567
expect_exit 0 provision_gpg
grep -q '^config --global commit.gpgsign true$' "$fixture/git-calls" || fail 'registered key did not enable signing'
auth_ok=no
SSH_MODE=reuse
expect_exit 3 provision_ssh
grep -q $'^manual-action\tgithub-login\t' "$fixture/output" || fail 'manual login guidance missing'
# Invalid TSV input cannot corrupt a manual-action record.
expect_exit 1 credential_manual_action github-login $'bad\tpath' destination explanation
[[ ! -s $fixture/output ]] || fail 'malformed action was emitted'
# A pending second generation must not be described as a reconcile-only resume.
auth_ok=yes SSH_MODE=generate GPG_MODE=generate SSH_KEY_PATH="$fixture/combined-key" api_keys=''
expect_exit 3 provision_ssh
grep -q 'original approved choices' "$fixture/error" || fail 'combined generation resume guidance missing'
grep -q -- "--ssh reuse --ssh-key '$SSH_KEY_PATH'" "$fixture/error" || fail 'already generated SSH reuse guidance missing'
GPG_MODE=reuse

# --- Refusal and manual-action branches (CI-9; the gh scope part of CI-11) ---
# expect_action <action> [destination]: the last run printed that record.
expect_action() {
  local record
  record=$(grep $'^manual-action\t'"$1"$'\t' "$fixture/output" || true)
  [[ -n $record ]] || fail "no $1 manual action: $(cat "$fixture/output" "$fixture/error")"
  [[ $# -lt 2 || $record == *$'\t'"$2" ]] || fail "$1 destination: $record"
}
expect_no_action() {
  ! grep -q '^manual-action' "$fixture/output" || fail "an error became a manual action: $(cat "$fixture/output")"
}
COMMAND=apply SSH_MODE=reuse SSH_KEY_PATH="$fixture/custom-key" GPG_MODE=skip SIGNING_MODE=skip
api_keys='ssh-ed25519 AAAATEST' api_gpg=89ABCDEF01234567
# A key list the token may not read is a typed manual action naming only the
# scopes the selected modes need; anything else stays an error (ONB-2).
for gh_fail_kind in 404 403; do
  gh_fail_endpoint=user/keys
  expect_exit 3 provision_ssh
  expect_action github-key-scope 'gh auth refresh -h github.com -s read:public_key'
done
for gh_fail_kind in rate 500 net; do
  expect_exit 1 provision_ssh
  expect_no_action
  grep -q 'refusing to guess' "$fixture/error" || fail "$gh_fail_kind: no refusal: $(cat "$fixture/error")"
done
GPG_MODE=reuse
for gh_fail_kind in 404 403; do
  gh_fail_endpoint=user/gpg_keys
  expect_exit 3 provision_gpg
  expect_action github-key-scope 'gh auth refresh -h github.com -s read:public_key,read:gpg_key'
done
gh_fail_kind=net
expect_exit 1 provision_gpg
expect_no_action
# The email list: a missing scope is github-email-scope, a network failure an error.
gh_fail_endpoint=user/emails gh_fail_kind=404
expect_exit 3 provision_gpg
expect_action github-email-scope https://github.com/settings/emails
gh_fail_kind=net
expect_exit 1 provision_gpg
expect_no_action
gh_fail_endpoint='' gh_fail_kind=''
# An unverified Git email.
verified_emails=someone-else@example.com
expect_exit 1 provision_gpg
grep -q 'not verified' "$fixture/error" || fail 'unverified email accepted'
verified_emails=test@example.com
# An invalid account login.
api_login='bad login!'
expect_exit 1 provision_ssh
grep -q 'invalid account login' "$fixture/error" || fail 'invalid login accepted'
api_login=tester
# The keyring returns another key, or none (CQ-2: a clear message, not a silent exit).
gpg_listed_fingerprint=FEDCBA9876543210FEDCBA9876543210FEDCBA98
expect_exit 1 provision_gpg
grep -q 'different key' "$fixture/error" || fail "fingerprint mismatch accepted: $(cat "$fixture/error")"
gpg_listed_fingerprint=''
expect_exit 1 provision_gpg
grep -q 'was not found' "$fixture/error" || fail "missing key not reported: $(cat "$fixture/error")"
gpg_listed_fingerprint=same
# The key has no user ID for the Git email.
gpg_uid='Test User <other@example.com>'
expect_exit 1 provision_gpg
grep -q 'no user ID' "$fixture/error" || fail 'key without the email UID accepted'
gpg_uid='Test User <test@example.com>'
# An export containing private material is refused and never saved.
api_gpg='' gpg_export_private=yes
rm -f "$LOCAL_DIR/gpg-public-$GPG_KEY_ID.asc"
expect_exit 1 provision_gpg
expect_no_action
grep -q 'private key material' "$fixture/error" || fail 'private export not refused'
[[ ! -e $LOCAL_DIR/gpg-public-$GPG_KEY_ID.asc ]] || fail 'private export was saved'
! grep -q 'PRIVATE KEY' "$fixture/output" "$fixture/error" || fail 'private material printed'
# The manual action's own check refuses a file with private material too.
printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' '-----BEGIN PGP PRIVATE KEY BLOCK-----' \
  '-----END PGP PUBLIC KEY BLOCK-----' > "$fixture/bad-export.asc"
expect_exit 1 credential_manual_action register-gpg-key "$fixture/bad-export.asc" https://github.com/settings/gpg/new explanation
grep -q 'Invalid public GPG export' "$fixture/error" || fail 'manual action accepted private material'
expect_no_action
gpg_export_private=no api_gpg=89ABCDEF01234567

# --- --ssh agent (MI-7): a key only the agent holds ---
SSH_MODE=agent SSH_KEY_PATH='laptop key' GPG_MODE=skip api_keys=''
agent_keys=$'ssh-ed25519 AAAAAGENTONE laptop key\nssh-ed25519 AAAAAGENTTWO work\nssh-rsa AAAAAGENTTHREE work'
(
  unset SSH_AUTH_SOCK
  expect_exit 1 provision_ssh
  grep -q 'SSH_AUTH_SOCK is not set' "$fixture/error" || fail "no agent error: $(cat "$fixture/error")"
)
SSH_AUTH_SOCK="$fixture/not-a-socket"
: > "$SSH_AUTH_SOCK"
expect_exit 1 provision_ssh
grep -q 'not a socket' "$fixture/error" || fail 'a regular file was accepted as the agent socket'
SSH_AUTH_SOCK="$fixture/agent.sock"
if /usr/bin/env python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SSH_AUTH_SOCK" 2>/dev/null; then
  agent_status=1
  expect_exit 1 provision_ssh
  grep -q 'holds no keys' "$fixture/error" || fail 'an empty agent was not reported'
  agent_status=2
  expect_exit 1 provision_ssh
  grep -q 'Could not reach the SSH agent' "$fixture/error" || fail 'an unreachable agent was not reported'
  agent_status=0
  SSH_KEY_PATH='no such key'
  expect_exit 1 provision_ssh
  grep -q "No key in the SSH agent matches --ssh-key 'no such key'.*SHA256:AGENTONE (laptop key)" "$fixture/error" ||
    fail "unmatched selector: $(cat "$fixture/error")"
  SSH_KEY_PATH=work
  expect_exit 1 provision_ssh
  grep -q 'matches 2 agent keys' "$fixture/error" || fail 'an ambiguous selector picked a key'
  # Selected by comment: the public key is saved under local/ and registration
  # is a manual action naming it; the profile keeps the fingerprint.
  SSH_KEY_PATH='laptop key'
  : > "$ssh_keygen_calls"
  expect_exit 3 provision_ssh
  expect_action register-ssh-key https://github.com/settings/ssh/new
  grep -q $'^manual-action\tregister-ssh-key\t'"$LOCAL_DIR/ssh-agent-key.pub"$'\t' "$fixture/output" || fail 'agent public key path missing'
  [[ $(cat "$LOCAL_DIR/ssh-agent-key.pub") == 'ssh-ed25519 AAAAAGENTONE laptop key' ]] || fail 'agent public key not saved'
  grep -qxF $'agent\tSHA256:AGENTONE' "$PROFILE_FILE" || fail "agent selection not saved: $(cat "$PROFILE_FILE")"
  ! grep -q -- '^-y' "$ssh_keygen_calls" || fail 'agent mode read a private-key file'
  # Registered: verified through the agent with the public key, in batch mode.
  for SSH_KEY_PATH in SHA256:AGENTONE 'ssh-ed25519 AAAAAGENTONE' 'ssh-ed25519 AAAAAGENTONE laptop key'; do
    api_keys='ssh-ed25519 AAAAAGENTONE'
    : > "$fixture/ssh-calls"
    expect_exit 0 provision_ssh
    grep -qxF -- "-i $LOCAL_DIR/ssh-agent-key.pub -o IdentityAgent=$SSH_AUTH_SOCK -F /dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o BatchMode=yes -T git@github.com" "$fixture/ssh-calls" ||
      fail "agent key not verified through the agent: $(cat "$fixture/ssh-calls")"
  done
  # Ordinary SSH that does not use the agent: guidance names the agent.
  ordinary_login=other_account
  expect_exit 3 provision_ssh
  expect_action configure-ssh-key
  grep -q 'use the agent' "$fixture/error" || fail 'agent configuration guidance missing'
  ordinary_login=tester
else
  echo 'SKIP: agent-socket fixtures need python3 to create a Unix socket.'
fi

# --- --ssh-config yes (SEC-1/MI-7): an opt-in managed github.com block ---
SSH_MODE=reuse SSH_KEY_PATH="$fixture/custom-key" api_keys='ssh-ed25519 AAAATEST' OS_FAMILY=macos SSH_CONFIG=no
rm -rf "$HOME/.ssh"
expect_exit 0 provision_ssh
[[ ! -e $HOME/.ssh/config ]] || fail 'SSH configuration was written without --ssh-config yes'
SSH_CONFIG=yes
expect_exit 0 provision_ssh
expected_block=$'# >>> leos-profiles ssh-config >>>\nHost github.com\n  AddKeysToAgent yes\n  UseKeychain yes\n  IdentityFile "'"$SSH_KEY_PATH"$'"\n# <<< leos-profiles ssh-config <<<'
[[ $(cat "$HOME/.ssh/config") == "$expected_block" ]] || fail "unexpected SSH config block: $(cat "$HOME/.ssh/config")"
[[ $(file_mode "$HOME/.ssh/config") == 600 ]] || fail 'a new ~/.ssh/config is not private'
# Idempotent, after the user's own content, which it leaves alone.
printf '%s\n' 'Host *' '  ServerAliveInterval 60' > "$HOME/.ssh/config"
expect_exit 0 provision_ssh
expect_exit 0 provision_ssh
[[ $(grep -c '^# >>> leos-profiles ssh-config >>>$' "$HOME/.ssh/config") == 1 ]] || fail 'SSH config block duplicated'
[[ $(head -n 2 "$HOME/.ssh/config") == $'Host *\n  ServerAliveInterval 60' ]] || fail 'user SSH config changed'
# Linux has no UseKeychain; an agent key has no IdentityFile.
OS_FAMILY=apt
expect_exit 0 provision_ssh
! grep -q UseKeychain "$HOME/.ssh/config" || fail 'UseKeychain written on Linux'
if [[ -S $fixture/agent.sock ]]; then
  SSH_MODE=agent SSH_KEY_PATH=SHA256:AGENTONE SSH_AUTH_SOCK="$fixture/agent.sock" api_keys='ssh-ed25519 AAAAAGENTONE'
  expect_exit 0 provision_ssh
  ! grep -q IdentityFile "$HOME/.ssh/config" || fail 'IdentityFile written for an agent key'
fi
SSH_MODE=reuse SSH_KEY_PATH="$fixture/custom-key" api_keys='ssh-ed25519 AAAATEST' SSH_CONFIG=no
unset OS_FAMILY
rm -rf "$HOME/.ssh"

# New GPG keys get the approved expiry (SEC-1).
GPG_MODE=generate GPG_EXPIRY=2y
: > "$fixture/gpg-calls"
expect_exit 0 provision_gpg
grep -q -- '--quick-generate-key Test User <test@example.com> ed25519 sign 2y$' "$fixture/gpg-calls" ||
  fail "expiry not passed: $(cat "$fixture/gpg-calls")"
GPG_MODE=generate GPG_EXPIRY=never
expect_exit 0 provision_gpg
grep -q -- 'ed25519 sign never$' "$fixture/gpg-calls" || fail 'explicit no-expiry not passed'
GPG_EXPIRY=2y
# A second `--gpg generate` stops while the key an earlier run saved is still
# in the keyring, and names it for reuse (the SSH guard's GPG twin).
(
  printf 'gpg\treuse\ngpg-key\t%s\n' "$GPG_KEY_ID" > "$PROFILE_FILE"
  GPG_MODE=generate
  expect_exit 1 gpg_generation_guard
  grep -q -- "Refusing to generate a second GPG key.*--gpg reuse --gpg-key $GPG_KEY_ID" "$fixture/error" ||
    fail "no GPG reuse guidance: $(cat "$fixture/error")"
  gpg_listed_fingerprint=''
  expect_exit 0 gpg_generation_guard
  gpg_listed_fingerprint=same GPG_MODE=reuse
  expect_exit 0 gpg_generation_guard
  printf 'gpg\tgenerate\ngpg-key\t\n' > "$PROFILE_FILE"
  GPG_MODE=generate
  expect_exit 0 gpg_generation_guard
)
GPG_MODE=reuse

# Credential prerequisite installation requests only missing packages.
# The overrides below are invoked indirectly by the code under test.
# shellcheck disable=SC2317
(
  ensure_sudo() { :; }
  ensure_brew() { fail 'unnecessary Homebrew bootstrap'; }
  run() { local IFS=' '; printf '%s\n' "$*" >> "$fixture/prerequisites"; }
  package_installed() { [[ ,$installed_packages, == *,"$1",* ]]; }
  SSH_MODE=reuse GPG_MODE=reuse
  for OS_FAMILY in apt fedora arch; do
    case $OS_FAMILY in
      apt) installed_packages=gh; expected_ssh=openssh-client; expected_gpg=gnupg ;;
      fedora) installed_packages=gh; expected_ssh=openssh-clients; expected_gpg=gnupg2 ;;
      arch) installed_packages=github-cli; expected_ssh=openssh; expected_gpg=gnupg ;;
    esac
    : > "$fixture/prerequisites"
    install_credential_prerequisites
    grep -q " $expected_ssh $expected_gpg$" "$fixture/prerequisites" || fail "missing credential packages on $OS_FAMILY"
    ! grep -Eq ' (gh|github-cli)( |$)' "$fixture/prerequisites" || fail 'already installed CLI requested'
    installed_packages="$installed_packages,$expected_ssh,$expected_gpg"
    : > "$fixture/prerequisites"
    install_credential_prerequisites
    [[ ! -s $fixture/prerequisites ]] || fail 'fully installed prerequisites caused mutation'
  done
  # macOS uses the system OpenSSH in /usr/bin and installs only gh/gnupg via
  # Homebrew. The fixture's gh and gpg are shell functions, which `command -v`
  # reports as present, so the first run must not touch Homebrew at all.
  if [[ $(uname -s) == Darwin ]]; then
    OS_FAMILY=macos
    : > "$fixture/prerequisites"
    install_credential_prerequisites
    [[ ! -s $fixture/prerequisites ]] || fail 'macOS prerequisites mutated with gh and gpg present'
    # Without them (no functions, nothing on PATH) exactly both are requested.
    (
      unset -f gh gpg
      mkdir -p "$fixture/empty-path"
      # Deliberate: an empty search path makes `command -v gh` fail.
      # shellcheck disable=SC2123
      PATH="$fixture/empty-path"
      ensure_brew() { :; }
      install_credential_prerequisites
    )
    [[ $(cat "$fixture/prerequisites") == 'brew install gh gnupg' ]] ||
      fail "macOS prerequisites requested: $(cat "$fixture/prerequisites")"
  fi
)
# Deduplicate known-host material only for the matching host.
(
  source "$ROOT/installer/credentials.sh"
  ssh-keyscan() { echo 'github.com ssh-ed25519 AAAATEST'; }
  mkdir -p "$HOME/.ssh"
  echo 'other.example ssh-ed25519 AAAATEST' > "$HOME/.ssh/known_hosts"
  ensure_github_known_hosts
  grep -q '^github.com ssh-ed25519 AAAATEST$' "$HOME/.ssh/known_hosts" || fail 'other host suppressed github.com key'
  ensure_github_known_hosts
  [[ $(grep -c '^github.com ' "$HOME/.ssh/known_hosts") == 1 ]] || fail 'same-host key duplicated'
)
# Check the public pause against the real schema writer and EXIT cleanup.
integration_ssh_pause() {
  # shellcheck source=../install.sh
  LEOS_PROFILES_INSTALL_LIB_ONLY=1 source "$ROOT/install.sh"
  LOCAL_DIR="$fixture/integration"
  PROFILE_FILE="$LOCAL_DIR/profile"
  LOCK_DIR="$LOCAL_DIR/lock"
  COMMAND=apply SSH_MODE=generate SSH_KEY_PATH="$fixture/integration-key"
  DRY_RUN=0 auth_ok=yes api_keys=''
  trap cleanup EXIT
  acquire_lock
  provision_ssh
}
expect_exit 3 integration_ssh_pause
[[ ! -e $fixture/integration/lock ]] || fail 'manual pause retained installer lock'
[[ -s $fixture/integration-key.pub ]] || fail 'EXIT cleanup removed public key'
grep -q $'^schema\t2$' "$fixture/integration/profile" || fail 'manual pause failed to persist current profile schema'
grep -q $'^ssh\treuse$' "$fixture/integration/profile" || fail 'manual pause did not persist SSH reuse mode'

# Exercise real cryptography and Git signing, confined to a disposable keyring
# and explicit Git config. GitHub and SSH connections remain simulated.
if command -v gpg >/dev/null && command -v gpgconf >/dev/null && command -v ssh-keygen >/dev/null; then
  (
    unset -f gpg git ssh-keygen
    export GNUPGHOME="$fixture/g"
    export GIT_CONFIG_GLOBAL="$fixture/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0
    mkdir -m 700 "$GNUPGHOME"
    trap 'command gpgconf --homedir "$GNUPGHOME" --kill gpg-agent >/dev/null 2>&1 || true' EXIT
    command git config --global user.name 'Credential Fixture'
    command git config --global user.email test@example.com
    command git config --global core.hooksPath /dev/null
    auth_ok=yes COMMAND=apply SSH_MODE=generate api_keys=''
    SSH_KEY_PATH="$fixture/real-ssh"
    expect_exit 3 provision_ssh
    [[ -s $SSH_KEY_PATH && -s $SSH_KEY_PATH.pub ]] || fail 'real SSH generation failed'
    api_keys=$(command ssh-keygen -y -f "$SSH_KEY_PATH")
    SSH_MODE=reuse
    expect_exit 0 provision_ssh
    GPG_MODE=generate api_gpg=''
    expect_exit 3 provision_gpg
    GPG_KEY_ID=$(command gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    [[ -n $GPG_KEY_ID && -s $LOCAL_DIR/gpg-public-$GPG_KEY_ID.asc ]] || fail 'real public GPG artifact missing'
    # The default 2y expiry reached the real key (field 7 of the pub record).
    [[ -n $(command gpg --batch --with-colons --list-keys "$GPG_KEY_ID" 2>/dev/null | awk -F: '$1 == "pub" { print $7; exit }') ]] ||
      fail 'real GPG key has no expiry'
    if command git config --global --get commit.gpgsign >/dev/null; then fail 'real signing enabled before registration'; fi
    GPG_MODE=reuse
    api_gpg=${GPG_KEY_ID: -16}
    expect_exit 0 provision_gpg
    [[ $(command git config --global --get commit.gpgsign) == true ]] || fail 'real signing verification failed'
    # Only the public key export is provided in the manual-action record.
    ! grep -q 'PRIVATE KEY' "$fixture/output" || fail 'private key material leaked to stdout'
  )
else
  echo 'SKIP: real credential fixtures require gpg, gpgconf and ssh-keygen.'
fi
echo 'Credential tests passed.' 
