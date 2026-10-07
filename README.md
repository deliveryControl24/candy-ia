# CANDY IA 🍬

Asistente de IA local para tu Mac — controla tu equipo por chat o por voz, con
[Ollama](https://ollama.com) corriendo **100 % en tu Mac** (sin nube, sin cuentas).

## Instalación (una línea)

```bash
curl -fsSL https://github.com/deliveryControl24/candy-ia/main/install.sh | bash
```

El instalador:

1. Descarga la app y la instala en `/Applications`
2. Instala Ollama si no lo tienes
3. Descarga el modelo `llama3.2:3b` (~2 GB)
4. Abre CANDY IA

**Requisitos:** macOS 14 o superior · Intel o Apple Silicon · ~3 GB de disco.

## Qué puede hacer

- 💬 **Chat** con herramientas: abre apps, ejecuta comandos, busca y escribe archivos
- 🎙️ **Modo voz**: habla con Candy (micrófono), Esc interrumpe, lee las respuestas en voz alta
- 📊 **Dashboard**: CPU, memoria, batería en vivo y **servicios vigilados**
- 🍬 **Menú de barra**: acceso rápido desde el icono de la barra de menús (⌘1/⌘2/⌘3),
  con CPU/memoria en vivo, **limpiar temporales**, **vaciar papelera** y **liberar memoria**
- 🧠 **Selector de modelos dinámico**: lista todos los modelos instalados en Ollama
  (✓) más el catálogo descargable — cambia de modelo y lo baja si hace falta
- 🛡️ **Seguridad**: las acciones sensibles piden tu confirmación ("Permitir todo" opcional)
- 🔧 **`check_service`**: pídele que vigile una URL y verás su uptime de 7 días en el dashboard

## Ejemplos para probar

- «Abre Safari y busca clima en San José»
- «¿Cómo está la CPU?»
- «Vigila https://mi-api.com/health»
- «Crea un archivo de notas en el escritorio con…»

## Permisos de macOS

La primera vez que uses el micrófono, macOS pedirá permiso
(**Ajustes del Sistema → Privacidad y Seguridad → Micrófono / Reconocimiento de voz**).

## Compilar desde fuentes

```bash
cd candy-ia
swiftc -O macOS/Sources/*.swift -o build/CandyIA
./build/CandyIA --selftest        # pruebas end-to-end
```

Para armar el bundle `.app` y el DMG ver `build-release.sh`.

## Solución de problemas

**La descarga de modelos se queda en 0 % o falla con `network is unreachable`.**
Ocurre en redes donde IPv6 no tiene ruta: el cliente de descarga de Ollama fija la
primera dirección resuelta (IPv6) y no reintenta en IPv4. Mientras tanto puedes
instalar los modelos directamente con IPv4:

```bash
python3 tools/seed_models.py qwen2.5:1.5b qwen3:1.7b   # añade los que quieras
ollama list                                             # comprueba que aparecen
```

El script baja los blobs con `curl -4`, verifica el hash y escribe el manifiesto
en `~/.ollama/models`. Después, CANDY IA los mostrará con ✓ en el selector.

## Estructura

```
macOS/Sources/
  main.swift           ventana, menú y arranque
  MenuBarController.swift icono de barra de menús + optimizador
  ContentView.swift    UI de chat (dark, chips de herramientas)
  VoiceModeView.swift  modo voz con orbe
  OrbView.swift        la orbe animada
  Voice.swift          STT (SFSpeechRecognizer) + TTS (say)
  DashboardView.swift  widgets CPU/mem/batería/servicios
  SystemStats.swift    métricas del sistema (Darwin/IOKit)
  SystemOptimizer.swift liberar memoria / temporales / papelera
  ServicesMonitor.swift monitoreo de servicios + persistencia
  Agent.swift          bucle del agente (Ollama streaming)
  Tools.swift          herramientas del agente + prompts
  SelfTest.swift       tests end-to-end (--selftest)
tools/
  seed_models.py       instalador de modelos vía IPv4
  make_icon.py         genera assets/CandyIA.icns
```
