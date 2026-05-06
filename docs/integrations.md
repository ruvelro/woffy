# Integrations

## Woffu
- Base URL: `https://app.woffu.com`
- `Confirmed` endpoints:
  - `POST /token`
  - `GET /api/signs`
  - `POST /api/signs`
  - `GET /api/users`
  - `GET /api/users/<id>/workdaylite`
- `Confirmed`: tokens are stored per worker email in SQLite.

## Telegram Bot API
- Base URL pattern: `https://api.telegram.org/bot<TG_TOKEN>/sendMessage`
- `Confirmed`: settings are global DB keys: `TG_TOKEN`, `TG_CHAT_ID`, `TG_THREAD`, `TG_NOTIFY`.
- `Confirmed`: messages include worker identity when emitted from user-specific operations.

## SQLite
- `Confirmed`: `sqlite3` CLI is required at runtime.
- `Confirmed`: DB path defaults to `~/.woffy/woffy.db`.
- `Confirmed`: tests use a real SQLite database.

## GitHub
- Raw content:
  - `https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/<branch>/woffy.sh`
- Main usage:
  - installer bootstrap
  - self-update
  - changelog

## Local System
- Required tools include `bash`, `curl`, `jq`, `awk`, `date`, `sqlite3`, `tar`, `crontab`, and `readlink`.
