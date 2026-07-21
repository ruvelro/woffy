from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any, Iterable


class WoffyReader:
    def __init__(self, path: Path) -> None:
        self.path = path

    def connect(self) -> sqlite3.Connection:
        if not self.path.exists():
            raise FileNotFoundError(self.path)
        uri = f"file:{self.path}?mode=ro"
        connection = sqlite3.connect(uri, uri=True, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    def rows(self, sql: str, params: Iterable[object] = ()) -> list[dict[str, Any]]:
        try:
            with self.connect() as connection:
                return [dict(row) for row in connection.execute(sql, tuple(params)).fetchall()]
        except (FileNotFoundError, sqlite3.OperationalError):
            return []

    def one(self, sql: str, params: Iterable[object] = ()) -> dict[str, Any]:
        rows = self.rows(sql, params)
        return rows[0] if rows else {}

    def dashboard(self) -> dict[str, Any]:
        return self.one(
            """
            SELECT
              (SELECT COUNT(*) FROM users) AS users,
              (SELECT COUNT(*) FROM users WHERE active=1) AS active_users,
              (SELECT COUNT(*) FROM events WHERE status='error' AND created_at>=datetime('now','-24 hours')) AS recent_errors,
              (SELECT MAX(created_at) FROM events) AS last_event,
              (SELECT COUNT(*) FROM run_guard WHERE state IN ('retryable','failed')) AS pending_failures,
              (SELECT value IS NOT NULL FROM settings WHERE key='TG_TOKEN') AS telegram,
              (SELECT COUNT(*) FROM integration_credentials WHERE provider='woffu') AS api
            """
        )

    def users(self) -> list[dict[str, Any]]:
        return self.rows(
            """
            SELECT u.email,u.active,u.created_at,u.updated_at,c.full_name,c.company_name,c.office_name,c.schedule_name,
              (SELECT MAX(created_at) FROM events e WHERE e.email=u.email) AS last_run,
              (SELECT MAX(created_at) FROM events e WHERE e.email=u.email AND e.status='error') AS last_error
            FROM users u LEFT JOIN user_cards c ON c.email=u.email ORDER BY COALESCE(c.full_name,u.email)
            """
        )

    def schedules(self, email: str = "") -> list[dict[str, Any]]:
        if email:
            return self.rows(
                "SELECT email,action,time_hhmm,weekdays,active FROM schedules WHERE email=? ORDER BY action,time_hhmm",
                (email,),
            )
        return self.rows(
            "SELECT email,action,time_hhmm,weekdays,active FROM schedules ORDER BY email,action,time_hhmm"
        )

    def upcoming(self) -> list[dict[str, Any]]:
        return self.rows(
            """
            SELECT s.email,s.action,s.time_hhmm,s.weekdays FROM schedules s
            JOIN users u ON u.email=s.email WHERE u.active=1 AND s.active=1
            ORDER BY s.time_hhmm,s.email LIMIT 100
            """
        )

    def events(self, email: str, status: str, search: str, limit: int, offset: int) -> list[dict[str, Any]]:
        clauses = ["1=1"]
        params: list[object] = []
        if email:
            clauses.append("email=?")
            params.append(email)
        if status:
            clauses.append("status=?")
            params.append(status)
        if search:
            clauses.append("(message LIKE ? OR kind LIKE ? OR action LIKE ?)")
            wildcard = f"%{search}%"
            params.extend([wildcard, wildcard, wildcard])
        params.extend([min(max(limit, 1), 500), max(offset, 0)])
        return self.rows(
            "SELECT id,email,action,kind,status,message,created_at,request_id FROM events WHERE "
            + " AND ".join(clauses)
            + " ORDER BY id DESC LIMIT ? OFFSET ?",
            params,
        )

    def guards(self) -> list[dict[str, Any]]:
        return self.rows("SELECT * FROM run_guard ORDER BY run_date DESC,time_hhmm DESC,email LIMIT 200")

    def settings(self) -> dict[str, str]:
        rows = self.rows("SELECT key,value FROM settings")
        return {str(row["key"]): str(row["value"]) for row in rows}
