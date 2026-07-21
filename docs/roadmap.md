# Roadmap

## Phase 1: Release v3 Safely
- Validate official OAuth and `/api/v1/signs` against a Woffu test tenant.
- Publish checksummed CLI assets and exercise update on a VPS canary.
- Observe two schedule windows before enabling all workers.

## Phase 2: Release v3.1 Web Companion
- Publish the checksummed Linux x86_64 web archive and install it on the canary through an SSH tunnel.
- Exercise login, schedules, manual sign, logs, backup/restore and joint CLI/web update.
- Observe systemd user-service health before enabling destructive GUI actions on the production VPS.

## Phase 3: Reduce Remaining Risk
- Remove positional passwords in the next major version.
- Evaluate an OS keyring or encrypted secret provider compatible with unattended cron.
- Investigate documented Woffu idempotency/reconciliation capabilities.
- Add per-worker time zones and holiday calendars.
- Add bulk CSV onboarding and schedule import.
- Evaluate ARM64 web artifacts, named administrators/RBAC and Prometheus metrics.

## Non-Goals For Now
- No public Internet exposure or reverse proxy for Woffy Web.
- No multi-administrator access in v3.1.
- No encrypted master passphrase because cron must run unattended.
- No stack migration away from Bash yet.
