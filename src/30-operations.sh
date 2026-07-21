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
  local tmp checksum_tmp expected actual bin_path bin_dir previous installed_version
  local pre_update_backup doctor_output doctor_status

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

  bin_path="$(get_bin_path)"
  [ -n "$bin_path" ] || {
    echo "ERROR Current woffy binary not found" >&2
    return 1
  }
  bin_dir="$(dirname "$bin_path")"

  # 1. Download the new binary to a temp file on the same filesystem as the
  #    installed binary, so the later replace step can be a true atomic mv.
  tmp="$(mktemp "$bin_dir/.woffy.update.XXXXXX")" || {
    echo "ERROR Could not create temp file for update" >&2
    return 1
  }
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

  # 2. Verify the SHA-256 checksum.
  expected="$(awk 'NR==1{print $1}' "$checksum_tmp")"
  actual="$(sha256_file "$tmp")"
  rm -f "$checksum_tmp"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    rm -f "$tmp"
    echo "ERROR Update checksum mismatch" >&2
    return 1
  fi

  # 3. Syntax check.
  bash -n "$tmp" || {
    rm -f "$tmp"
    echo "ERROR Downloaded update failed syntax check" >&2
    return 1
  }

  # 4. Reject CRLF line endings (corrupted transfer or wrong platform asset).
  if LC_ALL=C grep -q $'\r' "$tmp"; then
    rm -f "$tmp"
    echo "ERROR Downloaded update contains CRLF line endings" >&2
    return 1
  fi

  chmod +x "$tmp"

  # 5. Confirm the downloaded binary reports the expected version.
  installed_version="$("$tmp" version 2>/dev/null | awk '/^woffy v/{sub(/^woffy v/,""); print; exit}')"
  if [ "$installed_version" != "$target_version" ]; then
    rm -f "$tmp"
    echo "ERROR Update binary version does not match metadata" >&2
    return 1
  fi

  # 6. Preserve the current binary for rollback.
  previous="$bin_path.previous"
  cp -p "$bin_path" "$previous" || {
    rm -f "$tmp"
    echo "ERROR Could not preserve current binary" >&2
    return 1
  }

  # 7. Safety backup of settings/DB before touching the installed binary.
  pre_update_backup="$(backup_files "$WOFFY_HOME/pre-update-$(date +%Y%m%d-%H%M%S).tar.gz" 2>/dev/null || true)"
  if [ -n "$pre_update_backup" ] && [ -f "$pre_update_backup" ]; then
    echo "OK Pre-update backup: $pre_update_backup"
  else
    echo "WARN Could not create pre-update backup; continuing" >&2
  fi

  # 8. Atomic replace: tmp and bin_path share a filesystem (step 1), so mv
  #    either fully succeeds or leaves the original binary untouched.
  if ! mv "$tmp" "$bin_path"; then
    rm -f "$tmp"
    echo "ERROR Could not install update" >&2
    return 1
  fi

  # 9. Post-install health check; roll back automatically on any failure.
  doctor_output="$("$bin_path" doctor 2>&1)"
  doctor_status=$?
  installed_version="$("$bin_path" version 2>/dev/null || true)"
  if [ "$doctor_status" -ne 0 ] || [ "$installed_version" != "woffy v$target_version" ] ||
    [ "${WOFFY_TEST_UPDATE_POSTCHECK_FAIL:-false}" = "true" ]; then
    mv "$previous" "$bin_path"
    echo "ERROR Updated binary failed post-update doctor check; previous binary restored" >&2
    echo "$doctor_output" >&2
    return 1
  fi
  echo "OK Woffy updated to v$target_version from '$channel'."
  echo "Rollback: $previous"
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
  woffy telegram {configure --token-stdin <chat-id> [thread-id] [mode]|set-mode {all|errors|success}|test|clear}
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
