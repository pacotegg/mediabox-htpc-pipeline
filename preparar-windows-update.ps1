<#
============================================================================
 preparar-windows-update.ps1  -  Actualizar Windows sin sustos en el HTPC
============================================================================
 CONTEXTO (por que existe este script):
 Entre junio y agosto de 2026 el equipo se colgo varias veces (congelacion,
 sin BSOD). El 01/08/2026 se desinstalo KB5101684 y se PAUSO Windows Update
 hasta el 31/08/2026. Desde entonces, cero incidentes. Pero la pausa caduca
 sola y Windows no deja volver a pausar sin instalar antes lo pendiente:
 hay que actualizar SI o SI, y mas vale hacerlo con el pipeline parado que
 un martes cualquiera a mitad de un encode de 90 minutos.

 QUE HACE, EN ORDEN:
   1. Comprueba que no hay trabajo en vuelo y para el pipeline.
   2. Activa la proteccion del sistema en C: y crea un punto de restauracion.
   3. Levanta la pausa de Windows Update e instala lo pendiente - y solo si
      se pasa -Instalar.
   4. Deja constancia de que KB y que drivers entraron, para poder revertir.

 DRIVERS (-ConDrivers):
   Por defecto NO se instalan drivers: el sospechoso numero 1 de los cuelgues
   de 2026 era la GPU Arc A730M. Con -ConDrivers si se instalan.
   Aun asi, la politica ExcludeWUDriversInQualityUpdate=1 se deja SIEMPRE
   puesta, y es a proposito: esa politica gobierna lo que Windows instala POR
   SU CUENTA, no lo que instala este script. Dejandola a 1 los drivers solo
   pueden entrar aqui, o sea con el pipeline parado, con punto de restauracion
   y con la version anterior anotada. Nunca un martes por sorpresa.

 LO QUE NO HACE, A PROPOSITO:
   - No reinicia. Te dice si hace falta y lo decides tu.
   - No reanuda el pipeline. Eso se hace despues del reinicio con -Reanudar.

 USO (COMO ADMINISTRADOR, obligatorio):
   Ensayo, no cambia nada del sistema (recomendado la primera vez):
       pwsh -ExecutionPolicy Bypass -File C:\scripts\preparar-windows-update.ps1
   De verdad:
       pwsh -ExecutionPolicy Bypass -File C:\scripts\preparar-windows-update.ps1 -Instalar
   De verdad, drivers incluidos:
       pwsh -ExecutionPolicy Bypass -File C:\scripts\preparar-windows-update.ps1 -Instalar -ConDrivers
   Despues de reiniciar, para devolver el equipo al trabajo:
       pwsh -ExecutionPolicy Bypass -File C:\scripts\preparar-windows-update.ps1 -Reanudar

 NOTA: fichero en ASCII puro (codigo y comentarios).
============================================================================
#>

param(
    # Sin este switch el script NO toca nada: solo informa de que haria.
    [switch]$Instalar,

    # Instalar tambien los drivers que ofrezca Windows Update. Ver la nota
    # sobre drivers en la cabecera: si entra un driver de video, es el unico
    # cambio de toda esta operacion con antecedentes de tumbar el equipo.
    [switch]$ConDrivers,

    # Instalar tambien las actualizaciones PRELIMINARES (preview / opcionales de
    # mitad de mes). Por defecto NO: no traen seguridad, solo adelantan lo que
    # saldra el mes que viene, y son las mas gordas con diferencia.
    [switch]$ConPreliminares,

    # Modo post-reinicio: quita la pausa global y vuelve a levantar el pipeline.
    [switch]$Reanudar,

    # Minutos a esperar a que termine un trabajo en vuelo antes de rendirse.
    [int]$EsperarMin = 180,

    # Saltarse la espera y parar el pipeline en seco. Solo si sabes que lo que
    # hay en marcha es desechable: mata el encode y deja el trabajo a medias.
    [switch]$SinEsperar
)

$ErrorActionPreference = 'Continue'
# La ruta del temp de ESTADO sale de mediabox-paths.ps1, unica definicion del
# pipeline (02/09/2026: aqui estaba escrita a mano). Este script no carga
# ninguna otra libreria, asi que la carga el solo; si faltara, el valor de
# siempre.
$PathsLib = Join-Path $PSScriptRoot 'mediabox-paths.ps1'
if (-not (Test-Path -LiteralPath $PathsLib)) { $PathsLib = 'C:\scripts\mediabox-paths.ps1' }
if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
$Tmp        = if ($MediaBoxTmp) { $MediaBoxTmp } else { 'C:\Media\tmp' }
$PausaFile  = Join-Path $Tmp 'pipeline_paused'
$LogDir     = 'C:\Media\encode_logs'
$UXKey      = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$PolKey     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$SRKey      = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$Registro   = Join-Path $LogDir 'windows-update-historial.txt'

function Titulo { param($t) Write-Host ""; Write-Host ("=" * 74); Write-Host "  $t"; Write-Host ("=" * 74) }
function Ok    { param($m) Write-Host "  [OK]    $m" -ForegroundColor Green }
function Aviso { param($m) Write-Host "  [!]     $m" -ForegroundColor Yellow }
function Malo  { param($m) Write-Host "  [FALLO] $m" -ForegroundColor Red }
function Dato  { param($m) Write-Host "          $m" }

# ---------------------------------------------------------------------------
# 0. PRELIMINARES
# ---------------------------------------------------------------------------
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $esAdmin) {
    Write-Host ""
    Malo "Este script necesita ejecutarse COMO ADMINISTRADOR."
    Dato "Sin privilegios no se puede ni CONSULTAR el estado de la proteccion del"
    Dato "sistema: Get-ComputerRestorePoint responde 'Acceso denegado', que desde"
    Dato "fuera parece 'no hay puntos de restauracion'. Tampoco se puede crear el"
    Dato "punto ni instalar actualizaciones."
    Dato ""
    Dato "Abre PowerShell como administrador y repite el comando."
    exit 1
}

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log   = Join-Path $LogDir "windows-update-$stamp.log"
# Write-Host NO pasa por la tuberia: Tee-Object no lo captura, el transcript si.
Start-Transcript -Path $log -Force | Out-Null

Write-Host ""
Write-Host "PREPARAR WINDOWS UPDATE  -  $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
Write-Host "Log: $log"

# --- Modo -Reanudar: salir por aqui ----------------------------------------
if ($Reanudar) {
    Titulo "REANUDAR EL PIPELINE"
    if (Test-Path -LiteralPath $PausaFile) {
        Remove-Item -LiteralPath $PausaFile -Force -ErrorAction Stop
        Ok "Pausa global levantada (borrado pipeline_paused)."
    } else {
        Dato "No habia pausa global puesta."
    }
    $arranque = 'C:\scripts\start-mediabox-hidden.vbs'
    if (Test-Path -LiteralPath $arranque) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$arranque`"" | Out-Null
        Ok "Pipeline arrancado ($arranque)."
    } else {
        Aviso "No encuentro $arranque. Arranca el pipeline a mano."
    }
    Dato ""
    Dato "Comprueba el panel y deja el equipo 3-4 dias con carga real antes de"
    Dato "dar el update por bueno. Si algo va mal: Diagnostico-HTPC.ps1"
    Stop-Transcript | Out-Null
    exit 0
}

if (-not $Instalar) {
    Write-Host ""
    Aviso "MODO ENSAYO. No se va a tocar nada: ni el pipeline, ni la proteccion"
    Aviso "del sistema, ni Windows Update. Repite con -Instalar para hacerlo."
}

# ---------------------------------------------------------------------------
# 1. FOTO DEL ESTADO ACTUAL (para poder comparar despues)
# ---------------------------------------------------------------------------
Titulo "1) ESTADO ACTUAL"

$ver = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Dato ("Windows: {0} {1}  build {2}.{3}" -f $ver.ProductName, $ver.DisplayVersion, $ver.CurrentBuild, $ver.UBR)
$buildAntes = "$($ver.CurrentBuild).$($ver.UBR)"

Dato "Ultimos KB instalados:"
foreach ($k in @(Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 6)) {
    $f = if ($k.InstalledOn) { $k.InstalledOn.ToString('dd/MM/yyyy') } else { '?' }
    Dato ("  {0}  {1}" -f $k.HotFixID, $f)
}

# Se guarda para poder anotar el antes/despues en el historial: si un driver de
# video cambia, la version anterior es lo unico que permite volver atras.
$driversAntes = @(Get-CimInstance Win32_VideoController |
                  Where-Object { $_.Name -match 'Arc|UHD' } |
                  ForEach-Object { "{0} = {1}" -f $_.Name, $_.DriverVersion })
foreach ($d in $driversAntes) { Dato "Video: $d" }

$ux = Get-ItemProperty -Path $UXKey -ErrorAction SilentlyContinue
if ($ux.PauseUpdatesExpiryTime) {
    $exp  = [datetime]::Parse($ux.PauseUpdatesExpiryTime).ToLocalTime()
    $dias = [math]::Round(($exp - (Get-Date)).TotalDays, 1)
    if ($dias -gt 0) { Aviso ("Windows Update PAUSADO hasta {0} (quedan {1} dias)." -f $exp.ToString('dd/MM/yyyy HH:mm'), $dias) }
    else             { Dato  ("La pausa caduco el {0}." -f $exp.ToString('dd/MM/yyyy HH:mm')) }
} else {
    Dato "Windows Update NO esta pausado."
}

$pol = Get-ItemProperty -Path $PolKey -ErrorAction SilentlyContinue
if ($pol.ExcludeWUDriversInQualityUpdate -eq 1) {
    Ok "ExcludeWUDriversInQualityUpdate=1: Windows no instalara drivers POR SU CUENTA."
    if ($ConDrivers) {
        Dato "  (-ConDrivers: este script si los instalara, deliberadamente. La"
        Dato "   politica se queda a 1 para que sea la UNICA via por la que entren.)"
    }
} else {
    # NO se vuelve a poner sola. Se quito a proposito el 20/08/2026, para que los
    # drivers aparezcan en la ventana de Windows Update. Un script que restaura
    # por su cuenta una directiva que has borrado a mano es un script que pelea
    # contigo: aqui solo se informa.
    Aviso "ExcludeWUDriversInQualityUpdate NO esta puesta: Windows puede instalar"
    Aviso "drivers por su cuenta, incluido el de la Arc A730M, sin pipeline parado"
    Aviso "ni punto de restauracion. Es una decision tomada, no un fallo."
    Dato  "  Para volver a activarla, como administrador:"
    Dato  "    New-ItemProperty -Path '$PolKey' ``"
    Dato  "      -Name ExcludeWUDriversInQualityUpdate -Value 1 -PropertyType DWord -Force"
}

# ---------------------------------------------------------------------------
# 2. PARAR EL PIPELINE
# ---------------------------------------------------------------------------
Titulo "2) PARAR EL PIPELINE"

# Trabajo en vuelo = los procesos que de verdad duelen si los matas a medias.
function Get-TrabajoEnVuelo {
    return @(Get-Process -Name 'ffmpeg','dee','truehdd','mkvmerge' -ErrorAction SilentlyContinue)
}

$vuelo = Get-TrabajoEnVuelo
if ($vuelo) {
    Aviso ("Hay {0} proceso(s) de trabajo en marcha:" -f $vuelo.Count)
    foreach ($p in $vuelo) { Dato ("  {0} (PID {1}), {2} min de CPU" -f $p.Name, $p.Id, [math]::Round($p.CPU / 60, 1)) }
} else {
    Ok "No hay ningun encode ni conversion de audio en marcha."
}

if (-not $Instalar) {
    Dato "(ensayo) Aqui se pondria la pausa global y se llamaria a stop-mediabox.ps1."
} else {
    # Pausa GLOBAL primero: ningun watcher coge trabajo NUEVO mientras esperamos
    # a que termine lo que ya estaba en marcha. Ver Test-PipelinePaused en
    # pipeline-lock.ps1. Sin esto, esperar no sirve de nada: en cuanto acabe un
    # trabajo el watcher arranca el siguiente y no se para nunca.
    if (-not (Test-Path -LiteralPath $Tmp)) { New-Item -ItemType Directory -Path $Tmp -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $PausaFile)) {
        New-Item -ItemType File -Path $PausaFile -Force | Out-Null
        Ok "Pausa global puesta: los watchers no cogeran trabajo nuevo."
    } else {
        Dato "La pausa global ya estaba puesta."
    }

    if ($vuelo -and -not $SinEsperar) {
        Dato "Esperando a que termine el trabajo en vuelo (maximo $EsperarMin min)..."
        Dato "Ctrl+C para abortar; la pausa global se queda puesta."
        $limite = (Get-Date).AddMinutes($EsperarMin)
        while ((Get-TrabajoEnVuelo) -and (Get-Date) -lt $limite) {
            Start-Sleep -Seconds 60
            $q = Get-TrabajoEnVuelo
            if ($q) { Dato ("  ... {0} sigue vivo ({1})" -f $q[0].Name, (Get-Date -Format 'HH:mm')) }
        }
        if (Get-TrabajoEnVuelo) {
            Malo "Se agoto la espera de $EsperarMin min y sigue habiendo trabajo en marcha."
            Dato "NO se sigue adelante: reiniciar ahora tiraria el trabajo a la basura."
            Dato "Opciones: esperar mas (-EsperarMin 300), o matarlo aposta (-SinEsperar)."
            Dato "La pausa global se queda puesta; para quitarla: -Reanudar"
            Stop-Transcript | Out-Null
            exit 75      # transitorio y reintentable, no un error de verdad
        }
        Ok "El trabajo en vuelo ha terminado."
    } elseif ($vuelo -and $SinEsperar) {
        Aviso "-SinEsperar: se mata el trabajo en marcha sin esperar."
    }

    $stop = 'C:\scripts\stop-mediabox.ps1'
    if (Test-Path -LiteralPath $stop) {
        # En el mismo proceso: stop-mediabox excluye $PID y este script no encaja
        # en su patron de watchers, asi que no puede matarse a si mismo.
        & $stop
        Ok "stop-mediabox.ps1 ejecutado (panel y watchers parados, temporales barridos)."
    } else {
        Malo "No encuentro $stop. Para el pipeline a mano antes de seguir."
        Stop-Transcript | Out-Null
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 3. PUNTO DE RESTAURACION
# ---------------------------------------------------------------------------
Titulo "3) PROTECCION DEL SISTEMA Y PUNTO DE RESTAURACION"

function Get-Puntos {
    try { return @(Get-ComputerRestorePoint -ErrorAction Stop) } catch { return $null }
}

$puntos = Get-Puntos
if ($null -eq $puntos) {
    Aviso "No se pudo consultar la lista de puntos de restauracion."
} elseif ($puntos.Count -gt 0) {
    Dato ("Hay {0} punto(s) de restauracion. El ultimo: {1}" -f $puntos.Count, ($puntos | Select-Object -Last 1).Description)
} else {
    Aviso "No hay ningun punto de restauracion: la proteccion del sistema esta"
    Aviso "desactivada en C: o no tiene espacio reservado."
}

if (-not $Instalar) {
    Dato "(ensayo) Aqui se activaria la proteccion en C: y se crearia un punto."
} else {
    try {
        Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop
        Ok "Proteccion del sistema activada en C: (si ya lo estaba, no cambia nada)."
    } catch {
        Aviso "No se pudo activar la proteccion: $($_.Exception.Message)"
    }

    # Windows solo deja crear UN punto cada 24 h. Como el punto es justo la red
    # de seguridad de toda esta operacion, se levanta el limite y se deja como
    # estaba al terminar.
    $frecAntes = (Get-ItemProperty -Path $SRKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    New-ItemProperty -Path $SRKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null

    $desc = "Antes de Windows Update $stamp"
    try {
        Checkpoint-Computer -Description $desc -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    } catch {
        Aviso "Checkpoint-Computer fallo: $($_.Exception.Message)"
    }

    if ($null -ne $frecAntes) {
        Set-ItemProperty -Path $SRKey -Name 'SystemRestorePointCreationFrequency' -Value $frecAntes
    } else {
        Remove-ItemProperty -Path $SRKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
    }

    # VERIFICAR que el punto existe de verdad. Checkpoint-Computer puede terminar
    # sin error y no dejar nada; dar el punto por bueno sin comprobarlo es
    # quedarse sin red justo cuando hace falta.
    $nuevo = @(Get-Puntos) | Where-Object { $_.Description -eq $desc }
    if ($nuevo) {
        Ok "Punto de restauracion creado y VERIFICADO: '$desc'"
    } else {
        Malo "NO se ha podido crear el punto de restauracion."
        Dato "Sin red de seguridad no se sigue adelante. Causas tipicas:"
        Dato "  - Proteccion del sistema desactivada por directiva."
        Dato "  - Sin espacio reservado para instantaneas en C:."
        Dato "Comprobar en: Panel de control > Sistema > Proteccion del sistema."
        Dato "La pausa del pipeline se queda puesta; para quitarla: -Reanudar"
        Stop-Transcript | Out-Null
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 4. WINDOWS UPDATE
# ---------------------------------------------------------------------------
Titulo "4) WINDOWS UPDATE"

if ($Instalar) {
    # Levantar la pausa SOLO en modo real. Levantarla sin instalar seria lo peor
    # de los dos mundos: Windows actualizaria por su cuenta, cuando le viniera
    # bien a el y no a ti.
    $valoresPausa = @(
        'PauseUpdatesExpiryTime', 'PauseUpdatesStartTime',
        'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime',
        'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime'
    )
    foreach ($v in $valoresPausa) { Remove-ItemProperty -Path $UXKey -Name $v -ErrorAction SilentlyContinue }
    Ok "Pausa de Windows Update levantada."
    Restart-Service wuauserv -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
}

Dato "Buscando actualizaciones (tarda un rato)..."
$ses = New-Object -ComObject Microsoft.Update.Session
try {
    $res = $ses.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
} catch {
    Malo "Fallo la busqueda: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit 1
}

# Type 1 = Software, 2 = Driver. Los drivers solo entran con -ConDrivers.
# Las definiciones de Defender (KB2267602) se dejan siempre fuera para que el
# cambio sea lo mas pequeno posible: se instalan solas varias veces al dia.
# Tamano legible SIN separador de miles. En es-ES el formato N0 escribe
# "92.452 MB" para 92 GB, que se lee como 92 MB y es justo el error que hizo
# lanzar una descarga de 7 GB creyendo que eran megas. Ver la memoria
# parseo-decimal-locale-es: el locale ya ha mordido antes.
function Tam {
    param($bytes)
    $mb = [math]::Round($bytes / 1MB)
    if ($mb -ge 1024) { return ("{0} GB" -f [math]::Round($bytes / 1GB, 1)) }
    return ("$mb MB")
}

$software    = @()
$drivers     = @()
$descartados = @()
foreach ($u in $res.Updates) {
    if ($u.Title -match 'KB2267602') { $descartados += "Defender (se instala solo): $($u.Title)"; continue }

    # PRELIMINARES / PREVIEW: son las opcionales de mitad de mes (las "C release").
    # No traen seguridad, solo adelantan lo que saldra el mes que viene ya probado
    # por otros. En un equipo con historial de cuelgues no hay ningun motivo para
    # ir por delante, y ademas son las mas gordas. Fuera salvo peticion expresa.
    if ($u.Title -match 'preliminar|[Pp]review') {
        if ($ConPreliminares) { $software += $u }
        else                  { $descartados += "PRELIMINAR/opcional (usa -ConPreliminares): $($u.Title)" }
        continue
    }

    if ($u.Type -eq 2) {
        if ($ConDrivers) { $drivers += $u }
        else             { $descartados += "DRIVER (usa -ConDrivers): $($u.Title)" }
        continue
    }
    $software += $u
}

# Un driver de video es el unico cambio de toda esta operacion con antecedentes
# de tumbar el equipo. Se avisa aparte para que no pase desapercibido en medio
# de una lista de cosas rutinarias.
$driversVideo = @($drivers | Where-Object { $_.Title -match 'Arc|Graphics|Display|NVIDIA|AMD|Radeon' })

$aInstalar = @($software) + @($drivers)

foreach ($d in $descartados) { Dato "  - $d" }

if ($aInstalar.Count -eq 0) {
    Ok "No hay nada pendiente que instalar."
    if (-not $Instalar) { Dato "(ensayo: con la pausa puesta Windows puede estar ocultando el acumulativo)" }
} else {
    if ($software.Count -gt 0) {
        Write-Host ""
        Dato "SOFTWARE ($($software.Count)):"
        foreach ($u in $software) { Dato ("  * [$(Tam $u.MaxDownloadSize)] $($u.Title)") }
    }
    if ($drivers.Count -gt 0) {
        Write-Host ""
        Dato "DRIVERS ($($drivers.Count)):"
        foreach ($u in $drivers) { Dato ("  * [$(Tam $u.MaxDownloadSize)] $($u.Title)") }
    }
    $total = ($aInstalar | Measure-Object -Property MaxDownloadSize -Sum).Sum
    Write-Host ""
    Dato "TOTAL A DESCARGAR: $(Tam $total)"
    if ($total -gt 2GB) {
        Aviso "Son muchos gigas. La descarga puede tardar mucho y NO tiene barra de"
        Aviso "progreso: si dudas de si avanza, mira como crece la carpeta"
        Aviso "C:\Windows\SoftwareDistribution\Download desde otra ventana."
    }
    if ($driversVideo.Count -gt 0) {
        Write-Host ""
        Aviso "OJO: entre los drivers hay uno de VIDEO."
        foreach ($u in $driversVideo) { Aviso "  $($u.Title)" }
        Aviso "La GPU era el sospechoso numero 1 de los cuelgues de 2026. Si tras"
        Aviso "esto vuelven, el driver es lo primero que hay que mirar, y se"
        Aviso "revierte por Administrador de dispositivos > Revertir al anterior."
        Aviso "La version actual queda anotada en el historial."
    }
}

if (-not $Instalar) {
    Write-Host ""
    Aviso "Fin del ensayo. Nada ha cambiado en el equipo."
    Aviso "Para hacerlo de verdad, repite con -Instalar"
    if (-not $ConDrivers) { Aviso "Para incluir tambien los drivers: -Instalar -ConDrivers" }
    Stop-Transcript | Out-Null
    exit 0
}

$reinicio = $false
if ($aInstalar.Count -gt 0) {
    $col = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $aInstalar) {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        $null = $col.Add($u)
    }

    Dato "Descargando..."
    $dl = $ses.CreateUpdateDownloader()
    $dl.Updates = $col
    $rd = $dl.Download()
    if ($rd.ResultCode -ne 2) { Aviso "La descarga termino con codigo $($rd.ResultCode) (2 = OK)." }

    Dato "Instalando... NO apagues el equipo."
    $ins = $ses.CreateUpdateInstaller()
    $ins.Updates = $col
    $ri = $ins.Install()
    $reinicio = $ri.RebootRequired

    switch ($ri.ResultCode) {
        2       { Ok "Instalacion correcta." }
        3       { Aviso "Instalacion correcta CON ERRORES. Revisa el log." }
        default { Malo "La instalacion fallo (codigo $($ri.ResultCode))." }
    }

    # Que KB ha entrado exactamente y con que resultado. Esto es lo que hara
    # falta para revertir si el update sale rana.
    Write-Host ""
    Dato "Resultado por actualizacion:"
    $kbs = @()
    for ($i = 0; $i -lt $col.Count; $i++) {
        $it = $col.Item($i)
        $t  = $it.Title
        $kb = if ($it.Type -eq 2)            { 'DRIVER'    }
              elseif ($t -match '(KB\d{6,7})') { $matches[1] }
              else                             { '(sin KB)'  }
        $rc = $ri.GetUpdateResult($i).ResultCode
        $kbs += $kb
        Dato ("  {0,-10} codigo {1}  {2}" -f $kb, $rc, $t)
    }

    $ver2         = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $buildDespues = "$($ver2.CurrentBuild).$($ver2.UBR)"
    $limite       = (Get-Date).AddDays(10).ToString('dd/MM/yyyy')

    # OJO: la version nueva del driver puede no verse hasta despues de reiniciar.
    # Lo que importa guardar es la de ANTES, que es la que hace falta para volver.
    $driversDespues = @(Get-CimInstance Win32_VideoController |
                        Where-Object { $_.Name -match 'Arc|UHD' } |
                        ForEach-Object { "{0} = {1}" -f $_.Name, $_.DriverVersion })

    # Historial acumulado, aparte del log de esta ejecucion: es lo que se mira
    # dentro de tres semanas para saber que revertir y si aun se puede.
    $lineas = @(
        "",
        "=== $(Get-Date -Format 'dd/MM/yyyy HH:mm') ===",
        "  Build: $buildAntes -> $buildDespues",
        "  Instalados: $($kbs -join ', ')",
        "  Reinicio necesario: $reinicio",
        "  REVERTIR ANTES DEL $limite (aprox): pasada la limpieza de componentes",
        "  (CbsTask pasa los paquetes Superseded a Absent) ya NO se puede quitar.",
        "  Para revertir un KB: Configuracion > Windows Update > Historial > Desinstalar"
    )
    if ($drivers.Count -gt 0) {
        $lineas += "  DRIVERS instalados:"
        foreach ($u in $drivers) { $lineas += "    - $($u.Title)" }
        $lineas += "  Video ANTES:   $($driversAntes -join ' | ')"
        $lineas += "  Video DESPUES: $($driversDespues -join ' | ')  (puede no cambiar hasta reiniciar)"
        $lineas += "  Para revertir un driver: Administrador de dispositivos > el dispositivo >"
        $lineas += "  Propiedades > Controlador > Revertir al controlador anterior."
    }
    $lineas | Add-Content -LiteralPath $Registro -Encoding utf8
    Ok "Anotado en $Registro"
}

# ---------------------------------------------------------------------------
# 5. QUE HACER AHORA
# ---------------------------------------------------------------------------
Titulo "5) QUE HACER AHORA"

if ($reinicio) {
    Aviso "HACE FALTA REINICIAR. El script no lo hace por ti, a proposito."
    Dato "  1. Reinicia cuando te venga bien."
    Dato "  2. Despues:  pwsh -File C:\scripts\preparar-windows-update.ps1 -Reanudar"
} else {
    Ok "No hace falta reiniciar."
    Dato "  Reanuda el pipeline:  pwsh -File C:\scripts\preparar-windows-update.ps1 -Reanudar"
}
Write-Host ""
Dato "Y luego, IMPORTANTE:"
Dato "  - Deja el equipo 3-4 dias con carga real antes de fiarte."
Dato "  - Si vuelven los cuelgues: Analizar-Watchdog.ps1 sobre el dump nuevo, y"
Dato "    REVERTIR ESA MISMA SEMANA (la ventana para desinstalar se cierra sola)."
if ($driversVideo.Count -gt 0) {
    Dato "  - HA ENTRADO UN DRIVER DE VIDEO junto con el update. Son DOS cambios a"
    Dato "    la vez: si el equipo vuelve a colgarse no vas a saber cual fue, igual"
    Dato "    que paso en agosto de 2026. Si puede repetirse, mejor de uno en uno."
    Dato "    Versiones anteriores anotadas en $Registro"
} elseif ($ConDrivers) {
    Dato "  - Se permitieron drivers (-ConDrivers) pero no habia ninguno de video."
} else {
    Dato "  - No se ha instalado ningun driver. El de la Arc sigue solo en tus manos:"
    Dato "    con el instalador de Intel, o con -ConDrivers, y NUNCA a la vez que un"
    Dato "    update: dos cambios a la vez y ya no sabes cual fue."
}

Stop-Transcript | Out-Null
