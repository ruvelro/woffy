# Roadmap

## Phase 1: Release v3 Safely
- Validate official OAuth and `/api/v1/signs` against a Woffu test tenant.
- Publish checksummed `v3.0.0` assets and exercise update on a VPS canary.
- Observe two schedule windows before enabling all workers.

## Phase 2: Improve Operator Control
- Finish last-run/last-error summaries in `woffy users`.
- Add Telegram report templates and alert recovery summaries.
- Add a staging stress test for many workers and crash recovery.

## Phase 3: Reduce Remaining Risk
- Remove positional passwords in the next major version.
- Evaluate an OS keyring or encrypted secret provider compatible with unattended cron.
- Investigate documented Woffu idempotency/reconciliation capabilities.

## Non-Goals For Now
- No web panel in v3.
- No encrypted master passphrase because cron must run unattended.
- No stack migration away from Bash yet.
