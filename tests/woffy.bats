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
if [[ "$args" == *"/token"* ]]; then
  printf '{"access_token":"token-%s","expires_in":%s}\n' "$(date +%s)" "${WOFFY_TOKEN_EXPIRES_IN:-3600}"
  exit 0
fi
if [[ "$args" == *"/api/users/"*"/workdaylite"* ]]; then
  printf '{"ScheduleHours":8,"IsWeekend":false,"IsHoliday":false,"IsEvent":false}\n'
  exit 0
fi
if [[ "$args" == *"/api/users"* ]]; then
  printf '[{"UserId":"u-1","FullName":"Test User","CompanyName":"Acme","OfficeName":"HQ","Schedule":{"Name":"Default"}}]\n'
  exit 0
fi
if [[ "$args" == *"/api/signs"* && "$args" == *"-X POST"* ]]; then
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

@test "update nightly uses nightly branch url" {
  run bash "$TEST_DIR/woffy.sh" update nightly
  [ "$status" -ne 0 ]
  calls="$(cat "$TEST_DIR/curl.calls")"
  [[ "$calls" == *"refs/heads/nightly/woffy.sh"* ]]
}
