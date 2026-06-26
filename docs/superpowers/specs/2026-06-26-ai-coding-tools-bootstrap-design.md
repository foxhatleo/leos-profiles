# AI Coding Tools in the Bootstrap — Design

**Date:** 2026-06-26
**Status:** Approved design, pending spec review
**Scope:** Sub-project #1 of a larger "supercharge" effort (see Follow-ups)

## Goal

Make `quick-install.sh` set up a working AI coding CLI environment — **Claude Code**
and **Codex** — as a first-class, opt-out-able bootstrap step, and keep them current
through the existing maintenance (`*-checkup`) pattern. Seed light, neutral starter
config so a fresh machine lands in a usable state without manual file creation.

Authentication/login is explicitly **out of scope** — it stays manual and interactive,
as both CLIs intend.

## Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| Which tools | Claude Code + Codex |
| Install mechanism | npm global, via the nvm-managed Node the installer already sets up |
| Beyond install | Fold updates into the `*-checkup` pattern; seed minimal config |
| Config opinionation | Light opinionated defaults (commented, easy to change) |

## Components

### 1. Installer step — `install_ai_tools`

Added to `util/quick-install.sh`, slotted **immediately after `setup_nvm_default_node`**.

- **`STEP_IDS`**: insert `install_ai_tools` after `setup_nvm_default_node`.
- **`step_label`**: `"Install AI coding tools (Claude Code, Codex)"`.
- **`step_dependencies`**: `setup_nvm_default_node` — the global npm installs must land
  on the nvm default Node, not a stray system Node.
- **`step_default_enabled`**: default **yes**. No desktop gate — these CLIs are useful
  on servers too.
- **Body**: route the install through fish so it uses the nvm default Node, mirroring
  how `setup_nvm_default_node` already shells out to `fish -c`:

  ```bash
  install_ai_tools() {
    printf "${BLUE}Installing AI coding tools (Claude Code, Codex)...${NORMAL}\n"
    ensure_fisher_and_nvm_fish
    fish -c "npm install -g @anthropic-ai/claude-code @openai/codex"
    seed_ai_config
  }
  ```

  Idempotent: re-running updates the packages in place.

### 2. Maintenance — `ai-checkup`

New function in `fish/commands.fish`, matching the existing `brew-checkup` / `apt-checkup`
/ `dnf-checkup` convention (those live in the gitignored `_private` file; `ai-checkup`
will be the first in-repo checkup):

```fish
# Update AI coding CLIs to their latest versions.
function ai-checkup
  if not command -sq npm
    puts-err "npm is not available; cannot update AI tools."
    return 1
  end
  puts "Updating Claude Code and Codex..."
  npm update -g @anthropic-ai/claude-code @openai/codex
end
```

- A `complete -c ai-checkup -f -d "Update AI coding CLIs"` line alongside the others.
- Wired into `bye` (commands.fish, after the `dnf-checkup` block) as a fourth checkup:

  ```fish
  if functions ai-checkup > /dev/null
    puts "Doing AI tools checkup..."
    ai-checkup
  end
  ```

### 3. Config seeding

Neutral, light-opinionated starter templates stored in-repo, copied to the user's home
**only if the target does not already exist** — never overwrite.

| Template (in repo) | Target |
| --- | --- |
| `res/ai/claude-settings.json` | `~/.claude/settings.json` |
| `res/ai/codex-config.toml` | `~/.codex/config.toml` |

Bash helper in `util/quick-install.sh`, called at the end of `install_ai_tools`:

```bash
seed_ai_config() {
  seed_one() {  # $1 = template (relative to repo), $2 = target
    local src="$PF/$1" dst="$2"
    [ -f "$src" ] || return 0
    if [ -f "$dst" ]; then
      printf "${YELLOW}Keeping existing %s${NORMAL}\n" "$dst"
      return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    printf "${GREEN}Seeded %s${NORMAL}\n" "$dst"
  }
  seed_one res/ai/claude-settings.json "$HOME/.claude/settings.json"
  seed_one res/ai/codex-config.toml "$HOME/.codex/config.toml"
}
```

**`res/ai/claude-settings.json`** — valid skeleton with the common sections present but
empty, so it is safe and easy to grow:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {},
  "permissions": {
    "allow": [],
    "deny": []
  }
}
```

**`res/ai/codex-config.toml`** — commented defaults, all conservative:

```toml
# Codex CLI configuration — Leo's Profiles starter
# Docs: https://github.com/openai/codex
# Uncomment and edit to taste; login/auth is handled separately by `codex`.

# model = "gpt-5-codex"

# How Codex asks before acting: "untrusted" | "on-failure" | "on-request" | "never"
approval_policy = "on-request"

# Filesystem sandbox: "read-only" | "workspace-write" | "danger-full-access"
# sandbox_mode = "workspace-write"
```

## Error Handling

- `install_ai_tools` runs under the installer's existing `set -e` + per-step state
  machine: a failure marks the step failed and the run is resumable from it. No new
  error-handling machinery needed.
- `seed_ai_config` is non-fatal by nature (copy-if-absent); a missing template is
  silently skipped so a partial checkout can't abort the bootstrap.
- `ai-checkup` guards on `command -sq npm` and returns non-zero with a `puts-err`
  message if npm is absent, so `bye` degrades gracefully.

## Testing / Verification

- **Package existence**: extend `util/verify-quick-install-packages.py` expectations or
  at minimum confirm the two npm package names resolve (`npm view <pkg> version`).
- **Step wiring**: a non-interactive installer run (`[ -t 0 ]` false path) must include
  `install_ai_tools` in the default-enabled set and respect its dependency on
  `setup_nvm_default_node`.
- **Idempotency**: running `install_ai_tools` twice leaves one global install and does
  not clobber an existing `~/.claude/settings.json` or `~/.codex/config.toml`.
- **`ai-checkup`**: defined, completes, and is invoked by `bye` when present.
- **Lint**: `shellcheck util/quick-install.sh` and `fish_indent --check` on touched
  fish files stay clean (ties into Follow-up #2).

## Documentation

Update `README.md`:
- Add `install_ai_tools` to the step flow list (between Node LTS and fish setup).
- Add `ai-checkup` to the "Included Fish Commands" list.
- Note the seeded config files and that auth stays manual.

## Out of Scope / YAGNI

- Authentication, API keys, or login automation.
- Additional CLIs (Gemini, etc.) — the npm-list pattern makes adding one trivial later.
- PATH entries under `fish/path/` — npm global bin is already on PATH; no entry needed.

## Follow-up Sub-projects (not part of this spec)

1. **Quality infra** — `shellcheck` + `fish_indent --check` + wire
   `verify-quick-install-packages.py` into a GitHub Actions CI workflow.
2. **Hardening pass** — fix README/doc drift (e.g. stale "cloud sync" mention), tighten
   the broad `*.txt` `.gitignore` rule, audit shell edge cases surfaced by #1.

Each gets its own spec → plan → implementation cycle.
