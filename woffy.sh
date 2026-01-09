#!/bin/bash
set -euo pipefail

CONFIG_FILE="$HOME/.woffy.conf"
API_URL="https://app.woffu.com"

# Comprobaciones básicas de comandos necesarios
for cmd in curl jq crontab date sort mktemp awk sed; do
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

# Interpreta el valor retornado por la API para SignIn en forma robusta
# Devuelve "inside", "outside" o "unknown"
interpret_status() {
  local raw="$1"
  local lowered
  lowered=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | xargs || true)
  case "$lowered" in
    "true"|"1"|"yes"|"y"|"si"|"sí")
      printf 'inside'
      ;;
    "false"|"0"|"no"|"n")
      printf 'outside'
      ;;
    *)
      printf 'unknown'
      ;;
  esac
}

# Extrae el último SignIn de la respuesta de /api/signs de forma tolerante
extract_last_signin() {
  local body="$1"
  # Si body vacío, devolvemos vacío
  if [ -z "${body}" ]; then
    printf ''
    return
  fi

  # Probamos varias rutas comunes. jq devuelve vacío si no existe.
  printf '%s' "$body" | jq -r '
    try (
      if type=="array" then
        (.[-1].SignIn // .[-1].signIn // .[-1].sign_in // empty)
      elif (has("data") and (.data | type=="array")) then
        (.data[-1].SignIn // .data[-1].signIn // .data[-1].sign_in // empty)
      elif has("SignIn") then
        (.SignIn // .signIn // .sign_in // empty)
      else
        empty
      end
    ) catch ""' 2>/dev/null || true
}

# GET a /api/signs con código HTTP y reintento sencillo
api_get_signs() {
  local body_and_code resp body http_code attempt=0
  while [ $attempt -le 1 ]; do
    body_and_code=$(curl -s -H "Authorization: Bearer $TOKEN" -w "%{http_code}" "$API_URL/api/signs" || true)
    http_code="${body_and_code: -3}"
    body="${body_and_code:0:$((${#body_and_code}-3))}"
    if [ -n "$body" ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      printf '%s' "$body"
      return 0
    fi
    attempt=$((attempt+1))
    sleep 1
  done
  # si falló, devolvemos cuerpo (posible vacío) y exportamos código vía variable
  printf '%s' "$body"
  return 1
}

# POST para realizar fichaje; devuelve código HTTP y cuerpo
api_post_sign() {
  local payload="$1"
  local body_and_code resp body http_code
  body_and_code=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -w "%{http_code}" -d "$payload" "$API_URL/api/signs" || true)
  http_code="${body_and_code: -3}"
  body="${body_and_code:0:$((${#body_and_code}-3))}"
  printf '%s|%s' "$http_code" "$body"
}

# Elimina todas las entradas de woffy (in/out) en crontab
clear_woffy_cron() {
  local tmp
  tmp=$(mktemp)
  # Conservamos todas las líneas que NO contengan 'woffy in' ni 'woffy out' ni los comentarios '# woffy-in'/'# woffy-out'
  crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+(in|out)/ && !/# woffy-(in|out)/ {print}' > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
}

case "$COMMAND" in
  in|out)
    get_token

    raw_body=$(api_get_signs) || true

    if [ -z "${raw_body:-}" ]; then
      echo "⚠️ No se obtuvo respuesta válida de la API al consultar el estado (respuesta vacía o error HTTP)."
      echo "Aborto para evitar duplicados. Vuelve a intentarlo o comprueba conectividad/credenciales."
      exit 1
    fi

    LAST_SIGNIN=$(extract_last_signin "$raw_body" || true)
    STATUS=$(interpret_status "$LAST_SIGNIN")

    ACTION="clock_in"
    [[ "$COMMAND" == "out" ]] && ACTION="clock_out"

    if [[ "$STATUS" == "inside" && "$COMMAND" == "in" ]]; then
      echo "❌ Ya estás fichado dentro."
      tg_send "❌ Ya estás fichado *dentro*."
      exit 1
    elif [[ "$STATUS" == "outside" && "$COMMAND" == "out" ]]; then
      echo "❌ Ya estás fichado fuera."
      tg_send "❌ Ya estás fichado *fuera*."
      exit 1
    elif [[ "$STATUS" == "unknown" ]]; then
      echo "⚠️ Estado desconocido (no se pudo interpretar la respuesta de la API). Se aborta para evitar duplicados."
      echo "Respuesta API (extracto): $(printf '%s' "$LAST_SIGNIN" | sed -n '1,3p')"
      exit 1
    fi

    payload="{\"signType\":0,\"date\":\"$(date -Iseconds)\",\"action\":\"$ACTION\"}"
    res=$(api_post_sign "$payload")
    http_code="${res%%|*}"
    body="${res#*|}"

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      echo "✅ Fichaje '$COMMAND' realizado correctamente."
      tg_send "✅ Fichaje *$COMMAND* realizado a las *$(date +%H:%M)*."
    else
      echo "❌ Error al realizar el fichaje (HTTP $http_code). Respuesta:"
      echo "$body"
      exit 1
    fi
    ;;

  status)
    get_token
    raw_body=$(api_get_signs) || true
    if [ -z "${raw_body:-}" ]; then
      echo "❓ No se pudo obtener estado (API no respondió)."
      exit 1
    fi
    LAST_SIGNIN=$(extract_last_signin "$raw_body" || true)
    STATUS=$(interpret_status "$LAST_SIGNIN")
    if [ "$STATUS" == "inside" ]; then
      echo "📍 Actualmente estás fichado DENTRO."
    elif [ "$STATUS" == "outside" ]; then
      echo "📍 Actualmente estás fichado FUERA."
    else
      echo "❓ Estado desconocido. Extracto de la respuesta API:"
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
    [ -f "$CONFIG_FILE" ] || { touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"; }
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
    SUB="${2:-}"
    case "$SUB" in
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
        crontab -l 2>/dev/null | awk '!/woffy[[:space:]]+out/ && !/# woffy-out/ {print}' > "$TMP_CRON" || true
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
