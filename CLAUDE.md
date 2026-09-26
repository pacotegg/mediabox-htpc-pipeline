<!-- Destino: C:\scripts\CLAUDE.md -->
<!-- Es el MAPA del proyecto, no el manual. La profundidad vive en las skills: -->
<!-- no copiar aquí lo que ya explican, solo apuntar a ellas. -->

# MediaBox — pipeline de medios del HTPC

Pipeline de codificación de vídeo, audio y subtítulos con panel web. Minisforum HN2673,
Windows 11 Pro, **PowerShell 7.6**, Intel Arc A730M.

**`C:\scripts` es la fuente de verdad.** Las copias adjuntas a conversaciones o proyectos se
quedan obsoletas: leer siempre el fichero real antes de proponer nada.

## Estructura

```
C:\scripts\
  encode.ps1              # Vídeo. hevc_qsv + vpp_qsv
  encode-watch.ps1        # Watcher de vídeo    -> C:\Media\encode_queue
  subs-watch.ps1          # Watcher de subs     -> C:\Media\subs_queue  (encode.ps1 -SubsOnly)
  atmosenc\
    audio_encode.ps1      # Solo audio
    audio-watch.ps1       # Watcher de audio    -> C:\Media\audio_queue
  atmos-lib.ps1           # Librería COMPARTIDA (1800+ líneas). Debe vivir junto a encode.ps1
  subs-lib.ps1  jd-lib.ps1  mediabox-paths.ps1   # Librerías: subtítulos, JDownloader, rutas
  pipeline-lock.ps1       # Lock atómico. Lo dot-sourcean los tres watchers
  webpanel\               # Panel Flask + SSE — ver sección Webpanel más abajo
  bin\  DEE\              # deew, truehdd, dee.exe
  atmos_audit\            # Inventario del catálogo + Generar-Faltantes.ps1
  pruebas\                # SUITE DE PRUEBAS. correr-todo.ps1 lo lanza todo
  archivo\                # Scripts RETIRADOS (check-source, run-queue, ab-denoise…). No usar
  ScummVM-Manager\        # Proyecto aparte que vive aquí dentro
  WinKlean\               # Mantenimiento de Windows, Docker, Caddy, Jellyfin
  start-mediabox-core.ps1 / stop-mediabox.ps1 / mediabox-watchdog.xml
  ab-test.ps1  icq-probe.ps1  av1-vs-hevc.ps1  bench-atmos-parallel.ps1   # Medición
  Diagnostico-HTPC.ps1  Analizar-Watchdog.ps1                             # Post-cuelgue, solo lectura
```

`archivo\` es papelera, no biblioteca: lo que hay ahí está retirado a propósito. Si algo parece
que falta en la raíz, mirar ahí antes de reescribirlo.

## Comandos

```powershell
# Arrancar o reparar (idempotente: no duplica lo que ya esté vivo)
pwsh -ExecutionPolicy Bypass -File C:\scripts\start-mediabox-core.ps1

# Parar
C:\scripts\stop-mediabox.bat

# Ver qué está vivo (tasklist /v NO muestra los argumentos)
Get-CimInstance Win32_Process | Where-Object CommandLine -match 'encode-watch|audio-watch|subs-watch|app\.py'

# Pausa global para mantenimiento
New-Item -ItemType File 'C:\Media\tmp\pipeline_paused'
Remove-Item 'C:\Media\tmp\pipeline_paused'

# Obligatorio tras editar cualquier .ps1
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
if ($errs) { $errs } else { "Sintaxis OK" }
```

**Sí hay suite de pruebas**, en `C:\scripts\pruebas\`. Pasarla antes de dar por bueno un cambio:

```powershell
pwsh -File C:\scripts\pruebas\correr-todo.ps1      # toda la batería
pwsh -File C:\scripts\pruebas\auditar-codigo.ps1   # auditoría estática
```

Dentro hay pruebas de espejo (`test-espejo-audio`, `-ddp`, `-abtest`), de ranuras, de
presupuesto, de sondeo, de colisiones de parámetros y de reconstrucción. Si se toca la zona que
cubre una de ellas, ejecutarla en concreto además de la batería.

Para capturar una ejecución completa, transcript: `Write-Host` no pasa por la tubería.

**`pwsh.exe` siempre por ruta completa** (`C:\Program Files\PowerShell\7\pwsh.exe`): `powershell`
a secas resuelve a 5.1, que no es el host con el que se ha probado nada. Python:
`C:\Users\HTPC\AppData\Local\Programs\Python\Python314\python.exe`.

## Webpanel (Flask)

`webpanel\app.py` — Flask + SSE, `http://localhost:8080`. Al menos una plantilla en
`webpanel\templates\index.html`. Es el único trozo de Python del proyecto; todo lo demás es PS7.

- **No tiene guarda de instancia única** (los watchers sí). Dos arranques a la vez y el segundo
  muere al no poder coger el puerto 8080 — por eso el watchdog espera 5 minutos tras el logon,
  para no competir con el acceso directo de Inicio.
- **Dos ficheros de pausa distintos, no confundir**: `pipeline_paused` en `C:\Media\tmp` es la
  pausa global (ningún watcher coge trabajo nuevo); `encode_paused`, en el mismo sitio, la crea
  el botón STOP **del propio panel** y es solo del vídeo — no debe congelar la cola de audio.
- Lee de `C:\Media\tmp` (estado, KB) y muestra progreso de lo que hay en `G:\MediaTmp`
  (temporales pesados), pero **nunca escribe ahí directamente** — eso es cosa de `encode.ps1`
  y `audio_encode.ps1`.
- **Tras tocar JS o plantillas, recargar con `Ctrl+Shift+R`**: si no, el navegador sirve la
  versión cacheada y parece que el cambio no ha hecho nada.

No hay más detalle aquí a propósito — el resto (arrancar/parar/diagnosticar, el lock, el
watchdog) está en `mediabox-ops` y `ps7-edit-guard`. Duplicarlo aquí es la misma trampa que los
gotchas de PS7 repetidos en cuatro skills: dos copias que un día dejan de decir lo mismo.

## Dónde está el conocimiento

No duplicar aquí lo que ya explican las skills. Leer la que toque **antes** de tocar nada:

| Tarea | Skill |
|---|---|
| Editar cualquier `.ps1` de aquí (o el webpanel) | `ps7-edit-guard` |
| Arrancar, parar, reparar, cola atascada, cuelgue | `mediabox-ops` |
| Rama de audio DD+/Atmos, `atmos-lib.ps1`, workers | `atmos-pipeline` |
| Parámetros de `hevc_qsv`, GQ, bitrate, filtros | `arc-qsv-facts` |
| Medir si un cambio de encode sirve de algo | `encode-ab-test` |

## Quirks

- **No copiar la lógica.** `New-DeeAtmosXml` y el motor de audio ya se duplicaron y divergieron
  dos veces, y hubo que deshacerlo. Todo lo compartido vive en la librería.
- **Los comentarios del código han mentido.** `extbrc+LA60` y un cap muerto de 10.75M. Mandan las
  asignaciones, no los comentarios. Un comentario no es una verificación.
- `encode.ps1` pasa varias opciones QSV **inertes**, documentadas como tales en el propio script.
  Verlas ahí no significa que hagan algo.
- `encode.ps1` es **ASCII** salvo tres caracteres heredados dentro de `Repair-Mojibake`. No
  introducir acentos nuevos en ese fichero.
- **Nunca degradar al eac3 nativo en silencio**: perder el Atmos sin aviso es el fallo que este
  subsistema existe para evitar.
- `Stop-Process -Force` **no ejecuta el `finally`**, así que los temporales quedan huérfanos
  siempre: 12-21 GB por trabajo. El barrido por patrón no es opcional.
- Máquina en **es-ES**: `[double]::TryParse('34.5')` da `345`. Parsear en `InvariantCulture`.
- Al editar `mediabox-watchdog.xml`: dos guiones seguidos rompen un comentario XML, y el fichero
  tiene que estar en **UTF-16**.

<!--
Estructura y comandos cotejados contra el disco el 21/09/2026 (listado real de *.ps1).
La sección Webpanel sale de lo citado en las skills ps7-edit-guard y mediabox-ops, no de leer
app.py directamente — no se ha visto el fichero real. El resto (quirks, reglas) sale también de
las skills. Si algo aquí no cuadra con el fichero real, manda el fichero: corregir esto, no el código.
-->
