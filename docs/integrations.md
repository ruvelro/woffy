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
- `Confirmed`: the public integration uses OAuth `client_credentials` with CompanyId/API key and Bearer authentication.
- `Pending confirmation`: `/api/v1/signs` payload and permissions must be exercised against current Swagger/a Woffu test account before production enablement.

## Telegram Bot API
- Base URL pattern: `https://api.telegram.org/bot<TG_TOKEN>/sendMessage`
- `Confirmed`: settings are global DB keys: `TG_TOKEN`, `TG_CHAT_ID`, `TG_THREAD`, `TG_NOTIFY`.
- `Confirmed`: messages include worker identity when emitted from user-specific operations.
- `Confirmed`: web configuration passes the bot token through stdin and never exposes it in argv or rendered pages.

## SQLite
- `Confirmed`: `sqlite3` CLI is required at runtime.
- `Confirmed`: DB path defaults to `~/.woffy/woffy.db`.
- `Confirmed`: tests use a real SQLite database.

## GitHub
- Raw content:
  - `https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/<branch>/woffy.sh`
- Main usage:
  - installer script bootstrap
  - checksummed stable and nightly release assets for install/self-update
  - changelog
  - optional checksummed web archive with its offline Python wheelhouse

## Woffy Web
- `Confirmed`: FastAPI, Uvicorn, Jinja, python-multipart and Argon2 dependencies are pinned in the release artifact.
- `Confirmed`: HTMX 2.0.4 is vendored at build time after verifying a pinned SHA-256; no runtime CDN is used.
- `Confirmed`: the panel binds only to `127.0.0.1` and relies on SSH port forwarding rather than public HTTPS.
- `Confirmed`: `systemd --user` operates the persistent service; foreground `woffy web serve` is the fallback.

## Local System
- CLI tools remain unchanged. Installing the optional web companion additionally requires Linux x86_64 and Python 3.11+.
