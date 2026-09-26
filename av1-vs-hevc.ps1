<#
============================================================================
 av1-vs-hevc.ps1     Comparacion JUSTA entre av1_qsv y hevc_qsv
============================================================================
 EL PROBLEMA QUE RESUELVE
 Comparar dos codecs a igual GQ no significa nada: las escalas de quantizador
 son distintas. Y compararlos a igual -b:v tampoco: los dos saldran al mismo
 tamano por construccion, que es lo que paso en la primera prueba del 29/07
 (AV1 157.73 MB contra HEVC 169.22 MB, ambos pegados al -b:v de 8M).
 La UNICA comparacion valida es a IGUAL TAMANO: se busca el GQ de AV1 que da
 los mismos megabytes que el HEVC de produccion, y ahi se compara la calidad.

 OTRO ERROR CORREGIDO: la primera medida daba AV1 en 42 s contra HEVC en 65 s,
 pero el AV1 corrio SIN -preset (default) y el HEVC en veryslow. No eran
 comparables. Aqui se fuerza EL MISMO preset en los dos; si av1_qsv lo rechaza,
 se reintenta sin el y se avisa en la salida.

 EL LADO HEVC ES UN ESPEJO DE PRODUCCION, y estaba DESFASADO (04/09/2026).
 Decia '-vf denoise=16:detail=20' y '-b:v 8M -maxrate 10.8M -bufsize 16M' con
 -preset veryslow, o sea la configuracion de julio. Produccion lleva desde el
 07/08 con denoise=7 detail=6, target 9.5M y preset medium. El script imprime
 la etiqueta 'HEVC de produccion (referencia)' encima de esa cifra, asi que el
 veredicto AV1-vs-HEVC se estaba dando contra un HEVC que no existe.
 Es el mismo fallo que ya se ha comido a ab-test.ps1 CINCO veces; por eso
 ahora lo vigila pruebas/test-espejo-abtest.ps1, que compara estos numeros
 con encode.ps1 en cada pasada de la suite.

 FASES
   1. HEVC de produccion, encode completo -> tamano de referencia y SSIM.
   2. Mapa grueso de AV1: barrido de GQ con clips de 20 s (rapido) para ver
      que rango de bitrate da cada GQ. Se necesita porque la escala de GQ de
      av1_qsv no es la de HEVC y no se sabe de antemano donde cae.
   3. Interpolacion: se elige el GQ de AV1 que deberia clavar el tamano HEVC.
   4. Encode AV1 completo a ese GQ + SSIM.
   5. Comparacion a igual tamano.

 NOTA SOBRE EL MODO: AV1 se usa en ICQ (solo -global_quality, sin -b:v) porque
 av1_qsv NO SOPORTA QVBR en este runtime (verificado el 29/07: qvbr, qvbr+prof
 y qvbr+preset fallan al inicializar; cqp, icq, vbr y vbr+maxrate funcionan).

 Uso:
   .\av1-vs-hevc.ps1
   .\av1-vs-hevc.ps1 -Start "00:45:00" -Seconds 180
============================================================================
#>

param(
    [string]$Source  = "",
    [string]$Start   = "01:20:00",
    [int]$Seconds    = 180,
    # --- ESPEJO DE PRODUCCION: Movie 4K HDR de encode.ps1 ------------------
    # Comprobado el 04/09/2026 y vigilado por pruebas/test-espejo-abtest.ps1.
    # De donde sale cada numero:
    #   HevcGq -> la tabla de $BaseGq, rama 4K HDR   (encode.ps1 ~1818)
    #   Rate   -> la tabla de $Target, Movie 4K HDR  (encode.ps1 ~1547)
    #   MaxR   -> Rate x1.35   ($MaxRateFactor, ~1760)
    #   BufS   -> MaxR x1.5    (~1762)
    #   Vf     -> $Denoise / $Detail  (~1898). NO dependen de la resolucion.
    #   Preset -> $Preset      (~331)
    [int]$HevcGq     = 15,
    [string]$Rate    = "9.0M",
    [string]$MaxR    = "12.2M",
    [string]$BufS    = "18M",
    [string]$Vf      = "vpp_qsv=denoise=7:detail=6:format=p010le",
    # El MISMO preset en los dos codecs: comparar veryslow contra el default
    # fue justo el error de la primera medida. Y es ademas el de produccion,
    # que en esta GPU da un bitstream casi identico a veryslow (+0,11 % de
    # tamano, -0,0000331 SSIM) a 108 fps en vez de 68.
    [string]$Preset  = "medium",
    [int[]]$Av1Sweep = @(12,15,18,21,24,28),
    [string]$OutDir  = "C:\Media\tmp\av1"
)

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
    Write-Host "No encuentro la fuente. Pasala con -Source." -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Push-Location $OutDir

function Invoke-Enc([string[]]$a, [string]$out) {
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    $t0 = Get-Date
    $o = & $FFMPEG @a 2>&1
    # EL CODIGO DE SALIDA NO ES OPCIONAL AQUI (04/09/2026).
    # Antes bastaba con que el fichero existiera y no estuviera vacio. MEDIDO:
    # un ffmpeg matado a los 6 s de un encode de 600 s sale con codigo 137 y
    # deja 3,9 MB de video perfectamente reproducibles -> se daba por bueno.
    # En ESTE script eso no es un fallo cualquiera, porque la comparacion es
    # POR TAMANO: un AV1 que muere a mitad pesa menos y el script imprime
    # "a tamano equiparable AV1 comprime mejor". El SSIM tampoco lo delata,
    # porque el filtro ssim compara hasta que se acaba el mas corto de los dos.
    # Un encode roto se convertia en una conclusion de codec del reves.
    $rc   = $LASTEXITCODE
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    $okFile = (Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out).Length -gt 0)
    $ok = ($rc -eq 0) -and $okFile
    if ($okFile -and $rc -ne 0) {
        Write-Host ("  ffmpeg salio con codigo {0} y AUN ASI dejo {1:N2} MB en {2}: encode INCOMPLETO, se descarta." -f `
            $rc, ((Get-Item -LiteralPath $out).Length / 1MB), (Split-Path $out -Leaf)) -ForegroundColor Red
    }
    return [pscustomobject]@{ Ok=$ok; Rc=$rc; Seconds=$secs; Out=$o
        Bytes=$(if ($ok) { (Get-Item -LiteralPath $out).Length } else { 0 }) }
}

function Get-Ssim([string]$enc, [string]$stats) {
    Remove-Item -LiteralPath $stats -ErrorAction SilentlyContinue
    & $FFMPEG -v error -ss $Start -t "$Seconds" -i $Source -i $enc `
        -lavfi "[0:v]setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];[a][b]ssim=stats_file=$stats" `
        -f null NUL 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath $stats)) { return $null }
    $v = @(Select-String -Path $stats -Pattern 'All:([0-9.]+)' |
           ForEach-Object { [double]$_.Matches[0].Groups[1].Value })
    if ($v.Count -eq 0) { return $null }
    return ($v | Measure-Object -Average).Average
}

$common = @('-y','-hwaccel','qsv','-hwaccel_output_format','qsv',
            '-ss',$Start,'-t',"$Seconds",'-i',$Source,
            '-map','0:v:0','-an','-sn','-vf',$Vf)

Write-Host "Fuente : $Source"
Write-Host "Clip   : $Start + ${Seconds}s"
Write-Host ""

# --- FASE 1: HEVC de produccion ------------------------------------------
Write-Host "=== FASE 1: HEVC de produccion (referencia) ==="
$hevcOut = "hevc_ref.mkv"
$hevcArgs = $common + @(
    '-c:v','hevc_qsv','-preset',$Preset,'-global_quality',"$HevcGq",
    '-b:v',$Rate,'-maxrate',$MaxR,'-bufsize',$BufS,
    '-extbrc','1','-look_ahead_depth','60','-adaptive_i','1','-adaptive_b','1',
    '-b_strategy','1','-mbbrc','1','-rdo','1','-scenario','archive',
    '-bf','3','-refs','4','-profile:v','main10','-g','240', $hevcOut)
$h = Invoke-Enc $hevcArgs $hevcOut
if (-not $h.Ok) { Write-Host "  El HEVC de referencia fallo. Abortando." -ForegroundColor Red; Pop-Location; exit 1 }
$hevcMB = $h.Bytes/1MB
$hevcMbps = $hevcMB*8*1MB/$Seconds/1e6
"  HEVC: {0,7:N2} MB  {1,5:N2} Mbps  en {2} s" -f $hevcMB,$hevcMbps,$h.Seconds

# --- FASE 2: mapa grueso de AV1 (clips de 20 s) --------------------------
Write-Host ""
Write-Host "=== FASE 2: donde cae cada GQ de AV1 (clips de 20 s) ==="
Write-Host "    (la escala de GQ de AV1 no es la de HEVC: hay que mapearla)"
$usePreset = $true
$map = @()

function Probe-Gq([int]$q) {
    # Encode corto de 20 s solo para saber a que bitrate cae ese GQ. Devuelve
    # Mbps, o 0 si fallo. Usa $script: para el flag del preset porque las
    # funciones ven un ambito hijo.
    $o = "av1_map_$q.mkv"
    $mk = {
        param($withPreset)
        $a = @('-y','-hwaccel','qsv','-hwaccel_output_format','qsv',
               '-ss',$Start,'-t','20','-i',$Source,'-map','0:v:0','-an','-sn','-vf',$Vf,
               '-c:v','av1_qsv','-global_quality',"$q",'-g','240')
        if ($withPreset) { $a += @('-preset',$Preset) }
        return ($a + @($o))
    }
    $r = Invoke-Enc (& $mk $script:usePreset) $o
    if (-not $r.Ok -and $script:usePreset) {
        Write-Host "    av1_qsv rechaza -preset $Preset`: reintento sin el." -ForegroundColor Yellow
        $script:usePreset = $false
        $r = Invoke-Enc (& $mk $false) $o
    }
    $mbps = 0
    if ($r.Ok) { $mbps = ($r.Bytes/1MB)*8*1MB/20/1e6 }
    Remove-Item -LiteralPath $o -ErrorAction SilentlyContinue
    return $mbps
}

foreach ($q in $Av1Sweep) {
    $m = Probe-Gq $q
    if ($m -gt 0) {
        $map += [pscustomobject]@{ Gq=$q; Mbps=$m }
        "  GQ {0,-4} {1,6:N2} Mbps" -f $q,$m
    } else {
        "  GQ {0,-4} FALLO" -f $q
    }
}
if ($map.Count -lt 2) { Write-Host "  Mapa insuficiente. Abortando." -ForegroundColor Red; Pop-Location; exit 1 }
if (-not $usePreset) {
    Write-Host "  AVISO: AV1 corre SIN preset y HEVC en $Preset. Los tiempos NO" -ForegroundColor Yellow
    Write-Host "  son comparables; el tamano y el SSIM si." -ForegroundColor Yellow
}

# --- FASE 3: afinar y elegir el GQ que iguala el tamano del HEVC ---------
# El mapa grueso casi nunca cae justo, y la escala de AV1 tiene un ACANTILADO:
# medido el 29/07, GQ 20 daba 7.42 Mbps y GQ 30 solo 1.26. Sin afinar, el
# resultado sale a un tamano distinto y la comparacion no vale (paso: -4.3 %).
$target = $hevcMbps

# Si el objetivo pide mas bitrate que el GQ mas bajo del barrido, hay que bajar.
$guard = 0
while ($guard -lt 6) {
    $lowest = $map | Sort-Object Gq | Select-Object -First 1
    if ($target -le $lowest.Mbps -or $lowest.Gq -le 1) { break }
    $q = [math]::Max(1, $lowest.Gq - 3)
    $m = Probe-Gq $q
    if ($m -le 0) { break }
    $map += [pscustomobject]@{ Gq=$q; Mbps=$m }
    "  GQ {0,-4} {1,6:N2} Mbps  (ampliando por abajo)" -f $q,$m
    $guard++
}

# Afinado de 1 en 1 dentro del par que rodea al objetivo.
$map = $map | Sort-Object Gq
$lo = $map | Where-Object { $_.Mbps -ge $target } | Select-Object -Last 1
$hi = $map | Where-Object { $_.Mbps -lt $target } | Select-Object -First 1
if ($lo -and $hi -and ($hi.Gq - $lo.Gq) -gt 1) {
    for ($q = $lo.Gq + 1; $q -lt $hi.Gq; $q++) {
        $m = Probe-Gq $q
        if ($m -le 0) { continue }
        $map += [pscustomobject]@{ Gq=$q; Mbps=$m }
        "  GQ {0,-4} {1,6:N2} Mbps  (afinando)" -f $q,$m
        if ($m -lt $target) { break }
    }
    $map = $map | Sort-Object Gq
    $lo = $map | Where-Object { $_.Mbps -ge $target } | Select-Object -Last 1
    $hi = $map | Where-Object { $_.Mbps -lt $target } | Select-Object -First 1
}

if ($lo -and $hi) {
    # Se queda con el mas cercano al objetivo, no con una interpolacion: los
    # clips de 20 s tienen ruido y afinar mas de la cuenta es falsa precision.
    $pick = $(if ([math]::Abs($lo.Mbps-$target) -le [math]::Abs($hi.Mbps-$target)) { $lo.Gq } else { $hi.Gq })
} elseif ($lo) { $pick = ($map | Sort-Object Gq | Select-Object -Last 1).Gq }
else           { $pick = ($map | Sort-Object Gq | Select-Object -First 1).Gq }

Write-Host ""
Write-Host "=== FASE 3: GQ de AV1 elegido para igualar $([math]::Round($target,2)) Mbps -> $pick ==="
if (-not $lo -or -not $hi) {
    Write-Host "  AVISO: el objetivo sigue fuera del rango. Amplia -Av1Sweep a mano." -ForegroundColor Yellow
}

# --- FASE 4: encode AV1 completo + SSIM de ambos -------------------------
Write-Host ""
Write-Host "=== FASE 4: encode AV1 completo y SSIM de los dos ==="
$av1Out = "av1_gq$pick.mkv"
$a = @('-y','-hwaccel','qsv','-hwaccel_output_format','qsv',
       '-ss',$Start,'-t',"$Seconds",'-i',$Source,'-map','0:v:0','-an','-sn','-vf',$Vf,
       '-c:v','av1_qsv','-global_quality',"$pick",'-g','240')
if ($usePreset) { $a += @('-preset',$Preset) }
$a += @($av1Out)
[System.IO.File]::WriteAllText((Join-Path (Get-Location).Path "cmd_av1_gq$pick.txt"),
    ('"' + $FFMPEG + '" ' + ($a -join ' ')), (New-Object System.Text.UTF8Encoding($false)))
$v = Invoke-Enc $a $av1Out
if (-not $v.Ok) { Write-Host "  El AV1 completo fallo." -ForegroundColor Red; Pop-Location; exit 1 }
$av1MB = $v.Bytes/1MB

Write-Host "  calculando SSIM del HEVC..."
$sH = Get-Ssim $hevcOut "hevc_ref_ssim.txt"
Write-Host "  calculando SSIM del AV1..."
$sA = Get-Ssim $av1Out "av1_gq${pick}_ssim.txt"

# --- RESULTADO ------------------------------------------------------------
Write-Host ""
Write-Host "=== RESULTADO ==="
$rows = @(
    [pscustomobject]@{ Codec='HEVC (QVBR GQ '+$HevcGq+')'; MB=[math]::Round($hevcMB,2)
        Mbps=[math]::Round($hevcMbps,2); SSIM=$(if ($sH) { '{0:F6}' -f $sH } else { 'n/a' }); Seg=$h.Seconds }
    [pscustomobject]@{ Codec='AV1 (ICQ GQ '+$pick+')'; MB=[math]::Round($av1MB,2)
        Mbps=[math]::Round($av1MB*8*1MB/$Seconds/1e6,2); SSIM=$(if ($sA) { '{0:F6}' -f $sA } else { 'n/a' }); Seg=$v.Seconds }
)
$rows | Format-Table -AutoSize

Pop-Location
Write-Host ""
$dm = (($av1MB - $hevcMB) / $hevcMB) * 100
"  Diferencia de tamano: {0:+0.0;-0.0;0.0} %" -f $dm
if ($sH -and $sA) {
    "  Diferencia de SSIM  : {0:+0.0000;-0.0000;0.0000} (x1000)" -f (($sA - $sH) * 1000)
    Write-Host ""
    if ([math]::Abs($dm) -gt 5) {
        Write-Host "  OJO: los tamanos difieren mas de un 5 %, la comparacion NO es limpia." -ForegroundColor Yellow
        Write-Host "  Reejecuta afinando -Av1Sweep alrededor de GQ $pick." -ForegroundColor Yellow
    } else {
        # Veredicto REAL, calculado. Antes habia aqui una leyenda fija que decia
        # "SSIM de AV1 mayor -> comprime mejor" pasara lo que pasara, y el 29/07
        # se imprimio junto a un resultado donde el SSIM de AV1 era MENOR.
        $dS = ($sA - $sH) * 1000
        if ($dS -gt 0) {
            Write-Host "  VEREDICTO: a tamano equiparable AV1 tiene MEJOR SSIM. Comprime mejor." -ForegroundColor Green
        } elseif ($dS -gt -0.05) {
            Write-Host "  VEREDICTO: empate tecnico. La diferencia de SSIM es ruido." -ForegroundColor Cyan
        } else {
            Write-Host "  VEREDICTO: a tamano equiparable AV1 tiene PEOR SSIM. No compensa." -ForegroundColor Yellow
        }
        Write-Host ("  Y AV1 tardo un {0:+0.0;-0.0;0.0} % mas de tiempo." -f ((($v.Seconds - $h.Seconds)/$h.Seconds)*100))
    }
}
Write-Host ""
Write-Host "Ficheros en $OutDir. El script no borra nada."
