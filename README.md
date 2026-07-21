# woffy v3.0.0

CLI multiusuario para automatizar fichajes de Woffu desde un VPS administrado de forma centralizada.

## Instalación

Tras publicar el release `v3.0.0`:

```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash
woffy login worker@example.com
```

El instalador descarga los assets versionados `woffy` y `woffy.sha256`, verifica su integridad e instala en `~/.local/bin/woffy`.

Dependencias: `bash`, `curl`, `jq`, `awk`, `date`, `sqlite3`, `crontab`, `readlink`, `tar` y `sha256sum` o `shasum`.

## Estado y seguridad

- DB: `~/.woffy/woffy.db`, con migraciones, WAL y permisos `600`.
- Log: `~/.woffy/woffy.log`.
- Lock: `~/.woffy/woffy.lock.d`.
- Credenciales, tokens y claves API se guardan sin cifrado adicional; el host debe estar controlado por un administrador de confianza.
- La forma recomendada de login usa prompt: `woffy login <email>`. Para automatización: `printf '%s\n' "$PASSWORD" | woffy login <email> --password-stdin`.
- `login <email> <password>` se conserva en v3 con aviso de deprecación.

## Usuarios y fichajes

```bash
woffy users
woffy user <email>
woffy users enable|disable|delete <email>
woffy status <email>
woffy in <email>
woffy out <email>
woffy dry-run in|out <email>
```

Las entradas fallan de forma segura si Woffu no permite comprobar `workdaylite`.

## Scheduler

```bash
woffy schedule install
woffy schedule list
woffy schedule clear
woffy schedule user <email> list
woffy schedule user <email> set in 08:00,16:00 1,2,3,4,5
woffy schedule user <email> add|remove ...
woffy schedule user <email> clear|defaults
woffy run due --dry-run
```

Cron ejecuta `woffy run due --quiet` cada minuto. Por defecto se recuperan los últimos cinco minutos, se procesan hasta cuatro trabajadores en paralelo y las acciones de cada trabajador se serializan. Los fallos reintentables conservan estado y disponen de tres intentos.

Variables validadas: `WOFFY_MAX_PARALLEL`, `WOFFY_CATCHUP_MINUTES`, `WOFFY_JITTER_MAX`, `WOFFY_CURL_CONNECT_TIMEOUT`, `WOFFY_CURL_MAX_TIME`, `WOFFY_SQLITE_BUSY_MS`, `WOFFY_SCHEDULE_MAX_ATTEMPTS`, `WOFFY_CLAIM_LEASE_SECONDS` y `WOFFY_RUN_GUARD_RETENTION_DAYS`.

## API oficial y retroactivos

```bash
woffy api configure <company-id>
printf '%s\n' "$API_KEY" | woffy api configure <company-id> --secret-stdin
woffy api status
woffy api test
woffy api clear
woffy sign <email> in|out YYYY-MM-DD HH:MM
```

Usa OAuth `client_credentials` y `/api/v1/signs`. No existe fallback mediante endpoints no documentados. Un `2xx` se registra como aceptado por la API; debe validarse con una cuenta de integración antes de activar la función en producción.

## Eventos, informes y mantenimiento

```bash
woffy events all|<email> [--days N] [--status STATUS] [--format text|json|csv] [--limit N]
woffy events purge --before YYYY-MM-DD --yes
woffy report all [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--format text|json|csv] [telegram]
woffy telegram <token> <chat-id> [thread-id] [all|errors|success]
woffy telegram test
woffy doctor [--json]
woffy backup [path.tar.gz]
woffy restore <path.tar.gz>
```

Los eventos no se purgan automáticamente. Backup usa una snapshot SQLite consistente y restore valida rutas e integridad antes de reemplazar la DB.

## Actualización y rollback

```bash
woffy update --check
woffy update
woffy update nightly
woffy update --allow-downgrade
```

El actualizador usa GitHub Releases, verifica versión, SHA-256 y sintaxis, conserva `woffy.previous` y restaura el binario anterior si falla el post-check.

El desarrollo está modularizado en `src/`; `scripts/build-woffy.sh` genera el ejecutable distribuible y `--check` detecta divergencias.

## Licencia

GNU GPL v3. Consulta `LICENSE`.
