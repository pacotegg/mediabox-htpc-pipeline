<#
============================================================================
 inyectar-atmos.ps1  -  Convierte UNA pista TrueHD Atmos y la mete en otra copia
============================================================================
 Caso de uso: tienes la pelicula en la biblioteca con un audio normal, y por
 otro lado un release con la pista TrueHD Atmos. Esto convierte SOLO esa pista
 a DD+ JOC y la muxea en tu copia, sin remuxear el fichero fuente entero.

 Por que no vale meter el fuente en audio_queue: el motor convierte TODAS sus
 pistas (los DTS-HD MA tambien, ~26 min cada una por DEE) y produce una pelicula
 nueva de la que aun habria que extraer la pista. Aqui se toca solo lo que hace
 falta.

 REQUISITO DE SINCRONIA: el fuente y el destino tienen que ser el MISMO montaje.
 El script lo comprueba y aborta si las duraciones no cuadran; no intenta
 sincronizar nada (para eso esta la pestana Sync del panel).

 COGE EL pipeline.lock. Es obligatorio, no cortesia: audio_recap.ps1 y los
 watchers barren G:\MediaTmp con los patrones thd_*/dee_*/ddp_*, o sea que sin
 el lock otro trabajo borraria los temporales de esta conversion a media faena.

 Uso:
   pwsh -File C:\scripts\inyectar-atmos.ps1 -DryRun
   pwsh -File C:\scripts\inyectar-atmos.ps1
============================================================================
#>
param(
    [string]$Fuente  = 'C:\Media\audio_queue\EDSLA.La comunidad del anillo(2001)',
    [int]   $PistaFuente = 2,        # indice a:N del TrueHD Atmos en el fuente
    [string]$Destino = 'E:\Peliculas\El señor de los anillos∶ La comunidad del anillo - Extended Edition (2001)\El señor de los anillos∶ La comunidad del anillo - Extended Edition (2001) 2160p EAC3⁄Atmos.mkv',
    [int]   $PistaDestino = 0,       # indice a:N del destino que se REEMPLAZA
    [int]   $Bitrate = 768,          # el mismo que ya anuncian los titulos
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# $FFMPEG, $FFPROBE, $MKVPROPEDIT los da mediabox-paths.ps1 (31/08/2026: estaban copiados aqui).
foreach ($lib in @('C:\scripts\pipeline-lock.ps1','C:\scripts\atmos-lib.ps1','C:\scripts\mediabox-paths.ps1')) {
    if (Test-Path -LiteralPath $lib) { . $lib } else { Write-Host "ERROR: falta $lib"; exit 1 }
}
$BigTmp = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { 'G:\MediaTmp' }
# Temp de ESTADO y lock. Bajados aqui el 02/09/2026: salen de mediabox-paths.ps1
# y antes se fijaban ARRIBA del dot-source, o sea con la libreria sin cargar.
$Tmp = if ($MediaBoxTmp) { $MediaBoxTmp } else { 'C:\Media\tmp' }
$LockFile = Join-Path $Tmp 'pipeline.lock'

$LogFile = "C:\Media\encode_logs\inyectar-atmos-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
function Log($m) {
    $s = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $s; Add-Content -LiteralPath $LogFile -Value $s
}
function Dur([string]$f) {
    (ConvertTo-DoubleInv ((& $FFPROBE -v error -show_entries format=duration -of csv=p=0 -- $f 2>$null) | Out-String).Trim())
}

foreach ($f in @($Fuente, $Destino)) {
    if (-not (Test-Path -LiteralPath $f)) { Log "ERROR: no existe $f"; exit 1 }
}

# --- 1) Comprobaciones previas ------------------------------------------
$prof = ((& $FFPROBE -v error -select_streams "a:$PistaFuente" -show_entries stream=profile,codec_name,channels `
             -of csv=p=0 -- $Fuente 2>$null) | Out-String).Trim()
Log "Fuente  a:${PistaFuente} -> $prof"
if ($prof -notmatch '(?i)atmos') {
    Log "ERROR: a:$PistaFuente del fuente NO declara Atmos. Abortado (no tiene sentido seguir)."
    exit 1
}

$dS = Dur $Fuente; $dD = Dur $Destino
Log ("Duracion fuente {0:N3}s | destino {1:N3}s | diferencia {2:N3}s" -f $dS, $dD, [math]::Abs($dS-$dD))
if ([math]::Abs($dS - $dD) -gt 2.0) {
    Log "ERROR: no son el mismo montaje (mas de 2 s de diferencia). El audio entraria desincronizado."
    Log "       Para montajes distintos hay que sincronizar antes: pestana Sync del panel."
    exit 1
}

if ($DryRun) {
    Log "DRY-RUN: se convertiria a:$PistaFuente ($Bitrate k DD+ JOC) y reemplazaria a:$PistaDestino del destino."
    exit 0
}

# --- 2) El lock, ANTES de crear un solo temporal -------------------------
if (-not (Enter-PipelineLock $LockFile)) {
    Log "Hay otro pipeline trabajando. Vuelve a lanzarlo cuando termine la cola."
    exit 1
}

$ec3 = Join-Path $BigTmp ("inyecta_{0}.ec3" -f (Get-Date -Format 'yyyyMMddHHmmss'))
# LA EXTENSION IMPORTA: ffmpeg deduce el contenedor de salida por ella, y con
# "....mkv.nuevo" respondia "Error initializing the muxer: Invalid argument".
# Tiene que acabar en .mkv (o pasarle -f matroska, pero asi es mas claro).
$nuevo = [System.IO.Path]::ChangeExtension($Destino, '.nuevo.mkv')
$ok = $false
try {
    Log "Convirtiendo la pista Atmos a DD+ JOC ${Bitrate}k (DEE; es de un solo nucleo y va para largo)..."
    $conv = Convert-TrueHDToDDPCached -InputFile $Fuente -AudioIndex $PistaFuente -Bitrate $Bitrate `
                -OutFile $ec3 -Tmp $Tmp -BigTmp $BigTmp -IsAtmos -Channels 8 -DurationSec $dS `
                -OnProgress { param($stage,$pct) if ($pct -gt 0) { Write-Host ("  {0} {1:N0}%" -f $stage,$pct) } }
    if (-not $conv -or -not (Test-Path -LiteralPath $ec3)) { throw "la conversion no produjo el .ec3" }
    Log ("  .ec3 listo: {0:N0} MB" -f ((Get-Item -LiteralPath $ec3).Length / 1MB))

    # --- 3) Muxear: se reemplaza la pista pedida y se deja como default ---
    $raw = (& $FFPROBE -v error -select_streams a -show_entries "stream=index:stream_tags=language" -of json -- $Destino 2>$null) | Out-String
    $nAud = @((ConvertFrom-Json $raw).streams).Count
    $map = @('-map','0:v'); $codec = @('-c:v','copy'); $meta = @(); $disp = @(); $o = 0
    for ($i = 0; $i -lt $nAud; $i++) {
        if ($i -eq $PistaDestino) {
            $map   += @('-map','1:a:0')
            $meta  += @("-metadata:s:a:$o","title=DD+ JOC Atmos ${Bitrate}k", "-metadata:s:a:$o","language=spa")
        } else {
            $map   += @('-map', "0:a:$i")
        }
        $codec += @("-c:a:$o",'copy')
        # La pista con Atmos pasa a ser la de por defecto; las demas, no.
        $disp  += @("-disposition:a:$o", $(if ($i -eq $PistaDestino) { 'default' } else { '0' }))
        $o++
    }
    $ff = @('-y','-i',$Destino,'-i',$ec3) + $map + $codec + $meta + $disp +
          @('-map','0:s?','-map','0:t?','-c:s','copy','-map_metadata','0','-map_chapters','0', $nuevo)
    Log "Muxeando en la copia de la biblioteca..."
    & $FFMPEG @ff 2>&1 | Select-Object -Last 3 | ForEach-Object { Log "    | $_" }

    # --- 4) Verificar ANTES de sustituir ---------------------------------
    if (-not (Test-Path -LiteralPath $nuevo)) { throw "el muxeo no produjo fichero" }
    $pn = ((& $FFPROBE -v error -select_streams "a:$PistaDestino" -show_entries stream=profile -of csv=p=0 -- $nuevo 2>$null) | Out-String).Trim()
    if ($pn -notmatch '(?i)atmos|joc') { throw "la pista nueva no declara Atmos ('$pn'): el JOC se habria perdido" }
    $dN = Dur $nuevo
    if ([math]::Abs($dN - $dD) -gt 2.0) { throw ("la duracion no cuadra: {0:N1}s vs {1:N1}s" -f $dD, $dN) }
    $md5o = ((& $FFMPEG -v error -i $Destino -map 0:v -c copy -f md5 - 2>$null) | Out-String).Trim()
    $md5n = ((& $FFMPEG -v error -i $nuevo   -map 0:v -c copy -f md5 - 2>$null) | Out-String).Trim()
    if ($md5o -ne $md5n -or -not $md5o) { throw "el video NO es identico ($md5o vs $md5n)" }
    Log "Verificado: Atmos presente, duracion OK y video identico ($md5n)"

    # --- 5) Sustituir ----------------------------------------------------
    # SUSTITUCION SEGURA (29/08/2026). Aqui habia un borrar-y-renombrar: si el
    # Rename fallaba despues del Remove -por ejemplo con el handle aun sin
    # soltar-, la pelicula de la biblioteca desaparecia. Es la misma forma que
    # destruyo 'El cortador de cesped' desde Rebuild-Container ese mismo dia.
    $sw = Move-FicheroEnSitio -Nuevo $nuevo -Destino $Destino
    if ($sw.Aviso) { Log "  aviso: $($sw.Aviso)" }
    if (-not $sw.Ok) { throw $sw.Motivo }
    & $MKVPROPEDIT $Destino --add-track-statistics-tags 2>&1 | Out-Null
    Log "HECHO: el Atmos castellano ya esta en tu copia."
    $ok = $true
}
catch {
    Log "ERROR: $_"
    Log "El destino NO se ha tocado."
    if (Test-Path -LiteralPath $nuevo) { Remove-Item -LiteralPath $nuevo -Force -ErrorAction SilentlyContinue }
}
finally {
    Remove-Item -LiteralPath $ec3 -Force -ErrorAction SilentlyContinue
    Clear-JobTemps -Prefix 'audio' -Tmp $Tmp -BigTmp $BigTmp
    Exit-PipelineLock $LockFile
}
if ($ok) {
    Log "Siguiente paso: 'python audio_plan.py' la reincorpora sola al plan (la exclusion se levanta al detectar Atmos)."
}
exit $(if ($ok) { 0 } else { 1 })
