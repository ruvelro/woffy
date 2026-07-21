#!/bin/bash
set -euo pipefail

INSTALL_DIR="${WOFFY_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_PATH="$INSTALL_DIR/woffy"
ASSET_BASE="${WOFFY_INSTALL_BASE_URL:-https://github.com/ruvelro/woffy/releases/latest/download}"
tmp_bin="$(mktemp)"
tmp_sum="$(mktemp)"

cleanup() {
  rm -f "$tmp_bin" "$tmp_sum"
}
trap cleanup EXIT

for cmd in bash curl jq awk date sqlite3 crontab readlink tar; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR Missing required dependency: $cmd" >&2
    exit 1
  }
done
if command -v sha256sum >/dev/null 2>&1; then
  SHA_TOOL=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  SHA_TOOL="shasum -a 256"
else
  echo "ERROR Missing SHA-256 tool (sha256sum or shasum)" >&2
  exit 1
fi

echo "Installing woffy in user mode (no sudo)..."
mkdir -p "$INSTALL_DIR"
curl -fsSL --connect-timeout 5 --max-time 30 "$ASSET_BASE/woffy" -o "$tmp_bin"
curl -fsSL --connect-timeout 5 --max-time 30 "$ASSET_BASE/woffy.sha256" -o "$tmp_sum"
expected="$(awk 'NR==1{print $1}' "$tmp_sum")"
if [ "$SHA_TOOL" = "sha256sum" ]; then
  actual="$(sha256sum "$tmp_bin" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$tmp_bin" | awk '{print $1}')"
fi
[ -n "$expected" ] && [ "$expected" = "$actual" ] || {
  echo "ERROR Download checksum mismatch" >&2
  exit 1
}
bash -n "$tmp_bin"
chmod +x "$tmp_bin"
mv "$tmp_bin" "$INSTALL_PATH"
echo "woffy installed at $INSTALL_PATH"

case "${SHELL:-}" in
  */zsh) SHELL_RC="$HOME/.zshrc" ;;
  */bash) SHELL_RC="$HOME/.bashrc" ;;
  *) SHELL_RC="" ;;
esac
if ! echo "$PATH" | tr ':' '\n' | grep -Fqx "$INSTALL_DIR"; then
  if [ -n "$SHELL_RC" ]; then
    if ! grep -Fq '# Added by woffy' "$SHELL_RC" 2>/dev/null; then
      {
        echo ""
        echo "# Added by woffy"
        echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
      } >>"$SHELL_RC"
    fi
    echo "Restart the terminal or run: source $SHELL_RC"
  else
    echo "Add $INSTALL_DIR to PATH manually."
  fi
fi

if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
  echo "WARN Installer password arguments are deprecated; run 'woffy login <email>' instead." >&2
  "$INSTALL_PATH" login "$1" "$2"
fi

"$INSTALL_PATH" schedule clear
"$INSTALL_PATH" schedule install
echo "Install complete. Run: woffy help"
