#!/bin/bash
set -euo pipefail

VERSION="1.3.0"

# Rutas
CONFIG_FILE="$HOME/.woffy.conf"
TOKEN_FILE="$HOME/.woffy.token"
LOG_FILE="$HOME/.woffy.log"
LOCK_DIR="$HOME/.woffy.lock.d"
USER_FILE="$HOME/.woffy.user"

API_URL="https://app.woffu.com"
REPO_RAW_BASE="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main"

NO_TELEGRAM=false

# Global flags
if [ "$#" -gt 0 ]; then
  FILTERED_ARGS=()
  for arg in "$@"; do
    case "$arg" in
      --no-telegram) NO_TELEGRAM=true ;;
      *) FILTERED_ARGS+=("$arg") ;;
    esac
  done
  set -- "${FILTERED_ARGS[@]}"
fi

# 
# Utils
# 
LOG_MAX_BYTES_DEFAULT=1048576
LOG_MAX_FILES_DEFAULT=5

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

rotate_log_if_needed() {
  [ -f "$LOG_FILE" ] || return 0
  local max_bytes max_files size i prev next
  max_bytes="${WOFFY_LOG_MAX_BYTES:-$LOG_MAX_BYTES_DEFAULT}"
  max_files="${WOFFY_LOG_MAX_FILES:-$LOG_MAX_FILES_DEFAULT}"
  is_int "$max_bytes" || max_bytes="$LOG_MAX_BYTES_DEFAULT"
  is_int "$max_files" || max_files="$LOG_MAX_FILES_DEFAULT"
  [ "$max_files" -lt 1 ] && max_files=1
  size="$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
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
  : > "$LOG_FILE"
}

log() {
  rotate_log_if_needed
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

check_deps() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "❌ Falta dependencia crítica: $cmd"
      exit 1
    }
  done
}

write_kv_line() {
  local key="$1"
  local value="${2-}"
  printf '%s=%q\n' "$key" "$value"
}

date_days_ago() {
  local days="$1"
  if date -d "$days days ago" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
    date -d "$days days ago" "+%Y-%m-%d %H:%M:%S"
  else
    date -v-"$days"d "+%Y-%m-%d %H:%M:%S"
  fi
}

current_week_start_date() {
  local dow offset
  dow="$(date '+%u' 2>/dev/null || echo 1)"
  offset=$((dow - 1))
  if [ "$offset" -eq 0 ]; then
    date "+%Y-%m-%d"
    return
  fi
  if date -d "today -$offset days" "+%Y-%m-%d" >/dev/null 2>&1; then
    date -d "today -$offset days" "+%Y-%m-%d"
  else
    date -v-"$offset"d "+%Y-%m-%d"
  fi
}

is_valid_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

date_to_boundary() {
  local day="$1"
  local mode="${2:-start}" # start|end
  if [ "$mode" = "end" ]; then
    echo "$day 23:59:59"
  else
    echo "$day 00:00:00"
  fi
}

json_escape() {
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

validate_kv_file() {
  local file="$1"
  local kind="$2"
  local line key val
  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 1
    key="${line%%=*}"
    val="${line#*=}"

    case "$kind" in
      config)
        [[ "$key" =~ ^(WURL_USER|WURL_PASS|TG_TOKEN|TG_CHAT_ID|TG_THREAD|TG_NOTIFY|WOFFY_TZ|WOFFY_LOG_MAX_BYTES|WOFFY_LOG_MAX_FILES)$ ]] || return 1
        ;;
      token)
        [[ "$key" =~ ^(WOFFY_TOKEN|WOFFY_TOKEN_EXP)$ ]] || return 1
        ;;
      user)
        [[ "$key" =~ ^(WOFFY_USER_VERSION|WOFFY_USER_FETCHED_AT|WOFFY_USER_ID|WOFFY_USER_NUMBER|WOFFY_FULL_NAME|WOFFY_EMAIL|WOFFY_COMPANY_ID|WOFFY_COMPANY_NAME|WOFFY_OFFICE_NAME|WOFFY_SCHEDULE_NAME)$ ]] || return 1
        ;;
      *)
        return 1
        ;;
    esac

    case "$val" in
      *\$\(*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*)
        return 1
        ;;
    esac
  done < "$file"

  return 0
}

safe_source_file() {
  local file="$1"
  local kind="$2"
  validate_kv_file "$file" "$kind" || {
    echo "❌ Archivo invalido o inseguro: $file"
    log "Archivo bloqueado por validacion: $file ($kind)"
    exit 1
  }
  # shellcheck disable=SC1090
  source "$file"
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
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return
  fi

  local dir_pid
  dir_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
  if [ -n "$dir_pid" ] && kill -0 "$dir_pid" 2>/dev/null; then
    log "Lock activo (PID $dir_pid). Abortando ejecución concurrente."
    exit 0
  fi

  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return
  fi

  log "No se pudo adquirir lock atómico."
  exit 1
}

# 
# Telegram
# 
tg_send() {
  [ "$NO_TELEGRAM" = "true" ] && return
  [ -z "${TG_TOKEN:-}" ] && return
  [ -z "${TG_CHAT_ID:-}" ] && return

  local TYPE="$1"  # error | success | info | test
  local MSG="$2"
  local FORCE="${3:-false}"

  if [ "$FORCE" != "true" ]; then
    case "${TG_NOTIFY:-all}" in
      all) ;;
      errors)  [ "$TYPE" != "error" ] && return ;;
      success) [ "$TYPE" != "success" ] && return ;;
      *) ;;
    esac
  fi

  local curl_args
  curl_args=(-s --max-time 10 -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$MSG")
  if [ -n "${TG_THREAD:-}" ]; then
    [[ "${TG_THREAD:-}" =~ ^-?[0-9]+$ ]] || {
      log "TG_THREAD invalido. Debe ser numerico."
      return
    }
    curl_args+=(-d "message_thread_id=$TG_THREAD")
  fi

  curl "${curl_args[@]}" > /dev/null || log "Error enviando a Telegram"
}

# 
# Cargar config cuando haga falta
# 
need_config=true
case "${1:-}" in
  help|version|login|uninstall|schedule|report|update|backup|restore|changelog|self-test|notify|config|"")
    need_config=false
    ;;
esac

if $need_config; then
  [ ! -f "$CONFIG_FILE" ] && { echo "❌ Configuración no encontrada. Ejecuta 'woffy login'"; exit 1; }
  safe_source_file "$CONFIG_FILE" "config"
fi

# 
# Token
# 
get_token() {
  : "${WURL_USER:?Credenciales no configuradas. Ejecuta 'woffy login'}"
  : "${WURL_PASS:?Credenciales no configuradas. Ejecuta 'woffy login'}"
  local now response token expires exp
  now=$(date +%s)

  if [ -f "$TOKEN_FILE" ]; then
    if validate_kv_file "$TOKEN_FILE" "token"; then
      safe_source_file "$TOKEN_FILE" "token" 2>/dev/null || true
    fi
    if [ -n "${WOFFY_TOKEN:-}" ] && [ "${WOFFY_TOKEN_EXP:-0}" -gt "$((now + 60))" ]; then
      echo "$WOFFY_TOKEN"
      return
    fi
  fi

  log "Renovando token OAuth..."
  response="$(curl -s -X POST "$API_URL/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "username=$WURL_USER" \
  --data-urlencode "password=$WURL_PASS" || true)"

  token="$(echo "$response" | jq -r .access_token 2>/dev/null || echo "")"
  expires="$(echo "$response" | jq -r '.expires_in // 3600' 2>/dev/null || echo "3600")"

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    log "ERROR API Auth: $response"
    echo "❌ Error autenticando con Woffu"
    tg_send error "❌ woffy: Credenciales inválidas o error de API."
    exit 1
  fi

  exp=$((now + expires - 60))
  {
    write_kv_line "WOFFY_TOKEN" "$token"
    echo "WOFFY_TOKEN_EXP=$exp"
  } > "$TOKEN_FILE" 2>/dev/null || true
  chmod 600 "$TOKEN_FILE" 2>/dev/null || true

  log "Token renovado exitosamente."
  echo "$token"
}

# Epoch -> fecha/hora portable (GNU/BSD)
fmt_epoch() {
  local epoch="$1"
  if date -d "@$epoch" "+%d/%m/%Y a las %H:%M" >/dev/null 2>&1; then
    date -d "@$epoch" "+%d/%m/%Y a las %H:%M"
  else
    date -r "$epoch" "+%d/%m/%Y a las %H:%M"
  fi
}

token_status_human() {
  [ ! -f "$TOKEN_FILE" ] && { echo "NO"; return; }
  validate_kv_file "$TOKEN_FILE" "token" || { echo "INVALIDO"; return; }
  safe_source_file "$TOKEN_FILE" "token" 2>/dev/null || { echo "INVALIDO"; return; }
  [ -z "${WOFFY_TOKEN_EXP:-}" ] && { echo "INVALIDO"; return; }

  local now exp_h
  now=$(date +%s)
  exp_h="$(fmt_epoch "$WOFFY_TOKEN_EXP" 2>/dev/null || echo "")"

  if [ -z "$exp_h" ]; then
    echo "OK (expira en epoch=$WOFFY_TOKEN_EXP)"
    return
  fi

  if [ "$WOFFY_TOKEN_EXP" -le "$now" ]; then
    echo "EXPIRADO (caducó el $exp_h)"
  else
    echo "OK (expira el $exp_h)"
  fi
}

# 
# API core
# 
api_get_raw() {
  local path="$1"
  [ -z "${TOKEN:-}" ] && return 1
  curl -fsS --max-time 15 \
    -H "Authorization: Bearer $TOKEN" \
    "$API_URL$path"
}

get_status() {
  local body="" signin=""

  if ! body="$(api_get_raw "/api/signs" 2>/dev/null)"; then
    log "Error accediendo a /api/signs"
    echo "unknown"
    return 0
  fi

  if ! echo "$body" | jq -e 'type=="array"' >/dev/null 2>&1; then
    log "JSON inesperado en /api/signs"
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
      | if length == 0 then "out"
        else last.SignIn
        end
    '
  )"

  case "$signin" in
    true|1|in)   echo "in"  ;;
    false|0|out) echo "out" ;;
    *)           echo "unknown" ;;
  esac
}


post_sign() {
  local action="$1"
  local now json_data resp status_code body

  now=$(date -Iseconds)

  # shellcheck disable=SC2016
  json_data="$(jq -nc --arg date "$now" --arg action "$action" \
    '{signType:0, date:$date, action:$action}')"

  resp="$(curl -s -w "\n%{http_code}" -X POST "$API_URL/api/signs" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$json_data" || true)"

  status_code="$(echo "$resp" | tail -n1)"
  # shellcheck disable=SC2016
  body="$(echo "$resp" | sed '$d')"

  if [[ "$status_code" =~ ^2 ]]; then
    return 0
  else
    log "Error API Sign ($action): HTTP $status_code | $body"
    return 1
  fi
}

run_sign_flow() {
  local mode="$1"          # in | out
  local dry_run="${2:-false}"
  local st wd reason action msg

  st="$(get_status)"
  log "Solicitud: $mode | Estado actual: $st | DryRun=$dry_run"

  if [ "$st" = "unknown" ]; then
    msg="⚠️ No se puede determinar el estado actual. Abortando por seguridad."
    echo "$msg"
    tg_send error "$msg"
    return 1
  fi

  if [ "$mode" = "in" ] && [ "$st" = "in" ]; then
    msg="⚠️ No ficho IN: ya estabas DENTRO."
    echo "$msg"
    log "$msg"
    tg_send error "$msg"
    return 0
  fi

  if [ "$mode" = "out" ] && [ "$st" = "out" ]; then
    msg="⚠️ No ficho OUT: ya estabas FUERA."
    echo "$msg"
    log "$msg"
    tg_send error "$msg"
    return 0
  fi

  if [ "$mode" = "in" ]; then
    wd="$(get_workday)"
    if [ -n "$wd" ] && ! is_workday_ok_for_in "$wd"; then
      reason="$(workday_reason "$wd")"
      [ -z "$reason" ] && reason="día no laborable"
      msg="⚠️ No se ficha entrada: $reason."
      echo "$msg"
      log "$msg"
      tg_send error "$msg"
      return 0
    fi
  fi

  if [ "$dry_run" = "true" ]; then
    msg="ℹ️ DRY-RUN: se ficharía '$mode' ahora."
    echo "$msg"
    log "$msg"
    tg_send info "$msg"
    return 0
  fi

  action="clock_in"
  [ "$mode" = "out" ] && action="clock_out"

  local max_retries retry_delay attempt success
  max_retries=4
  retry_delay=15
  attempt=1
  success=false

  while [ "$attempt" -le "$max_retries" ]; do
    if post_sign "$action"; then
      success=true
      break
    fi

    log "Intento $attempt/$max_retries fallido al fichar $mode."
    if [ "$attempt" -lt "$max_retries" ]; then
      log "Reintentando en ${retry_delay}s..."
      sleep "$retry_delay"
    fi
    attempt=$((attempt + 1))
  done

  if $success; then
    msg="✅ Fichaje correcto: $mode"
    echo "$msg"
    log "$msg"
    tg_send success "✅ *woffy*: Fichaje *$mode* realizado ($(date +%H:%M))."
    return 0
  fi

  msg="❌ Error al fichar $mode en la API tras $max_retries intentos."
  echo "$msg"
  log "$msg"
  tg_send error "$msg"
  return 1
}

build_weekly_report() {
  local since="$1"
  local until="$2"
  local format="${3:-text}" # text|json|csv
  local now in_count out_count err_count warn_count counts
  now="$(date '+%Y-%m-%d %H:%M:%S')"

  if [ ! -f "$LOG_FILE" ]; then
    in_count=0; out_count=0; err_count=0; warn_count=0
  else
    counts="$(awk -v since="$since" -v until="$until" '
      /^\[/ {
        ts = substr($0,2,19)
        if (ts < since || ts > until) next
        if (index($0,"Fichaje correcto: in") > 0) in_count++
        if (index($0,"Fichaje correcto: out") > 0) out_count++
        if (index($0,"Error al fichar") > 0) err_count++
        if ($0 ~ /(No ficho IN|No ficho OUT|No se ficha entrada|Abortando por seguridad)/) warn_count++
      }
      END {
        printf "%d;%d;%d;%d\n", in_count + 0, out_count + 0, err_count + 0, warn_count + 0
      }
    ' "$LOG_FILE")"
    IFS=';' read -r in_count out_count err_count warn_count <<< "$counts"
  fi

  case "$format" in
    json)
      cat <<EOF
{"generated_at":"$(json_escape "$now")","from":"$(json_escape "$since")","to":"$(json_escape "$until")","entries_in":$in_count,"entries_out":$out_count,"warnings":$warn_count,"errors":$err_count}
EOF
      ;;
    csv)
      echo "generated_at,from,to,entries_in,entries_out,warnings,errors"
      echo "\"$now\",\"$since\",\"$until\",$in_count,$out_count,$warn_count,$err_count"
      ;;
    *)
      cat <<EOF
📊 Reporte woffy
Periodo: $since -> $until
Generado: $now
✅ Entradas: $in_count
✅ Salidas: $out_count
⚠️ Avisos: $warn_count
❌ Errores: $err_count
EOF
      ;;
  esac
}

self_test() {
  local fails=0
  local ok=0
  local msg

  check_item() {
    local name="$1"
    shift
    if "$@"; then
      echo "✅ $name"
      ok=$((ok + 1))
    else
      echo "❌ $name"
      fails=$((fails + 1))
    fi
  }

  file_perm_600() {
    local f="$1"
    local p=""
    [ ! -f "$f" ] && return 1
    p="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || echo "")"
    [ "$p" = "600" ]
  }

  check_item "Dependencias base (curl)" command -v curl
  check_item "Dependencias JSON (jq)" command -v jq
  check_item "Archivo config legible" test -f "$CONFIG_FILE"
  check_item "Permiso config 600" file_perm_600 "$CONFIG_FILE"
  check_item "Comando crontab disponible" command -v crontab
  check_item "Log accesible" touch "$LOG_FILE"

  if [ -f "$CONFIG_FILE" ]; then
    safe_source_file "$CONFIG_FILE" "config" 2>/dev/null || true
    msg="$(get_token 2>/dev/null || true)"
    if [ -n "$msg" ]; then
      echo "✅ Token API disponible"
      ok=$((ok + 1))
    else
      echo "⚠️ Token API no disponible (credenciales/API)"
    fi
  else
    echo "⚠️ Sin config: no se prueba autenticación API"
  fi

  echo "Resumen self-test: OK=$ok FAIL=$fails"
  [ "$fails" -eq 0 ]
}

# 
# Workdaylite (solo para IN)
# 
get_user_id() {
  if [ -f "$USER_FILE" ]; then
    if validate_kv_file "$USER_FILE" "user"; then
      safe_source_file "$USER_FILE" "user" 2>/dev/null || true
    fi
    [ -n "${WOFFY_USER_ID:-}" ] && { echo "$WOFFY_USER_ID"; return; }
  fi

  local uj
  uj="$(api_get_raw "/api/users")"
  echo "$uj" | jq -r 'if type=="array" then .[0].UserId else .UserId end // empty' 2>/dev/null || true
}

get_workday() {
  local uid
  uid="$(get_user_id)"
  [ -z "$uid" ] && { echo ""; return; }
  api_get_raw "/api/users/$uid/workdaylite"
}

workday_reason() {
  local wd="$1"
  local sh iw ih ie
  sh="$(echo "$wd" | jq -r '.ScheduleHours // 0' 2>/dev/null || echo "0")"
  iw="$(echo "$wd" | jq -r '.IsWeekend // false' 2>/dev/null || echo "false")"
  ih="$(echo "$wd" | jq -r '.IsHoliday // false' 2>/dev/null || echo "false")"
  ie="$(echo "$wd" | jq -r '.IsEvent // false' 2>/dev/null || echo "false")"

  if [ "$ih" = "true" ]; then echo "vacaciones/festivo (IsHoliday=true)";
  elif [ "$ie" = "true" ]; then echo "evento/ausencia (IsEvent=true)";
  elif [ "$iw" = "true" ]; then echo "fin de semana (IsWeekend=true)";
  elif awk "BEGIN{exit !($sh<=0)}"; then echo "sin horas programadas (ScheduleHours=$sh)";
  else echo ""; fi
}

is_workday_ok_for_in() {
  local wd="$1"
  [ -z "$wd" ] && return 0
  local sh
  sh="$(echo "$wd" | jq -r '.ScheduleHours // 0' 2>/dev/null || echo "0")"
  awk "BEGIN{exit !($sh>0)}"
}

# 
# User card (ficha de trabajador)
# 
save_user_card() {
  local uj="$1"
  local obj
  obj="$(echo "$uj" | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")"
  [ -z "$obj" ] && return 1

  local uid un full email cid cname office sched now

  now="$(date +%s)"
  
  uid="$(echo "$obj" | jq -r '.UserId // empty')"
  un="$(echo "$obj" | jq -r '.UserNumber // empty')"
  full="$(echo "$obj" | jq -r '.FullName // empty')"
  email="$(echo "$obj" | jq -r '.Email // empty')"
  cid="$(echo "$obj" | jq -r '.CompanyId // empty')"
  cname="$(echo "$obj" | jq -r '.CompanyName // empty')"
  office="$(echo "$obj" | jq -r '.OfficeName // empty')"
  sched="$(echo "$obj" | jq -r '.Schedule.Name // .ScheduleName // empty')"

  {
    echo "# woffy user card v1"
    echo "WOFFY_USER_VERSION=1"
    echo "WOFFY_USER_FETCHED_AT=\"$now\""
    write_kv_line "WOFFY_USER_ID" "$uid"
    write_kv_line "WOFFY_USER_NUMBER" "$un"
    write_kv_line "WOFFY_FULL_NAME" "$full"
    write_kv_line "WOFFY_EMAIL" "$email"
    write_kv_line "WOFFY_COMPANY_ID" "$cid"
    write_kv_line "WOFFY_COMPANY_NAME" "$cname"
    write_kv_line "WOFFY_OFFICE_NAME" "$office"
    write_kv_line "WOFFY_SCHEDULE_NAME" "$sched"
  } > "$USER_FILE" 2>/dev/null || true
  chmod 600 "$USER_FILE" 2>/dev/null || true
  return 0
}

user_card_summary() {
  [ ! -f "$USER_FILE" ] && { echo "NO"; return; }
  validate_kv_file "$USER_FILE" "user" || { echo "INVALIDO"; return; }
  safe_source_file "$USER_FILE" "user" 2>/dev/null || { echo "INVALIDO"; return; }
  if [ -n "${WOFFY_FULL_NAME:-}" ]; then
    echo "OK"
  else
    echo "PARCIAL"
  fi
}

# 
# Cron
# 
clear_woffy_cron() {
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v '# woffy-' > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
}

pause_woffy_cron() {
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | awk '
    {
      if ($0 ~ /# woffy-/ && $0 !~ /^# PAUSED-WOFFY /) {
        print "# PAUSED-WOFFY " $0
      } else {
        print
      }
    }
  ' > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
}

resume_woffy_cron() {
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | sed 's/^# PAUSED-WOFFY //' > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
}

validate_time() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; }

backup_files() {
  local out="${1:-$HOME/woffy-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir"
  [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$tmpdir/"
  [ -f "$TOKEN_FILE" ] && cp "$TOKEN_FILE" "$tmpdir/"
  [ -f "$USER_FILE" ] && cp "$USER_FILE" "$tmpdir/"
  [ -f "$LOG_FILE" ] && cp "$LOG_FILE" "$tmpdir/"
  tar -czf "$out" -C "$tmpdir" . >/dev/null 2>&1
  rm -rf "$tmpdir"
  echo "$out"
}

restore_files() {
  local in="$1"
  [ ! -f "$in" ] && return 1
  local tmpdir
  tmpdir="$(mktemp -d)"
  tar -xzf "$in" -C "$tmpdir" >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 1; }
  [ -f "$tmpdir/.woffy.conf" ] && cp "$tmpdir/.woffy.conf" "$CONFIG_FILE"
  [ -f "$tmpdir/.woffy.token" ] && cp "$tmpdir/.woffy.token" "$TOKEN_FILE"
  [ -f "$tmpdir/.woffy.user" ] && cp "$tmpdir/.woffy.user" "$USER_FILE"
  [ -f "$tmpdir/.woffy.log" ] && cp "$tmpdir/.woffy.log" "$LOG_FILE"
  chmod 600 "$CONFIG_FILE" "$TOKEN_FILE" "$USER_FILE" 2>/dev/null || true
  rm -rf "$tmpdir"
  return 0
}

upsert_config_key() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$CONFIG_FILE" ]; then
    grep -v "^${key}=" "$CONFIG_FILE" > "$tmp" || true
  fi
  write_kv_line "$key" "$value" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

install_systemd_user_timers() {
  local script="$1"
  local dir="$HOME/.config/systemd/user"
  mkdir -p "$dir"

  cat > "$dir/woffy-in.service" <<EOF
[Unit]
Description=Woffy clock in
[Service]
Type=oneshot
ExecStart=$script in
EOF
  cat > "$dir/woffy-in.timer" <<'EOF'
[Unit]
Description=Woffy IN timer
[Timer]
OnCalendar=Mon..Fri 09:00
OnCalendar=Mon..Fri 15:30
Persistent=true
[Install]
WantedBy=timers.target
EOF

  cat > "$dir/woffy-out.service" <<EOF
[Unit]
Description=Woffy clock out
[Service]
Type=oneshot
ExecStart=$script out
EOF
  cat > "$dir/woffy-out.timer" <<'EOF'
[Unit]
Description=Woffy OUT timer
[Timer]
OnCalendar=Mon..Fri 14:00
OnCalendar=Mon..Fri 18:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

  cat > "$dir/woffy-report.service" <<EOF
[Unit]
Description=Woffy weekly report
[Service]
Type=oneshot
ExecStart=$script report telegram
EOF
  cat > "$dir/woffy-report.timer" <<'EOF'
[Unit]
Description=Woffy weekly report timer
[Timer]
OnCalendar=Fri 18:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now woffy-in.timer woffy-out.timer woffy-report.timer
}

remove_systemd_user_timers() {
  local dir="$HOME/.config/systemd/user"
  systemctl --user disable --now woffy-in.timer woffy-out.timer woffy-report.timer 2>/dev/null || true
  rm -f "$dir/woffy-in.service" "$dir/woffy-in.timer" \
        "$dir/woffy-out.service" "$dir/woffy-out.timer" \
        "$dir/woffy-report.service" "$dir/woffy-report.timer"
  systemctl --user daemon-reload 2>/dev/null || true
}

show_changelog() {
  local remote local_v remote_v
  local_v="$VERSION"
  echo "Versión local: $local_v"
  remote="$(curl -fsSL "${REPO_RAW_BASE}/woffy.sh" 2>/dev/null || true)"
  if [ -z "$remote" ]; then
    echo "⚠️ No se pudo consultar versión remota."
    return 0
  fi
  # shellcheck disable=SC2016
  remote_v="$(echo "$remote" | awk -F'"' '/^VERSION=/{print $2; exit}')"
  [ -z "$remote_v" ] && remote_v="desconocida"
  echo "Versión remota: $remote_v"
  if [ "$remote_v" = "$local_v" ]; then
    echo "✅ Estás al día."
  else
    echo "ℹ️ Hay actualización disponible."
  fi

  echo
  echo "Últimos cambios (commits):"
  curl -fsSL "https://api.github.com/repos/ruvelro/woffy/commits?per_page=8" 2>/dev/null \
    | jq -r '.[] | "- " + (.commit.message | split("\n")[0]) + " (" + (.sha[0:7]) + ")"' 2>/dev/null \
    || echo "- No disponible"
}

# 
# Help
# 
show_help() {
cat <<EOF
woffy v$VERSION - CLI para fichar en Woffu (modo usuario, sin sudo)

USO:
  woffy [--no-telegram] <comando> [subcomando] [opciones]

COMANDOS PRINCIPALES:
  in                 Fichar entrada (solo ficha si estabas fuera y hoy hay horas programadas)
  out                Fichar salida  (solo ficha si estabas dentro)
  dry-run            Simular fichaje sin enviar nada a la API (dry-run in|out)
  status             Mostrar estado actual (in/out/unknown)
  report             Reporte de fichajes (admite --from/--to/--format/--strict/telegram)
  config             Validar configuracion local sin ejecutar nada (config check)
  notify             Enviar notificación de prueba a Telegram (notify test ...)
  self-test          Prueba automática de dependencias y estado local
  backup             Backup de config/token/user/log
  restore            Restaurar backup de woffy
  changelog          Versión local/remota y últimos commits
  user               Mostrar ficha de trabajador
  login              Guardar credenciales y generar ficha de trabajador (~/.woffy.user)
  telegram           Configurar Telegram (token/chat/thread/notify) y enviar test
  telegram test      Enviar mensaje de prueba a Telegram
  doctor             Diagnóstico completo (doctor --json)
  update             Actualizar woffy (main por defecto, nightly opcional)
  schedule           Gestionar cron
  version            Mostrar versión
  uninstall          Desinstalar woffy (borra binario, config y cron)
  help               Mostrar esta ayuda

CONFIGURACIÓN:
  - Credenciales: $CONFIG_FILE
  - Token cache:  $TOKEN_FILE
  - Log:          $LOG_FILE
  - Lock:         $LOCK_DIR
  - Ficha:        $USER_FILE

TELEGRAM:
  woffy telegram
    - Token Bot (ej: 123:ABC)
    - Chat ID (ej: -100xxxx)
    - Thread ID (opcional, para topics)
    - Notify: all | errors | success
  woffy telegram test

CRON / SCHEDULE:
  woffy schedule list
  woffy schedule clear
  woffy schedule pause
  woffy schedule resume
  woffy schedule timezone Europe/Madrid
  woffy schedule report            (viernes 18:00)
  woffy schedule systemd enable|disable|status
  woffy schedule entrada HH:MM   (L-V)
  woffy schedule salida  HH:MM   (L-V)

EJEMPLOS:
  woffy login
  woffy status
  woffy dry-run in
  woffy report --format json
  woffy report --strict --from 2026-01-31 --to 2026-01-01
  woffy report --from 2026-01-01 --to 2026-01-31
  woffy config check
  woffy update nightly
  woffy notify test warning "Mensaje de prueba"
  woffy backup
  woffy changelog
  woffy in
  woffy out
  woffy telegram
  woffy schedule clear
  woffy schedule entrada 09:00
  woffy schedule salida 18:00

NOTAS:
  - 'report' usa por defecto la semana en curso (lunes -> hoy).
  - Para 'in', woffy consulta /workdaylite y NO ficha si ScheduleHours <= 0.
  - Si la API no permite determinar estado (unknown), woffy aborta por seguridad.
  - Toda la información del usuario se guarda localmente tras 'woffy login'.
EOF
}

# 
# Main
# 
case "${1:-}" in
  help|"")
    show_help
    ;;

  version)
    echo "woffy v$VERSION"
    ;;

  login)
    check_deps curl jq date
    if [ $# -ge 3 ]; then
      EMAIL="$2"
      PASS="$3"
    else
      read -r -p "Correo: " EMAIL
      read -r -s -p "Contraseña: " PASS
      echo
    fi

    # 1. Crear el archivo si no existe
    touch "$CONFIG_FILE" 
    
    # 2. Filtrar y guardar (forma segura para set -e)
    tmp="$(mktemp)"
    if [ -s "$CONFIG_FILE" ]; then
        grep -v '^WURL_' "$CONFIG_FILE" > "$tmp" || true
    fi
    
    {
      write_kv_line "WURL_USER" "$EMAIL"
      write_kv_line "WURL_PASS" "$PASS"
    } >> "$tmp"
    
    mv "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    rm -f "$TOKEN_FILE" 2>/dev/null || true
  
    # 3. Exportar para uso inmediato
    export WURL_USER="$EMAIL"
    export WURL_PASS="$PASS"
  
    TOKEN="$(get_token)"
    export TOKEN
    
    # 4. Obtener ficha
    uj="$(api_get_raw "/api/users" || true)"
    
    if [ -n "$uj" ] && echo "$uj" | jq -e 'if type=="array" then .[0].UserId else .UserId end' >/dev/null 2>&1; then
      save_user_card "$uj"
      echo "✅ Login correcto. Ficha de trabajador guardada."
    else
      echo "⚠️ Login OK, pero no se pudo generar la ficha de usuario (API error)."
    fi
    ;;


  user)
    if [ ! -f "$USER_FILE" ]; then
      echo "❌ No existe ficha de usuario. Ejecuta: woffy login"
      exit 1
    fi

    validate_kv_file "$USER_FILE" "user" || {
      echo "ERROR Ficha de usuario corrupta/insegura."
      exit 1
    }
    safe_source_file "$USER_FILE" "user" 2>/dev/null || {
      echo "ERROR Ficha de usuario corrupta."
      exit 1
    }

    echo "👤 Usuario Woffy"
    echo "Nombre:   ${WOFFY_FULL_NAME:-?}"
    echo "Email:    ${WOFFY_EMAIL:-?}"
    echo "Empresa:  ${WOFFY_COMPANY_NAME:-?}"
    echo "Oficina:  ${WOFFY_OFFICE_NAME:-?}"
    echo "User ID:  ${WOFFY_USER_ID:-?}"
    echo "User Nº:  ${WOFFY_USER_NUMBER:-?}"
    echo "Horario:  ${WOFFY_SCHEDULE_NAME:-?}"
    ;;

  telegram)
    check_deps curl
    if [ "${2:-}" = "test" ]; then
      safe_source_file "$CONFIG_FILE" "config" 2>/dev/null || true
      tg_send test "🟢 Telegram OK (woffy)"
      echo "✅ Mensaje enviado."
      exit 0
    fi

    echo "Configuración de Telegram (Enter para saltar / mantener)"
    # valores actuales (si existen) para no pisar con vacío
    CUR_TG_TOKEN="${TG_TOKEN:-}"
    CUR_CHAT_ID="${TG_CHAT_ID:-}"
    CUR_THREAD="${TG_THREAD:-}"
    CUR_NOTIFY="${TG_NOTIFY:-all}"

    read -r -p "Token Bot [${CUR_TG_TOKEN:+ya configurado}]: " TG
    read -r -p "Chat ID [${CUR_CHAT_ID:+ya configurado}]: " CHAT
    read -r -p "Thread ID (opcional) [${CUR_THREAD:-none}]: " THREAD
    read -r -p "Notify (all|errors|success) [$CUR_NOTIFY]: " NOTIFY

    TG="${TG:-$CUR_TG_TOKEN}"
    CHAT="${CHAT:-$CUR_CHAT_ID}"
    THREAD="${THREAD:-$CUR_THREAD}"
    NOTIFY="${NOTIFY:-$CUR_NOTIFY}"
    if [ -n "$THREAD" ] && ! [[ "$THREAD" =~ ^-?[0-9]+$ ]]; then
      echo "❌ Thread ID inválido. Debe ser numérico."
      exit 1
    fi

    tmp="$(mktemp)"
    grep -v '^TG_' "$CONFIG_FILE" 2>/dev/null > "$tmp" || true
    {
      [ -n "$TG" ] && write_kv_line "TG_TOKEN" "$TG"
      [ -n "$CHAT" ] && write_kv_line "TG_CHAT_ID" "$CHAT"
      [ -n "$THREAD" ] && write_kv_line "TG_THREAD" "$THREAD"
      write_kv_line "TG_NOTIFY" "$NOTIFY"
    } >> "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    # Recargar para que tg_send use valores nuevos
    safe_source_file "$CONFIG_FILE" "config"

    echo "✅ Telegram guardado. (notify=$TG_NOTIFY${TG_THREAD:+, thread=$TG_THREAD})"
    tg_send test "🟢 Telegram configurado correctamente en woffy"
    ;;

  status)
    check_deps curl jq date
    [ -f "$CONFIG_FILE" ] && safe_source_file "$CONFIG_FILE" "config"
    TOKEN="$(get_token)"
    export TOKEN
    st="$(get_status)"
    case "$st" in
      in) echo "🟢 DENTRO" ;;
      out) echo "⚪ FUERA" ;;
      *) echo "⚠️ Estado desconocido (API/JSON inesperado)" ;;
    esac
    ;;

  dry-run)
    check_deps curl jq awk date
    [ -f "$CONFIG_FILE" ] && safe_source_file "$CONFIG_FILE" "config"
    MODE="${2:-}"
    if [ "$MODE" != "in" ] && [ "$MODE" != "out" ]; then
      echo "Uso: woffy dry-run {in|out}"
      exit 1
    fi
    acquire_lock
    TOKEN="$(get_token)"
    export TOKEN
    run_sign_flow "$MODE" true
    ;;

  report)
    check_deps awk date
    if [ -f "$CONFIG_FILE" ] && validate_kv_file "$CONFIG_FILE" "config"; then
      safe_source_file "$CONFIG_FILE" "config" 2>/dev/null || true
    fi
    REPORT_FROM="$(current_week_start_date)"
    REPORT_TO="$(date '+%Y-%m-%d')"
    REPORT_FORMAT="text"
    STRICT_RANGE=false
    SEND_TG=false

    shift || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        telegram)
          SEND_TG=true
          shift
          ;;
        --from)
          [ -z "${2:-}" ] && { echo "❌ Falta valor para --from"; exit 1; }
          REPORT_FROM="$2"
          shift 2
          ;;
        --to)
          [ -z "${2:-}" ] && { echo "❌ Falta valor para --to"; exit 1; }
          REPORT_TO="$2"
          shift 2
          ;;
        --format)
          [ -z "${2:-}" ] && { echo "❌ Falta valor para --format"; exit 1; }
          REPORT_FORMAT="$2"
          shift 2
          ;;
        --strict)
          STRICT_RANGE=true
          shift
          ;;
        *)
          echo "❌ Opción desconocida en report: $1"
          exit 1
          ;;
      esac
    done

    is_valid_date "$REPORT_FROM" || { echo "❌ Fecha inválida en --from (YYYY-MM-DD)"; exit 1; }
    is_valid_date "$REPORT_TO" || { echo "❌ Fecha inválida en --to (YYYY-MM-DD)"; exit 1; }
    case "$REPORT_FORMAT" in text|json|csv) ;; *) echo "ERROR Formato invalido: $REPORT_FORMAT"; exit 1 ;; esac
    if [[ "$REPORT_FROM" > "$REPORT_TO" ]]; then
      if $STRICT_RANGE; then
        echo "ERROR Rango invalido: --from ($REPORT_FROM) es mayor que --to ($REPORT_TO)."
        exit 1
      fi
      echo "WARN Rango invertido detectado. Intercambiando fechas automaticamente."
      tmp_date="$REPORT_FROM"
      REPORT_FROM="$REPORT_TO"
      REPORT_TO="$tmp_date"
    fi

    REPORT_MSG="$(build_weekly_report "$(date_to_boundary "$REPORT_FROM" start)" "$(date_to_boundary "$REPORT_TO" end)" "$REPORT_FORMAT")"
    echo "$REPORT_MSG"
    log "Reporte generado: from=$REPORT_FROM to=$REPORT_TO format=$REPORT_FORMAT send_tg=$SEND_TG"
    if $SEND_TG; then
      if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        tg_send info "$REPORT_MSG" true
        log "Reporte enviado a Telegram."
        echo "✅ Reporte enviado a Telegram."
      else
        log "Reporte no enviado: Telegram no configurado."
        echo "⚠️ Telegram no configurado. Reporte solo mostrado por consola."
      fi
    fi
    ;;

  notify)
    check_deps curl
    if [ -f "$CONFIG_FILE" ] && validate_kv_file "$CONFIG_FILE" "config"; then
      safe_source_file "$CONFIG_FILE" "config" 2>/dev/null || true
    fi
    if [ "${2:-}" != "test" ]; then
      echo "Uso: woffy notify test {success|warning|error|info|all} [mensaje]"
      exit 1
    fi
    KIND="${3:-all}"
    CUSTOM_MSG="${4:-Mensaje de prueba woffy}"
    case "$KIND" in
      success) tg_send success "✅ $CUSTOM_MSG" ;;
      warning) tg_send info "⚠️ $CUSTOM_MSG" ;;
      error) tg_send error "❌ $CUSTOM_MSG" ;;
      info) tg_send info "ℹ️ $CUSTOM_MSG" ;;
      all)
        tg_send success "✅ $CUSTOM_MSG"
        tg_send info "⚠️ $CUSTOM_MSG"
        tg_send error "❌ $CUSTOM_MSG"
        tg_send info "ℹ️ $CUSTOM_MSG"
        ;;
      *)
        echo "❌ Tipo inválido: $KIND"
        exit 1
        ;;
    esac
    echo "✅ Notificación enviada."
    ;;

  self-test)
    check_deps curl jq awk date
    if [ -f "$CONFIG_FILE" ] && validate_kv_file "$CONFIG_FILE" "config"; then
      safe_source_file "$CONFIG_FILE" "config" 2>/dev/null || true
    fi
    self_test || exit 1
    ;;

  backup)
    check_deps tar
    OUT="${2:-}"
    BAK_PATH="$(backup_files "$OUT")"
    echo "✅ Backup creado: $BAK_PATH"
    ;;

  restore)
    check_deps tar
    [ -z "${2:-}" ] && { echo "Uso: woffy restore /ruta/backup.tar.gz"; exit 1; }
    if restore_files "$2"; then
      echo "✅ Backup restaurado."
    else
      echo "❌ No se pudo restaurar el backup."
      exit 1
    fi
    ;;

  changelog)
    check_deps curl jq awk
    show_changelog
    ;;

  in|out)
    check_deps curl jq awk date
    [ -f "$CONFIG_FILE" ] && safe_source_file "$CONFIG_FILE" "config"
    acquire_lock
    TOKEN="$(get_token)"
    export TOKEN
    run_sign_flow "$1" false || exit 1
    ;;

  update)
    check_deps curl
    UPDATE_BRANCH="main"
    if [ "${2:-}" = "nightly" ]; then
      UPDATE_BRANCH="nightly"
    elif [ -n "${2:-}" ]; then
      echo "Uso: woffy update [nightly]"
      exit 1
    fi
    UPDATE_RAW_BASE="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/$UPDATE_BRANCH"

    BIN_PATH="$(get_bin_path)"
  
    if [ -z "$BIN_PATH" ]; then
      echo "ERROR No se encuentra el binario actual de woffy"
      exit 1
    fi
  
    TMP="$(mktemp)"
    echo "INFO Descargando version '$UPDATE_BRANCH' de woffy..."
  
    if ! curl -fsSL "${UPDATE_RAW_BASE}/woffy.sh" -o "$TMP"; then
      echo "ERROR Error descargando la actualizacion"
      rm -f "$TMP"
      exit 1
    fi

    chmod +x "$TMP"
    mv "$TMP" "$BIN_PATH"
  
    echo "SUCCESS Woffy actualizado correctamente desde '$UPDATE_BRANCH'."
    exit 0
    ;;
  doctor)
    check_deps curl jq awk date
    TOKEN="$(get_token 2>/dev/null || true)"
    export TOKEN
    if [ "${2:-}" = "--json" ]; then
      CFG="false"; [ -f "$CONFIG_FILE" ] && CFG="true"
      LCK="false"; [ -d "$LOCK_DIR" ] && LCK="true"
      USTAT="$(user_card_summary)"
      ST="unknown"; [ -n "${TOKEN:-}" ] && ST="$(get_status)"
      TG="false"; [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] && TG="true"
      cat <<EOF
{"version":"$VERSION","bin":"$(json_escape "$(get_bin_path)")","config":$CFG,"lock":$LCK,"token":"$(json_escape "$(token_status_human)")","status":"$(json_escape "$ST")","user":"$(json_escape "$USTAT")","telegram":$TG}
EOF
      exit 0
    fi
    
    echo "🩺 Diagnóstico woffy v$VERSION"
    echo
    echo "Sistema"
    if [ -f "$CONFIG_FILE" ]; then
      config_state="OK"
    else
      config_state="NO"
    fi
    if [ -d "$LOCK_DIR" ]; then
      lock_state="ACTIVO"
    else
      lock_state="libre"
    fi
    echo "  Bin:     $(get_bin_path)"
    echo "  Config:  $config_state"
    echo "  Deps:    OK"
    echo "  Lock:    $lock_state"
    echo
    echo "Autenticación"
    echo "  Token:   $(token_status_human)"
    echo
    echo "Usuario"
    if [ -f "$USER_FILE" ]; then
      if validate_kv_file "$USER_FILE" "user"; then
        safe_source_file "$USER_FILE" "user" 2>/dev/null || true
      fi
      echo "  Ficha:   OK"
      echo "  Nombre:  ${WOFFY_FULL_NAME:-?}"
      echo "  Empresa: ${WOFFY_COMPANY_NAME:-?}"
    else
      echo "  Ficha:   NO"
    fi

    if [ -n "${TOKEN:-}" ]; then
      echo "Estado:  $(get_status)"
    else
      echo "Estado:  unknown"
    fi

    echo "User:    $(user_card_summary)"
    if [ -f "$USER_FILE" ]; then
      if validate_kv_file "$USER_FILE" "user"; then
        safe_source_file "$USER_FILE" "user" 2>/dev/null || true
      fi
      [ -n "${WOFFY_FULL_NAME:-}" ] && echo "Nombre:  $WOFFY_FULL_NAME"
      [ -n "${WOFFY_EMAIL:-}" ] && echo "Email:   $WOFFY_EMAIL"
      [ -n "${WOFFY_COMPANY_NAME:-}" ] && echo "Empresa: $WOFFY_COMPANY_NAME"
      [ -n "${WOFFY_USER_NUMBER:-}" ] && echo "UserNo:  $WOFFY_USER_NUMBER"
      [ -n "${WOFFY_USER_ID:-}" ] && echo "UserId:  $WOFFY_USER_ID"
    fi

    wd="$(get_workday)"
    if echo "$wd" | jq -e '.ScheduleHours' >/dev/null 2>&1; then
      sh="$(echo "$wd" | jq -r '.ScheduleHours')"
      rsn="$(workday_reason "$wd")"
      echo "Workday: ${sh}h | Reason: ${rsn}"
    else
      echo "Workday: (no disponible)"
    fi

    if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
      echo "TG:      OK (enviando test...)"
      tg_send test "🟢 woffy doctor: Telegram OK"
    else
      echo "TG:      NO configurado"
    fi
    ;;

  schedule)
    check_deps crontab readlink
    if [ -f "$CONFIG_FILE" ] && validate_kv_file "$CONFIG_FILE" "config"; then
      safe_source_file "$CONFIG_FILE" "config" 2>/dev/null || true
    fi
    SCRIPT_PATH="$(get_script_path)"
    SCRIPT_PATH_ESCAPED="$(printf '%q' "$SCRIPT_PATH")"
    TZ_LINE=""
    [ -n "${WOFFY_TZ:-}" ] && TZ_LINE="CRON_TZ=$WOFFY_TZ # woffy-tz"

    case "${2:-}" in
      list)
        crontab -l 2>/dev/null | grep 'woffy-' || echo "Sin tareas."
        [ -n "${WOFFY_TZ:-}" ] && echo "Timezone configurada: $WOFFY_TZ"
        ;;
      clear)
        clear_woffy_cron
        echo "✅ Cron limpiado."
        ;;
      pause)
        pause_woffy_cron
        echo "✅ Cron de woffy en pausa."
        ;;
      resume)
        resume_woffy_cron
        echo "✅ Cron de woffy reanudado."
        ;;
      report)
        tmp="$(mktemp)"
        crontab -l 2>/dev/null | grep -v '# woffy-report' > "$tmp" || true
        [ -n "$TZ_LINE" ] && {
          grep -q '# woffy-tz' "$tmp" || echo "$TZ_LINE" >> "$tmp"
        }
        echo "0 18 * * 5 $SCRIPT_PATH_ESCAPED report telegram # woffy-report" >> "$tmp"
        crontab "$tmp"
        rm -f "$tmp"
        echo "✅ Reporte semanal programado (viernes 18:00)."
        ;;
      timezone)
        [ -z "${3:-}" ] && { echo "Uso: woffy schedule timezone <TZ>"; exit 1; }
        upsert_config_key "WOFFY_TZ" "$3"
        tmp="$(mktemp)"
        crontab -l 2>/dev/null | grep -v '# woffy-tz' > "$tmp" || true
        echo "CRON_TZ=$3 # woffy-tz" >> "$tmp"
        crontab "$tmp"
        rm -f "$tmp"
        echo "✅ Timezone de cron guardada: $3"
        ;;
      systemd)
        check_deps systemctl
        case "${3:-}" in
          enable|install)
            install_systemd_user_timers "$SCRIPT_PATH"
            echo "✅ Timers systemd --user activados."
            ;;
          disable|remove)
            remove_systemd_user_timers
            echo "✅ Timers systemd --user eliminados."
            ;;
          status)
            systemctl --user status woffy-in.timer woffy-out.timer woffy-report.timer --no-pager || true
            ;;
          *)
            echo "Uso: woffy schedule systemd {enable|disable|status}"
            exit 1
            ;;
        esac
        ;;
      entrada|salida)
        TYPE="in"
        TAG="# woffy-in"
        DEFAULT_TIMES=("09:00" "15:30")

        if [ "$2" = "salida" ]; then
          TYPE="out"
          TAG="# woffy-out"
          DEFAULT_TIMES=("14:00" "18:00")
        fi

        if [ -n "${3:-}" ]; then
          validate_time "$3" || { echo "❌ Hora inválida"; exit 1; }
          TIMES=("$3")
        else
          TIMES=("${DEFAULT_TIMES[@]}")
        fi

        tmp="$(mktemp)"
        crontab -l 2>/dev/null | grep -v "$TAG" > "$tmp" || true
        [ -n "$TZ_LINE" ] && {
          grep -q '# woffy-tz' "$tmp" || echo "$TZ_LINE" >> "$tmp"
        }

        for T in "${TIMES[@]}"; do
          IFS=':' read -r H M <<< "$T"
          echo "$M $H * * 1-5 $SCRIPT_PATH_ESCAPED $TYPE $TAG" >> "$tmp"
        done

        crontab "$tmp"
        rm -f "$tmp"
        echo "✅ Programado $TYPE (${TIMES[*]}) de lunes a viernes"
        ;;
      *)
        echo "Uso: woffy schedule {list|clear|pause|resume|timezone <TZ>|report|systemd {enable|disable|status}|entrada [HH:MM]|salida [HH:MM]}"
        ;;
    esac
    ;;

  config)
    case "${2:-}" in
      check)
        if [ ! -f "$CONFIG_FILE" ]; then
          echo "❌ Config no encontrada: $CONFIG_FILE"
          exit 1
        fi
        if validate_kv_file "$CONFIG_FILE" "config"; then
          echo "✅ Config valida (sintaxis y claves permitidas)."
          grep -q '^WURL_USER=' "$CONFIG_FILE" || echo "⚠️ Falta WURL_USER en config."
          grep -q '^WURL_PASS=' "$CONFIG_FILE" || echo "⚠️ Falta WURL_PASS en config."
          exit 0
        else
          echo "❌ Config invalida o insegura."
          exit 1
        fi
        ;;
      *)
        echo "Uso: woffy config check"
        exit 1
        ;;
    esac
    ;;

  uninstall)
    check_deps crontab
    echo "⚠️ Esto eliminará completamente woffy de tu usuario."
    echo "    - Binario"
    echo "    - Configuración"
    echo "    - Token"
    echo "    - Ficha de usuario"
    echo "    - Entradas de cron"
    echo
    read -r -p "Seguro que quieres continuar? (s/N): " CONFIRM

    case "$CONFIRM" in
      s|S|y|Y) ;;
      *) echo "ℹ️ Cancelado."; exit 0 ;;
    esac

    echo "ℹ️ Eliminando cron..."
    clear_woffy_cron

    BIN_PATH="$(get_bin_path)"
    if [ -n "$BIN_PATH" ]; then
      echo "ℹ️ Eliminando binario: $BIN_PATH"
      rm -f "$BIN_PATH"
    fi

    echo "ℹ️ Eliminando archivos de usuario..."
    rm -f "$CONFIG_FILE" "$TOKEN_FILE" "$USER_FILE" "$LOG_FILE"
    rm -rf "$LOCK_DIR"

    echo "✅ woffy desinstalado correctamente."
    exit 0
    ;;

  *)
    echo "❌ Comando desconocido. Ejecuta 'woffy help' para ver las opciones."
    exit 1
    ;;
esac






