#requires -Version 7.0
<#
============================================================================
 atmos-farm.ps1  -  Granja por lotes para la cola de audio (DD+ / Atmos)
============================================================================
 QUE HACE

 Vacia C:\Media\audio_queue corriendo K peliculas A LA VEZ, en vez de una
 detras de otra como hace audio-watch.ps1. Coge el pipeline.lock UNA vez para
 todo el lote y lo suelta al final.

 POR QUE EXISTE (28/08/2026)

 La conversion a DD+ no se puede acelerar por pista: ni encode_to_atmos_ddp ni
 pcm_to_ddp admiten <threads> en el esquema del propio DEE, y no hay
 codificador Atmos ni DD+ por GPU (ver dee-atmos-un-nucleo-sin-gpu). Una pista
 = un nucleo. Reescribir deew tampoco serviria: deew es un envoltorio y el
 propio log de DEE dice "Average CPU used by DEE process: 5 %".

 O sea que con una pelicula en vuelo esta maquina usa 1 nucleo de 16. La UNICA
 paralelizacion que no pierde calidad es por ARCHIVO, y es lo que hace esto.
 Medido en bench-atmos-parallel.ps1 con peliculas completas:

     K=2 -> 1,62x agregado (81 % de eficiencia)
     K=4 -> 2,65x agregado (66 %)

 En la ruta ATMOS sale gratis ademas el solapamiento decode/encode: un trabajo
 Atmos es ~34 % truehdd + ~66 % dee.exe (12,5 + 24,3 min de 36,8 en dracula).
 Con K trabajos en vuelo, mientras unos decodifican otros codifican y ese 34 %
 se absorbe solo, sin necesidad de una etapa aparte de decodificado adelantado.

 PARA QUE LOTE SIRVE DE VERDAD (medido el 28/08/2026 sobre los 1.377 sidecars
 -mediainfo.xml de E:\Peliculas, que son la biblioteca de verdad; el
 inventario.csv del 10/08 ya estaba desfasado):

     TrueHD Atmos -> DD+ JOC     0 peliculas   <- ese trabajo YA esta hecho
     TrueHD/DTS/FLAC -> deew     5 peliculas
     Techo 640k -> DD+ 448k    177 peliculas (251 pistas, ~87 GiB)
     Copia pura (solo remux)  1195 peliculas

 O sea que hoy la granja es para el lote del TECHO DE AUDIO, no para Atmos.
 Importa porque cambia el cuello de botella: la ruta deew NO genera DAMF, su
 temporal es el RF64 (~8-10 GB) en vez de los ~40 GB de la ruta Atmos, asi que
 ahi el limite deja de ser el espacio en G: y pasa a ser la CPU. Por eso el
 estimador de mas abajo mira la ruta REAL de cada pelicula en vez de asumir la
 peor: asumiendo Atmos, K se quedaria en 3 cuando caben 8.

 QUE **NO** HACE, a proposito

 - No trocea pistas. Cortar una pista y concatenar los .ec3 mete encoder delay
   en cada trozo y rompe la interpolacion de objetos del JOC: se degradaria en
   silencio, que es justo lo que este pipeline lleva meses quitando.
 - No relaja la exclusion entre pipelines. Coge el pipeline.lock igual que
   cualquier trabajo, asi que el watcher de video y el de subtitulos siguen
   esperando su turno. Lo que se paraleliza es lo de DENTRO del lote.
 - No reimplementa el motor de audio. Cada ranura lanza el MISMO
   atmosenc\audio_encode.ps1 de siempre, con los mismos parametros. Esa logica
   ya divergio dos veces en este repo; aqui solo se orquesta.
 - No decide el routing de ninguna pista. Eso lo sigue haciendo el motor.

 AISLAMIENTO DE RANURA (lo que hace que esto sea seguro)

   - Cada ranura trabaja en su PROPIA carpeta G:\MediaTmp\dee_farm_s<N>.
     Imprescindible: los temporales de la libreria se nombran con sello al
     SEGUNDO + indice de pista, asi que dos peliculas arrancadas en el mismo
     segundo escribirian en el MISMO .thd/DAMF -> audio corrupto sin aviso.
   - Cada ranura pone un sufijo a sus ficheros de estado de C:\Media\tmp
     (MEDIABOX_SLOT), o los K trabajos se pisarian audio_status/_pid/_outfile
     y el marcador de "trabajo en vuelo" dejaria de significar nada.
   - Se fuerza UNA pista a la vez dentro de cada trabajo (MEDIABOX_DDP_TRACKS),
     para que cada ranura tenga como mucho un temporal pesado vivo y la cuenta
     de espacio sea exacta. El paralelismo lo pone la granja, no el trabajo.
   - Antes de arrancar CADA pelicula se vuelve a mirar el hueco real. Si no
     cabe, esa ranura espera en vez de reventar a mitad (el 31/07/2026 un disco
     lleno se llevo el Atmos de Interstellar y el pipeline lo degrado sin decir
     nada).

 El prefijo 'dee_' de las carpetas de ranura es A PROPOSITO: es uno de los
 patrones que barren los tres watchers y stop-mediabox, asi que si alguien mata
 la granja con taskkill esos GB los recoge el siguiente barrido aunque este
 script no llegue a su finally.

 REQUISITO: audio_encode.ps1 tiene que entender MEDIABOX_SLOT y
 MEDIABOX_DDP_TRACKS. Sin eso la granja NO arranca (lo comprueba abajo y sale
 con un mensaje claro): correr K trabajos que se pisan el estado es justo la
 clase de fallo silencioso que no se admite aqui.

 USO
   pwsh -File C:\scripts\atmos-farm.ps1 -DryRun            # plan, sin tocar nada
   pwsh -File C:\scripts\atmos-farm.ps1                    # K=4 (por defecto)
   pwsh -File C:\scripts\atmos-farm.ps1 -MaxParallel 6
   pwsh -File C:\scripts\atmos-farm.ps1 -MaxFiles 10       # solo 10 de la cola
============================================================================
#>
[CmdletBinding()]
param(
    # Peliculas simultaneas. 4 por defecto: es el ultimo nivel MEDIDO (2,65x).
    # El valor efectivo lo puede BAJAR el chequeo de espacio; nunca lo sube.
    # Para un lote solo-deew (techo de audio) 6 es razonable pero NO esta
    # medido: subirlo es una hipotesis, no un hecho.
    [int]$MaxParallel = 4,
    # 0 = toda la cola. >0 = solo las N primeras (util para probar).
    [int]$MaxFiles = 0,
    [int]$AtmosBitrate = 768,
    # Pistas simultaneas DENTRO de cada trabajo. 0 = automatico (1 si K>1).
    # Subirlo multiplica los dee.exe vivos por K: no hacerlo sin medir.
    [int]$DdpTracksPerJob = 0,
    # Margen por ranura ademas de lo que estime Get-DdpSpaceNeeded.
    [double]$MarginGB = 10,
    # Ensena el plan (peliculas, ruta, K efectivo, espacio) y sale sin convertir.
    [switch]$DryRun
)

# ==========================================================================
#  RETIRADO EL 02/09/2026, A PETICION DEL USUARIO: NO SE VA A USAR.
# ==========================================================================
#  El fichero se conserva -no se borra- por dos motivos:
#
#    1. Aqui viven MEDICIONES que no estan en ningun otro sitio y que otros
#       ficheros citan: K=2 -> 1,62x agregado (81 % de eficiencia) y
#       K=4 -> 2,65x (66 %), sobre peliculas completas. Borrarlo tiraria el
#       dato y dejaria los comentarios de audio_encode.ps1 apuntando al aire.
#    2. En esta maquina no hay git y el borrado es definitivo.
#
#  QUE SE COMPROBO ANTES DE RETIRARLO: NADIE lo llama. No lo lanza ningun
#  watcher, ni el panel, ni ninguna tarea programada; solo se invocaba a mano.
#  Las dos variables de entorno que ponia -MEDIABOX_SLOT y MEDIABOX_DDP_TRACKS-
#  siguen leyendose en audio_encode.ps1, y SIN PONERLAS el comportamiento es
#  exactamente el de siempre (sufijo vacio y 2 pistas). O sea que retirarlo no
#  cambia nada de lo que corre hoy.
#
#  Si algun dia hiciera falta vaciar la cola de audio en paralelo, quitar este
#  bloque es todo lo que hay que hacer.
# ==========================================================================
Write-Host "atmos-farm.ps1 esta RETIRADO (02/09/2026): no se usa y no hace nada."
Write-Host "  Nadie lo llama. Para reactivarlo, quita el bloque RETIRADO de su cabecera."
exit 0


$ErrorActionPreference = 'Continue'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---- Rutas ---------------------------------------------------------------
$Base    = 'C:\Media'
$Watch   = Join-Path $Base 'audio_queue'
$Running = Join-Path $Base 'audio_running'
$LogDir  = Join-Path $Base 'audio_logs'
# $FFPROBE los da mediabox-paths.ps1 (31/08/2026: estaban copiados aqui).
# $Tmp (temp de ESTADO) se asigna abajo, con $BigTmpRoot: desde el 02/09/2026
# sale de mediabox-paths.ps1 y no puede fijarse antes de cargarla.

# Ruta unica de temporales pesados (mediabox-paths.ps1), igual que el resto del
# pipeline. Si se cambia ahi, esto la sigue sola.
$PathsLib = Join-Path $PSScriptRoot 'mediabox-paths.ps1'
if (-not (Test-Path -LiteralPath $PathsLib)) { $PathsLib = 'C:\scripts\mediabox-paths.ps1' }
if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
$BigTmpRoot = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { 'G:\MediaTmp' }
# Temp de ESTADO (pid, status, lock). Misma regla: una sola definicion en
# mediabox-paths.ps1. Estaba a mano en ONCE scripts (02/09/2026).
$Tmp        = if ($MediaBoxTmp) { $MediaBoxTmp } else { 'C:\Media\tmp' }

$LockLib = Join-Path $PSScriptRoot 'pipeline-lock.ps1'
if (-not (Test-Path -LiteralPath $LockLib)) { $LockLib = 'C:\scripts\pipeline-lock.ps1' }
if (-not (Test-Path -LiteralPath $LockLib)) { Write-Host "ERROR: no encuentro pipeline-lock.ps1."; exit 1 }
. $LockLib

$AtmosLib = Join-Path $PSScriptRoot 'atmos-lib.ps1'
if (-not (Test-Path -LiteralPath $AtmosLib)) { $AtmosLib = 'C:\scripts\atmos-lib.ps1' }
if (-not (Test-Path -LiteralPath $AtmosLib)) { Write-Host "ERROR: no encuentro atmos-lib.ps1."; exit 1 }
. $AtmosLib

$Encoder = Join-Path $PSScriptRoot 'atmosenc\audio_encode.ps1'
if (-not (Test-Path -LiteralPath $Encoder)) { $Encoder = 'C:\scripts\atmosenc\audio_encode.ps1' }
if (-not (Test-Path -LiteralPath $Encoder)) { Write-Host "ERROR: no encuentro audio_encode.ps1."; exit 1 }

$LockFile   = Join-Path $Tmp 'pipeline.lock'
$FarmPid    = Join-Path $Tmp 'audio_farm_pid'
$StatusFile = Join-Path $Tmp 'audio_status'
$VideoExt   = @('.mkv','.mp4','.m2ts','.ts','.mov')

New-Item -ItemType Directory -Force -Path $Watch,$Running,$LogDir,$Tmp | Out-Null

$stampRun = Get-Date -Format 'yyyyMMdd_HHmmss'
$FarmLog  = Join-Path $LogDir "farm_${stampRun}.log"
function Log($m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    Add-Content -LiteralPath $FarmLog -Value $line -ErrorAction SilentlyContinue
}
function Write-NoBom([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- El motor tiene que soportar ranuras ---------------------------------
# Sin esto los K trabajos comparten audio_status, audio_pid y audio_outfile en
# C:\Media\tmp. El peor de los tres es el marcador: audio-watch.ps1 lo usa para
# saber si a un trabajo lo mataron, y con varios pisandolo el rescate de
# arranque borraria salidas buenas o dejaria basura. Se comprueba y se PARA.
#
# NO se exige en -DryRun: ese camino no lanza ningun trabajo ni escribe un solo
# fichero de estado, asi que no puede pisar nada. Bloquearlo ahi solo impedia
# ver el plan, que es justo lo que uno quiere mirar ANTES de aplicar el parche.
$encSrc     = Get-Content -LiteralPath $Encoder -Raw -ErrorAction SilentlyContinue
$SinRanuras = ("$encSrc" -notmatch 'MEDIABOX_SLOT')
if ($SinRanuras -and -not $DryRun) {
    Write-Host ""
    Write-Host "ERROR: $Encoder no entiende MEDIABOX_SLOT."
    Write-Host "       Sin ese sufijo, K trabajos a la vez se pisan audio_status,"
    Write-Host "       audio_pid y audio_outfile en $Tmp. El marcador audio_outfile es"
    Write-Host "       el que dice si a un trabajo lo mataron: compartirlo corrompe el"
    Write-Host "       rescate de audio-watch.ps1."
    Write-Host "       Aplica el parche de ranura a audio_encode.ps1 antes de usar la granja."
    Write-Host ""
    Write-Host "       Para ver el plan sin aplicar nada:  -DryRun"
    exit 1
}

# ---- Instancia unica -----------------------------------------------------
# EL PID SOLO NO BASTA (31/08/2026). Esto era un 'Get-Process -Id' pelado, que
# es EXACTAMENTE el agujero que ya se cerro en el pipeline.lock: si la maquina se
# apaga en sucio con la granja en marcha -y aqui hay cuelgues documentados-, el
# fichero sobrevive al reinicio con un PID muerto que Windows reparte enseguida
# desde numeros bajos. Con el numero en manos de cualquier otro proceso,
# Get-Process lo encuentra vivo y la granja se niega a arrancar PARA SIEMPRE,
# diciendo ademas que ya esta corriendo. Sin error y sin una linea en ningun log.
# Test-LockOwnerAlive (pipeline-lock.ps1) compara ademas la HORA DE ARRANQUE, que
# distingue un PID reciclado del original sin ambiguedad, y admite el formato
# viejo de una sola linea.
if (Test-Path -LiteralPath $FarmPid) {
    $ex = @(Get-Content -LiteralPath $FarmPid -ErrorAction SilentlyContinue)[0]
    if (Test-LockOwnerAlive $FarmPid) {
        Write-Host "atmos-farm ya esta corriendo (PID $ex) - saliendo."
        exit 0
    }
    Write-Host "[..] habia un audio_farm_pid huerfano (PID $ex, ya no vive): sigo."
}

# ---- Limpieza de ranuras huerfanas de una granja anterior ----------------
function Remove-SlotDirs {
    param([string]$Etiqueta = 'ranura')
    $n = 0; $gb = 0.0
    foreach ($d in @(Get-ChildItem -LiteralPath $BigTmpRoot -Directory -Filter 'dee_farm_s*' -Force -ErrorAction SilentlyContinue)) {
        try {
            $sz = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Measure-Object -Property Length -Sum).Sum
            if ($sz) { $gb += ($sz / 1GB) }
        } catch { }
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $d.FullName)) { $n++ }
    }
    if ($n -gt 0) { Log ("  [clean] {0} carpeta(s) de {1} borradas ({2:N1} GB)." -f $n, $Etiqueta, $gb) }
}

# ---- Estado de una ranura muerta: marcador + salida parcial ---------------
# Equivalente a Clear-JobTemps para los ficheros de estado CON SUFIJO, que la
# version sin sufijo de la libreria no ve. Mismo contrato: si el marcador sigue
# ahi, al proceso lo mataron y su salida esta a medias.
function Clear-SlotState {
    param([string]$Sufijo)
    $marker = Join-Path $Tmp "audio_outfile_$Sufijo"
    if (Test-Path -LiteralPath $marker) {
        $out = @(Get-Content -LiteralPath $marker -ErrorAction SilentlyContinue)[0]
        if ($out -and (Test-Path -LiteralPath $out)) {
            $null = Remove-ConReintento -Ruta $out -Etiqueta "salida parcial ($Sufijo)"
        }
        Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $Tmp "audio_status_$Sufijo") -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Tmp "audio_pid_$Sufijo")    -ErrorAction SilentlyContinue
}

if (-not (Test-PipelineLockBusy $LockFile)) {
    foreach ($m in @(Get-ChildItem -LiteralPath $Tmp -Filter 'audio_outfile_f*' -Force -ErrorAction SilentlyContinue)) {
        Clear-SlotState -Sufijo ($m.Name -replace '^audio_outfile_','')
    }
    Remove-SlotDirs -Etiqueta 'ranura huerfana'
}

# ---- Puertas de entrada --------------------------------------------------
if (Test-PipelinePaused $Tmp) {
    Write-Host "El pipeline esta en PAUSA de mantenimiento. No arranco."
    exit 0
}
if (Test-PipelineLockBusy $LockFile) {
    Write-Host "Hay otro pipeline trabajando (pipeline.lock cogido). No arranco."
    exit 0
}

# ---- Candidatos de la cola ----------------------------------------------
$cands = @()
foreach ($f in @(Get-ChildItem -LiteralPath $Watch -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ($f.Extension.ToLower() -notin $VideoExt) {
        Log ("  [skip] {0}: extension {1} no admitida (se aceptan {2})." -f $f.Name, $f.Extension, ($VideoExt -join ' '))
        continue
    }
    $cands += $f
}
if ($MaxFiles -gt 0 -and $cands.Count -gt $MaxFiles) { $cands = @($cands[0..($MaxFiles-1)]) }
if ($cands.Count -eq 0) { Write-Host "audio_queue vacia: nada que hacer."; exit 0 }

Log ("=== atmos-farm: {0} pelicula(s) en cola ===" -f $cands.Count)

# ---- Ruta y espacio necesario, POR PELICULA ------------------------------
# Se mira la ruta real en vez de asumir la peor. Importa mucho: la ruta Atmos
# escribe un DAMF de 15-31 GB y la ruta deew un RF64 de 8-10 GB, o sea que
# asumir Atmos para un lote del techo de audio dejaria K en 3 cuando caben 8.
# La estimacion sigue siendo generosa a proposito (Get-DdpSpaceNeeded): un
# falso "no cabe" cuesta un aviso, un falso "si cabe" cuesta 20 min tirados.
$plan = @()
foreach ($f in $cands) {
    $dur = 0.0; $esAtmos = $false; $chMax = 6
    if (Test-Path -LiteralPath $FFPROBE) {
        $raw = & $FFPROBE -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null
        $d = ConvertTo-DoubleInv "$raw"
        if ($d) { $dur = $d }
        $js = & $FFPROBE -v error -select_streams a -show_entries stream=codec_name,channels,profile -of json $f.FullName 2>$null
        try {
            $o = ("$js" | ConvertFrom-Json)
            foreach ($st in @($o.streams)) {
                $ch = [int]$st.channels
                if ($ch -gt $chMax) { $chMax = $ch }
                # Solo la combinacion TrueHD + Atmos usa la cadena truehdd->DAMF,
                # que es la cara en disco. Un E-AC-3+Atmos no se toca nunca y un
                # TrueHD sin Atmos va por deew.
                if ("$($st.codec_name)" -eq 'truehd' -and "$($st.profile)" -match 'Atmos') { $esAtmos = $true }
            }
        } catch { }
    }
    $need = Get-DdpSpaceNeeded -DurationSec $dur -Channels $chMax -IsAtmos:$esAtmos `
                               -Bitrate $AtmosBitrate -MarginGB $MarginGB
    $plan += [pscustomobject]@{
        File = $f; Dur = $dur; Need = $need
        Ruta = $(if ($esAtmos) { 'atmos' } else { 'deew' })
    }
}
$sinDur = @($plan | Where-Object { $_.Dur -le 0 })
if ($sinDur.Count -gt 0) {
    Log ("  AVISO: {0} pelicula(s) sin duracion legible; se les reserva el maximo del lote." -f $sinDur.Count)
    $peor = ($plan | Measure-Object -Property Need -Maximum).Maximum
    foreach ($p in $sinDur) { $p.Need = $peor }
}
$nAtmos = @($plan | Where-Object { $_.Ruta -eq 'atmos' }).Count
Log ("  rutas: {0} por truehdd+DEE (DAMF pesado), {1} por deew (RF64)." -f $nAtmos, ($plan.Count - $nAtmos))

# ---- K efectivo: lo que de verdad cabe en G: -----------------------------
function Get-FreeBytes {
    param([string]$Path)
    try {
        $q = (Split-Path $Path -Qualifier) -replace ':',''
        return (Get-PSDrive -Name $q -ErrorAction Stop).Free
    } catch { return 0L }
}
$freeBytes = Get-FreeBytes -Path $BigTmpRoot
$peorNeed  = ($plan | Measure-Object -Property Need -Maximum).Maximum
$kEspacio  = if ($peorNeed -gt 0 -and $freeBytes -gt 0) { [int][math]::Floor($freeBytes / $peorNeed) } else { 1 }
if ($kEspacio -lt 1) { $kEspacio = 1 }
$K = [math]::Min($MaxParallel, $kEspacio)
$K = [math]::Min($K, $plan.Count)
if ($K -lt 1) { $K = 1 }

Log ("  {0} libre {1:N1} GB | peor pelicula {2:N1} GB -> caben {3}" -f $BigTmpRoot, ($freeBytes/1GB), ($peorNeed/1GB), $kEspacio)
if ($K -lt $MaxParallel) {
    Log ("  K BAJADO de {0} a {1} por ESPACIO en {2} (no por CPU)." -f $MaxParallel, $K, $BigTmpRoot)
}
$tracksPerJob = if ($DdpTracksPerJob -gt 0) { $DdpTracksPerJob } elseif ($K -gt 1) { 1 } else { 2 }
Log ("  K = {0} pelicula(s) a la vez, {1} pista(s) a la vez dentro de cada una." -f $K, $tracksPerJob)

if ($DryRun) {
    Log "  --- DryRun: plan y salgo, sin tocar nada ---"
    foreach ($p in $plan) {
        Log ("    {0,-55} {1,5:N0} min  {2,6:N1} GB  {3}" -f `
             $p.File.Name, ($p.Dur/60), ($p.Need/1GB), $p.Ruta)
    }
    $minTot = (($plan | Measure-Object -Property Dur -Sum).Sum) / 60
    Log ("  total: {0} pelicula(s), {1:N0} min de metraje." -f $plan.Count, $minTot)
    if ($SinRanuras) {
        Log ""
        Log "  AVISO: audio_encode.ps1 aun NO entiende MEDIABOX_SLOT, asi que"
        Log "         la granja no arrancara de verdad hasta aplicar el parche"
        Log "         de ranura. Este plan si es valido tal cual."
    }
    exit 0
}

# ---- El lote -------------------------------------------------------------
# PID + HORA DE ARRANQUE, el mismo formato de dos lineas que el pipeline.lock,
# para que Test-LockOwnerAlive pueda descartar un PID reciclado (ver arriba).
$startTicks = (Get-Process -Id $PID).StartTime.Ticks
Write-NoBom $FarmPid "$PID`n$startTicks"
$PsExe = (Get-Process -Id $PID).Path
if (-not $PsExe) { $PsExe = 'pwsh.exe' }

if (-not (Enter-PipelineLock $LockFile)) {
    Write-Host "No he podido coger el pipeline.lock (otro se me adelanto). Salgo."
    Remove-Item -LiteralPath $FarmPid -ErrorAction SilentlyContinue
    exit 0
}

$booster  = $null
$slots    = @()
$pend     = [System.Collections.ArrayList]@($plan)
$hechas   = 0
$fallidas = 0
$reencol  = 0
$total    = $plan.Count
$t0       = Get-Date

try {
    # UN booster para todo el arbol de la granja. Depth 6 y no 4: desde aqui la
    # cadena mas larga es
    #     farm -> audio_encode -> deew -> deew -> dee
    # o sea cuatro saltos, y por la rama del worker de pistas hay uno mas. Con
    # Depth 4 el dee de la ruta sin Atmos se quedaria en prioridad Normal, que
    # es exactamente el 2,76x que este booster existe para no perder.
    $boosterScript = Join-Path $PSScriptRoot 'atmos-prio-booster.ps1'
    if (-not (Test-Path -LiteralPath $boosterScript)) { $boosterScript = 'C:\scripts\atmos-prio-booster.ps1' }
    if (Test-Path -LiteralPath $boosterScript) {
        $bArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$boosterScript,
                   '-RootPid',"$PID",'-Depth','6','-TimeoutMin','720','-LogFile',$FarmLog)
        $bLine = ($bArgs | ForEach-Object {
            if ("$_" -match '[\s"()]') { '"' + ("$_" -replace '"','\"') + '"' } else { "$_" }
        }) -join ' '
        try {
            $booster = Start-Process -FilePath $PsExe -ArgumentList $bLine -NoNewWindow -PassThru -ErrorAction Stop
            if ($booster) { $null = $booster.Handle }
            Log "  [prio] booster en marcha (AboveNormal para dee/deew/truehdd/ffmpeg)."
        } catch {
            Log "  [prio] AVISO: no se pudo lanzar el booster: $($_.Exception.Message). Se sigue, pero mas lento."
        }
    }

    $slotIdx = 0
    while ($pend.Count -gt 0 -or @($slots | Where-Object { $_.Proc }).Count -gt 0) {

        # --- 1) Cosechar las ranuras que hayan terminado ---
        foreach ($s in @($slots | Where-Object { $_.Proc })) {
            if (-not $s.Proc.HasExited) { continue }
            $rc   = $s.Proc.ExitCode
            $mins = ((Get-Date) - $s.T0).TotalMinutes

            if ($rc -eq 75) {
                # Fallo declarado TRANSITORIO (disco lleno). NO se degrada: se
                # devuelve a la cola. Via la libreria, que lleva la cuenta de
                # intentos y para a los 3 en vez de girar para siempre.
                $ok = Invoke-PipelineRequeue -Tmp $Tmp -Prefix 'audio' -Nombre $s.Name `
                                             -Origen $s.Dest -Cola $Watch
                if ($ok) { $reencol++ } else { $fallidas++ }
                Log ("  [{0}] {1}: exit 75 (disco lleno) tras {2:N0} min." -f $s.Sfx, $s.Name, $mins)
            } elseif ($rc -eq 0) {
                $hechas++
                Log ("  [{0}] OK {1} en {2:N0} min." -f $s.Sfx, $s.Name, $mins)
            } else {
                $fallidas++
                Log ("  [{0}] FALLO {1} (exit {2}) tras {3:N0} min. El fuente sigue en audio_running." -f $s.Sfx, $s.Name, $rc, $mins)
            }

            Clear-SlotState -Sufijo $s.Sfx
            Remove-Item -LiteralPath $s.Dir -Recurse -Force -ErrorAction SilentlyContinue
            $s.Proc = $null
        }

        # --- 2) Arrancar lo que quepa ---
        while ($pend.Count -gt 0 -and @($slots | Where-Object { $_.Proc }).Count -lt $K) {
            $next = $pend[0]

            # Espacio AHORA, no el del principio: las ranuras vivas ya se han
            # comido su parte. Comprobarlo aqui es lo que evita el disco lleno a
            # mitad de un DEE de 20 minutos.
            $libre = Get-FreeBytes -Path $BigTmpRoot
            if ($libre -lt $next.Need) {
                if (@($slots | Where-Object { $_.Proc }).Count -eq 0) {
                    # Nada corriendo y aun asi no cabe: no es contencion, es que
                    # no hay sitio. Callarse aqui dejaria la granja girando.
                    Log ("  SIN ESPACIO: '{0}' necesita {1:N1} GB y en {2} hay {3:N1} GB. Se queda en la cola." -f `
                         $next.File.Name, ($next.Need/1GB), $BigTmpRoot, ($libre/1GB))
                    $null = $pend.RemoveAt(0)
                    $fallidas++
                    continue
                }
                break   # hay ranuras vivas: cuando alguna acabe habra hueco
            }

            $null = $pend.RemoveAt(0)
            $slotIdx++
            $sfx = "f$slotIdx"
            $dir = Join-Path $BigTmpRoot "dee_farm_s$slotIdx"
            New-Item -ItemType Directory -Force -Path $dir | Out-Null

            # Mover a audio_running CON EL LOCK COGIDO: nadie mas puede tocarlo.
            $dest = Join-Path $Running $next.File.Name
            try {
                Move-Item -LiteralPath $next.File.FullName -Destination $dest -Force -ErrorAction Stop
            } catch {
                Log ("  [{0}] no pude mover '{1}' a audio_running: {2}" -f $sfx, $next.File.Name, $_.Exception.Message)
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                $fallidas++
                continue
            }

            # Aislamiento de la ranura. Los hijos heredan el entorno AL NACER,
            # asi que basta con ponerlas justo antes de cada Start-Process: las
            # ranuras ya en marcha conservan su copia.
            #   MEDIABOX_BIGTMP     -> temporales pesados en carpeta propia
            #   MEDIABOX_SLOT       -> sufijo de los ficheros de estado en $Tmp
            #   MEDIABOX_DDP_TRACKS -> pistas a la vez dentro del trabajo
            $env:MEDIABOX_BIGTMP     = $dir
            $env:MEDIABOX_SLOT       = $sfx
            $env:MEDIABOX_DDP_TRACKS = "$tracksPerJob"

            $aArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Encoder,
                       $dest,'-AtmosBitrate',"$AtmosBitrate")
            # Citado POR ELEMENTO: los nombres de pelicula llevan espacios y
            # parentesis constantemente, y -ArgumentList une con espacios sin citar.
            $aLine = ($aArgs | ForEach-Object {
                if ("$_" -match '[\s"()]') { '"' + ("$_" -replace '"','\"') + '"' } else { "$_" }
            }) -join ' '
            # Salida a fichero y no a la consola: con K hijos escribiendo a la vez
            # el log de la granja quedaria ilegible justo cuando hace falta. Cada
            # trabajo ademas sigue escribiendo su propio log en audio_logs.
            # Dos ficheros distintos: stdout y stderr al mismo fichero falla.
            $soLog = Join-Path $BigTmpRoot "dee_farm_${sfx}_out.log"
            $seLog = Join-Path $BigTmpRoot "dee_farm_${sfx}_err.log"

            $p = $null
            try {
                $p = Start-Process -FilePath $PsExe -ArgumentList $aLine -NoNewWindow -PassThru `
                                   -RedirectStandardOutput $soLog -RedirectStandardError $seLog -ErrorAction Stop
            } catch {
                Log ("  [{0}] no se pudo lanzar el trabajo de '{1}': {2}" -f $sfx, $next.File.Name, $_.Exception.Message)
            }
            if ($null -eq $p) {
                # Se devuelve a la cola: el fichero esta intacto y sin convertir.
                Move-Item -LiteralPath $dest -Destination $next.File.FullName -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                $fallidas++
                continue
            }
            $null = $p.Handle   # sin tocar Handle, ExitCode puede venir a $null

            $slots += [pscustomobject]@{
                Sfx = $sfx; Dir = $dir; Name = $next.File.Name; Dest = $dest
                Orig = $next.File.FullName; Proc = $p; T0 = (Get-Date)
            }
            Log ("  [{0}] arranca {1} ({2:N0} min, ruta {3}, {4:N1} GB reservados)" -f `
                 $sfx, $next.File.Name, ($next.Dur/60), $next.Ruta, ($next.Need/1GB))
        }

        # --- 3) Estado agregado para el panel ---
        # Los hijos escriben audio_status_f1, _f2... (sufijo de ranura), asi que
        # este no se lo pisa nadie.
        $vivas = @($slots | Where-Object { $_.Proc })
        $pct = if ($total -gt 0) { [math]::Round(100.0 * $hechas / $total, 1) } else { 0 }
        $enCurso = ($vivas | ForEach-Object { $_.Name }) -join ' | '
        Write-NoBom $StatusFile ("status=encoding`nfile=granja x{0}: {1}`nduration=0`nstage={2}/{3} hechas`npct={4}" -f `
                                 $vivas.Count, $enCurso, $hechas, $total, $pct)

        if ($pend.Count -gt 0 -or $vivas.Count -gt 0) { Start-Sleep -Seconds 5 }
    }

    $mins = ((Get-Date) - $t0).TotalMinutes
    Log ("=== FIN: {0} OK, {1} fallidas, {2} reencoladas en {3:N0} min ===" -f $hechas, $fallidas, $reencol, $mins)
    if ($hechas -gt 0) {
        Log ("    {0:N1} min por pelicula de reloj con K={1}" -f ($mins/$hechas), $K)
    }
    Write-NoBom $StatusFile ("status=idle`nfile=granja: {0} hechas, {1} fallidas`nduration=0`nstage=done`npct=100" -f $hechas, $fallidas)
}
finally {
    # Matar lo que siga vivo, ARBOL COMPLETO: el hijo es un pwsh que casi no
    # consume; los que llenan G: y queman CPU son sus nietos (truehdd, dee).
    # Matar solo al padre dejaria vivo justo lo que hay que parar.
    foreach ($s in @($slots | Where-Object { $_.Proc })) {
        try {
            if (-not $s.Proc.HasExited) {
                $s.Proc.Kill($true)
                Log ("  [{0}] trabajo matado al abortar la granja." -f $s.Sfx)
            }
        } catch { }
        Clear-SlotState -Sufijo $s.Sfx
    }
    if ($booster) { try { if (-not $booster.HasExited) { $booster.Kill() } } catch { } }

    # Con el lock TODAVIA cogido, igual que Clear-JobTemps: si se soltara antes,
    # otro pipeline podria entrar y sus temporales recien creados casarian con
    # los patrones del barrido.
    Remove-SlotDirs -Etiqueta 'ranura'
    foreach ($pat in @('dee_farm_f*_out.log','dee_farm_f*_err.log')) {
        Get-ChildItem -LiteralPath $BigTmpRoot -Filter $pat -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Clear-JobTemps -Prefix 'audio' -Tmp $Tmp -BigTmp $BigTmpRoot
    Clear-ProcessedSources -Running $Running `
                           -CompletedJsonl (Join-Path $Base 'encode_logs\completed.jsonl') `
                           -MinFreeGB 100 -MinAgeHours 2

    Exit-PipelineLock $LockFile
    Remove-Item -LiteralPath $FarmPid -ErrorAction SilentlyContinue
}
