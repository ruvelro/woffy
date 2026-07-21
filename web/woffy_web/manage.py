from __future__ import annotations

import argparse
import getpass

from .config import settings
from .store import WebStore


def main() -> int:
    parser = argparse.ArgumentParser(prog="python -m woffy_web.manage")
    parser.add_argument("command", choices=["init", "passwd"])
    parser.add_argument("--password-stdin", action="store_true")
    args = parser.parse_args()
    settings.prepare()
    store = WebStore(settings.web_db_path, settings.session_idle_seconds, settings.session_max_seconds)
    store.initialize()
    if args.command == "init" and store.has_password():
        print("Woffy Web is already initialized.")
        return 0
    password = input().rstrip("\n") if args.password_stdin else getpass.getpass("Administrator password: ")
    confirm = password if args.password_stdin else getpass.getpass("Repeat password: ")
    if password != confirm:
        raise SystemExit("Passwords do not match")
    store.set_password(password)
    print("Administrator password saved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
