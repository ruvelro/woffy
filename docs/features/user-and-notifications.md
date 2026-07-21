# Feature: Users And Notifications

## Users
- `Confirmed`: `woffy login <email> <password>` upserts a worker, stores credentials in SQLite, refreshes token, fetches Woffu user card, and seeds default schedules.
- `Confirmed`: `woffy users` lists email, cached name, and active/inactive state.
- `Confirmed`: `woffy user <email>` shows cached worker metadata.
- `Confirmed`: `woffy users disable <email>` marks a worker inactive, so sign and `run due` skip it.
- `Confirmed`: `woffy users enable <email>` reactivates a worker.
- `Confirmed`: `woffy users delete <email>` removes credentials, token, user card, schedules, and run guards while preserving historical events.

## Notifications
- `Confirmed`: Telegram settings (`TG_TOKEN`, `TG_CHAT_ID`, `TG_THREAD`, `TG_NOTIFY`) are global SQLite settings.
- `Confirmed`: `woffy telegram configure --token-stdin <chat-id> [thread-id] [all|errors|success]` keeps the bot token out of process arguments and stores all four settings atomically.
- `Confirmed`: `woffy telegram set-mode {all|errors|success}` updates only `TG_NOTIFY`, without touching the stored token or chat id. The web panel exposes the same operation as a standalone control on the Integrations page.
- `Confirmed`: `woffy telegram test` sends a test message if configured.
- `Confirmed`: `woffy telegram clear` removes all four Telegram settings.
- `Confirmed`: user-specific messages include email and cached full name when available.
- `Confirmed`: Telegram tests and requested report delivery fail visibly when configuration/delivery fails.
- `Confirmed`: positional login passwords are deprecated; prompt and stdin forms avoid shell history/process arguments.
- `Confirmed`: company API credentials are configured separately with `woffy api` and secret stdin/prompt.
- `Confirmed`: the legacy positional `woffy telegram <bot_token> <chat_id> [thread_id] [mode]` syntax still works for v2 compatibility but prints a deprecation warning; new setups should use `configure --token-stdin`.
