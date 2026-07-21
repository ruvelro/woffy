# Feature: Scheduling

## Cron Orchestrator
- `Confirmed`: `woffy schedule install` writes one cron entry tagged `# woffy-run-due`.
- `Confirmed`: the cron entry runs `woffy run due --quiet` every minute.
- `Confirmed`: `woffy schedule list` prints tagged woffy cron entries.
- `Confirmed`: `woffy schedule clear` removes tagged woffy cron entries.

## User Schedules
- `Confirmed`: schedules are stored per worker in SQLite.
- `Confirmed`: new users receive default weekday schedules:
  - `in` at `09:00` and `15:30`
  - `out` at `14:00` and `18:00`
- `Confirmed`: `woffy schedule user <email> list` shows action, time, weekdays, and active state.
- `Confirmed`: `woffy schedule user <email> set {in|out} HH:MM[,HH:MM...] [weekdays]` replaces all times for one action.
- `Confirmed`: `woffy schedule user <email> add {in|out} HH:MM [weekdays]` adds or reactivates one schedule row.
- `Confirmed`: `woffy schedule user <email> remove {in|out} HH:MM` removes one schedule row.
- `Confirmed`: `woffy schedule user <email> clear` removes all schedules for one worker.
- `Confirmed`: `woffy schedule user <email> defaults` restores default weekday schedules.
- `Confirmed`: weekdays use ISO numbers, `1=Monday` through `7=Sunday`.

## Duplicate Protection
- `Confirmed`: `run_guard` prevents the same worker/action/date/time from running twice.
- `Confirmed`: the scheduler rechecks a five-minute window, leases slots and persists attempts/retry times.
- `Confirmed`: up to four workers run concurrently, but each worker's due actions run serially.
- `Confirmed`: `run due --dry-run` lists due slots without claims or Woffu writes.
