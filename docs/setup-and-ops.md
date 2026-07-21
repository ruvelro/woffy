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
- Notifications: `woffy telegram configure --token-stdin ...`, `woffy telegram set-mode all|errors|success` (changes only the notification level, no token/chat id re-entry).
- Maintenance: `woffy doctor`, `woffy self-test`, `woffy config`, `woffy backup`, `woffy restore`, `woffy changelog`, `woffy update`.

## Optional Web Panel

### Install

```bash
printf '%s\n' "$ADMIN_PASSWORD" | woffy web install --password-stdin
woffy web status
```

`web install` downloads the checksummed offline artifact (vendored Python dependencies, no runtime CDN), creates the Argon2id admin credential, and registers a `systemd --user` service (`woffy-web.service`) bound to `127.0.0.1:8787` by default. Use `--port N` to pick a different local-only port.

### Reach it through an SSH tunnel

The panel binds **only to loopback**, never to a public interface. From the client machine:

```bash
ssh -L 8787:127.0.0.1:8787 user@vps
```

Keep that SSH session open and browse `http://127.0.0.1:8787` locally; traffic is encrypted end-to-end inside the tunnel. Do not change the bind address or expose port 8787 publicly — there is no TLS/public-exposure hardening on the panel itself, by design.

If the VPS does not retain user services after logout, enable user lingering according to host policy (`loginctl enable-linger <user>`); otherwise run `woffy web serve [port]` in a managed foreground session (`tmux`/`screen`) as the fallback.

### Operate the service

```bash
woffy web start|stop|restart|status
woffy web logs [N]
woffy web passwd            # rotates the administrator password, invalidates all sessions
woffy web update stable|nightly
woffy web uninstall         # removes only the panel; CLI data is untouched
```

`woffy web update` stages and health-checks a release before switching; `current` is restored from `previous` automatically on a failed post-check, so a bad panel update never leaves the service down.

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
