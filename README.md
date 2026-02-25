# woffy v1.3.0-nightly

CLI para fichar en Woffu desde terminal, automatizar fichajes y notificar por Telegram.

## Instalacion (sin sudo)
Recomendado (verificando integridad del instalador):
```bash
curl -fsSLO https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh
curl -fsSLO https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh.sha256
sha256sum -c install-woffy.sh.sha256
bash install-woffy.sh
```

Con credenciales:
```bash
bash install-woffy.sh "EMAIL" "PASSWORD"
```

## Seguridad
- Lock de ejecucion para evitar concurrencia.
- Archivos sensibles con permisos `600`.
- `install` y `update` con verificacion SHA256.
- `woffy config check` para validar config sin ejecutar contenido.

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

Por defecto usa la semana en curso (lunes -> hoy). Si quieres otro rango, usa `--from` y/o `--to`.

Formatos:
- `--format text` (por defecto)
- `--format json`
- `--format csv`

Filtros de fechas:
- `--from YYYY-MM-DD`
- `--to YYYY-MM-DD`
- `--strict` (falla si `--from > --to`)

Envio por Telegram:
- `woffy report telegram` fuerza el envio del reporte aunque `TG_NOTIFY` este en `errors` o `success`.

## Telegram
Configurar:
```bash
woffy telegram
woffy telegram test
```

Probar tipos de notificacion:
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
woffy update nightly
```
`woffy update` usa rama `main`.  
`woffy update nightly` usa rama `nightly`.  
En ambos casos descarga script + checksum y solo reemplaza el binario si el hash coincide.

## Checklist de release
Usa `CHECKLIST.md` antes de mergear a `main`.

## Licencia
GNU GPL v3
