#!/usr/bin/env bash
# Drive `install.sh setup` through a pseudo-terminal, as a user would, in a
# fixture HOME with a temporary copy of the public checkout and PATH fakes for
# package managers, network clients and privilege escalation (the same
# hermetic setup as tests/readonly-test.sh). Nothing here touches the real
# HOME, keys or Git configuration, and no scenario applies anything except
# one --dry-run.
#
# Scenarios: Recommended and Customize (--print-command must print exactly
# the expected apply argv), a run without a terminal (exit 2 with guidance),
# an existing non-Git ~/.pyenv (offers and passes
# --skip-existing-version-managers), a saved profile (offers reconcile), and
# a dry run through the real apply path. Unit checks cover the manual-action
# screen, resuming after a key was generated, and NO_COLOR.
# shellcheck disable=SC1091,SC2016,SC2034
set -Eeuo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
FIXTURE=$(CDPATH='' cd -- "$(mktemp -d "${TMPDIR:-/tmp}/leos-setup-wizard.XXXXXX")" && pwd -P)
trap 'rm -rf -- "$FIXTURE"' EXIT
fail() {
  if [[ -s ${TRANSCRIPT:-} ]]; then
    printf '%s\n' '--- last wizard transcript ---' >&2
    cat "$TRANSCRIPT" >&2
  fi
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The system Python on macOS (what the other pty tests use), python3 elsewhere.
PYTHON=python3
if [[ -x /usr/bin/python3 ]]; then PYTHON=/usr/bin/python3; fi
command -v "$PYTHON" >/dev/null 2>&1 || fail "python3 is required for the pty driver"

FIXTURE_HOME="$FIXTURE/home"
PROFILE="$FIXTURE/profile"
FAKEBIN="$FIXTURE/fakebin"
SCRATCH_TMP="$FIXTURE/tmp"
CALLS="$FIXTURE/calls.log"
DRIVER="$FIXTURE/pty-driver.py"
STEPS="$FIXTURE/steps"
TRANSCRIPT="$FIXTURE/transcript"
mkdir -p "$FAKEBIN" "$SCRATCH_TMP"
: > "$CALLS"

# The pty driver: runs the command on a pseudo-terminal (80x24) as its
# controlling terminal, then follows the steps file: `expect <regex>` waits
# for output matching the regex after the previous match, `send <text>` types
# the text and Enter. Writes the transcript (CR removed) and prints the exit
# status.
cat > "$DRIVER" <<'PY'
import fcntl, os, pty, re, select, struct, sys, termios, time

transcript_path, steps_path = sys.argv[1], sys.argv[2]
command = sys.argv[sys.argv.index("--") + 1:]
steps = []
with open(steps_path) as handle:
    for line in handle:
        line = line.rstrip("\n")
        if line:
            kind, _, argument = line.partition(" ")
            steps.append((kind, argument))

pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.execvp(command[0], command)

buffer = ""
position = 0
finished = False


def read_some(timeout):
    global buffer, finished
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return
    try:
        data = os.read(fd, 65536)
    except OSError:
        data = b""
    if not data:
        finished = True
        return
    buffer += data.decode("utf-8", "replace").replace("\r", "")


def save():
    with open(transcript_path, "w") as handle:
        handle.write(buffer)


def give_up(message):
    save()
    sys.stderr.write("pty driver: %s\n--- transcript tail ---\n%s\n" % (message, buffer[-4000:]))
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    sys.exit(99)


for kind, argument in steps:
    if kind == "expect":
        pattern = re.compile(argument, re.M)
        deadline = time.time() + 120
        while True:
            match = pattern.search(buffer, position)
            if match:
                position = match.end()
                break
            if finished or time.time() > deadline:
                give_up("no match for %r" % argument)
            read_some(max(0.0, min(1.0, deadline - time.time())))
    elif kind == "send":
        os.write(fd, (argument + "\r").encode())
    else:
        give_up("unknown step %r" % kind)

deadline = time.time() + 300
while not finished:
    if time.time() > deadline:
        give_up("the wizard did not exit")
    read_some(1.0)
_, status = os.waitpid(pid, 0)
save()
print(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PY

# PATH fakes, as in readonly-test.sh: queries answer "not installed" or "no
# network"; anything else is recorded as a mutation attempt and fails.
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
# An SSH agent holding one key.
AGENT_FINGERPRINT=SHA256:fixtureAgentKey0123456789abcdefghijklmnopqrs
cat > "$FAKEBIN/ssh-add" <<FAKE
#!/bin/sh
case "\$*" in
  '-l -E sha256') printf '256 $AGENT_FINGERPRINT fixture@agent (ED25519)\n' ;;
  -L) printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFixture fixture@agent\n' ;;
  *) exit 2 ;;
esac
FAKE
chmod 755 "$FAKEBIN/ssh-add"

# A fresh HOME and checkout for each scenario.
new_fixture() {
  rm -rf -- "$FIXTURE_HOME" "$PROFILE"
  mkdir -p "$FIXTURE_HOME" "$PROFILE"
  cp -R "$ROOT/install.sh" "$ROOT/installer" "$ROOT/zsh" "$ROOT/util" "$PROFILE/"
  rm -rf -- "$PROFILE/zsh/plugins" "$PROFILE/zsh/_private.zsh"
}

# wizard <setup args...>: run the wizard on the pty with the steps in $STEPS;
# sets WIZARD_STATUS. NO_COLOR keeps the transcript plain.
wizard() {
  WIZARD_STATUS=$(env -i HOME="$FIXTURE_HOME" LANG=C TERM=xterm NO_COLOR=1 \
    PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$SCRATCH_TMP" \
    XDG_STATE_HOME="$FIXTURE_HOME/.local/state" XDG_CONFIG_HOME="$FIXTURE_HOME/.config" \
    XDG_CACHE_HOME="$FIXTURE_HOME/.cache" XDG_DATA_HOME="$FIXTURE_HOME/.local/share" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$FIXTURE_HOME/.gitconfig" LEOS_READONLY_CALLS="$CALLS" \
    SSH_AUTH_SOCK="$FIXTURE/agent.sock" \
    "$PYTHON" -I "$DRIVER" "$TRANSCRIPT" "$STEPS" -- "${BASH:-bash}" "$PROFILE/install.sh" setup "$@") ||
    fail "the pty driver failed"
}

# The command --print-command printed (the line after the heading and a
# blank line).
printed_command() {
  awk '/^The equivalent command/ { getline; getline; print; exit }' "$TRANSCRIPT"
}

# expected_command <install.sh arguments as typed>: the line the wizard must
# print. Plain words stay bare, others are single-quoted, in every Bash.
expected_command() {
  printf 'bash %s/install.sh %s\n' "$PROFILE" "$*"
}

# The wizard fits an 80-column terminal: only the printed command may be
# longer (the terminal wraps it; breaking it would spoil copy and paste).
check_width() {
  local label=$1
  awk -v label="$label" '
    length($0) > 80 && $0 !~ /^bash / { printf "%s: line %d is %d columns: %s\n", label, NR, length($0), $0; bad = 1 }
    END { exit bad }
  ' "$TRANSCRIPT" >&2 || fail "$label does not fit 80 columns"
  ! grep -q $'\033' "$TRANSCRIPT" || fail "$label printed escape sequences despite NO_COLOR"
}

no_mutations() {
  ! grep '^MUTATION ' "$CALLS" >&2 || fail "$1 invoked a mutating command"
  [[ ! -e $PROFILE/local/install-profile.tsv || $2 == saved ]] || fail "$1 wrote a profile"
}

RECOMMENDED_STEPS=packages,pyenv,rbenv,bun,fnm,yarn,pnpm,uv,plugins,fonts,zsh-config,default-shell
RECOMMENDED_GROUPS=core-utils,shell,dev-tools,languages,media,network,system
MACOS=0
[[ $(uname -s) != Darwin ]] || MACOS=1

# (i) Recommended: --print-command prints exactly the apply argv.
new_fixture
cat > "$STEPS" <<'EOF'
expect Leo's Profiles setup
expect == This machine ==
expect How do you want to set up\?
expect Choose 1-2 \[1\], q to quit:
send
expect == The plan \(apply\) ==
expect The equivalent command
EOF
wizard --print-command
[[ $WIZARD_STATUS == 0 ]] || fail "Recommended --print-command exited $WIZARD_STATUS"
expected=$(expected_command apply --yes --groups "$RECOMMENDED_STEPS" --package-groups "$RECOMMENDED_GROUPS" \
  --ssh skip --gpg skip --signing skip --fonts auto --default-shell auto --full-upgrade)
[[ $(printed_command) == "$expected" ]] ||
  fail "Recommended printed: $(printed_command)"$'\n'"expected: $expected"
grep -q '^OS packages ([0-9]*):' "$TRANSCRIPT" || fail 'the plan did not list the OS packages'
grep -q '^Runs as root' "$TRANSCRIPT" || fail 'the plan did not list the root actions'
grep -q '^Cannot be undone automatically:' "$TRANSCRIPT" || fail 'the plan did not list irreversible effects'
check_width 'Recommended'
no_mutations 'Recommended'

# (ii) Customize: toggle components and package groups, an agent key and SSH
# signing (which asks for the missing Git identity).
new_fixture
{
  printf '%s\n' 'expect How do you want to set up\?' 'expect Choose 1-2 \[1\]' 'send 2'
  # Components: 4 = rbenv, 5 = bun off.
  printf '%s\n' 'expect Components' 'expect Enter = done' 'send 4 5'
  printf '%s\n' 'expect  4 \[ \] rbenv' 'expect Enter = done' 'send'
  # Package groups: 5 = python on, 6 = media off.
  printf '%s\n' 'expect Package groups' 'expect Enter = done' 'send 5 6'
  printf '%s\n' 'expect  6 \[ \] media' 'expect Enter = done' 'send'
  printf '%s\n' 'expect SSH key for GitHub' 'expect Choose 1-4 \[1\]' 'send 4'
  printf '%s\n' 'expect Which agent key\?' 'expect fixture@agent' 'expect Choose 1-2,' 'send 1'
  printf '%s\n' 'expect Add that block to ~/.ssh/config\? \[y/N\]' 'send'
  printf '%s\n' 'expect GPG key' 'expect Choose 1-3 \[1\]' 'send'
  printf '%s\n' 'expect Sign your Git commits\?' 'expect Sign with the SSH key \(recommended' 'expect Choose 1-2 \[1\]' 'send 2'
  printf '%s\n' 'expect Git user.name:' 'send Fixture User'
  printf '%s\n' 'expect Git user.email:' 'send fixture@example.invalid'
  printf '%s\n' 'expect Install a Nerd Font\?' 'expect Choose 1-3 \[1\]' 'send'
  printf '%s\n' 'expect Make zsh your login shell\?' 'expect Choose 1-3 \[1\]' 'send'
  printf '%s\n' 'expect Upgrade the installed OS packages too\?' 'expect Choose 1-2 \[1\]' 'send 2'
  if [[ $MACOS -eq 1 ]]; then
    printf '%s\n' 'expect Where should Homebrew download from\?' 'expect Choose 1-2 \[1\]' 'send'
  fi
  printf '%s\n' 'expect == The plan \(apply\) ==' 'expect The equivalent command'
} > "$STEPS"
wizard --print-command
[[ $WIZARD_STATUS == 0 ]] || fail "Customize --print-command exited $WIZARD_STATUS"
expected=$(expected_command apply --yes --groups packages,pyenv,fnm,yarn,pnpm,uv,plugins,fonts,zsh-config,default-shell \
  --package-groups core-utils,shell,dev-tools,languages,python,network,system \
  --ssh agent --ssh-key "$AGENT_FINGERPRINT" --ssh-config no --gpg skip --signing ssh \
  "--git-name 'Fixture User'" --git-email fixture@example.invalid --fonts auto --default-shell auto --no-full-upgrade)
[[ $(printed_command) == "$expected" ]] ||
  fail "Customize printed: $(printed_command)"$'\n'"expected: $expected"
grep -q 'read:public_key,read:ssh_signing_key,user:email' "$TRANSCRIPT" ||
  fail 'the plan did not name the GitHub read scopes SSH signing needs'
grep -q '^Credentials: *SSH agent, GPG skip, commit signing ssh' "$TRANSCRIPT" ||
  fail 'the plan did not show the credential choices'
check_width 'Customize'
no_mutations 'Customize'

# (iii) No terminal: exit 2 with the non-interactive commands.
new_fixture
status=0
output=$(env -i HOME="$FIXTURE_HOME" PATH="$FAKEBIN:/usr/bin:/bin" TMPDIR="$SCRATCH_TMP" \
  "${BASH:-bash}" "$PROFILE/install.sh" setup --print-command < /dev/null 2>&1) || status=$?
[[ $status == 2 ]] || fail "setup without a terminal exited $status: $output"
for text in 'needs a terminal' "install.sh inspect" "install.sh apply --yes" 'setup --print-command'; do
  [[ $output == *"$text"* ]] || fail "the no-terminal guidance does not mention '$text': $output"
done

# (iv) An existing non-Git ~/.pyenv: disclosed, and keeping it passes
# --skip-existing-version-managers.
new_fixture
mkdir -p "$FIXTURE_HOME/.pyenv"
cat > "$STEPS" <<'EOF'
expect == This machine ==
expect In the way of pyenv: .*/\.pyenv exists but is not a Git
expect Choose 1-2 \[1\]
send
expect Existing installation in the way
expect \(--skip-existing-version-managers\)\? \[Y/n\]
send y
expect == The plan \(apply\) ==
expect Kept as is: *pyenv
expect The equivalent command
EOF
wizard --print-command
[[ $WIZARD_STATUS == 0 ]] || fail "the conflict scenario exited $WIZARD_STATUS"
expected=$(expected_command apply --yes --groups "$RECOMMENDED_STEPS" --package-groups "$RECOMMENDED_GROUPS" \
  --ssh skip --gpg skip --signing skip --fonts auto --default-shell auto --full-upgrade --skip-existing-version-managers)
[[ $(printed_command) == "$expected" ]] ||
  fail "conflict printed: $(printed_command)"$'\n'"expected: $expected"
no_mutations 'Conflict'

# (v) A saved profile: reconcile is offered first and is the default.
new_fixture
mkdir -p "$PROFILE/local"
printf '%s\t%s\n' schema 2 groups packages,zsh-config package-groups shell full-upgrade no \
  fonts no font '' default-shell no git-name '' git-email '' ssh skip ssh-key '' \
  ssh-passphrase empty gpg skip gpg-key '' gpg-passphrase empty node-channel current-lts \
  node-policy preserve-compatible ai-cli-update-channel native package-channel system > "$PROFILE/local/install-profile.tsv"
chmod 600 "$PROFILE/local/install-profile.tsv"
cat > "$STEPS" <<'EOF'
expect A saved setup exists
expect 1\) Reconcile the saved setup
expect Choose 1-3 \[1\]
send
expect Also upgrade the installed OS packages .*\[y/N\]
send
expect == The plan \(reconcile the saved setup\) ==
expect Components: *packages, zsh-config
expect The equivalent command
EOF
wizard --print-command
[[ $WIZARD_STATUS == 0 ]] || fail "the saved-profile scenario exited $WIZARD_STATUS"
expected=$(expected_command reconcile --yes)
[[ $(printed_command) == "$expected" ]] ||
  fail "reconcile printed: $(printed_command)"$'\n'"expected: $expected"
no_mutations 'Saved profile' saved

# (v, continued) Change the selection: Customize starts from the saved one.
cat > "$STEPS" <<'EOF'
expect Choose 1-3 \[1\]
send 2
expect How do you want to set up\?
expect Choose 1-2 \[1\]
send 2
expect Components
expect  1 \[x\] packages
expect  3 \[ \] pyenv
expect Enter = done
send q
EOF
wizard --print-command
[[ $WIZARD_STATUS == 1 ]] || fail "quitting the wizard exited $WIZARD_STATUS"
grep -q 'Setup cancelled. Nothing was changed.' "$TRANSCRIPT" || fail 'quitting did not say nothing changed'

# (vi) A dry run through the real apply path: the wizard runs
# `apply --yes ... --dry-run` and streams its output.
new_fixture
: > "$CALLS"
cat > "$STEPS" <<'EOF'
expect Choose 1-2 \[1\]
send
expect Proceed\? \[y/N\]
send y
expect Running: bash .*install\.sh apply --yes .* --dry-run
expect Profile apply complete
expect Dry run finished: nothing was changed
EOF
wizard --dry-run
[[ $WIZARD_STATUS == 0 ]] || fail "the dry run exited $WIZARD_STATUS"
no_mutations 'Dry run'

# The wizard is sourced into the engine: none of its functions may replace
# one of the engine's (a shadowed helper silently changes apply).
engine_functions=$(for file in "$ROOT/install.sh" "$ROOT"/installer/*.sh; do
  [[ $file == */setup.sh ]] || grep -o '^[a-z_][a-z0-9_]*()' "$file"
done | sort -u)
wizard_functions=$(grep -o '^[a-z_][a-z0-9_]*()' "$ROOT/installer/setup.sh" | sort -u)
shadowed=$(comm -12 <(printf '%s\n' "$engine_functions") <(printf '%s\n' "$wizard_functions"))
[[ -z $shadowed ]] || fail "installer/setup.sh redefines engine functions: $shadowed"

# Unit checks, with the engine sourced as a library.
(
  export LEOS_PROFILES_INSTALL_LIB_ONLY=1 HOME="$FIXTURE_HOME"
  TRANSCRIPT=""
  # shellcheck source=../install.sh disable=SC1091
  source "$PROFILE/install.sh"
  W_WIDTH=78
  log="$FIXTURE/attempt.log"
  {
    printf 'manual-action\tgithub-login\t\thttps://github.com/login\n'
    printf 'manual-action\tregister-ssh-key\t%s\thttps://github.com/settings/ssh/new\n' "$FIXTURE_HOME/.ssh/id_ed25519.pub"
    printf '%s\n' 'WARNING: Manual action required (exit 3). Complete each manual-action record above, then resume.'
    printf '%s\n' '  - Log in to GitHub CLI yourself with gh auth login, then rerun.'
    printf '%s\n' '  - Add the public key to your GitHub account, then rerun.'
  } > "$log"
  screen=$(setup_show_manual_actions "$log")
  [[ $screen == *'1. github-login'*'Log in to GitHub CLI yourself'*'Where:'*'https://github.com/login'*'2. register-ssh-key'* ]] ||
    fail "manual-action screen: $screen"
  [[ $(grep -c 'File:' <<< "$screen") == 1 ]] || fail "an empty public path was shown: $screen"
  grep -qF "File: ~/.ssh/id_ed25519.pub" <<< "$screen" || fail "the key file was not shown: $screen"

  # Resume after generation: the saved references are reused, never
  # generated twice.
  PROFILE_FILE="$FIXTURE/resume-profile.tsv"
  printf '%s\t%s\n' ssh reuse ssh-key "$FIXTURE_HOME/.ssh/id_ed25519" gpg reuse \
    gpg-key 0123456789ABCDEF0123456789ABCDEF01234567 > "$PROFILE_FILE"
  SETUP_MODE=apply
  SETUP_RECOMMENDED_STEPS=$SELECTED_STEPS SETUP_RECOMMENDED_GROUPS=$SELECTED_GROUPS
  setup_reset_choices
  S_SSH=generate S_SSH_KEY="$FIXTURE_HOME/.ssh/id_ed25519" S_GPG=generate S_SIGNING=gpg
  setup_resume_choices > /dev/null
  [[ $S_SSH == reuse && $S_SSH_KEY == "$FIXTURE_HOME/.ssh/id_ed25519" ]] || fail "SSH resume: $S_SSH $S_SSH_KEY"
  [[ $S_GPG == reuse && $S_GPG_KEY == 0123456789ABCDEF0123456789ABCDEF01234567 ]] || fail "GPG resume: $S_GPG $S_GPG_KEY"
  setup_run_args
  args=" ${SETUP_ARGS[*]} "
  [[ $args == *' --ssh reuse --ssh-key '*' --gpg reuse --gpg-key 0123456789ABCDEF0123456789ABCDEF01234567 '* ]] ||
    fail "resumed argv: $args"

  # NO_COLOR and TERM=dumb turn colour off.
  W_BOLD=""
  NO_COLOR=1 TERM=xterm setup_init_terminal < /dev/null
  [[ -z $W_BOLD ]] || fail 'NO_COLOR did not disable colour'
  NO_COLOR='' TERM=xterm setup_init_terminal < /dev/null
  [[ -n $W_BOLD ]] || fail 'colour stayed off without NO_COLOR'
)

# Only the run log the wizard names at the end stays behind.
for leftover in "$SCRATCH_TMP"/* "$SCRATCH_TMP"/.[!.]*; do
  [[ -e $leftover && ${leftover##*/} != leos-setup-log.* ]] || continue
  fail "the wizard left a temporary file: $leftover"
done
printf 'setup wizard (%s): PASS\n' "$(uname -s)"
