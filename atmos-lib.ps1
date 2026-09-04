<#
============================================================================
 atmos-lib.ps1  -  utilidades compartidas para DDP+Atmos (dee.exe directo)
============================================================================
 Lo dot-sourcea encode.ps1 (video). Convert-TrueHDToDDP usa la MISMA cadena
 validada que atmosENC\audio_encode.ps1:
   CON Atmos:  extraer .thd -> truehdd decode -> DAMF -> dee.exe -x XML -> .ec3
   SIN Atmos:  deew -f ddp   (DEE via ffmpeg, sin objetos que perder)
 Debe vivir junto a encode.ps1 (p.ej. C:\scripts).
 NOTA: el DAMF intermedio puede pasar de 10 GB -> $Tmp debe tener espacio.
============================================================================
#>

# Red de seguridad: quien nos hace dot-source (encode.ps1, audio_encode.ps1)
# define su propia Log, que escribe al fichero de log del trabajo. PowerShell
# resuelve las funciones en tiempo de ejecucion, asi que da igual que la definan
# despues del dot-source. Pero si alguien carga esta libreria suelta, sin Log,
# no queremos que reviente: caemos a Write-Host.
if (-not (Get-Command Log -ErrorAction SilentlyContinue)) {
    function Log($m) { Write-Host $m }
}

# Rutas compartidas: de aqui sale $MediaBoxBigTmp (ver mediabox-paths.ps1). Esta
# libreria y pipeline-lock.ps1 lo cargan las dos, y entre ambas cubren los siete
# scripts del pipeline. Si faltara el fichero se usa el valor de siempre: nadie
# se queda sin arrancar por esto.
$PathsLib = Join-Path (Split-Path $PSCommandPath -Parent) 'mediabox-paths.ps1'
if (-not (Test-Path -LiteralPath $PathsLib)) { $PathsLib = 'C:\scripts\mediabox-paths.ps1' }
if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
if (-not $MediaBoxBigTmp) { $MediaBoxBigTmp = 'G:\MediaTmp' }
if (-not $MediaBoxTmp)    { $MediaBoxTmp    = 'C:\Media\tmp' }

# -- pwsh por ruta ABSOLUTA -------------------------------------------------
# Regla del proyecto: no depender del PATH. Era la unica llamada del pipeline que
# lo hacia (encode-watch usa (Get-Process -Id $PID).Path y app.py la ruta con
# fallback), y aqui el precio de fallar era el mas alto de todos:
# Start-Process SIN -ErrorAction Stop devuelve $null cuando no encuentra el
# binario, sin lanzar excepcion; $null.Handle tampoco protesta; y la ranura se
# quedaba con Proc=$null. Step-DdpTracksParallel la daba entonces por VIVA para
# siempre y Wait-DdpTracksParallel giraba sin fin CON EL pipeline.lock COGIDO:
# no colgaba un trabajo, colgaba los tres pipelines.
# Se arregla por los dos lados: ruta absoluta aqui, y tratar Proc=$null como
# ranura muerta en Step- (ver alli).
$MediaBoxPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $MediaBoxPwsh)) { $MediaBoxPwsh = 'pwsh' }

# ===========================================================================
#  ESPACIO EN DISCO: los temporales pesados NO van en C:
# ===========================================================================
# El 31/07/2026 el DDP+Atmos de Interstellar murio a mitad con
#   ERROR: encode_to_atmos_ddp: FileWriter: write error for frame: 110941
# y el pipeline lo degrado a EAC3, perdiendo el Atmos en silencio. NO fue un
# fallo de DEE: NTFS registro cuatro eventos 141 ("disco lleno") en el mismo
# segundo -mkvmerge.exe, dee.exe, pwsh.exe y brave.exe-, con 6,4 GB "libres"
# que eran TODOS espacio reservado. A dee.exe le negaron 64 KB.
#
# La causa de fondo es que C: es un recurso COMPARTIDO por cosas que no se
# coordinan entre si:
#   - el pagefile (administrado por el sistema; habia crecido a 95,9 GB)
#   - la fuente en encode_running (26 GB)
#   - lo que alguien este copiando a encode_queue en ese momento (57 GB aquel
#     dia, escrito por un mkvmerge ajeno al pipeline.lock)
#   - el .thd extraido + el DAMF (30-40 GB juntos)
# El pipeline.lock serializa los ENCODES, pero no puede serializar a quien
# vuelca ficheros en la cola. Mientras el trabajo pesado viva en C:, cualquiera
# de esos cuatro puede matar un DEE de 20 minutos.
#
# Solucion: el trabajo pesado se va a otra unidad. C:\Media\tmp se queda solo
# con los ficheros de estado que lee el panel (unos KB), que es para lo que
# tiene que ser un temp "unico".
function ConvertTo-DoubleInv {
    <#
      Parsea un numero SIEMPRE en cultura invariante. Devuelve $null si no cuela.

      POR QUE EXISTE (05/08/2026): esta maquina corre en es-ES, donde el '.' es
      separador de MILES. [double]::TryParse SIN cultura usa la cultura ACTUAL, asi
      que se comia el punto decimal:
          [double]::TryParse('34.5')      -> 345          (un 34,5 % mostrado como 345 %)
          [double]::TryParse('30.000000') -> 30000000     (30 s leidos como 30 millones)
      ffmpeg, ffprobe, truehdd y DEE emiten SIEMPRE punto decimal, pasara lo que
      pase con el idioma de Windows, asi que hay que parsear en invariante.
      (El CAST [double]'34.5' si usa invariante y por eso el codigo que castea
      -como el $Duration de encode.ps1- nunca tuvo este problema. El TryParse no.)
    #>
    param([string]$Text)
    $v = 0.0
    if ([double]::TryParse(("$Text").Trim(),
                           [System.Globalization.NumberStyles]::Float,
                           [System.Globalization.CultureInfo]::InvariantCulture,
                           [ref]$v)) { return $v }
    return $null
}

function Get-PerformanceCoreMask {
    <#
      Mascara de afinidad con SOLO los nucleos rapidos (P-cores) en una CPU
      hibrida Intel. Devuelve 0 si la CPU no es hibrida (o no se puede saber),
      y entonces el llamante NO toca la afinidad.

      POR QUE EXISTE (06/08/2026, medido en produccion):
      Windows 11 mandaba los dee.exe del pipeline a los E-cores. El motivo es que
      el pipeline lo lanza un VBS OCULTO: todo lo que cuelga de ese arbol se marca
      como trabajo de segundo plano (EcoQoS) y el planificador lo manda a los
      nucleos de eficiencia. Se veia clarisimo en los contadores por nucleo:
          P-cores (0-11):  16 %   <- ociosos
          E-cores (12-15): 311 %  <- los dos dee, saturados
      Cada dee tenia "un nucleo entero" al 100 %... pero de los lentos.

      CUANTO APORTA LA AFINIDAD, MEDIDO BIEN (comparando el MISMO tramo de
      progreso, 70-80 %, en dos peliculas casi gemelas de 2 pistas):
          E-cores, prioridad Normal      -> 1,03 %/min
          P-cores, prioridad Normal      -> 1,18 %/min   (1,15x)
          P-cores, prioridad AboveNormal -> 3,20 %/min   (3,1x)
      O sea que la afinidad sola aporta poco: LA GANANCIA GRANDE ESTA EN LA
      PRIORIDAD (ver Set-ChildPriority). La primera lectura de "3,46x por los
      P-cores" era erronea: se midio parcheando afinidad Y prioridad a la vez y
      se le atribuyo todo a la afinidad.
      Aun asi la afinidad se conserva: ese 1,15x es real y no cuesta nada.

      COMO SE DERIVAN (sin numeros a fuego, que solo valdrian para esta CPU):
      en los hibridos de Intel los P-cores llevan SMT (2 hilos) y los E-cores no.
      Con L logicos y C fisicos:  P = L - C  y  E = C - P.
      Aqui: L=16, C=10 -> P=6 P-cores (logicos 0..11), E=4 (logicos 12..15).
      Y el orden de enumeracion pone los P-cores primero (Alder/Raptor Lake).
      Si L == C no hay hibrido que valga: se devuelve 0 y no se toca nada.
    #>
    try {
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        $L = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        $C = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
        if (-not $L -or -not $C -or $L -le $C) { return [int64]0 }   # sin SMT o sin datos: no tocar
        $P = $L - $C                      # nucleos con SMT = P-cores
        if ($P -le 0 -or (2 * $P) -gt $L) { return [int64]0 }
        if ((2 * $P) -eq $L) { return [int64]0 }   # todos con SMT: no es hibrido
        $mask = [int64]0
        for ($i = 0; $i -lt (2 * $P); $i++) { $mask = $mask -bor ([int64]1 -shl $i) }
        return $mask
    } catch { return [int64]0 }
}

function Start-PrioBooster {
    <#
      Lanza el vigilante de prioridades (atmos-prio-booster.ps1) y devuelve su
      proceso, para poder pararlo en un finally. Devuelve $null si no se puede.

      Hace falta un proceso APARTE porque el que hay que vigilar aparece MAS
      TARDE: en la ruta sin Atmos, DEEW tarda ~3 min en lanzar su dee.exe. Todo
      lo que dependa de las lineas de salida falla ahi, porque DEEW calla
      mientras convierte (ver el comentario largo del booster).
    #>
    param(
        [string]$LogFile = '',
        [int]$TimeoutMin = 240
    )
    $script = Join-Path (Split-Path $PSCommandPath -Parent) 'atmos-prio-booster.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return $null }
    try {
        $args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,
                  '-RootPid', "$PID", '-TimeoutMin', "$TimeoutMin")
        if ($LogFile) { $args += @('-LogFile', $LogFile) }
        $line = ($args | ForEach-Object {
            if ("$_" -match '[\s"()]') { '"' + ("$_" -replace '"','\"') + '"' } else { "$_" }
        }) -join ' '
        $p = Start-Process -FilePath $MediaBoxPwsh -ArgumentList $line -NoNewWindow -PassThru -ErrorAction Stop
        if ($null -eq $p) { return $null }
        $null = $p.Handle
        return $p
    } catch { return $null }
}

function Set-ChildPriority {
    <#
      Sube la prioridad de los procesos HIJOS que ya estan corriendo.

      POR QUE HACE FALTA (medido el 06/08/2026): Windows hereda la AFINIDAD al
      crear un proceso, pero NO la clase de prioridad. Segun la propia
      documentacion de CreateProcess, el hijo recibe NORMAL salvo que el padre
      sea IDLE o BELOW_NORMAL. O sea que poner AboveNormal en este proceso NO
      llega a truehdd ni a dee, que son justo los que consumen la CPU.

      Y la prioridad es lo que MAS pesa, mas que la afinidad. Medido sobre la
      misma pista, mismo tramo de progreso, con los dos en P-cores:
          prioridad Normal      -> 1,16 %/min
          prioridad AboveNormal -> 3,20 %/min   (2,76x)
      El motivo es EcoQoS: a un proceso "de segundo plano" Windows le baja la
      frecuencia aunque le dejes un P-core entero. Subir la prioridad lo saca de
      esa clase. (Comparar con solo cambiar la afinidad, que daba 1,15x: casi
      toda la ganancia estaba aqui.)

      Se llama en cuanto el hijo empieza a escribir salida, que es la senyal mas
      barata de que ya existe. Devuelve $true si subio la prioridad de ALGUNO,
      para que el llamante sepa si tiene que volver a intentarlo.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Priority = 'AboveNormal',
        # Niveles de descendencia. 4 y no 2: medido el 06/08/2026 en el encode de
        # "No Hables Con Extranos", la cadena real de la ruta SIN Atmos es
        #     pwsh -> deew -> deew -> dee
        # o sea TRES saltos hasta el proceso que de verdad quema CPU (DEEW lanza
        # otro DEEW, y ese lanza dee.exe). Con Depth=2 el dee se quedaba en
        # prioridad Normal, que es justo lo que este arreglo viene a evitar.
        [int]$Depth = 4
    )
    $tocado = $false
    try {
        $todos = @(Get-CimInstance Win32_Process -ErrorAction Stop |
                   Select-Object ProcessId, ParentProcessId, Name)
        $nivel = @($PID)
        for ($d = 0; $d -lt $Depth; $d++) {
            $siguiente = @($todos | Where-Object { $nivel -contains $_.ParentProcessId })
            if (-not $siguiente) { break }
            foreach ($h in ($siguiente | Where-Object { $_.Name -like "$Name*" })) {
                $p = Get-Process -Id $h.ProcessId -ErrorAction SilentlyContinue
                if ($p -and "$($p.PriorityClass)" -ne $Priority) {
                    $p.PriorityClass = $Priority
                    Log "    [prio] $($h.Name) (PID $($h.ProcessId)) -> $Priority"
                    $tocado = $true
                }
            }
            $nivel = @($siguiente | ForEach-Object { $_.ProcessId })
        }
    } catch { }   # nunca debe tumbar la conversion: como mucho se queda lento
    return $tocado
}

function Get-BigTmp {
    # Carpeta para los temporales PESADOS (.thd + DAMF + temp de DEE).
    # Si la unidad preferida no existe o no deja escribir se cae a $Fallback:
    # preferimos que el trabajo corra (y como mucho falle por espacio, ahora con
    # un mensaje claro) a que no corra porque alguien movio un disco.
    # Los valores por defecto salen de mediabox-paths.ps1 (una sola definicion
    # para todo el pipeline), no de una constante escrita aqui.
    param(
        [string]$Preferred = $MediaBoxBigTmp,
        [string]$Fallback  = $MediaBoxTmp
    )
    if (-not $Preferred) { $Preferred = 'G:\MediaTmp' }
    if (-not $Fallback)  { $Fallback  = 'C:\Media\tmp' }
    try {
        New-Item -ItemType Directory -Force -Path $Preferred -ErrorAction Stop | Out-Null
        # Escribir DE VERDAD: que la carpeta exista no garantiza ni permisos ni
        # que la unidad siga conectada.
        $probe = Join-Path $Preferred (".wtest_{0}" -f $PID)
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $Preferred
    } catch {
        Log "    [ddp] AVISO: no puedo escribir en $Preferred ($($_.Exception.Message)). Temporales pesados a $Fallback."
        New-Item -ItemType Directory -Force -Path $Fallback -ErrorAction SilentlyContinue | Out-Null
        return $Fallback
    }
}

function Get-FreeBytes([string]$Path) {
    # Bytes libres de la UNIDAD donde vive $Path. -1 si no se puede saber (el
    # llamante trata -1 como "no bloquear": nunca queremos que un fallo del
    # chequeo impida un trabajo que habria ido bien).
    try { return (New-Object System.IO.DriveInfo((Get-Item -LiteralPath $Path).Root)).AvailableFreeSpace }
    catch { return -1 }
}

function Get-DdpSpaceNeeded {
    <#
      Bytes que necesita UNA pista para completar la conversion, con techos
      generosos a proposito: este numero solo sirve para decir "no cabe", y un
      falso negativo (dejar arrancar algo que no cabe) cuesta 20 minutos de
      trabajo tirado, mientras que un falso positivo solo cuesta un aviso.

      Ruta Atmos: conviven a la vez el .thd y el DAMF (el .thd no se borra hasta
      el finally, despues de DEE), asi que SE SUMAN.
        .thd  -> 8 Mbps (techo del TrueHD Atmos de un UHD)
        DAMF  -> 16 canales x 48 kHz x 4 bytes = 3,072 MB/s
                 (16 ch es el maximo del mezzanine de TrueHD; 4 bytes es techo,
                  en la practica son 3. Interstellar: 169 min -> 31 GB.)
        .ec3  -> el bitrate pedido

      Ruta deew: el .mka extraido + el RF64 pcm_s32le que deew genera antes de
      pasarselo a DEE (ver el comentario de TEMP/TMP mas abajo).
    #>
    param(
        [Parameter(Mandatory=$true)][double]$DurationSec,
        [int]$Channels = 8,
        [switch]$IsAtmos,
        [int]$Bitrate = 768,
        [double]$MarginGB = 10
    )
    if ($DurationSec -le 0) { return 0L }
    if ($Channels -lt 1)    { $Channels = 8 }
    $ec3 = $DurationSec * $Bitrate * 1000 / 8
    if ($IsAtmos) {
        $src  = $DurationSec * 1e6           # .thd  a 8 Mbps
        $work = $DurationSec * 3072000       # DAMF  16ch/48k/32bit
    } else {
        $src  = $DurationSec * 1e6           # .mka  a 8 Mbps
        $work = $DurationSec * 48000 * $Channels * 4   # RF64 pcm_s32le
    }
    return [long]($src + $work + $ec3 + ($MarginGB * 1GB))
}

function Test-DdpSpace {
    # $true si en la unidad de $Path caben $NeededBytes. Loguea el desglose
    # SIEMPRE: cuando esto falle, el log tiene que decir por que sin que nadie
    # tenga que ir al visor de eventos.
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][long]$NeededBytes,
        [string]$Label = 'DDP'
    )
    if ($NeededBytes -le 0) { return $true }
    $free = Get-FreeBytes $Path
    if ($free -lt 0) {
        Log "    [$Label] AVISO: no puedo leer el espacio libre de $Path; sigo sin comprobar."
        return $true
    }
    $fmt = { param($b) "{0:N1} GB" -f ($b / 1GB) }
    if ($free -lt $NeededBytes) {
        Log ("    [$Label] ESPACIO INSUFICIENTE en $Path : hay {0}, hacen falta {1}." -f (& $fmt $free), (& $fmt $NeededBytes))
        return $false
    }
    Log ("    [$Label] espacio OK en $Path : {0} libres, estimados {1}." -f (& $fmt $free), (& $fmt $NeededBytes))
    return $true
}

function Set-DdpFailure {
    <#
      Clasifica un fallo como 'diskfull' u 'other'. Dos senyales:

      1. -Force: el llamante ya vio el mensaje de disco lleno en la salida de la
         herramienta. Es la senyal FIABLE. DEE dice "FileWriter: write error";
         ffmpeg/truehdd dicen "No space left on device" o "disk full".

      2. Espacio libre por debajo de $FloorBytes. Es una heuristica de respaldo y
         el suelo es ALTO (10 GB) a proposito: el dia del incidente NTFS reportaba
         6,4 GB "libres" que eran todos espacio reservado, o sea cero utilizable.
         Un umbral de 1-2 GB no lo habria cogido.
    #>
    param([string]$Path, [long]$FloorBytes = 10GB, [switch]$Force)
    if ($Force) { $global:DdpLastFailure = 'diskfull'; return }
    $free = Get-FreeBytes $Path
    if ($free -ge 0 -and $free -lt $FloorBytes) {
        Log ("    [ddp] el fallo coincide con {0:N1} GB libres en $Path -> se trata como disco lleno." -f ($free / 1GB))
        $global:DdpLastFailure = 'diskfull'
    } else {
        $global:DdpLastFailure = 'other'
    }
}

# Motivo del ULTIMO fallo de Convert-TrueHDToDDP: '' | 'diskfull' | 'other'.
# Global a proposito: la libreria se dot-sourcea, y el llamante (encode.ps1)
# necesita distinguir "DEE fallo" de "el disco se lleno" para decidir entre
# degradar a EAC3 o abortar y devolver el trabajo a la cola. Degradar un fallo
# de disco es lo que hizo que se perdiera el Atmos de Interstellar: el fallo era
# TRANSITORIO y reintentarlo lo habria recuperado.
$global:DdpLastFailure = ''

function Get-DdpBitrate {
    # kbps recomendado para DDP (E-AC-3) via DEE segun canales/Atmos.
    param([bool]$IsAtmos, [int]$Ch, [int]$AtmosBitrate = 768)
    if ($IsAtmos)  { return $AtmosBitrate }
    if ($Ch -ge 6) { return 640 }
    return 256
}

# -- TECHO DEL AUDIO QUE SE COPIA -----------------------------------------
# Los codecs que el TV decodifica (AC3/EAC3/AAC/MP3) se copian tal cual, y hasta
# el 27/08/2026 SIN NINGUN TOPE. Auditada la biblioteca por los sidecar
# *-mediainfo.xml: 749 peliculas con pistas por encima, 253 GiB de exceso, con
# E-AC-3 5.1 a 1536k y hasta 2304k (cinco veces el estandar de Blu-ray).
#
# VIVE AQUI Y NO EN CADA SCRIPT porque la MISMA regla hace falta en los dos
# caminos -encode.ps1 y audio_encode.ps1- y en este proyecto dos copias de una
# regla ya han divergido tres veces (New-DeeAtmosXml, el motor de audio, las
# cuatro listas de temporales). Los dos la llaman; nadie la reimplementa.
# DOS numeros por rama, y son cosas distintas:
#   *TriggerK = a partir de que bitrate MERECE LA PENA tocar la pista
#   *MaxK     = a que bitrate se recodifica cuando se toca
# El disparo esta en 640k -no en 449- porque recortar un 512k a 448k ahorra un
# 12 % y cuesta una generacion de perdida: no sale a cuenta. MEDIDO sobre la
# biblioteca (749 peliculas con exceso, 217 GiB en pistas no-Atmos):
#     449-511k   151 pistas    17 GiB   <- se renuncia
#     512-639k    58 pistas    11 GiB   <- se renuncia
#     640k        663 pistas  103 GiB   <- el grueso, y entra
#     641-1000k  193 pistas    57 GiB
#     >1000k      40 pistas    29 GiB
# O sea que disparar en 640 deja fuera 209 pistas y 28 GiB, y conserva 189.
# El 640k del AC3 es ademas el estandar de Blu-ray y es justo donde esta el
# grueso: 448k de DD+ equivale a ese 640k de AC3 porque DD+ es mas eficiente.
$MinCopyAudioTriggerK       = 640    # multicanal: se toca a partir de aqui
$MaxCopyAudioK             = 448    # multicanal: y se recorta a esto. 0 = sin tope
$MinCopyAudioTriggerStereoK = 320    # estereo/mono: mismo ratio
$MaxCopyAudioStereoK       = 224

function Get-CopyAudioCapK {
    <#
      Devuelve los kbps a los que hay que recodificar una pista que SE IBA A
      COPIAR, o 0 si hay que dejarla en paz.

      GUARDAS, y las tres son por algo:

      1. ATMOS. Un E-AC-3 5.1 a 768k PUEDE ser Atmos (DD+ JOC) y 'codec_name' no
         lo dice: sale como 'eac3' a secas. Se vio en la primera prueba, con
         'Intercambiados': ffprobe daba
             profile='Dolby Digital Plus + Dolby Atmos'
         en las dos pistas que iban a ser capadas. Recodificarlas habria perdido
         los objetos EN SILENCIO. Por eso hay que pasarle el 'profile' de la
         pista, no solo el codec.

      2. MAS DE 6 CANALES. El encoder eac3 de ffmpeg topa en 5.1, asi que capar
         un 7.1 le costaria CANALES, no bitrate. Se deja entero.

      3. UMBRAL DE DISPARO, no margen. Solo se toca a partir de
         $MinCopyAudioTriggerK (640k multicanal): recortar un 512k a 448k ahorra
         un 12 % y cuesta una generacion de perdida, y eso no sale a cuenta.
         Ver el desglose medido junto a la constante.
    #>
    param(
        [int]$Ch,
        [long]$Bps,
        [string]$Profile = '',
        [int]$MaxMultiK  = -1,
        [int]$MaxStereoK = -1,
        [int]$TriggerMultiK  = -1,
        [int]$TriggerStereoK = -1,
        # "Gordo" no significa lo mismo en cada codec: 640k es el MAXIMO NORMAL
        # del AC-3 (el estandar de Blu-ray), mientras que en DD+ 640k ya es
        # generoso -448k de DD+ equivale a ese 640k de AC-3 porque DD+ es mas
        # eficiente-. Recortar un AC-3 correctamente dimensionado solo compra una
        # generacion de perdida; recortar un DD+ de 640k quita bits que sobran.
        # Por eso el AC-3 solo se toca POR ENCIMA de 640k.
        [string]$Codec = ''
    )
    if ($MaxMultiK      -lt 0) { $MaxMultiK      = $MaxCopyAudioK }
    if ($MaxStereoK     -lt 0) { $MaxStereoK     = $MaxCopyAudioStereoK }
    if ($TriggerMultiK  -lt 0) { $TriggerMultiK  = $MinCopyAudioTriggerK }
    if ($TriggerStereoK -lt 0) { $TriggerStereoK = $MinCopyAudioTriggerStereoK }
    if ($MaxMultiK -le 0)  { return 0 }
    if ($Ch -gt 6 -or $Bps -le 0) { return 0 }
    # EL ATMOS NO SE TOCA NUNCA. Dos guardas, no una:
    #
    #  a) si el 'profile' dice Atmos/JOC -> se copia. ffprobe 8.1 lo devuelve
    #     como 'Dolby Digital Plus + Dolby Atmos'.
    #
    #  b) SI NO SE PUEDE SABER, TAMPOCO SE TOCA. Con un E-AC-3 el profile de
    #     ffprobe sale 'unknown' cuando NO hay Atmos y con el texto de Atmos
    #     cuando lo hay; una cadena VACIA significa que no se ha podido sondear
    #     (ffprobe viejo, fichero raro), y ahi lo unico seguro es no tocar.
    #     Recodificar un DD+ JOC pierde los objetos EN SILENCIO y no hay vuelta
    #     atras: no existe ninguna ruta ddp -> atmos_ddp (el esquema de DEE solo
    #     llega al Atmos desde el mezzanine o desde PCM+metadatos), asi que el
    #     Atmos perdido se pierde para siempre.
    #     Preferimos no ahorrar unos GB a arriesgar un Atmos. Ver la preferencia
    #     de fallar alto antes que degradar en silencio.
    if ($Profile -match '(?i)atmos|joc') { return 0 }
    if (($Codec -in @('eac3','ec-3','e-ac-3')) -and [string]::IsNullOrWhiteSpace($Profile)) { return 0 }
    $tope    = if ($Ch -gt 2) { $MaxMultiK }     else { $MaxStereoK }
    $disparo = if ($Ch -gt 2) { $TriggerMultiK } else { $TriggerStereoK }
    # AC-3 justo en su maximo normal: se deja. Ver el comentario de -Codec.
    if (($Codec -eq 'ac3') -and ($Bps -le ($disparo * 1000))) { return 0 }
    if ($Bps -ge ($disparo * 1000)) { return $tope }
    return 0
}

function Get-DdpBitrateForLossy {
    <#
      kbps de DD+ para una pista de origen CON PERDIDA y bitrate bajo (Opus, Vorbis,
      MP3...). Anadida el 04/08/2026.

      POR QUE no vale Get-DdpBitrate a secas: esa funcion mira SOLO los canales y da
      256k a cualquier cosa por debajo de 5.1. Para un Opus de 128k eso es el doble,
      y para un Vorbis de 64k el cuadruple, sin recuperar un solo detalle: el techo
      de calidad ya lo puso el encoder original. Se dimensiona sobre el ORIGEN con un
      50 % de margen -holgura para no acumular artefactos en la cascada lossy->lossy-
      y se acota por canales.

      NO se aplica a fuentes SIN perdida (FLAC, PCM) ni a DTS: ahi el bitrate de
      origen no dice nada sobre cuanto necesita el DD+ (un FLAC estereo son ~800 kbps
      y no por eso hacen falta).

      El resultado se AJUSTA A LA REJILLA de DEE, que valida contra una lista cerrada
      (sale de 'dee.exe --schema', filtro pcm_to_ddp, que es el que usa deew para el
      DD+ sin Atmos). Ojo al tramo alto: despues de 400 los saltos son 448/512/576/
      640, asi que 416 o 480 NO son validos aunque sean multiplos de 32. Se sube
      siempre al primer valor valido, nunca se baja: no quitar calidad por redondeo.
    #>
    param([int]$Ch, [long]$SrcBps)

    # Rejilla del esquema de DEE (pcm_to_ddp). La ruta ATMOS es otra y mas corta
    # (solo 384/448/576/640/768/1024); esta no vale para aquella.
    $grid = @(32,40,48,56,64,72,80,88,96,104,112,120,128,144,160,176,
              192,200,208,216,224,232,240,248,256,272,288,304,320,336,
              352,368,384,400,448,512,576,640,704,768,832,896,960,1008,1024)

    if ($SrcBps -le 0) { return (Get-DdpBitrate $false $Ch 768) }   # sin dato: como antes

    $piso  = if ($Ch -ge 8) { 384 } elseif ($Ch -ge 6) { 256 } else { 128 }
    $techo = if ($Ch -ge 6) { 640 } else { 256 }
    $k = [int][math]::Ceiling(($SrcBps / 1000.0) * 1.5)
    if ($k -lt $piso)  { $k = $piso }
    if ($k -gt $techo) { $k = $techo }
    foreach ($v in $grid) { if ($v -ge $k) { return $v } }
    return 640
}

function Test-DeeWorthy {
    <#
      Una pista que NO se copia -el TV no la decodifica- tiene dos destinos
      posibles: el DD+ de DEE o el eac3 de ffmpeg. Esta funcion decide cual.

      VIVE AQUI POR EL MISMO MOTIVO QUE Get-CopyAudioCapK: la regla hace falta en
      los DOS motores y las dos copias YA HABIAN DIVERGIDO (visto el 02/09/2026).
      La misma pelicula salia con una pista distinta segun por que cola entrase:
      encode.ps1 mandaba al eac3 de ffmpeg todo lo lossy y los estereo sin
      perdida, y audio_encode.ps1 mandaba a DEE TODO lo no nativo. Ninguna de las
      dos era "la mala"; lo malo era que fueran dos.

      El criterio, decidido el 02/09/2026:

        - MULTICANAL (>2) -> DEE. El encoder de Dolby es mejor a igual bitrate y
          maneja el 7.1 el solo; el eac3 de ffmpeg topa en 5.1 y obliga a
          downmixear. En una pista de 5.1 esa diferencia se paga.
        - ESTEREO/MONO -> eac3 de ffmpeg. Pasar un estereo por DEE cuesta MINUTOS
          (extraccion a .mka, DAMF, dee.exe) y no aporta nada audible. Es el
          mismo razonamiento que ya se aplicaba a los comentarios y a la ruta
          'tope'.
        - DTS a cualquier numero de canales -> DEE. No es un capricho: los dos
          motores YA coincidian en esto, asi que no forma parte de la divergencia
          que se estaba arreglando y cambiarlo seria una decision de calidad que
          nadie ha pedido.

      El AC-3/E-AC-3/AAC/MP3 no llega aqui: eso se COPIA (lo decodifica el TV).
    #>
    param([string]$Codec, [int]$Ch)
    if ("$Codec".Trim().ToLower() -eq 'dts') { return $true }
    return ($Ch -gt 2)
}

function Get-Eac3BitrateK {
    <#
      kbps del eac3 de ffmpeg para una pista no nativa que NO va por DEE. Estaba
      escrito a mano dentro de encode.ps1; desde el 02/09/2026 lo llaman los dos
      motores, igual que Test-DeeWorthy.

      CON PERDIDA y bitrate conocido: se dimensiona sobre el ORIGEN con un 50 %
      de margen -holgura para no acumular artefactos en la cascada lossy->lossy-
      redondeando hacia arriba a multiplos de 32k, que es la rejilla de E-AC-3.
      Gastar 384k en transportar un Opus de 128k es tirar el triple de bits sin
      recuperar un solo detalle: el techo de calidad ya lo puso el encoder
      original.

      SIN PERDIDA (FLAC, PCM), codec desconocido o sin dato de bitrate: cifra
      fija. Ahi el bitrate de origen no dice NADA sobre lo que necesita el E-AC-3
      (un FLAC estereo son ~800k y no por eso hacen falta).

      Los suelos y techos por canales evitan los dos extremos: que un Vorbis de
      64k acabe en un EAC3 de 96k -por debajo de lo que el codec hace bien- y que
      un MP3 de 320k se lleve 480k sin ninguna ganancia.

      Las ramas MULTICANAL se conservan aunque hoy Test-DeeWorthy mande todo lo
      de >2 canales a DEE: esta funcion responde "cuanto", no "por donde", y
      dejarla coja obligaria a reescribirla el dia que la otra regla cambie.
    #>
    param([int]$Ch, [long]$SrcBps, [bool]$LossyBajo)

    if ((-not $LossyBajo) -or ($SrcBps -le 0)) {
        if ($Ch -ge 8) { return 640 }
        if ($Ch -ge 6 -and $SrcBps -gt 0 -and $SrcBps -lt 160000) { return 448 }
        if ($Ch -ge 6) { return 640 }
        return 384
    }
    $piso  = if ($Ch -ge 8) { 384 } elseif ($Ch -ge 6) { 256 } else { 128 }
    $techo = if ($Ch -ge 6) { 640 } else { 256 }
    $k = [int]([math]::Ceiling(($SrcBps / 1000.0) * 1.5 / 32.0) * 32)
    if ($k -lt $piso)  { $k = $piso }
    if ($k -gt $techo) { $k = $techo }
    return $k
}

function Get-DeeFps([string]$r) {
    $v = 0.0
    if     ($r -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) { $v = [double]$Matches[1] / [double]$Matches[2] }
    elseif ($r -match '^[\d.]+$')                                     { $v = [double]$r }
    if ([math]::Abs($v-23.976) -lt 0.015) { return '23.976' }
    if ([math]::Abs($v-24)     -lt 0.015) { return '24' }
    if ([math]::Abs($v-25)     -lt 0.015) { return '25' }
    if ([math]::Abs($v-29.97)  -lt 0.015) { return '29.97' }
    if ([math]::Abs($v-30)     -lt 0.015) { return '30' }
    if ([math]::Abs($v-50)     -lt 0.015) { return '50' }
    if ([math]::Abs($v-59.94)  -lt 0.02)  { return '59.94' }
    if ([math]::Abs($v-60)     -lt 0.015) { return '60' }
    return 'not_indicated'
}

function Get-TrueHDDialnorm {
    # Lee el 'Dialogue Level' del stream TrueHD via 'truehdd info' y lo devuelve
    # como entero dBFS en [-31..0]. 0 = no se pudo leer => el llamante NO fuerza
    # dialnorm (se queda el measure_only actual, sin cambiar nada). El master trae
    # su propio dialnorm; preservarlo evita que la pista DD+ acabe a distinto
    # volumen que el TrueHD de origen cuando DEE mide y decide otro valor.
    # (Formato confirmado en la sesion previa: 'truehdd info' -> 'Dialogue Level',
    #  con tope en >= -31, igual que el main.py de referencia.)
    param(
        [Parameter(Mandatory=$true)][string]$Thd,
        [string]$Truehdd = 'C:\scripts\bin\truehdd.exe'
    )
    if (-not (Test-Path -LiteralPath $Thd))     { return 0 }
    if (-not (Test-Path -LiteralPath $Truehdd)) { return 0 }
    $info = ""
    try { $info = (& $Truehdd info $Thd 2>&1 | Out-String) } catch { return 0 }
    if ($info -match '(?im)Dialogue\s*Level[^\r\n0-9-]*(-?[0-9]+)') {
        $v = [int]$Matches[1]
        if ($v -gt 0) { $v = -$v }       # por si el volcado diera la magnitud (27 -> -27)
        # CLAMP A [-31, 0] DE UNA PIEZA (31/08/2026). Aqui habia dos 'if' sueltos y
        # el segundo -'if ($v -gt 0) { $v = 0 }'- era CODIGO MUERTO: la negacion de
        # la linea de arriba ya deja $v en cero o negativo, asi que nunca se cumplia.
        # Parecia que cubria el limite superior y no cubria nada. Asi la intencion
        # -el rango que aceptan el XSD y el main.py de referencia- se lee entera y
        # de verdad se aplica por los dos lados.
        return [math]::Max(-31, [math]::Min(0, $v))
    }
    return 0
}

function New-DeeAtmosXml($DamfName, $DamfPath, $Ec3Name, $Ec3Path, $TempPath, $DataRate, $Fps, [int]$Dialnorm = 0) {
    # custom_dialnorm: ultimo hijo de encode_to_atmos_ddp (tras custom_trims), solo
    # valido con measure_only (lo que usamos). 0 = sin override (por defecto y lo que
    # el XSD recomienda). Con un valor en [-31..-1] se fuerza el dialnorm del master.
    $dnLine = ""
    if ($Dialnorm -lt 0 -and $Dialnorm -ge -31) {
        $dnLine = "`n      <custom_dialnorm>$Dialnorm</custom_dialnorm>"
    }
    return @"
<?xml version="1.0"?>
<job_config>
  <input><audio>
    <damf version="1">
      <file_name>$DamfName</file_name>
      <timecode_frame_rate>$Fps</timecode_frame_rate>
      <offset>auto</offset><ffoa>auto</ffoa>
      <storage><local><path>$DamfPath</path></local></storage>
    </damf>
  </audio></input>
  <filter><audio>
    <encode_to_atmos_ddp version="1">
      <loudness><measure_only>
        <metering_mode>1770-4</metering_mode>
        <dialogue_intelligence>true</dialogue_intelligence>
        <speech_threshold>15</speech_threshold>
      </measure_only></loudness>
      <data_rate>$DataRate</data_rate>
      <timecode_frame_rate>$Fps</timecode_frame_rate>
      <start>first_frame_of_action</start><end>end_of_file</end>
      <time_base>file_position</time_base>
      <prepend_silence_duration>0.0</prepend_silence_duration>
      <append_silence_duration>0.0</append_silence_duration>
      <drc><line_mode_drc_profile>film_light</line_mode_drc_profile>
           <rf_mode_drc_profile>film_light</rf_mode_drc_profile></drc>
      <downmix>
        <loro_center_mix_level>-3</loro_center_mix_level>
        <loro_surround_mix_level>-3</loro_surround_mix_level>
        <ltrt_center_mix_level>-3</ltrt_center_mix_level>
        <ltrt_surround_mix_level>-3</ltrt_surround_mix_level>
        <preferred_downmix_mode>loro</preferred_downmix_mode>
      </downmix>
      <custom_trims>
        <surround_trim_5_1>auto</surround_trim_5_1>
        <height_trim_5_1>auto</height_trim_5_1>
      </custom_trims>$dnLine
    </encode_to_atmos_ddp>
  </audio></filter>
  <output><ec3 version="1">
    <file_name>$Ec3Name</file_name>
    <storage><local><path>$Ec3Path</path></local></storage>
  </ec3></output>
  <misc><temp_dir><clean_temp>true</clean_temp><path>$TempPath</path></temp_dir></misc>
</job_config>
"@
}

function Invoke-FfmpegProgress {
    <#
      ffmpeg con progreso CONTINUO, para las fases que antes se quedaban mudas.

      El problema que resuelve: las llamadas de extraccion y de remux son de
      disco (leer y reescribir ficheros de 20-40 GB) y son las mas largas en
      pelis grandes, pero no reportaban nada. La barra del panel se quedaba
      clavada en 0 durante la extraccion y en 99 durante el remux, pareciendo
      colgada justo cuando mas rato pasa.

      Mecanismo: el mismo que ya usa encode.ps1 para el video. Se le pasa a
      ffmpeg '-progress <fichero>' y va escribiendo alli su posicion mientras
      trabaja; aqui se sondea ese fichero cada medio segundo y se traduce a %.

      Se parsea 'out_time' (HH:MM:SS.mmm) y NO 'out_time_ms': ese campo tiene
      una ambiguedad historica en ffmpeg (unas versiones lo escriben en
      milisegundos y otras en microsegundos) y daria porcentajes x1000.

      Devuelve $true si ffmpeg termino con codigo 0.
    #>
    param(
        [Parameter(Mandatory)][string]$Ffmpeg,
        [Parameter(Mandatory)][string[]]$FfArgs,
        [Parameter(Mandatory)][string]$ProgFile,
        [double]$DurationSec = 0,
        [scriptblock]$OnProgress = $null,
        [string]$Stage = 'ffmpeg'
    )
    Remove-Item -LiteralPath $ProgFile -ErrorAction SilentlyContinue
    $all = @('-progress', $ProgFile, '-nostats', '-loglevel', 'error') + $FfArgs
    # CITADO POR ELEMENTO, imprescindible. Start-Process -ArgumentList une el
    # array con espacios SIN citar nada, asi que una ruta como
    # "El senyor de los anillos - ... (2003).mkv" se partiria en pedazos y ffmpeg
    # recibiria media docena de argumentos basura. Es el mismo bug que ya mordio
    # en encode.ps1; se usa aqui su misma solucion, incluidos los parentesis en
    # la clase de caracteres (los nombres de pelicula llevan el anyo entre
    # parentesis constantemente).
    $argline = ($all | ForEach-Object {
        if ($_ -match '[\s"()]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" }
    }) -join ' '
    $proc = $null
    try {
        $proc = Start-Process -FilePath $Ffmpeg -ArgumentList $argline -NoNewWindow -PassThru -ErrorAction Stop
    } catch {
        Log "    [ffmpeg] ERROR al lanzar: $_"
        return $false
    }
    # Sin tocar .Handle, .ExitCode puede venir a $null tras salir el proceso.
    # Mismo bug que ya mordio en encode.ps1 con ffmpeg y con el OCR.
    $null = $proc.Handle
    if ($OnProgress) { & $OnProgress $Stage 0 }
    $last = -1.0
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if ($DurationSec -le 0 -or -not $OnProgress) { continue }
        try {
            $tail = Get-Content -LiteralPath $ProgFile -Tail 16 -ErrorAction SilentlyContinue
            $m = $tail | Select-String -Pattern '^out_time=(\d+):(\d+):([\d.]+)' | Select-Object -Last 1
            if ($m) {
                $g = $m.Matches[0].Groups
                $sec = ([double]$g[1].Value * 3600) + ([double]$g[2].Value * 60) + [double]$g[3].Value
                $pct = [math]::Min(100.0, ($sec / $DurationSec) * 100.0)
                # Solo se reporta cada punto entero: evita machacar el fichero de
                # status dos veces por segundo sin que la barra gane nada.
                if (($pct - $last) -ge 1.0) { $last = $pct; & $OnProgress $Stage $pct }
            }
        } catch { }
    }
    $proc.WaitForExit()
    Remove-Item -LiteralPath $ProgFile -ErrorAction SilentlyContinue
    return ($proc.ExitCode -eq 0)
}

# ===========================================================================
#  CACHE DE .ec3: no repetir 60-90 minutos de DEE por el mismo audio
# ===========================================================================
# POR QUE: convertir una pista Atmos cuesta ~90 min (truehdd ~30 + DEE ~60) y hoy
# se repite ENTERA cada vez que un trabajo vuelve a pasar por aqui. Y vuelve mas
# de lo que parece: un fallo transitorio de disco sale con 75 (EX_TEMPFAIL) y el
# watcher REENCOLA el fichero, asi que el reintento rehace un audio que ya estaba
# perfecto. Tambien sirve para reaprovechar .ec3 producidos fuera del pipeline
# (p.ej. un benchmark) via Import-DdpCacheEntry.
#
# DONDE VIVE, Y POR QUE NO EN $BigTmp: los tres watchers y stop-mediabox.ps1
# barren $BigTmp con los patrones 'ddp_*','dee_*','d_*','a_*','thd_*',... y el
# Get-ChildItem -Filter casa TAMBIEN con directorios. Una carpeta 'ddp_cache'
# dentro de G:\MediaTmp se borraria sola en el primer barrido. Por eso la cache
# vive FUERA, en G:\DdpCache, que ningun barrido mira.
#
# SEGURIDAD (que la cache NO sirva audio equivocado, que seria peor que no
# tenerla): la clave incluye ruta + tamanyo + fecha de modificacion del ORIGEN,
# ademas de pista/bitrate/atmos. Y en cada acierto se revalida DOS cosas:
#   1. el sidecar .json describe el mismo origen (defensa ante colision de hash)
#   2. la DURACION del .ec3 cuadra con la esperada -lo unico que delata a un
#      .ec3 truncado por un DEE muerto a mitad, que pesa lo suyo y parece bueno-
# Si algo no cuadra, se ignora la entrada y se reconvierte. Nunca se sirve a
# medias: en la duda, trabajar de mas.

function Get-DdpCacheDir {
    # Carpeta de la cache. Fuera de $BigTmp a proposito (ver arriba).
    # Devuelve '' si no se puede usar: el llamante sigue SIN cache, nunca falla.
    param([string]$Preferred = 'G:\DdpCache')
    try {
        New-Item -ItemType Directory -Force -Path $Preferred -ErrorAction Stop | Out-Null
        $probe = Join-Path $Preferred (".wtest_{0}" -f $PID)
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $Preferred
    } catch {
        Log "    [cache] AVISO: no puedo usar $Preferred ($($_.Exception.Message)). Sigo sin cache."
        return ''
    }
}

function Get-DdpCacheKey {
    <#
      Identidad de (origen + pista + parametros). Si CUALQUIERA cambia, la clave
      cambia y no hay acierto: es lo que impide servir el audio de otra cosa.
      Se incluyen tamanyo y fecha del origen porque una ruta sola no basta -un
      fichero re-descargado con el mismo nombre es OTRO audio-.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$InputFile,
        [Parameter(Mandatory=$true)][int]$AudioIndex,
        [Parameter(Mandatory=$true)][int]$Bitrate,
        [bool]$IsAtmos = $true
    )
    $it = Get-Item -LiteralPath $InputFile -ErrorAction SilentlyContinue
    if (-not $it) { return '' }
    # SOLO EL NOMBRE, no la ruta completa. El pipeline MUEVE el fichero de
    # encode_queue a encode_running antes de procesarlo, asi que una clave con la
    # ruta cambiaba entre el momento de guardar y el de consultar: la cache nunca
    # habria acertado en su caso de uso principal (el reintento de un trabajo
    # reencolado, que ademas se reencola DESDE running). Comprobado moviendo un
    # fichero entre dos carpetas: la clave cambiaba.
    # Nombre + tamanyo + fecha de modificacion siguen identificando el fichero de
    # forma solida -dos peliculas distintas no coinciden en los tres- y el mover
    # dentro del mismo volumen conserva la fecha.
    $raw = "{0}|{1}|{2}|{3}|{4}|{5}" -f `
            ($it.Name.ToLowerInvariant()), `
            $it.Length, $it.LastWriteTimeUtc.Ticks, $AudioIndex, $Bitrate, ([int]$IsAtmos)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
        return ([System.BitConverter]::ToString($h) -replace '-','').Substring(0, 24).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-Ec3DurationSec {
    # Duracion de un .ec3 segun ffprobe. 0 si no se puede leer (el llamante trata
    # el 0 como "no se puede validar" y NO usa la entrada: en la duda, reconvertir).
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Ffprobe = ''
    )
    if (-not $Ffprobe) { $Ffprobe = 'ffprobe' }
    try {
        $d = & $Ffprobe -v error -show_entries format=duration -of csv=p=0 -- $Path 2>$null
        # Invariante SIEMPRE: en es-ES un TryParse normal lee "30.000000" como 30
        # millones de segundos y la validacion de la cache se vuelve un sinsentido
        # (rechazaria todo). Ver ConvertTo-DoubleInv.
        $v = ConvertTo-DoubleInv $d
        if ($null -ne $v) { return $v }
    } catch { }
    return 0.0
}

function Get-AudioTrackDurationSec {
    <#
      Duracion REAL de una pista de audio concreta (a:N), en segundos. 0 si no se
      puede leer. Se usa como referencia del control de integridad del .ec3 en vez
      de la duracion del CONTENEDOR, porque no son lo mismo cuando el fichero tiene
      pistas de distinta longitud.

      Caso que lo motivo (WALL-E, 11/08/2026): la pista TrueHD inglesa duraba
      5892,6 s -lo mismo que el video-, pero otra pista (un DTS español) duraba
      5922 s por relleno, asi que el CONTENEDOR marcaba 5922. El .ec3 Atmos salia
      correcto a 5893 s y el control lo comparaba contra los 5922 del contenedor:
      30 s de "desvio" -> lo daba por TRUNCADO y degradaba el Atmos a EAC3. Falso
      positivo: el .ec3 casaba perfectamente con SU pista.

      Prioridad: el tag DURATION que escribe mkvmerge por pista (fiable, es el que
      mostraba 5892,6 s), y si no, el 'duration' del stream. TrueHD en MKV muchas
      veces no expone 'duration' de stream, de ahi que se pruebe primero el tag.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$InputFile,
        [Parameter(Mandatory=$true)][int]$AudioIndex,
        [string]$Ffprobe = '',
        # Duracion del contenedor, si el llamante ya la tiene: sirve para acotar el
        # seek de la 3a via (ver abajo) y ahorrarse leer format=duration.
        [double]$ContainerHintSec = 0
    )
    if (-not $Ffprobe) { $Ffprobe = 'ffprobe' }

    # 1) El tag DURATION (lo escribe mkvmerge por pista) o el 'duration' del stream.
    #    Instantaneo, pero un fichero CRUDO (no remuxeado por el pipeline) no los
    #    trae: WALL-E daba 0 en las dos. De ahi la 3a via.
    foreach ($entrada in @('stream_tags=DURATION', 'stream=duration')) {
        try {
            $raw = & $Ffprobe -v error -select_streams "a:$AudioIndex" `
                     -show_entries $entrada -of csv=p=0 -- $InputFile 2>$null
            $raw = ("$raw" -split "`n")[0].Trim()
            if (-not $raw) { continue }
            # El tag DURATION viene como HH:MM:SS.mmmmmmmmm; 'duration' como segundos.
            if ($raw -match '^(\d+):(\d{2}):(\d{2}(?:\.\d+)?)$') {
                $h = [int]$Matches[1]; $m = [int]$Matches[2]
                $s = ConvertTo-DoubleInv $Matches[3]
                if ($null -ne $s) { return ($h * 3600 + $m * 60 + $s) }
            } else {
                $v = ConvertTo-DoubleInv $raw
                if ($null -ne $v -and $v -gt 0) { return $v }
            }
        } catch { }
    }

    # 2) El pts del ULTIMO paquete de la pista. Es la duracion real y es
    #    independiente de la extraccion (justo lo que necesita el control de
    #    integridad). TrueHD en MKV crudo no expone ni tag ni 'duration', pero los
    #    paquetes SIEMPRE estan. Leer la pista entera son 7 millones de paquetes
    #    (~40 s y mucha RAM), asi que se SALTA a la cola con -read_intervals: se
    #    empieza 180 s antes del final del contenedor y se lee hasta el final.
    #    Medido en WALL-E: 4,5 s. El margen de 180 s cubre que una pista dure hasta
    #    3 min menos que la mas larga del fichero (WALL-E: 30 s menos). Si durara
    #    aun menos, la cola vendria vacia y se cae al contenedor (return 0).
    try {
        $cont = $ContainerHintSec
        if ($cont -le 0) {
            $cont = ConvertTo-DoubleInv (& $Ffprobe -v error -show_entries format=duration -of csv=p=0 -- $InputFile 2>$null)
        }
        $ini = 0.0
        if ($cont -gt 200) { $ini = $cont - 180 }
        $intervalo = "{0}%+99999" -f ([int]$ini)
        $pts = & $Ffprobe -v error -select_streams "a:$AudioIndex" `
                 -read_intervals $intervalo -show_entries 'packet=pts_time' `
                 -of csv=p=0 -- $InputFile 2>$null
        $ultimo = 0.0
        foreach ($linea in @($pts)) {
            $v = ConvertTo-DoubleInv ("$linea".Trim())
            if ($null -ne $v -and $v -gt $ultimo) { $ultimo = $v }
        }
        # Sano: dentro del contenedor y no ridiculamente corto.
        if ($ultimo -gt 60 -and ($cont -le 0 -or $ultimo -le $cont + 5)) { return $ultimo }
    } catch { }

    return 0.0
}

function Get-DdpCacheHit {
    <#
      Devuelve la ruta del .ec3 cacheado si existe Y pasa las dos validaciones.
      '' si no hay acierto utilizable. NUNCA lanza: un fallo de la cache tiene que
      degradar a "convertir normalmente", jamas tumbar el trabajo.
    #>
    # ToleranceSec es la tolerancia de COHERENCIA (duracion guardada vs la esperada
    # por el llamante). 30 s y no 5: la duracion "esperada" que pasan encode.ps1 y
    # audio_encode.ps1 es la del CONTENEDOR, y el video suele durar unos segundos
    # MAS que el audio (creditos, frames negros al final). Medido en El Unico
    # Superviviente: contenedor 7276 s, pista 7268 s -> 7,6 s de diferencia
    # legitima que una tolerancia de 5 s marcaba como "truncado". Lo que de verdad
    # protege contra un .ec3 corrompido DESPUES de guardarse no es esta tolerancia
    # sino el chequeo de INTEGRIDAD de abajo, que es exacto.
    param(
        [Parameter(Mandatory=$true)][string]$CacheDir,
        [Parameter(Mandatory=$true)][string]$Key,
        [double]$ExpectedDurationSec = 0,
        [double]$ToleranceSec = 30,
        [string]$Ffprobe = ''
    )
    if (-not $CacheDir -or -not $Key) { return '' }
    $ec3  = Join-Path $CacheDir "$Key.ec3"
    $meta = Join-Path $CacheDir "$Key.json"
    if (-not (Test-Path -LiteralPath $ec3))  { return '' }
    if (-not (Test-Path -LiteralPath $meta)) {
        Log "    [cache] entrada sin sidecar ($Key): la ignoro."
        return ''
    }
    $it = Get-Item -LiteralPath $ec3 -ErrorAction SilentlyContinue
    if (-not $it -or $it.Length -le 1024) { return '' }

    $m = $null
    try { $m = Get-Content -LiteralPath $meta -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return '' }
    if (-not $m -or "$($m.key)" -ne "$Key") {
        Log "    [cache] sidecar no casa con la clave ($Key): la ignoro."
        return ''
    }

    # Validacion en DOS niveles, cada uno contra un fallo distinto:
    #
    #  1. INTEGRIDAD (exacta): la duracion de AHORA tiene que ser la que se anoto al
    #     guardar. Es lo que detecta que el .ec3 se trunco o corrompio DESPUES de
    #     entrar en la cache (copia interrumpida, disco lleno a mitad, barrido a
    #     medias). Aqui la tolerancia es minima a proposito: comparamos el fichero
    #     consigo mismo, no hay diferencias legitimas posibles.
    #
    #  2. COHERENCIA (holgada): lo guardado tiene que parecerse a lo que el llamante
    #     espera. Protege contra haber guardado un CLIP en vez de la pelicula. Va
    #     holgada porque la referencia del llamante es la duracion del CONTENEDOR y
    #     el video dura algo mas que el audio (ver el comentario del param).
    #
    # La identidad (que sea el audio de ESTA pelicula y ESTA pista) no depende de
    # ninguna de las dos: la garantiza la CLAVE, que incluye ruta+tamanyo+fecha.
    $dur = Get-Ec3DurationSec -Path $ec3 -Ffprobe $Ffprobe
    if ($dur -le 0) {
        Log "    [cache] no puedo leer la duracion del .ec3 cacheado: lo ignoro."
        return ''
    }
    $guardada = 0.0
    if ($null -ne $m.durationSec) { $guardada = [double]$m.durationSec }
    if ($guardada -gt 0) {
        if ([math]::Abs($dur - $guardada) -gt 0.5) {
            Log ("    [cache] INTEGRIDAD: el .ec3 dura {0:N0}s pero se guardo con {1:N0}s. Corrupto o a medias: lo ignoro." -f $dur, $guardada)
            return ''
        }
    }
    if ($ExpectedDurationSec -gt 0) {
        $delta = [math]::Abs($dur - $ExpectedDurationSec)
        if ($delta -gt $ToleranceSec) {
            Log ("    [cache] COHERENCIA: .ec3 de {0:N0}s frente a {1:N0}s esperados ({2:N0}s de desvio). Lo ignoro." -f $dur, $ExpectedDurationSec, $delta)
            return ''
        }
    } elseif ($guardada -le 0) {
        # Ni duracion esperada ni duracion guardada: no hay NADA que validar.
        Log "    [cache] entrada sin duracion guardada y sin referencia: la ignoro."
        return ''
    }
    return $ec3
}

function Save-DdpCacheEntry {
    # Mete un .ec3 recien hecho en la cache. Escribe a un temporal y renombra:
    # si el proceso muere copiando, no queda una entrada a medias que un trabajo
    # posterior daria por buena.
    param(
        [Parameter(Mandatory=$true)][string]$CacheDir,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Ec3,
        [Parameter(Mandatory=$true)][string]$InputFile,
        [int]$AudioIndex = 0,
        [int]$Bitrate = 768,
        [bool]$IsAtmos = $true,
        [double]$DurationSec = 0
    )
    if (-not $CacheDir -or -not $Key) { return $false }
    try {
        # Crear la carpeta aqui: Get-DdpCacheDir la crea, pero a esta funcion se le
        # puede pasar un -CacheDir explicito (los tests y el importador lo hacen) que
        # aun no exista, y Copy-Item fallaba con "could not find a part of the path".
        New-Item -ItemType Directory -Force -Path $CacheDir -ErrorAction Stop | Out-Null
        $dst = Join-Path $CacheDir "$Key.ec3"
        $tmp = Join-Path $CacheDir "$Key.ec3.partial"
        Copy-Item -LiteralPath $Ec3 -Destination $tmp -Force -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $dst -Force -ErrorAction Stop
        [pscustomobject]@{
            key         = $Key
            source      = [System.IO.Path]::GetFullPath($InputFile)
            audioIndex  = $AudioIndex
            bitrate     = $Bitrate
            isAtmos     = $IsAtmos
            durationSec = $DurationSec
            created     = (Get-Date -Format 's')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $CacheDir "$Key.json") -Encoding UTF8
        Log ("    [cache] guardada entrada {0} ({1:N0} MB)" -f $Key, ((Get-Item -LiteralPath $dst).Length / 1MB))
        return $true
    } catch {
        Log "    [cache] AVISO: no pude guardar la entrada ($($_.Exception.Message)). Sigo igual."
        Remove-Item -LiteralPath (Join-Path $CacheDir "$Key.ec3.partial") -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Remove-DdpCacheStale {
    <#
      Poda la cache. Sin esto crece sin freno: cada pista son ~0,7 GB (768k x 2h)
      y G: tiene 223 GB que ademas comparte con los temporales pesados de 40 GB
      por trabajo. Se poda por EDAD y luego por TAMANYO TOTAL (mas viejo primero).
      Se llama tras guardar, que es cuando la cache crece.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CacheDir,
        [int]$MaxAgeDays = 14,
        [double]$MaxTotalGB = 25
    )
    if (-not $CacheDir -or -not (Test-Path -LiteralPath $CacheDir)) { return }
    try {
        $borrados = 0L
        # 1) Por edad.
        $limite = (Get-Date).AddDays(-$MaxAgeDays)
        foreach ($f in @(Get-ChildItem -LiteralPath $CacheDir -Filter '*.ec3' -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.LastWriteTime -lt $limite })) {
            $borrados += $f.Length
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ([System.IO.Path]::ChangeExtension($f.FullName, '.json')) -Force -ErrorAction SilentlyContinue
        }
        # 2) Por tamanyo total, del mas antiguo al mas nuevo.
        $files = @(Get-ChildItem -LiteralPath $CacheDir -Filter '*.ec3' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
        $total = ($files | Measure-Object -Property Length -Sum).Sum
        $i = 0
        while ($total -gt ($MaxTotalGB * 1GB) -and $i -lt $files.Count) {
            $f = $files[$i]; $i++
            $total -= $f.Length; $borrados += $f.Length
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ([System.IO.Path]::ChangeExtension($f.FullName, '.json')) -Force -ErrorAction SilentlyContinue
        }
        # Restos de copias interrumpidas.
        foreach ($p in @(Get-ChildItem -LiteralPath $CacheDir -Filter '*.partial' -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-6) })) {
            Remove-Item -LiteralPath $p.FullName -Force -ErrorAction SilentlyContinue
        }
        if ($borrados -gt 0) { Log ("    [cache] podada: {0:N1} GB liberados en $CacheDir" -f ($borrados / 1GB)) }
    } catch { }
}

function Import-DdpCacheEntry {
    <#
      Mete en la cache un .ec3 producido FUERA del pipeline (p.ej. por el
      benchmark de paralelismo), para no tirar 90 minutos de DEE por pista.
      Valida la duracion ANTES de aceptarlo: importar un .ec3 corto seria meter
      una pista incompleta en la biblioteca sin que salte ningun aviso.
      Devuelve $true si quedo importado.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Ec3,
        [Parameter(Mandatory=$true)][string]$InputFile,
        [Parameter(Mandatory=$true)][int]$AudioIndex,
        [int]$Bitrate = 768,
        [bool]$IsAtmos = $true,
        # 30 s por lo mismo que en Get-DdpCacheHit: se compara contra la duracion
        # del CONTENEDOR y el video dura algo mas que el audio. Un clip o un
        # truncado de verdad se desvia muchisimo mas que eso.
        [double]$ToleranceSec = 30,
        [string]$CacheDir = '',
        [string]$Ffprobe = ''
    )
    if (-not $CacheDir) { $CacheDir = Get-DdpCacheDir }
    if (-not $CacheDir) { return $false }
    if (-not (Test-Path -LiteralPath $Ec3)) { Log "    [cache] no existe $Ec3"; return $false }
    if (-not (Test-Path -LiteralPath $InputFile)) { Log "    [cache] no existe el origen $InputFile"; return $false }

    # LA REFERENCIA ES LA DURACION DE LA PISTA, NO LA DEL CONTENEDOR (02/09/2026).
    # Aqui se llamaba a Get-Ec3DurationSec sobre el MKV de origen, que lee
    # 'format=duration', o sea el contenedor: mide por la pista MAS LARGA. Es
    # exactamente la trampa que obligo a escribir Get-AudioTrackDurationSec, y con
    # una tolerancia de 30 s dejaba el caso WALL-E (contenedor 5922 s, pista Atmos
    # 5892 s = 30 s justos) en la mismisima frontera del rechazo. Se compara contra
    # la pista, que es de lo que sale el .ec3; si no se puede leer, se cae al
    # contenedor como antes.
    $esperada = Get-AudioTrackDurationSec -InputFile $InputFile -AudioIndex $AudioIndex -Ffprobe $Ffprobe
    if ($esperada -le 0) { $esperada = Get-Ec3DurationSec -Path $InputFile -Ffprobe $Ffprobe }
    $real     = Get-Ec3DurationSec -Path $Ec3 -Ffprobe $Ffprobe
    if ($esperada -le 0 -or $real -le 0) { Log "    [cache] no puedo leer duraciones; no importo."; return $false }
    $delta = [math]::Abs($real - $esperada)
    if ($delta -gt $ToleranceSec) {
        Log ("    [cache] RECHAZADO: el .ec3 dura {0:N0}s y el origen {1:N0}s (desvio {2:N0}s). Parece un clip o esta truncado." -f $real, $esperada, $delta)
        return $false
    }
    $key = Get-DdpCacheKey -InputFile $InputFile -AudioIndex $AudioIndex -Bitrate $Bitrate -IsAtmos $IsAtmos
    if (-not $key) { return $false }
    $ok = Save-DdpCacheEntry -CacheDir $CacheDir -Key $key -Ec3 $Ec3 -InputFile $InputFile `
              -AudioIndex $AudioIndex -Bitrate $Bitrate -IsAtmos $IsAtmos -DurationSec $real
    if ($ok) { Log ("    [cache] importado: {0} a:{1} ({2:N0}s) -> {3}" -f (Split-Path $InputFile -Leaf), $AudioIndex, $real, $key) }
    return $ok
}

function Convert-TrueHDToDDPCached {
    <#
      Envoltorio de Convert-TrueHDToDDP con cache. MISMA firma y mismo contrato:
      devuelve $true/$false y deja el .ec3 en $OutFile, y $global:DdpLastFailure
      conserva su significado ('diskfull' | 'other' | '').

      Es lo unico que cambia en los consumidores (encode.ps1 y audio_encode.ps1):
      una linea, el nombre de la funcion. La logica vive AQUI, en la libreria
      compartida, no copiada en cada uno: copiar ya divergio dos veces en este
      proyecto y hubo que deshacerlo.

      -NoCache desactiva la cache para una llamada concreta sin tocar nada mas.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$InputFile,
        [Parameter(Mandatory=$true)][int]$AudioIndex,
        [int]$Bitrate = 768,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [switch]$IsAtmos,
        [int]$Dialnorm = 0,
        [string]$Tmp        = 'C:\Media\tmp',
        [string]$BigTmp     = '',
        [int]$Channels      = 8,
        [string]$Dee        = 'C:\scripts\DEE\dee.exe',
        [string]$Truehdd    = 'C:\scripts\bin\truehdd.exe',
        [string]$Ffmpeg     = 'C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe',
        [string]$Mkvmerge   = 'C:\Program Files\MKVToolNix\mkvmerge.exe',
        [string]$Mkvextract = 'C:\Program Files\MKVToolNix\mkvextract.exe',
        [string]$Deew       = 'C:\scripts\bin\deew.exe',
        [double]$DurationSec = 0,
        [scriptblock]$OnProgress = $null,
        [switch]$NoCache,
        [string]$CacheDir = ''
    )

    # ffprobe al lado del ffmpeg que nos pasan, igual que hace Convert-TrueHDToDDP.
    $ffprobe = Join-Path (Split-Path $Ffmpeg -Parent) 'ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffprobe)) { $ffprobe = 'ffprobe' }

    $cache = ''
    $key   = ''
    if (-not $NoCache) {
        if ($CacheDir) { $cache = $CacheDir } else { $cache = Get-DdpCacheDir }
        if ($cache) {
            $key = Get-DdpCacheKey -InputFile $InputFile -AudioIndex $AudioIndex -Bitrate $Bitrate -IsAtmos ([bool]$IsAtmos)
        }
    }

    # --- ACIERTO: copiar y salir. Se ahorran 60-90 minutos de DEE. ---
    if ($cache -and $key) {
        $hit = Get-DdpCacheHit -CacheDir $cache -Key $key -ExpectedDurationSec $DurationSec -Ffprobe $ffprobe
        if ($hit) {
            try {
                Copy-Item -LiteralPath $hit -Destination $OutFile -Force -ErrorAction Stop
                $global:DdpLastFailure = ''
                Log ("    [cache] ACIERTO para a:{0} ({1}k): reutilizo el .ec3 y me ahorro la conversion." -f $AudioIndex, $Bitrate)
                # PODAR TAMBIEN EN EL ACIERTO (26/08/2026). Remove-DdpCacheStale
                # solo se llamaba tras GUARDAR, o sea solo cuando la cache crece.
                # Con una racha de aciertos -que es justo su caso de uso: los
                # reintentos de un trabajo reencolado- no se podaba nunca, y las
                # entradas de mas de 14 dias se quedaban ocupando G: sin que nada
                # las mirase. Cuesta un listado de directorio sobre una carpeta de
                # decenas de ficheros, frente a los 60-90 min que se acaban de
                # ahorrar: es gratis.
                Remove-DdpCacheStale -CacheDir $cache
                # El progreso salta al final: el panel no puede quedarse en 0 sin
                # explicacion cuando la conversion "termina" en dos segundos.
                if ($OnProgress) { & $OnProgress 'dee' 100 }
                return $true
            } catch {
                Log "    [cache] no pude copiar la entrada ($($_.Exception.Message)); convierto normalmente."
            }
        }
    }

    # --- FALLO de cache: conversion normal, sin cambiar nada del contrato. ---
    $ok = Convert-TrueHDToDDP -InputFile $InputFile -AudioIndex $AudioIndex -Bitrate $Bitrate `
              -OutFile $OutFile -IsAtmos:$IsAtmos -Dialnorm $Dialnorm -Tmp $Tmp -BigTmp $BigTmp `
              -Channels $Channels -Dee $Dee -Truehdd $Truehdd -Ffmpeg $Ffmpeg `
              -Mkvmerge $Mkvmerge -Mkvextract $Mkvextract -Deew $Deew `
              -DurationSec $DurationSec -OnProgress $OnProgress

    if ($ok -and $cache -and $key -and (Test-Path -LiteralPath $OutFile)) {
        $dur = Get-Ec3DurationSec -Path $OutFile -Ffprobe $ffprobe
        $null = Save-DdpCacheEntry -CacheDir $cache -Key $key -Ec3 $OutFile -InputFile $InputFile `
                    -AudioIndex $AudioIndex -Bitrate $Bitrate -IsAtmos ([bool]$IsAtmos) -DurationSec $dur
        Remove-DdpCacheStale -CacheDir $cache
    }
    return $ok
}

# === PARALELISMO DE PISTAS: Start / Step / Wait / Stop =====================
# El bucle de sondeo vivia DENTRO de Invoke-DdpTracksParallel, asi que el
# llamante se quedaba bloqueado hasta que terminaba TODO el audio. Eso es lo
# que impedia solapar el audio con el encode de VIDEO, que es GPU pura y no
# compite con DEE (medido 16/08/2026: el encode QSV usa 0,33 nucleos de CPU y
# tarda lo mismo con 4 nucleos ocupados; DEE es 1 nucleo y cero GPU).
#
# El corte es MECANICO: no cambia ni una decision, solo separa "lanzar" de
# "esperar".
#   Start- : reserva el espacio, crea las ranuras y lanza las primeras.
#            Devuelve el ESTADO (o $null si no se puede paralelizar).
#   Step-  : UNA pasada del relevo de ranuras, con el progreso opcional. NO
#            duerme: el ritmo lo pone quien llama (p. ej. el bucle que vigila a
#            ffmpeg mientras encodea el video).
#   Wait-  : Step en bucle hasta que no queda nadie vivo, volcado de los logs
#            de cada pista y recogida de resultados. Marca el estado como
#            UNIDO (Joined), que es lo que distingue "termino" de "lo dejamos
#            a medias".
#   Stop-  : mata lo que siga vivo. OBLIGATORIO antes de abandonar un trabajo
#            con workers en marcha: si no, quedan dee.exe huerfanos comiendose
#            G: mientras el watcher ya ha arrancado el trabajo siguiente.
#
# Invoke-DdpTracksParallel se conserva como envoltorio Start+Wait, con el MISMO
# contrato y el MISMO comportamiento de siempre, para que audio_encode.ps1 y el
# camino en serie de encode.ps1 no se enteren de este cambio.
# ===========================================================================

function Start-DdpSlot {
    <#
      Lanza el worker de UNA ranura. Era una funcion interna de
      Invoke-DdpTracksParallel que se apoyaba en las variables de su ambito;
      ahora esos datos viajan en el objeto de estado, que es lo que permite
      relanzar ranuras desde Step- mucho despues del Start-.
    #>
    param(
        [Parameter(Mandatory=$true)]$Slot,
        [Parameter(Mandatory=$true)]$State
    )
    $argsArr = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$State.WorkerPath,
        '-InputFile',   $State.InputFile,
        '-AudioIndex',  $Slot.Idx,
        '-Bitrate',     $Slot.Track.Bitrate,
        '-OutFile',     $Slot.Track.OutFile,
        '-IsAtmos',     $(if ($Slot.Track.IsAtmos) { 1 } else { 0 }),
        '-Channels',    $Slot.Track.Ch,
        '-DurationSec', $State.DurationSec,
        '-Tmp',         $State.Tmp,
        '-BigTmp',      $State.BigTmp,
        '-LibPath',     $State.LibPath,
        '-SlotLog',     $Slot.SlotLog,
        '-ResultFile',  $Slot.Result,
        '-ProgressFile',$Slot.Progress
    )
    # Citado POR ELEMENTO: -ArgumentList une con espacios sin citar, y los
    # nombres de pelicula llevan espacios y parentesis constantemente. Mismo
    # bug que ya mordio en encode.ps1 y en Invoke-FfmpegProgress.
    $line = ($argsArr | ForEach-Object {
        if ("$_" -match '[\s"()]') { '"' + ("$_" -replace '"','\"') + '"' } else { "$_" }
    }) -join ' '
    # CON RED (26/08/2026). Antes esto era un Start-Process pelado: si no se podia
    # lanzar devolvia $null en silencio y la ranura quedaba con Proc=$null, que
    # Step- daba por viva para siempre (ver $MediaBoxPwsh arriba). Ahora se dice y
    # se devuelve $null, que Step- y Wait- ya saben tratar: la pista sale como
    # 'noresult' y el llamante la reconvierte en SECUENCIAL.
    $p = $null
    try {
        $p = Start-Process -FilePath $MediaBoxPwsh -ArgumentList $line -NoNewWindow -PassThru -ErrorAction Stop
    } catch {
        Log "    [par] no se pudo lanzar el worker de la pista $($Slot.Idx): $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $p) {
        Log "    [par] Start-Process no devolvio proceso para la pista $($Slot.Idx)."
        return $null
    }
    $null = $p.Handle   # sin tocar Handle, ExitCode puede venir a $null
    return $p
}

function Start-DdpTracksParallel {
    <#
      Convierte EN PARALELO varias pistas de la MISMA pelicula, una por proceso,
      y DEVUELVE EL CONTROL en cuanto las ha lanzado. El resultado se recoge con
      Wait-DdpTracksParallel.

      Devuelve el objeto de estado, o $null si no se puede paralelizar (no esta
      el worker, o no cabe en disco). En ese caso el llamante hace lo de
      siempre: convertir en SECUENCIAL.

      POR QUE ESTO Y NO PARALELIZAR ENTRE PELICULAS (medido el 06/08/2026):
        K=2 -> 1,62x (81 % de eficiencia)   <- este caso
        K=4 -> 2,65x (66 %)                 <- exigiria relajar el pipeline.lock
      Paralelizar las pistas DE UN MISMO TRABAJO no toca el lock para nada: sigue
      habiendo un solo trabajo a la vez, asi que no se reabre ninguno de los
      fallos de concurrencia que el lock existe para evitar. Casi todo el
      beneficio, practicamente nada del riesgo.

      LOS TEMPORALES VAN AL $BigTmp DE SIEMPRE, no a subcarpetas por pista:
        - No colisionan: la libreria los nombra con sello de tiempo + INDICE DE
          PISTA (thd_<sello>_<idx>), y aqui los indices son distintos por
          definicion. (Entre TRABAJOS si colisionarian, que es justo por lo que
          el pipeline.lock sigue donde esta.)
        - Y sobre todo: el Clean-JobLeftovers de los watchers barre $BigTmp por
          patron y SIN -Recurse. Metiendo los temporales en subcarpetas, un
          trabajo muerto por taskkill dejaria 30-40 GB huerfanos donde nadie los
          busca.

      -ExtraNeededBytes: espacio que el LLAMANTE va a ocupar en el mismo disco
      mientras esto corre. Existe por el solapamiento audio+video: el temporal
      de video (~15 GB en 4K) se escribe en $BigTmp a la vez que DEE trabaja
      alli, y la reserva de DEE se calcula ANTES de que ese fichero exista. Sin
      sumarlo aqui, el video le come el disco al Atmos a media conversion, que
      es exactamente el fallo del 31/07/2026.
    #>
    param(
        [Parameter(Mandatory=$true)][array]$Tracks,       # @{Idx;Bitrate;IsAtmos;Ch;OutFile}
        [Parameter(Mandatory=$true)][string]$InputFile,
        [double]$DurationSec = 0,
        [string]$Tmp    = 'C:\Media\tmp',
        [string]$BigTmp = '',
        [int]$MaxParallel = 2,
        [string]$WorkerPath = '',
        [string]$LibPath = '',
        [long]$ExtraNeededBytes = 0
    )
    if (-not $BigTmp)     { $BigTmp = Get-BigTmp -Fallback $Tmp }
    if (-not $LibPath)    { $LibPath = $PSCommandPath }
    if (-not $WorkerPath) { $WorkerPath = Join-Path (Split-Path $LibPath -Parent) 'atmos-track-worker.ps1' }
    if (-not (Test-Path -LiteralPath $WorkerPath)) {
        Log "    [par] no encuentro $WorkerPath -> no puedo paralelizar."
        return $null
    }

    # ESPACIO COMBINADO. La comprobacion de dentro de Convert-TrueHDToDDP es POR
    # PISTA: dos en paralelo la pasarian las dos viendo sitio de sobra y se
    # quedarian sin disco a mitad, que es exactamente el fallo que costo el Atmos
    # de Interstellar. Aqui se exige la suma antes de lanzar nada.
    $need = 0L
    foreach ($t in $Tracks) {
        $need += Get-DdpSpaceNeeded -DurationSec $DurationSec -Channels $t.Ch `
                     -IsAtmos:([bool]$t.IsAtmos) -Bitrate $t.Bitrate
    }
    if ($ExtraNeededBytes -gt 0) {
        $need += $ExtraNeededBytes
        Log ("    [par] +{0:N1} GB reservados para el temporal de video (solapamiento audio+video)." -f ($ExtraNeededBytes/1GB))
    }
    if (-not (Test-DdpSpace -Path $BigTmp -NeededBytes $need -Label 'par')) {
        Log "    [par] no caben las $($Tracks.Count) pistas a la vez -> lo hara el camino secuencial."
        return $null
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $slots = @()
    foreach ($t in $Tracks) {
        $slots += [pscustomobject]@{
            Idx      = $t.Idx
            Track    = $t
            # Prefijo 'dee_' A PROPOSITO: es uno de los patrones que barren los
            # TRES watchers y stop-mediabox. Con 'd_*' (primera version) solo lo
            # habrian recogido el de audio y stop-mediabox: en la cola de VIDEO
            # estos ficheros habrian quedado ahi para siempre tras un taskkill.
            SlotLog  = Join-Path $BigTmp ("dee_parlog_{0}_{1}.log"  -f $stamp, $t.Idx)
            Result   = Join-Path $BigTmp ("dee_parres_{0}_{1}.json" -f $stamp, $t.Idx)
            Progress = Join-Path $BigTmp ("dee_parprog_{0}_{1}.txt" -f $stamp, $t.Idx)
            Proc     = $null
        }
    }

    $pendientes = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $slots) { $pendientes.Enqueue($s) }

    $state = [pscustomobject]@{
        Slots       = $slots
        Pendientes  = $pendientes
        Vivos       = @()
        Lanzados    = @()
        MaxParallel = $MaxParallel
        WorkerPath  = $WorkerPath
        InputFile   = $InputFile
        DurationSec = $DurationSec
        Tmp         = $Tmp
        BigTmp      = $BigTmp
        LibPath     = $LibPath
        # Joined distingue "termino y ya se recogieron los resultados" de "lo
        # dejamos a medias". Es lo que mira Stop- para no borrar los .ec3 de un
        # trabajo que fue BIEN.
        Joined      = $false
    }

    # Lanzar. Se respeta MaxParallel por si algun dia hay 3+ pistas y no interesa
    # abrirlas todas: por encima de 2 la eficiencia medida baja (81 % -> 66 %).
    $vivos = @(); $lanzados = @()
    while ($pendientes.Count -gt 0 -and $vivos.Count -lt $MaxParallel) {
        $s = $pendientes.Dequeue()
        $s.Proc = Start-DdpSlot -Slot $s -State $state
        $vivos += $s; $lanzados += $s
    }
    $state.Vivos = @($vivos); $state.Lanzados = @($lanzados)
    Log ("    [par] {0} pistas en paralelo (max {1})." -f $lanzados.Count, $MaxParallel)
    return $state
}

function Step-DdpTracksParallel {
    <#
      UNA pasada: releva ranuras libres y, si se le pasa -OnProgress, compone el
      porcentaje conjunto. No duerme y no bloquea: devuelve $true mientras quede
      algun worker vivo.
    #>
    param(
        [Parameter(Mandatory=$true)]$State,
        [scriptblock]$OnProgress = $null
    )
    if (-not $State) { return $false }
    if (@($State.Vivos).Count -eq 0) { return $false }

    $sigue = @()
    foreach ($s in @($State.Vivos)) {
        # Proc a $null = el worker NO llego a arrancar. Antes caia en el 'else' y
        # la ranura se quedaba VIVA para siempre: Wait- giraba sin fin con el
        # pipeline.lock cogido y colgaba los tres pipelines. Tratarla como muerta
        # la saca de Vivos, deja entrar a la siguiente pendiente, y Wait- la
        # devuelve como 'noresult' -> se reconvierte en secuencial.
        if ((-not $s.Proc) -or $s.Proc.HasExited) {
            if ($State.Pendientes.Count -gt 0) {
                $n = $State.Pendientes.Dequeue()
                $n.Proc = Start-DdpSlot -Slot $n -State $State
                $sigue += $n
                $State.Lanzados = @($State.Lanzados) + $n
            }
        } else { $sigue += $s }
    }
    $State.Vivos = @($sigue)

    if ($OnProgress) {
        # Porcentaje conjunto: media de las pistas lanzadas, y como etapa la MENOS
        # avanzada (si una va por 'dee' y otra por 'extract', el trabajo esta en
        # extract; decir 'dee' haria creer que queda menos de lo que queda).
        $orden = @{ 'extract' = 0; 'truehdd' = 1; 'ddp' = 2; 'dee' = 2 }
        $suma = 0.0; $n = 0; $peor = 'extract'; $peorN = 99
        foreach ($s in @($State.Lanzados)) {
            if (-not (Test-Path -LiteralPath $s.Progress)) { $n++; continue }
            try {
                $txt = [System.IO.File]::ReadAllText($s.Progress)
                if ($txt -match 'stage=(\w+)') {
                    $st = $Matches[1]
                    $o = if ($orden.ContainsKey($st)) { $orden[$st] } else { 0 }
                    if ($o -lt $peorN) { $peorN = $o; $peor = $st }
                }
                if ($txt -match 'pct=([\d.,]+)') {
                    $v = ConvertTo-DoubleInv ($Matches[1] -replace ',','.')
                    if ($null -ne $v) { $suma += $v }
                }
            } catch { }
            $n++
        }
        if ($n -gt 0) { & $OnProgress $peor ([math]::Round($suma / $n, 1)) }
    }
    return (@($State.Vivos).Count -gt 0)
}

function Wait-DdpTracksParallel {
    <#
      Espera a que terminen todas las pistas, vuelca sus logs al log del trabajo
      y devuelve un objeto por pista: @{ AudioIndex, Ok, Failure, OutFile,
      OutBytes, Seconds }. Si una pista no deja resultado, se devuelve Ok=$false
      y Failure='noresult' para que el llamante la rehaga en SECUENCIAL.
    #>
    param(
        [Parameter(Mandatory=$true)]$State,
        [scriptblock]$OnProgress = $null
    )
    if (-not $State) { return @() }

    while (@($State.Vivos).Count -gt 0) {
        Start-Sleep -Milliseconds 1000
        $null = Step-DdpTracksParallel -State $State -OnProgress $OnProgress
    }
    foreach ($s in @($State.Lanzados)) { if ($s.Proc) { $s.Proc.WaitForExit() } }

    # Volcar los logs de cada pista al log del trabajo, uno detras de otro. Ahora
    # que han terminado no se entrelazan y el diagnostico sigue siendo posible.
    foreach ($s in @($State.Lanzados)) {
        if (Test-Path -LiteralPath $s.SlotLog) {
            Log "    [par] --- log de la pista $($s.Idx) ---"
            # SE FILTRA EL RUIDO. DEE imprime una linea de "Overall progress" CADA
            # SEGUNDO: un encode de una hora deja 5.000-6.000 lineas por pista, casi
            # todas repitiendo el mismo porcentaje. Volcarlas enteras costaba dos
            # cosas: ~11.000 llamadas a Add-Content de golpe (minutos de reloj con
            # el trabajo ya terminado) y un log del trabajo ilegible.
            # Se conserva TODO lo que sirve para diagnosticar -errores, avisos, el
            # resumen de tiempos de DEE, versiones- y del progreso solo un hito por
            # cada 10 %, que es lo unico que se mira despues.
            $ultimoHito = -1
            foreach ($l in @(Get-Content -LiteralPath $s.SlotLog -ErrorAction SilentlyContinue)) {
                if ($l -match 'Overall progress:\s*([0-9]+(?:\.[0-9]+)?)') {
                    $v = ConvertTo-DoubleInv $Matches[1]
                    if ($null -ne $v) {
                        $hito = [int][math]::Floor($v / 10)
                        if ($hito -le $ultimoHito) { continue }
                        $ultimoHito = $hito
                    }
                }
                # El resto del volcado de INTERNAL_INFO al cargar las DLL tampoco
                # aporta nada: son 60 lineas por pista de librerias de VIDEO que
                # esta ruta ni usa.
                elseif ($l -match 'INTERNAL_INFO:.*(Loading library|is a component of|is a DEE''s component)') { continue }
                Log "  $l"
            }
        }
        Remove-Item -LiteralPath $s.SlotLog  -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $s.Progress -Force -ErrorAction SilentlyContinue
    }

    # Resultados. Sin JSON => 'noresult' => el llamante lo rehace en secuencial.
    $out = @()
    foreach ($s in @($State.Lanzados)) {
        $r = $null
        if (Test-Path -LiteralPath $s.Result) {
            try { $r = Get-Content -LiteralPath $s.Result -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
        }
        Remove-Item -LiteralPath $s.Result -Force -ErrorAction SilentlyContinue
        if ($r) {
            $out += [pscustomobject]@{
                AudioIndex = [int]$r.audioIndex; Ok = [bool]$r.ok; Failure = "$($r.failure)"
                OutFile = "$($r.outFile)"; OutBytes = [long]$r.outBytes; Seconds = [double]$r.seconds
            }
        } else {
            Log "    [par] la pista $($s.Idx) no dejo resultado (worker muerto): se rehara en secuencial."
            $out += [pscustomobject]@{
                AudioIndex = [int]$s.Idx; Ok = $false; Failure = 'noresult'
                OutFile = "$($s.Track.OutFile)"; OutBytes = 0L; Seconds = 0
            }
        }
    }
    # Las pistas que nunca se llegaron a lanzar (no deberia pasar) tambien vuelven
    # marcadas, para que el llamante no se las deje sin convertir en silencio.
    foreach ($s in @($State.Slots)) {
        if (@($State.Lanzados) -notcontains $s) {
            $out += [pscustomobject]@{
                AudioIndex = [int]$s.Idx; Ok = $false; Failure = 'nolanzada'
                OutFile = "$($s.Track.OutFile)"; OutBytes = 0L; Seconds = 0
            }
        }
    }
    $State.Joined = $true
    return $out
}

function Stop-DdpTracksParallel {
    <#
      Mata los workers que sigan vivos y borra lo que dejaron a medias. Devuelve
      cuantos mato.

      POR QUE EXISTE: hasta ahora el audio terminaba SIEMPRE antes de que
      pudiera abortarse el trabajo, asi que no habia nada que matar. Con el
      audio solapado con el video ya no es asi: un timeout de OCR o un ffmpeg
      que no arranca abortan el trabajo con DEE en plena faena. Si nadie los
      para, quedan dee.exe y truehdd.exe huerfanos llenando G: mientras el
      watcher arranca el trabajo siguiente, y eso no lo ve nadie hasta que el
      disco se llena.

      NO hace nada si el estado ya esta UNIDO (Joined): en un trabajo que fue
      bien, los .ec3 son el resultado y no se tocan.

      Lo que NO puede limpiar: los temporales pesados del worker (thd_*,
      damf_*), que los borra su propio finally y ese finally no corre cuando lo
      matas. De eso se encarga el Clean-JobLeftovers del watcher, que barre
      $BigTmp por patron despues de CADA trabajo.
    #>
    param($State)
    if (-not $State) { return 0 }
    if ($State.Joined) { return 0 }

    $n = 0
    foreach ($s in @($State.Lanzados)) {
        if ($s.Proc -and -not $s.Proc.HasExited) {
            # Kill($true) = ARBOL COMPLETO. El worker es un pwsh que casi no
            # consume: quien ocupa la CPU y el disco son sus hijos (ffmpeg,
            # truehdd.exe, dee.exe). Matar solo al padre dejaria vivo justo lo
            # que hay que parar.
            try { $s.Proc.Kill($true); $n++ } catch { }
        }
    }
    foreach ($s in @($State.Lanzados)) {
        if ($s.Proc) { try { $null = $s.Proc.WaitForExit(10000) } catch { } }
    }
    # Los .ec3 a medias no valen y nadie debe tomarlos por buenos. La cache solo
    # guarda conversiones TERMINADAS, asi que aqui no hay nada que invalidar.
    foreach ($s in @($State.Lanzados)) {
        Remove-Item -LiteralPath $s.SlotLog  -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $s.Progress -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $s.Result   -Force -ErrorAction SilentlyContinue
        if ($s.Track -and $s.Track.OutFile) {
            Remove-Item -LiteralPath $s.Track.OutFile -Force -ErrorAction SilentlyContinue
        }
    }
    $State.Vivos = @()
    if ($n -gt 0) { Log ("    [par] {0} worker(s) de audio matados (arbol completo) al abortar el trabajo." -f $n) }
    return $n
}

function Invoke-DdpTracksParallel {
    <#
      ENVOLTORIO de siempre: Start + Wait en una sola llamada, bloqueando hasta
      que termina. Mismo contrato y mismo comportamiento que antes del corte
      Start/Step/Wait, para que audio_encode.ps1 y el camino en serie de
      encode.ps1 sigan funcionando sin cambiar una linea.

      Devuelve @() cuando no se puede paralelizar, que es la senal de siempre
      para que el llamante lo haga en SECUENCIAL.
    #>
    param(
        [Parameter(Mandatory=$true)][array]$Tracks,       # @{Idx;Bitrate;IsAtmos;Ch;OutFile}
        [Parameter(Mandatory=$true)][string]$InputFile,
        [double]$DurationSec = 0,
        [string]$Tmp    = 'C:\Media\tmp',
        [string]$BigTmp = '',
        [int]$MaxParallel = 2,
        [scriptblock]$OnProgress = $null,
        [string]$WorkerPath = '',
        [string]$LibPath = ''
    )
    $st = Start-DdpTracksParallel -Tracks $Tracks -InputFile $InputFile -DurationSec $DurationSec `
              -Tmp $Tmp -BigTmp $BigTmp -MaxParallel $MaxParallel -WorkerPath $WorkerPath -LibPath $LibPath
    if (-not $st) { return @() }
    return (Wait-DdpTracksParallel -State $st -OnProgress $OnProgress)
}

function Invoke-ThdPipe {
    <#
      ffmpeg -> truehdd POR TUBERIA, sin escribir el .thd intermedio.

      QUE AHORRA: hoy la extraccion (leer el MKV entero, 22-52 GB) y la
      decodificacion van en serie. Por tuberia se SOLAPAN, y ademas no se
      escriben ~4 GB de .thd por pista. Medido sobre dracula: extraccion 16,6 min
      + truehdd 25,6 min = 42,2 min en serie, frente a ~25,6 solapados.

      POR QUE ASI Y NO DE OTRA FORMA:
      - '& ffmpeg | & truehdd' NO vale: PowerShell convierte la salida de un
        proceso nativo a TEXTO antes de pasarla, y eso CORROMPE binario.
      - 'cmd /c "... | ..."' funciona, pero mete las reglas de citado de cmd y un
        '&' en el nombre de una pelicula rompe el comando. En este repo ya han
        mordido dos bugs de citado; no se repite el patron.
      - Con ProcessStartInfo.ArgumentList cada argumento viaja como UN elemento y
        nadie reinterpreta comillas, parentesis ni ampersands.

      EL PROGRESO y EL BLOQUEO, que van juntos: si no se vacia el stderr de los
      hijos, se llena el buffer del sistema (~64 KB) y el proceso se queda
      colgado a mitad. El stderr de truehdd se drena en ASINCRONO por eso mismo.
      Como entonces no se puede ir leyendo su barra de progreso, el progreso se
      saca del fichero -progress de FFMPEG (que no pasa por ninguna tuberia) y se
      sondea entre bloque y bloque de la copia. Mide por donde va LEYENDO el
      origen, que con una tuberia es justo el ritmo al que avanza el conjunto.

      Devuelve un objeto con Ok y los codigos de salida. NO valida el DAMF: de eso
      se encarga el llamante, que es quien sabe donde tiene que haber quedado.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Ffmpeg,
        [Parameter(Mandatory=$true)][string]$Truehdd,
        [Parameter(Mandatory=$true)][string]$InputFile,
        [Parameter(Mandatory=$true)][int]$AudioIndex,
        [Parameter(Mandatory=$true)][string]$OutPrefix,
        [string]$ProgFile = '',
        [double]$DurationSec = 0,
        [scriptblock]$OnProgress = $null,
        [string]$LogFile = ''
    )
    $psiF = [System.Diagnostics.ProcessStartInfo]::new()
    $psiF.FileName = $Ffmpeg
    $ffArgs = @('-nostdin','-y','-loglevel','error')
    if ($ProgFile) { $ffArgs += @('-progress', $ProgFile) }
    $ffArgs += @('-i',$InputFile,'-map',"0:a:$AudioIndex",'-c:a','copy','-f','truehd','-')
    foreach ($a in $ffArgs) { $psiF.ArgumentList.Add($a) }
    $psiF.RedirectStandardOutput = $true
    $psiF.RedirectStandardError  = $true
    $psiF.UseShellExecute = $false

    $psiT = [System.Diagnostics.ProcessStartInfo]::new()
    $psiT.FileName = $Truehdd
    foreach ($a in @('decode','--progress','--output-path',$OutPrefix,'-')) { $psiT.ArgumentList.Add($a) }
    $psiT.RedirectStandardInput = $true
    $psiT.RedirectStandardError = $true
    $psiT.UseShellExecute = $false

    if ($ProgFile) { Remove-Item -LiteralPath $ProgFile -ErrorAction SilentlyContinue }

    $pf = $null; $pt = $null
    $errF = $null; $errT = $null
    $copiaOk = $true; $copiaErr = ''
    try {
        $pf = [System.Diagnostics.Process]::Start($psiF)
        $pt = [System.Diagnostics.Process]::Start($psiT)
        $errF = $pf.StandardError.ReadToEndAsync()
        $errT = $pt.StandardError.ReadToEndAsync()
        Set-ChildPriority -Name 'truehdd' | Out-Null
        Set-ChildPriority -Name 'ffmpeg'  | Out-Null

        $buf = New-Object byte[] (4 * 1024 * 1024)
        $inS  = $pf.StandardOutput.BaseStream
        $outS = $pt.StandardInput.BaseStream
        $ultimo = -1.0
        $bloques = 0
        if ($OnProgress) { & $OnProgress 'truehdd' 0 }
        while (($n = $inS.Read($buf, 0, $buf.Length)) -gt 0) {
            $outS.Write($buf, 0, $n)
            $bloques++
            # Sondeo del progreso cada ~16 bloques (64 MB): barato y de sobra para
            # una barra que solo se mira de vez en cuando.
            if ($OnProgress -and $ProgFile -and $DurationSec -gt 0 -and ($bloques % 16) -eq 0) {
                try {
                    $tail = Get-Content -LiteralPath $ProgFile -Tail 16 -ErrorAction SilentlyContinue
                    $m = $tail | Select-String -Pattern '^out_time=(\d+):(\d+):([\d.]+)' | Select-Object -Last 1
                    if ($m) {
                        $g = $m.Matches[0].Groups
                        $sec = ([double]$g[1].Value * 3600) + ([double]$g[2].Value * 60) + [double]$g[3].Value
                        $pct = [math]::Min(100.0, ($sec / $DurationSec) * 100.0)
                        if (($pct - $ultimo) -ge 1.0) { $ultimo = $pct; & $OnProgress 'truehdd' $pct }
                    }
                } catch { }
            }
        }
        $outS.Flush()
    } catch {
        $copiaOk = $false
        $copiaErr = $_.Exception.Message
    } finally {
        # Cerrar la entrada de truehdd es lo que le dice "se acabo el stream".
        # Sin esto se queda esperando para siempre.
        if ($pt) { try { $pt.StandardInput.Close() } catch { } }
    }

    $exF = -1; $exT = -1
    if ($pf) { $pf.WaitForExit(); $exF = $pf.ExitCode }
    if ($pt) { $pt.WaitForExit(); $exT = $pt.ExitCode }
    $sF = ''; $sT = ''
    try { if ($errF) { $sF = $errF.Result } } catch { }
    try { if ($errT) { $sT = $errT.Result } } catch { }
    if ($LogFile) {
        Add-Content -LiteralPath $LogFile -Value "--- ffmpeg (pipe) ---`n$sF`n--- truehdd (pipe) ---`n$sT" -ErrorAction SilentlyContinue
    }
    if ($ProgFile) { Remove-Item -LiteralPath $ProgFile -ErrorAction SilentlyContinue }

    return [pscustomobject]@{
        Ok         = ($copiaOk -and $exF -eq 0 -and $exT -eq 0)
        FfmpegExit = $exF
        TruehddExit= $exT
        CopyError  = $copiaErr
        FfmpegErr  = $sF
        TruehddErr = $sT
        DiskFull   = [bool](("$sF$sT") -match '(?i)no space left|disk (is )?full|espacio en disco')
    }
}


function Convert-TrueHDToDDP {
    # TrueHD -> DDP (E-AC-3) via DEE. Devuelve $true y deja el .ec3 en $OutFile.
    param(
        [Parameter(Mandatory=$true)][string]$InputFile,
        [Parameter(Mandatory=$true)][int]$AudioIndex,     # indice de audio (a:N)
        [int]$Bitrate = 768,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [switch]$IsAtmos,
        # dialnorm a forzar (dBFS, [-31..-1]). 0 = auto: en la ruta Atmos se lee del
        # master con Get-TrueHDDialnorm; en la ruta deew se deja el de DEE (measure).
        [int]$Dialnorm = 0,
        [string]$Tmp        = 'C:\Media\tmp',
        # Donde van los temporales PESADOS (.thd, DAMF, temp de DEE, .ec3 de DEE).
        # Vacio = se resuelve con Get-BigTmp (G:\MediaTmp, con caida a $Tmp).
        # Ver el comentario largo de Get-BigTmp: esto es lo que impide que un
        # DAMF de 30 GB compita por C: con el pagefile y con la cola.
        [string]$BigTmp     = '',
        # Canales de la pista. Solo se usa para estimar el espacio del RF64 que
        # genera deew en la ruta SIN Atmos; la ruta Atmos no lo mira.
        [int]$Channels      = 8,
        [string]$Dee        = 'C:\scripts\DEE\dee.exe',
        [string]$Truehdd    = 'C:\scripts\bin\truehdd.exe',
        # Ruta absoluta como el resto: antes se llamaba a '& ffmpeg' desde el
        # PATH, unico sitio de esta funcion que dependia de el.
        [string]$Ffmpeg     = 'C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe',
        [string]$Mkvmerge   = 'C:\Program Files\MKVToolNix\mkvmerge.exe',
        [string]$Mkvextract = 'C:\Program Files\MKVToolNix\mkvextract.exe',
        # Binario standalone, NO el de pip. El pip se queda en la 2.9.5 porque
        # deew 3.x declara Requires: Python <3.14 y aqui hay un Python 3.14: pip
        # no puede instalar la version nueva aunque exista. El standalone no
        # necesita Python.
        # Ruta absoluta como todo lo demas ($Truehdd, $Dee, $Mkvextract...): hoy
        # se ha visto lo que pasa fiandose del PATH (dotnet desaparecio y el OCR
        # llevaba semanas roto sin que nadie lo supiera).
        [string]$Deew       = 'C:\scripts\bin\deew.exe',
        # Duracion del titulo en segundos. Solo se usa para convertir la posicion
        # que reporta ffmpeg en un porcentaje durante extract. Si no se pasa (0),
        # esa fase reporta solo el 0 inicial, como antes.
        [double]$DurationSec = 0,
        # Callback opcional para reportar progreso al panel: se invoca como
        #   & $OnProgress <stage> <pct>
        # p.ej. 'extract' 0 / 'truehdd' 0 / 'dee' 34.5. El llamante decide que
        # hacer con ello (encode.ps1 lo escribe en encode_status).
        [scriptblock]$OnProgress = $null
    )
    $global:DdpLastFailure = ''
    if (-not $BigTmp) { $BigTmp = Get-BigTmp -Fallback $Tmp }
    New-Item -ItemType Directory -Force -Path $BigTmp -ErrorAction SilentlyContinue | Out-Null

    # CHEQUEO DE ESPACIO, antes de tocar nada. Hasta hoy esta ruta entraba a
    # ciegas: audio_encode.ps1 exigia 25 GB fijos (que ni siquiera cubren el DAMF
    # de una peli de 3 horas) y encode.ps1 no comprobaba NADA. Si no cabe, se sale
    # marcando 'diskfull' para que el llamante aborte y reencole en vez de
    # degradar a EAC3: degradar pierde el Atmos para siempre por un fallo que era
    # transitorio.
    $need = Get-DdpSpaceNeeded -DurationSec $DurationSec -Channels $Channels -IsAtmos:$IsAtmos -Bitrate $Bitrate
    if (-not (Test-DdpSpace -Path $BigTmp -NeededBytes $need -Label 'ddp')) {
        $global:DdpLastFailure = 'diskfull'
        return $false
    }

    $tag = "{0}_{1}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $AudioIndex
    $thd = Join-Path $BigTmp "thd_${tag}.thd"
    $ok  = $false
    # Todo lo que hay que borrar pase lo que pase. Se rellena segun se van
    # creando los ficheros y lo barre el finally: antes la limpieza estaba en el
    # camino feliz, asi que un return temprano o una excepcion dejaba 30 GB de
    # DAMF huerfanos hasta el siguiente stop-mediabox.
    # OJO: $OutFile NUNCA entra aqui; es lo que espera quien llama.
    # Ficheros y carpetas van separados: borrar una carpeta necesita -Recurse.
    $limpiar     = @($thd)
    $limpiarDirs = @()
    # Respiro entre pistas: cuando una peli tiene DOS pistas Atmos, la 2a arranca
    # justo despues de que truehdd+DEE de la 1a hayan cargado y soltado ~gigas de
    # RAM y handles de fichero. Darle a Windows medio segundo + forzar el GC de
    # .NET deja que se libere todo eso antes de que truehdd vuelva a cargar el
    # stream para contar frames. Barato (unos segundos en un proceso de ~15 min) y
    # descarta la memoria como causa del fallo de la 2a pista sin arriesgar nada.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 2

    # --- P-CORES: que truehdd y dee NO acaben en los nucleos de eficiencia -----
    # La afinidad y la prioridad se HEREDAN: basta con ponerlas en ESTE proceso
    # antes de lanzar los hijos. Se restauran en el finally, imprescindible porque
    # en encode.ps1 esta misma sesion sigue luego con el encode de VIDEO, que si
    # aprovecha TODOS los nucleos (incluidos los E) y no debe quedarse capado.
    # Ver Get-PerformanceCoreMask para el porque y las mediciones (3,46x).
    $pcoreMask = Get-PerformanceCoreMask
    $affPrev   = $null
    $prioPrev  = $null
    if ($pcoreMask -ne 0) {
        try {
            $me       = Get-Process -Id $PID
            $affPrev  = $me.ProcessorAffinity
            $prioPrev = $me.PriorityClass
            $me.ProcessorAffinity = [IntPtr]$pcoreMask
            # AboveNormal ademas de la afinidad: la afinidad decide DONDE corre, y
            # la prioridad saca al proceso de la clase "background" a la que
            # Windows le baja tambien la frecuencia.
            $me.PriorityClass = 'AboveNormal'
            Log ("    [ddp] fijado a P-cores (mascara 0x{0:X}) y prioridad AboveNormal." -f $pcoreMask)
        } catch {
            Log "    [ddp] AVISO: no pude fijar P-cores ($($_.Exception.Message)). Sigo igual."
            $affPrev = $null; $prioPrev = $null
        }
    }
    try {
        if ($IsAtmos) {
            # --- CON Atmos: truehdd -> DAMF -> dee.exe (conserva objetos) ---
            $pfx     = Join-Path $BigTmp "damf_${tag}"
            $damf    = "$pfx.atmos"
            $ec3name = "ddp_${tag}.ec3"
            $ec3     = Join-Path $BigTmp $ec3name
            # Se inicializa aqui (no solo donde se calcula tras DEE) para que la
            # limpieza de mas abajo lo lea definido aunque DEE falle antes.
            $samePath = $false
            $xml     = Join-Path $BigTmp "job_${tag}.xml"
            $deeTemp = Join-Path $BigTmp "deetemp_${tag}"
            $deeLog  = Join-Path $BigTmp "dee_${tag}.log"
            # Se apuntan YA, antes de existir: si truehdd o DEE mueren a mitad, el
            # finally tiene que poder barrer lo que hayan dejado escrito.
            # $deeTemp va en $limpiarDirs, NO aqui: Remove-Item sobre una carpeta
            # NO vacia sin -Recurse PREGUNTA, y este proceso corre oculto (lo lanza
            # el VBS), asi que se quedaria colgado esperando una respuesta que nadie
            # puede darle.
            $limpiar    += @("$pfx.atmos","$pfx.atmos.audio","$pfx.atmos.metadata",$pfx,$xml,$deeLog)
            $limpiarDirs += @($deeTemp)

            # ---------------------------------------------------------------
            # 1-bis) CAMINO RAPIDO: ffmpeg -> truehdd por TUBERIA.
            # Ahorra ~16 min por pelicula (la extraccion se solapa con la
            # decodificacion) y ~4 GB de escritura por pista. Si falla por lo que
            # sea se cae al camino de siempre (extraer .thd, con su respaldo de
            # mkvextract), que se conserva intacto justo debajo.
            #
            # EL DIALNORM SE LEE ANTES, de un prefijo de 10 s: Get-TrueHDDialnorm
            # necesita un fichero, y por tuberia no hay .thd que leer. Verificado
            # el 06/08/2026 que el valor es una propiedad del STREAM y no de la
            # posicion: leido desde 0 s, 1800 s, 5000 s y 9000 s del mismo fichero
            # da lo mismo, y coincide con el que uso el trabajo real. Sin esto se
            # perderia el dialnorm del master y la pista sonaria a otro volumen
            # que el TrueHD de origen, en silencio.
            $usarPipe = $true
            $damfOk = $false
            if ($usarPipe) {
                $pre = Join-Path $BigTmp "thd_${tag}_pre.thd"
                $limpiar += @($pre)
                & $Ffmpeg -y -loglevel error -t 10 -i $InputFile -map "0:a:$AudioIndex" `
                          -c:a copy -f truehd $pre 2>&1 | Out-Null
                $dnPipe = 0
                if (Test-Path -LiteralPath $pre) { $dnPipe = Get-TrueHDDialnorm -Thd $pre -Truehdd $Truehdd }
                Remove-Item -LiteralPath $pre -Force -ErrorAction SilentlyContinue

                Log "    [ddp] extraccion+decodificacion por TUBERIA (sin .thd intermedio)..."
                $pipeLog = Join-Path $BigTmp "thd_${tag}_pipe.log"
                $limpiar += @($pipeLog)
                $rp = Invoke-ThdPipe -Ffmpeg $Ffmpeg -Truehdd $Truehdd -InputFile $InputFile `
                          -AudioIndex $AudioIndex -OutPrefix $pfx `
                          -ProgFile (Join-Path $Tmp "ffprog_${tag}.txt") `
                          -DurationSec $DurationSec -OnProgress $OnProgress -LogFile $pipeLog
                $damfOk = $rp.Ok -and (Test-Path -LiteralPath $damf)
                if ($damfOk) {
                    $dnEff = if ($Dialnorm -ne 0) { $Dialnorm } else { $dnPipe }
                    if ($dnEff -ne 0) { Log "    [ddp] custom_dialnorm=$dnEff dB (Dialogue Level del master)" }
                    else              { Log "    [ddp] custom_dialnorm: no legible -> DEE medira (measure_only)" }
                } else {
                    # Disco lleno NO se reintenta por el camino largo: volveria a
                    # llenarlo. Se marca y se sale para que el llamante reencole.
                    if ($rp.DiskFull) {
                        Log "    [ddp] la tuberia fallo por falta de espacio."
                        Set-DdpFailure -Path $BigTmp -Force
                        return $false
                    }
                    Log ("    [ddp] la tuberia no genero DAMF (ffmpeg={0}, truehdd={1}). Reintento por el camino largo." -f $rp.FfmpegExit, $rp.TruehddExit)
                    if ($rp.CopyError) { Log "    [ddp]   copia: $($rp.CopyError)" }
                    foreach ($l in @(("$($rp.TruehddErr)" -split "`n") | Select-Object -Last 5)) {
                        if ("$l".Trim()) { Log "    [ddp]   [truehdd] $l" }
                    }
                    # Restos de un DAMF a medias: si no se borran, el camino largo
                    # podria dar por bueno un fichero truncado.
                    foreach ($x in @("$pfx.atmos","$pfx.atmos.audio","$pfx.atmos.metadata")) {
                        Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            if (-not $damfOk) {
            # 1) Extraer el .thd. FFMPEG PRIMERO (antes iba mkvextract): esta fase
            # lee el fichero ENTERO -20-40 GB- y es donde la barra se quedaba
            # muerta mas rato, porque mkvextract no emite progreso parseable.
            # ffmpeg con -progress si lo da. mkvextract queda de reserva por si
            # ffmpeg no consigue sacar la pista.
            Remove-Item -LiteralPath $thd -ErrorAction SilentlyContinue
            $prog = Join-Path $Tmp "ffprog_${tag}.txt"
            $null = Invoke-FfmpegProgress -Ffmpeg $Ffmpeg -ProgFile $prog `
                        -DurationSec $DurationSec -OnProgress $OnProgress -Stage 'extract' `
                        -FfArgs @('-y','-i',$InputFile,'-map',"0:a:$AudioIndex",'-c:a','copy','-f','truehd',$thd)
            $extracted = (Test-Path -LiteralPath $thd) -and ((Get-Item -LiteralPath $thd).Length -gt 1024)
            if ((-not $extracted) -and (Test-EsMatroska $InputFile) -and (Test-Path -LiteralPath $Mkvmerge) -and (Test-Path -LiteralPath $Mkvextract)) {
                Log "    [ddp] ffmpeg no extrajo la pista; reintento con mkvextract (esta fase va sin progreso)."
                try {
                    $j = (& $Mkvmerge -J $InputFile 2>$null) | Out-String | ConvertFrom-Json
                    $audio = @($j.tracks | Where-Object { $_.type -eq 'audio' })
                    if ($AudioIndex -lt $audio.Count) {
                        & $Mkvextract tracks $InputFile "$($audio[$AudioIndex].id):$thd" 2>&1 | Out-Null
                        $extracted = (Test-Path -LiteralPath $thd) -and ((Get-Item -LiteralPath $thd).Length -gt 1024)
                    }
                } catch {}
            }
            if (-not $extracted) {
                Log "    [ddp] ERROR: no se pudo extraer TrueHD (a:$AudioIndex)."
                Set-DdpFailure -Path $BigTmp
                return $false
            }

            # dialnorm del master para custom_dialnorm. Auto (0) => se lee del propio
            # .thd con 'truehdd info'; si el llamante fuerza uno, se respeta. Si tras
            # leer sigue en 0 => no se toca (DEE medira, measure_only), identico a antes.
            $dnEff = if ($Dialnorm -ne 0) { $Dialnorm } else { Get-TrueHDDialnorm -Thd $thd -Truehdd $Truehdd }
            if ($dnEff -ne 0) { Log "    [ddp] custom_dialnorm=$dnEff dB (Dialogue Level del master)" }
            else              { Log "    [ddp] custom_dialnorm: no legible -> DEE medira (measure_only)" }

            # 2) truehdd -> DAMF
            # --progress es imprescindible: con --loglevel off truehdd no imprime
            # NADA y el panel se queda congelado ~9 min (el DAMF son ~12 GB),
            # pareciendo colgado. Las dos opciones conviven (asi lo hace el
            # main.py de Atmos-Encoder). El parseo del % es a ojo; si no casa, la
            # salida cruda va al log igual y ahi se ve que avanza.
            if ($OnProgress) { & $OnProgress 'truehdd' 0 }
            $lastThd = -1.0
            # ANTES: --loglevel off. Eso silenciaba TODO menos la barra de
            # progreso, incluidos los errores: cuando truehdd fallaba (p.ej. la 2a
            # pista Atmos de una peli con doble Atmos), el pipeline solo veia "no
            # genero DAMF" sin el motivo. Ahora corre en el nivel por defecto
            # (info) y TODA su salida -progreso Y errores- se guarda en
            # $thdLog; al log del trabajo solo van las lineas de % (para no
            # inundarlo con los cientos de INFO de drc_start_up_gain). Si el DAMF
            # no aparece, se vuelcan las ultimas lineas de $thdLog, que ES donde
            # esta el error de verdad.
            $thdLog = Join-Path $BigTmp "thd_${tag}.log"
            $limpiar += @($thdLog)
            Remove-Item -LiteralPath $thdLog -ErrorAction SilentlyContinue
            # Se marca si truehdd se queja de espacio: es la senyal fiable para
            # distinguir "el stream esta corrupto" de "el disco se lleno", y de esa
            # distincion depende que el trabajo se reencole en vez de degradarse.
            $thdDiskFull = $false
            $thdPrio = $false
            & $Truehdd decode --progress --output-path $pfx $thd 2>&1 | ForEach-Object {
                # La PRIMERA linea de salida es la senyal de que el hijo ya existe:
                # es el momento de subirle la prioridad. La afinidad si la heredo,
                # pero la prioridad NO (ver Set-ChildPriority), y es la que manda.
                # | Out-Null OBLIGATORIO: desde que Set-ChildPriority devuelve si
                # subio algo, su valor se colaria en la salida de esta funcion y
                # Convert-TrueHDToDDP devolveria un ARRAY en vez de un booleano.
                # Y en PowerShell 'if (@($false,$true))' es VERDADERO, asi que una
                # conversion fallida podia reportarse como buena. Lo cazo la prueba
                # del pipe, que imprimio "ok=True True" (06/08/2026).
                if (-not $thdPrio) { $thdPrio = $true; Set-ChildPriority -Name 'truehdd' | Out-Null }
                $l = "$_"
                Add-Content -LiteralPath $thdLog -Value $l -ErrorAction SilentlyContinue
                if ($l -match '(?i)no space left|disk (is )?full|espacio en disco') { $thdDiskFull = $true }
                if ($l -match '([0-9]+(?:\.[0-9]+)?)\s*%') {
                    # Invariante: en es-ES el TryParse normal convertia "34.5" en 345
                    # y el panel mostraba porcentajes de tres cifras.
                    $tv = ConvertTo-DoubleInv $Matches[1]
                    if ($null -ne $tv) {
                        if ([math]::Abs($tv - $lastThd) -ge 1.0) {
                            $lastThd = $tv
                            if ($OnProgress) { & $OnProgress 'truehdd' $tv }
                            Log "      [truehdd] $l"
                        }
                        return
                    }
                }
            }
            if (-not (Test-Path -LiteralPath $damf)) {
                Log "    [ddp] ERROR: truehdd no genero DAMF (a:$AudioIndex)."
                # Volcar el final del log de truehdd: AHI esta el motivo real
                # (OOM, stream corrupto, permisos...). Sin esto seguiriamos ciegos.
                if (Test-Path -LiteralPath $thdLog) {
                    Log "    [ddp] ultimas lineas de truehdd:"
                    Get-Content -LiteralPath $thdLog -Tail 15 -ErrorAction SilentlyContinue |
                        ForEach-Object { Log "      [truehdd] $_" }
                }
                Set-DdpFailure -Path $BigTmp -Force:$thdDiskFull
                Remove-Item -LiteralPath $thdLog -ErrorAction SilentlyContinue
                return $false
            }
            Remove-Item -LiteralPath $thdLog -ErrorAction SilentlyContinue
            }   # <- fin del camino largo (solo se recorre si la tuberia no dio DAMF)


            # 3) XML sin BOM + dee.exe
            # ffprobe al lado del ffmpeg absoluto que ya nos pasan por parametro:
            # era la ULTIMA llamada por PATH que quedaba en esta libreria.
            $FfprobeExe = Join-Path (Split-Path $Ffmpeg -Parent) 'ffprobe.exe'
            if (-not (Test-Path -LiteralPath $FfprobeExe)) { $FfprobeExe = 'ffprobe' }
            $rfps = (& $FfprobeExe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 $InputFile 2>$null)
            $fps  = Get-DeeFps ("$rfps".Trim())
            New-Item -ItemType Directory -Force -Path $deeTemp | Out-Null
            [System.IO.File]::WriteAllText($xml,
                (New-DeeAtmosXml ([System.IO.Path]::GetFileName($damf)) $BigTmp $ec3name $BigTmp $deeTemp $Bitrate $fps $dnEff),
                (New-Object System.Text.UTF8Encoding($false)))
            # DEE imprime "Overall progress: 34.5" (y un "0.0." con punto final al
            # arrancar), de ahi el regex estricto + TryParse.
            if ($OnProgress) { & $OnProgress 'dee' 0 }
            # "FileWriter: write error" es LITERALMENTE lo que imprimio DEE el
            # 31/07/2026 cuando C: se lleno a mitad del encoder pass. Es un fallo de
            # ESCRITURA, no del encoder: reconocerlo aqui es lo que permite reencolar
            # el trabajo en vez de tirar el Atmos por la borda.
            $deeDiskFull = $false
            $deePrio = $false
            & $Dee --progress --stdout --log-file $deeLog -x $xml 2>&1 | ForEach-Object {
                # Prioridad al hijo en cuanto asoma. AQUI esta la ganancia grande:
                # dee a prioridad Normal iba a 1,16 %/min y a AboveNormal a 3,20.
                # | Out-Null por lo mismo que en truehdd: sin el, el booleano se
                # cuela en el valor de retorno de la funcion.
                if (-not $deePrio) { $deePrio = $true; Set-ChildPriority -Name 'dee' | Out-Null }
                if ($OnProgress -and ($_ -match 'Overall progress:\s*([0-9]+(?:\.[0-9]+)?)')) {
                    # Invariante: DEE imprime "Overall progress: 34.5" y en es-ES el
                    # TryParse normal lo leia como 345.
                    $pv = ConvertTo-DoubleInv $Matches[1]
                    if ($null -ne $pv) { & $OnProgress 'dee' $pv }
                }
                if ($_ -match '(?i)FileWriter: write error|no space left|disk (is )?full') { $deeDiskFull = $true }
                Log "      [dee] $_"
            }

            # INTEGRIDAD: que el .ec3 dure lo que tiene que durar.
            #
            # Es el punto de control que sustituye al que daba el .thd. Con el
            # camino de fichero, si la extraccion se cortaba lo veias enseguida
            # (el .thd no estaba, o pesaba nada). Por TUBERIA no: si ffmpeg muere a
            # mitad, truehdd recibe EOF, cierra un DAMF corto pero VALIDO, y DEE
            # codifica tan tranquilo una pista truncada. El fichero existe, pesa lo
            # suyo y parece bueno: lo unico que lo delata es la duracion.
            #
            # LA REFERENCIA ES LA DURACION DE LA PROPIA PISTA, no la del contenedor.
            # Antes se comparaba contra $DurationSec (el contenedor), con 30 s de
            # tolerancia para absorber que el video suele durar algo mas que el
            # audio. Pero eso se rompe cuando el fichero tiene pistas de DISTINTA
            # longitud: WALL-E (11/08/2026) tenia la TrueHD inglesa a 5892 s -igual
            # que el video- y un DTS español a 5922 s; el contenedor marcaba 5922,
            # el .ec3 salia correcto a 5893 y el control lo daba por TRUNCADO por
            # 30 s de "desvio" que no eran suyos. Se perdio el Atmos de una pista
            # que estaba perfecta. Comparando contra la duracion de LA PISTA el
            # desvio legitimo es de decimas, asi que basta una tolerancia de 10 s
            # (un truncado real por tuberia rota se va de minutos). Si no se puede
            # leer la duracion de la pista se cae al contenedor con los 30 s de
            # antes.
            #
            # Y si falla NO se degrada a EAC3: se marca como fallo de disco para que
            # el llamante REENCOLE. Un .ec3 corto es un accidente, no una razon para
            # perder el Atmos.
            $durOk = $true
            if ((Test-Path -LiteralPath $ec3) -and $DurationSec -gt 0) {
                $FfprobeChk = Join-Path (Split-Path $Ffmpeg -Parent) 'ffprobe.exe'
                if (-not (Test-Path -LiteralPath $FfprobeChk)) { $FfprobeChk = 'ffprobe' }
                $dEc3 = Get-Ec3DurationSec -Path $ec3 -Ffprobe $FfprobeChk
                $refDur = Get-AudioTrackDurationSec -InputFile $InputFile -AudioIndex $AudioIndex -Ffprobe $FfprobeChk -ContainerHintSec $DurationSec
                if ($refDur -gt 0) { $tol = 10; $refTxt = 'la pista' } else { $refDur = $DurationSec; $tol = 30; $refTxt = 'el contenedor' }
                if ($dEc3 -gt 0 -and [math]::Abs($dEc3 - $refDur) -gt $tol) {
                    Log ("    [ddp] ERROR de INTEGRIDAD: el .ec3 dura {0:N0}s y {1} {2:N0}s ({3:N0}s de desvio, tol {4}s). Pista TRUNCADA." -f $dEc3, $refTxt, $refDur, [math]::Abs($dEc3 - $refDur), $tol)
                    Log  "    [ddp] no se degrada a EAC3: se trata como fallo transitorio para que el trabajo se reintente."
                    $durOk = $false
                    $global:DdpLastFailure = 'diskfull'
                }
            }

            if ($durOk -and (Test-Path -LiteralPath $ec3) -and ((Get-Item -LiteralPath $ec3).Length -gt 1024)) {
                # Si $ec3 (el que genera DEE, nombrado con el $tag interno) y
                # $OutFile (el que espera quien llama) resuelven al MISMO fichero,
                # NO se copia: Copy-Item de un fichero sobre si mismo LANZA
                # excepcion, $ok se queda sin asignar (= $false) y el pipeline
                # reporta "FALLO dee.exe" pese a que el .ec3 esta perfecto ahi
                # mismo. Pasaba de forma intermitente cuando el $stamp de
                # encode.ps1 y el $tag de esta funcion caian en el MISMO segundo
                # (los dos usan Get-Date 'yyyyMMdd_HHmmss' + indice de pista): con
                # dos pistas Atmos, si una convertia en ese segundo, se degradaba
                # a eac3 y perdia el Atmos. GetFullPath normaliza para comparar
                # sin que mayusculas o separadores despisten.
                $samePath = [System.IO.Path]::GetFullPath($ec3) -ieq [System.IO.Path]::GetFullPath($OutFile)
                if ($samePath) {
                    $ok = $true
                } else {
                    Copy-Item -LiteralPath $ec3 -Destination $OutFile -Force -ErrorAction SilentlyContinue
                    $ok = (Test-Path -LiteralPath $OutFile)
                }
            } else {
                Log "    [ddp] ERROR: dee no genero .ec3."
                Set-DdpFailure -Path $BigTmp -Force:$deeDiskFull
            }

            # $ec3 solo se borra si NO es el propio $OutFile (ver el $samePath de
            # arriba); si coinciden, borrarlo se llevaria por delante justo el
            # fichero que espera quien llama, y volveria el falso "FALLO dee.exe".
            if (-not $samePath) { $limpiar += $ec3 }
            # El barrido real lo hace el finally, que corre TAMBIEN si esto revienta
            # o si se sale por un return de arriba. Antes la limpieza vivia solo
            # aqui, en el camino feliz: cualquier salida temprana dejaba el DAMF
            # (30 GB) huerfano hasta el siguiente stop-mediabox.
        }
        else {
            # --- SIN Atmos: deew -f ddp (DEE via ffmpeg) ---
            $mka = Join-Path $BigTmp "src_${tag}.mka"
            $out = Join-Path $BigTmp "deew_${tag}"
            $limpiar     += @($mka)
            $limpiarDirs += @($out)
            Remove-Item -LiteralPath $mka -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
            if ($OnProgress) { & $OnProgress 'extract' 0 }
            $prog = Join-Path $Tmp "ffprog_${tag}.txt"
            $null = Invoke-FfmpegProgress -Ffmpeg $Ffmpeg -ProgFile $prog `
                        -DurationSec $DurationSec -OnProgress $OnProgress -Stage 'extract' `
                        -FfArgs @('-y','-i',$InputFile,'-map',"0:a:$AudioIndex",'-c:a','copy',$mka)
            if ((Test-Path -LiteralPath $mka) -and ((Get-Item -LiteralPath $mka).Length -gt 1024)) {
                New-Item -ItemType Directory -Force -Path $out | Out-Null
                # deew imprime un logo ASCII con caracteres Unicode al arrancar
                # (via rich). Con la salida REDIRIGIDA -como aqui, que la
                # canalizamos al Log- Python usa cp1252, no puede codificarlos y
                # revienta con UnicodeEncodeError ANTES de tocar el fichero:
                #   main() -> print(logos[...]) -> rich -> cp1252.encode -> boom
                # Con PYTHONIOENCODING=utf-8 el logo ya no lo mata.
                # Alternativa equivalente: poner logo = 0 en el config.toml de
                # deew. Se hace aqui para no depender de una config externa.
                # OJO: esto afectaba a CUALQUIER llamada a deew desde el script,
                # no solo al DTS: la ruta 'TrueHD sin Atmos -> deew' nunca habia
                # llegado a funcionar, simplemente no se habia ejercitado.
                #
                # TEMP/TMP: deew convierte la entrada a RF64 (pcm_s32le) antes de
                # pasarsela a DEE. Para 5.1/48k/32bit son ~1,15 MB por segundo:
                # ~10 GB en una peli de 2h30. Con el temp_path de su config vacio
                # deew cae al temp del sistema (C:\Users\...\AppData\Local\Temp),
                # que queda FUERA de C:\Media\tmp: ni lo ve el chequeo de espacio
                # ni lo barre stop-mediabox.ps1, asi que si se corta un encode a
                # medias esos GB quedan huerfanos donde nadie los busca.
                # Python resuelve el temp del sistema leyendo TEMP/TMP, asi que
                # basta con apuntarlas a $BigTmp mientras dura la llamada. Desde
                # el 31/07/2026 apuntan a $BigTmp (otra unidad) y no a $Tmp: ese
                # RF64 son 10-20 GB que no tienen por que competir por C:.
                # Se ve en el log: la tabla de deew imprime "Temp path".
                # (Si algun dia su config trae un temp_path explicito, esto no
                # bastara y habra que editar ese config.toml.)
                # -np (--no-prompt): imprescindible aqui. El watcher corre OCULTO
                # (lo lanza el VBS), asi que si deew preguntase algo se quedaria
                # esperando una respuesta que nadie puede darle, colgado para
                # siempre y sin ventana donde verlo.
                # El chequeo va ANTES de tocar las variables de entorno: si
                # saliera con return despues, el finally que las restaura no se
                # ejecutaria y quedarian pisadas para el resto del proceso.
                if (-not (Test-Path -LiteralPath $Deew)) {
                    Log "    [ddp] ERROR: no encuentro deew en $Deew."
                    $global:DdpLastFailure = 'other'
                    return $false
                }
                $prevEnc   = $env:PYTHONIOENCODING
                $prevTemp  = $env:TEMP
                $prevTmp   = $env:TMP
                $prevForce = $env:FORCE_COLOR
                $env:PYTHONIOENCODING = 'utf-8'
                # OJO: estas dos NO mueven el temp de deew. Lo manda el temp_path de
                # su config.toml, que es explicito. Comprobado el 18/08/2026 con
                # 'deew.exe -c': el config que GANA es el de %LOCALAPPDATA%\deew\,
                # no el de C:\scripts\bin (ahi quedaba la duda apuntada). Se dejan
                # porque valen para el ffmpeg que deew lanza por debajo y por si
                # algun dia ese temp_path se vacia.
                $env:TEMP = $BigTmp
                $env:TMP  = $BigTmp
                # SIN ESTO LA BARRA DEL PANEL NO SE MUEVE. deew pinta el progreso con
                # rich, que al detectar la salida redirigida desactiva el refresco en
                # vivo: no imprime NADA mientras trabaja y al terminar suelta una
                # sola linea al 100 %. MEDIDO el 18/08/2026 con un WAV 5.1 de 6 min:
                # 34 s de silencio y 1 linea; con FORCE_COLOR=1, 320 lineas en 36 s.
                # Era el motivo de que el panel se quedase clavado los 9 min de un
                # DTS->DDP (trabajo de Human nature, 18:03). La rama Atmos NO tenia
                # el problema: ahi se habla con dee.exe directo y si imprime en vivo.
                # VERIFICADO que no revive el crash de Unicode que documenta
                # config.toml (rich en modo terminal podria sacar caracteres de
                # dibujo que cp1252 no sabe codificar): exit 0, tabla en ASCII, CERO
                # caracteres no-ASCII en 353 lineas y .ec3 correcto al byte
                # (28.800.000 B = 640 kbps x 360 s).
                $env:FORCE_COLOR = '1'
                # AVISO si el temp real de deew no coincide con el temporal pesado de
                # este trabajo. Desde aqui no se puede corregir -manda su config-,
                # pero mas vale verlo en el log que descubrirlo por un disco lleno:
                # con G: caido, Get-BigTmp cae a C: y entonces el chequeo de espacio
                # de mas arriba vigila una unidad y deew escribe en otra.
                $deewTmpCfg = ''
                foreach ($cfg in @((Join-Path $env:LOCALAPPDATA 'deew\config.toml'), 'C:\scripts\bin\config.toml')) {
                    if (Test-Path -LiteralPath $cfg) {
                        $mt = [regex]::Match((Get-Content -LiteralPath $cfg -Raw), "(?m)^\s*temp_path\s*=\s*'([^']*)'")
                        if ($mt.Success) { $deewTmpCfg = $mt.Groups[1].Value; break }
                    }
                }
                if ($deewTmpCfg -and ($deewTmpCfg.TrimEnd('\') -ne "$BigTmp".TrimEnd('\'))) {
                    Log ("    [ddp] AVISO: el temp de deew es '{0}' y el temporal pesado del trabajo es '{1}'. El RF64 (~1,15 MB/s, unos 10 GB en 2h30) NO cae donde se comprobo el espacio." -f $deewTmpCfg, $BigTmp)
                }
                $deewDiskFull = $false
                try {
                    # -dn solo si se fuerza un dialnorm explicito (por defecto 0 =>
                    # deew en auto). La deteccion desde 'truehdd info' aqui exigiria
                    # extraer el .thd (la ruta deew usa .mka), asi que para TrueHD sin
                    # Atmos / DTS se deja el dialnorm automatico de DEE.
                    $deewDn = if ($Dialnorm -lt 0 -and $Dialnorm -ge -31) { @('-dn', "$Dialnorm") } else { @() }
                    # 'extract' y no 'ddp': lo primero que hace deew es convertir
                    # a RF64 con ffmpeg, y ahora que su barra se ve (FORCE_COLOR) el
                    # panel puede decir la verdad ya desde el principio.
                    if ($OnProgress) { & $OnProgress 'extract' 0 }
                    # VIGILANTE POR TIEMPO, no por lineas de salida.
                    #
                    # Aqui el proceso caro (el dee.exe que lanza DEEW) nace unos
                    # 3 MINUTOS despues que DEEW, porque antes hay una conversion a
                    # RF64. Dos intentos anteriores fallaron por lo mismo: los dos
                    # colgaban de este ForEach-Object, y DEEW no imprime NADA
                    # mientras convierte, asi que el bloque no llega a ejecutarse y
                    # el reintento nunca corre. Medido en Gladiator: dee arranco a
                    # las 20:58 y seguia en Normal a las 21:07.
                    # Para vigilar algo que aparece mas tarde hace falta un reloj,
                    # no un flujo que puede callarse: de ahi el proceso aparte.
                    $boosterLog = Join-Path $BigTmp "dee_prio_${tag}.log"
                    $limpiar += @($boosterLog)
                    $booster = Start-PrioBooster -LogFile $boosterLog
                    try {
                        # HITOS PARA EL LOG. Con FORCE_COLOR la barra llega ~9 veces
                        # por segundo (medido: 320 lineas en 36 s), o sea unas 6.000
                        # lineas por pista en una pelicula. Se registra UNA CADA 10 %
                        # y por etapa, exactamente igual que ya se filtra el 'Overall
                        # progress' de dee al volcar el log de la pista.
                        # Hashtables a proposito: se mutan por referencia, asi que el
                        # bloque de ForEach-Object no depende de reglas de scope.
                        $deewHito = @{}
                        $deewUlt  = @{}
                        & $Deew -i $mka -f ddp -b $Bitrate @deewDn -o $out -np 2>&1 | ForEach-Object {
                            $linea = $_
                            if ($linea -match '(?i)FileWriter: write error|no space left|disk (is )?full') { $deewDiskFull = $true }
                            # deew pinta DOS barras: '[ ffmpeg | ...' mientras hace el
                            # RF64 y '[ DEE: encode | ...' al encodear. Se mapean a
                            # etapas DISTINTAS o el panel veria el % subir a 100,
                            # volver a 0 y subir otra vez.
                            $etapa = ''
                            if     ($linea -match '^\s*\[\s*ffmpeg') { $etapa = 'extract' }
                            elseif ($linea -match '^\s*\[\s*DEE')    { $etapa = 'ddp' }
                            if ($etapa -and ($linea -match '(\d+(?:\.\d+)?)\s*%')) {
                                # Invariante, mismo motivo que en las otras dos barras.
                                $pv = ConvertTo-DoubleInv $Matches[1]
                                if ($null -ne $pv) {
                                    if ($OnProgress -and (-not $deewUlt.ContainsKey($etapa) -or ($pv - $deewUlt[$etapa]) -ge 1.0)) {
                                        $deewUlt[$etapa] = $pv
                                        & $OnProgress $etapa $pv
                                    }
                                    $h = [int][math]::Floor($pv / 10)
                                    if (-not $deewHito.ContainsKey($etapa) -or $h -gt $deewHito[$etapa]) {
                                        $deewHito[$etapa] = $h
                                        Log "      [deew] $linea"
                                    }
                                }
                            } else {
                                Log "      [deew] $linea"
                            }
                        }
                    } finally {
                        # Parar el vigilante pase lo que pase: si no, queda un pwsh
                        # sondeando procesos hasta agotar su timeout de 4 horas.
                        if ($booster) { try { $booster.Kill() } catch { } }
                        # Y volcar al log del trabajo lo que hizo, que si no se
                        # pierde el rastro de si la prioridad llego o no.
                        if (Test-Path -LiteralPath $boosterLog) {
                            foreach ($bl in @(Get-Content -LiteralPath $boosterLog -EA SilentlyContinue)) { Log "    $bl" }
                        }
                    }
                } finally {
                    $env:PYTHONIOENCODING = $prevEnc
                    $env:TEMP = $prevTemp
                    $env:TMP  = $prevTmp
                    $env:FORCE_COLOR = $prevForce
                }
                $e = Get-ChildItem -LiteralPath $out -Filter *.ec3 -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($e -and $e.Length -gt 1024) { Copy-Item -LiteralPath $e.FullName -Destination $OutFile -Force -ErrorAction SilentlyContinue; $ok = (Test-Path -LiteralPath $OutFile) }
                else {
                    Log "    [ddp] ERROR: deew no genero .ec3."
                    Set-DdpFailure -Path $BigTmp -Force:$deewDiskFull
                }
            } else {
                Log "    [ddp] ERROR: no se pudo extraer la pista (a:$AudioIndex)."
                Set-DdpFailure -Path $BigTmp
            }
        }
    }
    catch {
        Log "    [ddp] ERROR inesperado: $_"
        Set-DdpFailure -Path $BigTmp
    }
    finally {
        # RESTAURAR afinidad y prioridad SIEMPRE. Si esto no corriera, encode.ps1
        # seguiria con el encode de video capado a los P-cores (y en AboveNormal),
        # que es justo lo contrario de lo que le conviene: ffmpeg si escala con
        # todos los nucleos, E-cores incluidos.
        if ($null -ne $affPrev) {
            try {
                $me = Get-Process -Id $PID
                $me.ProcessorAffinity = $affPrev
                if ($null -ne $prioPrev) { $me.PriorityClass = $prioPrev }
            } catch { Log "    [ddp] AVISO: no pude restaurar afinidad/prioridad ($($_.Exception.Message))." }
        }
        # LIMPIEZA GARANTIZADA de los temporales pesados de ESTA pista, salga esta
        # funcion como salga: exito, fallo, return temprano o excepcion. Es lo unico
        # que impide que $BigTmp acumule DAMFs de 30 GB trabajo tras trabajo.
        # (Un taskkill /F del panel sigue sin ejecutar esto: para ese caso estan los
        #  Clean-JobLeftovers de los watchers, que barren $BigTmp con los mismos
        #  patrones. Si se tocan los nombres de fichero de aqui, hay que tocarlos
        #  alli tambien.)
        $libre = 0L
        foreach ($f in ($limpiar | Where-Object { $_ } | Select-Object -Unique)) {
            $it = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            if ($it) { $libre += $it.Length }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
        foreach ($d in ($limpiarDirs | Where-Object { $_ } | Select-Object -Unique)) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($libre -gt 1GB) { Log ("    [ddp] temporales borrados: {0:N1} GB liberados en $BigTmp" -f ($libre / 1GB)) }
    }
    if ((-not $ok) -and (-not $global:DdpLastFailure)) { $global:DdpLastFailure = 'other' }
    return $ok
}
function Move-FicheroEnSitio {
    <#
      Sustituye $Destino por $Nuevo SIN que exista NUNCA un instante en el que no
      haya una copia buena en disco. Devuelve un objeto con Ok, Motivo, Grave y
      Aviso.

      POR QUE EXISTE (29/08/2026). Este repositorio hacia la misma sustitucion en
      cinco sitios y de tres formas distintas. Una de ellas -la de
      Rebuild-Container- DESTRUYO una pelicula de 7,09 GB e irrepetible con una
      sola linea:

          Move-Item -LiteralPath $tmpOut -Destination $File -Force

      Reconstruido con el diario USN del volumen, sin conjeturas:
          07:07:23  se crea   ...AAC.mkv._rebuild.mkv
          07:08:28  se BORRA  ...AAC.mkv          <- lo hizo el -Force
          07:08:30  se BORRA  ...._rebuild.mkv    <- lo hizo el finally
      Ni un solo evento de renombrado entre medias.

      Tres fallos que se sumaron, y hacian falta los tres:
        1. '-Force' NO es atomico: borra el destino y DESPUES mueve. El
           movimiento fallo por violacion de comparticion (mkvmerge aun no habia
           soltado el handle de su propia salida: su 'Cerrar' cae en el mismo
           segundo), y para entonces el destino ya no existia.
        2. Los scripts que llaman ahi corren con $ErrorActionPreference='Continue',
           asi que ese fallo NO fue terminante: no llego al catch, la ejecucion
           siguio en la linea de abajo y la funcion devolvio EXITO.
        3. El finally borro el sustituto, que a esas alturas era la unica copia.

      Las tres reglas que salen de ahi, y que esta funcion aplica siempre:
        1. NUNCA borrar el destino antes de tener el sustituto en su sitio. El
           original se APARTA con un renombrado: en el mismo volumen es
           instantaneo y no copia un solo byte.
        2. Todo movimiento con -ErrorAction Stop, para que un error no
           terminante no pueda colarse como exito.
        3. Comprobar DESPUES -que el destino existe y mide lo que debe- y, ante
           cualquier fallo, DESHACER.

      Los reintentos no son un adorno: Windows no suelta el handle en el mismo
      instante en que el proceso termina. Es el mismo motivo por el que existe
      Remove-ConReintento en pipeline-lock.ps1.

      Vive en atmos-lib.ps1 porque es la unica libreria que cargan LOS DOS
      motores (encode.ps1 y audio_encode.ps1) ademas de todos los drivers.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Nuevo,
        [Parameter(Mandatory=$true)][string]$Destino,
        # Suelo de tamanyo del sustituto respecto al destino. 0 lo desactiva
        # (util cuando la salida puede encoger mucho a proposito).
        [double]$MinRatio = 0.5,
        [int]$Intentos    = 5,
        [int]$EsperaMs    = 700
    )
    $r = [pscustomobject]@{ Ok = $false; Motivo = ''; Grave = $false; Aviso = '' }

    if (-not (Test-Path -LiteralPath $Nuevo)) { $r.Motivo = "el sustituto no existe: $Nuevo"; return $r }
    $bytesNuevo = (Get-Item -LiteralPath $Nuevo).Length
    if ($bytesNuevo -le 0) { $r.Motivo = 'el sustituto esta vacio'; return $r }

    $hayDestino = Test-Path -LiteralPath $Destino
    if ($hayDestino) {
        $bytesDest = (Get-Item -LiteralPath $Destino).Length
        if ($MinRatio -gt 0 -and $bytesNuevo -lt ($bytesDest * $MinRatio)) {
            $r.Motivo = ("el sustituto mide {0:N0} bytes y el destino {1:N0}: no llega al minimo exigido" -f $bytesNuevo, $bytesDest)
            return $r
        }
    }

    # 1) Apartar el original. Renombrado, no copia.
    $aparte = "$Destino.viejo"
    if ($hayDestino) {
        Remove-Item -LiteralPath $aparte -Force -ErrorAction SilentlyContinue
        try { Move-Item -LiteralPath $Destino -Destination $aparte -ErrorAction Stop }
        catch { $r.Motivo = "no se ha podido apartar el original: $($_.Exception.Message)"; return $r }
    }

    # 2) Poner el sustituto en su sitio, con reintentos por el handle.
    $movido = $false
    for ($i = 1; $i -le $Intentos -and -not $movido; $i++) {
        try { Move-Item -LiteralPath $Nuevo -Destination $Destino -ErrorAction Stop; $movido = $true }
        catch {
            if ($i -eq $Intentos) { $r.Motivo = "no se ha podido poner el sustituto en su sitio: $($_.Exception.Message)" }
            else { Start-Sleep -Milliseconds $EsperaMs }
        }
    }
    # 3) Comprobar de verdad, no fiarse de que la orden no protestara.
    if ($movido -and -not (Test-Path -LiteralPath $Destino)) {
        $movido = $false
        $r.Motivo = 'el movimiento no dio error pero el destino no esta'
    }

    if (-not $movido) {
        # DESHACER: el original vuelve a su nombre.
        if ($hayDestino -and -not (Test-Path -LiteralPath $Destino)) {
            try { Move-Item -LiteralPath $aparte -Destination $Destino -ErrorAction Stop }
            catch {
                $r.Grave  = $true
                $r.Motivo = "$($r.Motivo) -- Y NO SE HA PODIDO DESHACER. El original sigue existiendo, apartado en: $aparte"
            }
        }
        return $r
    }

    # 4) Ya hay sustituto en su sitio: el apartado sobra. Si no se puede borrar
    #    NO se calla: un huerfano de 10-40 GB en la carpeta de la pelicula no lo
    #    alcanza ningun barrido de temporales.
    if ($hayDestino) {
        $fuera = $false
        for ($i = 1; $i -le $Intentos -and -not $fuera; $i++) {
            Remove-Item -LiteralPath $aparte -Force -ErrorAction SilentlyContinue
            $fuera = -not (Test-Path -LiteralPath $aparte)
            if (-not $fuera -and $i -lt $Intentos) { Start-Sleep -Milliseconds $EsperaMs }
        }
        if (-not $fuera) { $r.Aviso = "sobra el original apartado en $aparte (borralo a mano)" }
    }
    $r.Ok = $true
    return $r
}

# ---------------------------------------------------------------------------
# LA DURACION DEL *VIDEO*, que es el invariante bueno para verificar un remux.
# La del CONTENEDOR no vale: mide por la pista mas larga, asi que se mueve por
# motivos legitimos (descartar un audio mas largo que el video) y NO se mueve
# cuando deberia (un video reescalado en el tiempo mientras el audio conserva su
# duracion). Ver la memoria 'medir-duracion-video-mkv'.
#
# Vive AQUI desde el 29/08/2026: habia dos copias identicas -audio_recap.ps1 y
# audio_compat.ps1- y estaba a punto de haber una tercera. Las tres trampas que
# lleva dentro (el sufijo de idioma en el tag, el ancla del patron y el decimal)
# costaron una ejecucion cada una; mantenerlas en tres sitios era cuestion de
# tiempo que divergieran.
# Necesita $FFPROBE definido por quien la usa.
# ---------------------------------------------------------------------------
function Get-DurVideo([string]$f) {
    # La duracion del VIDEO, no la del contenedor: al descartar una pista de audio
    # que dure mas que el video, el contenedor se acorta de forma legitima y
    # compararlo daria un falso fallo. El video va con '-c:v copy', asi que SU
    # duracion tiene que coincidir siempre.
    $d = (& $FFPROBE -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 -- $f 2>$null | Out-String).Trim()
    $v = ConvertTo-DoubleInv $d
    if ($v -gt 0) { return $v }
    # En MKV 'stream=duration' casi siempre viene vacio; el respaldo es el tag
    # DURATION. El decimal se captura con (\d+(?:[.,]\d+)?) y NO con [\d.,]+:
    # ese ultimo se traga el separador de detras y convierte "1:20:10,8" en
    # 1:20:00 (paso de verdad con 'Corre Lola, corre').
    # SE LEEN TODOS LOS TAGS, NO 'stream_tags=DURATION' (29/08/2026).
    # En Matroska los tags van POR IDIOMA y mkvpropedit escribe
    # 'DURATION-eng', no 'DURATION'. Pedir el nombre exacto no casaba y
    # ffprobe devolvia vacio, asi que esta funcion daba 0 y la guarda de
    # abajo abortaba la reconstruccion de TODOS esos ficheros -en
    # silencio salvo por un aviso en el log-. Visto en 'The Booth at the
    # End S01E01': TAG:DURATION-eng=00:22:45.363708333.
    $t = (& $FFPROBE -v error -select_streams v:0 -show_entries stream_tags -of default=nw=1 -- $f 2>$null | Out-String)
    if ($t -match '(?im)^TAG:DURATION[^=]*=(\d+):(\d+):(\d+(?:[.,]\d+)?)') {
        $s = ConvertTo-DoubleInv $Matches[3]
        if ($null -eq $s) { $s = 0.0 }
        return ([int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + $s)
    }
    # ULTIMO RECURSO: el PTS del ultimo paquete de video. Hay ficheros que NO
    # traen ningun tag en la pista de video: 'El maquinista (2004)' no tiene ni
    # 'duration', ni 'DURATION', ni 'nb_frames'. Sin esto la comprobacion se
    # quedaba sin poder medir y habia que renunciar a ella justo donde mas
    # falta hace. Leer SOLO LA COLA con -read_intervals cuesta 0,25 s medidos
    # (frente a los 16,7 s de demuxear el fichero entero), asi que sale gratis.
    # Se coge el MAXIMO y no el ultimo: los paquetes salen en orden de
    # decodificacion y con B-frames el pts no es monotono.
    $fd = ConvertTo-DoubleInv ((& $FFPROBE -v error -show_entries format=duration -of csv=p=0 -- $f 2>$null | Out-String).Trim())
    if ($fd -gt 0) {
        $desde = [math]::Max(0, [int]$fd - 90)
        $pts = @(& $FFPROBE -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 -read_intervals "$desde%+120" -- $f 2>$null) |
               ForEach-Object { ConvertTo-DoubleInv "$_" } | Where-Object { $null -ne $_ }
        if ($pts.Count) { return [double](($pts | Measure-Object -Maximum).Maximum) }
    }
    return 0.0
}

# ---------------------------------------------------------------------------
# LA DURACION DEL *CONTENEDOR*. Aqui desde el 31/08/2026: habia dos copias
# (audio_recap.ps1 y reordenar-pistas.ps1), llamadas las dos Get-Dur.
#
# VA PEGADA A Get-DurVideo A PROPOSITO, y no en cualquier otro sitio del
# fichero: la trampa de este proyecto no es que falte ninguna de las dos, es
# CONFUNDIRLAS. La del contenedor mide por la pista MAS LARGA, asi que:
#   - se mueve por motivos legitimos (descartar un audio mas largo que el video)
#   - y NO se mueve cuando deberia: un video reescalado en el tiempo mientras el
#     audio conserva su duracion la deja igual. Asi paso 'Informe Robinson
#     S04E06' -declaraba 50 fps con 25 reales- por delante de dos chequeos.
#
# REGLA: para verificar un remux, Get-DurVideo. Esta solo sirve como red gruesa
# o cuando lo que interesa es de verdad lo que dura el fichero entero.
# Ver la memoria 'medir-duracion-video-mkv'.
# Necesita $FFPROBE definido por quien la usa (lo da mediabox-paths.ps1).
# ---------------------------------------------------------------------------
function Test-EsMatroska {
    <#
      $true solo si el fichero ES Matroska DE VERDAD, mirando dentro.

      POR QUE NO VALE LA EXTENSION (01/09/2026). En esta biblioteca hay CUATRO
      ficheros con extension '.mkv' que son MP4: 'Rent (2005)', 'Siete
      psicopatas (2012)', 'Vidas al limite (2005)' y 'La nueva corporacion'.
      Abren y se reproducen perfectamente -Plex mira el contenedor, no el
      nombre-, asi que nadie se habia enterado. Pero los drivers que preguntan
      "termina en .mkv?" se los daban a mkvpropedit y a mkvextract, que solo
      entienden Matroska: fallo garantizado, y en retrofit-reconstruir.ps1
      ademas un reintento en cada pasada para siempre.

      Se mira la firma EBML (1A 45 DF A3) y no se llama a ffprobe: son cuatro
      bytes, sin lanzar un proceso por fichero, y sobre una lista de 6.700 esa
      diferencia se nota. Un Matroska con la cabecera destruida da $false, que
      es lo correcto: mkvmerge tampoco iba a poder leerlo.
    #>
    param([Parameter(Mandatory=$true)][string]$File)
    try {
        $fs = [System.IO.File]::OpenRead($File)
        try {
            $b = New-Object byte[] 4
            if ($fs.Read($b, 0, 4) -ne 4) { return $false }
        } finally { $fs.Dispose() }
    } catch { return $false }
    return ($b[0] -eq 0x1A -and $b[1] -eq 0x45 -and $b[2] -eq 0xDF -and $b[3] -eq 0xA3)
}


function Get-DurContenedor([string]$f) {
    # Con Out-String: si ffprobe devolviera mas de una linea, $r seria un array
    # y la interpolacion las pegaria con espacios, dejando un numero imposible
    # de parsear. Una de las dos copias no lo llevaba.
    $r = (& $FFPROBE -v error -show_entries format=duration -of csv=p=0 -- $f 2>$null) | Out-String
    return (ConvertTo-DoubleInv $r.Trim())
}

# ---------------------------------------------------------------------------
# GUARDAR EL ESTADO DE UN DRIVER. Aqui desde el 31/08/2026: habia CUATRO copias
# (audio_compat, audio_recap, reordenar-pistas, retrofit-reconstruir) y ya
# habian divergido -tres escribian con -Depth 3 y una con -Depth 4-.
#
# POR QUE IMPORTA ESA DIVERGENCIA, que parece cosmetica: ConvertTo-Json no avisa
# cuando se pasa de profundidad, TRUNCA Y SIGUE. El sobrante sale como la cadena
# literal del tipo de objeto, y lo que se relee en el arranque siguiente es un
# estado incompleto que parece bueno. Es exactamente la forma de fallo que este
# repositorio se ha comido varias veces: sin error, sin aviso, sin log.
#
# Por eso el valor por defecto es 6 y no 3: mas hondo de lo que ninguno de los
# cuatro necesita. Subirlo no cambia la salida de un objeto llano.
# ---------------------------------------------------------------------------
function Save-EstadoDriver {
    param(
        [Parameter(Mandatory=$true)]$Estado,
        [Parameter(Mandatory=$true)][string]$Fichero,
        [int]$Depth = 6
    )
    ($Estado | ConvertTo-Json -Depth $Depth -Compress) |
        Set-Content -LiteralPath $Fichero -Encoding UTF8
}

# ---------------------------------------------------------------------------
# ISO 639-2 tiene DOS codigos para el mismo idioma: el bibliografico (B) y el
# terminologico (T). Matroska y ffprobe usan el B ('ger','fre','dut'); MediaInfo
# devuelve el T ('deu','fra','nld'). Comparar uno contra otro daba falsos fallos
# de verificacion en 37 ficheros. Se normaliza a la forma B, que es la que acaba
# escrita en el contenedor. Aqui desde el 29/08/2026, por lo mismo que
# Get-DurVideo: habia dos copias.
# ---------------------------------------------------------------------------
$IsoT2B = @{
    deu='ger'; fra='fre'; nld='dut'; ell='gre'; ces='cze'; ron='rum'; isl='ice'
    fas='per'; eus='baq'; slk='slo'; sqi='alb'; hye='arm'; mya='bur'; kat='geo'
    mkd='mac'; msa='may'; mri='mao'; bod='tib'; cym='wel'; zho='chi'
}
function Get-IsoCanon([string]$c) {
    $k = "$c".Trim().ToLower()
    if ($IsoT2B.ContainsKey($k)) { return $IsoT2B[$k] }
    return $k
}

# ===========================================================================
# RECONSTRUCCION DEL CONTENEDOR
# ===========================================================================
# Vino de encode.ps1 el 31/08/2026, SIN tocar una sola linea de la funcion.
# Vive aqui por lo mismo que Move-FicheroEnSitio: es la unica libreria que
# cargan los dos motores (encode.ps1 y audio_encode.ps1) y todos los drivers.
# Antes se la sacaban de encode.ps1 con el parser, cuatro veces.
#
# NECESITA de quien la usa: $MKVMERGE, $MKVEXTRACT, $FFMPEG, $FFPROBE (los da
# mediabox-paths.ps1, que este fichero ya carga), $BigTmp, y una funcion Log.
# ===========================================================================
function Rebuild-Container {
    param(
        [Parameter(Mandatory=$true)][string]$File,
        # Se llama con el % (0-100) DE ESTA FASE segun avanzan mkvextract y
        # mkvmerge. Sin esto el panel escribia 97 una sola vez y se quedaba
        # clavado ahi los 13,6 min que tarda la fase en una pelicula de 10 GB.
        # Reparto medido en "Oceanos De Fuego": la extraccion se lleva ~70 % del
        # tiempo de la fase y el muxeo el ~30 % restante.
        [scriptblock]$OnProgress = $null
    )
    <#
      Reconstruye el MKV: extrae cada pista a un fichero suelto y vuelve a
      muxear desde cero con mkvmerge. NO recodifica: los streams quedan bit a
      bit identicos, solo cambia como se construye el contenedor.

      POR QUE (31/07/2026). Cuatro peliculas de este pipeline (Keepers,
      Vengadores La Era de Ultron, Regreso al futuro, En la linea de fuego) NO
      se reproducian en la TV Samsung de 2024 via Plex: imagen negra y la TV
      abortaba sola a los ~3 s. Fallaba SIEMPRE en Direct Play, y por eso Plex
      no registraba ningun error: desde su lado servia el fichero correctamente.
      Esta reconstruccion las arregla las cuatro.

      LA CAUSA RAIZ NO SE ENCONTRO. Descartado POR MEDICION, no repetir:
        - contenedor: un remux con mkvmerge (conserva timestamps) TAMBIEN falla
        - tier HEVC, nivel, bitstream de video (un clip -c copy del mismo video
          funciona con otro audio)
        - duracion/tamano: fallaba ya en clips de 225 MB
        - subtitulos, orden de pistas, banderas default/forced, idioma
        - codec EAC3 en si: El reino de los cielos e Interstellar llevan EAC3 en
          Direct Play y funcionan
        - estructura del bitstream de audio: 201.641 syncframes parseados a mano,
          un solo substream, cabeceras constantes, cero anomalias
        - niveles de audio, tags de estadisticas, DefaultDuration, compresion
      Lo unico que se deduce: como el remux reescribe el contenedor y aun asi
      falla, pero extraer+reconstruir (que DESCARTA los timestamps y los
      regenera desde el framerate) si funciona, el defecto esta en la
      TEMPORIZACION que escribe ffmpeg, no en el contenedor ni en los codecs.

      VA ANTES de los mkvpropedit finales a proposito: la reconstruccion pierde
      las propiedades de color del contenedor (viven en el contenedor, no en el
      stream), asi que el mastering display HDR10 tiene que reinyectarse DESPUES.

      Fail-safe: si algo va mal se conserva el fichero original y solo se avisa.
      Un fallo aqui no corrompe nada; como mucho deja el defecto de la TV.
      Devuelve $true si reconstruyo.
    #>
    if (-not (Test-Path -LiteralPath $MKVMERGE) -or -not (Test-Path -LiteralPath $MKVEXTRACT)) {
        Log "AVISO: no encuentro mkvmerge/mkvextract - se omite la reconstruccion del contenedor"
        return $false
    }
    $ext = @{
        "V_MPEGH/ISO/HEVC"="h265"; "V_MPEG4/ISO/AVC"="h264"; "V_AV1"="obu"
        "A_EAC3"="eac3"; "A_AC3"="ac3"; "A_AAC"="aac"; "A_TRUEHD"="thd"
        "A_DTS"="dts"; "A_FLAC"="flac"; "A_OPUS"="opus"; "A_VORBIS"="ogg"
        "A_MPEG/L3"="mp3"; "A_PCM/INT/LIT"="wav"
        "S_TEXT/UTF8"="srt"; "S_TEXT/ASS"="ass"; "S_TEXT/SSA"="ssa"
        "S_HDMV/PGS"="sup"; "S_VOBSUB"="sub"
    }
    $work = Join-Path $BigTmp ("_recon_" + [System.IO.Path]::GetRandomFileName().Substring(0,8))
    # Declarado FUERA del try: el finally lo consulta para no dejar huerfano el
    # original apartado si algo revienta por el camino.
    $aparte = $null
    # Cuantas pistas vacias se han apartado. Quien llama lo necesita para no
    # contar de menos al comparar pistas antes/despues y dar un falso fallo.
    $global:UltimasPistasFuera = 0
    try {
        $json = & $MKVMERGE -J $File 2>$null | Out-String | ConvertFrom-Json
        if (-not $json.tracks) { throw "mkvmerge -J no devolvio pistas" }

        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $specs = @(); $files = @{}; $tipos = @{}
        # PORTADAS INCRUSTADAS (29/08/2026). Hay MKV con una SEGUNDA pista de
        # video que no es video: es la caratula metida dentro del fichero.
        # Medido: 'Gattaca' lleva un V_MJPEG de 580x859 (un poster en vertical) y
        # 'Train to Busan' un V_MS/VFW/FOURCC de 234x140 (una miniatura).
        # mkvextract SE NIEGA a extraerlas -"la extraccion de la pista con
        # CodecID 'V_MJPEG' no es compatible"-, asi que no pueden sobrevivir a un
        # extraer+muxear y antes tumbaban la reconstruccion entera.
        # Se descartan por decision del usuario: no las usa nadie -Plex tira de
        # los -poster.jpg/-fanart.jpg que hay en cada carpeta- y el precio de
        # conservarlas es quedarse sin reconstruir, o sea con la pantalla negra.
        #
        # LA GUARDA QUE IMPORTA: solo se descarta una pista de video que NO sea
        # la PRIMERA. La primera es la pelicula, y si esa trae un codec_id que no
        # sabemos extraer se aborta como siempre. Sin esa condicion, un codec de
        # video desconocido se tiraria a la basura en silencio.
        $vistoVideo = $false
        $portadas   = @()
        foreach ($t in $json.tracks) {
            $cid = "$($t.properties.codec_id)"
            $esVideo = ("$($t.type)" -eq 'video')
            if ($esVideo -and -not $vistoVideo) { $vistoVideo = $true }
            elseif ($esVideo -and -not $ext.ContainsKey($cid)) {
                $portadas += ("id {0} {1} {2}" -f $t.id, $cid, $t.properties.pixel_dimensions)
                continue
            }
            if (-not $ext.ContainsKey($cid)) { throw "codec_id sin extension conocida: $cid" }
            $p = Join-Path $work ("t{0}.{1}" -f $t.id, $ext[$cid])
            $files[[int]$t.id] = $p
            $tipos[[int]$t.id] = "$($t.type)"
            $specs += ("{0}:{1}" -f $t.id, $p)
        }
        if ($portadas.Count) {
            Log ("  {0} portada(s)/miniatura(s) incrustada(s) descartada(s): {1}" -f $portadas.Count, ($portadas -join ' ; '))
            Log "  No son video: mkvextract no sabe extraerlas y la caratula ya esta en la carpeta como -poster.jpg."
        }
        # '--gui-mode' Y NO LA SALIDA NORMAL, y esto no es un capricho: esta
        # instalacion de MKVToolNix esta EN ESPANOL y escribe "Progreso: 4%", no
        # "Progress: 4%". Un patron en ingles no habria casado nunca y la barra se
        # habria quedado muda otra vez, que es justo el fallo que esto viene a
        # arreglar. Con --gui-mode la salida es '#GUI#progress 4%': un token
        # estable, pensado para que lo lea un programa, e independiente del idioma.
        # (Verificado ejecutando los dos modos: 26 lineas capturadas con gui-mode,
        # 0 con el patron ingles.)
        # PRIORIDAD (19/08/2026). Este era EL cuello de botella de la fase, y no
        # era ni la herramienta ni el disco:
        #   en el trabajo real de hoy    -> 13 MB/s  (13,6 min para 10,24 GB)
        #   la misma mkvextract ociosa   -> 108 MB/s (5,69 GB de E: a G: en 53,9 s)
        # Ocho veces mas lenta, y ademas leyendo del NVMe en vez del array USB. La
        # diferencia era CONTENCION: eMule leyendo a 40 MB/s y tinyMediaManager
        # sacando miniaturas con su propio ffmpeg, todos a la misma prioridad.
        # Es el mismo fallo que ya mordio con el OCR (ver la nota del 14/08) y la
        # misma solucion: subir la prioridad del hijo. Windows NO la hereda -segun
        # la propia documentacion de CreateProcess, el hijo nace en Normal-, asi
        # que hay que subirsela una vez ya existe. La primera linea de progreso es
        # la senyal mas barata de que ya esta ahi.
        # (Medido en dee: la prioridad vale 2,76x y la afinidad solo 1,15x.)
        # Set-ChildPriority vive en atmos-lib.ps1. Se comprueba que exista en vez
        # de darlo por hecho: si esa libreria faltara, encode.ps1 solo avisa y
        # sigue (el aviso habla del modo atmos_ddp), y sin esta guarda la
        # reconstruccion -que no tiene nada que ver con Atmos- se caeria entera
        # por una dependencia ajena. La prioridad es una MEJORA, no un requisito.
        $puedePrio = [bool](Get-Command Set-ChildPriority -ErrorAction SilentlyContinue)
        if (-not $puedePrio) { Log "  aviso: no esta Set-ChildPriority; la reconstruccion corre a prioridad normal" }
        $ultExt = -1
        $prioExt = $false
        & $MKVEXTRACT --gui-mode $File tracks @specs 2>&1 | ForEach-Object {
            if ($puedePrio -and -not $prioExt) { $prioExt = $true; Set-ChildPriority -Name 'mkvextract' | Out-Null }
            if ($OnProgress -and ("$_" -match '#GUI#progress\s+(\d+)\s*%')) {
                $pv = [int]$Matches[1]
                if ($pv -ne $ultExt) { $ultExt = $pv; & $OnProgress ($pv * 0.70) }
            }
        }
        # PISTAS VACIAS (29/08/2026). Un MKV puede llevar una pista declarada y
        # SIN un solo paquete dentro. mkvextract la procesa, informa de "100%" y
        # no escribe fichero -o escribe uno de 0 bytes-, y despues mkvmerge se
        # niega con "No se pudo reconocer el tipo de archivo 't3.sup'". Como su
        # salida se descartaba, en el log solo quedaba "mkvmerge no genero la
        # salida" y no habia por donde cogerlo. Medido en 'El cuerpo (2012)' y
        # 'Escape de Absolom (1994)': los dos con un PGS vacio.
        #
        # Una pista de subtitulos vacia NO tiene contenido que perder, asi que se
        # deja fuera de la reconstruccion y SE DICE. Con video o audio no se hace
        # eso ni de broma: ahi un fichero vacio significa que la extraccion ha
        # fallado, y entonces se aborta y la pelicula se queda como estaba.
        $fuera = @()
        foreach ($id in @($files.Keys)) {
            $p = $files[$id]
            $vacio = (-not (Test-Path -LiteralPath $p)) -or ((Get-Item -LiteralPath $p -ErrorAction SilentlyContinue).Length -eq 0)
            if (-not $vacio) { continue }
            if ($tipos[$id] -ne 'subtitles') {
                throw "mkvextract no genero contenido para la pista $id ($($tipos[$id])): $p"
            }
            $fuera += $id
            $files.Remove($id)
        }
        # Se suman las portadas: quien llama compara pistas antes/despues y sin
        # esto daria un falso fallo justo en los ficheros que acabamos de salvar.
        # ASS/SSA -> SRT, SIEMPRE (29/08/2026, por decision explicita).
        #
        # El ASS lleva estilos y posicionamiento propios y pide sus FUENTES como
        # adjuntos del MKV; el SRT es texto plano y lo pinta el reproductor con
        # el suyo. Convertir simplifica la biblioteca entera y ademas vuelve
        # irrelevantes esas fuentes -que es justo lo que esta reconstruccion
        # perdia en silencio hasta hoy-.
        #
        # ENCAJA AQUI SIN ESFUERZO porque la reconstruccion ya extrae cada pista
        # a un fichero suelto: basta con convertir ese fichero antes de volver a
        # muxear. El numero de pistas no cambia.
        #
        # LO QUE SE PIERDE, dicho claro: posicionamiento y estilos. En un ASS de
        # dialogo no se nota; en uno usado para carteles y rotulos, si.
        #
        # ffmpeg se resuelve AQUI DENTRO y no se da por hecho: esta funcion se
        # extrae con el parser a scripts que NO definen $FFMPEG (el retrofit,
        # sanear.ps1, reconstruir-contenedor.ps1), y darlo por sentado la habria
        # roto justo en esos.
        $ffm = if ($FFMPEG -and (Test-Path -LiteralPath $FFMPEG)) { $FFMPEG }
               else { 'C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe' }
        $aSrt = @{}
        if (Test-Path -LiteralPath $ffm) {
            foreach ($id in @($files.Keys)) {
                if ($tipos[$id] -ne 'subtitles') { continue }
                $pa = $files[$id]
                if ($pa -notmatch '\.(ass|ssa)$') { continue }
                $srt = [System.IO.Path]::ChangeExtension($pa, '.srt')
                & $ffm -v error -y -i $pa -c:s subrip -- $srt 2>&1 | Out-Null
                if ((Test-Path -LiteralPath $srt) -and ((Get-Item -LiteralPath $srt).Length -gt 0)) {
                    $files[$id] = $srt
                    $aSrt[$id]  = $true
                } else {
                    Log "  AVISO: la pista $id no se ha podido convertir de ASS a SRT; se queda en ASS"
                }
            }
            if ($aSrt.Count) { Log ("  subtitulos convertidos de ASS/SSA a SRT: {0}" -f $aSrt.Count) }
        } else {
            Log "  aviso: no encuentro ffmpeg; los subtitulos ASS se quedan como estan"
        }

        $global:UltimasPistasFuera = $fuera.Count + $portadas.Count
        if ($fuera.Count) {
            Log ("  AVISO: {0} pista(s) de subtitulos VACIAS en el origen (id {1}); se quedan fuera del reconstruido." -f $fuera.Count, ($fuera -join ', '))
            Log "  No se pierde nada: no tenian un solo paquete dentro. Por eso mkvmerge rechazaba el fichero entero."
        }
        if ($OnProgress) { & $OnProgress 70.0 }
        # ADJUNTOS (29/08/2026). Esta reconstruccion extrae PISTAS y capitulos, y
        # los adjuntos se quedaban por el camino: se perdian en silencio. En un
        # MKV con subtitulos ASS los adjuntos son LAS FUENTES que esos subtitulos
        # piden por nombre, asi que sin ellas el reproductor cae a una cualquiera
        # y los subtitulos ya no se ven como estaban hechos.
        #
        # Se descubrio porque el driver comparaba el numero de streams de ffprobe
        # antes y despues -ffprobe cuenta los adjuntos como streams- y salia
        # "pistas 6 != 9" en 9 peliculas. Sin esa comparacion no se habria visto
        # nunca: ni el log ni mkvmerge dicen una palabra.
        $adjDir = Join-Path $work "adj"
        $adjuntos = @($json.attachments)
        if ($adjuntos.Count) {
            New-Item -ItemType Directory -Path $adjDir -Force | Out-Null
            $espec = @()
            foreach ($a in $adjuntos) {
                # El nombre se guarda aparte y el fichero se escribe con el ID:
                # dos adjuntos pueden llamarse igual, y ademas un nombre de fuente
                # puede traer caracteres que aqui no ayudan.
                $espec += ("{0}:{1}" -f $a.id, (Join-Path $adjDir ("a{0}.bin" -f $a.id)))
            }
            & $MKVEXTRACT $File attachments @espec 2>&1 | Out-Null
        }
        $chaps = Join-Path $work "chapters.xml"
        & $MKVEXTRACT $File chapters $chaps 2>&1 | Out-Null
        $hasCh = (Test-Path -LiteralPath $chaps) -and ((Get-Item -LiteralPath $chaps).Length -gt 50)

        # DONDE ESCRIBE mkvmerge (19/08/2026). Antes siempre en $work, o sea en
        # $BigTmp (G:), y el Move-Item final cruzaba de unidad: eso NO es un
        # renombrado, es una COPIA COMPLETA del fichero. Medido en Oceanos De
        # Fuego (salida de 10,24 GB), la cadena entera movia ~70 GB de I/O:
        #   extract  C: -> G:   (10 leidos + 10 escritos)
        #   mkvmerge G: -> G:   (10 + 10)
        #   Move     G: -> C:   (10 + 10)   <- este sobra
        #   propedit C:         (10 leidos)
        # Escribiendo directamente en la unidad del DESTINO, ese tercer paso pasa
        # a ser un renombrado instantaneo: se ahorran 10 GB de lectura y 10 de
        # escritura por pelicula.
        #
        # CON GUARDA DE ESPACIO: mientras dura, conviven el fichero original y el
        # reconstruido, asi que hacen falta ~2x su tamano en el destino. C: es el
        # disco que se lleno a mitad de un encode el 31/07/2026, asi que si no hay
        # margen holgado se vuelve al camino de antes (temporal en $BigTmp) en vez
        # de arriesgarse. Se deja dicho en el log cual de los dos se uso.
        $srcBytes = (Get-Item -LiteralPath $File).Length
        $dstRoot  = (Get-Item -LiteralPath $File).Directory.Root.FullName
        $dstFree  = try { (New-Object System.IO.DriveInfo($dstRoot)).AvailableFreeSpace } catch { 0 }
        $tmpOut   = Join-Path $work "rebuilt.mkv"
        $mismoVol = $false
        $ultMux   = -1
        if ($dstFree -gt ($srcBytes * 2 + 10GB)) {
            # Junto al destino y con extension .mkv: mkvmerge decide el tipo de
            # contenedor por la extension de salida.
            # Se AÑADE el sufijo, no se cambia la extension: en PowerShell el
            # $null de ChangeExtension llega como cadena vacia y devuelve
            # "Peli (2004)." -con punto final-, o sea "Peli (2004).._rebuild.mkv".
            # Funcionaba de milagro porque el barrido lo calculaba igual de mal.
            # Asi acaba en .mkv, que es lo que mkvmerge mira para elegir formato.
            $tmpOut   = $File + "._rebuild.mkv"
            $mismoVol = $true
            Log ("  reconstruccion: mkvmerge escribe en la unidad del destino ({0}), el move final sera un renombrado" -f $dstRoot.TrimEnd('\'))
        } else {
            Log ("  reconstruccion: solo {0:N0} GB libres en {1}; mkvmerge escribe en {2} y habra copia entre unidades" -f ($dstFree/1GB), $dstRoot.TrimEnd('\'), $BigTmp)
        }
        # ─────────────────────────────────────────────────────────────────
        # LOS TIMESTAMPS DEL ORIGEN (29/08/2026).
        #
        # Esta reconstruccion regenera los timestamps del video desde el
        # framerate, y eso es lo que arregla la pantalla negra. Pero hay
        # ficheros a los que les FALTAN FOTOGRAMAS: sus fotogramas van al ritmo
        # nominal y hay SALTOS por medio. Regenerar a ritmo constante los
        # empaqueta uno detras de otro, se come los huecos, y el video sale mas
        # corto y -lo grave- DESINCRONIZADO del audio a partir de cada salto.
        #
        # Medido en 'Hotel Fawlty - S02E01': 2 huecos que suman 18,80 s, y el
        # video se acortaba exactamente 18,9 s. Y no era el framerate declarado:
        # 'Juegos de guerra' y 'Philadelphia' declaran 23,976 y MIDEN 23,976, y
        # tambien se acortaban. La causa son los huecos, no la cifra.
        #
        # Asi que se extraen los timestamps de cada pista de video por si hay que
        # usarlos. Es barato: mkvextract los saca del indice, no demuxea.
        $tsFiles = @{}
        foreach ($t in $json.tracks) {
            if ("$($t.type)" -ne 'video') { continue }
            if (-not $files.ContainsKey([int]$t.id)) { continue }
            $ts = Join-Path $work ("ts{0}.txt" -f $t.id)
            & $MKVEXTRACT $File timestamps_v2 ("{0}:{1}" -f $t.id, $ts) 2>&1 | Out-Null
            if ((Test-Path -LiteralPath $ts) -and ((Get-Item -LiteralPath $ts).Length -gt 0)) {
                $tsFiles[[int]$t.id] = $ts
            }
        }

        # LA DURACION DEL VIDEO LA MIDE Get-DurVideo, unas 400 lineas mas
        # arriba en este mismo fichero (31/08/2026).
        #
        # Aqui vivia una copia ANIDADA, identica linea por linea. Tenia un
        # motivo de verdad: audio_encode.ps1 no dot-sourceaba encode.ps1,
        # extraia ESTA funcion sola con el parser, y una ayudante suelta en
        # encode.ps1 no habria llegado hasta alli -la guarda se habria caido
        # justo en la rama de audio, que es donde mas falta hace-.
        #
        # ESE MOTIVO YA NO EXISTE: Rebuild-Container vive en atmos-lib.ps1,
        # Get-DurVideo tambien, y las cuatro copias del truco del parser se
        # borraron. Mantener dos copias de una funcion que lleva TRES trampas
        # dentro -el sufijo de idioma del tag, el ancla del patron y el
        # decimal, una ejecucion perdida cada una- era esperar a que
        # divergieran.

        # Los argumentos de mkvmerge se construyen en una funcion porque hacen
        # falta DOS veces: primero regenerando los timestamps (lo que arregla la
        # pantalla negra) y, si eso desplaza el video, otra vez conservando los
        # del origen.
        function ArgsMux([bool]$ConservarTs) {
            $mkvArgs = @("-o",$tmpOut)
            if ($hasCh) { $mkvArgs += @("--chapters",$chaps) }
            # EL TITULO DEL CONTENEDOR (26/08/2026). La reconstruccion conservaba
            # idioma, nombre, banderas, fps y capitulos de cada pista, pero el titulo
            # del FICHERO se perdia: mkvmerge no lo hereda de ninguna pista y aqui no
            # se le pasaba. Comprobado sobre una salida real: el fuente traia
            # title='Rocky's Cat-astrophe' y el resultado no traia ninguno.
            # Se toma del fichero que entra a la reconstruccion -que es la salida de
            # ffmpeg, ya con el -map_metadata 0 aplicado-, asi que reconstruir deja de
            # cambiar nada observable del contenedor.
            $titCont = "$($json.container.properties.title)"
            if ($titCont) { $mkvArgs += @("--title",$titCont) }
            $order = @(); $i = 0
            foreach ($t in $json.tracks) {
                # Las vacias que se han apartado arriba ya no estan en $files.
                if (-not $files.ContainsKey([int]$t.id)) { continue }
                $pr = $t.properties
                $lang = if ($pr.language) { $pr.language } else { "und" }
                $mkvArgs += @("--language","0:$lang")
                if ($pr.track_name) { $mkvArgs += @("--track-name",("0:{0}" -f $pr.track_name)) }
                $mkvArgs += @("--default-track-flag",("0:{0}" -f $(if ($pr.default_track) {1} else {0})))
                $mkvArgs += @("--forced-display-flag",("0:{0}" -f $(if ($pr.forced_track) {1} else {0})))
                if ($t.type -eq "video" -and $pr.default_duration) {
                    # Con $ConservarTs mandan los timestamps del origen, asi que
                    # NO se declara framerate: seria contradecirlos.
                    if (-not $ConservarTs) {
                        $fps = 1000000000.0 / [double]$pr.default_duration
                        $mkvArgs += @("--default-duration",("0:{0}fps" -f $fps.ToString("F10",[System.Globalization.CultureInfo]::InvariantCulture)))
                    }
                }
                if ($aSrt.ContainsKey([int]$t.id)) {
                    # mkvmerge asume la codepage del SISTEMA para un .srt externo si
                    # no la detecta, y ffmpeg escribe UTF-8 sin BOM. Decirlo cuesta
                    # un argumento y evita que cualquier acento entre como mojibake.
                    $mkvArgs += @("--sub-charset","0:UTF-8")
                }
                # --timestamps va INMEDIATAMENTE antes del fichero al que se
                # aplica, y el '0' es la pista dentro de ESE fichero (cada uno
                # trae una sola).
                if ($ConservarTs -and $tsFiles.ContainsKey([int]$t.id)) {
                    $mkvArgs += @("--timestamps", ("0:{0}" -f $tsFiles[[int]$t.id]))
                }
                $mkvArgs += @($files[[int]$t.id])
                $order += ("{0}:0" -f $i); $i++
            }
            $mkvArgs += @("--track-order",($order -join ","))
            # Cada adjunto con su nombre y su tipo MIME originales: las opciones van
            # ANTES del --attach-file al que se aplican.
            $adjOk = 0
            foreach ($a in $adjuntos) {
                $ruta = Join-Path $adjDir ("a{0}.bin" -f $a.id)
                if (-not (Test-Path -LiteralPath $ruta)) { continue }
                if ($a.file_name)    { $mkvArgs += @("--attachment-name", "$($a.file_name)") }
                if ($a.content_type) { $mkvArgs += @("--attachment-mime-type", "$($a.content_type)") }
                $mkvArgs += @("--attach-file", $ruta)
                $adjOk++
            }
            if ($adjuntos.Count) {
                Log ("  adjuntos conservados: {0} de {1}" -f $adjOk, $adjuntos.Count)
                if ($adjOk -ne $adjuntos.Count) { throw "no se han podido extraer todos los adjuntos ($adjOk de $($adjuntos.Count))" }
            }

            return $mkvArgs
        }

        # Ya NO se pasa '-q' (silenciaba tambien el progreso) y SI '--gui-mode',
        # por lo mismo que en mkvextract: el token '#GUI#progress NN%' no depende
        # del idioma de la instalacion. El resto de su salida se descarta aqui
        # mismo, asi que no ensucia el log.
        # DOS INTENTOS. El primero REGENERA los timestamps desde el framerate,
        # que es lo que arregla la pantalla negra y lo que vale para la inmensa
        # mayoria. Si eso desplaza el video -porque el fichero tiene huecos-, el
        # segundo los CONSERVA. Ver la nota de $tsFiles arriba.
        $conservandoTs = $false
        $reintentadoTs = $false
        while ($true) {
            $mkvArgs = ArgsMux $conservandoTs
            $prioMux = $false
            # SE GUARDA LO QUE DICE mkvmerge (29/08/2026). Antes su salida se
            # descartaba entera, asi que cuando fallaba lo unico que quedaba en el
            # log era "mkvmerge no genero la salida" -sin una sola pista de por que-
            # y no habia forma de arreglar el fichero sin volver a reproducirlo a
            # mano. Con '--gui-mode' los errores salen como '#GUI#error <texto>', y
            # eso es lo que interesa; el progreso se sigue filtrando.
            $errMux = New-Object System.Collections.Generic.List[string]
            & $MKVMERGE --gui-mode @mkvArgs 2>&1 | ForEach-Object {
                # Misma razon que en mkvextract: sin esto el muxeo pelea de tu a tu
                # con eMule por el disco.
                if ($puedePrio -and -not $prioMux) { $prioMux = $true; Set-ChildPriority -Name 'mkvmerge' | Out-Null }
                $ln = "$_"
                if ($OnProgress -and ($ln -match '#GUI#progress\s+(\d+)\s*%')) {
                    $pv = [int]$Matches[1]
                    if ($pv -ne $ultMux) { $ultMux = $pv; & $OnProgress (70.0 + $pv * 0.30) }
                }
                elseif ($ln -match '#GUI#error' -or $ln -match '(?i)^\s*(error|fehler)') {
                    if ($errMux.Count -lt 6) { $errMux.Add(($ln -replace '^#GUI#error\s*','')) }
                }
            }
            if (-not (Test-Path -LiteralPath $tmpOut)) {
                $det = if ($errMux.Count) { " -> " + ($errMux -join ' | ') } else { ' (y no dijo por que)' }
                throw "mkvmerge no genero la salida$det"
            }

            # Comprobacion antes de pisar nada: mismo numero de pistas y duracion a <1 s.
            $chk = & $MKVMERGE -J $tmpOut 2>$null | Out-String | ConvertFrom-Json
            # Contra las pistas que se han MUXEADO, no contra las del origen: si se
            # aparto alguna vacia, el origen tiene una mas y esto daria un falso fallo.
            if ($chk.tracks.Count -ne $files.Count) { throw "el reconstruido tiene $($chk.tracks.Count) pistas y se esperaban $($files.Count)" }
            # ORDEN: PRIMERO EL VIDEO (29/08/2026). Estaba al reves, y eso mentia
            # sobre la causa: en 6 peliculas el chequeo del contenedor saltaba antes
            # y el fallo se leia como "se ha quedado corto" -que suena a cabecera
            # inflada, benigno- cuando lo que pasaba de verdad era un reescalado del
            # tiempo del video. Comprobado quitando el chequeo del contenedor en una
            # copia de 'Hotel Fawlty S02E01': el video pasaba de 1.883,0 s a 1.864,1.
            # Un diagnostico equivocado cuesta mas que no tenerlo.
            # LA DURACION DEL *VIDEO*, QUE ES LO QUE DE VERDAD PUEDE ROMPERSE AQUI
            # (29/08/2026). La comprobacion de arriba mira el CONTENEDOR, y el
            # contenedor mide por la pista MAS LARGA: mientras el audio conserve su
            # duracion -y la conserva siempre, porque sus timestamps salen del propio
            # stream-, el contenedor no se entera de nada aunque el video haya
            # quedado al doble de velocidad.
            #
            # Y ese fallo existe, no es teorico. Esta reconstruccion regenera los
            # timestamps del video DESDE EL FRAMERATE DECLARADO (es justo lo que
            # arregla la pantalla negra), asi que un fichero que declara un framerate
            # que no es el suyo sale con el video reescalado en el tiempo. Medido en
            # 'Informe Robinson - S04E06': declara 50 fps y lleva 47.267 fotogramas
            # en 1.890,9 s, o sea 25 reales; el reconstruido dejaba el video en
            # 945,3 s -la mitad- mientras la duracion del contenedor seguia marcando
            # 1.890,9 s por los AAC. Las dos comprobaciones de arriba lo daban por
            # bueno.
            #
            # Lo cazaba audio_recap.ps1 desde FUERA, pero SOLO EL. Por la cola normal
            # de audio, por 'encode.ps1 -SubsOnly' (que tambien copia el video de un
            # origen ajeno) y por cualquier reconstructor futuro, el fichero se habria
            # dado por bueno. La guarda va AQUI, que es donde vive el riesgo, y no en
            # uno de los que llaman.
            #
            # Fail-safe: si no cuadra se lanza, el catch conserva el fichero tal cual
            # y como mucho se pierde el arreglo de la pantalla negra. Nunca al reves.
            #
            # La mide Get-DurVideo (este mismo fichero). Ver la nota de mas arriba.
            $v0 = Get-DurVideo $File
            $v1 = Get-DurVideo $tmpOut
            if ($v0 -le 0 -or $v1 -le 0) {
                throw ("no se puede medir la duracion del video (origen {0}s, reconstruido {1}s): no se sustituye a ciegas" -f $v0, $v1)
            }
            # TOLERANCIA 3 s, la misma que audio_recap.ps1 y por la misma razon: lo
            # que se comparan son ETIQUETAS, y tienen un ruido propio de un segundo
            # largo (medido en 'La soga (1948)': 24 fotogramas de diferencia con el
            # video MD5-identico). Lo que hay que cazar aqui son MINUTOS.
            if ([math]::Abs($v0 - $v1) -le 3.0) { break }

            # NO CUADRA. Si aun no lo hemos intentado, se rehace CONSERVANDO los
            # timestamps del origen. No es rendirse: el contenedor se reconstruye
            # igual -clusters, cues, indice, todo nuevo-, lo unico que se toma del
            # fichero de partida es CUANDO va cada fotograma. Y es justo lo que
            # necesitan los ficheros con huecos, donde no existe ningun framerate
            # que los describa.
            if (-not $reintentadoTs -and $tsFiles.Count -gt 0) {
                Log ("  el video se desplaza {0:N1}s al regenerar los timestamps ({1:N1}s -> {2:N1}s)." -f [math]::Abs($v0-$v1), $v0, $v1)
                Log "  Se rehace conservando los timestamps del origen (el fichero tiene huecos en su linea de tiempo)."
                $reintentadoTs = $true
                $conservandoTs = $true
                # Se dice CUANTOS --timestamps se van a aplicar. Sin esto, un
                # reintento que no cambia nada es indistinguible de uno que si
                # se aplico y no basto, y eso son horas de diagnostico.
                Log ("  timestamps disponibles: {0} pista(s) de video" -f $tsFiles.Count)
                Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
                if ($OnProgress) { & $OnProgress 70.0 }
                $ultMux = -1
                continue
            }
            throw ("la duracion del VIDEO no cuadra: {0:N1}s antes y {1:N1}s despues, y conservar los timestamps tampoco lo arregla." -f $v0, $v1)
        }

        # DURACION DEL CONTENEDOR: ASIMETRICA (29/08/2026). Antes era un valor
        # absoluto con 1 s de margen, y eso rechazaba reconstrucciones BUENAS.
        # Medido en 'Escape de Absolom (1994)':
        #     contenedor original 7.087,388 s
        #     pista mas larga     7.085,959 s (el video)
        # o sea que la cabecera del origen declaraba 1,43 s MAS de lo que dura
        # nada de lo que hay dentro. mkvmerge escribe la duracion real y sale
        # 7.086,0 s: la reconstruccion no acorta nada, CORRIGE la cabecera.
        #
        # Que se acorte un poco es entonces legitimo; que se ALARGUE no lo es.
        # Y quien manda de verdad sobre el reescalado de tiempo es la
        # comprobacion de la duracion del VIDEO de mas abajo, que es la que caza
        # los framerates mal declarados. Esta se queda como red gruesa: coge un
        # audio que se hubiera quedado corto sin que el video se entere.
        $d0 = [double]$json.container.properties.duration
        $d1 = [double]$chk.container.properties.duration
        if (($d1 - $d0) -gt 1e9) {
            throw ("el reconstruido dura MAS que el origen: {0:N1}s vs {1:N1}s" -f ($d0/1e9),($d1/1e9))
        }
        if (($d0 - $d1) -gt 3e9) {
            # ANTES DE RECHAZAR: puede que la cabecera del ORIGEN estuviera
            # inflada. El invariante bueno no es lo que el origen DECLARA, sino
            # lo que dura su pista MAS LARGA -que es lo que mkvmerge escribe al
            # reconstruir-. Medido en 'Escape de Absolom (1994)': declaraba
            # 7.087,4 s con la pista mas larga en 7.086,0 s, y en 'Amor en
            # conserva' la diferencia llegaba a 26,9 s.
            #
            # Solo se mide AQUI, cuando el chequeo barato ya ha fallado: en el
            # caso normal no cuesta nada. Y no relaja nada de verdad, porque el
            # reescalado de tiempo lo caza la comprobacion del VIDEO de ARRIBA,
            # que ya ha pasado para llegar hasta esta linea.
            $maxT = 0.0
            $nPorTipo = @{}
            foreach ($tk in $json.tracks) {
                $ty = "$($tk.type)"
                if (-not $nPorTipo.ContainsKey($ty)) { $nPorTipo[$ty] = 0 }
                $sel = "{0}:{1}" -f $ty.Substring(0,1), $nPorTipo[$ty]
                $nPorTipo[$ty] = $nPorTipo[$ty] + 1
                $tg = (& $FFPROBE -v error -select_streams $sel -show_entries stream_tags -of default=nw=1 -- $File 2>$null) | Out-String
                if ($tg -match '(?im)^TAG:DURATION[^=]*=(\d+):(\d+):(\d+(?:[.,]\d+)?)') {
                    $sg = ConvertTo-DoubleInv $Matches[3]; if ($null -eq $sg) { $sg = 0.0 }
                    $dd = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + $sg
                    if ($dd -gt $maxT) { $maxT = $dd }
                }
            }
            if ($maxT -gt 0 -and (($maxT * 1e9) - $d1) -le 3e9) {
                Log ("  la cabecera del origen declaraba {0:N1}s pero su pista mas larga dura {1:N1}s: el reconstruido ({2:N1}s) esta bien" -f ($d0/1e9), $maxT, ($d1/1e9))
            } else {
                throw ("el reconstruido se ha quedado corto: {0:N1}s vs {1:N1}s (pista mas larga del origen: {2:N1}s)" -f ($d0/1e9),($d1/1e9),$maxT)
            }
        }

        # SUSTITUCION SEGURA. La logica -y la historia larga de por que hace
        # falta- vive en Move-FicheroEnSitio (atmos-lib.ps1), en UN solo sitio:
        # esta misma sustitucion estaba escrita a mano en cinco puntos del
        # repositorio y de tres formas distintas, y una de ellas destruyo una
        # pelicula de 7,09 GB el 29/08/2026. Resumen: nunca se borra el destino
        # antes de tener el sustituto colocado; el original se aparta con un
        # renombrado, se comprueba, y solo entonces se tira.
        $aparte = $File + ".viejo"
        $sw = Move-FicheroEnSitio -Nuevo $tmpOut -Destino $File
        if ($sw.Aviso) { Log "  aviso: $($sw.Aviso)" }
        if (-not $sw.Ok) { throw $sw.Motivo }
        Log ("Contenedor reconstruido (extract+mkvmerge): {0} pistas, sin recodificar" -f $chk.tracks.Count)
        return $true
    } catch {
        Log "AVISO: la reconstruccion del contenedor fallo - se conserva el fichero tal cual"
        Log "  motivo: $($_.Exception.Message)"
        # El motivo tambien FUERA, para quien llama (29/08/2026). La funcion solo
        # devuelve $true/$false, asi que el driver escribia en su estado un
        # generico "Rebuild-Container devolvio false" y el porque se quedaba
        # unicamente en el log: para saber que le pasaba a una pelicula concreta
        # habia que ir a buscarla a mano entre miles de lineas.
        $global:UltimoMotivoRebuild = $_.Exception.Message
        return $false
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        # El reconstruido puede vivir FUERA de $work (junto al destino) desde el
        # 19/08/2026: si quedo a medias por un fallo, hay que barrerlo aparte o se
        # queda un fichero de 10 GB en la carpeta de salida. El caso de "lo mataron
        # a lo bruto" -donde este finally no corre- lo cubre Clear-JobTemps, que
        # borra el hermano ._rebuild.mkv de la salida parcial que apunte el marcador.
        #
        # SOLO SI EL DESTINO ESTA EN SU SITIO (29/08/2026). Antes se borraba sin
        # mirar, y ese borrado a ciegas fue el tercer paso de la cadena que
        # destruyo 'El cortador de cesped': cuando el destino ya no existe, ESTE
        # fichero es la unica copia que queda. Si pasa, se dice ALTO y se deja
        # ahi: un huerfano de 10 GB se borra a mano en un segundo, una pelicula
        # perdida no se recupera.
        if ($tmpOut -and $tmpOut -ne $File -and (Test-Path -LiteralPath $tmpOut)) {
            if (Test-Path -LiteralPath $File) {
                # CON REINTENTOS: si el handle que impidio el movimiento sigue
                # abierto, este borrado tambien falla, y callarse deja un huerfano
                # de 10-40 GB en la carpeta de la pelicula -donde ningun barrido
                # de temporales lo alcanza, porque no vive ni en $Tmp ni en
                # $BigTmp-. Visto en la prueba del 29/08/2026.
                $fuera = $false
                for ($rr = 1; $rr -le 5 -and -not $fuera; $rr++) {
                    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
                    $fuera = -not (Test-Path -LiteralPath $tmpOut)
                    if (-not $fuera -and $rr -lt 5) { Start-Sleep -Milliseconds 700 }
                }
                if (-not $fuera) { Log "AVISO: no se ha podido borrar $tmpOut - borralo a mano (no es la pelicula, es la reconstruccion sobrante)" }
            } else {
                Log "AVISO: NO borro $tmpOut porque el destino NO existe."
                Log "  Ese fichero puede ser la unica copia que queda. Revisalo a mano."
            }
        }
        # Y el original apartado: si el destino falta, se devuelve a su nombre.
        if ($aparte -and (Test-Path -LiteralPath $aparte)) {
            if (Test-Path -LiteralPath $File) {
                Remove-Item -LiteralPath $aparte -Force -ErrorAction SilentlyContinue
            } else {
                Move-Item -LiteralPath $aparte -Destination $File -ErrorAction SilentlyContinue
                Log "AVISO: el destino faltaba; se ha restaurado el original desde $aparte"
            }
        }
    }
}
