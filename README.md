# woffy v1.3.0

CLI para fichar en Woffu desde terminal, automatizar fichajes y notificar por Telegram.

## Instalacion (sin sudo)
```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash
```

Con credenciales:
```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash -s - "EMAIL" "PASSWORD"
```

## Comandos principales
- `woffy in`
- `woffy out`
- `woffy dry-run in|out`
- `woffy status`
- `woffy report [telegram] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--format text|json|csv] [--strict]`
- `woffy config check`
- `woffy doctor [--json]`
- `woffy self-test`
- `woffy notify test {success|warning|error|info|all} [mensaje]`
- `woffy backup [ruta.tar.gz]`
- `woffy restore <ruta.tar.gz>`
- `woffy changelog`
- `woffy update`
- `woffy update nightly`
- `woffy uninstall`

Flag global:
- `--no-telegram` evita envios de Telegram en el comando actual.

## Schedule (cron)
- `woffy schedule list`
- `woffy schedule clear`
- `woffy schedule pause`
- `woffy schedule resume`
- `woffy schedule entrada [HH:MM]`
- `woffy schedule salida [HH:MM]`
- `woffy schedule report` (viernes 18:00)
- `woffy schedule timezone <TZ>`

## Schedule (systemd --user)
- `woffy schedule systemd enable`
- `woffy schedule systemd status`
- `woffy schedule systemd disable`

## Reportes
`woffy report` analiza `~/.woffy.log` y resume:
- entradas correctas
- salidas correctas
- avisos
- errores

Por defecto usa la semana en curso (lunes -> hoy).

## Update
```bash
woffy update
woffy update nightly
```
`woffy update` usa rama `main`.  
`woffy update nightly` usa rama `nightly`.

## Checklist de release
Usa `CHECKLIST.md` antes de mergear a `main`.

## Licencia
GNU GPL v3
