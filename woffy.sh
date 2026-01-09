#!/bin/bash

# woffy – Fichajes Woffu desde terminal (versión regenerada)

CONFIG_FILE="$HOME/.woffy.conf"
LOG_FILE="$HOME/.woffy.log"

load_config() {
  [[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"
}

notify() {
  local msg="$1"
  [[ "$TG_NOTIFY" == "none" ]] && return
  [[ "$TG_NOTIFY" == "errors" && "$2" != "error" ]] && return
  [[ "$TG_NOTIFY" == "success" && "$2" != "success" ]] && return

  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]] && curl -s -X POST https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage     -d chat_id="$TG_CHAT_ID" -d text="$msg" ${TG_THREAD_ID:+-d message_thread_id="$TG_THREAD_ID"} > /dev/null
}

get_token() {
  curl -s -X POST https://app.woffu.com/token     -H "Content-Type: application/x-www-form-urlencoded"     -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS" | jq -r .access_token
}

status() {
  token=$(get_token)
  signs=$(curl -s -H "Authorization: Bearer $token" https://app.woffu.com/api/signs)
  echo "$signs" | jq '.[] | {fecha: .Date, entrada: .SignIn}' 2>/dev/null
}

fichar() {
  tipo="$1"
  token=$(get_token)
  json=$(curl -s -X POST https://app.woffu.com/api/signs     -H "Authorization: Bearer $token" -H "Content-Type: application/json"     -d "{"signType":0,"date":"$(date -Iseconds)","action":"clock_in"}")
  echo "$json" >> "$LOG_FILE"
  if [[ "$json" == *"SignIn"* ]]; then
    estado=$(echo "$json" | jq .SignIn)
    [[ "$tipo" == "in" && "$estado" == "true" ]] && echo "✅ Ya estabas dentro" && exit 1
    [[ "$tipo" == "out" && "$estado" == "false" ]] && echo "✅ Ya estabas fuera" && exit 1
    notify "✔️ Fichado $tipo correcto a las $(date +%H:%M)" "success"
    echo "✔️ Fichado $tipo correcto."
  else
    notify "❌ Error al fichar ($tipo): $json" "error"
    echo "❌ Error: $json"
    exit 1
  fi
}

if [[ ! -f $CONFIG_FILE ]]; then echo "No hay configuración. Ejecuta 'woffy login'"; exit 1; fi
load_config

case "$1" in
  in) fichar "in" ;;
  out) fichar "out" ;;
  status) status ;;
  login)
    read -p "Email: " email
    read -s -p "Password: " pass && echo
    echo "WURL_USER="$email"" > "$CONFIG_FILE"
    echo "WURL_PASS="$pass"" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "Credenciales actualizadas."
    ;;
  telegram)
    read -p "Token: " tok
    read -p "Chat ID: " chat
    read -p "Thread ID (opcional): " thread
    echo "TG_BOT_TOKEN="$tok"" >> "$CONFIG_FILE"
    echo "TG_CHAT_ID="$chat"" >> "$CONFIG_FILE"
    echo "TG_THREAD_ID="$thread"" >> "$CONFIG_FILE"
    ;;
  help|*) echo "Uso: woffy in|out|status|login|telegram" ;;
esac