#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

# ---------------------------------------------------------------------------
# pinentry (MI-1). A GPG key with a passphrase asks for it through
# gpg-agent's pinentry. Commits from an IDE, a GUI or an agent have no
# terminal, so GPG commit signing and prompt passphrases get a pinentry that
# needs none: pinentry-mac on macOS, pinentry-gnome3 in a Linux desktop
# session, pinentry-curses elsewhere. A managed block in gpg-agent.conf
# selects it.
gpg_pinentry_needed() {
  [[ ${GPG_MODE:-skip} != skip ]] || return 1
  [[ ${SIGNING_MODE:-skip} == gpg || ${GPG_PASSPHRASE_MODE:-empty} == prompt ]]
}

linux_desktop_session() {
  [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-}${XDG_CURRENT_DESKTOP:-} ]]
}

# The packages providing the pinentry, space-separated. Arch's pinentry
# holds every front end; its GNOME one needs gcr-4 at run time.
pinentry_packages() {
  case $OS_FAMILY in
    macos) printf 'pinentry-mac' ;;
    apt) if linux_desktop_session; then printf 'pinentry-gnome3'; else printf 'pinentry-curses'; fi ;;
    fedora) if linux_desktop_session; then printf 'pinentry-gnome3'; else printf 'pinentry'; fi ;;
    arch) if linux_desktop_session; then printf 'pinentry gcr-4'; else printf 'pinentry'; fi ;;
  esac
}

pinentry_program() {
  local prefix=${HOMEBREW_PREFIX:-}
  if [[ $OS_FAMILY == macos ]]; then
    [[ -n $prefix ]] || prefix=$(brew --prefix 2>/dev/null) || prefix=""
    printf '%s/bin/pinentry-mac\n' "${prefix:-/opt/homebrew}"
  elif linux_desktop_session; then
    printf '/usr/bin/pinentry-gnome3\n'
  else
    printf '/usr/bin/pinentry-curses\n'
  fi
}

gpg_agent_conf_path() { printf '%s/gpg-agent.conf\n' "${GNUPGHOME:-$HOME/.gnupg}"; }

# ensure_gpg_pinentry: point gpg-agent at the pinentry through a managed
# `pinentry` block, and restart the agent when that changed it. A
# pinentry-program the user set outside the block is theirs and wins.
ensure_gpg_pinentry() {
  gpg_pinentry_needed || return 0
  local conf home=${GNUPGHOME:-$HOME/.gnupg} program content
  conf=$(gpg_agent_conf_path)
  if [[ -f $conf ]] && strip_block pinentry "$(resolve_config_path "$conf")" |
      grep -Eq '^[[:space:]]*pinentry-program[[:space:]]'; then
    say "Keeping the pinentry-program already set in $conf"
    return 0
  fi
  program=$(pinentry_program)
  [[ -x $program ]] || die "The pinentry for GPG passphrases is not installed: $program"
  content="pinentry-program $program"
  managed_block_equals "$conf" pinentry "$content" && return 0
  if [[ ! -d $home ]]; then (umask 077 && mkdir -p "$home"); fi
  install_managed_block "$conf" pinentry "$content"
  # gpg-agent reads its configuration only when it starts.
  gpgconf --kill gpg-agent >/dev/null 2>&1 || true
  say "GPG passphrases are asked for by $program (managed block in $conf)"
}

# ---------------------------------------------------------------------------
# credential_package_candidates: the Linux packages the selected credential
# modes need, one per line.
credential_package_candidates() {
  case $OS_FAMILY in
    apt) printf '%s\n' gh; [[ $SSH_MODE == skip ]] || printf '%s\n' openssh-client
      [[ $GPG_MODE == skip ]] || printf '%s\n' gnupg ;;
    fedora) printf '%s\n' gh; [[ $SSH_MODE == skip ]] || printf '%s\n' openssh-clients
      [[ $GPG_MODE == skip ]] || printf '%s\n' gnupg2 ;;
    arch) printf '%s\n' github-cli; [[ $SSH_MODE == skip ]] || printf '%s\n' openssh
      [[ $GPG_MODE == skip ]] || printf '%s\n' gnupg ;;
    *) return 0 ;;
  esac
  if gpg_pinentry_needed; then
    # shellcheck disable=SC2046  # a space-separated package list
    printf '%s\n' $(pinentry_packages)
  fi
}

# credential_prerequisites_missing: on Linux, the credential packages this
# host lacks, space-separated (they install as root).
credential_prerequisites_missing() {
  [[ $SSH_MODE == skip && $GPG_MODE == skip ]] && return 0
  local package missing=""
  while IFS= read -r package; do
    package_installed "$package" || missing+=" $package"
  done < <(credential_package_candidates)
  printf '%s' "${missing# }"
}

install_credential_prerequisites() {
  [[ $SSH_MODE == skip && $GPG_MODE == skip ]] && return 0
  local package tool
  local -a missing=()
  case $OS_FAMILY in
    macos)
      if [[ $SSH_MODE != skip ]]; then
        for tool in ssh ssh-keygen ssh-keyscan ssh-add; do
          [[ -x /usr/bin/$tool ]] || die "macOS system SSH tool is missing: /usr/bin/$tool"
        done
      fi
      command -v gh >/dev/null 2>&1 || missing+=(gh)
      if [[ $GPG_MODE != skip ]] && ! command -v gpg >/dev/null 2>&1; then missing+=(gnupg); fi
      if gpg_pinentry_needed && [[ ! -x $(pinentry_program) ]]; then missing+=(pinentry-mac); fi
      pkg_install ${missing[@]+"${missing[@]}"}
      return ;;
    apt|fedora|arch) ;;
    *) die "Unsupported credential package family: $OS_FAMILY" ;;
  esac
  while IFS= read -r package; do
    package_installed "$package" || missing+=("$package")
  done < <(credential_package_candidates)
  (( ${#missing[@]} > 0 )) || return 0
  ensure_sudo
  pkg_install "${missing[@]}"
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

# github_list <endpoint> <jq filter>: every page of a read-only GitHub API
# list, one jq result per line. Status 0 on success; 2 when the token lacks
# the scope the endpoint needs; 1 for anything else. gh exits 1 for every
# failure, so the two are told apart by its message: a missing OAuth scope is
# an HTTP 404 (or 403) that names the scope ("This API operation needs the
# "admin:public_key" scope", from the X-Accepted-OAuth-Scopes header), and a
# fine-grained token without the permission is a 403 "Resource not accessible
# by ... token". A network error, a 5xx, or a 403 rate limit names neither,
# and stays an error: it is never evidence that a key is missing (ONB-2).
github_list() {
  local endpoint=$1 filter=$2 errors output status=0
  errors=$(mktemp "${TMPDIR:-/tmp}/leos-gh.XXXXXX")
  output=$(gh api --hostname github.com --paginate "$endpoint" --jq "$filter" 2> "$errors") || status=$?
  if (( status == 0 )); then
    rm -f -- "$errors"
    [[ -z $output ]] || printf '%s\n' "$output"
    return 0
  fi
  sed 's/^/  gh: /' "$errors" >&2
  if grep -Eq 'HTTP 40[34]' "$errors" && grep -Eqi 'scope|resource not accessible' "$errors"; then
    status=2
  else
    status=1
  fi
  rm -f -- "$errors"
  return "$status"
}

# The read scopes the selected credential modes need for listing keys.
github_key_scopes() {
  local scopes=""
  [[ ${SSH_MODE:-skip} == skip ]] || scopes+=",read:public_key"
  [[ ${GPG_MODE:-skip} == skip ]] || scopes+=",read:gpg_key"
  [[ ${SIGNING_MODE:-skip} != ssh ]] || scopes+=",read:ssh_signing_key"
  printf '%s' "${scopes#,}"
}

# github_list_failed <status> <endpoint> <description>: a scope problem is a
# manual action (exit 3); any other failure is an error.
github_list_failed() {
  local status=$1 endpoint=$2 description=$3 scopes refresh
  if [[ $status == 2 ]]; then
    scopes=$(github_key_scopes)
    case $endpoint in
      user/keys) [[ ,$scopes, == *,read:public_key,* ]] || scopes+=",read:public_key" ;;
      user/gpg_keys) [[ ,$scopes, == *,read:gpg_key,* ]] || scopes+=",read:gpg_key" ;;
      user/ssh_signing_keys) [[ ,$scopes, == *,read:ssh_signing_key,* ]] || scopes+=",read:ssh_signing_key" ;;
    esac
    refresh="gh auth refresh -h github.com -s ${scopes#,}"
    credential_manual_action github-key-scope '' "$refresh" \
      "GitHub CLI's token may not read your $description ($endpoint answered HTTP 403/404 for a missing scope). Grant read-only access yourself with: $refresh (a GITHUB_TOKEN in the environment needs the same read permissions), then rerun. Nothing was uploaded."
  fi
  die "Could not list GitHub $description; refusing to guess (check network and gh auth)"
}

github_ssh_key_present() {
  local public_key=$1 material remote_keys status=0
  material=$(ssh_public_material "$public_key")
  [[ -n $material ]] || return 1
  remote_keys=$(github_list user/keys '.[].key') || status=$?
  (( status == 0 )) || github_list_failed "$status" user/keys "SSH keys"
  awk 'NF >= 2 { print $1 " " $2 }' <<< "$remote_keys" | grep -qxF "$material"
}

# Manual actions end the run with status 3. A component that needs one (a
# missing chsh, a font to install on the Windows side of WSL) queues it and
# the run goes on; finish_manual_actions then prints every queued
# `manual-action` record on stdout, repeats the explanations and exits 3. A
# credential pause queues its own action and finishes at once (ONB-4).
PENDING_MANUAL_ACTIONS=""
PENDING_MANUAL_EXPLANATIONS=""
STEP_AWAITS_MANUAL_ACTION=0

# queue_manual_action <action> <public path> <destination> <explanation>
queue_manual_action() {
  local action=$1 public_path=$2 destination=$3 explanation=$4 field
  for field in "$action" "$public_path" "$destination"; do
    [[ $field != *$'\t'* && $field != *$'\n'* && $field != *$'\r'* ]] ||
      die "Manual-action fields may not contain tabs or newlines"
  done
  [[ $action =~ ^[a-z][a-z-]+$ ]] || die "Invalid manual action name"
  PENDING_MANUAL_ACTIONS+=$(printf 'manual-action\t%s\t%s\t%s' "$action" "$public_path" "$destination")$'\n'
  PENDING_MANUAL_EXPLANATIONS+="${explanation//$'\n'/ }"$'\n'
  warn "$explanation"
}

finish_manual_actions() {
  [[ -n $PENDING_MANUAL_ACTIONS ]] || return 0
  printf '%s' "$PENDING_MANUAL_ACTIONS"
  warn "Manual action required (exit 3). Complete each manual-action record above, then resume with: bash $TARGET/install.sh reconcile --yes"
  printf '%s' "$PENDING_MANUAL_EXPLANATIONS" | sed 's/^/  - /' >&2
  exit 3
}

credential_manual_action() {
  local action=$1 public_path=$2 destination=$3 explanation=$4 field material
  for field in "$action" "$public_path" "$destination"; do
    [[ $field != *$'\t'* && $field != *$'\n'* && $field != *$'\r'* ]] ||
      die "Manual-action fields may not contain tabs or newlines"
  done
  [[ $action =~ ^[a-z][a-z-]+$ ]] || die "Invalid manual action name"
  case $action in
    register-ssh-key|register-ssh-signing-key)
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
  queue_manual_action "$action" "$public_path" "$destination" "$explanation"
  if [[ ${SSH_MODE:-skip} == generate || ${GPG_MODE:-skip} == generate ]]; then
    local created=""
    [[ ${SSH_MODE:-skip} != reuse || -z ${SSH_KEY_PATH:-} ]] || created+=" SSH: --ssh reuse --ssh-key '$SSH_KEY_PATH'."
    [[ ${GPG_MODE:-skip} != reuse || -z ${GPG_KEY_ID:-} ]] || created+=" GPG: --gpg reuse --gpg-key $GPG_KEY_ID."
    warn "Key generation is still pending. After completing the manual action, resume apply with the original approved choices; select reuse for every key already created.${created} Reconcile will not generate the pending key. Obtain new approval only if the choices change."
  fi
  finish_manual_actions
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
  local email=$1 verified status=0
  verified=$(github_list user/emails '.[] | select(.verified == true) | .email') || status=$?
  if [[ $status == 2 ]]; then
    credential_manual_action github-email-scope '' https://github.com/settings/emails \
      "Grant GitHub CLI email-read access yourself with gh auth refresh --hostname github.com -s user:email, then rerun."
  fi
  (( status == 0 )) || die "Could not read the GitHub account's email addresses; refusing to guess (check network and gh auth)"
  grep -qxiF "$email" <<< "$verified"
}

ensure_github_known_hosts() {
  local approved scanned verified known_hosts known_tmp mode host key_type key material existing
  approved=$(mktemp)
  scanned=$(mktemp)
  verified=$(mktemp)
  track_temp "$approved"
  track_temp "$scanned"
  track_temp "$verified"
  gh api --hostname github.com meta --jq '.ssh_keys[]' > "$approved" || die "Could not obtain GitHub's published SSH host keys"
  ssh-keyscan -T 15 -t rsa,ecdsa,ed25519 github.com > "$scanned" 2>/dev/null ||
    die "Could not scan GitHub SSH host keys"
  # ssh-keyscan output is space-separated; say so explicitly rather than rely
  # on whatever IFS the caller has.
  while IFS=$' \t' read -r host key_type key _; do
    material="$key_type $key"
    grep -qxF "$material" "$approved" && printf '%s %s %s\n' "$host" "$key_type" "$key" >> "$verified"
  done < "$scanned"
  [[ -s $verified ]] || die "GitHub SSH host keys did not match GitHub's published metadata"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  # A symlinked known_hosts (dotfiles managers) is updated where it points;
  # the link stays (SEC-7).
  known_hosts=$(resolve_config_path "$HOME/.ssh/known_hosts")
  mkdir -p "$(dirname -- "$known_hosts")"
  known_tmp=$(mktemp "$(dirname -- "$known_hosts")/.known-hosts.tmp.XXXXXX")
  track_temp "$known_tmp"
  track_temp "$known_tmp.old"
  mode=600
  if [[ -f $known_hosts ]]; then
    cp "$known_hosts" "$known_tmp"
    mode=$(file_mode "$known_hosts")
  fi
  # Drop every github.com entry first, so a rotated or revoked host key (the
  # RSA key GitHub replaced in 2023) does not stay trusted next to the
  # verified ones (SEC-7). ssh-keygen -R handles hashed entries too; it
  # leaves the previous contents in <file>.old.
  ssh-keygen -R github.com -f "$known_tmp" >/dev/null 2>&1 ||
    die "Could not remove old github.com entries from a copy of $known_hosts"
  rm -f -- "$known_tmp.old"
  while IFS=$' \t' read -r host key_type key; do
    material="$key_type $key"
    existing=$(ssh-keygen -F "$host" -f "$known_tmp" 2>/dev/null | awk 'NF >= 3 && $1 !~ /^#/ { print $2 " " $3 }' || true)
    grep -qxF "$material" <<< "$existing" || printf '%s %s %s\n' "$host" "$key_type" "$key" >> "$known_tmp"
  done < "$verified"
  chmod "$mode" "$known_tmp"
  mv -f "$known_tmp" "$known_hosts"
}

# The public half of the selected SSH identity: <key>.pub for a key file, or
# the agent identity's public key saved under local/ (agent mode has no file).
SSH_PUBLIC_KEY=""
SSH_KEY_ENCRYPTED=0

ssh_agent_public_key_path() { printf '%s\n' "$LOCAL_DIR/ssh-agent-key.pub"; }

# ssh_agent_select <selector> (MI-7): choose the one key the running agent
# (ssh-agent, 1Password, Secretive, ...) lists whose SHA256 fingerprint,
# comment, "type base64" material or whole public-key line equals the
# selector. Never picks a key on its own: no match or several matches stop.
# Saves the public key to local/ and leaves its fingerprint in SSH_KEY_PATH.
ssh_agent_select() {
  local selector=$1 listing line candidate material comment fingerprint status=0
  local chosen_fingerprint="" chosen_line="" count=0 available="" public_tmp
  [[ -n ${SSH_AUTH_SOCK:-} ]] || die "--ssh agent needs a running SSH agent, but SSH_AUTH_SOCK is not set"
  [[ -S $SSH_AUTH_SOCK ]] || die "--ssh agent: SSH_AUTH_SOCK is not a socket: $SSH_AUTH_SOCK"
  listing=$(ssh-add -L 2>/dev/null) || status=$?
  case $status in
    0) ;;
    1) die "The SSH agent at $SSH_AUTH_SOCK holds no keys (ssh-add -L). Add or unlock the key in your agent, then rerun." ;;
    *) die "Could not reach the SSH agent at $SSH_AUTH_SOCK (ssh-add -L exited $status)" ;;
  esac
  candidate=$(mktemp "${TMPDIR:-/tmp}/leos-agent-key.XXXXXX")
  track_temp "$candidate"
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    printf '%s\n' "$line" > "$candidate"
    fingerprint=$(ssh-keygen -lf "$candidate" 2>/dev/null | awk '{ print $2; exit }' || true)
    [[ -n $fingerprint ]] || continue
    material=$(ssh_public_material "$candidate")
    comment=$(awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }' "$candidate")
    available+=" $fingerprint${comment:+ ($comment)};"
    if [[ $selector == "$fingerprint" || $selector == "$material" || $selector == "$line" ||
          ( -n $comment && $selector == "$comment" ) ]]; then
      count=$((count + 1))
      chosen_fingerprint=$fingerprint
      chosen_line=$line
    fi
  done <<< "$listing"
  (( count > 0 )) || die "No key in the SSH agent matches --ssh-key '$selector'. The agent holds:${available%;}"
  (( count == 1 )) || die "--ssh-key '$selector' matches $count agent keys; select one by its SHA256 fingerprint. The agent holds:${available%;}"
  prepare_local_dir
  SSH_PUBLIC_KEY=$(ssh_agent_public_key_path)
  public_tmp=$(mktemp "$LOCAL_DIR/.ssh-agent-key.XXXXXX")
  track_temp "$public_tmp"
  printf '%s\n' "$chosen_line" > "$public_tmp"
  chmod 600 "$public_tmp"
  mv -f "$public_tmp" "$SSH_PUBLIC_KEY"
  SSH_KEY_PATH=$chosen_fingerprint
}

# ssh_verification_options: the options of the two GitHub SSH checks, in
# SSH_VERIFY_OPTIONS. BatchMode keeps them from ever waiting for input
# (SEC-1); the one exception is a passphrase-protected key file on a
# terminal, which ssh unlocks by asking, as it always did.
SSH_VERIFY_OPTIONS=()
ssh_verification_options() {
  SSH_VERIFY_OPTIONS=(-o ConnectTimeout=15 -o StrictHostKeyChecking=yes)
  if [[ $SSH_KEY_ENCRYPTED -eq 1 ]] && stdin_is_terminal; then return 0; fi
  SSH_VERIFY_OPTIONS+=(-o BatchMode=yes)
}

# The opt-in (--ssh-config yes) managed block in ~/.ssh/config. It is
# appended, so the user's own earlier settings for github.com still win.
ssh_config_block_content() {
  printf '%s\n' 'Host github.com' '  AddKeysToAgent yes'
  [[ ${OS_FAMILY:-} != macos ]] || printf '%s\n' '  UseKeychain yes'
  if [[ $SSH_MODE != agent && -n $SSH_KEY_PATH ]]; then
    printf '  IdentityFile "%s"\n' "$SSH_KEY_PATH"
  fi
}

install_ssh_config_block() {
  [[ ${SSH_CONFIG:-no} == yes ]] || return 0
  local content created=0
  [[ $SSH_KEY_PATH != *'"'* ]] || die "Cannot write an IdentityFile for a path containing a double quote: $SSH_KEY_PATH"
  content=$(ssh_config_block_content)
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  [[ -e $(resolve_config_path "$HOME/.ssh/config") ]] || created=1
  install_managed_block "$HOME/.ssh/config" ssh-config "$content"
  # A config this run created is private; an existing one keeps its mode.
  if [[ $created -eq 1 ]]; then chmod 600 "$(resolve_config_path "$HOME/.ssh/config")"; fi
  say "Managed github.com block in $HOME/.ssh/config: AddKeysToAgent$([[ ${OS_FAMILY:-} != macos ]] || printf ', UseKeychain')$([[ $SSH_MODE == agent ]] || printf ', IdentityFile %s' "$SSH_KEY_PATH") (--ssh-config yes)"
}

provision_ssh() {
  [[ $SSH_MODE == skip ]] && return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would prepare the selected SSH key, check registration, and verify selected-key and ordinary GitHub SSH authentication; missing registration requires manual action"
    if [[ ${SSH_CONFIG:-no} == yes ]]; then say "Would install the managed github.com block in $HOME/.ssh/config (--ssh-config yes)"; fi
    return 0
  fi
  if [[ $COMMAND == reconcile && $SSH_MODE == generate ]]; then
    credential_manual_action select-ssh-key '' "$PROFILE_FILE" \
      "Reconciliation will not generate credentials. Explicitly select an existing SSH key or approve generation through apply."
  fi
  command -v gh >/dev/null 2>&1 || die "SSH provisioning requires gh; install/authenticate it first"
  ensure_github_auth
  verify_github_api
  SSH_KEY_ENCRYPTED=0
  local key=${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519} identity
  local -a selected_identity=()
  if [[ $SSH_MODE == agent ]]; then
    ssh_agent_select "$SSH_KEY_PATH"
    write_profile
    identity="the agent key $SSH_KEY_PATH"
    # -i with the public key makes ssh use exactly that agent identity.
    selected_identity=(-i "$SSH_PUBLIC_KEY" -o "IdentityAgent=$SSH_AUTH_SOCK")
  else
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
        warn "Generating $key WITHOUT a passphrase (--ssh-passphrase empty). Anyone who can read the file can use the key; prefer --ssh-passphrase prompt (macOS: --ssh-config yes keeps it in the Keychain)."
        run ssh-keygen -t ed25519 -f "$key" -N "" -q
      fi
    fi
    # An empty passphrase that does not open the key means it has one.
    ssh-keygen -y -P '' -f "$key" >/dev/null 2>&1 || SSH_KEY_ENCRYPTED=1
    local derived_public
    derived_public=$(mktemp)
    track_temp "$derived_public"
    ssh-keygen -y -f "$key" > "$derived_public" ||
      die "Could not read the public half of $key (a passphrase-protected key needs a terminal)"
    if [[ ! -e $key.pub && ! -L $key.pub ]]; then
      mv -f "$derived_public" "$key.pub"
      chmod 644 "$key.pub"
    elif [[ ! -f $key.pub || $(ssh_public_material "$derived_public") != "$(ssh_public_material "$key.pub")" ]]; then
      die "Existing public key does not match the selected private key: $key.pub"
    fi
    SSH_KEY_PATH=$key
    SSH_PUBLIC_KEY=$key.pub
    SSH_MODE=reuse
    write_profile
    identity=$key
    selected_identity=(-i "$key")
  fi
  if ! github_ssh_key_present "$SSH_PUBLIC_KEY"; then
    credential_manual_action register-ssh-key "$SSH_PUBLIC_KEY" https://github.com/settings/ssh/new \
      "Register this public SSH key yourself on GitHub account $GITHUB_LOGIN: $SSH_PUBLIC_KEY (or: gh ssh-key add $SSH_PUBLIC_KEY --type authentication, which needs the admin:public_key scope). Resume with reconcile when no key generation remains pending."
  fi
  ensure_github_known_hosts
  ssh_verification_options
  local ssh_output expected="Hi $GITHUB_LOGIN! You've successfully authenticated" hint=""
  ssh_output=$(ssh "${selected_identity[@]}" -F /dev/null -o IdentitiesOnly=yes "${SSH_VERIFY_OPTIONS[@]}" -T git@github.com 2>&1 || true)
  if [[ $ssh_output != *"$expected"* ]]; then
    if [[ $SSH_KEY_ENCRYPTED -eq 1 ]]; then hint=" The key has a passphrase: add it to your agent (ssh-add) or run the installer in a terminal."; fi
    credential_manual_action verify-ssh-key "$SSH_PUBLIC_KEY" https://github.com/settings/keys \
      "The selected SSH key ($identity) did not authenticate as $GITHUB_LOGIN.$hint Check the selected key and GitHub account, then rerun."
  fi
  install_ssh_config_block
  ssh_output=$(ssh "${SSH_VERIFY_OPTIONS[@]}" -T git@github.com 2>&1 || true)
  if [[ $ssh_output != *"$expected"* ]]; then
    warn "Effective ordinary SSH settings for github.com:"
    ssh -G github.com 2>/dev/null | awk '$1 == "identityfile" || $1 == "identitiesonly" || $1 == "identityagent" || $1 == "hostname" || $1 == "user"' >&2 || true
    if [[ $SSH_MODE == agent ]]; then
      hint="Make ordinary SSH use the agent for github.com (SSH_AUTH_SOCK, or IdentityAgent in ~/.ssh/config)"
    else
      hint="Configure github.com IdentityFile for $key and IdentitiesOnly yes yourself (or load it into your agent)"
    fi
    local changed="No SSH or Git protocol configuration was changed."
    [[ ${SSH_CONFIG:-no} != yes ]] || changed="Only the managed github.com block in ~/.ssh/config was written; your earlier settings for github.com take precedence over it."
    credential_manual_action configure-ssh-key "$SSH_PUBLIC_KEY" "$HOME/.ssh/config" \
      "Ordinary SSH did not authenticate as $GITHUB_LOGIN. $hint, then rerun. $changed"
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
  local fingerprint=$1 remote_ids status=0
  remote_ids=$(github_list user/gpg_keys '.[].key_id') || status=$?
  (( status == 0 )) || github_list_failed "$status" user/gpg_keys "GPG keys"
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

# saved_profile_value <key>: one value from the saved profile as it is on
# disk now (before this run rewrites it), or nothing.
saved_profile_value() {
  [[ -f $PROFILE_FILE ]] || return 0
  awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$PROFILE_FILE"
}

# A generated GPG key is saved as gpg=reuse with its fingerprint before
# anything else can fail. Like an existing SSH key file, it is never replaced
# or silently reused: a later `--gpg generate` stops, before the run changes
# anything (preflight calls this before the profile is rewritten), and names
# the saved key to select instead. Once that key has left the keyring,
# generating again creates no second key and is allowed.
gpg_generation_guard() {
  [[ $GPG_MODE == generate ]] || return 0
  local saved_mode saved_key
  saved_mode=$(saved_profile_value gpg)
  saved_key=$(saved_profile_value gpg-key)
  [[ $saved_mode == reuse ]] || return 0
  [[ $saved_key =~ ^[A-Fa-f0-9]{40}$ || $saved_key =~ ^[A-Fa-f0-9]{64}$ ]] || return 0
  if command -v gpg >/dev/null 2>&1 && [[ -z $(gpg_secret_fingerprint "$saved_key" || true) ]]; then
    return 0
  fi
  die "Refusing to generate a second GPG key: this profile already holds $saved_key. Select it explicitly with --gpg reuse --gpg-key $saved_key"
}

provision_gpg() {
  [[ $GPG_MODE == skip ]] && return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would prepare the selected GPG key, verify signing and registration$([[ $SIGNING_MODE != gpg ]] || printf ', and enable commit signing'); missing registration requires manual action"
    if gpg_pinentry_needed; then say "Would set pinentry-program $(pinentry_program) in a managed block of $(gpg_agent_conf_path)"; fi
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
  # ensure_git_identity leaves the effective global identity in
  # GIT_NAME/GIT_EMAIL, so it is not read again here (CQ-2).
  ensure_git_identity
  local name=$GIT_NAME email=$GIT_EMAIL keyid="" creation_output exported_key
  [[ -n $name && -n $email ]] || die "Set global git user.name and user.email before GPG provisioning"
  github_email_is_verified "$email" || die "Git email is not verified on the authenticated GitHub account: $email"
  # Before a prompt-mode key asks for its passphrase, so it already uses it.
  ensure_gpg_pinentry
  if [[ $GPG_MODE == reuse ]]; then
    [[ $GPG_KEY_ID =~ ^[A-Fa-f0-9]{40}$ || $GPG_KEY_ID =~ ^[A-Fa-f0-9]{64}$ ]] || die "Select a full GPG fingerprint"
    # gpg exits non-zero for an unknown key; that is the "not found" case
    # below, not a silent errexit.
    keyid=$(gpg_secret_fingerprint "$GPG_KEY_ID" || true)
    [[ -n $keyid ]] || die "The selected GPG secret key was not found in the keyring (${GNUPGHOME:-~/.gnupg}): $GPG_KEY_ID"
    [[ $(printf '%s' "$keyid" | tr '[:lower:]' '[:upper:]') == "$(printf '%s' "$GPG_KEY_ID" | tr '[:lower:]' '[:upper:]')" ]] || die "GPG returned a different key ($keyid) from the selected fingerprint $GPG_KEY_ID"
  else
    if [[ $GPG_PASSPHRASE_MODE == prompt ]]; then
      creation_output=$(gpg --status-fd 1 --quick-generate-key "$name <$email>" ed25519 sign "$GPG_EXPIRY")
    else
      warn "Creating a GPG signing key WITHOUT a passphrase (--gpg-passphrase empty). Anyone who can read your keyring can sign as you."
      creation_output=$(gpg --batch --status-fd 1 --pinentry-mode loopback --passphrase '' --quick-generate-key "$name <$email>" ed25519 sign "$GPG_EXPIRY")
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
    # Never leave secret material at the path a manual action shows.
    ! grep -q -- 'PRIVATE KEY' "$export_tmp" || die "GPG export contained private key material; refusing to save it"
    chmod 600 "$export_tmp"
    mv -f "$export_tmp" "$exported_key"
    local after="Then rerun reconcile."
    [[ $SIGNING_MODE != gpg ]] || after="Then rerun reconcile; global commit signing is not enabled until registration is verified."
    credential_manual_action register-gpg-key "$exported_key" https://github.com/settings/gpg/new \
      "Register this public GPG key yourself on GitHub account $GITHUB_LOGIN: $exported_key (or: gh gpg-key add $exported_key, which needs the admin:gpg_key scope). $after"
  fi
  # --signing skip or ssh: the key is ready, the signing settings are not ours.
  [[ $SIGNING_MODE == gpg ]] || return 0
  git config --global user.signingkey "$keyid"
  git config --global gpg.format openpgp
  git config --global commit.gpgsign true
}

# ---------------------------------------------------------------------------
# SSH commit signing (MI-2): Git signs with the selected SSH key
# (gpg.format ssh), verifies with an allowed-signers file this checkout
# manages, and GitHub shows the commits as verified once the same public key
# is registered as a *signing* key, a separate registration from the
# authentication key.
allowed_signers_path() { printf '%s\n' "$LOCAL_DIR/allowed_signers"; }

# user.signingkey for the selected key: a key file's public key, from which
# ssh-keygen -Y sign finds the private key beside it (or the agent's copy),
# or for an agent key the literal key:: form, which signs through the agent.
ssh_signing_key_value() {
  if [[ $SSH_MODE == agent ]]; then
    printf 'key::%s\n' "$(ssh_public_material "$SSH_PUBLIC_KEY")"
  else
    printf '%s\n' "$SSH_PUBLIC_KEY"
  fi
}

github_ssh_signing_key_present() {
  local material remote_keys status=0
  material=$(ssh_public_material "$1")
  [[ -n $material ]] || return 1
  remote_keys=$(github_list user/ssh_signing_keys '.[].key') || status=$?
  (( status == 0 )) || github_list_failed "$status" user/ssh_signing_keys "SSH signing keys"
  awk 'NF >= 2 { print $1 " " $2 }' <<< "$remote_keys" | grep -qxF "$material"
}

provision_ssh_signing() {
  [[ ${SIGNING_MODE:-skip} == ssh ]] || return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would sign and verify a test commit with the SSH key, check its GitHub signing-key registration, and enable commit signing (gpg.format ssh); missing registration requires manual action"
    return 0
  fi
  [[ -n $SSH_PUBLIC_KEY && -f $SSH_PUBLIC_KEY ]] || die "SSH signing needs the SSH key, which was not prepared"
  ensure_git_identity
  local name=$GIT_NAME email=$GIT_EMAIL material signing_key signers signers_tmp temp_repo
  [[ -n $name && -n $email ]] || die "Set global git user.name and user.email before enabling SSH signing"
  github_email_is_verified "$email" ||
    die "Git email is not verified on the authenticated GitHub account: $email (GitHub marks a signed commit verified only for a verified email)"
  material=$(ssh_public_material "$SSH_PUBLIC_KEY")
  [[ $material == ssh-* || $material == ecdsa-* || $material == sk-* ]] || die "Invalid SSH public material in $SSH_PUBLIC_KEY"
  signing_key=$(ssh_signing_key_value)
  # The allowed-signers file is entirely managed: this identity, git only.
  prepare_local_dir
  signers=$(allowed_signers_path)
  signers_tmp=$(mktemp "$LOCAL_DIR/.allowed-signers.XXXXXX")
  track_temp "$signers_tmp"
  printf '%s namespaces="git" %s\n' "$email" "$material" > "$signers_tmp"
  chmod 600 "$signers_tmp"
  mv -f "$signers_tmp" "$signers"
  # Sign, then verify, a commit in a throwaway repository first, as the GPG
  # path does; global settings change only after both work.
  temp_repo=$(mktemp -d)
  track_temp "$temp_repo"
  git -C "$temp_repo" init -q
  git -C "$temp_repo" config user.name "$name"
  git -C "$temp_repo" config user.email "$email"
  git -C "$temp_repo" config gpg.format ssh
  git -C "$temp_repo" config user.signingkey "$signing_key"
  git -C "$temp_repo" config gpg.ssh.allowedSignersFile "$signers"
  git -C "$temp_repo" config commit.gpgsign true
  if ! git -C "$temp_repo" commit --allow-empty -S -m 'Verify Leo profiles signing setup' >/dev/null; then
    rm -rf "$temp_repo"
    die "The SSH key cannot sign a Git commit (a passphrase-protected key needs a terminal or your agent)"
  fi
  if ! git -C "$temp_repo" verify-commit HEAD >/dev/null 2>&1; then
    rm -rf "$temp_repo"
    die "Git could not verify the SSH-signed test commit against $signers"
  fi
  rm -rf "$temp_repo"
  if ! github_ssh_signing_key_present "$SSH_PUBLIC_KEY"; then
    credential_manual_action register-ssh-signing-key "$SSH_PUBLIC_KEY" https://github.com/settings/ssh/new \
      "Register this public key yourself as a signing key on GitHub account $GITHUB_LOGIN: gh ssh-key add $SSH_PUBLIC_KEY --type signing (needs the admin:ssh_signing_key scope: gh auth refresh -h github.com -s admin:ssh_signing_key), or choose Key type: Signing Key on the settings page. Then rerun reconcile; global commit signing is not enabled until registration is verified."
  fi
  git config --global gpg.format ssh
  git config --global user.signingkey "$signing_key"
  git config --global gpg.ssh.allowedSignersFile "$signers"
  git config --global commit.gpgsign true
}
