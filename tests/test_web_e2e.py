from __future__ import annotations

import os
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import urlopen

from playwright.sync_api import sync_playwright
from test_web import create_woffy_db


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def test_browser_login_navigation_and_safe_user_action(tmp_path: Path):
    home = tmp_path / "home"
    woffy_home = home / ".woffy"
    woffy_home.mkdir(parents=True)
    create_woffy_db(woffy_home / "woffy.db")
    calls = tmp_path / "calls"
    fake = tmp_path / "woffy"
    fake.write_text(
        """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['WOFFY_TEST_CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1:]==['version']: print('woffy v3.1.2')
elif sys.argv[1:3]==['doctor','--json']: print('{"version":"3.1.2","schema_version":4,"cron_run_due":true}')
else: print('OK')
""",
        encoding="utf-8",
    )
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    port = free_port()
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "WOFFY_HOME": str(woffy_home),
            "WOFFY_WEB_HOME": str(woffy_home / "web"),
            "WOFFY_WEB_PORT": str(port),
            "WOFFY_BIN": str(fake),
            "WOFFY_WEB_TESTING": "true",
            "WOFFY_TEST_CALLS": str(calls),
            "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "web"),
        }
    )
    subprocess.run(
        [sys.executable, "-m", "woffy_web.manage", "init", "--password-stdin"],
        input="correct horse battery staple\n",
        text=True,
        env=env,
        check=True,
        stdout=subprocess.PIPE,
    )
    server = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "woffy_web.app:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--no-server-header",
        ],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                if urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1).read() == b"ok":
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise AssertionError("Woffy Web did not start")
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            page = browser.new_page()
            page.goto(f"http://127.0.0.1:{port}/")
            page.get_by_label("Clave administrativa").fill("correct horse battery staple")
            page.get_by_role("button", name="Entrar").click()
            page.get_by_role("link", name="Usuarios").click()
            assert page.get_by_role("heading", name="Usuarios").is_visible()
            page.get_by_role("button", name="Consultar estado").click()
            assert page.get_by_text("OK", exact=True).is_visible()
            page.get_by_role("link", name="Horarios").click()
            assert page.get_by_role("heading", name="Horarios").is_visible()
            browser.close()
        assert '["status", "alice@example.com"]' in calls.read_text(encoding="utf-8")
    finally:
        server.terminate()
        server.wait(timeout=10)
