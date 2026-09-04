<#
============================================================================
 reconstruir-contenedor.ps1  -  Prueba del arreglo de la pantalla negra
============================================================================
 Reconstruye el contenedor de una pelicula (extraer con mkvextract + volver a
 muxear con mkvmerge) DEJANDO EL ORIGINAL INTACTO, para poder probar en la TV
 si el fichero reconstruido si se reproduce.

 POR QUE: cuatro peliculas dieron pantalla negra en Direct Play en la Samsung de
 2024 (31/07/2026) y esta reconstruccion las arreglo 4 de 4. La causa raiz nunca
 se encontro; la unica deduccion solida es que el defecto esta en la
 TEMPORIZACION que escribe el muxer de ffmpeg, porque un remux normal (que
 conserva timestamps) tambien falla y extraer+reconstruir (que los DESCARTA y los
 regenera desde el framerate) si funciona.

 El 28/08/2026 aparecio el mismo sintoma en la QN93A, que hasta entonces se creia
 no afectada.

 SE CONSERVA EL ORIGINAL, y no es un detalle: la vez anterior se borraron las
 cuatro peliculas afectadas y por eso el caso sigue abierto sin poder comparar
 original contra reconstruido. El resultado se deja al lado, con el sufijo
 [RECONSTRUIDO], para poder elegir uno u otro en Plex y compararlos.

 NO DUPLICA CODIGO: la funcion Rebuild-Container se extrae de encode.ps1 con el
 parser de PowerShell, asi que si alli cambia, esto la sigue. encode.ps1 no se
 puede dot-sourcear (tiene parametros obligatorios y se ejecutaria entero).

 Uso:
   pwsh -File C:\scripts\reconstruir-contenedor.ps1 -DryRun
   pwsh -File C:\scripts\reconstruir-contenedor.ps1
   pwsh -File C:\scripts\reconstruir-contenedor.ps1 -Ficheros 'E:\...\peli.mkv'
============================================================================
#>
param(
    [string[]]$Ficheros = @(
        'E:\Peques\¡Rompe Ralph! (2012)\¡Rompe Ralph! (2012) 2160p EAC3⁄Atmos.mkv',
        'E:\Peques\Policán (2025)\Policán (2025) 2160p EAC3⁄Atmos.mkv'
    ),
    [string]$Sufijo = ' [RECONSTRUIDO]',
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# $FFPROBE, $MKVMERGE y $MKVEXTRACT los da mediabox-paths.ps1, que se carga
# unas lineas mas abajo (31/08/2026: estaban copiados aqui a mano).
foreach ($lib in @('C:\scripts\pipeline-lock.ps1','C:\scripts\atmos-lib.ps1','C:\scripts\mediabox-paths.ps1')) {
    if (Test-Path -LiteralPath $lib) { . $lib } else { Write-Host "ERROR: falta $lib"; exit 1 }
}
$BigTmp = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { 'G:\MediaTmp' }
# Temp de ESTADO y lock. Bajados aqui el 02/09/2026: salen de mediabox-paths.ps1
# y antes se fijaban ARRIBA del dot-source, o sea con la libreria sin cargar.
$Tmp        = if ($MediaBoxTmp) { $MediaBoxTmp } else { 'C:\Media\tmp' }
$LockFile   = Join-Path $Tmp 'pipeline.lock'

$LogFile = "C:\Media\encode_logs\reconstruir-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
function Log($m) {
    $s = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $s; Add-Content -LiteralPath $LogFile -Value $s
}

# Rebuild-Container viene de atmos-lib.ps1, que ya se ha cargado arriba
# (31/08/2026). Antes se sacaba de encode.ps1 con el parser -doce lineas
# repetidas en cuatro scripts- porque encode.ps1 tiene parametros obligatorios
# y dot-sourcearlo lo ejecutaria entero.
if (-not (Get-Command Rebuild-Container -ErrorAction SilentlyContinue)) {
    Log "ERROR: atmos-lib.ps1 no trae Rebuild-Container."; exit 1
}

function Resumen([string]$f) {
    $j = (& $FFPROBE -v error -show_entries "stream=index,codec_type,codec_name" -of json -- $f 2>$null) | Out-String
    try { $s = @((ConvertFrom-Json $j).streams) } catch { return $null }
    $d = (& $FFPROBE -v error -show_entries format=duration -of csv=p=0 -- $f 2>$null) | Out-String
    return [pscustomobject]@{
        Pistas = $s.Count
        Video  = @($s | Where-Object { $_.codec_type -eq 'video' }).Count
        Audio  = @($s | Where-Object { $_.codec_type -eq 'audio' }).Count
        Subs   = @($s | Where-Object { $_.codec_type -eq 'subtitle' }).Count
        Dur    = (ConvertTo-DoubleInv $d.Trim())
        Bytes  = (Get-Item -LiteralPath $f).Length
    }
}

$hechos = @()
foreach ($src in $Ficheros) {
    if (-not (Test-Path -LiteralPath $src)) { Log "NO EXISTE: $src"; continue }
    $dir  = [System.IO.Path]::GetDirectoryName($src)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $dst  = Join-Path $dir ($base + $Sufijo + '.mkv')

    Log ""
    Log "=== $([System.IO.Path]::GetFileName($src))"
    $antes = Resumen $src
    Log ("    original: {0:N2} GiB | {1} pistas ({2}v {3}a {4}s) | {5:N1}s" -f `
         ($antes.Bytes/1GB), $antes.Pistas, $antes.Video, $antes.Audio, $antes.Subs, $antes.Dur)
    if (Test-Path -LiteralPath $dst) { Log "    ya existe la reconstruida, la salto."; continue }
    if ($DryRun) { Log "    DRY-RUN: se crearia $([System.IO.Path]::GetFileName($dst))"; continue }

    # El lock: la reconstruccion usa BigTmp y los barridos de los otros pipelines
    # se llevarian sus temporales por delante.
    if (-not (Enter-PipelineLock $LockFile)) { Log "    otro pipeline trabajando; lo dejo para luego."; continue }
    try {
        Log "    copiando (el original NO se toca)..."
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        Log "    reconstruyendo el contenedor sobre la copia..."
        $ok = Rebuild-Container -File $dst -OnProgress { param($p) if ($p -in 25,50,75) { Write-Host "      $p%" } }
        if (-not $ok) { throw "Rebuild-Container devolvio false" }

        $desp = Resumen $dst
        if (-not $desp) { throw "la reconstruida no se puede sondear" }
        if ($desp.Pistas -ne $antes.Pistas) { throw "pistas: $($desp.Pistas) vs $($antes.Pistas)" }
        if ([math]::Abs($desp.Dur - $antes.Dur) -gt 1.0) { throw "duracion: $($desp.Dur) vs $($antes.Dur)" }
        Log ("    OK -> {0:N2} GiB | {1} pistas | {2:N1}s" -f ($desp.Bytes/1GB), $desp.Pistas, $desp.Dur)
        $hechos += $dst
    } catch {
        Log "    FALLO: $_"
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
    } finally {
        Clear-JobTemps -Prefix 'audio' -Tmp $Tmp -BigTmp $BigTmp
        Exit-PipelineLock $LockFile
    }
}

Log ""
if ($hechos.Count) {
    Log "LISTO. Reconstruidas $($hechos.Count):"
    foreach ($h in $hechos) { Log "   $h" }
    Log ""
    Log "Ahora en Plex apareceran DOS versiones de cada pelicula."
    Log "Reproduce la marcada$Sufijo en la TV:"
    Log "  - si va -> el arreglo funciona tambien en la QN93A; se queda esa y se borra la otra."
    Log "  - si NO va -> NO BORRES NINGUNA: es la primera vez que se puede comparar"
    Log "    original contra reconstruido, y eso es lo que falta para cerrar el caso."
} else {
    Log "No se ha reconstruido nada."
}
