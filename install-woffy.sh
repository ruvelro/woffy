#!/bin/bash
set -euo pipefail

# Instalador simple de woffy — sobrescribe /usr/local/bin/woffy y crea config si se pasan args.
INSTALL_PATH="/usr/local/bin/woffy"
REPO_RAW_BASE="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main"

if [ "$(id -u)" -ne 0 ]; then
  SUDO=sudo
else
  SUDO=
fi

echo "Descargando woffy..."
$SUDO curl -fsSL "$REPO_RAW_BASE/woffy.sh" -o "$INSTALL_PATH"
$SUDO chmod +x "$INSTALL_PATH"
echo "✅ woffy instalado correctamente en $INSTALL_PATH"

# Si se pasan email y password como parámetros, creamos el config
if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
  EMAIL="$1"
  PASS="$2"
  CFG_PATH="$HOME/.woffy.conf"
  cat > "$CFG_PATH" <<EOF
WURL_USER="$EMAIL"
WURL_PASS="$PASS"
EOF
  chmod 600 "$CFG_PATH"
  echo "✅ Configuración creada en $CFG_PATH"
fi

# Limpiamos entradas previas creadas por woffy antes de añadir las programaciones por defecto
echo "Limpiando entradas previas de woffy en crontab..."
$INSTALL_PATH schedule clear || true

# Añadimos horarios por defecto (si quieres cambiarlos, el usuario puede ejecutar schedule entrada/salida)
echo "Programando horarios por defecto..."
$INSTALL_PATH schedule entrada || true
$INSTALL_PATH schedule salida || true

echo "Instalación completa."
