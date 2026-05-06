# Roadmap

## Phase 1: Stabilize Multi-User SQLite
- Harden DB migrations and backward-compatibility messages.
- Add admin commands for enabling/disabling users.
- Add schedule editing commands for per-user overrides.
- Expand tests around Woffu API failure modes.

## Phase 2: Improve Operator Control
- Add CSV exports by user and date range.
- Add last-run and last-error summaries to `woffy users`.
- Add Telegram report templates for daily operations.

## Phase 3: Reduce Structural Risk
- Split large shell sections carefully while preserving single-file distribution.
- Consider generating the distributable script from sourced modules.

## Non-Goals For Now
- No web panel in v1.
- No encrypted master passphrase because cron must run unattended.
- No stack migration away from Bash yet.
