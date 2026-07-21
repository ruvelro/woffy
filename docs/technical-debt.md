# Technical Debt

## High Priority

### WFY-023: Validate official Woffu integration contract
- `Pending confirmation`: OAuth client credentials follow the official guide, but retroactive sign payload/permissions require a live test account.
- Why it matters: a mocked `2xx` cannot prove the production tenant accepts and persists the sign.

## Medium Priority

### WFY-003: Monolithic shell architecture
- `Confirmed`: canonical sources are modular, while the generated distribution intentionally remains one script.
- Why it matters: module boundaries still share global Bash state and require the build synchronization check.

### WFY-024: Plaintext unattended credentials
- `Confirmed`: credentials remain plaintext in a filesystem-protected SQLite database because cron must authenticate unattended.
- Why it matters: host compromise exposes all managed Woffu accounts.

### WFY-025: External exactly-once boundary
- `Inference`: status reconciliation strongly reduces duplicates, but a process can still crash after Woffu accepts a POST and before the local guard is committed.
- Why it matters: the external API does not expose a documented idempotency key in this repository.

### WFY-031: Broaden web artifact platforms
- `Confirmed`: the first offline wheelhouse supports Linux x86_64 only.
- Why it matters: ARM VPS and macOS development hosts can use the CLI but cannot install the packaged panel.

### WFY-032: Multi-admin authorization
- `Confirmed`: Woffy Web intentionally has one administrator and no RBAC.
- Why it matters: shared operations would require named identities and permissions instead of one audit actor.

## Resolved Or Superseded

### WFY-006: Document a systemd scheduler alternative
- `Confirmed`: cron remains primary and a mutually exclusive `systemd --user` timer is documented; the optional panel has its own hardened user service.

### WFY-012: Add user activation and schedule editing commands
- `Confirmed`: `woffy users enable|disable|delete` and `woffy schedule user ...` are implemented.
- `Confirmed`: user deletion keeps historical events.

### WFY-013: Broaden multi-user API failure coverage
- `Confirmed`: v3 tests cover authentication, workday outages, retries, catch-up, migration and update rollback paths.

### WFY-016: Reduce shell monolith coupling
- `Confirmed`: `src/` modules generate the single-file distribution and CI detects drift.

### WFY-026–030: Deliver optional web administration
- `Confirmed`: configuration, secure subprocess boundary, local authentication, complete operator pages, maintenance rollback and release packaging are implemented.

### WFY-001: Bootstrap gating blocks diagnostic and read-only commands
- `Confirmed`: `doctor --json` can report missing SQLite without requiring old config files.

### WFY-002: Config validator is too restrictive for escaped values
- `Confirmed`: worker credentials no longer use sourced shell config files.
