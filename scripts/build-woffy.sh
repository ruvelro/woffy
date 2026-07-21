#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
output="$repo_dir/woffy.sh"
tmp="$(mktemp)"

cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

for module in \
  "$repo_dir/src/00-core.sh" \
  "$repo_dir/src/10-woffu.sh" \
  "$repo_dir/src/20-scheduler.sh" \
  "$repo_dir/src/30-operations.sh" \
  "$repo_dir/src/40-commands.sh"; do
  cat "$module" >>"$tmp"
done

bash -n "$tmp"
if [ "${1:-}" = "--check" ]; then
  cmp -s "$tmp" "$output" || {
    echo "ERROR woffy.sh is not synchronized with src modules" >&2
    exit 1
  }
else
  chmod +x "$tmp"
  mv "$tmp" "$output"
fi
