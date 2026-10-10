# Notes for coding agents

Leo's Profiles is a Zsh workstation profile (`zsh/`) and a deterministic
Bash installer (`install.sh`, `installer/*.sh`) with an interactive front end,
`install.sh setup` (`installer/setup.sh`). [README.md](./README.md) is the
user guide; [docs/development.md](./docs/development.md) is the engineering
guide and the reference for everything below.

## Rules

- **Bash 3.2.** The installer and `tests/*.sh` run under macOS `/bin/bash`
  3.2: no associative arrays, `mapfile`/`readarray`, `${var,,}`, `declare -n`
  or negative array indices; expand possibly empty arrays as
  `${a[@]+"${a[@]}"}` under `set -u`. Run the Bash suites with `/bin/bash` on
  macOS as well as a current Bash.
- **Never run `tests/provisioning-test.sh`** (or
  `tests/provisioning-container.sh`) outside disposable CI: it installs and
  upgrades real host packages, and its guard is deliberate. Do not run
  `install.sh apply`, `reconcile` or `setup` against your real HOME either;
  tests use a fixture HOME, a copy of the checkout and PATH fakes.
- **Read-only stays read-only.** `inspect`, `inspect --saved`, `inventory`,
  `apply --dry-run` and `reconcile --dry-run` must not write anything
  (`tests/readonly-test.sh` proves it).
- **The TSV contract.** Every inspect record type and its column count is in
  the table in docs/development.md, "State and TSV contract". Change the
  emitter and the table together; `tests/readonly-test.sh` fails on drift.
  Parsers dispatch on the record type and keep empty columns.
- **The wizard has no provisioning logic.** `installer/setup.sh` reads
  `inspect` records and runs `apply`/`reconcile` with explicit flags; new
  behaviour belongs in the engine and its records.

## Local checks

From the repository root:

```bash
shellcheck -s bash -x install.sh installer/*.sh tests/*.sh
for file in zsh/*.zsh zsh/path/*.zsh tests/*.zsh; do zsh -n "$file" || exit; done
bash tests/install-test.sh
/bin/bash tests/install-test.sh
bash tests/credentials-test.sh
bash tests/node-test.sh
bash tests/apply-dryrun-test.sh
/bin/bash tests/readonly-test.sh
bash tests/setup-wizard-test.sh
zsh tests/profile-test.zsh
zsh tests/runtime-cache-test.zsh
/usr/bin/python3 -I tests/rmdsstore_test.py
```

The network-backed checks and CI layout are in docs/development.md.
