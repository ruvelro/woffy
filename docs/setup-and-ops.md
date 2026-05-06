# Setup And Ops

## Repo Stack
- Language: Bash
- Delivery: single executable script
- State: SQLite
- CI: GitHub Actions on Ubuntu
- Test framework: Bats

## Runtime Dependencies
- Base: `bash`, `curl`, `date`, `awk`
- API and JSON: `jq`
- State: `sqlite3`
- Scheduling: `crontab`, `readlink`
- Backup: `tar`

## Install Model
- Installer downloads `woffy.sh` from GitHub raw content.
- Target binary path: `~/.local/bin/woffy`.
- Installer optionally performs `woffy login <email> <password>`.
- Installer clears previous woffy cron entries and installs the single `run due` orchestrator.

## Runtime Files
- `~/.woffy/woffy.db`
- `~/.woffy/woffy.log`
- `~/.woffy/woffy.lock.d`

## Operational Commands
- Worker setup: `woffy login <email> <password>`, `woffy users`, `woffy user <email>`, `woffy users enable|disable|delete <email>`.
- Core: `woffy status <email>`, `woffy in <email>`, `woffy out <email>`, `woffy dry-run in|out <email>`.
- Scheduling: `woffy run due`, `woffy schedule install`, `woffy schedule list`, `woffy schedule clear`, `woffy schedule user <email> ...`.
- Investigation: `woffy events all`, `woffy events <email> --days 30|60 --status error`.
- Reporting: `woffy report all`.
- Maintenance: `woffy doctor`, `woffy self-test`, `woffy config check`, `woffy backup`, `woffy restore`, `woffy changelog`, `woffy update`.

## CI And Verification
- CI installs `shellcheck`, `shfmt`, `bats`, and `sqlite3`.
- CI runs shellcheck, non-blocking shfmt diff, and Bats tests.
