#requires -Version 7.0
<#
============================================================================
 atmos-prio-booster.ps1  -  sube la prioridad de los descendientes, por TIEMPO
============================================================================
 POR QUE EXISTE (06/08/2026, tercer intento sobre el mismo problema):

 Windows hereda la AFINIDAD al crear un proceso pero NO la clase de prioridad,
 y a los procesos "de segundo plano" les baja la frecuencia (EcoQoS). Medido:
 dee.exe a prioridad Normal rinde 1,16 %/min y a AboveNormal 3,20 %/min (2,76x).

 El primer arreglo subia la prioridad al ver la PRIMERA LINEA de salida del
 hijo. Funciona para la ruta Atmos, donde dee.exe ES quien escribe. NO funciona
 para la ruta sin Atmos: ahi la cadena es
     pwsh -> deew -> deew -> dee
 y el dee que quema la CPU nace TRES MINUTOS despues que deew, porque DEEW
 primero convierte la entrada a RF64. El segundo intento reintentaba cada 5 s,
 pero seguia colgado de las lineas de salida: mientras DEEW convierte no imprime
 nada, el bloque del pipeline no se ejecuta y el reintento nunca llega a correr.
 Medido en Gladiator: dee arranco a las 20:58 y seguia en Normal a las 21:07.

 La leccion: para vigilar algo que aparece MAS TARDE hace falta un reloj, no un
 flujo de datos que puede callarse. De ahi este proceso aparte.

 Uso:
   $b = Start-Process pwsh -ArgumentList ... -PassThru   (ver Start-PrioBooster)
   ... trabajo ...
   $b.Kill()    # en un finally

 Sale solo si el proceso raiz muere o si se agota el tiempo, asi que un fallo
 del llamante no lo deja huerfano para siempre.
============================================================================
#>
param(
    [Parameter(Mandatory=$true)][int]$RootPid,
    [string[]]$Names = @('dee','deew','truehdd','ffmpeg'),
    [string]$Priority = 'AboveNormal',
    [int]$Depth = 4,
    [int]$IntervalSec = 3,
    [int]$TimeoutMin = 240,
    [string]$LogFile = ''
)

function Escribe($m) {
    if ($LogFile) {
        Add-Content -LiteralPath $LogFile -Value ("{0}  [prio] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ErrorAction SilentlyContinue
    }
}

$fin = (Get-Date).AddMinutes($TimeoutMin)
$yaVistos = @{}

# Momento de arranque del proceso que vigilamos, para no confundirlo con otro que
# herede su numero. Windows REUTILIZA los PID: comprobar solo que el PID exista no
# basta -si el padre muere y su numero se recicla, este proceso seguiria sondeando
# hasta agotar el timeout de horas-. La hora de arranque lo desambigua.
$rootStart = $null
try { $rootStart = (Get-Process -Id $RootPid -ErrorAction Stop).StartTime } catch { }

while ((Get-Date) -lt $fin) {
    # Si el que nos lanzo ya no esta -o su PID lo tiene ya otro proceso-, fuera.
    $root = Get-Process -Id $RootPid -ErrorAction SilentlyContinue
    if (-not $root) { break }
    if ($rootStart) {
        try { if ($root.StartTime -ne $rootStart) { break } } catch { break }
    }

    try {
        $todos = @(Get-CimInstance Win32_Process -ErrorAction Stop |
                   Select-Object ProcessId, ParentProcessId, Name)
        $nivel = @($RootPid)
        for ($d = 0; $d -lt $Depth; $d++) {
            $sig = @($todos | Where-Object { $nivel -contains $_.ParentProcessId })
            if (-not $sig) { break }
            foreach ($h in $sig) {
                foreach ($n in $Names) {
                    if ($h.Name -like "$n*") {
                        if ($yaVistos.ContainsKey($h.ProcessId)) { continue }
                        $p = Get-Process -Id $h.ProcessId -ErrorAction SilentlyContinue
                        if ($p -and "$($p.PriorityClass)" -ne $Priority) {
                            try {
                                $p.PriorityClass = $Priority
                                $yaVistos[$h.ProcessId] = $true
                                Escribe "$($h.Name) (PID $($h.ProcessId)) -> $Priority"
                            } catch { }
                        } elseif ($p) {
                            $yaVistos[$h.ProcessId] = $true
                        }
                        break
                    }
                }
            }
            $nivel = @($sig | ForEach-Object { $_.ProcessId })
        }
    } catch { }

    Start-Sleep -Seconds $IntervalSec
}
