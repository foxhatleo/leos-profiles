#!/usr/bin/env bash
# Isolated credential workflows: all API, SSH and GPG operations are simulated.
# Installer variables are consumed by the sourced module.
# shellcheck disable=SC1091,SC2034,SC2030,SC2031,SC2329
set -Eeuo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../installer/credentials.sh
source "$ROOT/installer/credentials.sh"
fixture=$(mktemp -d /tmp/leos-credentials.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export HOME="$fixture/home"
export TMPDIR="$fixture"
mkdir -p "$HOME" "$fixture/local"
LOCAL_DIR="$fixture/local"
PROFILE_FILE="$LOCAL_DIR/profile"
DRY_RUN=0 COMMAND=apply SSH_MODE=reuse SSH_PASSPHRASE_MODE=empty
GPG_MODE=reuse GPG_PASSPHRASE_MODE=empty
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
ssh_keygen_calls="$fixture/keygen-calls"
gh() {
  local IFS=' '
  printf '%s\n' "$*" >> "$fixture/gh-calls"
  [[ $api_ok == yes || $1 != api ]] || return 1
  case "$*" in
    'auth status --hostname github.com') [[ $auth_ok == yes ]] ;;
    'api --hostname github.com user --jq .login') echo tester ;;
    'api --hostname github.com --paginate user/keys --jq .[].key') printf '%s' "$api_keys" ;;
    'api --hostname github.com --paginate user/gpg_keys --jq .[].key_id') printf '%s' "$api_gpg" ;;
    'api --hostname github.com user/emails --jq '*) echo test@example.com ;;
    'api --hostname github.com meta --jq .ssh_keys[]') echo 'ssh-ed25519 AAAATEST' ;;
    *) fail "unexpected gh mutation or request: $*" ;;
  esac
}
ssh-keygen() {
  printf '%s\n' "$*" >> "$ssh_keygen_calls"
  if [[ $1 == -y ]]; then echo 'ssh-ed25519 AAAATEST'; return; fi
  if [[ $1 == -lf ]]; then echo '256 SHA256:TEST public fixture (ED25519)'; return; fi
  if [[ $1 == -F ]]; then awk -v host="$2" '$1 == host { print }' "$4"; return; fi
  local output=''
  while (( $# )); do
    if [[ $1 == -f ]]; then output=$2; shift; fi
    shift
  done
  printf 'fake private test fixture\n' > "$output"
  printf 'ssh-ed25519 AAAATEST\n' > "$output.pub"
}
ensure_github_known_hosts() { :; }
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
gpg() {
  local IFS=' '
  printf '%s\n' "$*" >> "$fixture/gpg-calls"
  case "$*" in
    *--list-secret-keys*) printf 'fpr:::::::::%s:\n' "$GPG_KEY_ID" ;;
    *--list-keys*) printf 'uid:::::::::Test User <test@example.com>:\n' ;;
    '--armor --export '*) printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'PUBLIC FIXTURE' '-----END PGP PUBLIC KEY BLOCK-----' ;;
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
grep -q '^-o ConnectTimeout=15 -o StrictHostKeyChecking=yes -T git@github.com$' "$fixture/ssh-calls" || fail 'ordinary SSH was not tested'
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
# Credential prerequisite installation requests only missing packages.
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
  if [[ $(uname -s) == Darwin ]]; then
    OS_FAMILY=macos
    install_credential_prerequisites
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
