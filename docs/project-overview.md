# Project Overview

## Executive Summary
- `Confirmed`: `woffy` is now a centrally managed multi-user Bash CLI for Woffu attendance automation on a VPS.
- `Confirmed`: the CLI remains a single executable script, with an optional Python web companion.
- `Confirmed`: the current development version is `3.1.2`.
- `Confirmed`: SQLite is the source of truth for users, credentials, tokens, schedules, user cards, run guards, and events.

## Current System Shape
- Entrypoint: `woffy.sh`
- Installer: `install-woffy.sh`
- Tests: `tests/woffy.bats`
- CI: `.github/workflows/shell-ci.yml`
- Runtime DB: `~/.woffy/woffy.db`
- Optional UI: FastAPI/Jinja/HTMX under `web/woffy_web`

## Main Capabilities
- `Confirmed`: register or update workers with `woffy login <email> <password>`.
- `Confirmed`: enable, disable, and delete worker records with explicit `woffy users` subcommands.
- `Confirmed`: operate attendance per worker with `woffy in|out|status <email>`.
- `Confirmed`: list workers and inspect a worker card.
- `Confirmed`: run a central scheduler with `woffy run due`.
- `Confirmed`: install one cron orchestrator with `woffy schedule install`.
- `Confirmed`: edit per-worker schedules with `woffy schedule user <email> ...`.
- `Confirmed`: inspect per-worker or global event history with `woffy events`.
- `Confirmed`: report across all users from SQLite events.
- `Confirmed`: send Telegram admin notifications from global DB settings.
- `Confirmed`: backup, restore, self-test, doctor, update, changelog, and uninstall remain available.
- `Confirmed`: v3 adds schema migrations, catch-up scheduling, bounded cross-worker parallelism, per-worker serialization and persisted retry state.
- `Confirmed`: official backdated signs use OAuth client credentials; undocumented token fallback is intentionally excluded.
- `Confirmed`: installation and self-update consume checksummed GitHub Release assets and retain a rollback binary.
- `Confirmed`: Woffy Web provides local-only, password-protected administration with CLI parity, independent audit state and SSH-tunnel access.
- `Confirmed`: runtime tunables can be persisted through `woffy config` while environment variables retain precedence.

## Product Direction
- `Confirmed`: the old single-user file model is no longer the primary interface.
- `Confirmed`: commands identify workers by email instead of relying on the Unix user's home-scoped `.woffy.conf`.
- `Inference`: the product is optimized for one trusted administrator managing a VPS, not for untrusted local multi-tenant users.
- `Confirmed`: the optional panel is also single-administrator and is not a public web service.
