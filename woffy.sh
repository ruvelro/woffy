#!/bin/bash
set -e

CONFIG_FILE="$HOME/.woffy.conf"

# Verificar existencia del config
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Configuración no encontrada. Ejecuta 'woffy login'"
    exit 1
fi

source "$CONFIG_FILE"

API_URL="https://app.woffu.com"

# Obtener Token con validación de errores
TOKEN_RESPONSE=$(curl -s -X POST "$API_URL/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS")

TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .access_token)

if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
    echo "❌ Error de autenticación. Revisa tus credenciales con 'woffy login'."
    exit 1
fi

tg_send() {
    [ -z "$TG_TOKEN" ] && return
    MSG="$1"
    TYPE="$2"

    case "${TG_NOTIFY:-errors}" in
        errors)  [[ "$TYPE" == "error" ]] || return ;;
        success) [[ "$TYPE" == "success" ]] || return ;;
        all)     ;; 
        *)       return ;;
    esac

    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
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
            tg_send "❌ Ya estás fichado *dentro*." error
            exit 1
        elif [[ "$STATUS" == "false" && "$1" == "out" ]]; then
            echo "❌ Ya estás fichado fuera."
            tg_send "❌ Ya estás fichado *fuera*." error
            exit 1
        fi

        curl -s -X POST "$API_URL/api/signs" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"signType":0,"date":"'"$(date -Iseconds)'","action":"'"$ACTION"'"}' > /dev/null

        echo "✅ Fichaje '$1' realizado correctamente."
        tg_send "✅ Fichaje *$1* realizado a las *$(date +%H:%M)*." success
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
        touch "$CONFIG_FILE"
        sed -i '/^WURL_/d' "$CONFIG_FILE" 2>/dev/null || true
        echo "WURL_USER=\"$EMAIL\"" >> "$CONFIG_FILE"
        echo "WURL_PASS=\"$PASS\"" >> "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo "✅ Configuración actualizada."
        ;;

    telegram)
        read -p "Token de bot (sin 'bot'): " TG
        read -p "Chat ID: " CHAT
        read -p "Thread ID (opcional): " THREAD
        read -p "Modo notificación (errors/success/all) [errors]: " MODE
        touch "$CONFIG_FILE"
        sed -i '/^TG_/d' "$CONFIG_FILE" 2>/dev/null || true
        echo "TG_TOKEN=\"$TG\"" >> "$CONFIG_FILE"
        echo "TG_CHAT_ID=\"$CHAT\"" >> "$CONFIG_FILE"
        echo "TG_THREAD=\"$THREAD\"" >> "$CONFIG_FILE"
        echo "TG_NOTIFY=\"${MODE:-errors}\"" >> "$CONFIG_FILE"
        echo "✅ Telegram configurado."
        ;;

    schedule)
        case "${2:-}" in
            list)
                crontab -l 2>/dev/null | grep -E '# woffy-(in|out)|woffy (in|out)' || echo "(Sin tareas programadas)"
                ;;
            pause)
                crontab -l 2>/dev/null | sed 's/^\([^#]\)/#DISABLED# \1/' | crontab -
                echo "停 Tareas programadas pausadas."
                ;;
            resume)
                crontab -l 2>/dev/null | sed 's/^#DISABLED# //' | crontab -
                echo "▶️ Tareas programadas reactivadas."
                ;;
            clear)
                clear_woffy_cron
                echo "🧹 Todas las entradas eliminadas."
                ;;
            entrada|salida)
                TYPE="in"; [[ "$2" == "salida" ]] && TYPE="out"
                TIMES=("09:00" "18:00") # Defaults
                [[ "$2" == "entrada" ]] && TIMES=("09:00" "15:30")
                [ -n "${3:-}" ] && TIMES=("$3")
                
                TMP_CRON=$(mktemp)
                crontab -l 2>/dev/null | awk -v t="$TYPE" '!($0 ~ "woffy " t) && !($0 ~ "woffy-" t) {print}' > "$TMP_CRON" || true
                for T in "${TIMES[@]}"; do
                    IFS=':' read -r H M <<< "$T"
                    H=$((10#$H)); M=$((10#$M))
                    echo "$M $H * * 1-5 $(command -v woffy || echo "woffy") $TYPE # woffy-$TYPE" >> "$TMP_CRON"
                done
                crontab "$TMP_CRON"
                rm -f "$TMP_CRON"
                echo "✅ Programación de $2 actualizada."
                ;;
            *)
                echo "Uso: woffy schedule {list|pause|resume|clear|entrada|salida}"
                exit 1
                ;;
        esac
        ;;

    help|*)
        echo "Comandos: in, out, status, login, telegram, schedule"
        ;;
esac
