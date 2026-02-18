# CHECKLIST de Release (pre-main)

Usa esta lista antes de mergear a `main`.

## 1) Integridad y formato
- [ ] `sha256sum woffy.sh` coincide con `woffy.sh.sha256`.
- [ ] `bash -n woffy.sh` sin errores.
- [ ] `bash -n install-woffy.sh` sin errores.
- [ ] `chmod +x woffy.sh install-woffy.sh`.

## 2) Instalación segura
- [ ] Instalación normal funciona:
  - `curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash`
- [ ] Si el checksum remoto no coincide, la instalación aborta.
- [ ] Binario instalado en `~/.local/bin/woffy`.

## 3) Config/login
- [ ] `woffy login` funciona con credenciales válidas.
- [ ] Se crean/actualizan:
  - `~/.woffy.conf` (600)
  - `~/.woffy.token` (600)
  - `~/.woffy.user` (600)
- [ ] `woffy user` muestra datos coherentes.

## 4) Fichaje y estado
- [ ] `woffy status` responde.
- [ ] `woffy in` correcto cuando procede.
- [ ] `woffy out` correcto cuando procede.
- [ ] Evita doble fichaje (warnings esperados).

## 5) Dry-run
- [ ] `woffy dry-run in` simula sin fichar de verdad.
- [ ] `woffy dry-run out` simula sin fichar de verdad.

## 6) Reporte
- [ ] `woffy report` (texto) correcto.
- [ ] `woffy report --format json` válido.
- [ ] `woffy report --format csv` válido.
- [ ] `woffy report --from YYYY-MM-DD --to YYYY-MM-DD` filtra bien.
- [ ] `woffy report telegram` envía si Telegram está configurado.

## 7) Telegram
- [ ] `woffy telegram` guarda config.
- [ ] `woffy telegram test` llega al chat.
- [ ] `woffy notify test success|warning|error|info|all` funciona.
- [ ] `--no-telegram` evita envíos cuando se usa en comandos.

## 8) Cron / schedule
- [ ] `woffy schedule list` muestra tareas.
- [ ] `woffy schedule entrada` / `salida` crean tareas.
- [ ] `woffy schedule pause` pausa tareas woffy.
- [ ] `woffy schedule resume` reanuda tareas woffy.
- [ ] `woffy schedule report` programa viernes 18:00.
- [ ] `woffy schedule timezone Europe/Madrid` aplica CRON_TZ.
- [ ] `woffy schedule clear` limpia tareas de woffy.

## 9) Systemd user timers
- [ ] `woffy schedule systemd enable` crea/activa timers.
- [ ] `woffy schedule systemd status` muestra estado.
- [ ] `woffy schedule systemd disable` los elimina.

## 10) Mantenimiento
- [ ] `woffy doctor` correcto.
- [ ] `woffy doctor --json` devuelve JSON válido.
- [ ] `woffy self-test` pasa (o documentar fallos esperados).
- [ ] `woffy backup` genera `.tar.gz`.
- [ ] `woffy restore <backup>` restaura correctamente.
- [ ] `woffy changelog` muestra versión local/remota y commits.
- [ ] `woffy update` valida checksum y actualiza.

## 11) Desinstalación
- [ ] `woffy uninstall` elimina binario, config, token, user, log, lock y cron.

## 12) Control final de cambios
- [ ] `git diff` revisado sin secretos.
- [ ] `README.md` actualizado y consistente con comandos reales.
- [ ] `CHECKLIST.md` actualizado.
