# Working on Leo's Profiles

Notes for coding agents (and people) changing this repository. Installing the
profile is not an agent task: users run the bootstrap one-liner in the
README themselves, and `install.sh setup` asks them its questions.

## Layout

- `bootstrap.sh`: the curl entry point; installs Git, clones or fast-forwards
  `~/.leos-profiles`, starts `install.sh setup`.
- `install.sh` and `installer/*.sh`: the installer. `setup` is the
  interactive front end (`installer/setup.sh` for its stages,
  `installer/ui.sh` for the gum or plain prompts); `inspect`, `apply`,
  `reconcile`, `remove-blocks` and `inventory` are the engine.
- `zsh/`: the shell profile itself (`start.zsh` loads the rest).
- `util/rmdsstore.py`: the metadata cleaner `bye` runs.
- `tests/`: the suites below.
- Docs: `README.md` for users; `docs/development.md` for module boundaries,
  the inspect TSV contract, the apply flow, CI and the release-age rules.
  Read the relevant section of `docs/development.md` before changing the
  installer.

## Rules

- Every installer and bootstrap script must run under macOS's `/bin/bash`
  3.2: no `declare -A`, `mapfile`/`readarray`, `${var,,}`/`${var^^}`,
  `[[ -v ]]`, negative array indices, `{fd}<` redirections or `&>>`. Under
  `set -u`, expand a possibly empty array as `${a[@]+"${a[@]}"}`. Use BSD-
  and GNU-compatible `sed`, `awk`, `stat`, `date` and `mktemp` flags.
- Sourced modules only define functions and variables; nothing provisions on
  load. Use `LEOS_PROFILES_INSTALL_LIB_ONLY=1` to source `install.sh` in
  tests.
- A new inspect record type, or a changed column count, goes into the table
  in `docs/development.md` in the same change: `tests/readonly-test.sh`
  checks every record against it.
- Tests stub package managers, GitHub, sudo and anything else that changes the
  host, and use a fixture HOME; never touch the real HOME or `local/`. A new
  test must fail without the change it covers.
- Commit messages explain why; keep the user-facing docs in step with
  behaviour.

## Checks

From the repository root:

```bash
for f in install.sh bootstrap.sh installer/*.sh tests/*.sh; do bash -n "$f" || exit; done
for f in zsh/*.zsh zsh/path/*.zsh tests/*.zsh; do zsh -n "$f" || exit; done
shellcheck -s bash -x install.sh bootstrap.sh installer/*.sh tests/*.sh   # 0.11.0
bash tests/install-test.sh
bash tests/credentials-test.sh
bash tests/node-test.sh
bash tests/migration-test.sh
bash tests/apply-dryrun-test.sh
bash tests/readonly-test.sh
zsh tests/profile-test.zsh
zsh tests/runtime-cache-test.zsh
python3 tests/rmdsstore_test.py
ruff check util tests
actionlint
```

To see the setup wizard without changing anything:
`bash install.sh setup --dry-run` (add `--plain` for the numbered prompts).
