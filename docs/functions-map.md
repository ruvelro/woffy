# Functions Map

## Core Utilities
- `check_deps`: validates required CLI dependencies.
- `ensure_home`: creates `~/.woffy` with protected permissions.
- `log` and `rotate_log_if_needed`: maintain diagnostic logging.
- `sql_quote`: escapes values for SQLite statements.

## SQLite State
- `db_init`: creates all SQLite tables idempotently.
- `ensure_run_guard_column`: performs additive migration of legacy v2 guard tables.
- `db_exec`: executes SQLite statements.
- `settings_get` and `settings_set`: manage global settings such as Telegram.
- `record_event`: stores operational events and writes the diagnostic log.
- `seed_default_schedule`: adds default weekday schedules for new workers.
- `print_users`, `set_user_active`, `delete_user`: user administration helpers.
- `print_user_schedule`, `add_user_schedule`, `remove_user_schedule`, `set_user_schedule`, `clear_user_schedule`, `reset_default_schedule`: per-worker schedule administration.

## Woffu
- `get_token`: resolves or refreshes a worker-specific OAuth token.
- `api_get_raw`: performs authenticated GET calls.
- `get_status`: derives `in`, `out`, or `unknown` from `/api/signs`.
- `post_sign`: posts `clock_in` or `clock_out`.
- `save_user_card_db`: stores Woffu user metadata.
- `get_workday`, `workday_reason`, `is_workday_ok_for_in`: enforce workday checks for entries.

## Multi-User Operations
- `run_sign_flow`: shared implementation for `in`, `out`, and `dry-run` by email.
- `run_due`: central scheduler that selects due user schedules and guards duplicate execution.
- `claim_schedule_slot` and `process_scheduled_user`: lease/retry state and serial per-worker execution.
- `integration_get_token` and `backfill_sign_official`: OAuth client credentials and official retroactive signs.
- `build_report_all`: aggregates SQLite events for reports.
- `print_events`: renders recent event history by user/status/days in text, JSON, or CSV.

## Local Ops
- `install_run_due_cron`: installs the one-minute cron orchestrator.
- `clear_woffy_cron`: removes tagged woffy cron entries.
- `backup_files` and `restore_files`: archive and restore `~/.woffy`.
- `perform_update`, `semver_number`, and `sha256_file`: verified release update and rollback.
- `doctor_json`: emits machine-readable health details.
- `show_help`, `show_changelog`, `get_script_path`, `get_bin_path`: user and maintenance helpers.

## Command Dispatch
- Primary commands: `login`, `users`, `user`, `status`, `in`, `out`, `dry-run`, `run due`, `events`, `report all`, `schedule`, `telegram`, `doctor`, `self-test`, `config check`, `backup`, `restore`, `changelog`, `update`, `uninstall`.
