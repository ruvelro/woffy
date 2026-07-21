# Architecture

## Functional Architecture
- `Confirmed`: `woffy.sh` parses global flags before command dispatch.
- `Confirmed`: command dispatch is implemented in a large Bash `case` block.
- `Confirmed`: `db_init` creates and migrates the local SQLite schema idempotently and records schema version `3` with `PRAGMA user_version`.
- `Confirmed`: Woffu credentials and tokens are scoped by worker email.
- `Confirmed`: `run due` queries a five-minute catch-up window and uses leased, stateful `run_guard` rows for deduplication and bounded retries.
- `Confirmed`: administrative user and schedule changes are first-class CLI operations, not manual SQL requirements.
- `Confirmed`: event history is queryable by worker, status, age window, output format, and limit.

## Local State Layer
- `Confirmed`: runtime state is stored under `~/.woffy/`.
- `Confirmed`: `~/.woffy/woffy.db` stores settings, users, tokens, user cards, schedules, events, and run guards.
- `Confirmed`: `~/.woffy/woffy.log` remains a diagnostic log, but reports use SQLite events.
- `Confirmed`: locking uses `~/.woffy/woffy.lock.d`.
- `Confirmed`: SQLite uses WAL, foreign keys per connection and a configurable busy timeout.

## Woffu Access Layer
- `Confirmed`: OAuth password grant is used per worker against `https://app.woffu.com/token`.
- `Confirmed`: authenticated API requests use a worker-specific bearer token.
- `Confirmed`: implemented Woffu endpoints include `/api/signs`, `/api/users`, and `/api/users/<id>/workdaylite`.

## Scheduling Layer
- `Confirmed`: cron is reduced to one orchestrator entry tagged `# woffy-run-due`.
- `Confirmed`: schedules are per worker in SQLite.
- `Confirmed`: new users receive default weekday schedules for two entries and two exits.
- `Confirmed`: operators can replace, add, remove, clear, or restore schedules per worker.
- `Confirmed`: workers run in parallel up to a validated limit; each worker's slots remain chronological and serial.

## Source And Distribution
- `Confirmed`: development modules live in `src/` and generate the single-file `woffy.sh` distribution.
- `Confirmed`: CI rejects a generated artifact that differs from its modules.

## Notification Layer
- `Confirmed`: Telegram settings are global records in SQLite.
- `Confirmed`: multi-user messages include worker email and, when available, full name.

## Architectural Constraints
- `Confirmed`: distribution remains simple because the app is still a single Bash file.
- `Confirmed`: SQLite is now a required runtime dependency.
- `Inference`: future UI or web control should use SQLite as the integration point instead of reintroducing per-user files.
