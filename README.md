# woffy — fichajes Woffu desde terminal (sin sudo)

**woffy** es una utilidad de línea de comandos para fichar **entrada** y **salida** en Woffu directamente desde la terminal, sin navegador y sin apps oficiales.

Está pensada para:
- fichar rápido con `woffy in` / `woffy out`
- automatizar fichajes con `cron`
- recibir notificaciones por Telegram (opcional)
- funcionar **sin sudo**, solo con privilegios de usuario

---

## ✅ Instalación (modo usuario)

Instala woffy en `~/.local/bin` y añade el PATH si es necesario.

```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash
```

Con credenciales iniciales:

```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash -s - "EMAIL" "PASSWORD"
```

Si Bash sigue apuntando a una ruta antigua:

---

## ⚙️ Configuración

### Archivo de configuración

`~/.woffy.conf`

```bash
WURL_USER="tu@email.com"
WURL_PASS="tu_password"
```

Permisos: `600`.

### Telegram (opcional)

```bash
woffy telegram
woffy telegram test
```

Variables guardadas:

```bash
TG_TOKEN="..."
TG_CHAT_ID="..."
TG_THREAD="..."   # opcional
TG_NOTIFY="all"   # all | errors | success
```

---

## 🔐 Seguridad

- Config y token con permisos `600`
- Token OAuth cacheado en `~/.woffy.token`
- Logs en `~/.woffy.log`

---

## 🧠 Funcionamiento interno

1. Autenticación OAuth contra Woffu (`/token`)
2. Cacheo del token local
3. Uso de `https://app.woffu.com/api/signs`
4. Notificaciones Telegram según configuración

---

## 🧾 Comandos

| Comando | Descripción |
|------|-----------|
| `woffy in` | Ficha entrada |
| `woffy out` | Ficha salida |
| `woffy status` | Estado actual |
| `woffy login` | Cambiar credenciales |
| `woffy telegram` | Configurar Telegram |
| `woffy telegram test` | Test Telegram |
| `woffy doctor` | Diagnóstico + test TG |
| `woffy update` | Actualiza binario |
| `woffy uninstall` | Desinstala todo |
| `woffy version` | Versión |
| `woffy help` | Ayuda completa |

---

## ⏰ Cron / schedule

Listar:

```bash
woffy schedule list
```

Limpiar solo woffy:

```bash
woffy schedule clear
```

Pausar / reanudar SOLO woffy:

```bash
woffy schedule pause
woffy schedule resume
```

Entradas:

```bash
woffy schedule entrada
woffy schedule entrada 09:00
```

Salidas:

```bash
woffy schedule salida
woffy schedule salida 18:00
```

---

## 🩺 Diagnóstico

```bash
woffy doctor
```

Muestra:
- config
- token
- dependencias
- cron
- Telegram (envía test si está configurado)

---

## 🧹 Desinstalar

```bash
woffy uninstall
```

Elimina:
- binario
- config
- token
- log
- cron de woffy

---

## 🧹 Actualizar

```bash
woffy update
```

Actualiza:
- binario
  
Mantiene:
- config
- token
- log
- cron de woffy

---

## 📌 Pendientes

- No fichar en vacaciones/descansos/festivos
- validación estricta de horas
- lockfile cron/manual

---

GNU GPL v3 License
