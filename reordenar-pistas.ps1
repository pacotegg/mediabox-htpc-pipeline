<#
============================================================================
 reordenar-pistas.ps1  -  Pone el castellano como PRIMERA pista de audio
============================================================================
 POR QUE: este cliente de Plex solo hace Direct Play de la PRIMERA pista de
 audio. Elegir cualquier otra fuerza transcodificacion, y en 4K eso deja la app
 colgada con pantalla negra. Lo dice el log sin rodeos:

     MDE: selected audio stream is not the first audio stream
          and direct play [is not allowed]

 Confirmado el 28/08/2026 en tres peliculas (Dracula de Bram Stoker, Jurassic
 Park, El reino de los cielos): en castellano transcodifica, en ingles no, y la
 unica diferencia es el ORDEN. LA BANDERA 'default' NO BASTA.

 SE USA UN REMUX NORMAL de mkvmerge, no extract+merge. Es importante: el remux
 CONSERVA los timestamps, mientras que extraer y volver a muxear los REGENERA
 desde el framerate declarado, y eso corrompe los ficheros cuyo framerate no
 coincide con el real (medido en 'Informe Robinson S04E06': 50 fps declarados
 contra 25 reales, y la reconstruccion dejaba el video a doble velocidad).

 NO SE BORRA NADA HASTA VERIFICAR: se escribe al lado, se comprueba, y solo
 entonces se sustituye.

 Uso:
   pwsh -File C:\scripts\reordenar-pistas.ps1 -DryRun
   pwsh -File C:\scripts\reordenar-pistas.ps1 -MaxFiles 5
   pwsh -File C:\scripts\reordenar-pistas.ps1
============================================================================
#>
param(
    [int]$MaxFiles  = 0,
    [int]$BatchSize = 25,
    [switch]$DryRun,
    [string]$Lista     = 'C:\scripts\orden_pistas.json',
    [string]$StateFile = 'C:\scripts\reordenar_estado.json'
)

$ErrorActionPreference = 'Continue'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# $FFPROBE, $MKVMERGE los da mediabox-paths.ps1 (31/08/2026: estaban copiados aqui).
foreach ($lib in @('C:\scripts\pipeline-lock.ps1','C:\scripts\atmos-lib.ps1','C:\scripts\mediabox-paths.ps1')) {
    if (Test-Path -LiteralPath $lib) { . $lib } else { Write-Host "ERROR: falta $lib"; exit 1 }
}
$BigTmp = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { 'G:\MediaTmp' }
# Temp de ESTADO y lock. Bajados aqui el 02/09/2026: salen de mediabox-paths.ps1
# y antes se fijaban ARRIBA del dot-source, o sea con la libreria sin cargar.
$Tmp      = if ($MediaBoxTmp) { $MediaBoxTmp } else { 'C:\Media\tmp' }
$LockFile = Join-Path $Tmp 'pipeline.lock'

$LogFile = "C:\Media\encode_logs\reordenar-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
function Log($m) {
    $s = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $s; Add-Content -LiteralPath $LogFile -Value $s
}
$ES = @('es','spa')

# SIN '--' (17/09/2026). mkvmerge no conoce el separador '--': en modo
# identificacion lo rechazaba ("no esta permitido para el modo de
# identificacion") y devolvia un JSON sin 'tracks', y el script lo leia como
# "sin pista en castellano". En modo mezcla intentaba abrir un fichero llamado
# '--'. Resultado: las 182 de agosto y las 232 de hoy quedaron SALTADAS sin que
# se reordenara NI UNA. La salida se lee en UTF-8 a proposito: mkvmerge escribe
# UTF-8 y la consola es cp850, y los nombres con acentos salian rotos.
function Get-Info([string]$f) {
    $antes = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $j = (& $MKVMERGE -J $f 2>$null) | Out-String
    } finally { [Console]::OutputEncoding = $antes }
    try {
        $o = ConvertFrom-Json $j
        if (-not $o.tracks) { return $null }
        return $o
    } catch { return $null }
}
# Get-DurContenedor vive en atmos-lib.ps1 desde el 31/08/2026, pegada a
# Get-DurVideo para que no vuelvan a confundirse: esta mide por la pista MAS
# LARGA del fichero y NO sirve para verificar un remux.

if (-not (Test-Path -LiteralPath $Lista)) { Log "ERROR: no existe $Lista. Ejecuta antes escanear_orden.py."; exit 1 }
$scan = @(Get-Content -LiteralPath $Lista -Raw -Encoding UTF8 | ConvertFrom-Json)

$estado = @{}
if (Test-Path -LiteralPath $StateFile) {
    try {
        (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $estado[$_.Name] = $_.Value }
    } catch { Log "AVISO: estado ilegible, se empieza de cero." }
}
function Save-Estado {
    # Envoltorio fino: el cuerpo vive en atmos-lib.ps1 desde el 31/08/2026.
    # Habia CUATRO copias de esta linea y ya habian divergido en -Depth, que
    # NO es cosmetico: ConvertTo-Json no avisa al pasarse de profundidad,
    # TRUNCA Y SIGUE, y lo que se relee al arrancar parece un estado bueno.
    Save-EstadoDriver -Estado $estado -Fichero $StateFile
}

# Solo las que tienen castellano y NO esta el primero. Y solo MKV: reordenar un
# mp4 obligaria a cambiarle el contenedor, que es otra decision.
$cola = @($scan | Where-Object {
    $null -ne $_.pos_es -and $_.pos_es -ne 0 -and
    # El CONTENEDOR, no la extension: hay '.mkv' que son MP4 por dentro y
    # mkvmerge no los puede reordenar (ver Test-EsMatroska en atmos-lib.ps1).
    (Test-EsMatroska $_.path) -and
    $estado[$_.path] -ne 'ok' -and (-not "$($estado[$_.path])".StartsWith('SALTADA:')) -and
    (Test-Path -LiteralPath $_.path)
})
if ($MaxFiles -gt 0 -and $cola.Count -gt $MaxFiles) { $cola = $cola[0..($MaxFiles-1)] }

Log ("A reordenar: {0} ficheros." -f $cola.Count)
if ($DryRun) {
    $n = 0
    foreach ($x in $cola) {
        $n++
        if ($n -le 20) { Log ("  {0,4}. pos_es={1} [{2}]  {3}" -f $n, $x.pos_es, ($x.langs -join ','), [System.IO.Path]::GetFileName($x.path)) }
    }
    Log "DRY-RUN. No se toca nada."
    exit 0
}

$ok = 0; $mal = 0; $i = 0; $t0 = Get-Date
foreach ($x in $cola) {
    $i++
    $f = $x.path
    if (Test-PipelinePaused $Tmp) { Log "Pausa global activa. Paro."; break }
    Log ("[{0}/{1}] {2}" -f $i, $cola.Count, [System.IO.Path]::GetFileName($f))

    if (-not (Enter-PipelineLock $LockFile)) {
        Log "   otro pipeline trabajando; espero 60 s."
        Start-Sleep -Seconds 60
        if (-not (Enter-PipelineLock $LockFile)) { Log "   sigue ocupado, lo dejo para la proxima pasada."; continue }
    }

    # ---- DENTRO DEL LOCK: ni continue ni break hasta el Exit ----
    $motivo = ''; $bien = $false
    $tmpOut = "$f.reorden.mkv"
    $info = Get-Info $f
    if (-not $info) {
        $motivo = 'mkvmerge no puede leerlo'
    } else {
        $aud = @($info.tracks | Where-Object { $_.type -eq 'audio' })
        $pistasEs  = @($aud | Where-Object { $ES -contains ("" + $_.properties.language).ToLower() })
        if ($pistasEs.Count -eq 0) {
            $motivo = 'sin pista en castellano'
        } elseif ($aud[0].id -eq $pistasEs[0].id) {
            $motivo = 'ya estaba la primera'
        } else {
            # Orden nuevo: todo igual, pero el castellano al frente del bloque de
            # audio. El resto conserva su orden relativo.
            $idsAudio = @($pistasEs[0].id) + @($aud | Where-Object { $_.id -ne $pistasEs[0].id } | ForEach-Object { $_.id })
            $orden = @()
            $puestoAudio = $false
            foreach ($t in $info.tracks) {
                if ($t.type -eq 'audio') {
                    if (-not $puestoAudio) { $puestoAudio = $true; foreach ($id in $idsAudio) { $orden += "0:$id" } }
                } else { $orden += "0:$($t.id)" }
            }
            $antesDur = Get-DurContenedor $f
            $antesN   = $info.tracks.Count
            & $MKVMERGE --gui-mode -o $tmpOut --track-order ($orden -join ',') $f 2>&1 |
                Where-Object { $_ -match '#GUI#error' } | ForEach-Object { Log "    | $_" }

            if (-not (Test-Path -LiteralPath $tmpOut)) {
                $motivo = 'mkvmerge no produjo salida'
            } else {
                # EL SONDEO ANTES DE USARLO (31/08/2026). Aqui se leia '$ni.tracks'
                # una linea ANTES de comprobar que '$ni' no fuera $null. Hoy no
                # revienta -PowerShell sin Set-StrictMode da $null y sigue- pero la
                # comprobacion queda de adorno, y basta activar el modo estricto
                # para que el fallo salga por donde no toca.
                $ni = Get-Info $tmpOut
                if (-not $ni) { $motivo = 'la salida no se puede leer' }
                else {
                    $nd = Get-DurContenedor $tmpOut
                    $na = @($ni.tracks | Where-Object { $_.type -eq 'audio' })
                    if ($na.Count -eq 0)                          { $motivo = 'la salida no tiene ninguna pista de audio' }
                    elseif ($ni.tracks.Count -ne $antesN)         { $motivo = "pistas $($ni.tracks.Count) != $antesN" }
                    elseif ([math]::Abs($nd - $antesDur) -gt 2.0) { $motivo = "duracion $nd vs $antesDur" }
                    elseif ($ES -notcontains ("" + $na[0].properties.language).ToLower()) {
                        $motivo = "la primera pista de audio sigue siendo '$($na[0].properties.language)'"
                    } else {
                        # Todo bien: ahora si se sustituye.
                        try {
                            # SUSTITUCION SEGURA (29/08/2026): ver Move-FicheroEnSitio
                            # en atmos-lib.ps1. Aqui habia un borrar-y-renombrar, la
                            # misma forma que destruyo una pelicula ese mismo dia.
                            $sw = Move-FicheroEnSitio -Nuevo $tmpOut -Destino $f
                            if ($sw.Aviso) { Log "   aviso: $($sw.Aviso)" }
                            if (-not $sw.Ok) { throw $sw.Motivo }
                            $bien = $true
                        } catch { $motivo = "fallo al sustituir: $_" }
                    }
                }
            }
        }
    }
    if (-not $bien -and (Test-Path -LiteralPath $tmpOut)) { Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue }
    Clear-JobTemps -Prefix 'audio' -Tmp $Tmp -BigTmp $BigTmp
    Exit-PipelineLock $LockFile
    # -------------------------------------------------------------

    if ($bien) {
        $ok++; $estado[$f] = 'ok'; Log "   OK - castellano ya es la primera"
    } elseif ($motivo -in @('ya estaba la primera','sin pista en castellano')) {
        $estado[$f] = "SALTADA: $motivo"; Log "   SALTADA: $motivo"
    } else {
        $mal++; $estado[$f] = "fallo: $motivo"; Log "   FALLO: $motivo (el original NO se ha tocado)"
    }
    Save-Estado

    if (($i % $BatchSize) -eq 0) {
        $min = ((Get-Date) - $t0).TotalMinutes
        Log ("--- LOTE: {0} ok, {1} fallos, {2:N1} min ({3:N0} s/fichero) ---" -f $ok, $mal, $min, ($min*60/$i))
    }
}
$min = ((Get-Date) - $t0).TotalMinutes
Log ("TOTAL: {0} reordenadas, {1} fallos, {2:N1} min." -f $ok, $mal, $min)
