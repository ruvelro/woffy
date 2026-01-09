#!/bin/bash
set -e

CONFIG_FILE="$HOME/.woffy.conf"
[ ! -f "$CONFIG_FILE" ] && echo "❌ Configuración no encontrada. Ejecuta 'woffy login'" && exit 1
source "$CONFIG_FILE"

API_URL="https://app.woffu.com"
TOKEN=$(curl -s -X POST "$API_URL/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=$WURL_USER&password=$WURL_PASS" | jq -r .access_token)

case "$1" in
  in|out)
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

    RESPONSE=$(curl -s -X POST "$API_URL/api/signs" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"signType":0,"date":"'"$(date -Iseconds)"'","action":"'"$ACTION"'"}')

    echo "✅ Fichaje '$1' realizado correctamente."
    ;;

  status)
    STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/signs" | jq -r '.[-1].SignIn')
    [ "$STATUS" == "true" ] && echo "📍 Actualmente estás fichado DENTRO." || echo "📍 Actualmente estás fichado FUERA."
    ;;

  login)
    read -p "Correo: " EMAIL
    read -s -p "Contraseña: " PASS
    echo
    echo "WURL_USER=\"$EMAIL\"" > "$CONFIG_FILE"
    echo "WURL_PASS=\"$PASS\"" >> "$CONFIG_FILE"
    echo "TG_NOTIFY=errors" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "✅ Configuración actualizada."
    ;;

  schedule)
    case "$2" in
      list)
        crontab -l | grep '# woffy-' || echo "(Sin tareas programadas)"
        ;;
      pause)
        crontab -l | sed 's/^/#DISABLED# /' | crontab -
        echo "⏸️ Tareas programadas pausadas."
        ;;
      resume)
        crontab -l | sed 's/^#DISABLED# //' | crontab -
        echo "▶️ Tareas programadas reactivadas."
        ;;
      entrada)
        (crontab -l 2>/dev/null; echo "0 9 * * 1-5 woffy in # woffy-in"; echo "30 15 * * 1-5 woffy in # woffy-in") | sort -u | crontab -
        echo "✅ Fichajes de entrada programados."
        ;;
      salida)
        (crontab -l 2>/dev/null; echo "0 14 * * 1-5 woffy out # woffy-out"; echo "0 18 * * 1-5 woffy out # woffy-out") | sort -u | crontab -
        echo "✅ Fichajes de salida programados."
        ;;
      *)
        echo "❌ Uso: woffy schedule {list|pause|resume|entrada|salida}"
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
    echo "  schedule        Gestionar programación en cron"
    echo "      list        Mostrar fichajes programados"
    echo "      pause       Desactivar tareas"
    echo "      resume      Activar tareas"
    echo "      entrada     Añadir tareas de entrada"
    echo "      salida      Añadir tareas de salida"
    ;;
esac
