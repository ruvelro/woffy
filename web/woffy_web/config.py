from __future__ import annotations

import json
import os
import stat
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    home: Path
    db_path: Path
    log_path: Path
    web_home: Path
    web_db_path: Path
    config_path: Path
    recovery_dir: Path
    cli_path: str
    host: str
    port: int
    session_idle_seconds: int
    session_max_seconds: int
    max_upload_bytes: int

    @classmethod
    def load(cls) -> "Settings":
        home = Path(os.environ.get("WOFFY_HOME", Path.home() / ".woffy")).expanduser().resolve()
        web_home = Path(os.environ.get("WOFFY_WEB_HOME", home / "web")).expanduser().resolve()
        config_path = web_home / "config.json"
        configured: dict[str, object] = {}
        if config_path.exists():
            configured = json.loads(config_path.read_text(encoding="utf-8"))
        host = str(configured.get("host", os.environ.get("WOFFY_WEB_HOST", "127.0.0.1")))
        if host not in {"127.0.0.1", "::1", "localhost"}:
            raise RuntimeError("Woffy Web only supports loopback bind addresses")
        port = int(configured.get("port", os.environ.get("WOFFY_WEB_PORT", "8787")))
        if port < 1024 or port > 65535:
            raise RuntimeError("WOFFY_WEB_PORT must be between 1024 and 65535")
        session_idle_seconds = int(configured.get("session_idle_seconds", 1800))
        session_max_seconds = int(configured.get("session_max_seconds", 28800))
        max_upload_bytes = int(configured.get("max_upload_bytes", 50 * 1024 * 1024))
        if not 60 <= session_idle_seconds <= 86400:
            raise RuntimeError("session_idle_seconds must be between 60 and 86400")
        if not 300 <= session_max_seconds <= 604800 or session_max_seconds < session_idle_seconds:
            raise RuntimeError("session_max_seconds is invalid")
        if not 1024 * 1024 <= max_upload_bytes <= 1024 * 1024 * 1024:
            raise RuntimeError("max_upload_bytes must be between 1 MiB and 1 GiB")
        return cls(
            home=home,
            db_path=Path(os.environ.get("WOFFY_DB_FILE", home / "woffy.db")).expanduser().resolve(),
            log_path=Path(os.environ.get("WOFFY_LOG_FILE", home / "woffy.log")).expanduser().resolve(),
            web_home=web_home,
            web_db_path=web_home / "web.db",
            config_path=config_path,
            recovery_dir=Path.home() / ".local" / "state" / "woffy-backups",
            cli_path=os.environ.get("WOFFY_BIN", "woffy"),
            host=host,
            port=port,
            session_idle_seconds=session_idle_seconds,
            session_max_seconds=session_max_seconds,
            max_upload_bytes=max_upload_bytes,
        )

    def prepare(self) -> None:
        self.web_home.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.web_home, stat.S_IRWXU)
        self.recovery_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.recovery_dir, stat.S_IRWXU)
        if not self.config_path.exists():
            self.config_path.write_text(
                json.dumps({"host": self.host, "port": self.port}, indent=2) + "\n",
                encoding="utf-8",
            )
        os.chmod(self.config_path, stat.S_IRUSR | stat.S_IWUSR)


settings = Settings.load()
