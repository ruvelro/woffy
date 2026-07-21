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
  [ -n "$client_id" ] && [ -n "$client_secret" ] || {
    echo "ERROR Woffu integration is not configured" >&2
    return 1
  }
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
