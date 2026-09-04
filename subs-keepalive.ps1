<#
============================================================================
 subs-keepalive.ps1  -  Mantiene VIVA la API key de OpenSubtitles
============================================================================
 OpenSubtitles purga las claves que pasan demasiado tiempo sin usarse (60 dias
 segun lo que vio el usuario). Este script hace una consulta trivial para que
 la clave cuente como activa.

 Lo llama la tarea programada "MediaBox - keepalive subtitulos" cada 25 dias.
 Por que 25 y no 55: deja margen para que fallen DOS ejecuciones seguidas
 -equipo apagado, sin red, la API caida- y todavia quede holgura antes de los
 60. Con una cada 55 dias, un solo fallo ya se come el margen entero.

 NO gasta cupo de descargas: usa /infos/formats, que solo exige la Api-Key.

 El resultado se acumula en C:\Media\encode_logs\subs-keepalive.log para poder
 mirar despues si ha estado corriendo. Si algun dia la clave caduca igualmente,
 ahi estara la fecha del ultimo intento con exito.

 Manual:  pwsh -ExecutionPolicy Bypass -File C:\scripts\subs-keepalive.ps1
 NOTA: fichero en ASCII puro (codigo Y comentarios).
============================================================================
#>

$PYTHON = 'C:\Users\HTPC\AppData\Local\Programs\Python\Python314\python.exe'
$SCRIPT = 'C:\scripts\webpanel\subsfetch.py'
$LOG    = 'C:\Media\encode_logs\subs-keepalive.log'

function Apunta([string]$txt) {
    $linea = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $txt
    Write-Host $linea
    try {
        $dir = Split-Path $LOG -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $LOG -Value $linea
    } catch { }
}

if (-not (Test-Path -LiteralPath $PYTHON)) { Apunta "FALLO: no encuentro python en $PYTHON"; exit 1 }
if (-not (Test-Path -LiteralPath $SCRIPT)) { Apunta "FALLO: no encuentro $SCRIPT"; exit 1 }

$salida = & $PYTHON $SCRIPT --keepalive 2>&1
$rc = $LASTEXITCODE
foreach ($l in @($salida)) { Apunta "  $l" }
if ($rc -eq 0) { Apunta "keepalive correcto." } else { Apunta "keepalive FALLIDO (exit $rc)." }
exit $rc
