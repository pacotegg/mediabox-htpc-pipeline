<#
============================================================================
 sanear.ps1  -  Deja UNA pelicula lista para entrar en la biblioteca
============================================================================
 PARA QUE: hay peliculas que no necesitan pasar por el pipeline de video -la
 imagen ya esta bien- pero que NO se pueden meter tal cual:

   1. El contenedor puede dar PANTALLA NEGRA en Direct Play en las Samsung.
      Demostrado con un A/B/A en la QN93A el 28/08/2026, las tres veces en
      Direct Play: reconstruido va, ORIGINAL pantalla negra, reconstruido va.
      Y ojo: un remux normal de mkvmerge NO lo arregla, porque conserva los
      timestamps. Hace falta extraer+muxear, que los regenera.
   2. Las banderas 'default' vienen como vienen. Lo que queremos siempre es
      audio CASTELLANO por defecto y subtitulo FORZADO en castellano por
      defecto, y todo lo demas a cero.
   3. Puede traer un codec que la TV no decodifica (DTS, TrueHD, FLAC, Opus).
      Con Direct Play forzado eso ya no se degrada a transcodificacion: se
      queda MUDO para siempre y sin aviso.

 SE LLAMA DESDE DOS SITIOS, y por eso es un script y no codigo del panel:
   - el boton de saneado de la pestana Remux, sobre un fichero suelto;
   - el final de un remux normal, sobre la salida que acaba de generar.

 NO DUPLICA REGLAS. El plan -que pista es la castellana, cual sobra, cual hay
 que recortar- lo da 'audio_plan.py --file', que es el MISMO codigo que decide
 en la cola de la biblioteca. Y la reconstruccion es la Rebuild-Container de
 encode.ps1, extraida con el parser. Si esas reglas cambian, esto las sigue.

 DOS CAMINOS, y elegir bien importa:
   - Si hay trabajo de AUDIO (recorte, descartes, codec no nativo) -> pasa por
     audio_encode.ps1, que ya hace audio + banderas + reconstruccion en una
     pasada.
   - Si NO lo hay -> mkvpropedit para las banderas (en el sitio, milisegundos)
     y reconstruccion. Se evita a proposito reescribir el fichero entero con
     ffmpeg: es lento y ademas es SU muxer el sospechoso de la pantalla negra.

 Uso:
   pwsh -File C:\scripts\sanear.ps1 -File 'D:\peli.mkv' -Analizar
   pwsh -File C:\scripts\sanear.ps1 -File 'D:\peli.mkv'
============================================================================
#>
param(
    [Parameter(Mandatory=$true)][string]$File,
    # Solo mira y cuenta lo que haria. No toca un solo byte.
    [switch]$Analizar,
    # Salta el trabajo de audio: solo banderas + reconstruccion.
    [switch]$SinAudio,
    # Fichero JSON con el resultado, para que lo lea el panel.
    [string]$Json = ''
)

$ErrorActionPreference = 'Continue'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# $FFPROBE, $MKVMERGE, $MKVEXTRACT y $MKVPROPEDIT los da mediabox-paths.ps1,
# que se carga unas lineas mas abajo (31/08/2026: estaban copiados aqui).
$PYTHON      = 'C:\Users\HTPC\AppData\Local\Programs\Python\Python314\python.exe'
$PsExe       = (Get-Process -Id $PID).Path
$Encoder     = 'C:\scripts\atmosenc\audio_encode.ps1'
$Done        = 'C:\Media\audio_done'

foreach ($lib in @('C:\scripts\pipeline-lock.ps1','C:\scripts\atmos-lib.ps1','C:\scripts\mediabox-paths.ps1')) {
    if (Test-Path -LiteralPath $lib) { . $lib } else { Write-Host "ERROR: falta $lib"; exit 1 }
}
$BigTmp = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { 'G:\MediaTmp' }
# Temp de ESTADO, lock y status. Bajados aqui el 02/09/2026: salen de
# mediabox-paths.ps1 y antes se fijaban ARRIBA del dot-source, con la libreria
# sin cargar.
$Tmp         = if ($MediaBoxTmp) { $MediaBoxTmp } else { 'C:\Media\tmp' }
$LockFile    = Join-Path $Tmp 'pipeline.lock'
$StatusFile  = Join-Path $Tmp 'sanear_status'
New-Item -ItemType Directory -Force -Path $Done | Out-Null

$LogFile = "C:\Media\encode_logs\sanear-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
function Log($m) {
    $s = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $s; Add-Content -LiteralPath $LogFile -Value $s
}
function Set-Estado([string]$estado, [string]$fase, [int]$pct) {
    # Mismo formato clave=valor que el resto de ficheros de estado del panel.
    $t = "status=$estado`nfile=$([System.IO.Path]::GetFileName($File))`nstage=$fase`npct=$pct"
    [System.IO.File]::WriteAllText($StatusFile, $t, (New-Object System.Text.UTF8Encoding($false)))
}

$res = [ordered]@{ ok = $false; file = $File; motivo = ''; acciones = @(); avisos = @() }
function Salir([int]$code) {
    if ($Json) {
        ($res | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Json -Encoding UTF8
    }
    exit $code
}

# ---------------------------------------------------------------------------
# 1) CORDURA DEL FICHERO, ANTES DE NADA
#
# Esto no es burocracia: el 29/08/2026 aparecio en la biblioteca un '.mkv' que
# eran 1,1 GB de AC-3 CRUDO, sin una sola imagen dentro, y llevaba meses ahi.
# Detectarlo en la puerta cuesta dos sondeos; detectarlo dentro cuesta un
# disgusto.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $File)) { $res.motivo = 'no existe'; Log "ERROR: no existe $File"; Salir 1 }
$fmt = ((& $FFPROBE -v error -show_entries format=format_name -of csv=p=0 -- $File 2>$null) | Out-String).Trim()
if ($fmt -notmatch 'matroska|webm') {
    $res.motivo = "no es un MKV: ffprobe dice que el contenedor es '$fmt'"
    Log "ERROR: $($res.motivo)"
    Salir 1
}
$nv = @((& $FFPROBE -v error -select_streams v -show_entries stream=index -of csv=p=0 -- $File 2>$null)).Count
$na = @((& $FFPROBE -v error -select_streams a -show_entries stream=index -of csv=p=0 -- $File 2>$null)).Count
if ($nv -lt 1) { $res.motivo = 'no tiene pista de video'; Log "ERROR: $($res.motivo)"; Salir 1 }
if ($na -lt 1) { $res.motivo = 'no tiene pista de audio'; Log "ERROR: $($res.motivo)"; Salir 1 }

# mkvmerge tiene que poder leerlo: es quien va a reconstruirlo.
$mmOk = $false
try { $mmOk = [bool]((& $MKVMERGE -J $File 2>$null | Out-String | ConvertFrom-Json).tracks) } catch { }
if (-not $mmOk) { $res.motivo = 'mkvmerge no puede leer el fichero'; Log "ERROR: $($res.motivo)"; Salir 1 }

# ---------------------------------------------------------------------------
# 2) EL PLAN, del MISMO codigo que decide en la cola de la biblioteca
# ---------------------------------------------------------------------------
$planJson = Join-Path $Tmp ("sanear_plan_{0}.json" -f (Get-Date -Format 'yyyyMMddHHmmss'))
& $PYTHON 'C:\scripts\audio_plan.py' '--file' $File '--out' $planJson 2>&1 |
    ForEach-Object { Add-Content -LiteralPath $LogFile -Value "    | $_" }
if (-not (Test-Path -LiteralPath $planJson)) {
    $res.motivo = 'audio_plan.py no ha producido plan'
    Log "ERROR: $($res.motivo)"
    Salir 1
}
$plan = Get-Content -LiteralPath $planJson -Raw -Encoding UTF8 | ConvertFrom-Json
Remove-Item -LiteralPath $planJson -Force -ErrorAction SilentlyContinue
if ($plan.error) { $res.motivo = "el plan no se pudo calcular: $($plan.error)"; Log "ERROR: $($res.motivo)"; Salir 1 }

$drops = @($plan.tracks | Where-Object { $_.drop -and -not "$($_.drop)".StartsWith('REVISAR') } | ForEach-Object { [int]$_.i })
$vivas = @($plan.tracks | Where-Object { $drops -notcontains [int]$_.i })
$caps  = @($vivas | Where-Object { $_.cap })
# No nativas: lo que la TV no decodifica. Con Direct Play forzado es lo mas
# grave que puede quedarse dentro, porque no da error, da silencio.
$noNat = @($vivas | Where-Object { "$($_.codec)" -notin @('ac3','eac3','aac','mp3') })
$hayAudio = ($drops.Count -gt 0) -or ($caps.Count -gt 0) -or ($noNat.Count -gt 0)

$res.acciones = @()
if ($noNat.Count) { $res.acciones += ("convertir {0} pista(s) con codec que la TV no decodifica: {1}" -f $noNat.Count, (($noNat | ForEach-Object { "a:$($_.i) $($_.fmt)" }) -join ', ')) }
if ($caps.Count)  { $res.acciones += ("recortar {0} pista(s) de audio al techo: {1}" -f $caps.Count, (($caps | ForEach-Object { "a:$($_.i) $([int]($_.bps/1000))k -> $($_.cap)k" }) -join ', ')) }
if ($drops.Count) { $res.acciones += ("descartar {0} pista(s): {1}" -f $drops.Count, (($plan.tracks | Where-Object { $drops -contains [int]$_.i } | ForEach-Object { "a:$($_.i) $($_.drop)" }) -join ', ')) }
$defA = if ($null -ne $plan.default_audio) { [int]$plan.default_audio } else { -1 }
$defS = if ($null -ne $plan.default_sub)   { [int]$plan.default_sub }   else { -1 }
if ($defA -ge 0) { $res.acciones += "audio por defecto -> a:$defA [$(($plan.tracks | Where-Object { [int]$_.i -eq $defA }).lang)]" }
else             { $res.avisos   += 'no hay ninguna pista en castellano: el audio por defecto se deja como esta' }
if ($defS -ge 0) { $res.acciones += "subtitulo por defecto -> s:$defS (forzado castellano)" }
else             { $res.avisos   += 'no hay subtitulo forzado en castellano' }
$res.acciones += 'reconstruir el contenedor (arreglo de la pantalla negra)'

# Aviso de deriva de framerate: si el declarado no es el real, la reconstruccion
# NO se va a poder hacer, y es mejor saberlo ahora que cuando falle.
$fpsDec = ((& $FFPROBE -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- $File 2>$null) | Out-String).Trim()
$durVid = Get-DurVideo $File
if ($durVid -gt 0 -and $fpsDec -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -gt 0) {
    $fps = [double]$Matches[1] / [double]$Matches[2]
    $desde = [math]::Max(0, [int]$durVid - 60)
    # SE DIVIDE POR EL INTERVALO REAL, NO POR LOS 60 s PEDIDOS. Con un fichero
    # mas corto que la ventana -o con la ventana recortada al final- se leen
    # menos segundos de los que se piden, y dividir por 60 daba un framerate
    # inventado: en una prueba de 20 s decia "25 declarados contra 8,3 reales" y
    # anunciaba un rechazo que luego no ocurria. Un aviso que se equivoca es
    # peor que no avisar.
    $pts = @(& $FFPROBE -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 -read_intervals "$desde%+60" -- $File 2>$null) |
           ForEach-Object { ConvertTo-DoubleInv "$_" } | Where-Object { $null -ne $_ }
    if ($pts.Count -gt 10) {
        $m = $pts | Measure-Object -Minimum -Maximum
        $span = $m.Maximum - $m.Minimum
        if ($span -gt 1.0) {
            $fpsReal = ($pts.Count - 1) / $span
            if ([math]::Abs($fpsReal - $fps) / $fps -gt 0.10) {
                $res.avisos += ("el framerate declarado ({0:N3}) no cuadra con el real (~{1:N3}): la reconstruccion se va a rechazar" -f $fps, $fpsReal)
            }
        }
    }
}

Log "FICHERO : $File"
foreach ($a in $res.acciones) { Log "  - $a" }
foreach ($a in $res.avisos)   { Log "  AVISO: $a" }

if ($Analizar) {
    $res.ok = $true
    $res.motivo = 'solo analisis: no se ha tocado nada'
    Log "ANALISIS. No se ha tocado nada."
    Salir 0
}

# ---------------------------------------------------------------------------
# 3) EJECUTAR
# ---------------------------------------------------------------------------
Set-Estado 'working' 'lock' 0
if (-not (Enter-PipelineLock $LockFile)) {
    $res.motivo = 'hay otro trabajo del pipeline en marcha'
    Log "Ocupado: $($res.motivo). Vuelve a intentarlo cuando termine."
    Set-Estado 'idle' 'busy' 0
    Salir 75
}

$bien = $false
try {
    if ($hayAudio -and -not $SinAudio) {
        # --- Camino A: hay trabajo de audio -> el motor lo hace TODO ---------
        Set-Estado 'working' 'audio' 5
        Log "Trabajo de audio: pasa por audio_encode.ps1 (audio + banderas + reconstruccion)."
        $out = Join-Path $Done ([System.IO.Path]::GetFileName($File))
        $force = @($vivas | Where-Object { $_.profile -and ("$($_.profile)".Trim()) -ne '' -and ("$($_.profile)" -notmatch '(?i)atmos|joc') } | ForEach-Object { [int]$_.i })
        $argsEnc = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Encoder,$File,'-SoloSanear')
        if ($drops.Count) { $argsEnc += @('-DropTracks',     ($drops -join ',')) }
        if ($force.Count) { $argsEnc += @('-ForceCapTracks', ($force -join ',')) }
        if ($defA -ge 0)  { $argsEnc += @('-DefaultAudio', "$defA") }
        if ($defS -ge 0)  { $argsEnc += @('-DefaultSub',   "$defS") }
        $fixes = @($plan.tracks | Where-Object { $_.fix_lang } | ForEach-Object { "$($_.i)=$($_.fix_lang)" })
        if ($fixes.Count) { $argsEnc += @('-SetLang', ($fixes -join ',')) }

        & $PsExe @argsEnc 2>&1 | ForEach-Object { Add-Content -LiteralPath $LogFile -Value "    | $_" }
        $rc = $LASTEXITCODE
        if ($rc -ne 0) { throw "audio_encode.ps1 devolvio $rc" }
        if (-not (Test-Path -LiteralPath $out)) { throw 'el motor no ha producido salida' }

        Set-Estado 'working' 'verificando' 85
        $vs = Get-DurVideo $File; $vo = Get-DurVideo $out
        if ($vs -le 0 -or $vo -le 0)          { throw 'no se puede medir la duracion del video' }
        if ([math]::Abs($vs - $vo) -gt 3.0)   { throw ("la duracion del VIDEO no cuadra: {0:N1}s vs {1:N1}s" -f $vs,$vo) }
        $got = @((& $FFPROBE -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 -- $out 2>$null))
        if ($got.Count -ne $vivas.Count)      { throw "pistas de audio: $($got.Count) en la salida, $($vivas.Count) esperadas" }
        $malo = @($got | Where-Object { "$_".Trim() -notin @('ac3','eac3','aac','mp3') })
        if ($malo.Count)                      { throw "sigue habiendo codec no nativo en la salida: $($malo -join ',')" }

        Set-Estado 'working' 'sustituyendo' 95
        # MinRatio 0: aqui el fichero puede crecer (Opus -> DD+) o encoger
        # (recorte al techo) a proposito; el tamanyo ya se ha comprobado arriba
        # por duracion y pistas.
        $sw = Move-FicheroEnSitio -Nuevo $out -Destino $File -MinRatio 0
        if ($sw.Aviso) { $res.avisos += $sw.Aviso; Log "  aviso: $($sw.Aviso)" }
        if (-not $sw.Ok) { throw $sw.Motivo }
        $bien = $true
    }
    else {
        # --- Camino B: no hay audio que tocar -------------------------------
        # mkvpropedit trabaja EN EL SITIO y en milisegundos; reescribir 20 GB con
        # ffmpeg para mover una bandera no tiene sentido, y ademas es su muxer el
        # sospechoso de la pantalla negra que venimos a arreglar.
        if ($hayAudio) { Log "-SinAudio: se salta el trabajo de audio a peticion." }
        Set-Estado 'working' 'banderas' 10
        $ed = @()
        $ia = 0
        foreach ($t in $plan.tracks) { $ed += @('--edit', "track:a$($ia + 1)", '--set', "flag-default=$(if ([int]$t.i -eq $defA) {1} else {0})"); $ia++ }
        if ($defS -ge 0) {
            $isb = 0
            foreach ($s in $plan.subs) { $ed += @('--edit', "track:s$($isb + 1)", '--set', "flag-default=$(if ([int]$s.i -eq $defS) {1} else {0})"); $isb++ }
        }
        if ($ed.Count) {
            & $MKVPROPEDIT $File @ed 2>&1 | ForEach-Object { Add-Content -LiteralPath $LogFile -Value "    | $_" }
            if ($LASTEXITCODE -ne 0) { throw "mkvpropedit devolvio $LASTEXITCODE al poner las banderas" }
            Log "Banderas puestas (mkvpropedit, en el sitio)."
        }

        Set-Estado 'working' 'reconstruyendo' 30
        # Rebuild-Container viene de atmos-lib.ps1, cargada al arrancar
        # (31/08/2026). Antes se sacaba de encode.ps1 con el parser, aqui
        # dentro y en cada pelicula.
        if (-not (Get-Command Rebuild-Container -ErrorAction SilentlyContinue)) {
            throw 'atmos-lib.ps1 no trae Rebuild-Container'
        }
        $global:UltimoMotivoRebuild = ''
        if (-not (Rebuild-Container -File $File -OnProgress { param($p) Set-Estado 'working' 'reconstruyendo' ([int](30 + $p * 0.6)) })) {
            throw $(if ($global:UltimoMotivoRebuild) { $global:UltimoMotivoRebuild } else { 'la reconstruccion fallo' })
        }
        & $MKVPROPEDIT $File --add-track-statistics-tags 2>&1 | Out-Null
        $bien = $true
    }
}
catch {
    $res.motivo = "$_"
    Log "FALLO: $_"
    Log "El fichero NO se ha quedado a medias: o esta el original, o esta el sustituto entero."
}
finally {
    Get-ChildItem -LiteralPath $Done -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq [System.IO.Path]::GetFileName($File) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    Clear-JobTemps -Prefix 'audio' -Tmp $Tmp -BigTmp $BigTmp
    Exit-PipelineLock $LockFile
}

if ($bien) {
    $res.ok = $true
    $res.motivo = 'saneada'
    Set-Estado 'idle' 'done' 100
    Log "HECHO: la pelicula esta lista para la biblioteca."
} else {
    Set-Estado 'error' 'fallo' 0
}
Salir $(if ($bien) { 0 } else { 1 })
