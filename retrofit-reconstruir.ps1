<#
============================================================================
 retrofit-reconstruir.ps1  -  Reconstruye el contenedor de lo ya procesado
============================================================================
 audio_recap.ps1 remuxeo 648 peliculas con ffmpeg ANTES de que audio_encode.ps1
 aprendiera a reconstruir el contenedor (28/08/2026, 22:16). Un MKV muxeado por
 ffmpeg puede dar PANTALLA NEGRA en Direct Play en las Samsung, con Plex
 informando "playing" tan tranquilo: el que falla es el decodificador del
 televisor, asi que no hay error en ningun log.

 Demostrado ese mismo dia con un A/B/A en la QN93A, las tres veces Direct Play:
     reconstruido -> va | ORIGINAL -> pantalla negra | reconstruido -> va

 Esto pasa esas 648 por la misma reconstruccion (extraer con mkvextract y volver
 a muxear con mkvmerge). NO recodifica: los streams quedan intactos, solo cambia
 como se construye el contenedor. ~40 s por pelicula.

 NO entran las que fueron por mkvpropedit (solo cambio de bandera): esas nunca se
 remuxearon, asi que su contenedor es el que ya tenian.

 Reanudable: lleva su propio registro de estado.

 Uso:
   pwsh -File C:\scripts\retrofit-reconstruir.ps1 -DryRun
   pwsh -File C:\scripts\retrofit-reconstruir.ps1 -MaxFiles 5
   pwsh -File C:\scripts\retrofit-reconstruir.ps1
============================================================================
#>
param(
    [int]$MaxFiles  = 0,
    [int]$BatchSize = 25,
    [switch]$DryRun,
    [string]$Lista     = 'C:\scripts\retrofit_lista.json',
    [string]$StateFile = 'C:\scripts\retrofit_estado.json'
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

$LogFile = "C:\Media\encode_logs\retrofit-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
function Log($m) {
    $s = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $s; Add-Content -LiteralPath $LogFile -Value $s
}

# Rebuild-Container viene de atmos-lib.ps1, que ya se ha cargado arriba
# (31/08/2026). Antes se sacaba de encode.ps1 con el parser.
#
# ESTO ARREGLA UNA TRAMPA REAL: este script carga la funcion en memoria al
# arrancar, asi que mientras vivia en encode.ps1 cada arreglo obligaba a pararlo
# y relanzarlo -y el 29/08/2026 se dio por bueno un pase que estaba corriendo
# con la version vieja-. Sigue habiendo que relanzarlo para coger cambios, pero
# ahora basta con mirar un solo fichero para saber que version lleva.
if (-not (Get-Command Rebuild-Container -ErrorAction SilentlyContinue)) {
    Log "ERROR: atmos-lib.ps1 no trae Rebuild-Container."; exit 1
}

function Resumen([string]$f) {
    $j = (& $FFPROBE -v error -show_entries "stream=index,codec_type" -of json -- $f 2>$null) | Out-String
    try { $s = @((ConvertFrom-Json $j).streams) } catch { return $null }
    $d = (& $FFPROBE -v error -show_entries format=duration -of csv=p=0 -- $f 2>$null) | Out-String
    return [pscustomobject]@{ N = $s.Count; Dur = (ConvertTo-DoubleInv $d.Trim()); Bytes = (Get-Item -LiteralPath $f).Length }
}

if (-not (Test-Path -LiteralPath $Lista)) { Log "ERROR: no existe $Lista"; exit 1 }
$todos = @(Get-Content -LiteralPath $Lista -Raw -Encoding UTF8 | ConvertFrom-Json)

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

# 'SALTADA:' SE EXCLUYE IGUAL QUE 'ok' (31/08/2026). Sin esto, un fichero que no
# se puede reconstruir NUNCA -un .mp4- volvia a la cola en cada pasada para
# fallar exactamente igual, para siempre. El diagnostico ya estaba escrito unas
# lineas mas abajo ("se reintentaban en cada pasada sin llegar nunca a ninguna
# parte") y se le anyadio la rama que lo detecta, pero el resultado se seguia
# guardando como 'fallo:', que es justo lo que este filtro vuelve a coger.
# Mismo criterio y mismo prefijo que audio_recap.ps1, donde si esta completo.
$cola = @($todos | Where-Object {
    $estado[$_] -ne 'ok' -and (-not "$($estado[$_])".StartsWith('SALTADA:')) -and (Test-Path -LiteralPath $_)
})
if ($MaxFiles -gt 0 -and $cola.Count -gt $MaxFiles) { $cola = $cola[0..($MaxFiles-1)] }

Log ("Retrofit: {0} en la lista, {1} por hacer." -f $todos.Count, $cola.Count)
if ($DryRun) {
    $i = 0
    foreach ($f in $cola) { $i++; if ($i -le 15) { Log ("  {0,4}. {1}" -f $i, [System.IO.Path]::GetFileName($f)) } }
    Log "DRY-RUN. No se toca nada."
    exit 0
}

$ok = 0; $mal = 0; $i = 0; $t0 = Get-Date
foreach ($f in $cola) {
    $i++
    if (Test-PipelinePaused $Tmp) { Log "Pausa global activa. Paro."; break }
    Log ("[{0}/{1}] {2}" -f $i, $cola.Count, [System.IO.Path]::GetFileName($f))

    if (-not (Enter-PipelineLock $LockFile)) {
        Log "   otro pipeline trabajando; espero 60 s."
        Start-Sleep -Seconds 60
        if (-not (Enter-PipelineLock $LockFile)) { Log "   sigue ocupado, lo dejo para la proxima pasada."; continue }
    }

    # ---- DENTRO DEL LOCK: ni continue ni break hasta el Exit ----
    $res    = $false
    $motivo = ''
    $antes  = $null
    # Fallo DEL FICHERO, no del trabajo: reintentarlo daria siempre lo mismo.
    $noReintentar = $false

    # SOLO MKV. La reconstruccion es extraer con mkvextract y volver a muxear con
    # mkvmerge, y eso vive en el mundo Matroska: sobre un .mp4 los codec_id que
    # devuelve mkvmerge no son los V_/A_ de Matroska y no hay extension que
    # asignarles. Fallaban 4 ficheros con "codec_id sin extension conocida:"
    # -vacio- y se reintentaban en cada pasada sin llegar nunca a ninguna parte.
    # EL CONTENEDOR, NO LA EXTENSION (01/09/2026). Aqui se preguntaba si el nombre
    # termina en '.mkv', y en esta biblioteca hay CUATRO ficheros '.mkv' que son
    # MP4 por dentro y se reproducen igual de bien. A esos, mkvpropedit/mkvextract
    # no les puede hacer nada. Test-EsMatroska (atmos-lib.ps1) mira la firma EBML.
    if (-not (Test-EsMatroska $f)) {
        $motivo = 'no es Matroska por dentro: la reconstruccion solo aplica a Matroska'
        $noReintentar = $true
    }
    else {
        $antes = Resumen $f
        if (-not $antes) {
            $motivo = 'no se puede sondear el original'
        }
        else {
            $global:UltimoMotivoRebuild = ''
            $res = Rebuild-Container -File $f
            if (-not $res) {
                # El motivo REAL, no un generico: Rebuild-Container solo devuelve
                # $true/$false y el porque se quedaba unicamente en el log.
                $motivo = if ($global:UltimoMotivoRebuild) { $global:UltimoMotivoRebuild }
                          else { 'Rebuild-Container devolvio false (el fichero se conserva tal cual)' }
            }
            else {
                $desp = Resumen $f
                if (-not $desp) { $motivo = 'la reconstruida no se puede sondear'; $res = $false }
                # Se descuentan las pistas VACIAS y las portadas incrustadas que la
                # reconstruccion aparta a proposito (ver Rebuild-Container): sin esto,
                # un fichero con un PGS sin paquetes se reconstruia BIEN y aun asi se
                # marcaba como fallo.
                elseif ($desp.N -ne ($antes.N - [int]$global:UltimasPistasFuera)) {
                    $motivo = "pistas $($desp.N) != $($antes.N - [int]$global:UltimasPistasFuera)"; $res = $false
                }
                # LA DURACION YA NO SE COMPRUEBA AQUI (29/08/2026). Esta
                # comparaba la del CONTENEDOR con 2 s de margen, y eso rechazaba
                # reconstrucciones BUENAS: hay ficheros cuya cabecera declara mas
                # de lo que dura su pista mas larga -'This Is Spinal Tap' 9,0 s,
                # 'Adicto' 8,5 s- y la reconstruccion lo que hace es corregirla.
                # Los dos salian marcados como fallo con el fichero ya sustituido
                # y perfecto.
                #
                # Rebuild-Container lo comprueba mucho mejor por dentro: la
                # duracion del VIDEO -que es la que caza un reescalado de tiempo-
                # y la del contenedor contra la pista mas larga del origen. Tener
                # aqui una version peor de lo mismo solo generaba ruido.
                #
                # El recuento de pistas SI se queda: es por una via distinta
                # (ffprobe cuenta los adjuntos, mkvmerge no) y por eso fue lo
                # unico que destapo que la reconstruccion perdia los adjuntos.
            }
        }
    }
    Clear-JobTemps -Prefix 'audio' -Tmp $Tmp -BigTmp $BigTmp
    Exit-PipelineLock $LockFile
    # -------------------------------------------------------------

    if ($res) {
        $ok++; $estado[$f] = 'ok'
        Log "   OK"
    } elseif ($noReintentar) {
        # No cuenta como fallo: el fichero esta bien, simplemente esta fuera del
        # alcance de esta herramienta. Se marca 'SALTADA:' -que el filtro de la
        # cola excluye igual que 'ok'- para que no vuelva en cada pasada, pero
        # queda a la vista en el estado.
        $estado[$f] = "SALTADA: $motivo"
        Log "   SALTADA: $motivo"
    } else {
        $mal++; $estado[$f] = "fallo: $motivo"
        # OJO: si el fallo es POSTERIOR a la reconstruccion, el fichero YA se ha
        # sustituido. Rebuild-Container solo mueve si mkvmerge produjo algo
        # valido, asi que no deberia pasar, pero si pasa hay que mirarlo a mano.
        Log "   FALLO: $motivo"
    }
    Save-Estado

    if (($i % $BatchSize) -eq 0) {
        $min = ((Get-Date) - $t0).TotalMinutes
        Log ("--- LOTE: {0} ok, {1} fallos, {2:N1} min ({3:N1} s/pelicula) ---" -f $ok, $mal, $min, ($min*60/$i))
    }
}
$min = ((Get-Date) - $t0).TotalMinutes
Log ("TOTAL: {0} reconstruidas, {1} fallos, {2:N1} min." -f $ok, $mal, $min)
