# Leo's Profiles — user commands (zsh)

# rmdsstore [--dry-run] [--purge-recycle-bins] [root ...]
# Remove .DS_Store and its Windows siblings under the macOS data volume and
# every mounted volume, or under the given roots. Every argument goes to
# util/rmdsstore.py unchanged, so `rmdsstore --help` is its own usage text.
#
# The sweep runs with the OS interpreter, not a PATH-resolved one: sudo must
# not execute a python3 from a user-writable directory (the Homebrew prefix,
# pyenv shims). `-I` isolates the interpreter (no PYTHON* environment, no user
# site, no script directory on sys.path from 3.11). The script itself lives in
# this user-owned checkout by design (see the README trust model).
rmdsstore() {
  local arg
  if [[ $(uname -s) != Darwin ]]; then
    puts-err "rmdsstore only supports the macOS data-volume layout."
    return 1
  fi
  if [[ ! -x /usr/bin/python3 ]]; then
    puts-err "/usr/bin/python3 (the system Python) is required for rmdsstore."
    return 1
  fi
  # Help needs no privileges.
  for arg in "$@"; do
    [[ $arg != -- ]] || break
    if [[ $arg == (-h|--help) ]]; then
      /usr/bin/python3 -I "$LEOS_PROFILES/util/rmdsstore.py" "$@"
      return
    fi
  done
  __leos_sudo /usr/bin/python3 -I "$LEOS_PROFILES/util/rmdsstore.py" "$@"
}

# leos-ds-store-prevention [on|off|status]
# Ask Finder not to write .DS_Store files on network shares and USB volumes
# (com.apple.desktopservices DSDontWriteNetworkStores and DSDontWriteUSBStores),
# the files other machines see. Optional and never run automatically; local
# disks are unaffected, so rmdsstore still has work there. Finder reads the
# setting when it starts: log out and back in, or `killall Finder`.
leos-ds-store-prevention() {
  local action=${1:-status} key value
  local -a keys=(DSDontWriteNetworkStores DSDontWriteUSBStores)
  if (( $# > 1 )) || [[ $action != (on|off|status) ]]; then
    puts-err "Usage: leos-ds-store-prevention [on|off|status]"
    return 2
  fi
  if [[ $(uname -s) != Darwin ]]; then
    puts-err "leos-ds-store-prevention is only available on macOS."
    return 1
  fi
  case $action in
    on)
      for key in $keys; do
        defaults write com.apple.desktopservices "$key" -bool true || return 1
      done
      puts "Finder stops writing .DS_Store files on network shares and USB volumes after you log out and back in (or run killall Finder)." ;;
    off)
      # A key that was never set is already the default.
      for key in $keys; do
        defaults delete com.apple.desktopservices "$key" 2>/dev/null || true
      done
      puts "Restored Finder's default; it takes effect after you log out and back in (or run killall Finder)." ;;
    status)
      for key in $keys; do
        value=$(defaults read com.apple.desktopservices "$key" 2>/dev/null) || value=
        if [[ $value == (1|true|YES) ]]; then
          print -r -- "$key: on"
        else
          print -r -- "$key: off"
        fi
      done ;;
  esac
}

# Clear known history files. The aggressive mode adds the legacy broad globs,
# but still never recursively deletes a matched directory.
clear-history() {
  local aggressive=${1:-} f exit_code=0
  local -a candidates
  candidates=("$HOME/.zsh_history" "$HOME/.bash_history" "$HOME/.python_history"
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
    puts-err "This command is only available on macOS."
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

# bye's options, "--name:description", shared with its usage line and its
# completion (_leos_bye in interactive.zsh), so the three cannot drift apart.
# Descriptions must not contain square brackets (_values syntax).
typeset -ga __leos_bye_options=(
  '--keep-history:Preserve history files'
  '--non-interactive:No prompts: skip the steps that need sudo, and no Homebrew questions'
  '--no-exit:Do not quit the terminal'
  '--aggressive-history:Also remove legacy history and HSTS matches'
  '--purge-recycle-bins:Permit removal of macOS recycle-bin directories'
  '--shutdown-wsl:Shut down WSL after maintenance'
)

# Clean up and quit the terminal. This intentionally performs the full Leo's
# maintenance routine: package updates, AI CLI updates, history cleanup, and
# on macOS a privileged metadata sweep plus Finder/Dock restart.
# Options are exact; destructive extensions are explicit opt-ins.
#
# Order matters for sudo (SEC-2): a cached sudo credential lets any process in
# this terminal run `sudo -n` without a prompt. So the third-party updaters
# (the AI CLIs, then Homebrew and its casks) run first, after `sudo -k` has
# dropped any credential an earlier command left; sudo is primed only right
# before the steps that need it (OS package upgrades, the metadata sweep) and
# dropped again right after them. --non-interactive skips those steps instead
# of asking for a password.
bye() {
  local arg name usage=Usage:\ bye exit_code=0
  local -A opt
  local -a names privileged
  names=(${__leos_bye_options%%:*})
  for name in $names; do usage+=" [$name]"; done
  for arg in "$@"; do
    if (( ${names[(Ie)$arg]} )); then
      opt[$arg]=1
    else
      puts-err "$usage"
      return 2
    fi
  done
  if (( ${+opt[--shutdown-wsl]} && ${+opt[--no-exit]} )); then
    puts-err "--shutdown-wsl and --no-exit are contradictory."
    return 2
  fi
  if (( ${+opt[--keep-history]} && ${+opt[--aggressive-history]} )); then
    puts-err "--keep-history and --aggressive-history are contradictory."
    return 2
  fi

  puts "Bye!"
  # A local export is automatically restored even on an early function return.
  if (( ${+opt[--non-interactive]} )); then
    local -x HOMEBREW_NO_ASK=1
  fi
  (( ! ${+opt[--keep-history]} )) || puts "History will be preserved."

  # No cached sudo credential while third-party code updates itself.
  __leos_sudo -k 2>/dev/null || true
  if (( $+functions[ai-checkup] )); then puts "Doing AI tools checkup..."; ai-checkup || exit_code=1; fi
  if (( $+functions[brew-checkup] )); then puts "Doing brew checkup..."; brew-checkup || exit_code=1; fi

  for name in apt dnf pacman; do
    (( ! $+functions[$name-checkup] )) || privileged+=($name-checkup)
  done
  [[ $(uname -s) != Darwin ]] || privileged+=(rmdsstore)
  if (( ! $#privileged )); then
    :
  elif (( ${+opt[--non-interactive]} )); then
    puts "Skipped the steps that need sudo (--non-interactive): ${(j:, :)privileged}. Run them yourself later."
  else
    # Sudo is primed only now, and dropped again however the steps end
    # (a failure or Ctrl-C included).
    __leos_sudo -v || { puts-err "sudo authentication is required for: ${(j:, :)privileged}."; return 1; }
    {
      for name in $privileged; do
        case $name in
          rmdsstore)
            puts "Removing .DS_Store files..."
            if (( ${+opt[--purge-recycle-bins]} )); then
              rmdsstore --purge-recycle-bins || exit_code=1
            else
              rmdsstore || exit_code=1
            fi ;;
          *) puts "Doing ${name%-checkup} checkup..."; "$name" || exit_code=1 ;;
        esac
      done
    } always {
      __leos_sudo -k 2>/dev/null || true
    }
  fi

  if (( ! ${+opt[--keep-history]} )); then
    puts "Clear all history files.."
    if (( ${+opt[--aggressive-history]} )); then
      clear-history --aggressive || exit_code=1
    else
      clear-history || exit_code=1
    fi
  fi

  if [[ $(uname -s) == Darwin ]]; then
    puts "Restarting Finder, Dock, SystemUIServer..."
    killall Finder Dock SystemUIServer || exit_code=1
  fi

  if (( ${+opt[--no-exit]} )); then
    puts "Skipped exiting."
    return $exit_code
  elif (( ${+opt[--shutdown-wsl]} )) && command -v /mnt/c/Windows/system32/wsl.exe >/dev/null 2>&1; then
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
      *) puts-err "Usage: upgrade-leos-profiles [--full-upgrade] [--yes] [--verify-signatures]"; return 2 ;;
    esac
  done
  # Without a saved setup there is nothing to reconcile: say so before
  # changing the checkout, not after (MI-12).
  if [[ ! -f $LEOS_PROFILES/local/install-profile.tsv ]]; then
    puts-err "No saved setup in $LEOS_PROFILES/local/install-profile.tsv, so there is nothing to reconcile. Set up first with $LEOS_PROFILES/install.sh setup; to update only the checkout, use git -C $LEOS_PROFILES pull --ff-only."
    return 1
  fi
  if (( verify )); then
    if [[ -z $(git -C "$LEOS_PROFILES" config --get gpg.ssh.allowedSignersFile 2>/dev/null) ]] &&
        ! whence -p gpg >/dev/null; then
      puts-err "--verify-signatures needs a way to check signatures: set gpg.ssh.allowedSignersFile for SSH-signed commits, or install gpg with the signer's public key."
      return 1
    fi
    merge_args+=(--verify-signatures)
  fi
  branch=$(git -C "$LEOS_PROFILES" symbolic-ref --quiet --short HEAD) || {
    puts-err "The profile checkout must be on a branch."
    return 1
  }
  upstream=$(git -C "$LEOS_PROFILES" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || {
    puts-err "Branch $branch has no configured upstream."
    return 1
  }
  if [[ -n $(git -C "$LEOS_PROFILES" status --porcelain --untracked-files=normal) ]]; then
    puts-err "Refusing to update because the profile checkout has local changes. Commit or stash them first."
    return 1
  fi
  git -C "$LEOS_PROFILES" fetch --quiet || return $?
  # Review before running anything new: these commits are about to run with
  # sudo through reconcile (SEC-3).
  incoming=$(git -C "$LEOS_PROFILES" log --oneline 'HEAD..@{upstream}') || return $?
  if [[ -z $incoming ]]; then
    puts "$LEOS_PROFILES is up to date with $upstream; reconciling the saved setup."
  else
    puts "Incoming commits from $upstream:"
    print -r -- "$incoming"
    if (( ! yes )); then
      if [[ -t 0 ]]; then
        read -r "answer?Fast-forward to these commits and reconcile? [y/N] "
        [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { puts "Cancelled; nothing was changed."; return 1; }
      else
        puts-err "Not a terminal: review the commits above, then run upgrade-leos-profiles --yes to apply them."
        return 1
      fi
    fi
    git -C "$LEOS_PROFILES" "${merge_args[@]}" '@{upstream}' || return $?
    puts "Updated $LEOS_PROFILES from $upstream; reconciling the saved setup."
  fi
  command bash "$LEOS_PROFILES/install.sh" "${reconcile_args[@]}"
}

# A read-only health check of the saved setup: runs `install.sh inspect
# --saved` and summarises its postconditions, warnings and conflicts (MI-14).
leos-doctor() {
  local out rc=0 line needed=0
  local -a fields
  if (( $# )); then
    puts-err "Usage: leos-doctor"
    return 2
  fi
  out=$(command bash "$LEOS_PROFILES/install.sh" inspect --saved) || rc=$?
  if (( rc )); then
    puts-err "leos-doctor: install.sh inspect --saved failed (exit $rc); see the message above."
    return $rc
  fi
  puts "Leo's Profiles at $LEOS_PROFILES"
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
      shadow) print -r -- "  note     $fields[3] is shadowed by the pinned $fields[4]" ;;
      existing) print -r -- "  note     $fields[2] at $fields[3]: $fields[4]" ;;
    esac
  done
  if (( needed )); then
    puts "Repair with: upgrade-leos-profiles (pulls first), or bash $LEOS_PROFILES/install.sh reconcile --yes"
    return 1
  fi
  puts "Everything the saved setup installs is in place."
}

# Update only installed AI coding CLIs using their supported native updaters.
ai-checkup() {
  local found=0 exit_code=0
  if command -v claude >/dev/null 2>&1; then
    found=1; puts "Updating Claude Code..."; claude update || exit_code=1
  fi
  if command -v codex >/dev/null 2>&1; then
    found=1; puts "Updating Codex..."; codex update || exit_code=1
  fi
  # Skip a Homebrew-managed opencode: brew-checkup already owns that copy, and
  # `opencode upgrade` would fight it. Only self-installed copies are updated.
  # `command -v` for detection (so it can be stubbed like claude/codex above),
  # $commands for the prefix test — empty for a stub, which reads as non-brew.
  if command -v opencode >/dev/null 2>&1 && [[ ${commands[opencode]:-} != ${HOMEBREW_PREFIX:-/opt/homebrew}/* ]]; then
    found=1; puts "Updating opencode..."; opencode upgrade || exit_code=1
  fi
  (( found )) || puts "No supported installed AI CLI was detected; nothing to update."
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
  local service; service=$(__leos_display_manager) || { puts-err "No supported display manager was found."; return 1; }
  __leos_sudo systemctl start "$service"
}
gui-stop() {
  local service; service=$(__leos_display_manager) || { puts-err "No supported display manager was found."; return 1; }
  __leos_sudo systemctl stop "$service"
}
gui-disable() { command -v systemctl >/dev/null 2>&1 || { puts-err "systemd is required."; return 1; }; __leos_sudo systemctl set-default multi-user.target && gui-stop; }
gui-enable()  { command -v systemctl >/dev/null 2>&1 || { puts-err "systemd is required."; return 1; }; __leos_sudo systemctl set-default graphical.target && gui-start; }

:
