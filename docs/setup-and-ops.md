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
- Installer downloads checksummed executable assets from the latest GitHub Release; the raw script only bootstraps the installer.
- Target binary path: `~/.local/bin/woffy`.
- Installer temporarily accepts deprecated email/password arguments; secure login is a separate prompt/stdin command.
- Installer clears previous woffy cron entries and installs the single `run due` orchestrator.

## Runtime Files
- `~/.woffy/woffy.db`
- `~/.woffy/woffy.log`
- `~/.woffy/woffy.lock.d`

## Operational Commands
- Worker setup: `woffy login <email>` or `--password-stdin`, `woffy users`, `woffy user <email>`, `woffy users enable|disable|delete <email>`.
- Core: `woffy status <email>`, `woffy in <email>`, `woffy out <email>`, `woffy dry-run in|out <email>`.
- Scheduling: `woffy run due`, `woffy schedule install`, `woffy schedule list`, `woffy schedule clear`, `woffy schedule user <email> ...`.
- Investigation: `woffy events all`, `woffy events <email> --days 30|60 --status error`.
- Reporting: `woffy report all`.
- Maintenance: `woffy doctor`, `woffy self-test`, `woffy config check`, `woffy backup`, `woffy restore`, `woffy changelog`, `woffy update`.

## CI And Verification
- CI installs `shellcheck`, `shfmt`, `bats`, and `sqlite3`.
- CI treats shellcheck and shfmt as blocking, runs Bats on Ubuntu/macOS, verifies generated output and simulates VPS update/rollback.

## systemd User Equivalent
Cron remains the supported installer path. It must be cleared before enabling this alternative.

`~/.config/systemd/user/woffy.service`:
```ini
[Unit]
Description=Woffy due-slot orchestrator
[Service]
Type=oneshot
ExecStart=%h/.local/bin/woffy run due --quiet
```

`~/.config/systemd/user/woffy.timer`:
```ini
[Unit]
Description=Run Woffy every minute
[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true
Unit=woffy.service
[Install]
WantedBy=timers.target
```

Enable with `systemctl --user daemon-reload && systemctl --user enable --now woffy.timer`. Do not run the timer alongside the cron entry; both target the same global lock.
