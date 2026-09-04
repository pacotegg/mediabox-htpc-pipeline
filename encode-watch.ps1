<#
============================================================================
 encode-watch.ps1  —  Windows port of encode-watch.sh
============================================================================
 Watches the queue folder, waits for a dropped file to finish copying,
 detects non-Atmos TrueHD (prompts via web panel), then calls encode.ps1.

 Run it (keep the window open, or use Task Scheduler / NSSM as a service):
   powershell -ExecutionPolicy Bypass -File C:\scripts\encode-watch.ps1
============================================================================
#>

$Base       = "C:\Media"                  # <-- EDIT: must match encode.ps1
$Watch      = Join-Path $Base "encode_queue"
$Running    = Join-Path $Base "encode_running"
$EncodedDir = Join-Path $Base "encoded"
$ScriptDir  = "C:\scripts"                # <-- EDIT: where encode.ps1 lives
# Ruta absoluta (regla del proyecto: no depender del PATH)
# $FFPROBE los da mediabox-paths.ps1 (31/08/2026: estaban copiados aqui).
# $Tmp (temp de ESTADO) se asigna MAS ABAJO, junto a $BigTmp: desde el
# 02/09/2026 sale de mediabox-paths.ps1 y no puede fijarse antes de cargarla.
# Temporales PESADOS (.thd/DAMF/ec3). Tienen que coincidir con el $BigTmp de
# encode.ps1 y con el Get-BigTmp de atmos-lib.ps1: si aqui apuntara a otro sitio,
# Clean-JobLeftovers barreria una carpeta vacia y los 30-40 GB de un trabajo
# matado se quedarian ahi para siempre.
# La ruta sale de mediabox-paths.ps1 (unica definicion del pipeline). Se carga
# aqui y no se espera a pipeline-lock.ps1 -que tambien la trae- porque ese
# dot-source va mas abajo y esta variable hace falta ya.
$PathsLib = Join-Path $PSScriptRoot 'mediabox-paths.ps1'
if (-not (Test-Path -LiteralPath $PathsLib)) { $PathsLib = 'C:\scripts\mediabox-paths.ps1' }
if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
$BigTmp     = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { "G:\MediaTmp" }
# Temp de ESTADO (pid, status, ffprog, lock). Misma regla que $BigTmp: una sola
# definicion en mediabox-paths.ps1. Estaba escrito a mano en ONCE scripts, que
# es la trampa que esa libreria existe para matar (02/09/2026).
$Tmp        = if ($MediaBoxTmp) { $MediaBoxTmp } else { "C:\Media\tmp" }
# Lock COMPARTIDO por todos los pipelines (video, audio y los que vengan).
# Antes cada watcher tenia el suyo y miraba ademas el del otro, lo cual solo
# funciona con exactamente dos: con tres, cada uno tendria que mirar los otros
# dos. Un unico lock escala solo.
# Por que serializar: todos comparten C:\Media\tmp y un DAMF ocupa 12-21 GB. Si
# dos corren a la vez pueden llenar el disco a mitad de trabajo, porque cada
# script comprueba el espacio por su cuenta y ambos verian sitio de sobra.
# (El panel NO lee este fichero - comprobado -, asi que el nombre es libre.)
$LockFile   = Join-Path $Tmp "pipeline.lock"
# Lock atomico compartido por los tres watchers. Ver pipeline-lock.ps1: el
# protocolo anterior (comprobar y luego escribir) dejaba entrar a dos pipelines
# a la vez, y el barrido de temporales de uno se llevaba los del otro.
$LockLib = Join-Path $PSScriptRoot 'pipeline-lock.ps1'
if (-not (Test-Path -LiteralPath $LockLib)) { $LockLib = 'C:\scripts\pipeline-lock.ps1' }
. $LockLib
$WatcherPid = Join-Path $Tmp "encode_watch_pid"
# Flag de PAUSA de la cola: lo escribe el boton Stop del panel (app.py) y lo
# quita el boton Reanudar. Mientras exista, este watcher no coge nada nuevo.
$PauseFile  = Join-Path $Tmp "encode_paused"
# RETENCION: mientras exista, no se arranca ningun trabajo que no traiga una
# decision EXPLICITA de modo en su sidecar '.opts'. No es una pausa: la cola
# sigue viva y los ficheros ya decididos entran con normalidad.
#
# POR QUE (27/08/2026): QVBR e ICQ tienen sesgos OPUESTOS -QVBR castiga por
# duracion, ICQ por grano- y ninguno gana siempre, asi que para algunas peliculas
# la eleccion buena solo la puede hacer quien las mira. Sin esto, el watcher las
# coge a los 8 s y la decision se toma sola.
# Lo pone y lo quita el interruptor 'Retener' del panel.
$HoldFile   = Join-Path $Tmp "encode_hold"

# LA CONSULTA "TrueHD sin Atmos: keep o convert?" SE ELIMINO EL 19/08/2026.
# Vivia en cuatro sitios (el fichero encode_truehd_pending y $AtmosPolicy aqui,
# la ruta /api/enc/truehd_decide y su lectura por sondeo en app.py, y el modal de
# index.html) y no la disparaba NADIE desde que se decidio convertir todo TrueHD:
# nadie escribia ya ese fichero. Lo que costaba: app.py intentaba abrirlo en CADA
# sondeo de estado, y quedaban ~90 lineas de interfaz que no se podian alcanzar.
# La politica hoy es una sola: TODO TrueHD se convierte a DD+, y la ruta la elige
# encode.ps1 PISTA A PISTA segun el 'profile':
#   CON Atmos -> mkvextract -> truehdd -> XML -> dee.exe, 768k JOC (objetos)
#   SIN Atmos -> deew -f ddp, 640k (DEE; mejor que el eac3 de ffmpeg)
# Si algun dia hay que volver a preguntar, esta en el historial de _backups.

# --- Barrido de fuentes ya procesados en encode_running -------------------
# Los fuentes NO se borran al terminar un trabajo: se quedan en encode_running a
# proposito, para poder comparar con la salida. El problema es que son 26-60 GB
# cada uno y se acumulan en C:, que es justo el disco que el 31/07/2026 se lleno
# a mitad de un encode. Esto es una RED DE SEGURIDAD, no una limpieza rutinaria:
# mientras haya espacio de sobra no hace absolutamente nada.
$RunningMinFreeGB   = 100   # por debajo de esto empieza a reclamar espacio
$RunningMinAgeHours = 2     # y solo con fuentes de mas de N horas

# Mismo host de PowerShell que corre este watcher (pwsh 7 o powershell 5.1)
$PsExe = (Get-Process -Id $PID).Path

# ── Single-instance guard ─────────────────────────────────────────
if (Test-Path $WatcherPid) {
    $existing = Get-Content $WatcherPid -ErrorAction SilentlyContinue
    if ($existing -and (Get-Process -Id $existing -ErrorAction SilentlyContinue)) {
        Write-Host "encode-watch ya esta corriendo (PID $existing) - saliendo."
        exit
    }
}
$PID | Set-Content -LiteralPath $WatcherPid

if (-not (Test-Path -LiteralPath $FFPROBE)) {
    Write-Host "ERROR: no encuentro ffprobe en $FFPROBE - sin el no se puede detectar Atmos."
    exit 1
}

# ---------------------------------------------------------------------------
# CUANTOS TRABAJOS DE VIDEO A LA VEZ (04/09/2026)
# ---------------------------------------------------------------------------
# MEDIDO el 17/08/2026: dos encodes de 4K simultaneos terminan los dos en
# 30,6 min contra 44,6 en serie -1,45x de rendimiento- y las salidas son BIT A
# BIT IDENTICAS a la del encode en solitario, o sea que la concurrencia no
# altera el bitstream. Un solo encode NO satura la GPU.
#
# SIGUE EN 1 A PROPOSITO. Subirlo a 2 no rompe nada del pipeline -encode.ps1
# aisla por -Slot sus ficheros de estado y sus temporales, y Clear-JobTemps
# barre el marcador de todas las ranuras- pero deja el PANEL medio ciego: lee
# 'encode_status', 'encode_pid' y 'encode_ffprog' por nombre FIJO, asi que veria
# solo la ranura 1 y el boton Stop mataria a esa. Y el Stop es lo que salva un
# trabajo que va mal. Se sube cuando el panel sepa de las dos.
$MaxSlots = 1

New-Item -ItemType Directory -Force -Path $Watch,$Running,$EncodedDir,$Tmp | Out-Null
Write-Host "Watching: $Watch (PID $PID)"

function Clean-JobLeftovers {
    # El cuerpo se movio a pipeline-lock.ps1 el 19/08/2026 como Clear-JobTemps,
    # por la razon de siempre en este proyecto: habia TRES copias (una por
    # watcher) mas la de stop-mediabox.ps1, y ya habian divergido. Aqui queda
    # solo la llamada con el prefijo de estado de esta cola.
    # Se llama CON EL LOCK TODAVIA COGIDO (ver la funcion).
    Clear-JobTemps -Prefix 'encode' -Tmp $Tmp -BigTmp $BigTmp
}

function Clean-RunningSources {
    # El cuerpo de esta funcion se movio a pipeline-lock.ps1 el 05/08/2026 como
    # Clear-ProcessedSources, para que subs-watch.ps1 tenga la misma red de
    # seguridad (subs_running acumula fuentes igual de grandes y no tenia
    # ninguna). Aqui queda solo la llamada con los parametros de esta cola.
    Clear-ProcessedSources -Running $Running `
                           -CompletedJsonl (Join-Path $Base 'encode_logs\completed.jsonl') `
                           -MinFreeGB $RunningMinFreeGB -MinAgeHours $RunningMinAgeHours
}

function Detect-TruehdMode([string]$file) {
    # "keep"   -> no hay TrueHD, no hay nada que convertir
    # "truehd" -> hay TrueHD (CON o SIN Atmos). Aqui NO hace falta distinguir:
    #             encode.ps1 consulta el 'profile' PISTA A PISTA y elige la ruta:
    #               CON Atmos -> dee.exe directo, 768k, objetos preservados
    #               SIN Atmos -> deew, 640k (el encoder de Dolby, mejor que el
    #                            eac3 de ffmpeg al mismo bitrate)
    $codecs = & $FFPROBE -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 $file 2>$null
    if (-not ($codecs -match '(?i)truehd|mlp')) { return "keep" }
    return "truehd"
}

# Limpieza de ARRANQUE: si el PC se reinicio (o el watcher murio) con un trabajo
# a medias, su marcador/salida parcial/temporales siguen ahi y nadie los barrio
# (Clean-JobLeftovers solo corre despues de cada trabajo). Solo si no hay ningun
# pipeline vivo con el lock cogido, para no tocar temporales ajenos en uso.
# Via la libreria y no a mano (05/08/2026): estas tres copias sueltas hacian
# 'Get-Content' sin envolver en @(), que sobre un fichero de UNA linea devuelve
# una CADENA y no un array -de "26488" saca "2"-. Aqui no llegaba a dar problema
# porque el valor entero se pasa a Get-Process, pero es la misma trampa que ya
# simulo un lock corrupto una vez. Test-PipelineLockBusy lo hace bien.
$lockBusy = Test-PipelineLockBusy $LockFile
if (-not $lockBusy) {
    # El marcador se lee AQUI, ANTES de Clean-JobLeftovers: esa funcion se lo
    # lleva por delante y despues ya no habria forma de saber como acabo el
    # ultimo trabajo.
    $murioAMedias = Test-Path -LiteralPath (Join-Path $Tmp 'encode_outfile')

    Clean-JobLeftovers

    # RESCATE de trabajos a medias: si el PC se apago/reinicio con un encode en
    # curso, su fichero fuente quedo en encode_running y ANTES nadie lo volvia a
    # coger -> se quedaba huerfano para siempre. Aqui se devuelve a la cola para
    # reprocesarlo ENTERO (un encode a medias no se puede continuar; Clean-
    # JobLeftovers de arriba ya borro su salida parcial y sus temporales, asi que
    # empieza limpio). Solo se hace con el lock libre: si estuviera cogido, ese
    # _running seria de un trabajo VIVO y moverlo lo romperia.
    #
    # EL MARCADOR ES LA CONDICION, y no basta con que haya algo en _running.
    # Nadie saca el fuente de encode_running cuando un trabajo termina BIEN: se
    # queda ahi a proposito. Sin esta condicion, el rescate no distingue "murio a
    # medias" de "termino y el fuente sigue ahi", y **reencodea la ultima pelicula
    # en cada reinicio**. Paso de verdad el 31/07/2026: Interstellar acabo bien a
    # las 15:36, se reinicio a las 16:02 y a las 16:03:12 estaba repitiendose
    # entera -1,5 h de CPU- sin que nadie lo pidiera.
    # encode.ps1 escribe el marcador al empezar y lo borra en TODAS sus salidas
    # controladas, asi que: presente = lo mataron (corte de luz, taskkill del
    # panel); ausente = salio por su pie. Es el mismo criterio que ya usa
    # Clean-JobLeftovers para decidir si la salida de encoded/ esta a medias.
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
            Write-Host "  [rescate] $($quedan.Count) fichero(s) en encode_running de trabajos YA TERMINADOS: no se tocan."
        }
    }

    # VA DESPUES del rescate: lo que se acabe de devolver a la cola ya no esta en
    # _running y no puede confundirse con un fuente ya procesado.
    Clean-RunningSources
}

while ($true) {
    # Ver subs-watch.ps1: el listado alimenta tambien a Write-ColaIgnora.
    $enCola = @(Get-ChildItem -LiteralPath $Watch -File -ErrorAction SilentlyContinue)
    $cola   = @($enCola | ForEach-Object { $_.Name })
    # FASE A: se eligen hasta $MaxSlots candidatos SIN coger el lock (ver la
    # fase B). Aqui abajo hay 'continue' y 'break' por todas partes y eso es
    # justo lo que obliga a que el lock no este cogido todavia.
    $lote   = @()
    foreach ($f in $enCola) {
        # Cola en PAUSA (Stop del panel): no coger nada nuevo hasta Reanudar.
        # Pausa del VIDEO (la crea el boton STOP del panel) y pausa GLOBAL
        # (pipeline_paused, para mantenimiento: la miran los tres watchers).
        if (Test-Path -LiteralPath $PauseFile) { break }
        if (Test-PipelinePaused $Tmp) { break }
        # Los .thd eran los sidecar de decision de la consulta TrueHD, que ya no
        # existe. El filtro se queda -y ahora cubre mas- porque en esta cola se
        # sueltan ficheros a mano y no todo lo que cae aqui es una pelicula:
        # un .part a medio bajar o un .srt suelto no deben entrar al encoder.
        # '.partial' ENTRA EL 26/08/2026 y FALTABA. Es la extension con la que el
        # panel copia a esta cola (_encolar_async en app.py, boton "a cola de
        # video" de la pestanya Audio): copia a '<nombre>.partial' y solo al
        # terminar renombra con os.replace, que es atomico. El comentario de esa
        # funcion daba por hecho que los tres watchers la descartaban, pero los de
        # audio y subs lo hacen por LISTA BLANCA (.mkv/.mp4/.m2ts/.ts/.mov) y este
        # va por lista negra, donde '.part' NO casa con '.partial'.
        # Lo unico que quedaba protegiendo era la espera de 3 s de estabilizacion
        # de tamanyo, que es justo la que el comentario de _encolar_async declara
        # insuficiente: un atasco de disco de mas de 3 s -y pasan cuando hay un
        # encode en marcha- dejaba entrar al encoder un fichero TRUNCADO con toda
        # la pinta de estar entero.
        if ($f.Extension.ToLower() -in @('.thd','.part','.partial','.tmp','.opts','.srt','.sub','.idx','.txt','.jpg','.nfo')) {
            # Igual que en los otros dos watchers: se descarta, pero se dice.
            Write-ColaIgnora -Nombre $f.Name -Presentes @($cola) `
                -Motivo ("extension {0} descartada en encode_queue (no es una pelicula)" -f $f.Extension)
            continue
        }

        # Skip if ANY pipeline is busy (video, audio, ...). Comprobacion BARATA,
        # solo para no hacer en balde el trabajo preparatorio de aqui abajo. La
        # exclusion de verdad la da Enter-PipelineLock, que es atomico.
        if (Test-PipelineLockBusy $LockFile) { break }

        # Wait for stable size (copy finished)
        $s1 = $f.Length; Start-Sleep -Seconds 3
        $f2 = Get-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        if (-not $f2 -or $f2.Length -ne $s1) { continue }

        # TrueHD: se convierte SIEMPRE, tenga Atmos o no. Este ffprobe sigue
        # haciendo falta pese a que la politica sea unica, porque encode.ps1 solo
        # entra en la cadena de DD+ si se le pasa 'atmos_ddp' POR POSICION; con
        # el 'keep' por defecto, el TrueHD se copiaria sin convertir.
        $thd = if ((Detect-TruehdMode $f.FullName) -eq "truehd") { "atmos_ddp" } else { "keep" }

        # -- AJUSTES POR PELICULA (sidecar '<fichero>.opts') -------------------
        # Lo escriben el desplegable de modo y el campo Mbps de la cola del panel
        # (/api/enc/queue/opts). JSON: {"mode":"auto|icq|qvbr","target_mbps":N}.
        #
        # POR QUE UN SIDECAR Y NO EL NOMBRE DEL FICHERO: la cola es dirigida por
        # CARPETA, asi que no hay donde meter parametros; y meterlos en el nombre
        # obligaria a limpiarlos despues (el renombrado Plex-friendly de
        # encode.ps1 se los llevaria a la salida). Un fichero al lado no toca
        # nada de eso y se ve en la carpeta.
        #
        # VA ANTES DE COGER EL LOCK, y esto no es un detalle de estilo: aqui hay
        # un 'continue' (la retencion). Cuando esto vivia DESPUES del
        # Enter-PipelineLock, ese continue salia SIN SOLTAR EL LOCK y el watcher
        # se bloqueaba a si mismo -y de paso a los otros dos pipelines- para
        # siempre. Paso de verdad el 27/08/2026, en la primera prueba.
        # Regla: nada que pueda hacer 'continue' o 'break' puede ir entre
        # Enter-PipelineLock y el Exit-PipelineLock correspondiente.
        $optsSrc = $f.FullName + '.opts'
        $tgtMbps = 0.0
        $modo    = 'auto'
        $dest = Join-Path $Running $f.Name
        $optsDst = $dest + '.opts'
        if (Test-Path -LiteralPath $optsSrc) {
            try {
                $o = Get-Content -LiteralPath $optsSrc -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($null -ne $o.target_mbps) { $tgtMbps = [double]$o.target_mbps }
                if ($o.mode -and ($o.mode -in @('auto','icq','qvbr'))) { $modo = "$($o.mode)" }
            } catch {
                Write-Host "  [opts] '$($f.Name).opts' ilegible ($($_.Exception.Message)); se ignora."
            }
        }

        # RETENCION: no arranca nada sin decision de modo. 'decidido' = tiene modo
        # explicito o Mbps; con cualquiera de los dos entra.
        if (Test-Path -LiteralPath $HoldFile) {
            $decidido = ($modo -ne 'auto') -or ($tgtMbps -gt 0)
            if (-not $decidido) {
                Write-ColaIgnora -Nombre $f.Name -Presentes @($cola) `
                    -Motivo "RETENIDO: elige modo (ICQ/QVBR) o pon Mbps en su fila del panel"
                continue
            }
        }

        # ------------------------------------------------------------------
        # FIN DE LA FASE A. El fichero esta listo: entra en el lote.
        # ------------------------------------------------------------------
        $lote += [pscustomobject]@{
            File    = $f
            Nombre  = $f.Name
            Dest    = $dest
            OptsSrc = $optsSrc
            OptsDst = $optsDst
            Thd     = $thd
            Modo    = $modo
            TgtMbps = $tgtMbps
        }
        if ($lote.Count -ge $MaxSlots) { break }
    }

    # ======================================================================
    # FASE B: coger el lock UNA vez, ejecutar el lote entero y soltarlo.
    # ======================================================================
    # POR QUE EN DOS FASES (04/09/2026). La regla escrita en este fichero es que
    # nada que pueda hacer 'continue' o 'break' puede ir entre el
    # Enter-PipelineLock y su Exit: el 27/08/2026 un 'continue' entre los dos
    # dejo el lock cogido y bloqueo los TRES pipelines para siempre.
    # Con varias ranuras el lock tendria que sobrevivir a VARIAS vueltas del
    # foreach de arriba, o sea que cada continue de la preparacion pasaria a ser
    # una fuga en potencia. Separando las fases, la preparacion conserva todos
    # sus continue y el lock se coge en UN solo sitio y se suelta en un finally,
    # que es mas seguro que lo que habia antes de este cambio.
    #
    # El lock se sigue cogiendo ANTES de mover nada: si se cogiera despues del
    # Move y otro pipeline se nos hubiera adelantado, el fichero ya estaria en
    # _running y no volveria a la cola. Perdiendo la carrera aqui no pasa nada:
    # el fichero sigue en la cola y se reintenta en la vuelta siguiente.
    if ($lote.Count -eq 0) { Start-Sleep -Seconds 5; continue }
    if (-not (Enter-PipelineLock $LockFile)) { Start-Sleep -Seconds 5; continue }

    $resultados = @()
    try {
        $vivos = @()
        $ranura = 0
        foreach ($j in $lote) {
            $ranura++
            # LA PELICULA PRIMERO Y EL SIDECAR DESPUES (31/08/2026). Estaba al
            # reves, asi que si el movimiento de la pelicula fallaba -y podia: se
            # hacia sin -ErrorAction Stop y este script corre con 'Continue'- el
            # '.opts' se quedaba en _running con su pelicula todavia en la cola.
            # Move-AEnCurso comprueba el efecto y NO borra un huerfano que hubiera
            # en el destino: lo aparta.
            if (-not (Move-AEnCurso -Origen $j.File.FullName -Destino $j.Dest)) {
                Write-Host ("  no se pudo mover a _running: {0} (se queda en la cola)" -f $j.Nombre)
                continue
            }
            if (Test-Path -LiteralPath $j.OptsSrc) {
                Move-Item -LiteralPath $j.OptsSrc -Destination $j.OptsDst -Force -ErrorAction SilentlyContinue
            }

            # TODO POR NOMBRE Y NADA POR POSICION (04/09/2026). Antes esto era
            # '& $PsExe ... -File encode.ps1 $dest "" "fast" $thd', con una CADENA
            # VACIA en la posicion de -TypeOverride. Al pasar a Start-Process esa
            # cadena vacia es justo lo que peor viaja por la linea de comandos, y
            # ademas '' es el valor por defecto del parametro: no hay que pasarlo.
            # Por nombre no hay posiciones que puedan bailar.
            $argu = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', (Join-Path $ScriptDir 'encode.ps1'),
                '-InputFile',  $j.Dest,
                '-Mode',       'fast',
                '-TruehdMode', $j.Thd,
                '-RateMode',   $j.Modo,
                '-Slot',       "$ranura"
            )
            if ($j.TgtMbps -gt 0) {
                # Con cultura INVARIANTE: en es-ES el ToString() normal daria
                # '9,85' y el binder del otro lado leeria 985.
                $argu += @('-TargetMbps', $j.TgtMbps.ToString([System.Globalization.CultureInfo]::InvariantCulture))
            }
            Write-Host ("Starting: {0} (ranura {1}/{2}, truehd={3}, modo={4}{5})" -f `
                        $j.Nombre, $ranura, $MaxSlots, $j.Thd, $j.Modo,
                        $(if ($j.TgtMbps -gt 0) { ", bitrate a mano $($j.TgtMbps)M" } else { "" }))
            # Get-ArgLine (pipeline-lock.ps1) entrecomilla cada argumento: sin
            # eso, Start-Process une el array con espacios y el nombre de la
            # pelicula se parte en pedazos. Ver la funcion.
            $p = Start-Process -FilePath $PsExe -ArgumentList (Get-ArgLine $argu) -NoNewWindow -PassThru
            # Sin tocar Handle, ExitCode puede venir a $null despues de salir.
            $null = $p.Handle
            $vivos += [pscustomobject]@{ Job = $j; Proc = $p; Ranura = $ranura }
        }

        # SE ESPERA A TODOS ANTES DE BARRER. Es la razon por la que el barrido
        # sigue siendo seguro con varias ranuras: Clean-JobLeftovers borra POR
        # PATRON (vid_*, thd_*, ...), asi que si se llamara al acabar la primera
        # ranura se llevaria por delante los temporales de la que sigue viva. Es
        # exactamente el fallo que el 04/08/2026 se comio 45 min de truehdd.
        foreach ($v in $vivos) {
            $v.Proc.WaitForExit()
            $resultados += [pscustomobject]@{ Job = $v.Job; Rc = $v.Proc.ExitCode }
        }
    }
    finally {
        # Con el lock TODAVIA cogido: nadie mas puede estar usando esos fuentes.
        # El registro de exito de los trabajos que acaban de terminar ya esta
        # escrito, pero sus fuentes no seran elegibles hasta $RunningMinAgeHours.
        # En un finally para que un fallo inesperado no deje el lock cogido, que
        # es lo que paralizaria los tres pipelines.
        Clean-JobLeftovers
        Clean-RunningSources
        Exit-PipelineLock $LockFile
    }

    # ---- YA SIN EL LOCK: reencolar lo que fallo por algo transitorio ------
    $hayTempfail = $false
    foreach ($r in $resultados) {
        $j  = $r.Job
        $rc = $r.Rc

        # 75 (EX_TEMPFAIL) = encode.ps1 aborto por algo TRANSITORIO, hoy solo por
        # disco lleno. El fichero no tiene nada malo: vuelve a la cola y se
        # reintentara. Sin esto, un disco lleno degradaba el Atmos a EAC3 y daba
        # el trabajo por bueno (asi se perdio el de Interstellar el 31/07/2026), o
        # -si el que se llenaba era el disco de salida- dejaba el fuente muerto en
        # encode_running sin que nadie lo volviera a mirar.
        # Se reencola DESPUES de soltar el lock y de limpiar: si se hiciera antes,
        # el propio bucle podria recogerlo al instante y entrar en un ciclo
        # cerrado de reintentos contra un disco que sigue lleno.
        # CON TOPE DE INTENTOS desde el 26/08/2026. Antes no habia contador y una
        # causa que no se resuelve sola daba un ciclo infinito: cada vuelta
        # reencodeaba el video entero para volver a morir por lo mismo. Ver
        # Invoke-PipelineRequeue en pipeline-lock.ps1 (compartida con subs-watch).
        if ($rc -eq 75) {
            $hayTempfail = $true
            $reencolado = Invoke-PipelineRequeue -Tmp $Tmp -Prefix 'encode' -Nombre $j.Nombre `
                              -Origen $j.Dest -Cola $Watch
            # El sidecar vuelve CON la pelicula: un fallo transitorio no debe
            # perder el ajuste que pediste, o el reintento saldria con el bitrate
            # automatico y otro tamano sin que nadie lo dijera.
            if ($reencolado -and (Test-Path -LiteralPath $j.OptsDst)) {
                Move-Item -LiteralPath $j.OptsDst -Destination ((Join-Path $Watch $j.Nombre) + '.opts') `
                          -Force -ErrorAction SilentlyContinue
            }
        }

        # Salio bien: se olvida su historial de reintentos, para que un fallo de
        # hoy no cuente contra el mismo fichero dentro de un mes.
        if ($rc -eq 0) { Clear-RequeueStrike -Tmp $Tmp -Nombre $j.Nombre }
        # El sidecar ya no pinta nada: el trabajo se hizo (bien o mal) con el.
        # Si se dejara, un fichero con el mismo nombre encolado manyana heredaria
        # un ajuste que nadie recuerda haber puesto.
        if ($rc -ne 75) { Remove-Item -LiteralPath $j.OptsDst -Force -ErrorAction SilentlyContinue }

        Write-Host "Done: $($j.Nombre) (exit $rc)"
    }

    # Respiro antes de volver a mirar la cola: si el disco sigue lleno,
    # reintentarlo cada 5 segundos solo llena el log. Va UNA vez por lote, no
    # por fichero: dos trabajos que mueren por el mismo disco lleno no tienen
    # por que costar 10 minutos de espera.
    if ($hayTempfail) { Start-Sleep -Seconds 300 }

    Start-Sleep -Seconds 5
}
