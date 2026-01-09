#!/bin/bash
set -e

CONFIG_FILE="$HOME/.woffy.conf"
[ ! -f "$CONFIG_FILE" ] && echo "❌ Configuración no encontrada. Ejecuta 'woffy login'" && exit 1
source "$CONFIG_FILE"

API_URL="https://app.woffu.com"
TOKEN=$(curl -s -X POST "$API_URL/token"   -H "Content-Type: application/x-www-form-urlencoded"   -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS" | jq -r .access_token)

if [[ "$1" == "in" || "$1" == "out" ]]; then
  STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" | jq -r '.[-1].SignIn')
  ACTION="clock_in"
  [[ "$1" == "out" ]] && ACTION="clock_out"

  if [[ "$STATUS" == "true" && "$1" == "in" ]]; then
    echo "❌ Ya estás fichado dentro."
    exit 1
  elif [[ "$STATUS" == "false" && "$1" == "out" ]]; then
    echo "❌ Ya estás fichado fuera."
    exit 1
  fi

  RESPONSE=$(curl -s -X POST "$API_URL/api/signs"     -H "Authorization: Bearer $TOKEN"     -H "Content-Type: application/json"     -d '{"signType":0,"date":"'"$(date -Iseconds)"'","action":"'"$ACTION"'"}')

  echo "✅ Fichaje '$1' realizado correctamente."
  exit 0
elif [[ "$1" == "status" ]]; then
  STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" | jq -r '.[-1].SignIn')
  [ "$STATUS" == "true" ] && echo "📍 Actualmente estás fichado DENTRO." || echo "📍 Actualmente estás fichado FUERA."
  exit 0
elif [[ "$1" == "login" ]]; then
  read -p "Correo: " EMAIL
  read -s -p "Contraseña: " PASS
  echo
  echo "WURL_USER="$EMAIL"" > "$CONFIG_FILE"
  echo "WURL_PASS="$PASS"" >> "$CONFIG_FILE"
  echo "TG_NOTIFY=errors" >> "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  echo "✅ Configuración actualizada."
  exit 0
elif [[ "$1" == "help" || -z "$1" ]]; then
  echo "Comandos disponibles: in, out, status, login, help"
  exit 0
else
  echo "❌ Comando desconocido: $1"
  exit 1
fi
