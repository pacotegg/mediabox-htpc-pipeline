<#
============================================================================
 dialogo-test.ps1  -  Comparar realces del canal central en una escena
============================================================================
 PARA QUE SIRVE
 --------------
 Extrae un fragmento de una pelicula y genera UN SOLO MKV que lleva dentro la
 pista original MAS varias variantes con el canal central (los dialogos)
 realzado en distinta medida. Se reproduce en la barra y se cambia de pista
 sobre la marcha: mismo momento, misma escena, comparacion inmediata.

 POR QUE ASI Y NO TOCANDO LA BIBLIOTECA
 --------------------------------------
 La biblioteca esta YA toda en AC-3/E-AC-3/AAC (medido sobre 957 sidecars:
 1179 AC-3, 464 AAC, 228 E-AC-3, 1 DTS), o sea que el pipeline las COPIA y no
 pasa ninguna por DEE. Cualquier realce de dialogo sobre lo que ya existe
 obliga a recodificar, y eso no se hace a ciegas sobre 957 peliculas: primero
 se decide CUANTO realce hace falta, con el oido y en el equipo de verdad.

 LAS VARIANTES
 -------------
   a:0  Original                  la pista tal cual, sin recodificar (copy)
   a:1  Centro +3 dB              resto de canales intacto
   a:2  Centro +6 dB              resto intacto; el mas agresivo
   a:3  Centro +3 / resto -3 dB   mismo contraste que a:2 (6 dB) pero por el
                                  otro camino: en vez de subir el dialogo baja
                                  el ruido. Suena MAS BAJO en conjunto -hay que
                                  subir el mando- y a cambio no puede saturar.

 a:0 esta ahi a proposito: sin referencia sin tocar, el oido se acostumbra en
 dos minutos y todo parece igual.

 EL LIMITADOR. Las variantes que SUBEN el centro pueden pasarse de fondo de
 escala en un grito o un portazo. Lleva 'alimiter' con 'level=false': recorta
 los picos sin normalizar. Si normalizara subiria el volumen de la variante
 entera y la comparacion seria mentira -sonaria mejor por ser mas alta, no por
 el realce-.

 OJO CON EL ATMOS. Si la pista elegida es E-AC-3 con JOC, las VARIANTES pierden
 los objetos (se recodifican como 5.1 plano). Para esta prueba da igual, pero
 avisa por el log: no vale como base para tocar una pelicula con Atmos.

 USO
 ---
   pwsh -File C:\scripts\dialogo-test.ps1 -Src "E:\Peliculas\X (2001)\X.mkv" -Start 00:42:30 -Duration 180

 Sale en G:\pruebas. No toca la fuente ni entra en el pipeline: no coge el
 lock, no encola nada y no escribe en la biblioteca.

 NOTA: fichero en ASCII puro (codigo Y comentarios).
============================================================================
#>
param(
    [Parameter(Mandatory=$true)][string]$Src,
    [string]$Start      = '00:30:00',
    [int]   $Duration   = 180,
    # Indice de la pista de audio RELATIVO al audio (el 'a:N' que muestra el
    # log y el que usa ffmpeg), no el indice absoluto de stream. -1 = elegir la
    # primera de 6 canales.
    [int]   $AudioIndex = -1,
    [string]$OutDir     = 'G:\pruebas',
    [int]   $Bitrate    = 640,
    # MODO CONTROL. Antes de afinar cuantos dB hace falta, hay que demostrar que
    # la cadena de reproduccion cambia de pista de verdad. Genera variantes
    # BRUTALES -una sin canal central y otra con solo el central- que es
    # imposible confundir. Si suenan todas igual, el problema no es el realce:
    # es que el reproductor no esta sirviendo la pista que se le pide.
    [switch]$Diag,
    [string]$Ffmpeg     = 'C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe'
)

$ErrorActionPreference = 'Stop'
function Log($m) { Write-Host $m }

$Ffprobe = Join-Path (Split-Path $Ffmpeg -Parent) 'ffprobe.exe'
foreach ($exe in @($Ffmpeg, $Ffprobe)) {
    if (-not (Test-Path -LiteralPath $exe)) { Log "ERROR: no existe $exe"; exit 1 }
}
# -LiteralPath en todo: los nombres de esta biblioteca llevan corchetes
# ([UHDReescalado], [YTS.MX]) y sin el se interpretan como comodin.
if (-not (Test-Path -LiteralPath $Src)) { Log "ERROR: no existe la fuente: $Src"; exit 1 }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# --- INVENTARIO DE PISTAS ---------------------------------------------------
# NO json: ffprobe OMITE el campo 'profile' del JSON cuando vale 'unknown', y
# entonces no hay forma de distinguir "no tiene Atmos" de "no me lo has dicho".
#
# NO csv tampoco: ffprobe emite las columnas en SU orden interno, no en el que
# se piden. Con 'codec_name,channels,profile' devuelve en realidad
# codec_name,profile,channels -y si el profile va vacio, como en cualquier AC-3,
# sale 'ac3,,6,spa'-. La primera version de este script leia asi 0 canales y
# 6 de profile, y descartaba como estereo un 5.1 perfecto. El formato de
# clave=valor no depende del orden y no puede desalinearse.
$raw = & $Ffprobe -v error -select_streams a -show_entries 'stream=codec_name,channels,profile:stream_tags=language' -of default -- $Src 2>&1
if ($LASTEXITCODE -ne 0 -or -not $raw) {
    Log "ERROR: ffprobe no pudo leer las pistas de audio."
    Log "       Si el fichero se reproduce bien, puede ser UNA sola pista rota:"
    Log "       reintentar con -v warning o mirar con mkvmerge -J."
    exit 1
}

$pistas = @()
$i = 0
$cur = $null
foreach ($line in @($raw)) {
    $l = "$line".Trim()
    if ($l -eq '[STREAM]') {
        $cur = [pscustomobject]@{ A = $i; Codec = ''; Ch = 0; Profile = ''; Lang = 'und' }
        continue
    }
    if ($l -eq '[/STREAM]') {
        if ($cur) { $pistas += $cur; $i++ }
        $cur = $null
        continue
    }
    if (-not $cur) { continue }
    $kv = $l -split '=', 2
    if ($kv.Count -ne 2) { continue }
    switch ($kv[0]) {
        'codec_name'   { $cur.Codec   = $kv[1] }
        'profile'      { $cur.Profile = $kv[1] }
        'TAG:language' { if ($kv[1]) { $cur.Lang = $kv[1] } }
        'channels'     { $cur.Ch = [int]("0" + ($kv[1] -replace '\D','')) }
    }
}
if ($pistas.Count -eq 0) { Log "ERROR: el fichero no tiene pistas de audio."; exit 1 }

Log "Pistas de audio en la fuente:"
foreach ($t in $pistas) {
    Log ("  a:{0}  {1,-6} {2}ch  [{3}]  {4}" -f $t.A, $t.Codec, $t.Ch, $t.Lang, $t.Profile)
}

# --- ELECCION DE PISTA ------------------------------------------------------
if ($AudioIndex -ge 0) {
    $sel = $pistas | Where-Object { $_.A -eq $AudioIndex } | Select-Object -First 1
    if (-not $sel) { Log "ERROR: no hay ninguna pista a:$AudioIndex en este fichero."; exit 1 }
} else {
    $sel = $pistas | Where-Object { $_.Ch -eq 6 } | Select-Object -First 1
    if (-not $sel) {
        Log "ERROR: ninguna pista de 6 canales. Un realce de canal central necesita"
        Log "       un 5.1 de verdad: en estereo el dialogo esta repartido entre L y R"
        Log "       y no se puede separar sin inventar. Elegir otra fuente."
        exit 1
    }
}
if ($sel.Ch -ne 6) {
    Log ("ERROR: a:{0} tiene {1} canales y este script solo trata 5.1 (6ch)." -f $sel.A, $sel.Ch)
    Log "       Con 8 canales (7.1) el reparto es otro y el pan de abajo mezclaria mal."
    exit 1
}
if ($sel.Profile -match '(?i)atmos|joc') {
    Log ""
    Log ("AVISO: a:{0} lleva Atmos/JOC. Las VARIANTES saldran como 5.1 plano: se" -f $sel.A)
    Log "       pierden los objetos. La original (a:0 de la salida) se copia intacta,"
    Log "       asi que la comparacion sigue valiendo para decidir cuanto realce."
    Log ""
}
Log ("Se realza a:{0} ({1} {2}ch [{3}])" -f $sel.A, $sel.Codec, $sel.Ch, $sel.Lang)

# --- GANANCIAS --------------------------------------------------------------
# En 5.1 el orden de ffmpeg es FL,FR,FC,LFE,BL/SL,BR/SR: c2 es SIEMPRE el
# centro. Se referencia por INDICE y no por nombre a proposito, para que de
# igual que la fuente sea 5.1(side) o 5.1(back).
$g3   = 1.4125   # +3 dB
$g6   = 1.9953   # +6 dB
$m3   = 0.7079   # -3 dB
$lim  = 'alimiter=level=false:limit=0.97'

$f = @()
$f += "[0:a:$($sel.A)]asplit=3[s1][s2][s3]"
if ($Diag) {
    # Control: diferencias imposibles de no oir. Los canales que se anulan se
    # escriben con '0*' en vez de omitirlos, para que 'pan' no avise de canales
    # de salida sin definir y quede claro que el silencio es intencionado.
    $g12 = 3.9811   # +12 dB
    $f += "[s1]pan=5.1|c0=c0|c1=c1|c2=0*c2|c3=c3|c4=c4|c5=c5[e1]"
    $f += "[s2]pan=5.1|c0=0*c0|c1=0*c1|c2=c2|c3=0*c3|c4=0*c4|c5=0*c5[e2]"
    $f += "[s3]pan=5.1|c0=c0|c1=c1|c2=$g12*c2|c3=c3|c4=c4|c5=c5,$lim[e3]"
    $titulos = @(
        '0 - Original (referencia)',
        '1 - SIN canal central: no deberia oirse casi ningun dialogo',
        '2 - SOLO canal central: solo dialogo, sin musica ni efectos',
        '3 - Centro +12 dB (exagerado a proposito)'
    )
} else {
    $f += "[s1]pan=5.1|c0=c0|c1=c1|c2=$g3*c2|c3=c3|c4=c4|c5=c5,$lim[e1]"
    $f += "[s2]pan=5.1|c0=c0|c1=c1|c2=$g6*c2|c3=c3|c4=c4|c5=c5,$lim[e2]"
    $f += "[s3]pan=5.1|c0=$m3*c0|c1=$m3*c1|c2=$g3*c2|c3=$m3*c3|c4=$m3*c4|c5=$m3*c5,$lim[e3]"
    $titulos = @(
        '0 - Original (referencia)',
        '1 - Centro +3 dB',
        '2 - Centro +6 dB',
        '3 - Centro +3 / resto -3 dB (subir el mando)'
    )
}
$filtro = $f -join ';'

$base = [IO.Path]::GetFileNameWithoutExtension($Src)
$tag  = ($Start -replace '[^0-9]','')
$sufijo = if ($Diag) { 'CONTROL' } else { 'dialogos' }
$out  = Join-Path $OutDir ("{0}_{1}_{2}.mkv" -f $base, $sufijo, $tag)

# --- FFMPEG -----------------------------------------------------------------
# Quoting POR ELEMENTO del array, nunca una linea de comando montada a mano:
# es lo unico que aguanta espacios, corchetes y acentos en los nombres.
$fargs = @(
    '-y', '-hide_banner', '-loglevel', 'warning', '-stats',
    '-ss', $Start, '-i', $Src, '-t', "$Duration",
    '-filter_complex', $filtro,
    '-map', '0:v:0', '-c:v', 'copy',
    '-map', "0:a:$($sel.A)", '-c:a:0', 'copy',
    '-map', '[e1]', '-c:a:1', 'eac3', '-b:a:1', "${Bitrate}k",
    '-map', '[e2]', '-c:a:2', 'eac3', '-b:a:2', "${Bitrate}k",
    '-map', '[e3]', '-c:a:3', 'eac3', '-b:a:3', "${Bitrate}k",
    '-metadata:s:a:0', "title=$($titulos[0])",
    '-metadata:s:a:1', "title=$($titulos[1])",
    '-metadata:s:a:2', "title=$($titulos[2])",
    '-metadata:s:a:3', "title=$($titulos[3])",
    '-sn', '-dn',
    '-avoid_negative_ts', 'make_zero'
)
foreach ($n in 0..3) { $fargs += @("-metadata:s:a:$n", "language=$($sel.Lang)") }
$fargs += $out

Log ""
Log "Generando el clip de comparacion..."
& $Ffmpeg @fargs
$rc = $LASTEXITCODE

# --- VERIFICACION -----------------------------------------------------------
# Un exit 0 NO basta: ya ha pasado antes que un encode 'correcto' dejara un
# fichero de 0 bytes.
if ($rc -ne 0) { Log "ERROR: ffmpeg termino con codigo $rc"; exit 1 }
if (-not (Test-Path -LiteralPath $out)) { Log "ERROR: no se genero $out"; exit 1 }
$sz = (Get-Item -LiteralPath $out).Length
if ($sz -le 0) { Log "ERROR: la salida esta vacia (0 bytes): $out"; exit 1 }

Log ""
Log ("LISTO: {0}  ({1:N1} MB)" -f $out, ($sz/1MB))
# Volcado literal, sin parsear: aqui solo se mira, y asi no hay orden de
# columnas que pueda desalinearse.
$chk = & $Ffprobe -v error -select_streams a -show_entries 'stream=codec_name,channels:stream_tags=title' -of 'default=noprint_wrappers=1' -- $out 2>&1
Log "Pistas de la salida:"
foreach ($l in @($chk)) { Log "  $l" }
Log ""
Log "COMO ESCUCHARLO"
Log "  Ponlo en la barra por Plex o por USB y ve cambiando de pista en la MISMA"
Log "  escena. Empieza y termina siempre por la 0 (la original): el oido se"
Log "  acostumbra al realce en un par de minutos y despues todo parece igual."
Log "  La pista 3 suena mas baja de por si: sube el mando antes de juzgarla."
