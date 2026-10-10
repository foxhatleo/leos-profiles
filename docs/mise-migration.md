# Design note: consolidating fnm + pyenv + rbenv onto mise

**Status:** not adopted. Written as a follow-up to the 2026-08 review so the
decision has a record and does not have to be re-derived. Function and
variable names below are the installer's as of 2026-08: locked binaries are now
rows in `artifact_registry` (`installer/registry.sh`), installed through
`artifact_install`, and steps are registry components.

## What prompted it

The review flagged that this profile runs three version managers where mise is
the modern single replacement. That was true, but its headline argument — startup
cost — has since been addressed directly: `pyenv init`/`rbenv init` were the two
heaviest lines in the profile (~365 ms of a 550 ms startup), and caching plus
`--no-rehash` brought total interactive startup to **~0.12 s**. mise's own
activate costs roughly 50 ms, so migrating today would not make shells faster.

What remains is a genuine simplification argument, not a performance one.

## What migrating would actually involve

1. **Pin the binary.** `installer/lock.sh` would gain `MISE_VERSION` plus a
   per-platform URL and SHA-256, and `install.sh` a `mise` step using the
   existing `install_locked_archive_binary` path. mise publishes per-arch
   tarballs, so this fits the current pattern directly.
2. **Retire two install steps.** `install_pyenv` and `install_rbenv` (with the
   `ruby-build` plugin clone and the `src/configure && make` compile) would go
   away, along with their `verify_step` arms and `step_signature` material. The
   `CANONICAL_STEPS` vocabulary changes, which changes every step signature — so
   the first reconcile after the change re-runs everything.
3. **Collapse three snippets into one.** `zsh/path/{pyenv,rbenv,fnm}.zsh` become
   a single `zsh/path/mise.zsh` doing `eval "$(mise activate zsh)"`. Note this
   *cannot* use `leos-source-cached`: like `fnm env`, mise's activate output is
   per-shell.
4. **Re-provision installed runtimes.** This is the real cost. Existing
   `~/.pyenv` and `~/.rbenv` installs are not readable by mise; every Python and
   Ruby version in use has to be reinstalled under mise, and Ruby builds are
   slow. `.python-version` / `.ruby-version` / `.node-version` files keep
   working (mise reads all three), so project repos need no changes.
5. **Keep a fallback.** Machines where the mise step was skipped still need the
   old snippets, so they would stay as guarded fallbacks for at least one
   release rather than being deleted outright.

## Why it is not being done now

- The performance case is gone; the remaining benefit is one less tool concept
  and one activate instead of three.
- The migration's cost is concentrated in re-provisioning runtimes on every
  machine, which is exactly the kind of thing that goes wrong quietly.
- pyenv and rbenv are pinned to reviewed commits and currently work. Replacing a
  working, pinned dependency with a differently-pinned one is churn unless
  something is actually wrong.

## When to revisit

- A fourth language manager would otherwise be added (that is the point where
  three becomes clearly too many).
- pyenv or rbenv breaks on a new macOS/Linux release and the fix is not cheap.
- Per-project tool versions beyond Python/Ruby/Node are wanted — mise's
  `.mise.toml` covers arbitrary tools, which the current trio cannot do at all.
