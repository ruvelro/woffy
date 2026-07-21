from __future__ import annotations

import os
import re
import subprocess
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Sequence

EMAIL = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
TIME = re.compile(r"^(?:[01]\d|2[0-3]):[0-5]\d$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
WEEKDAYS = re.compile(r"^[1-7](?:,[1-7])*$")
SETTING = re.compile(r"^[a-z][a-z0-9_]{1,40}$")


@dataclass(frozen=True)
class Result:
    ok: bool
    returncode: int
    output: str
    request_id: str


class CommandError(ValueError):
    pass


class WoffyCLI:
    def __init__(self, binary: str, home: Path) -> None:
        self.binary = binary
        self.home = home

    @staticmethod
    def email(value: str) -> str:
        if not EMAIL.fullmatch(value):
            raise CommandError("Invalid email")
        return value

    @staticmethod
    def action(value: str) -> str:
        if value not in {"in", "out"}:
            raise CommandError("Invalid action")
        return value

    @staticmethod
    def time(value: str) -> str:
        if not TIME.fullmatch(value):
            raise CommandError("Invalid time")
        return value

    @staticmethod
    def date(value: str) -> str:
        if not DATE.fullmatch(value):
            raise CommandError("Invalid date")
        return value

    @staticmethod
    def weekdays(value: str) -> str:
        if not WEEKDAYS.fullmatch(value):
            raise CommandError("Invalid weekdays")
        return value

    def run(
        self,
        args: Sequence[str],
        stdin: Optional[str] = None,
        timeout: int = 120,
        request_id: Optional[str] = None,
    ) -> Result:
        if not args or any("\x00" in value or "\n" in value for value in args):
            raise CommandError("Invalid command arguments")
        rid = request_id or str(uuid.uuid4())
        env = {
            "HOME": str(Path.home()),
            "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
            "LANG": os.environ.get("LANG", "C.UTF-8"),
            "WOFFY_HOME": str(self.home),
            "WOFFY_REQUEST_ID": rid,
        }
        for name in ("WOFFY_DB_FILE", "WOFFY_LOG_FILE", "WOFFY_RELEASE_BASE", "WOFFY_UPDATE_BASE_URL"):
            if name in os.environ:
                env[name] = os.environ[name]
        if os.environ.get("WOFFY_WEB_TESTING") == "true" and "WOFFY_TEST_CALLS" in os.environ:
            env["WOFFY_TEST_CALLS"] = os.environ["WOFFY_TEST_CALLS"]
        try:
            completed = subprocess.run(
                [self.binary, *args],
                input=stdin,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                shell=False,
                timeout=timeout,
                env=env,
                check=False,
            )
            output = completed.stdout[-12000:].strip()
            return Result(completed.returncode == 0, completed.returncode, output, rid)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return Result(False, 124, f"Command failed: {type(exc).__name__}", rid)

    def version(self) -> Result:
        return self.run(["version"], timeout=10)
