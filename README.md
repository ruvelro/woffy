# woffy – fichajes Woffu desde terminal

**woffy** es una utilidad de terminal para fichar entrada y salida en Woffu usando `curl`, sin API key, sin navegador y sin aplicaciones oficiales.

Ideal para automatizar tus jornadas con `cron`, recibir notificaciones por Telegram y controlar tu estado sin abrir el portal.

## 🚀 Instalación rápida

```bash
curl -fsSL https://tu-sitio/install-woffy.sh | bash -s - EMAIL PASSWORD [TG_TOKEN CHAT_ID THREAD_ID]
```

## ⚙️ Comandos disponibles

woffy in / out / status / login / telegram / schedule list|pause|resume|entrada add|salida add / help

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