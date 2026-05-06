# Feature: Attendance Signing

## Behavior
- `Confirmed`: attendance commands require a worker email.
- `Confirmed`: `woffy in <email>` and `woffy out <email>` refresh or reuse that worker's token.
- `Confirmed`: status is read from Woffu `/api/signs`.
- `Confirmed`: duplicate entries or exits are skipped.
- `Confirmed`: clock-in checks `/workdaylite` and skips non-working days.

## Events
- `Confirmed`: successes, warnings, errors, dry-runs, and login outcomes are stored in SQLite `events`.
