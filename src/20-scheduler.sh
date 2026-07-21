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
