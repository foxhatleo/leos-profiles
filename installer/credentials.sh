#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

install_credential_prerequisites() {
  [[ $SSH_MODE == skip && $GPG_MODE == skip ]] && return 0
  local package tool
  local -a candidates=() missing=()
  case $OS_FAMILY in
    macos)
      if [[ $SSH_MODE != skip ]]; then
        for tool in ssh ssh-keygen ssh-keyscan; do
          [[ -x /usr/bin/$tool ]] || die "macOS system SSH tool is missing: /usr/bin/$tool"
        done
      fi
      command -v gh >/dev/null 2>&1 || missing+=(gh)
      if [[ $GPG_MODE != skip ]] && ! command -v gpg >/dev/null 2>&1; then missing+=(gnupg); fi
      (( ${#missing[@]} > 0 )) || return 0
      ensure_brew
      run brew install "${missing[@]}"
      return ;;
    apt)
      candidates=(gh)
      [[ $SSH_MODE == skip ]] || candidates+=(openssh-client)
      [[ $GPG_MODE == skip ]] || candidates+=(gnupg) ;;
    fedora)
      candidates=(gh)
      [[ $SSH_MODE == skip ]] || candidates+=(openssh-clients)
      [[ $GPG_MODE == skip ]] || candidates+=(gnupg2) ;;
    arch)
      candidates=(github-cli)
      [[ $SSH_MODE == skip ]] || candidates+=(openssh)
      [[ $GPG_MODE == skip ]] || candidates+=(gnupg) ;;
    *) die "Unsupported credential package family: $OS_FAMILY" ;;
  esac
  for package in "${candidates[@]}"; do
    package_installed "$package" || missing+=("$package")
  done
  (( ${#missing[@]} > 0 )) || return 0
  ensure_sudo
  case $OS_FAMILY in
    apt)
      run sudo apt-get update
      run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" ;;
    fedora) run sudo dnf install -y "${missing[@]}" ;;
    arch) run sudo pacman -S --needed --noconfirm "${missing[@]}" ;;
  esac
}

ensure_git_identity() {
  local existing_name existing_email
  existing_name=$(git config --global user.name || true)
  existing_email=$(git config --global user.email || true)
  if [[ -z $existing_name ]]; then
    [[ -n $GIT_NAME ]] || die "GPG provisioning needs a Git name; pass --git-name"
    run git config --global user.name "$GIT_NAME"
    existing_name=$GIT_NAME
  fi
  if [[ -z $existing_email ]]; then
    [[ -n $GIT_EMAIL ]] || die "GPG provisioning needs a Git email; pass --git-email"
    run git config --global user.email "$GIT_EMAIL"
    existing_email=$GIT_EMAIL
  fi
  GIT_NAME=$existing_name
  GIT_EMAIL=$existing_email
}

ssh_public_material() {
  awk 'NF >= 2 { print $1 " " $2; exit }' "$1"
}

github_ssh_key_present() {
  local public_key=$1 material remote_keys
  material=$(ssh_public_material "$public_key")
  [[ -n $material ]] || return 1
  remote_keys=$(gh api --hostname github.com --paginate user/keys --jq '.[].key') \
    || die "Could not list GitHub SSH keys; refusing to guess (check network and gh auth)"
  awk 'NF >= 2 { print $1 " " $2 }' <<< "$remote_keys" | grep -qxF "$material"
}

credential_manual_action() {
  local action=$1 public_path=$2 destination=$3 explanation=$4 field material
  for field in "$action" "$public_path" "$destination"; do
    [[ $field != *$'\t'* && $field != *$'\n'* && $field != *$'\r'* ]] ||
      die "Manual-action fields may not contain tabs or newlines"
  done
  [[ $action =~ ^[a-z][a-z-]+$ ]] || die "Invalid manual action name"
  case $action in
    register-ssh-key)
      material=$(ssh_public_material "$public_path")
      [[ $material == ssh-* || $material == ecdsa-* || $material == sk-* ]] || die "Invalid SSH public material"
      printf 'SSH public key:\n%s\nFingerprint:\n' "$material" >&2
      ssh-keygen -lf "$public_path" >&2 || die "Could not fingerprint public SSH key" ;;
    register-gpg-key)
      if ! grep -qx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$public_path" ||
         ! grep -qx -- '-----END PGP PUBLIC KEY BLOCK-----' "$public_path" ||
         grep -q -- 'PRIVATE KEY' "$public_path"; then die "Invalid public GPG export"; fi
      [[ $GPG_KEY_ID =~ ^[A-Fa-f0-9]{40}$ || $GPG_KEY_ID =~ ^[A-Fa-f0-9]{64}$ ]] || die "Invalid GPG fingerprint"
      printf 'GPG public key (fingerprint %s):\n' "$GPG_KEY_ID" >&2
      cat "$public_path" >&2 ;;
  esac
  printf 'manual-action\t%s\t%s\t%s\n' "$action" "$public_path" "$destination"
  warn "$explanation"
  if [[ ${SSH_MODE:-skip} == generate || ${GPG_MODE:-skip} == generate ]]; then
    warn "Key generation is still pending. After completing the manual action, resume apply with the original approved choices; select reuse for every key already created (SSH: --ssh reuse --ssh-key '$SSH_KEY_PATH' when present). Reconcile will not generate the pending key. Obtain new approval only if the choices change."
  fi
  exit 3
}

ensure_github_auth() {
  gh auth status --hostname github.com >/dev/null 2>&1 && return 0
  credential_manual_action github-login '' https://github.com/login \
    "Authenticate GitHub CLI yourself with gh auth login --hostname github.com, then rerun."
}

verify_github_api() {
  GITHUB_LOGIN=$(gh api --hostname github.com user --jq '.login') || die "GitHub API authentication/connectivity verification failed"
  [[ $GITHUB_LOGIN =~ ^[A-Za-z0-9-]+$ ]] || die "GitHub API returned an invalid account login"
}

github_email_is_verified() {
  local email=$1 verified
  if ! verified=$(gh api --hostname github.com user/emails --jq '.[] | select(.verified == true) | .email' 2>/dev/null); then
    credential_manual_action github-email-scope '' https://github.com/settings/emails \
      "Grant GitHub CLI email-read access yourself with gh auth refresh --hostname github.com -s user:email, then rerun."
  fi
  grep -qxiF "$email" <<< "$verified"
}

ensure_github_known_hosts() {
  local approved scanned verified known_tmp host key_type key material existing
  approved=$(mktemp)
  scanned=$(mktemp)
  verified=$(mktemp)
  track_temp "$approved"
  track_temp "$scanned"
  track_temp "$verified"
  gh api --hostname github.com meta --jq '.ssh_keys[]' > "$approved" || die "Could not obtain GitHub's published SSH host keys"
  ssh-keyscan -T 15 -t rsa,ecdsa,ed25519 github.com > "$scanned" 2>/dev/null ||
    die "Could not scan GitHub SSH host keys"
  # ssh-keyscan output is space-separated; the global IFS ($'\n\t') has no space,
  # so this read must set a space-splitting IFS or the whole line lands in $host.
  while IFS=$' \t' read -r host key_type key _; do
    material="$key_type $key"
    grep -qxF "$material" "$approved" && printf '%s %s %s\n' "$host" "$key_type" "$key" >> "$verified"
  done < "$scanned"
  [[ -s $verified ]] || die "GitHub SSH host keys did not match GitHub's published metadata"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  known_tmp=$(mktemp "$HOME/.ssh/.known-hosts.tmp.XXXXXX")
  track_temp "$known_tmp"
  if [[ -f $HOME/.ssh/known_hosts ]]; then cp "$HOME/.ssh/known_hosts" "$known_tmp"; fi
  while IFS=$' \t' read -r host key_type key; do
    material="$key_type $key"
    existing=$(ssh-keygen -F "$host" -f "$known_tmp" 2>/dev/null | awk 'NF >= 3 && $1 !~ /^#/ { print $2 " " $3 }' || true)
    grep -qxF "$material" <<< "$existing" || printf '%s %s %s\n' "$host" "$key_type" "$key" >> "$known_tmp"
  done < "$verified"
  chmod 600 "$known_tmp"
  mv -f "$known_tmp" "$HOME/.ssh/known_hosts"
}

provision_ssh() {
  [[ $SSH_MODE == skip ]] && return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would prepare the selected SSH key, check registration, and verify selected-key and ordinary GitHub SSH authentication; missing registration requires manual action"
    return 0
  fi
  if [[ $COMMAND == reconcile && $SSH_MODE == generate ]]; then
    credential_manual_action select-ssh-key '' "$PROFILE_FILE" \
      "Reconciliation will not generate credentials. Explicitly select an existing SSH key or approve generation through apply."
  fi
  command -v gh >/dev/null 2>&1 || die "SSH provisioning requires gh; install/authenticate it first"
  ensure_github_auth
  verify_github_api
  local key=${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}
  if [[ $SSH_MODE == reuse ]]; then
    [[ -n $SSH_KEY_PATH && -f $key ]] || die "Chosen SSH private key does not exist: $key"
  else
    [[ ! -e $key && ! -L $key && ! -e $key.pub && ! -L $key.pub ]] ||
      die "Refusing to replace or silently reuse an existing SSH key; select it explicitly with --ssh reuse --ssh-key $key"
    run mkdir -p "$(dirname -- "$key")"
    if [[ $(dirname -- "$key") == "$HOME/.ssh" ]]; then chmod 700 "$HOME/.ssh"; fi
    if [[ $SSH_PASSPHRASE_MODE == prompt ]]; then
      run ssh-keygen -t ed25519 -f "$key"
    else
      warn "Generating $key WITHOUT a passphrase (--ssh-passphrase empty). Anyone who can read the file can use the key."
      run ssh-keygen -t ed25519 -f "$key" -N "" -q
    fi
  fi
  local derived_public
  derived_public=$(mktemp)
  track_temp "$derived_public"
  ssh-keygen -y -f "$key" > "$derived_public"
  if [[ ! -e $key.pub && ! -L $key.pub ]]; then
    mv -f "$derived_public" "$key.pub"
    chmod 644 "$key.pub"
  elif [[ ! -f $key.pub || $(ssh_public_material "$derived_public") != "$(ssh_public_material "$key.pub")" ]]; then
    die "Existing public key does not match the selected private key: $key.pub"
  fi
  SSH_KEY_PATH=$key
  SSH_MODE=reuse
  write_profile
  if ! github_ssh_key_present "$key.pub"; then
    credential_manual_action register-ssh-key "$key.pub" https://github.com/settings/ssh/new \
      "Register this public SSH key yourself on GitHub account $GITHUB_LOGIN: $key.pub. Resume with reconcile when no key generation remains pending."
  fi
  ensure_github_known_hosts
  local ssh_output expected="Hi $GITHUB_LOGIN! You've successfully authenticated"
  ssh_output=$(ssh -i "$key" -F /dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -T git@github.com 2>&1 || true)
  if [[ $ssh_output != *"$expected"* ]]; then
    credential_manual_action verify-ssh-key "$key.pub" https://github.com/settings/keys \
      "The selected SSH key did not authenticate as $GITHUB_LOGIN. Check the selected key and GitHub account, then rerun."
  fi
  ssh_output=$(ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -T git@github.com 2>&1 || true)
  if [[ $ssh_output != *"$expected"* ]]; then
    warn "Effective ordinary SSH settings for github.com:"
    ssh -G github.com 2>/dev/null | awk '$1 == "identityfile" || $1 == "identitiesonly" || $1 == "hostname" || $1 == "user"' >&2 || true
    credential_manual_action configure-ssh-key "$key.pub" "$HOME/.ssh/config" \
      "Ordinary SSH did not authenticate as $GITHUB_LOGIN. Configure github.com IdentityFile for $key and IdentitiesOnly yes yourself (or your agent), then rerun. No SSH or Git protocol configuration was changed."
  fi
}

gpg_secret_fingerprint() {
  gpg --batch --with-colons --list-secret-keys "$1" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}'
}

gpg_key_has_email() {
  local fingerprint=$1 email=$2
  gpg --batch --with-colons --list-keys "$fingerprint" 2>/dev/null | awk -F: -v email="<$email>" '
    BEGIN { email=tolower(email) }
    /^uid:/ && index(tolower($10), email) { found=1 }
    END { exit !found }
  '
}

github_gpg_key_present() {
  local fingerprint=$1 remote_ids
  remote_ids=$(gh api --hostname github.com --paginate user/gpg_keys --jq '.[].key_id') \
    || die "Could not list GitHub GPG keys; refusing to guess (check network and gh auth)"
  awk -v fingerprint="$fingerprint" '
    BEGIN { fingerprint=toupper(fingerprint) }
    {
      remote=toupper($0)
      if (remote ~ /^[0-9A-F]+$/ && length(remote) == 16 && length(remote) <= length(fingerprint) &&
          substr(fingerprint, length(fingerprint) - length(remote) + 1) == remote) found=1
    }
    END { exit !found }
  ' <<< "$remote_ids"
}

provision_gpg() {
  [[ $GPG_MODE == skip ]] && return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would prepare the selected GPG key, verify signing and registration, and enable commit signing; missing registration requires manual action"
    return 0
  fi
  if [[ $COMMAND == reconcile && $GPG_MODE == generate ]]; then
    credential_manual_action select-gpg-key '' "$PROFILE_FILE" \
      "Reconciliation will not generate credentials. Explicitly select an existing GPG fingerprint or approve generation through apply."
  fi
  command -v gpg >/dev/null 2>&1 || die "GPG provisioning requires gpg; install it first"
  command -v gh >/dev/null 2>&1 || die "GPG provisioning requires gh; install/authenticate it first"
  ensure_github_auth
  verify_github_api
  ensure_git_identity
  local name email keyid="" creation_output exported_key
  name=$(git config --global user.name || true)
  email=$(git config --global user.email || true)
  [[ -n $name && -n $email ]] || die "Set global git user.name and user.email before GPG provisioning"
  github_email_is_verified "$email" || die "Git email is not verified on the authenticated GitHub account: $email"
  if [[ $GPG_MODE == reuse ]]; then
    [[ $GPG_KEY_ID =~ ^[A-Fa-f0-9]{40}$ || $GPG_KEY_ID =~ ^[A-Fa-f0-9]{64}$ ]] || die "Select a full GPG fingerprint"
    keyid=$(gpg_secret_fingerprint "$GPG_KEY_ID")
    [[ $(printf '%s' "$keyid" | tr '[:lower:]' '[:upper:]') == "$(printf '%s' "$GPG_KEY_ID" | tr '[:lower:]' '[:upper:]')" ]] || die "GPG returned a different key from the selected fingerprint"
    [[ -n $keyid ]] || die "The selected GPG secret key was not found: $GPG_KEY_ID"
  else
    if [[ $GPG_PASSPHRASE_MODE == prompt ]]; then
      creation_output=$(gpg --status-fd 1 --quick-generate-key "$name <$email>" ed25519 sign never)
    else
      warn "Creating a GPG signing key WITHOUT a passphrase (--gpg-passphrase empty). Anyone who can read your keyring can sign as you."
      creation_output=$(gpg --batch --status-fd 1 --pinentry-mode loopback --passphrase '' --quick-generate-key "$name <$email>" ed25519 sign never)
    fi
    keyid=$(awk '$2 == "KEY_CREATED" {print $4; exit}' <<< "$creation_output")
  fi
  [[ $keyid =~ ^[A-Fa-f0-9]{40}$ || $keyid =~ ^[A-Fa-f0-9]{64}$ ]] || die "No valid GPG fingerprint found"
  gpg_key_has_email "$keyid" "$email" || die "Selected GPG key has no user ID for the Git email $email"
  # Save the fingerprint before signing/upload verification so a partial
  # failure retries this exact key instead of creating another one.
  GPG_KEY_ID=$keyid
  GPG_MODE=reuse
  write_profile
  local temp_repo
  temp_repo=$(mktemp -d)
  track_temp "$temp_repo"
  git -C "$temp_repo" init -q
  git -C "$temp_repo" config user.name "$name"
  git -C "$temp_repo" config user.email "$email"
  git -C "$temp_repo" config gpg.format openpgp
  git -C "$temp_repo" config user.signingkey "$keyid"
  git -C "$temp_repo" config commit.gpgsign true
  if ! git -C "$temp_repo" commit --allow-empty -S -m 'Verify Leo profiles signing setup' >/dev/null; then
    rm -rf "$temp_repo"
    die "GPG key cannot sign a Git commit"
  fi
  rm -rf "$temp_repo"
  if ! github_gpg_key_present "$keyid"; then
    prepare_local_dir
    exported_key="$LOCAL_DIR/gpg-public-$keyid.asc"
    local export_tmp
    export_tmp=$(mktemp "$LOCAL_DIR/.gpg-public.XXXXXX")
    track_temp "$export_tmp"
    gpg --armor --export "$keyid" > "$export_tmp"
    [[ -s $export_tmp ]] || die "GPG did not export public key material"
    chmod 600 "$export_tmp"
    mv -f "$export_tmp" "$exported_key"
    credential_manual_action register-gpg-key "$exported_key" https://github.com/settings/gpg/new \
      "Register this public GPG key yourself on GitHub account $GITHUB_LOGIN: $exported_key. Then rerun reconcile; global commit signing is not enabled until registration is verified."
  fi
  git config --global user.signingkey "$keyid"
  git config --global gpg.format openpgp
  git config --global commit.gpgsign true
}
