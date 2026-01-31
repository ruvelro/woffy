#!/bin/bash
set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/woffy"
CONFIG_FILE="$HOME/.woffy.conf"

echo "📦 Instalando woffy en modo usuario (sin sudo)..."

# Crear directorio si no existe
mkdir -p "$INSTALL_DIR"

# Descargar binario
echo "⬇️ Descargando woffy..."
curl -fsSL "$REPO_RAW_BASE/woffy.sh" -o "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

echo "✅ woffy instalado en $INSTALL_PATH"

# Asegurar que ~/.local/bin está en PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo "➕ Añadiendo $INSTALL_DIR al PATH"

  SHELL_RC=""
  if [ -n "${BASH_VERSION:-}" ]; then
    SHELL_RC="$HOME/.bashrc"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    SHELL_RC="$HOME/.zshrc"
  fi

  if [ -n "$SHELL_RC" ]; then
    echo "" >> "$SHELL_RC"
    echo "# Añadido por woffy" >> "$SHELL_RC"
    echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$SHELL_RC"
    echo "ℹ️ Reinicia la terminal o ejecuta: source $SHELL_RC"
  else
    echo "⚠️ No se pudo detectar el shell. Añade manualmente ~/.local/bin al PATH."
  fi
fi

# Login automático si se pasan credenciales
if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
  echo "🔐 Iniciando sesión y generando ficha de usuario..."
  "$INSTALL_PATH" login "$1" "$2"
fi

# Programar cron (como usuario)
echo "🧹 Limpiando entradas previas de woffy en crontab..."
"$INSTALL_PATH" schedule clear || true

echo "⏱️ Programando horarios por defecto..."
"$INSTALL_PATH" schedule entrada || true
"$INSTALL_PATH" schedule salida || true

echo "🎉 Instalación completa. Ejecuta: woffy help"
