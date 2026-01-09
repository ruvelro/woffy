#!/bin/bash
set -e

CONFIG_FILE="$HOME/.woffy.conf"
[ ! -f "$CONFIG_FILE" ] && echo "❌ Configuración no encontrada. Ejecuta 'woffy login'" && exit 1
source "$CONFIG_FILE"

API_URL="https://app.woffu.com"
TOKEN=$(curl -s -X POST "$API_URL/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS" | jq -r .access_token)

tg_send() {
  [ -z "$TG_TOKEN" ] && return
  MSG="$1"
  curl -s -X POST https://api.telegram.org/bot$TG_TOKEN/sendMessage \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$MSG" \
    -d parse_mode="Markdown" \
    ${TG_THREAD:+-d message_thread_id=$TG_THREAD} > /dev/null
}

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
      tg_send "❌ Ya estás fichado *dentro*."
      exit 1
    elif [[ "$STATUS" == "false" && "$1" == "out" ]]; then
      echo "❌ Ya estás fichado fuera."
      tg_send "❌ Ya estás fichado *fuera*."
      exit 1
    fi

    RESPONSE=$(curl -s -X POST "$API_URL/api/signs" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"signType":0,"date":"'"$(date -Iseconds)"'","action":"'"$ACTION"'"}')

    echo "✅ Fichaje '$1' realizado correctamente."
    tg_send "✅ Fichaje *$1* realizado a las *$(date +%H:%M)*."
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
    echo "WURL_USER=\"$EMAIL\"" > "$CONFIG_FILE"
    echo "WURL_PASS=\"$PASS\"" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "✅ Configuración actualizada."
    ;;

  telegram)
    read -p "Token de bot (sin el 'bot' del principio): " TG
    read -p "Chat ID: " CHAT
    read -p "Thread ID (opcional): " THREAD
    echo "TG_TOKEN=\"$TG\"" >> "$CONFIG_FILE"
    echo "TG_CHAT_ID=\"$CHAT\"" >> "$CONFIG_FILE"
    echo "TG_THREAD=\"$THREAD\"" >> "$CONFIG_FILE"
    echo "✅ Telegram configurado."
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
