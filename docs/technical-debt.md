# Technical Debt

## High Priority

### WFY-013: Broaden multi-user API failure coverage
- `Confirmed`: tests cover happy paths and orchestration guards.
- Why it matters: token expiry, Woffu outages, malformed JSON, and Telegram failures need regression coverage.

## Medium Priority

### WFY-003: Monolithic shell architecture
- `Confirmed`: behavior still lives in one script.
- Why it matters: SQLite expanded the script surface and future changes will benefit from clearer sections.

### WFY-006: Systemd timer model removed from the primary flow
- `Confirmed`: v2 focuses on cron orchestrator only.
- Why it matters: systemd users may need a documented equivalent later.

## Resolved Or Superseded

### WFY-012: Add user activation and schedule editing commands
- `Confirmed`: `woffy users enable|disable|delete` and `woffy schedule user ...` are implemented.
- `Confirmed`: user deletion keeps historical events.

### WFY-001: Bootstrap gating blocks diagnostic and read-only commands
- `Confirmed`: `doctor --json` can report missing SQLite without requiring old config files.

### WFY-002: Config validator is too restrictive for escaped values
- `Confirmed`: worker credentials no longer use sourced shell config files.
