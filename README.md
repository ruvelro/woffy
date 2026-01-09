# woffy – fichajes Woffu desde terminal

**woffy** es una utilidad de terminal para fichar entrada y salida en Woffu usando `curl`, sin API key, sin navegador y sin aplicaciones oficiales.

Ideal para automatizar tus jornadas con `cron`, recibir notificaciones por Telegram y controlar tu estado sin abrir el portal.

## 🚀 Instalación rápida

```bash
curl -fsSL https://raw.githubusercontent.com/ruvelro/woffy/refs/heads/main/install-woffy.sh | bash -s - EMAIL PASSWORD TG_TOKEN TG_CHAT_ID TG_THREAD_ID
```
Si no vas a usar Telegram, los tres parámetros TG_* son opcionales. Puedes activarlo más adelante.

## ⚙️ Comandos disponibles

| Comando                         | Descripción                                                                 |
|--------------------------------|-----------------------------------------------------------------------------|
| `woffy in`                     | Ficha la entrada. Si ya estás dentro, muestra error.                        |
| `woffy out`                    | Ficha la salida. Si no habías fichado antes, muestra error.                 |
| `woffy status`                 | Muestra el estado de fichajes del día actual (entrada/salida).             |
| `woffy login`                  | Cambia el email y la contraseña de acceso a Woffu (modo interactivo).      |
| `woffy telegram`               | Configura el bot de Telegram (token, chat ID, thread ID).                  |
| `woffy help`                   | Muestra esta ayuda básica de uso.                                          |

### ⏰ Gestión de horarios (cron)

| Comando                                     | Descripción                                                                    |
|--------------------------------------------|--------------------------------------------------------------------------------|
| `woffy schedule list`                      | Muestra las tareas programadas (entradas/salidas automáticas).                |
| `woffy schedule pause`                     | Pausa las tareas automáticas sin eliminarlas (comentando en `crontab`).       |
| `woffy schedule resume`                    | Reactiva las tareas pausadas.                                                 |
| `woffy schedule entrada add HH:MM`         | Añade un fichaje automático de entrada a esa hora.                            |
| `woffy schedule salida add HH:MM`          | Añade un fichaje automático de salida a esa hora.                             |

> 🧠 **Nota:** los horarios deben indicarse en formato `HH:MM` (24h), y se programan solo de **lunes a viernes**.


## 🕘 Horarios por defecto

Entrada: 09:00 y 15:30  
Salida : 14:00 y 18:00 (L-V)

## 🔐 Configuración (`~/.woffy.conf`)

WURL_USER=usuario@empresa.com  
WURL_PASS=contraseña  
TG_BOT_TOKEN=opcional  
TG_CHAT_ID=opcional  
TG_THREAD_ID=opcional  
TG_NOTIFY=errors | success | all

## 📌 Pendientes

- Validación de hora HH:MM
- Modo no interactivo para login/telegram
- Soporte perfiles múltiples
- Rotación de logs

## 📝 Licencia

MIT
