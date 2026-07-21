#!/bin/bash
set -euo pipefail

VERSION="3.1.0"

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
get_token() {
  local email="$1"
  local now token exp password response expires
  db_init
  user_exists_active "$email" || {
    echo "ERROR Unknown or inactive user: $email" >&2
    return 1
  }
  now="$(date +%s)"
  token="$(db_exec "SELECT COALESCE(token,'') FROM tokens WHERE email=$(sql_quote "$email") AND expires_at > $((now + 60)) LIMIT 1;")"
  if [ -n "$token" ]; then
    echo "$token"
    return 0
  fi

  password="$(user_password "$email")"
  log "Refreshing OAuth token for $email"
  response="$(printf '%s' "$password" | curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -X POST "$API_URL/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=$email" \
    --data-urlencode "password@-" || true)"

  token="$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null || echo "")"
  expires="$(echo "$response" | jq -r '.expires_in // 3600' 2>/dev/null || echo "3600")"

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    record_event "$email" "auth" "auth" "error" "Woffu authentication failed"
    echo "ERROR Could not authenticate $email with Woffu" >&2
    return 1
  fi

  is_int "$expires" || expires=3600
  exp=$((now + expires - 60))
  db_exec "INSERT INTO tokens(email, token, expires_at, updated_at)
           VALUES($(sql_quote "$email"),$(sql_quote "$token"),$exp,datetime('now','localtime'))
           ON CONFLICT(email) DO UPDATE SET token=excluded.token, expires_at=excluded.expires_at, updated_at=excluded.updated_at;"
  echo "$token"
}

api_get_raw() {
  local path="$1"
  [ -z "${TOKEN:-}" ] && return 1
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" --config - "$API_URL$path"
}

get_status() {
  local body signin
  if ! body="$(api_get_raw "/api/signs" 2>/dev/null)"; then
    echo "unknown"
    return 0
  fi

  if ! echo "$body" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "unknown"
    return 0
  fi

  signin="$(
    echo "$body" | jq -r '
      map(select(
        (.Deleted // false) == false
        and (.SignType == 0)
        and (.SignIn == true or .SignIn == false)
      ))
      | sort_by(.TrueDate // .Date)
      | if length == 0 then "out" else last.SignIn end
    '
  )"

  case "$signin" in
    true | 1 | in) echo "in" ;;
    false | 0 | out) echo "out" ;;
    *) echo "unknown" ;;
  esac
}

post_sign() {
  local action="$1"
  local now json_data resp status_code body
  now="$(date -Iseconds)"
  json_data="$(jq -nc --arg date "$now" --arg action "$action" '{signType:0, date:$date, action:$action}')"
  resp="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" --config - -w "\n%{http_code}" -X POST "$API_URL/api/signs" \
    -H "Content-Type: application/json" \
    -d "$json_data" || true)"
  status_code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"
  if [[ "$status_code" =~ ^2 ]]; then
    return 0
  fi
  log "API sign error ($action): HTTP $status_code | $body"
  case "$status_code" in
    000 | 408 | 429 | 5?? | "") return 1 ;;
    401) return 3 ;;
    4??) return 2 ;;
    *) return 1 ;;
  esac
}

integration_get_token() {
  local now token client_id client_secret response expires exp
  db_init
  now="$(date +%s)"
  token="$(db_exec "SELECT COALESCE(token,'') FROM integration_tokens WHERE provider='woffu' AND expires_at > $((now + 60)) LIMIT 1;")"
  if [ -n "$token" ]; then
    echo "$token"
    return 0
  fi
  client_id="$(db_exec "SELECT client_id FROM integration_credentials WHERE provider='woffu' LIMIT 1;")"
  client_secret="$(db_exec "SELECT client_secret FROM integration_credentials WHERE provider='woffu' LIMIT 1;")"
  if ! { [ -n "$client_id" ] && [ -n "$client_secret" ]; }; then
    echo "ERROR Woffu integration is not configured" >&2
    return 1
  fi
  response="$(printf '%s' "$client_secret" | curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -X POST "$API_URL/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=$client_id" \
    --data-urlencode "client_secret@-" || true)"
  token="$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null || true)"
  expires="$(echo "$response" | jq -r '.expires_in // 3600' 2>/dev/null || echo 3600)"
  [ -n "$token" ] || {
    echo "ERROR Could not authenticate the Woffu integration" >&2
    return 1
  }
  is_int "$expires" || expires=3600
  exp=$((now + expires - 60))
  db_exec "INSERT INTO integration_tokens(provider,token,expires_at,updated_at)
           VALUES('woffu',$(sql_quote "$token"),$exp,datetime('now','localtime'))
           ON CONFLICT(provider) DO UPDATE SET token=excluded.token,expires_at=excluded.expires_at,updated_at=excluded.updated_at;"
  echo "$token"
}

backfill_sign_official() {
  local email="$1" mode="$2" datetime="$3" api_token uid signin payload response status_code body
  uid="$(db_exec "SELECT COALESCE(woffu_user_id,'') FROM user_cards WHERE email=$(sql_quote "$email") LIMIT 1;")"
  is_int "$uid" || {
    echo "ERROR No numeric Woffu UserId cached for $email; run login first" >&2
    return 1
  }
  api_token="$(integration_get_token)" || return 1
  signin=true
  [ "$mode" = "out" ] && signin=false
  payload="$(jq -nc --argjson uid "$uid" --arg date "$datetime" --argjson signin "$signin" '{UserId:$uid,Date:$date,SignIn:$signin}')"
  response="$(printf 'header = "Authorization: Bearer %s"\n' "$api_token" | curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" --config - -w "\n%{http_code}" -X POST "$API_URL/api/v1/signs" -H "Content-Type: application/json" -d "$payload" || true)"
  status_code="$(echo "$response" | tail -n1)"
  body="$(echo "$response" | sed '$d')"
  if [[ "$status_code" =~ ^2 ]]; then
    return 0
  fi
  log "Official backfill error ($email $mode $datetime): HTTP $status_code | $body"
  echo "ERROR Woffu API rejected the backdated sign (HTTP $status_code)" >&2
  return 1
}

save_user_card_db() {
  local login_email="$1"
  local uj="$2"
  local obj uid full cname office sched
  obj="$(echo "$uj" | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")"
  [ -z "$obj" ] && return 1
  uid="$(echo "$obj" | jq -r '.UserId // empty')"
  full="$(echo "$obj" | jq -r '.FullName // empty')"
  cname="$(echo "$obj" | jq -r '.CompanyName // empty')"
  office="$(echo "$obj" | jq -r '.OfficeName // empty')"
  sched="$(echo "$obj" | jq -r '.Schedule.Name // .ScheduleName // empty')"
  db_exec "INSERT INTO user_cards(email, woffu_user_id, full_name, company_name, office_name, schedule_name, raw_json, fetched_at)
           VALUES($(sql_quote "$login_email"),$(sql_quote "$uid"),$(sql_quote "$full"),$(sql_quote "$cname"),$(sql_quote "$office"),$(sql_quote "$sched"),$(sql_quote "$obj"),datetime('now','localtime'))
           ON CONFLICT(email) DO UPDATE SET
             woffu_user_id=excluded.woffu_user_id,
             full_name=excluded.full_name,
             company_name=excluded.company_name,
             office_name=excluded.office_name,
             schedule_name=excluded.schedule_name,
             raw_json=excluded.raw_json,
             fetched_at=excluded.fetched_at;"
}

get_user_id() {
  local email="$1"
  local uid uj
  uid="$(db_exec "SELECT COALESCE(woffu_user_id,'') FROM user_cards WHERE email=$(sql_quote "$email") LIMIT 1;")"
  if [ -n "$uid" ]; then
    echo "$uid"
    return 0
  fi
  uj="$(api_get_raw "/api/users")"
  echo "$uj" | jq -r 'if type=="array" then .[0].UserId else .UserId end // empty' 2>/dev/null || true
}

get_workday() {
  local email="$1"
  local uid
  uid="$(get_user_id "$email")"
  [ -z "$uid" ] && return 0
  api_get_raw "/api/users/$uid/workdaylite"
}

workday_reason() {
  local wd="$1"
  local sh iw ih ie
  sh="$(echo "$wd" | jq -r '.ScheduleHours // 0' 2>/dev/null || echo "0")"
  iw="$(echo "$wd" | jq -r '.IsWeekend // false' 2>/dev/null || echo "false")"
  ih="$(echo "$wd" | jq -r '.IsHoliday // false' 2>/dev/null || echo "false")"
  ie="$(echo "$wd" | jq -r '.IsEvent // false' 2>/dev/null || echo "false")"
  if [ "$ih" = "true" ]; then
    echo "holiday/vacation"
  elif [ "$ie" = "true" ]; then
    echo "event/absence"
  elif [ "$iw" = "true" ]; then
    echo "weekend"
  elif awk "BEGIN{exit !($sh<=0)}"; then
    echo "no scheduled hours"
  else echo ""; fi
}

is_workday_ok_for_in() {
  local wd="$1"
  local sh
  [ -z "$wd" ] && return 0
  sh="$(echo "$wd" | jq -r '.ScheduleHours // 0' 2>/dev/null || echo "0")"
  awk "BEGIN{exit !($sh>0)}"
}

notify_user_result() {
  local type="$1"
  local email="$2"
  local msg="$3"
  local name label
  name="$(user_full_name "$email")"
  label="$email"
  [ -n "$name" ] && label="$name <$email>"
  tg_send "$type" "woffy: $label: $msg" || true
}

run_sign_flow() {
  local email="$1"
  local mode="$2"
  local dry_run="${3:-false}"
  local quiet="${4:-false}"
  local max_retries="${5:-3}"
  local send_notifications="${6:-true}"
  local st wd reason action msg attempt retry_delay rc auth_refreshed=false

  SIGN_FLOW_RESULT="retryable"

  user_exists_active "$email" || {
    echo "ERROR Unknown or inactive user: $email"
    SIGN_FLOW_RESULT="terminal"
    return 65
  }

  if [ "$JITTER_MAX" -gt 0 ]; then
    sleep "$((RANDOM % (JITTER_MAX + 1)))"
  fi
  if ! TOKEN="$(get_token "$email")"; then
    [ "$quiet" = "true" ] || echo "ERROR $email: authentication failed."
    [ "$send_notifications" = "true" ] && notify_user_result error "$email" "Authentication failed."
    return 75
  fi
  st="$(get_status)"
  log "$email | requested=$mode | status=$st | dry_run=$dry_run"

  if [ "$st" = "unknown" ]; then
    msg="Cannot determine current status. Aborting."
    [ "$quiet" = "true" ] || echo "WARN $email: $msg"
    record_event "$email" "$mode" "sign" "error" "$msg"
    [ "$send_notifications" = "true" ] && notify_user_result error "$email" "$msg"
    return 75
  fi

  if [ "$mode" = "in" ] && [ "$st" = "in" ]; then
    msg="Already clocked in."
    [ "$quiet" = "true" ] || echo "WARN $email: $msg"
    record_event "$email" "$mode" "sign" "warning" "$msg"
    [ "$send_notifications" = "true" ] && notify_user_result error "$email" "$msg"
    SIGN_FLOW_RESULT="skipped"
    return 0
  fi

  if [ "$mode" = "out" ] && [ "$st" = "out" ]; then
    msg="Already clocked out."
    [ "$quiet" = "true" ] || echo "WARN $email: $msg"
    record_event "$email" "$mode" "sign" "warning" "$msg"
    [ "$send_notifications" = "true" ] && notify_user_result error "$email" "$msg"
    SIGN_FLOW_RESULT="skipped"
    return 0
  fi

  if [ "$mode" = "in" ]; then
    wd="$(get_workday "$email" || true)"
    if [ -z "$wd" ] || ! echo "$wd" | jq -e 'type=="object" and has("ScheduleHours")' >/dev/null 2>&1; then
      msg="Cannot verify workday. Aborting."
      [ "$quiet" = "true" ] || echo "WARN $email: $msg"
      record_event "$email" "$mode" "sign" "error" "$msg"
      [ "$send_notifications" = "true" ] && notify_user_result error "$email" "$msg"
      return 75
    fi
    if ! is_workday_ok_for_in "$wd"; then
      reason="$(workday_reason "$wd")"
      [ -z "$reason" ] && reason="non-working day"
      msg="Clock-in skipped: $reason."
      [ "$quiet" = "true" ] || echo "WARN $email: $msg"
      record_event "$email" "$mode" "sign" "warning" "$msg"
      [ "$send_notifications" = "true" ] && notify_user_result error "$email" "$msg"
      SIGN_FLOW_RESULT="skipped"
      return 0
    fi
  fi

  if [ "$dry_run" = "true" ]; then
    msg="DRY-RUN would clock $mode now."
    [ "$quiet" = "true" ] || echo "INFO $email: $msg"
    record_event "$email" "$mode" "sign" "dry-run" "$msg"
    SIGN_FLOW_RESULT="skipped"
    return 0
  fi

  action="clock_in"
  [ "$mode" = "out" ] && action="clock_out"
  attempt=1
  retry_delay=2

  while [ "$attempt" -le "$max_retries" ]; do
    if post_sign "$action"; then
      msg="Clock $mode completed."
      [ "$quiet" = "true" ] || echo "OK $email: $msg"
      record_event "$email" "$mode" "sign" "success" "$msg"
      [ "$send_notifications" = "true" ] && notify_user_result success "$email" "$msg"
      SIGN_FLOW_RESULT="success"
      return 0
    else
      rc=$?
    fi
    if [ "$rc" -eq 3 ] && [ "$auth_refreshed" = "false" ]; then
      auth_refreshed=true
      db_exec "DELETE FROM tokens WHERE email=$(sql_quote "$email");"
      if TOKEN="$(get_token "$email")"; then
        continue
      fi
      rc=1
    fi
    if [ "$rc" -eq 2 ]; then
      msg="Clock $mode rejected by Woffu."
      [ "$quiet" = "true" ] || echo "ERROR $email: $msg"
      record_event "$email" "$mode" "sign" "error" "$msg"
      [ "$send_notifications" = "true" ] && notify_user_result error "$email" "$msg"
      SIGN_FLOW_RESULT="terminal"
      return 65
    fi
    [ "$attempt" -lt "$max_retries" ] && sleep "$retry_delay"
    retry_delay=$((retry_delay * 2))
    attempt=$((attempt + 1))
  done

  msg="Clock $mode failed after $max_retries attempts."
  [ "$quiet" = "true" ] || echo "ERROR $email: $msg"
  record_event "$email" "$mode" "sign" "error" "$msg"
  [ "$send_notifications" = "true" ] && notify_user_result error "$email" "$msg"
  return 75
}
minute_ago_parts() {
  local minutes="$1"
  if date -d "-$minutes minutes" '+%Y-%m-%d|%H:%M|%u' 2>/dev/null; then
    return 0
  fi
  date -v-"${minutes}"M '+%Y-%m-%d|%H:%M|%u'
}

claim_schedule_slot() {
  local email="$1" action="$2" day="$3" time="$4"
  db_exec "INSERT INTO run_guard(email,action,run_date,time_hhmm,state,attempts,claimed_at,updated_at)
           VALUES($(sql_quote "$email"),$(sql_quote "$action"),$(sql_quote "$day"),$(sql_quote "$time"),'claimed',1,datetime('now','localtime'),datetime('now','localtime'))
           ON CONFLICT(email,action,run_date,time_hhmm) DO UPDATE SET
             state='claimed', attempts=run_guard.attempts+1,
             claimed_at=datetime('now','localtime'), next_retry_at=NULL, last_error=NULL,
             updated_at=datetime('now','localtime')
           WHERE (run_guard.state='retryable' AND run_guard.attempts < $SCHEDULE_MAX_ATTEMPTS
                  AND COALESCE(run_guard.next_retry_at,'') <= datetime('now','localtime'))
              OR (run_guard.state='claimed'
                  AND run_guard.claimed_at < datetime('now','localtime','-$CLAIM_LEASE_SECONDS seconds'));
           SELECT changes();"
}

process_scheduled_user() {
  local email="$1" slots_file="$2"
  local day time row_email action claimed attempts rc failures=0 error_message
  while IFS=$'\t' read -r day time row_email action; do
    [ "$row_email" = "$email" ] || continue
    claimed="$(claim_schedule_slot "$email" "$action" "$day" "$time")"
    [ "$claimed" = "1" ] || continue
    attempts="$(db_exec "SELECT attempts FROM run_guard WHERE email=$(sql_quote "$email") AND action=$(sql_quote "$action") AND run_date=$(sql_quote "$day") AND time_hhmm=$(sql_quote "$time");")"

    if run_sign_flow "$email" "$action" false "$QUIET" 1 false; then
      rc=0
    else
      rc=$?
    fi
    case "$SIGN_FLOW_RESULT" in
      success | skipped)
        db_exec "UPDATE run_guard SET state=$(sql_quote "$SIGN_FLOW_RESULT"),updated_at=datetime('now','localtime')
                 WHERE email=$(sql_quote "$email") AND action=$(sql_quote "$action") AND run_date=$(sql_quote "$day") AND time_hhmm=$(sql_quote "$time");"
        if [ "${attempts:-1}" -gt 1 ]; then
          notify_user_result success "$email" "Recovered scheduled $action at $time after $attempts attempts."
        fi
        ;;
      terminal)
        error_message="Permanent Woffu rejection for scheduled $action at $time."
        db_exec "UPDATE run_guard SET state='failed',last_error=$(sql_quote "$error_message"),updated_at=datetime('now','localtime')
                 WHERE email=$(sql_quote "$email") AND action=$(sql_quote "$action") AND run_date=$(sql_quote "$day") AND time_hhmm=$(sql_quote "$time");"
        notify_user_result error "$email" "$error_message"
        failures=$((failures + 1))
        ;;
      *)
        error_message="Retryable failure for scheduled $action at $time."
        if [ "${attempts:-1}" -ge "$SCHEDULE_MAX_ATTEMPTS" ]; then
          db_exec "UPDATE run_guard SET state='failed',last_error=$(sql_quote "$error_message"),updated_at=datetime('now','localtime')
                   WHERE email=$(sql_quote "$email") AND action=$(sql_quote "$action") AND run_date=$(sql_quote "$day") AND time_hhmm=$(sql_quote "$time");"
          notify_user_result error "$email" "$error_message Attempts exhausted."
        else
          db_exec "UPDATE run_guard SET state='retryable',next_retry_at=datetime('now','localtime','+60 seconds'),last_error=$(sql_quote "$error_message"),updated_at=datetime('now','localtime')
                   WHERE email=$(sql_quote "$email") AND action=$(sql_quote "$action") AND run_date=$(sql_quote "$day") AND time_hhmm=$(sql_quote "$time");"
        fi
        failures=$((failures + 1))
        ;;
    esac
    : "$rc"
  done <"$slots_file"
  [ "$failures" -eq 0 ]
}

run_due() {
  local dry_run="${1:-false}" i parts day time dow rows email action slots_file
  local running failures=0 pid pids=()
  db_init
  acquire_lock
  slots_file="$(mktemp)"
  RUN_DUE_TMP="$slots_file"

  for ((i = CATCHUP_MINUTES - 1; i >= 0; i--)); do
    parts="$(minute_ago_parts "$i")" || continue
    IFS='|' read -r day time dow <<<"$parts"
    rows="$(db_exec "SELECT users.email || char(9) || schedules.action
                     FROM schedules JOIN users ON users.email=schedules.email
                     WHERE users.active=1 AND schedules.active=1
                       AND schedules.time_hhmm=$(sql_quote "$time")
                       AND instr(',' || schedules.weekdays || ',', ',' || $(sql_quote "$dow") || ',') > 0
                     ORDER BY users.email,schedules.action;")"
    while IFS=$'\t' read -r email action; do
      [ -n "$email" ] && printf '%s\t%s\t%s\t%s\n' "$day" "$time" "$email" "$action" >>"$slots_file"
    done <<<"$rows"
  done

  if [ ! -s "$slots_file" ]; then
    rm -f "$slots_file"
    RUN_DUE_TMP=""
    $QUIET || echo "No due users for the last $CATCHUP_MINUTES minute(s)."
    return 0
  fi
  if [ "$dry_run" = "true" ]; then
    awk -F'\t' '{printf "DRY-RUN %s %s %s %s\n",$1,$2,$3,$4}' "$slots_file"
    rm -f "$slots_file"
    RUN_DUE_TMP=""
    return 0
  fi

  while IFS= read -r email; do
    while :; do
      running="$(jobs -rp | wc -l | tr -d ' ')"
      [ "$running" -lt "$MAX_PARALLEL" ] && break
      sleep 0.2
    done
    process_scheduled_user "$email" "$slots_file" &
    pid=$!
    pids+=("$pid")
  done < <(awk -F'\t' '!seen[$3]++{print $3}' "$slots_file")

  for pid in "${pids[@]}"; do
    wait "$pid" || failures=$((failures + 1))
  done
  rm -f "$slots_file"
  RUN_DUE_TMP=""
  db_exec "DELETE FROM run_guard WHERE run_date < date('now','localtime','-$RUN_GUARD_RETENTION_DAYS days');" || true
  [ "$failures" -eq 0 ]
}
build_report_all() {
  local since="$1"
  local until="$2"
  local format="${3:-text}"
  local now counts in_count out_count warn_count err_count dry_count
  db_init
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  counts="$(db_exec "SELECT
      SUM(CASE WHEN action='in' AND status='success' THEN 1 ELSE 0 END),
      SUM(CASE WHEN action='out' AND status='success' THEN 1 ELSE 0 END),
      SUM(CASE WHEN status='warning' THEN 1 ELSE 0 END),
      SUM(CASE WHEN status='error' THEN 1 ELSE 0 END),
      SUM(CASE WHEN status='dry-run' THEN 1 ELSE 0 END)
    FROM events
    WHERE created_at >= $(sql_quote "$since") AND created_at <= $(sql_quote "$until");")"
  IFS='|' read -r in_count out_count warn_count err_count dry_count <<<"$counts"
  in_count="${in_count:-0}"
  out_count="${out_count:-0}"
  warn_count="${warn_count:-0}"
  err_count="${err_count:-0}"
  dry_count="${dry_count:-0}"

  case "$format" in
    json)
      cat <<EOF
{"generated_at":"$(json_escape "$now")","from":"$(json_escape "$since")","to":"$(json_escape "$until")","entries_in":${in_count:-0},"entries_out":${out_count:-0},"warnings":${warn_count:-0},"errors":${err_count:-0},"dry_runs":${dry_count:-0}}
EOF
      ;;
    csv)
      echo "generated_at,from,to,entries_in,entries_out,warnings,errors,dry_runs"
      echo "\"$now\",\"$since\",\"$until\",${in_count:-0},${out_count:-0},${warn_count:-0},${err_count:-0},${dry_count:-0}"
      ;;
    *)
      cat <<EOF
Woffy multi-user report
Period: $since -> $until
Generated: $now
Entries: ${in_count:-0}
Exits: ${out_count:-0}
Warnings: ${warn_count:-0}
Errors: ${err_count:-0}
Dry-runs: ${dry_count:-0}
EOF
      ;;
  esac
}

print_events() {
  local target="${1:-all}"
  local days="${2:-30}"
  local status_filter="${3:-all}"
  local format="${4:-text}"
  local limit="${5:-200}"
  local where email_clause status_clause
  db_init
  is_int "$days" || {
    echo "ERROR Invalid days: $days"
    exit 1
  }
  is_int "$limit" || {
    echo "ERROR Invalid limit: $limit"
    exit 1
  }
  email_clause=""
  if [ "$target" != "all" ]; then
    email_clause="AND email=$(sql_quote "$target")"
  fi
  status_clause=""
  if [ "$status_filter" != "all" ]; then
    status_clause="AND status=$(sql_quote "$status_filter")"
  fi
  where="created_at >= datetime('now','localtime','-${days} days') $email_clause $status_clause"

  case "$format" in
    json)
      check_deps jq
      db_exec "SELECT COALESCE(json_group_array(json_object(
                       'id',id,'created_at',created_at,'email',COALESCE(email,''),
                       'action',COALESCE(action,''),'kind',kind,'status',status,'message',message
                     )),json('[]'))
               FROM (SELECT * FROM events WHERE $where ORDER BY created_at DESC,id DESC LIMIT $limit);" |
        jq .
      ;;
    csv)
      sqlite3 -cmd ".timeout $SQLITE_BUSY_MS" -header -csv "$DB_FILE" \
        "SELECT id,created_at,COALESCE(email,'') AS email,COALESCE(action,'') AS action,kind,status,message
         FROM events WHERE $where ORDER BY created_at DESC,id DESC LIMIT $limit;"
      ;;
    text)
      db_exec "SELECT created_at || char(9) || COALESCE(email,'') || char(9) || COALESCE(action,'') || char(9) || kind || char(9) || status || char(9) || message
               FROM events
               WHERE $where
               ORDER BY created_at DESC, id DESC
               LIMIT $limit;" |
        awk 'BEGIN{FS="\t"; printf "%-19s %-34s %-8s %-8s %-8s %s\n","CREATED_AT","EMAIL","ACTION","KIND","STATUS","MESSAGE"} {printf "%-19s %-34s %-8s %-8s %-8s %s\n",$1,$2,$3,$4,$5,$6}'
      ;;
    *)
      echo "ERROR Invalid format: $format"
      exit 1
      ;;
  esac
}

purge_events() {
  local before="$1"
  is_valid_date "$before" || {
    echo "ERROR Invalid purge date: $before" >&2
    return 1
  }
  db_init
  db_exec "DELETE FROM events WHERE created_at < $(sql_quote "$before 00:00:00"); SELECT changes();"
}

backup_files() {
  local out="${1:-$HOME/woffy-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  local tmp
  ensure_home
  db_init
  acquire_lock
  tmp="$(mktemp -d)"
  sqlite3 -cmd ".timeout $SQLITE_BUSY_MS" "$DB_FILE" ".backup '$tmp/woffy.db'"
  [ -f "$LOG_FILE" ] && cp -p "$LOG_FILE" "$tmp/woffy.log"
  for rotated in "$LOG_FILE".[0-9]*; do
    [ -f "$rotated" ] && cp -p "$rotated" "$tmp/$(basename "$rotated")"
  done
  printf 'woffy_backup_version=3\ncreated_at=%s\n' "$(date -Iseconds)" >"$tmp/manifest"
  tar -czf "$out" -C "$tmp" . >/dev/null 2>&1
  rm -rf "$tmp"
  echo "$out"
}

restore_files() {
  local in="$1"
  local tmp backup_db
  [ -f "$in" ] || return 1
  if tar -tzf "$in" | awk 'BEGIN{bad=0} /^\//{bad=1} /(^|\/)\.\.($|\/)/{bad=1} END{exit bad?0:1}'; then
    echo "ERROR Unsafe backup paths detected" >&2
    return 1
  fi
  if tar -tvzf "$in" | awk '$1 ~ /^[lh]/{bad=1} END{exit bad?0:1}'; then
    echo "ERROR Backup links are not allowed" >&2
    return 1
  fi
  tmp="$(mktemp -d)"
  tar -xzf "$in" -C "$tmp" >/dev/null 2>&1 || {
    rm -rf "$tmp"
    return 1
  }
  [ -f "$tmp/woffy.db" ] || {
    rm -rf "$tmp"
    return 1
  }
  [ "$(sqlite3 "$tmp/woffy.db" 'PRAGMA integrity_check;' 2>/dev/null)" = "ok" ] || {
    rm -rf "$tmp"
    echo "ERROR Backup database integrity check failed" >&2
    return 1
  }
  ensure_home
  acquire_lock
  backup_db="$DB_FILE.pre-restore"
  [ -f "$DB_FILE" ] && cp -p "$DB_FILE" "$backup_db"
  mv "$tmp/woffy.db" "$DB_FILE"
  [ -f "$tmp/woffy.log" ] && cp -p "$tmp/woffy.log" "$LOG_FILE"
  rm -rf "$tmp"
  chmod 700 "$WOFFY_HOME" 2>/dev/null || true
  if [ -f "$DB_FILE" ]; then
    chmod 600 "$DB_FILE" 2>/dev/null || true
  fi
}

clear_woffy_cron() {
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v '# woffy-' >"$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
}

install_run_due_cron() {
  local tmp script_path escaped
  script_path="$(get_script_path)"
  escaped="$(printf '%q' "$script_path")"
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v '# woffy-run-due' >"$tmp" || true
  echo "* * * * * $escaped run due --quiet # woffy-run-due" >>"$tmp"
  crontab "$tmp"
  rm -f "$tmp"
}

show_changelog() {
  local remote_version commits
  remote_version="$(curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$REPO_RAW_BASE/woffy.sh" | awk -F\" '/^VERSION=/{print $2; exit}' 2>/dev/null || echo "unknown")"
  echo "Local:  v$VERSION"
  echo "Remote: v$remote_version"
  commits="$(curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "https://api.github.com/repos/ruvelro/woffy/commits?per_page=8" |
    jq -r '.[] | "- " + (.sha[0:7]) + " " + .commit.message' 2>/dev/null || true)"
  [ -n "$commits" ] && echo "$commits"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

semver_number() {
  local version="${1#v}" major minor patch
  version="${version%%-*}"
  IFS='.' read -r major minor patch <<<"$version"
  is_int "$major" && is_int "$minor" && is_int "$patch" || return 1
  echo $((major * 1000000 + minor * 1000 + patch))
}

perform_update() {
  local channel="$1" check_only="$2" allow_downgrade="$3"
  local asset_base version_url target_version current_number target_number
  local tmp checksum_tmp expected actual bin_path previous installed_version

  if [ -n "${WOFFY_UPDATE_BASE_URL:-}" ]; then
    asset_base="${WOFFY_UPDATE_BASE_URL%/}/$channel"
  elif [ "$channel" = "nightly" ]; then
    asset_base="$RELEASE_BASE/download/nightly"
  else
    asset_base="$RELEASE_BASE/latest/download"
  fi
  version_url="$asset_base/woffy.version"
  target_version="$(curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 30 "$version_url")" || {
    echo "ERROR Could not fetch update metadata" >&2
    return 1
  }
  target_version="${target_version#v}"
  target_number="$(semver_number "$target_version")" || {
    echo "ERROR Invalid release version: $target_version" >&2
    return 1
  }
  current_number="$(semver_number "$VERSION")"
  echo "Current: v$VERSION"
  echo "Available ($channel): v$target_version"
  [ "$check_only" = "true" ] && return 0
  if [ "$channel" != "nightly" ] && [ "$target_number" -eq "$current_number" ]; then
    echo "OK Already up to date."
    return 0
  fi
  if [ "$target_number" -lt "$current_number" ] && [ "$allow_downgrade" != "true" ]; then
    echo "ERROR Refusing downgrade to v$target_version (use --allow-downgrade)" >&2
    return 1
  fi

  tmp="$(mktemp)"
  checksum_tmp="$(mktemp)"
  curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 30 "$asset_base/woffy" -o "$tmp" || {
    rm -f "$tmp" "$checksum_tmp"
    echo "ERROR Could not download update" >&2
    return 1
  }
  curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 30 "$asset_base/woffy.sha256" -o "$checksum_tmp" || {
    rm -f "$tmp" "$checksum_tmp"
    echo "ERROR Could not download update checksum" >&2
    return 1
  }
  expected="$(awk 'NR==1{print $1}' "$checksum_tmp")"
  actual="$(sha256_file "$tmp")"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    rm -f "$tmp" "$checksum_tmp"
    echo "ERROR Update checksum mismatch" >&2
    return 1
  fi
  bash -n "$tmp" || {
    rm -f "$tmp" "$checksum_tmp"
    echo "ERROR Downloaded update failed syntax check" >&2
    return 1
  }
  chmod +x "$tmp"
  installed_version="$("$tmp" version 2>/dev/null | awk '/^woffy v/{sub(/^woffy v/,""); print; exit}')"
  if [ "$installed_version" != "$target_version" ]; then
    rm -f "$tmp" "$checksum_tmp"
    echo "ERROR Update binary version does not match metadata" >&2
    return 1
  fi

  bin_path="$(get_bin_path)"
  [ -n "$bin_path" ] || {
    rm -f "$tmp" "$checksum_tmp"
    echo "ERROR Current woffy binary not found" >&2
    return 1
  }
  previous="$bin_path.previous"
  cp -p "$bin_path" "$previous"
  if ! mv "$tmp" "$bin_path"; then
    rm -f "$tmp" "$checksum_tmp"
    return 1
  fi
  rm -f "$checksum_tmp"
  installed_version="$("$bin_path" version 2>/dev/null || true)"
  if [ "$installed_version" != "woffy v$target_version" ] || [ "${WOFFY_TEST_UPDATE_POSTCHECK_FAIL:-false}" = "true" ]; then
    mv "$previous" "$bin_path"
    echo "ERROR Updated binary failed post-check; previous binary restored" >&2
    return 1
  fi
  echo "OK Woffy updated to v$target_version from '$channel'."
}

show_help() {
  cat <<EOF
woffy v$VERSION

Multi-user Woffu attendance automation for a centrally managed VPS.

Usage:
  woffy login <email> [<password>|--password-stdin]
  woffy users [enable|disable|delete <email>]
  woffy user <email>
  woffy status <email>
  woffy in <email>
  woffy out <email>
  woffy sign <email> {in|out} <YYYY-MM-DD> <HH:MM>
  woffy api {configure <company-id>|status|test|clear} [--secret-stdin]
  woffy dry-run {in|out} <email>
  woffy run due [--quiet] [--dry-run]
  woffy events {all|<email>} [--days N] [--status all|success|warning|error|dry-run] [--format text|json|csv] [--limit N]
  woffy report all [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--format text|json|csv] [telegram]
  woffy schedule install
  woffy schedule list
  woffy schedule clear
  woffy schedule user <email> list
  woffy schedule user <email> add {in|out} HH:MM [weekdays]
  woffy schedule user <email> set {in|out} HH:MM[,HH:MM...] [weekdays]
  woffy schedule user <email> remove {in|out} HH:MM
  woffy schedule user <email> clear
  woffy schedule user <email> defaults
  woffy telegram {configure --token-stdin <chat-id> [thread-id] [mode]|test|clear}
  woffy config {check|list|get|set|reset}
  woffy web {install|update|start|stop|restart|status|logs|passwd|serve|uninstall}
  woffy doctor [--json]
  woffy backup [path.tar.gz]
  woffy restore <path.tar.gz>
  woffy changelog
  woffy update [nightly] [--check] [--allow-downgrade]
  woffy version
  woffy help

State:
  Home: $WOFFY_HOME
  DB:   $DB_FILE
  Log:  $LOG_FILE

Notes:
  - SQLite is the source of truth for users, credentials, tokens, schedules and events.
  - New users receive default weekday schedules: in 09:00/15:30 and out 14:00/18:00.
  - Weekdays use ISO numbers: 1=Monday ... 7=Sunday.
  - Cron should call 'woffy run due --quiet' once per minute.
  - Scheduled slots use a catch-up window and run in parallel across workers,
    while each worker's actions remain serial.
  - Backdated signs require the official Woffu API integration.
EOF
}

doctor_json() {
  local sqlite_ok db_exists users_count cron_installed tg_enabled api_enabled schema_version journal_mode sqlite_version
  sqlite_ok=false
  command -v sqlite3 >/dev/null 2>&1 && sqlite_ok=true
  db_exists=false
  [ -f "$DB_FILE" ] && db_exists=true
  users_count=0
  schema_version=0
  journal_mode="unknown"
  sqlite_version=""
  if $sqlite_ok; then
    db_init
    users_count="$(db_exec "SELECT COUNT(*) FROM users;" 2>/dev/null || echo 0)"
    schema_version="$(db_exec "PRAGMA user_version;" 2>/dev/null || echo 0)"
    journal_mode="$(db_exec "PRAGMA journal_mode;" 2>/dev/null || echo unknown)"
    sqlite_version="$(sqlite3 --version | awk '{print $1}')"
  fi
  cron_installed=false
  crontab -l 2>/dev/null | grep -q '# woffy-run-due' && cron_installed=true
  tg_enabled=false
  if $sqlite_ok; then
    [ -n "$(settings_get TG_TOKEN 2>/dev/null || true)" ] && [ -n "$(settings_get TG_CHAT_ID 2>/dev/null || true)" ] && tg_enabled=true
  fi
  api_enabled=false
  if $sqlite_ok; then
    [ -n "$(db_exec "SELECT client_id FROM integration_credentials WHERE provider='woffu';" 2>/dev/null || true)" ] && api_enabled=true
  fi
  jq -nc \
    --arg version "$VERSION" --arg bin "$(get_bin_path)" --arg db "$DB_FILE" \
    --arg sqlite_version "$sqlite_version" --arg journal_mode "$journal_mode" \
    --argjson sqlite3 "$sqlite_ok" --argjson db_exists "$db_exists" --argjson users "${users_count:-0}" \
    --argjson schema_version "${schema_version:-0}" --argjson cron "$cron_installed" \
    --argjson telegram "$tg_enabled" --argjson api "$api_enabled" \
    --argjson max_parallel "$MAX_PARALLEL" --argjson catchup "$CATCHUP_MINUTES" \
    '{version:$version,bin:$bin,sqlite3:$sqlite3,sqlite_version:$sqlite_version,db:$db,
      db_exists:$db_exists,schema_version:$schema_version,journal_mode:$journal_mode,users:$users,
      cron_run_due:$cron,telegram:$telegram,woffu_api:$api,
      scheduler:{max_parallel:$max_parallel,catchup_minutes:$catchup}}'
  $sqlite_ok
}
WEB_INSTALL_ROOT="${WOFFY_WEB_INSTALL_DIR:-$HOME/.local/share/woffy-web}"
WEB_STATE_HOME="${WOFFY_WEB_HOME:-$WOFFY_HOME/web}"
WEB_SERVICE_DIR="${WOFFY_WEB_SERVICE_DIR:-$HOME/.config/systemd/user}"
WEB_SERVICE_FILE="$WEB_SERVICE_DIR/woffy-web.service"
WEB_PORT_DEFAULT="${WOFFY_WEB_PORT:-8787}"
WEB_RECOVERY_DIR="${WOFFY_WEB_RECOVERY_DIR:-$HOME/.local/state/woffy-backups}"

web_python() {
  local candidate
  for candidate in python3.13 python3.12 python3.11 python3; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import sys; raise SystemExit(0 if (3, 11) <= sys.version_info[:2] <= (3, 13) else 1)' >/dev/null 2>&1 || continue
    command -v "$candidate"
    return 0
  done
  echo "ERROR Woffy Web requires CPython 3.11, 3.12 or 3.13" >&2
  return 1
}

web_current_dir() {
  [ -L "$WEB_INSTALL_ROOT/current" ] || return 1
  (cd "$WEB_INSTALL_ROOT/current" 2>/dev/null && pwd -P)
}

web_write_service() {
  local current bin_path port
  current="$WEB_INSTALL_ROOT/current"
  bin_path="$(get_bin_path)"
  [ -n "$bin_path" ] || bin_path="$(get_script_path)"
  port="$1"
  mkdir -p "$WEB_SERVICE_DIR"
  mkdir -p "$WEB_RECOVERY_DIR"
  chmod 700 "$WEB_RECOVERY_DIR" 2>/dev/null || true
  chmod 700 "$WEB_SERVICE_DIR" 2>/dev/null || true
  {
    echo "[Unit]"
    echo "Description=Woffy local administrative panel"
    echo "After=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=simple"
    printf 'Environment=WOFFY_BIN=%q\n' "$bin_path"
    printf 'Environment=WOFFY_HOME=%q\n' "$WOFFY_HOME"
    printf 'Environment=WOFFY_WEB_HOME=%q\n' "$WEB_STATE_HOME"
    printf 'ExecStart=%q -m uvicorn woffy_web.app:app --app-dir %q --host 127.0.0.1 --port %s --no-server-header\n' "$current/venv/bin/python" "$current/app" "$port"
    echo "Restart=on-failure"
    echo "RestartSec=3"
    echo "UMask=0077"
    echo "NoNewPrivileges=true"
    echo "PrivateTmp=true"
    echo "ProtectSystem=strict"
    printf 'ReadWritePaths=%q\n' "$WOFFY_HOME"
    printf 'ReadWritePaths=%q\n' "$WEB_RECOVERY_DIR"
    echo ""
    echo "[Install]"
    echo "WantedBy=default.target"
  } >"$WEB_SERVICE_FILE"
  chmod 600 "$WEB_SERVICE_FILE"
}

web_verify_archive() {
  local archive="$1"
  if tar -tzf "$archive" | awk 'BEGIN{bad=0} /^\//{bad=1} /(^|\/)\.\.($|\/)/{bad=1} END{exit bad?0:1}'; then
    echo "ERROR Unsafe web artifact paths detected" >&2
    return 1
  fi
  if tar -tvzf "$archive" | awk '$1 ~ /^[lh]/{bad=1} END{exit bad?0:1}'; then
    echo "ERROR Web artifact links are not allowed" >&2
    return 1
  fi
}

web_install_release() {
  local channel="${1:-stable}" port="${2:-$WEB_PORT_DEFAULT}" password_stdin="${3:-false}"
  local python asset_base archive checksum expected actual staging release_id release_dir previous_target
  local artifact_version minimum_cli maximum_schema current_number minimum_number schema_version
  if ! { is_int "$port" && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; }; then
    echo "ERROR Web port must be between 1024 and 65535" >&2
    return 1
  fi
  if [ "$(uname -s)" != "Linux" ] || { [ "$(uname -m)" != "x86_64" ] && [ "$(uname -m)" != "amd64" ]; }; then
    echo "ERROR Woffy Web v3.1 artifacts currently support Linux x86_64 VPS hosts only" >&2
    return 1
  fi
  python="$(web_python)" || return 1
  check_deps tar curl jq sqlite3
  archive="$(mktemp)"
  checksum="$(mktemp)"
  staging="$(mktemp -d)"
  if [ -n "${WOFFY_WEB_ARTIFACT_DIR:-}" ]; then
    cp "$WOFFY_WEB_ARTIFACT_DIR/woffy-web.tar.gz" "$archive"
    cp "$WOFFY_WEB_ARTIFACT_DIR/woffy-web.sha256" "$checksum"
  else
    if [ -n "${WOFFY_WEB_BASE_URL:-}" ]; then
      asset_base="${WOFFY_WEB_BASE_URL%/}/$channel"
    elif [ "$channel" = "nightly" ]; then
      asset_base="$RELEASE_BASE/download/nightly"
    else
      asset_base="$RELEASE_BASE/latest/download"
    fi
    curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 120 "$asset_base/woffy-web.tar.gz" -o "$archive" || return 1
    curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 30 "$asset_base/woffy-web.sha256" -o "$checksum" || return 1
  fi
  expected="$(awk 'NR==1{print $1}' "$checksum")"
  actual="$(sha256_file "$archive")"
  if ! { [ -n "$expected" ] && [ "$expected" = "$actual" ]; }; then
    echo "ERROR Woffy Web checksum mismatch" >&2
    return 1
  fi
  web_verify_archive "$archive"
  tar -xzf "$archive" -C "$staging"
  if ! { [ -f "$staging/app/requirements.lock" ] && [ -d "$staging/app/woffy_web" ] && [ -d "$staging/wheelhouse" ]; }; then
    echo "ERROR Incomplete Woffy Web artifact" >&2
    return 1
  fi
  artifact_version="$(jq -r '.version // empty' "$staging/app/manifest.json" 2>/dev/null || true)"
  minimum_cli="$(jq -r '.minimum_cli_version // empty' "$staging/app/manifest.json" 2>/dev/null || true)"
  maximum_schema="$(jq -r '.maximum_schema_version // empty' "$staging/app/manifest.json" 2>/dev/null || true)"
  if ! semver_number "$artifact_version" >/dev/null || ! minimum_number="$(semver_number "$minimum_cli")"; then
    echo "ERROR Invalid Woffy Web compatibility manifest" >&2
    return 1
  fi
  current_number="$(semver_number "$VERSION")"
  if ! [ "$current_number" -ge "$minimum_number" ]; then
    echo "ERROR Woffy Web $artifact_version requires CLI $minimum_cli or newer" >&2
    return 1
  fi
  if ! is_int "$maximum_schema"; then
    echo "ERROR Invalid maximum schema in Woffy Web manifest" >&2
    return 1
  fi
  if [ -f "$DB_FILE" ]; then
    schema_version="$(sqlite3 "$DB_FILE" 'PRAGMA user_version;' 2>/dev/null || echo 0)"
    if ! { is_int "$schema_version" && [ "$schema_version" -le "$maximum_schema" ]; }; then
      echo "ERROR Woffy DB schema $schema_version is newer than the panel supports" >&2
      return 1
    fi
  fi
  "$python" -m venv "$staging/venv"
  "$staging/venv/bin/python" -m pip install --disable-pip-version-check --no-index --find-links "$staging/wheelhouse" -r "$staging/app/requirements.lock" >/dev/null
  PYTHONPATH="$staging/app" "$staging/venv/bin/python" -m py_compile "$staging/app"/woffy_web/*.py
  release_id="$artifact_version-$(date +%Y%m%d%H%M%S)"
  release_dir="$WEB_INSTALL_ROOT/releases/$release_id"
  mkdir -p "$WEB_INSTALL_ROOT/releases" "$WEB_STATE_HOME"
  chmod 700 "$WEB_INSTALL_ROOT" "$WEB_INSTALL_ROOT/releases" "$WEB_STATE_HOME" 2>/dev/null || true
  mv "$staging" "$release_dir"
  previous_target="$(web_current_dir 2>/dev/null || true)"
  [ -n "$previous_target" ] && ln -sfn "$previous_target" "$WEB_INSTALL_ROOT/previous"
  ln -sfn "$release_dir" "$WEB_INSTALL_ROOT/current"
  mkdir -p "$WEB_STATE_HOME"
  if [ ! -f "$WEB_STATE_HOME/web.db" ]; then
    echo "Set the initial administrator password."
    WEB_INIT_ARGS=(init)
    [ "$password_stdin" = "true" ] && WEB_INIT_ARGS+=(--password-stdin)
    WOFFY_WEB_HOME="$WEB_STATE_HOME" WOFFY_WEB_PORT="$port" PYTHONPATH="$release_dir/app" "$release_dir/venv/bin/python" -m woffy_web.manage "${WEB_INIT_ARGS[@]}" || {
      if [ -n "$previous_target" ]; then
        ln -sfn "$previous_target" "$WEB_INSTALL_ROOT/current"
      else
        rm -f "$WEB_INSTALL_ROOT/current"
      fi
      return 1
    }
  fi
  web_write_service "$port"
  if command -v systemctl >/dev/null 2>&1 && [ "${WOFFY_WEB_NO_SYSTEMD:-false}" != "true" ]; then
    systemctl --user daemon-reload
    systemctl --user enable --now woffy-web.service
    if command -v curl >/dev/null 2>&1; then
      sleep 1
      if ! curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/healthz" >/dev/null; then
        if [ -n "$previous_target" ]; then
          ln -sfn "$previous_target" "$WEB_INSTALL_ROOT/current"
          systemctl --user restart woffy-web.service || true
        else
          systemctl --user disable --now woffy-web.service 2>/dev/null || true
          rm -f "$WEB_INSTALL_ROOT/current"
        fi
        echo "ERROR Woffy Web failed its health check; previous release restored" >&2
        return 1
      fi
    fi
  else
    echo "WARN systemd user services are disabled or unavailable; run 'woffy web serve'." >&2
  fi
  echo "OK Woffy Web $artifact_version installed on http://127.0.0.1:$port"
  echo "Tunnel: ssh -L $port:127.0.0.1:$port <user>@<vps>"
}

web_manage() {
  local current
  current="$(web_current_dir)" || {
    echo "ERROR Woffy Web is not installed" >&2
    return 1
  }
  WOFFY_WEB_HOME="$WEB_STATE_HOME" PYTHONPATH="$current/app" "$current/venv/bin/python" -m woffy_web.manage "$@"
}

web_serve() {
  local current port="${1:-$WEB_PORT_DEFAULT}"
  current="$(web_current_dir)" || {
    echo "ERROR Woffy Web is not installed" >&2
    return 1
  }
  exec env WOFFY_BIN="$(get_bin_path)" WOFFY_HOME="$WOFFY_HOME" WOFFY_WEB_HOME="$WEB_STATE_HOME" PYTHONPATH="$current/app" \
    "$current/venv/bin/python" -m uvicorn woffy_web.app:app --app-dir "$current/app" --host 127.0.0.1 --port "$port" --no-server-header
}

web_service_action() {
  local action="$1"
  command -v systemctl >/dev/null 2>&1 || {
    echo "ERROR systemctl is unavailable" >&2
    return 1
  }
  systemctl --user "$action" woffy-web.service
}

web_deferred_update() {
  local channel="${1:-stable}" bin unit
  command -v systemd-run >/dev/null 2>&1 || {
    echo "ERROR systemd-run is required for a deferred panel update" >&2
    return 1
  }
  bin="$(get_bin_path)"
  [ -n "$bin" ] || bin="$(get_script_path)"
  unit="woffy-web-update-$(date +%s)"
  systemd-run --user --collect --on-active=5s --unit="$unit" "$bin" web update "$channel"
  echo "OK Deferred Woffy Web update scheduled as $unit."
}

web_cleanup_all() {
  case "$WEB_INSTALL_ROOT" in
    "" | / | "$HOME" | "$WOFFY_HOME") return 1 ;;
  esac
  case "$WEB_STATE_HOME" in
    "" | / | "$HOME") return 1 ;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable woffy-web.service 2>/dev/null || true
  fi
  [ -f "$WEB_SERVICE_FILE" ] && rm -f "$WEB_SERVICE_FILE"
  [ -d "$WEB_INSTALL_ROOT" ] && rm -rf "$WEB_INSTALL_ROOT"
  [ -d "$WEB_STATE_HOME" ] && rm -rf "$WEB_STATE_HOME"
}

web_uninstall_panel() {
  case "$WEB_INSTALL_ROOT" in
    "" | / | "$HOME" | "$WOFFY_HOME")
      echo "ERROR Unsafe Woffy Web install directory: $WEB_INSTALL_ROOT" >&2
      return 1
      ;;
  esac
  echo "This removes only the optional Woffy Web application; CLI data is preserved."
  read -r -p "Continue? (y/N): " WEB_CONFIRM
  case "$WEB_CONFIRM" in y | Y | s | S) ;; *)
    echo "Cancelled."
    return 0
    ;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now woffy-web.service 2>/dev/null || true
  fi
  [ -f "$WEB_SERVICE_FILE" ] && rm -f "$WEB_SERVICE_FILE"
  [ -d "$WEB_INSTALL_ROOT" ] && rm -rf "$WEB_INSTALL_ROOT"
  echo "OK Woffy Web removed. Audit and web authentication remain in $WEB_STATE_HOME."
}
load_persisted_runtime_config
validate_runtime_config

case "${1:-}" in
  help | "")
    show_help
    ;;

  version)
    echo "woffy v$VERSION"
    ;;

  login)
    check_deps curl jq sqlite3 date
    [ -n "${2:-}" ] || {
      echo "Usage: woffy login <email> [<password>|--password-stdin]"
      exit 1
    }
    EMAIL="$2"
    validate_email "$EMAIL" || {
      echo "ERROR Invalid email: $EMAIL"
      exit 1
    }
    case "${3:-}" in
      --password-stdin)
        IFS= read -r PASS
        ;;
      "")
        [ -t 0 ] || {
          echo "ERROR Password required; use --password-stdin in non-interactive mode" >&2
          exit 1
        }
        read -r -s -p "Woffu password: " PASS
        echo
        ;;
      *)
        PASS="$3"
        echo "WARN Positional passwords are deprecated; use prompt or --password-stdin." >&2
        ;;
    esac
    [ -n "$PASS" ] || {
      echo "ERROR Empty password" >&2
      exit 1
    }
    db_init
    db_exec "INSERT INTO users(email,password,active,created_at,updated_at)
             VALUES($(sql_quote "$EMAIL"),$(sql_quote "$PASS"),1,datetime('now','localtime'),datetime('now','localtime'))
             ON CONFLICT(email) DO UPDATE SET password=excluded.password, active=1, updated_at=excluded.updated_at;"
    seed_default_schedule "$EMAIL"
    db_exec "DELETE FROM tokens WHERE email=$(sql_quote "$EMAIL");"
    TOKEN="$(get_token "$EMAIL")"
    uj="$(api_get_raw "/api/users" || true)"
    if [ -n "$uj" ] && echo "$uj" | jq -e 'if type=="array" then .[0].UserId else .UserId end' >/dev/null 2>&1; then
      save_user_card_db "$EMAIL" "$uj"
      record_event "$EMAIL" "login" "auth" "success" "Login completed and user card saved."
      echo "OK Login completed for $EMAIL. User card saved."
    else
      record_event "$EMAIL" "login" "auth" "warning" "Login completed but user card could not be fetched."
      echo "WARN Login completed for $EMAIL, but user card could not be fetched."
    fi
    ;;

  users)
    check_deps sqlite3
    db_init
    case "${2:-}" in
      "")
        print_users
        ;;
      enable)
        [ -n "${3:-}" ] || {
          echo "Usage: woffy users enable <email>"
          exit 1
        }
        set_user_active "$3" 1
        ;;
      disable)
        [ -n "${3:-}" ] || {
          echo "Usage: woffy users disable <email>"
          exit 1
        }
        set_user_active "$3" 0
        ;;
      delete)
        [ -n "${3:-}" ] || {
          echo "Usage: woffy users delete <email>"
          exit 1
        }
        delete_user "$3"
        ;;
      *)
        echo "Usage: woffy users [enable|disable|delete <email>]"
        exit 1
        ;;
    esac
    ;;

  user)
    check_deps sqlite3
    [ -n "${2:-}" ] || {
      echo "Usage: woffy user <email>"
      exit 1
    }
    db_init
    db_exec "SELECT
               'Email: ' || users.email || char(10) ||
               'Active: ' || users.active || char(10) ||
               'Name: ' || COALESCE(user_cards.full_name,'') || char(10) ||
               'Company: ' || COALESCE(user_cards.company_name,'') || char(10) ||
               'Office: ' || COALESCE(user_cards.office_name,'') || char(10) ||
               'Woffu user id: ' || COALESCE(user_cards.woffu_user_id,'')
             FROM users LEFT JOIN user_cards ON user_cards.email=users.email
             WHERE users.email=$(sql_quote "$2");"
    ;;

  status)
    check_deps curl jq sqlite3 date
    [ -n "${2:-}" ] || {
      echo "Usage: woffy status <email>"
      exit 1
    }
    TOKEN="$(get_token "$2")"
    st="$(get_status)"
    echo "$2: $st"
    ;;

  dry-run)
    check_deps curl jq awk sqlite3 date
    MODE="${2:-}"
    EMAIL="${3:-}"
    [ "$MODE" = "in" ] || [ "$MODE" = "out" ] || {
      echo "Usage: woffy dry-run {in|out} <email>"
      exit 1
    }
    [ -n "$EMAIL" ] || {
      echo "Usage: woffy dry-run {in|out} <email>"
      exit 1
    }
    acquire_lock
    run_sign_flow "$EMAIL" "$MODE" true "$QUIET"
    ;;

  in | out)
    check_deps curl jq awk sqlite3 date
    [ -n "${2:-}" ] || {
      echo "Usage: woffy $1 <email>"
      exit 1
    }
    acquire_lock
    run_sign_flow "$2" "$1" false "$QUIET"
    ;;

  api)
    check_deps curl jq sqlite3 date
    db_init
    case "${2:-}" in
      configure)
        CLIENT_ID="${3:-}"
        is_int "$CLIENT_ID" || {
          echo "Usage: woffy api configure <company-id> [--secret-stdin]"
          exit 1
        }
        if [ "${4:-}" = "--secret-stdin" ]; then
          IFS= read -r CLIENT_SECRET
        else
          [ -t 0 ] || {
            echo "ERROR API key required; use --secret-stdin in non-interactive mode" >&2
            exit 1
          }
          read -r -s -p "Woffu API key: " CLIENT_SECRET
          echo
        fi
        [ -n "$CLIENT_SECRET" ] || {
          echo "ERROR Empty API key" >&2
          exit 1
        }
        db_exec "INSERT INTO integration_credentials(provider,client_id,client_secret,updated_at)
                 VALUES('woffu',$(sql_quote "$CLIENT_ID"),$(sql_quote "$CLIENT_SECRET"),datetime('now','localtime'))
                 ON CONFLICT(provider) DO UPDATE SET client_id=excluded.client_id,client_secret=excluded.client_secret,updated_at=excluded.updated_at;
                 DELETE FROM integration_tokens WHERE provider='woffu';"
        echo "OK Woffu API integration configured."
        ;;
      status)
        if [ -n "$(db_exec "SELECT client_id FROM integration_credentials WHERE provider='woffu';")" ]; then
          echo "Woffu API: configured"
        else
          echo "Woffu API: not configured"
        fi
        ;;
      test)
        integration_get_token >/dev/null
        echo "OK Woffu API authentication succeeded."
        ;;
      clear)
        db_exec "DELETE FROM integration_tokens WHERE provider='woffu'; DELETE FROM integration_credentials WHERE provider='woffu';"
        echo "OK Woffu API integration removed."
        ;;
      *)
        echo "Usage: woffy api {configure <company-id>|status|test|clear} [--secret-stdin]"
        exit 1
        ;;
    esac
    ;;

  sign)
    check_deps curl jq sqlite3 date
    EMAIL="${2:-}"
    MODE="${3:-}"
    SIGN_DATE="${4:-}"
    SIGN_TIME="${5:-}"
    if ! validate_email "$EMAIL" || ! validate_action "$MODE" || ! is_valid_date "$SIGN_DATE" || ! validate_time "$SIGN_TIME"; then
      echo "Usage: woffy sign <email> {in|out} <YYYY-MM-DD> <HH:MM>"
      exit 1
    fi
    user_exists "$EMAIL" || {
      echo "ERROR Unknown user: $EMAIL"
      exit 1
    }
    SIGN_DT="${SIGN_DATE}T${SIGN_TIME}:00"
    NOW_DT="$(date '+%Y-%m-%dT%H:%M:%S')"
    if [[ "$SIGN_DT" > "$NOW_DT" ]]; then
      echo "ERROR Backfill timestamp is in the future: $SIGN_DT"
      exit 1
    fi
    if backfill_sign_official "$EMAIL" "$MODE" "$SIGN_DT"; then
      record_event "$EMAIL" "$MODE" "backfill" "success" "Backdated sign accepted by official API: $SIGN_DT."
      echo "OK Backdated $MODE accepted for $EMAIL at $SIGN_DT."
    else
      record_event "$EMAIL" "$MODE" "backfill" "error" "Official API backfill failed: $SIGN_DT."
      exit 1
    fi
    ;;

  run)
    check_deps curl jq awk sqlite3 date
    case "${2:-}" in
      due)
        if [ "${3:-}" = "--dry-run" ]; then
          run_due true
        elif [ -n "${3:-}" ]; then
          echo "Usage: woffy run due [--quiet] [--dry-run]"
          exit 1
        else
          run_due false
        fi
        ;;
      *)
        echo "Usage: woffy run due [--quiet]"
        exit 1
        ;;
    esac
    ;;

  events)
    check_deps sqlite3 awk date
    if [ "${2:-}" = "purge" ]; then
      if ! { [ "${3:-}" = "--before" ] && [ -n "${4:-}" ] && [ "${5:-}" = "--yes" ]; }; then
        echo "Usage: woffy events purge --before YYYY-MM-DD --yes"
        exit 1
      fi
      PURGED="$(purge_events "$4")"
      echo "OK Purged $PURGED event(s) before $4."
      exit 0
    fi
    TARGET="${2:-all}"
    DAYS=30
    STATUS_FILTER="all"
    EVENTS_FORMAT="text"
    EVENTS_LIMIT=200
    shift || true
    if [ "$#" -gt 0 ]; then
      shift
    fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --days)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --days value"
            exit 1
          }
          DAYS="$2"
          shift 2
          ;;
        --status)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --status value"
            exit 1
          }
          STATUS_FILTER="$2"
          shift 2
          ;;
        --format)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --format value"
            exit 1
          }
          EVENTS_FORMAT="$2"
          shift 2
          ;;
        --limit)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --limit value"
            exit 1
          }
          EVENTS_LIMIT="$2"
          shift 2
          ;;
        *)
          echo "ERROR Unknown events option: $1"
          exit 1
          ;;
      esac
    done
    case "$STATUS_FILTER" in all | success | warning | error | dry-run) ;; *)
      echo "ERROR Invalid status: $STATUS_FILTER"
      exit 1
      ;;
    esac
    print_events "$TARGET" "$DAYS" "$STATUS_FILTER" "$EVENTS_FORMAT" "$EVENTS_LIMIT"
    ;;

  report)
    check_deps sqlite3 date
    [ "${2:-}" = "all" ] || {
      echo "Usage: woffy report all [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--format text|json|csv] [telegram]"
      exit 1
    }
    REPORT_FROM="$(current_week_start_date)"
    REPORT_TO="$(date '+%Y-%m-%d')"
    REPORT_FORMAT="text"
    SEND_TG=false
    shift 2 || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        telegram)
          SEND_TG=true
          shift
          ;;
        --from)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --from value"
            exit 1
          }
          REPORT_FROM="$2"
          shift 2
          ;;
        --to)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --to value"
            exit 1
          }
          REPORT_TO="$2"
          shift 2
          ;;
        --format)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --format value"
            exit 1
          }
          REPORT_FORMAT="$2"
          shift 2
          ;;
        *)
          echo "ERROR Unknown report option: $1"
          exit 1
          ;;
      esac
    done
    is_valid_date "$REPORT_FROM" || {
      echo "ERROR Invalid --from date (YYYY-MM-DD)"
      exit 1
    }
    is_valid_date "$REPORT_TO" || {
      echo "ERROR Invalid --to date (YYYY-MM-DD)"
      exit 1
    }
    if [[ "$REPORT_FROM" > "$REPORT_TO" ]]; then
      echo "ERROR --from must not be after --to"
      exit 1
    fi
    case "$REPORT_FORMAT" in text | json | csv) ;; *)
      echo "ERROR Invalid format: $REPORT_FORMAT"
      exit 1
      ;;
    esac
    REPORT_MSG="$(build_report_all "$(date_to_boundary "$REPORT_FROM" start)" "$(date_to_boundary "$REPORT_TO" end)" "$REPORT_FORMAT")"
    echo "$REPORT_MSG"
    if $SEND_TG; then
      tg_send info "$REPORT_MSG" true || {
        echo "ERROR Report could not be sent to Telegram." >&2
        exit 1
      }
      echo "OK Report sent to Telegram."
    fi
    ;;

  schedule)
    check_deps sqlite3
    db_init
    case "${2:-}" in
      install)
        check_deps crontab readlink
        install_run_due_cron
        echo "OK Cron orchestrator installed."
        ;;
      list)
        check_deps crontab
        crontab -l 2>/dev/null | grep 'woffy-' || echo "No woffy cron entries."
        ;;
      clear)
        check_deps crontab
        clear_woffy_cron
        echo "OK Cron cleared."
        ;;
      user)
        EMAIL="${3:-}"
        SUB="${4:-}"
        [ -n "$EMAIL" ] || {
          echo "Usage: woffy schedule user <email> {list|add|set|remove|clear|defaults}"
          exit 1
        }
        case "$SUB" in
          list)
            print_user_schedule "$EMAIL"
            ;;
          add)
            if [ -z "${5:-}" ] || [ -z "${6:-}" ]; then
              echo "Usage: woffy schedule user <email> add {in|out} HH:MM [weekdays]"
              exit 1
            fi
            add_user_schedule "$EMAIL" "$5" "$6" "${7:-1,2,3,4,5}"
            ;;
          set)
            if [ -z "${5:-}" ] || [ -z "${6:-}" ]; then
              echo "Usage: woffy schedule user <email> set {in|out} HH:MM[,HH:MM...] [weekdays]"
              exit 1
            fi
            set_user_schedule "$EMAIL" "$5" "$6" "${7:-1,2,3,4,5}"
            ;;
          remove)
            if [ -z "${5:-}" ] || [ -z "${6:-}" ]; then
              echo "Usage: woffy schedule user <email> remove {in|out} HH:MM"
              exit 1
            fi
            remove_user_schedule "$EMAIL" "$5" "$6"
            ;;
          clear)
            clear_user_schedule "$EMAIL"
            ;;
          defaults)
            reset_default_schedule "$EMAIL"
            ;;
          *)
            echo "Usage: woffy schedule user <email> {list|add|set|remove|clear|defaults}"
            exit 1
            ;;
        esac
        ;;
      *)
        echo "Usage: woffy schedule {install|list|clear|user <email> ...}"
        exit 1
        ;;
    esac
    ;;

  telegram)
    check_deps curl sqlite3
    db_init
    if [ "${2:-}" = "test" ]; then
      if tg_send test "woffy Telegram OK" true; then
        echo "OK Telegram test sent."
        exit 0
      fi
      echo "ERROR Telegram is not configured or delivery failed." >&2
      exit 1
    fi
    if [ "${2:-}" = "configure" ]; then
      if ! { [ "${3:-}" = "--token-stdin" ] && [ -n "${4:-}" ]; }; then
        echo "Usage: woffy telegram configure --token-stdin <chat-id> [thread-id] [all|errors|success]"
        exit 1
      fi
      IFS= read -r TG_INPUT_TOKEN
      [ -n "$TG_INPUT_TOKEN" ] || {
        echo "ERROR Empty Telegram token" >&2
        exit 1
      }
      [[ "$4" =~ ^-?[0-9]+$ ]] || {
        echo "ERROR Telegram chat id must be numeric" >&2
        exit 1
      }
      if [ -n "${5:-}" ] && ! [[ "$5" =~ ^-?[0-9]+$ ]]; then
        echo "ERROR Telegram thread id must be numeric" >&2
        exit 1
      fi
      case "${6:-all}" in all | errors | success) ;; *)
        echo "ERROR Invalid Telegram notification mode" >&2
        exit 1
        ;;
      esac
      settings_set TG_TOKEN "$TG_INPUT_TOKEN"
      settings_set TG_CHAT_ID "$4"
      settings_set TG_THREAD "${5:-}"
      settings_set TG_NOTIFY "${6:-all}"
      record_event "" "telegram" "admin" "success" "Telegram settings updated."
      echo "OK Telegram settings saved."
      exit 0
    fi
    if [ "${2:-}" = "clear" ]; then
      db_exec "DELETE FROM settings WHERE key IN ('TG_TOKEN','TG_CHAT_ID','TG_THREAD','TG_NOTIFY');"
      record_event "" "telegram" "admin" "warning" "Telegram settings removed."
      echo "OK Telegram settings removed."
      exit 0
    fi
    if [ $# -ge 3 ]; then
      settings_set TG_TOKEN "$2"
      settings_set TG_CHAT_ID "$3"
      [ -n "${4:-}" ] && settings_set TG_THREAD "$4"
      [ -n "${5:-}" ] && settings_set TG_NOTIFY "$5"
      record_event "" "telegram" "admin" "success" "Telegram settings updated through deprecated positional token syntax."
      echo "WARN Positional Telegram tokens are deprecated; use configure --token-stdin." >&2
      echo "OK Telegram settings saved."
      exit 0
    fi
    echo "Usage: woffy telegram {configure --token-stdin <chat-id> [thread-id] [mode]|test|clear}"
    ;;

  config)
    case "${2:-}" in
      check)
        check_deps sqlite3
        db_init
        echo "OK SQLite config valid: $DB_FILE"
        ;;
      list)
        CONFIG_FORMAT="${3:-text}"
        [ "$CONFIG_FORMAT" = "text" ] || [ "$CONFIG_FORMAT" = "--json" ] || {
          echo "Usage: woffy config list [--json]"
          exit 1
        }
        if [ "$CONFIG_FORMAT" = "--json" ]; then
          printf '{'
          CONFIG_FIRST=true
          for CONFIG_NAME in $(runtime_config_names); do
            $CONFIG_FIRST || printf ','
            CONFIG_FIRST=false
            printf '"%s":%s' "$CONFIG_NAME" "$(runtime_config_value "$CONFIG_NAME")"
          done
          printf '}\n'
        else
          for CONFIG_NAME in $(runtime_config_names); do
            printf '%-30s %s\n' "$CONFIG_NAME" "$(runtime_config_value "$CONFIG_NAME")"
          done
        fi
        ;;
      get)
        if [ -z "${3:-}" ] || ! runtime_setting_key "$3" >/dev/null; then
          echo "Usage: woffy config get <name>"
          exit 1
        fi
        runtime_config_value "$3"
        ;;
      set)
        if ! { [ -n "${3:-}" ] && [ -n "${4:-}" ]; }; then
          echo "Usage: woffy config set <name> <value>"
          exit 1
        fi
        runtime_config_set "$3" "$4"
        record_event "" "config" "admin" "success" "Runtime setting changed: $3."
        echo "OK Runtime setting $3 saved."
        ;;
      reset)
        [ -n "${3:-}" ] || {
          echo "Usage: woffy config reset <name>"
          exit 1
        }
        runtime_config_reset "$3" || {
          echo "ERROR Unknown runtime setting: $3" >&2
          exit 1
        }
        record_event "" "config" "admin" "warning" "Runtime setting reset: $3."
        echo "OK Runtime setting $3 reset."
        ;;
      *)
        echo "Usage: woffy config {check|list|get|set|reset}"
        exit 1
        ;;
    esac
    ;;

  self-test)
    check_deps curl jq awk sqlite3 date
    db_init
    echo "OK sqlite3 available"
    echo "OK DB initialized: $DB_FILE"
    echo "OK Users: $(db_exec "SELECT COUNT(*) FROM users;")"
    ;;

  doctor)
    if [ "${2:-}" = "--json" ]; then
      check_deps jq
      doctor_json
      exit $?
    fi
    check_deps sqlite3
    db_init
    echo "Woffy doctor v$VERSION"
    echo "Bin:   $(get_bin_path)"
    echo "Home:  $WOFFY_HOME"
    echo "DB:    $DB_FILE"
    echo "Users: $(db_exec "SELECT COUNT(*) FROM users;")"
    if crontab -l 2>/dev/null | grep -q '# woffy-run-due'; then
      echo "Cron:  run-due installed"
    else
      echo "Cron:  not installed"
    fi
    ;;

  backup)
    check_deps tar
    OUT="${2:-}"
    BAK_PATH="$(backup_files "$OUT")"
    echo "OK Backup created: $BAK_PATH"
    ;;

  restore)
    check_deps tar sqlite3
    [ -n "${2:-}" ] || {
      echo "Usage: woffy restore <path.tar.gz>"
      exit 1
    }
    restore_files "$2" || {
      echo "ERROR Could not restore backup."
      exit 1
    }
    db_init
    echo "OK Backup restored."
    ;;

  changelog)
    check_deps curl jq awk
    show_changelog
    ;;

  update)
    check_deps curl awk
    UPDATE_CHANNEL="stable"
    UPDATE_CHECK=false
    ALLOW_DOWNGRADE=false
    shift || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        nightly) UPDATE_CHANNEL="nightly" ;;
        --check) UPDATE_CHECK=true ;;
        --allow-downgrade) ALLOW_DOWNGRADE=true ;;
        *)
          echo "Usage: woffy update [nightly] [--check] [--allow-downgrade]"
          exit 1
          ;;
      esac
      shift
    done
    perform_update "$UPDATE_CHANNEL" "$UPDATE_CHECK" "$ALLOW_DOWNGRADE"
    ;;

  web)
    case "${2:-}" in
      install)
        WEB_PORT="$WEB_PORT_DEFAULT"
        WEB_PASSWORD_STDIN=false
        shift 2 || true
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --port)
              WEB_PORT="${2:-}"
              shift 2
              ;;
            --password-stdin)
              WEB_PASSWORD_STDIN=true
              shift
              ;;
            *)
              echo "Usage: woffy web install [--port N] [--password-stdin]"
              exit 1
              ;;
          esac
        done
        web_install_release stable "$WEB_PORT" "$WEB_PASSWORD_STDIN"
        ;;
      update)
        if [ "${3:-}" = "--deferred" ]; then
          WEB_CHANNEL="${4:-stable}"
          [ "$WEB_CHANNEL" = "stable" ] || [ "$WEB_CHANNEL" = "nightly" ] || {
            echo "Usage: woffy web update --deferred [stable|nightly]"
            exit 1
          }
          web_deferred_update "$WEB_CHANNEL"
          exit $?
        fi
        WEB_CHANNEL="${3:-stable}"
        [ "$WEB_CHANNEL" = "stable" ] || [ "$WEB_CHANNEL" = "nightly" ] || {
          echo "Usage: woffy web update [stable|nightly]"
          exit 1
        }
        web_install_release "$WEB_CHANNEL" "$WEB_PORT_DEFAULT"
        ;;
      start | stop | restart | status)
        web_service_action "$2"
        ;;
      logs)
        command -v journalctl >/dev/null 2>&1 || {
          echo "ERROR journalctl is unavailable" >&2
          exit 1
        }
        journalctl --user -u woffy-web.service -n "${3:-100}" --no-pager
        ;;
      passwd)
        if [ "${3:-}" = "--password-stdin" ]; then
          web_manage passwd --password-stdin
        else
          web_manage passwd
        fi
        ;;
      serve)
        web_serve "${3:-$WEB_PORT_DEFAULT}"
        ;;
      uninstall)
        web_uninstall_panel
        ;;
      *)
        echo "Usage: woffy web {install [--port N] [--password-stdin]|update [stable|nightly]|start|stop|restart|status|logs [N]|passwd [--password-stdin]|serve [port]|uninstall}"
        exit 1
        ;;
    esac
    ;;

  uninstall)
    check_deps crontab
    echo "This removes the installed binary, cron entries and $WOFFY_HOME."
    read -r -p "Continue? (y/N): " CONFIRM
    case "$CONFIRM" in y | Y | s | S) ;; *)
      echo "Cancelled."
      exit 0
      ;;
    esac
    clear_woffy_cron
    web_cleanup_all || true
    BIN_PATH="$(get_bin_path)"
    [ -n "$BIN_PATH" ] && rm -f "$BIN_PATH"
    for target in "$DB_FILE" "$DB_FILE-wal" "$DB_FILE-shm" "$LOG_FILE" "$LOG_FILE".[0-9]*; do
      [ -f "$target" ] && rm -f "$target"
    done
    release_lock
    rmdir "$WOFFY_HOME" 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user stop woffy-web.service 2>/dev/null || true
    fi
    echo "OK Woffy uninstalled."
    ;;

  *)
    echo "ERROR Unknown command. Run 'woffy help'."
    exit 1
    ;;
esac
