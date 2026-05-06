# Data Flow

## Login Flow
1. Admin runs `woffy login <email> <password>`.
2. The worker is inserted or updated in `users`.
3. Default schedules are inserted if missing.
4. Existing token for that worker is removed.
5. Woffu OAuth token is fetched and stored in `tokens`.
6. `/api/users` is fetched and saved in `user_cards`.
7. A login event is stored in `events`.

## Sign Flow
1. Admin or scheduler runs `woffy in <email>`, `woffy out <email>`, or dry-run.
2. The global lock is acquired.
3. A valid worker token is loaded or refreshed.
4. `/api/signs` determines the current state.
5. Duplicate or unsafe actions are skipped.
6. For `in`, `/workdaylite` may block non-working days.
7. The sign is posted and an event is written to SQLite.

## Run Due Flow
1. Cron calls `woffy run due --quiet` once per minute.
2. The command selects active schedules matching current weekday and `HH:MM`.
3. `run_guard` is inserted before execution.
4. If the guard already exists, that user/action/minute is skipped.
5. Due sign flows run per selected worker.

## User Administration Flow
1. `woffy users disable <email>` sets `users.active=0` and records a warning event.
2. `woffy users enable <email>` sets `users.active=1` and records a success event.
3. `woffy users delete <email>` removes credentials, token, user card, schedules, and run guards.
4. Historical events are kept so deletion does not erase operational evidence.

## Schedule Editing Flow
1. `woffy schedule user <email> set <action> <times> [weekdays]` replaces all schedules for one action.
2. `add` and `remove` mutate one action/time row.
3. `clear` removes all schedules for one worker.
4. `defaults` restores the default weekday schedule.

## Event Investigation Flow
1. `woffy events all` or `woffy events <email>` queries SQLite events.
2. `--days N` limits the window, commonly `30` or `60`.
3. `--status` filters success, warning, error, or dry-run records.
4. `--format` renders text, JSON, or CSV.

## Report Flow
1. `woffy report all` resolves a date range.
2. It aggregates `events` inside the range.
3. It renders text, JSON, or CSV.
4. Optional Telegram delivery sends the global admin report.

## Backup And Restore Flow
1. `backup` archives the whole `~/.woffy` directory.
2. `restore` extracts it back and reapplies expected permissions.
