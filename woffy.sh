#!/bin/bash
set -e

VERSION="1.1"

CONFIG_FILE="$HOME/.woffy.conf"
TOKEN_FILE="$HOME/.woffy.token"
LOG_FILE="$HOME/.woffy.log"
API_URL="https://app.woffu.com"

# ─────────────────────────────────────────────
# Utilidades
# ─────────────────────────────────────────────
init_files() {
  # No fallar si no se puede (por ejemplo FS read-only en algún entorno raro)
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true
}

log() {
  init_files
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

check_deps() {
  local missing=()
  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "❌ Faltan dependencias necesarias: ${missing[*]}"
    echo "Instálalas antes de usar woffy."
    echo "Ejemplo (Debian/Ubuntu): sudo apt install ${missing[*]}"
    tg_send error "❌ Faltan dependencias necesarias: ${missing[*]}"
    exit 1
  fi
}

require_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Configuración no encontrada. Ejecuta 'woffy login'"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

require_creds() {
  if [ -z "${WURL_USER:-}" ] || [ -z "${WURL_PASS:-}" ]; then
    echo "❌ Faltan credenciales. Ejecuta 'woffy login'"
    exit 1
  fi
}

# ─────────────────────────────────────────────
# Telegram (con TG_NOTIFY=errors|success|all)
# ─────────────────────────────────────────────
tg_send() {
  [ -z "${TG_TOKEN:-}" ] && return
  [ -z "${TG_CHAT_ID:-}" ] && return

  local TYPE="$1"   # error | success
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
    > /dev/null || true
}

# ─────────────────────────────────────────────
# Token OAuth cacheado
# ─────────────────────────────────────────────
get_token() {
  local now response token expires_in exp

  now=$(date +%s)

  # Reusar token si sigue válido
  if [ -f "$TOKEN_FILE" ]; then
    # shellcheck disable=SC1090
    source "$TOKEN_FILE" 2>/dev/null || true
    if [ -n "${WOFFY_TOKEN:-}" ] && [ -n "${WOFFY_TOKEN_EXP:-}" ] && [ "$now" -lt "$WOFFY_TOKEN_EXP" ]; then
      echo "$WOFFY_TOKEN"
      return 0
    fi
  fi

  log "Renovando token OAuth"
  response=$(curl -s -X POST "$API_URL/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS")

  token=$(echo "$response" | jq -r '.access_token' 2>/dev/null || echo "")
  expires_in=$(echo "$response" | jq -r '.expires_in' 2>/dev/null || echo "")

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "❌ Error autenticando con Woffu (token vacío)."
    log "ERROR auth: $response"
    tg_send error "❌ Error autenticando con Woffu."
    exit 1
  fi

  # Si no viene expires_in, asumimos 1h con margen
  if [ -z "$expires_in" ] || [ "$expires_in" = "null" ]; then
    expires_in=3600
  fi

  exp=$((now + expires_in - 60))

  {
    echo "WOFFY_TOKEN=\"$token\""
    echo "WOFFY_TOKEN_EXP=$exp"
  } > "$TOKEN_FILE" 2>/dev/null || true

  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  log "Token renovado (expira en ${expires_in}s)"
  echo "$token"
}

# ─────────────────────────────────────────────
# API wrapper con validación HTTP y reintento 401
# ─────────────────────────────────────────────
api_request() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local resp http body

  # Nota: requiere que $TOKEN esté set
  if [ -n "$data" ]; then
    resp=$(curl -s -w '\n%{http_code}' -X "$method" "$url" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$data")
  else
    resp=$(curl -s -w '\n%{http_code}' -X "$method" "$url" \
      -H "Authorization: Bearer $TOKEN")
  fi

  http=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')

  # 401 -> renovar token una vez y reintentar
  if [ "$http" = "401" ]; then
    log "401 Unauthorized: renovando token y reintentando"
    rm -f "$TOKEN_FILE" 2>/dev/null || true
    TOKEN=$(get_token)

    if [ -n "$data" ]; then
      resp=$(curl -s -w '\n%{http_code}' -X "$method" "$url" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$data")
    else
      resp=$(curl -s -w '\n%{http_code}' -X "$method" "$url" \
        -H "Authorization: Bearer $TOKEN")
    fi

    http=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
  fi

  if [ "$http" -lt 200 ] || [ "$http" -ge 300 ]; then
    echo "❌ Error de Woffu (HTTP $http)"
    log "ERROR API $http $method $url :: $body"
    tg_send error "❌ Error de Woffu (HTTP $http)"
    exit 1
  fi

  echo "$body"
}

# ─────────────────────────────────────────────
# Calendario Woffu: NO fichar si claramente hoy no se trabaja
# (Si endpoint/estructura falla -> NO bloquea para no romper)
# ─────────────────────────────────────────────
check_workday_woffu() {
  local today resp working desc type reason

  today=$(date +%Y-%m-%d)

  # Intento best-effort: si falla, no bloqueamos
  resp=$(api_request GET "$API_URL/api/calendar/me?date=$today" 2>/dev/null || true)
  [ -z "$resp" ] && return 0

  # Intentar distintas claves posibles, sin morir si jq falla
  working=$(echo "$resp" | jq -r '.workingDay // .isWorkingDay // empty' 2>/dev/null || true)
  type=$(echo "$resp" | jq -r '.type // empty' 2>/dev/null || true)
  desc=$(echo "$resp" | jq -r '.description // .name // empty' 2>/dev/null || true)
  reason=$(echo "$resp" | jq -r '.reason // empty' 2>/dev/null || true)

  # Bloquear SOLO si:
  # - workingDay=false explícito, o
  # - type indica claramente vacaciones/ausencia
  if [ "$working" = "false" ] || [[ "$type" =~ ^(vacation|vacaciones|absence|ausencia|holiday|festivo|leave|permiso)$ ]]; then
    local label
    label="${desc:-${reason:-$type}}"
    [ -z "$label" ] && label="no laborable"

    echo "❌ Hoy no es un día laborable según Woffu ($label)"
    log "Bloqueado fichaje por calendario Woffu: $label :: resp=$resp"
    tg_send error "❌ No se ficha hoy: $label"
    exit 1
  fi

  return 0
}

# ─────────────────────────────────────────────
# Cron helpers (idéntico al original)
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
# Cargamos config para TODOS los comandos (como el original).
# Esto mantiene compatibilidad con tu instalador actual.
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

    # No fichar si Woffu dice claramente que hoy no trabajas
    check_workday_woffu

    SIGNS=$(api_request GET "$API_URL/api/signs")
    STATUS=$(echo "$SIGNS" | jq -r '.[-1].SignIn' 2>/dev/null || echo "")

    ACTION="clock_in"
    [[ "$1" == "out" ]] && ACTION="clock_out"

    if [[ "$STATUS" == "true" && "$1" == "in" ]]; then
      echo "❌ Ya estás fichado dentro."
      log "ERROR: intento in estando dentro"
      tg_send error "❌ Ya estás fichado *dentro*."
      exit 1
    elif [[ "$STATUS" == "false" && "$1" == "out" ]]; then
      echo "❌ Ya estás fichado fuera."
      log "ERROR: intento out estando fuera"
      tg_send error "❌ Ya estás fichado *fuera*."
      exit 1
    fi

    api_request POST "$API_URL/api/signs" \
      '{"signType":0,"date":"'"$(date -Iseconds)"'","action":"'"$ACTION"'"}' >/dev/null

    echo "✅ Fichaje '$1' realizado correctamente."
    log "Fichaje $1 OK"
    tg_send success "✅ Fichaje *$1* realizado a las *$(date +%H:%M)*."
    ;;

  status)
    check_deps
    require_creds
    TOKEN=$(get_token)

    SIGNS=$(api_request GET "$API_URL/api/signs")
    STATUS=$(echo "$SIGNS" | jq -r '.[-1].SignIn' 2>/dev/null || echo "")

    if [ "$STATUS" == "true" ]; then
      echo "📍 Actualmente estás fichado DENTRO."
    else
      echo "📍 Actualmente estás fichado FUERA."
    fi
    ;;

  login)
    # No requiere deps ni token
    read -p "Correo: " EMAIL
    read -s -p "Contraseña: " PASS
    echo

    TMP=$(mktemp)

    # Copiar todo excepto WURL_*
    grep -v '^WURL_' "$CONFIG_FILE" 2>/dev/null > "$TMP" || true

    {
      echo "WURL_USER=\"$EMAIL\""
      echo "WURL_PASS=\"$PASS\""
    } >> "$TMP"

    mv "$TMP" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    # invalidar token viejo
    rm -f "$TOKEN_FILE" 2>/dev/null || true

    echo "✅ Credenciales de Woffu actualizadas."
    log "Credenciales actualizadas (token invalidado)"
    ;;

  telegram)
    # No requiere deps ni token
    read -p "Token de bot (sin el 'bot' del principio): " TG
    read -p "Chat ID: " CHAT
    read -p "Thread ID (opcional): " THREAD
    read -p "Notificaciones (errors | success | all) [all]: " NOTIFY
    NOTIFY=${NOTIFY:-all}

    TMP=$(mktemp)

    # Copiar todo excepto TG_*
    grep -v '^TG_' "$CONFIG_FILE" 2>/dev/null > "$TMP" || true

    {
      echo "TG_TOKEN=\"$TG\""
      echo "TG_CHAT_ID=\"$CHAT\""
      [ -n "$THREAD" ] && echo "TG_THREAD=\"$THREAD\""
      echo "TG_NOTIFY=\"$NOTIFY\""
    } >> "$TMP"

    mv "$TMP" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo "✅ Telegram configurado (notificaciones: $NOTIFY)."
    log "Telegram configurado (notify=$NOTIFY)"
    ;;

  schedule)
    # Mantiene comportamiento original
    case "${2:-}" in
      list)
        crontab -l 2>/dev/null | grep -E '# woffy-(in|out)|woffy (in|out)' || echo "(Sin tareas programadas)"
        ;;
      pause)
        CURRENT=$(crontab -l 2>/dev/null || true)
        if [ -z "$CURRENT" ]; then
          echo "(No hay tareas para pausar)"
        else
          echo "$CURRENT" | sed 's/^/#DISABLED# /' | crontab -
          echo "⏸️ Tareas programadas pausadas."
          log "Schedule pausado"
        fi
        ;;
      resume)
        CURRENT=$(crontab -l 2>/dev/null || true)
        if [ -z "$CURRENT" ]; then
          echo "(No hay tareas para reactivar)"
        else
          echo "$CURRENT" | sed 's/^#DISABLED# //' | crontab -
          echo "▶️ Tareas programadas reactivadas."
          log "Schedule reanudado"
        fi
        ;;
      clear)
        clear_woffy_cron
        echo "🧹 Todas las entradas de woffy en crontab han sido eliminadas."
        log "Schedule clear"
        ;;
      entrada)
        TIMES=("09:00" "15:30")
        [ -n "${3:-}" ] && TIMES=("$3")
        TMP_CRON=$(mktemp)
        crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+in/ && !/# woffy-in/ {print}' > "$TMP_CRON" || true
        for T in "${TIMES[@]}"; do
          IFS=':' read -r H M <<< "$T"
          H=$((10#$H)); M=$((10#$M))
          echo "$M $H * * 1-5 woffy in # woffy-in" >> "$TMP_CRON"
        done
        sort -u "$TMP_CRON" | crontab -
        rm -f "$TMP_CRON"
        echo "✅ Fichajes de entrada programados."
        log "Schedule entrada actualizado: ${TIMES[*]}"
        ;;
      salida)
        TIMES=("14:00" "18:00")
        [ -n "${3:-}" ] && TIMES=("$3")
        TMP_CRON=$(mktemp)
        crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+out/ && !/# woffy-out/ {print}' > "$TMP_CRON" || true
        for T in "${TIMES[@]}"; do
          IFS=':' read -r H M <<< "$T"
          H=$((10#$H)); M=$((10#$M))
          echo "$M $H * * 1-5 woffy out # woffy-out" >> "$TMP_CRON"
        done
        sort -u "$TMP_CRON" | crontab -
        rm -f "$TMP_CRON"
        echo "✅ Fichajes de salida programados."
        log "Schedule salida actualizado: ${TIMES[*]}"
        ;;
      *)
        echo "❌ Uso: woffy schedule {list|pause|resume|clear|entrada [HH:MM]|salida [HH:MM]}"
        exit 1
        ;;
    esac
    ;;

  doctor)
    echo "🩺 Diagnóstico woffy v$VERSION"
    echo "Config:  $([ -f "$CONFIG_FILE" ] && echo OK || echo ERROR)"
    echo "Token:   $([ -f "$TOKEN_FILE" ] && echo OK || echo NO)"
    echo "Log:     $LOG_FILE"

    # Dependencias
    missing=()
    for cmd in curl jq; do
      command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
      echo "Deps:    OK (curl, jq)"
    else
      echo "Deps:    ❌ Faltan: ${missing[*]}"
    fi

    # Telegram
    if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
      echo "TG:      OK (notify=${TG_NOTIFY:-all})"
    else
      echo "TG:      NO"
    fi

    # Cron woffy
    cron_count=$(crontab -l 2>/dev/null | grep -E 'woffy (in|out) # woffy-(in|out)' | wc -l | tr -d ' ')
    echo "Cron:    $cron_count entradas woffy"

    # API test (best effort)
    if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -n "${WURL_USER:-}" ] && [ -n "${WURL_PASS:-}" ]; then
      TOKEN=$(get_token)
      if api_request GET "$API_URL/api/signs" >/dev/null 2>&1; then
        echo "API:     OK"
      else
        echo "API:     ERROR"
      fi
    else
      echo "API:     (omitido: faltan deps o credenciales)"
    fi
    ;;

  help|*)
    echo "woffy v$VERSION"
    echo
    echo "Comandos disponibles:"
    echo "  in              Fichar entrada"
    echo "  out             Fichar salida"
    echo "  status          Consultar estado actual"
    echo "  login           Cambiar email y contraseña (limpia WURL_*)"
    echo "  telegram        Configurar Telegram (limpia TG_* y permite TG_NOTIFY)"
    echo "  doctor          Diagnóstico (deps, config, token, cron, API best-effort)"
    echo "  version         Mostrar versión"
    echo "  schedule        Gestionar programación en cron"
    echo "      list        Mostrar fichajes programados"
    echo "      pause       Desactivar tareas"
    echo "      resume      Activar tareas"
    echo "      clear       Eliminar todas las entradas de woffy en crontab"
    echo "      entrada     Añadir tareas de entrada [HH:MM opcional]"
    echo "      salida      Añadir tareas de salida [HH:MM opcional]"
    ;;
esac
