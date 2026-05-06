# AGENTS.md

## Purpose
This repository is an existing product. The primary source of truth is the code in `woffy.sh`, `install-woffy.sh`, the test suite, and CI config.

This file defines how agents should work in this repo so documentation, backlog, and code stay aligned.

## Working Mode
- Audit first, change later.
- Do not redesign the project from scratch unless the codebase state clearly justifies it.
- Treat existing docs as historical context until they are confirmed against code.
- Record every relevant finding either in `/docs` or in the task system under `/docs/tasks`.

## Evidence Labels
Use these labels in repo documentation when the confidence level matters:
- `Confirmed`: verified in code, config, tests, or executable behavior.
- `Inference`: strong conclusion derived from code structure or naming, but not fully exercised.
- `Pending confirmation`: plausible but not verified yet.

## Mandatory Documentation Map
Keep these files updated when behavior, setup, or architecture changes:
- `/docs/project-overview.md`
- `/docs/architecture.md`
- `/docs/file-map.md`
- `/docs/functions-map.md`
- `/docs/data-flow.md`
- `/docs/integrations.md`
- `/docs/domain-glossary.md`
- `/docs/setup-and-ops.md`
- `/docs/testing.md`
- `/docs/technical-debt.md`
- `/docs/roadmap.md`
- `/docs/features/`
- `/docs/tasks/backlog.md`
- `/docs/tasks/in-progress.md`
- `/docs/tasks/done.md`
- `/docs/decisions/architecture-decisions.md`
- `/docs/history/change-log.md`

## Task System
- New bugs, risks, missing tests, refactors, documentation gaps, and operational issues go to `/docs/tasks/backlog.md`.
- Active work goes to `/docs/tasks/in-progress.md`.
- Completed work goes to `/docs/tasks/done.md`.
- Use stable IDs with the `WFY-` prefix.
- If a change resolves a documented debt item, update both the task file and `/docs/technical-debt.md`.

## Repo-Specific Guidance
- The current product is a Bash CLI distributed as a single executable script plus installer.
- Runtime state is stored in the user's home directory, so any change to config keys, file formats, or scheduling behavior must be documented.
- Woffu, Telegram, GitHub raw downloads, cron, and optional `systemd --user` are real integrations and must stay documented.
- Keep README aligned enough for end users, but keep `/docs` as the operational source for multi-agent work.

## Minimum Audit Checklist Before Meaningful Changes
1. Review `woffy.sh`, `install-woffy.sh`, `tests/woffy.bats`, and `.github/workflows/shell-ci.yml`.
2. Reconfirm affected commands and dependencies.
3. Update the relevant `/docs/*.md` files.
4. Create or move task items across backlog, in-progress, and done.

## Change Discipline
- Prefer incremental changes over broad rewrites.
- Do not remove historical context unless it is clearly wrong and replaced by a better record.
- When behavior is unclear, document it as `Pending confirmation` instead of guessing.
