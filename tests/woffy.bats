#!/usr/bin/env bats

setup() {
  export TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR/home"
  export BIN_DIR="$TEST_DIR/bin"
  export CRON_FILE="$TEST_DIR/crontab.txt"
  export WOFFY_TOKEN_EXPIRES_IN=3600
  mkdir -p "$HOME" "$BIN_DIR"
  : > "$TEST_DIR/curl.calls"

  cp "$BATS_TEST_DIRNAME/../woffy.sh" "$TEST_DIR/woffy.sh"
  chmod +x "$TEST_DIR/woffy.sh"
  ln -s "$TEST_DIR/woffy.sh" "$BIN_DIR/woffy"

  cat > "$BIN_DIR/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CRON_FILE="${CRON_FILE:?}"
if [ "${1:-}" = "-l" ]; then
  [ -f "$CRON_FILE" ] && cat "$CRON_FILE"
  exit 0
fi
if [ $# -eq 1 ] && [ -f "$1" ]; then
  cp "$1" "$CRON_FILE"
  exit 0
fi
exit 1
EOF
  chmod +x "$BIN_DIR/crontab"

  cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${TEST_DIR}/curl.calls"
args="$*"
if [ -n "${WOFFY_UPDATE_FIXTURE_DIR:-}" ] && [[ "$args" == *"/stable/woffy"* || "$args" == *"/nightly/woffy"* ]]; then
  source_name=""
  output=""
  previous=""
  for item in "$@"; do
    case "$item" in */woffy|*/woffy.version|*/woffy.sha256) source_name="${item##*/}" ;; esac
    if [ "$previous" = "-o" ]; then output="$item"; break; fi
    previous="$item"
  done
  [ -n "$source_name" ] || exit 1
  if [ -n "$output" ]; then
    cp "$WOFFY_UPDATE_FIXTURE_DIR/$source_name" "$output"
  else
    cat "$WOFFY_UPDATE_FIXTURE_DIR/$source_name"
  fi
  exit 0
fi
if [[ "$args" == *"/token"* ]]; then
  if [ -f "${TEST_DIR}/fail_token" ]; then
    printf '{"error":"invalid_grant"}\n'
    exit 0
  fi
  printf '{"access_token":"token-%s","expires_in":%s}\n' "$(date +%s)" "${WOFFY_TOKEN_EXPIRES_IN:-3600}"
  exit 0
fi
if [[ "$args" == *"/api/users/"*"/workdaylite"* ]]; then
  if [ -f "${TEST_DIR}/fail_workday" ]; then exit 1; fi
  printf '{"ScheduleHours":8,"IsWeekend":false,"IsHoliday":false,"IsEvent":false}\n'
  exit 0
fi
if [[ "$args" == *"/api/users"* ]]; then
  printf '[{"UserId":"u-1","FullName":"Test User","CompanyName":"Acme","OfficeName":"HQ","Schedule":{"Name":"Default"}}]\n'
  exit 0
fi
if [[ "$args" == *"/api/v1/signs"* && "$args" == *"-X POST"* ]]; then
  printf '{}\n200\n'
  exit 0
fi
if [[ "$args" == *"/api/signs"* && "$args" == *"-X POST"* ]]; then
  if [ -f "${TEST_DIR}/fail_sign" ]; then
    printf '{}\n500\n'
    exit 0
  fi
  printf '{}\n200\n'
  exit 0
fi
if [[ "$args" == *"/api/signs"* ]]; then
  printf '[{"Deleted":false,"SignType":0,"SignIn":false,"TrueDate":"2026-01-01T08:00:00"}]\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$BIN_DIR/curl"

  export PATH="$BIN_DIR:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "config check initializes sqlite database with protected location" {
  run bash "$TEST_DIR/woffy.sh" config check
  [ "$status" -eq 0 ]
  [ -f "$HOME/.woffy/woffy.db" ]
  [ -d "$HOME/.woffy" ]
  if [[ "$(uname -s)" =~ MINGW|MSYS|CYGWIN ]]; then
    skip "Windows Git Bash does not reliably expose chmod 600 via stat"
  fi
  perms="$(stat -c %a "$HOME/.woffy/woffy.db" 2>/dev/null || stat -f %Lp "$HOME/.woffy/woffy.db")"
  [ "$perms" = "600" ]
}

@test "login stores user token card and default schedules" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  [[ "$output" == *"Login completed"* ]]

  user_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM users WHERE email='worker@example.com';")"
  token_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM tokens WHERE email='worker@example.com';")"
  card_name="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT full_name FROM user_cards WHERE email='worker@example.com';")"
  schedule_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM schedules WHERE email='worker@example.com';")"

  [ "$user_count" = "1" ]
  [ "$token_count" = "1" ]
  [ "$card_name" = "Test User" ]
  [ "$schedule_count" = "4" ]
}

@test "status uses the selected email token" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]

  run bash "$TEST_DIR/woffy.sh" status worker@example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"worker@example.com: out"* ]]

  calls="$(cat "$TEST_DIR/curl.calls")"
  [[ "$calls" == *"username=worker@example.com"* || "$calls" == *"worker@example.com"* ]]
}

@test "in records a successful event for the selected user" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]

  run bash "$TEST_DIR/woffy.sh" in worker@example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK worker@example.com"* ]]

  event_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM events WHERE email='worker@example.com' AND action='in' AND status='success';")"
  [ "$event_count" = "1" ]
}

@test "run due processes matching active schedules only once" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  now_hhmm="$(date '+%H:%M')"
  dow="$(date '+%u')"
  sqlite3 "$HOME/.woffy/woffy.db" "DELETE FROM schedules; INSERT INTO schedules(email,action,time_hhmm,weekdays,active) VALUES('worker@example.com','in','$now_hhmm','$dow',1);"

  run bash "$TEST_DIR/woffy.sh" run due
  [ "$status" -eq 0 ]
  run bash "$TEST_DIR/woffy.sh" run due
  [ "$status" -eq 0 ]

  guard_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM run_guard WHERE email='worker@example.com' AND action='in';")"
  success_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM events WHERE email='worker@example.com' AND action='in' AND status='success';")"
  [ "$guard_count" = "1" ]
  [ "$success_count" = "1" ]
}

@test "report all emits aggregate json from sqlite events" {
  run bash "$TEST_DIR/woffy.sh" config check
  [ "$status" -eq 0 ]
  sqlite3 "$HOME/.woffy/woffy.db" "INSERT INTO events(email,action,kind,status,message,created_at) VALUES
    ('a@example.com','in','sign','success','ok','2026-01-02 09:00:00'),
    ('b@example.com','out','sign','success','ok','2026-01-02 18:00:00'),
    ('b@example.com','in','sign','error','bad','2026-01-02 09:00:00');"

  run bash "$TEST_DIR/woffy.sh" report all --from 2026-01-01 --to 2026-01-03 --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"entries_in\":1"* ]]
  [[ "$output" == *"\"entries_out\":1"* ]]
  [[ "$output" == *"\"errors\":1"* ]]
}

@test "schedule install list and clear manage one run-due cron entry" {
  run bash "$TEST_DIR/woffy.sh" schedule install
  [ "$status" -eq 0 ]
  run bash "$TEST_DIR/woffy.sh" schedule list
  [ "$status" -eq 0 ]
  [[ "$output" == *"# woffy-run-due"* ]]
  [[ "$output" == *"run due --quiet"* ]]

  run bash "$TEST_DIR/woffy.sh" schedule clear
  [ "$status" -eq 0 ]
  run bash "$TEST_DIR/woffy.sh" schedule list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No woffy cron entries"* ]]
}

@test "users enable disable and delete manage worker state without deleting audit events" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]

  run bash "$TEST_DIR/woffy.sh" users disable worker@example.com
  [ "$status" -eq 0 ]
  active="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT active FROM users WHERE email='worker@example.com';")"
  [ "$active" = "0" ]

  run bash "$TEST_DIR/woffy.sh" users enable worker@example.com
  [ "$status" -eq 0 ]
  active="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT active FROM users WHERE email='worker@example.com';")"
  [ "$active" = "1" ]

  run bash "$TEST_DIR/woffy.sh" users delete worker@example.com
  [ "$status" -eq 0 ]
  user_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM users WHERE email='worker@example.com';")"
  event_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM events WHERE email='worker@example.com';")"
  [ "$user_count" = "0" ]
  [ "$event_count" -gt 0 ]
}

@test "schedule user commands can list set add remove clear and restore defaults" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]

  run bash "$TEST_DIR/woffy.sh" schedule user worker@example.com set in 08:00,16:00 1,2,3
  [ "$status" -eq 0 ]
  in_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM schedules WHERE email='worker@example.com' AND action='in';")"
  weekdays="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT DISTINCT weekdays FROM schedules WHERE email='worker@example.com' AND action='in';")"
  [ "$in_count" = "2" ]
  [ "$weekdays" = "1,2,3" ]

  run bash "$TEST_DIR/woffy.sh" schedule user worker@example.com add out 19:00 1,2,3,4,5
  [ "$status" -eq 0 ]
  out_added="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM schedules WHERE email='worker@example.com' AND action='out' AND time_hhmm='19:00';")"
  [ "$out_added" = "1" ]

  run bash "$TEST_DIR/woffy.sh" schedule user worker@example.com remove out 19:00
  [ "$status" -eq 0 ]
  out_removed="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM schedules WHERE email='worker@example.com' AND action='out' AND time_hhmm='19:00';")"
  [ "$out_removed" = "0" ]

  run bash "$TEST_DIR/woffy.sh" schedule user worker@example.com clear
  [ "$status" -eq 0 ]
  all_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM schedules WHERE email='worker@example.com';")"
  [ "$all_count" = "0" ]

  run bash "$TEST_DIR/woffy.sh" schedule user worker@example.com defaults
  [ "$status" -eq 0 ]
  default_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM schedules WHERE email='worker@example.com';")"
  [ "$default_count" = "4" ]
}

@test "events command shows per-user recent problems with days status format and limit filters" {
  run bash "$TEST_DIR/woffy.sh" config check
  [ "$status" -eq 0 ]
  sqlite3 "$HOME/.woffy/woffy.db" "INSERT INTO events(email,action,kind,status,message,created_at) VALUES
    ('worker@example.com','in','sign','error','recent bad',datetime('now','localtime','-5 days')),
    ('worker@example.com','out','sign','success','recent ok',datetime('now','localtime','-5 days')),
    ('worker@example.com','in','sign','error','old bad',datetime('now','localtime','-90 days')),
    ('other@example.com','in','sign','error','other bad',datetime('now','localtime','-5 days'));"

  run bash "$TEST_DIR/woffy.sh" events worker@example.com --days 30 --status error --format json --limit 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"recent bad"* ]]
  [[ "$output" != *"old bad"* ]]
  [[ "$output" != *"other bad"* ]]
  [[ "$output" != *"recent ok"* ]]
}

@test "doctor json reports sqlite and user count" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]

  run bash "$TEST_DIR/woffy.sh" doctor --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"sqlite3\":true"* ]]
  [[ "$output" == *"\"users\":1"* ]]
}

@test "schedule set validates everything before replacing existing rows" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  before="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT group_concat(time_hhmm,',') FROM schedules WHERE email='worker@example.com' AND action='in' ORDER BY time_hhmm;")"
  run bash "$TEST_DIR/woffy.sh" schedule user worker@example.com set in 08:00,invalid 1,2,3
  [ "$status" -ne 0 ]
  after="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT group_concat(time_hhmm,',') FROM schedules WHERE email='worker@example.com' AND action='in' ORDER BY time_hhmm;")"
  [ "$after" = "$before" ]
}

@test "report rejects impossible and inverted date ranges" {
  run bash "$TEST_DIR/woffy.sh" report all --from 2025-99-99 --to 2026-01-01
  [ "$status" -ne 0 ]
  run bash "$TEST_DIR/woffy.sh" report all --from 2026-02-02 --to 2026-02-01
  [ "$status" -ne 0 ]
}

@test "events json correctly escapes backslashes and newlines" {
  run bash "$TEST_DIR/woffy.sh" config check
  [ "$status" -eq 0 ]
  sqlite3 "$HOME/.woffy/woffy.db" "INSERT INTO events(email,action,kind,status,message,created_at) VALUES('a@example.com','in','sign','error','path' || char(92) || 'q' || char(10) || 'next',datetime('now','localtime'));"
  run bash "$TEST_DIR/woffy.sh" events all --format json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].message == "path\\q\nnext"' >/dev/null
}

@test "telegram test fails when no destination is configured" {
  run bash "$TEST_DIR/woffy.sh" telegram test
  [ "$status" -ne 0 ]
}

@test "migration upgrades a v2 run_guard table additively" {
  mkdir -p "$HOME/.woffy"
  sqlite3 "$HOME/.woffy/woffy.db" "CREATE TABLE run_guard(email TEXT NOT NULL,action TEXT NOT NULL,run_date TEXT NOT NULL,time_hhmm TEXT NOT NULL,PRIMARY KEY(email,action,run_date,time_hhmm)); INSERT INTO run_guard VALUES('a@example.com','in','2026-01-01','09:00');"
  run bash "$TEST_DIR/woffy.sh" config check
  [ "$status" -eq 0 ]
  state="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT state FROM run_guard;")"
  version="$(sqlite3 "$HOME/.woffy/woffy.db" "PRAGMA user_version;")"
  [ "$state" = "success" ]
  [ "$version" = "3" ]
}

@test "clock in fails closed when workday cannot be verified" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  touch "$TEST_DIR/fail_workday"
  run bash "$TEST_DIR/woffy.sh" in worker@example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot verify workday"* ]]
}

@test "official backfill uses client credentials and bearer token" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  sqlite3 "$HOME/.woffy/woffy.db" "UPDATE user_cards SET woffu_user_id='110654' WHERE email='worker@example.com';"
  run bash -c "printf '%s\n' 'API-SECRET' | '$TEST_DIR/woffy.sh' api configure 123 --secret-stdin"
  [ "$status" -eq 0 ]
  run bash "$TEST_DIR/woffy.sh" sign worker@example.com in 2026-01-01 09:00
  [ "$status" -eq 0 ]
  calls="$(cat "$TEST_DIR/curl.calls")"
  [[ "$calls" == *"grant_type=client_credentials"* ]]
  [[ "$calls" == *"/api/v1/signs"* ]]
  [[ "$calls" != *"API-SECRET"* ]]
}

@test "run due dry-run neither signs nor creates guards" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  now_hhmm="$(date '+%H:%M')"
  dow="$(date '+%u')"
  sqlite3 "$HOME/.woffy/woffy.db" "DELETE FROM schedules; INSERT INTO schedules(email,action,time_hhmm,weekdays,active) VALUES('worker@example.com','in','$now_hhmm','$dow',1);"
  before="$(wc -l < "$TEST_DIR/curl.calls")"
  run bash "$TEST_DIR/woffy.sh" run due --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  guards="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM run_guard;")"
  after="$(wc -l < "$TEST_DIR/curl.calls")"
  [ "$guards" = "0" ]
  [ "$after" = "$before" ]
}

@test "update nightly verifies checksum and replaces the installed binary" {
  export WOFFY_UPDATE_FIXTURE_DIR="$TEST_DIR/update"
  export WOFFY_UPDATE_BASE_URL="https://updates.example.test"
  mkdir -p "$WOFFY_UPDATE_FIXTURE_DIR"
  sed 's/^VERSION="3.0.0"/VERSION="3.0.1"/' "$TEST_DIR/woffy.sh" > "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  chmod +x "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  printf '3.0.1\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.version"
  (cd "$WOFFY_UPDATE_FIXTURE_DIR" && { sha256sum woffy 2>/dev/null || shasum -a 256 woffy; }) > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.sha256"
  run bash "$TEST_DIR/woffy.sh" update nightly
  [ "$status" -eq 0 ]
  run "$BIN_DIR/woffy" version
  [ "$output" = "woffy v3.0.1" ]
  [ -f "$BIN_DIR/woffy.previous" ]
}

@test "update keeps the current binary on checksum or post-check failure" {
  export WOFFY_UPDATE_FIXTURE_DIR="$TEST_DIR/update"
  export WOFFY_UPDATE_BASE_URL="https://updates.example.test"
  mkdir -p "$WOFFY_UPDATE_FIXTURE_DIR"
  sed 's/^VERSION="3.0.0"/VERSION="3.0.1"/' "$TEST_DIR/woffy.sh" > "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  chmod +x "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  printf '3.0.1\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.version"
  printf 'bad  woffy\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.sha256"
  run bash "$TEST_DIR/woffy.sh" update nightly
  [ "$status" -ne 0 ]
  run "$BIN_DIR/woffy" version
  [ "$output" = "woffy v3.0.0" ]

  (cd "$WOFFY_UPDATE_FIXTURE_DIR" && { sha256sum woffy 2>/dev/null || shasum -a 256 woffy; }) > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.sha256"
  export WOFFY_TEST_UPDATE_POSTCHECK_FAIL=true
  run bash "$TEST_DIR/woffy.sh" update nightly
  [ "$status" -ne 0 ]
  run "$BIN_DIR/woffy" version
  [ "$output" = "woffy v3.0.0" ]
}

@test "run due processes different workers in one orchestrator run" {
  for user in a b c; do
    run bash "$TEST_DIR/woffy.sh" login "$user@example.com" secret
    [ "$status" -eq 0 ]
  done
  now_hhmm="$(date '+%H:%M')"
  dow="$(date '+%u')"
  sqlite3 "$HOME/.woffy/woffy.db" "DELETE FROM schedules; INSERT INTO schedules(email,action,time_hhmm,weekdays,active) VALUES
    ('a@example.com','in','$now_hhmm','$dow',1),('b@example.com','in','$now_hhmm','$dow',1),('c@example.com','in','$now_hhmm','$dow',1);"
  run bash "$TEST_DIR/woffy.sh" run due
  [ "$status" -eq 0 ]
  success_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM events WHERE action='in' AND status='success';")"
  guard_count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM run_guard WHERE state='success';")"
  [ "$success_count" = "3" ]
  [ "$guard_count" = "3" ]
}

@test "run due recovers a slot inside the catch-up window" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  past_hhmm="$(date -d '-2 minutes' '+%H:%M' 2>/dev/null || date -v-2M '+%H:%M')"
  past_dow="$(date -d '-2 minutes' '+%u' 2>/dev/null || date -v-2M '+%u')"
  sqlite3 "$HOME/.woffy/woffy.db" "DELETE FROM schedules; INSERT INTO schedules(email,action,time_hhmm,weekdays,active) VALUES('worker@example.com','in','$past_hhmm','$past_dow',1);"
  run bash "$TEST_DIR/woffy.sh" run due
  [ "$status" -eq 0 ]
  guard_time="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT time_hhmm FROM run_guard WHERE email='worker@example.com';")"
  [ "$guard_time" = "$past_hhmm" ]
}

@test "retryable scheduled failure keeps state and later recovers" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  now_hhmm="$(date '+%H:%M')"
  dow="$(date '+%u')"
  sqlite3 "$HOME/.woffy/woffy.db" "DELETE FROM schedules; INSERT INTO schedules(email,action,time_hhmm,weekdays,active) VALUES('worker@example.com','in','$now_hhmm','$dow',1);"
  touch "$TEST_DIR/fail_sign"
  run bash "$TEST_DIR/woffy.sh" run due
  [ "$status" -ne 0 ]
  state="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT state FROM run_guard;")"
  [ "$state" = "retryable" ]
  rm -f "$TEST_DIR/fail_sign"
  sqlite3 "$HOME/.woffy/woffy.db" "UPDATE run_guard SET next_retry_at=datetime('now','-1 minute');"
  run bash "$TEST_DIR/woffy.sh" run due
  [ "$status" -eq 0 ]
  result="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT state || ':' || attempts FROM run_guard;")"
  [ "$result" = "success:2" ]
}

@test "runtime tunables reject zero parallelism and SQL-like values" {
  run env WOFFY_MAX_PARALLEL=0 bash "$TEST_DIR/woffy.sh" version
  [ "$status" -ne 0 ]
  run env WOFFY_RUN_GUARD_RETENTION_DAYS="1'); DROP TABLE users;--" bash "$TEST_DIR/woffy.sh" version
  [ "$status" -ne 0 ]
}

@test "backup and restore use a consistent sqlite snapshot" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  backup="$TEST_DIR/backup.tar.gz"
  run bash "$TEST_DIR/woffy.sh" backup "$backup"
  [ "$status" -eq 0 ]
  sqlite3 "$HOME/.woffy/woffy.db" "DELETE FROM users;"
  run bash "$TEST_DIR/woffy.sh" restore "$backup"
  [ "$status" -eq 0 ]
  count="$(sqlite3 "$HOME/.woffy/woffy.db" "SELECT COUNT(*) FROM users WHERE email='worker@example.com';")"
  [ "$count" = "1" ]
  [ "$(sqlite3 "$HOME/.woffy/woffy.db" 'PRAGMA integrity_check;')" = "ok" ]
}

@test "event purge requires explicit date and confirmation" {
  run bash "$TEST_DIR/woffy.sh" config check
  [ "$status" -eq 0 ]
  sqlite3 "$HOME/.woffy/woffy.db" "INSERT INTO events(email,action,kind,status,message,created_at) VALUES('a@example.com','in','sign','success','old','2020-01-01 00:00:00');"
  run bash "$TEST_DIR/woffy.sh" events purge --before 2021-01-01
  [ "$status" -ne 0 ]
  run bash "$TEST_DIR/woffy.sh" events purge --before 2021-01-01 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Purged 1"* ]]
}

@test "update check reads metadata without replacing the binary" {
  export WOFFY_UPDATE_FIXTURE_DIR="$TEST_DIR/update"
  export WOFFY_UPDATE_BASE_URL="https://updates.example.test"
  mkdir -p "$WOFFY_UPDATE_FIXTURE_DIR"
  printf '3.0.1\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.version"
  run bash "$TEST_DIR/woffy.sh" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Available (stable): v3.0.1"* ]]
  run "$BIN_DIR/woffy" version
  [ "$output" = "woffy v3.0.0" ]
}

@test "update rejects invalid syntax and version mismatch" {
  export WOFFY_UPDATE_FIXTURE_DIR="$TEST_DIR/update"
  export WOFFY_UPDATE_BASE_URL="https://updates.example.test"
  mkdir -p "$WOFFY_UPDATE_FIXTURE_DIR"
  printf '3.0.1\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.version"
  printf '#!/bin/bash\nif then\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  chmod +x "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  (cd "$WOFFY_UPDATE_FIXTURE_DIR" && { sha256sum woffy 2>/dev/null || shasum -a 256 woffy; }) > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.sha256"
  run bash "$TEST_DIR/woffy.sh" update nightly
  [ "$status" -ne 0 ]
  run "$BIN_DIR/woffy" version
  [ "$output" = "woffy v3.0.0" ]

  sed 's/^VERSION="3.0.0"/VERSION="3.0.2"/' "$TEST_DIR/woffy.sh" > "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  chmod +x "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  (cd "$WOFFY_UPDATE_FIXTURE_DIR" && { sha256sum woffy 2>/dev/null || shasum -a 256 woffy; }) > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.sha256"
  run bash "$TEST_DIR/woffy.sh" update nightly
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match metadata"* ]]
}

@test "stable update rejects downgrade unless explicitly allowed" {
  export WOFFY_UPDATE_FIXTURE_DIR="$TEST_DIR/update"
  export WOFFY_UPDATE_BASE_URL="https://updates.example.test"
  mkdir -p "$WOFFY_UPDATE_FIXTURE_DIR"
  printf '2.9.0\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.version"
  run bash "$TEST_DIR/woffy.sh" update
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing downgrade"* ]]
}

@test "update reports metadata network failure without replacing binary" {
  export WOFFY_UPDATE_FIXTURE_DIR="$TEST_DIR/missing-update"
  export WOFFY_UPDATE_BASE_URL="https://updates.example.test"
  mkdir -p "$WOFFY_UPDATE_FIXTURE_DIR"
  run bash "$TEST_DIR/woffy.sh" update --check
  [ "$status" -ne 0 ]
  run "$BIN_DIR/woffy" version
  [ "$output" = "woffy v3.0.0" ]
}

@test "installer verifies release assets and installs the cron orchestrator" {
  export WOFFY_UPDATE_FIXTURE_DIR="$TEST_DIR/install-assets"
  export WOFFY_INSTALL_BASE_URL="https://updates.example.test/stable"
  mkdir -p "$WOFFY_UPDATE_FIXTURE_DIR"
  cp "$TEST_DIR/woffy.sh" "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  chmod +x "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  printf '3.0.0\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.version"
  (cd "$WOFFY_UPDATE_FIXTURE_DIR" && { sha256sum woffy 2>/dev/null || shasum -a 256 woffy; }) > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.sha256"
  run bash "$BATS_TEST_DIRNAME/../install-woffy.sh"
  [ "$status" -eq 0 ]
  run "$HOME/.local/bin/woffy" version
  [ "$output" = "woffy v3.0.0" ]
  grep -q '# woffy-run-due' "$CRON_FILE"
}

@test "installer rejects a release with an invalid checksum" {
  export WOFFY_UPDATE_FIXTURE_DIR="$TEST_DIR/install-assets"
  export WOFFY_INSTALL_BASE_URL="https://updates.example.test/stable"
  mkdir -p "$WOFFY_UPDATE_FIXTURE_DIR"
  cp "$TEST_DIR/woffy.sh" "$WOFFY_UPDATE_FIXTURE_DIR/woffy"
  printf '3.0.0\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.version"
  printf 'bad  woffy\n' > "$WOFFY_UPDATE_FIXTURE_DIR/woffy.sha256"
  run bash "$BATS_TEST_DIRNAME/../install-woffy.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/.local/bin/woffy" ]
}

@test "users shows last run and last error summaries" {
  run bash "$TEST_DIR/woffy.sh" login worker@example.com secret
  [ "$status" -eq 0 ]
  sqlite3 "$HOME/.woffy/woffy.db" "INSERT INTO events(email,action,kind,status,message,created_at) VALUES
    ('worker@example.com','in','sign','success','ok','2026-01-02 09:00:00'),
    ('worker@example.com','out','sign','error','bad','2026-01-02 18:00:00');"
  run bash "$TEST_DIR/woffy.sh" users
  [ "$status" -eq 0 ]
  [[ "$output" == *"LAST_RUN"* ]]
  [[ "$output" == *"LAST_ERROR"* ]]
  [[ "$output" == *"2026-01-02 18:00:00"* ]]
}
