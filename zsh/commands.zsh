# Leo's Profiles — user commands (zsh)

__rmdsstore() {
  if [[ $(uname -s) != Darwin ]]; then
    __leos_puts_err "rmdsstore only supports the macOS data-volume layout."
    return 1
  fi
  # Run the sweep with the OS interpreter, not a PATH-resolved one: `sudo` must
  # not execute a python3 from a user-writable dir (the Homebrew prefix, pyenv
  # shims), which would be a local root-escalation vector — especially since
  # `bye` runs `brew upgrade` moments earlier. `-I` isolates the interpreter
  # (ignores PYTHON* env and user site; drops the script dir from sys.path on
  # 3.11+). rmdsstore.py is stdlib-only, so the system Python is sufficient.
  # Note: the script itself lives in the user-owned checkout by design (see the
  # README trust model); this closes the interpreter/env vectors, not that one.
  if [[ ! -x /usr/bin/python3 ]]; then
    __leos_puts_err "/usr/bin/python3 (the system Python) is required for rmdsstore."
    return 1
  fi
  sudo /usr/bin/python3 -I "$LEOS_PROFILES/util/rmdsstore.py" "$@" || return $?
  __leos_puts "Finished scanning $*"
}

# Remove all .DS_Store and sibling metadata files under standard macOS roots.
rmdsstore() {
  local arg
  local -a options
  while (( $# > 0 )); do
    arg=$1
    case $arg in
      --dry-run|--purge-recycle-bins) options+=("$arg"); shift ;;
      --) shift; break ;;
      -*) __leos_puts_err "Usage: rmdsstore [--dry-run] [--purge-recycle-bins] [root ...]"; return 2 ;;
      *) break ;;
    esac
  done
  __rmdsstore "${options[@]}" "$@"
}

# Clear known history files. The aggressive mode adds the legacy broad globs,
# but still never recursively deletes a matched directory.
clear-history() {
  local aggressive=${1:-} f exit_code=0
  local -a candidates
  # The profile's HISTFILE is in ZDOTDIR when that is set; the HOME copy is
  # zsh's usual place, and where earlier versions of this profile kept it.
  candidates=("${ZDOTDIR:-$HOME}/.zsh_history" "$HOME/.zsh_history" "$HOME/.bash_history" "$HOME/.python_history"
              "$HOME/.node_repl_history" "$HOME/.lesshst")
  if [[ $aggressive == --aggressive ]]; then
    # Completion dumps: the profile's own (cache root, one per Zsh version)
    # and any legacy or third-party ones in HOME/ZDOTDIR.
    candidates+=($HOME/.*history(N) $HOME/.zcompdump*(N) ${ZDOTDIR:-$HOME}/.zcompdump*(N) \
                 ${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/zcompdump-[0-9]*(N) \
                 $HOME/.oracle_jre_usage(N) $HOME/.*hsts(N))
  fi
  for f in "${candidates[@]}"; do
    [[ -f $f || -L $f ]] || continue
    rm -f -- "$f" || exit_code=1
  done
  : > "$HISTFILE" 2>/dev/null || exit_code=1
  fc -p "$HISTFILE" 2>/dev/null || exit_code=1
  if [[ -d $HOME/.lldb ]]; then
    for f in $HOME/.lldb/*history(N); do
      if [[ -f $f || -L $f ]]; then rm -f -- "$f" || exit_code=1; fi
    done
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -Command "Remove-Item (Get-PSReadlineOption).HistorySavePath" || exit_code=1
  fi
  return $exit_code
}

# Show/hide hidden files in Finder (macOS).
__hidden-set() {
  if [[ $(uname -s) == Darwin ]]; then
    defaults write com.apple.Finder AppleShowAllFiles "$1" || return 1
    killall Finder >/dev/null 2>&1 || true
  else
    __leos_puts_err "This command is only available on macOS."
    return 1
  fi
}
hidden-on()  { __hidden-set YES; }
hidden-off() { __hidden-set NO; }

# Make a directory then cd into it.
mkcdir() {
  if (( $# == 0 )); then
    echo "Usage: mkcdir <directory>"; return 1
  fi
  mkdir -p -- "$1" && cd -- "$1"
}

# Clean up and quit the terminal. This intentionally performs the full Leo's
# maintenance routine: package updates (with autoremove, cleanup and orphan
# removal), AI CLI updates and, on macOS, a privileged metadata sweep plus
# Finder/Dock restart. History is kept unless asked: --wipe-history clears the
# known history files, and --aggressive-history (which implies it) the legacy
# broad matches too.
# Options are exact; destructive extensions are explicit opt-ins.
bye() {
  local wipe_history non_interactive no_exit aggressive_history purge_recycle_bins shutdown_wsl arg exit_code=0
  for arg in "$@"; do
    case $arg in
      # Dashed forms only: the usage string and the _leos_bye completion define
      # the supported surface.
      --wipe-history) wipe_history=1 ;;
      # Keeping history became the default; the old opt-out is still accepted
      # so existing aliases and scripts keep working.
      --keep-history) ;;
      --non-interactive) non_interactive=1 ;;
      --no-exit) no_exit=1 ;;
      --aggressive-history) aggressive_history=1; wipe_history=1 ;;
      --purge-recycle-bins) purge_recycle_bins=1 ;;
      --shutdown-wsl) shutdown_wsl=1 ;;
      *) __leos_puts_err "Usage: bye [--wipe-history] [--aggressive-history] [--non-interactive] [--no-exit] [--purge-recycle-bins] [--shutdown-wsl]"; return 2 ;;
    esac
  done
  if [[ -n $shutdown_wsl && -n $no_exit ]]; then
    __leos_puts_err "--shutdown-wsl and --no-exit are contradictory."
    return 2
  fi

  __leos_puts "Bye!"

  sudo -v || { __leos_puts_err "sudo authentication is required for the cleanup routine."; return 1; }

  # A local export is automatically restored even on an early function return.
  if [[ -n $non_interactive ]]; then
    local -x HOMEBREW_NO_ASK=1
  fi

  if (( $+functions[brew-checkup] )); then __leos_puts "Doing brew checkup..."; brew-checkup || exit_code=1; fi
  if (( $+functions[apt-checkup]   )); then __leos_puts "Doing apt checkup...";  apt-checkup || exit_code=1; fi
  if (( $+functions[dnf-checkup]   )); then __leos_puts "Doing dnf checkup...";  dnf-checkup || exit_code=1; fi
  if (( $+functions[pacman-checkup] )); then __leos_puts "Doing pacman checkup..."; pacman-checkup || exit_code=1; fi
  if (( $+functions[ai-checkup]    )); then __leos_puts "Doing AI tools checkup..."; ai-checkup || exit_code=1; fi

  if [[ -n $wipe_history ]]; then
    __leos_puts "Clearing history files..."
    if [[ -n $aggressive_history ]]; then
      clear-history --aggressive || exit_code=1
    else
      clear-history || exit_code=1
    fi
  fi

  if [[ $(uname -s) == Darwin ]]; then
    __leos_puts "Restarting Finder, Dock, SystemUIServer..."
    if [[ -n $purge_recycle_bins ]]; then rmdsstore --purge-recycle-bins || exit_code=1; else rmdsstore || exit_code=1; fi
    killall Finder Dock SystemUIServer || exit_code=1
  fi

  if [[ -n $no_exit ]]; then
    __leos_puts "Skipped exiting."
    return $exit_code
  elif [[ -n $shutdown_wsl ]] && command -v /mnt/c/Windows/system32/wsl.exe >/dev/null 2>&1; then
    /mnt/c/Windows/system32/wsl.exe --shutdown
  else
    exit $exit_code
  fi
}

# Fetch the configured profile upstream, show what it would bring in, and
# after confirmation fast-forward to it and run the newly pulled reconciler
# against the saved local profile.
#
#   --full-upgrade        pass --full-upgrade to reconcile
#   --yes                 apply without asking (required without a terminal)
#   --verify-signatures   only fast-forward when every new commit carries a
#                         good signature Git can verify: SSH signatures need
#                         gpg.ssh.allowedSignersFile, GPG ones need gpg and
#                         the signer's key in your keyring
upgrade-leos-profiles() {
  local branch upstream incoming answer arg yes=0 verify=0
  local -a reconcile_args merge_args
  reconcile_args=(reconcile --yes)
  merge_args=(merge --ff-only)
  for arg in "$@"; do
    case $arg in
      --full-upgrade) reconcile_args+=(--full-upgrade) ;;
      --yes) yes=1 ;;
      --verify-signatures) verify=1 ;;
      *) __leos_puts_err "Usage: upgrade-leos-profiles [--full-upgrade] [--yes] [--verify-signatures]"; return 2 ;;
    esac
  done
  # Without a saved setup there is nothing to reconcile: say so before
  # changing the checkout, not after (MI-12).
  if [[ ! -f $LEOS_PROFILES/local/install-profile.tsv ]]; then
    __leos_puts_err "No saved setup in $LEOS_PROFILES/local/install-profile.tsv, so there is nothing to reconcile. Set up first (QUICK-INSTALL.md, or bash $LEOS_PROFILES/install.sh apply --yes); to update only the checkout, use git -C $LEOS_PROFILES pull --ff-only."
    return 1
  fi
  if (( verify )); then
    if [[ -z $(git -C "$LEOS_PROFILES" config --get gpg.ssh.allowedSignersFile 2>/dev/null) ]] &&
        ! whence -p gpg >/dev/null; then
      __leos_puts_err "--verify-signatures needs a way to check signatures: set gpg.ssh.allowedSignersFile for SSH-signed commits, or install gpg with the signer's public key."
      return 1
    fi
    merge_args+=(--verify-signatures)
  fi
  branch=$(git -C "$LEOS_PROFILES" symbolic-ref --quiet --short HEAD) || {
    __leos_puts_err "The profile checkout must be on a branch."
    return 1
  }
  upstream=$(git -C "$LEOS_PROFILES" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || {
    __leos_puts_err "Branch $branch has no configured upstream."
    return 1
  }
  if [[ -n $(git -C "$LEOS_PROFILES" status --porcelain --untracked-files=normal) ]]; then
    __leos_puts_err "Refusing to update because the profile checkout has local changes. Commit or stash them first."
    return 1
  fi
  git -C "$LEOS_PROFILES" fetch --quiet || return $?
  # Review before running anything new: these commits are about to run with
  # sudo through reconcile (SEC-3).
  incoming=$(git -C "$LEOS_PROFILES" log --oneline 'HEAD..@{upstream}') || return $?
  if [[ -z $incoming ]]; then
    __leos_puts "$LEOS_PROFILES is up to date with $upstream; reconciling the saved setup."
  else
    __leos_puts "Incoming commits from $upstream:"
    print -r -- "$incoming"
    if (( ! yes )); then
      if [[ -t 0 ]]; then
        read -r "answer?Fast-forward to these commits and reconcile? [y/N] "
        [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { __leos_puts "Cancelled; nothing was changed."; return 1; }
      else
        __leos_puts_err "Not a terminal: review the commits above, then run upgrade-leos-profiles --yes to apply them."
        return 1
      fi
    fi
    git -C "$LEOS_PROFILES" "${merge_args[@]}" '@{upstream}' || return $?
    __leos_puts "Updated $LEOS_PROFILES from $upstream; reconciling the saved setup."
  fi
  command bash "$LEOS_PROFILES/install.sh" "${reconcile_args[@]}"
}

# A read-only health check of the saved setup: runs `install.sh inspect
# --saved` and summarises its postconditions, warnings and conflicts (MI-14).
leos-doctor() {
  local out rc=0 line needed=0
  local -a fields
  if (( $# )); then
    __leos_puts_err "Usage: leos-doctor"
    return 2
  fi
  out=$(command bash "$LEOS_PROFILES/install.sh" inspect --saved) || rc=$?
  if (( rc )); then
    __leos_puts_err "leos-doctor: install.sh inspect --saved failed (exit $rc); see the message above."
    return $rc
  fi
  __leos_puts "Leo's Profiles at $LEOS_PROFILES"
  for line in "${(@f)out}"; do
    fields=("${(@ps:\t:)line}")
    case $fields[1] in
      postcondition)
        case $fields[3] in
          verified) print -r -- "  ok       $fields[2]" ;;
          skipped) print -r -- "  skipped  $fields[2] (an existing installation is kept)" ;;
          *) print -r -- "  NEEDED   $fields[2]"; needed=1 ;;
        esac ;;
      warning) print -r -- "  warning  $fields[2]: $fields[3]" ;;
      conflict) print -r -- "  conflict $fields[2]: $fields[3] ($fields[4])" ;;
      migration) print -r -- "  pending  migration: $fields[2] ${fields[3]:-}" ;;
      shadow) print -r -- "  note     $fields[3] is shadowed by the profile's $fields[4]" ;;
      existing) print -r -- "  note     $fields[2] at $fields[3]: $fields[4]" ;;
    esac
  done
  if (( needed )); then
    __leos_puts "Repair with: upgrade-leos-profiles (pulls first), or bash $LEOS_PROFILES/install.sh reconcile --yes"
    return 1
  fi
  __leos_puts "Everything the saved setup installs is in place."
}

# Update only installed AI coding CLIs using their supported native updaters.
ai-checkup() {
  local found=0 exit_code=0
  if command -v claude >/dev/null 2>&1; then
    found=1; __leos_puts "Updating Claude Code..."; claude update || exit_code=1
  fi
  if command -v codex >/dev/null 2>&1; then
    found=1; __leos_puts "Updating Codex..."; codex update || exit_code=1
  fi
  # Skip a Homebrew-managed opencode: brew-checkup already owns that copy, and
  # `opencode upgrade` would fight it. Only self-installed copies are updated.
  # `command -v` for detection (so it can be stubbed like claude/codex above),
  # $commands for the prefix test — empty for a stub, which reads as non-brew.
  if command -v opencode >/dev/null 2>&1 && [[ ${commands[opencode]:-} != ${HOMEBREW_PREFIX:-/opt/homebrew}/* ]]; then
    found=1; __leos_puts "Updating opencode..."; opencode upgrade || exit_code=1
  fi
  (( found )) || __leos_puts "No supported installed AI CLI was detected; nothing to update."
  return $exit_code
}

# Linux GUI toggles. Detect a known display-manager service instead of assuming
# Debian's gdm3 name on every distribution.
__leos_display_manager() {
  local service
  command -v systemctl >/dev/null 2>&1 || return 1
  for service in gdm3 gdm sddm lightdm; do
    systemctl cat "$service" >/dev/null 2>&1 && { print -r -- "$service"; return 0; }
  done
  return 1
}

gui-start() {
  local service; service=$(__leos_display_manager) || { __leos_puts_err "No supported display manager was found."; return 1; }
  sudo systemctl start "$service"
}
gui-stop() {
  local service; service=$(__leos_display_manager) || { __leos_puts_err "No supported display manager was found."; return 1; }
  sudo systemctl stop "$service"
}
gui-disable() { command -v systemctl >/dev/null 2>&1 || { __leos_puts_err "systemd is required."; return 1; }; sudo systemctl set-default multi-user.target && gui-stop; }
gui-enable()  { command -v systemctl >/dev/null 2>&1 || { __leos_puts_err "systemd is required."; return 1; }; sudo systemctl set-default graphical.target && gui-start; }

:
