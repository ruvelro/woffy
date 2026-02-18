# woffy v1.2.0

CLI para fichar en Woffu desde terminal, automatizar fichajes y notificar por Telegram.

## Instalación (sin sudo)
```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash
```

Con credenciales:
```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash -s - "EMAIL" "PASSWORD"
```

## Seguridad
- Lock de ejecución para evitar concurrencia.
- Archivos sensibles con permisos `600`.
- `install` y `update` con verificación SHA256 (`woffy.sh.sha256`).

## Comandos principales
- `woffy in`
- `woffy out`
- `woffy dry-run in|out`
- `woffy status`
- `woffy report [telegram] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--format text|json|csv]`
- `woffy doctor [--json]`
- `woffy self-test`
- `woffy notify test {success|warning|error|info|all} [mensaje]`
- `woffy backup [ruta.tar.gz]`
- `woffy restore <ruta.tar.gz>`
- `woffy changelog`
- `woffy update`
- `woffy uninstall`

Flag global:
- `--no-telegram` evita envíos de Telegram en el comando actual.

Ejemplo:
```bash
woffy --no-telegram in
```

## Schedule (cron)
- `woffy schedule list`
- `woffy schedule clear`
- `woffy schedule pause`
- `woffy schedule resume`
- `woffy schedule entrada [HH:MM]`
- `woffy schedule salida [HH:MM]`
- `woffy schedule report` (viernes 18:00)
- `woffy schedule timezone <TZ>`

Ejemplo:
```bash
woffy schedule timezone Europe/Madrid
```

## Schedule (systemd --user)
- `woffy schedule systemd enable`
- `woffy schedule systemd status`
- `woffy schedule systemd disable`

Crea timers de IN/OUT y reporte semanal en `~/.config/systemd/user`.

## Reportes
`woffy report` analiza `~/.woffy.log` y resume:
- entradas correctas
- salidas correctas
- avisos
- errores

Formatos:
- `--format text` (por defecto)
- `--format json`
- `--format csv`

Filtros de fechas:
- `--from YYYY-MM-DD`
- `--to YYYY-MM-DD`

## Telegram
Configurar:
```bash
woffy telegram
woffy telegram test
```

Probar tipos de notificación:
```bash
woffy notify test all "Prueba de alertas"
```

## Backup y restore
Backup:
```bash
woffy backup
woffy backup /tmp/woffy-backup.tar.gz
```

Restore:
```bash
woffy restore /tmp/woffy-backup.tar.gz
```

## Update seguro
```bash
woffy update
```
Descarga script + checksum y solo reemplaza el binario si el hash coincide.

## Checklist de release
Usa `CHECKLIST.md` antes de mergear a `main`.

## Licencia
GNU GPL v3
