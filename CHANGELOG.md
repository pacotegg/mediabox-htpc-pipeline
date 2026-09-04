# Changelog — MediaBox (HTPC Encode Pipeline & Webpanel)

Formato libre por sesión de trabajo (no SemVer: esto es un pipeline casero,
no una librería versionada). Cada entrada resume el `TRASPASO_*.md`
correspondiente, que queda en la raíz con el detalle completo.

## 2026-08-29 — Pérdida de una película + saneado del patrón de sustitución

- **Incidente:** `retrofit-reconstruir.ps1` destruyó de forma irrecuperable
  una película (`Move-Item -Force` no es atómico + `ErrorActionPreference=Continue`
  ocultó el fallo + el `finally` borró el único sustituto que quedaba).
- **Fix de fondo:** nueva `Move-FicheroEnSitio` en `atmos-lib.ps1` — apartar
  nunca borrar, `-ErrorAction Stop` siempre, comprobar el efecto, deshacer al
  fallar, reintentos por el handle. Adoptada por `Rebuild-Container`,
  `audio_recap.ps1`, `audio_compat.ps1`, `inyectar-atmos.ps1`, `reordenar-pistas.ps1`.
- Pérdida menor: `Rebuild-Container` no conservaba adjuntos (fuentes ASS de
  9 películas) — arreglado y verificado por MD5.
- `Rebuild-Container`: guarda de framerate, dos intentos de timestamps,
  adjuntos conservados, pistas de subtítulos vacías apartadas (no tumban el
  muxeo), ASS/SSA → SRT siempre, stderr de mkvmerge capturado.
- Retrofit de reconstrucción de contenedores cerrado: 640/648 hechas
  (4 `.mp4` no aplican, 3 con bitstream problemático, 1 la perdida).
- Compatibilidad de códecs cerrada: 0 códecs no nativos en 5.452 ficheros.
- `sanear.ps1` (nuevo): deja una película lista para biblioteca en un paso.
- Revisión de arquitectura publicada — veredicto: no reescribir; batería de
  pruebas mínima y sacar `Rebuild-Container` de `encode.ps1` como prioridades.

## 2026-08-26/27 — Auditoría completa + rediseño de la política de tamaño

- Auditoría de los tres pipelines: **10 fallos reales encontrados y arreglados**
  (fuga de 10-20 GB de `_recon_*` sin barrer, `.partial` colándose en la cola
  de vídeo, ciclo infinito de reintentos en `exit 75`, `pwsh` lanzado por PATH
  que podía colgar los tres pipelines a la vez, XSS en título de pista MKV,
  código muerto, lock que podía quedar cogido para siempre, pérdida de título
  de contenedor, poda de caché solo al guardar, y un log de limpieza que
  mentía sobre si había borrado algo).
- Watchers ahora dejan log persistente (`C:\Media\encode_logs\watcher-*.log`).
- **QSVEncC descartado en firme**: con `ffmpeg -v verbose` se confirmó que
  `extbrc`/lookahead/min-max QP/`MaxFrameSize` son inertes porque la Arc A730M
  solo tiene ruta VDENC con BRC en hardware — no es límite de ffmpeg, es
  límite del driver. QSVEncC pasaría por el mismo runtime oneVPL: no
  compraría nada.
- Política de tamaño redefinida (1080p bajó de 8.5/7.5 a 5.5/5.0 GB, −21%
  sobre la biblioteca) y **1080p volvió de ICQ a QVBR** (ICQ no tiene control
  de tamaño: medido 2.6× de diferencia entre dos películas del mismo bitrate
  de fuente).
- Panel: selector por película `auto | ICQ | QVBR` + Mbps manual + sidecar `.opts`.
- Nuevos campos en `completed.jsonl`: `rate_mode`, `rate_mode_req`, `target_manual`.

## 2026-08-25 — Perfil de calidad por resolución + autocorrección de sync

- 1080p pasa a ICQ puro (GQ 15, mismo nivel pedido de siempre, sin inflar
  escenas fáciles); 4K se queda en QVBR con techo por tabla (en ICQ el
  contenido con grano real podía pedir más que el techo, medido en
  *El Bueno El Feo Y El Malo*: +23% de tamaño).
- Autocorrección de sync en remux (`webpanel/app.py::_remux_verify` /
  `remux_worker`) y cronómetro por fase.
- `Test-PieceMatch` cierra el autoemparejamiento de procesos en
  `start-mediabox-core.ps1`.

## 2026-07-17 — Pestaña Subs + arreglo de Stop/Skip + endurecimiento de PATH

- Pestaña **Subs** completa en el panel (`app.py` + `index.html`): añadir a
  cola, estado en vivo, cancelar — mismo patrón que la pestaña Audio.
- **Diagnóstico y arreglo de Stop/Skip rotos**: escribían/mataban el PID de
  ffmpeg, que no existe durante las fases de audio (~20 min) — pasan a
  escribir el PID del propio `encode.ps1` desde el arranque.
- El `Skip` antiguo borraba **todo** `encode_running` a ciegas al pulsarse,
  incluso si el kill fallaba — causó pérdida de fuentes en producción.
  Rehecho: nunca borra, solo mata.
- Semántica nueva de botones: **Stop** mata y pausa la cola entera (flag
  `encode_paused`); **Skip** mata y pasa al siguiente; nuevo botón
  **Reanudar cola**.
- Mecanismo de limpieza marcador+barrido (`${StatePfx}_outfile` +
  `Clean-JobLeftovers`) para que `taskkill /F` (que no dispara `finally`) no
  deje huérfanos de 12-21 GB en `C:\Media\tmp`.
- Barrido de todas las llamadas a ffmpeg/ffprobe por PATH que quedaban
  (`encode.ps1::Probe`, extracción PGS, `atmos-lib.ps1`, `app.py`) — todas a
  ruta absoluta.
