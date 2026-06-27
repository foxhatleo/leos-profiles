# AI-Driven Bootstrap for `quick-install.sh` — Design

**Date:** 2026-06-26
**Status:** Approved design, pending spec review
**Scope:** Split the installer into a deterministic prereq core plus an AI-driven
remainder: bootstrap brew/node/npm + the two AI CLIs deterministically, authenticate,
then drive the rest of the setup with the chosen agent in bypass mode using a runbook
auto-generated from the resolved plan. Deterministic engine stays as the fallback.

## Goal

Let an authenticated AI CLI (Claude Code or Codex) perform the bulk of machine setup,
including error recovery, while guaranteeing the end state matches what the current
deterministic script produces. The AI is the primary executor on the interactive happy
path; the existing step machine remains the source of truth and the non-interactive
fallback.

## Locked decisions (from brainstorming — do not relitigate)

| Topic | Decision |
| --- | --- |
| Architecture | AI-primary, driven by a precise runbook generated from the resolved plan; deterministic engine kept as source-of-truth + fallback. |
| Prereq order | brew (macOS) → node + npm → install Claude Code + Codex → auth. Then AI drives the rest. |
| Auth | Install both CLIs. Ask per-CLI whether to authenticate (both / one / neither). Neither → script ends gracefully after install. Both authed → ask which drives. One authed → it drives. |
| Sudo | Full bypass + `sudo -v` up front + background keep-alive, killed on exit. |
| Runbook | Generated from the resolved plan (exact commands), NOT hand-written prose. Single source of truth = the deterministic step/package data. |
| Permissiveness | Most permissive agent flags (Claude `--dangerously-skip-permissions`, Codex `--dangerously-bypass-approvals-and-sandbox`). |

## Hard constraints (carried from the existing installer)

- bash 3.2 floor (macOS 3.2.57): no assoc arrays / `mapfile` / `${var^^}`.
- No `source` of any `$PF` path before the clone completes.
- Preserve the deterministic engine verbatim: `STEP_IDS`, `step_*`, `run_step`,
  resumable `quick-install.state`, the literal `install_packages_*` lists (verify script
  parses them), the setup-wizard, all CLI flags, `install_ai_tools`, the SSH-key flow.
- Stay shellcheck-clean at `--severity=warning` (`.shellcheckrc`); keep the 83-test suite
  green on bash 3.2 and 5.x; keep `verify-quick-install-packages.py` working.

---

## 1. Architecture & flow

```
main:
  args_parse / capture_env / handle_immediate_flags / open_interaction_channel

  decide DRIVE_MODE (before the wizard, so it can lock prereqs on the AI path):
    - silent / no-TTY / no-network / --no-ai / agent-unavailable  -> DRIVE=deterministic
    - interactive                                                 -> DRIVE=ai (pending auth)

  resolve_plan (wizard or non-interactive) -> STATE_ENABLED_STEPS + PKG_SKIP
    - the wizard still lets the user customize WHICH steps/packages to set up; that
      resolved plan is exactly what generate_runbook consumes (section 4).
    - on the AI path the prereq steps (prepare_and_clone_repo, install_min_toolchain,
      install_ai_tools) are shown locked-on, since the agent cannot run without them.

  if DRIVE = deterministic:
     run the existing step loop (today's behavior, fully customizable)   [unchanged]
     exit

  if DRIVE = ai:
     run PREREQ steps deterministically, each SKIPPING work already present:
        prepare_and_clone_repo        # existing guard: skip if repo already cloned
        install_min_toolchain         # brew + node + npm; skip any already on PATH
        install_ai_tools              # npm i -g; skip if both claude and codex present
     run AUTH flow (section 3)         # skip login for any CLI already authenticated
        if neither authed -> print guidance (+ --silent hint) and exit 0
        else select DRIVER cli
     sudo_keepalive_start             # sudo -v + background loop (section 5)
     RUNBOOK=$(generate_runbook)      # from the wizard's resolved plan, minus prereqs
     run_agent "$DRIVER" "$RUNBOOK"   # bypass mode; preamble notes steps may be pre-done
     sudo_keepalive_stop
     report result; leave resume-state intact if the agent aborted
```

### New / changed step ids

- **`install_min_toolchain`** (new): the minimal path to a working `npm` — brew on macOS
  then `node`; on Linux the OS package manager's `nodejs`+`npm`. **Idempotent and
  skip-aware**: probes `find_brew_bin` / `command -v node` / `command -v npm` first and
  installs only what is missing (a machine that already has brew+npm does nothing here).
  Overlaps harmlessly with the later full `install_os_packages`.
- **`install_ai_tools`** moves into the prereq core (runs before the AI driver), instead
  of mid-sequence. Its body gains a skip-aware guard: if both `claude` and `codex` are
  already on PATH it skips the `npm i -g` (the wizard can force a refresh/update). Config
  seeding (copy-if-absent) is unchanged.
- The remaining `STEP_IDS` are unchanged; on the AI path they are executed *by the agent*
  via the runbook rather than by the bash loop.

`step_dependencies` updates: `install_ai_tools` depends on `install_min_toolchain`
(replacing its current dependency on `setup_nvm_default_node`, which itself stays for the
deterministic path).

---

## 2. Mode selection (`DRIVE_MODE`)

The AI path is entered only when ALL hold:

1. Not `--silent` / `QUICK_INSTALL_SILENT`, and a controlling TTY is available (fd 3).
2. Not `--no-ai` (new opt-out flag) / `QUICK_INSTALL_NO_AI`.
3. Network reachable (a cheap connectivity probe; if it fails, deterministic).

Otherwise the deterministic engine runs exactly as today. This keeps CI, offline, and
scripted installs reproducible and AI-free. `--no-ai` lets an interactive user force the
classic path.

> The deterministic path is a first-class mode (reproducible/offline/CI), not a degraded
> shim. It is also the source of truth the runbook is generated from.

---

## 3. Auth flow

After `install_ai_tools`. Each CLI's existing auth state is detected first and a CLI that
is already authenticated is treated as authed without re-prompting:

```
for cli in claude codex:
   if cli_is_authenticated(cli):        # detect via the CLI's own status/config (§3.1)
      mark authed; print "<cli> already authenticated — skipping login"
   else:
      ask "Authenticate <cli> now? [Y/n]" -> if yes: run that CLI's interactive login (fd 3)

authed = {claude?, codex?}
case authed in
  neither -> print: "No AI CLI authenticated. Installed but not run. Re-run, or use
                     `quick-install.sh --silent` for the classic deterministic install."
             exit 0
  one     -> DRIVER = that one
  both    -> ask "Which should drive setup? [claude/codex]" -> DRIVER
esac
```

Auth uses each CLI's own interactive login (browser / device / API-key). Login I/O is
routed through fd 3 so it works even under `curl | bash`. The script never handles or
stores credentials itself.

### 3.1 Auth detection (`cli_is_authenticated`)

A best-effort, non-interactive probe per CLI, confirmed against current docs at build
time (e.g. a `claude`/`codex` status subcommand, or presence of the CLI's credential file
such as `~/.codex/auth.json` / the Claude Code credentials store). If detection is
unreliable for a CLI, fall back to asking — but default the prompt to "skip" when a
credential file is present, so an already-set-up machine is not nagged.

---

## 4. Runbook generation + agent invocation

### 4.1 Runbook generation (`generate_runbook`)

The runbook is produced from the **resolved plan** (the enabled steps + the per-OS
resolved package list), so it cannot drift from what the deterministic engine would do.
Structure:

```
You are setting up this machine. Some steps may ALREADY be complete — this machine may be
partially set up. Before running each step, check whether it is already done; if so,
verify and move on. Every command below is safe to re-run (idempotent). Execute the plan
IN ORDER. After each step, verify it succeeded. If a command fails, diagnose and fix it
using your full shell access, then continue. Do not improvise beyond making each step's
end-state match. Do not re-authenticate, change unrelated config, or install anything not
listed. The target OS is <os>. The repo is already cloned at <PF>.

STEP <id> — <label>
  Run exactly:
    <exact command(s) for this step on this OS>
  Already-done check: <cheap idempotency probe — skip the run if this passes>
  Success check: <how to verify the end state>

... (one block per enabled step not already done in the prereq core) ...

When all steps succeed (or were already complete), print: SETUP-COMPLETE.
```

Because the runbook is built only from the **wizard's resolved plan**, any step or package
group the user deselects in the setup UI simply never appears in the runbook — the agent
cannot set up something the user opted out of. The wizard is the single control surface for
"what to install/set up" on both the deterministic and AI paths.

Command sourcing per step, to guarantee fidelity:

- **Package install** (`install_os_packages`): emit the exact per-OS literal install
  command, filtered through `pkg_filter_for_os` — identical to what the bash step runs.
- **Simple steps** (local bins, pyenv, rbenv, bun, yarn): emit the exact commands from
  the step body.
- **Complex / interactive / multi-command steps** (`setup_fish` with its fisher/Tide
  config, `setup_nvm_default_node`, `set_default_shell_fish`, the SSH-key portions):
  the runbook instructs the agent to run the script's own idempotent step:
  `bash "$PF/util/quick-install.sh" --silent --only=<step>` and to fix+retry on failure.
  This delegates fiddly logic back to the tested code while keeping the agent in charge of
  orchestration and recovery. Steps that share in-process state must be delegated in one
  invocation: `setup_nvm_default_node` passes `INSTALLED_NVM_VERSION` to `setup_fish`, so
  the runbook emits a single `--only=setup_nvm_default_node,setup_fish` block (one bash
  process, run in `STEP_IDS` order) rather than two separate calls.

A new immediate flag **`--print-runbook`** dumps the generated runbook and exits (for
inspection, testing, and the parity check).

### 4.2 Determinism / no-drift guarantee

The runbook generator and the deterministic step loop read the **same** step list and
package data. A new parity test asserts that, for each enabled step, the runbook's
"Run exactly" command (for inlined steps) equals what the step body would execute, and
that every enabled non-prereq step appears in the runbook exactly once. This is the same
drift-guard discipline used for the package registry.

### 4.3 Agent invocation (`run_agent`)

```
claude) claude -p "$RUNBOOK" --dangerously-skip-permissions ;;
codex)  codex exec --dangerously-bypass-approvals-and-sandbox "$RUNBOOK" ;;
```

- Exact flags/subcommands are **verified against the current Claude Code / Codex CLI docs
  at implementation time** (the document-specialist confirms before coding).
- The agent runs in the foreground; its output streams to the user (the install log is not
  in the alt-screen). Success is detected by the `SETUP-COMPLETE` sentinel and/or exit 0.
- On agent failure / non-zero exit / missing sentinel: report failure, leave resume-state
  intact, and tell the user they can re-run (the prereq core + completed steps are
  idempotent) or fall back to `--silent`.

---

## 5. Sudo handling

```
sudo_keepalive_start:
  sudo -v                       # prompt once (interactive, via the terminal)
  ( while true; do sudo -n true; sleep 60; done ) &  KEEPALIVE_PID=$!
sudo_keepalive_stop:
  kill "$KEEPALIVE_PID" 2>/dev/null
```

- Started before `run_agent`, stopped after, and `KEEPALIVE_PID` is killed by the unified
  `on_signal` trap so it never leaks.
- macOS brew needs no sudo; `set_default_shell_fish` / `/etc/shells` still do. If `sudo -v`
  fails (no sudo rights), warn and let the agent proceed — sudo-requiring steps will then
  surface errors the agent reports.

---

## 6. Error recovery semantics

- Happy path = exact commands → deterministic.
- Recovery = the agent's job: any failed command, it diagnoses and fixes with full shell,
  then continues. This is the explicit value of the AI path.
- The deterministic resume-state (`quick-install.state`) still records prereq-step
  progress, so a killed run resumes the prereqs without redoing them. The agent itself is
  idempotent-by-instruction (re-running the runbook re-checks each step).

---

## 7. Backward compatibility

- `--silent` / CI / no-TTY / offline → unchanged deterministic behavior, AI-free.
- New opt-outs: `--no-ai` flag and `QUICK_INSTALL_NO_AI` env force the deterministic path
  in an interactive terminal.
- All existing flags, env vars, the wizard, the step engine, the literal package lists,
  `verify-quick-install-packages.py`, and the 83-test suite remain valid. The wizard's
  resolved plan simply feeds the runbook on the AI path.
- `install_ai_tools` body unchanged (only its position/dependency changes).

## 8. Testing / verification

- **Runbook generation unit tests** (no network, no agent): `--print-runbook` for a given
  resolved plan on each OS produces the expected blocks; prereq steps excluded; every
  enabled step present once.
- **Parity test**: inlined-step runbook commands equal the deterministic step commands
  (drift guard, §4.2).
- **Mode-selection tests**: `--silent`, `--no-ai`, no-TTY, simulated no-network all select
  the deterministic path; interactive + authed selects AI.
- **Auth-flow tests**: neither-authed exits 0 with guidance; one-authed sets driver; both
  prompts for driver. (CLI logins are stubbed/mocked — no real auth in tests.)
- **Idempotency / skip-aware tests**: with brew+node+npm stubbed as present,
  `install_min_toolchain` installs nothing; with `claude`+`codex` stubbed present,
  `install_ai_tools` skips `npm i -g`; with `cli_is_authenticated` stubbed true, the auth
  flow skips that CLI's login prompt.
- **Wizard→runbook tests**: deselecting a step or package group in the resolved plan
  removes exactly its block/entries from the generated runbook (the UI adjusts the
  runbook); prereq steps stay locked-on on the AI path.
- **No real agent run in CI / tests** — agent invocation is behind a seam that tests can
  stub (e.g. `RUN_AGENT_CMD` override) so we assert the command line built, not a live run.
- Existing suite + shellcheck + bash 3.2 gate stay green.

## 9. Risks

1. **Autonomous root-capable agent** in bypass mode: can take destructive/unintended
   actions. Mitigations: a tightly-scoped runbook ("do not touch unrelated config"), the
   `--no-ai` escape hatch, and the deterministic default for non-interactive runs. The user
   has explicitly accepted this posture for their own machine.
2. **Non-determinism on the recovery path** — inherent; bounded by the exact-command happy
   path and the "don't improvise" instruction.
3. **Network / cost / latency / rate-limits** — the AI path depends on the service; the
   deterministic fallback covers outages and CI.
4. **Runbook drift** from the step bodies — guarded by the §4.2 parity test (CI gate).
5. **CLI flag churn** — Claude/Codex flags may change; verified against docs at build time
   and centralized in `run_agent` so there is one place to update.
6. **Sudo timeout** mid long agent run — mitigated by the 60s keep-alive loop.

## 10. Out of scope / YAGNI

- Storing or managing AI credentials (each CLI owns its own login).
- A second agent verifying the first; multi-agent orchestration.
- Streaming structured progress from the agent back into the wizard UI.
- Changing what gets installed — this is a delivery-mechanism change only; the end state
  equals today's deterministic install.
