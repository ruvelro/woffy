#!/bin/bash
set -euo pipefail

CONFIG_FILE="$HOME/.woffy.conf"
API_URL="https://app.woffu.com"

# Verificación comandos mínimos
for cmd in curl jq crontab mktemp sed awk sort date; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Necesitas '$cmd' instalado para usar woffy."
    exit 1
  fi
done

tg_send() {
  [ -z "${TG_TOKEN:-}" ] && return
  local MSG="$1"
  local CURL_ARGS=(-s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$MSG" -d "parse_mode=Markdown")
  [ -n "${TG_THREAD:-}" ] && CURL_ARGS+=(-d "message_thread_id=$TG_THREAD")
  curl "${CURL_ARGS[@]}" >/dev/null || true
}

# Requerir config al inicio (igual que tu script original)
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ Configuración no encontrada. Ejecuta 'woffy login'"
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Obtener token (igual que tu versión que funcionaba)
TOKEN=$(curl -s -X POST "$API_URL/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS" | jq -r .access_token // empty)

if [ -z "$TOKEN" ]; then
  echo "❌ No se pudo obtener token. Revisa credenciales con 'woffy login'."
  exit 1
fi

# Interpretación simple del SignIn
interpret_status_value() {
  local v="$1"
  # normalizar
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]' | xargs)" in
    "true"|"1"|"yes"|"y"|"si"|"sí") printf "inside" ;;
    "false"|"0"|"no"|"n") printf "outside" ;;
    *) printf "" ;;
  esac
}

# Extrae última propiedad SignIn de forma tolerante
extract_last_signin() {
  local body="$1"
  if [ -z "$body" ]; then
    printf ""
    return
  fi
  printf '%s' "$body" | jq -r 'try (if type=="array" then (.[-1].SignIn // .[-1].signIn // .[-1].sign_in // empty) elif has("data") and (.data|type=="array") then (.data[-1].SignIn // .data[-1].signIn // .data[-1].sign_in // empty) elif has("SignIn") then (.SignIn // .signIn // .sign_in // empty) else empty end) catch ""' 2>/dev/null || true
}

# Lee /api/signs con un reintento sencillo
get_signs_body() {
  local body
  body=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" || true)
  if [ -z "$body" ]; then
    sleep 1
    body=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" || true)
  fi
  printf '%s' "$body"
}

# Borra todas las entradas de woffy (in/out) en crontab
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

    # Obtener estado
    body="$(get_signs_body)"
    LAST_SIGNIN="$(extract_last_signin "$body")"
    STATUS="$(interpret_status_value "$LAST_SIGNIN")"

    ACTION="clock_in"
    [[ "$CMD" == "out" ]] && ACTION="clock_out"

    # Si la API ha devuelto explicitamente inside/outside, evitamos duplicados
    if [[ "$STATUS" == "inside" && "$CMD" == "in" ]]; then
      echo "❌ Ya estás fichado dentro."
      tg_send "❌ Ya estás fichado *dentro*."
      exit 1
    elif [[ "$STATUS" == "outside" && "$CMD" == "out" ]]; then
      echo "❌ Ya estás fichado fuera."
      tg_send "❌ Ya estás fichado *fuera*."
      exit 1
    fi

    # Si no podemos extraer estado (cadena vacía), avisamos pero seguimos (comportamiento próximo al original)
    if [ -z "$STATUS" ]; then
      echo "⚠️ No se pudo obtener estado claro de la API (respuesta vacía o inesperada). Intentando fichar de todos modos..."
    fi

    RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/woffy_post_response.$$ -X POST "$API_URL/api/signs" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"signType\":0,\"date\":\"$(date -Iseconds)\",\"action\":\"$ACTION\"}") || true
    HTTP_CODE="$RESPONSE"
    BODY_POST="$(cat /tmp/woffy_post_response.$$ 2>/dev/null || true)"
    rm -f /tmp/woffy_post_response.$$ || true

    if [ "${HTTP_CODE:-0}" -ge 200 ] && [ "${HTTP_CODE:-0}" -lt 300 ]; then
      echo "✅ Fichaje '$CMD' realizado correctamente."
      tg_send "✅ Fichaje *$CMD* realizado a las *$(date +%H:%M)*."
    else
      echo "❌ Error al realizar el fichaje (HTTP ${HTTP_CODE:-?}). Respuesta:"
      printf '%s\n' "$BODY_POST"
      exit 1
    fi
    ;;

  status)
    body="$(get_signs_body)"
    LAST_SIGNIN="$(extract_last_signin "$body")"
    STATUS="$(interpret_status_value "$LAST_SIGNIN")"
    if [ "$STATUS" == "inside" ]; then
      echo "📍 Actualmente estás fichado DENTRO."
    elif [ "$STATUS" == "outside" ]; then
      echo "📍 Actualmente estás fichado FUERA."
    else
      echo "❓ Estado desconocido. Extracto respuesta API:"
      printf '%s\n' "$LAST_SIGNIN" | sed -n '1,10p'
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
    # Evitamos duplicados en el archivo de config
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
