# AI-Driven Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `util/quick-install.sh` always AI-assisted: bootstrap minimal prereqs deterministically, then drive the rest of setup with Claude Code or Codex in bypass mode using a runbook generated from the resolved plan.

**Architecture:** Keep the existing deterministic step engine as an internal primitive (source of truth + per-step executor + tests). Add two run modes — interactive (wizard + install CLIs + auth) and silent/unattended (`--silent[=driver]`, assume CLIs set up). `main()` selects the mode, runs prereqs, picks a driver, generates a runbook from the resolved plan, and invokes the agent. All new logic lives inline in the single bootstrap file (no `source` of repo files pre-clone).

**Tech Stack:** POSIX bash (3.2.57 floor), Claude Code CLI, Codex CLI, the existing `util/test-quick-install.sh` assertion harness.

## Global Constraints

- bash 3.2 floor (macOS 3.2.57): NO associative arrays / `declare -A`, NO `mapfile`/`readarray`, NO `${var^^}`/`${var,,}`, NO `read -N`, NO fractional `read -t`. Indexed arrays + the existing word-list string helpers only.
- NO `source`/`.` of any `$PF` path before `prepare_and_clone_repo` completes. All new functions are defined inline in `util/quick-install.sh`.
- Preserve verbatim: `STEP_IDS`, `step_label`, `step_dependencies`, `step_default_enabled`, `run_step`, resumable `quick-install.state`, the literal `install_packages_*` lists, the setup-wizard, existing flags/env vars, the SSH-key flow, `install_ai_tools` body.
- Stay shellcheck-clean at `--severity=warning` (`.shellcheckrc` exists; SC2034 disabled). Keep the test suite green on `/bin/bash` (3.2) AND bash 5.x. Keep `verify-quick-install-packages.py` parsing.
- Verified CLI facts (do not re-derive): Claude headless = `claude -p "<prompt>" --dangerously-skip-permissions`; Claude auth probe = `claude auth status` (exit 0 = authed), login = `claude auth login`. Codex headless = `codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "<prompt>"`; Codex auth probe = `codex login status` (exit 0 = authed), login = `codex login`.
- Tests must never run a real agent, real `npm i -g`, real package install, real clone, or real login. Use PATH-shim stubs and function seams (`RUN_AGENT_CMD`).
- Spec: `docs/superpowers/specs/2026-06-26-ai-driven-bootstrap-design.md`.

## File Structure

- **Modify `util/quick-install.sh`** — all new logic (Tasks 1–11): arg additions, mode selection, `install_min_toolchain`, `--exec-steps`, auth helpers, driver resolution, runbook generation, agent invocation, sudo keep-alive, `main()` rewrite. Sequential (same file).
- **Modify `util/test-quick-install.sh`** — new test sections per task.
- **Modify `README.md`** (Task 12) — document the always-AI model, `--silent[=driver]`, the removed deterministic mode.
- **No new files.** CI (`.github/workflows/ci.yml`) already runs the suite, so new tests are gated automatically.

All `util/quick-install.sh` tasks (1–11) are **sequential** — one owner, in order. Task 12 (README) is parallelizable once flags are final (after Task 2).

---

### Task 1: `--exec-steps` internal primitive

**Files:**
- Modify: `util/quick-install.sh` (arg parser §2; `main` §9 dispatch)
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Produces: `OPT_EXEC_STEPS` (comma list, empty if unset); `exec_steps_run "<ids>"` runs `run_step` for each id and returns the first non-zero status.

- [ ] **Step 1: Write failing tests**

Add to `util/test-quick-install.sh`:

```bash
# --- Task 1: --exec-steps -------------------------------------------------
_reset_opts; args_parse --exec-steps=install_bun,install_yarn
assert_eq "exec-steps parses list" "$OPT_EXEC_STEPS" "install_bun,install_yarn"

# exec_steps_run dispatches to run_step for each id (run_step stubbed)
_EXEC_CALLS=""
run_step() { _EXEC_CALLS="$_EXEC_CALLS $1"; return 0; }
exec_steps_run "install_bun,install_yarn"
assert_eq "exec_steps_run dispatches in order" "$_EXEC_CALLS" " install_bun install_yarn"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/bin/bash util/test-quick-install.sh`
Expected: FAIL — `OPT_EXEC_STEPS: unbound`/empty and `exec_steps_run: command not found`.

- [ ] **Step 3: Implement**

In the arg parser, add `OPT_EXEC_STEPS=""` to the OPT defaults and a case branch:

```bash
    --exec-steps=*) OPT_EXEC_STEPS="${1#*=}" ;;
    --exec-steps) shift; OPT_EXEC_STEPS="$1" ;;
```

Add the runner near the step engine:

```bash
# Internal: run specific step bodies deterministically (used by the AI runbook
# and by tests). Comma-separated ids, executed in given order.
exec_steps_run() {
  local ids="$1" id rc=0 oldifs="$IFS"
  IFS=,
  for id in $ids; do
    run_step "$id" || rc=$?
  done
  IFS="$oldifs"
  return "$rc"
}
```

In `main`, immediately after `args_parse "$@"` and `capture_env`, before mode logic:

```bash
  if [ -n "$OPT_EXEC_STEPS" ]; then
    # Internal primitive: deterministic per-step run, no wizard/AI/auth.
    STATE_ENABLED_STEPS="$(printf '%s' "$OPT_EXEC_STEPS" | tr ',' ' ')"
    exec_steps_run "$OPT_EXEC_STEPS"
    exit $?
  fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/bin/bash util/test-quick-install.sh`
Expected: PASS (both new assertions); existing 83 still pass.

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck --severity=warning util/quick-install.sh && /bin/bash -n util/quick-install.sh`
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): add --exec-steps internal per-step primitive"
```

---

### Task 2: `--silent[=claude|codex]` optional value + `--print-runbook`

**Files:**
- Modify: `util/quick-install.sh` (arg parser §2, `--help` text, `handle_immediate_flags`)
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Consumes: existing `OPT_SILENT` (currently boolean `"1"`/`""`).
- Produces: `OPT_SILENT` (`"1"` when `--silent` in any form), `OPT_SILENT_DRIVER` (`""`|`claude`|`codex`), `OPT_PRINT_RUNBOOK` (`"1"`/`""`).

- [ ] **Step 1: Write failing tests**

```bash
# --- Task 2: --silent=driver + --print-runbook ----------------------------
_reset_opts; args_parse --silent
assert_eq "bare --silent sets flag"   "$OPT_SILENT" "1"
assert_eq "bare --silent no driver"   "$OPT_SILENT_DRIVER" ""
_reset_opts; args_parse --silent=codex
assert_eq "--silent=codex flag"       "$OPT_SILENT" "1"
assert_eq "--silent=codex driver"     "$OPT_SILENT_DRIVER" "codex"
_reset_opts
( args_parse --silent=bogus ) ; assert_eq "--silent=bogus rejected" "$?" "2"
_reset_opts; args_parse --print-runbook
assert_eq "--print-runbook flag"      "$OPT_PRINT_RUNBOOK" "1"
```

Ensure `_reset_opts` (test helper) clears `OPT_SILENT_DRIVER` and `OPT_PRINT_RUNBOOK` too.

- [ ] **Step 2: Run to verify fail**

Run: `/bin/bash util/test-quick-install.sh` — Expected: FAIL (driver empty, bogus not rejected).

- [ ] **Step 3: Implement**

Add defaults `OPT_SILENT_DRIVER=""` and `OPT_PRINT_RUNBOOK=""`. Replace the `--silent` branch:

```bash
    --silent|-s|--non-interactive) OPT_SILENT=1 ;;
    --silent=*)
      OPT_SILENT=1
      OPT_SILENT_DRIVER="${1#*=}"
      case "$OPT_SILENT_DRIVER" in
        claude|codex) ;;
        *) printf "Error: --silent must be claude or codex\n" >&2; usage_short; exit 2 ;;
      esac
      ;;
    --print-runbook) OPT_PRINT_RUNBOOK=1 ;;
```

In `handle_immediate_flags`, after `--list-packages`, add (runbook printing is wired in Task 9; for now just reserve the flag — no early exit yet). Update the `--help` text: change the `--silent` line to `-s, --silent[=claude|codex]` and add `--print-runbook`. Add an `ENVIRONMENT`/examples note that `--silent` requires an already-authed CLI.

- [ ] **Step 4: Run to verify pass** — `/bin/bash util/test-quick-install.sh` → PASS.
- [ ] **Step 5: shellcheck + commit**
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): --silent optional driver value + --print-runbook flag"
```

---

### Task 3: `cli_is_authenticated` + `cli_is_installed`

**Files:**
- Modify: `util/quick-install.sh` (new auth-helpers section)
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Produces: `cli_is_installed <claude|codex>` (0 if on PATH); `cli_is_authenticated <claude|codex>` (0 if the CLI's status probe exits 0). Both pure-ish — testable with PATH-shim stubs.

- [ ] **Step 1: Write failing tests**

```bash
# --- Task 3: cli_is_installed / cli_is_authenticated ----------------------
_stubdir="$(mktemp -d)"; _oldpath="$PATH"
# stub: claude authed (status exit 0), codex present but unauthed (status exit 1)
printf '#!/bin/sh\ncase "$1 $2" in "auth status") exit 0;; esac\nexit 0\n' > "$_stubdir/claude"
printf '#!/bin/sh\ncase "$1 $2" in "login status") exit 1;; esac\nexit 0\n' > "$_stubdir/codex"
chmod +x "$_stubdir/claude" "$_stubdir/codex"; PATH="$_stubdir:$PATH"
assert_exit "claude installed"      0 'cli_is_installed claude'
assert_exit "claude authed"         0 'cli_is_authenticated claude'
assert_exit "codex installed"       0 'cli_is_installed codex'
assert_exit "codex unauthed -> 1"   1 'cli_is_authenticated codex'
PATH="$_oldpath"; rm -rf "$_stubdir"
```

(If `assert_exit <name> <expected_rc> <cmd-string>` does not exist, add it: runs `eval "$3"` in a subshell and compares `$?`.)

- [ ] **Step 2: Run to verify fail** — functions undefined → FAIL.

- [ ] **Step 3: Implement**

```bash
# True if the named AI CLI is on PATH.
cli_is_installed() {
  case "$1" in
    claude|codex) command -v "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# True if the named AI CLI reports an authenticated session.
# claude: `claude auth status` exits 0 when signed in.
# codex:  `codex login status` exits 0 when signed in.
cli_is_authenticated() {
  case "$1" in
    claude) claude auth status >/dev/null 2>&1 ;;
    codex)  codex login status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: shellcheck + commit**
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): cli_is_installed/cli_is_authenticated probes"
```

---

### Task 4: `install_min_toolchain` (skip-aware) + reposition `install_ai_tools`

**Files:**
- Modify: `util/quick-install.sh` (`STEP_IDS`, `step_label`, `step_dependencies`, new `install_min_toolchain`, `install_ai_tools` guard)
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Produces: step id `install_min_toolchain` (label "Install minimal toolchain (brew, node, npm)"); `min_toolchain_needs_node` (0 if node missing), `min_toolchain_needs_npm`. `install_ai_tools` gains an early skip when both CLIs present.

- [ ] **Step 1: Write failing tests**

```bash
# --- Task 4: install_min_toolchain skip-aware -----------------------------
assert_eq "min_toolchain in STEP_IDS" \
  "$(printf '%s\n' "${STEP_IDS[@]}" | grep -c '^install_min_toolchain$')" "1"
assert_eq "min_toolchain label" \
  "$(step_label install_min_toolchain)" "Install minimal toolchain (brew, node, npm)"
assert_eq "ai_tools depends on min_toolchain" \
  "$(step_dependencies install_ai_tools)" "install_min_toolchain"
# skip logic: with node+npm present, needs_* return 1 (false)
_stubdir="$(mktemp -d)"; _oldpath="$PATH"
printf '#!/bin/sh\nexit 0\n' > "$_stubdir/node"; printf '#!/bin/sh\nexit 0\n' > "$_stubdir/npm"
chmod +x "$_stubdir/node" "$_stubdir/npm"; PATH="$_stubdir:$PATH"
assert_exit "node present -> no need" 1 'min_toolchain_needs_node'
assert_exit "npm present -> no need"  1 'min_toolchain_needs_npm'
PATH="$_oldpath"; rm -rf "$_stubdir"
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement**

Insert `install_min_toolchain` into `STEP_IDS` right after `prepare_and_clone_repo` and `install_local_bins` ordering as appropriate (before `install_os_packages`). Add label + dependency (`install_min_toolchain` → `prepare_and_clone_repo`; change `install_ai_tools` dep to `install_min_toolchain`). Move `install_ai_tools` earlier in `STEP_IDS` (right after `install_min_toolchain`).

```bash
min_toolchain_needs_node() { ! command -v node >/dev/null 2>&1; }
min_toolchain_needs_npm()  { ! command -v npm  >/dev/null 2>&1; }

# Minimal path to a working npm: brew (macOS) + node. Skips anything present.
install_min_toolchain() {
  printf "${BLUE}Ensuring minimal toolchain (brew, node, npm)...${NORMAL}\n"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if ! find_brew_bin >/dev/null 2>&1; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    setup_brew_env
    if min_toolchain_needs_node; then brew install node; fi
  else
    if min_toolchain_needs_node || min_toolchain_needs_npm; then
      install_os_node_npm   # extract the per-distro nodejs+npm install used by install_packages_*
    fi
  fi
}
```

Add `install_os_node_npm` that installs just `nodejs`/`npm` via apt/dnf/pacman (mirroring the literal lists). In `install_ai_tools`, prepend:

```bash
  if cli_is_installed claude && cli_is_installed codex; then
    printf "${YELLOW}Claude Code and Codex already installed; skipping npm install.${NORMAL}\n"
    seed_ai_config
    return 0
  fi
```

- [ ] **Step 4: Run to verify pass** — PASS; existing suite green.
- [ ] **Step 5: shellcheck + commit**
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): skip-aware install_min_toolchain; reposition install_ai_tools"
```

---

### Task 5: Mode selection (`select_mode`)

**Files:**
- Modify: `util/quick-install.sh`
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Consumes: `OPT_SILENT`, `TTY_OPEN` (set by `open_interaction_channel`).
- Produces: `select_mode` → sets `MODE=silent|interactive` and returns 0, or prints guidance and returns 2 when no-TTY + no `--silent`.

- [ ] **Step 1: Write failing tests**

```bash
# --- Task 5: select_mode --------------------------------------------------
OPT_SILENT=1; TTY_OPEN=0; MODE=""; select_mode; assert_eq "silent flag -> silent" "$MODE" "silent"
OPT_SILENT="";  TTY_OPEN=1; MODE=""; select_mode; assert_eq "tty -> interactive"  "$MODE" "interactive"
OPT_SILENT="";  TTY_OPEN=0; MODE=""
( select_mode ) ; assert_eq "no tty no silent -> exit 2" "$?" "2"
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement**

```bash
select_mode() {
  if [ -n "$OPT_SILENT" ]; then MODE=silent; return 0; fi
  if [ "${TTY_OPEN:-0}" -eq 1 ]; then MODE=interactive; return 0; fi
  printf "${RED}No terminal available for interactive setup.${NORMAL}\n" >&2
  printf "Re-run with --silent[=claude|codex] for an unattended install (needs an authed CLI).\n" >&2
  return 2
}
```

- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: shellcheck + commit**
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): select_mode (interactive vs silent vs no-tty error)"
```

---

### Task 6: Silent driver resolution (`resolve_silent_driver`)

**Files:**
- Modify: `util/quick-install.sh`
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Consumes: `OPT_SILENT_DRIVER`, `cli_is_installed`, `cli_is_authenticated`.
- Produces: `resolve_silent_driver` → sets `DRIVER` and returns 0, or returns 1 (no usable driver). `DRIVER_CANDIDATES` order = explicit driver, else `claude codex`.

- [ ] **Step 1: Write failing tests** (stub `cli_is_installed`/`cli_is_authenticated` as functions)

```bash
# --- Task 6: resolve_silent_driver ----------------------------------------
cli_is_installed() { return 0; }                       # both installed
cli_is_authenticated() { [ "$1" = codex ]; }           # only codex authed
OPT_SILENT_DRIVER=""; DRIVER=""; resolve_silent_driver
assert_eq "bare silent picks authed codex" "$DRIVER" "codex"
OPT_SILENT_DRIVER="claude"; DRIVER=""
( resolve_silent_driver ) ; assert_eq "explicit claude unauthed -> fail" "$?" "1"
OPT_SILENT_DRIVER="codex"; DRIVER=""; resolve_silent_driver
assert_eq "explicit codex authed -> ok" "$DRIVER" "codex"
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement**

```bash
resolve_silent_driver() {
  local candidates c
  if [ -n "$OPT_SILENT_DRIVER" ]; then candidates="$OPT_SILENT_DRIVER"; else candidates="claude codex"; fi
  for c in $candidates; do
    if cli_is_installed "$c" && cli_is_authenticated "$c"; then DRIVER="$c"; return 0; fi
  done
  if [ -n "$OPT_SILENT_DRIVER" ]; then
    printf "${RED}%s is not installed/authenticated.${NORMAL}\n" "$OPT_SILENT_DRIVER" >&2
  else
    printf "${RED}Neither Claude nor Codex is set up; cannot run unattended.${NORMAL}\n" >&2
  fi
  return 1
}
```

- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: shellcheck + commit**
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): silent driver resolution with claude->codex fallback"
```

---

### Task 7: Interactive auth flow (`run_auth_flow`)

**Files:**
- Modify: `util/quick-install.sh`
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Consumes: `cli_is_authenticated`, `tty_read`/`prompt_yes_no`, login commands.
- Produces: `run_auth_flow` → sets `DRIVER`, or returns 10 to signal "neither authenticated → caller exits 0". A seam `AUTH_LOGIN_CMD` (default runs the real `claude auth login`/`codex login`) lets tests stub logins. `AUTHED_CLAUDE`/`AUTHED_CODEX` set to `1`/`""`.

- [ ] **Step 1: Write failing tests**

```bash
# --- Task 7: run_auth_flow ------------------------------------------------
AUTH_LOGIN_CMD() { return 0; }           # stub: pretend login succeeds
prompt_yes_no() { return 0; }            # stub: user says yes
# both already authed -> ask which drives; stub driver pick:
cli_is_authenticated() { return 0; }
_pick_driver() { echo claude; }          # stub the "which drives?" reader
DRIVER=""; run_auth_flow; assert_eq "both authed -> driver from pick" "$DRIVER" "claude"
# neither authed and user declines -> return 10
cli_is_authenticated() { return 1; }
prompt_yes_no() { return 1; }            # user declines both logins
( run_auth_flow ) ; assert_eq "neither authed -> 10" "$?" "10"
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement** (login + driver-pick behind seams; detection first)

```bash
AUTH_LOGIN_CMD() { # $1 = claude|codex ; real interactive login via fd 3
  case "$1" in
    claude) claude auth login <&3 >&3 2>&3 ;;
    codex)  codex login        <&3 >&3 2>&3 ;;
  esac
}

run_auth_flow() {
  AUTHED_CLAUDE=""; AUTHED_CODEX=""
  local cli
  for cli in claude codex; do
    if cli_is_authenticated "$cli"; then
      printf "${GREEN}%s already authenticated.${NORMAL}\n" "$cli"
      eval "AUTHED_$(printf '%s' "$cli" | tr a-z A-Z)=1"
    elif prompt_yes_no "Authenticate $cli now?" "yes"; then
      AUTH_LOGIN_CMD "$cli" && eval "AUTHED_$(printf '%s' "$cli" | tr a-z A-Z)=1"
    fi
  done
  if [ -n "$AUTHED_CLAUDE" ] && [ -n "$AUTHED_CODEX" ]; then
    DRIVER="$(_pick_driver)"
  elif [ -n "$AUTHED_CLAUDE" ]; then DRIVER=claude
  elif [ -n "$AUTHED_CODEX" ];  then DRIVER=codex
  else return 10
  fi
  return 0
}

_pick_driver() { # ask which CLI drives; default claude. Reads via fd 3.
  local ans
  printf "Which should drive setup? [claude/codex] (claude): " >&3
  IFS= read -r ans <&3 2>/dev/null || ans=""
  case "$ans" in codex) echo codex ;; *) echo claude ;; esac
}
```

- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: shellcheck + commit**
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): interactive auth flow (detect/skip, login, driver pick)"
```

---

### Task 8: Runbook generation (`generate_runbook` + `--print-runbook`)

**Files:**
- Modify: `util/quick-install.sh` (generator + wire `--print-runbook` in `handle_immediate_flags`)
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Consumes: `STATE_ENABLED_STEPS`, `PKG_SKIP`, `step_label`, the per-step command emitters.
- Produces: `runbook_step_block <id> <os>` (emits the STEP block: exact command or an `--exec-steps` delegation); `generate_runbook <os>` (preamble + blocks for enabled non-prereq steps + `SETUP-COMPLETE`). `PREREQ_STEPS="prepare_and_clone_repo install_min_toolchain install_ai_tools"`.

- [ ] **Step 1: Write failing tests**

```bash
# --- Task 8: generate_runbook ---------------------------------------------
STATE_ENABLED_STEPS="install_os_packages install_bun setup_fish"
PKG_SKIP=""
RB="$(generate_runbook macos)"
assert_contains "runbook has preamble" "$RB" "Some steps may ALREADY be complete"
assert_contains "runbook inlines bun"  "$RB" "STEP install_bun"
assert_contains "runbook delegates fish" "$RB" "--exec-steps=setup_fish"
assert_contains "runbook ends sentinel" "$RB" "SETUP-COMPLETE"
assert_eq "prereqs excluded" \
  "$(printf '%s' "$RB" | grep -c 'STEP install_min_toolchain')" "0"
```

(Add `assert_contains <name> <haystack> <needle>` if absent: `case "$2" in *"$3"*) pass;; *) fail;; esac`.)

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement**

Define `PREREQ_STEPS`, a `DELEGATED_STEPS="setup_nvm_default_node setup_fish set_default_shell_fish"` set, and `runbook_step_block`. Inlined steps emit their exact command (reuse the package command builder from `pkg_list_for_os`/the literal filter for `install_os_packages`; for simple steps emit the literal body command). Delegated steps emit `bash "$PF/util/quick-install.sh" --exec-steps=<id>` (group `setup_nvm_default_node,setup_fish` into one block when both enabled). `generate_runbook` writes the preamble (spec §4.1 verbatim with `<os>`/`<PF>` substituted), iterates `STATE_ENABLED_STEPS` in `STEP_IDS` order skipping `PREREQ_STEPS`, and appends `When all steps succeed (or were already complete), print: SETUP-COMPLETE.` Wire `--print-runbook`: in `handle_immediate_flags`, after `resolve_plan` is available, if `OPT_PRINT_RUNBOOK` is set, `generate_runbook "$(detect_os_key)"` and exit 0. (Add `detect_os_key` returning `macos|apt|fedora|pacman` from the existing OS detection in `install_os_packages`.)

- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: shellcheck + commit**
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): generate_runbook from resolved plan + --print-runbook"
```

---

### Task 9: Runbook/step parity test (drift guard)

**Files:**
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Consumes: `generate_runbook`, `STEP_IDS`, `step bodies`.

- [ ] **Step 1: Write the parity test**

```bash
# --- Task 9: runbook parity ----------------------------------------------
# Every enabled non-prereq step appears exactly once in the runbook.
STATE_ENABLED_STEPS="$(printf '%s ' "${STEP_IDS[@]}")"; PKG_SKIP=""
RB="$(generate_runbook macos)"
for s in $STATE_ENABLED_STEPS; do
  case " prepare_and_clone_repo install_min_toolchain install_ai_tools " in
    *" $s "*) continue ;;
  esac
  n="$(printf '%s' "$RB" | grep -cE "STEP $s|--exec-steps=[^ ]*$s")"
  assert_eq "step $s present once in runbook" "$n" "1"
done
```

- [ ] **Step 2: Run — Expected PASS** (if any step is missing/duplicated, it fails, exposing drift).
- [ ] **Step 3: Commit**
```bash
git add util/test-quick-install.sh
git commit -m "test(install): runbook/step parity drift guard"
```

---

### Task 10: Agent invocation (`run_agent`) with stub seam + silent fallback

**Files:**
- Modify: `util/quick-install.sh`
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Consumes: `DRIVER`, the runbook string.
- Produces: `run_agent <driver> <runbook>` builds the exact argv and runs it (or `RUN_AGENT_CMD` if set), returns its exit. `run_agent_with_fallback <runbook>` (silent bare-`--silent`): try `DRIVER`, on failure try the other authed candidate.

- [ ] **Step 1: Write failing tests**

```bash
# --- Task 10: run_agent ---------------------------------------------------
RUN_AGENT_CMD() { _AGENT_ARGV="$*"; return 0; }
run_agent claude "RB-TEXT"
assert_eq "claude argv" "$_AGENT_ARGV" "claude -p RB-TEXT --dangerously-skip-permissions"
run_agent codex "RB-TEXT"
assert_eq "codex argv" "$_AGENT_ARGV" \
  "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check RB-TEXT"
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement**

```bash
run_agent() {
  local driver="$1" runbook="$2"
  case "$driver" in
    claude) set -- claude -p "$runbook" --dangerously-skip-permissions ;;
    codex)  set -- codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$runbook" ;;
    *) printf "${RED}Unknown driver: %s${NORMAL}\n" "$driver" >&2; return 2 ;;
  esac
  if [ -n "${RUN_AGENT_CMD:-}" ]; then RUN_AGENT_CMD "$@"; return $?; fi
  "$@"
}

# Silent bare --silent: try DRIVER, then the other authed candidate.
run_agent_with_fallback() {
  local runbook="$1" first="$DRIVER" other rc
  run_agent "$first" "$runbook" && return 0
  rc=$?
  [ -n "$OPT_SILENT_DRIVER" ] && return "$rc"        # explicit driver: no fallback
  case "$first" in claude) other=codex ;; codex) other=claude ;; esac
  if cli_is_installed "$other" && cli_is_authenticated "$other"; then
    printf "${YELLOW}%s run failed; retrying with %s...${NORMAL}\n" "$first" "$other" >&2
    run_agent "$other" "$runbook"; return $?
  fi
  return "$rc"
}
```

- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: shellcheck + commit**
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): run_agent (bypass flags) + silent claude->codex fallback"
```

---

### Task 11: Sudo keep-alive + `main()` rewrite + trap integration

**Files:**
- Modify: `util/quick-install.sh` (`sudo_keepalive_start/stop`, `main`, `on_signal`)
- Test: `util/test-quick-install.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: `sudo_keepalive_start`/`sudo_keepalive_stop` (sets/clears `KEEPALIVE_PID`); rewritten `main` orchestrating the full flow; `on_signal` also kills `KEEPALIVE_PID`.

- [ ] **Step 1: Write failing tests** (keep-alive stop is safe to unit-test; main is integration-tested via seams)

```bash
# --- Task 11: sudo keep-alive ---------------------------------------------
KEEPALIVE_PID=""
sudo_keepalive_stop                       # no-op when unset, must not error
assert_eq "stop no-op when unset" "$?" "0"
# main orchestration (all heavy ops stubbed):
MODE=""; OPT_SILENT=1; OPT_SILENT_DRIVER=codex
cli_is_installed(){ return 0; }; cli_is_authenticated(){ return 0; }
prepare_and_clone_repo(){ return 0; }; install_min_toolchain(){ return 0; }
generate_runbook(){ echo RB; }; detect_os_key(){ echo macos; }
resolve_plan(){ STATE_ENABLED_STEPS="install_bun"; }
open_interaction_channel(){ TTY_OPEN=0; }
_RAN=""; RUN_AGENT_CMD(){ _RAN="$*"; return 0; }
sudo_keepalive_start(){ return 0; }; sudo_keepalive_stop(){ return 0; }
main_ai_flow                               # the extracted orchestrator (see impl)
assert_contains "silent codex drove" "$_RAN" "codex exec"
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement**

```bash
sudo_keepalive_start() {
  [ -n "$OPT_SILENT" ] && return 0            # cannot prompt unattended
  sudo -v 2>/dev/null || { printf "${YELLOW}No sudo; sudo steps may fail.${NORMAL}\n"; return 0; }
  ( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &
  KEEPALIVE_PID=$!
}
sudo_keepalive_stop() {
  [ -n "${KEEPALIVE_PID:-}" ] && kill "$KEEPALIVE_PID" 2>/dev/null
  KEEPALIVE_PID=""
}
```

Extract the AI orchestration into `main_ai_flow` (called by `main` after `--exec-steps` short-circuit and `select_mode`):

```bash
main_ai_flow() {
  resolve_plan                                  # wizard (interactive) or defaults+flags
  prepare_and_clone_repo
  install_min_toolchain
  if [ "$MODE" = interactive ]; then
    install_ai_tools
    run_auth_flow; rc=$?
    if [ "$rc" -eq 10 ]; then
      printf "No AI CLI authenticated. Re-run to authenticate, or --silent=<cli> once set up.\n"
      return 0
    fi
  else
    resolve_silent_driver || return 1
  fi
  sudo_keepalive_start
  local os rb; os="$(detect_os_key)"; rb="$(generate_runbook "$os")"
  if [ "$MODE" = silent ]; then run_agent_with_fallback "$rb"; else run_agent "$DRIVER" "$rb"; fi
  local rc=$?
  sudo_keepalive_stop
  return "$rc"
}
```

Rewire `main`: `args_parse` → `capture_env` → `handle_immediate_flags` → `--exec-steps` short-circuit (Task 1) → `open_interaction_channel` → `select_mode || exit 2` → `main_ai_flow`. Add `KEEPALIVE_PID` kill to `on_signal`. Remove the old deterministic full-install loop from `main` (the loop logic stays available via `exec_steps_run`/`run_step`).

- [ ] **Step 4: Run to verify pass; full suite green on bash 3.2 + 5.x**

Run: `/bin/bash util/test-quick-install.sh && bash util/test-quick-install.sh`
Expected: all PASS.

- [ ] **Step 5: shellcheck + non-destructive smoke + commit**

Run: `shellcheck --severity=warning util/quick-install.sh quick-install.sh util/test-quick-install.sh`
Run: `bash util/quick-install.sh --help >/dev/null && bash util/quick-install.sh --print-runbook --only=install_bun --silent >/dev/null 2>&1; echo done`
```bash
git add util/quick-install.sh util/test-quick-install.sh
git commit -m "feat(install): sudo keep-alive + AI-driven main() orchestration"
```

---

### Task 12: Documentation (README + `--help` already updated)

**Files:**
- Modify: `README.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Update README**

Rewrite the "Quick installer" / "What The Installer Does" / "Installer Configuration" sections to describe: the always-AI model; the prereq core (clone, node/npm, CLIs, auth); the interactive auth flow (both/one/neither); `--silent[=claude|codex]` and the Claude→Codex fallback; that an install now requires an authed Claude or Codex (no deterministic mode); `--exec-steps` noted as internal; the bypass-permissions/sudo posture and the passwordless-sudo requirement for unattended Linux. Remove any claim that `--silent` is a deterministic install. Keep the flag table in sync with `--help`.

- [ ] **Step 2: Verify** — `bash util/quick-install.sh --help` matches the README flag table.

- [ ] **Step 3: Commit**
```bash
git add README.md
git commit -m "docs: document always-AI bootstrap, --silent[=driver], auth flow"
```

---

## Self-Review

- **Spec coverage:** §1 flow → Tasks 1,4,5,11; §2 modes → Task 5; §3 auth/driver → Tasks 3,6,7; §4 runbook/agent → Tasks 8,9,10; §5 sudo → Task 11; §6 recovery → Tasks 10,11; §7 compat → Tasks 2,11,12; §8 testing → every task's tests; §9 risks → mitigated by Tasks 8 (scoped runbook), 9 (parity), 10 (centralized flags). All sections covered.
- **Placeholder scan:** `install_os_node_npm`, the per-step command emitters, and the §4.1 preamble substitution are described with their exact source (literal lists / step bodies / spec §4.1) — the implementer copies existing literals; no invented APIs.
- **Type/name consistency:** `OPT_SILENT_DRIVER`, `OPT_EXEC_STEPS`, `OPT_PRINT_RUNBOOK`, `MODE`, `DRIVER`, `KEEPALIVE_PID`, `cli_is_installed`, `cli_is_authenticated`, `select_mode`, `resolve_silent_driver`, `run_auth_flow`, `generate_runbook`, `runbook_step_block`, `run_agent`, `run_agent_with_fallback`, `main_ai_flow`, `detect_os_key`, `PREREQ_STEPS` — used consistently across tasks.
- **bash 3.2:** no banned constructs introduced; tests run under `/bin/bash`.

## Notes for the implementer

- The two trickiest tasks are **8 (runbook generation)** and **11 (main rewrite)** — keep the existing step bodies untouched; the runbook either inlines their literal command or delegates via `--exec-steps`.
- Auth-status exit-code semantics were confirmed for `codex login status` (0 when authed). Confirm `claude auth status` returns non-zero when signed out on first implementation; the unit tests stub it either way.
- Do not run a real agent/login/install in tests — every external effect is behind a stub (`RUN_AGENT_CMD`, `AUTH_LOGIN_CMD`, PATH shims).
