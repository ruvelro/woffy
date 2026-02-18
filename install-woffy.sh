#!/bin/bash
set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/woffy"

echo "📦 Instalando woffy en modo usuario (sin sudo)..."

hash_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    echo "shasum -a 256"
  elif command -v openssl >/dev/null 2>&1; then
    echo "openssl dgst -sha256"
  else
    echo ""
  fi
}

sha256_file() {
  local file="$1"
  local hc
  hc="$(hash_cmd)"
  [ -z "$hc" ] && return 1

  case "$hc" in
    "sha256sum")
      sha256sum "$file" | awk '{print $1}'
      ;;
    "shasum -a 256")
      shasum -a 256 "$file" | awk '{print $1}'
      ;;
    *)
      openssl dgst -sha256 "$file" | awk '{print $NF}'
      ;;
  esac
}

HC="$(hash_cmd)"
if [ -z "$HC" ]; then
  echo "❌ Falta herramienta de hash (sha256sum/shasum/openssl)."
  exit 1
fi

mkdir -p "$INSTALL_DIR"

tmp_bin="$(mktemp)"
tmp_sum="$(mktemp)"

echo "⬇️ Descargando woffy..."
curl -fsSL "$REPO_RAW_BASE/woffy.sh" -o "$tmp_bin"
curl -fsSL "$REPO_RAW_BASE/woffy.sh.sha256" -o "$tmp_sum"

expected_hash="$(awk '{print $1}' "$tmp_sum" | head -n1)"
actual_hash="$(sha256_file "$tmp_bin" || echo "")"

if [ -z "$expected_hash" ] || [ -z "$actual_hash" ] || [ "$expected_hash" != "$actual_hash" ]; then
  echo "❌ Verificación SHA256 fallida. Instalación cancelada."
  rm -f "$tmp_bin" "$tmp_sum"
  exit 1
fi

chmod +x "$tmp_bin"
mv "$tmp_bin" "$INSTALL_PATH"
rm -f "$tmp_sum"

echo "✅ woffy instalado en $INSTALL_PATH"

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

if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
  echo "🔐 Iniciando sesión y generando ficha de usuario..."
  "$INSTALL_PATH" login "$1" "$2"
fi

echo "🧹 Limpiando entradas previas de woffy en crontab..."
"$INSTALL_PATH" schedule clear || true

echo "⏱️ Programando horarios por defecto..."
"$INSTALL_PATH" schedule entrada || true
"$INSTALL_PATH" schedule salida || true
"$INSTALL_PATH" schedule report || true

echo "🎉 Instalación completa. Ejecuta: woffy help"
