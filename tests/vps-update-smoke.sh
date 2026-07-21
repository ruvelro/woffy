#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
smoke_dir="$(mktemp -d)"
smoke_home="$smoke_dir/home"
smoke_bin="$smoke_home/.local/bin"
assets="$smoke_dir/releases/stable"
mkdir -p "$smoke_bin" "$assets"

cleanup() {
  rm -rf "$smoke_dir"
}
trap cleanup EXIT

sed 's/^VERSION="3.1.2"/VERSION="2.0.0"/' "$repo_dir/woffy.sh" >"$smoke_bin/woffy"
chmod +x "$smoke_bin/woffy"
cp "$repo_dir/woffy.sh" "$assets/woffy"
chmod +x "$assets/woffy"
printf '3.1.2\n' >"$assets/woffy.version"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$assets" && sha256sum woffy >woffy.sha256)
else
  (cd "$assets" && shasum -a 256 woffy >woffy.sha256)
fi

export HOME="$smoke_home"
export PATH="$smoke_bin:$PATH"
export WOFFY_UPDATE_BASE_URL="file://$smoke_dir/releases"

woffy config check >/dev/null
[ "$(woffy version)" = "woffy v2.0.0" ]
woffy update >/dev/null
[ "$(woffy version)" = "woffy v3.1.2" ]
[ -f "$smoke_bin/woffy.previous" ]
[ "$(sqlite3 "$HOME/.woffy/woffy.db" 'PRAGMA user_version;')" = "4" ]
woffy doctor --json | jq -e '.version=="3.1.2" and .schema_version==4 and .journal_mode=="wal"' >/dev/null

mv "$smoke_bin/woffy.previous" "$smoke_bin/woffy"
[ "$(woffy version)" = "woffy v2.0.0" ]
echo "VPS update and rollback smoke test passed."
