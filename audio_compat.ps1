<#
============================================================================
 audio_compat.ps1  -  Convierte a un codec que la TV SI decodifica
============================================================================
 PARA QUE: con Direct Play forzado en el cliente de Plex ya no hay red de
 seguridad. Una pista con un codec que el televisor no entienda se queda MUDA
 para siempre y sin aviso -no hay transcodificacion que la salve-. El barrido
 del 29/08/2026 sobre los 5.452 ficheros de la biblioteca encontro 11:

     10 x Opus 2.0   The Booth at the End (S01-S02)
      1 x DTS-HD MA  El maquinista (2004)

 POR QUE NO SIRVE audio_recap.ps1, que ya hace este mismo baile:
 su verificacion exige que la salida ENCOJA ("no ha encogido"), y con razon,
 porque alli el objetivo es recuperar espacio. Aqui el objetivo es otro y el
 fichero PUEDE crecer de forma legitima: un Opus estereo de ~128k convertido a
 DD+ sale mas gordo. Forzar aquella premisa habria rechazado los 10 episodios.
 Lo que sigue en pie es lo demas: duracion de video, pistas, canales e idioma.

 NO se pasa por C:\Media\audio_queue a proposito: eso copiaria 6,4 GB a C: para
 nada. Se llama al motor con la ruta de E: directamente, igual que audio_recap.

 EL MOTOR YA SABE HACERLO: audio_encode.ps1 manda DTS, FLAC, PCM y Opus por la
 ruta de deew/DEE (Get-DdpBitrateForLossy dimensiona sobre el origen para no
 gastar 256k en transportar un Opus de 128k). Aqui solo se le dice QUE fichero,
 que pista sobra y cual manda.

 AQUI NO SE BORRA NADA, PUNTO. El original se APARTA a E:\_originales_compat en
 vez de borrarse: es la misma unidad, o sea un renombrado instantaneo y sin
 copiar un solo byte, y esa carpeta no la escanea ninguna biblioteca de Plex
 (las bibliotecas apuntan a Peliculas\, Series\, ... no a la raiz), asi que
 tampoco aparecen duplicados. Son ~6,4 GB en total sobre 1,1 TB libres.
 Cuando la conversion este comprobada en la TV, esa carpeta se puede vaciar de
 una vez; mientras tanto, cualquier sorpresa tiene vuelta atras.

 Uso:
   pwsh -File C:\scripts\audio_compat.ps1 -DryRun
   pwsh -File C:\scripts\audio_compat.ps1
============================================================================
#>
param(
    [int]$MaxFiles = 0,
    [switch]$DryRun,
    [string]$Lista     = 'C:\scripts\audio_compat_lista.json',
    [string]$StateFile = 'C:\scripts\audio_compat_estado.json'
)

$ErrorActionPreference = 'Continue'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# $FFPROBE, $MKVPROPEDIT los da mediabox-paths.ps1 (31/08/2026: estaban copiados aqui).
$PsExe       = (Get-Process -Id $PID).Path
$Encoder     = 'C:\scripts\atmosenc\audio_encode.ps1'
$Done        = 'C:\Media\audio_done'

foreach ($lib in @('C:\scripts\pipeline-lock.ps1','C:\scripts\atmos-lib.ps1','C:\scripts\mediabox-paths.ps1')) {
    if (Test-Path -LiteralPath $lib) { . $lib } else { Write-Host "ERROR: falta $lib"; exit 1 }
}
$BigTmp = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { 'G:\MediaTmp' }
# Temp de ESTADO y lock. Bajados aqui el 02/09/2026: salen de mediabox-paths.ps1
# y antes se fijaban ARRIBA del dot-source, o sea con la libreria sin cargar.
$Tmp         = if ($MediaBoxTmp) { $MediaBoxTmp } else { 'C:\Media\tmp' }
$LockFile    = Join-Path $Tmp 'pipeline.lock'
# Donde van a parar los originales. En la RAIZ de E: y no en G:, por dos razones:
# es la misma unidad que la biblioteca -o sea que apartar un fichero de 5,7 GB es
# un renombrado instantaneo en vez de una copia entre discos- y ninguna biblioteca
# de Plex escanea la raiz, asi que no salen duplicados en la interfaz.
$Apartados = 'E:\_originales_compat'
New-Item -ItemType Directory -Force -Path $Done,$Apartados | Out-Null

$LogFile = "C:\Media\encode_logs\audio_compat-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
function Log($m) {
    $s = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $s; Add-Content -LiteralPath $LogFile -Value $s
}

# Codigos ISO 639-2: MediaInfo escribe la forma terminologica (deu/fra/nld) y
# Matroska la bibliografica (ger/fre/dut). Comparar en crudo daba falsos fallos.
# Get-IsoCanon y su tabla viven en atmos-lib.ps1 desde el 29/08/2026.

# Get-DurVideo vive en atmos-lib.ps1 desde el 29/08/2026 (habia dos copias
# identicas de una funcion con tres trampas dentro).

function Test-Salida {
    param([string]$Src, [string]$Out, $Esperadas)

    if (-not (Test-Path -LiteralPath $Out)) { return 'la salida no existe' }
    $so = (Get-Item -LiteralPath $Out).Length
    $ss = (Get-Item -LiteralPath $Src).Length
    # AQUI NO SE EXIGE QUE ENCOJA (ver la cabecera). Lo que se sigue cazando es
    # una salida TRUNCADA -que tambien abre con ffprobe, o sea que el tamano no
    # es opcional- y una que se haya ido de madre.
    if ($so -lt ($ss * 0.5)) { return ("demasiado pequena: {0:N0} vs {1:N0} bytes" -f $so,$ss) }
    if ($so -gt ($ss * 1.5)) { return ("ha crecido demasiado: {0:N0} vs {1:N0} bytes" -f $so,$ss) }

    $vs = Get-DurVideo $Src; $vo = Get-DurVideo $Out
    if ($vs -gt 0 -and $vo -gt 0) {
        # 3 s: lo que se comparan son ETIQUETAS y tienen ruido propio de un
        # segundo largo. Lo que hay que cazar aqui son MINUTOS.
        if ([math]::Abs($vs - $vo) -gt 3.0) {
            return ("la duracion del VIDEO no cuadra: {0:N1}s vs {1:N1}s" -f $vs,$vo)
        }
    } else {
        return 'no se puede medir la duracion del video en alguno de los dos'
    }

    $raw = (& $FFPROBE -v error -select_streams a `
             -show_entries "stream=codec_name,channels:stream_tags=language" `
             -of json -- $Out 2>$null) | Out-String
    $got = @()
    try { $got = @((ConvertFrom-Json $raw).streams) } catch { return 'no se pueden leer las pistas de la salida' }
    if ($got.Count -ne $Esperadas.Count) {
        return ("pistas de audio: {0} en la salida, {1} esperadas" -f $got.Count, $Esperadas.Count)
    }
    for ($i = 0; $i -lt $got.Count; $i++) {
        $e = $Esperadas[$i]
        $gl = "$($got[$i].tags.language)"; if (-not $gl) { $gl = 'und' }
        if ([int]$got[$i].channels -ne [int]$e.ch) {
            return ("a:{0} canales {1} != {2}" -f $i, $got[$i].channels, $e.ch)
        }
        if ((Get-IsoCanon $gl) -ne (Get-IsoCanon $e.lang) -and $e.lang -ne 'und') {
            return ("a:{0} idioma '{1}' != '{2}'" -f $i, $gl, $e.lang)
        }
        # LA RAZON DE SER DE TODO ESTO: que no quede un codec que la TV no sepa
        # decodificar. Si sigue ahi, el trabajo no ha servido de nada.
        if ("$($got[$i].codec_name)" -notin @('ac3','eac3','aac','mp3')) {
            return ("a:{0} sigue en un codec no nativo: {1}" -f $i, $got[$i].codec_name)
        }
    }
    return ''
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

$cola = @($todos | Where-Object { $estado[$_.path] -ne 'ok' -and (Test-Path -LiteralPath $_.path) })
if ($MaxFiles -gt 0 -and $cola.Count -gt $MaxFiles) { $cola = $cola[0..($MaxFiles-1)] }

Log ("Compatibilidad: {0} en la lista, {1} por hacer." -f $todos.Count, $cola.Count)
if ($DryRun) {
    foreach ($x in $cola) {
        $dl = @($x.tracks | Where-Object { $_.drop } | ForEach-Object { $_.i })
        $d  = if ($dl.Count) { ($dl -join ',') } else { '-' }
        Log ("  {0}  | descarta a:{1} | default a:{2}" -f [System.IO.Path]::GetFileName($x.path), $d, $x.default_audio)
        foreach ($t in $x.tracks) { Log ("      a:{0} {1} {2}ch [{3}]{4}" -f $t.i,$t.codec,$t.ch,$t.lang, $(if ($t.drop) {' <- DESCARTA'} else {''})) }
    }
    Log "DRY-RUN. No se toca nada."
    exit 0
}

$ok = 0; $mal = 0; $i = 0; $t0 = Get-Date
foreach ($x in $cola) {
    $i++
    $src = $x.path
    if (Test-PipelinePaused $Tmp) { Log "Pausa global activa. Paro."; break }
    Log ("[{0}/{1}] {2}" -f $i, $cola.Count, [System.IO.Path]::GetFileName($src))

    if (-not (Enter-PipelineLock $LockFile)) {
        Log "   otro pipeline trabajando; espero 60 s."
        Start-Sleep -Seconds 60
        if (-not (Enter-PipelineLock $LockFile)) { Log "   sigue ocupado, lo dejo para la proxima pasada."; continue }
    }

    # ---- DENTRO DEL LOCK: ni continue ni break hasta el Exit ----
    $motivo = ''; $bien = $false; $grave = $false
    $out = Join-Path $Done ([System.IO.Path]::GetFileName($src))
    $drops = @($x.tracks | Where-Object { $_.drop } | ForEach-Object { [int]$_.i })
    $vivas = @($x.tracks | Where-Object { -not $_.drop })

    $argsEnc = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Encoder,$src)
    # Los arrays van en UN SOLO TOKEN separado por comas: sueltos, el hijo liga el
    # primero al parametro y deja el resto huerfano.
    if ($drops.Count)                { $argsEnc += @('-DropTracks', ($drops -join ',')) }
    if ($null -ne $x.default_audio)  { $argsEnc += @('-DefaultAudio', "$($x.default_audio)") }
    if ($null -ne $x.default_sub)    { $argsEnc += @('-DefaultSub',   "$($x.default_sub)") }

    $salidaEnc = & $PsExe @argsEnc 2>&1
    $rc = $LASTEXITCODE
    $salidaEnc | ForEach-Object { Add-Content -LiteralPath $LogFile -Value "    | $_" }

    if ($rc -eq 75) {
        $motivo = 'disco lleno (exit 75)'
    } elseif ($rc -ne 0) {
        $motivo = "audio_encode.ps1 devolvio $rc"
    } else {
        $motivo = Test-Salida -Src $src -Out $out -Esperadas $vivas
        if (-not $motivo) {
            # EL CAMBIAZO, SIN BORRAR NADA. Orden: dejar la copia buena AL LADO ->
            # APARTAR el original -> renombrar la copia. Si el Rename fallara, el
            # original sigue existiendo en la carpeta de apartados y el log dice
            # exactamente donde: se recupera con un mover a mano. En ningun paso
            # hay un momento en que el fichero no exista en algun sitio.
            $nuevo = [System.IO.Path]::ChangeExtension($src, '.compat.mkv')
            $apart = Join-Path $Apartados ([System.IO.Path]::GetFileName($src))
            try {
                Copy-Item -LiteralPath $out -Destination $nuevo -Force -ErrorAction Stop
                # Misma unidad: apartar es un renombrado, no una copia de 5,7 GB.
                # Se usa Move-FicheroEnSitio para que la sustitucion siga las
                # mismas reglas que el resto del repositorio (atmos-lib.ps1), y
                # DESPUES se aparta el original a la carpeta de apartados.
                # MinRatio 0: aqui el fichero puede crecer o encoger a proposito
                # y el tamanyo ya lo ha comprobado Test-Salida.
                Move-Item -LiteralPath $src -Destination $apart -ErrorAction Stop
                $sw = Move-FicheroEnSitio -Nuevo $nuevo -Destino $src -MinRatio 0
                if (-not $sw.Ok) {
                    # Deshacer: el original vuelve de la carpeta de apartados.
                    Move-Item -LiteralPath $apart -Destination $src -ErrorAction SilentlyContinue
                    throw $sw.Motivo
                }
                $bien = $true
            } catch {
                $motivo = "fallo al sustituir: $_"
                if (-not (Test-Path -LiteralPath $src)) {
                    $grave = $true
                    $motivo += " -- el original esta APARTADO en: $apart"
                }
                # LA COPIA AL LADO HAY QUE RETIRARLA (31/08/2026). '$nuevo' vive
                # JUNTO A LA PELICULA, dentro de la biblioteca que escanea Plex, y
                # no lo alcanza ningun barrido: $PipelineTempPatterns solo mira en
                # $Tmp y $BigTmp, y esto no esta en ninguno de los dos. Dejarlo ahi
                # es un duplicado de tamanyo completo que aparece en la interfaz.
                #
                # SOLO SI EL ORIGINAL HA VUELTO. Si el deshacer tambien fallo, esta
                # copia puede ser lo unico bueno que queda: entonces se queda donde
                # esta y el caso ya va marcado como GRAVE para mirarlo a mano.
                if ((-not $grave) -and (Test-Path -LiteralPath $nuevo)) {
                    Remove-Item -LiteralPath $nuevo -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($bien) {
        # El sidecar de MediaInfo se queda declarando el codec VIEJO y la proxima
        # auditoria volveria a listar la pelicula. Se APARTA, no se borra;
        # tinyMediaManager lo regenera solo.
        #
        # OJO CON ChangeExtension($src, $null): en PowerShell el $null llega como
        # cadena vacia y devuelve "Peli (2004)." -CON PUNTO FINAL-, o sea
        # "Peli (2004).-mediainfo.xml", que no existe y no se apartaria nunca.
        # Es la misma trampa que ya mordio en la reconstruccion de encode.ps1.
        $dir  = [System.IO.Path]::GetDirectoryName($src)
        $side = Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($src) + '-mediainfo.xml')
        if (Test-Path -LiteralPath $side) {
            Move-Item -LiteralPath $side -Destination (Join-Path $Apartados ([System.IO.Path]::GetFileName($side))) -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
    Clear-JobTemps -Prefix 'audio' -Tmp $Tmp -BigTmp $BigTmp
    Exit-PipelineLock $LockFile
    # -------------------------------------------------------------

    if ($bien) {
        $ok++; $estado[$src] = 'ok'; Log "   OK"
    } elseif ($grave) {
        $mal++; $estado[$src] = "GRAVE: $motivo"; Log "   GRAVE: $motivo  <-- MIRAR A MANO"
    } else {
        $mal++; $estado[$src] = "fallo: $motivo"; Log "   FALLO: $motivo (el original NO se ha tocado)"
    }
    Save-Estado
}
$min = ((Get-Date) - $t0).TotalMinutes
Log ("TOTAL: {0} convertidas, {1} fallos, {2:N1} min." -f $ok, $mal, $min)
