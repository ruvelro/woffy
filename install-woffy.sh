#!/bin/bash

# =====================
# Instalador de woffy CLI
# =====================

if [ $# -lt 2 ]; then
  echo "Uso: bash -s - EMAIL PASSWORD [TELEGRAM_TOKEN CHAT_ID THREAD_ID]"
  exit 1
fi

EMAIL="$1"
PASSWORD="$2"
TG_BOT_TOKEN="$3"
TG_CHAT_ID="$4"
TG_THREAD_ID="$5"

DEST="/usr/local/bin/woffy"
SCRIPT_URL="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/woffy.sh"

TMPDIR=$(mktemp -d)
cd "$TMPDIR" || exit 1

curl -fsSL "$SCRIPT_URL" -o woffy.sh || exit 1

chmod +x woffy.sh
sudo mv woffy.sh "$DEST" || exit 1

CONFIG_FILE="$HOME/.woffy.conf"
echo "WURL_USER="$EMAIL"" > "$CONFIG_FILE"
echo "WURL_PASS="$PASSWORD"" >> "$CONFIG_FILE"
[ -n "$TG_BOT_TOKEN" ] && echo "TG_BOT_TOKEN="$TG_BOT_TOKEN"" >> "$CONFIG_FILE"
[ -n "$TG_CHAT_ID" ] && echo "TG_CHAT_ID="$TG_CHAT_ID"" >> "$CONFIG_FILE"
[ -n "$TG_THREAD_ID" ] && echo "TG_THREAD_ID="$TG_THREAD_ID"" >> "$CONFIG_FILE"
echo "TG_NOTIFY=errors" >> "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# Horarios de fichaje por defecto
(crontab -l 2>/dev/null; echo "0 9 * * 1-5 woffy in # woffy-in") | crontab -
(crontab -l 2>/dev/null; echo "0 14 * * 1-5 woffy out # woffy-out") | crontab -
(crontab -l 2>/dev/null; echo "30 15 * * 1-5 woffy in # woffy-in") | crontab -
(crontab -l 2>/dev/null; echo "0 18 * * 1-5 woffy out # woffy-out") | crontab -

echo "✅ woffy instalado correctamente en /usr/local/bin/woffy"