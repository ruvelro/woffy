from __future__ import annotations

import asyncio
import csv
import io
import json
import re
import secrets
import threading
import time
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Callable, Optional

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    PlainTextResponse,
    RedirectResponse,
    StreamingResponse,
)
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from . import __version__
from .cli import SETTING, CommandError, WoffyCLI
from .config import settings
from .store import WebStore
from .woffy_db import WoffyReader

PACKAGE_DIR = Path(__file__).resolve().parent
MANIFEST = json.loads((PACKAGE_DIR.parent / "manifest.json").read_text(encoding="utf-8"))
templates = Jinja2Templates(directory=str(PACKAGE_DIR / "templates"))
settings.prepare()
store = WebStore(settings.web_db_path, settings.session_idle_seconds, settings.session_max_seconds)
store.initialize()
reader = WoffyReader(settings.db_path)
cli = WoffyCLI(settings.cli_path, settings.home)
app = FastAPI(title="Woffy Web", version=__version__, docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=str(PACKAGE_DIR / "static")), name="static")

PUBLIC_PATHS = {"/login", "/healthz"}
CRITICAL_CONFIRMATIONS = {
    "delete-user": lambda target: target,
    "purge-events": lambda target: target,
    "restore": lambda target: "RESTORE",
    "downgrade": lambda target: "DOWNGRADE",
    "uninstall": lambda target: "UNINSTALL WOFFY",
}


@app.middleware("http")
async def security_middleware(request: Request, call_next: Callable[..., Any]):
    host_header = request.headers.get("host", "")
    if host_header.startswith("["):
        host = host_header[1:].split("]", 1)[0]
    else:
        host = host_header.rsplit(":", 1)[0] if host_header.count(":") == 1 else host_header
    if host not in {"127.0.0.1", "localhost", "::1", "testserver"}:
        return PlainTextResponse("Invalid Host", status_code=400)
    if request.url.path == "/maintenance/restore":
        content_length = request.headers.get("content-length", "0")
        if content_length.isdigit() and int(content_length) > settings.max_upload_bytes + 1024 * 1024:
            return PlainTextResponse("Upload too large", status_code=413)
    token = request.cookies.get("woffy_session", "")
    request.state.session = store.get_session(token)
    request.state.session_token = token
    if request.url.path not in PUBLIC_PATHS and not request.url.path.startswith("/static/"):
        if request.state.session is None:
            return RedirectResponse("/login", status_code=303)
    response = await call_next(request)
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
    )
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Cache-Control"] = "no-store"
    return response


def context(request: Request, **values: Any) -> dict[str, Any]:
    base = {
        "request": request,
        "version": __version__,
        "csrf": (request.state.session or {}).get("csrf_token", ""),
        "message": request.query_params.get("message", ""),
        "error": request.query_params.get("error", ""),
    }
    base.update(values)
    return base


def redirect(path: str, message: str = "", error: str = "") -> RedirectResponse:
    from urllib.parse import urlencode

    query = urlencode({key: value for key, value in {"message": message, "error": error}.items() if value})
    return RedirectResponse(path + (f"?{query}" if query else ""), status_code=303)


def require_csrf(request: Request, csrf: str) -> None:
    expected = (request.state.session or {}).get("csrf_token", "")
    if not expected or not secrets.compare_digest(expected, csrf):
        raise CommandError("Invalid CSRF token")


def require_critical(request: Request, password: str, confirmation: str, expected: str) -> None:
    if confirmation != expected:
        raise CommandError(f"Type exactly: {expected}")
    if not store.reauthenticate(request.state.session_token, password):
        raise CommandError("Administrator password is incorrect")


def audited(action: str, target: str, result: Any) -> None:
    store.audit(result.request_id, action, target, "success" if result.ok else "error", result.output)


def invoke(action: str, target: str, args: list[str], stdin: Optional[str] = None, timeout: int = 120):
    result = cli.run(args, stdin=stdin, timeout=timeout)
    audited(action, target, result)
    return result


def start_job(
    action: str, target: str, args: list[str], stdin: Optional[str] = None, postcheck: bool = False
) -> str:
    job_id = str(uuid.uuid4())
    store.create_job(job_id, action)

    def worker() -> None:
        store.start_job(job_id)
        result = invoke(action, target, args, stdin=stdin, timeout=600)
        output = result.output
        ok = result.ok
        if ok and postcheck:
            checked = invoke("postcheck", target, ["doctor", "--json"], timeout=60)
            ok = checked.ok
            output = f"{output}\n{checked.output}".strip()
        store.finish_job(job_id, ok, output)

    threading.Thread(target=worker, daemon=True).start()
    return job_id


def start_restore_job(upload: Path, fallback: Path, target: str) -> str:
    job_id = str(uuid.uuid4())
    store.create_job(job_id, "restore")

    def worker() -> None:
        store.start_job(job_id)
        restored = invoke("restore", target, ["restore", str(upload)], timeout=600)
        output = restored.output
        ok = restored.ok
        if ok:
            checked = invoke("restore-postcheck", target, ["doctor", "--json"], timeout=60)
            output = f"{output}\n{checked.output}".strip()
            ok = checked.ok
        if not ok:
            rolled_back = invoke("restore-rollback", fallback.name, ["restore", str(fallback)], timeout=600)
            output = f"{output}\nRollback: {rolled_back.output}".strip()
        store.finish_job(job_id, ok, output)
        upload.unlink(missing_ok=True)

    threading.Thread(target=worker, daemon=True).start()
    return job_id


def start_update_job(channel: str, allow_downgrade: bool) -> str:
    job_id = str(uuid.uuid4())
    store.create_job(job_id, "update")

    def worker() -> None:
        store.start_job(job_id)
        backup_dir = settings.web_home / "backups"
        backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        backup_path = backup_dir / f"pre-update-{int(time.time())}.tar.gz"
        backed = invoke("pre-update-backup", backup_path.name, ["backup", str(backup_path)], timeout=300)
        if not backed.ok:
            store.finish_job(job_id, False, backed.output)
            return
        args = ["update"]
        if channel == "nightly":
            args.append("nightly")
        if allow_downgrade:
            args.append("--allow-downgrade")
        updated = invoke("update-cli", channel, args, timeout=600)
        output = updated.output
        ok = updated.ok
        if ok:
            panel = invoke("update-web", channel, ["web", "update", "--deferred", channel], timeout=60)
            output = f"{output}\n{panel.output}".strip()
            ok = panel.ok
        if ok:
            checked = invoke("update-postcheck", channel, ["doctor", "--json"], timeout=60)
            output = f"{output}\n{checked.output}".strip()
            ok = checked.ok
        store.finish_job(job_id, ok, output)

    threading.Thread(target=worker, daemon=True).start()
    return job_id


@app.get("/healthz", response_class=PlainTextResponse)
def healthz():
    version_result = cli.version()
    version_match = re.search(r"woffy v(\d+\.\d+\.\d+)", version_result.output)
    minimum = tuple(int(part) for part in str(MANIFEST["minimum_cli_version"]).split("."))
    current = tuple(int(part) for part in version_match.group(1).split(".")) if version_match else (0, 0, 0)
    schema = reader.one("PRAGMA user_version").get("user_version", 0) if settings.db_path.exists() else 0
    if not version_result.ok or current < minimum or int(schema) > int(MANIFEST["maximum_schema_version"]):
        return PlainTextResponse("incompatible", status_code=503)
    return "ok"


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    if request.state.session:
        return RedirectResponse("/", status_code=303)
    return templates.TemplateResponse(
        request, "login.html", context(request, configured=store.has_password())
    )


@app.post("/login")
def login(request: Request, password: str = Form(...)):
    if store.login_blocked():
        return redirect("/login", error="Demasiados intentos. Espera 15 minutos.")
    valid = store.verify_password(password)
    store.record_login(valid)
    if not valid:
        return redirect("/login", error="Clave incorrecta.")
    token, _ = store.create_session()
    response = redirect("/", message="Sesión iniciada.")
    response.set_cookie(
        "woffy_session",
        token,
        httponly=True,
        samesite="strict",
        max_age=settings.session_max_seconds,
        path="/",
    )
    return response


@app.post("/logout")
def logout(request: Request, csrf: str = Form(...)):
    require_csrf(request, csrf)
    store.destroy_session(request.state.session_token)
    response = RedirectResponse("/login", status_code=303)
    response.delete_cookie("woffy_session", path="/")
    return response


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request):
    doctor = cli.run(["doctor", "--json"], timeout=20)
    try:
        doctor_data = json.loads(doctor.output) if doctor.ok else {}
    except json.JSONDecodeError:
        doctor_data = {}
    return templates.TemplateResponse(
        request,
        "dashboard.html",
        context(
            request,
            stats=reader.dashboard(),
            upcoming=reader.upcoming(),
            doctor=doctor_data,
            recent=reader.events("", "error", "", 10, 0),
            jobs=store.jobs(8),
        ),
    )


@app.get("/users", response_class=HTMLResponse)
def users_page(request: Request):
    return templates.TemplateResponse(request, "users.html", context(request, users=reader.users()))


@app.post("/users")
def users_action(
    request: Request,
    csrf: str = Form(...),
    operation: str = Form(...),
    email: str = Form(...),
    password: str = Form(""),
    admin_password: str = Form(""),
    confirmation: str = Form(""),
):
    try:
        require_csrf(request, csrf)
        email = cli.email(email)
        if operation == "login":
            if not password:
                raise CommandError("Woffu password is required")
            result = invoke("user-login", email, ["login", email, "--password-stdin"], password + "\n")
        elif operation == "status":
            result = invoke("user-status", email, ["status", email])
        elif operation in {"enable", "disable"}:
            result = invoke(f"user-{operation}", email, ["users", operation, email])
        elif operation == "delete":
            require_critical(request, admin_password, confirmation, email)
            result = invoke("delete-user", email, ["users", "delete", email])
        else:
            raise CommandError("Unknown user operation")
        return redirect(
            "/users", message=result.output if result.ok else "", error="" if result.ok else result.output
        )
    except CommandError as exc:
        return redirect("/users", error=str(exc))


@app.get("/schedules", response_class=HTMLResponse)
def schedules_page(request: Request, email: str = ""):
    selected = email if not email or any(user["email"] == email for user in reader.users()) else ""
    schedules = reader.schedules(selected)
    today = date.today()
    preview = []
    for offset in range(7):
        day = today + timedelta(days=offset)
        dow = str(day.isoweekday())
        for row in schedules:
            if dow in str(row["weekdays"]).split(","):
                preview.append({**row, "day": day.isoformat()})
    return templates.TemplateResponse(
        request,
        "schedules.html",
        context(request, users=reader.users(), selected=selected, schedules=schedules, preview=preview),
    )


@app.post("/schedules")
def schedules_action(
    request: Request,
    csrf: str = Form(...),
    operation: str = Form(...),
    email: str = Form(...),
    action: str = Form(""),
    times: str = Form(""),
    weekdays: str = Form("1,2,3,4,5"),
):
    try:
        require_csrf(request, csrf)
        if operation in {"cron-install", "cron-clear", "cron-list"}:
            args = ["schedule", operation.split("-", 1)[1]]
            result = invoke(operation, "cron", args)
            return redirect(
                "/schedules",
                message=result.output if result.ok else "",
                error="" if result.ok else result.output,
            )
        email = cli.email(email)
        if operation in {"defaults", "clear"}:
            args = ["schedule", "user", email, operation]
        elif operation in {"add", "remove"}:
            args = ["schedule", "user", email, operation, cli.action(action), cli.time(times)]
            if operation == "add":
                args.append(cli.weekdays(weekdays))
        elif operation == "set":
            clean_times = ",".join(cli.time(item.strip()) for item in times.split(",") if item.strip())
            if not clean_times:
                raise CommandError("At least one time is required")
            args = ["schedule", "user", email, "set", cli.action(action), clean_times, cli.weekdays(weekdays)]
        else:
            raise CommandError("Unknown schedule operation")
        result = invoke(f"schedule-{operation}", email, args)
        return redirect(
            f"/schedules?email={email}",
            message=result.output if result.ok else "",
            error="" if result.ok else result.output,
        )
    except CommandError as exc:
        return redirect(f"/schedules?email={email}", error=str(exc))


@app.get("/attendance", response_class=HTMLResponse)
def attendance_page(request: Request):
    return templates.TemplateResponse(
        request,
        "attendance.html",
        context(request, users=reader.users(), api_tested=store.get_state("api_tested") == "yes"),
    )


@app.post("/attendance")
def attendance_action(
    request: Request,
    csrf: str = Form(...),
    operation: str = Form(...),
    email: str = Form(""),
    action: str = Form(""),
    sign_date: str = Form(""),
    sign_time: str = Form(""),
):
    try:
        require_csrf(request, csrf)
        if operation in {"in", "out", "dry-run"}:
            email = cli.email(email)
            if operation == "dry-run":
                args = ["dry-run", cli.action(action), email]
            else:
                args = [operation, email]
        elif operation == "backfill":
            if store.get_state("api_tested") != "yes":
                raise CommandError("Run a successful API test before enabling backdated signs")
            email = cli.email(email)
            args = ["sign", email, cli.action(action), cli.date(sign_date), cli.time(sign_time)]
        elif operation == "run-due-dry":
            args = ["run", "due", "--dry-run"]
        elif operation == "run-due":
            args = ["run", "due"]
        else:
            raise CommandError("Unknown attendance operation")
        result = invoke(f"attendance-{operation}", email or "all", args, timeout=300)
        return redirect(
            "/attendance",
            message=result.output if result.ok else "",
            error="" if result.ok else result.output,
        )
    except CommandError as exc:
        return redirect("/attendance", error=str(exc))


@app.get("/events", response_class=HTMLResponse)
def events_page(request: Request, email: str = "", status: str = "", q: str = "", page: int = 1):
    if status not in {"", "success", "warning", "error", "dry-run"}:
        status = ""
    page = min(max(page, 1), 100000)
    return templates.TemplateResponse(
        request,
        "events.html",
        context(
            request,
            users=reader.users(),
            events=reader.events(email, status, q[:100], 100, (page - 1) * 100),
            guards=reader.guards(),
            filters={"email": email, "status": status, "q": q, "page": page},
        ),
    )


def csv_cell(value: Any) -> str:
    text = "" if value is None else str(value)
    return "'" + text if text.startswith(("=", "+", "-", "@")) else text


def redact_log_line(line: str) -> str:
    line = re.sub(r"(?i)(authorization:\s*bearer\s+)[^\s]+", r"\1[REDACTED]", line)
    line = re.sub(
        r"(?i)((?:password|client_secret|token|api[_ -]?key)\s*[=:]\s*)[^\s&]+", r"\1[REDACTED]", line
    )
    return re.sub(r"bot\d{6,}:[A-Za-z0-9_-]{20,}", "bot[REDACTED]", line)


@app.get("/events.csv")
def events_csv(email: str = "", status: str = "", q: str = ""):
    output = io.StringIO()
    fields = ["id", "created_at", "email", "action", "kind", "status", "message", "request_id"]
    writer = csv.DictWriter(output, fieldnames=fields)
    writer.writeheader()
    for row in reader.events(email, status, q[:100], 500, 0):
        writer.writerow({key: csv_cell(row.get(key)) for key in fields})
    return PlainTextResponse(
        output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=woffy-events.csv"},
    )


@app.post("/events/purge")
def events_purge(
    request: Request,
    csrf: str = Form(...),
    before: str = Form(...),
    password: str = Form(...),
    confirmation: str = Form(...),
):
    try:
        require_csrf(request, csrf)
        before = cli.date(before)
        require_critical(request, password, confirmation, before)
        result = invoke("purge-events", before, ["events", "purge", "--before", before, "--yes"])
        return redirect(
            "/events", message=result.output if result.ok else "", error="" if result.ok else result.output
        )
    except CommandError as exc:
        return redirect("/events", error=str(exc))


@app.get("/logs", response_class=HTMLResponse)
def logs_page(request: Request):
    lines: list[str] = []
    for path in [settings.log_path.with_name(settings.log_path.name + ".1"), settings.log_path]:
        if path.is_file():
            lines.extend(
                redact_log_line(line)
                for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
            )
    return templates.TemplateResponse(request, "logs.html", context(request, lines=lines[-500:]))


@app.get("/logs/stream")
async def logs_stream():
    async def generate():
        position = settings.log_path.stat().st_size if settings.log_path.exists() else 0
        for _ in range(120):
            if settings.log_path.exists():
                size = settings.log_path.stat().st_size
                if size < position:
                    position = 0
                if size > position:
                    with settings.log_path.open("r", encoding="utf-8", errors="replace") as handle:
                        handle.seek(position)
                        for line in handle:
                            yield f"data: {json.dumps(redact_log_line(line.rstrip()))}\n\n"
                        position = handle.tell()
            await asyncio.sleep(0.5)

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.get("/reports", response_class=HTMLResponse)
def reports_page(request: Request):
    today = date.today()
    return templates.TemplateResponse(
        request,
        "reports.html",
        context(
            request,
            from_date=(today - timedelta(days=today.weekday())).isoformat(),
            to_date=today.isoformat(),
            report="",
        ),
    )


@app.post("/reports", response_class=HTMLResponse)
def reports_generate(
    request: Request,
    csrf: str = Form(...),
    from_date: str = Form(...),
    to_date: str = Form(...),
    format: str = Form("text"),
    telegram: bool = Form(False),
):
    try:
        require_csrf(request, csrf)
        if format not in {"text", "json", "csv"}:
            raise CommandError("Invalid report format")
        args = ["report", "all", "--from", cli.date(from_date), "--to", cli.date(to_date), "--format", format]
        if telegram:
            args.append("telegram")
        result = invoke("report", f"{from_date}:{to_date}", args, timeout=120)
        return templates.TemplateResponse(
            request,
            "reports.html",
            context(
                request,
                from_date=from_date,
                to_date=to_date,
                report=result.output,
                error="" if result.ok else result.output,
            ),
        )
    except CommandError as exc:
        return templates.TemplateResponse(
            request,
            "reports.html",
            context(request, from_date=from_date, to_date=to_date, report="", error=str(exc)),
            status_code=400,
        )


@app.get("/integrations", response_class=HTMLResponse)
def integrations_page(request: Request):
    values = reader.settings()
    return templates.TemplateResponse(
        request,
        "integrations.html",
        context(
            request,
            telegram=bool(values.get("TG_TOKEN") and values.get("TG_CHAT_ID")),
            telegram_mode=values.get("TG_NOTIFY", "all"),
            api=bool(
                reader.one("SELECT 1 AS configured FROM integration_credentials WHERE provider='woffu'")
            ),
            api_tested=store.get_state("api_tested") == "yes",
        ),
    )


@app.post("/integrations")
def integrations_action(
    request: Request,
    csrf: str = Form(...),
    operation: str = Form(...),
    secret: str = Form(""),
    company_id: str = Form(""),
    chat_id: str = Form(""),
    thread_id: str = Form(""),
    notify: str = Form("all"),
):
    try:
        require_csrf(request, csrf)
        if operation == "telegram-configure":
            if not secret or not chat_id or notify not in {"all", "errors", "success"}:
                raise CommandError("Token, chat id and a valid notification mode are required")
            result = invoke(
                operation,
                chat_id,
                ["telegram", "configure", "--token-stdin", chat_id, thread_id, notify],
                secret + "\n",
            )
        elif operation == "telegram-set-mode":
            if notify not in {"all", "errors", "success"}:
                raise CommandError("A valid notification mode is required")
            result = invoke(operation, "telegram", ["telegram", "set-mode", notify])
        elif operation in {"telegram-test", "telegram-clear"}:
            result = invoke(operation, "telegram", ["telegram", operation.split("-", 1)[1]])
        elif operation == "api-configure":
            if not company_id.isdigit() or not secret:
                raise CommandError("Numeric company id and API key are required")
            result = invoke(
                operation, company_id, ["api", "configure", company_id, "--secret-stdin"], secret + "\n"
            )
            store.set_state("api_tested", "no")
        elif operation in {"api-test", "api-clear"}:
            result = invoke(operation, "woffu", ["api", operation.split("-", 1)[1]])
            if operation == "api-test" and result.ok:
                store.set_state("api_tested", "yes")
            if operation == "api-clear":
                store.set_state("api_tested", "no")
        else:
            raise CommandError("Unknown integration operation")
        return redirect(
            "/integrations",
            message=result.output if result.ok else "",
            error="" if result.ok else result.output,
        )
    except CommandError as exc:
        return redirect("/integrations", error=str(exc))


@app.get("/settings", response_class=HTMLResponse)
def settings_page(request: Request):
    result = cli.run(["config", "list", "--json"], timeout=20)
    try:
        runtime = json.loads(result.output) if result.ok else {}
    except json.JSONDecodeError:
        runtime = {}
    return templates.TemplateResponse(request, "settings.html", context(request, runtime=runtime))


@app.post("/settings")
def settings_action(
    request: Request,
    csrf: str = Form(...),
    operation: str = Form(...),
    name: str = Form(...),
    value: str = Form(""),
):
    try:
        require_csrf(request, csrf)
        if not SETTING.fullmatch(name):
            raise CommandError("Invalid setting")
        if operation == "set":
            if not value.isdigit():
                raise CommandError("Setting values must be integers")
            args = ["config", "set", name, value]
        elif operation == "reset":
            args = ["config", "reset", name]
        else:
            raise CommandError("Unknown settings operation")
        result = invoke(f"config-{operation}", name, args)
        return redirect(
            "/settings", message=result.output if result.ok else "", error="" if result.ok else result.output
        )
    except CommandError as exc:
        return redirect("/settings", error=str(exc))


@app.get("/maintenance", response_class=HTMLResponse)
def maintenance_page(request: Request):
    backups = (
        sorted((settings.web_home / "backups").glob("*.tar.gz"), reverse=True)
        if (settings.web_home / "backups").exists()
        else []
    )
    return templates.TemplateResponse(
        request,
        "maintenance.html",
        context(
            request, jobs=store.jobs(), backups=[path.name for path in backups], audit=store.recent_audit(50)
        ),
    )


@app.post("/maintenance/action")
def maintenance_action(
    request: Request,
    operation: str = Form(...),
    csrf: str = Form(...),
    password: str = Form(""),
    confirmation: str = Form(""),
    channel: str = Form("stable"),
    allow_downgrade: bool = Form(False),
):
    try:
        require_csrf(request, csrf)
        if operation in {"doctor", "self-test", "config-check", "changelog", "update-check"}:
            mapping = {
                "doctor": ["doctor", "--json"],
                "self-test": ["self-test"],
                "config-check": ["config", "check"],
                "changelog": ["changelog"],
                "update-check": ["update", *(["nightly"] if channel == "nightly" else []), "--check"],
            }
            result = invoke(operation, channel, mapping[operation], timeout=120)
            return redirect(
                "/maintenance",
                message=result.output if result.ok else "",
                error="" if result.ok else result.output,
            )
        if operation == "backup":
            backup_dir = settings.web_home / "backups"
            backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            path = backup_dir / f"woffy-{int(time.time())}.tar.gz"
            result = invoke("backup", path.name, ["backup", str(path)], timeout=300)
            return redirect(
                "/maintenance",
                message=result.output if result.ok else "",
                error="" if result.ok else result.output,
            )
        if operation == "update":
            if channel not in {"stable", "nightly"}:
                raise CommandError("Invalid update channel")
            if allow_downgrade:
                require_critical(request, password, confirmation, "DOWNGRADE")
            job_id = start_update_job(channel, allow_downgrade)
            return redirect("/maintenance", message=f"Actualización iniciada: {job_id}")
        if operation == "uninstall":
            require_critical(request, password, confirmation, "UNINSTALL WOFFY")
            backup_dir = settings.web_home / "backups"
            backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            backup_path = settings.recovery_dir / f"woffy-pre-uninstall-{int(time.time())}.tar.gz"
            backed = invoke(
                "pre-uninstall-backup", backup_path.name, ["backup", str(backup_path)], timeout=300
            )
            if not backed.ok:
                raise CommandError(backed.output)
            job_id = start_job("uninstall", "woffy", ["uninstall"], stdin="y\n")
            return redirect(
                "/maintenance", message=f"Desinstalación aceptada: {job_id}. Conserva {backup_path}."
            )
        raise CommandError("Unknown maintenance operation")
    except CommandError as exc:
        return redirect("/maintenance", error=str(exc))


@app.post("/maintenance/restore")
async def restore_backup(
    request: Request,
    csrf: str = Form(...),
    password: str = Form(...),
    confirmation: str = Form(...),
    backup: UploadFile = File(...),
):
    path: Optional[Path] = None
    try:
        require_csrf(request, csrf)
        require_critical(request, password, confirmation, "RESTORE")
        if not backup.filename or not backup.filename.endswith(".tar.gz"):
            raise CommandError("Only .tar.gz backups are accepted")
        upload_dir = settings.web_home / "uploads"
        upload_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = upload_dir / f"{uuid.uuid4()}.tar.gz"
        size = 0
        with path.open("xb") as handle:
            while chunk := await backup.read(1024 * 1024):
                size += len(chunk)
                if size > settings.max_upload_bytes:
                    raise CommandError("Backup exceeds the upload limit")
                handle.write(chunk)
        pre_dir = settings.web_home / "backups"
        pre_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        pre = pre_dir / f"pre-restore-{int(time.time())}.tar.gz"
        backed = invoke("pre-restore-backup", pre.name, ["backup", str(pre)], timeout=300)
        if not backed.ok:
            raise CommandError(backed.output)
        job_id = start_restore_job(path, pre, backup.filename)
        return redirect("/maintenance", message=f"Restauración iniciada: {job_id}")
    except CommandError as exc:
        if path and path.exists():
            path.unlink()
        return redirect("/maintenance", error=str(exc))


@app.get("/maintenance/backup/{name}")
def download_backup(name: str):
    if not name.endswith(".tar.gz") or Path(name).name != name:
        return PlainTextResponse("Invalid backup", status_code=400)
    path = settings.web_home / "backups" / name
    if not path.is_file():
        return PlainTextResponse("Not found", status_code=404)
    return FileResponse(path, filename=name, media_type="application/gzip")
