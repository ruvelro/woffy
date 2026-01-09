#!/bin/bash
set -euo pipefail

CONFIG_FILE="$HOME/.woffy.conf"
API_URL="https://app.woffu.com"

# Comprobaciones básicas de comandos necesarios
for cmd in curl jq crontab date sort mktemp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Necesitas '$cmd' instalado para usar woffy."
    exit 1
  fi
done

# tg_send: envía notificaciones por Telegram si está configurado
tg_send() {
  [ -z "${TG_TOKEN:-}" ] && return
  local MSG="$1"
  local CURL_ARGS=(-s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$MSG" -d "parse_mode=Markdown")
  [ -n "${TG_THREAD:-}" ] && CURL_ARGS+=(-d "message_thread_id=$TG_THREAD")
  curl "${CURL_ARGS[@]}" >/dev/null || true
}

# NO requerir config para comandos como login/help/telegram/schedule
COMMAND="${1:-help}"
case "$COMMAND" in
  login|help|telegram|schedule) ;;
  *)
    if [ ! -f "$CONFIG_FILE" ]; then
      echo "❌ Configuración no encontrada. Ejecuta 'woffy login'"
      exit 1
    fi
    # Cargamos la configuración
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    ;;
esac

# Obtener token solo para las acciones que lo requieren
get_token() {
  if [ -n "${TOKEN:-}" ]; then
    return
  fi
  if [ -z "${WURL_USER:-}" ] || [ -z "${WURL_PASS:-}" ]; then
    echo "❌ Faltan credenciales en $CONFIG_FILE. Ejecuta 'woffy login'."
    exit 1
  fi
  local resp
  resp=$(curl -s -X POST "$API_URL/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS")
  TOKEN=$(echo "$resp" | jq -r '.access_token // empty')
  if [ -z "$TOKEN" ]; then
    echo "❌ No se pudo obtener token. Respuesta del servidor:"
    echo "$resp"
    exit 1
  fi
}

case "$COMMAND" in
  in|out)
    # Obtener token y estado actual
    get_token

    STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" | jq -r '.[-1].SignIn // empty')

    ACTION="clock_in"
    [[ "$COMMAND" == "out" ]] && ACTION="clock_out"

    if [[ "$STATUS" == "true" && "$COMMAND" == "in" ]]; then
      echo "❌ Ya estás fichado dentro."
      tg_send "❌ Ya estás fichado *dentro*."
      exit 1
    elif [[ "$STATUS" == "false" && "$COMMAND" == "out" ]]; then
      echo "❌ Ya estás fichado fuera."
      tg_send "❌ Ya estás fichado *fuera*."
      exit 1
    fi

    RESPONSE=$(curl -s -X POST "$API_URL/api/signs" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"signType\":0,\"date\":\"$(date -Iseconds)\",\"action\":\"$ACTION\"}")

    echo "✅ Fichaje '$COMMAND' realizado correctamente."
    tg_send "✅ Fichaje *$COMMAND* realizado a las *$(date +%H:%M)*."
    ;;

  status)
    get_token
    STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" | jq -r '.[-1].SignIn // empty')
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
    cat > "$CONFIG_FILE" <<EOF
WURL_USER="$EMAIL"
WURL_PASS="$PASS"
EOF
    chmod 600 "$CONFIG_FILE"
    echo "✅ Configuración actualizada."
    ;;

  telegram)
    # Aseguramos que el archivo existe antes de añadir (si no, lo creamos)
    [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"
    read -p "Token de bot: " TG
    read -p "Chat ID: " CHAT
    read -p "Thread ID (opcional): " THREAD
    # Eliminamos entradas previas y añadimos las nuevas de forma sencilla
    # Usamos grep -v para no duplicar si ya existía (mínimo esfuerzo)
    sed -i '/^TG_TOKEN=/d' "$CONFIG_FILE" 2>/dev/null || true
    sed -i '/^TG_CHAT_ID=/d' "$CONFIG_FILE" 2>/dev/null || true
    sed -i '/^TG_THREAD=/d' "$CONFIG_FILE" 2>/dev/null || true
    {
      echo "TG_TOKEN=\"$TG\""
      echo "TG_CHAT_ID=\"$CHAT\""
      echo "TG_THREAD=\"$THREAD\""
    } >> "$CONFIG_FILE"
    echo "✅ Telegram configurado."
    ;;

  schedule)
    SUB="${2:-}"
    case "$SUB" in
      list)
        crontab -l 2>/dev/null | grep '# woffy-' || echo "(Sin tareas programadas)"
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
      entrada)
        TIMES=("09:00" "15:30")
        [ -n "${3:-}" ] && TIMES=("$3")
        TMP_CRON=$(mktemp)
        crontab -l 2>/dev/null | grep -v '# woffy-in' > "$TMP_CRON" || true
        for T in "${TIMES[@]}"; do
          # extraer hora y minuto de forma segura y manejar 00
          IFS=':' read -r HOUR MIN <<< "$T"
          HOUR=$((10#$HOUR))
          MIN=$((10#$MIN))
          echo "$MIN $HOUR * * 1-5 woffy in # woffy-in" >> "$TMP_CRON"
        done
        sort -u "$TMP_CRON" | crontab -
        rm -f "$TMP_CRON"
        echo "✅ Fichajes de entrada programados."
        ;;
      salida)
        TIMES=("14:00" "18:00")
        [ -n "${3:-}" ] && TIMES=("$3")
        TMP_CRON=$(mktemp)
        crontab -l 2>/dev/null | grep -v '# woffy-out' > "$TMP_CRON" || true
        for T in "${TIMES[@]}"; do
          IFS=':' read -r HOUR MIN <<< "$T"
          HOUR=$((10#$HOUR))
          MIN=$((10#$MIN))
          echo "$MIN $HOUR * * 1-5 woffy out # woffy-out" >> "$TMP_CRON"
        done
        sort -u "$TMP_CRON" | crontab -
        rm -f "$TMP_CRON"
        echo "✅ Fichajes de salida programados."
        ;;
      *)
        echo "❌ Uso: woffy schedule {list|pause|resume|entrada [HH:MM]|salida [HH:MM]}"
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
    echo "      entrada     Añadir tareas de entrada [HH:MM opcional]"
    echo "      salida      Añadir tareas de salida [HH:MM opcional]"
    ;;
esac
