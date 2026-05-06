# Project Overview

## Executive Summary
- `Confirmed`: `woffy` is now a centrally managed multi-user Bash CLI for Woffu attendance automation on a VPS.
- `Confirmed`: the runtime product remains a single executable script, `woffy.sh`, plus `install-woffy.sh`.
- `Confirmed`: the current version in code is `2.0.0`.
- `Confirmed`: SQLite is the source of truth for users, credentials, tokens, schedules, user cards, run guards, and events.

## Current System Shape
- Entrypoint: `woffy.sh`
- Installer: `install-woffy.sh`
- Tests: `tests/woffy.bats`
- CI: `.github/workflows/shell-ci.yml`
- Runtime DB: `~/.woffy/woffy.db`

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

## Product Direction
- `Confirmed`: the old single-user file model is no longer the primary interface.
- `Confirmed`: commands identify workers by email instead of relying on the Unix user's home-scoped `.woffy.conf`.
- `Inference`: the product is optimized for one trusted administrator managing a VPS, not for untrusted local multi-tenant users.
