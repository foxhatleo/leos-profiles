#!/usr/bin/env zsh
# Informational public-profile timing with real detected tools and isolated state.
# Private overrides and background shim maintenance are deliberately excluded.
#
#   zsh tests/startup-benchmark.zsh [--pty] [profile-checkout]
#
# Default: wall time of a non-terminal `zsh -dfi -c 'source start.zsh'`.
# --pty:   run an interactive shell on a pseudo-terminal, like zsh-bench, and
#          measure time to the first prompt and command lag (Enter on an empty
#          line until the next prompt is ready for input).
# Both modes measure cold (no cache, no completion dump), warm, and aged-dump
# (warm caches but a completion dump older than a day, which takes the full
# compinit path instead of `compinit -C`). Where strace exists (Linux), the
# non-pty mode also counts process creations in one warm startup.
emulate -L zsh
setopt err_return no_unset pipe_fail
mode=plain
if [[ ${1:-} == --pty ]]; then
  mode=pty
  shift
fi
root=${1:-${0:A:h:h}}
[[ $# -le 1 && -f $root/zsh/start.zsh ]] || {
  print -u2 'Usage: zsh tests/startup-benchmark.zsh [--pty] [profile-checkout]'; exit 2
}
python3 - "$mode" "$root" "${commands[zsh]}" "$PATH" <<'PY'
import os
import pathlib
import platform
import re
import select
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

mode, source, shell, tool_path = sys.argv[1:]
source = pathlib.Path(source).resolve()
SAMPLES = int(os.environ.get("LEOS_BENCH_SAMPLES", "10"))
READY = b"\x1b]7777;leos-ready\x07"
TIMEOUT = 30.0
# Wrapper rc for the pty mode: load the profile, then announce each prompt that
# is ready for input. A line-init hook fires after the prompt has been drawn.
PTY_ZSHRC = """\
source "$LEOS_PROFILES_HOME/zsh/start.zsh"
autoload -Uz add-zle-hook-widget
__leos_bench_ready() { print -rn -- $'\\e]7777;leos-ready\\a' }
zle -N __leos_bench_ready
add-zle-hook-widget line-init __leos_bench_ready
"""


def summary(label, values):
    return (f"{label}: n={len(values)} median={statistics.median(values):.1f} ms "
            f"min={min(values):.1f} ms max={max(values):.1f} ms")


def dumps(home):
    """Completion dumps: the profile's cache-root dump, or a HOME fallback."""
    return [*home.glob(".cache/leos-profiles/zcompdump-[0-9]*"), *home.glob(".zcompdump*")]


def reset(state, home):
    """Prepare the fixture HOME for one sample of the given scenario."""
    if state == "cold":
        shutil.rmtree(home / ".cache", ignore_errors=True)
        for dump in home.glob(".zcompdump*"):
            dump.unlink()
    elif state == "aged-dump":
        aged = time.time() - 2 * 24 * 3600
        for dump in dumps(home):
            os.utime(dump, (aged, aged))


def read_until_ready(fd, deadline, transcript):
    """Read pty output until the readiness marker; return the arrival time."""
    while True:
        remaining = deadline - time.perf_counter()
        if remaining <= 0:
            raise TimeoutError("no prompt within %.0f s" % TIMEOUT)
        readable, _, _ = select.select([fd], [], [], remaining)
        if not readable:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            raise RuntimeError("shell exited before its prompt")
        if not chunk:
            raise RuntimeError("shell exited before its prompt")
        transcript.extend(chunk)
        if READY in transcript:
            del transcript[:transcript.index(READY) + len(READY)]
            return time.perf_counter()


def pty_sample(env, lag_presses):
    """One interactive shell: first-prompt time and per-Enter command lags."""
    import pty
    import struct
    import fcntl
    import termios
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
    started = time.perf_counter()
    process = subprocess.Popen([shell, "-d", "-i"], env=env, stdin=slave, stdout=slave,
                               stderr=slave, start_new_session=True, close_fds=True)
    os.close(slave)
    transcript = bytearray()
    lags = []
    try:
        first = read_until_ready(master, started + TIMEOUT, transcript) - started
        for _ in range(lag_presses):
            pressed = time.perf_counter()
            os.write(master, b"\r")
            lags.append(1000 * (read_until_ready(master, pressed + TIMEOUT, transcript) - pressed))
        # Keep draining output while the shell exits: a full pty buffer would
        # otherwise block its final writes. Hang up if it does not leave.
        os.write(master, b"exit\r")
        deadline = time.perf_counter() + 5
        while process.poll() is None and time.perf_counter() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    if not os.read(master, 65536):
                        break
                except OSError:
                    break
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGHUP)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        os.close(master)
    return 1000 * first, lags


def count_processes(command, env, home):
    """Process creations and execs in one startup, via strace; None if unavailable."""
    strace = shutil.which("strace")
    if not strace:
        return None
    trace = home.parent / "strace.out"
    result = subprocess.run([strace, "-f", "-qq", "-o", str(trace),
                             "-e", "trace=fork,vfork,clone,clone3,execve"] + command,
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode != 0 or not trace.exists():
        return None
    forks = execs = 0
    for line in trace.read_text(errors="replace").splitlines():
        # Thread creation is not a process; failed calls created nothing.
        if "CLONE_THREAD" in line or re.search(r"= -\d", line):
            continue
        if re.search(r"\b(fork|vfork|clone|clone3)\(", line):
            forks += 1
        elif re.search(r"\bexecve\(", line):
            execs += 1
    return forks, execs


with tempfile.TemporaryDirectory(prefix="leos-startup-") as fixture:
    base = pathlib.Path(fixture)
    profile = base / "profile"
    shutil.copytree(source / "zsh", profile / "zsh")
    # The public runtime references its utility path but never runs maintenance.
    shutil.copytree(source / "util", profile / "util")
    with (profile / "zsh/cache.zsh").open("a") as cache:
        cache.write("\n__leos_rehash_daily() { :; }\n__leos_fnm_prune_daily() { :; }\n")
    home = base / "home"
    home.mkdir(mode=0o700)
    zdotdir = base / "zdotdir"
    zdotdir.mkdir(mode=0o700)
    (zdotdir / ".zshrc").write_text(PTY_ZSHRC)
    env = {
        "HOME": str(home), "ZDOTDIR": str(home), "PATH": tool_path,
        "LEOS_PROFILES_HOME": str(profile), "TERM": "xterm-256color",
        "SHELL": shell, "USER": os.environ.get("USER", "benchmark"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_STATE_HOME": str(home / ".local/state"),
        "FNM_DIR": str(home / ".local/share/fnm"),
        "PYENV_ROOT": str(home / ".pyenv"), "RBENV_ROOT": str(home / ".rbenv"),
    }
    command = [shell, "-dfi", "-c", 'source "$LEOS_PROFILES_HOME/zsh/start.zsh"']
    states = ("cold", "warm", "aged-dump")
    samples = {state: [] for state in states}
    lags = []
    warnings = set()
    for state in states:
        for _ in range(SAMPLES):
            reset(state, home)
            if mode == "pty":
                pty_env = dict(env, ZDOTDIR=str(zdotdir))
                first, sample_lags = pty_sample(pty_env, 2 if state == "warm" else 0)
                samples[state].append(first)
                lags.extend(sample_lags)
            else:
                started = time.perf_counter()
                result = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, check=True)
                samples[state].append(1000 * (time.perf_counter() - started))
                warnings.update(result.stderr.splitlines())
    print(platform.platform(), platform.machine())
    print(subprocess.check_output([shell, "--version"], text=True).strip())
    print("Isolated public profile; real PATH tools; no private overrides, rehash or fnm prune.")
    revision = subprocess.run(["git", "-C", str(source), "describe", "--always", "--dirty"],
                              capture_output=True, text=True)
    print("Checkout:", revision.stdout.strip() or "unversioned")
    for tool in ("brew", "fnm", "node", "npm", "pnpm", "bun", "pyenv", "rbenv", "starship"):
        executable = shutil.which(tool, path=tool_path)
        if executable:
            try:
                version = subprocess.run([executable, "--version"], env=env,
                                         capture_output=True, text=True, timeout=10)
                lines = version.stdout.strip().splitlines()
                print(f"{tool}: {executable}: {lines[0] if lines else 'version unavailable'}")
            except (OSError, subprocess.TimeoutExpired):
                print(f"{tool}: {executable}: version unavailable")
    if mode == "pty":
        print("Mode: pty (interactive shell on a pseudo-terminal; time to first prompt)")
        for state in states:
            print(summary(f"first prompt {state}", samples[state]))
        print(summary("command lag (Enter to next prompt, warm)", lags))
        print("zsh-bench perceptibility references: first prompt 50 ms, command lag 10 ms.")
    else:
        print("Mode: non-terminal `zsh -dfi -c` exit time")
        for state in states:
            print(summary(state, samples[state]))
        reset("warm", home)
        counted = count_processes(command, env, home)
        if counted is None:
            print("process count: unavailable (needs strace; macOS has no unprivileged equivalent)")
        else:
            print(f"process count (one warm startup, strace): forks={counted[0]} execs={counted[1]}")
    if warnings:
        print("Runtime diagnostics (may explain timing differences):", file=sys.stderr)
        for warning in sorted(warnings):
            print(warning, file=sys.stderr)
PY
