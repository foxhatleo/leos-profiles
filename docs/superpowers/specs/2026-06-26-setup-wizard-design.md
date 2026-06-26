# Setup Wizard for `quick-install.sh` — Design

**Date:** 2026-06-26
**Status:** Proposed design, pending spec review
**Scope:** Transform the bootstrap into a flag-driven, optionally-fullscreen TUI setup wizard with grouped package selection and improved error recovery.

## Goal

Turn `util/quick-install.sh` from a yes/no-prompt installer into:

1. A **flag-driven** non-interactive installer (CLI parameters for scripted use), while
   keeping every existing env var working.
2. A **polished fullscreen terminal wizard** (pure bash + ANSI, zero deps) for interactive
   use, letting the user pick install **steps**, pick **packages** via expandable grouped
   categories, and **confirm** before execution.
3. A **more resilient resumable** run, building on the existing per-step state machine.

It must degrade to a non-interactive path whenever there is no controlling terminal
(notably `curl | bash`, where stdin is the script, not a keyboard).

## Locked decisions (do not relitigate)

| Topic | Decision |
| --- | --- |
| TUI engine | Pure bash + ANSI escape codes. Zero external deps (no gum/dialog/whiptail). Alternate screen buffer, cursor control, `read -rsn1` raw key handling. Degrade to non-interactive when not a TTY. |
| CLI | Flags **plus** existing env vars. Precedence: **flags > env vars > wizard selections > built-in defaults**. |
| Packages | Grouped categories, expandable to individual packages. Toggle at group level. Must map back to correct per-OS package names. |

## Hard constraints (carried through the whole design)

- **Bootstrap ordering:** the public one-liner is
  `bash -c "$(curl -fsSL .../quick-install.sh)"`. The top-level `quick-install.sh` fetches
  `util/quick-install.sh` and `exec`s it **before the repo is cloned** (cloning is the
  `prepare_and_clone_repo` step). Therefore `util/quick-install.sh` **cannot `source`
  sibling library files** on the remote path. See [Bootstrap & file layout](#1-architecture--file-layout).
- **bash 3.2 floor:** macOS ships bash 3.2.57. **No** associative arrays / `declare -A`,
  **no** `mapfile`/`readarray`, **no** `${var^^}`. Indexed arrays and the existing
  newline/space-delimited string-table idioms are the data model.
- **Zero-TTY path must work:** when piped, stdin is the script. The wizard needs a
  controlling terminal — detect this and either re-open `/dev/tty`, or fall back to
  flags/env/defaults.
- **Preserve all existing behavior:** `STEP_IDS`, `step_label`, `step_dependencies`,
  `step_default_enabled`, `run_step`, the resumable `quick-install.state`, the SSH-key
  flow, brew detection, `install_ai_tools`, etc.
- **Keep `verify-quick-install-packages.py` working** (it parses package names out of the
  installer — see [Package registry](#4-package-registry-data-model)).

---

## 1. Architecture & file layout

### The bootstrap problem, stated precisely

`quick-install.sh` (top level) does, for the remote path
(`quick-install.sh:32`): `exec /bin/bash -c "$(curl ... util/quick-install.sh)" -- "$@"`.
At that instant **only `util/quick-install.sh`'s text exists in memory**; the repo is not
on disk. `prepare_and_clone_repo` (`util/quick-install.sh:499`) clones it later. So any
`source util/lib/foo.sh` inside `util/quick-install.sh` would fail on every fresh machine.

### Decision: single self-contained `util/quick-install.sh`, internally sectioned

**Do NOT split into `util/lib/*.sh` that get `source`d at runtime.** Keep
`util/quick-install.sh` a single file that runs correctly when piped as text. Achieve the
"clear separation" goal through **strict in-file sectioning** with banner comments and a
naming convention, not multiple runtime files:

```
util/quick-install.sh
  §0  shebang, colors, set -e, umask            (unchanged head)
  §1  config + env-var capture                  (PF, USE_HTTPS, NO_FONTS, state file)
  §2  arg parser            args_*  / OPT_* vars
  §3  word-list helpers     contains_word, append_unique_word, remove_word (unchanged)
  §4  step engine           STEP_IDS, step_label, step_dependencies,
                            step_default_enabled, run_step, state file I/O (mostly unchanged)
  §5  package registry      pkg_* functions + the literal install_packages_* functions
  §6  TUI primitives        tui_*  (ANSI, raw key read, menu loop)
  §7  wizard screens        wizard_steps_screen, wizard_packages_screen,
                            wizard_confirm_screen, run_wizard
  §8  step bodies           prepare_and_clone_repo ... set_default_shell_fish (unchanged)
  §9  main()                resolve config -> (wizard | non-interactive) -> execute
```

Rationale: a prefix convention (`tui_`, `wizard_`, `pkg_`, `args_`) gives reviewers the
same navigability as separate files with **zero** bootstrap risk and zero new failure
modes. The file grows from ~770 to ~1300–1500 lines; that is acceptable for a
self-contained bootstrap and is the industry norm (rustup, nvm, Homebrew installer are all
single multi-thousand-line scripts).

### Alternative (documented, not chosen): clone-first bootstrap

If the file later becomes unwieldy, the **only correct** way to split is to make the
top-level `quick-install.sh` **clone the repo first, then `exec` the on-disk installer**,
which can then `source util/lib/*.sh`. Sketch:

```
# top-level quick-install.sh (remote path), replacing fetch_remote_bootstrap:
#   1. ensure git + a writable PF
#   2. git clone (HTTPS by default; SSH path needs the interactive key flow that
#      currently lives INSIDE prepare_and_clone_repo — so SSH-first cloning would have
#      to move up here, a non-trivial reshuffle)
#   3. exec /bin/bash "$PF/util/quick-install.sh" "$@"
#   Fallback: if clone fails (offline mirror, private fork), fall back to the current
#   fetch-and-exec-text path with libs inlined.
```

This is explicitly **deferred**. It collides with the SSH-key-before-clone UX
(`prepare_and_clone_repo` generates a key and waits for the user to add it to GitHub
*before* cloning) and would force HTTPS-first or a key flow in the top-level script. Not
worth it now. **The chosen single-file design sidesteps this entirely.**

> Hard rule for implementers: **no `source`/`.` of any path under `$PF` until
> `prepare_and_clone_repo` has completed.** The wizard, arg parser, package registry, and
> TUI primitives are all defined inline above `main` and need nothing from disk.

---

## 2. ANSI TUI component design

All primitives are `tui_*` functions in §6. They assume a VT100/xterm-ish terminal and a
controlling TTY on fd 3 (see [TTY handling](#3-tty-detection--inputoutput-routing)).

### 2.1 Terminal control primitives

| Function | ANSI / behavior |
| --- | --- |
| `tui_supported` | returns 0 only if interactive TTY available, `TERM` not `dumb`, and `tput colors >= 8`. Gate for entering the wizard at all. |
| `tui_enter` | enter alternate screen `\e[?1049h`, hide cursor `\e[?25l`, save `stty` state, set `stty -echo -icanon min 1 time 0`. |
| `tui_leave` | restore `stty`, show cursor `\e[?25h`, leave alt screen `\e[?1049l`. Registered via `trap tui_leave EXIT INT TERM` so a crash never leaves a wrecked terminal. |
| `tui_size` | `LINES=$(tput lines) COLS=$(tput cols)` with `${LINES:-24}` / `${COLS:-80}` fallbacks. Re-read each render so resize is tolerated. |
| `tui_clear` | `\e[2J\e[H`. |
| `tui_move r c` | `\e[${r};${c}H`. |
| `tui_color` / `tui_reset` | reuse the existing `tput`-derived `$RED/$GREEN/...` plus add `DIM`, `REV` (reverse video for the selected row), `CYAN`. |

### 2.2 Key reader (bash 3.2 safe)

```
tui_read_key  ->  echoes a normalized token: UP DOWN LEFT RIGHT SPACE ENTER
                  QUIT TOGGLE_ALL HELP CHAR:<x>
```

Implementation: `read -rsn1 c <&3`. If `c` is ESC (`$'\e'`), do a **non-blocking**
follow-up `read -rsn2 -t 0.01 rest <&3` to capture `[A`/`[B`/`[C`/`[D` (arrows). Map:

- `A`->UP, `B`->DOWN, `C`->RIGHT, `D`->LEFT
- bare space -> SPACE (toggle), `$'\n'`/`''` -> ENTER
- `k`/`j` -> UP/DOWN (vim), `h`/`l` -> LEFT/RIGHT
- `q` -> QUIT, `a` -> TOGGLE_ALL, `?` -> HELP
- digits/letters -> `CHAR:x` (reserved for type-ahead; optional)

`read -rsn1` and the `-t` fractional timeout both work in bash 3.2. No `read -N`.

### 2.3 Generic menu render

`tui_render_menu` is the reusable core for the steps screen and the (flattened) package
screen. Inputs are **parallel indexed arrays** (bash-3.2 safe; no assoc arrays):

- `MENU_LABEL[i]` — display text
- `MENU_STATE[i]` — `on` | `off` | `forced-on` (dependency-locked) | `group` | `child`
- `MENU_INDENT[i]` — 0 for group/step rows, 1 for expanded child package rows
- `MENU_EXPANDED[i]` — `yes`/`no`/`-` (groups only)

Render rules:
- checkbox glyph: `[x]` on, `[ ]` off, `[~]` partial group, `[*]` forced-on (locked).
- selected row drawn in reverse video (`REV`), arrow `>` gutter.
- group rows show an expand caret `▸`/`▾` (ASCII fallback `+`/`-` if `TERM`/locale is poor).
- a fixed header (title + breadcrumb) and a fixed footer (key legend: `↑↓ move ·
  space toggle · → expand · enter next · a all · q quit`).
- a scroll window: keep a `TOP` index; if cursor leaves `[TOP, TOP+window)` adjust `TOP`.
  Window height = `LINES - header - footer`. Long lists scroll; no reliance on terminal
  scrollback.

Every render is a full repaint of the content region (simplest correct approach; flicker
is negligible at these sizes on the alternate buffer).

### 2.4 Screen state machine

`run_wizard` drives three screens with Back/Next:

```
  STEPS  --Next-->  PACKAGES  --Next-->  CONFIRM  --Execute-->  (exit wizard, run)
    ^                  |                    |
    +----Back----------+--------Back--------+
  q at any screen = abort (no changes; exit 130-style clean, terminal restored)
```

Selections persist in shell variables across Back/Next so nothing is lost. See
[Wizard flow](#5-wizard-flow).

---

## 3. TTY detection & input/output routing

The single most important correctness detail. Current code keys off `[ -t 0 ]`
(`util/quick-install.sh:228,305,508`). Under `curl | bash`, **stdin is the script**, so
`[ -t 0 ]` is false and the installer already takes a non-interactive path. The wizard must
do better: try to grab the real terminal.

### Resolution order for the interaction channel

1. If `--silent`/`-s`/`--non-interactive` flag OR `QUICK_INSTALL_SILENT` env set ->
   **non-interactive**, never open a TTY.
2. Else attempt to open the controlling terminal on **fd 3**:
   `exec 3<>/dev/tty 2>/dev/null`. All wizard `read`s use `<&3`; all wizard drawing goes to
   `>&3` (so even if stdout is redirected, the UI reaches the terminal).
3. If `/dev/tty` opens **and** `tui_supported` (TERM ok, colors >= 8) -> **wizard mode**.
4. Else -> **non-interactive** (flags/env/defaults).

This means `curl | bash` on a real terminal **can** show the wizard (because `/dev/tty`
exists even though fd 0 is the pipe). On CI / no-tty, `/dev/tty` open fails and we fall
back cleanly. This is the rustup/oh-my-zsh approach and is the right one.

> Note: the existing `prompt_ssh_key_added_to_github` and `prepare_and_clone_repo` read
> from fd 0. To keep the SSH flow interactive even under `curl | bash`, route those reads
> through the same fd-3 helper (`tty_read`/`tty_available`) so they benefit from the
> `/dev/tty` reopen too. Low-risk, high-value side improvement.

---

## 4. Argument / flag schema, `--help`, precedence

### 4.1 Flags

Parsed by `args_parse "$@"` (§2), setting `OPT_*` variables. Support `--flag=value` and
`--flag value`. Unknown flag -> print error + `--help` synopsis, exit 2.

| Flag | Alias | Effect |
| --- | --- | --- |
| `--help` | `-h` | print help (below), exit 0 |
| `--silent` | `-s`, `--non-interactive` | never show wizard; use flags/env/defaults; sets non-interactive everywhere |
| `--yes` | `-y` | assume "yes" to confirmations (implies running the resolved plan without the confirm screen) |
| `--only=a,b,c` | | run ONLY these step ids (plus their forced dependencies) |
| `--skip=x,y` | | disable these step ids |
| `--no-fonts` | | disable `install_nerd_fonts` (equivalent to `NO_FONTS=1`) |
| `--https` | | clone via HTTPS (equivalent to `USE_HTTPS=1`) |
| `--packages=g1,g2` or `cat:pkg` | | enable only these package groups/individual packages |
| `--skip-packages=...` | | disable these package groups/individual packages |
| `--state-file=PATH` | | override `QUICK_INSTALL_STATE_FILE` |
| `--fresh` | | ignore/clear any resumable state, start a clean run |
| `--list-steps` | | print step ids + labels + defaults, exit 0 |
| `--list-packages` | | print package groups + members per OS, exit 0 |
| `--version` | | print installer version string, exit 0 |

`--only` and `--skip` are mutually exclusive (error if both). Same for
`--packages`/`--skip-packages`.

### 4.2 `--help` text (authoritative)

```
Leo's Profiles quick-install

USAGE:
  quick-install.sh [OPTIONS]
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)"

By default, on an interactive terminal, a setup wizard lets you choose steps and
packages and confirm before anything runs. With no terminal (e.g. piped) or with
--silent, sensible defaults run non-interactively.

OPTIONS:
  -h, --help                 Show this help and exit
  -s, --silent,
      --non-interactive      Skip the wizard; run the resolved plan with defaults
  -y, --yes                  Don't show the confirm screen; proceed once resolved
      --fresh                Ignore any saved resume state; start a clean run
      --only=IDS             Run ONLY these steps (comma-separated step ids)
      --skip=IDS             Skip these steps (comma-separated step ids)
      --packages=SEL         Install ONLY these package groups/items (see below)
      --skip-packages=SEL    Skip these package groups/items
      --no-fonts             Skip nerd-font install (same as NO_FONTS=1)
      --https                Clone via HTTPS instead of SSH (same as USE_HTTPS=1)
      --state-file=PATH      Resume-state file (same as QUICK_INSTALL_STATE_FILE)
      --list-steps           Print all step ids with labels and defaults, then exit
      --list-packages        Print package groups and per-OS members, then exit
      --version              Print version and exit

PACKAGE SELECTION (SEL):
  Comma-separated. A bare name selects a whole group (e.g. dev-tools).
  Use group:item to select one package (e.g. media:ffmpeg).
  Groups: core-utils, shell, dev-tools, languages, media, network, system

ENVIRONMENT (still honored; flags take precedence):
  PF                         Install/clone target (default: $HOME/.leos-profiles)
  USE_HTTPS                  Non-empty => clone via HTTPS
  NO_FONTS                   Non-empty => skip nerd fonts
  QUICK_INSTALL_STATE_FILE   Resume-state file path
  QUICK_INSTALL_SILENT       Non-empty => same as --silent

EXAMPLES:
  quick-install.sh --silent --skip=install_nerd_fonts
  quick-install.sh --only=prepare_and_clone_repo,install_os_packages
  quick-install.sh --silent --packages=core-utils,shell,network --no-fonts
  USE_HTTPS=1 quick-install.sh --silent
```

### 4.3 Precedence (single source of truth: `resolve_plan`)

`resolve_plan` computes the final enabled/skipped sets in this exact order, each later
layer overriding earlier ones:

```
1. defaults      : step_default_enabled + package group defaults
2. wizard         : user toggles (only reached in wizard mode)
3. env vars       : NO_FONTS, USE_HTTPS, QUICK_INSTALL_SILENT, PF, QUICK_INSTALL_STATE_FILE
4. flags          : --only/--skip/--no-fonts/--https/--packages/--skip-packages/...
```

The locked precedence is **flags > env > wizard > defaults**. So the application
order (low to high) is: defaults, then wizard, then env, then flags:

- Start from defaults.
- If wizard runs, apply its selections.
- Then apply env vars (so `NO_FONTS=1` still wins over a wizard "yes").
- Then apply flags (so `--no-fonts` / `--only` win over everything).

Implication worth flagging: **env vars and flags override the wizard.** If a user is in the
wizard and also passed `--skip=install_yarn`, yarn stays skipped regardless of the toggle.
To avoid a confusing UX, the wizard **pre-seeds** its toggles from defaults+env+flags and
**locks** rows that flags/env force (drawn `[*]` forced, like dependency locks). That keeps
the displayed state honest while preserving the precedence rule. After dependency closure
(`ensure_step_dependencies_selected`) runs last, since deps are correctness, not preference.

`--only` semantics: enable exactly the listed steps, then run dependency closure (so a
listed step's prerequisites are pulled in and shown as forced-on).

---

## 5. Package registry data model (bash 3.2 compatible)

### Problem with today's code

Package lists are hardcoded inside `install_packages_macos/apt/fedora/pacman`
(`util/quick-install.sh:533–581`) as literal `brew install ...` / `apt ... install ...`
arg lists. `verify-quick-install-packages.py` depends on exactly that shape: it regex-grabs
each function body (`extract_function_block`, verify:99) and reads tokens after
`install`/`-S` (verify:109–175).

### Decision: registry as newline-delimited string tables; **keep the four
`install_packages_*` functions emitting literal name lists**

We add a **logical grouping layer** for the UI without changing what the four OS functions
ultimately pass to the package manager. The registry is a set of plain functions returning
newline-delimited rows — no associative arrays.

#### 5.1 Group definitions (OS-independent identity)

```
pkg_groups() {            # group ids, render order
  printf '%s\n' core-utils shell dev-tools languages media network system
}
pkg_group_label() {       # id -> human label (case, like step_label)
  case "$1" in
    core-utils) echo "Core CLI utilities" ;;
    shell)      echo "Shell (fish, zsh, completions)" ;;
    dev-tools)  echo "Developer tools & build" ;;
    languages)  echo "Languages & runtimes" ;;
    media)      echo "Media (ffmpeg, imagemagick, yt-dlp)" ;;
    network)    echo "Network & transfer (wget, rclone)" ;;
    system)     echo "System & disk (smartmontools)" ;;
    *) echo "$1" ;;
  esac
}
```

#### 5.2 Canonical members per group (logical package ids)

A canonical/logical id (usually the macOS/Homebrew name) is the registry key. Members are a
space/newline list:

```
pkg_group_members() {     # group id -> canonical member ids
  case "$1" in
    core-utils) echo "bash coreutils diffutils ed findutils gnu-indent gnu-sed gnu-tar gnu-which grep gawk gzip less nano sed tar which" ;;
    shell)      echo "fish zsh" ;;
    dev-tools)  echo "git vim build-essential clang gcc" ;;
    languages)  echo "node python ruby" ;;
    media)      echo "ffmpeg imagemagick yt-dlp" ;;
    network)    echo "wget rclone gnutls heroku ssh-copy-id" ;;
    system)     echo "smartmontools" ;;
    *) echo "" ;;
  esac
}
```

(Final grouping to be tuned during implementation against the actual four lists — the table
above is the starting partition and MUST collectively cover every package currently
installed per OS.)

#### 5.3 Canonical -> per-OS name mapping

The crux of "map back to correct per-OS package names." A single resolver, driven by `case`
on `(os, canonical)`; default is "same name; if empty, package absent on that OS":

```
pkg_resolve() {           # $1=os(macos|apt|fedora|pacman) $2=canonical -> real name or "" if N/A
  local os="$1" id="$2"
  case "$os:$id" in
    apt:coreutils|fedora:coreutils|pacman:coreutils) echo "$id" ;;
    *:gnu-indent)  [ "$os" = macos ] && echo gnu-indent ;;        # brew-only
    *:gnu-sed)     [ "$os" = macos ] && echo gnu-sed ;;
    *:gnu-tar)     [ "$os" = macos ] && echo gnu-tar ;;
    *:gnu-which)   [ "$os" = macos ] && echo gnu-which ;;
    *:gnutls)      [ "$os" = macos ] && echo gnutls ;;
    *:ssh-copy-id) [ "$os" = macos ] && echo ssh-copy-id ;;
    *:heroku)      [ "$os" = macos ] && echo heroku ;;            # via heroku/brew tap
    *:build-essential) [ "$os" = apt ] && echo build-essential ;; # apt-only meta
    *:clang)       case "$os" in apt) echo clang ;; esac ;;
    *:gcc)         case "$os" in apt) echo gcc ;; esac ;;
    apt:node)      echo nodejs ;;
    fedora:node)   echo nodejs ;;
    pacman:node)   echo "nodejs npm" ;;                            # pacman needs npm too
    macos:node)    echo node ;;
    *:python)      case "$os" in macos) echo python ;; pacman) echo python ;; apt|fedora) echo python-is-python3 ;; esac ;;
    macos:imagemagick|apt:imagemagick|pacman:imagemagick) echo imagemagick ;;
    fedora:imagemagick) echo ImageMagick ;;
    # ...default: same name on every OS (bash, fish, git, grep, gawk, gzip, less, nano,
    #    vim, wget, ed, diffutils, findutils, ffmpeg, rclone, ruby, smartmontools,
    #    yt-dlp, zsh)
    *) echo "$id" ;;
  esac
}
```

The mapping table above is **derived directly** from the four current lists
(`util/quick-install.sh:540–580`). Notable per-OS facts the table encodes: Homebrew has the
`gnu-*`/`gnutls`/`ssh-copy-id`/`heroku` extras and `node`/`python`; apt uses `nodejs` +
`python-is-python3` + `build-essential`+`clang`+`gcc`; fedora uses `nodejs` +
`python-is-python3` + `ImageMagick` (capitalized) and gets `development-tools` group +
ffmpeg swap separately; pacman uses `nodejs npm` + `python` + `base-devel`.

#### 5.4 How the four OS functions consume the registry

Two implementation options; **Option A is the default** because it keeps the verify script
untouched.

**Option A — registry feeds a generator, generator output is committed as the literal
lists (build step), OR the functions are kept literal and the registry is a *parallel UI
view* validated against them by a test.**

Concretely for A: keep `install_packages_macos/apt/fedora/pacman` exactly as today (literal
`brew install a b c`). The registry (5.1–5.3) is the **UI + filtering** layer. When the user
deselects a group, `resolve_plan` produces a `PKG_SKIP` set of *canonical* ids; each OS
function, just before invoking the package manager, **filters its literal list** through a
one-line helper:

```
# inside install_packages_apt, after building the literal list as today:
pkgs="bash build-essential clang ... zsh"          # unchanged literal (verify still parses this)
pkgs=$(pkg_filter_for_os apt "$pkgs")              # drops user-skipped canonicals
sudo apt -y install $pkgs
```

`pkg_filter_for_os` reverse-maps each literal name to its canonical id and drops it if the
canonical is in `PKG_SKIP`. The **literal list stays in the source verbatim**, so
`verify-quick-install-packages.py` keeps working with **zero changes**. This is the
recommended path: lowest risk, preserves the verify contract, and the registry is purely
additive.

**Option B — fully data-driven (functions built from registry at runtime).** The four
functions become `sudo apt -y install $(pkg_list_for_os apt)`. Cleaner, but it **breaks the
verify parser** (no literal `apt install a b c` to regex). If B is chosen, the verify script
must be updated (see §8) to import the canonical registry instead of regexing function
bodies — a larger, riskier change. **Not recommended for the first iteration.**

> Decision: ship **Option A**. Revisit B only after the registry + verify-via-registry are
> both proven.

---

## 6. Wizard flow

```
main:
  args_parse "$@"                     # -> OPT_*
  capture_env                         # -> ENV_* (PF, USE_HTTPS, NO_FONTS, ...)
  handle_immediate_flags              # --help/--version/--list-steps/--list-packages -> exit
  open_interaction_channel            # fd 3 = /dev/tty or none; sets MODE=wizard|silent
  prepare_run_plan                    # existing resume logic (+ --fresh handling)

  if MODE = wizard and not resuming-without-prompt:
     run_wizard                       # may set STATE_ENABLED_STEPS, PKG_SKIP, etc.
  else:
     resolve_plan_noninteractive

  resolve_plan                        # apply precedence defaults<wizard<env<flags
  ensure_step_dependencies_selected   # existing, unchanged (dep closure)
  save_state_file

  for step in STEP_IDS: run_step      # existing loop, unchanged
  clear_state_file on success
```

### Screen 1 — Steps

- Lists `STEP_IDS` with `step_label`, pre-seeded from defaults+env+flags.
- Dependency-locked rows are `[*]` and cannot be turned off (live recompute via
  `ensure_step_dependencies_selected` after each toggle so the lock set is always correct).
- Footer: `space toggle · a all/none · enter Next · q quit`.

### Screen 2 — Packages (grouped, expandable)

- Only shown if `install_os_packages` is enabled (else skipped with a note).
- Rows = groups (`pkg_groups`) with `[x]/[ ]/[~]` tri-state. `→`/`l`/`space-on-caret`
  expands a group to indented child rows (its canonical members **for the detected OS
  only**, resolved via `pkg_resolve`; members that map to "" on this OS are hidden).
- Toggling a group toggles all its (OS-present) children; toggling children updates the
  group to `[~]` partial.
- Footer adds: `→ expand · ← collapse`.

### Screen 3 — Confirm

- Read-only summary: enabled steps (with any forced-by-dependency annotations), skipped
  steps, and per-group package counts (`media: 2/3 selected (skipping yt-dlp)`).
- Shows clone method (SSH/HTTPS) and font decision.
- Footer: `enter Execute · b Back · q quit`. `--yes` auto-confirms and skips this screen.

On Execute: `tui_leave` (restore terminal), then the normal step loop runs with ordinary
scrolling log output (the install itself is **not** in the alt-screen — users want a
scrollable log).

---

## 7. Error recovery improvements

Builds on the existing machine (`run_step`, `save_state_file`, `STATE_LAST_FAILED_STEP`,
`record_interrupted_run`). Current behavior: on failure, mark step failed, exit; on re-run,
offer "continue from failed step." Improvements:

1. **Persist the resolved plan, not just step status.** Today `STATE_ENABLED_STEPS` is
   saved (`save_state_file`, `:141`) but **package selections are not**. Add
   `STATE_PKG_SKIP` (and `STATE_PKG_ENABLE` if needed) to the state file so a resumed run
   re-applies the same package choices without re-running the wizard. Backward-compatible:
   absent fields default to empty.
2. **Resume is wizard-free by default.** On detecting a resumable failed run, the
   non-interactive prompt ("Continue from failed step? [Y/n]") stays — but skip the wizard
   entirely on resume unless `--fresh` is passed. This prevents re-litigating choices
   mid-recovery.
3. **Per-step retry policy.** In `run_step`, on failure offer (interactive only, via fd 3):
   `[R]etry / [S]kip / [A]bort`. Retry re-invokes the step body; Skip marks it skipped and
   continues (existing `mark_step_skipped`); Abort exits 1 with the resumable state intact.
   Non-interactive/silent keeps today's behavior (fail + exit, resumable).
4. **Idempotent step guarantees stay.** Steps already guard (`[ -d "$PF" ]`,
   `[ -d "$HOME/.pyenv" ]`, seed-if-absent). Document the contract: every step body must be
   safe to re-run, since Retry and resume both depend on it.
5. **Trap hygiene with the TUI.** The existing `trap record_interrupted_run INT TERM`
   (`:765`) must compose with `trap tui_leave EXIT INT TERM`. Wizard-phase traps restore the
   terminal first, then the install phase restores the original interrupted-run trap. Define
   a single `on_signal` dispatcher to avoid clobbering.

---

## 8. Keeping `verify-quick-install-packages.py` aligned

With **Option A** (recommended): the four `install_packages_*` functions keep their literal
`brew install ... / apt ... install ... / dnf ... install ... / pacman -S ...` lines
verbatim. `verify-quick-install-packages.py` parses those (verify:99–182) **unchanged**.
The registry filtering (`pkg_filter_for_os`) only ever **removes** names at runtime; it
never changes the source text the verifier reads. **No verify changes required.**

Guard against drift with a new tiny test (see §9): assert that the **union of
`pkg_group_members` (after `pkg_resolve` per OS)** equals the literal list each
`install_packages_*` installs. That catches a package added to a function but not to a
group (or vice versa). This is the only new coupling and it is test-enforced.

If **Option B** is ever adopted: rewrite `parse_quick_install` (verify:134) to source/parse
the registry tables (`pkg_group_members` + `pkg_resolve`) instead of regexing function
bodies — e.g. shell out to `bash -c 'source installer; for os in ...; pkg_list_for_os $os'`
and read the names. Larger change; explicitly out of scope for v1.

---

## 9. Testing / verification strategy

Testing a TTY UI is the hard part. Strategy = mostly **function-level unit tests** of pure
logic, plus a few **driven end-to-end** checks.

### 9.1 Pure-function unit tests (no TTY needed) — highest value

Add `util/test-quick-install.sh` (bash, runnable in CI). Because all logic lives in
sourceable functions, source the installer with a guard so `main` does **not** auto-run
when sourced:

```
# at bottom of util/quick-install.sh, replace `main "$@"` with:
case "${QUICK_INSTALL_SOURCED:-}" in
  1) : ;;                       # sourced for tests: define functions, don't run
  *) main "$@" ;;
esac
```

Then unit-test:
- `args_parse`: each flag sets the right `OPT_*`; `--only`+`--skip` errors; `=value` and
  ` value` forms; unknown flag exits 2.
- `resolve_plan`: precedence matrix — defaults vs wizard vs env vs flags, including the
  "flag overrides wizard" and "env overrides wizard" cases.
- `ensure_step_dependencies_selected`: closure correctness (e.g. enabling `install_ai_tools`
  pulls in `setup_nvm_default_node` -> `install_os_packages`).
- `pkg_resolve`: spot-check per-OS names (apt node->nodefs? no: nodejs; fedora
  imagemagick->ImageMagick; pacman node->"nodejs npm"; python mapping).
- `pkg_filter_for_os`: skipping group `media` drops ffmpeg/imagemagick/yt-dlp from each OS
  literal list and nothing else.
- **Registry/literal parity** (the §8 drift guard): union of resolved members == literal
  function list, per OS.
- Word-list helpers regression (`contains_word`, `append_unique_word`, `remove_word`) —
  unchanged but now load-bearing.

### 9.2 Key-decode unit tests

`tui_read_key` can be tested without a real terminal by feeding bytes on fd 3 from a string:
`printf '\e[A' | tui_read_key` (route the function's `<&3` to a here-string in the test).
Assert UP/DOWN/SPACE/ENTER/QUIT decode correctly, including the ESC-then-`[A` arrow path and
a lone ESC (timeout) -> treated as QUIT or ignored.

### 9.3 Driven end-to-end (TTY emulation)

- **Non-interactive smoke:** `bash util/quick-install.sh --silent --only=prepare_and_clone_repo
  --https` in a container/VM; assert it clones and exits 0, state file cleared. Add
  `--list-steps` / `--list-packages` golden-output tests (pure, no side effects).
- **Wizard smoke via `script`/`expect`:** use `expect` (or `tmux send-keys` against a pane,
  which the qa-tester agent can drive) to launch the installer with a forced pseudo-TTY,
  send `Down Down Space Enter Enter Enter`, and assert the resolved plan / that it reaches
  the step loop. Keep this to 1–2 happy-path flows; the heavy logic is already covered by
  9.1. Verifying exact ANSI bytes is brittle and explicitly **not** a goal.
- **Terminal-restoration test:** launch under `script`, send `q`, assert the terminal is
  restored (cursor visible, alt-screen left) by checking the emitted trailing escape
  sequences include `\e[?1049l` and `\e[?25h`.

### 9.4 Lint / compat

- `shellcheck util/quick-install.sh` clean (it'll flag the intentional `eval` word-list
  helpers — keep existing disables).
- **bash 3.2 gate:** run the unit suite under `/bin/bash` (3.2) on macOS, not just 5.x. CI
  matrix should include a 3.2 invocation (`docker run bash:3.2` or macOS runner) to catch
  `declare -A`/`mapfile`/`${var^^}` regressions.
- `verify-quick-install-packages.py` still runs green (no code change under Option A).

---

## 10. Backward-compatibility guarantees

- `bash -c "$(curl ... quick-install.sh)"` with **no args** behaves like today on a real
  terminal except it now shows the wizard (pre-seeded to today's defaults; pressing
  `enter enter enter` = current default install). Under `curl | bash` with no `/dev/tty`,
  it runs the **same default non-interactive plan** as today.
- All env vars unchanged: `USE_HTTPS`, `NO_FONTS`, `PF`, `QUICK_INSTALL_STATE_FILE` keep
  exact current semantics; new `QUICK_INSTALL_SILENT` is additive.
- The state file format is a superset (new `STATE_PKG_*` lines); old state files load fine
  (missing vars default empty). A resumed pre-upgrade run still works.
- Step ids, labels, dependencies, ordering, and bodies are unchanged. SSH-key flow, brew
  detection, `install_ai_tools`, nerd-fonts desktop gate all preserved.
- `verify-quick-install-packages.py` unchanged and still green (Option A).
- Top-level `quick-install.sh` bootstrap unchanged (still fetch-and-exec text; no `source`
  of repo files pre-clone).

## 11. Risks

1. **Wizard under `curl | bash` relies on `/dev/tty`.** If a user's environment has no
   `/dev/tty` (some minimal containers), they silently get the non-interactive path. This is
   correct behavior but should be documented; `--silent` makes it explicit.
2. **File size growth** (~2x). Mitigated by strict sectioning + prefix naming. The
   alternative (clone-first split) is worse given the SSH-before-clone UX.
3. **Registry/literal drift** (Option A keeps two sources of package truth). Mitigated by
   the §9.1 parity test, which must be in CI before merge.
4. **Terminal restoration on crash.** A bug in `tui_leave`/trap composition could leave a
   wrecked terminal. Mitigated by `trap ... EXIT` and the restoration test (§9.3).
5. **bash 3.2 regressions** are easy to introduce (everyone develops on 5.x). The CI 3.2
   gate (§9.4) is non-optional.

## Out of scope / YAGNI

- Mouse support, themes, animations, Unicode box-drawing beyond simple carets.
- Clone-first bootstrap refactor (documented in §1 as the deferred alternative).
- Option B data-driven package functions + verify rewrite (documented, deferred).
- Adding new packages or steps — this is structure only.
