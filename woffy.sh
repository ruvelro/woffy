#!/bin/bash
set -euo pipefail

VERSION="2.0.0"

WOFFY_HOME="${WOFFY_HOME:-$HOME/.woffy}"
DB_FILE="${WOFFY_DB_FILE:-$WOFFY_HOME/woffy.db}"
LOG_FILE="${WOFFY_LOG_FILE:-$WOFFY_HOME/woffy.log}"
LOCK_DIR="${WOFFY_LOCK_DIR:-$WOFFY_HOME/woffy.lock.d}"
API_URL="https://app.woffu.com"
REPO_RAW_BASE="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main"

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

LOG_MAX_BYTES_DEFAULT=1048576
LOG_MAX_FILES_DEFAULT=5

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

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
  max_bytes="${WOFFY_LOG_MAX_BYTES:-$LOG_MAX_BYTES_DEFAULT}"
  max_files="${WOFFY_LOG_MAX_FILES:-$LOG_MAX_FILES_DEFAULT}"
  is_int "$max_bytes" || max_bytes="$LOG_MAX_BYTES_DEFAULT"
  is_int "$max_files" || max_files="$LOG_MAX_FILES_DEFAULT"
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
  sqlite3 "$DB_FILE" "$1"
}

db_init() {
  check_deps sqlite3
  ensure_home
  sqlite3 "$DB_FILE" <<'SQL'
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
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS run_guard(
  email TEXT NOT NULL,
  action TEXT NOT NULL,
  run_date TEXT NOT NULL,
  time_hhmm TEXT NOT NULL,
  PRIMARY KEY(email, action, run_date, time_hhmm)
);
SQL
  chmod 600 "$DB_FILE" 2>/dev/null || true
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
  [ -z "${TG_TOKEN:-}" ] && return 0
  [ -z "${TG_CHAT_ID:-}" ] && return 0

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
  curl_args=(-s --max-time 10 -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$msg")
  if [ -n "${TG_THREAD:-}" ]; then
    [[ "$TG_THREAD" =~ ^-?[0-9]+$ ]] || {
      log "Invalid TG_THREAD. It must be numeric."
      return 0
    }
    curl_args+=(-d "message_thread_id=$TG_THREAD")
  fi
  curl "${curl_args[@]}" >/dev/null || log "Error sending Telegram message"
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
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" >"$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
  fi

  local dir_pid
  dir_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
  if [ -n "$dir_pid" ] && kill -0 "$dir_pid" 2>/dev/null; then
    log "Active lock (PID $dir_pid). Skipping concurrent run."
    exit 0
  fi

  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || {
    log "Could not acquire lock."
    exit 1
  }
  echo "$$" >"$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
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
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

validate_time() {
  [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]
}

validate_action() {
  [ "$1" = "in" ] || [ "$1" = "out" ]
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
  db_exec "INSERT INTO events(email,action,kind,status,message,created_at)
           VALUES($(sql_quote "$email"),$(sql_quote "$action"),$(sql_quote "$kind"),$(sql_quote "$status"),$(sql_quote "$message"),datetime('now','localtime'));"
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
  db_exec "SELECT users.email || char(9) || COALESCE(user_cards.full_name,'') || char(9) || CASE users.active WHEN 1 THEN 'active' ELSE 'inactive' END
           FROM users LEFT JOIN user_cards ON user_cards.email=users.email
           ORDER BY users.email;" |
    awk 'BEGIN{FS="\t"; printf "%-34s %-30s %s\n","EMAIL","NAME","STATUS"} {printf "%-34s %-30s %s\n",$1,$2,$3}'
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
  local time
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
  db_exec "DELETE FROM schedules WHERE email=$(sql_quote "$email") AND action=$(sql_quote "$action");"
  IFS=',' read -ra TIMES <<<"$times_csv"
  for time in "${TIMES[@]}"; do
    validate_time "$time" || {
      echo "ERROR Invalid time: $time"
      exit 1
    }
    db_exec "INSERT INTO schedules(email, action, time_hhmm, weekdays, active)
             VALUES($(sql_quote "$email"),$(sql_quote "$action"),$(sql_quote "$time"),$(sql_quote "$weekdays"),1);"
  done
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
    echo "ERROR Unknown or inactive user: $email"
    exit 1
  }
  now="$(date +%s)"
  token="$(db_exec "SELECT COALESCE(token,'') FROM tokens WHERE email=$(sql_quote "$email") AND expires_at > $((now + 60)) LIMIT 1;")"
  if [ -n "$token" ]; then
    echo "$token"
    return 0
  fi

  password="$(user_password "$email")"
  log "Refreshing OAuth token for $email"
  response="$(curl -s -X POST "$API_URL/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=$email" \
    --data-urlencode "password=$password" || true)"

  token="$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null || echo "")"
  expires="$(echo "$response" | jq -r '.expires_in // 3600' 2>/dev/null || echo "3600")"

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    record_event "$email" "auth" "auth" "error" "Woffu authentication failed"
    echo "ERROR Could not authenticate $email with Woffu"
    tg_send error "woffy: auth failed for $email"
    exit 1
  fi

  exp=$((now + expires - 60))
  db_exec "INSERT INTO tokens(email, token, expires_at, updated_at)
           VALUES($(sql_quote "$email"),$(sql_quote "$token"),$exp,datetime('now','localtime'))
           ON CONFLICT(email) DO UPDATE SET token=excluded.token, expires_at=excluded.expires_at, updated_at=excluded.updated_at;"
  echo "$token"
}

api_get_raw() {
  local path="$1"
  [ -z "${TOKEN:-}" ] && return 1
  curl -fsS --max-time 15 -H "Authorization: Bearer $TOKEN" "$API_URL$path"
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
  resp="$(curl -s -w "\n%{http_code}" -X POST "$API_URL/api/signs" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$json_data" || true)"
  status_code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"
  if [[ "$status_code" =~ ^2 ]]; then
    return 0
  fi
  log "API sign error ($action): HTTP $status_code | $body"
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
  tg_send "$type" "woffy: $label: $msg"
}

run_sign_flow() {
  local email="$1"
  local mode="$2"
  local dry_run="${3:-false}"
  local quiet="${4:-false}"
  local st wd reason action msg attempt success max_retries retry_delay

  user_exists_active "$email" || {
    echo "ERROR Unknown or inactive user: $email"
    exit 1
  }
  TOKEN="$(get_token "$email")"
  export TOKEN
  st="$(get_status)"
  log "$email | requested=$mode | status=$st | dry_run=$dry_run"

  if [ "$st" = "unknown" ]; then
    msg="Cannot determine current status. Aborting."
    [ "$quiet" = "true" ] || echo "WARN $email: $msg"
    record_event "$email" "$mode" "sign" "error" "$msg"
    notify_user_result error "$email" "$msg"
    return 1
  fi

  if [ "$mode" = "in" ] && [ "$st" = "in" ]; then
    msg="Already clocked in."
    [ "$quiet" = "true" ] || echo "WARN $email: $msg"
    record_event "$email" "$mode" "sign" "warning" "$msg"
    notify_user_result error "$email" "$msg"
    return 0
  fi

  if [ "$mode" = "out" ] && [ "$st" = "out" ]; then
    msg="Already clocked out."
    [ "$quiet" = "true" ] || echo "WARN $email: $msg"
    record_event "$email" "$mode" "sign" "warning" "$msg"
    notify_user_result error "$email" "$msg"
    return 0
  fi

  if [ "$mode" = "in" ]; then
    wd="$(get_workday "$email" || true)"
    if [ -n "$wd" ] && ! is_workday_ok_for_in "$wd"; then
      reason="$(workday_reason "$wd")"
      [ -z "$reason" ] && reason="non-working day"
      msg="Clock-in skipped: $reason."
      [ "$quiet" = "true" ] || echo "WARN $email: $msg"
      record_event "$email" "$mode" "sign" "warning" "$msg"
      notify_user_result error "$email" "$msg"
      return 0
    fi
  fi

  if [ "$dry_run" = "true" ]; then
    msg="DRY-RUN would clock $mode now."
    [ "$quiet" = "true" ] || echo "INFO $email: $msg"
    record_event "$email" "$mode" "sign" "dry-run" "$msg"
    return 0
  fi

  action="clock_in"
  [ "$mode" = "out" ] && action="clock_out"
  max_retries=4
  retry_delay=15
  attempt=1
  success=false

  while [ "$attempt" -le "$max_retries" ]; do
    if post_sign "$action"; then
      success=true
      break
    fi
    [ "$attempt" -lt "$max_retries" ] && sleep "$retry_delay"
    attempt=$((attempt + 1))
  done

  if $success; then
    msg="Clock $mode completed."
    [ "$quiet" = "true" ] || echo "OK $email: $msg"
    record_event "$email" "$mode" "sign" "success" "$msg"
    notify_user_result success "$email" "$msg"
    return 0
  fi

  msg="Clock $mode failed after $max_retries attempts."
  [ "$quiet" = "true" ] || echo "ERROR $email: $msg"
  record_event "$email" "$mode" "sign" "error" "$msg"
  notify_user_result error "$email" "$msg"
  return 1
}

run_due() {
  local now_time today dow rows email action guard_changed failures=0
  db_init
  acquire_lock
  now_time="$(date '+%H:%M')"
  today="$(date '+%Y-%m-%d')"
  dow="$(date '+%u')"
  rows="$(db_exec "SELECT users.email || char(9) || schedules.action
                   FROM schedules JOIN users ON users.email=schedules.email
                   WHERE users.active=1
                     AND schedules.active=1
                     AND schedules.time_hhmm=$(sql_quote "$now_time")
                     AND instr(',' || schedules.weekdays || ',', ',' || $(sql_quote "$dow") || ',') > 0;")"
  [ -z "$rows" ] && {
    $QUIET || echo "No due users for $now_time."
    return 0
  }
  while IFS=$'\t' read -r email action; do
    [ -z "$email" ] && continue
    guard_changed="$(db_exec "INSERT OR IGNORE INTO run_guard(email, action, run_date, time_hhmm)
                              VALUES($(sql_quote "$email"),$(sql_quote "$action"),$(sql_quote "$today"),$(sql_quote "$now_time"));
                              SELECT changes();")"
    if [ "$guard_changed" != "1" ]; then
      $QUIET || echo "SKIP $email: already processed $action at $now_time"
      continue
    fi
    if ! run_sign_flow "$email" "$action" false "$QUIET"; then
      failures=$((failures + 1))
    fi
  done <<<"$rows"
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
      db_exec "SELECT '{\"id\":' || id ||
                     ',\"created_at\":\"' || replace(created_at,'\"','\\\"') || '\"' ||
                     ',\"email\":\"' || replace(COALESCE(email,''),'\"','\\\"') || '\"' ||
                     ',\"action\":\"' || replace(COALESCE(action,''),'\"','\\\"') || '\"' ||
                     ',\"kind\":\"' || replace(kind,'\"','\\\"') || '\"' ||
                     ',\"status\":\"' || replace(status,'\"','\\\"') || '\"' ||
                     ',\"message\":\"' || replace(message,'\"','\\\"') || '\"}'
               FROM events
               WHERE $where
               ORDER BY created_at DESC, id DESC
               LIMIT $limit;" |
        awk 'BEGIN{print "["} {if (NR>1) printf ",\n"; printf "%s",$0} END{print "\n]"}'
      ;;
    csv)
      echo "id,created_at,email,action,kind,status,message"
      db_exec "SELECT id || ',' ||
                     '\"' || replace(created_at,'\"','\"\"') || '\",' ||
                     '\"' || replace(COALESCE(email,''),'\"','\"\"') || '\",' ||
                     '\"' || replace(COALESCE(action,''),'\"','\"\"') || '\",' ||
                     '\"' || replace(kind,'\"','\"\"') || '\",' ||
                     '\"' || replace(status,'\"','\"\"') || '\",' ||
                     '\"' || replace(message,'\"','\"\"') || '\"'
               FROM events
               WHERE $where
               ORDER BY created_at DESC, id DESC
               LIMIT $limit;"
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

backup_files() {
  local out="${1:-$HOME/woffy-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  ensure_home
  tar -czf "$out" -C "$WOFFY_HOME" . >/dev/null 2>&1
  echo "$out"
}

restore_files() {
  local in="$1"
  [ -f "$in" ] || return 1
  ensure_home
  tar -xzf "$in" -C "$WOFFY_HOME" >/dev/null 2>&1 || return 1
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
  remote_version="$(curl -fsSL "$REPO_RAW_BASE/woffy.sh" | awk -F\" '/^VERSION=/{print $2; exit}' 2>/dev/null || echo "unknown")"
  echo "Local:  v$VERSION"
  echo "Remote: v$remote_version"
  commits="$(curl -fsSL "https://api.github.com/repos/ruvelro/woffy/commits?per_page=8" |
    jq -r '.[] | "- " + (.sha[0:7]) + " " + .commit.message' 2>/dev/null || true)"
  [ -n "$commits" ] && echo "$commits"
}

show_help() {
  cat <<EOF
woffy v$VERSION

Multi-user Woffu attendance automation for a centrally managed VPS.

Usage:
  woffy login <email> <password>
  woffy users [enable|disable|delete <email>]
  woffy user <email>
  woffy status <email>
  woffy in <email>
  woffy out <email>
  woffy dry-run {in|out} <email>
  woffy run due [--quiet]
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
  woffy telegram [test]
  woffy doctor [--json]
  woffy backup [path.tar.gz]
  woffy restore <path.tar.gz>
  woffy changelog
  woffy update [nightly]
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
EOF
}

doctor_json() {
  local sqlite_ok db_exists users_count cron_installed tg_enabled
  sqlite_ok=false
  command -v sqlite3 >/dev/null 2>&1 && sqlite_ok=true
  db_exists=false
  [ -f "$DB_FILE" ] && db_exists=true
  users_count=0
  if $sqlite_ok; then
    db_init
    users_count="$(db_exec "SELECT COUNT(*) FROM users;" 2>/dev/null || echo 0)"
  fi
  cron_installed=false
  crontab -l 2>/dev/null | grep -q '# woffy-run-due' && cron_installed=true
  tg_enabled=false
  if $sqlite_ok; then
    [ -n "$(settings_get TG_TOKEN 2>/dev/null || true)" ] && [ -n "$(settings_get TG_CHAT_ID 2>/dev/null || true)" ] && tg_enabled=true
  fi
  cat <<EOF
{"version":"$VERSION","bin":"$(json_escape "$(get_bin_path)")","sqlite3":$sqlite_ok,"db":"$(json_escape "$DB_FILE")","db_exists":$db_exists,"users":$users_count,"cron_run_due":$cron_installed,"telegram":$tg_enabled}
EOF
  $sqlite_ok
}

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
      echo "Usage: woffy login <email> <password>"
      exit 1
    }
    [ -n "${3:-}" ] || {
      echo "Usage: woffy login <email> <password>"
      exit 1
    }
    EMAIL="$2"
    PASS="$3"
    db_init
    db_exec "INSERT INTO users(email,password,active,created_at,updated_at)
             VALUES($(sql_quote "$EMAIL"),$(sql_quote "$PASS"),1,datetime('now','localtime'),datetime('now','localtime'))
             ON CONFLICT(email) DO UPDATE SET password=excluded.password, active=1, updated_at=excluded.updated_at;"
    seed_default_schedule "$EMAIL"
    db_exec "DELETE FROM tokens WHERE email=$(sql_quote "$EMAIL");"
    TOKEN="$(get_token "$EMAIL")"
    export TOKEN
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
    export TOKEN
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

  run)
    check_deps curl jq awk sqlite3 date
    case "${2:-}" in
      due) run_due ;;
      *)
        echo "Usage: woffy run due [--quiet]"
        exit 1
        ;;
    esac
    ;;

  events)
    check_deps sqlite3 awk date
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
    case "$REPORT_FORMAT" in text | json | csv) ;; *)
      echo "ERROR Invalid format: $REPORT_FORMAT"
      exit 1
      ;;
    esac
    REPORT_MSG="$(build_report_all "$(date_to_boundary "$REPORT_FROM" start)" "$(date_to_boundary "$REPORT_TO" end)" "$REPORT_FORMAT")"
    echo "$REPORT_MSG"
    if $SEND_TG; then
      tg_send info "$REPORT_MSG" true
      echo "OK Report sent to Telegram if configured."
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
      tg_send test "woffy Telegram OK" true
      echo "OK Telegram test sent if configured."
      exit 0
    fi
    if [ $# -ge 3 ]; then
      settings_set TG_TOKEN "$2"
      settings_set TG_CHAT_ID "$3"
      [ -n "${4:-}" ] && settings_set TG_THREAD "$4"
      [ -n "${5:-}" ] && settings_set TG_NOTIFY "$5"
      echo "OK Telegram settings saved."
      exit 0
    fi
    echo "Usage: woffy telegram <bot_token> <chat_id> [thread_id] [all|errors|success]"
    ;;

  config)
    case "${2:-}" in
      check)
        check_deps sqlite3
        db_init
        echo "OK SQLite config valid: $DB_FILE"
        ;;
      *)
        echo "Usage: woffy config check"
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
    check_deps curl
    UPDATE_BRANCH="main"
    if [ "${2:-}" = "nightly" ]; then
      UPDATE_BRANCH="nightly"
    elif [ -n "${2:-}" ]; then
      echo "Usage: woffy update [nightly]"
      exit 1
    fi
    BIN_PATH="$(get_bin_path)"
    [ -n "$BIN_PATH" ] || {
      echo "ERROR Current woffy binary not found"
      exit 1
    }
    TMP="$(mktemp)"
    curl -fsSL "https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/$UPDATE_BRANCH/woffy.sh" -o "$TMP" || {
      rm -f "$TMP"
      echo "ERROR Could not download update"
      exit 1
    }
    chmod +x "$TMP"
    mv "$TMP" "$BIN_PATH"
    echo "OK Woffy updated from '$UPDATE_BRANCH'."
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
    BIN_PATH="$(get_bin_path)"
    [ -n "$BIN_PATH" ] && rm -f "$BIN_PATH"
    rm -rf "$WOFFY_HOME"
    echo "OK Woffy uninstalled."
    ;;

  *)
    echo "ERROR Unknown command. Run 'woffy help'."
    exit 1
    ;;
esac
