# CHECKLIST de Release (pre-main)

Use this list before merging to `main`.

## 1) Integrity and format
- [ ] `bash -n woffy.sh` without errors.
- [ ] `bash -n install-woffy.sh` without errors.
- [ ] `chmod +x woffy.sh install-woffy.sh`.

## 2) Install
- [ ] Standard install works:
  - `curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash`
- [ ] Binary installed at `~/.local/bin/woffy`.

## 3) Config/login
- [ ] `woffy login` works with valid credentials.
- [ ] Files are created/updated:
  - `~/.woffy.conf` (600)
  - `~/.woffy.token` (600)
  - `~/.woffy.user` (600)
- [ ] `woffy user` shows coherent data.

## 4) Sign and status
- [ ] `woffy status` responds.
- [ ] `woffy in` works when expected.
- [ ] `woffy out` works when expected.
- [ ] Double sign attempts are blocked.

## 5) Dry-run
- [ ] `woffy dry-run in` simulates without real sign.
- [ ] `woffy dry-run out` simulates without real sign.

## 6) Report
- [ ] `woffy report` (text) is correct.
- [ ] `woffy report --format json` is valid.
- [ ] `woffy report --format csv` is valid.
- [ ] `woffy report --from YYYY-MM-DD --to YYYY-MM-DD` filters correctly.
- [ ] `woffy report --strict --from ... --to ...` fails on invalid range.
- [ ] `woffy report telegram` sends when Telegram is configured.

## 7) Telegram
- [ ] `woffy telegram` saves config.
- [ ] `woffy telegram test` reaches chat.
- [ ] `woffy notify test success|warning|error|info|all` works.
- [ ] `--no-telegram` blocks sends when used.

## 8) Cron / schedule
- [ ] `woffy schedule list` shows tasks.
- [ ] `woffy schedule entrada` / `salida` create tasks.
- [ ] `woffy schedule pause` pauses woffy tasks.
- [ ] `woffy schedule resume` resumes woffy tasks.
- [ ] `woffy schedule report` sets Friday 18:00.
- [ ] `woffy schedule timezone Europe/Madrid` sets CRON_TZ.
- [ ] `woffy schedule clear` removes woffy tasks.

## 9) Systemd user timers
- [ ] `woffy schedule systemd enable` creates/enables timers.
- [ ] `woffy schedule systemd status` shows status.
- [ ] `woffy schedule systemd disable` removes timers.

## 10) Maintenance
- [ ] `woffy doctor` is correct.
- [ ] `woffy doctor --json` returns valid JSON.
- [ ] `woffy self-test` passes (or expected failures documented).
- [ ] `woffy backup` creates `.tar.gz`.
- [ ] `woffy restore <backup>` restores correctly.
- [ ] `woffy changelog` shows local/remote version and commits.
- [ ] `woffy update` updates from main.
- [ ] `woffy update nightly` updates from nightly.

## 11) Uninstall
- [ ] `woffy uninstall` removes binary, config, token, user, log, lock and cron.

## 12) Final control
- [ ] `git diff` reviewed with no secrets.
- [ ] `README.md` matches real commands.
- [ ] `CHECKLIST.md` updated.
