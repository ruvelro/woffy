# Feature: Users And Notifications

## Users
- `Confirmed`: `woffy login <email> <password>` upserts a worker, stores credentials in SQLite, refreshes token, fetches Woffu user card, and seeds default schedules.
- `Confirmed`: `woffy users` lists email, cached name, and active/inactive state.
- `Confirmed`: `woffy user <email>` shows cached worker metadata.
- `Confirmed`: `woffy users disable <email>` marks a worker inactive, so sign and `run due` skip it.
- `Confirmed`: `woffy users enable <email>` reactivates a worker.
- `Confirmed`: `woffy users delete <email>` removes credentials, token, user card, schedules, and run guards while preserving historical events.

## Notifications
- `Confirmed`: Telegram settings are global SQLite settings.
- `Confirmed`: `woffy telegram <bot_token> <chat_id> [thread_id] [all|errors|success]` stores settings.
- `Confirmed`: `woffy telegram test` sends a test message if configured.
- `Confirmed`: user-specific messages include email and cached full name when available.
- `Confirmed`: Telegram tests and requested report delivery fail visibly when configuration/delivery fails.
- `Confirmed`: positional login passwords are deprecated; prompt and stdin forms avoid shell history/process arguments.
- `Confirmed`: company API credentials are configured separately with `woffy api` and secret stdin/prompt.
