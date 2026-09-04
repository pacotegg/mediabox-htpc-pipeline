<#
============================================================================
 start-mediabox-core.ps1  -  Arranque ROBUSTO del panel y los 3 watchers
----------------------------------------------------------------------------
 Lo invoca start-mediabox-hidden.vbs (que solo aporta la invisibilidad). Este
 script es el que de verdad arranca las cosas, y a diferencia del VBS viejo NO
 dispara a ciegas:

  1) ESPERA a que C:\Media exista antes de nada. En un arranque de Windows los
     watchers pueden ejecutarse antes de que el disco/carpeta este listo; si
     arrancan sin C:\Media se caen al instante y te quedas sin pipeline (paso
     el 19/07: tras reiniciar no arranco ninguno). Aunque C:\Media este en el
     NVMe, el arranque temprano puede adelantarse a que este disponible.

  2) VERIFICA cada proceso tras lanzarlo (por su marca en la linea de comandos)
     y REINTENTA si no aparecio. Disparar y olvidar era justo lo que fallaba.

  3) Es idempotente: si un watcher ya esta vivo, no lo duplica. Asi este mismo
     script sirve para arrancar Y para "reparar" si algo se cayo (lo puede
     relanzar el Programador de tareas cada X min si se quiere, sin duplicar).

 Uso normal: lo llama el VBS al iniciar sesion. Manual (con ventana, para ver
 que dice):  pwsh -ExecutionPolicy Bypass -File C:\scripts\start-mediabox-core.ps1
============================================================================
#>

$ErrorActionPreference = 'Continue'

# --- UNA SOLA EJECUCION A LA VEZ -------------------------------------------
# Este script lo lanza el watchdog CADA 10 MINUTOS, y ademas se ejecuta a mano
# para arrancar o reparar. Mientras solo sabia ARRANCAR, que dos copias se
# solaparan era inofensivo: la segunda veia todo vivo y no hacia nada.
# Desde que ademas MATA procesos obsoletos (Update-StalePiece) ya no lo es: en el
# peor entrelazado, la copia A mata un watcher, la copia B lo arranca, y A -que
# ya habia decidido que estaba obsoleto- se lleva por delante el recien nacido.
# PASO DE VERDAD el 19/08/2026: el watchdog salto a las 16:15:01 justo durante una
# ejecucion manual, y se vio en la salida ("...reiniciando" seguido de "ya esta
# vivo", que es otra copia habiendolo arrancado en medio).
# Un mutex con nombre lo resuelve: quien no lo consigue en 5 s se va sin hacer
# nada, que es exactamente lo correcto -si hay otra copia trabajando, el trabajo
# ya se esta haciendo-.
$mutex = New-Object System.Threading.Mutex($false, 'Global\MediaBoxStart')
$tengoMutex = $false
try { $tengoMutex = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $tengoMutex = $true }
if (-not $tengoMutex) {
    Write-Host "[ok] ya hay otro arranque/reparacion en curso; no hago nada."
    exit 0
}

$PWSH   = 'C:\Program Files\PowerShell\7\pwsh.exe'
$PY     = 'C:\Users\HTPC\AppData\Local\Programs\Python\Python314\python.exe'
$Media  = 'C:\Media'

# --- 1) Esperar a que C:\Media exista (hasta ~60s) --------------------------
$waited = 0
while (-not (Test-Path -LiteralPath $Media) -and $waited -lt 60) {
    Start-Sleep -Seconds 2
    $waited += 2
}
if (-not (Test-Path -LiteralPath $Media)) {
    # No existe tras 60s: crearla y seguir (mejor intentarlo que rendirse).
    New-Item -ItemType Directory -Force -Path $Media | Out-Null
}

# --- Helpers ----------------------------------------------------------------
# Marca = trozo UNICO de la linea de comandos con el que reconocer el proceso.

# COINCIDENCIA AJUSTADA, no una subcadena suelta (25/08/2026). Exige que $marca
# sea el SCRIPT que se esta ejecutando -tras '-File' para pwsh, o como el
# argumento del interprete de python- y no solo texto en algun sitio de la
# linea de comandos. Antes 'Test-Running'/'Get-StaleProc' hacian
# "-match [regex]::Escape($marca)" contra CUALQUIER pwsh.exe/python.exe: un
# diagnostico que solo MENCIONABA 'webpanel\app.py' dentro de un -Command
# (por ejemplo, un Start-Process construyendo esa ruta a mano para probar algo)
# hizo que 'Test-Running' se autodetectara y start-mediabox-core.ps1 se negara
# a relanzar un panel que en realidad estaba caido -paso de verdad el
# 22/08/2026-. El listado final de mas abajo ya usaba esta regla mas estricta
# y nunca dio ese falso positivo; ahora la comparten las tres funciones que
# miran procesos, en vez de tener la logica floja en dos sitios y la buena en
# un tercero.
function Test-PieceMatch([string]$CommandLine, [string]$marca) {
    if (-not $CommandLine) { return $false }
    if ($marca -like '*.ps1') {
        return [bool]($CommandLine -match ('-File\s+"?[^"]*' + [regex]::Escape($marca)))
    }
    return [bool]($CommandLine -match ('python\.exe"?\s+"?[^"]*' + [regex]::Escape($marca)))
}

function Test-Running([string]$marca) {
    $procs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if (Test-PieceMatch $p.CommandLine $marca) { return $true }
    }
    return $false
}

# --- Codigo OBSOLETO en un proceso vivo -------------------------------------
# EL FALLO QUE ESTO EXISTE PARA CAZAR (19/08/2026)
# ------------------------------------------------
# Los watchers son bucles infinitos: PowerShell parsea el script entero al
# arrancar y hace el dot-source de sus librerias UNA sola vez. A partir de ahi,
# editar el .ps1 no cambia nada hasta reiniciarlos.
#
# Los tres llevaban corriendo desde el 12/08 18:35 mientras encode-watch.ps1
# (17/08), subs-watch.ps1 (14/08) y pipeline-lock.ps1 (17/08) ya se habian
# tocado. Consecuencia medible: el cambio de plan de energia por trabajo
# -anadido el 16/08, +6,7 % de velocidad y mucha menos dispersion- NUNCA llego a
# ejecutarse. UNA SEMANA de encodes estrangulados a ratos, y nada aviso: el
# watchdog solo sabia resucitar watchers MUERTOS, y estos estaban vivos.
#
# La comprobacion es barata y no tiene ambiguedad: si el proceso arranco ANTES de
# la ultima modificacion de su script o de sus librerias, corre codigo viejo.
#
# DOS CONDICIONES antes de tocar nada, porque reiniciar a destiempo es peor que
# el codigo viejo:
#   1. El pipeline.lock tiene que estar LIBRE. Jamas a mitad de un trabajo.
#   2. Y no debe haber pausa global puesta (alguien esta haciendo mantenimiento
#      a mano; que no le reinicien las cosas por debajo).
# Como el watchdog corre cada 10 min, un cambio de codigo se aplica solo en la
# siguiente ventana ociosa sin que nadie tenga que acordarse.
$LockLib = Join-Path $PSScriptRoot 'pipeline-lock.ps1'
if (-not (Test-Path -LiteralPath $LockLib)) { $LockLib = 'C:\scripts\pipeline-lock.ps1' }
if (Test-Path -LiteralPath $LockLib) { . $LockLib }

function Test-PipelineIdle {
    # Sin la libreria no se puede comprobar: se responde NO IDLE, que es el lado
    # seguro (no se reinicia nada).
    if (-not (Get-Command Test-PipelineLockBusy -ErrorAction SilentlyContinue)) { return $false }
    if (Test-PipelineLockBusy (Join-Path 'C:\Media\tmp' 'pipeline.lock')) { return $false }
    if (Test-PipelinePaused 'C:\Media\tmp') { return $false }
    return $true
}

function Get-StaleProc([string]$marca, [string[]]$Fuentes) {
    <#
      Devuelve el proceso que casa con $marca si arranco ANTES que el fichero mas
      recientemente modificado de $Fuentes. $null si esta al dia o no existe.
    #>
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='python.exe'" -ErrorAction Stop |
                   Where-Object { Test-PieceMatch $_.CommandLine $marca })
        if ($procs.Count -eq 0) { return $null }
        $masNuevo = $null
        foreach ($f in $Fuentes) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $t = (Get-Item -LiteralPath $f).LastWriteTime
            if ($null -eq $masNuevo -or $t -gt $masNuevo) { $masNuevo = $t }
        }
        if ($null -eq $masNuevo) { return $null }
        foreach ($p in $procs) {
            if ($p.CreationDate -and $p.CreationDate -lt $masNuevo) { return $p }
        }
    } catch { }
    return $null
}

function Update-StalePiece([string]$nombre, [string]$marca, [string[]]$Fuentes) {
    # Mata el proceso obsoleto para que el Start-Piece de despues lo relance con
    # el codigo nuevo. Solo con el pipeline ocioso.
    $p = Get-StaleProc $marca $Fuentes
    if (-not $p) { return }
    if (-not (Test-PipelineIdle)) {
        Write-Host ("[!!] {0} corre codigo OBSOLETO (arranco {1}), pero el pipeline esta ocupado o en pausa: se reintentara." -f $nombre, $p.CreationDate)
        return
    }
    Write-Host ("[..] {0} corre codigo OBSOLETO (arranco {1}, el codigo es posterior): reiniciando." -f $nombre, $p.CreationDate)
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# --- LA SALIDA DE LOS WATCHERS, A DISCO (26/08/2026) ------------------------
# Hasta hoy los cuatro procesos se lanzaban con -WindowStyle Hidden y SIN
# redirigir nada: todo su Write-Host se escribia en una consola que no existe y
# se perdia. Eso deja sin rastro cosas que hay que poder auditar:
#   - '[barrido] borrado: X (N GB)' de Clear-ProcessedSources, que BORRA DE
#     FORMA DEFINITIVA fuentes de 26-60 GB (desde el 06/08/2026 no van a la
#     papelera, a proposito: la papelera no libera espacio). Es la unica linea
#     que dice que se ha borrado algo, y no se guardaba en ninguna parte.
#   - '[rescate] ...' y '[requeue] ...', que explican por que un trabajo volvio
#     a la cola o dejo de volver.
#   - '[ignorado] ...', el aviso de un fichero que la cola no va a procesar.
# El 26/08/2026 desaparecio un fuente de encode_running y NO SE PUDO DETERMINAR
# quien lo borro precisamente por esto: la linea que lo habria dicho se escribio
# en el vacio. Comprobado que la redireccion a fichero SI captura Write-Host de
# un proceso hijo (y que -WindowStyle Hidden convive con -Redirect*).
#
# Se ROTA en cada arranque en vez de truncar: si un watcher se reinicia justo
# despues del incidente que interesa, el log anterior sigue estando en '.1'.
$LogWatchers = 'C:\Media\encode_logs'

function Get-PieceLog([string]$nombre) {
    $slug = ($nombre -replace '[^A-Za-z0-9]+','-').Trim('-').ToLower()
    return (Join-Path $LogWatchers ("watcher-{0}.log" -f $slug))
}

function Rotate-PieceLog([string]$ruta) {
    try {
        if (Test-Path -LiteralPath $ruta) {
            Move-Item -LiteralPath $ruta -Destination ($ruta + '.1') -Force -ErrorAction Stop
        }
    } catch { }   # si esta bloqueado, Start-Process lo truncara: mejor eso que no arrancar
}

function Start-Piece([string]$nombre, [string]$exe, [string]$arguments, [string]$marca) {
    if (Test-Running $marca) {
        Write-Host "[ok] $nombre ya esta vivo."
        return
    }
    New-Item -ItemType Directory -Force -Path $LogWatchers -ErrorAction SilentlyContinue | Out-Null
    $log = Get-PieceLog $nombre
    $err = $log -replace '\.log$', '.err.log'
    for ($try = 1; $try -le 3; $try++) {
        Write-Host "[..] arrancando $nombre (intento $try)..."
        Rotate-PieceLog $log
        Rotate-PieceLog $err
        # Best-effort: si la redireccion falla por lo que sea, se arranca igual
        # SIN log. Un watcher vivo sin log es mucho mejor que ningun watcher.
        try {
            Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden `
                -RedirectStandardOutput $log -RedirectStandardError $err -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "[!!] no se pudo redirigir el log de $nombre ($($_.Exception.Message)); arranco sin el."
            Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        }
        Start-Sleep -Seconds 3
        if (Test-Running $marca) { Write-Host "[ok] $nombre arrancado.  log: $log"; return }
    }
    Write-Host "[XX] $nombre NO arranco tras 3 intentos. Revisar a mano (mira $log)."
}

# Librerias que cargan los tres watchers: si cambia cualquiera de ellas, el
# watcher que la tenia dot-sourceada esta obsoleto igual que si cambiara el suyo.
$LibsComunes = @('C:\scripts\pipeline-lock.ps1', 'C:\scripts\mediabox-paths.ps1')

# --- 2) Panel web (Flask) ---------------------------------------------------
# El panel se AVISA pero NO se reinicia solo: tiene trabajo en memoria (la cola
# de remux se persiste, pero una descarga de yt-dlp en curso no se reanuda) y
# sesiones de navegador abiertas. Que lo decida una persona.
$pStale = Get-StaleProc 'webpanel\app.py' @('C:\scripts\webpanel\app.py','C:\scripts\webpanel\remuxlib.py')
if ($pStale) {
    Write-Host ("[!!] el PANEL corre codigo OBSOLETO (arranco {0}). NO se reinicia solo: reinicialo cuando no haya remux ni descargas en curso." -f $pStale.CreationDate)
}
Start-Piece 'panel (app.py)' $PY '"C:\scripts\webpanel\app.py"' 'webpanel\app.py'
Start-Sleep -Seconds 2

# --- 3) Los tres watchers ---------------------------------------------------
# Update-StalePiece va ANTES de cada Start-Piece: mata al obsoleto (solo si el
# pipeline esta ocioso) y entonces Start-Piece, que ya no lo encuentra vivo, lo
# relanza con el codigo nuevo. Si esta al dia no hace absolutamente nada.
Update-StalePiece 'watcher VIDEO' 'encode-watch.ps1' (@('C:\scripts\encode-watch.ps1')          + $LibsComunes)
Start-Piece 'watcher VIDEO' $PWSH '-ExecutionPolicy Bypass -File "C:\scripts\encode-watch.ps1"'          'encode-watch.ps1'
Update-StalePiece 'watcher AUDIO' 'audio-watch.ps1'  (@('C:\scripts\atmosENC\audio-watch.ps1')  + $LibsComunes)
Start-Piece 'watcher AUDIO' $PWSH '-ExecutionPolicy Bypass -File "C:\scripts\atmosENC\audio-watch.ps1"'  'audio-watch.ps1'
Update-StalePiece 'watcher SUBS'  'subs-watch.ps1'   (@('C:\scripts\subs-watch.ps1')            + $LibsComunes)
Start-Piece 'watcher SUBS'  $PWSH '-ExecutionPolicy Bypass -File "C:\scripts\subs-watch.ps1"'            'subs-watch.ps1'

Write-Host ""
Write-Host "Arranque completado. Estado final:"
# Misma regla ajustada que Test-Running/Get-StaleProc (Test-PieceMatch, mas
# arriba): exige que el nombre sea el SCRIPT invocado, no solo texto presente
# en la linea de comandos. Antes esto vivia por triplicado -suelto aqui y en
# las otras dos funciones- y solo esta copia era la estricta.
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { (Test-PieceMatch $_.CommandLine 'encode-watch.ps1') -or
                   (Test-PieceMatch $_.CommandLine 'audio-watch.ps1') -or
                   (Test-PieceMatch $_.CommandLine 'subs-watch.ps1') -or
                   (Test-PieceMatch $_.CommandLine 'webpanel\app.py') } |
    ForEach-Object { Write-Host ("  PID {0}  {1}" -f $_.ProcessId, (($_.CommandLine -split '\\')[-1])) }

$mutex.ReleaseMutex()
$mutex.Dispose()
