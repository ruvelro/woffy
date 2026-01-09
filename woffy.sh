#!/bin/bash
set -e

CONFIG_FILE="$HOME/.woffy.conf"
[ ! -f "$CONFIG_FILE" ] && echo "❌ Configuración no encontrada. Ejecuta 'woffy login'" && exit 1
source "$CONFIG_FILE"

tg_send() {
  [ -z "${TG_TOKEN:-}" ] && return

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
    > /dev/null
}

check_deps() {
  local missing=()

  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    MSG="❌ Faltan dependencias necesarias: ${missing[*]}"
    echo "$MSG"
    echo "Instálalas antes de usar woffy."
    echo "Ejemplo (Debian/Ubuntu): sudo apt install ${missing[*]}"

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

API_URL="https://app.woffu.com"
TOKEN=$(curl -s -X POST "$API_URL/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS" | jq -r .access_token)

clear_woffy_cron() {
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+(in|out)/ && !/# woffy-(in|out)/ {print}' > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
}

case "$1" in
  in|out)
    STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" | jq -r '.[-1].SignIn')
    ACTION="clock_in"
    [[ "$1" == "out" ]] && ACTION="clock_out"

    if [[ "$STATUS" == "true" && "$1" == "in" ]]; then
      echo "❌ Ya estás fichado dentro."
      tg_send error "❌ Ya estás fichado *dentro*."
      exit 1
    elif [[ "$STATUS" == "false" && "$1" == "out" ]]; then
      echo "❌ Ya estás fichado fuera."
      tg_send error "❌ Ya estás fichado *fuera*."
      exit 1
    fi

    RESPONSE=$(curl -s -X POST "$API_URL/api/signs" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"signType":0,"date":"'"$(date -Iseconds)"'","action":"'"$ACTION"'"}')

    echo "✅ Fichaje '$1' realizado correctamente."
    tg_send success "✅ Fichaje *$1* realizado a las *$(date +%H:%M)*."
    ;;

  status)
    STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" | jq -r '.[-1].SignIn')
    if [ "$STATUS" == "true" ]; then
      echo "📍 Actualmente estás fichado DENTRO."
    else
      echo "📍 Actualmente estás fichado FUERA."
    fi
    ;;

  login)
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

  echo "✅ Credenciales de Woffu actualizadas."
  ;;


  telegram)
  read -p "Token de bot (sin 'bot'): " TG
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
  ;;


  schedule)
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
        fi
        ;;
      resume)
        CURRENT=$(crontab -l 2>/dev/null || true)
        if [ -z "$CURRENT" ]; then
          echo "(No hay tareas para reactivar)"
        else
          echo "$CURRENT" | sed 's/^#DISABLED# //' | crontab -
          echo "▶️ Tareas programadas reactivadas."
        fi
        ;;
      clear)
        clear_woffy_cron
        echo "🧹 Todas las entradas de woffy en crontab han sido eliminadas."
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
        ;;
      *)
        echo "❌ Uso: woffy schedule {list|pause|resume|clear|entrada [HH:MM]|salida [HH:MM]}"
        exit 1
        ;;
    esac
    ;;

  help|*)
    echo "Comandos disponibles:"
    echo "  in              Fichar entrada"
    echo "  out             Fichar salida"
    echo "  status          Consultar estado actual"
    echo "  login           Reconfigurar credenciales"
    echo "  telegram        Configurar notificaciones"
    echo "  schedule        Gestionar programación en cron"
    echo "      list        Mostrar fichajes programados"
    echo "      pause       Desactivar tareas"
    echo "      resume      Activar tareas"
    echo "      clear       Eliminar todas las entradas de woffy en crontab"
    echo "      entrada     Añadir tareas de entrada [HH:MM opcional]"
    echo "      salida      Añadir tareas de salida [HH:MM opcional]"
    ;;
esac
