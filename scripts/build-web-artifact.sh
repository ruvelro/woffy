#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="${1:-$repo_dir/dist}"
tmp="$(mktemp -d)"
python="${PYTHON:-python3}"
bash "$repo_dir/scripts/vendor-web-assets.sh"
mkdir -p "$tmp/app" "$tmp/wheelhouse" "$out_dir"
cp -R "$repo_dir/web/woffy_web" "$tmp/app/"
cp "$repo_dir/web/requirements.lock" "$tmp/app/requirements.lock"
cp "$repo_dir/web/manifest.json" "$tmp/app/manifest.json"
cp "$repo_dir/web/THIRD_PARTY_NOTICES.md" "$tmp/app/THIRD_PARTY_NOTICES.md"
"$python" -m pip download --only-binary=:all: --platform manylinux2014_x86_64 --python-version 311 --implementation cp --abi cp311 --dest "$tmp/wheelhouse" -r "$repo_dir/web/requirements.lock"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$out_dir/woffy-web.tar.gz" -C "$tmp" app wheelhouse
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$out_dir" && sha256sum woffy-web.tar.gz >woffy-web.sha256)
else
  (cd "$out_dir" && shasum -a 256 woffy-web.tar.gz >woffy-web.sha256)
fi
printf '%s\n' "$(sed -n 's/__version__ = "\([^"]*\)"/\1/p' "$repo_dir/web/woffy_web/__init__.py")" >"$out_dir/woffy-web.version"
