#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

prepare_local_dir() {
  [[ $DRY_RUN -eq 0 ]] || return 0
  mkdir -p "$LOCAL_DIR/flags"
  chmod 700 "$LOCAL_DIR" "$LOCAL_DIR/flags"
  # private.zsh routinely holds API keys and is created by hand, so its mode is
  # enforced on every run — migrate_one_local_file only chmods files it moves.
  [[ ! -f $LOCAL_DIR/private.zsh ]] || chmod 600 "$LOCAL_DIR/private.zsh"
}

track_temp() { TEMP_PATHS+=("$1"); }

cleanup() {
  local path
  for path in "${TEMP_PATHS[@]-}"; do [[ -z $path ]] || rm -rf -- "$path"; done
  # Only remove the lock if it is still ours — never delete a lock a different
  # run now holds (defensive backstop for the reclaim race).
  if [[ $LOCK_HELD -eq 1 && -f $LOCK_DIR/pid ]] && [[ $(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null) == "$$" ]]; then
    rm -rf -- "$LOCK_DIR"
  fi
}

acquire_lock() {
  [[ $DRY_RUN -eq 0 ]] || return 0
  prepare_local_dir
  # The ONLY state-changing operation here is the atomic exclusive `mkdir`, so
  # two concurrent runs can never both acquire and there is no reclaim TOCTOU.
  # A stale lock is only left by an unclean kill (SIGKILL/power loss) — the EXIT
  # trap clears it on any normal or signalled exit — so we fail closed and tell
  # the operator how to remove it rather than racily auto-reclaiming it.
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    chmod 600 "$LOCK_DIR/pid"
    LOCK_HELD=1
    return 0
  fi
  local owner=""
  [[ -f $LOCK_DIR/pid ]] && owner=$(sed -n '1p' "$LOCK_DIR/pid")
  if [[ ! $owner =~ ^[0-9]+$ ]]; then
    # No readable pid: a kill between the mkdir and the pid write left this
    # behind, so there is no process to point at. Give the removal guidance
    # rather than claiming another operation is running.
    die "A previous Leo's Profiles operation left a lock with no usable owner record, which means it exited uncleanly. If no install is running, remove it and retry: rm -rf -- '$LOCK_DIR'"
  fi
  if ! kill -0 "$owner" 2>/dev/null; then
    die "A previous Leo's Profiles operation (PID $owner) exited uncleanly and left a lock. If no such process is running, remove it and retry: rm -rf -- '$LOCK_DIR'"
  fi
  die "Another Leo's Profiles operation is running (PID $owner)"
}

write_profile() {
  [[ $DRY_RUN -eq 0 ]] || return 0
  local tmp
  prepare_local_dir
  tmp=$(mktemp "$LOCAL_DIR/.install-profile.tmp.XXXXXX")
  track_temp "$tmp"
  {
    printf 'schema\t2\n'
    printf 'groups\t%s\n' "$SELECTED_STEPS"
    printf 'package-groups\t%s\n' "$SELECTED_GROUPS"
    printf 'full-upgrade\t%s\n' "$SAVED_FULL_UPGRADE"
    printf 'fonts\t%s\n' "$INSTALL_FONTS"
    printf 'font\t%s\n' "$FONT_NAME"
    printf 'default-shell\t%s\n' "$CHANGE_DEFAULT_SHELL"
    printf 'git-name\t%s\n' "$GIT_NAME"
    printf 'git-email\t%s\n' "$GIT_EMAIL"
    printf 'ssh\t%s\n' "$SSH_MODE"
    printf 'ssh-key\t%s\n' "$SSH_KEY_PATH"
    printf 'ssh-passphrase\t%s\n' "$SSH_PASSPHRASE_MODE"
    printf 'gpg\t%s\n' "$GPG_MODE"
    printf 'gpg-key\t%s\n' "$GPG_KEY_ID"
    printf 'gpg-passphrase\t%s\n' "$GPG_PASSPHRASE_MODE"
    printf 'node-channel\t%s\n' "$NODE_CHANNEL"
    printf 'node-policy\t%s\n' "$NODE_POLICY"
    printf 'ai-cli-update-channel\t%s\n' "$AI_CLI_UPDATE_CHANNEL"
    printf 'package-channel\t%s\n' "$PACKAGE_CHANNEL"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PROFILE_FILE"
}

read_profile() {
  [[ -f $PROFILE_FILE ]] || die "No saved install profile. Run the AI setup flow first: $PROFILE_FILE"
  local key value extra schema="" seen=","
  while IFS=$'\t' read -r key value extra || [[ -n $key ]]; do
    [[ -z ${extra:-} ]] || die "Malformed install profile row: $key"
    validate_tsv_value "$key" "${value:-}"
    [[ $seen != *",$key,"* ]] || die "Duplicate install profile key: $key"
    seen+="$key,"
    case $key in
      schema) schema=$value ;;
      groups) SELECTED_STEPS=$value ;;
      package-groups) SELECTED_GROUPS=$value ;;
      full-upgrade) SAVED_FULL_UPGRADE=$value ;;
      fonts) INSTALL_FONTS=$value ;;
      font) FONT_NAME=$value ;;
      default-shell) CHANGE_DEFAULT_SHELL=$value ;;
      git-name) GIT_NAME=$value ;;
      git-email) GIT_EMAIL=$value ;;
      ssh) SSH_MODE=$value ;;
      ssh-key) SSH_KEY_PATH=$value ;;
      ssh-passphrase) SSH_PASSPHRASE_MODE=$value ;;
      gpg) GPG_MODE=$value ;;
      gpg-key) GPG_KEY_ID=$value ;;
      gpg-passphrase) GPG_PASSPHRASE_MODE=$value ;;
      node-channel) NODE_CHANNEL=$value ;;
      node-policy) NODE_POLICY=$value ;;
      ai-cli-update-channel) AI_CLI_UPDATE_CHANNEL=$value ;;
      package-channel) PACKAGE_CHANNEL=$value ;;
      '') ;;
      *) die "Unknown install profile key: $key" ;;
    esac
  done < "$PROFILE_FILE"
  [[ $schema == 1 || $schema == 2 ]] || die "Unsupported install profile schema: ${schema:-missing}"
  local required
  for required in groups package-groups full-upgrade fonts font default-shell git-name git-email \
    ssh ssh-key ssh-passphrase gpg gpg-key gpg-passphrase node-channel ai-cli-update-channel package-channel; do
    [[ $seen == *",$required,"* ]] || die "Incomplete install profile: missing $required"
  done
  PROFILE_SCHEMA=$schema
  if [[ $schema == 1 ]]; then NODE_POLICY=preserve-compatible; fi
  if [[ $schema == 2 && $seen != *,node-policy,* ]]; then die "Profile schema 2 requires node-policy"; fi
}

migrate_one_local_file() {
  local legacy=$1 destination=$2
  [[ -e $legacy || -L $legacy ]] || return 0
  if [[ -e $destination || -L $destination ]]; then
    # The conflict check runs in dry-run too — see migrate_local_state.
    cmp -s "$legacy" "$destination" || die "Conflicting local settings: $legacy and $destination"
    [[ $DRY_RUN -eq 0 ]] || { say "Would remove the superseded $legacy"; return 0; }
    rm -f -- "$legacy"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would move $legacy to $destination (mode 600)"
    return 0
  fi
  mkdir -p "$(dirname -- "$destination")"
  mv -- "$legacy" "$destination"
  chmod 600 "$destination"
}

# Dry-run performs the *detection* half of the migration but none of the
# mutations, so `apply --dry-run` surfaces the same conflicts a real apply would
# die on. Previously it returned early and reported success, then the real apply
# failed immediately on a legacy-state conflict the dry-run never looked at.
migrate_local_state() {
  prepare_local_dir
  if [[ -f $LEGACY_STATE_FILE && ! -e $STATE_FILE ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would migrate $LEGACY_STATE_FILE to $STATE_FILE"
    else
      cp -p "$LEGACY_STATE_FILE" "$STATE_FILE"
      chmod 600 "$STATE_FILE"
      rm -f "$LEGACY_STATE_FILE"
    fi
  elif [[ -f $LEGACY_STATE_FILE && -f $STATE_FILE ]]; then
    cmp -s "$LEGACY_STATE_FILE" "$STATE_FILE" ||
      die "Conflicting installer state: $LEGACY_STATE_FILE and $STATE_FILE"
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would remove the superseded $LEGACY_STATE_FILE"
    else
      rm -f "$LEGACY_STATE_FILE"
    fi
  fi
  migrate_one_local_file "$TARGET/zsh/_private.zsh" "$LOCAL_DIR/private.zsh"
  migrate_one_local_file "$HOME/.brew-china" "$LOCAL_DIR/flags/brew-china"
  migrate_one_local_file "$HOME/.lp-no-gnu" "$LOCAL_DIR/flags/no-gnu"
  migrate_one_local_file "$HOME/.lp-nobrew" "$LOCAL_DIR/flags/no-brew"
  migrate_one_local_file "$HOME/.lp-nopyenv" "$LOCAL_DIR/flags/no-pyenv"
  migrate_one_local_file "$HOME/.lp-norbenv" "$LOCAL_DIR/flags/no-rbenv"
}

state_done() {
  local step=$1 signature
  signature=$(step_signature "$step")
  [[ -f $STATE_FILE ]] && awk -F '\t' -v step="$step" -v signature="$signature" \
    '$1 == step && $2 == signature { found=1 } END { exit !found }' "$STATE_FILE"
}

mark_done() {
  local step=$1 signature tmp detail=""
  [[ $DRY_RUN -eq 1 ]] && return 0
  signature=$(step_signature "$step")
  prepare_local_dir
  tmp=$(mktemp "$LOCAL_DIR/.install-state.tmp.XXXXXX")
  track_temp "$tmp"
  if [[ -f $STATE_FILE ]]; then
    awk -F '\t' -v step="$step" '$1 != step' "$STATE_FILE" > "$tmp"
  else
    : > "$tmp"
  fi
  # Column 4 is diagnostic only — nothing reads it back; it records which Node
  # version the fnm step resolved so a state file can be inspected by hand.
  [[ $step != fnm ]] || detail=$RESOLVED_NODE_VERSION
  printf '%s\t%s\t%s\t%s\n' "$step" "$signature" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$detail" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}


report_profile_migration() {
  local schema=$PROFILE_SCHEMA
  if [[ -f $PROFILE_FILE ]]; then
    schema=$(awk -F '\t' '$1 == "schema" { print $2; exit }' "$PROFILE_FILE")
  fi
  if [[ $schema == 1 ]]; then
    printf 'migration\tprofile-schema\t1\t2\n'
  fi
  return 0
}
