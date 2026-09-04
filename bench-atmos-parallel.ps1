#requires -Version 7.0
<#
============================================================================
 bench-atmos-parallel.ps1  -  Benchmark: DD+ Atmos secuencial vs N en paralelo
============================================================================
 QUE MIDE (y que NO)
 -------------------
 La conversion TrueHD Atmos -> DD+ Atmos (E-AC-3 JOC) via truehdd + dee.exe usa
 UN solo nucleo y no hay palanca para acelerar UNA pista (verificado en el
 esquema del propio DEE: encode_to_atmos_ddp no admite <threads>, y no existe
 codificador Atmos por GPU). Ver la nota de memoria dee-atmos-un-nucleo-sin-gpu.

 Trocear una sola pista y concatenar los .ec3 NO es una opcion: cada dee mete su
 encoder delay/padding en cada chunk (costuras audibles) y el Joint Object Coding
 interpola la posicion de los objetos ENTRE frames, asi que un corte duro rompe
 esa continuidad. Se degradaria en silencio, justo lo que el pipeline evita.

 La unica paralelizacion SIN perder calidad es a nivel de ARCHIVO: N conversiones
 completas a la vez, cada una intacta de principio a fin, una por nucleo. Este
 script mide exactamente eso y busca el punto donde la CONTENCION (CPU y sobre
 todo disco) deja de compensar. El numero que importa no es "segundos por pista"
 sino THROUGHPUT AGREGADO: cuanto audio se codifica por segundo de reloj con K
 instancias.

   Metodo A (baseline) = una ejecucion del nivel K=1.
   Metodo B           = los niveles K=2,4,... del mismo bucle.

 COMO
 ----
 - Reutiliza Convert-TrueHDToDDP de atmos-lib.ps1 (la MISMA cadena del pipeline).
   No se reimplementa nada: copiar esa logica ya divergio dos veces en este repo.
 - Cada instancia corre en su PROPIO proceso pwsh y su PROPIA carpeta de temporales
   en G: (bench_slot_N). Imprescindible: los temporales de la funcion se nombran
   con sello al SEGUNDO + indice de pista; dos instancias en el mismo segundo con
   el mismo indice escribirian en el MISMO .thd/DAMF -> audio corrupto sin aviso
   (es la carrera que documenta pipeline-lock.ps1). Aislar el BigTmp lo elimina.
 - Un muestreador lee los contadores del disco fisico de G: durante cada tanda
   (via CIM, con nombres de propiedad en ingles: robusto en Windows en espanyol).

 AVISO DE ESPACIO -el hallazgo mas probable-
 -------------------------------------------
 Un DAMF de pelicula ronda 15-31 GB y conviven .thd + DAMF a la vez (~40 GB por
 instancia). G:\MediaTmp son 223 GB en total: 4 instancias ya rozan el limite y 6
 NO caben. Antes de cada nivel se comprueba el espacio con Get-DdpSpaceNeeded (la
 misma estimacion del pipeline) y si no cabe se SALTA el nivel con un aviso claro,
 en vez de arrancarlo y que reviente a mitad. Para explorar K altos sin necesitar
 240 GB, usar -ClipSeconds (recorta el audio a un clip corto; ver su aviso).

 USO
 ---
   pwsh -File C:\scripts\bench-atmos-parallel.ps1 `
        -Inputs 'C:\Users\HTPC\Downloads\peli.mkv' -Throttles 1,2,4

   # varias pelis reales (mas representativo que replicar una):
   -Inputs 'a.mkv','b.mkv','c.mkv','d.mkv' -Throttles 1,2,4

   # probar escalado hasta 6 barato, con clips de 4 min:
   -Inputs 'peli.mkv' -Throttles 1,2,4,6 -ClipSeconds 240

 Si se pasa UN solo input y K>1, se REPLICA para llenar los huecos (workload
 identico => la diferencia sale solo de la contencion, no del tamanyo del fichero).
============================================================================
#>
[CmdletBinding()]
param(
    # MKV(s) con TrueHD Atmos. Uno o varios. Si hay menos que el K maximo, se
    # replican ciclicamente para llenar las ranuras.
    [Parameter(Mandatory=$true)][string[]]$Inputs,
    # Indice de pista de audio (a:N) a convertir en cada input.
    [int]$AudioIndex = 0,
    # Bitrate DD+ Atmos. Rejilla valida: 384/448/576/640/768/1024 (768 = default del pipeline).
    [int]$Bitrate = 768,
    # Niveles de paralelismo a medir. El 1 es el baseline (Metodo A).
    [int[]]$Throttles = @(1, 2, 4),
    # Raiz de temporales pesados. Por defecto la misma que el pipeline (G:).
    [string]$BigTmpRoot = 'G:\MediaTmp',
    # Donde caen los .ec3 (se descartan; son pequenyos). Off de C: a proposito.
    [string]$OutDir = '',
    # >0: recorta cada input a un clip de esos segundos ANTES de medir, para probar
    # K altos sin llenar G:. OJO: el corte de TrueHD es por copia (MLP tiene restart
    # intervals), asi que el clip PUEDE perder frames de cabecera o, en el peor caso,
    # no decodificar. Vale para medir ESCALADO, no para juzgar calidad. Sin clip = 0.
    [double]$ClipSeconds = 0,
    # Margen de espacio por instancia (GB) que exige la estimacion. Generoso a proposito.
    [int]$MarginGB = 8,
    # Nucleos FISICOS que se dejan siempre libres para el SO, el video (GPU pero con
    # su hilo de CPU), los watchers y el panel. El techo de paralelismo es
    # (nucleos_fisicos - ReserveCores): con eso el PC nunca se queda sin potencia.
    [int]$ReserveCores = 2,
    # RAM (GB) por instancia. 1,5 GB MEDIDO, no supuesto: en la tanda del
    # 05/08/2026 el propio DEE reporto "Max MEM used by DEE process: 59 MB" y
    # truehdd se quedo en ~10 MB de working set. El DAMF (15 GB) vive en DISCO, no
    # en RAM, que es lo que hace que este proceso sea tan barato en memoria.
    # ANTES habia un 4 aqui, puesto a ojo: con el, el nivel K=4 se SALTO por
    # "RAM justa" pese a que sobraban 18 GB. Un guardarrail mal calibrado no es
    # prudencia, es un falso negativo que tira una medicion.
    [double]$RamPerInstanceGB = 1.5,
    # RAM libre (GB) que se exige DEJAR tras lanzar la tanda. Si no queda, se salta el nivel.
    [double]$MinFreeRamGB = 3,
    # Intervalo de muestreo del disco (ms).
    [int]$DiskSampleMs = 1500,
    # Lock real del pipeline: si esta ocupado, el benchmark aborta (los resultados
    # serian ruido y ademas competiria por G: con un trabajo vivo de 40 GB).
    [string]$PipelineLock = 'C:\Media\tmp\pipeline.lock',
    # Saltarse ese guardarail (medir aun con el pipeline trabajando). No recomendado.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Log($m) { Write-Host ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Section($m) { Write-Host ""; Write-Host "==== $m ====" -ForegroundColor Cyan }

# --- Dependencias: la libreria real y el lock ------------------------------
$AtmosLib = Join-Path $ScriptDir 'atmos-lib.ps1'
$LockLib  = Join-Path $ScriptDir 'pipeline-lock.ps1'
foreach ($lib in @($AtmosLib, $LockLib)) {
    if (-not (Test-Path -LiteralPath $lib)) { throw "No encuentro $lib (este script debe vivir junto a atmos-lib.ps1)." }
}
. $AtmosLib
. $LockLib

# --- Binarios --------------------------------------------------------------
# $FFMPEG y $FFPROBE los da mediabox-paths.ps1, que ya llega por atmos-lib.ps1
# (04/09/2026). Aqui habia una copia -con el mismo valor y el mismo respaldo-
# escrita DESPUES del dot-source, o sea que ganaba ella: el dia que cambiara la
# ruta de WinGet, este fichero se habria quedado con la vieja sin decir nada.
# Es la trampa que la cabecera de mediabox-paths.ps1 describe. dee y truehdd
# si se quedan: no son del pipeline y la libreria no los define.
$Dee     = 'C:\scripts\DEE\dee.exe'
$Truehdd = 'C:\scripts\bin\truehdd.exe'
foreach ($b in @(@{P=$Dee;N='dee.exe'}, @{P=$Truehdd;N='truehdd.exe'})) {
    if (-not (Test-Path -LiteralPath $b.P)) { throw "No encuentro $($b.N) en $($b.P)." }
}

# --- Guardarail: no medir con el pipeline vivo -----------------------------
if (-not $Force) {
    if (Test-PipelineLockBusy -LockFile $PipelineLock) {
        throw "El pipeline esta TRABAJANDO ($PipelineLock ocupado). Los resultados serian ruido y competirias por G: con un trabajo de 40 GB. Espera a que acabe, o pasa -Force si sabes lo que haces."
    }
    if (Test-PipelinePaused) {
        Log "AVISO: el pipeline esta en pausa global. Sigo (la pausa no impide medir), pero los watchers no cogeran trabajo mientras tanto."
    }
}

# --- Salidas y temporales del benchmark ------------------------------------
if (-not $OutDir) { $OutDir = Join-Path $BigTmpRoot 'bench_out' }
New-Item -ItemType Directory -Force -Path $BigTmpRoot | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir     | Out-Null
$RunDir = Join-Path $BigTmpRoot ("bench_run_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

$LogicalCores = [Environment]::ProcessorCount
try { $PhysCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum } catch { $PhysCores = $LogicalCores }
if (-not $PhysCores -or $PhysCores -lt 1) { $PhysCores = $LogicalCores }
# Techo de paralelismo por CPU: dee es compute-bound y usa 1 nucleo FISICO, no logico
# (el SMT no ayuda a un encoder serie). Se dejan ReserveCores libres pase lo que pase.
$MaxK = [math]::Max(1, $PhysCores - $ReserveCores)
Log ("CPU: {0} nucleos fisicos ({1} logicos). Cada dee usa 1 fisico. Techo por CPU: K<={2} (reservo {3} para el SO/video/panel)." -f $PhysCores, $LogicalCores, $MaxK, $ReserveCores)

function Get-FreeRamGB {
    try { return (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB / 1GB } catch { return 999 }
}

# --- El worker: un proceso pwsh que llama a la funcion REAL y cronometra ---
# Se escribe a disco una vez y se invoca con -File por cada ranura.
$WorkerPath = Join-Path $RunDir 'worker.ps1'
@'
param(
    [Parameter(Mandatory)][string]$InputFile,
    [int]$AudioIndex,
    [int]$Bitrate,
    [string]$BigTmp,
    [string]$OutFile,
    [double]$DurationSec,
    [int]$Channels,
    [string]$LibPath,
    [string]$SlotLog,
    [string]$ResultFile
)
# Log propio de la ranura: la libreria lo resuelve en runtime, asi que escribe aqui.
function Log($m) { Add-Content -LiteralPath $SlotLog -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ErrorAction SilentlyContinue }
. $LibPath
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ok = $false; $fail = ''
try {
    $ok = Convert-TrueHDToDDP -InputFile $InputFile -AudioIndex $AudioIndex -Bitrate $Bitrate `
            -OutFile $OutFile -IsAtmos -BigTmp $BigTmp -Tmp $BigTmp `
            -DurationSec $DurationSec -Channels $Channels
    $fail = $global:DdpLastFailure
} catch {
    $fail = "exc: $($_.Exception.Message)"
}
$sw.Stop()
$sz = 0L
if (Test-Path -LiteralPath $OutFile) { $sz = (Get-Item -LiteralPath $OutFile).Length }

# TIEMPO DE LA FASE DEE, sacado del propio resumen de DEE en el log de la ranura.
# Es LA metrica que decide: DEE es monohilo y CPU pura, asi que su duracion no
# depende de la cache de disco del sistema operativo. El tiempo total SI depende
# (la extraccion lee 28-37 GB), y eso fue justo lo que contamino el baseline del
# 05/08/2026: el K=1 arranco con el post-proceso del encode anterior aun comiendo
# maquina y salio 1,8x mas lento que la misma pelicula en K=2, un imposible fisico
# que invalido la tanda entera. Con este dato el nivel se puede comparar aunque el
# I/O varie entre tandas.
$deeEnc = 0.0; $deeMeas = 0.0
if (Test-Path -LiteralPath $SlotLog) {
    $txt = Get-Content -LiteralPath $SlotLog -Raw -ErrorAction SilentlyContinue
    if ($txt -match 'Encoder pass completed in ([\d.]+)') {
        $v = 0.0
        if ([double]::TryParse($Matches[1], [System.Globalization.NumberStyles]::Float,
                               [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $deeEnc = $v }
    }
    if ($txt -match 'Measurement pass completed in ([\d.]+)') {
        $v = 0.0
        if ([double]::TryParse($Matches[1], [System.Globalization.NumberStyles]::Float,
                               [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $deeMeas = $v }
    }
}

[pscustomobject]@{
    ok       = [bool]$ok
    seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    failure  = "$fail"
    outBytes = $sz
    audioSec = $DurationSec
    deeEnc   = [math]::Round($deeEnc, 1)
    deeMeas  = [math]::Round($deeMeas, 1)
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultFile -Encoding UTF8
'@ | Set-Content -LiteralPath $WorkerPath -Encoding UTF8

# --- Sondeo del input: duracion y canales (para espacio y throughput) ------
function Get-AudioInfo([string]$File, [int]$Idx) {
    $dur = 0.0; $ch = 8
    try {
        # ConvertTo-DoubleInv (de atmos-lib): parseo en cultura INVARIANTE. Con el
        # TryParse normal, en es-ES "5458.048000" se lee como 5.458.048.000 s y el
        # chequeo de espacio pediria exabytes -> saltaria todos los niveles.
        $d = & $FFPROBE -v error -select_streams "a:$Idx" -show_entries stream=duration -of csv=p=0 -- $File 2>$null
        $v = ConvertTo-DoubleInv $d
        if ($null -eq $v -or $v -le 0) {
            $d2 = & $FFPROBE -v error -show_entries format=duration -of csv=p=0 -- $File 2>$null
            $v = ConvertTo-DoubleInv $d2
        }
        if ($null -ne $v) { $dur = $v }
        $c = & $FFPROBE -v error -select_streams "a:$Idx" -show_entries stream=channels -of csv=p=0 -- $File 2>$null
        $ci = 0; if ([int]::TryParse(("$c").Trim(), [ref]$ci) -and $ci -gt 0) { $ch = $ci }
    } catch { }
    return [pscustomobject]@{ DurationSec = $dur; Channels = $ch }
}

# --- Clips opcionales (para probar K altos sin llenar G:) ------------------
$EffectiveIndex = $AudioIndex
if ($ClipSeconds -gt 0) {
    Section "Recortando clips de $ClipSeconds s (corte por copia de TrueHD; puede perder frames de cabecera)"
    $ClipDir = Join-Path $RunDir 'clips'
    New-Item -ItemType Directory -Force -Path $ClipDir | Out-Null
    $clipped = @()
    $seen = @{}
    foreach ($f in $Inputs) {
        if (-not (Test-Path -LiteralPath $f)) { throw "No existe el input: $f" }
        $key = [System.IO.Path]::GetFullPath($f).ToLower()
        if ($seen.ContainsKey($key)) { $clipped += $seen[$key]; continue }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f)
        $clip = Join-Path $ClipDir ("clip_{0}_{1}.mkv" -f $base, $clipped.Count)
        Log "  recorto: $base -> $(Split-Path $clip -Leaf)"
        & $FFMPEG -y -loglevel error -i $f -map "0:a:$AudioIndex" -t $ClipSeconds -c:a copy -f matroska $clip 2>&1 | Out-Null
        if (-not ((Test-Path -LiteralPath $clip) -and (Get-Item -LiteralPath $clip).Length -gt 1MB)) {
            throw "El recorte de $base fallo o salio vacio. Ese titulo no admite corte por copia; prueba sin -ClipSeconds."
        }
        $seen[$key] = $clip
        $clipped += $clip
    }
    $Inputs = $clipped
    $EffectiveIndex = 0   # el clip solo tiene la pista de audio -> a:0
}

# --- Resolver la info de cada input UNA vez --------------------------------
Section "Sondeando inputs"
$Resolved = @()
foreach ($f in $Inputs) {
    if (-not (Test-Path -LiteralPath $f)) { throw "No existe el input: $f" }
    $info = Get-AudioInfo $f $EffectiveIndex
    if ($info.DurationSec -le 0) { throw "No pude leer la duracion de $f (a:$EffectiveIndex). Revisa el indice de pista." }
    Log ("  {0}: {1:N0} s, {2} canales" -f (Split-Path $f -Leaf), $info.DurationSec, $info.Channels)
    $Resolved += [pscustomobject]@{ Path = $f; DurationSec = $info.DurationSec; Channels = $info.Channels }
}

# --- Muestreador de disco (CIM, propiedades en ingles: robusto en es-ES) ---
# Numero de disco fisico que respalda G:, para filtrar el contador correcto.
$DiskNum = $null
$DriveLetter = (Split-Path -Qualifier $BigTmpRoot).TrimEnd(':')
try { $DiskNum = (Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number } catch { }

# El muestreador corre en su PROPIO proceso pwsh (no ThreadJob: su modulo cambia
# de nombre entre versiones y aqui no esta por el nombre clasico). Se detiene
# creando el stop-file; el proceso sale solo y el llamante espera su ExitCode.
$SamplerPath = Join-Path $RunDir 'sampler.ps1'
@'
param([string]$diskNum, [string]$driveLetter, [string]$stopFile, [string]$csv, [int]$ms)
"PctIdle,QueueLen,ReadMBs,WriteMBs" | Set-Content -LiteralPath $csv -Encoding ASCII
while (-not (Test-Path -LiteralPath $stopFile)) {
    try {
        $all = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop
        $d = $null
        if ($diskNum -ne '') { $d = $all | Where-Object { $_.Name -match "^$diskNum(\s|$)" } | Select-Object -First 1 }
        if (-not $d) { $d = $all | Where-Object { $_.Name -match "\b${driveLetter}:" } | Select-Object -First 1 }
        if (-not $d) { $d = $all | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1 }
        if ($d) {
            ("{0},{1},{2:N1},{3:N1}" -f `
                $d.PercentIdleTime, $d.AvgDiskQueueLength, `
                ($d.DiskReadBytesPerSec / 1MB), ($d.DiskWriteBytesPerSec / 1MB)
            ) | Add-Content -LiteralPath $csv -Encoding ASCII
        }
    } catch { }
    Start-Sleep -Milliseconds $ms
}
'@ | Set-Content -LiteralPath $SamplerPath -Encoding UTF8

function Start-DiskSampler([string]$StopFile, [string]$CsvOut) {
    $dn = if ($null -ne $DiskNum) { "$DiskNum" } else { '' }
    $argsArr = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $SamplerPath,
        '-diskNum', $dn, '-driveLetter', $DriveLetter, '-stopFile', $StopFile, '-csv', $CsvOut, '-ms', $DiskSampleMs
    )
    $argline = Get-ArgLine $argsArr
    $p = Start-Process -FilePath 'pwsh' -ArgumentList $argline -NoNewWindow -PassThru
    $null = $p.Handle
    return $p
}

function Summarize-Disk([string]$Csv) {
    if (-not (Test-Path -LiteralPath $Csv)) { return $null }
    $rows = @(Import-Csv -LiteralPath $Csv)
    if ($rows.Count -eq 0) { return $null }
    $idle = $rows | ForEach-Object { [double]$_.PctIdle }
    $q    = $rows | ForEach-Object { [double]$_.QueueLen }
    $w    = $rows | ForEach-Object { [double]$_.WriteMBs }
    return [pscustomobject]@{
        IdleAvg   = [math]::Round(($idle | Measure-Object -Average).Average, 0)
        IdleMin   = [math]::Round(($idle | Measure-Object -Minimum).Minimum, 0)
        QueueMax  = [math]::Round(($q    | Measure-Object -Maximum).Maximum, 1)
        WriteMax  = [math]::Round(($w    | Measure-Object -Maximum).Maximum, 0)
        Samples   = $rows.Count
    }
}

# El citado por elemento vive en pipeline-lock.ps1 como Get-ArgLine desde el
# 04/09/2026: lo necesitaban dos ficheros y una segunda copia es como empiezan
# aqui todas las divergencias. Este script ya carga esa libreria.

# --- Ejecutar una tanda de K instancias en paralelo -----------------------
function Invoke-Batch([int]$K) {
    # Marca CLIP/FULL para los nombres de salida (ver el comentario del campo Out).
    $tagKind = if ($ClipSeconds -gt 0) { "CLIP{0:N0}s" -f $ClipSeconds } else { 'FULL' }
    # Ranuras: se cicla sobre los inputs resueltos para llenar K huecos.
    $slots = @()
    for ($i = 0; $i -lt $K; $i++) {
        $src = $Resolved[$i % $Resolved.Count]
        $slotTmp = Join-Path $RunDir ("k{0}_slot{1}" -f $K, $i)
        New-Item -ItemType Directory -Force -Path $slotTmp | Out-Null
        $slots += [pscustomobject]@{
            Idx     = $i
            Input   = $src.Path
            AudioSec= $src.DurationSec
            Channels= $src.Channels
            BigTmp  = $slotTmp
            # Nombre AUTODESCRIPTIVO: lleva el titulo y si es CLIP o FULL. Con el
            # nombre generico anterior ("k2_slot1.ec3") una tanda de clips y una de
            # peliculas completas COLISIONAN, y si un nivel full se salta por
            # espacio te quedas con un .ec3 de 4 minutos con pinta de pelicula
            # entera. Muxear eso seria perdida silenciosa. Con el sufijo es
            # imposible confundirlos, y los FULL se pueden reaprovechar.
            Out     = Join-Path $OutDir ("{0}_a{1}_{2}_k{3}_slot{4}.ec3" -f `
                        ([System.IO.Path]::GetFileNameWithoutExtension($src.Path) -replace '[^\w\-]','_'), `
                        $EffectiveIndex, $tagKind, $K, $i)
            SlotLog = Join-Path $slotTmp 'slot.log'
            Result  = Join-Path $slotTmp 'result.json'
        }
    }

    # K<1 no es una tanda: sin ranuras, mas abajo se indexa $slots[0] y el
    # script muere con un error que no dice nada de la causa.
    if ($K -lt 1) {
        Log ("K={0}: no es un nivel valido (hace falta K>=1). Nivel SALTADO." -f $K)
        return [pscustomobject]@{ K = $K; Skipped = $true }
    }

    # Techo de CPU: no oversuscribir. Deja ReserveCores fisicos libres SIEMPRE.
    if ($K -gt $MaxK) {
        Log ("K={0}: supera el techo de CPU (K<={1}, reservo {2} nucleos). Nivel SALTADO." -f $K, $MaxK, $ReserveCores)
        return [pscustomobject]@{ K = $K; Skipped = $true }
    }

    # Chequeo de RAM: que quede MinFreeRamGB libre tras arrancar las K instancias.
    $ramFree = Get-FreeRamGB
    $ramNeed = $K * $RamPerInstanceGB
    if (($ramFree - $ramNeed) -lt $MinFreeRamGB) {
        Log ("K={0}: RAM justa ({1:N1} GB libres, ~{2:N1} GB para {0} instancias, minimo a dejar {3:N1}). Nivel SALTADO." -f $K, $ramFree, $ramNeed, $MinFreeRamGB)
        return [pscustomobject]@{ K = $K; Skipped = $true }
    }

    # Chequeo de espacio: suma de lo que necesita cada ranura. Si no cabe, se SALTA.
    $need = 0L
    foreach ($s in $slots) {
        $need += Get-DdpSpaceNeeded -DurationSec $s.AudioSec -Channels $s.Channels -IsAtmos -Bitrate $Bitrate -MarginGB $MarginGB
    }
    $free = Get-FreeBytes $BigTmpRoot
    $fmt = { param($b) "{0:N1} GB" -f ($b / 1GB) }
    Log ("K={0}: necesito {1} en {2}, hay {3} libres." -f $K, (& $fmt $need), $BigTmpRoot, (& $fmt $free))
    if ($free -ge 0 -and $free -lt $need) {
        Log ("K={0}: NO CABE en $BigTmpRoot. Nivel SALTADO (sin esto reventaria a mitad). Usa -ClipSeconds para probar K altos." -f $K)
        return [pscustomobject]@{ K = $K; Skipped = $true }
    }

    # Muestreador de disco arrancado justo antes de lanzar.
    $stopFile = Join-Path $slots[0].BigTmp '..\sampler.stop'
    $stopFile = [System.IO.Path]::GetFullPath($stopFile)
    Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue
    $diskCsv  = Join-Path $RunDir ("disk_k{0}.csv" -f $K)
    $sampler  = Start-DiskSampler -StopFile $stopFile -CsvOut $diskCsv

    Log ("K={0}: lanzando {0} instancia(s)..." -f $K)
    $procs = @()
    $batch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($s in $slots) {
        $argsArr = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $WorkerPath,
            '-InputFile',   $s.Input,
            '-AudioIndex',  $EffectiveIndex,
            '-Bitrate',     $Bitrate,
            '-BigTmp',      $s.BigTmp,
            '-OutFile',     $s.Out,
            '-DurationSec', $s.AudioSec,
            '-Channels',    $s.Channels,
            '-LibPath',     $AtmosLib,
            '-SlotLog',     $s.SlotLog,
            '-ResultFile',  $s.Result
        )
        $argline = Get-ArgLine $argsArr
        $p = Start-Process -FilePath 'pwsh' -ArgumentList $argline -NoNewWindow -PassThru
        $null = $p.Handle   # sin tocar Handle, ExitCode puede venir a null tras salir
        $procs += $p
    }
    foreach ($p in $procs) { $p.WaitForExit() }
    $batch.Stop()

    # Parar el muestreador (crea el stop-file) y esperar a que su proceso salga.
    Set-Content -LiteralPath $stopFile -Value 'stop' -Encoding ASCII
    if (-not $sampler.WaitForExit(10000)) { try { $sampler.Kill() } catch { } }
    Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue
    $disk = Summarize-Disk $diskCsv

    # Resultados por ranura.
    $rows = @()
    foreach ($s in $slots) {
        $r = $null
        if (Test-Path -LiteralPath $s.Result) {
            try { $r = Get-Content -LiteralPath $s.Result -Raw | ConvertFrom-Json } catch { }
        }
        $rows += [pscustomobject]@{
            Slot     = $s.Idx
            Ok       = if ($r) { [bool]$r.ok } else { $false }
            Seconds  = if ($r) { [double]$r.seconds } else { 0 }
            AudioSec = $s.AudioSec
            DeeEnc   = if ($r -and $r.deeEnc) { [double]$r.deeEnc } else { 0 }
            Failure  = if ($r) { "$($r.failure)" } else { 'sin-result' }
        }
    }

    $okRows   = @($rows | Where-Object { $_.Ok })
    # SOLO EL AUDIO QUE DE VERDAD SE CODIFICO (04/09/2026).
    # Antes se sumaba el AudioSec de TODAS las ranuras, tambien el de las que
    # habian reventado. Y como una ranura que revienta acaba ANTES, la tanda
    # dura menos: el nivel que fallaba la mitad de sus instancias salia con el
    # DOBLE de xRT_agg que ese mismo nivel funcionando (medido con 4 ranuras de
    # 7000 s: imprimia 23,3 donde lo real eran 11,7). O sea que el nivel mas
    # roto se llevaba el mejor numero de la tabla, que es justo el numero por
    # el que uno mira esta tabla. El punto dulce ya excluia los niveles con
    # fallos, pero el resumen no, y el resumen es lo que se lee y se cita.
    $sumAudio = ($okRows | Measure-Object -Property AudioSec -Sum).Sum
    if ($null -eq $sumAudio) { $sumAudio = 0 }   # Measure-Object sobre vacio da $null
    $batchSec = [math]::Round($batch.Elapsed.TotalSeconds, 1)
    # Throughput agregado: segundos de audio codificados por segundo de reloj (xRT).
    $aggThr   = if ($batchSec -gt 0) { [math]::Round($sumAudio / $batchSec, 3) } else { 0 }
    $meanSlot = if ($okRows.Count -gt 0) { [math]::Round((($okRows | Measure-Object -Property Seconds -Average).Average), 1) } else { 0 }

    # xRT de la FASE DEE por instancia: segundos de audio / segundos de encoder pass.
    # Inmune a la cache de disco (ver el comentario del worker). Si este numero se
    # mantiene al subir K, la CPU no se esta estorbando y paralelizar sale gratis en
    # la parte cara; si cae, es que si se estorban.
    $deeRows = @($okRows | Where-Object { $_.DeeEnc -gt 0 })
    $deeXrt  = if ($deeRows.Count -gt 0) {
                   [math]::Round((($deeRows | ForEach-Object { $_.AudioSec / $_.DeeEnc } | Measure-Object -Average).Average), 2)
               } else { 0 }
    $deeMean = if ($deeRows.Count -gt 0) { [math]::Round((($deeRows | Measure-Object -Property DeeEnc -Average).Average), 1) } else { 0 }

    return [pscustomobject]@{
        K         = $K
        Skipped   = $false
        BatchSec  = $batchSec
        AggThru   = $aggThr        # xRT agregado
        DeeXrt    = $deeXrt        # xRT de la fase DEE por instancia (metrica limpia)
        DeeMean   = $deeMean       # s de encoder pass por instancia
        MeanSlot  = $meanSlot      # s por instancia (media de las que fueron OK)
        OkCount   = $okRows.Count
        FailCount = $rows.Count - $okRows.Count
        Failures  = (@($rows | Where-Object { -not $_.Ok } | ForEach-Object { "s$($_.Slot):$($_.Failure)" }) -join '; ')
        Disk      = $disk
        Rows      = $rows
    }
}

# ===========================================================================
#  BUCLE PRINCIPAL
# ===========================================================================
Section "Benchmark DD+ Atmos: secuencial vs paralelo"
Log "Inputs: $($Resolved.Count) distinto(s) | AudioIndex efectivo: $EffectiveIndex | Bitrate: $Bitrate | BigTmp: $BigTmpRoot"
if ($ClipSeconds -gt 0) { Log "Modo CLIP: $ClipSeconds s por instancia (solo para escalado; no juzga calidad)." }

$results = @()
foreach ($K in ($Throttles | Sort-Object -Unique)) {
    Section "Nivel K = $K"
    $results += Invoke-Batch -K $K
}

# --- Baseline (K=1) para eficiencia ----------------------------------------
$base = $results | Where-Object { -not $_.Skipped -and $_.K -eq 1 } | Select-Object -First 1
$thr1 = if ($base) { $base.AggThru } else { $null }
# Referencia de la fase DEE en solitario. Es la buena para juzgar: no la mueve la
# cache de disco. Si DEE_efic se mantiene cerca del 100% al subir K, la CPU no es
# el cuello y paralelizar sale gratis en la parte cara.
$deeBase = if ($base -and $base.DeeXrt -gt 0) { $base.DeeXrt } else { $null }

Section "RESUMEN"
$table = foreach ($r in ($results | Sort-Object K)) {
    if ($r.Skipped) {
        [pscustomobject]@{ K=$r.K; 'Cabe?'='NO'; 'Tanda(s)'='-'; 'xRT_agg'='-'; 'Speedup'='-'; 'Efic.'='-'; 'DEE_xRT'='-'; 'DEE_efic'='-'; 'OK/Fail'='-'; 'Disco idle/colaMax'='-' }
    } else {
        $speedup = if ($thr1) { [math]::Round($r.AggThru / $thr1, 2) } else { $null }
        $effic   = if ($thr1) { "{0:N0}%" -f (100 * $r.AggThru / ($thr1 * $r.K)) } else { '-' }
        $diskStr = if ($r.Disk) { "{0} / {1}" -f $r.Disk.IdleAvg, $r.Disk.QueueMax } else { '-' }
        # Eficiencia DEE: cuanto conserva cada instancia de su ritmo en solitario.
        # 100% = las instancias no se estorban en la parte cara (CPU).
        $deeEff = if ($deeBase -and $r.DeeXrt -gt 0) { "{0:N0}%" -f (100 * $r.DeeXrt / $deeBase) } else { '-' }
        [pscustomobject]@{
            K = $r.K
            'Cabe?' = 'si'
            'Tanda(s)' = $r.BatchSec
            'xRT_agg' = $r.AggThru
            'Speedup' = if ($null -ne $speedup) { "{0}x" -f $speedup } else { '-' }
            'Efic.' = $effic
            'DEE_xRT' = $r.DeeXrt
            'DEE_efic' = $deeEff
            'OK/Fail' = "$($r.OkCount)/$($r.FailCount)"
            'Disco idle/colaMax' = $diskStr
        }
    }
}
$table | Format-Table -AutoSize | Out-String | Write-Host

# --- Interpretacion automatica ---------------------------------------------
Write-Host ""
Write-Host "Como leerlo:" -ForegroundColor Yellow
Write-Host "  - xRT_agg  = segundos de audio CODIFICADOS CON EXITO por segundo de reloj. Mas alto = mejor."
Write-Host "               Las ranuras que fallan no cuentan: si no, el nivel mas roto ganaba la tabla."
Write-Host "  - Speedup  = xRT_agg respecto a K=1. Ideal = K (2x a K=2, 4x a K=4). Lo que falte es contencion."
Write-Host "  - Efic.    = Speedup/K. 100% = escala perfecto; cae segun CPU y disco empiezan a disputarse."
Write-Host "  - Disco    = % de inactividad medio y cola maxima del disco de $BigTmpRoot. Si idle% se hunde y la"
Write-Host "               cola sube al subir K, el cuello es el DISCO, no la CPU (ver disco-contencion-manda-sobre-velocidad)."
Write-Host "  - 'Cabe? NO' = ese K no entra en $BigTmpRoot con pelis completas: el limite real es ESPACIO, no nucleos."

# Recomendacion de punto dulce.
# El comentario que habia aqui decia "mayor K con eficiencia razonable", pero el
# codigo se quedaba con el K de mayor throughput A SECAS: no miraba la eficiencia
# para nada. Con eso, un K=4 que diera un 1 % mas que K=2 se recomendaba igual, o
# sea gastar el doble de nucleos por un 1 %.
# Ahora se busca el pico y se recomienda el K MAS PEQUENYO que quede a menos de un
# 3 % de el. Es lo que pide la cabecera del script ("el punto donde la CONTENCION
# deja de compensar") y deja nucleos para el video y el panel, que es de lo que va
# $ReserveCores. Si el pico y la recomendacion no coinciden, se dicen los dos.
$viables = @($results | Where-Object { -not $_.Skipped -and $_.FailCount -eq 0 -and $_.K -ge 1 })
if ($thr1 -and $viables.Count -gt 0) {
    $pico = $viables | Sort-Object { $_.AggThru } -Descending | Select-Object -First 1
    $best = $viables | Where-Object { $_.AggThru -ge ($pico.AggThru * 0.97) } | Sort-Object K | Select-Object -First 1
    $bestEff = [math]::Round(100 * $best.AggThru / ($thr1 * $best.K), 0)
    Write-Host ""
    Write-Host ("PUNTO DULCE medido: K={0}  ({1}x mas throughput que secuencial, eficiencia {2}%)." -f $best.K, ([math]::Round($best.AggThru/$thr1,2)), $bestEff) -ForegroundColor Green
    if ($best.K -ne $pico.K) {
        Write-Host ("   El pico bruto esta en K={0} ({1}x), pero solo un {2:N1} % por encima: no compensa ocupar {3} nucleo(s) mas." -f `
            $pico.K, ([math]::Round($pico.AggThru/$thr1,2)), (100*($pico.AggThru/$best.AggThru - 1)), ($pico.K - $best.K)) -ForegroundColor DarkGray
    }
    # xRT ya es "segundos de audio por segundo de reloj", que es lo mismo que
    # "minutos por minuto". Antes ponia (AggThru*60/60), que no convertia nada.
    Write-Host ("Traducido: {0:N1} min de audio codificados por minuto de reloj, frente a {1:N1} en secuencial." -f $best.AggThru, $thr1)
}

# --- CSV para conservar -----------------------------------------------------
$csvPath = Join-Path $OutDir ("bench_summary_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$table | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
Log "Resumen guardado en $csvPath"
Log "Logs y result.json por ranura en $RunDir (borralo cuando termines: puede tener varios GB de temporales huerfanos si algo murio)."
Write-Host ""
Log "Hecho."
