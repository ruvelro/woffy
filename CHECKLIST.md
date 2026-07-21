# Release checklist — Woffy v3

## Integridad

- [ ] `bash scripts/build-woffy.sh --check`
- [ ] `bash -n woffy.sh install-woffy.sh`
- [ ] `shellcheck woffy.sh install-woffy.sh`
- [ ] `shfmt -d -i 2 -ci woffy.sh install-woffy.sh`
- [ ] `bats tests`
- [ ] `bash tests/vps-update-smoke.sh`
- [ ] `git diff --check` y revisión sin secretos.

## Migración y operación

- [ ] Migrar una copia de DB v2 y confirmar `user_version=3`, WAL e `integrity_check=ok`.
- [ ] Verificar login seguro, horarios atómicos, `run due --dry-run`, catch-up, reintentos y serialización por trabajador.
- [ ] Verificar que un fallo de `workdaylite` no ficha.
- [ ] Probar JSON/CSV con caracteres especiales y Telegram configurado/no configurado.
- [ ] Probar backup/restore y rollback del binario.

## API oficial

- [ ] Validar OAuth `client_credentials` con CompanyId/API key de pruebas.
- [ ] Contrastar `/api/v1/signs`, payload y respuesta con Swagger vigente.
- [ ] Ejecutar un retroactivo de pruebas y verificarlo en Woffu.

## Release y VPS

- [ ] El tag coincide con `VERSION`.
- [ ] El release contiene `woffy`, `woffy.version` y `woffy.sha256`.
- [ ] Instalar desde release en un HOME limpio.
- [ ] Actualizar una instalación v2 con `woffy update` y confirmar DB/cron.
- [ ] Forzar checksum y post-check fallidos y confirmar restauración de `.previous`.
- [ ] Ejecutar canario y observar al menos dos ventanas de horarios antes de ampliar usuarios.

## Documentación

- [ ] README, `/docs`, tareas, ADR y changelog coinciden con el comportamiento publicado.
- [ ] El release conserva el punto de retorno `b4a12a3` y snapshot `faeb74b`.
