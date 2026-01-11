#!/bin/bash
set -e

VERSION="1.1"

CONFIG_FILE="$HOME/.woffy.conf"
TOKEN_FILE="$HOME/.woffy.token"
LOG_FILE="$HOME/.woffy.log"
API_URL="https://app.woffu.com"

[ ! -f "$CONFIG_FILE" ] && echo "❌ Configuración no encontrada. Ejecuta 'woffy login'" && exit 1
source "$CONFIG_FILE"

# ─────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────
# Telegram
# ─────────────────────────────────────────────
tg_send() {
  [ -z "${TG_TOKEN:-}" ] && return

  local TYPE="$1"
  local MSG="$2"

  case "${TG_NOTIFY:-all}" in
    all) ;;
    errors)  [ "$TYPE" != "error" ] && return ;;
    success) [ "$TYPE" != "success" ] && return ;;
    *) ;;
  esac

  curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$MSG" \
    -d parse_mode="Markdown" \
    ${TG_THREAD:+-d message_thread_id=$TG_THREAD} \
    > /dev/null
}

# ─────────────────────────────────────────────
# Dependencias
# ─────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    MSG="❌ Faltan dependencias necesarias: ${missing[*]}"
    echo "$MSG"
    echo "Instálalas antes de usar woffy."
    tg_send error "$MSG"
    exit 1
  fi
}

case "$1" in
  help|version|"") ;;
  *) check_deps ;;
esac

# ─────────────────────────────────────────────
# Token OAuth (cacheado)
# ─────────────────────────────────────────────
get_token() {
  local now token exp response expires_in
  now=$(date +%s)

  if [ -f "$TOKEN_FILE" ]; then
    source "$TOKEN_FILE"
    if [ -n "${WOFFY_TOKEN:-}" ] && [ "$now" -lt "${WOFFY_TOKEN_EXP:-0}" ]; then
      echo "$WOFFY_TOKEN"
      return
    fi
  fi

  log "Renovando token OAuth"
  response=$(curl -s -X POST "$API_URL/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS")

  token=$(echo "$response" | jq -r '.access_token')
  expires_in=$(echo "$response" | jq -r '.expires_in')

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "❌ Error autenticando con Woffu."
    log "ERROR autenticando: $response"
    tg_send error "❌ Error autenticando con Woffu."
    exit 1
  fi

  exp=$((now + expires_in - 60))

  {
    echo "WOFFY_TOKEN=\"$token\""
    echo "WOFFY_TOKEN_EXP=$exp"
  } > "$TOKEN_FILE"

  chmod 600 "$TOKEN_FILE"
  log "Token renovado correctamente"
  echo "$token"
}

TOKEN=$(get_token)

# ─────────────────────────────────────────────
# API wrapper
# ─────────────────────────────────────────────
api_request() {
  local method="$1" url="$2" data="${3:-}"
  local response http body

  if [ -n "$data" ]; then
    response=$(curl -s -w '\n%{http_code}' -X "$method" "$url" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$data")
  else
    response=$(curl -s -w '\n%{http_code}' -X "$method" "$url" \
      -H "Authorization: Bearer $TOKEN")
  fi

  http=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [ "$http" = "401" ]; then
    log "Token inválido, renovando"
    rm -f "$TOKEN_FILE"
    TOKEN=$(get_token)
    api_request "$method" "$url" "$data"
    return
  fi

  if [ "$http" -lt 200 ] || [ "$http" -ge 300 ]; then
    echo "❌ Error de Woffu (HTTP $http)"
    log "ERROR API $http: $body"
    tg_send error "❌ Error de Woffu (HTTP $http)"
    exit 1
  fi

  echo "$body"
}

# ─────────────────────────────────────────────
# Validar día laborable en Woffu
# ─────────────────────────────────────────────
check_workday_woffu() {
  local today resp working desc type
  today=$(date +%Y-%m-%d)

  resp=$(api_request GET "$API_URL/api/calendar/me?date=$today")
  working=$(echo "$resp" | jq -r '.workingDay')
  desc=$(echo "$resp" | jq -r '.description // empty')
  type=$(echo "$resp" | jq -r '.type // empty')

  if [ "$working" != "true" ]; then
    echo "❌ Hoy no es un día laborable según Woffu ($desc)"
    log "Bloqueado fichaje: $type ($desc)"
    tg_send error "❌ No se ficha hoy: $desc"
    exit 1
  fi
}

# ─────────────────────────────────────────────
# Cron helpers
# ─────────────────────────────────────────────
clear_woffy_cron() {
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+(in|out)/ && !/# woffy-(in|out)/ {print}' > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
  log "Crontab limpiado"
}

# ─────────────────────────────────────────────
# Comandos
# ─────────────────────────────────────────────
case "$1" in
  version)
    echo "woffy v$VERSION"
    ;;

  in|out)
    check_workday_woffu

    SIGNS=$(api_request GET "$API_URL/api/signs")
    STATUS=$(echo "$SIGNS" | jq -r '.[-1].SignIn')

    ACTION="clock_in"
    [ "$1" = "out" ] && ACTION="clock_out"

    if [[ "$STATUS" == "true" && "$1" == "in" ]]; then
      echo "❌ Ya estás fichado dentro."
      tg_send error "❌ Ya estás fichado dentro."
      exit 1
    fi

    if [[ "$STATUS" == "false" && "$1" == "out" ]]; then
      echo "❌ Ya estás fichado fuera."
      tg_send error "❌ Ya estás fichado fuera."
      exit 1
    fi

    api_request POST "$API_URL/api/signs" \
      '{"signType":0,"date":"'"$(date -Iseconds)"'","action":"'"$ACTION"'"}'

    echo "✅ Fichaje '$1' realizado correctamente."
    log "Fichaje $1 correcto"
    tg_send success "✅ Fichaje *$1* realizado a las *$(date +%H:%M)*."
    ;;

  status)
    SIGNS=$(api_request GET "$API_URL/api/signs")
    STATUS=$(echo "$SIGNS" | jq -r '.[-1].SignIn')
    [ "$STATUS" = "true" ] && echo "📍 Estás fichado DENTRO." || echo "📍 Estás fichado FUERA."
    ;;

  doctor)
    echo "🩺 Diagnóstico woffy v$VERSION"
    echo "Config: $([ -f "$CONFIG_FILE" ] && echo OK || echo ERROR)"
    echo "Token:  $([ -f "$TOKEN_FILE" ] && echo OK || echo NO)"
    echo "API:    $(api_request GET "$API_URL/api/me" >/dev/null 2>&1 && echo OK || echo ERROR)"
    echo "Log:    $LOG_FILE"
    ;;

  help|*)
    echo "woffy v$VERSION"
    echo
    echo "Comandos:"
    echo "  in           Fichar entrada"
    echo "  out          Fichar salida"
    echo "  status       Consultar estado"
    echo "  doctor       Diagnóstico del sistema"
    echo "  version      Mostrar versión"
    echo "  login        Configurar credenciales"
    echo "  telegram     Configurar Telegram"
    echo "  schedule     Gestionar cron"
    ;;
esac
