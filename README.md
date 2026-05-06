# woffy v2.0.0

CLI multiusuario para automatizar fichajes de varios trabajadores en Woffu desde un VPS administrado de forma centralizada.

## Instalacion
```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash
```

Con el primer trabajador:
```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash -s - "EMAIL" "PASSWORD"
```

Dependencias runtime: `bash`, `curl`, `jq`, `awk`, `date`, `sqlite3`, `crontab`, `readlink`, `tar`.

## Estado local
`woffy` usa SQLite como fuente de verdad:

- DB: `~/.woffy/woffy.db`
- Log: `~/.woffy/woffy.log`
- Lock: `~/.woffy/woffy.lock.d`

El directorio `~/.woffy` se crea con permisos `700` y la base con permisos `600`. Las credenciales y tokens de cada trabajador se guardan en esa DB local sin cifrado adicional.

## Gestion de usuarios
```bash
woffy login <email> <password>
```
Da de alta o actualiza un trabajador. Guarda credenciales, obtiene token, descarga ficha Woffu y crea horarios por defecto si no existian.

```bash
woffy users
woffy user <email>
```
Lista trabajadores o muestra la ficha cacheada de uno.

```bash
woffy users disable <email>
woffy users enable <email>
woffy users delete <email>
```
`disable` deja al trabajador inactivo sin borrar datos. `enable` lo reactiva. `delete` elimina credenciales, token, ficha, horarios y guardas de ejecucion, pero conserva eventos historicos y anade un evento de borrado.

## Fichajes
```bash
woffy status <email>
woffy in <email>
woffy out <email>
woffy dry-run in <email>
woffy dry-run out <email>
```
Todos los comandos usan el token del email indicado. `in` comprueba `workdaylite` y evita fichar entrada si no hay horas programadas, vacaciones/festivo, evento/ausencia o fin de semana. `dry-run` registra lo que habria hecho sin enviar fichaje.

Flag global:
```bash
--no-telegram
```
Evita envios de Telegram en el comando actual.

## Horarios por trabajador
Los dias usan ISO: `1=lunes`, `2=martes`, ..., `7=domingo`.

```bash
woffy schedule user <email> list
```
Muestra horarios del trabajador.

```bash
woffy schedule user <email> set in 08:00,16:00 1,2,3,4,5
woffy schedule user <email> set out 14:00,18:00 1,2,3,4,5
```
Reemplaza todos los horarios de una accion (`in` u `out`) para ese usuario. Si no se indican dias, usa `1,2,3,4,5`.

```bash
woffy schedule user <email> add in 10:00 1,2,3
woffy schedule user <email> remove in 10:00
```
Anade o elimina una hora concreta.

```bash
woffy schedule user <email> clear
woffy schedule user <email> defaults
```
Borra todos los horarios del trabajador o restaura los horarios por defecto: entradas `09:00`, `15:30`; salidas `14:00`, `18:00`; lunes a viernes.

## Orquestador cron
```bash
woffy schedule install
woffy schedule list
woffy schedule clear
```
`install` crea un unico cron:

```cron
* * * * * woffy run due --quiet # woffy-run-due
```

```bash
woffy run due [--quiet]
```
Consulta SQLite cada minuto, selecciona horarios vencidos y evita duplicados con `run_guard`.

## Registro e investigacion
```bash
woffy events all
woffy events <email>
woffy events <email> --days 30
woffy events <email> --days 60 --status error
woffy events all --status warning --format csv --limit 500
```
Consulta eventos guardados en SQLite. Parametros:

- `all` o `<email>`: alcance de la consulta.
- `--days N`: ventana hacia atras desde ahora; por defecto `30`.
- `--status all|success|warning|error|dry-run`: filtro de estado; por defecto `all`.
- `--format text|json|csv`: formato de salida; por defecto `text`.
- `--limit N`: maximo de filas; por defecto `200`.

Los eventos incluyen login, cambios administrativos, fichajes correctos, dry-runs, warnings y errores.

## Reportes
```bash
woffy report all
woffy report all --from YYYY-MM-DD --to YYYY-MM-DD
woffy report all --format text|json|csv
woffy report all telegram
```
Resume eventos de SQLite por rango: entradas, salidas, avisos, errores y dry-runs. Por defecto usa la semana actual.

## Telegram
```bash
woffy telegram <bot_token> <chat_id> [thread_id] [all|errors|success]
woffy telegram test
```
Guarda notificaciones globales de administrador en SQLite. Los avisos por trabajador incluyen email y nombre si existe ficha cacheada.

## Diagnostico y mantenimiento
```bash
woffy doctor
woffy doctor --json
woffy self-test
woffy config check
```
Valida dependencias, DB, usuarios, cron y estado basico.

```bash
woffy backup [ruta.tar.gz]
woffy restore <ruta.tar.gz>
```
Backup y restore archivan/restauran todo `~/.woffy`.

```bash
woffy changelog
woffy update
woffy update nightly
woffy uninstall
```
Mantenimiento de version, actualizacion y desinstalacion. `uninstall` borra binario, cron y `~/.woffy`.

## Licencia
GNU GPL v3
