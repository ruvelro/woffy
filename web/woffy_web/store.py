from __future__ import annotations

import hashlib
import secrets
import sqlite3
import time
from pathlib import Path
from typing import Any, Optional

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError


class WebStore:
    def __init__(self, path: Path, idle_seconds: int, max_seconds: int) -> None:
        self.path = path
        self.idle_seconds = idle_seconds
        self.max_seconds = max_seconds
        self.password_hasher = PasswordHasher()

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA foreign_keys=ON")
        return connection

    def initialize(self) -> None:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS admin(
                  id INTEGER PRIMARY KEY CHECK(id=1),
                  password_hash TEXT NOT NULL,
                  password_changed_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sessions(
                  token_hash TEXT PRIMARY KEY,
                  csrf_token TEXT NOT NULL,
                  created_at INTEGER NOT NULL,
                  last_seen_at INTEGER NOT NULL,
                  reauthenticated_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS login_attempts(
                  attempted_at INTEGER NOT NULL,
                  success INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS audit(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  request_id TEXT NOT NULL,
                  action TEXT NOT NULL,
                  target TEXT NOT NULL,
                  status TEXT NOT NULL,
                  detail TEXT NOT NULL,
                  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS jobs(
                  id TEXT PRIMARY KEY,
                  action TEXT NOT NULL,
                  status TEXT NOT NULL,
                  output TEXT NOT NULL DEFAULT '',
                  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  finished_at TEXT
                );
                CREATE TABLE IF NOT EXISTS state(
                  key TEXT PRIMARY KEY,
                  value TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_audit_created ON audit(created_at);
                CREATE INDEX IF NOT EXISTS idx_login_attempts_time ON login_attempts(attempted_at);
                """
            )
        self.path.chmod(0o600)

    def has_password(self) -> bool:
        with self.connect() as connection:
            return connection.execute("SELECT 1 FROM admin WHERE id=1").fetchone() is not None

    def set_password(self, password: str) -> None:
        if len(password) < 12:
            raise ValueError("The administrator password must contain at least 12 characters")
        hashed = self.password_hasher.hash(password)
        now = int(time.time())
        with self.connect() as connection:
            connection.execute(
                "INSERT INTO admin(id,password_hash,password_changed_at) VALUES(1,?,?) "
                "ON CONFLICT(id) DO UPDATE SET password_hash=excluded.password_hash,password_changed_at=excluded.password_changed_at",
                (hashed, now),
            )
            connection.execute("DELETE FROM sessions")

    def verify_password(self, password: str) -> bool:
        with self.connect() as connection:
            row = connection.execute("SELECT password_hash FROM admin WHERE id=1").fetchone()
        if row is None:
            return False
        try:
            valid = self.password_hasher.verify(row["password_hash"], password)
        except VerifyMismatchError:
            return False
        if valid and self.password_hasher.check_needs_rehash(row["password_hash"]):
            with self.connect() as connection:
                connection.execute(
                    "UPDATE admin SET password_hash=?,password_changed_at=? WHERE id=1",
                    (self.password_hasher.hash(password), int(time.time())),
                )
        return valid

    def login_blocked(self) -> bool:
        cutoff = int(time.time()) - 900
        with self.connect() as connection:
            failures = connection.execute(
                "SELECT COUNT(*) FROM login_attempts WHERE attempted_at>=? AND success=0", (cutoff,)
            ).fetchone()[0]
        return failures >= 5

    def record_login(self, success: bool) -> None:
        now = int(time.time())
        with self.connect() as connection:
            connection.execute("DELETE FROM login_attempts WHERE attempted_at<?", (now - 86400,))
            connection.execute(
                "INSERT INTO login_attempts(attempted_at,success) VALUES(?,?)", (now, int(success))
            )

    @staticmethod
    def _digest(token: str) -> str:
        return hashlib.sha256(token.encode("utf-8")).hexdigest()

    def create_session(self) -> tuple[str, str]:
        token = secrets.token_urlsafe(48)
        csrf = secrets.token_urlsafe(32)
        now = int(time.time())
        with self.connect() as connection:
            connection.execute(
                "INSERT INTO sessions(token_hash,csrf_token,created_at,last_seen_at,reauthenticated_at) VALUES(?,?,?,?,?)",
                (self._digest(token), csrf, now, now, now),
            )
        return token, csrf

    def get_session(self, token: str) -> Optional[dict[str, Any]]:
        if not token:
            return None
        now = int(time.time())
        digest = self._digest(token)
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM sessions WHERE token_hash=?", (digest,)).fetchone()
            if row is None:
                return None
            if now - row["last_seen_at"] > self.idle_seconds or now - row["created_at"] > self.max_seconds:
                connection.execute("DELETE FROM sessions WHERE token_hash=?", (digest,))
                return None
            connection.execute("UPDATE sessions SET last_seen_at=? WHERE token_hash=?", (now, digest))
        return dict(row)

    def reauthenticate(self, token: str, password: str) -> bool:
        if not self.verify_password(password):
            return False
        with self.connect() as connection:
            connection.execute(
                "UPDATE sessions SET reauthenticated_at=? WHERE token_hash=?",
                (int(time.time()), self._digest(token)),
            )
        return True

    def destroy_session(self, token: str) -> None:
        if token:
            with self.connect() as connection:
                connection.execute("DELETE FROM sessions WHERE token_hash=?", (self._digest(token),))

    def audit(self, request_id: str, action: str, target: str, status: str, detail: str) -> None:
        safe_detail = detail.replace("\x00", "")[:4000]
        with self.connect() as connection:
            connection.execute(
                "INSERT INTO audit(request_id,action,target,status,detail) VALUES(?,?,?,?,?)",
                (request_id, action, target[:250], status, safe_detail),
            )

    def recent_audit(self, limit: int = 100) -> list[dict[str, Any]]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM audit ORDER BY id DESC LIMIT ?", (min(max(limit, 1), 500),)
            ).fetchall()
        return [dict(row) for row in rows]

    def set_state(self, key: str, value: str) -> None:
        with self.connect() as connection:
            connection.execute(
                "INSERT INTO state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, value),
            )

    def get_state(self, key: str, default: str = "") -> str:
        with self.connect() as connection:
            row = connection.execute("SELECT value FROM state WHERE key=?", (key,)).fetchone()
        return str(row["value"]) if row else default

    def create_job(self, job_id: str, action: str) -> None:
        with self.connect() as connection:
            connection.execute("INSERT INTO jobs(id,action,status) VALUES(?,?,'queued')", (job_id, action))

    def finish_job(self, job_id: str, ok: bool, output: str) -> None:
        with self.connect() as connection:
            connection.execute(
                "UPDATE jobs SET status=?,output=?,finished_at=CURRENT_TIMESTAMP WHERE id=?",
                ("success" if ok else "error", output[-12000:], job_id),
            )

    def start_job(self, job_id: str) -> None:
        with self.connect() as connection:
            connection.execute("UPDATE jobs SET status='running' WHERE id=?", (job_id,))

    def jobs(self, limit: int = 30) -> list[dict[str, Any]]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (min(max(limit, 1), 100),)
            ).fetchall()
        return [dict(row) for row in rows]
