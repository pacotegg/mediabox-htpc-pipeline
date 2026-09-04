<#
    Analizar-Watchdog.ps1
    Analiza un volcado de C:\Windows\LiveKernelReports (o cualquier .dmp) con las
    Herramientas de depuracion de Windows (kd.exe) para identificar el driver culpable.

    SOLO LECTURA sobre el sistema: copia el .dmp a una carpeta de trabajo y lo analiza alli.
    NO instala nada por su cuenta: si faltan las herramientas, te dice como instalarlas.

    Uso (COMO ADMINISTRADOR, obligatorio para leer LiveKernelReports):
        powershell.exe -ExecutionPolicy Bypass -File "Analizar-Watchdog.ps1"

    Analizar un volcado concreto:
        powershell.exe -ExecutionPolicy Bypass -File "Analizar-Watchdog.ps1" -Dump "C:\ruta\al\archivo.dmp"
#>

param(
    [string]$Dump
)

$ErrorActionPreference = 'Stop'

function Info { param($m) Write-Host $m }
function Ok   { param($m) Write-Host $m -ForegroundColor Green }
function Warn { param($m) Write-Host $m -ForegroundColor Yellow }
function Err  { param($m) Write-Host $m -ForegroundColor Red }

# --- 1. Comprobar privilegios ------------------------------------------------
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $esAdmin) {
    Err "Este script necesita ejecutarse COMO ADMINISTRADOR para leer C:\Windows\LiveKernelReports."
    Err "Cierra esta ventana y abre PowerShell con 'Ejecutar como administrador'."
    exit 1
}

# --- 2. Localizar kd.exe -----------------------------------------------------
$rutasKd = @(
    # ${env:...} CON LLAVES (04/09/2026). Sin ellas PowerShell interpola solo
    # $env:ProgramFiles y deja el "(x86)" como texto pegado detras, o sea
    # "C:\Program Files(x86)\..." -sin el espacio-, que no existe nunca. La ruta
    # de abajo, que si lleva llaves, demuestra que la forma buena ya se conocia.
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\kd.exe",
    "${env:ProgramFiles}\Windows Kits\10\Debuggers\x64\kd.exe",
    "${env:ProgramFiles}\Windows Kits\11\Debuggers\x64\kd.exe"
)
$kd = $null
foreach ($r in $rutasKd) { if ($r -and (Test-Path $r)) { $kd = $r; break } }

if (-not $kd) {
    # Buscar por si esta en otra ubicacion
    $encontrado = Get-ChildItem -Path "${env:ProgramFiles}", "${env:ProgramFiles(x86)}" -Filter 'kd.exe' -Recurse -ErrorAction SilentlyContinue |
                  Where-Object FullName -match 'Debuggers\\x64' | Select-Object -First 1
    if ($encontrado) { $kd = $encontrado.FullName }
}

if (-not $kd) {
    Warn "No se han encontrado las Herramientas de depuracion de Windows (kd.exe)."
    Info ""
    Info "Para instalarlas, elige UNA de estas dos opciones:"
    Info ""
    Info "  OPCION A (recomendada, ligera) - via winget:"
    Info "      winget install Microsoft.WinDbg"
    Info "      (instala WinDbg moderno; incluye el motor de analisis)"
    Info ""
    Info "  OPCION B - SDK de Windows:"
    Info "      Descarga el 'Windows SDK' desde la web de Microsoft y, en el instalador,"
    Info "      marca UNICAMENTE 'Debugging Tools for Windows'. No hace falta nada mas."
    Info ""
    Info "Cuando lo tengas instalado, vuelve a ejecutar este script."
    exit 1
}
Ok "kd.exe encontrado en: $kd"

# --- 3. Localizar el volcado -------------------------------------------------
if (-not $Dump) {
    $lkr = Get-ChildItem "$env:SystemRoot\LiveKernelReports" -Recurse -Filter *.dmp -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending
    if (-not $lkr) {
        Err "No se han encontrado volcados en C:\Windows\LiveKernelReports."
        Err "Pasa uno manualmente con:  -Dump 'C:\ruta\al\archivo.dmp'"
        exit 1
    }
    if ($lkr.Count -gt 1) {
        Info ""
        Info "Volcados disponibles (se analizara el MAS RECIENTE):"
        $lkr | ForEach-Object { Info ("  {0}  ({1}, {2:N1} MB)" -f $_.Name, $_.LastWriteTime.ToString('dd/MM HH:mm'), ($_.Length/1MB)) }
    }
    $Dump = $lkr[0].FullName
}

if (-not (Test-Path $Dump)) { Err "No existe el archivo: $Dump"; exit 1 }
$infoDump = Get-Item $Dump
Ok ("Volcado a analizar: {0}  ({1}, {2:N1} MB)" -f $infoDump.Name, $infoDump.LastWriteTime.ToString('dd/MM/yyyy HH:mm'), ($infoDump.Length/1MB))

# --- 4. Preparar carpeta de trabajo y copiar el volcado ----------------------
$trabajo = Join-Path $env:USERPROFILE 'AnalisisWatchdog'
$simbolos = Join-Path $trabajo 'Symbols'
New-Item -ItemType Directory -Path $trabajo  -Force | Out-Null
New-Item -ItemType Directory -Path $simbolos -Force | Out-Null

$copia = Join-Path $trabajo $infoDump.Name
Info "Copiando el volcado a $trabajo ..."
Copy-Item -Path $Dump -Destination $copia -Force -ErrorAction Stop
Ok "Copia lista."

# --- 5. Ejecutar el analisis -------------------------------------------------
$salida = Join-Path $trabajo ("Analisis_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$rutaSimbolos = "srv*$simbolos*https://msdl.microsoft.com/download/symbols"

Info ""
Info "Ejecutando el analisis. La PRIMERA vez descarga simbolos de Microsoft y puede tardar"
Info "varios minutos (necesita conexion a internet). No cierres la ventana."
Info ""

$argumentos = @(
    '-z', "`"$copia`""
    '-y', "`"$rutaSimbolos`""
    '-c', '"!analyze -v; lm kv; q"'
    '-logo', "`"$salida`""
)

try {
    $p = Start-Process -FilePath $kd -ArgumentList $argumentos -NoNewWindow -Wait -PassThru
    Info ("kd.exe termino con codigo {0}." -f $p.ExitCode)
} catch {
    Err "Fallo al ejecutar kd.exe: $($_.Exception.Message)"
    exit 1
}

# --- 6. Resumen de lo mas relevante -----------------------------------------
if (-not (Test-Path $salida)) {
    Err "kd.exe no genero el archivo de salida. Revisa que los simbolos se hayan podido descargar."
    exit 1
}

Ok ""
Ok "Analisis completo guardado en: $salida"
Info ""
Info ("=" * 70)
Info "  LINEAS CLAVE (lo importante suele estar aqui)"
Info ("=" * 70)

$contenido = Get-Content $salida
$patrones = 'MODULE_NAME', 'IMAGE_NAME', 'PROCESS_NAME', 'FAILURE_BUCKET_ID',
            'BUGCHECK_CODE', 'BUGCHECK_P', 'FAILURE_ID_HASH', 'STACK_TEXT',
            'DRIVER_OBJECT', 'BLACKBOXNTFS', 'Probably caused by'

$claves = $contenido | Select-String -Pattern ($patrones -join '|')
if ($claves) {
    $claves | ForEach-Object { Info ("  " + $_.Line.Trim()) }
} else {
    Warn "  No se han localizado las lineas habituales."
    Warn "  Abre el archivo completo y busca 'Probably caused by' o 'MODULE_NAME'."
}

Info ""
Info ("=" * 70)
Info "COMO INTERPRETARLO:"
Info "  - 'Probably caused by' / 'MODULE_NAME' / 'IMAGE_NAME' = el driver o modulo senalado."
Info "  - Si aparece igdkmd64.sys, igdkmdn64.sys o similar -> driver grafico Intel (Arc)."
Info "  - Si aparece ntoskrnl.exe a secas, el culpable real suele estar mas abajo en STACK_TEXT."
Info "  - OJO: en volcados de tipo WATCHDOG el modulo senalado a veces es solo quien detecto"
Info "    el bloqueo, no quien lo causo. Hay que leer la pila (STACK_TEXT) con calma."
Info ""
Info "Pasame el archivo $salida y lo interpretamos juntos."
