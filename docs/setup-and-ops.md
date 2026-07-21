# Setup And Ops

## Repo Stack
- Languages: Bash CLI; optional Python web companion
- Delivery: single CLI executable plus optional checksummed web archive
- State: SQLite
- CI: GitHub Actions on Ubuntu
- Test frameworks: Bats, pytest and Playwright

## Runtime Dependencies
- Base: `bash`, `curl`, `date`, `awk`
- API and JSON: `jq`
- State: `sqlite3`
- Scheduling: `crontab`, `readlink`
- Backup: `tar`
- Optional web: Linux x86_64, CPython 3.11-3.13, systemd user services

## Install Model
- Installer downloads checksummed executable assets from the latest GitHub Release; the raw script only bootstraps the installer.
- Target binary path: `~/.local/bin/woffy`.
- Installer temporarily accepts deprecated email/password arguments; secure login is a separate prompt/stdin command.
- Installer clears previous woffy cron entries and installs the single `run due` orchestrator.

## Runtime Files
- `~/.woffy/woffy.db`
- `~/.woffy/woffy.log`
- `~/.woffy/woffy.lock.d`
- `~/.woffy/web/web.db` and `config.json` for optional web-only state
- `~/.local/share/woffy-web/current` and `previous` release links
- `~/.local/state/woffy-backups` for recovery archives that must survive uninstall

## Operational Commands
- Worker setup: `woffy login <email>` or `--password-stdin`, `woffy users`, `woffy user <email>`, `woffy users enable|disable|delete <email>`.
- Core: `woffy status <email>`, `woffy in <email>`, `woffy out <email>`, `woffy dry-run in|out <email>`.
- Scheduling: `woffy run due`, `woffy schedule install`, `woffy schedule list`, `woffy schedule clear`, `woffy schedule user <email> ...`.
- Investigation: `woffy events all`, `woffy events <email> --days 30|60 --status error`.
- Reporting: `woffy report all`.
- Maintenance: `woffy doctor`, `woffy self-test`, `woffy config`, `woffy backup`, `woffy restore`, `woffy changelog`, `woffy update`.

## Optional Web Panel

```bash
printf '%s\n' "$ADMIN_PASSWORD" | woffy web install --password-stdin
systemctl --user status woffy-web.service
ssh -L 8787:127.0.0.1:8787 user@vps
```

Open `http://127.0.0.1:8787` locally. Do not change the bind address or expose port 8787 publicly. If the VPS does not retain user services after logout, enable user lingering according to the host policy; otherwise run `woffy web serve` in a managed foreground session.

Use `woffy web passwd` to rotate the administrator password and invalidate all sessions. `woffy web update stable|nightly` stages and health-checks a release; `current` is restored to `previous` on failure. `woffy web uninstall` removes only the panel and preserves CLI data.

The runtime configuration interface accepts only documented bounded integer keys. Persistent SQLite values are used unless the corresponding `WOFFY_*` environment variable is set.

## CI And Verification
- CI installs Bash tooling plus Python/Playwright.
- CI blocks on shellcheck, shfmt, Bats, pytest, Chromium E2E, generated output, CLI VPS update and offline web install/rollback.

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
