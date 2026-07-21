# woffy v3.1.2

![shell-ci](https://github.com/ruvelro/woffy/actions/workflows/shell-ci.yml/badge.svg)
![release](https://github.com/ruvelro/woffy/actions/workflows/release.yml/badge.svg)
![license](https://img.shields.io/badge/license-GPL--3.0-blue)

CLI multiusuario para automatizar fichajes de [Woffu](https://www.woffu.com/) desde un VPS administrado de forma centralizada. Un único binario Bash, SQLite como fuente de verdad, y un panel web opcional para operar todo sin tocar la terminal.

## Índice

- [Instalación](#instalación)
- [Primeros pasos](#primeros-pasos)
- [Usuarios y fichajes](#usuarios-y-fichajes)
- [Horarios y scheduler](#horarios-y-scheduler)
- [Telegram](#telegram)
- [API oficial de Woffu y fichajes retroactivos](#api-oficial-de-woffu-y-fichajes-retroactivos)
- [Eventos, informes y mantenimiento](#eventos-informes-y-mantenimiento)
- [Actualización y rollback](#actualización-y-rollback)
- [Panel web opcional](#panel-web-opcional)
  - [Instalación y arranque](#instalación-y-arranque)
  - [Acceso por túnel SSH](#acceso-por-túnel-ssh)
  - [Gestión del servicio](#gestión-del-servicio)
  - [Seguridad del panel](#seguridad-del-panel)
- [Estado, ficheros y seguridad general](#estado-ficheros-y-seguridad-general)
- [Desarrollo](#desarrollo)
- [Licencia](#licencia)

## Instalación

```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash
```

El instalador descarga los assets versionados y firmados del último release (`woffy` + `woffy.sha256`), verifica su integridad SHA-256, y coloca el binario en `~/.local/bin/woffy`. También instala el orquestador de cron (`* * * * * woffy run due --quiet`) si no existe todavía.

**Dependencias en el VPS:** `bash`, `curl`, `jq`, `awk`, `date`, `sqlite3`, `crontab`, `readlink`, `tar` y `sha256sum` o `shasum`.

## Primeros pasos

```bash
woffy login worker@example.com                 # pide la contraseña por prompt (recomendado)
printf '%s\n' "$PASSWORD" | woffy login worker@example.com --password-stdin   # para scripts/automatización
```

El login guarda las credenciales, refresca el token de Woffu, descarga la ficha del usuario y crea horarios por defecto (entrada 09:00/15:30, salida 14:00/18:00, lunes a viernes). La forma antigua `woffy login <email> <password>` se conserva por compatibilidad, pero deja la contraseña en el historial del shell — evítala en producción.

## Usuarios y fichajes

```bash
woffy users                          # lista de usuarios, nombre y estado
woffy user <email>                   # ficha de un usuario
woffy users enable|disable <email>   # activar/desactivar sin borrar histórico
woffy users delete <email>           # borra credenciales, token, horarios y guards (conserva eventos)
woffy status <email>                 # in/out/unknown según Woffu
woffy in <email>
woffy out <email>
woffy dry-run in|out <email>         # simula sin fichar de verdad
```

Los fichajes de entrada **fallan de forma segura**: si Woffu no permite verificar el horario laboral del día (`workdaylite`), el fichaje se aborta en vez de arriesgarse a fichar en festivo o fin de semana.

## Horarios y scheduler

```bash
woffy schedule install                              # instala el cron de un minuto
woffy schedule list
woffy schedule clear

woffy schedule user <email> list
woffy schedule user <email> add {in|out} HH:MM [weekdays]
woffy schedule user <email> set {in|out} HH:MM[,HH:MM...] [weekdays]   # reemplaza, admite turnos partidos
woffy schedule user <email> remove {in|out} HH:MM
woffy schedule user <email> clear
woffy schedule user <email> defaults                 # restaura el horario estándar

woffy run due --dry-run                              # qué haría el próximo minuto, sin ejecutar nada
```

`weekdays` usa números ISO separados por coma (1=lunes … 7=domingo, por defecto `1,2,3,4,5`).

Cron ejecuta `woffy run due --quiet` cada minuto. Por defecto se recupera una ventana de 5 minutos (catch-up), se procesan hasta 4 trabajadores en paralelo y las acciones de cada trabajador se serializan entre sí. Los fallos reintentables conservan su estado y disponen de hasta 3 intentos.

Variables de entorno validadas para ajustar estos límites: `WOFFY_MAX_PARALLEL`, `WOFFY_CATCHUP_MINUTES`, `WOFFY_JITTER_MAX`, `WOFFY_CURL_CONNECT_TIMEOUT`, `WOFFY_CURL_MAX_TIME`, `WOFFY_SQLITE_BUSY_MS`, `WOFFY_SCHEDULE_MAX_ATTEMPTS`, `WOFFY_CLAIM_LEASE_SECONDS`, `WOFFY_RUN_GUARD_RETENTION_DAYS`. Los mismos valores se pueden fijar de forma persistente con `woffy config set <nombre> <valor>` (ver `woffy config list`).

## Telegram

```bash
printf '%s\n' "$TG_TOKEN" | woffy telegram configure --token-stdin <chat-id> [thread-id] [all|errors|success]
woffy telegram set-mode {all|errors|success}   # cambia solo el nivel de avisos, sin re-enviar el token
woffy telegram test
woffy telegram clear
```

- `configure --token-stdin` guarda el token del bot leyéndolo por stdin, para que no quede en el historial del shell ni sea visible en `ps`.
- `set-mode` es la forma rápida de subir/bajar el ruido de notificaciones (`all` = todo, `errors` = solo errores, `success` = solo éxitos) sin volver a pegar el token ni el chat id. El panel web tiene el mismo control en **Integraciones**.
- La sintaxis posicional antigua (`woffy telegram <token> <chat_id> ...`) sigue funcionando con un aviso de deprecación, por compatibilidad con instalaciones v2.

## API oficial de Woffu y fichajes retroactivos

```bash
printf '%s\n' "$API_KEY" | woffy api configure <company-id> --secret-stdin
woffy api status
woffy api test
woffy api clear
woffy sign <email> {in|out} YYYY-MM-DD HH:MM
```

Usa OAuth `client_credentials` contra `/api/v1/signs`; no hay fallback por endpoints no documentados. Un `2xx` se registra como aceptado por la API — valida siempre con `woffy api test` contra una cuenta de integración antes de activar fichajes retroactivos en producción.

## Eventos, informes y mantenimiento

```bash
woffy events all|<email> [--days N] [--status all|success|warning|error|dry-run] [--format text|json|csv] [--limit N]
woffy events purge --before YYYY-MM-DD --yes

woffy report all [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--format text|json|csv] [telegram]

woffy config list|get|set|reset
woffy doctor [--json]

woffy backup [ruta.tar.gz]
woffy restore <ruta.tar.gz>
```

Los eventos **no se purgan automáticamente** — solo con `events purge --before ... --yes`. `backup` usa una snapshot SQLite consistente; `restore` valida rutas e integridad antes de reemplazar la base de datos.

## Actualización y rollback

```bash
woffy update --check          # solo consulta la versión disponible
woffy update                  # canal estable
woffy update nightly          # canal nightly
woffy update --allow-downgrade
```

El actualizador sigue una secuencia con múltiples redes de seguridad:

1. Descarga el binario a un temporal **en el mismo filesystem** que el binario instalado (para que el reemplazo final sea un `mv` atómico de verdad).
2. Verifica su checksum SHA-256.
3. Comprueba la sintaxis (`bash -n`).
4. Rechaza el binario si contiene finales de línea CRLF.
5. Ejecuta el binario descargado con `version` y confirma que coincide con la versión anunciada.
6. Guarda el binario actual como `woffy.previous`.
7. Hace un backup de seguridad de settings/DB (equivalente a `woffy backup`) antes de tocar nada.
8. Reemplaza el binario de forma atómica.
9. Ejecuta `woffy doctor` sobre el binario nuevo; si falla, **restaura automáticamente** `woffy.previous` y no deja el sistema a medias.

El desarrollo está modularizado en `src/`; `scripts/build-woffy.sh` genera el ejecutable distribuible (`woffy.sh`) y `--check` detecta si está desincronizado con los fuentes.

## Panel web opcional

Woffy Web es un panel FastAPI + Jinja + HTMX, en local, que cubre toda la operación de la CLI desde el navegador: usuarios, horarios, fichajes (manual/dry-run/retroactivo), eventos, guards, informes con export CSV, logs en vivo, integraciones (Telegram/API Woffu) y configuración persistente, backup/restore y actualización.

**Requisitos del artefacto:** VPS Linux x86_64, CPython 3.11–3.13 y `systemd --user`. La CLI y el cron funcionan exactamente igual con o sin el panel instalado — es un complemento opcional, nunca una dependencia.

### Instalación y arranque

```bash
printf '%s\n' "$ADMIN_PASSWORD" | woffy web install --password-stdin
woffy web status
```

`web install` descarga el artefacto offline (`woffy-web.tar.gz`, con sus dependencias Python vendorizadas), lo verifica por SHA-256, crea la clave de administrador con Argon2id y registra un servicio `systemd --user` (`woffy-web.service`) que arranca en el puerto `127.0.0.1:8787` por defecto.

### Acceso por túnel SSH

El panel **solo escucha en loopback** (`127.0.0.1`) — nunca en una interfaz pública. Para usarlo desde tu equipo, abre un túnel SSH hacia el VPS:

```bash
ssh -L 8787:127.0.0.1:8787 <usuario>@<vps>
```

Deja esa sesión SSH abierta y entra en **`http://127.0.0.1:8787`** desde el navegador de tu equipo local. Todo el tráfico viaja cifrado dentro del túnel SSH; el puerto 8787 nunca queda expuesto a internet.

Consejos:
- Si tu VPS no mantiene los servicios de usuario tras cerrar sesión SSH, activa *lingering* según la política del proveedor (`loginctl enable-linger <usuario>`), o usa `woffy web serve` en una sesión gestionada (`tmux`/`screen`) como alternativa en primer plano.
- Si quieres cambiar el puerto: `woffy web install --port <puerto>` (o reinstalar), y ajusta el túnel (`ssh -L <puerto>:127.0.0.1:<puerto> ...`) en consecuencia.
- Nunca cambies la dirección de bind ni expongas el puerto públicamente — no hay HTTPS ni protección adicional pensada para exposición directa a internet.

### Gestión del servicio

```bash
woffy web start|stop|restart|status
woffy web logs [N]                    # últimas N líneas vía journalctl
woffy web passwd                      # rota la contraseña de admin (invalida todas las sesiones)
woffy web update stable|nightly       # actualización con health-check y rollback automático a `previous`
woffy web serve [puerto]              # alternativa en primer plano, sin systemd
woffy web uninstall                   # quita solo el panel; los datos de la CLI se conservan intactos
```

### Seguridad del panel

- Autenticación de un único administrador con Argon2id; las sesiones expiran y rotar la contraseña invalida todas las activas.
- Cabeceras CSP, validación de `Host`, protección CSRF en cada formulario y limitación de intentos de login.
- Toda acción crítica (borrar usuario, restaurar backup, etc.) exige confirmación exacta y re-autenticación con la contraseña de administrador.
- Los secretos (tokens, contraseñas, claves API) viajan por stdin hacia la CLI — nunca aparecen en argumentos de proceso, páginas renderizadas ni en el log de auditoría.
- Las lecturas a la base de datos principal usan una conexión SQLite de solo lectura; toda escritura se delega a la CLI mediante una allowlist de comandos sin invocar shell.
- Las sesiones, trabajos y auditoría del panel viven en una base separada: `~/.woffy/web/web.db`.

## Estado, ficheros y seguridad general

- DB: `~/.woffy/woffy.db` — migraciones aditivas, modo WAL, permisos `600`.
- Log: `~/.woffy/woffy.log` (con rotación).
- Lock global: `~/.woffy/woffy.lock.d`.
- Panel web (si está instalado): `~/.woffy/web/web.db`, `~/.local/share/woffy-web/{current,previous}`.
- Credenciales, tokens y claves API se guardan sin cifrado adicional en SQLite — el host debe estar controlado por un administrador de confianza; no expongas `~/.woffy` a otros usuarios del sistema.

## Desarrollo

```bash
bash scripts/build-woffy.sh --check     # comprueba que woffy.sh está sincronizado con src/
shellcheck woffy.sh install-woffy.sh
shfmt -d -i 2 -ci woffy.sh install-woffy.sh
bats tests
bash tests/vps-update-smoke.sh
PYTHONPATH=web pytest -q tests/test_web.py tests/test_web_e2e.py
```

`src/*.sh` son los módulos fuente; `scripts/build-woffy.sh` los concatena en el `woffy.sh` distribuible. Nunca edites `woffy.sh` directamente — cualquier cambio debe hacerse en `src/` y regenerarse. Más contexto de arquitectura, flujos y deuda técnica en [`docs/`](docs/).

## Licencia

GNU GPL v3. Consulta [`LICENSE`](LICENSE).
