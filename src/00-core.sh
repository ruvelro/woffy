#!/bin/bash
set -euo pipefail

VERSION="3.1.2"

WOFFY_HOME="${WOFFY_HOME:-$HOME/.woffy}"
DB_FILE="${WOFFY_DB_FILE:-$WOFFY_HOME/woffy.db}"
LOG_FILE="${WOFFY_LOG_FILE:-$WOFFY_HOME/woffy.log}"
LOCK_DIR="${WOFFY_LOCK_DIR:-$WOFFY_HOME/woffy.lock.d}"
API_URL="https://app.woffu.com"
REPO_RAW_BASE="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main"
RELEASE_BASE="${WOFFY_RELEASE_BASE:-https://github.com/ruvelro/woffy/releases}"

CURL_CONNECT_TIMEOUT="${WOFFY_CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${WOFFY_CURL_MAX_TIME:-15}"
MAX_PARALLEL="${WOFFY_MAX_PARALLEL:-4}"
CATCHUP_MINUTES="${WOFFY_CATCHUP_MINUTES:-5}"
JITTER_MAX="${WOFFY_JITTER_MAX:-0}"
SQLITE_BUSY_MS="${WOFFY_SQLITE_BUSY_MS:-5000}"
SCHEDULE_MAX_ATTEMPTS="${WOFFY_SCHEDULE_MAX_ATTEMPTS:-3}"
CLAIM_LEASE_SECONDS="${WOFFY_CLAIM_LEASE_SECONDS:-120}"
RUN_GUARD_RETENTION_DAYS="${WOFFY_RUN_GUARD_RETENTION_DAYS:-30}"
LOG_MAX_BYTES="${WOFFY_LOG_MAX_BYTES:-1048576}"
LOG_MAX_FILES="${WOFFY_LOG_MAX_FILES:-5}"
REQUEST_ID="${WOFFY_REQUEST_ID:-}"

NO_TELEGRAM=false
QUIET=false

if [ "$#" -gt 0 ]; then
  FILTERED_ARGS=()
  for arg in "$@"; do
    case "$arg" in
      --no-telegram) NO_TELEGRAM=true ;;
      --quiet) QUIET=true ;;
      *) FILTERED_ARGS+=("$arg") ;;
    esac
  done
  set -- "${FILTERED_ARGS[@]}"
fi

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

validate_bounded_int() {
  local name="$1" value="$2" min="$3" max="$4"
  if ! { is_int "$value" && [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; }; then
    echo "ERROR $name must be an integer between $min and $max" >&2
    return 1
  fi
}

validate_runtime_config() {
  validate_bounded_int WOFFY_CURL_CONNECT_TIMEOUT "$CURL_CONNECT_TIMEOUT" 1 120
  validate_bounded_int WOFFY_CURL_MAX_TIME "$CURL_MAX_TIME" 1 120
  validate_bounded_int WOFFY_MAX_PARALLEL "$MAX_PARALLEL" 1 16
  validate_bounded_int WOFFY_CATCHUP_MINUTES "$CATCHUP_MINUTES" 1 60
  validate_bounded_int WOFFY_JITTER_MAX "$JITTER_MAX" 0 30
  validate_bounded_int WOFFY_SQLITE_BUSY_MS "$SQLITE_BUSY_MS" 100 60000
  validate_bounded_int WOFFY_SCHEDULE_MAX_ATTEMPTS "$SCHEDULE_MAX_ATTEMPTS" 1 10
  validate_bounded_int WOFFY_CLAIM_LEASE_SECONDS "$CLAIM_LEASE_SECONDS" 30 600
  validate_bounded_int WOFFY_RUN_GUARD_RETENTION_DAYS "$RUN_GUARD_RETENTION_DAYS" 1 3650
  validate_bounded_int WOFFY_LOG_MAX_BYTES "$LOG_MAX_BYTES" 1024 1073741824
  validate_bounded_int WOFFY_LOG_MAX_FILES "$LOG_MAX_FILES" 1 100
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sql_quote() {
  local value="${1-}"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

check_deps() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "ERROR Missing required dependency: $cmd"
      exit 1
    }
  done
}

ensure_home() {
  mkdir -p "$WOFFY_HOME"
  chmod 700 "$WOFFY_HOME" 2>/dev/null || true
}

rotate_log_if_needed() {
  [ -f "$LOG_FILE" ] || return 0
  local max_bytes max_files size i prev next
  max_bytes="$LOG_MAX_BYTES"
  max_files="$LOG_MAX_FILES"
  [ "$max_files" -lt 1 ] && max_files=1
  size="$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)"
  is_int "$size" || size=0
  [ "$size" -lt "$max_bytes" ] && return 0

  i="$max_files"
  while [ "$i" -ge 1 ]; do
    prev="$LOG_FILE.$i"
    next="$LOG_FILE.$((i + 1))"
    [ -f "$prev" ] && mv -f "$prev" "$next"
    i=$((i - 1))
  done
  mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  : >"$LOG_FILE"
}

log() {
  ensure_home
  rotate_log_if_needed
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG_FILE" 2>/dev/null || true
}

db_exec() {
  sqlite3 -cmd ".timeout $SQLITE_BUSY_MS" -cmd "PRAGMA foreign_keys=ON;" "$DB_FILE" "$1"
}

db_init() {
  [ "${DB_READY:-false}" = "true" ] && return 0
  check_deps sqlite3
  ensure_home
  sqlite3 -cmd ".timeout $SQLITE_BUSY_MS" "$DB_FILE" <<'SQL'
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS settings(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS users(
  email TEXT PRIMARY KEY,
  password TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens(
  email TEXT PRIMARY KEY,
  token TEXT,
  expires_at INTEGER,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(email) REFERENCES users(email) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS user_cards(
  email TEXT PRIMARY KEY,
  woffu_user_id TEXT,
  full_name TEXT,
  company_name TEXT,
  office_name TEXT,
  schedule_name TEXT,
  raw_json TEXT,
  fetched_at TEXT NOT NULL,
  FOREIGN KEY(email) REFERENCES users(email) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS schedules(
  email TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('in','out')),
  time_hhmm TEXT NOT NULL,
  weekdays TEXT NOT NULL DEFAULT '1,2,3,4,5',
  active INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY(email, action, time_hhmm),
  FOREIGN KEY(email) REFERENCES users(email) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS events(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT,
  action TEXT,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  message TEXT NOT NULL,
  created_at TEXT NOT NULL,
  request_id TEXT
);
CREATE TABLE IF NOT EXISTS run_guard(
  email TEXT NOT NULL,
  action TEXT NOT NULL,
  run_date TEXT NOT NULL,
  time_hhmm TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'success',
  attempts INTEGER NOT NULL DEFAULT 0,
  claimed_at TEXT,
  next_retry_at TEXT,
  last_error TEXT,
  updated_at TEXT,
  PRIMARY KEY(email, action, run_date, time_hhmm)
);
CREATE TABLE IF NOT EXISTS integration_credentials(
  provider TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  client_secret TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS integration_tokens(
  provider TEXT PRIMARY KEY,
  token TEXT,
  expires_at INTEGER,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at);
CREATE INDEX IF NOT EXISTS idx_schedules_due ON schedules(active,time_hhmm,email);
SQL
  ensure_run_guard_column state "TEXT NOT NULL DEFAULT 'success'"
  ensure_run_guard_column attempts "INTEGER NOT NULL DEFAULT 0"
  ensure_run_guard_column claimed_at "TEXT"
  ensure_run_guard_column next_retry_at "TEXT"
  ensure_run_guard_column last_error "TEXT"
  ensure_run_guard_column updated_at "TEXT"
  ensure_table_column events request_id "TEXT"
  db_exec "CREATE TABLE IF NOT EXISTS integration_credentials(provider TEXT PRIMARY KEY,client_id TEXT NOT NULL,client_secret TEXT NOT NULL,updated_at TEXT NOT NULL);
           CREATE TABLE IF NOT EXISTS integration_tokens(provider TEXT PRIMARY KEY,token TEXT,expires_at INTEGER,updated_at TEXT NOT NULL);
           CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at);
           CREATE INDEX IF NOT EXISTS idx_events_request_id ON events(request_id);
           CREATE INDEX IF NOT EXISTS idx_schedules_due ON schedules(active,time_hhmm,email);
           CREATE INDEX IF NOT EXISTS idx_run_guard_state ON run_guard(state,next_retry_at,claimed_at);
           PRAGMA journal_mode=WAL;
           PRAGMA user_version=4;" >/dev/null
  chmod 600 "$DB_FILE" 2>/dev/null || true
  DB_READY=true
}

ensure_run_guard_column() {
  local column="$1" definition="$2"
  if ! sqlite3 "$DB_FILE" "PRAGMA table_info(run_guard);" | awk -F'|' -v column="$column" '$2==column{found=1} END{exit !found}'; then
    sqlite3 -cmd ".timeout $SQLITE_BUSY_MS" "$DB_FILE" "ALTER TABLE run_guard ADD COLUMN $column $definition;"
  fi
}

ensure_table_column() {
  local table="$1" column="$2" definition="$3"
  if ! sqlite3 "$DB_FILE" "PRAGMA table_info($table);" | awk -F'|' -v column="$column" '$2==column{found=1} END{exit !found}'; then
    sqlite3 -cmd ".timeout $SQLITE_BUSY_MS" "$DB_FILE" "ALTER TABLE $table ADD COLUMN $column $definition;"
  fi
}

runtime_setting_key() {
  case "$1" in
    curl_connect_timeout) echo RUNTIME_CURL_CONNECT_TIMEOUT ;;
    curl_max_time) echo RUNTIME_CURL_MAX_TIME ;;
    max_parallel) echo RUNTIME_MAX_PARALLEL ;;
    catchup_minutes) echo RUNTIME_CATCHUP_MINUTES ;;
    jitter_max) echo RUNTIME_JITTER_MAX ;;
    sqlite_busy_ms) echo RUNTIME_SQLITE_BUSY_MS ;;
    schedule_max_attempts) echo RUNTIME_SCHEDULE_MAX_ATTEMPTS ;;
    claim_lease_seconds) echo RUNTIME_CLAIM_LEASE_SECONDS ;;
    run_guard_retention_days) echo RUNTIME_RUN_GUARD_RETENTION_DAYS ;;
    log_max_bytes) echo RUNTIME_LOG_MAX_BYTES ;;
    log_max_files) echo RUNTIME_LOG_MAX_FILES ;;
    *) return 1 ;;
  esac
}

runtime_setting_bounds() {
  case "$1" in
    curl_connect_timeout | curl_max_time) echo "1 120" ;;
    max_parallel) echo "1 16" ;;
    catchup_minutes) echo "1 60" ;;
    jitter_max) echo "0 30" ;;
    sqlite_busy_ms) echo "100 60000" ;;
    schedule_max_attempts) echo "1 10" ;;
    claim_lease_seconds) echo "30 600" ;;
    run_guard_retention_days) echo "1 3650" ;;
    log_max_bytes) echo "1024 1073741824" ;;
    log_max_files) echo "1 100" ;;
    *) return 1 ;;
  esac
}

runtime_setting_default() {
  case "$1" in
    curl_connect_timeout) echo 5 ;;
    curl_max_time) echo 15 ;;
    max_parallel) echo 4 ;;
    catchup_minutes) echo 5 ;;
    jitter_max) echo 0 ;;
    sqlite_busy_ms) echo 5000 ;;
    schedule_max_attempts) echo 3 ;;
    claim_lease_seconds) echo 120 ;;
    run_guard_retention_days) echo 30 ;;
    log_max_bytes) echo 1048576 ;;
    log_max_files) echo 5 ;;
    *) return 1 ;;
  esac
}

runtime_setting_env() {
  case "$1" in
    curl_connect_timeout) echo WOFFY_CURL_CONNECT_TIMEOUT ;;
    curl_max_time) echo WOFFY_CURL_MAX_TIME ;;
    max_parallel) echo WOFFY_MAX_PARALLEL ;;
    catchup_minutes) echo WOFFY_CATCHUP_MINUTES ;;
    jitter_max) echo WOFFY_JITTER_MAX ;;
    sqlite_busy_ms) echo WOFFY_SQLITE_BUSY_MS ;;
    schedule_max_attempts) echo WOFFY_SCHEDULE_MAX_ATTEMPTS ;;
    claim_lease_seconds) echo WOFFY_CLAIM_LEASE_SECONDS ;;
    run_guard_retention_days) echo WOFFY_RUN_GUARD_RETENTION_DAYS ;;
    log_max_bytes) echo WOFFY_LOG_MAX_BYTES ;;
    log_max_files) echo WOFFY_LOG_MAX_FILES ;;
    *) return 1 ;;
  esac
}

runtime_setting_assign() {
  local name="$1" value="$2"
  case "$name" in
    curl_connect_timeout) CURL_CONNECT_TIMEOUT="$value" ;;
    curl_max_time) CURL_MAX_TIME="$value" ;;
    max_parallel) MAX_PARALLEL="$value" ;;
    catchup_minutes) CATCHUP_MINUTES="$value" ;;
    jitter_max) JITTER_MAX="$value" ;;
    sqlite_busy_ms) SQLITE_BUSY_MS="$value" ;;
    schedule_max_attempts) SCHEDULE_MAX_ATTEMPTS="$value" ;;
    claim_lease_seconds) CLAIM_LEASE_SECONDS="$value" ;;
    run_guard_retention_days) RUN_GUARD_RETENTION_DAYS="$value" ;;
    log_max_bytes) LOG_MAX_BYTES="$value" ;;
    log_max_files) LOG_MAX_FILES="$value" ;;
    *) return 1 ;;
  esac
}

runtime_config_names() {
  echo "curl_connect_timeout curl_max_time max_parallel catchup_minutes jitter_max sqlite_busy_ms schedule_max_attempts claim_lease_seconds run_guard_retention_days log_max_bytes log_max_files"
}

load_persisted_runtime_config() {
  local name key env_name value
  [ -f "$DB_FILE" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  sqlite3 "$DB_FILE" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings';" 2>/dev/null | grep -q 1 || return 0
  for name in $(runtime_config_names); do
    env_name="$(runtime_setting_env "$name")"
    eval "value=\${$env_name-}"
    [ -n "$value" ] && continue
    key="$(runtime_setting_key "$name")"
    value="$(sqlite3 "$DB_FILE" "SELECT value FROM settings WHERE key='$key' LIMIT 1;" 2>/dev/null || true)"
    [ -n "$value" ] && runtime_setting_assign "$name" "$value"
  done
  return 0
}

runtime_config_value() {
  case "$1" in
    curl_connect_timeout) echo "$CURL_CONNECT_TIMEOUT" ;;
    curl_max_time) echo "$CURL_MAX_TIME" ;;
    max_parallel) echo "$MAX_PARALLEL" ;;
    catchup_minutes) echo "$CATCHUP_MINUTES" ;;
    jitter_max) echo "$JITTER_MAX" ;;
    sqlite_busy_ms) echo "$SQLITE_BUSY_MS" ;;
    schedule_max_attempts) echo "$SCHEDULE_MAX_ATTEMPTS" ;;
    claim_lease_seconds) echo "$CLAIM_LEASE_SECONDS" ;;
    run_guard_retention_days) echo "$RUN_GUARD_RETENTION_DAYS" ;;
    log_max_bytes) echo "$LOG_MAX_BYTES" ;;
    log_max_files) echo "$LOG_MAX_FILES" ;;
    *) return 1 ;;
  esac
}

runtime_config_validate_value() {
  local name="$1" value="$2" bounds min max
  bounds="$(runtime_setting_bounds "$name")" || return 1
  read -r min max <<<"$bounds"
  is_int "$value" && [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]
}

runtime_config_set() {
  local name="$1" value="$2" key
  runtime_config_validate_value "$name" "$value" || {
    echo "ERROR Invalid runtime setting '$name' or value '$value'" >&2
    return 1
  }
  key="$(runtime_setting_key "$name")"
  settings_set "$key" "$value"
  runtime_setting_assign "$name" "$value"
}

runtime_config_reset() {
  local name="$1" key
  key="$(runtime_setting_key "$name")" || return 1
  db_init
  db_exec "DELETE FROM settings WHERE key=$(sql_quote "$key");"
}

settings_get() {
  db_init
  db_exec "SELECT value FROM settings WHERE key=$(sql_quote "$1") LIMIT 1;"
}

settings_set() {
  db_init
  db_exec "INSERT INTO settings(key,value) VALUES($(sql_quote "$1"),$(sql_quote "$2"))
           ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
}

load_telegram_settings() {
  TG_TOKEN="$(settings_get TG_TOKEN 2>/dev/null || true)"
  TG_CHAT_ID="$(settings_get TG_CHAT_ID 2>/dev/null || true)"
  TG_THREAD="$(settings_get TG_THREAD 2>/dev/null || true)"
  TG_NOTIFY="$(settings_get TG_NOTIFY 2>/dev/null || true)"
  TG_NOTIFY="${TG_NOTIFY:-all}"
}

tg_send() {
  [ "$NO_TELEGRAM" = "true" ] && return 0
  load_telegram_settings
  [ -z "${TG_TOKEN:-}" ] && return 2
  [ -z "${TG_CHAT_ID:-}" ] && return 2

  local type="$1"
  local msg="$2"
  local force="${3:-false}"

  if [ "$force" != "true" ]; then
    case "${TG_NOTIFY:-all}" in
      all) ;;
      errors) [ "$type" != "error" ] && return 0 ;;
      success) [ "$type" != "success" ] && return 0 ;;
      *) ;;
    esac
  fi

  local curl_args
  curl_args=(-fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" --data-urlencode "text=$msg")
  if [ -n "${TG_THREAD:-}" ]; then
    [[ "$TG_THREAD" =~ ^-?[0-9]+$ ]] || {
      log "Invalid TG_THREAD. It must be numeric."
      return 0
    }
    curl_args+=(-d "message_thread_id=$TG_THREAD")
  fi
  curl "${curl_args[@]}" >/dev/null || {
    log "Error sending Telegram message"
    return 1
  }
}

get_bin_path() { command -v woffy 2>/dev/null || true; }

get_script_path() {
  local source="${BASH_SOURCE[0]}"
  while [ -h "$source" ]; do
    local dir
    dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    [[ $source != /* ]] && source="$dir/$source"
  done
  echo "$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)/$(basename "$source")"
}

acquire_lock() {
  ensure_home
  case "$LOCK_DIR" in
    "" | / | "$HOME")
      echo "ERROR Unsafe lock directory: $LOCK_DIR" >&2
      exit 1
      ;;
  esac
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" >"$LOCK_DIR/pid"
    trap release_lock EXIT
    return 0
  fi

  local dir_pid
  dir_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
  if [ -n "$dir_pid" ] && kill -0 "$dir_pid" 2>/dev/null; then
    log "Active lock (PID $dir_pid). Skipping concurrent run."
    exit 0
  fi

  [ -f "$LOCK_DIR/pid" ] && rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || {
    log "Unsafe or non-empty stale lock directory: $LOCK_DIR"
    exit 1
  }
  mkdir "$LOCK_DIR" 2>/dev/null || {
    log "Could not acquire lock."
    exit 1
  }
  echo "$$" >"$LOCK_DIR/pid"
  trap release_lock EXIT
}

release_lock() {
  if [ -n "${RUN_DUE_TMP:-}" ] && [ -f "$RUN_DUE_TMP" ]; then
    rm -f "$RUN_DUE_TMP"
  fi
  [ -f "$LOCK_DIR/pid" ] && rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

fmt_epoch() {
  local epoch="$1"
  if date -d "@$epoch" "+%Y-%m-%d %H:%M" >/dev/null 2>&1; then
    date -d "@$epoch" "+%Y-%m-%d %H:%M"
  else
    date -r "$epoch" "+%Y-%m-%d %H:%M"
  fi
}

is_valid_date() {
  local input="$1" normalized
  [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  if normalized="$(date -d "$input" '+%Y-%m-%d' 2>/dev/null)"; then
    [ "$normalized" = "$input" ]
    return
  fi
  normalized="$(date -j -f '%Y-%m-%d' "$input" '+%Y-%m-%d' 2>/dev/null || true)"
  [ "$normalized" = "$input" ]
}

validate_time() {
  [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

validate_action() {
  [ "$1" = "in" ] || [ "$1" = "out" ]
}

validate_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_weekdays() {
  [[ "$1" =~ ^[1-7](,[1-7])*$ ]]
}

date_to_boundary() {
  local day="$1"
  local mode="${2:-start}"
  if [ "$mode" = "end" ]; then
    echo "$day 23:59:59"
  else
    echo "$day 00:00:00"
  fi
}

current_week_start_date() {
  local dow offset
  dow="$(date '+%u' 2>/dev/null || echo 1)"
  offset=$((dow - 1))
  if [ "$offset" -eq 0 ]; then
    date "+%Y-%m-%d"
  elif date -d "today -$offset days" "+%Y-%m-%d" >/dev/null 2>&1; then
    date -d "today -$offset days" "+%Y-%m-%d"
  else
    date -v-"$offset"d "+%Y-%m-%d"
  fi
}

user_exists_active() {
  local email="$1"
  local count
  db_init
  count="$(db_exec "SELECT COUNT(*) FROM users WHERE email=$(sql_quote "$email") AND active=1;")"
  [ "$count" = "1" ]
}

user_exists() {
  local email="$1"
  local count
  db_init
  count="$(db_exec "SELECT COUNT(*) FROM users WHERE email=$(sql_quote "$email");")"
  [ "$count" = "1" ]
}

user_password() {
  db_init
  db_exec "SELECT password FROM users WHERE email=$(sql_quote "$1") LIMIT 1;"
}

user_full_name() {
  db_init
  db_exec "SELECT COALESCE(full_name,'') FROM user_cards WHERE email=$(sql_quote "$1") LIMIT 1;"
}

record_event() {
  local email="$1"
  local action="$2"
  local kind="$3"
  local status="$4"
  local message="$5"
  db_init
  db_exec "INSERT INTO events(email,action,kind,status,message,created_at,request_id)
           VALUES($(sql_quote "$email"),$(sql_quote "$action"),$(sql_quote "$kind"),$(sql_quote "$status"),$(sql_quote "$message"),datetime('now','localtime'),$(sql_quote "$REQUEST_ID"));"
  log "$email | $action | $status | $message"
}

seed_default_schedule() {
  local email="$1"
  db_init
  db_exec "INSERT OR IGNORE INTO schedules(email, action, time_hhmm, weekdays) VALUES
           ($(sql_quote "$email"), 'in', '09:00', '1,2,3,4,5'),
           ($(sql_quote "$email"), 'in', '15:30', '1,2,3,4,5'),
           ($(sql_quote "$email"), 'out', '14:00', '1,2,3,4,5'),
           ($(sql_quote "$email"), 'out', '18:00', '1,2,3,4,5');"
}

print_users() {
  db_init
  db_exec "SELECT users.email || char(9) || COALESCE(user_cards.full_name,'') || char(9) || CASE users.active WHEN 1 THEN 'active' ELSE 'inactive' END || char(9) ||
                  COALESCE((SELECT MAX(created_at) FROM events WHERE events.email=users.email AND kind='sign'),'') || char(9) ||
                  COALESCE((SELECT MAX(created_at) FROM events WHERE events.email=users.email AND status='error'),'')
           FROM users LEFT JOIN user_cards ON user_cards.email=users.email
           ORDER BY users.email;" |
    awk 'BEGIN{FS="\t"; printf "%-34s %-24s %-8s %-19s %s\n","EMAIL","NAME","STATUS","LAST_RUN","LAST_ERROR"} {printf "%-34s %-24s %-8s %-19s %s\n",$1,$2,$3,$4,$5}'
}

set_user_active() {
  local email="$1"
  local active="$2"
  user_exists "$email" || {
    echo "ERROR Unknown user: $email"
    exit 1
  }
  db_exec "UPDATE users SET active=$active, updated_at=datetime('now','localtime') WHERE email=$(sql_quote "$email");"
  if [ "$active" = "1" ]; then
    record_event "$email" "user" "admin" "success" "User enabled."
    echo "OK User enabled: $email"
  else
    record_event "$email" "user" "admin" "warning" "User disabled."
    echo "OK User disabled: $email"
  fi
}

delete_user() {
  local email="$1"
  user_exists "$email" || {
    echo "ERROR Unknown user: $email"
    exit 1
  }
  db_exec "DELETE FROM run_guard WHERE email=$(sql_quote "$email");
           DELETE FROM schedules WHERE email=$(sql_quote "$email");
           DELETE FROM tokens WHERE email=$(sql_quote "$email");
           DELETE FROM user_cards WHERE email=$(sql_quote "$email");
           DELETE FROM users WHERE email=$(sql_quote "$email");"
  record_event "$email" "user" "admin" "warning" "User deleted."
  echo "OK User deleted: $email"
}

print_user_schedule() {
  local email="$1"
  user_exists "$email" || {
    echo "ERROR Unknown user: $email"
    exit 1
  }
  db_exec "SELECT action || char(9) || time_hhmm || char(9) || weekdays || char(9) || CASE active WHEN 1 THEN 'active' ELSE 'inactive' END
           FROM schedules
           WHERE email=$(sql_quote "$email")
           ORDER BY action, time_hhmm;" |
    awk 'BEGIN{FS="\t"; printf "%-6s %-6s %-13s %s\n","ACTION","TIME","WEEKDAYS","STATUS"} {printf "%-6s %-6s %-13s %s\n",$1,$2,$3,$4}'
}

add_user_schedule() {
  local email="$1"
  local action="$2"
  local time="$3"
  local weekdays="${4:-1,2,3,4,5}"
  user_exists "$email" || {
    echo "ERROR Unknown user: $email"
    exit 1
  }
  validate_action "$action" || {
    echo "ERROR Invalid action: $action"
    exit 1
  }
  validate_time "$time" || {
    echo "ERROR Invalid time: $time"
    exit 1
  }
  validate_weekdays "$weekdays" || {
    echo "ERROR Invalid weekdays: $weekdays"
    exit 1
  }
  db_exec "INSERT INTO schedules(email, action, time_hhmm, weekdays, active)
           VALUES($(sql_quote "$email"),$(sql_quote "$action"),$(sql_quote "$time"),$(sql_quote "$weekdays"),1)
           ON CONFLICT(email, action, time_hhmm) DO UPDATE SET weekdays=excluded.weekdays, active=1;"
  record_event "$email" "schedule" "admin" "success" "Schedule added: $action $time weekdays=$weekdays."
  echo "OK Schedule added for $email: $action $time ($weekdays)"
}

remove_user_schedule() {
  local email="$1"
  local action="$2"
  local time="$3"
  user_exists "$email" || {
    echo "ERROR Unknown user: $email"
    exit 1
  }
  validate_action "$action" || {
    echo "ERROR Invalid action: $action"
    exit 1
  }
  validate_time "$time" || {
    echo "ERROR Invalid time: $time"
    exit 1
  }
  db_exec "DELETE FROM schedules WHERE email=$(sql_quote "$email") AND action=$(sql_quote "$action") AND time_hhmm=$(sql_quote "$time");"
  record_event "$email" "schedule" "admin" "warning" "Schedule removed: $action $time."
  echo "OK Schedule removed for $email: $action $time"
}

set_user_schedule() {
  local email="$1"
  local action="$2"
  local times_csv="$3"
  local weekdays="${4:-1,2,3,4,5}"
  local time sql
  user_exists "$email" || {
    echo "ERROR Unknown user: $email"
    exit 1
  }
  validate_action "$action" || {
    echo "ERROR Invalid action: $action"
    exit 1
  }
  validate_weekdays "$weekdays" || {
    echo "ERROR Invalid weekdays: $weekdays"
    exit 1
  }
  IFS=',' read -ra TIMES <<<"$times_csv"
  [ "${#TIMES[@]}" -gt 0 ] || {
    echo "ERROR At least one schedule time is required"
    exit 1
  }
  for time in "${TIMES[@]}"; do
    validate_time "$time" || {
      echo "ERROR Invalid time: $time"
      exit 1
    }
  done
  sql="BEGIN IMMEDIATE; DELETE FROM schedules WHERE email=$(sql_quote "$email") AND action=$(sql_quote "$action");"
  for time in "${TIMES[@]}"; do
    sql="$sql INSERT INTO schedules(email, action, time_hhmm, weekdays, active)
         VALUES($(sql_quote "$email"),$(sql_quote "$action"),$(sql_quote "$time"),$(sql_quote "$weekdays"),1);"
  done
  db_exec "$sql COMMIT;"
  record_event "$email" "schedule" "admin" "success" "Schedule set: $action $times_csv weekdays=$weekdays."
  echo "OK Schedule set for $email: $action $times_csv ($weekdays)"
}

clear_user_schedule() {
  local email="$1"
  user_exists "$email" || {
    echo "ERROR Unknown user: $email"
    exit 1
  }
  db_exec "DELETE FROM schedules WHERE email=$(sql_quote "$email");"
  record_event "$email" "schedule" "admin" "warning" "All schedules cleared."
  echo "OK Schedules cleared for $email"
}

reset_default_schedule() {
  local email="$1"
  clear_user_schedule "$email" >/dev/null
  seed_default_schedule "$email"
  record_event "$email" "schedule" "admin" "success" "Default schedules restored."
  echo "OK Default schedules restored for $email"
}
