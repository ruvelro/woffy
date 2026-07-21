# File Map

## Root
- `woffy.sh`: main Bash application, SQLite schema, Woffu API access, scheduling, reporting, Telegram, and maintenance commands.
- `install-woffy.sh`: user-mode installer that verifies release assets, optionally handles the deprecated first-worker arguments, and installs the central orchestrator.
- `README.md`: user-facing multi-user usage summary.
- `CHECKLIST.md`: release checklist.
- `LICENSE`: GPL-3.0-only license notice.
- `src/*.sh`: canonical Bash modules used to generate the distribution.
- `scripts/build-woffy.sh`: deterministic build and synchronization check.
- `scripts/build-web-artifact.sh`: builds the checksummed offline Linux web payload.
- `scripts/vendor-web-assets.sh`: downloads the pinned HTMX asset and verifies its SHA-256.
- `web/woffy_web/`: FastAPI application, security/store/CLI adapters, templates and local assets.
- `web/THIRD_PARTY_NOTICES.md`: license notice for vendored browser assets.

## CI
- `.github/workflows/shell-ci.yml`: blocking Bash matrix plus Python, HTTP, Chromium and web install tests.
- `.github/workflows/release.yml`: stable-tag and rolling-nightly release asset publisher.

## Tests
- `tests/woffy.bats`: Bats suite using real SQLite and mocked HTTP/cron, including migration, scheduler, API and updater failures.
- `tests/vps-update-smoke.sh`: v2-to-v3 update and rollback simulation.
- `tests/test_web.py`: HTTP integration and web security coverage.
- `tests/test_web_e2e.py`: real Chromium login/navigation/action smoke test.
- `tests/web-install-smoke.sh`: offline artifact installation, serving and checksum rollback on Linux.

## Docs
- `docs/architecture.md`: current SQLite architecture.
- `docs/data-flow.md`: login, sign, run-due, report, backup, and restore flows.
- `docs/integrations.md`: Woffu, Telegram, SQLite, GitHub, and local tools.
- `docs/tasks/`: backlog, in-progress, and done task queues.
- `docs/decisions/architecture-decisions.md`: accepted SQLite and cron-orchestrator decisions.
