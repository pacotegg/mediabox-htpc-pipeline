<#
============================================================================
 stop-mediabox.ps1  -  Para el panel y los watchers (video + audio)
============================================================================
 POR QUE UN .ps1 Y NO TODO EN EL .bat:
 la version anterior metia la logica dentro de un `pwsh -NoProfile -Command "..."`
 lanzado desde cmd. Ese trayecto cmd -> pwsh fallaba de formas que nunca se
 llegaron a explicar: primero un "Force: The term 'Force' is not recognized",
 y despues (sin error ninguno) simplemente no mataba nada, aun cuando la MISMA
 consulta pegada a mano en pwsh SI encontraba los procesos. En vez de seguir
 peleando con el escapado de cmd, la logica vive aqui y el .bat solo hace
 `pwsh -File`. Sin comillas anidadas, sin sorpresas.

 Uso:
   C:\scripts\stop-mediabox.bat
   (o directamente: pwsh -ExecutionPolicy Bypass -File C:\scripts\stop-mediabox.ps1)

 NOTA: fichero en ASCII puro (codigo y comentarios).
============================================================================
#>

$ErrorActionPreference = 'Continue'
$Tmp = 'C:\Media\tmp'
# La plomeria compartida de los watchers. De aqui salen DOS cosas que este script
# necesita y hasta el 19/08/2026 tenia por su cuenta (o no tenia):
#   - $PipelineTempPatterns : la lista de temporales. Habia CUATRO copias (los
#     tres watchers y esta) y ya habian divergido.
#   - Restore-PipelinePowerPlan : el pipeline sube el plan a 'Alto rendimiento'
#     al coger el lock y lo baja al soltarlo. Un stop mata al que lo tenia
#     cogido SIN que corra ese Exit-PipelineLock, asi que el equipo se quedaba
#     en Alto rendimiento hasta el siguiente trabajo. Y este equipo esta
#     encendido todo el dia y casi siempre ocioso: es justo el consumo 24 h que
#     el plan por trabajo existe para no pagar.
$LockLib = Join-Path $PSScriptRoot 'pipeline-lock.ps1'
if (-not (Test-Path -LiteralPath $LockLib)) { $LockLib = 'C:\scripts\pipeline-lock.ps1' }
if (Test-Path -LiteralPath $LockLib) { . $LockLib }
else { Write-Host "AVISO: no encuentro pipeline-lock.ps1; se usan los patrones de reserva." }
# Temporales PESADOS (.thd/DAMF/ec3): desde el 31/07/2026 viven en otra unidad
# para que un DAMF de 30 GB no compita por C: con el pagefile y con la cola.
# Tiene que coincidir con el $BigTmp de encode.ps1 / audio_encode.ps1 / los
# watchers; si no, el barrido de mas abajo dejaria ahi los GB de un trabajo
# matado, que es justo lo que este script existe para evitar.
$BigTmp = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { 'G:\MediaTmp' }
$killed = 0

# --- 1) Watchers y encodes en curso (ambos pipelines, ambos hosts) -----
# Nota: el patron 'encode\.ps1' tambien casa con 'audio_encode.ps1' (es
# subcadena), lo cual es justo lo que queremos: caen los dos. Y los trabajos de
# subtitulos corren como 'encode.ps1 -SubsOnly', asi que tambien casan; lo que
# hay que nombrar aparte es su watcher.
#
# HIJOS EN pwsh (19/08/2026). Faltaban los dos, y Stop-Process -Force NO mata el
# arbol: quedaban vivos despues de "parar MediaBox".
#   - atmos-track-worker.ps1 : cada pista de audio paralelizada corre en su
#     propio pwsh (Invoke-DdpTracksParallel). Sus binarios (dee/truehdd) si
#     morian en el paso 2, pero el worker seguia y podia escribir temporales
#     DESPUES del barrido del paso 5, dejandolos huerfanos.
#   - atmos-prio-booster.ps1 : el vigilante de prioridades. Se autolimita a
#     240 min, o sea que sin esto seguia subiendole la prioridad a procesos
#     hasta CUATRO HORAS despues de haber parado todo.
# Y ademas, el peor detalle: la verificacion final de este script usaba esta
# misma lista, asi que informaba de "MediaBox detenido" con procesos vivos.
$MediaBoxPs = 'encode-watch|encode\.ps1|audio-watch|audio_encode\.ps1|subs-watch|atmos-track-worker|atmos-prio-booster'
$targets = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -in @('powershell.exe','pwsh.exe') -and
    $_.CommandLine -match $MediaBoxPs -and
    $_.ProcessId -ne $PID
}
foreach ($p in $targets) {
    $what = $p.CommandLine
    if ($what -match '-File\s+"?([^"]+)"?') { $what = $Matches[1] }
    Write-Host ("  [kill] PID {0,-6} {1}" -f $p.ProcessId, $what)
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    $killed++
}

# --- 2) Procesos de encode (video: ffmpeg; audio: dee/truehdd) ---------
# FFMPEG SE FILTRA POR RUTA (19/08/2026). Matarlo por nombre se llevaba por
# delante CUALQUIER ffmpeg del equipo, y aqui hay otro: tinyMediaManager trae el
# suyo en AppData\Roaming\tinyMediaManager\addons y lo usa para sacar miniaturas.
# Comprobado hoy: en un stop normal murio su PID 8236, que no tenia nada que ver
# con el pipeline. "Parar MediaBox" no debe tocar otras aplicaciones.
# dee/truehdd/mkvextract/mkvmerge se quedan por nombre: los dos primeros son
# exclusivamente nuestros, y los de MKVToolNix son procesos cortos que en esta
# maquina solo lanza el pipeline.
$FfmpegNuestro = 'C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe'
foreach ($p in @(Get-Process -Name 'ffmpeg' -ErrorAction SilentlyContinue)) {
    $ruta = ''
    try { $ruta = $p.Path } catch { }
    # Sin ruta legible no se toca: mejor dejar vivo algo ajeno que matarlo.
    if (-not $ruta) {
        Write-Host ("  [skip] PID {0,-6} ffmpeg.exe (no se puede leer su ruta; no es seguro matarlo)" -f $p.Id)
        continue
    }
    if ($ruta -ne $FfmpegNuestro -and $ruta -notlike 'C:\scripts\*') {
        Write-Host ("  [skip] PID {0,-6} ffmpeg.exe AJENO ({1})" -f $p.Id, (Split-Path $ruta -Parent))
        continue
    }
    Write-Host ("  [kill] PID {0,-6} ffmpeg.exe" -f $p.Id)
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    $killed++
}
foreach ($n in @('dee','truehdd','mkvextract','mkvmerge')) {
    foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
        Write-Host ("  [kill] PID {0,-6} {1}.exe" -f $p.Id, $n)
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $killed++
    }
}

# --- 2b) OCR de subtitulos (dotnet PgsToSrt) ---------------------------
# El OCR corre como 'dotnet PgsToSrt.dll' y NADIE lo mataba: no es un .ps1, asi
# que no casa con el paso 1, y su nombre de proceso es 'dotnet', que no estaba en
# la lista del paso 2. Un OCR dura 10-30 min, o sea que "parar MediaBox" a mitad
# de un trabajo de subtitulos dejaba un proceso comiendo CPU sin dueno.
# SE FILTRA POR LINEA DE COMANDOS, no por nombre: en esta maquina hay mas cosas
# corriendo sobre dotnet y matarlas todas seria mucho peor que el problema.
foreach ($p in @(Get-CimInstance Win32_Process | Where-Object {
            $_.Name -eq 'dotnet.exe' -and $_.CommandLine -match 'PgsToSrt' })) {
    Write-Host ("  [kill] PID {0,-6} dotnet PgsToSrt (OCR)" -f $p.ProcessId)
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    $killed++
}

# --- 3) Panel Flask (app.py) y el buscador de subtitulos ---------------
# subsfetch.py lo lanza encode.ps1 como hijo; matar al padre no se lo lleva.
# Se filtra por linea de comandos para no tocar ningun otro python del sistema.
$py = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'python.exe' -and $_.CommandLine -match 'app\.py|subsfetch\.py'
}
foreach ($p in $py) {
    $que = if ($p.CommandLine -match 'subsfetch') { 'subsfetch.py (subtitulos)' } else { 'app.py (panel)' }
    Write-Host ("  [kill] PID {0,-6} {1}" -f $p.ProcessId, $que)
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    $killed++
}

Start-Sleep -Milliseconds 500

# --- 3b) Salidas PARCIALES de trabajos matados --------------------------
# encode.ps1 y audio_encode.ps1 escriben en <pfx>_outfile la ruta de su salida y
# lo borran al terminar por las buenas. Si el marcador sigue aqui es que acabamos
# de matar el trabajo a mitad: la salida es un MKV a medias y hay que borrarla.
# (Se lee ANTES del barrido de estado de abajo, que se lleva los marcadores.)
foreach ($mk in @('encode_outfile','subs_outfile','audio_outfile')) {
    $mkPath = Join-Path $Tmp $mk
    if (Test-Path -LiteralPath $mkPath) {
        $out = @(Get-Content -LiteralPath $mkPath -ErrorAction SilentlyContinue)[0]
        if ($out -and (Test-Path -LiteralPath $out)) {
            # Remove-ConReintento (pipeline-lock.ps1) Y NO un Remove-Item mudo
            # (03/09/2026). Estas dos lineas eran, LITERALMENTE, el caso que esa
            # funcion se escribio para arreglar el 26/08 -su propio comentario las
            # cita- y aqui se quedaron sin cambiar.
            #
            # Y este es el peor sitio para tenerlo: medio segundo antes, este
            # mismo script ha matado a ffmpeg con Stop-Process -Force, que es
            # justo cuando Windows todavia no ha soltado el handle. El
            # Remove-Item choca con una violacion de comparticion, se la traga el
            # SilentlyContinue, y el log dice "salida parcial borrada" al lado de
            # un MKV a medias CON EL NOMBRE DEFINITIVO en C:\Media\encoded, que
            # es indistinguible de un encode terminado y ademas sale en la lista
            # de Completed del panel. Paso de verdad: 804 MB.
            if (Get-Command Remove-ConReintento -ErrorAction SilentlyContinue) {
                $null = Remove-ConReintento -Ruta $out -Etiqueta 'salida parcial'
            } else {
                # Sin la libreria: al menos NO anunciar lo que no se ha comprobado.
                Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $out) {
                    Write-Host "  [clean] AVISO: NO se pudo borrar la salida parcial -> $out"
                    Write-Host "  [clean] Sigue ahi CON EL NOMBRE DEFINITIVO y esta A MEDIAS. Borrala a mano."
                } else {
                    Write-Host "  [clean] salida parcial borrada: $out"
                }
            }
        }
        Remove-Item -LiteralPath $mkPath -ErrorAction SilentlyContinue
    }
}

# --- 4) Estado y locks -------------------------------------------------
# Los *_status/*_pid hay que borrarlos TAMBIEN: si no, encode_status se queda
# con 'status=encoding' del trabajo recien matado y el panel muestra el encode
# como "live" para siempre. app.py tolera que falten (devuelve status=idle).
# 'pipeline_paused' entra aqui el 05/08/2026. Se quedaba fuera, y era una trampa
# silenciosa: quien pausara para mantenimiento y despues parase y volviera a
# arrancar se encontraba los TRES pipelines congelados sin ninguna senyal (el
# panel no muestra el estado de la pausa global). La pausa es estado de ejecucion,
# igual que el lock: un stop completo la retira. Si hace falta, se vuelve a poner.
if (Test-Path -LiteralPath (Join-Path $Tmp 'pipeline_paused')) {
    Write-Host "  [estado] habia una PAUSA GLOBAL puesta; se retira (era mantenimiento, y esto es un stop completo)."
}
# ('encode_truehd_pending' salio de esta lista el 19/08/2026 junto con la
#  consulta TrueHD entera; ya no lo escribe ni lo lee nadie.)
$estado = @('encode_paused','pipeline_paused','pipeline.lock','encode_watch_pid','audio_watch_pid','subs_watch_pid',
            'encode_status','encode_ffprog','encode_pid','encode_ffmpeg_pid',
            'audio_status','audio_pid',
            'subs_status','subs_ffprog','subs_pid','subs_ffmpeg_pid',
            # Nombres viejos: los watchers ya usan el pipeline.lock compartido,
            # pero se siguen borrando por si quedo alguno de antes del cambio.
            'encode_watch.lock','audio_watch.lock')
foreach ($f in $estado) { Remove-Item -LiteralPath (Join-Path $Tmp $f) -Force -ErrorAction SilentlyContinue }

# --- 5) Temporales pesados huerfanos (si se corto a mitad) -------------
# OJO: un Stop-Process -Force NO ejecuta el finally de PowerShell, asi que los
# temporales del encode que acabamos de matar quedan huerfanos SIEMPRE. Por eso
# este barrido no es opcional: son 12-21 GB por trabajo.
# Los patrones a_*/d_* exigen 'a'/'d' seguido de '_', asi que no tocan
# audio_status ni audio_pid.
# deetemp_*/deew_* NO los cubre 'dee_*' (el 4o caracter no es '_'); el stderr
# de ffmpeg (encode_ff_stderr_*) tampoco estaba y se acumulaba uno por encode
# matado. damf_* sin sufijo: ademas de .atmos/.audio/.metadata, truehdd puede
# dejar el prefijo pelado si lo matan justo al empezar.
# remux_*/_rmx_* entran el 05/08/2026: son los del REMUX DEL PANEL (los .ec3 y
# .srt convertidos, y los directorios de trabajo de la medicion de sync). Su
# worker los borra en el finally, pero matar el panel -que es como se reinicia-
# no ejecuta ningun finally, y nadie los barria: quedaban para siempre.
# Los 'remux_*' los barren ahora tambien los tres watchers. Los '_rmx_*' SOLO se
# pueden barrer AQUI: la medicion de sync que los crea es un sondeo del panel y
# corre SIN el lock, asi que desde un watcher podriamos llevarnos una medicion en
# marcha. Aqui es seguro porque el paso 1 ya ha matado el panel.
# La lista compartida (pipeline-lock.ps1) MAS '_rmx_*': los directorios de la
# medicion de sync del panel solo se pueden barrer AQUI, porque esa medicion
# corre sin lock y el paso 1 ya ha matado al panel.
if ($PipelineTempPatterns) { $patrones = @($PipelineTempPatterns) + @('_rmx_*') }
else { $patrones = @('thd_*','damf_*','ddp_*','job_*','dee_*','deetemp_*','deew_*','src_*','a_*','d_*','ocr_*','pgs2srt_*','encode_ff_stderr_*','remux_*','_rmx_*','vid_*','_MEI*') }
$libGb = 0
foreach ($dir in @($Tmp, $BigTmp | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($pat in $patrones) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter $pat -Force -ErrorAction SilentlyContinue)) {
            # '.Length' EN UNA CARPETA NO ES SU TAMANYO (31/08/2026): DirectoryInfo
            # no tiene esa propiedad y devuelve $null en silencio, o sea que suma 0.
            # Y varios de estos patrones SON carpetas -'_recon_*', 'sf_*', '_rmx_*',
            # 'job_*'-, justo las que mas ocupan: un DAMF de 20 GB se contaba como
            # cero y el resumen decia haber liberado mucho menos de lo que libero.
            if ($f.PSIsContainer) {
                $libGb += (Get-ChildItem -LiteralPath $f.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                           Measure-Object -Property Length -Sum).Sum
            } else {
                $libGb += $f.Length
            }
            Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
if ($libGb -gt 0) { Write-Host ("  [tmp] liberados {0:N1} GB de temporales huerfanos" -f ($libGb/1GB)) }

# --- 5b) Plan de energia -----------------------------------------------
# Al matar al dueno del lock no corre su Exit-PipelineLock, que es quien baja el
# plan. Sin esto el equipo se quedaba en 'Alto rendimiento' indefinidamente.
# Es best-effort y no hace nada si no habia plan guardado.
if (Get-Command Restore-PipelinePowerPlan -ErrorAction SilentlyContinue) {
    if (Test-Path -LiteralPath (Join-Path $Tmp 'powerplan_prev')) {
        Write-Host "  [energia] el pipeline habia subido el plan; se restaura el anterior."
    }
    Restore-PipelinePowerPlan
}

# --- 6) Informe HONESTO ------------------------------------------------
# La version anterior imprimia "MediaBox detenido." pasara lo que pasara, sin
# comprobar si habia matado algo. Un parador que miente es peor que uno que
# falla: por eso este cuenta, verifica y avisa.
if ($killed -eq 0) {
    Write-Host "AVISO: no habia ningun proceso de MediaBox corriendo (nada que parar)." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "MediaBox detenido: $killed proceso(s)." -ForegroundColor Green
}

# Verificar que no ha sobrevivido nadie.
#
# LOS BINARIOS TAMBIEN (31/08/2026). Esta lista cubria los .ps1, el panel y el
# OCR, pero NO lo que mata el paso 2: ffmpeg, dee, truehdd, mkvextract y
# mkvmerge. O sea que un dee.exe superviviente -y un Atmos son 90 min- no
# aparecia por ningun lado y el script decia "MediaBox detenido" tan tranquilo.
# Es EXACTAMENTE el defecto que la cabecera de este fichero da por corregido en
# el paso 1 ("informaba de MediaBox detenido con procesos vivos"): se arreglo
# para los hijos en pwsh y se quedo sin arreglar para los binarios.
#
# El ffmpeg AJENO no cuenta: el paso 2 lo perdona a proposito -es el de
# tinyMediaManager- y listarlo aqui seria dar por fallido un stop correcto.
$FfmpegVivo = @(Get-Process -Name 'ffmpeg' -ErrorAction SilentlyContinue | Where-Object {
    $ruta = ''
    # '.Path' LANZA en un proceso cuyo ejecutable no se puede abrir (permisos, o
    # que acabe de morir). Sin ruta no se puede saber si es nuestro, y el paso 2
    # tampoco lo mato por esa misma razon: entonces no cuenta como superviviente.
    # Dejar la ruta vacia hace justo eso, porque la condicion de abajo la exige.
    try { $ruta = $_.Path } catch { $ruta = '' }
    $ruta -and ($ruta -eq $FfmpegNuestro -or $ruta -like 'C:\scripts\*')
})
$vivos = @(Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -in @('powershell.exe','pwsh.exe') -and
     $_.CommandLine -match $MediaBoxPs -and
     $_.ProcessId -ne $PID) -or
    ($_.Name -eq 'python.exe'  -and $_.CommandLine -match 'app\.py|subsfetch\.py') -or
    ($_.Name -eq 'dotnet.exe'  -and $_.CommandLine -match 'PgsToSrt') -or
    ($_.Name -in @('dee.exe','truehdd.exe','mkvextract.exe','mkvmerge.exe'))
}) + $FfmpegVivo
if ($vivos.Count -gt 0) {
    Write-Host ""
    Write-Host "ERROR: $($vivos.Count) proceso(s) siguen vivos tras el intento:" -ForegroundColor Red
    # Los dos tipos de objeto no llevan el PID en la misma propiedad: los de
    # Get-CimInstance en 'ProcessId' y los de Get-Process en 'Id'. Pedir siempre
    # 'ProcessId' dejaba la mitad de las lineas con el hueco en blanco.
    $vivos | ForEach-Object {
        $pid_ = if ($null -ne $_.ProcessId) { $_.ProcessId } else { $_.Id }
        Write-Host ("  PID {0} - {1}" -f $pid_, $_.Name) -ForegroundColor Red
    }
    Write-Host "Puede que necesites una consola elevada." -ForegroundColor Yellow
    exit 1
}
exit 0
