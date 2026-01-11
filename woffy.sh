#!/bin/bash
set -e

VERSION="1.1"

CONFIG_FILE="$HOME/.woffy.conf"
TOKEN_FILE="$HOME/.woffy.token"
LOG_FILE="$HOME/.woffy.log"
API_URL="https://app.woffu.com"

# ─────────────────────────────────────────────
# Utils
# ─────────────────────────────────────────────
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

check_deps() {
  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "❌ Falta dependencia: $cmd"
      exit 1
    }
  done
}

require_config() {
  [ ! -f "$CONFIG_FILE" ] && {
    echo "❌ Configuración no encontrada. Ejecuta 'woffy login'"
    exit 1
  }
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

require_creds() {
  [ -z "${WURL_USER:-}" ] || [ -z "${WURL_PASS:-}" ] && {
    echo "❌ Faltan credenciales. Ejecuta 'woffy login'"
    exit 1
  }
}

# ─────────────────────────────────────────────
# Telegram
# ─────────────────────────────────────────────
tg_send() {
  [ -z "${TG_TOKEN:-}" ] && return
  [ -z "${TG_CHAT_ID:-}" ] && return

  local TYPE="$1"
  local MSG="$2"

  case "${TG_NOTIFY:-all}" in
    all) ;;
    errors)  [ "$TYPE" != "error" ] && return ;;
    success) [ "$TYPE" != "success" ] && return ;;
  esac

  curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$MSG" \
    ${TG_THREAD:+-d message_thread_id=$TG_THREAD} \
    > /dev/null || true
}

# ─────────────────────────────────────────────
# Token OAuth (cacheado)
# ─────────────────────────────────────────────
get_token() {
  local now response token expires exp

  now=$(date +%s)

  if [ -f "$TOKEN_FILE" ]; then
    # shellcheck disable=SC1090
    source "$TOKEN_FILE" 2>/dev/null || true
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
  expires=$(echo "$response" | jq -r '.expires_in // 3600')

  [ -z "$token" ] || [ "$token" = "null" ] && {
    log "ERROR autenticando: $response"
    echo "❌ Error autenticando con Woffu"
    exit 1
  }

  exp=$((now + expires - 60))

  {
    echo "WOFFY_TOKEN=\"$token\""
    echo "WOFFY_TOKEN_EXP=$exp"
  } > "$TOKEN_FILE"

  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  log "Token renovado correctamente"
  echo "$token"
}

# ─────────────────────────────────────────────
# API wrapper (solo endpoints reales)
# ─────────────────────────────────────────────
api_get() {
  curl -s -H "Authorization: Bearer $TOKEN" "$1"
}

api_post() {
  curl -s -X POST "$1" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$2"
}

# ─────────────────────────────────────────────
# Cron helpers (ORIGINAL)
# ─────────────────────────────────────────────
clear_woffy_cron() {
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+(in|out)/ && !/# woffy-(in|out)/ {print}' > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
}

# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
require_config

case "${1:-help}" in
  version)
    echo "woffy v$VERSION"
    ;;

  in|out)
    check_deps
    require_creds
    TOKEN=$(get_token)

    log "Intento de fichaje: $1"

    STATUS=$(api_get "$API_URL/api/signs" | jq -r '.[-1].SignIn')
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

    api_post "$API_URL/api/signs" \
      '{"signType":0,"date":"'"$(date -Iseconds)"'","action":"'"$ACTION"'"}' \
      >/dev/null

    echo "✅ Fichaje '$1' realizado correctamente."
    log "Fichaje $1 OK"
    tg_send success "✅ Fichaje *$1* realizado a las *$(date +%H:%M)*."
    ;;

  status)
    check_deps
    require_creds
    TOKEN=$(get_token)

    STATUS=$(api_get "$API_URL/api/signs" | jq -r '.[-1].SignIn')
    [ "$STATUS" = "true" ] && echo "📍 Estás fichado DENTRO." || echo "📍 Estás fichado FUERA."
    ;;

  login)
    read -p "Correo: " EMAIL
    read -s -p "Contraseña: " PASS
    echo

    TMP=$(mktemp)
    grep -v '^WURL_' "$CONFIG_FILE" 2>/dev/null > "$TMP" || true

    {
      echo "WURL_USER=\"$EMAIL\""
      echo "WURL_PASS=\"$PASS\""
    } >> "$TMP"

    mv "$TMP" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    rm -f "$TOKEN_FILE" 2>/dev/null || true

    echo "✅ Credenciales actualizadas."
    log "Credenciales actualizadas"
    ;;

  telegram)
    read -p "Token de bot (sin 'bot'): " TG
    read -p "Chat ID: " CHAT
    read -p "Thread ID (opcional): " THREAD
    read -p "Notificaciones (errors | success | all) [all]: " NOTIFY
    NOTIFY=${NOTIFY:-all}

    TMP=$(mktemp)
    grep -v '^TG_' "$CONFIG_FILE" 2>/dev/null > "$TMP" || true

    {
      echo "TG_TOKEN=\"$TG\""
      echo "TG_CHAT_ID=\"$CHAT\""
      [ -n "$THREAD" ] && echo "TG_THREAD=\"$THREAD\""
      echo "TG_NOTIFY=\"$NOTIFY\""
    } >> "$TMP"

    mv "$TMP" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo "✅ Telegram configurado."
    log "Telegram configurado"
    ;;

  schedule)
    case "${2:-}" in
      list)
        crontab -l 2>/dev/null | grep -E '# woffy-(in|out)|woffy (in|out)' || echo "(Sin tareas)"
        ;;
      pause)
        crontab -l 2>/dev/null | sed 's/^/#DISABLED# /' | crontab -
        echo "⏸️ Tareas pausadas."
        ;;
      resume)
        crontab -l 2>/dev/null | sed 's/^#DISABLED# //' | crontab -
        echo "▶️ Tareas reactivadas."
        ;;
      clear)
        clear_woffy_cron
        echo "🧹 Crontab limpiado."
        ;;
      entrada)
        TIMES=("09:00" "15:30")
        [ -n "${3:-}" ] && TIMES=("$3")
        TMP=$(mktemp)
        crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+in/ {print}' > "$TMP" || true
        for T in "${TIMES[@]}"; do
          IFS=':' read -r H M <<< "$T"
          echo "$M $H * * 1-5 woffy in # woffy-in" >> "$TMP"
        done
        crontab "$TMP"
        rm -f "$TMP"
        echo "✅ Entradas programadas."
        ;;
      salida)
        TIMES=("14:00" "18:00")
        [ -n "${3:-}" ] && TIMES=("$3")
        TMP=$(mktemp)
        crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+out/ {print}' > "$TMP" || true
        for T in "${TIMES[@]}"; do
          IFS=':' read -r H M <<< "$T"
          echo "$M $H * * 1-5 woffy out # woffy-out" >> "$TMP"
        done
        crontab "$TMP"
        rm -f "$TMP"
        echo "✅ Salidas programadas."
        ;;
    esac
    ;;

  doctor)
    echo "🩺 Diagnóstico woffy v$VERSION"
    echo "Config:  OK"
    echo "Token:   $([ -f "$TOKEN_FILE" ] && echo OK || echo NO)"
    echo "Log:     $LOG_FILE"
    echo "Deps:    $(command -v curl >/dev/null && command -v jq >/dev/null && echo OK || echo ERROR)"
    echo "Cron:    $(crontab -l 2>/dev/null | grep -c 'woffy ') entradas"
    ;;

  help|*)
    echo "woffy v$VERSION"
    echo
    echo "Comandos:"
    echo "  in | out        Fichar"
    echo "  status          Ver estado"
    echo "  login           Configurar credenciales"
    echo "  telegram        Configurar Telegram"
    echo "  schedule        Programación en cron"
    echo "  doctor          Diagnóstico"
    echo "  version         Mostrar versión"
    ;;
esac
