<#
============================================================================
 audio_recap.ps1  -  Aplica el tope de audio a la biblioteca ya existente
============================================================================
 Lee el plan de audio_plan.py y, pelicula a pelicula:

   1. coge el pipeline.lock (compartido con video/audio/subs)
   2. llama a audio_encode.ps1 CON LA RUTA DE E: (no copia a audio_queue)
   3. VERIFICA la salida
   4. la mete en la carpeta de origen y BORRA el original
   5. limpia C:\Media\audio_done y los temporales de G:
   6. suelta el lock

 POR QUE NO PASA POR audio_queue: meter la pelicula en la cola obliga a copiar
 8-40 GB de E: a C: ANTES de empezar, y deja dos copias en C: a la vez (cola +
 audio_done). Leyendo de E: directamente, C: solo aguanta UNA salida cada vez.
 Ademas el watcher de audio puede seguir vivo: no usamos su carpeta, asi que no
 nos roba trabajo, y el lock coordina a los dos.

 EL BORRADO ES DEFINITIVO (la papelera no libera espacio en este equipo).
 Por eso no se borra nada que no haya pasado ANTES la verificacion.

 Uso:
   pwsh -File C:\scripts\audio_recap.ps1 -DryRun
   pwsh -File C:\scripts\audio_recap.ps1 -MaxFiles 15
   pwsh -File C:\scripts\audio_recap.ps1            # hasta agotar el plan
============================================================================
#>
param(
    # 0 = sin limite (agota el plan). Con un numero, procesa como mucho esos.
    [int]$MaxFiles = 0,
    # Cada cuantas peliculas se imprime resumen de lote.
    [int]$BatchSize = 15,
    # Ensena lo que haria, sin tocar un solo fichero.
    [switch]$DryRun,
    # Incluir tambien las pistas marcadas 'REVISAR:*' en el descarte. Por defecto
    # NO: esas esperan al visto bueno humano y mientras tanto se CONSERVAN.
    [switch]$IncluirRevisar,
    # Trabajos en paralelo. Hoy solo 1 (ver la nota de abajo).
    [int]$MaxParallel = 1,
    [string]$PlanFile  = 'C:\scripts\audio_plan.json',
    [string]$StateFile = 'C:\scripts\audio_recap_estado.json'
)

$ErrorActionPreference = 'Continue'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# -- PARALELISMO: NO esta implementado, y es deliberado ---------------------
# El plan lo contemplaba, pero este script BORRA ORIGINALES. Estrenar aqui una
# gestion de ranuras a la vez que se estrena el borrado es acumular dos riesgos
# nuevos en el mismo sitio. Primero se demuestra que K=1 es correcto; despues,
# si la medicion lo justifica, se paraleliza sobre algo ya probado.
# Ademas el analisis dice que este lote es de DISCO: K remuxes simultaneos sobre
# el mismo DAS compiten entre si en vez de sumarse.
if ($MaxParallel -ne 1) {
    Write-Host "AVISO: -MaxParallel $MaxParallel no esta implementado todavia. Se usa 1."
    $MaxParallel = 1
}

# $FFPROBE, $MKVPROPEDIT los da mediabox-paths.ps1 (31/08/2026: estaban copiados aqui).
$Base    = 'C:\Media'
$Done    = Join-Path $Base 'audio_done'
$Encoder = 'C:\scripts\atmosenc\audio_encode.ps1'
$PsExe   = (Get-Process -Id $PID).Path

foreach ($lib in @('C:\scripts\pipeline-lock.ps1','C:\scripts\atmos-lib.ps1','C:\scripts\mediabox-paths.ps1')) {
    if (Test-Path -LiteralPath $lib) { . $lib } else { Write-Host "ERROR: falta $lib"; exit 1 }
}
$BigTmp = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { 'G:\MediaTmp' }
# Temp de ESTADO y lock. Bajados aqui el 02/09/2026: salen de mediabox-paths.ps1
# y antes se fijaban ARRIBA del dot-source, o sea con la libreria sin cargar.
# Aqui ademas se derivaba de $Base, que era una TERCERA forma de escribirlo.
$Tmp     = if ($MediaBoxTmp) { $MediaBoxTmp } else { Join-Path $Base 'tmp' }
$LockFile= Join-Path $Tmp 'pipeline.lock'

$LogDir = Join-Path $Base 'encode_logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("audio_recap-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
function Log($m) {
    $s = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $s
    Add-Content -LiteralPath $LogFile -Value $s
}

# Get-DurContenedor vive en atmos-lib.ps1 desde el 31/08/2026, pegada a
# Get-DurVideo para que no vuelvan a confundirse: esta mide por la pista MAS
# LARGA del fichero y NO sirve para verificar un remux.

# Get-DurVideo vive en atmos-lib.ps1 desde el 29/08/2026 (habia dos copias
# identicas de una funcion con tres trampas dentro).

# ISO 639-2 tiene DOS codigos para el mismo idioma: el bibliografico (B) y el
# terminologico (T). Matroska y ffprobe usan el B ('ger', 'fre', 'dut'...) y
# MediaInfo devuelve el T ('deu', 'fra', 'nld'...). Comparar uno contra otro daba
# un falso fallo -"a:1 idioma 'ger' != 'deu'"- en 37 ficheros del plan: 26 en
# aleman, 10 en frances y 1 en checo. El fichero estaba perfecto en todos.
# Se normaliza a la forma B, que es la que acaba escrita en el contenedor.
# Get-IsoCanon y su tabla viven en atmos-lib.ps1 desde el 29/08/2026.

# ---------------------------------------------------------------------------
# VERIFICACION. Todo tiene que pasar. Devuelve '' si esta bien, o el motivo.
# ---------------------------------------------------------------------------
function Test-Salida {
    param([string]$Src, [string]$Out, $Esperadas)

    if (-not (Test-Path -LiteralPath $Out)) { return 'la salida no existe' }
    $so = (Get-Item -LiteralPath $Out).Length
    $ss = (Get-Item -LiteralPath $Src).Length
    # Una salida truncada TAMBIEN abre con ffprobe: el tamano no es opcional.
    if ($so -ge $ss)          { return ("no ha encogido ({0:N0} >= {1:N0} bytes)" -f $so,$ss) }
    if ($so -lt ($ss * 0.5))  { return ("demasiado pequena: {0:N0} vs {1:N0} bytes" -f $so,$ss) }

    # Se compara el VIDEO, no el contenedor (ver Get-DurVideo).
    $vs = Get-DurVideo $Src; $vo = Get-DurVideo $Out
    if ($vs -gt 0 -and $vo -gt 0) {
        # TOLERANCIA DE 3 s, Y NO ES LAXITUD: lo que se compara son ETIQUETAS.
        #
        # En MKV el video no trae 'stream=duration', asi que esto lee el tag
        # DURATION. El del ORIGEN lo escribio quien creara el fichero -y puede
        # estar rancio o mal contado-, mientras que el de la SALIDA lo acaba de
        # recalcular mkvpropedit sobre los paquetes reales. Comparar uno con otro
        # tiene ruido propio que no significa nada.
        #
        # Medido en 'La soga (1948)': origen 116.091 fotogramas, salida 116.067
        # -24 menos, exactamente 1,001 s a 23,976 fps- y sin embargo el MD5 del
        # video es IDENTICO y la duracion del contenedor tambien. No se perdio
        # nada; el tag del origen simplemente no era exacto.
        #
        # Lo que esta comprobacion tiene que cazar es una salida TRUNCADA, y eso
        # son minutos, no segundos. Con 3 s sigue cazandolo de sobra, y quien
        # atrapa de verdad el truncamiento es el chequeo de tamano de arriba
        # (la salida tiene que pasar del 50 % del origen).
        if ([math]::Abs($vs - $vo) -gt 3.0) {
            return ("la duracion del VIDEO no cuadra: {0:N1}s vs {1:N1}s" -f $vs,$vo)
        }
    } else {
        # Sin duracion de video en alguno de los dos: se cae al contenedor, pero
        # con la regla asimetrica que corresponde. Descartar pistas solo puede
        # ACORTARLO (nunca alargarlo), asi que se admite que la salida sea mas
        # corta y se rechaza que sea mas larga o que se quede en nada.
        $ds = Get-DurContenedor $Src; $do = Get-DurContenedor $Out
        if ($do -le 0)            { return 'la salida no declara duracion' }
        if ($do -gt ($ds + 2.0))  { return ("la salida dura MAS que el origen: {0:N1}s vs {1:N1}s" -f $ds,$do) }
        if ($do -lt ($ds * 0.98)) { return ("la salida se ha quedado corta: {0:N1}s vs {1:N1}s" -f $ds,$do) }
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
    }
    return ''
}

# ---------------------------------------------------------------------------
# UNA PELICULA. Se llama CON EL LOCK COGIDO, asi que aqui dentro NO puede haber
# continue ni break: siempre se sale por return. (Regla aprendida a golpes: un
# break entre Enter- y Exit-PipelineLock bloqueo los tres pipelines.)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# VIA RAPIDA: cuando lo UNICO que hay que cambiar son las banderas 'default'.
#
# Reescribir un contenedor de 20 GB -leerlo de E:, escribirlo en C: y devolverlo-
# para tocar un flag de cabecera no tiene ningun sentido: mkvpropedit lo hace EN
# EL SITIO y en milisegundos. Son 193 de las 612 peliculas del plan.
#
# mkvpropedit numera las pistas por tipo y EMPEZANDO EN 1: el a:0 de ffmpeg es
# 'track:a1'. Confundirlo marcaria la pista de al lado.
# ---------------------------------------------------------------------------
function Set-DisposicionesEnSitio {
    param($P)
    # Grave: aqui SIEMPRE $false -mkvpropedit trabaja en el sitio y no borra
    # nada-, pero el campo va igual. El bucle lo consulta en las dos vias, y sin
    # StrictMode una propiedad que falta devuelve $null en silencio: hoy cuela,
    # pero el dia que alguien ponga Set-StrictMode esto reventaria justo despues
    # de soltar el lock. Los dos objetos de resultado tienen la MISMA forma.
    $r = [pscustomobject]@{ Path=$P.path; Ok=$false; Motivo=''; Ahorro=0L; Segundos=0; Requeue=$false; Grave=$false; SinCambios=$false; NoReintentar=$false }
    $src = $P.path
    if (-not (Test-Path -LiteralPath $src)) { $r.Motivo = 'ya no existe'; return $r }
    # EL CONTENEDOR, NO LA EXTENSION (01/09/2026). Aqui se preguntaba si el nombre
    # termina en '.mkv', y en esta biblioteca hay CUATRO ficheros '.mkv' que son
    # MP4 por dentro y se reproducen igual de bien. A esos, mkvpropedit/mkvextract
    # no les puede hacer nada. Test-EsMatroska (atmos-lib.ps1) mira la firma EBML.
    if (-not (Test-EsMatroska $src)) {
        # mkvpropedit solo entiende Matroska. Un .mp4 exigiria remuxearlo entero
        # -~1-2 min- para cambiar UNA bandera, y no compensa.
        #
        # NO REINTENTABLE: son 85 ficheros y el resultado seria siempre el mismo.
        # Marcarlo como 'fallo' los devolvia a la cola en cada pasada para volver
        # a fallar igual. Mismo criterio que con los videos que el muxer de MKV de
        # ffmpeg rechaza.
        $r.Motivo = 'no es Matroska por dentro: mkvpropedit no aplica (habria que remuxear entero por una bandera)'
        $r.NoReintentar = $true
        return $r
    }
    $t0 = Get-Date
    $ed = @()
    foreach ($t in @($P.tracks | Where-Object { -not $_.drop })) {
        $val = if ([int]$t.i -eq [int]$P.default_audio) { 1 } else { 0 }
        $ed += @('--edit', "track:a$([int]$t.i + 1)", '--set', "flag-default=$val")
    }
    if ($null -ne $P.default_sub) {
        foreach ($s in @($P.subs)) {
            $val = if ([int]$s.i -eq [int]$P.default_sub) { 1 } else { 0 }
            $ed += @('--edit', "track:s$([int]$s.i + 1)", '--set', "flag-default=$val")
        }
    }
    # NO ES UN FALLO, Y MARCARLO COMO TAL LA CONDENABA AL BUCLE (31/08/2026).
    # Sin bandera, esto cae en el 'else' final del bucle, se guarda como
    # "fallo: nada que cambiar", y el filtro de la cola -que solo excluye 'ok' y
    # 'SALTADA:'- la vuelve a meter en la pasada siguiente para fallar igual, y
    # asi para siempre. Es exactamente el caso que ya cubren 'NoReintentar' para
    # los no-MKV y 'SinCambios' para el motor que no ve nada que hacer.
    # Aqui la buena es 'SinCambios': el fichero esta bien y sin tocar, lo que
    # pasa es que la lectura del plan no coincide con lo que hay dentro.
    if (-not $ed.Count) { $r.Motivo = 'nada que cambiar'; $r.SinCambios = $true; return $r }

    & $MKVPROPEDIT $src @ed 2>&1 | ForEach-Object { Add-Content -LiteralPath $LogFile -Value "    | $_" }
    if ($LASTEXITCODE -ne 0) { $r.Motivo = "mkvpropedit devolvio $LASTEXITCODE"; return $r }

    $r.Ok = $true
    $r.Segundos = [int]((Get-Date) - $t0).TotalSeconds
    return $r
}

function Invoke-UnaPelicula {
    param($P)

    $src = $P.path
    # Grave = el original ya no esta. Solo lo pone la ruta de fallo del cambiazo,
    # y sirve para que el bucle NO imprima "el original NO se ha tocado".
    $r = [pscustomobject]@{ Path=$src; Ok=$false; Motivo=''; Ahorro=0L; Segundos=0; Requeue=$false; Grave=$false; SinCambios=$false; NoReintentar=$false }

    if (-not (Test-Path -LiteralPath $src)) { $r.Motivo = 'ya no existe'; return $r }

    $drops = @($P.tracks | Where-Object { $_.drop -and ($IncluirRevisar -or -not "$($_.drop)".StartsWith('REVISAR')) } | ForEach-Object { [int]$_.i })
    $vivas = @($P.tracks | Where-Object { $drops -notcontains [int]$_.i })
    # Pistas confirmadas no-Atmos por el barrido: profile no vacio y sin atmos/joc.
    $force = @($vivas | Where-Object { $_.profile -and ("$($_.profile)".Trim()) -ne '' -and ("$($_.profile)" -notmatch '(?i)atmos|joc') } | ForEach-Object { [int]$_.i })

    $t0 = Get-Date
    $srcBytes = (Get-Item -LiteralPath $src).Length
    $out = Join-Path $Done ([System.IO.Path]::GetFileName($src))

    $argsEnc = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Encoder,$src)
    # LOS ARRAYS VAN SEPARADOS POR COMAS, EN UN SOLO TOKEN.
    # Pasarlos como elementos sueltos ('-DropTracks','2','3') hace que el
    # PowerShell hijo ligue el 2 al parametro y deje el 3 suelto:
    #   "A positional parameter cannot be found that accepts argument '3'."
    # Se vio en el primer arranque del piloto: 2 peliculas fallaron asi (sin
    # danyo: la verificacion impide tocar el original si el encoder no sale a 0).
    if ($drops.Count) { $argsEnc += @('-DropTracks',     ($drops -join ',')) }
    if ($force.Count) { $argsEnc += @('-ForceCapTracks', ($force -join ',')) }
    # OJO con el indice 0: es valido, asi que la comprobacion es contra $null y
    # NO un test de veracidad -un 0 es 'falso' en PowerShell y se perderia-.
    if ($null -ne $P.default_audio) { $argsEnc += @('-DefaultAudio', "$($P.default_audio)") }
    if ($null -ne $P.default_sub)   { $argsEnc += @('-DefaultSub',   "$($P.default_sub)") }
    $fixes = @($P.tracks | Where-Object { $_.fix_lang } | ForEach-Object { "$($_.i)=$($_.fix_lang)" })
    if ($fixes.Count) { $argsEnc += @('-SetLang', ($fixes -join ',')) }

    $salidaEnc = & $PsExe @argsEnc 2>&1
    $rc = $LASTEXITCODE
    $salidaEnc | ForEach-Object { Add-Content -LiteralPath $LogFile -Value "    | $_" }
    # Hay ficheros cuyo VIDEO el muxer de Matroska de ffmpeg no acepta ni siquiera
    # copiandolo tal cual ("Could not write header"). No es cosa nuestra ni del
    # audio: el mismo video se copia bien a MP4, y mkvmerge lo remuxea sin
    # rechistar. Medido sobre 353 ficheros ya procesados: 2 casos, 0,57 %.
    # A esa tasa no compensa montar una via alternativa por mkvmerge; lo que si
    # hace falta es no reintentarlos en cada pasada, que no llevaria a ninguna
    # parte, y dejar constancia para arreglarlos aparte.
    $muxRoto = @($salidaEnc | Where-Object { "$_" -match 'Could not write header' }).Count -gt 0

    if ($rc -eq 75) { $r.Motivo = 'disco lleno (exit 75)'; $r.Requeue = $true; return $r }
    if ($rc -ne 0) {
        if ($muxRoto) {
            $r.Motivo = 'el muxer MKV de ffmpeg rechaza este video (mkvmerge si puede: hay que remuxearlo aparte)'
            $r.NoReintentar = $true
        } else {
            $r.Motivo = "audio_encode.ps1 devolvio $rc"
        }
        return $r
    }

    # EL MOTOR PUEDE SALIR CON 0 Y SIN PRODUCIR NADA: es lo que hace cuando
    # decide que no hay nada que convertir ni descartar. Eso NO es un fallo de
    # verificacion -no hay salida que verificar-, sino que su lectura del fichero
    # no coincide con la del plan; el caso tipico es un bitrate que ffprobe no
    # sabe leer y MediaInfo si. Tratarlo como fallo lo condenaba a reintentarse
    # en todas las pasadas sin avanzar nunca.
    if (-not (Test-Path -LiteralPath $out)) {
        $r.Motivo = 'el motor no vio nada que hacer (su lectura no coincide con el plan)'
        $r.SinCambios = $true
        return $r
    }

    $mal = Test-Salida -Src $src -Out $out -Esperadas $vivas
    if ($mal) {
        $r.Motivo = "VERIFICACION FALLIDA: $mal"
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
        return $r
    }

    # --- El cambiazo. Orden: copiar al lado -> borrar original -> renombrar.
    # Nunca se borra el original antes de tener la sustituta ENTERA en su disco.
    # OJO: 'Split-Path -LiteralPath $x -Parent' NO VALE. -LiteralPath y -Parent
    # estan en conjuntos de parametros distintos, asi que PowerShell responde
    # "Parameter set cannot be resolved" y $dir se queda VACIO; el fallo aparece
    # tres lineas mas abajo, en el Join-Path, y disfrazado de "LiteralPath null".
    # GetDirectoryName ademas no interpreta comodines, que es justo lo que hace
    # falta con rutas que llevan corchetes.
    $dir  = [System.IO.Path]::GetDirectoryName($src)
    $nom  = [System.IO.Path]::GetFileName($src)
    $tmpN = Join-Path $dir ($nom + '.nuevo')
    try {
        Copy-Item -LiteralPath $out -Destination $tmpN -Force -ErrorAction Stop
        $a = (Get-Item -LiteralPath $tmpN).Length; $b = (Get-Item -LiteralPath $out).Length
        if ($a -ne $b) { throw "la copia a E: no cuadra ($a vs $b bytes)" }

        # SUSTITUCION SEGURA (29/08/2026): apartar el original, colocar la
        # nueva, comprobar, y solo entonces tirar el apartado. Antes era
        # borrar-y-renombrar: el catch de abajo cubria bien la ventana en la que
        # la pelicula no existe con su nombre, pero es mejor que esa ventana no
        # exista. La logica esta en Move-FicheroEnSitio (atmos-lib.ps1).
        # MinRatio 0 porque aqui la salida encoge A PROPOSITO -es todo el punto
        # del recorte- y el tamanyo ya lo ha comprobado Test-Salida.
        $sw = Move-FicheroEnSitio -Nuevo $tmpN -Destino $src -MinRatio 0
        if ($sw.Aviso) { Add-Content -LiteralPath $LogFile -Value "    | aviso: $($sw.Aviso)" }
        if (-not $sw.Ok) { throw $sw.Motivo }
    } catch {
        # OJO AL ORDEN AL LIMPIAR (28/08/2026). Aqui se llega desde DOS sitios muy
        # distintos y tratarlos igual destruia la pelicula:
        #
        #   a) fallo el Copy-Item o el cotejo de tamanyo -> el ORIGINAL SIGUE AHI.
        #      Borrar $tmpN es lo correcto: es una copia a medias.
        #   b) fallo el Rename-Item DESPUES de que el Remove-Item se llevara el
        #      original -> $tmpN ES LA PELICULA, la unica que queda en E:.
        #      Borrarla la perdia, y encima el bucle imprimia "el original NO se
        #      ha tocado", que es justo lo contrario de lo que acababa de pasar.
        #      (Mismo patron que el '[clean] salida parcial borrada' que mentia.)
        #
        # La condicion es si el original sobrevive, no si $tmpN existe.
        $r.Motivo = "fallo al sustituir: $_"
        if (Test-Path -LiteralPath $src) {
            if (Test-Path -LiteralPath $tmpN) { Remove-Item -LiteralPath $tmpN -Force -ErrorAction SilentlyContinue }
        } else {
            $r.Grave = $true
            # Ultimo intento de dejarla con su nombre bueno antes de rendirse.
            if (Test-Path -LiteralPath $tmpN) {
                try   { Rename-Item -LiteralPath $tmpN -NewName $nom -ErrorAction Stop; $r.Grave = $false }
                catch { $r.Motivo = "$_ | LA PELICULA ESTA EN: $tmpN (renombrala a '$nom')" }
            } else {
                # Ni original ni copia en E:. Queda la de audio_done, que NO se
                # borra porque ese Remove-Item vive fuera de este try.
                $r.Motivo = "$_ | ORIGINAL BORRADO y sin copia en E:. LA PELICULA ESTA EN: $out"
            }
        }
        return $r
    }

    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    # El sidecar viejo seguiria declarando los bitrates de antes, y la proxima
    # auditoria volveria a listar la pelicula. tinyMediaManager lo regenera.
    foreach ($sc in @(Get-ChildItem -LiteralPath $dir -Filter '*-mediainfo.xml' -File -ErrorAction SilentlyContinue)) {
        if ($sc.BaseName -eq ([System.IO.Path]::GetFileNameWithoutExtension($nom) + '-mediainfo')) {
            Remove-Item -LiteralPath $sc.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $r.Ok = $true
    $r.Ahorro = $srcBytes - (Get-Item -LiteralPath (Join-Path $dir $nom)).Length
    $r.Segundos = [int]((Get-Date) - $t0).TotalSeconds
    return $r
}

# ---------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $PlanFile)) { Log "ERROR: no existe $PlanFile. Ejecuta antes audio_plan.py."; exit 1 }
$plan = @(Get-Content -LiteralPath $PlanFile -Raw -Encoding UTF8 | ConvertFrom-Json)

$estado = @{}
if (Test-Path -LiteralPath $StateFile) {
    try {
        (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $estado[$_.Name] = $_.Value }
    } catch { Log "AVISO: no se pudo leer el estado, se empieza de cero." }
}
function Save-Estado {
    # Envoltorio fino: el cuerpo vive en atmos-lib.ps1 desde el 31/08/2026.
    # Habia CUATRO copias de esta linea y ya habian divergido en -Depth, que
    # NO es cosmetico: ConvertTo-Json no avisa al pasarse de profundidad,
    # TRUNCA Y SIGUE, y lo que se relee al arrancar parece un estado bueno.
    Save-EstadoDriver -Estado $estado -Fichero $StateFile
}

# Solo las que tienen algo FIRME que hacer. Las que solo traen 'REVISAR' se
# quedan fuera hasta que alguien las apruebe.
$cola = @($plan | Where-Object {
    $p = $_
    $d = @($p.tracks | Where-Object { $_.drop -and ($IncluirRevisar -or -not "$($_.drop)".StartsWith('REVISAR')) })
    $c = @($p.tracks | Where-Object { $_.cap -gt 0 })
    # 'solo_disp' tambien entra: son las que solo necesitan recolocar el
    # 'default'. Sin esto se quedarian fuera de la cola por no tener ni recorte
    # ni descarte, que es justo lo que las define.
    ($d.Count -gt 0 -or $c.Count -gt 0 -or $p.solo_disp) -and ($estado[$p.path] -ne 'ok') -and (-not "$($estado[$p.path])".StartsWith('SALTADA:'))
})
if ($MaxFiles -gt 0 -and $cola.Count -gt $MaxFiles) { $cola = $cola[0..($MaxFiles-1)] }

Log ("Plan: {0} peliculas en total, {1} por hacer en esta pasada." -f $plan.Count, $cola.Count)
Log ("Modo: {0}{1}" -f $(if($DryRun){'DRY-RUN (no toca nada)'}else{'REAL - BORRA ORIGINALES'}), $(if($IncluirRevisar){' +REVISAR'}else{''}))

if ($DryRun) {
    $n = 0
    foreach ($p in $cola) {
        $n++
        $d = @($p.tracks | Where-Object { $_.drop -and ($IncluirRevisar -or -not "$($_.drop)".StartsWith('REVISAR')) })
        $c = @($p.tracks | Where-Object { $_.cap -gt 0 })
        $via = if ($p.solo_disp) { '  [mkvpropedit en el sitio]' } else { '' }
        Log ("{0,4}. {1}{2}" -f $n, [System.IO.Path]::GetFileName($p.path), $via)
        foreach ($t in $c) { Log ("        a:{0} {1} {2}k -> DD+ {3}k" -f $t.i,$t.fmt,[int]($t.bps/1000),$t.cap) }
        foreach ($t in $d) { Log ("        a:{0} {1} [{2}] FUERA ({3})" -f $t.i,$t.fmt,$t.lang,$t.drop) }
        if ($null -ne $p.default_audio) {
            $da = @($p.tracks | Where-Object { [int]$_.i -eq [int]$p.default_audio })[0]
            Log ("        default -> a:{0} [{1}]{2}" -f $p.default_audio, $da.lang,
                 $(if ($null -ne $p.default_sub) { "   subs por defecto -> s:$($p.default_sub) (forzados es)" } else { '' }))
        }
    }
    Log "DRY-RUN terminado. No se ha tocado nada."
    exit 0
}

$hechas = 0; $fallos = 0; $sinCambios = 0; $saltadas = 0; $ahorroTotal = 0L; $segTotal = 0; $i = 0
foreach ($p in $cola) {
    $i++
    if (Test-PipelinePaused $Tmp) { Log "Pausa global activa (pipeline_paused). Paro."; break }

    Log ("[{0}/{1}] {2}" -f $i, $cola.Count, [System.IO.Path]::GetFileName($p.path))

    if (-not (Enter-PipelineLock $LockFile)) {
        Log "   otro pipeline tiene el lock; reintento en 60 s."
        Start-Sleep -Seconds 60
        if (-not (Enter-PipelineLock $LockFile)) { Log "   sigue ocupado, lo dejo para la proxima pasada."; continue }
    }

    # ---- DENTRO DEL LOCK: ni un continue ni un break hasta el Exit ----
    # Via rapida si lo unico que cambia son las banderas: mkvpropedit en el sitio.
    $res = if ($p.solo_disp) { Set-DisposicionesEnSitio -P $p } else { Invoke-UnaPelicula -P $p }
    Clear-JobTemps -Prefix 'audio' -Tmp $Tmp -BigTmp $BigTmp
    Exit-PipelineLock $LockFile
    # ------------------------------------------------------------------

    if ($res.Ok) {
        $hechas++; $ahorroTotal += $res.Ahorro; $segTotal += $res.Segundos
        $estado[$p.path] = 'ok'
        Log ("   OK en {0}s, {1:N2} GiB recuperados." -f $res.Segundos, ($res.Ahorro/1GB))
    } elseif ($res.Requeue) {
        Log "   DISCO LLENO: no se toca nada. Espero 5 min y sigo."
        Start-Sleep -Seconds 300
    } elseif ($res.NoReintentar) {
        # Fallo del fichero, no del trabajo: reintentarlo daria siempre lo mismo.
        # Se marca 'SALTADA:' -que el filtro de la cola excluye igual que 'ok'-
        # para que no vuelva en cada pasada, pero queda a la vista en el estado.
        $saltadas++
        $estado[$p.path] = "SALTADA: $($res.Motivo)"
        Log ("   SALTADA: {0}" -f $res.Motivo)
        Log  "   (el original NO se ha tocado; se puede arreglar a mano con mkvmerge)"
    } elseif ($res.SinCambios) {
        # El motor no vio nada que hacer. No es un fallo -el fichero esta bien y
        # sin tocar-, pero tampoco un exito: significa que su lectura no coincide
        # con la del plan. Se marca 'ok' PARA QUE NO SE REINTENTE en cada pasada
        # (volveria a no hacer nada), y se cuenta aparte para poder verlo.
        $sinCambios++
        $estado[$p.path] = 'ok'
        Log ("   SIN CAMBIOS: {0}" -f $res.Motivo)
    } elseif ($res.Grave) {
        # El original ya no esta: NO se puede decir "no se ha tocado". Se marca
        # aparte para que la proxima pasada no la trate como un fallo normal
        # -daria 'ya no existe' y la enterraria- y se avisa alto, que es lo que
        # toca cuando hay una pelicula fuera de su sitio.
        $fallos++; $estado[$p.path] = "GRAVE: $($res.Motivo)"
        Log  "   *** ATENCION: el original SI se ha borrado y la sustitucion no cuajo. ***"
        Log ("   {0}" -f $res.Motivo)
        Log  "   Esa pelicula NO esta en su carpeta. Colocala a mano antes de seguir."
    } else {
        $fallos++; $estado[$p.path] = "fallo: $($res.Motivo)"
        Log ("   FALLO: {0} (el original NO se ha tocado)" -f $res.Motivo)
    }
    Save-Estado

    if (($i % $BatchSize) -eq 0) {
        Log ("--- LOTE: {0} hechas, {1} fallos, {2} sin cambios, {3} saltadas, {4:N1} GiB recuperados, {5:N1} min de media ---" -f `
             $hechas, $fallos, $sinCambios, $saltadas, ($ahorroTotal/1GB), $(if($hechas){($segTotal/$hechas)/60}else{0}))
    }
}

Log ("TOTAL: {0} hechas, {1} fallos, {2} sin cambios, {3} saltadas, {4:N1} GiB recuperados." -f $hechas, $fallos, $sinCambios, $saltadas, ($ahorroTotal/1GB))
if ($hechas) { Log ("Media por pelicula: {0:N1} min" -f (($segTotal/$hechas)/60)) }
