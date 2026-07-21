#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(mktemp -d)"
export HOME="$smoke_root/home"
export WOFFY_HOME="$HOME/.woffy"
export WOFFY_WEB_INSTALL_DIR="$HOME/.local/share/woffy-web"
export WOFFY_WEB_ARTIFACT_DIR="$repo_dir/dist"
export WOFFY_WEB_NO_SYSTEMD=true
mkdir -p "$HOME/.local/bin"
cp "$repo_dir/woffy.sh" "$HOME/.local/bin/woffy"
chmod +x "$HOME/.local/bin/woffy"
export PATH="$HOME/.local/bin:$PATH"

printf '%s\n' 'correct horse battery staple' | woffy web install --port 8877 --password-stdin
test -L "$WOFFY_WEB_INSTALL_DIR/current"
test -x "$WOFFY_WEB_INSTALL_DIR/current/venv/bin/python"
test -f "$WOFFY_WEB_INSTALL_DIR/current/app/woffy_web/app.py"
test "$(stat -c '%a' "$WOFFY_HOME/web/web.db")" = "600"
printf '%s\n' 'a newly changed administrator password' | woffy web passwd --password-stdin

WOFFY_WEB_PORT=8877 woffy web serve 8877 >"$smoke_root/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:8877/healthz" 2>/dev/null | grep -q '^ok$'; then
    break
  fi
  sleep 0.2
done
curl -fsS "http://127.0.0.1:8877/healthz" | grep -q '^ok$'
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true

current_before="$(readlink "$WOFFY_WEB_INSTALL_DIR/current")"
cp "$repo_dir/dist/woffy-web.sha256" "$smoke_root/good.sha256"
printf 'invalid  woffy-web.tar.gz\n' >"$repo_dir/dist/woffy-web.sha256"
if printf '%s\n' 'unused password' | woffy web update stable; then
  echo "ERROR Web update accepted an invalid checksum" >&2
  exit 1
fi
cp "$smoke_root/good.sha256" "$repo_dir/dist/woffy-web.sha256"
test "$(readlink "$WOFFY_WEB_INSTALL_DIR/current")" = "$current_before"
echo "Woffy Web install and checksum rollback smoke test passed."
