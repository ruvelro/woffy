WEB_INSTALL_ROOT="${WOFFY_WEB_INSTALL_DIR:-$HOME/.local/share/woffy-web}"
WEB_STATE_HOME="${WOFFY_WEB_HOME:-$WOFFY_HOME/web}"
WEB_SERVICE_DIR="${WOFFY_WEB_SERVICE_DIR:-$HOME/.config/systemd/user}"
WEB_SERVICE_FILE="$WEB_SERVICE_DIR/woffy-web.service"
WEB_PORT_DEFAULT="${WOFFY_WEB_PORT:-8787}"
WEB_RECOVERY_DIR="${WOFFY_WEB_RECOVERY_DIR:-$HOME/.local/state/woffy-backups}"

web_python() {
  local candidate
  for candidate in python3.13 python3.12 python3.11 python3; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)' >/dev/null 2>&1 || continue
    command -v "$candidate"
    return 0
  done
  echo "ERROR Woffy Web requires Python 3.11 or newer" >&2
  return 1
}

web_current_dir() {
  [ -L "$WEB_INSTALL_ROOT/current" ] || return 1
  (cd "$WEB_INSTALL_ROOT/current" 2>/dev/null && pwd -P)
}

web_write_service() {
  local current bin_path port
  current="$WEB_INSTALL_ROOT/current"
  bin_path="$(get_bin_path)"
  [ -n "$bin_path" ] || bin_path="$(get_script_path)"
  port="$1"
  mkdir -p "$WEB_SERVICE_DIR"
  mkdir -p "$WEB_RECOVERY_DIR"
  chmod 700 "$WEB_RECOVERY_DIR" 2>/dev/null || true
  chmod 700 "$WEB_SERVICE_DIR" 2>/dev/null || true
  {
    echo "[Unit]"
    echo "Description=Woffy local administrative panel"
    echo "After=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=simple"
    printf 'Environment=WOFFY_BIN=%q\n' "$bin_path"
    printf 'Environment=WOFFY_HOME=%q\n' "$WOFFY_HOME"
    printf 'Environment=WOFFY_WEB_HOME=%q\n' "$WEB_STATE_HOME"
    printf 'ExecStart=%q -m uvicorn woffy_web.app:app --app-dir %q --host 127.0.0.1 --port %s --no-server-header\n' "$current/venv/bin/python" "$current/app" "$port"
    echo "Restart=on-failure"
    echo "RestartSec=3"
    echo "UMask=0077"
    echo "NoNewPrivileges=true"
    echo "PrivateTmp=true"
    echo "ProtectSystem=strict"
    printf 'ReadWritePaths=%q\n' "$WOFFY_HOME"
    printf 'ReadWritePaths=%q\n' "$WEB_RECOVERY_DIR"
    echo ""
    echo "[Install]"
    echo "WantedBy=default.target"
  } >"$WEB_SERVICE_FILE"
  chmod 600 "$WEB_SERVICE_FILE"
}

web_verify_archive() {
  local archive="$1"
  if tar -tzf "$archive" | awk 'BEGIN{bad=0} /^\//{bad=1} /(^|\/)\.\.($|\/)/{bad=1} END{exit bad?0:1}'; then
    echo "ERROR Unsafe web artifact paths detected" >&2
    return 1
  fi
  if tar -tvzf "$archive" | awk '$1 ~ /^[lh]/{bad=1} END{exit bad?0:1}'; then
    echo "ERROR Web artifact links are not allowed" >&2
    return 1
  fi
}

web_install_release() {
  local channel="${1:-stable}" port="${2:-$WEB_PORT_DEFAULT}" password_stdin="${3:-false}"
  local python asset_base archive checksum expected actual staging release_id release_dir previous_target
  local artifact_version minimum_cli maximum_schema current_number minimum_number schema_version
  is_int "$port" && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || {
    echo "ERROR Web port must be between 1024 and 65535" >&2
    return 1
  }
  if [ "$(uname -s)" != "Linux" ] || { [ "$(uname -m)" != "x86_64" ] && [ "$(uname -m)" != "amd64" ]; }; then
    echo "ERROR Woffy Web v3.1 artifacts currently support Linux x86_64 VPS hosts only" >&2
    return 1
  fi
  python="$(web_python)" || return 1
  check_deps tar curl jq sqlite3
  archive="$(mktemp)"
  checksum="$(mktemp)"
  staging="$(mktemp -d)"
  if [ -n "${WOFFY_WEB_ARTIFACT_DIR:-}" ]; then
    cp "$WOFFY_WEB_ARTIFACT_DIR/woffy-web.tar.gz" "$archive"
    cp "$WOFFY_WEB_ARTIFACT_DIR/woffy-web.sha256" "$checksum"
  else
    if [ -n "${WOFFY_WEB_BASE_URL:-}" ]; then
      asset_base="${WOFFY_WEB_BASE_URL%/}/$channel"
    elif [ "$channel" = "nightly" ]; then
      asset_base="$RELEASE_BASE/download/nightly"
    else
      asset_base="$RELEASE_BASE/latest/download"
    fi
    curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 120 "$asset_base/woffy-web.tar.gz" -o "$archive" || return 1
    curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 30 "$asset_base/woffy-web.sha256" -o "$checksum" || return 1
  fi
  expected="$(awk 'NR==1{print $1}' "$checksum")"
  actual="$(sha256_file "$archive")"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || {
    echo "ERROR Woffy Web checksum mismatch" >&2
    return 1
  }
  web_verify_archive "$archive"
  tar -xzf "$archive" -C "$staging"
  [ -f "$staging/app/requirements.lock" ] && [ -d "$staging/app/woffy_web" ] && [ -d "$staging/wheelhouse" ] || {
    echo "ERROR Incomplete Woffy Web artifact" >&2
    return 1
  }
  artifact_version="$(jq -r '.version // empty' "$staging/app/manifest.json" 2>/dev/null || true)"
  minimum_cli="$(jq -r '.minimum_cli_version // empty' "$staging/app/manifest.json" 2>/dev/null || true)"
  maximum_schema="$(jq -r '.maximum_schema_version // empty' "$staging/app/manifest.json" 2>/dev/null || true)"
  if ! semver_number "$artifact_version" >/dev/null || ! minimum_number="$(semver_number "$minimum_cli")"; then
    echo "ERROR Invalid Woffy Web compatibility manifest" >&2
    return 1
  fi
  current_number="$(semver_number "$VERSION")"
  [ "$current_number" -ge "$minimum_number" ] || {
    echo "ERROR Woffy Web $artifact_version requires CLI $minimum_cli or newer" >&2
    return 1
  }
  is_int "$maximum_schema" || {
    echo "ERROR Invalid maximum schema in Woffy Web manifest" >&2
    return 1
  }
  if [ -f "$DB_FILE" ]; then
    schema_version="$(sqlite3 "$DB_FILE" 'PRAGMA user_version;' 2>/dev/null || echo 0)"
    is_int "$schema_version" && [ "$schema_version" -le "$maximum_schema" ] || {
      echo "ERROR Woffy DB schema $schema_version is newer than the panel supports" >&2
      return 1
    }
  fi
  "$python" -m venv "$staging/venv"
  "$staging/venv/bin/python" -m pip install --disable-pip-version-check --no-index --find-links "$staging/wheelhouse" -r "$staging/app/requirements.lock" >/dev/null
  PYTHONPATH="$staging/app" "$staging/venv/bin/python" -m py_compile "$staging/app"/woffy_web/*.py
  release_id="$artifact_version-$(date +%Y%m%d%H%M%S)"
  release_dir="$WEB_INSTALL_ROOT/releases/$release_id"
  mkdir -p "$WEB_INSTALL_ROOT/releases" "$WEB_STATE_HOME"
  chmod 700 "$WEB_INSTALL_ROOT" "$WEB_INSTALL_ROOT/releases" "$WEB_STATE_HOME" 2>/dev/null || true
  mv "$staging" "$release_dir"
  previous_target="$(web_current_dir 2>/dev/null || true)"
  [ -n "$previous_target" ] && ln -sfn "$previous_target" "$WEB_INSTALL_ROOT/previous"
  ln -sfn "$release_dir" "$WEB_INSTALL_ROOT/current"
  mkdir -p "$WEB_STATE_HOME"
  if [ ! -f "$WEB_STATE_HOME/web.db" ]; then
    echo "Set the initial administrator password."
    WEB_INIT_ARGS=(init)
    [ "$password_stdin" = "true" ] && WEB_INIT_ARGS+=(--password-stdin)
    WOFFY_WEB_HOME="$WEB_STATE_HOME" WOFFY_WEB_PORT="$port" PYTHONPATH="$release_dir/app" "$release_dir/venv/bin/python" -m woffy_web.manage "${WEB_INIT_ARGS[@]}" || {
      if [ -n "$previous_target" ]; then
        ln -sfn "$previous_target" "$WEB_INSTALL_ROOT/current"
      else
        rm -f "$WEB_INSTALL_ROOT/current"
      fi
      return 1
    }
  fi
  web_write_service "$port"
  if command -v systemctl >/dev/null 2>&1 && [ "${WOFFY_WEB_NO_SYSTEMD:-false}" != "true" ]; then
    systemctl --user daemon-reload
    systemctl --user enable --now woffy-web.service
    if command -v curl >/dev/null 2>&1; then
      sleep 1
      if ! curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/healthz" >/dev/null; then
        if [ -n "$previous_target" ]; then
          ln -sfn "$previous_target" "$WEB_INSTALL_ROOT/current"
          systemctl --user restart woffy-web.service || true
        else
          systemctl --user disable --now woffy-web.service 2>/dev/null || true
          rm -f "$WEB_INSTALL_ROOT/current"
        fi
        echo "ERROR Woffy Web failed its health check; previous release restored" >&2
        return 1
      fi
    fi
  else
    echo "WARN systemd user services are disabled or unavailable; run 'woffy web serve'." >&2
  fi
  echo "OK Woffy Web $artifact_version installed on http://127.0.0.1:$port"
  echo "Tunnel: ssh -L $port:127.0.0.1:$port <user>@<vps>"
}

web_manage() {
  local current
  current="$(web_current_dir)" || {
    echo "ERROR Woffy Web is not installed" >&2
    return 1
  }
  WOFFY_WEB_HOME="$WEB_STATE_HOME" PYTHONPATH="$current/app" "$current/venv/bin/python" -m woffy_web.manage "$@"
}

web_serve() {
  local current port="${1:-$WEB_PORT_DEFAULT}"
  current="$(web_current_dir)" || {
    echo "ERROR Woffy Web is not installed" >&2
    return 1
  }
  exec env WOFFY_BIN="$(get_bin_path)" WOFFY_HOME="$WOFFY_HOME" WOFFY_WEB_HOME="$WEB_STATE_HOME" PYTHONPATH="$current/app" \
    "$current/venv/bin/python" -m uvicorn woffy_web.app:app --app-dir "$current/app" --host 127.0.0.1 --port "$port" --no-server-header
}

web_service_action() {
  local action="$1"
  command -v systemctl >/dev/null 2>&1 || {
    echo "ERROR systemctl is unavailable" >&2
    return 1
  }
  systemctl --user "$action" woffy-web.service
}

web_deferred_update() {
  local channel="${1:-stable}" bin unit
  command -v systemd-run >/dev/null 2>&1 || {
    echo "ERROR systemd-run is required for a deferred panel update" >&2
    return 1
  }
  bin="$(get_bin_path)"
  [ -n "$bin" ] || bin="$(get_script_path)"
  unit="woffy-web-update-$(date +%s)"
  systemd-run --user --collect --on-active=5s --unit="$unit" "$bin" web update "$channel"
  echo "OK Deferred Woffy Web update scheduled as $unit."
}

web_cleanup_all() {
  case "$WEB_INSTALL_ROOT" in
    "" | / | "$HOME" | "$WOFFY_HOME") return 1 ;;
  esac
  case "$WEB_STATE_HOME" in
    "" | / | "$HOME") return 1 ;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable woffy-web.service 2>/dev/null || true
  fi
  [ -f "$WEB_SERVICE_FILE" ] && rm -f "$WEB_SERVICE_FILE"
  [ -d "$WEB_INSTALL_ROOT" ] && rm -rf "$WEB_INSTALL_ROOT"
  [ -d "$WEB_STATE_HOME" ] && rm -rf "$WEB_STATE_HOME"
}

web_uninstall_panel() {
  case "$WEB_INSTALL_ROOT" in
    "" | / | "$HOME" | "$WOFFY_HOME")
      echo "ERROR Unsafe Woffy Web install directory: $WEB_INSTALL_ROOT" >&2
      return 1
      ;;
  esac
  echo "This removes only the optional Woffy Web application; CLI data is preserved."
  read -r -p "Continue? (y/N): " WEB_CONFIRM
  case "$WEB_CONFIRM" in y | Y | s | S) ;; *)
    echo "Cancelled."
    return 0
    ;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now woffy-web.service 2>/dev/null || true
  fi
  [ -f "$WEB_SERVICE_FILE" ] && rm -f "$WEB_SERVICE_FILE"
  [ -d "$WEB_INSTALL_ROOT" ] && rm -rf "$WEB_INSTALL_ROOT"
  echo "OK Woffy Web removed. Audit and web authentication remain in $WEB_STATE_HOME."
}
