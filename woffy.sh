#!/bin/bash
set -e

VERSION="1.1.1-safe"

CONFIG_FILE="$HOME/.woffy.conf"
TOKEN_FILE="$HOME/.woffy.token"
LOG_FILE="$HOME/.woffy.log"
API_URL="https://app.woffu.com"

# ─────────────────────────────────────────────
# Base
# ─────────────────────────────────────────────
[ ! -f "$CONFIG_FILE" ] && {
  echo "❌ Configuración no encontrada. Ejecuta 'woffy login'"
  exit 1
}

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ─────────────────────────────────────────────
# Log pasivo (no rompe nada)
# ─────────────────────────────────────────────
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# ─────────────────────────────────────────────
# Telegram
# ─────────────────────────────────────────────
tg_send() {
  [ -z "${TG_TOKEN:-}" ] && return
  [ -z "${TG_CHAT_ID:-}" ] && return

  local TYPE="$1"   # error | success | test
  local MSG="$2"

  case "${TG_NOTIFY:-all}" in
    all) ;;
    errors)  [ "$TYPE" != "error" ] && return ;;
    success) [ "$TYPE" != "success" ] && return ;;
    test) ;;
    *) ;;
  esac

  curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$MSG" \
    ${TG_THREAD:+-d message_thread_id=$TG_THREAD} \
    > /dev/null || true
}

# ─────────────────────────────────────────────
# Dependencias (igual que 1.0)
# ─────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    MSG="❌ Faltan dependencias necesarias: ${missing[*]}"
    echo "$MSG"
    tg_send error "$MSG"
    exit 1
  fi
}

# help no necesita dependencias
case "$1" in
  help|"")
    ;;
  *)
    check_deps
    ;;
esac

# ─────────────────────────────────────────────
# Token OAuth (cacheado, fallback seguro)
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

  token=$(echo "$response" | jq -r .access_token)
  expires=$(echo "$response" | jq -r '.expires_in // 3600')

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    log "ERROR autenticando: $response"
    echo "❌ Error autenticando con Woffu"
    exit 1
  fi

  exp=$((now + expires - 60))

  {
    echo "WOFFY_TOKEN=\"$token\""
    echo "WOFFY_TOKEN_EXP=$exp"
  } > "$TOKEN_FILE" 2>/dev/null || true

  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  log "Token renovado correctamente"
  echo "$token"
}

TOKEN=$(get_token)

# ─────────────────────────────────────────────
# Cron helpers (idéntico a 1.0)
# ─────────────────────────────────────────────
clear_woffy_cron() {
  local tmp
  tmp=$(mktemp)

  crontab -l 2>/dev/null | \
    awk '!/woffy[[:space:]]+(in|out)/ && !/# woffy-(in|out)/ {print}' \
    > "$tmp" || true

  crontab "$tmp" || true
  rm -f "$tmp"
}

# ─────────────────────────────────────────────
# Comandos
# ─────────────────────────────────────────────
case "$1" in
  version)
    echo "woffy v$VERSION"
    ;;

  in|out)
    log "Intento de fichaje: $1"

    STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" \
      "$API_URL/api/signs" | jq -r '.[-1].SignIn')

    ACTION="clock_in"
    [[ "$1" == "out" ]] && ACTION="clock_out"

    if [[ "$STATUS" == "true" && "$1" == "in" ]]; then
      echo "❌ Ya estás fichado dentro."
      tg_send error "❌ Ya estás fichado dentro."
      exit 1
    elif [[ "$STATUS" == "false" && "$1" == "out" ]]; then
      echo "❌ Ya estás fichado fuera."
      tg_send error "❌ Ya estás fichado fuera."
      exit 1
    fi

    curl -s -X POST "$API_URL/api/signs" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"signType":0,"date":"'"$(date -Iseconds)"'","action":"'"$ACTION"'"}' \
      > /dev/null

    echo "✅ Fichaje '$1' realizado correctamente."
    tg_send success "✅ Fichaje *$1* realizado a las *$(date +%H:%M)*."
    log "Fichaje $1 OK"
    ;;

  status)
    STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" \
      "$API_URL/api/signs" | jq -r '.[-1].SignIn')

    [ "$STATUS" == "true" ] && \
      echo "📍 Actualmente estás fichado DENTRO." || \
      echo "📍 Actualmente estás fichado FUERA."
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

    echo "✅ Credenciales de Woffu actualizadas."
    log "Credenciales actualizadas"
    ;;

  telegram)
    if [ "${2:-}" = "test" ]; then
      tg_send test "✅ Mensaje de prueba de woffy"
      echo "📨 Mensaje de prueba enviado."
      exit 0
    fi

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
    
    # Recargar configuración para que tg_send use los nuevos valores
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    
    echo "✅ Telegram configurado."
    tg_send test "✅ Telegram configurado correctamente en woffy"
    log "Telegram configurado"
    ;;

  doctor)
  echo "🩺 Diagnóstico woffy v$VERSION"
  echo "Config:  OK"
  echo "Token:   $([ -f "$TOKEN_FILE" ] && echo OK || echo NO)"
  echo "Log:     $LOG_FILE"
  echo "Deps:    $(command -v curl >/dev/null && command -v jq >/dev/null && echo OK || echo ERROR)"
  echo "Cron:    $(crontab -l 2>/dev/null | grep -c 'woffy ') entradas"

  # Telegram
  if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
    echo "TG:      Configurado (enviando test...)"
    tg_send test "🩺 Woffy doctor: Telegram funciona correctamente"
  else
    echo "TG:      NO configurado"
  fi
  ;;



  uninstall)
    echo "⚠️ Esto eliminará completamente woffy."
    read -p "¿Seguro? (y/N): " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 0

    clear_woffy_cron
    rm -f "$CONFIG_FILE" "$TOKEN_FILE" "$LOG_FILE"

    BIN_PATH="$(which woffy 2>/dev/null || true)"
    [ -n "$BIN_PATH" ] && rm -f "$BIN_PATH"

    echo "✅ Woffy desinstalado completamente."
    exit 0
    ;;

  update)
    BIN_PATH="$(which woffy)"
    TMP=$(mktemp)

    echo "⬇️ Descargando última versión..."
    curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/main/woffy.sh -o "$TMP" || {
      echo "❌ Error descargando actualización"
      exit 1
    }

    chmod +x "$TMP"
    cp "$TMP" "$BIN_PATH"
    rm -f "$TMP"

    echo "✅ Woffy actualizado correctamente."
    exit 0
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

  help|*)
    echo "woffy v$VERSION"
    echo
    echo "Comandos:"
    echo "  in | out        Fichar"
    echo "  status          Ver estado"
    echo "  login           Configurar credenciales"
    echo "  telegram        Configurar Telegram"
    echo "  telegram test   Enviar mensaje de prueba"
    echo "  schedule        Programación en cron"
    echo "  doctor          Diagnóstico"
    echo "  update          Actualizar woffy"
    echo "  uninstall       Desinstalar completamente"
    echo "  version         Mostrar versión"
    ;;
esac
