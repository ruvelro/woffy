#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR/home"
  export BIN_DIR="$TEST_DIR/bin"
  export CRON_FILE="$TEST_DIR/crontab.txt"
  mkdir -p "$HOME" "$BIN_DIR"

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
exit 1
EOF
  chmod +x "$BIN_DIR/curl"

  export PATH="$BIN_DIR:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "report --strict fails when from > to" {
  run bash "$TEST_DIR/woffy.sh" report --from 2026-12-31 --to 2026-01-01 --strict
  [ "$status" -ne 0 ]
  [[ "$output" == *"Rango invalido"* ]]
}

@test "report counts current-week log entries" {
  today="$(date '+%Y-%m-%d')"
  old_day="2000-01-01"
  cat > "$HOME/.woffy.log" <<EOF
[$today 09:00:00] Fichaje correcto: in
[$today 18:00:00] Fichaje correcto: out
[$old_day 09:00:00] Fichaje correcto: in
EOF
  run bash "$TEST_DIR/woffy.sh" report --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"entries_in\":1"* ]]
  [[ "$output" == *"\"entries_out\":1"* ]]
}

@test "schedule report writes friday 18:00 cron entry" {
  run bash "$TEST_DIR/woffy.sh" schedule report
  [ "$status" -eq 0 ]
  run bash -c "cat \"$CRON_FILE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"# woffy-report"* ]]
  [[ "$output" == *"report telegram"* ]]
}

@test "backup and restore roundtrip config" {
  cat > "$HOME/.woffy.conf" <<'EOF'
WURL_USER=test@example.com
WURL_PASS=secret
EOF
  run bash "$TEST_DIR/woffy.sh" backup "$TEST_DIR/backup.tgz"
  [ "$status" -eq 0 ]
  rm -f "$HOME/.woffy.conf"
  run bash "$TEST_DIR/woffy.sh" restore "$TEST_DIR/backup.tgz"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.woffy.conf" ]
}

@test "config check rejects unsafe content" {
  cat > "$HOME/.woffy.conf" <<'EOF'
WURL_USER=test@example.com
WURL_PASS=$(id)
EOF
  run bash "$TEST_DIR/woffy.sh" config check
  [ "$status" -ne 0 ]
}

@test "update nightly uses nightly branch url" {
  run bash "$TEST_DIR/woffy.sh" update nightly
  [ "$status" -ne 0 ]
  run bash -c "cat \"$TEST_DIR/curl.calls\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"refs/heads/nightly/woffy.sh"* ]]
}
