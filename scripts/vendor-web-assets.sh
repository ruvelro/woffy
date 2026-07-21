#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
asset="$repo_dir/web/woffy_web/static/htmx.min.js"
tmp="$(mktemp)"
expected="e209dda5c8235479f3166defc7750e1dbcd5a5c1808b7792fc2e6733768fb447"

curl -fsSL --connect-timeout 5 --max-time 30 "https://cdn.jsdelivr.net/npm/htmx.org@2.0.4/dist/htmx.min.js" -o "$tmp"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$tmp" | awk '{print $1}')"
fi
[ "$actual" = "$expected" ] || {
  echo "ERROR htmx checksum mismatch" >&2
  exit 1
}
mv "$tmp" "$asset"
