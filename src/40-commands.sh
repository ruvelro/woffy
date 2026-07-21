load_persisted_runtime_config
validate_runtime_config

case "${1:-}" in
  help | "")
    show_help
    ;;

  version)
    echo "woffy v$VERSION"
    ;;

  login)
    check_deps curl jq sqlite3 date
    [ -n "${2:-}" ] || {
      echo "Usage: woffy login <email> [<password>|--password-stdin]"
      exit 1
    }
    EMAIL="$2"
    validate_email "$EMAIL" || {
      echo "ERROR Invalid email: $EMAIL"
      exit 1
    }
    case "${3:-}" in
      --password-stdin)
        IFS= read -r PASS
        ;;
      "")
        [ -t 0 ] || {
          echo "ERROR Password required; use --password-stdin in non-interactive mode" >&2
          exit 1
        }
        read -r -s -p "Woffu password: " PASS
        echo
        ;;
      *)
        PASS="$3"
        echo "WARN Positional passwords are deprecated; use prompt or --password-stdin." >&2
        ;;
    esac
    [ -n "$PASS" ] || {
      echo "ERROR Empty password" >&2
      exit 1
    }
    db_init
    db_exec "INSERT INTO users(email,password,active,created_at,updated_at)
             VALUES($(sql_quote "$EMAIL"),$(sql_quote "$PASS"),1,datetime('now','localtime'),datetime('now','localtime'))
             ON CONFLICT(email) DO UPDATE SET password=excluded.password, active=1, updated_at=excluded.updated_at;"
    seed_default_schedule "$EMAIL"
    db_exec "DELETE FROM tokens WHERE email=$(sql_quote "$EMAIL");"
    TOKEN="$(get_token "$EMAIL")"
    uj="$(api_get_raw "/api/users" || true)"
    if [ -n "$uj" ] && echo "$uj" | jq -e 'if type=="array" then .[0].UserId else .UserId end' >/dev/null 2>&1; then
      save_user_card_db "$EMAIL" "$uj"
      record_event "$EMAIL" "login" "auth" "success" "Login completed and user card saved."
      echo "OK Login completed for $EMAIL. User card saved."
    else
      record_event "$EMAIL" "login" "auth" "warning" "Login completed but user card could not be fetched."
      echo "WARN Login completed for $EMAIL, but user card could not be fetched."
    fi
    ;;

  users)
    check_deps sqlite3
    db_init
    case "${2:-}" in
      "")
        print_users
        ;;
      enable)
        [ -n "${3:-}" ] || {
          echo "Usage: woffy users enable <email>"
          exit 1
        }
        set_user_active "$3" 1
        ;;
      disable)
        [ -n "${3:-}" ] || {
          echo "Usage: woffy users disable <email>"
          exit 1
        }
        set_user_active "$3" 0
        ;;
      delete)
        [ -n "${3:-}" ] || {
          echo "Usage: woffy users delete <email>"
          exit 1
        }
        delete_user "$3"
        ;;
      *)
        echo "Usage: woffy users [enable|disable|delete <email>]"
        exit 1
        ;;
    esac
    ;;

  user)
    check_deps sqlite3
    [ -n "${2:-}" ] || {
      echo "Usage: woffy user <email>"
      exit 1
    }
    db_init
    db_exec "SELECT
               'Email: ' || users.email || char(10) ||
               'Active: ' || users.active || char(10) ||
               'Name: ' || COALESCE(user_cards.full_name,'') || char(10) ||
               'Company: ' || COALESCE(user_cards.company_name,'') || char(10) ||
               'Office: ' || COALESCE(user_cards.office_name,'') || char(10) ||
               'Woffu user id: ' || COALESCE(user_cards.woffu_user_id,'')
             FROM users LEFT JOIN user_cards ON user_cards.email=users.email
             WHERE users.email=$(sql_quote "$2");"
    ;;

  status)
    check_deps curl jq sqlite3 date
    [ -n "${2:-}" ] || {
      echo "Usage: woffy status <email>"
      exit 1
    }
    TOKEN="$(get_token "$2")"
    st="$(get_status)"
    echo "$2: $st"
    ;;

  dry-run)
    check_deps curl jq awk sqlite3 date
    MODE="${2:-}"
    EMAIL="${3:-}"
    [ "$MODE" = "in" ] || [ "$MODE" = "out" ] || {
      echo "Usage: woffy dry-run {in|out} <email>"
      exit 1
    }
    [ -n "$EMAIL" ] || {
      echo "Usage: woffy dry-run {in|out} <email>"
      exit 1
    }
    acquire_lock
    run_sign_flow "$EMAIL" "$MODE" true "$QUIET"
    ;;

  in | out)
    check_deps curl jq awk sqlite3 date
    [ -n "${2:-}" ] || {
      echo "Usage: woffy $1 <email>"
      exit 1
    }
    acquire_lock
    run_sign_flow "$2" "$1" false "$QUIET"
    ;;

  api)
    check_deps curl jq sqlite3 date
    db_init
    case "${2:-}" in
      configure)
        CLIENT_ID="${3:-}"
        is_int "$CLIENT_ID" || {
          echo "Usage: woffy api configure <company-id> [--secret-stdin]"
          exit 1
        }
        if [ "${4:-}" = "--secret-stdin" ]; then
          IFS= read -r CLIENT_SECRET
        else
          [ -t 0 ] || {
            echo "ERROR API key required; use --secret-stdin in non-interactive mode" >&2
            exit 1
          }
          read -r -s -p "Woffu API key: " CLIENT_SECRET
          echo
        fi
        [ -n "$CLIENT_SECRET" ] || {
          echo "ERROR Empty API key" >&2
          exit 1
        }
        db_exec "INSERT INTO integration_credentials(provider,client_id,client_secret,updated_at)
                 VALUES('woffu',$(sql_quote "$CLIENT_ID"),$(sql_quote "$CLIENT_SECRET"),datetime('now','localtime'))
                 ON CONFLICT(provider) DO UPDATE SET client_id=excluded.client_id,client_secret=excluded.client_secret,updated_at=excluded.updated_at;
                 DELETE FROM integration_tokens WHERE provider='woffu';"
        echo "OK Woffu API integration configured."
        ;;
      status)
        if [ -n "$(db_exec "SELECT client_id FROM integration_credentials WHERE provider='woffu';")" ]; then
          echo "Woffu API: configured"
        else
          echo "Woffu API: not configured"
        fi
        ;;
      test)
        integration_get_token >/dev/null
        echo "OK Woffu API authentication succeeded."
        ;;
      clear)
        db_exec "DELETE FROM integration_tokens WHERE provider='woffu'; DELETE FROM integration_credentials WHERE provider='woffu';"
        echo "OK Woffu API integration removed."
        ;;
      *)
        echo "Usage: woffy api {configure <company-id>|status|test|clear} [--secret-stdin]"
        exit 1
        ;;
    esac
    ;;

  sign)
    check_deps curl jq sqlite3 date
    EMAIL="${2:-}"
    MODE="${3:-}"
    SIGN_DATE="${4:-}"
    SIGN_TIME="${5:-}"
    if ! validate_email "$EMAIL" || ! validate_action "$MODE" || ! is_valid_date "$SIGN_DATE" || ! validate_time "$SIGN_TIME"; then
      echo "Usage: woffy sign <email> {in|out} <YYYY-MM-DD> <HH:MM>"
      exit 1
    fi
    user_exists "$EMAIL" || {
      echo "ERROR Unknown user: $EMAIL"
      exit 1
    }
    SIGN_DT="${SIGN_DATE}T${SIGN_TIME}:00"
    NOW_DT="$(date '+%Y-%m-%dT%H:%M:%S')"
    if [[ "$SIGN_DT" > "$NOW_DT" ]]; then
      echo "ERROR Backfill timestamp is in the future: $SIGN_DT"
      exit 1
    fi
    if backfill_sign_official "$EMAIL" "$MODE" "$SIGN_DT"; then
      record_event "$EMAIL" "$MODE" "backfill" "success" "Backdated sign accepted by official API: $SIGN_DT."
      echo "OK Backdated $MODE accepted for $EMAIL at $SIGN_DT."
    else
      record_event "$EMAIL" "$MODE" "backfill" "error" "Official API backfill failed: $SIGN_DT."
      exit 1
    fi
    ;;

  run)
    check_deps curl jq awk sqlite3 date
    case "${2:-}" in
      due)
        if [ "${3:-}" = "--dry-run" ]; then
          run_due true
        elif [ -n "${3:-}" ]; then
          echo "Usage: woffy run due [--quiet] [--dry-run]"
          exit 1
        else
          run_due false
        fi
        ;;
      *)
        echo "Usage: woffy run due [--quiet]"
        exit 1
        ;;
    esac
    ;;

  events)
    check_deps sqlite3 awk date
    if [ "${2:-}" = "purge" ]; then
      if ! { [ "${3:-}" = "--before" ] && [ -n "${4:-}" ] && [ "${5:-}" = "--yes" ]; }; then
        echo "Usage: woffy events purge --before YYYY-MM-DD --yes"
        exit 1
      fi
      PURGED="$(purge_events "$4")"
      echo "OK Purged $PURGED event(s) before $4."
      exit 0
    fi
    TARGET="${2:-all}"
    DAYS=30
    STATUS_FILTER="all"
    EVENTS_FORMAT="text"
    EVENTS_LIMIT=200
    shift || true
    if [ "$#" -gt 0 ]; then
      shift
    fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --days)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --days value"
            exit 1
          }
          DAYS="$2"
          shift 2
          ;;
        --status)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --status value"
            exit 1
          }
          STATUS_FILTER="$2"
          shift 2
          ;;
        --format)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --format value"
            exit 1
          }
          EVENTS_FORMAT="$2"
          shift 2
          ;;
        --limit)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --limit value"
            exit 1
          }
          EVENTS_LIMIT="$2"
          shift 2
          ;;
        *)
          echo "ERROR Unknown events option: $1"
          exit 1
          ;;
      esac
    done
    case "$STATUS_FILTER" in all | success | warning | error | dry-run) ;; *)
      echo "ERROR Invalid status: $STATUS_FILTER"
      exit 1
      ;;
    esac
    print_events "$TARGET" "$DAYS" "$STATUS_FILTER" "$EVENTS_FORMAT" "$EVENTS_LIMIT"
    ;;

  report)
    check_deps sqlite3 date
    [ "${2:-}" = "all" ] || {
      echo "Usage: woffy report all [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--format text|json|csv] [telegram]"
      exit 1
    }
    REPORT_FROM="$(current_week_start_date)"
    REPORT_TO="$(date '+%Y-%m-%d')"
    REPORT_FORMAT="text"
    SEND_TG=false
    shift 2 || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        telegram)
          SEND_TG=true
          shift
          ;;
        --from)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --from value"
            exit 1
          }
          REPORT_FROM="$2"
          shift 2
          ;;
        --to)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --to value"
            exit 1
          }
          REPORT_TO="$2"
          shift 2
          ;;
        --format)
          [ -n "${2:-}" ] || {
            echo "ERROR Missing --format value"
            exit 1
          }
          REPORT_FORMAT="$2"
          shift 2
          ;;
        *)
          echo "ERROR Unknown report option: $1"
          exit 1
          ;;
      esac
    done
    is_valid_date "$REPORT_FROM" || {
      echo "ERROR Invalid --from date (YYYY-MM-DD)"
      exit 1
    }
    is_valid_date "$REPORT_TO" || {
      echo "ERROR Invalid --to date (YYYY-MM-DD)"
      exit 1
    }
    if [[ "$REPORT_FROM" > "$REPORT_TO" ]]; then
      echo "ERROR --from must not be after --to"
      exit 1
    fi
    case "$REPORT_FORMAT" in text | json | csv) ;; *)
      echo "ERROR Invalid format: $REPORT_FORMAT"
      exit 1
      ;;
    esac
    REPORT_MSG="$(build_report_all "$(date_to_boundary "$REPORT_FROM" start)" "$(date_to_boundary "$REPORT_TO" end)" "$REPORT_FORMAT")"
    echo "$REPORT_MSG"
    if $SEND_TG; then
      tg_send info "$REPORT_MSG" true || {
        echo "ERROR Report could not be sent to Telegram." >&2
        exit 1
      }
      echo "OK Report sent to Telegram."
    fi
    ;;

  schedule)
    check_deps sqlite3
    db_init
    case "${2:-}" in
      install)
        check_deps crontab readlink
        install_run_due_cron
        echo "OK Cron orchestrator installed."
        ;;
      list)
        check_deps crontab
        crontab -l 2>/dev/null | grep 'woffy-' || echo "No woffy cron entries."
        ;;
      clear)
        check_deps crontab
        clear_woffy_cron
        echo "OK Cron cleared."
        ;;
      user)
        EMAIL="${3:-}"
        SUB="${4:-}"
        [ -n "$EMAIL" ] || {
          echo "Usage: woffy schedule user <email> {list|add|set|remove|clear|defaults}"
          exit 1
        }
        case "$SUB" in
          list)
            print_user_schedule "$EMAIL"
            ;;
          add)
            if [ -z "${5:-}" ] || [ -z "${6:-}" ]; then
              echo "Usage: woffy schedule user <email> add {in|out} HH:MM [weekdays]"
              exit 1
            fi
            add_user_schedule "$EMAIL" "$5" "$6" "${7:-1,2,3,4,5}"
            ;;
          set)
            if [ -z "${5:-}" ] || [ -z "${6:-}" ]; then
              echo "Usage: woffy schedule user <email> set {in|out} HH:MM[,HH:MM...] [weekdays]"
              exit 1
            fi
            set_user_schedule "$EMAIL" "$5" "$6" "${7:-1,2,3,4,5}"
            ;;
          remove)
            if [ -z "${5:-}" ] || [ -z "${6:-}" ]; then
              echo "Usage: woffy schedule user <email> remove {in|out} HH:MM"
              exit 1
            fi
            remove_user_schedule "$EMAIL" "$5" "$6"
            ;;
          clear)
            clear_user_schedule "$EMAIL"
            ;;
          defaults)
            reset_default_schedule "$EMAIL"
            ;;
          *)
            echo "Usage: woffy schedule user <email> {list|add|set|remove|clear|defaults}"
            exit 1
            ;;
        esac
        ;;
      *)
        echo "Usage: woffy schedule {install|list|clear|user <email> ...}"
        exit 1
        ;;
    esac
    ;;

  telegram)
    check_deps curl sqlite3
    db_init
    if [ "${2:-}" = "test" ]; then
      if tg_send test "woffy Telegram OK" true; then
        echo "OK Telegram test sent."
        exit 0
      fi
      echo "ERROR Telegram is not configured or delivery failed." >&2
      exit 1
    fi
    if [ "${2:-}" = "configure" ]; then
      if ! { [ "${3:-}" = "--token-stdin" ] && [ -n "${4:-}" ]; }; then
        echo "Usage: woffy telegram configure --token-stdin <chat-id> [thread-id] [all|errors|success]"
        exit 1
      fi
      IFS= read -r TG_INPUT_TOKEN
      [ -n "$TG_INPUT_TOKEN" ] || {
        echo "ERROR Empty Telegram token" >&2
        exit 1
      }
      [[ "$4" =~ ^-?[0-9]+$ ]] || {
        echo "ERROR Telegram chat id must be numeric" >&2
        exit 1
      }
      if [ -n "${5:-}" ] && ! [[ "$5" =~ ^-?[0-9]+$ ]]; then
        echo "ERROR Telegram thread id must be numeric" >&2
        exit 1
      fi
      case "${6:-all}" in all | errors | success) ;; *)
        echo "ERROR Invalid Telegram notification mode" >&2
        exit 1
        ;;
      esac
      settings_set TG_TOKEN "$TG_INPUT_TOKEN"
      settings_set TG_CHAT_ID "$4"
      settings_set TG_THREAD "${5:-}"
      settings_set TG_NOTIFY "${6:-all}"
      record_event "" "telegram" "admin" "success" "Telegram settings updated."
      echo "OK Telegram settings saved."
      exit 0
    fi
    if [ "${2:-}" = "clear" ]; then
      db_exec "DELETE FROM settings WHERE key IN ('TG_TOKEN','TG_CHAT_ID','TG_THREAD','TG_NOTIFY');"
      record_event "" "telegram" "admin" "warning" "Telegram settings removed."
      echo "OK Telegram settings removed."
      exit 0
    fi
    if [ $# -ge 3 ]; then
      settings_set TG_TOKEN "$2"
      settings_set TG_CHAT_ID "$3"
      [ -n "${4:-}" ] && settings_set TG_THREAD "$4"
      [ -n "${5:-}" ] && settings_set TG_NOTIFY "$5"
      record_event "" "telegram" "admin" "success" "Telegram settings updated through deprecated positional token syntax."
      echo "WARN Positional Telegram tokens are deprecated; use configure --token-stdin." >&2
      echo "OK Telegram settings saved."
      exit 0
    fi
    echo "Usage: woffy telegram {configure --token-stdin <chat-id> [thread-id] [mode]|test|clear}"
    ;;

  config)
    case "${2:-}" in
      check)
        check_deps sqlite3
        db_init
        echo "OK SQLite config valid: $DB_FILE"
        ;;
      list)
        CONFIG_FORMAT="${3:-text}"
        [ "$CONFIG_FORMAT" = "text" ] || [ "$CONFIG_FORMAT" = "--json" ] || {
          echo "Usage: woffy config list [--json]"
          exit 1
        }
        if [ "$CONFIG_FORMAT" = "--json" ]; then
          printf '{'
          CONFIG_FIRST=true
          for CONFIG_NAME in $(runtime_config_names); do
            $CONFIG_FIRST || printf ','
            CONFIG_FIRST=false
            printf '"%s":%s' "$CONFIG_NAME" "$(runtime_config_value "$CONFIG_NAME")"
          done
          printf '}\n'
        else
          for CONFIG_NAME in $(runtime_config_names); do
            printf '%-30s %s\n' "$CONFIG_NAME" "$(runtime_config_value "$CONFIG_NAME")"
          done
        fi
        ;;
      get)
        if [ -z "${3:-}" ] || ! runtime_setting_key "$3" >/dev/null; then
          echo "Usage: woffy config get <name>"
          exit 1
        fi
        runtime_config_value "$3"
        ;;
      set)
        if ! { [ -n "${3:-}" ] && [ -n "${4:-}" ]; }; then
          echo "Usage: woffy config set <name> <value>"
          exit 1
        fi
        runtime_config_set "$3" "$4"
        record_event "" "config" "admin" "success" "Runtime setting changed: $3."
        echo "OK Runtime setting $3 saved."
        ;;
      reset)
        [ -n "${3:-}" ] || {
          echo "Usage: woffy config reset <name>"
          exit 1
        }
        runtime_config_reset "$3" || {
          echo "ERROR Unknown runtime setting: $3" >&2
          exit 1
        }
        record_event "" "config" "admin" "warning" "Runtime setting reset: $3."
        echo "OK Runtime setting $3 reset."
        ;;
      *)
        echo "Usage: woffy config {check|list|get|set|reset}"
        exit 1
        ;;
    esac
    ;;

  self-test)
    check_deps curl jq awk sqlite3 date
    db_init
    echo "OK sqlite3 available"
    echo "OK DB initialized: $DB_FILE"
    echo "OK Users: $(db_exec "SELECT COUNT(*) FROM users;")"
    ;;

  doctor)
    if [ "${2:-}" = "--json" ]; then
      check_deps jq
      doctor_json
      exit $?
    fi
    check_deps sqlite3
    db_init
    echo "Woffy doctor v$VERSION"
    echo "Bin:   $(get_bin_path)"
    echo "Home:  $WOFFY_HOME"
    echo "DB:    $DB_FILE"
    echo "Users: $(db_exec "SELECT COUNT(*) FROM users;")"
    if crontab -l 2>/dev/null | grep -q '# woffy-run-due'; then
      echo "Cron:  run-due installed"
    else
      echo "Cron:  not installed"
    fi
    ;;

  backup)
    check_deps tar
    OUT="${2:-}"
    BAK_PATH="$(backup_files "$OUT")"
    echo "OK Backup created: $BAK_PATH"
    ;;

  restore)
    check_deps tar sqlite3
    [ -n "${2:-}" ] || {
      echo "Usage: woffy restore <path.tar.gz>"
      exit 1
    }
    restore_files "$2" || {
      echo "ERROR Could not restore backup."
      exit 1
    }
    db_init
    echo "OK Backup restored."
    ;;

  changelog)
    check_deps curl jq awk
    show_changelog
    ;;

  update)
    check_deps curl awk
    UPDATE_CHANNEL="stable"
    UPDATE_CHECK=false
    ALLOW_DOWNGRADE=false
    shift || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        nightly) UPDATE_CHANNEL="nightly" ;;
        --check) UPDATE_CHECK=true ;;
        --allow-downgrade) ALLOW_DOWNGRADE=true ;;
        *)
          echo "Usage: woffy update [nightly] [--check] [--allow-downgrade]"
          exit 1
          ;;
      esac
      shift
    done
    perform_update "$UPDATE_CHANNEL" "$UPDATE_CHECK" "$ALLOW_DOWNGRADE"
    ;;

  web)
    case "${2:-}" in
      install)
        WEB_PORT="$WEB_PORT_DEFAULT"
        WEB_PASSWORD_STDIN=false
        shift 2 || true
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --port)
              WEB_PORT="${2:-}"
              shift 2
              ;;
            --password-stdin)
              WEB_PASSWORD_STDIN=true
              shift
              ;;
            *)
              echo "Usage: woffy web install [--port N] [--password-stdin]"
              exit 1
              ;;
          esac
        done
        web_install_release stable "$WEB_PORT" "$WEB_PASSWORD_STDIN"
        ;;
      update)
        if [ "${3:-}" = "--deferred" ]; then
          WEB_CHANNEL="${4:-stable}"
          [ "$WEB_CHANNEL" = "stable" ] || [ "$WEB_CHANNEL" = "nightly" ] || {
            echo "Usage: woffy web update --deferred [stable|nightly]"
            exit 1
          }
          web_deferred_update "$WEB_CHANNEL"
          exit $?
        fi
        WEB_CHANNEL="${3:-stable}"
        [ "$WEB_CHANNEL" = "stable" ] || [ "$WEB_CHANNEL" = "nightly" ] || {
          echo "Usage: woffy web update [stable|nightly]"
          exit 1
        }
        web_install_release "$WEB_CHANNEL" "$WEB_PORT_DEFAULT"
        ;;
      start | stop | restart | status)
        web_service_action "$2"
        ;;
      logs)
        command -v journalctl >/dev/null 2>&1 || {
          echo "ERROR journalctl is unavailable" >&2
          exit 1
        }
        journalctl --user -u woffy-web.service -n "${3:-100}" --no-pager
        ;;
      passwd)
        if [ "${3:-}" = "--password-stdin" ]; then
          web_manage passwd --password-stdin
        else
          web_manage passwd
        fi
        ;;
      serve)
        web_serve "${3:-$WEB_PORT_DEFAULT}"
        ;;
      uninstall)
        web_uninstall_panel
        ;;
      *)
        echo "Usage: woffy web {install [--port N] [--password-stdin]|update [stable|nightly]|start|stop|restart|status|logs [N]|passwd [--password-stdin]|serve [port]|uninstall}"
        exit 1
        ;;
    esac
    ;;

  uninstall)
    check_deps crontab
    echo "This removes the installed binary, cron entries and $WOFFY_HOME."
    read -r -p "Continue? (y/N): " CONFIRM
    case "$CONFIRM" in y | Y | s | S) ;; *)
      echo "Cancelled."
      exit 0
      ;;
    esac
    clear_woffy_cron
    web_cleanup_all || true
    BIN_PATH="$(get_bin_path)"
    [ -n "$BIN_PATH" ] && rm -f "$BIN_PATH"
    for target in "$DB_FILE" "$DB_FILE-wal" "$DB_FILE-shm" "$LOG_FILE" "$LOG_FILE".[0-9]*; do
      [ -f "$target" ] && rm -f "$target"
    done
    release_lock
    rmdir "$WOFFY_HOME" 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user stop woffy-web.service 2>/dev/null || true
    fi
    echo "OK Woffy uninstalled."
    ;;

  *)
    echo "ERROR Unknown command. Run 'woffy help'."
    exit 1
    ;;
esac
