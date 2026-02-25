#!/bin/bash
set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/woffy"

echo "Installing woffy in user mode (no sudo)..."

mkdir -p "$INSTALL_DIR"

tmp_bin="$(mktemp)"

echo "Downloading woffy..."
curl -fsSL "$REPO_RAW_BASE/woffy.sh" -o "$tmp_bin"

chmod +x "$tmp_bin"
mv "$tmp_bin" "$INSTALL_PATH"

echo "woffy installed at $INSTALL_PATH"

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo "Adding $INSTALL_DIR to PATH"

  SHELL_RC=""
  if [ -n "${BASH_VERSION:-}" ]; then
    SHELL_RC="$HOME/.bashrc"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    SHELL_RC="$HOME/.zshrc"
  fi

  if [ -n "$SHELL_RC" ]; then
    {
      echo ""
      echo "# Added by woffy"
      echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
    } >> "$SHELL_RC"
    echo "Restart the terminal or run: source $SHELL_RC"
  else
    echo "Could not detect shell. Add ~/.local/bin to PATH manually."
  fi
fi

if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
  echo "Logging in and generating user card..."
  "$INSTALL_PATH" login "$1" "$2"
fi

echo "Cleaning previous woffy entries in crontab..."
"$INSTALL_PATH" schedule clear || true

echo "Scheduling default times..."
"$INSTALL_PATH" schedule entrada || true
"$INSTALL_PATH" schedule salida || true
"$INSTALL_PATH" schedule report || true

echo "Install complete. Run: woffy help"
