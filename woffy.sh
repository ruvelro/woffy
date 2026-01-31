#!/bin/bash
set -euo pipefail

VERSION="1.0"

# Rutas
CONFIG_FILE="$HOME/.woffy.conf"
TOKEN_FILE="$HOME/.woffy.token"
LOG_FILE="$HOME/.woffy.log"
LOCK_FILE="$HOME/.woffy.lock"
USER_FILE="$HOME/.woffy.user"

API_URL="https://app.woffu.com"

# ─────────────────────────────────────────────
# Utils
# ─────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }

check_deps() {
  for cmd in curl jq awk date crontab readlink; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "❌ Falta dependencia crítica: $cmd"
      exit 1
    }
  done
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
  if [ -f "$LOCK_FILE" ]; then
    local pid
    pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "Lock activo (PID $pid). Abortando ejecución concurrente."
      exit 0
    else
      log "Lock huérfano. Eliminando lock."
      rm -f "$LOCK_FILE"
    fi
  fi
  echo "$$" > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
}

# ─────────────────────────────────────────────
# Telegram
# ─────────────────────────────────────────────
tg_send() {
  [ -z "${TG_TOKEN:-}" ] && return
  [ -z "${TG_CHAT_ID:-}" ] && return

  local TYPE="$1"  # error | success | info | test
  local MSG="$2"

  case "${TG_NOTIFY:-all}" in
    all) ;;
    errors)  [ "$TYPE" != "error" ] && return ;;
    success) [ "$TYPE" != "success" ] && return ;;
    *) ;;
  esac

  curl -s --max-time 10 -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$MSG" \
    ${TG_THREAD:+-d message_thread_id=$TG_THREAD} \
    > /dev/null || log "Error enviando a Telegram"
}

# ─────────────────────────────────────────────
# Cargar config cuando haga falta
# ─────────────────────────────────────────────
need_config=true
case "${1:-}" in
  help|version|login|uninstall|"")
    need_config=false
    ;;
esac

if $need_config; then
  [ ! -f "$CONFIG_FILE" ] && { echo "❌ Configuración no encontrada. Ejecuta 'woffy login'"; exit 1; }
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# ─────────────────────────────────────────────
# Token
# ─────────────────────────────────────────────
get_token() {
  : "${WURL_USER:?Credenciales no configuradas. Ejecuta 'woffy login'}"
  : "${WURL_PASS:?Credenciales no configuradas. Ejecuta 'woffy login'}"
  local now response token expires exp
  now=$(date +%s)

  if [ -f "$TOKEN_FILE" ]; then
    # shellcheck disable=SC1090
    source "$TOKEN_FILE" 2>/dev/null || true
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
    echo "WOFFY_TOKEN=\"$token\""
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
  # shellcheck disable=SC1090
  source "$TOKEN_FILE" 2>/dev/null || { echo "INVALIDO"; return; }
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

# ─────────────────────────────────────────────
# API core
# ─────────────────────────────────────────────
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
  local now json_data resp status_code

  now=$(date -Iseconds)

  json_data="$(jq -nc --arg date "$now" --arg action "$action" \
    '{signType:0, date:$date, action:$action}')"

  resp="$(curl -s -w "\n%{http_code}" -X POST "$API_URL/api/signs" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$json_data" || true)"

  status_code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  if [[ "$status_code" =~ ^2 ]]; then
    return 0
  else
    log "Error API Sign ($action): HTTP $status_code | $body"
    return 1
  fi
}

# ─────────────────────────────────────────────
# Workdaylite (solo para IN)
# ─────────────────────────────────────────────
get_user_id() {
  if [ -f "$USER_FILE" ]; then
    # shellcheck disable=SC1090
    source "$USER_FILE" 2>/dev/null || true
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

# ─────────────────────────────────────────────
# User card (“ficha de trabajador”)
# ─────────────────────────────────────────────
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
    echo "WOFFY_USER_ID=\"$uid\""
    echo "WOFFY_USER_NUMBER=\"$un\""
    echo "WOFFY_FULL_NAME=\"$full\""
    echo "WOFFY_EMAIL=\"$email\""
    echo "WOFFY_COMPANY_ID=\"$cid\""
    echo "WOFFY_COMPANY_NAME=\"$cname\""
    echo "WOFFY_OFFICE_NAME=\"$office\""
    echo "WOFFY_SCHEDULE_NAME=\"$sched\""
  } > "$USER_FILE" 2>/dev/null || true
  chmod 600 "$USER_FILE" 2>/dev/null || true
  return 0
}

user_card_summary() {
  [ ! -f "$USER_FILE" ] && { echo "NO"; return; }
  # shellcheck disable=SC1090
  source "$USER_FILE" 2>/dev/null || { echo "INVALIDO"; return; }
  [ -n "${WOFFY_FULL_NAME:-}" ] && echo "OK" || echo "PARCIAL"
}

# ─────────────────────────────────────────────
# Cron
# ─────────────────────────────────────────────
clear_woffy_cron() {
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v '# woffy-' > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
}

validate_time() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; }

cron_count() {
  crontab -l 2>/dev/null | grep -c '# woffy-' || true
}

# ─────────────────────────────────────────────
# Help (MUCHO más completa)
# ─────────────────────────────────────────────
show_help() {
cat <<EOF
woffy v$VERSION — CLI para fichar en Woffu (modo usuario, sin sudo)

USO:
  woffy <comando> [subcomando] [opciones]

COMANDOS PRINCIPALES:
  in                 Fichar entrada (solo ficha si estabas fuera y hoy hay horas programadas)
  out                Fichar salida  (solo ficha si estabas dentro)
  status             Mostrar estado actual (in/out/unknown)
  user               Mostrar ficha de trabajador
  login              Guardar credenciales y generar ficha de trabajador (~/.woffy.user)
  telegram           Configurar Telegram (token/chat/thread/notify) y enviar test
  telegram test      Enviar mensaje de prueba a Telegram
  doctor             Diagnóstico completo (incluye test Telegram)
  update             Actualizar woffy manteniendo la configuración
  schedule           Gestionar cron
  version            Mostrar versión
  uninstall          Desinstalar woffy (borra binario, config y cron)
  help               Mostrar esta ayuda

CONFIGURACIÓN:
  - Credenciales: $CONFIG_FILE
  - Token cache:  $TOKEN_FILE
  - Log:          $LOG_FILE
  - Lock:         $LOCK_FILE
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
  woffy schedule entrada HH:MM   (L-V)
  woffy schedule salida  HH:MM   (L-V)

EJEMPLOS:
  woffy login
  woffy status
  woffy in
  woffy out
  woffy telegram
  woffy schedule clear
  woffy schedule entrada 09:00
  woffy schedule salida 18:00

NOTAS:
  - Para 'in', woffy consulta /workdaylite y NO ficha si ScheduleHours <= 0.
  - Si la API no permite determinar estado (unknown), woffy aborta por seguridad.
  - Toda la información del usuario se guarda localmente tras 'woffy login'.
EOF
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
case "${1:-}" in
  help|"")
    show_help
    ;;

  version)
    echo "woffy v$VERSION"
    ;;

  login)
    check_deps
    if [ $# -ge 3 ]; then
      EMAIL="$2"
      PASS="$3"
    else
      read -p "Correo: " EMAIL
      read -s -p "Contraseña: " PASS
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
      echo "WURL_USER=\"$EMAIL\""
      echo "WURL_PASS=\"$PASS\""
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

    # shellcheck disable=SC1090
    source "$USER_FILE" 2>/dev/null || {
      echo "❌ Ficha de usuario corrupta."
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
    check_deps
    if [ "${2:-}" = "test" ]; then
      # shellcheck disable=SC1090
      source "$CONFIG_FILE" 2>/dev/null || true
      tg_send test "✅ Telegram OK (woffy)"
      echo "📨 Mensaje enviado."
      exit 0
    fi

    echo "Configuración de Telegram (Enter para saltar / mantener)"
    # valores actuales (si existen) para no pisar con vacío
    CUR_TG_TOKEN="${TG_TOKEN:-}"
    CUR_CHAT_ID="${TG_CHAT_ID:-}"
    CUR_THREAD="${TG_THREAD:-}"
    CUR_NOTIFY="${TG_NOTIFY:-all}"

    read -p "Token Bot [${CUR_TG_TOKEN:+ya configurado}]: " TG
    read -p "Chat ID [${CUR_CHAT_ID:+ya configurado}]: " CHAT
    read -p "Thread ID (opcional) [${CUR_THREAD:-none}]: " THREAD
    read -p "Notify (all|errors|success) [$CUR_NOTIFY]: " NOTIFY

    TG="${TG:-$CUR_TG_TOKEN}"
    CHAT="${CHAT:-$CUR_CHAT_ID}"
    THREAD="${THREAD:-$CUR_THREAD}"
    NOTIFY="${NOTIFY:-$CUR_NOTIFY}"

    tmp="$(mktemp)"
    grep -v '^TG_' "$CONFIG_FILE" 2>/dev/null > "$tmp" || true
    [ -n "$TG" ] && echo "TG_TOKEN=\"$TG\"" >> "$tmp"
    [ -n "$CHAT" ] && echo "TG_CHAT_ID=\"$CHAT\"" >> "$tmp"
    [ -n "$THREAD" ] && echo "TG_THREAD=\"$THREAD\"" >> "$tmp"
    echo "TG_NOTIFY=\"$NOTIFY\"" >> "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    # Recargar para que tg_send use valores nuevos
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    echo "✅ Telegram guardado. (notify=$TG_NOTIFY${TG_THREAD:+, thread=$TG_THREAD})"
    tg_send test "✅ Telegram configurado correctamente en woffy"
    ;;

  status)
    check_deps
    TOKEN="$(get_token)"
    export TOKEN
    st="$(get_status)"
    case "$st" in
      in) echo "📍 DENTRO" ;;
      out) echo "📍 FUERA" ;;
      *) echo "❓ Estado desconocido (API/JSON inesperado)" ;;
    esac
    ;;

  in|out)
    check_deps
    acquire_lock
    TOKEN="$(get_token)"
    export TOKEN

    st="$(get_status)"
    log "Solicitud: $1 | Estado actual: $st"

    if [ "$st" = "unknown" ]; then
      MSG="⚠️ No se puede determinar el estado actual. Abortando por seguridad."
      echo "$MSG"
      tg_send error "$MSG"
      exit 1
    fi

    if [ "$1" = "in" ] && [ "$st" = "in" ]; then
      MSG="ℹ️ No ficho IN: ya estabas DENTRO."
      echo "$MSG"
      log "$MSG"
      tg_send error "$MSG"
      exit 0
    fi

    if [ "$1" = "out" ] && [ "$st" = "out" ]; then
      MSG="ℹ️ No ficho OUT: ya estabas FUERA."
      echo "$MSG"
      log "$MSG"
      tg_send error "$MSG"
      exit 0
    fi

    if [ "$1" = "in" ]; then
      wd="$(get_workday)"
      if [ -n "$wd" ] && ! is_workday_ok_for_in "$wd"; then
        reason="$(workday_reason "$wd")"
        [ -z "$reason" ] && reason="día no laborable"
        MSG="⛔ No se ficha entrada: $reason."
        echo "$MSG"
        log "$MSG"
        tg_send error "$MSG"
        exit 0
      fi
    fi

    ACTION="clock_in"
    [ "$1" = "out" ] && ACTION="clock_out"

MAX_RETRIES=4
RETRY_DELAY=15
attempt=1
success=false

while [ "$attempt" -le "$MAX_RETRIES" ]; do
  if post_sign "$ACTION"; then
    success=true
    break
  fi

  log "Intento $attempt/$MAX_RETRIES fallido al fichar $1."
  
  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    log "Reintentando en ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
  fi

  attempt=$((attempt + 1))
done

if $success; then
  MSG="✅ Fichaje correcto: $1"
  echo "$MSG"
  log "$MSG"
  tg_send success "✅ *woffy*: Fichaje *$1* realizado ($(date +%H:%M))."
else
  MSG="❌ Error al fichar $1 en la API tras $MAX_RETRIES intentos."
  echo "$MSG"
  log "$MSG"
  tg_send error "$MSG"
  exit 1
fi

    ;;

  update)
    check_deps
    BIN_PATH="$(get_bin_path)"
  
    if [ -z "$BIN_PATH" ]; then
      echo "❌ No se encuentra el binario actual de woffy"
      exit 1
    fi
  
    TMP="$(mktemp)"
    echo "⬇️ Descargando última versión de woffy..."
  
    if ! curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/main/woffy.sh -o "$TMP"; then
      echo "❌ Error descargando la actualización"
      rm -f "$TMP"
      exit 1
    fi
  
    chmod +x "$TMP"
    mv "$TMP" "$BIN_PATH"
  
    echo "✅ Woffy actualizado correctamente."
    exit 0
    ;;

  doctor)
    check_deps
    TOKEN="$(get_token 2>/dev/null || true)"
    export TOKEN
    
    echo "🩺 Diagnóstico woffy v$VERSION"
    echo
    echo "Sistema"
    echo "  Bin:     $(get_bin_path)"
    echo "  Config:  $( [ -f "$CONFIG_FILE" ] && echo OK || echo NO )"
    echo "  Deps:    OK"
    echo "  Lock:    $( [ -f "$LOCK_FILE" ] && echo ACTIVO || echo libre )"
    echo
    echo "Autenticación"
    echo "  Token:   $(token_status_human)"
    echo
    echo "Usuario"
    if [ -f "$USER_FILE" ]; then
      # shellcheck disable=SC1090
      source "$USER_FILE" 2>/dev/null || true
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
      source "$USER_FILE" 2>/dev/null || true
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
      tg_send test "🩺 woffy doctor: Telegram OK"
    else
      echo "TG:      NO configurado"
    fi
    ;;

  schedule)
    check_deps
    SCRIPT_PATH="$(get_script_path)"

    case "${2:-}" in
      list)
        crontab -l 2>/dev/null | grep '# woffy-' || echo "Sin tareas."
        ;;
      clear)
        clear_woffy_cron
        echo "✅ Cron limpiado."
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
          validate_time "$3" || { echo "Hora inválida"; exit 1; }
          TIMES=("$3")
        else
          TIMES=("${DEFAULT_TIMES[@]}")
        fi

        tmp="$(mktemp)"
        crontab -l 2>/dev/null | grep -v "$TAG" > "$tmp" || true

        for T in "${TIMES[@]}"; do
          IFS=':' read -r H M <<< "$T"
          echo "$M $H * * 1-5 $SCRIPT_PATH $TYPE $TAG" >> "$tmp"
        done

        crontab "$tmp"
        rm -f "$tmp"
        echo "✅ Programado $TYPE (${TIMES[*]}) de lunes a viernes"
        ;;
      *)
        echo "Uso: woffy schedule {list|clear|entrada [HH:MM]|salida [HH:MM]}"
        ;;
    esac
    ;;

  uninstall)
    check_deps
    echo "⚠️  Esto eliminará completamente woffy de tu usuario."
    echo "    - Binario"
    echo "    - Configuración"
    echo "    - Token"
    echo "    - Ficha de usuario"
    echo "    - Entradas de cron"
    echo
    read -p "¿Seguro que quieres continuar? (s/N): " CONFIRM

    case "$CONFIRM" in
      s|S|y|Y) ;;
      *) echo "❌ Cancelado."; exit 0 ;;
    esac

    echo "🧹 Eliminando cron..."
    clear_woffy_cron

    BIN_PATH="$(get_bin_path)"
    if [ -n "$BIN_PATH" ]; then
      echo "🗑️  Eliminando binario: $BIN_PATH"
      rm -f "$BIN_PATH"
    fi

    echo "🗑️  Eliminando archivos de usuario..."
    rm -f "$CONFIG_FILE" "$TOKEN_FILE" "$USER_FILE" "$LOCK_FILE" "$LOG_FILE"

    echo "✅ woffy desinstalado correctamente."
    exit 0
    ;;

  *)
    echo "❌ Comando desconocido. Ejecuta 'woffy help' para ver las opciones."
    exit 1
    ;;
esac
