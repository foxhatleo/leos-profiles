#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

# The saved profile's schema write_profile writes. PROFILE_SCHEMA is the one
# read_profile read (it reports a pending migration).
readonly CURRENT_PROFILE_SCHEMA=4

prepare_local_dir() {
  [[ $DRY_RUN -eq 0 ]] || return 0
  mkdir -p "$LOCAL_DIR/flags"
  chmod 700 "$LOCAL_DIR" "$LOCAL_DIR/flags"
  # The private override files routinely hold API keys and are created by hand,
  # so their mode is enforced on every run — migrate_one_local_file only chmods
  # files it moves.
  [[ ! -f $LOCAL_DIR/private.zsh ]] || chmod 600 "$LOCAL_DIR/private.zsh"
  [[ ! -f $LOCAL_DIR/private-interactive.zsh ]] || chmod 600 "$LOCAL_DIR/private-interactive.zsh"
}

track_temp() { TEMP_PATHS+=("$1"); }

cleanup() {
  local path
  # A sudo keepalive (packages.sh) dies with the run.
  if [[ -n ${SUDO_KEEPALIVE_PID:-} ]]; then kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; fi
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
  # The PID is alive, but after an unclean exit (a reboot, say) the number can
  # belong to an unrelated process by now. An installer runs install.sh.
  local command
  if command=$(process_command "$owner") && [[ -n $command && $command != *install.sh* ]]; then
    die "The lock looks stale: its PID $owner now belongs to another program ($command), so the Leo's Profiles operation that took it exited uncleanly. If no install is running, remove it and retry: rm -rf -- '$LOCK_DIR'"
  fi
  die "Another Leo's Profiles operation is running (PID $owner). If it is not (the lock outlived an unclean exit), remove the lock and retry: rm -rf -- '$LOCK_DIR'"
}

# process_command <pid>: the command line of a running process, when ps can
# tell (minimal containers may lack ps; the caller then assumes the worst).
process_command() {
  ps -p "$1" -o command= 2>/dev/null
}

write_profile() {
  [[ $DRY_RUN -eq 0 ]] || return 0
  local tmp
  prepare_local_dir
  tmp=$(mktemp "$LOCAL_DIR/.install-profile.tmp.XXXXXX")
  track_temp "$tmp"
  {
    printf 'schema\t%s\n' "$CURRENT_PROFILE_SCHEMA"
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
    printf 'gpg-generated\t%s\n' "$GPG_GENERATED_KEY"
    printf 'gpg-passphrase\t%s\n' "$GPG_PASSPHRASE_MODE"
    printf 'node-channel\t%s\n' "$NODE_CHANNEL"
    printf 'node-policy\t%s\n' "$NODE_POLICY"
    printf 'ai-cli-update-channel\t%s\n' "$AI_CLI_UPDATE_CHANNEL"
    printf 'package-channel\t%s\n' "$PACKAGE_CHANNEL"
    printf 'version-managers\t%s\n' "$([[ $SKIP_EXISTING_VERSION_MANAGERS -eq 1 ]] && printf skip-existing || printf install)"
    printf 'upgrade-casks\t%s\n' "$([[ $UPGRADE_CASKS -eq 1 ]] && printf yes || printf no)"
    printf 'release-age\t%s\n' "$MIN_RELEASE_AGE"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PROFILE_FILE"
}

# remember_generated_gpg_key: apply rewrites the profile from its own options
# before provisioning, so first carry over the GPG key an earlier run
# generated (see previously_generated_gpg_key).
remember_generated_gpg_key() {
  [[ -f $PROFILE_FILE ]] || return 0
  GPG_GENERATED_KEY=$(awk -F '\t' '$1 == "gpg-generated" { print $2; exit }' "$PROFILE_FILE")
  validate_tsv_value gpg-generated "$GPG_GENERATED_KEY"
}

read_profile() {
  [[ -f $PROFILE_FILE ]] || die "No saved install profile ($PROFILE_FILE). Set up first: bash $TARGET/install.sh setup"
  local key value extra schema="" seen=","
  UPGRADE_CASKS=0  # optional key: a profile without it predates the flag
  MIN_RELEASE_AGE=7  # optional key, likewise
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
      # Optional (added 2026-11): the key --gpg generate created, so a retried
      # generate reuses it (remember_generated_gpg_key).
      gpg-generated) GPG_GENERATED_KEY=$value ;;
      gpg-passphrase) GPG_PASSPHRASE_MODE=$value ;;
      node-channel) NODE_CHANNEL=$value ;;
      node-policy) NODE_POLICY=$value ;;
      ai-cli-update-channel) AI_CLI_UPDATE_CHANNEL=$value ;;
      package-channel) PACKAGE_CHANNEL=$value ;;
      # Optional (added after schema 2): keep an existing rbenv (pyenv too,
      # before schema 4).
      version-managers)
        case $value in
          install) SKIP_EXISTING_VERSION_MANAGERS=0 ;;
          skip-existing) SKIP_EXISTING_VERSION_MANAGERS=1 ;;
          *) die "Invalid saved version-managers value: $value" ;;
        esac ;;
      # Optional (added 2026-11; absent means no): the macOS full upgrade
      # also runs `brew upgrade --cask`.
      upgrade-casks)
        case $value in
          no) UPGRADE_CASKS=0 ;;
          yes) UPGRADE_CASKS=1 ;;
          *) die "Invalid saved upgrade-casks value: $value" ;;
        esac ;;
      # Optional (added 2026-11; absent means 7): --min-release-age.
      release-age)
        min_release_age_ok "$value" || die "Invalid saved release-age value: $value"
        MIN_RELEASE_AGE=$value ;;
      '') ;;
      *) die "Unknown install profile key: $key" ;;
    esac
  done < "$PROFILE_FILE"
  [[ $schema == 1 || $schema == 2 || $schema == 3 || $schema == 4 ]] || die "Unsupported install profile schema: ${schema:-missing}"
  local required
  for required in groups package-groups full-upgrade fonts font default-shell git-name git-email \
    ssh ssh-key ssh-passphrase gpg gpg-key gpg-passphrase node-channel ai-cli-update-channel package-channel; do
    [[ $seen == *",$required,"* ]] || die "Incomplete install profile: missing $required"
  done
  PROFILE_SCHEMA=$schema
  # Schemas 1 (no node-policy; before 2026-09) and 2 (node-policy
  # preserve-compatible; before 2026-10) migrate on the next approved
  # apply/reconcile: fnm's default now follows the current LTS. Keep reading
  # them until 2027-10, then reject them with a message to run apply again.
  if [[ $schema == 2 && $seen != *,node-policy,* ]]; then die "Profile schema 2 requires node-policy"; fi
  if [[ ($schema == 3 || $schema == 4) && $seen != *,node-policy,* ]]; then die "Profile schema $schema requires node-policy"; fi
  if [[ $schema == 1 || $schema == 2 ]]; then NODE_POLICY=current-lts; fi
  # Schemas 1-3 (before 2026-11) also name the retired components and the
  # languages group: map them to schema 4's (migrate_profile_selection). Kept
  # until 2027-11, like the schemas above.
  if [[ $schema != 4 ]]; then migrate_profile_selection; fi
}

# migrate_profile_selection: a schema 1-3 selection in schema 4's terms:
#   pyenv       -> cpython (uv's CPython; an existing ~/.pyenv stays, unmanaged)
#   yarn, pnpm  -> corepack
#   plugins     -> plugins and starship (Starship was part of plugins)
#   languages   -> removed (its installed packages stay; see
#                  report_profile_migration)
# Inspect and dry runs only read the result; an approved apply/reconcile
# writes it with the new schema.
migrate_profile_selection() {
  local item steps="" groups=""
  local -a items=()
  csv_split items "$SELECTED_STEPS"
  for item in ${items[@]+"${items[@]}"}; do
    case $item in
      pyenv) add_csv_item steps cpython ;;
      yarn|pnpm) add_csv_item steps corepack ;;
      plugins) add_csv_item steps plugins; add_csv_item steps starship ;;
      *) add_csv_item steps "$item" ;;
    esac
  done
  csv_split items "$SELECTED_GROUPS"
  for item in ${items[@]+"${items[@]}"}; do
    [[ $item == languages ]] || add_csv_item groups "$item"
  done
  SELECTED_STEPS=$steps
  SELECTED_GROUPS=$groups
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

# Legacy-location migrations. Each is kept for one year after the release that
# moved the data, then removed with its test:
#   - XDG installer state ($LEGACY_STATE_FILE) and zsh/_private.zsh moved into
#     local/ in 2026-09: remove after 2027-09.
#   - ~/.brew-china and ~/.lp-* markers moved to local/flags/ in 2026-09:
#     remove after 2027-09.
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
  # Schema 4 (2026-11): rows of retired steps; remove after 2027-11.
  # shellcheck disable=SC2086  # a list of step names
  drop_state_rows $RETIRED_STATE_STEPS
}

# Steps schema 4 retired, with nothing left to verify. Their rows in the state
# file are dropped by migrate_local_state (pyenv) or, for yarn and pnpm, by
# the corepack step once it has removed what they installed (macOS: it reads
# the rows to know Homebrew's yarn and pnpm were the profile's).
RETIRED_STATE_STEPS="pyenv"

# drop_state_rows <step...>: remove those steps' rows from the state file.
drop_state_rows() {
  local tmp list
  [[ -f $STATE_FILE ]] || return 0
  list=" $* "
  awk -F '\t' -v list="$list" 'index(list, " " $1 " ") { found = 1 } END { exit !found }' "$STATE_FILE" || return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would drop the retired $* rows from $STATE_FILE"
    return 0
  fi
  tmp=$(mktemp "$LOCAL_DIR/.install-state.tmp.XXXXXX")
  track_temp "$tmp"
  awk -F '\t' -v list="$list" '!index(list, " " $1 " ")' "$STATE_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# state_detail <step>: the diagnostic column of the step's row (fnm: the Node
# version; rbenv: ruby:<version> or ruby-failed:<version>).
state_detail() {
  [[ -f $STATE_FILE ]] || return 0
  awk -F '\t' -v step="$1" '$1 == step { detail = $4 } END { print detail }' "$STATE_FILE"
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
  # Column 4 is diagnostic: the Node version the fnm step resolved, and the
  # rbenv step's Ruby outcome, which verify_rbenv reads back (a recorded
  # failed compile is not retried until a full upgrade).
  case $step in
    fnm) detail=$RESOLVED_NODE_VERSION ;;
    rbenv) detail=$RUBY_RESULT ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$step" "$signature" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$detail" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}


# Pending migrations of the saved profile, as inspect records: the schema, and
# a saved languages group, whose packages stay installed (nothing uninstalls
# them; schema 4 just stops selecting them).
report_profile_migration() {
  local schema=$PROFILE_SCHEMA groups=""
  if [[ -f $PROFILE_FILE ]]; then
    schema=$(awk -F '\t' '$1 == "schema" { print $2; exit }' "$PROFILE_FILE")
    groups=$(awk -F '\t' '$1 == "package-groups" { print $2; exit }' "$PROFILE_FILE")
  fi
  if [[ $schema == 1 || $schema == 2 || $schema == 3 ]]; then
    printf 'migration\tprofile-schema\t%s\t%s\n' "$schema" "$CURRENT_PROFILE_SCHEMA"
    if has_csv_item "$groups" languages; then
      printf 'migration\tpackage-group\tlanguages\tdropped: the packages it installed stay installed; fnm, cpython (uv) and rbenv provide Node, Python and Ruby\n'
    fi
  fi
  return 0
}
