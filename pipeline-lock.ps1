<#
============================================================================
 pipeline-lock.ps1  -  Plomeria COMPARTIDA de los watchers
============================================================================
 Lo dot-sourcean encode-watch.ps1, audio-watch.ps1 y subs-watch.ps1 (y tiene su
 equivalente en Python para el remux, en webpanel/app.py).

 Contiene, por este orden:
   - Enter-PipelineLock / Exit-PipelineLock : el lock ATOMICO, para garantizar
     que solo UN pipeline trabaja a la vez. Es el motivo original del fichero.
   - Test-PipelinePaused                    : la pausa global de mantenimiento.
   - Test-PipelineLockBusy                  : comprobacion barata y orientativa.
   - Clear-ProcessedSources                 : red de seguridad de espacio en la
     unidad de las colas (vivia suelta en encode-watch.ps1 hasta el 05/08/2026).
   - Clear-JobTemps                         : barrido post-trabajo (salida
     parcial + temporales). Vivia COPIADO en los tres watchers hasta el
     19/08/2026; ver el comentario de la funcion para lo que costo.

 El nombre se ha quedado corto -esto ya no es solo el lock- pero se conserva
 porque hay cuatro ficheros apuntando aqui y renombrarlo no compra nada.

 POR QUE EXISTE ESTE FICHERO (04/08/2026)
 ----------------------------------------
 Los tres watchers hacian esto, cada uno con su copia:

     if (Test-Path $LockFile) { ...esperar... }     # 1) comprobar
     ...
     $PID | Set-Content -LiteralPath $LockFile      # 2) escribir

 Entre el paso 1 y el 2 hay una ventana, y los watchers sondean cada 5 s. Si
 al terminar un trabajo hay cola en DOS pipelines, los dos ven el lock libre
 casi a la vez, los dos escriben su PID y los dos siguen adelante. El fichero
 se queda con el PID del ultimo, pero AMBOS creen que lo tienen.

 Paso de verdad, y se pudo reconstruir entera:
   17:52:44  arranca el trabajo de AUDIO de "Rompe Ralph"
   17:52:45  arranca el trabajo de VIDEO de "Evil Dead Burn"   <- 1 segundo
   18:16:11  termina el de video -> su Clean-JobLeftovers barre G:\MediaTmp
             con los patrones 'thd_*' y 'damf_*'... que son tambien los del
             trabajo de audio que seguia vivo
   18:37     truehdd termina bien y su DAMF ya no existe -> "no genero DAMF"
 Resultado: 45 min de truehdd tirados y la pista se copio sin convertir. No se
 perdio calidad (el fallback copia el original), pero el trabajo se perdio.

 Y habia un peligro peor detras: los temporales se nombran con un sello de
 tiempo AL SEGUNDO (thd_20260804_175244_0.thd). Esos dos trabajos arrancaron
 con 1 segundo de diferencia; si llegan a coincidir en el mismo segundo,
 los dos pipelines escriben en EL MISMO fichero temporal y el resultado no
 seria un trabajo perdido sino audio corrupto sin ningun aviso.

 LA SOLUCION: que el sistema de ficheros haga la comprobacion y la creacion en
 un solo paso indivisible. [System.IO.FileMode]::CreateNew falla si el fichero
 ya existe, y esa operacion es atomica: gana exactamente uno.

 Va en un fichero APARTE y compartido a proposito. Copiar la funcion en los
 tres watchers es exactamente lo que ya paso con New-DeeAtmosXml y con el motor
 de audio, y hubo que deshacerlo: tres copias condenadas a divergir.

 NOTA: fichero en ASCII puro (codigo Y comentarios).
============================================================================
#>

# -- Rutas compartidas ------------------------------------------------------
# De aqui sale $MediaBoxBigTmp (y $MediaBoxTmp). Lo cargan tambien atmos-lib.ps1
# y, entre las dos, cubren los siete scripts del pipeline. Si el fichero no
# estuviera, se usa el valor de siempre: nadie debe quedarse sin arrancar por
# esto, pero tampoco queremos que la ruta se decida en siete sitios.
$PathsLib = Join-Path $PSScriptRoot 'mediabox-paths.ps1'
if (-not (Test-Path -LiteralPath $PathsLib)) { $PathsLib = 'C:\scripts\mediabox-paths.ps1' }
if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
if (-not $MediaBoxBigTmp) { $MediaBoxBigTmp = 'G:\MediaTmp' }
if (-not $MediaBoxTmp)    { $MediaBoxTmp    = 'C:\Media\tmp' }

# -- Plan de energia mientras se trabaja -----------------------------------
# MEDIDO el 16/08/2026 sobre el mismo clip 4K, encode QSV, tres pasadas cada uno:
#   Equilibrado      52,1 / 50,0 / 45,8 s   (media 49,3 ; dispersion 6,3 s)
#   Alto rendimiento 45,9 / 46,1 / 46,0 s   (media 46,0 ; dispersion 0,2 s)
# El PICO es el mismo (45,8 contra 45,9): lo que hace Equilibrado no es bajar el
# techo, es estrangular A RATOS. De ahi el 6,7 % de media y, sobre todo, que los
# tiempos dejen de ser reproducibles -que es lo que enturbia cualquier medicion-.
#
# NO se deja Alto rendimiento fijo: este equipo esta encendido todo el dia y casi
# siempre ocioso, y eso seria pagar consumo 24 h por ~72 s por pelicula. Se pone
# al coger el lock y se quita al soltarlo.
#
# El fichero con el plan anterior NO se sobrescribe si ya existe: asi, si un
# trabajo muere a lo bruto (taskkill /F, corte de luz) y el siguiente coge el
# lock, se sigue recordando el plan ORIGINAL y se acaba restaurando igual.
# La ruta sale de $MediaBoxTmp, que este mismo fichero acaba de resolver 17
# lineas mas arriba. Estaba escrita a mano aqui: la misma divergencia silenciosa
# que mediabox-paths.ps1 existe para matar, y encima en el fichero que ya tenia
# la variable buena a mano (02/09/2026).
$PowerPlanPrevFile = Join-Path $MediaBoxTmp 'powerplan_prev'
$PowerPlanHigh     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'   # Alto rendimiento

function Get-ActivePowerPlan {
    try {
        $s = (powercfg /getactivescheme) 2>$null
        if ("$s" -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            return $Matches[1]
        }
    } catch { }
    return $null
}

function Set-PipelinePowerPlan {
    # Best-effort: si powercfg falla o no existe el plan, se sigue trabajando.
    try {
        $actual = Get-ActivePowerPlan
        if (-not $actual) { return }
        if ($actual -eq $PowerPlanHigh) { return }          # ya estaba
        if (-not (Test-Path -LiteralPath $PowerPlanPrevFile)) {
            [System.IO.File]::WriteAllText($PowerPlanPrevFile, $actual,
                (New-Object System.Text.UTF8Encoding($false)))
        }
        powercfg /setactive $PowerPlanHigh 2>$null | Out-Null
    } catch { }
}

function Restore-PipelinePowerPlan {
    try {
        if (-not (Test-Path -LiteralPath $PowerPlanPrevFile)) { return }
        $prev = @(Get-Content -LiteralPath $PowerPlanPrevFile -ErrorAction Stop)[0]
        if ($prev -and $prev -match '^[0-9a-fA-F\-]{36}$') {
            powercfg /setactive $prev 2>$null | Out-Null
        }
        Remove-Item -LiteralPath $PowerPlanPrevFile -Force -ErrorAction SilentlyContinue
    } catch { }
}


function Test-LockOwnerAlive {
    <#
      $true solo si el proceso que escribio el lock SIGUE VIVO Y ES EL MISMO.

      POR QUE NO BASTA EL PID (01/09/2026). El lock guardaba solo el numero de
      proceso, y eso tiene un agujero que se abre justo en el peor momento: si
      la maquina se apaga en sucio con un trabajo en marcha -y aqui pasa: hay
      cuelgues documentados-, el fichero sobrevive al reinicio con un PID
      muerto. Normalmente Enter-PipelineLock lo recoge como huerfano y no pasa
      nada. Pero Windows REUTILIZA los PID, y tras un arranque los reparte desde
      numeros bajos: si ese PID se lo ha quedado cualquier otro proceso,
      Get-Process lo encuentra vivo y el lock se da por ocupado PARA SIEMPRE.

      Lo que ocurre entonces es lo peor de todo: nada falla. Los tres watchers
      hacen 'break' en cada vuelta, el panel no arranca remuxes, y
      Update-StalePiece tampoco relanza nada porque Test-PipelineIdle le dice
      que hay trabajo. El pipeline se para del todo y no hay una sola linea en
      ningun log que lo explique.

      La hora de arranque del proceso cierra el agujero: un PID reciclado tiene
      OTRA hora de arranque, asi que se distingue del original sin ambiguedad.

      COMPATIBLE CON EL FORMATO VIEJO: un lock de una sola linea (solo PID) se
      trata como antes. Solo hay uno vivo a la vez y stop-mediabox.ps1 lo borra,
      asi que el formato viejo desaparece solo.
    #>
    param([Parameter(Mandatory=$true)][string]$LockFile)

    $lineas = @()
    try { $lineas = @(Get-Content -LiteralPath $LockFile -ErrorAction Stop) } catch { return $false }
    if ($lineas.Count -eq 0) { return $false }

    $lpid = "$($lineas[0])".Trim()
    if (-not $lpid) { return $false }
    $p = Get-Process -Id $lpid -ErrorAction SilentlyContinue
    if (-not $p) { return $false }          # muerto: huerfano

    if ($lineas.Count -lt 2) { return $true }   # formato viejo: como antes

    $ticks = "$($lineas[1])".Trim()
    if (-not $ticks) { return $true }
    try {
        # Si no coinciden, ESE pid es de otro proceso que ha reciclado el numero.
        if ($p.StartTime.Ticks -ne [long]$ticks) { return $false }
    } catch {
        # Hay procesos cuyo StartTime no se deja leer (permisos). Ante la duda,
        # OCUPADO: bloquear de mas es recuperable, entrar dos veces no.
        return $true
    }
    return $true
}

function Enter-PipelineLock {
    <#
      Intenta coger el lock. Devuelve $true solo si lo ha conseguido.
      Es ATOMICO: si dos procesos llaman a la vez, exactamente uno recibe $true.

      Recupera locks HUERFANOS (los de un proceso que murio sin soltarlo, p.ej.
      por taskkill /F o por un corte de corriente): si el PID de dentro ya no
      existe, borra el fichero y reintenta UNA vez.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$LockFile
    )

    for ($intento = 1; $intento -le 2; $intento++) {
        try {
            # CreateNew = "crealo, y falla si ya existe". La comprobacion y la
            # creacion son una sola operacion del sistema de ficheros: aqui esta
            # todo el arreglo.
            $fs = [System.IO.File]::Open($LockFile,
                                         [System.IO.FileMode]::CreateNew,
                                         [System.IO.FileAccess]::Write,
                                         [System.IO.FileShare]::Read)
            try {
                # PID + hora de arranque (ticks). La segunda linea es la que
                # distingue este proceso de otro que reciclara su PID tras un
                # reinicio sucio. Ver Test-LockOwnerAlive.
                $miInicio = ''
                try { $miInicio = (Get-Process -Id $PID).StartTime.Ticks } catch { }
                $bytes = [System.Text.Encoding]::ASCII.GetBytes("$PID`n$miInicio")
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush()
            } finally {
                $fs.Dispose()
            }
            # Ya es nuestro: se sube el plan de energia mientras dure el trabajo.
            Set-PipelinePowerPlan
            return $true
        } catch [System.IO.IOException] {
            # El fichero ya existe (o no se pudo crear). Ver de quien es.
            $lpid = $null
            try {
                $lpid = @(Get-Content -LiteralPath $LockFile -ErrorAction Stop)[0]
            } catch {
                # Ni siquiera se puede leer: no es nuestro, no insistimos.
                return $false
            }
            if (Test-LockOwnerAlive $LockFile) {
                return $false      # ocupado de verdad por un proceso vivo
            }
            # Huerfano: limpiar y reintentar. Si en el reintento otro se nos
            # adelanta, el CreateNew volvera a fallar y devolveremos $false, que
            # es lo correcto.
            Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
        } catch {
            # Cualquier otra cosa (permisos, carpeta inexistente): no cogerlo.
            return $false
        }
    }
    return $false
}

function Exit-PipelineLock {
    <#
      Suelta el lock, pero SOLO si es nuestro. Comprobarlo importa: si por lo
      que sea el fichero ya lo tiene otro, borrarlo lo dejaria trabajando sin
      proteccion, que es justo el fallo que este modulo viene a arreglar.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$LockFile
    )
    try {
        $lpid = @(Get-Content -LiteralPath $LockFile -ErrorAction Stop)[0]
        if ("$lpid".Trim() -eq "$PID") {
            Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
            # El plan de energia vuelve a lo que hubiera. Va DESPUES de soltar el
            # lock: si powercfg se atasca, que no retenga el lock por ello.
            Restore-PipelinePowerPlan
        }
    } catch {
        # No existe o no se puede leer: nada que soltar.
    }
}

function Test-PipelinePaused {
    <#
      Pausa GLOBAL: si existe C:\Media\tmp\pipeline_paused, NINGUN watcher coge
      trabajo nuevo. Lo que ya este en marcha sigue hasta terminar.

      Anadida el 04/08/2026. Antes solo existia 'encode_paused', y solo lo miraba
      encode-watch.ps1, asi que "pausar" pausaba unicamente el video: para tocar
      los watchers habia que apartar la cola de audio a mano a una subcarpeta.

      NO se reutiliza 'encode_paused' a proposito: ese fichero lo crea el boton
      STOP del panel (mata el encode en curso y evita que el watcher arranque el
      siguiente), asi que es una pausa DEL VIDEO. Hacer que los otros pipelines
      lo miraran significaria que parar un encode congela tambien la cola de
      audio, que no es lo que espera nadie. Son dos conceptos distintos y tienen
      dos ficheros distintos.

      Uso tipico (mantenimiento, reiniciar watchers con trabajo en cola):
          New-Item -ItemType File 'C:\Media\tmp\pipeline_paused'
          ... esperar a que acabe lo que hubiera en marcha, hacer los cambios ...
          Remove-Item 'C:\Media\tmp\pipeline_paused'
    #>
    param(
        [string]$Tmp = 'C:\Media\tmp'
    )
    return (Test-Path -LiteralPath (Join-Path $Tmp 'pipeline_paused'))
}

function Test-PipelineLockBusy {
    <#
      Comprobacion BARATA de "hay alguien trabajando", para saltarse trabajo
      preparatorio (esperas de estabilizacion, sondeos) cuando esta claro que
      toca esperar.
      OJO: esto NO sirve para decidir si se puede entrar. Es orientativo y tiene
      la misma carrera de siempre; la unica forma valida de coger el lock es
      Enter-PipelineLock, que es atomico.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$LockFile
    )
    if (-not (Test-Path -LiteralPath $LockFile)) { return $false }
    # Mismo criterio que Enter-PipelineLock, y por eso comparte funcion: si
    # los dos no coincidieran, uno diria 'ocupado' y el otro entraria.
    return (Test-LockOwnerAlive $LockFile)
}

function Clear-ProcessedSources {
    <#
      Recupera espacio mandando a la PAPELERA los fuentes de una carpeta _running
      cuyo trabajo ya termino BIEN. Solo actua si el disco baja del umbral.

      Vivia dentro de encode-watch.ps1 y solo protegia a la cola de VIDEO. El
      05/08/2026 se movio aqui para que subs-watch tambien la tenga: subs_running
      acumula fuentes completos igual de grandes (26-60 GB) y no tenia ninguna red.
      Se MUEVE en vez de copiarse por la razon de siempre en este proyecto: tres
      copias de la misma funcion estan condenadas a divergir.

      Tres condiciones antes de tocar un fichero de 26-60 GB, porque un borrado
      equivocado aqui es irreparable:

        1. Espacio por debajo de -MinFreeGB. Con margen no hace NADA: los fuentes
           se quedan donde estan para poder comparar con la salida.
        2. El fichero tiene un registro de EXITO en completed.jsonl. Ese fichero
           solo se escribe cuando encode.ps1 termina bien, asi que es la prueba de
           que su salida existe. No vale mirar la carpeta de salida: el resultado
           se mueve a la biblioteca al poco de terminar y con otro nombre.
           (encode.ps1 -SubsOnly escribe su registro igual, con mode='subs_only',
           asi que este criterio vale tambien para la cola de subtitulos.)
        3. Tiene mas de -MinAgeHours horas, por si se esta revisando algo recien
           hecho.

      BORRADO DEFINITIVO, no papelera (cambiado el 06/08/2026). Antes iba a la
      papelera como red de seguridad, pero eso ANULABA la funcion entera: en
      Windows mover a la papelera NO libera espacio -el fichero sigue en
      C:\$Recycle.Bin-, y esta funcion existe justo para recuperar espacio.
      Consecuencia concreta: el bucle de abajo corta en cuanto AvailableFreeSpace
      vuelve por encima del umbral, y con la papelera ese valor no subia nunca.
      O sea que habria borrado TODAS las fuentes elegibles -no solo las
      necesarias- y ademas habria terminado avisando de que seguia sin espacio.

      La red de seguridad de verdad son las tres condiciones de arriba, sobre
      todo el registro de EXITO en completed.jsonl: no se borra nada de lo que no
      conste que su salida existe.

      Llamarla con el LOCK COGIDO: ningun trabajo puede estar usando esos ficheros.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Running,
        [Parameter(Mandatory=$true)][string]$CompletedJsonl,
        [int]$MinFreeGB   = 100,
        [int]$MinAgeHours = 2
    )

    if (-not (Test-Path -LiteralPath $Running)) { return }
    $raiz  = (Get-Item -LiteralPath $Running).Root.FullName
    $libre = (New-Object System.IO.DriveInfo($raiz)).AvailableFreeSpace
    if ($libre -ge ($MinFreeGB * 1GB)) { return }

    Write-Host ("  [barrido] {0:N1} GB libres en {1} (umbral {2} GB): busco fuentes ya procesados." -f `
                ($libre/1GB), $raiz, $MinFreeGB)

    # Fuentes con trabajo terminado con exito. Una linea rota del jsonl no debe
    # tumbar el barrido, de ahi el try por linea.
    $hechos = @{}
    foreach ($l in @(Get-Content -LiteralPath $CompletedJsonl -ErrorAction SilentlyContinue)) {
        try { $s = (ConvertFrom-Json $l).source; if ($s) { $hechos[[string]$s] = $true } } catch { }
    }
    if ($hechos.Count -eq 0) { Write-Host "  [barrido] sin registros de exito; no toco nada."; return }

    $limite = (Get-Date).AddHours(-$MinAgeHours)
    $candidatos = @(Get-ChildItem -LiteralPath $Running -File -ErrorAction SilentlyContinue |
                    Where-Object { $hechos.ContainsKey($_.FullName) -and $_.LastWriteTime -lt $limite } |
                    Sort-Object LastWriteTime)

    if ($candidatos.Count -eq 0) {
        Write-Host "  [barrido] no hay fuentes que cumplan las condiciones. Espacio sin recuperar."
        return
    }

    # Del mas antiguo al mas nuevo, y se para en cuanto se recupera el margen:
    # no se borra mas de lo necesario.
    $total = 0L
    foreach ($f in $candidatos) {
        if ((New-Object System.IO.DriveInfo($raiz)).AvailableFreeSpace -ge ($MinFreeGB * 1GB)) { break }
        $gb = $f.Length / 1GB
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $total += $f.Length
            Write-Host ("  [barrido] borrado: {0} ({1:N1} GB)" -f $f.Name, $gb)
        } catch {
            Write-Host ("  [barrido] no se pudo borrar {0}: {1}" -f $f.Name, $_.Exception.Message)
        }
    }
    $libreFin = (New-Object System.IO.DriveInfo($raiz)).AvailableFreeSpace
    Write-Host ("  [barrido] recuperados {0:N1} GB; quedan {1:N1} GB libres." -f ($total/1GB), ($libreFin/1GB))
    if ($libreFin -lt ($MinFreeGB * 1GB)) {
        Write-Host "  [barrido] AVISO: sigue por debajo del umbral y ya no hay fuentes elegibles."
    }
}

# ---------------------------------------------------------------------------
# LISTA UNICA de patrones de temporales de trabajo.
#
# Es la MISMA que usa stop-mediabox.ps1, y ese es justo el punto: hasta el
# 19/08/2026 habia CUATRO listas (una por watcher mas la del parador) y ya
# habian divergido, con consecuencias:
#   - '_MEI*' (los 20 MB que deew descomprime por ejecucion) estaba en
#     encode-watch y en stop-mediabox, pero NO en audio-watch... que es el
#     pipeline que MAS deew ejecuta. Con una cola larga de audio, esos
#     huerfanos se acumulaban sin que nadie los barriera.
#   - 'vid_*' (el temporal de video del solapamiento, ~15 GB en 4K) solo
#     estaba en encode-watch.
#   - subs-watch barria 4 patrones de 16 y ademas no contaba los GB, asi que
#     su barrido no aparecia en el log ni cuando liberaba algo.
# Una sola lista compartida es la unica forma de que esto no vuelva a pasar.
#
# Ampliar la lista es SEGURO: este barrido corre siempre con el lock cogido,
# asi que no hay ningun otro pipeline con temporales en vuelo y todo lo que
# case es basura. Los patrones 'a_*'/'d_*' exigen la letra MAS el guion bajo,
# asi que no tocan audio_status ni audio_pid.
#
# '_rmx_*' NO va aqui a proposito: son los directorios de la MEDICION de sync
# del panel, que es un sondeo y corre SIN lock. Barrerla desde un watcher
# podria llevarse una medicion en marcha. De esa solo se ocupa
# stop-mediabox.ps1, que antes ha matado el panel.
#
# '_recon_*', 'sf_*' y 'sfsrt_*' ENTRAN EL 26/08/2026, y el primero era el
# agujero mas caro de la lista:
#   - '_recon_*' es la carpeta de trabajo de Rebuild-Container (encode.ps1),
#     donde se EXTRAEN TODAS LAS PISTAS del MKV, video incluido: 10-20 GB por
#     pelicula. Su propio finally la borra, pero ese finally NO corre con el
#     taskkill /F /T que usan el Stop y el Skip del panel, y la reconstruccion
#     dura 13-20 min (el 25-40 % del trabajo): la ventana es enorme. Sin este
#     patron NADIE la barria; comprobado con un grep sobre todo el repositorio,
#     que devolvia una sola linea: la que la crea.
#   - 'sf_*' es la carpeta de trabajo de subsfetch y 'sfsrt_*' los .srt que se
#     mueven fuera de ella. Pequenyos, pero exactamente el mismo caso.
# OJO: hacen falta los DOS, 'sf_*' y 'sfsrt_*'. 'sf_*' exige la barra baja, asi
# que no casa con 'sfsrt_...'.
$PipelineTempPatterns = @(
    'thd_*','damf_*','ddp_*','job_*','dee_*','deetemp_*','deew_*','src_*',
    'a_*','d_*','ocr_*','pgs2srt_*','encode_ff_stderr_*','remux_*','vid_*',
    '_MEI*','_recon_*','sf_*','sfsrt_*'
)

function Move-AEnCurso {
    <#
      Mueve el fichero de la COLA a la carpeta de EN CURSO. Devuelve $true solo
      si el fichero esta de verdad en su destino. No lanza nunca.

      POR QUE EXISTE (31/08/2026). Los tres watchers hacian esto mismo con una
      linea identica y suelta:

          Move-Item -LiteralPath $f.FullName -Destination $dest -Force

      y detras, sin comprobar nada, lanzaban el encoder sobre $dest. Dos fallos
      en la misma linea:

        1. SIN -ErrorAction Stop, y los watchers corren con
           $ErrorActionPreference='Continue'. Un movimiento que falla -por un
           handle abierto, que es lo normal cuando algo acaba de copiar el
           fichero- NO detiene nada: se lanzaba el encoder sobre una ruta que no
           existia y el trabajo moria mas adelante con un error que no señalaba
           a la causa.

        2. '-Force' NO es atomico: BORRA el destino y despues mueve. Si ahi
           habia un huerfano de un trabajo interrumpido -la misma pelicula, 30
           GB-, se perdia antes de saber si el movimiento iba a funcionar. Es la
           misma forma exacta que destruyo una pelicula el 29/08/2026 desde
           Rebuild-Container.

      QUE HACE EN SU LUGAR: si el destino ya existe NO lo borra, lo APARTA con
      un sello de tiempo y lo dice en el log. Un huerfano se borra a mano en un
      segundo; una pelicula perdida no se recupera. Y perder la carrera aqui no
      es grave: el fichero se queda en la cola y se reintenta en la vuelta
      siguiente, que es justo lo que dicen los comentarios de los tres watchers.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Origen,
        [Parameter(Mandatory=$true)][string]$Destino
    )
    if (-not (Test-Path -LiteralPath $Origen)) {
        Write-Host "  [cola] el fichero ya no esta en la cola: $Origen"
        return $false
    }
    if (Test-Path -LiteralPath $Destino) {
        # No se borra: se aparta. Y se dice, porque llegar aqui significa que el
        # barrido de huerfanos del arranque no hizo su trabajo.
        $aparte = "{0}.huerfano-{1}" -f $Destino, (Get-Date -Format 'yyyyMMdd_HHmmss')
        try {
            Move-Item -LiteralPath $Destino -Destination $aparte -ErrorAction Stop
            Write-Host "  [cola] AVISO: ya habia un fichero en $Destino; se ha apartado a $aparte (revisalo a mano)."
        } catch {
            Write-Host "  [cola] hay un fichero en $Destino y no se puede apartar: $($_.Exception.Message)"
            Write-Host "  [cola] no se toca nada; el trabajo sigue en la cola y se reintenta."
            return $false
        }
    }
    try {
        Move-Item -LiteralPath $Origen -Destination $Destino -ErrorAction Stop
    } catch {
        Write-Host "  [cola] no se ha podido mover a en-curso: $($_.Exception.Message)"
        Write-Host "  [cola] el trabajo sigue en la cola y se reintenta en la vuelta siguiente."
        return $false
    }
    # COMPROBAR EL EFECTO, no fiarse de que la orden no protestara.
    if (-not (Test-Path -LiteralPath $Destino)) {
        Write-Host "  [cola] el movimiento no dio error pero el fichero no esta en $Destino."
        return $false
    }
    return $true
}

function Move-ARescate {
    <#
      Devuelve a la cola un fichero que se quedo en la carpeta de trabajo, y
      COMPRUEBA que llego. Devuelve $true solo si esta de verdad en la cola.

      POR QUE (02/09/2026). Los TRES watchers tenian esto copiado en su rescate
      de arranque, y los tres con la misma forma:

          Move-Item ... -Force -ErrorAction SilentlyContinue
          Write-Host "  [rescate] trabajo a medias devuelto a la cola: ..."

      o sea que anunciaban el rescate sin mirar si habia ocurrido. Si el
      movimiento falla -un handle todavia abierto, que es lo normal justo
      despues de un apagado sucio- el fichero se queda en _running, y ahi NO LO
      COGE NADIE: el rescate solo corre en el arranque y ya ha pasado. El log
      dice que se rescato y el trabajo desaparece del mapa.

      Es el mismo fallo, y el mismo arreglo, que ya obligaron a escribir
      Move-AEnCurso y Remove-ConReintento en este mismo fichero. Se quita
      ademas el -Force: el destino se comprueba antes, y -Force borraria lo que
      hubiera alli en vez de respetarlo.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Origen,
        [Parameter(Mandatory=$true)][string]$Cola,
        [Parameter(Mandatory=$true)][string]$Nombre,
        [string]$Etiqueta = 'rescate'
    )
    $destino = Join-Path $Cola $Nombre
    if (Test-Path -LiteralPath $destino) {
        Write-Host ("  [{0}] '{1}' sigue en la cola; dejo el de la carpeta de trabajo sin tocar." -f $Etiqueta, $Nombre)
        return $false
    }
    try {
        Move-Item -LiteralPath $Origen -Destination $destino -ErrorAction Stop
    } catch {
        Write-Host ("  [{0}] NO se ha podido devolver '{1}' a la cola: {2}" -f $Etiqueta, $Nombre, $_.Exception.Message)
        Write-Host ("  [{0}] Se queda en la carpeta de trabajo y NADIE lo va a coger. Muevelo a mano." -f $Etiqueta)
        return $false
    }
    if (-not (Test-Path -LiteralPath $destino)) {
        Write-Host ("  [{0}] el movimiento de '{1}' no dio error pero el fichero no esta en la cola." -f $Etiqueta, $Nombre)
        return $false
    }
    Write-Host ("  [{0}] trabajo a medias devuelto a la cola: {1}" -f $Etiqueta, $Nombre)
    return $true
}

function Remove-ConReintento {
    <#
      Borra un fichero y COMPRUEBA que se ha ido. Devuelve $true si ya no esta.

      POR QUE (26/08/2026, cazado en vivo). Clear-JobTemps hacia esto:

          Write-Host "  [clean] salida parcial borrada: $out"
          Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue

      o sea que anunciaba el borrado ANTES de intentarlo y se tragaba el fallo.
      Y falla de verdad: al panel se le para un trabajo con taskkill /F /T, pero
      Windows no cierra el handle de ffmpeg en el mismo instante, asi que el
      Remove-Item que viene detras choca con una violacion de comparticion. Pasado
      de verdad: quedo una salida a medias de 804 MB **con el nombre DEFINITIVO**
      en C:\Media\encoded, con el log diciendo "salida parcial borrada" al lado.

      Eso es lo peligroso: un fichero truncado con el nombre bueno es
      indistinguible de un encode terminado -sale en la lista de Completed del
      panel- y el original ya no esta para compararlo.

      Reintentos cortos porque el handle se suelta en un segundo o dos. Si aun asi
      no se puede, se dice ALTO en vez de callarse: preferimos un aviso a un
      fichero fantasma.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Ruta,
        [string]$Etiqueta = 'fichero',
        [int]$Intentos = 5,
        [int]$EsperaMs = 700
    )
    for ($i = 1; $i -le $Intentos; $i++) {
        Remove-Item -LiteralPath $Ruta -Force -Recurse -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Ruta)) {
            if ($i -eq 1) { Write-Host "  [clean] $Etiqueta borrado: $Ruta" }
            else          { Write-Host ("  [clean] $Etiqueta borrado al intento {0}: {1}" -f $i, $Ruta) }
            return $true
        }
        if ($i -lt $Intentos) { Start-Sleep -Milliseconds $EsperaMs }
    }
    Write-Host "  [clean] AVISO: NO se ha podido borrar $Etiqueta -> $Ruta"
    Write-Host "  [clean] Sigue ahi CON EL NOMBRE DEFINITIVO y esta A MEDIAS: no te fies"
    Write-Host "  [clean] de el aunque salga en Completed. Borralo a mano."
    return $false
}

function Get-ArgLine {
    <#
      Convierte un array de argumentos en la CADENA que espera
      Start-Process -ArgumentList, entrecomillando cada elemento que lo
      necesite.

      POR QUE HACE FALTA (04/09/2026). Start-Process -ArgumentList admite un
      array, pero NO lo entrecomilla: lo une con espacios tal cual. Con
      'El senyor de los anillos [UHDReescalado] (2001).mkv' el proceso hijo
      recibe una docena de argumentos sueltos, y en la prueba del watcher la
      palabra 'de' acabo aterrizando en -TargetMbps ('Cannot convert value
      "de" to type System.Double'). Como en esta biblioteca practicamente
      TODOS los nombres llevan espacios, habria fallado en todas.

      El operador de llamada '&' si lo hace bien, pero no sirve para lanzar
      algo en segundo plano y esperarlo despues, que es lo que necesita el
      watcher para tener dos ranuras.

      Se entrecomilla ante espacio, comilla o parentesis: los parentesis
      importan porque el hijo es otro pwsh y ahi '(2001)' es sintaxis.
    #>
    param([Parameter(Mandatory=$true)][string[]]$Argumentos)
    $partes = foreach ($a in $Argumentos) {
        $s = "$a"
        if ($s -match '[\s"()]') { '"' + ($s -replace '"', '\"') + '"' } else { $s }
    }
    return ($partes -join ' ')
}

function Clear-JobTemps {
    <#
      Barrido POST-TRABAJO, acabe como acabe el trabajo: exito, error o muerte
      por el Stop/Skip/Cancel del panel. El caso que importa es el ultimo: el
      panel mata con taskkill /F /T y PowerShell NO ejecuta ni el finally del
      script ni su limpieza, asi que quedan huerfanos la salida a medias y los
      temporales pesados (un DAMF son 12-21 GB, un vid_ en 4K unos 15).

      Hace dos cosas:
        1. Salida PARCIAL: el marcador <prefijo>_outfile lo escribe el script
           de trabajo al empezar y lo borra en TODAS sus salidas controladas.
           Si sigue ahi, al proceso lo mataron -> su salida esta a medias y se
           borra. Y como el muerto no pudo escribir su estado, se deja el panel
           en idle. SOLO en ese caso: si el script salio por su pie dejando
           status=error, ese error tiene que seguir viendose.
        2. Temporales de $PipelineTempPatterns, en las DOS carpetas. Desde el
           31/07/2026 el trabajo pesado vive en $BigTmp (otra unidad) y el
           estado en $Tmp; barrer solo $Tmp dejaria los DAMF de 30 GB ahi para
           siempre.

      LLAMARLA CON EL LOCK TODAVIA COGIDO. Si se soltara antes, otro pipeline
      podria entrar y sus temporales -recien creados- casarian con los
      patrones: exactamente el fallo del 04/08/2026 que se llevo por delante
      45 min de truehdd (ver la cabecera de este fichero).
    #>
    param(
        [Parameter(Mandatory=$true)][ValidateSet('encode','subs','audio')][string]$Prefix,
        [Parameter(Mandatory=$true)][string]$Tmp,
        [Parameter(Mandatory=$true)][string]$BigTmp
    )

    # UN MARCADOR POR RANURA (04/09/2026). Desde que encode.ps1 admite -Slot
    # puede haber 'encode_outfile' y 'encode2_outfile' a la vez. Barrer solo el
    # primero dejaria la salida A MEDIAS del otro trabajo en C:\Media\encoded,
    # con su nombre DEFINITIVO y con pinta de pelicula terminada: exactamente
    # el fallo que ya dejo un MKV incompleto ahi el 26/08.
    # El comodin recoge ademas el marcador de una ranura que se dejo de usar.
    # OJO: 'encode*_outfile' casa TAMBIEN con 'encode_outfile' (el * admite la
    # cadena vacia), asi que el caso de siempre sigue cubierto.
    foreach ($mk in @(Get-ChildItem -LiteralPath $Tmp -Filter "${Prefix}*_outfile" -File -ErrorAction SilentlyContinue)) {
        $marker = $mk.FullName
        $out = @(Get-Content -LiteralPath $marker -ErrorAction SilentlyContinue)[0]
        if ($out -and (Test-Path -LiteralPath $out)) {
            $null = Remove-ConReintento -Ruta $out -Etiqueta 'salida parcial'
        }
        # Temporal de la reconstruccion del contenedor (19/08/2026). Desde esa
        # fecha mkvmerge puede escribir el fichero reconstruido JUNTO AL DESTINO
        # -para que el move final sea un renombrado y no una copia de 10 GB entre
        # unidades-, o sea que vive fuera de $Tmp y de $BigTmp y estos patrones no
        # lo alcanzan. Su propio finally lo borra, pero ese finally NO corre
        # cuando matan el trabajo, que es justo el caso que cubre esta funcion.
        if ($out) {
            # Mismo nombre que construye Rebuild-Container: la ruta de salida MAS
            # el sufijo. Si se tocan, hay que tocar los dos.
            $reb = $out + "._rebuild.mkv"
            if (Test-Path -LiteralPath $reb) {
                $null = Remove-ConReintento -Ruta $reb -Etiqueta 'reconstruccion a medias'
            }
        }
        Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        # El 'idle' va al estado de LA MISMA ranura, no siempre al de la 1:
        # 'encode2_outfile' -> 'encode2_status'.
        $estado = Join-Path $Tmp ($mk.Name -replace '_outfile$', '_status')
        [System.IO.File]::WriteAllText($estado, 'status=idle',
            (New-Object System.Text.UTF8Encoding($false)))
    }

    # EL RECUENTO SUMA TAMBIEN LAS CARPETAS (02/09/2026).
    #
    # Esto era '$libGb += $t.Length' a secas, y varios de los patrones de la lista
    # casan con DIRECTORIOS: '_recon_*' (10-20 GB, todas las pistas extraidas de
    # una pelicula), 'dee_*', '_MEI*', 'sf_*'. Un DirectoryInfo NO TIENE la
    # propiedad Length, asi que sumaba $null EN SILENCIO -PowerShell no protesta-
    # y el log declaraba menos GB de los que acababa de liberar. Medido con una
    # carpeta de 5 MB y un fichero de 3: decia 2,86 MB tras borrar 7,63.
    #
    # Lo que se perdia no era un detalle: se dejaba de contar justo lo mas gordo,
    # que es lo unico por lo que uno mira esta linea. Y un log que miente es peor
    # que no tenerlo (es la razon por la que existe Remove-ConReintento, aqui al
    # lado). Es ademas una trampa ya conocida de este proyecto, escrita en la
    # skill de operaciones en lote; estaba en produccion igualmente.
    $libGb = 0
    foreach ($dir in @($Tmp, $BigTmp | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($pat in $PipelineTempPatterns) {
            foreach ($t in @(Get-ChildItem -LiteralPath $dir -Filter $pat -Force -ErrorAction SilentlyContinue)) {
                if ($t.PSIsContainer) {
                    # Recorrer la carpeta ANTES de borrarla, claro. Sin try/catch:
                    # con -ErrorAction SilentlyContinue el Get-ChildItem no lanza, y
                    # Measure-Object sobre un conjunto vacio devuelve .Sum = $null,
                    # que sumado no cambia nada (una carpeta vacia aporta 0). Un
                    # catch aqui solo serviria para tragarse algo sin decirlo.
                    $libGb += (Get-ChildItem -LiteralPath $t.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                               Measure-Object -Property Length -Sum).Sum
                } else {
                    $libGb += $t.Length
                }
                Remove-Item -LiteralPath $t.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($libGb -gt 1GB) { Write-Host ("  [clean] {0:N1} GB de temporales liberados" -f ($libGb/1GB)) }
}

# ---------------------------------------------------------------------------
# Ficheros que una cola NO va a procesar: avisar UNA vez, no callarse.
#
# Las colas de subtitulos y audio solo aceptan .mkv/.mp4/.m2ts/.ts/.mov, y la de
# video descarta una lista de extensiones. En los tres casos el fichero que no
# encaja se saltaba con un 'continue' MUDO: se quedaba en la carpeta para
# siempre, el bucle lo miraba cada 5 segundos, y nadie decia por que no pasaba
# nada. Un .avi o un .mpg en subs_queue desaparecia del mapa sin una linea.
#
# Es exactamente el fallo silencioso que este proyecto lleva meses quitando (ver
# la preferencia de fallar alto antes que degradar en silencio), asi que se avisa
# una vez POR FICHERO: sin spam, pero sin silencio. Si el fichero se retira y
# vuelve a caer, se vuelve a avisar.
$IgnoradosAvisados = @{}

function Write-ColaIgnora {
    param(
        [Parameter(Mandatory=$true)][string]$Nombre,
        [Parameter(Mandatory=$true)][string]$Motivo,
        [string[]]$Presentes = @()
    )
    if (-not $IgnoradosAvisados.ContainsKey($Nombre)) {
        Write-Host ("  [ignorado] {0}: {1}" -f $Nombre, $Motivo)
        $IgnoradosAvisados[$Nombre] = $true
    }
    # Olvidar los que ya no estan, para que un mismo nombre vuelva a avisar si
    # se deja caer otra vez. Sin esto la tabla crece y el aviso no se repite.
    if ($Presentes.Count -gt 0) {
        foreach ($k in @($IgnoradosAvisados.Keys)) {
            if ($Presentes -notcontains $k) { $IgnoradosAvisados.Remove($k) }
        }
    }
}

# ---------------------------------------------------------------------------
# TOPE DE REINTENTOS DEL REENCOLADO (exit 75)  -  26/08/2026
#
# EL AGUJERO: encode.ps1 sale con 75 (EX_TEMPFAIL) cuando el fallo es
# TRANSITORIO -disco lleno o timeout del OCR- y el watcher devuelve el fichero a
# la cola. No habia NINGUN contador, asi que una causa que no se resuelve sola
# daba un ciclo infinito:
#   - timeout de OCR sobre una pista que siempre tarda de mas -> una vuelta cada
#     ~17 min (12 de timeout + 5 de espera) para siempre. En un encode normal
#     cada vuelta ademas MATA EL FFMPEG DE VIDEO A MEDIAS, o sea que quema GPU en
#     cada iteracion.
#   - disco lleno de verdad (no un pico) -> una vuelta cada 5 min para siempre.
# La cache de .ec3 salva el Atmos, que es lo caro, pero el video se rehace entero
# en cada vuelta y nadie se entera de que el trabajo esta atascado.
#
# EL CRITERIO: 'transitorio' significa que reintentar TIENE SENTIDO, no que haya
# que reintentar eternamente. A la tercera se para y se deja el error a la vista
# del panel, que es la preferencia de siempre aqui: fallar alto antes que
# degradar -o girar- en silencio.
#
# Los avisos CADUCAN a las 24 h: un fallo de hoy no debe contar contra un
# reintento de la semana que viene. Se guardan por NOMBRE de fichero, que es lo
# unico estable entre la cola y la carpeta de trabajo.
#
# Va en la libreria y no en cada watcher por la razon de siempre: encode-watch y
# subs-watch tenian el mismo bloque de reencolado copiado, y copiarlo una tercera
# vez es como empezaron a divergir las cuatro listas de temporales.
# ---------------------------------------------------------------------------

function Get-RequeueStrikes {
    param([Parameter(Mandatory=$true)][string]$Tmp)
    $tabla = @{}
    $p = Join-Path $Tmp 'requeue_strikes.json'
    if (-not (Test-Path -LiteralPath $p)) { return $tabla }
    try {
        $o = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json
        $limite = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - (24 * 3600)
        foreach ($k in @($o.PSObject.Properties.Name)) {
            $e = $o.$k
            if ($null -ne $e -and [long]$e.ts -ge $limite) {
                $tabla[$k] = @{ n = [int]$e.n; ts = [long]$e.ts }
            }
        }
    } catch { }   # fichero roto = empezar de cero; nunca tumbar el watcher por esto
    return $tabla
}

function Save-RequeueStrikes {
    param(
        [Parameter(Mandatory=$true)][string]$Tmp,
        [Parameter(Mandatory=$true)][hashtable]$Tabla
    )
    $p = Join-Path $Tmp 'requeue_strikes.json'
    try {
        if ($Tabla.Count -eq 0) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            return
        }
        $o = [ordered]@{}
        foreach ($k in @($Tabla.Keys)) { $o[$k] = $Tabla[$k] }
        [System.IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Compress -Depth 4),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Clear-RequeueStrike {
    # El trabajo salio bien: se olvida su historial. Se llama tras un exit 0.
    param(
        [Parameter(Mandatory=$true)][string]$Tmp,
        [Parameter(Mandatory=$true)][string]$Nombre
    )
    $t = Get-RequeueStrikes -Tmp $Tmp
    if ($t.ContainsKey($Nombre)) {
        $t.Remove($Nombre)
        Save-RequeueStrikes -Tmp $Tmp -Tabla $t
    }
}

function Invoke-PipelineRequeue {
    <#
      Devuelve el fichero a su cola tras un exit 75, SI no ha agotado los
      intentos. Devuelve $true si lo reencolo.

      Cuando se agotan, el fichero se queda en la carpeta de trabajo (nadie lo
      pierde) y se escribe el motivo en <prefijo>_status para que el panel lo
      muestre. Ese status no lo pisa nadie: una salida por Exit-Requeue es
      CONTROLADA y ya borro su <prefijo>_outfile, asi que Clear-JobTemps no
      devuelve el estado a idle.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Tmp,
        [Parameter(Mandatory=$true)][ValidateSet('encode','subs','audio')][string]$Prefix,
        [Parameter(Mandatory=$true)][string]$Nombre,
        [Parameter(Mandatory=$true)][string]$Origen,
        [Parameter(Mandatory=$true)][string]$Cola,
        [int]$Max = 3
    )

    $t = Get-RequeueStrikes -Tmp $Tmp
    $n = 1
    if ($t.ContainsKey($Nombre)) { $n = [int]$t[$Nombre].n + 1 }
    $t[$Nombre] = @{ n = $n; ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    Save-RequeueStrikes -Tmp $Tmp -Tabla $t

    if ($n -ge $Max) {
        Write-Host ("  [requeue] '{0}' ya ha fallado {1} veces por un fallo declarado TRANSITORIO." -f $Nombre, $n)
        Write-Host  "  [requeue] NO se reencola mas: si fuera pasajero ya habria salido. El fichero"
        Write-Host ("  [requeue] se queda donde esta y el error queda a la vista en {0}_status." -f $Prefix)
        Write-Host  "  [requeue] Causas tipicas: disco lleno de verdad, o una pista PGS cuyo OCR"
        Write-Host  "  [requeue] no termina nunca. Arreglalo y vuelve a encolarlo a mano."
        try {
            $msg = "status=error`nfile=$Nombre`nduration=0`nerror=Abortado tras $n reintentos por fallo transitorio (disco lleno o timeout de OCR). No se reencola mas: revisalo y vuelve a encolarlo."
            [System.IO.File]::WriteAllText((Join-Path $Tmp "${Prefix}_status"), $msg,
                (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
        return $false
    }

    $back = Join-Path $Cola $Nombre
    if (Test-Path -LiteralPath $back) {
        Write-Host "  [requeue] ya hay un '$Nombre' en la cola; dejo el de la carpeta de trabajo sin tocar."
        return $false
    }
    # SE COMPRUEBA EL EFECTO, no que la orden no protestara (02/09/2026).
    # Esto era un Move-Item con -ErrorAction SilentlyContinue seguido de un
    # Write-Host que ya daba por hecho el reencolado y un 'return $true'. Si el
    # movimiento fallaba -y aqui es probable: se acaba de matar un trabajo y
    # Windows no suelta el handle en el mismo instante- el log decia "devuelto a
    # la cola", el watcher se lo creia, y el fichero se quedaba en la carpeta de
    # trabajo sin que nadie volviera a mirarlo.
    # Es el mismo fallo que ya obligo a escribir Move-AEnCurso y
    # Remove-ConReintento, dos funciones mas arriba en este mismo fichero: la
    # doctrina estaba escrita y este sitio se habia quedado fuera.
    # Se quita tambien el -Force: el destino ya se ha comprobado justo encima, y
    # -Force borraria el que hubiera antes de mover.
    try {
        Move-Item -LiteralPath $Origen -Destination $back -ErrorAction Stop
    } catch {
        Write-Host ("  [requeue] NO se ha podido devolver '{0}' a la cola: {1}" -f $Nombre, $_.Exception.Message)
        Write-Host  "  [requeue] Se queda en la carpeta de trabajo. Reencolalo a mano cuando se libere."
        return $false
    }
    if (-not (Test-Path -LiteralPath $back)) {
        Write-Host ("  [requeue] el movimiento de '{0}' no dio error pero el fichero no esta en la cola." -f $Nombre)
        return $false
    }
    Write-Host ("  [requeue] {0} devuelto a la cola (fallo transitorio; intento {1} de {2})." -f $Nombre, $n, $Max)
    return $true
}
