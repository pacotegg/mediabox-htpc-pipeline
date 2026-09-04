<#
============================================================================
 icq-probe.ps1     El GQ manda algo, o no?
============================================================================
 CONTEXTO (29/07): la suite 'gq' de ab-test.ps1 dio esto con -b:v 8M puesto:
     GQ 14 -> 168.95 MB     GQ 15 -> 169.22 MB
     GQ 16 -> 168.94 MB     GQ 17 -> 168.43 MB
 Tres puntos de GQ movieron el tamano un 0.47 %, y de forma NO monotona (GQ 16
 salio "mejor" que GQ 14). Eso no es una curva de calidad: es ruido alrededor
 de un valor fijo. 169.22 MB en 180 s son 7.89 Mbps, y -b:v era 8M: el encoder
 parece estar haciendo VBR contra el bitrate, con global_quality sin pintar
 nada o casi.

 ESTA PRUEBA lo resuelve: quita -b:v/-maxrate/-bufsize y deja al encoder en ICQ
 puro, donde el GQ es lo UNICO que puede decidir el tamano.
   - Tamanos muy distintos -> el GQ funciona, y -b:v lo estaba pisando.
     Habria que replantear como se combinan GQ y bitrate en encode.ps1.
   - Tamanos parecidos     -> el GQ es decoracion y el pipeline es VBR puro.
     La tabla GQ 15/18/18/19 no estaria haciendo nada.

 Con -Av1 hace ademas una pasada con av1_qsv para medir el coste en tiempo del
 encoder AV1 de la Arc. OJO al interpretarla: si AV1 tambien obedece a -b:v,
 saldra al mismo tamano que el HEVC y lo unico informativo seran los SEGUNDOS.

 Uso:
   .\icq-probe.ps1
   .\icq-probe.ps1 -Av1
   .\icq-probe.ps1 -Source "E:\ruta\peli.mkv"
============================================================================
#>

param(
    [string]$Source = "",
    [string]$Start  = "01:20:00",
    [int]$Seconds   = 180,
    # Rama de produccion a replicar: carga los filtros y el GQ de referencia.
    [ValidateSet('4K','1080p')][string]$Res = '4K',
    [int[]]$Gqs     = @(),
    [string]$Vf     = "",
    [switch]$Av1,
    [string]$OutDir = "C:\Media\tmp\ab"
)

# --- Perfiles de produccion (ESPEJO de encode.ps1) -------------------------
# ESTABA DESFASADO CINCO SEMANAS (04/09/2026). Ponia 'ESPEJO de encode.ps1,
# 30/07' y llevaba denoise 8 en 4K, denoise 5 y GQ 19 en 1080p, y detail 0 en
# las dos ramas. Produccion va desde el 07/08 con denoise 7, detail 6 y GQ 15
# en ambas. El propio comentario avisaba -'si tocas encode.ps1, toca esto o
# mediras una configuracion que ya no existe'- y es exactamente lo que paso:
# un acuerdo escrito que no vigila nadie no se cumple.
# AHORA LO VIGILA pruebas/test-espejo-abtest.ps1 en cada pasada de la suite.
#
# De donde sale cada numero (encode.ps1):
#   $dGq   -> la tabla de $BaseGq        (~1818)
#   $dRate -> la tabla de $Target, Movie (~1547)
#   $dMaxR -> $dRate x1.35 en 4K, x1.30 en 1080p ($MaxRateFactor, ~1760)
#   $dBufS -> $dMaxR x1.5                (~1762)
#   $dDn / $dDt -> $Denoise / $Detail    (~1898). No dependen de la resolucion.
#   $dPreset    -> $Preset               (~331)
# Se usa la MISMA forma que ab-test.ps1 a proposito: asi el test de espejos lee
# los dos ficheros con el mismo patron.
if ($Res -eq '1080p') { $dDn = 7; $dDt = 6; $dGq = 15; $dRate = '5.0M'; $dMaxR = '6.5M';  $dBufS = '10M' }
else                  { $dDn = 7; $dDt = 6; $dGq = 15; $dRate = '9.5M'; $dMaxR = '12.8M'; $dBufS = '19M' }
$dPreset = 'medium'
# ${dDn} y no $dDn: detras va un ':' y PowerShell lo leeria como calificador de
# unidad, dejando la cadena del filtro rota.
$dVf = "vpp_qsv=denoise=${dDn}:detail=${dDt}:format=p010le"
# El barrido por defecto se centra en el GQ de produccion, no en un 15 fijo.
$dGqs = @(($dGq - 3), $dGq, ($dGq + 4), ($dGq + 8))
if (-not $Vf)          { $Vf  = $dVf }
if ($Gqs.Count -eq 0)  { $Gqs = $dGqs }

$ErrorActionPreference = "Continue"
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

# Las rutas de herramientas salen de mediabox-paths.ps1, la unica definicion
# del pipeline (31/08/2026). Se carga explicitamente porque este script no
# usa ninguna de las dos librerias que ya la traen.
$PathsLib = 'C:\scripts\mediabox-paths.ps1'
if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
else { Write-Host 'ERROR: falta mediabox-paths.ps1'; exit 1 }

# $FFMPEG los da mediabox-paths.ps1 (31/08/2026: estaban copiados aqui).
# El respaldo al nombre suelto lo aplica ya mediabox-paths.ps1 (31/08/2026).

# Si no se pasa -Source, se busca solo. Asi no hay que teclear la enye ni
# arriesgarse a que la ruta se corrompa al copiar y pegar.
# Orden: primero C:\Media (NVMe, sin la latencia del DAS por USB), luego
# E:\Peliculas como respaldo.
if (-not $Source) {
    $hit = Get-ChildItem "C:\Media" -File -Filter *.mkv -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'retorno.*rey' } | Select-Object -First 1
    if (-not $hit) {
        $hit = Get-ChildItem "E:\Peliculas" -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'retorno.*rey' } | Select-Object -First 1
    }
    if ($hit) { $Source = $hit.FullName }
}
if (-not $Source -or -not (Test-Path -LiteralPath $Source)) {
    Write-Host "No encuentro la fuente. Pasala a mano:" -ForegroundColor Red
    Write-Host '  .\icq-probe.ps1 -Source "E:\Peliculas\...\peli.mkv"' -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "Fuente : $Source"
Write-Host "Rama   : $Res  ($Vf)"
Write-Host "Clip   : $Start + ${Seconds}s"
Write-Host ""

# --- Paso 0: PREGUNTARLE a ffmpeg en que modo esta -----------------------
# ffmpeg anuncia en el log verbose el modo de rate control que ha seleccionado.
# Esto es una respuesta DIRECTA; el barrido de abajo solo lo infiere de los
# tamanos. Cuesta 2 segundos de clip y deberia haber sido lo primero que se
# mirase en toda esta investigacion.
Write-Host "--- Modo de rate control que selecciona ffmpeg (con los flags de produccion) ---"
$vb = @(
    '-v','verbose','-hwaccel','qsv','-hwaccel_output_format','qsv',
    '-ss',$Start,'-t','2','-i',$Source,
    '-map','0:v:0','-an','-sn',
    '-vf',$Vf,
    '-c:v','hevc_qsv','-preset',$dPreset,
    '-global_quality',"$dGq",'-b:v',$dRate,'-maxrate',$dMaxR,'-bufsize',$dBufS,
    '-profile:v','main10','-g','240','-f','null','NUL'
)
$vbOut = & $FFMPEG @vb 2>&1
$hit = $vbOut | Select-String -Pattern 'RateControl|ratecontrol|QVBR|ICQ|CQP|AVBR|VBR|CBR|Quality|GlobalQuality|TargetKbps'
if ($hit) { $hit | ForEach-Object { "  $_" } }
else {
    Write-Host "  (no se encontro la linea; volcado completo en rc_verbose.txt)"
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'rc_verbose.txt'), ($vbOut -join "`r`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}
Write-Host ""
Write-Host "--- ICQ puro (sin -b:v, sin -maxrate): manda solo el GQ ---"

$sizes = @()
foreach ($q in $Gqs) {
    $o = Join-Path $OutDir "icq$q.mkv"
    Remove-Item -LiteralPath $o -ErrorAction SilentlyContinue
    $a = @(
        '-y','-hwaccel','qsv','-hwaccel_output_format','qsv',
        '-ss',$Start,'-t',"$Seconds",'-i',$Source,
        '-map','0:v:0','-an','-sn',
        '-vf',$Vf,
        '-c:v','hevc_qsv','-preset',$dPreset,
        '-global_quality',"$q",
        '-bf','3','-refs','4','-b_strategy','1',
        '-profile:v','main10','-g','240', $o
    )
    $t = Measure-Command { & $FFMPEG @a 2>&1 | Out-Null }
    if (Test-Path -LiteralPath $o) {
        $mb = (Get-Item -LiteralPath $o).Length/1MB
        $sizes += $mb
        "  GQ {0,-3} {1,8:N2} MB   {2,6:N2} Mbps   {3} s" -f $q, $mb, ($mb*8*1MB/$Seconds/1e6), [int]$t.TotalSeconds
    } else {
        "  GQ {0,-3} FALLO" -f $q
    }
}

Write-Host ""
if ($sizes.Count -ge 2) {
    $mn = ($sizes | Measure-Object -Minimum).Minimum
    $mx = ($sizes | Measure-Object -Maximum).Maximum
    $spread = (($mx - $mn) / $mn) * 100
    "  Dispersion entre el GQ mas alto y el mas bajo: {0:N1} %" -f $spread
    Write-Host ""
    if ($spread -lt 2) {
        Write-Host "  VEREDICTO: el GQ NO manda ni en ICQ puro. Es decoracion." -ForegroundColor Yellow
        Write-Host "  La tabla de GQ de encode.ps1 (4K HDR 15, 4K SDR 16, 1080p 15) no" -ForegroundColor Yellow
        Write-Host "  estaria haciendo nada y el tamano lo decidiria -b:v entero." -ForegroundColor Yellow
    } elseif ($spread -gt 10) {
        Write-Host "  VEREDICTO: el GQ SI funciona. Era -b:v quien lo estaba pisando." -ForegroundColor Green
        Write-Host "  Hay que revisar como se combinan GQ y bitrate en encode.ps1: tal" -ForegroundColor Green
        Write-Host "  como esta, el bitrate anula la intencion del GQ." -ForegroundColor Green
    } else {
        Write-Host "  VEREDICTO: zona gris. El GQ hace algo pero poco. Repite con un" -ForegroundColor Cyan
        Write-Host "  rango mas ancho:  .\icq-probe.ps1 -Gqs 12,20,28,36" -ForegroundColor Cyan
    }
}

if ($Av1) {
    Write-Host ""
    Write-Host "--- AV1 por hardware (mismo clip, mismos parametros que el HEVC base) ---"
    $o = Join-Path $OutDir "av1_probe.mkv"
    Remove-Item -LiteralPath $o -ErrorAction SilentlyContinue
    $a = @(
        '-y','-hwaccel','qsv','-hwaccel_output_format','qsv',
        '-ss',$Start,'-t',"$Seconds",'-i',$Source,
        '-map','0:v:0','-an','-sn',
        '-vf',$Vf,
        # EL MISMO PRESET QUE EL HEVC (04/09/2026). El titulo de esta seccion
        # dice 'mismos parametros que el HEVC base' y corria en veryslow contra
        # el medium del HEVC: es literalmente el error que av1-vs-hevc.ps1
        # documenta haber corregido, repetido aqui.
        '-c:v','av1_qsv','-preset',$dPreset,
        '-global_quality',"$dGq",'-b:v',$dRate,'-maxrate',$dMaxR,'-bufsize',$dBufS,
        '-profile:v','main','-g','240', $o
    )
    $t = Measure-Command { $av1Out = & $FFMPEG @a 2>&1 }
    if ((Test-Path -LiteralPath $o) -and ((Get-Item -LiteralPath $o).Length -gt 0)) {
        $mb = (Get-Item -LiteralPath $o).Length/1MB
        # SIN REFERENCIA FIJA (04/09/2026). Aqui habia un "(HEVC base: 169.22 MB
        # en 65 s)" del 29/07, medido con veryslow, denoise 16 y detail 20. Ya no
        # es comparable con nada de lo que corre este script, y una cifra impresa
        # al lado se lee como si lo fuera.
        "  AV1  {0,8:N2} MB en {1} s   (GQ {2}, -b:v {3}, preset {4})" -f `
            $mb, [int]$t.TotalSeconds, $dGq, $dRate, $dPreset
        Write-Host "  NO es comparable con el barrido de arriba: aquel es ICQ puro"
        Write-Host "  y este lleva -b:v. Para un HEVC contra AV1 a igual tamano esta"
        Write-Host "  av1-vs-hevc.ps1, que busca el GQ que iguala los megabytes."
        Write-Host ""
        Write-Host "  Recuerda: si AV1 tambien obedece a -b:v, el tamano saldra parecido"
        Write-Host "  al del HEVC y NO significa nada. Lo informativo aqui son los segundos."
    } else {
        Write-Host "  AV1: FALLO (salida vacia o inexistente). Error de ffmpeg:" -ForegroundColor Red
        $err = $av1Out | Select-String -Pattern 'rror|nvalid|nsupported|not supported|failed|Cannot|No such'
        if ($err) { $err | Select-Object -Last 12 | ForEach-Object { "    $_" } }
        else { $av1Out | Select-Object -Last 12 | ForEach-Object { "    $_" } }
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'av1_error.txt'), ($av1Out -join "`r`n"),
            (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "    (volcado completo en $OutDir\av1_error.txt)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Ficheros en $OutDir. El script no borra nada."
