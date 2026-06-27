# AI-Driven Bootstrap for `quick-install.sh` — Design

**Date:** 2026-06-26
**Status:** Approved design, pending spec review
**Scope:** Make `quick-install.sh` always AI-assisted. Bootstrap the minimal prereqs
deterministically (clone, node/npm, and — interactively — the two AI CLIs + auth), then
drive the rest of the setup with the chosen agent (Claude Code or Codex) in bypass mode,
using a runbook auto-generated from the resolved plan. The deterministic step engine is
retained only as the runbook's source of truth, an internal per-step exec primitive, and
the test units — it is no longer an end-user run mode.

## Goal

An authenticated AI CLI performs the bulk of machine setup, including error recovery,
while the end state matches what the deterministic step bodies would produce. The AI is
the executor; the step engine is the precise specification it follows.

## Locked decisions (from brainstorming — do not relitigate)

| Topic | Decision |
| --- | --- |
| Always AI | There is **no** non-AI run mode. Every install is AI-driven. The deterministic engine is internal (source of truth + per-step exec primitive + tests). |
| Architecture | AI-primary, driven by a precise runbook generated from the resolved plan; the runbook never drifts because it is built from the step/package data. |
| Prereq order | clone → node + npm → (interactive only) install Claude Code + Codex → auth. Then the AI drives the rest. |
| Modes | **Interactive** (TTY): wizard + install CLIs + auth flow. **Silent/unattended** (`--silent[=driver]`): assume CLIs installed+authed; verify and fail/fallback. No-TTY without `--silent` is an error with guidance. |
| Auth (interactive) | Install both CLIs. Detect existing auth and skip it. Ask per-CLI to authenticate (both/one/neither). Neither → exit. Both → ask which drives. One → it drives. |
| Driver (silent) | `--silent` alone → try Claude, then Codex on failure. `--silent=claude` / `--silent=codex` → that one ONLY; fail if it is not installed+authed. Either way, one must already be set up. |
| Sudo | Interactive: `sudo -v` + background keep-alive. Silent: no prompt possible — rely on cached/passwordless sudo; surface failures. |
| Permissiveness | Most permissive agent flags (Claude `--dangerously-skip-permissions`, Codex `--dangerously-bypass-approvals-and-sandbox`). |
| Idempotency | Prereqs skip work already present (brew/node/npm/CLIs/auth). The runbook tells the agent steps may already be done; every command is idempotent. |

## Hard constraints (carried from the existing installer)

- bash 3.2 floor (macOS 3.2.57): no assoc arrays / `mapfile` / `${var^^}`.
- No `source` of any `$PF` path before the clone completes.
- Preserve the deterministic engine verbatim as the internal primitive: `STEP_IDS`,
  `step_*`, `run_step`, resumable `quick-install.state`, the literal `install_packages_*`
  lists (verify script parses them), the setup-wizard, the existing CLI flags,
  `install_ai_tools`, the SSH-key flow.
- Stay shellcheck-clean at `--severity=warning`; keep the test suite green on bash 3.2 and
  5.x; keep `verify-quick-install-packages.py` working.

---

## 1. Architecture & flow

```
main:
  args_parse / capture_env / handle_immediate_flags / open_interaction_channel

  # Internal exec primitive (used by the AI driver and tests; bypasses all mode logic):
  if --exec-steps=<ids> given:
     run_step for each id (deterministic, no wizard/AI/auth), then exit with its status

  select MODE:
     --silent[=driver]            -> SILENT (unattended AI)
     else TTY (fd 3) available    -> INTERACTIVE (AI with wizard + auth)
     else                         -> error: "No terminal. Use --silent[=claude|codex]
                                      for unattended install (needs an authed CLI)."; exit 2

  resolve_plan:
     INTERACTIVE -> wizard customizes steps/packages; prereq steps shown locked-on
     SILENT      -> defaults + flags (--only/--skip/--packages still apply); no wizard
     -> STATE_ENABLED_STEPS + PKG_SKIP  (this is what generate_runbook consumes)

  run PREREQ core deterministically, each SKIPPING work already present:
     prepare_and_clone_repo         # existing guard: skip if repo already cloned
     install_min_toolchain          # brew + node + npm; skip any already on PATH
     INTERACTIVE only:
        install_ai_tools            # npm i -g; skip if both claude and codex present
        auth flow (section 3)       # skip login for any already-authed CLI
           neither authed -> guidance + exit 0
           else DRIVER selected

  if SILENT:
     resolve DRIVER (section 3.2): --silent=<driver> or Claude-then-Codex
     require DRIVER installed + authed, else fail (or fall back) — never install/login here

  sudo_keepalive_start              # interactive only (section 5)
  RUNBOOK=$(generate_runbook)       # from the resolved plan, minus prereqs (section 4)
  run_agent "$DRIVER" "$RUNBOOK"    # bypass mode; with Claude->Codex fallback in SILENT
  sudo_keepalive_stop
  report result; leave resume-state intact if the agent aborted
```

### New / changed step ids and flags

- **`install_min_toolchain`** (new): minimal path to a working `npm` — brew on macOS then
  `node`; on Linux the OS package manager's `nodejs`+`npm`. **Skip-aware**: probes
  `find_brew_bin` / `command -v node` / `command -v npm` and installs only what is missing.
  Overlaps harmlessly with the later full `install_os_packages`.
- **`install_ai_tools`** moves into the interactive prereq core. Skip-aware: if both
  `claude` and `codex` are on PATH it skips `npm i -g` (config seeding unchanged). Not run
  in SILENT (CLIs are assumed present).
- **`--exec-steps=<ids>`** (new, internal): run the listed step bodies deterministically
  and exit. The runbook uses it for complex/interactive steps; tests use it too. Distinct
  from `--only` (which only *restricts the plan*).
- **`--silent[=claude|codex]`**: `--silent` becomes optionally-valued. Bare `--silent` =
  unattended, Claude-then-Codex. `--silent=claude`/`=codex` = that driver only.
- **Removed:** no `--no-ai` flag and no deterministic run mode.
- `step_dependencies`: `install_ai_tools` depends on `install_min_toolchain`.

---

## 2. Mode selection

Exactly one of:

1. **`--exec-steps=<ids>`** → internal deterministic per-step execution, then exit. Not a
   user install mode; the mechanism by which the agent runs tested step bodies.
2. **`--silent` / `--silent=claude` / `--silent=codex`** → SILENT (unattended AI).
3. **No `--silent`, controlling TTY available** (fd 3, incl. `curl | bash` via `/dev/tty`)
   → INTERACTIVE (wizard + install + auth).
4. **No `--silent`, no TTY** → error + guidance (point to `--silent`), exit 2. We never
   silently guess at an unattended AI run without being told.

`--only` / `--skip` / `--packages` / `--skip-packages` still shape the resolved plan (and
thus the runbook) in every mode.

---

## 3. Auth & driver selection

### 3.1 Interactive auth flow

After `install_ai_tools`, each CLI's existing auth is detected first; an already-authed
CLI is treated as authed without prompting:

```
for cli in claude codex:
   if cli_is_authenticated(cli):       # detect via the CLI's own status/config (3.3)
      mark authed; print "<cli> already authenticated — skipping login"
   else:
      ask "Authenticate <cli> now? [Y/n]" -> if yes: run that CLI's interactive login (fd 3)

case authed in
  neither -> print "No AI CLI authenticated. Installed but not run. Re-run to authenticate,
                    or pass --silent=<cli> once a CLI is set up." ; exit 0
  one     -> DRIVER = that one
  both    -> ask "Which should drive setup? [claude/codex]" -> DRIVER
esac
```

### 3.2 Silent driver resolution

No install, no login in SILENT — only verification:

```
candidates = (--silent=<driver> given) ? [<driver>] : [claude, codex]
DRIVER = first candidate that is installed AND cli_is_authenticated(candidate)
if none:
   if explicit --silent=<driver> -> fail: "<driver> is not installed/authenticated"; exit 1
   else                          -> fail: "Neither Claude nor Codex is set up"; exit 1
```

The Claude-then-Codex order also applies as a run-time fallback: if the bare-`--silent`
DRIVER's agent run fails, retry with the other authed candidate (the runbook is idempotent,
so the second agent resumes from wherever the first stopped). An explicit `--silent=<driver>`
does **not** fall back.

### 3.3 Auth detection (`cli_is_authenticated`)

Best-effort, non-interactive probe per CLI, confirmed against current docs at build time
(a `claude`/`codex` status subcommand, or presence of the credential store such as
`~/.codex/auth.json` / Claude Code's credentials). If detection is unreliable for a CLI,
fall back to: interactive → ask (default "skip" when a credential file exists); silent →
treat absence of a credential file as not-authed and fail/fallback accordingly.

---

## 4. Runbook generation + agent invocation

### 4.1 Runbook generation (`generate_runbook`)

Built from the **resolved plan** (enabled steps + per-OS resolved package list), so it
cannot drift from the deterministic engine. Preamble + per-step blocks:

```
You are setting up this machine. Some steps may ALREADY be complete — this machine may be
partially set up. Before running each step, check whether it is already done; if so,
verify and move on. Every command below is safe to re-run (idempotent). Execute the plan
IN ORDER. After each step verify it succeeded. If a command fails, diagnose and fix it
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

Command sourcing per step, to guarantee fidelity:

- **Package install** (`install_os_packages`): the exact per-OS literal install command,
  filtered through `pkg_filter_for_os` — identical to the bash step.
- **Simple steps** (local bins, pyenv, rbenv, bun, yarn): the exact commands from the body.
- **Complex / multi-command / state-sharing steps** (`setup_fish` + Tide,
  `setup_nvm_default_node`, `set_default_shell_fish`): the runbook tells the agent to run
  the tested body via the internal primitive, e.g.
  `bash "$PF/util/quick-install.sh" --exec-steps=<step>`, and to fix+retry on failure.
  Steps sharing in-process state are delegated together:
  `--exec-steps=setup_nvm_default_node,setup_fish` (one process, `STEP_IDS` order) so
  `INSTALLED_NVM_VERSION` reaches `setup_fish`.

Because the runbook is built only from the wizard's/flags' resolved plan, anything the user
deselects never appears — the wizard is the single "what to install/set up" control surface.

A new immediate flag **`--print-runbook`** dumps the generated runbook and exits
(inspection, tests, parity check).

### 4.2 Determinism / no-drift guarantee

The runbook generator and the step engine read the same step list and package data. A
parity test asserts that each inlined step's "Run exactly" command equals the step body's
command, and that every enabled non-prereq step appears in the runbook exactly once — the
same drift-guard discipline as the package registry.

### 4.3 Agent invocation (`run_agent`)

```
claude) claude -p "$RUNBOOK" --dangerously-skip-permissions ;;
codex)  codex exec --dangerously-bypass-approvals-and-sandbox "$RUNBOOK" ;;
```

- Exact flags/subcommands are **verified against current Claude Code / Codex CLI docs at
  implementation time** (document-specialist confirms before coding), centralized here so
  there is one place to update.
- Foreground; output streams to the user. Success = the `SETUP-COMPLETE` sentinel and/or
  exit 0.
- On failure: SILENT bare-`--silent` retries the other authed candidate (4.3 fallback);
  otherwise report failure, leave resume-state intact, and tell the user they can re-run
  (prereqs + completed steps are idempotent).

---

## 5. Sudo handling

- **Interactive:** `sudo -v` once (prompt via terminal) + background keep-alive
  (`while true; do sudo -n true; sleep 60; done &`), `KEEPALIVE_PID` killed by the unified
  `on_signal` trap so it never leaks. macOS brew needs no sudo; `set_default_shell_fish` /
  `/etc/shells` do.
- **Silent:** cannot prompt. Skip `sudo -v`; rely on cached or passwordless sudo. If a
  sudo-requiring step fails, the agent surfaces it (and SILENT may fall back to the other
  CLI, which will hit the same wall — so document that unattended installs need
  passwordless sudo on Linux).

---

## 6. Error recovery semantics

- Happy path = exact commands → deterministic.
- Recovery = the agent's job: any failed command, it diagnoses and fixes with full shell,
  then continues.
- Cross-agent recovery (SILENT bare-`--silent`): if Claude fails, Codex resumes via the
  same idempotent runbook.
- The resume-state records prereq progress, so a killed run resumes prereqs without redoing
  them.

## 7. Backward compatibility & migration

- **`--silent` semantics change:** it now means "unattended AI" (was "deterministic
  non-interactive"). There is no deterministic run mode anymore — every install is
  AI-assisted. Documented prominently in README and `--help`.
- A no-TTY run with no `--silent` now errors with guidance instead of silently installing.
- All existing flags, env vars, the wizard, the step engine, the literal package lists,
  `verify-quick-install-packages.py`, and the test suite remain valid; the step engine is
  exercised via `--exec-steps` and as the runbook's source.
- `install_ai_tools` body unchanged (position/dependency change only).

## 8. Testing / verification

- **Runbook generation** (no network/agent): `--print-runbook` for a resolved plan on each
  OS produces the expected blocks; prereq steps excluded; every enabled step present once.
- **Parity**: inlined-step runbook commands equal the deterministic step commands (§4.2).
- **Mode selection**: `--silent`, `--silent=claude`, `--silent=codex` → SILENT; TTY present
  → INTERACTIVE; no-TTY-no-silent → exit 2 with guidance; `--exec-steps` runs steps and
  exits.
- **Driver resolution**: explicit `--silent=codex` with codex unauthed → exit 1; bare
  `--silent` with only codex authed → picks codex; with neither → exit 1. (`cli_is_authenticated`
  stubbed.)
- **Idempotency / skip-aware**: brew+node+npm stubbed present → `install_min_toolchain`
  installs nothing; both CLIs present → `install_ai_tools` skips `npm i -g`; authed stub →
  auth prompt skipped.
- **Interactive auth flow**: neither/one/both branches (logins stubbed — no real auth).
- **Wizard→runbook**: deselecting a step/package removes exactly its block/entries; prereq
  steps locked-on on the interactive path.
- **`run_agent` command building**: the exact agent command line is asserted via a stub
  seam (`RUN_AGENT_CMD` override) — no live agent run in tests/CI.
- Existing suite + shellcheck + bash 3.2 gate stay green.

## 9. Risks

1. **Autonomous root-capable agent** in bypass mode can take destructive/unintended
   actions. Mitigations: tightly-scoped runbook ("do not touch unrelated config"), the
   deterministic engine as a reviewable spec, and the user's explicit acceptance for their
   own machine.
2. **No offline / no-AI path** — by design. An install now hard-requires a working,
   authed AI CLI and network. Documented.
3. **Non-determinism on the recovery path** — bounded by exact-command happy path + "don't
   improvise."
4. **Runbook drift** — guarded by the §4.2 parity test (CI gate).
5. **CLI flag/auth-detection churn** — Claude/Codex surfaces may change; centralized in
   `run_agent` / `cli_is_authenticated` and verified against docs at build time.
6. **Unattended sudo** — Linux silent installs need passwordless/cached sudo; documented.

## 10. Out of scope / YAGNI

- Storing/managing AI credentials (each CLI owns its login).
- A second agent verifying the first; multi-agent orchestration beyond the Claude→Codex
  retry.
- Streaming structured agent progress into the wizard UI.
- Changing what gets installed — delivery-mechanism change only; end state equals today's.
