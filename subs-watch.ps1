<#
============================================================================
 subs-watch.ps1  -  Watch folder para el pipeline de SOLO SUBTITULOS
============================================================================
 Vigila C:\Media\subs_queue; cuando un fichero termina de copiarse lo mueve a
 subs_running y llama a encode.ps1 -SubsOnly (que deja el resultado en
 subs_done).

 POR QUE LLAMA A encode.ps1 Y NO A UN MOTOR PROPIO:
 un pipeline de subtitulos es el pipeline normal con el video y el audio en
 copy. El bloque de OCR (PGS -> SRT con PgsToSrt) son ~140 lineas dentro de
 encode.ps1; copiarlas a un script aparte habria creado dos copias condenadas a
 divergir, que es exactamente lo que ya paso con New-DeeAtmosXml y con el motor
 de audio, y que hubo que deshacer. Aqui no hay copia: es el mismo codigo con
 dos ramas.

 Arranque:  pwsh -ExecutionPolicy Bypass -File subs-watch.ps1

 NOTA: fichero en ASCII puro (codigo Y comentarios).
============================================================================
#>

$Base       = 'C:\Media'
$Watch      = Join-Path $Base 'subs_queue'
$Running    = Join-Path $Base 'subs_running'
$Done       = Join-Path $Base 'subs_done'
# $Tmp (temp de ESTADO) se asigna MAS ABAJO, junto a $BigTmp: desde el
# 02/09/2026 sale de mediabox-paths.ps1 y no puede fijarse antes de cargarla.
# Misma unidad de temporales pesados que usan encode.ps1 y encode-watch.ps1.
# Aqui solo se usa para BARRER lo que deje el OCR (ver Clean-JobLeftovers).
# Ruta unica del pipeline (mediabox-paths.ps1). Se carga aqui y no se espera a
# pipeline-lock.ps1, que se dot-sourcea mas abajo.
$PathsLib = Join-Path $PSScriptRoot 'mediabox-paths.ps1'
if (-not (Test-Path -LiteralPath $PathsLib)) { $PathsLib = 'C:\scripts\mediabox-paths.ps1' }
if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
$BigTmp     = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { 'G:\MediaTmp' }
# Temp de ESTADO (pid, status, lock). Misma regla que $BigTmp: una sola
# definicion en mediabox-paths.ps1. Estaba a mano en ONCE scripts (02/09/2026).
$Tmp        = if ($MediaBoxTmp) { $MediaBoxTmp } else { 'C:\Media\tmp' }
$WatcherPid = Join-Path $Tmp 'subs_watch_pid'

# Lock COMPARTIDO por todos los pipelines (video, audio, subtitulos).
# Aunque este modo no genera DAMF ni consume CPU de encoder, se serializa igual:
# comparte C:\Media\tmp y compite por disco, y no tiene sentido que un remux
# entre a pelearse con un encode de 20 minutos.
$LockFile   = Join-Path $Tmp 'pipeline.lock'
# Lock atomico compartido por los tres watchers (ver pipeline-lock.ps1).
$LockLib = Join-Path $PSScriptRoot 'pipeline-lock.ps1'
if (-not (Test-Path -LiteralPath $LockLib)) { $LockLib = 'C:\scripts\pipeline-lock.ps1' }
. $LockLib

# encode.ps1 vive en C:\scripts; este script puede estar aqui al lado o no.
$Encoder = Join-Path $PSScriptRoot 'encode.ps1'
if (-not (Test-Path -LiteralPath $Encoder)) { $Encoder = 'C:\scripts\encode.ps1' }

# pwsh 7: se reutiliza el MISMO host que corre este script. 'powershell' a secas
# resolveria a Windows PowerShell 5.1, que no es con lo que se ha probado nada.
$PsExe = (Get-Process -Id $PID).Path

$VideoExt = @('.mkv','.mp4','.m2ts','.ts','.mov')

# --- Barrido de fuentes ya procesados en subs_running ---------------------
# Igual que en encode-watch.ps1: los fuentes NO se borran al terminar (se quedan
# para poder comparar con la salida), pero son de 26-60 GB y se acumulan en C:,
# el mismo disco que se lleno a mitad de un encode el 31/07/2026. Esta cola no
# tenia ninguna red de seguridad hasta el 05/08/2026. Es eso, una red: mientras
# haya espacio de sobra no hace absolutamente nada.
$RunningMinFreeGB   = 100   # por debajo de esto empieza a reclamar espacio
$RunningMinAgeHours = 2     # y solo con fuentes de mas de N horas

function Clean-RunningSources {
    # Cuerpo compartido en pipeline-lock.ps1 (Clear-ProcessedSources): la misma
    # funcion que usa encode-watch.ps1, no una copia. encode.ps1 -SubsOnly escribe
    # su registro en completed.jsonl igual que un encode normal (con
    # mode='subs_only'), asi que el criterio de "termino bien" vale tal cual.
    Clear-ProcessedSources -Running $Running `
                           -CompletedJsonl (Join-Path $Base 'encode_logs\completed.jsonl') `
                           -MinFreeGB $RunningMinFreeGB -MinAgeHours $RunningMinAgeHours
}

function Clean-JobLeftovers {
    # Cuerpo compartido en pipeline-lock.ps1 (Clear-JobTemps), igual que ya
    # pasaba con Clear-ProcessedSources. Hasta el 19/08/2026 esto era una copia
    # que barria 4 patrones de los 16 y ademas no contaba los GB, asi que su
    # barrido no salia en el log ni cuando liberaba algo.
    # Se llama con el lock todavia cogido (ver la funcion).
    Clear-JobTemps -Prefix 'subs' -Tmp $Tmp -BigTmp $BigTmp
}

# ---- Instancia unica ----------------------------------------------
# Get-OtraInstancia (pipeline-lock.ps1) mira TAMBIEN la linea de comandos: un
# PID reciclado por otro proceso daba 'ya esta corriendo' para siempre y dejaba
# el pipeline parado. Paso el 04/09/2026 con este mismo guard.
$otraInstancia = Get-OtraInstancia -PidFile $WatcherPid -Marca 'subs-watch.ps1'
if ($otraInstancia) {
    Write-Host "subs-watch ya esta corriendo (PID $otraInstancia) - saliendo."
    exit
}
New-Item -ItemType Directory -Force -Path $Watch,$Running,$Done,$Tmp | Out-Null
$PID | Set-Content -LiteralPath $WatcherPid

if (-not (Test-Path -LiteralPath $Encoder)) {
    Write-Host "ERROR: no encuentro encode.ps1 (ni junto a este script ni en C:\scripts)."
    exit 1
}
Write-Host "Watching: $Watch (PID $PID)"

# Limpieza de ARRANQUE: mismo criterio que encode-watch.ps1 (trabajo muerto de
# antes de un reinicio). Solo si el lock no esta cogido por un proceso vivo.
# Via la libreria y no a mano (05/08/2026), igual que en los otros dos watchers:
# el Get-Content suelto sin @() es la trampa de siempre con este fichero.
$lockBusy = Test-PipelineLockBusy $LockFile
if (-not $lockBusy) {
    # ANTES de Clean-JobLeftovers, que borra el marcador (ver encode-watch.ps1).
    $murioAMedias = Test-Path -LiteralPath (Join-Path $Tmp 'subs_outfile')

    Clean-JobLeftovers

    # RESCATE de trabajos a medias: si el PC se apago/reinicio a mitad de un
    # trabajo de subtitulos, su fichero fuente quedo en subs_running. Se devuelve
    # a la cola para reprocesarlo entero. Solo con el lock libre.
    #
    # EL MARCADOR ES LA CONDICION: sin el, el rescate no distingue "murio a
    # medias" de "termino y el fuente sigue en _running", y repetiria el ultimo
    # trabajo en cada reinicio. Mismo fallo y mismo arreglo que en
    # encode-watch.ps1, donde se detecto el 31/07/2026.
    if ($murioAMedias) {
        foreach ($orphan in @(Get-ChildItem -LiteralPath $Running -File -ErrorAction SilentlyContinue)) {
            # Move-ARescate (pipeline-lock.ps1) COMPRUEBA que el fichero llego a
            # la cola. Antes esto era un Move-Item mudo seguido de un Write-Host
            # que lo daba por hecho: si fallaba, el fichero se quedaba en
            # _running y no lo cogia nadie, con el log diciendo lo contrario.
            $null = Move-ARescate -Origen $orphan.FullName -Cola $Watch -Nombre $orphan.Name
        }
    } else {
        $quedan = @(Get-ChildItem -LiteralPath $Running -File -ErrorAction SilentlyContinue)
        if ($quedan.Count) {
            Write-Host "  [rescate] $($quedan.Count) fichero(s) en subs_running de trabajos YA TERMINADOS: no se tocan."
        }
    }

    # VA DESPUES del rescate: lo que se acabe de devolver a la cola ya no esta en
    # _running y no puede confundirse con un fuente ya procesado.
    Clean-RunningSources
}

while ($true) {
    # El listado se toma UNA vez por vuelta: se recorre y ademas alimenta a
    # Write-ColaIgnora, que necesita saber que sigue habiendo para olvidar los
    # avisos de ficheros que ya se retiraron.
    $enCola = @(Get-ChildItem -LiteralPath $Watch -File -ErrorAction SilentlyContinue)
    $cola   = @($enCola | ForEach-Object { $_.Name })
    foreach ($f in $enCola) {
        if ($f.Extension.ToLower() -notin $VideoExt) {
            # No se calla: un fichero que la cola no va a procesar se queda ahi
            # para siempre, y sin este aviso nadie sabe por que. Una vez por
            # fichero (ver Write-ColaIgnora en pipeline-lock.ps1).
            Write-ColaIgnora -Nombre $f.Name -Presentes @($cola) `
                -Motivo ("extension {0} no admitida en subs_queue (se aceptan {1})" -f $f.Extension, ($VideoExt -join ' '))
            continue
        }

        # Pausa GLOBAL de mantenimiento (ver Test-PipelinePaused).
        if (Test-PipelinePaused $Tmp) { break }

        # Si hay CUALQUIER pipeline trabajando, esperar. Comprobacion BARATA:
        # la exclusion de verdad la da Enter-PipelineLock, que es atomico.
        if (Test-PipelineLockBusy $LockFile) { break }

        # Esperar a que el tamano se estabilice (copia terminada)
        $s1 = $f.Length; Start-Sleep -Seconds 3
        $f2 = Get-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        if (-not $f2 -or $f2.Length -ne $s1) { continue }

        # EL LOCK, ANTES DE MOVER NADA (ver el mismo bloque en encode-watch.ps1).
        if (-not (Enter-PipelineLock $LockFile)) { break }

        $dest = Join-Path $Running $f.Name
        # Move-AEnCurso (pipeline-lock.ps1) en vez de 'Move-Item -Force' suelto:
        # comprueba el efecto y no borra un huerfano que hubiera en el destino.
        # Si falla, el fichero se queda en la cola y se reintenta.
        if (-not (Move-AEnCurso -Origen $f.FullName -Destino $dest)) {
            Exit-PipelineLock $LockFile
            continue
        }
        Write-Host "Starting: $($f.Name)"

        & $PsExe -NoProfile -ExecutionPolicy Bypass -File $Encoder $dest -SubsOnly -OutDir $Done
        $rc = $LASTEXITCODE
        # ANTES de soltar el lock: si entrase otro pipeline ahora, sus temporales
        # casarian con los patrones y se los llevaria este barrido por delante.
        Clean-JobLeftovers
        # Con el lock TODAVIA cogido: nadie mas puede estar usando esos fuentes.
        Clean-RunningSources
        Exit-PipelineLock $LockFile

        # 75 (EX_TEMPFAIL) = encode.ps1 aborto por algo TRANSITORIO: disco lleno o,
        # desde el 14/08/2026, TIMEOUT DEL OCR (el OCR tarda ~20s por pista con la
        # maquina libre; si se va a 12 min es que habia contencion, no que el
        # fichero sea malo). El fichero esta intacto: vuelve a la cola en vez de
        # quedarse en subs_running dando el trabajo por hecho.
        #
        # ESTE WATCHER NO LO MIRABA hasta el 05/08/2026, y si podia pasar: el modo
        # SubsOnly tiene su propia rama en el chequeo de espacio de salida de
        # encode.ps1 (el video va en copy, asi que la salida pesa casi lo que la
        # fuente) y de ahi sale un Exit-Requeue igual que en un encode normal. El
        # resultado era el peor posible: el fuente varado en subs_running, un
        # "Done" en el log y nadie reintentando jamas. Mismo contrato que los
        # watchers de video y audio.
        # Se reencola DESPUES de soltar el lock y de limpiar: si se hiciera antes,
        # el propio bucle podria recogerlo al instante y entrar en un ciclo cerrado
        # de reintentos contra un disco que sigue lleno.
        # CON TOPE DE INTENTOS desde el 26/08/2026, y aqui hacia mas falta que en
        # ningun sitio: el timeout del OCR es la causa MAS probable de un 75 en
        # esta cola, y una pista que nunca termina daba una vuelta cada ~17 min
        # para siempre. Ver Invoke-PipelineRequeue en pipeline-lock.ps1.
        if ($rc -eq 75) {
            $null = Invoke-PipelineRequeue -Tmp $Tmp -Prefix 'subs' -Nombre $f.Name `
                        -Origen $dest -Cola $Watch
            # Respiro antes de volver a mirar la cola: si el disco sigue lleno -o
            # sigue habiendo contencion de CPU-, reintentarlo cada 5 segundos solo
            # llena el log.
            Start-Sleep -Seconds 300
        }

        # Salio bien: se olvida su historial de reintentos.
        if ($rc -eq 0) { Clear-RequeueStrike -Tmp $Tmp -Nombre $f.Name }

        Write-Host "Done: $($f.Name)  (exit $rc; original en subs_running, resultado en subs_done)"
        break
    }
    Start-Sleep -Seconds 5
}
