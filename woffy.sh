#!/bin/bash
set -euo pipefail

CONFIG_FILE="$HOME/.woffy.conf"
[ ! -f "$CONFIG_FILE" ] && echo "❌ Configuración no encontrada. Ejecuta 'woffy login'" && exit 1
# shellcheck disable=SC1090
source "$CONFIG_FILE"

API_URL="https://app.woffu.com"
TOKEN=$(curl -s -X POST "$API_URL/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS" | jq -r '.access_token // empty')

tg_send() {
  [ -z "${TG_TOKEN:-}" ] && return
  MSG="$1"
  CURL_ARGS=(-s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$MSG" -d "parse_mode=Markdown")
  [ -n "${TG_THREAD:-}" ] && CURL_ARGS+=(-d "message_thread_id=$TG_THREAD")
  curl "${CURL_ARGS[@]}" > /dev/null || true
}

interpret_status_value() {
  local v="$1"
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]' | xargs || true)
  case "$v" in
    "true"|"1"|"yes"|"y"|"si"|"sí") printf "inside" ;;
    "false"|"0"|"no"|"n") printf "outside" ;;
    *) printf "unknown" ;;
  esac
}

# Extrae el SignIn del registro más reciente:
# - Si body es array: elige max_by(.SignId) si existe, si no max_by(.Date)
# - Si body es objeto: usa su SignIn
extract_last_signin() {
  local body="$1"
  if [ -z "$body" ]; then
    printf ''
    return
  fi

  # jq intenta varias rutas y usa max_by para arrays
  printf '%s' "$body" | jq -r '
    try (
      if type=="array" then
        ( (map(select(has("SignId")) | .) | if length>0 then max_by(.SignId).SignIn // max_by(.SignId).signIn // max_by(.SignId).sign_in // empty
           else (map(select(has("Date")) | .) | if length>0 then max_by(.Date).SignIn // max_by(.Date).signIn // max_by(.Date).sign_in // empty else (.[-1].SignIn // .[-1].signIn // .[-1].sign_in // empty) end) end)
      elif type=="object" then
        (.SignIn // .signIn // .sign_in // empty)
      else
        empty
      end
    ) catch ""' 2>/dev/null || true
}

# Obtener body de /api/signs (intento rápido)
get_signs_body_once() {
  curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" || true
}

# Reintenta n veces hasta obtener inside/outside (devuelve "inside|raw" o "outside|raw" o "unknown|raw")
fetch_status_with_retries() {
  local attempts="${1:-3}"
  local i=0 body raw_status status
  while [ $i -lt "$attempts" ]; do
    body=$(get_signs_body_once)
    raw_status=$(extract_last_signin "$body" || true)
    status=$(interpret_status_value "$raw_status")
    if [ "$status" = "inside" ] || [ "$status" = "outside" ]; then
      printf '%s|%s' "$status" "$raw_status"
      return 0
    fi
    i=$((i+1))
    [ $i -lt "$attempts" ] && sleep 1
  done
  printf 'unknown|%s' "$raw_status"
  return 0
}

clear_woffy_cron() {
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+(in|out)/ && !/# woffy-(in|out)/ {print}' > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
}

case "${1:-help}" in
  in|out)
    CMD="$1"
    # obtener status con reintentos
    IFS='|' read -r CURRENT_STATUS CURRENT_RAW <<< "$(fetch_status_with_retries 3 || true)"
    ACTION="clock_in"
    [[ "$CMD" == "out" ]] && ACTION="clock_out"

    if [[ "$CURRENT_STATUS" == "inside" && "$CMD" == "in" ]]; then
      echo "❌ Ya estás fichado dentro."
      tg_send "❌ Ya estás fichado *dentro*."
      exit 1
    elif [[ "$CURRENT_STATUS" == "outside" && "$CMD" == "out" ]]; then
      echo "❌ Ya estás fichado fuera."
      tg_send "❌ Ya estás fichado *fuera*."
      exit 1
    fi

    if [[ "$CURRENT_STATUS" == "unknown" ]]; then
      echo "⚠️ No se obtuvo un estado claro de la API tras varios intentos; se intentará fichar de todos modos."
    fi

    # Hacemos el POST y capturamos body+http
    TMP_RESP=$(mktemp)
    HTTP_CODE=$(curl -s -o "$TMP_RESP" -w "%{http_code}" -X POST "$API_URL/api/signs" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"signType\":0,\"date\":\"$(date -Iseconds)\",\"action\":\"$ACTION\"}" || true)
    BODY_POST=$(cat "$TMP_RESP" 2>/dev/null || true)
    rm -f "$TMP_RESP"

    if [ "${HTTP_CODE:-0}" -ge 200 ] && [ "${HTTP_CODE:-0}" -lt 300 ]; then
      echo "✅ Fichaje '$CMD' realizado correctamente (HTTP $HTTP_CODE)."
      tg_send "✅ Fichaje *$CMD* realizado a las *$(date +%H:%M)*."

      # Extraemos SignIn directamente de la respuesta del POST (si existe) y lo mostramos
      NEW_SIGNIN_RAW=$(printf '%s' "$BODY_POST" | jq -r '.SignIn // .signIn // .sign_in // empty' 2>/dev/null || true)
      NEW_STATUS=$(interpret_status_value "$NEW_SIGNIN_RAW")
      if [ "$NEW_STATUS" = "inside" ]; then
        echo "📍 Estado tras fichaje: DENTRO."
      elif [ "$NEW_STATUS" = "outside" ]; then
        echo "📍 Estado tras fichaje: FUERA."
      else
        # Si la respuesta del POST no trae SignIn, hacemos una comprobación GET rápida (uno o dos intentos)
        IFS='|' read -r CONF_STATUS CONF_RAW <<< "$(fetch_status_with_retries 3 || true)"
        if [ "$CONF_STATUS" = "inside" ]; then
          echo "📍 Estado tras fichaje: DENTRO."
        elif [ "$CONF_STATUS" = "outside" ]; then
          echo "📍 Estado tras fichaje: FUERA."
        else
          echo "⚠️ No se pudo confirmar el estado tras el fichaje (API ambigua)."
          [ -n "$BODY_POST" ] && echo "Respuesta del POST: $(printf '%s' "$BODY_POST" | sed -n '1,10p')"
        fi
      fi
    else
      echo "❌ Error al realizar el fichaje (HTTP ${HTTP_CODE:-?}). Respuesta:"
      printf '%s\n' "$BODY_POST"
      exit 1
    fi
    ;;

  status)
    IFS='|' read -r STATUS RAW <<< "$(fetch_status_with_retries 3 || true)"
    if [ "$STATUS" = "inside" ]; then
      echo "📍 Actualmente estás fichado DENTRO."
    elif [ "$STATUS" = "outside" ]; then
      echo "📍 Actualmente estás fichado FUERA."
    else
      echo "❓ Estado desconocido. Extracto respuesta API (último intento):"
      printf '%s\n' "$RAW" | sed -n '1,10p'
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
    read -p "Token de bot: " TG
    read -p "Chat ID: " CHAT
    read -p "Thread ID (opcional): " THREAD
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
