<#
    Diagnostico-HTPC.ps1
    Diagnostico post-cuelgue (hang) para Windows 11. SOLO LECTURA.
    Cambios respecto a v1:
      - Corrige: ya no marca BSOD por un MEMORY.DMP antiguo (comprueba la fecha).
      - Corrige: los eventos Ntfs 98 (informativos "volumen correcto") ya no cuentan como error.
      - Anade: cuelgues de GPU/driver de pantalla (TDR Display 4101/4102).
      - Anade: carpeta LiveKernelReports (volcados de cuelgue de GPU sin BSOD).
      - Anade: version y fecha del driver de video (Arc A730M).
      - Anade: ultimos Windows Update (por si un update coincide con el inicio de los cuelgues).

    Uso (como Administrador, recomendado):
        powershell.exe -ExecutionPolicy Bypass -File "Diagnostico-HTPC.ps1"
    Cambiar dias a mirar hacia atras (por defecto 4):
        powershell.exe -ExecutionPolicy Bypass -File "Diagnostico-HTPC.ps1" -Dias 10
#>

param(
    [int]$Dias = 4
)

$ErrorActionPreference = 'SilentlyContinue'
$inicio = (Get-Date).AddDays(-$Dias)
$salida = Join-Path $env:USERPROFILE ("Diagnostico_HTPC_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:out = @()

function Log { param([string]$m); Write-Host $m; $script:out += $m }
function Sec { param([string]$t); Log ""; Log ("=" * 70); Log ("  " + $t); Log ("=" * 70) }
function Corta { param([string]$s,[int]$n=200); $s = ($s -replace '\s+',' '); if ($s.Length -gt $n) { $s.Substring(0,$n) } else { $s } }

$f = [ordered]@{
    Inesperado = $false; BSOD = $false; BugcheckCode = $null; PowerButton = $false
    WHEA = $false; Disco = $false; Termico = $false; GPU = $false
}

Log "DIAGNOSTICO HTPC v2  -  $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
Log "Ventana analizada: ultimos $Dias dia(s)  (desde $($inicio.ToString('dd/MM/yyyy HH:mm')))"

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $esAdmin) { Log "AVISO: NO se esta ejecutando como Administrador. LiveKernelReports y algunos dumps pueden salir vacios." }

# --------------------------------------------------------------------
Sec "1) LINEA DE TIEMPO DE ENCENDIDO/APAGADO"
try {
    $power = Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,1074,6005,6006,6008; StartTime=$inicio} -MaxEvents 60 | Sort-Object TimeCreated
    if ($power) {
        foreach ($e in $power) {
            $etq = switch ($e.Id) {
                41   { "[41]   Kernel-Power: reinicio SIN apagado limpio previo" }
                1074 { "[1074] Apagado/reinicio CONTROLADO (usuario o sistema)" }
                6005 { "[6005] Arranque de Windows" }
                6006 { "[6006] Apagado LIMPIO" }
                6008 { "[6008] Apagado INESPERADO detectado en el siguiente arranque" }
            }
            Log ("{0}  {1}" -f $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $etq)
            if ($e.Id -eq 6008 -or $e.Id -eq 41) { $f.Inesperado = $true }
        }
        Log ""
        Log "NOTA: si el equipo se quedo CONGELADO y lo reiniciaste tu a mano, el 41/6008 corresponde"
        Log "      a ESE reinicio forzado, no a un apagado espontaneo. El patron seria cuelgue (hang)."
    } else { Log "Sin eventos de energia en la ventana." }
} catch { Log "No se pudo leer la linea de tiempo: $($_.Exception.Message)" }

# --------------------------------------------------------------------
Sec "2) DETALLE KERNEL-POWER 41"
try {
    $k41 = Get-WinEvent -FilterHashtable @{LogName='System'; Id=41; StartTime=$inicio} -MaxEvents 3
    if ($k41) {
        foreach ($e in $k41) {
            $xml = [xml]$e.ToXml(); $d = @{}
            foreach ($n in $xml.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
            $bcc = $d['BugcheckCode']; $pbt = $d['PowerButtonTimestamp']
            Log ("Fecha: {0}  BugcheckCode: {1}  PowerButtonTimestamp: {2}" -f $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $bcc, $pbt)
            if ($bcc -and $bcc -ne '0') { $f.BSOD = $true; $f.BugcheckCode = $bcc; Log "  -> Bugcheck !=0 = hubo BSOD (ver seccion 3)." }
            elseif ($pbt -and $pbt -ne '0') { $f.PowerButton = $true; Log "  -> PowerButton !=0 = se pulso/mantuvo el boton fisico." }
            else { Log "  -> Bugcheck 0 y PowerButton 0 = ni BSOD ni boton. Compatible con corte de corriente O con reinicio forzado tras un cuelgue." }
        }
    } else { Log "No hay eventos Kernel-Power 41." }
} catch { Log "Error leyendo K-Power 41: $($_.Exception.Message)" }

# --------------------------------------------------------------------
Sec "3) BSOD Y VOLCADOS DE MEMORIA"
try {
    $bug = Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001; StartTime=$inicio} -MaxEvents 5 | Where-Object { $_.ProviderName -match 'BugCheck|WER-SystemErrorReporting' }
    if ($bug) { $f.BSOD = $true; foreach ($e in $bug) { Log ("{0}  [{1}]" -f $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $e.ProviderName); Log ("  " + (Corta $e.Message 240)) } }
    else { Log "Sin eventos BugCheck 1001 en la ventana." }

    if (Test-Path "$env:SystemRoot\MEMORY.DMP") {
        $dmp = Get-Item "$env:SystemRoot\MEMORY.DMP"
        if ($dmp.LastWriteTime -ge $inicio) {
            $f.BSOD = $true
            Log ("MEMORY.DMP RECIENTE: {0:N1} MB, {1}  -> corresponde a un BSOD dentro de la ventana." -f ($dmp.Length/1MB), $dmp.LastWriteTime.ToString('dd/MM HH:mm'))
        } else {
            Log ("MEMORY.DMP existe pero es ANTIGUO ({0}) -> se IGNORA, no es de este episodio." -f $dmp.LastWriteTime.ToString('dd/MM/yyyy'))
        }
    } else { Log "No hay C:\Windows\MEMORY.DMP." }

    $mini = Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" | Where-Object LastWriteTime -ge $inicio
    if ($mini) { $f.BSOD = $true; Log "Minidumps RECIENTES:"; $mini | ForEach-Object { Log ("  {0}  ({1})" -f $_.Name, $_.LastWriteTime.ToString('dd/MM HH:mm')) } }
    else { Log "Sin minidumps recientes." }
} catch { Log "Error en BSOD/dumps: $($_.Exception.Message)" }

# --------------------------------------------------------------------
Sec "4) CUELGUES DE GPU / DRIVER DE PANTALLA (clave para Arc A730M)"
try {
    # TDR: el driver de pantalla dejo de responder (4101 = recuperado, 4102 = OpenGL/relacionado)
    $tdr = Get-WinEvent -FilterHashtable @{LogName='System'; Id=4101,4102; StartTime=$inicio} -MaxEvents 20
    if ($tdr) {
        $f.GPU = $true
        Log "Eventos TDR (driver de pantalla dejo de responder):"
        foreach ($e in $tdr) { Log ("  {0}  ID {1} [{2}]  {3}" -f $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $e.Id, $e.ProviderName, (Corta $e.Message 160)) }
    } else { Log "Sin eventos TDR 4101/4102 (no consta que el driver de pantalla se recuperara de un cuelgue)." }

    # LiveKernelReports: volcados de watchdog/GPU que NO llegan a BSOD
    $lkr = Get-ChildItem "$env:SystemRoot\LiveKernelReports" -Recurse -Filter *.dmp | Where-Object LastWriteTime -ge $inicio
    if ($lkr) {
        $f.GPU = $true
        Log "LiveKernelReports RECIENTES (cuelgues sin BSOD):"
        $lkr | ForEach-Object { Log ("  {0}  ({1})" -f $_.FullName, $_.LastWriteTime.ToString('dd/MM HH:mm')) }
    } else { Log "Sin volcados recientes en C:\Windows\LiveKernelReports." }

    # Driver de video actual (comparar version/fecha con la recomendada de Intel)
    Log ""
    Log "Adaptadores de video y driver instalado:"
    Get-CimInstance Win32_VideoController | ForEach-Object {
        $fd = if ($_.DriverDate) { $_.DriverDate.ToString('dd/MM/yyyy') } else { 'desconocida' }
        Log ("  {0}  |  driver {1}  |  fecha {2}" -f $_.Name, $_.DriverVersion, $fd)
    }
} catch { Log "Error en seccion GPU: $($_.Exception.Message)" }

# --------------------------------------------------------------------
Sec "5) ERRORES DE HARDWARE (WHEA)"
try {
    $whea = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$inicio} -MaxEvents 20
    if ($whea) { $f.WHEA = $true; foreach ($e in $whea) { Log ("{0}  ID {1} [{2}]" -f $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $e.Id, $e.LevelDisplayName); Log ("  " + (Corta $e.Message 220)) }; Log "  -> WHEA = fallo hardware real (CPU/RAM/PCIe-GPU/bus)." }
    else { Log "Sin errores WHEA." }
} catch { Log "Error en WHEA: $($_.Exception.Message)" }

# --------------------------------------------------------------------
Sec "6) ERRORES DE DISCO / ALMACENAMIENTO (reales, sin los informativos)"
# 7=bloque danado 11=controladora 51=paginacion 55=corrupcion NTFS 129=reset dispositivo 153=E/S reintentada
try {
    $disco = Get-WinEvent -FilterHashtable @{LogName='System'; Id=7,11,51,55,129,153; StartTime=$inicio} -MaxEvents 30 | Where-Object { $_.ProviderName -match 'disk|Disk|Ntfs|volmgr|storahci|stornvme|storport|Storport' }
    if ($disco) { $f.Disco = $true; foreach ($e in $disco) { Log ("{0}  ID {1} [{2}]" -f $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $e.Id, $e.ProviderName); Log ("  " + (Corta $e.Message 180)) } }
    else { Log "Sin errores REALES de disco (los eventos Ntfs 98 'volumen correcto' son informativos y se ignoran)." }
} catch { Log "Error en disco: $($_.Exception.Message)" }

# --------------------------------------------------------------------
Sec "7) EVENTOS TERMICOS"
try {
    $crit = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=$inicio} -MaxEvents 300
    $term = $crit | Where-Object { $_.Message -match 'thermal|temperature|overheat|throttl|termic|térmic|sobrecalent|temperatura' }
    if ($term) { $f.Termico = $true; foreach ($e in ($term | Select-Object -First 10)) { Log ("{0}  ID {1} [{2}]" -f $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $e.Id, $e.ProviderName); Log ("  " + (Corta $e.Message 200)) } }
    else { Log "Sin eventos con mensajes termicos en los logs criticos/error." }
} catch { Log "Error en termicos: $($_.Exception.Message)" }

# --------------------------------------------------------------------
Sec "8) TEMPERATURA ACTUAL (estado AHORA, no del cuelgue)"
Log "Windows NO guarda historico de temperaturas. Para cazar el proximo cuelgue con datos,"
Log "deja LibreHardwareMonitor grabando a CSV (ver instrucciones que te paso aparte)."
$leido = $false
try { $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature; if ($tz) { foreach ($z in $tz) { Log ("  ACPI zona: {0} C" -f [math]::Round(($z.CurrentTemperature/10)-273.15,1)); $leido = $true } } } catch {}
foreach ($ns in 'root/LibreHardwareMonitor','root/OpenHardwareMonitor') {
    try { $s = Get-CimInstance -Namespace $ns -ClassName Sensor | Where-Object SensorType -eq 'Temperature'; if ($s) { Log ("  Fuente: {0}" -f $ns); $s | Sort-Object Name | ForEach-Object { Log ("    {0}: {1} C" -f $_.Name, [math]::Round($_.Value,1)); $leido = $true } } } catch {}
}
if (-not $leido) { Log "  Sin lectura de temperatura por WMI (normal si no tienes LibreHardwareMonitor/HWiNFO abierto)." }

# --------------------------------------------------------------------
Sec "9) ULTIMOS WINDOWS UPDATE (por si coinciden con el inicio de los cuelgues)"
try {
    $hf = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 6
    if ($hf) { foreach ($h in $hf) { $fecha = if ($h.InstalledOn) { $h.InstalledOn.ToString('dd/MM/yyyy') } else { 'fecha desconocida' }; Log ("  {0}  {1}  ({2})" -f $fecha, $h.HotFixID, $h.Description) } }
    else { Log "Sin datos de HotFix." }
    Log "  (Si alguna es de 'estos dias', un update pudo introducir el problema en vez del cambio de pasta.)"
} catch { Log "Error en Windows Update: $($_.Exception.Message)" }

# --------------------------------------------------------------------
Sec "10) DIAGNOSTICO (heuristico)"
$causas = @()
if ($f.GPU)  { $causas += "CUELGUE DE GPU/DRIVER DE PANTALLA (TDR o LiveKernelReport). Con Arc A730M es la causa nº1 de cuelgue sin BSOD." }
if ($f.BSOD) { $t = "PANTALLAZO AZUL reciente."; if ($f.BugcheckCode) { $t += " Bugcheck: $($f.BugcheckCode)." }; $causas += $t }
if ($f.WHEA) { $causas += "ERROR HARDWARE (WHEA): fallo a bajo nivel de CPU/RAM/PCIe-GPU." }
if ($f.Disco){ $causas += "ERRORES DE DISCO reales." }
if ($f.Termico){ $causas += "EVENTO TERMICO: indicios de sobrecalentamiento." }
if ($f.PowerButton){ $causas += "Se pulso/mantuvo el boton de encendido." }
if (-not $causas) { $causas += "Sin firmas claras en los logs: tipico de un CUELGUE DURO que no da tiempo a registrar nada. Con temperaturas grabadas (LibreHardwareMonitor) el proximo episodio si dejara pista." }

Log "CAUSA(S) MAS PROBABLE(S):"
$i = 1; foreach ($c in $causas) { Log ("  {0}. {1}" -f $i, $c); $i++ }
Log ""
Log "CONTEXTO IMPORTANTE (no detectable por el script): se cambio la PASTA TERMICA hace poco."
Log "Al abrir el equipo se manipulan disipador, RAM y la GPU Arc (placa MXM). Un contacto marginal"
Log "de RAM o de la GPU cuelga el sistema incluso en reposo. Revisar reasentamiento es prioritario."
Log ""
Log "QUE HACER:"
Log "  - Comprobar temperaturas reales dejando LibreHardwareMonitor grabando (descarta/confirma tema termico)."
Log "  - Reasentar RAM y comprobar tornillos del disipador (par uniforme, sin holguras)."
Log "  - GPU Arc: reinstalar driver LIMPIO (DDU + driver actual de Intel). Comparar la version de la seccion 4."
Log "  - Si se uso metal liquido, inspeccionar que no haya salpicado componentes cercanos a la GPU."

Log ""
$script:out -join "`r`n" | Out-File -FilePath $salida -Encoding UTF8
Write-Host ""
Write-Host "Informe guardado en: $salida" -ForegroundColor Green
