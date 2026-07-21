from __future__ import annotations

import json
import re
import sqlite3
import stat
import sys
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


def create_woffy_db(path: Path) -> None:
    with sqlite3.connect(path) as connection:
        connection.executescript(
            """
            PRAGMA user_version=4;
            CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE users(email TEXT PRIMARY KEY,password TEXT NOT NULL,active INTEGER NOT NULL,created_at TEXT,updated_at TEXT);
            CREATE TABLE user_cards(email TEXT PRIMARY KEY,full_name TEXT,company_name TEXT,office_name TEXT,schedule_name TEXT);
            CREATE TABLE schedules(email TEXT,action TEXT,time_hhmm TEXT,weekdays TEXT,active INTEGER);
            CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT,email TEXT,action TEXT,kind TEXT,status TEXT,message TEXT,created_at TEXT,request_id TEXT);
            CREATE TABLE run_guard(email TEXT,action TEXT,run_date TEXT,time_hhmm TEXT,state TEXT,attempts INTEGER,claimed_at TEXT,next_retry_at TEXT,last_error TEXT,updated_at TEXT);
            CREATE TABLE integration_credentials(provider TEXT PRIMARY KEY,client_id TEXT,client_secret TEXT,updated_at TEXT);
            INSERT INTO users VALUES('alice@example.com','hidden',1,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP);
            INSERT INTO user_cards VALUES('alice@example.com','Alice','Acme','Madrid','Office');
            INSERT INTO schedules VALUES('alice@example.com','in','09:00','1,2,3,4,5',1);
            INSERT INTO events(email,action,kind,status,message,created_at,request_id)
              VALUES('alice@example.com','in','sign','success','=FORMULA',CURRENT_TIMESTAMP,'existing-request');
            """
        )


@pytest.fixture()
def web_client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    home = tmp_path / "home"
    woffy_home = home / ".woffy"
    woffy_home.mkdir(parents=True)
    db_path = woffy_home / "woffy.db"
    create_woffy_db(db_path)
    calls = tmp_path / "calls.jsonl"
    fake = tmp_path / "woffy"
    fake.write_text(
        """#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]
with open(os.environ['WOFFY_TEST_CALLS'],'a',encoding='utf-8') as f: f.write(json.dumps(args)+'\\n')
if args==['version']: print('woffy v3.1.0')
elif args[:2]==['doctor','--json']: print('{"version":"3.1.0","schema_version":4,"cron_run_due":true,"telegram":false,"woffu_api":false}')
elif args[:3]==['config','list','--json']: print('{"max_parallel":4,"claim_lease_seconds":120}')
elif args and args[0]=='backup': pathlib.Path(args[1]).write_bytes(b'backup'); print('OK Backup created')
else: print('OK '+ ' '.join(args))
""",
        encoding="utf-8",
    )
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("WOFFY_HOME", str(woffy_home))
    monkeypatch.setenv("WOFFY_BIN", str(fake))
    monkeypatch.setenv("WOFFY_TEST_CALLS", str(calls))
    monkeypatch.setenv("WOFFY_WEB_TESTING", "true")
    calls.touch()
    for name in list(sys.modules):
        if name == "woffy_web" or name.startswith("woffy_web."):
            del sys.modules[name]
    from woffy_web.app import app, store

    store.set_password("correct horse battery staple")
    client = TestClient(app)
    yield client, store, calls, db_path
    client.close()


def login(client: TestClient) -> str:
    response = client.post(
        "/login", data={"password": "correct horse battery staple"}, follow_redirects=False
    )
    assert response.status_code == 303
    page = client.get("/users")
    assert page.status_code == 200
    match = re.search(r'name="csrf" value="([^"]+)"', page.text)
    assert match
    return match.group(1)


def test_authentication_cookie_headers_and_loopback_host(web_client):
    client, _, _, _ = web_client
    assert client.get("/", follow_redirects=False).status_code == 303
    assert client.post("/login", data={"password": "wrong"}, follow_redirects=False).status_code == 303
    csrf = login(client)
    response = client.get("/")
    assert response.status_code == 200
    assert "frame-ancestors 'none'" in response.headers["content-security-policy"]
    assert csrf
    assert client.get("/healthz", headers={"host": "attacker.example"}).status_code == 400


def test_csrf_and_command_injection_are_rejected(web_client):
    client, _, calls, _ = web_client
    login(client)
    response = client.post(
        "/users",
        data={"csrf": "wrong", "operation": "disable", "email": "alice@example.com"},
        follow_redirects=False,
    )
    assert response.status_code == 303
    response = client.post(
        "/users",
        data={"csrf": "wrong", "operation": "disable", "email": "x@example.com;touch /tmp/pwn"},
        follow_redirects=False,
    )
    assert response.status_code == 303
    assert "users" not in calls.read_text(encoding="utf-8")


def test_secret_uses_stdin_and_never_process_arguments_or_audit(web_client):
    client, store, calls, _ = web_client
    csrf = login(client)
    secret = "woffu-super-secret"
    response = client.post(
        "/users",
        data={"csrf": csrf, "operation": "login", "email": "bob@example.com", "password": secret},
        follow_redirects=False,
    )
    assert response.status_code == 303
    logged = calls.read_text(encoding="utf-8")
    assert "--password-stdin" in logged
    assert secret not in logged
    assert secret not in json.dumps(store.recent_audit())


def test_critical_delete_requires_password_and_exact_target(web_client):
    client, _, calls, _ = web_client
    csrf = login(client)
    bad = client.post(
        "/users",
        data={
            "csrf": csrf,
            "operation": "delete",
            "email": "alice@example.com",
            "admin_password": "correct horse battery staple",
            "confirmation": "Alice",
        },
        follow_redirects=False,
    )
    assert bad.status_code == 303
    assert "delete" not in calls.read_text(encoding="utf-8")
    good = client.post(
        "/users",
        data={
            "csrf": csrf,
            "operation": "delete",
            "email": "alice@example.com",
            "admin_password": "correct horse battery staple",
            "confirmation": "alice@example.com",
        },
        follow_redirects=False,
    )
    assert good.status_code == 303
    assert '["users", "delete", "alice@example.com"]' in calls.read_text(encoding="utf-8")


def test_csv_export_neutralizes_spreadsheet_formulas(web_client):
    client, _, _, _ = web_client
    login(client)
    response = client.get("/events.csv")
    assert response.status_code == 200
    assert "'=FORMULA" in response.text


def test_reader_connection_is_read_only(web_client):
    client, _, _, _ = web_client
    login(client)
    from woffy_web.app import reader

    with reader.connect() as connection:
        with pytest.raises(sqlite3.OperationalError):
            connection.execute("DELETE FROM users")


def test_api_test_gates_backdated_signs(web_client):
    client, store, calls, _ = web_client
    csrf = login(client)
    blocked = client.post(
        "/attendance",
        data={
            "csrf": csrf,
            "operation": "backfill",
            "email": "alice@example.com",
            "action": "in",
            "sign_date": "2026-01-01",
            "sign_time": "09:00",
        },
        follow_redirects=False,
    )
    assert blocked.status_code == 303
    assert "sign" not in calls.read_text(encoding="utf-8")
    store.set_state("api_tested", "yes")
    allowed = client.post(
        "/attendance",
        data={
            "csrf": csrf,
            "operation": "backfill",
            "email": "alice@example.com",
            "action": "in",
            "sign_date": "2026-01-01",
            "sign_time": "09:00",
        },
        follow_redirects=False,
    )
    assert allowed.status_code == 303
    assert '["sign", "alice@example.com", "in", "2026-01-01", "09:00"]' in calls.read_text(encoding="utf-8")


def test_backup_download_uses_fixed_directory(web_client):
    client, _, _, _ = web_client
    csrf = login(client)
    response = client.post(
        "/maintenance/action", data={"csrf": csrf, "operation": "backup"}, follow_redirects=False
    )
    assert response.status_code == 303
    page = client.get("/maintenance")
    match = re.search(r'href="/maintenance/backup/([^"]+\.tar\.gz)"', page.text)
    assert match
    assert client.get(f"/maintenance/backup/{match.group(1)}").status_code == 200
    assert client.get("/maintenance/backup/../woffy.db").status_code in {400, 404}


def test_reports_and_cron_controls_map_to_fixed_cli_commands(web_client):
    client, _, calls, _ = web_client
    csrf = login(client)
    report = client.post(
        "/reports",
        data={
            "csrf": csrf,
            "from_date": "2026-01-01",
            "to_date": "2026-01-31",
            "format": "json",
            "telegram": "true",
        },
    )
    assert report.status_code == 200
    cron = client.post(
        "/schedules",
        data={"csrf": csrf, "operation": "cron-install", "email": "system@local.invalid"},
        follow_redirects=False,
    )
    assert cron.status_code == 303
    logged = calls.read_text(encoding="utf-8")
    assert (
        '["report", "all", "--from", "2026-01-01", "--to", "2026-01-31", "--format", "json", "telegram"]'
        in logged
    )
    assert '["schedule", "install"]' in logged


def test_events_escape_untrusted_html(web_client):
    client, _, _, db_path = web_client
    with sqlite3.connect(db_path) as connection:
        connection.execute(
            "INSERT INTO events(email,action,kind,status,message,created_at) VALUES(?,?,?,?,?,CURRENT_TIMESTAMP)",
            ("alice@example.com", "in", "sign", "error", "<script>alert(1)</script>"),
        )
    login(client)
    page = client.get("/events")
    assert "<script>alert(1)</script>" not in page.text
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in page.text


def test_login_rate_limit_and_password_change_invalidate_sessions(web_client):
    client, store, _, _ = web_client
    for _ in range(5):
        store.record_login(False)
    assert store.login_blocked()
    store.record_login(True)
    assert store.login_blocked()
    token, _ = store.create_session()
    assert store.get_session(token)
    store.set_password("a completely different admin password")
    assert store.get_session(token) is None


def test_restore_upload_uses_generated_name_and_records_job(web_client):
    client, store, _, _ = web_client
    csrf = login(client)
    response = client.post(
        "/maintenance/restore",
        data={
            "csrf": csrf,
            "password": "correct horse battery staple",
            "confirmation": "RESTORE",
        },
        files={"backup": ("../../unsafe.tar.gz", b"archive", "application/gzip")},
        follow_redirects=False,
    )
    assert response.status_code == 303
    deadline = time.time() + 3
    while time.time() < deadline and store.jobs()[0]["status"] in {"queued", "running"}:
        time.sleep(0.05)
    job = store.jobs()[0]
    assert job["action"] == "restore"
    assert job["status"] == "success"


def test_log_view_redacts_common_secret_shapes_and_large_upload_is_rejected(web_client):
    client, _, _, db_path = web_client
    log_path = db_path.with_name("woffy.log")
    log_path.write_text(
        "Authorization: Bearer visible-token\nclient_secret=do-not-show\nbot123456789:abcdefghijklmnopqrstuvwxyz\n",
        encoding="utf-8",
    )
    login(client)
    page = client.get("/logs")
    assert "visible-token" not in page.text
    assert "do-not-show" not in page.text
    assert "abcdefghijklmnopqrstuvwxyz" not in page.text
    response = client.post(
        "/maintenance/restore",
        headers={"content-length": str(60 * 1024 * 1024)},
        content=b"",
    )
    assert response.status_code == 413


def test_health_rejects_a_database_schema_newer_than_the_panel(web_client):
    client, _, _, db_path = web_client
    assert client.get("/healthz").status_code == 200
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA user_version=99")
    response = client.get("/healthz")
    assert response.status_code == 503
    assert response.text == "incompatible"
