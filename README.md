# MediaBox — HTPC Encode Pipeline & Webpanel

Pipeline de codificación/remux de la biblioteca de vídeo del HTPC, con panel
web de control. Corre de forma nativa en Windows (PowerShell 7 + Python),
sin contenedores: usa aceleración por hardware Intel Quick Sync del equipo.

**Máquina:** HTPC Windows 11 (Minisforum HN2673, i7-12650H, Intel Arc A730M).

## Arquitectura

Un panel Flask (`webpanel/app.py`, puerto 8080, SSE para estado en vivo) más
tres watchers PowerShell independientes, cada uno dirigido por carpetas bajo
`C:\Media`:

| Pipeline | Watcher | Motor | Cola → Salida |
|---|---|---|---|
| **Vídeo** | `encode-watch.ps1` | `encode.ps1` (HEVC/QSV, QVBR o ICQ según perfil) | `encode_queue` → `encode_running` → `encoded/` |
| **Audio** | `atmosenc\audio-watch.ps1` | `audio_encode.ps1` (solo audio, `-c:v copy`) | cola propia, ver `atmosenc/` |
| **Subtítulos** | `subs-watch.ps1` | `encode.ps1 -SubsOnly` (OCR PGS→SRT vía PgsToSrt+Tesseract) | `subs_queue` → `subs_done` |

Los tres comparten un lock (`pipeline-lock.ps1` → `C:\Media\tmp\pipeline.lock`)
porque comparten el mismo directorio temporal y un DAMF (decodificación Atmos)
puede ocupar 12–21 GB.

Motor de audio único: `atmos-lib.ps1` (dot-sourced por `encode.ps1` y
`audio_encode.ps1`). Routing:

- TrueHD+Atmos → `mkvextract` → `truehdd` → DAMF → `dee.exe -x XML` → DD+ JOC 768k (objetos intactos, **nunca se tocan**).
- TrueHD sin Atmos / DTS → `deew -f ddp` → DEE → DD+ 640k.
- AC-3/E-AC-3/AAC/Opus ya compatibles → copy.
- Tope de audio copiado: `Get-CopyAudioCapK` — dispara en 640k, recorta a 448k (nunca toca Atmos).

## Reglas de oro (no romper)

1. **Nunca depender del PATH.** ffmpeg/ffprobe/pwsh siempre por ruta absoluta.
   Un `%PATH%` roto tuvo el OCR/dotnet caídos semanas.
2. **Los `.ps1` en ASCII puro.** Un carácter fuera de ASCII rompe el parseo
   bajo cp1252 en este host.
3. **El PID que mata un trabajo es el del script orquestador** (`encode.ps1`,
   `audio_encode.ps1`), nunca el de ffmpeg — las fases previas (DEE, ~20 min)
   no tienen proceso ffmpeg vivo y quedaban inmatables.
4. **`taskkill /F` no ejecuta el `finally` de PowerShell.** La limpieza de
   temporales/salida parcial tras matar un trabajo vive en el watcher
   (marcador `${StatePfx}_outfile` + `Clean-JobLeftovers`), no en el proceso matado.
5. **Sustitución de ficheros en sitio: usar `Move-FicheroEnSitio`** (`atmos-lib.ps1`).
   `Move-Item -Force` no es atómico (borra el destino y *luego* mueve) y con
   `$ErrorActionPreference='Continue'` un fallo a medias no para el script.
   Esto costó una película irrecuperable (29/08/2026) — ver `CHANGELOG.md`.
6. **Stop/Skip/Cancel nunca borran la fuente**, solo el trabajo en curso y su
   salida parcial. La versión antigua que sí borraba causó pérdidas de ficheros.
7. **El bitrate manual (sidecar `.opts`) es la última palabra**: manda sobre
   suelo, techo y el tope del 70% sobre la fuente.

## Política de calidad/tamaño actual

```
Perfil:  las dos ramas en 'icq-red' (21/09/2026): ICQ (4K GQ 19, 1080p GQ 15) y,
         al terminar el video, si gasta mas que el TARGET que 'techo' habria usado
         se REPITE solo el video en QVBR con ese target (GQ 15/16).

Pelicula  4K HDR 9.0  | 4K SDR 8.5  | 1080p HDR 5.5 | 1080p SDR 5.0
Serie     4K HDR 6.5  | 4K SDR 5.5  | 1080p HDR 4.5 | 1080p SDR 4.0
Suelo     4K 8.0 (6.5 si >=210 min) | 1080p 4.5 (4.0)
```

Bloque en `encode.ps1`, sección "PERFIL DE CALIDAD" (variables `$CfgPerfil1080p`,
`$CfgPerfil4K`, `$CfgGqIcq*`). Ver `CHANGELOG.md` para el porqué de cada valor.

**Hardware:** la Arc A730M solo tiene ruta VDENC con BRC en hardware —
`extbrc`, lookahead, min/max QP y `MaxFrameSize` son inertes vía QSV/oneVPL
(confirmado con `ffmpeg -v verbose`, no es un problema de ffmpeg). QSVEncC no
mejoraría nada: pasa por el mismo driver. Detalle en `CHANGELOG.md` (26/08).

## Scripts principales

| Fichero | Qué hace |
|---|---|
| `encode.ps1` | Motor de codificación de vídeo (HEVC/QSV), reconstrucción de contenedor, modo `-SubsOnly` |
| `encode-watch.ps1` | Watcher de la cola de vídeo |
| `atmos-lib.ps1` | Motor de audio (routing Atmos/DDP), utilidades compartidas (`Move-FicheroEnSitio`, `Get-CopyAudioCapK`, ...) |
| `atmos-farm.ps1`, `atmos-track-worker.ps1`, `atmos-prio-booster.ps1` | Paralelismo/prioridad de conversiones Atmos |
| `subs-watch.ps1` | Watcher de la cola de subtítulos |
| `sanear.ps1` | Deja una película lista para biblioteca (cordura, plan de audio, banderas de idioma, reconstrucción) |
| `audio_compat.ps1`, `audio_recap.ps1` | Compatibilidad de códecs de audio y recorte al tope de bitrate |
| `reordenar-pistas.ps1`, `inyectar-atmos.ps1`, `retrofit-reconstruir.ps1` | Operaciones de retrofit en lote sobre la biblioteca existente |
| `pipeline-lock.ps1` | Lock compartido entre los tres pipelines |
| `descargas-tanda.ps1` | Ciclo cerrado JDownloader → encode → tinyMediaManager → `E:\Series` / `E:\Peliculas`, por tandas de N títulos, sin llenar C: |
| `jd-lib.ps1`, `jd-api-setup.ps1` | Cliente de la API local de JDownloader (`127.0.0.1:3128`) y su activación, de un solo uso |
| `tandas-keepalive.ps1` | Red de seguridad de `descargas-tanda.ps1`: lo relanza tras un corte de luz o un reinicio, nunca tras una parada deliberada |
| `webpanel/app.py` + `webpanel/templates/index.html` | Panel Flask (SSE), pestañas Encoder/Audio/Subs/Remux |
| `webpanel/remuxlib.py`, `webpanel/subsfetch.py` | Lógica de remux y descarga de subtítulos del panel |
| `ab-test.ps1`, `icq-probe.ps1`, `av1-vs-hevc.ps1`, `bench-atmos-parallel.ps1` | Herramientas de medición/A-B testing de parámetros de codificación |
| `start-mediabox*.{bat,vbs,ps1}`, `stop-mediabox.{bat,ps1}` | Arranque/parada del panel + watchers |
| `Diagnostico-HTPC.ps1`, `Analizar-Watchdog.ps1` | Diagnóstico del equipo y del watchdog de estabilidad |

## Dependencias externas (no incluidas en este repo)

Herramientas de terceros que el pipeline invoca por ruta absoluta — se
instalan aparte y quedan fuera de git por tamaño/licencia (ver `.gitignore`):

- `DEE/` — Dolby Encoding Engine + MediaInfo + utilidades (~800 MB).
- `PgsToSrt/` — OCR de subtítulos PGS→SRT (~60 MB).
- `bin/` — ffmpeg/ffprobe/mkvtoolnix/truehdd/deew y similares.

## Estado y aprendizajes

El histórico detallado de cada sesión de trabajo (qué se cambió, por qué,
qué se midió, qué trampas costó encontrar) está en `CHANGELOG.md` y en los
documentos `TRASPASO_*.md` de la raíz, que quedan como bitácora completa.
