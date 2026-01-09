#!/bin/bash
set -euo pipefail

# Instalador de woffy — sobrescribe /usr/local/bin/woffy y crea config si se pasan args.
INSTALL_PATH="/usr/local/bin/woffy"
REPO_RAW_BASE="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main"

if [ "$(id -u)" -ne 0 ]; then
  SUDO=
  INVOKING_USER="${USER:-$(id -un)}"
else
  SUDO=sudo
  INVOKING_USER="${SUDO_USER:-root}"
fi

echo "Descargando woffy..."
$SUDO curl -fsSL "$REPO_RAW_BASE/woffy.sh" -o "$INSTALL_PATH"
$SUDO chmod +x "$INSTALL_PATH"
echo "✅ woffy instalado correctamente en $INSTALL_PATH"

# Si se pasan email y password como parámetros, creamos el config en el home del usuario invocante
if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
  EMAIL="$1"
  PASS="$2"
  if [ "$INVOKING_USER" = "root" ]; then
    CFG_PATH="/root/.woffy.conf"
  else
    # expandir home del usuario invocante
    USER_HOME=$(eval echo "~$INVOKING_USER")
    CFG_PATH="$USER_HOME/.woffy.conf"
  fi
  cat > /tmp/woffy_conf.$$ <<EOF
WURL_USER="$EMAIL"
WURL_PASS="$PASS"
EOF
  $SUDO mv /tmp/woffy_conf.$$ "$CFG_PATH"
  $SUDO chown "$INVOKING_USER":"$INVOKING_USER" "$CFG_PATH" 2>/dev/null || true
  $SUDO chmod 600 "$CFG_PATH"
  echo "✅ Configuración creada en $CFG_PATH"
fi

# Ejecutamos schedule clear + programaciones por defecto COMO el usuario invocante
echo "Limpiando entradas previas de woffy en crontab..."
if [ -n "$SUDO" ]; then
  sudo -u "$INVOKING_USER" "$INSTALL_PATH" schedule clear || true
  echo "Programando horarios por defecto..."
  sudo -u "$INVOKING_USER" "$INSTALL_PATH" schedule entrada || true
  sudo -u "$INVOKING_USER" "$INSTALL_PATH" schedule salida || true
else
  "$INSTALL_PATH" schedule clear || true
  echo "Programando horarios por defecto..."
  "$INSTALL_PATH" schedule entrada || true
  "$INSTALL_PATH" schedule salida || true
fi

echo "Instalación completa."
