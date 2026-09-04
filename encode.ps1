<#
============================================================================
 encode.ps1     Windows / Intel Arc (QSV) port of encode.sh
============================================================================
 Hardware HEVC 10-bit encoder for Intel Arc A-series on Windows using QSV.

 CAMBIOS v2:
  - Conversion PGS -> SRT con OCR de consola (PgsToSrt + Tesseract),
    sin depender de Subtitle Edit (GUI). Funciona desatendido / oculto.
  - Contador de subtitulos descartados (subs_dropped) registrado en
    completed.jsonl para que el panel lo muestre.
============================================================================
#>

param(
    [Parameter(Mandatory=$true)][string]$InputFile,
    [string]$TypeOverride = "",
    [string]$Mode         = "fast",
    [string]$TruehdMode   = "keep",
    # Modo SOLO SUBTITULOS: el video se copia (-c:v copy, sin QSV) y el audio se
    # copia entero sin descartar pistas. Solo se procesan los subtitulos (OCR de
    # PGS -> SRT). Es el MISMO codigo que el pipeline normal, no una copia: un
    # motor aparte habria acabado divergiendo, como ya paso con el de audio.
    [switch]$SubsOnly,
    # Carpeta de salida alternativa (la usa subs-watch.ps1). Vacia = la de siempre.
    [string]$OutDir       = "",
    # Salta la reconstruccion del contenedor (Rebuild-Container). ES PARA UN
    # EXPERIMENTO CONCRETO, no para uso normal: comprobar si la Samsung de 2024
    # sigue necesitandola. La reconstruccion se anadio el 31/07/2026 porque cuatro
    # peliculas daban pantalla negra en Direct Play y las arreglo 4 de 4; la causa
    # raiz nunca se encontro, asi que no se puede deducir si hoy sigue haciendo
    # falta. "Ya no me pasa" no vale como prueba: TODAS las peliculas desde el
    # 01/08 llevan la reconstruccion, asi que no ver el fallo es lo que se espera
    # tanto si hace falta como si no.
    # COMO HACER LA PRUEBA BIEN (las dos trampas costaron horas y estan anotadas):
    #   1. Reproducir el fichero COMPLETO en la TV, no un clip: los clips hechos
    #      con -ss -t -c copy arrastran estadisticas incoherentes y dieron
    #      resultados opuestos con contenido identico.
    #   2. Verificar EN EL LOG DE PLEX que fue Direct Play y no transcodificacion
    #      (buscar 'Content-Length of' frente a lineas 'MDE:'). Varias pruebas
    #      "funcionaron" solo porque Plex transcodifico.
    #   3. GUARDAR el fichero si falla. La vez anterior se borraron las cuatro
    #      afectadas y por eso la causa raiz sigue abierta.
    [switch]$NoRebuild,
    # BITRATE DE VIDEO A LA FUERZA, en Mbps, SOLO PARA ESTE TRABAJO. 0 = automatico
    # (la cadena de reglas de siempre). Lo pone el campo "Mbps" de la cola del
    # panel via un sidecar '<fichero>.opts' que lee encode-watch.ps1.
    #
    # POR QUE EXISTE (26/08/2026). "El destino de Jupiter" salio a 8,73 GiB y el
    # usuario lo queria mas pequenyo. En 4K el GQ NO sirve para eso: esta MEDIDO
    # que es inerte (cuatro puntos mueven el 1,3 % del tamanyo) porque manda el
    # -b:v. O sea que el unico mando real es el bitrate, y hasta hoy solo se podia
    # tocar globalmente, editando la tabla de $Target para TODAS las peliculas.
    #
    # Y tiene que ser POR PELICULA y no global: el suelo de 8,5M en 4K no es
    # arbitrario, sale de mirar fotogramas el 19/08/2026 (10,5M indistinguible,
    # 8,5M "casi nada", 5,8M perdida CLARA). Bajar el suelo para todas se llevaria
    # por delante las peliculas exigentes; bajarlo en la que tu has mirado, no.
    #
    # ES LA ULTIMA PALABRA: se aplica DESPUES del duration scaling, del tope del
    # 70 %, del techo de $CeilGb, del suelo de calidad y del $absFloor. Si no fuera
    # asi, pedir 6.0 en un 4K largo no serviria de nada -el suelo lo devolveria a
    # 8,5- que es justo lo que hace inutil el mando.
    [double]$TargetMbps = 0,
    # MODO DE CONTROL DE BITRATE, solo para este trabajo:
    #   auto -> el perfil de su resolucion ($CfgPerfil1080p / $CfgPerfil4K)
    #   icq  -> ICQ puro: manda el GQ, el tamano queda LIBRE (sin techo posible)
    #   qvbr -> QVBR: se emiten -b:v/-maxrate/-bufsize y el tamano es previsible
    # Lo pone el desplegable de la cola del panel, via el sidecar '.opts'.
    # Pasar -TargetMbps implica 'qvbr' aunque no se diga: un bitrate solo
    # significa algo si hay -b:v.
    [ValidateSet('auto','icq','qvbr')][string]$RateMode = 'auto',
    # RANURA de ejecucion (04/09/2026). Existe para poder correr DOS trabajos
    # de video a la vez: esta medido que dos encodes simultaneos rinden 1,45x
    # y que las salidas son bit a bit IDENTICAS, o sea que la concurrencia no
    # altera el bitstream. Lo que si chocaria sin esto son dos cosas:
    #
    #   1. LOS FICHEROS DE ESTADO. Se llaman '<prefijo>_status|_pid|_ffprog|
    #      _outfile' con prefijo FIJO, y el panel los lee por ese nombre. Dos
    #      trabajos compartiendolos = el boton Stop mata al que no es y el
    #      marcador de salida parcial solo guarda una ruta.
    #   2. LOS TEMPORALES PESADOS. Se nombran con un sello AL SEGUNDO, asi que
    #      dos trabajos que arranquen en el mismo segundo escribirian en el
    #      MISMO vid_*.mkv de 15 GB.
    #
    # LA RANURA 1 SE COMPORTA EXACTAMENTE COMO ANTES: mismo prefijo 'encode',
    # mismos nombres. Es deliberado, para que este cambio no toque nada del
    # camino que ya funciona ni del panel.
    [ValidateRange(1, 4)][int]$Slot = 1
)

$ErrorActionPreference = "Continue"

# Force '.' as decimal separator regardless of system locale (Spanish Windows uses ',')
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

# Forzar UTF-8 al capturar la salida de ffprobe y al pasar argumentos a ffmpeg.
# Sin esto, en Windows con consola no-UTF8 los acentos (e, n, ...) se corrompen
# al leer/reescribir los titulos de las pistas.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

# -- Configuration -------------------------------------------------
$Base        = "C:\Media"                 # <-- EDIT: your media root
$EncodedDir  = Join-Path $Base "encoded"
$LogDir      = Join-Path $Base "encode_logs"
# $Tmp (temp de ESTADO: status, pid, marcadores; lo lee app.py) se asigna MAS
# ABAJO, junto a $BigTmp: desde el 02/09/2026 sale de mediabox-paths.ps1 y no
# puede fijarse antes de cargarla.
# Temporales PESADOS (.thd + DAMF: 30-40 GB por pista Atmos) en OTRA unidad.
# Hasta el 31/07/2026 vivian en C:\Media\tmp junto al estado, y ese dia el disco
# se lleno a mitad del DEE de Interstellar (NTFS evento 141, cuatro procesos
# afectados a la vez) y el Atmos se perdio en un fallback silencioso a EAC3.
# En C: compiten el pagefile, la fuente de encode_running y lo que alguien este
# copiando a encode_queue; el pipeline.lock no puede serializar a este ultimo.
# Ver el comentario largo de Get-BigTmp en atmos-lib.ps1.
# La ruta ya NO se escribe aqui: sale de mediabox-paths.ps1, que es la unica
# definicion para todo el pipeline (estaba copiada en NUEVE sitios, cinco de
# ellos con un "<-- EDIT: igual que en X" al lado). Se carga explicitamente y no
# por herencia de atmos-lib.ps1 porque esa libreria se dot-sourcea MAS ABAJO, y
# aqui la ruta ya hace falta.
$PathsLib = Join-Path $PSScriptRoot 'mediabox-paths.ps1'
if (-not (Test-Path -LiteralPath $PathsLib)) { $PathsLib = 'C:\scripts\mediabox-paths.ps1' }
if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
$BigTmp      = if ($MediaBoxBigTmp) { $MediaBoxBigTmp } else { "G:\MediaTmp" }
$Tmp         = if ($MediaBoxTmp)    { $MediaBoxTmp }    else { "C:\Media\tmp" }
if ($SubsOnly -and $OutDir) { $EncodedDir = $OutDir }
# LAS HERRAMIENTAS SALEN DE mediabox-paths.ps1 (31/08/2026), que se acaba de
# cargar tres lineas mas arriba: $MKVMERGE, $MKVEXTRACT, $MKVPROPEDIT, $FFMPEG y
# $FFPROBE -este ultimo con su respaldo al nombre suelto si la ruta de WinGet
# cambiara-. Estaban escritas a mano en 41 sitios repartidos por 20 ficheros,
# que es la misma trampa que ya salio con 'G:\MediaTmp' y con las cuatro listas
# de patrones de temporales. El motivo de cada una vive ahora en esa libreria.

$UseVppFilters = $true   # set $false if vpp_qsv denoise/detail unsupported

# -- SOLAPAR AUDIO Y VIDEO -----------------------------------------
# Hoy el trabajo va audio -> subtitulos -> video EN SERIE, y no hace falta.
# Medido el 16/08/2026: el encode QSV usa 0,33 nucleos de CPU (es GPU pura) y
# tarda LO MISMO con 4 nucleos ocupados, mientras que DEE es 1 nucleo y cero
# GPU. En WALL-E eso son 22 min de audio + 18 min de video = 40 en serie,
# cuando solapados serian ~22.
# Con esto en $true: el audio arranca en segundo plano, el video se encodea SOLO
# a un temporal, y al final una SEGUNDA pasada de ffmpeg con -c:v copy muxea ese
# video con los .ec3 y los subtitulos. La logica de HDR, capitulos, mapeo y
# metadatos NO se reescribe: es la misma llamada de siempre, con otra entrada de
# video.
# LO QUE CAMBIA Y HAY QUE SABER: el bitrate objetivo del video se calcula con el
# audio ESTIMADO (el nominal de la tabla DEE) en vez del tamano real del .ec3,
# porque ese dato aun no existe. Solo importa cuando muerde el techo de tamano,
# o sea por encima de (CeilGb*8*2^30)/((Target+audio)*1e6) segundos de metraje:
# 192-203 min en 4K HDR segun cuanto audio se conserve. Por debajo, el target
# sale identico y el bitstream tambien.
# ENCENDIDO el 17/08/2026, con estas mediciones delante:
#   - Obsession (4K, TrueHD Atmos, 109 min): 42,3 min en serie -> 24,6 en
#     paralelo. 17,7 min menos (42 %).
#   - Speak No Evil (1080p HDR, TrueHD Atmos + PGS, 110 min): 27,3 -> 20,4 min.
#   - En las dos, PARIDAD EXACTA con la pasada en serie: mismo MD5 de los
#     paquetes de video y del audio, mismo tamano al byte, mismas pistas,
#     idiomas, titulos, orden, capitulos y HDR (contenedor y SEI).
#   - El OCR solapado con el encode tarda 31 s donde en serie tardaba 29: la
#     contencion que se temia no existe (el timeout esta en 720 s).
# LO QUE SIGUE ABIERTO: una vez, el 17/08, la pasada de video murio al 88 % con
# '[hevc_qsv] Invalid FrameType:0'. No se reprodujo (la misma linea sola termina
# bien; con DEE al lado en un banco aparte, 2 de 2 bien; y ese error no aparece
# en ninguno de los 265 logs historicos). Por eso existe la RED de mas abajo: si
# la pasada de video falla, se espera al audio y se rehace por el camino
# CLASICO, que da el mismo fichero. Peor caso conocido: ~3 min mas que en serie.
# Se anula solo en -SubsOnly (no hay encode que solapar), cuando la pelicula no
# trae ninguna pista que convertir con DEE, y cuando el audio pendiente es tan
# corto que no compensa la segunda pasada (ver $MinAudioParaleloSeg).
# Para volver atras: poner $false aqui. No hay nada mas que deshacer.
$ParallelAudioVideo = $true

# ============================================================================
#  PERFIL DE CALIDAD  (22/08/2026, separado por resolucion el 25/08/2026)
#  <-- EDITA AQUI PARA PROBAR O REVERTIR
# ============================================================================
#  'icq'   : sin -b:v/-maxrate/-bufsize. Manda el GQ y cada escena gasta lo que
#            su complejidad pide. Ficheros de tamano VARIABLE.
#  'techo' : comportamiento anterior al 22/08/2026 (QVBR con -b:v por tabla).
#            Tamano PREVISIBLE, pero infla las escenas faciles hasta el techo.
#
#  POR QUE ESTAN SEPARADOS POR RESOLUCION (25/08/2026). Con un solo interruptor
#  para las dos ramas no se podia tener lo bueno de cada una, y no se comportan
#  igual porque su GQ no significa lo mismo:
#
#    1080p en 'icq' -> GQ 15, o sea EXACTAMENTE la misma calidad pedida que en
#      'techo'. No se baja nada: solo se deja de inflar lo facil. Medido y
#      verificado a ojo por el usuario: siempre igual o mas pequenyo, nunca dio
#      un caso al alza. Es ahorro sin contrapartida -> se queda en 'icq'.
#
#    4K en 'icq' -> GQ 18, que SI es menos calidad pedida que el 15 de 'techo'.
#      Ahi esta el riesgo: en contenido con grano real de pelicula, la demanda a
#      GQ 18 puede superar el techo antiguo. Caso real que lo demostro, "El
#      Bueno El Feo Y El Malo" (1966, grano de 35 mm, fuente 25,56 Mbps): pidio
#      12,4 Mbps y salio a 17,1 GiB, cuando con 'techo' habrian sido ~13,9 GiB
#      (+23 %). Con el disco apretando eso es justo lo contrario de lo que se
#      busca -> se queda en 'techo' hasta que sobre espacio.
# 27/08/2026: 1080p VUELVE A 'techo'. MEDIDO, y el motivo es el mismo por el que
# el 4K volvio el 25/08: ICQ reparte por escena, que es lo que se quiere, pero NO
# TIENE NINGUN CONTROL DE TAMANO -no se le puede poner techo sin sacarlo del modo
# ICQ- y en 1080p eso resulto costar mucho mas de lo que se creia.
#
# Dos originales 1080p de la biblioteca, clip de 180 s en 00:35:00, argumentos
# EXACTOS de produccion, sin -b:v (o sea: lo que el GQ PIDE de verdad):
#
#            fuente        GQ14   GQ15    GQ16   GQ17   GQ18
#   Traffic (2000)  21,9M  17,63  15,98   14,21  12,78  11,49
#   Rapa Nui (1994) 21,8M   6,99   6,21    5,46   4,80   4,23
#
# Las dos vienen al MISMO bitrate de fuente y a GQ 15 una pide 2,6 VECES lo que
# la otra. O sea que el tamano de salida en ICQ no lo puede acotar nadie: en
# Traffic, 15,98 Mbps sobre 147 min son ~16,4 GiB PARA UN 1080p -mas que casi
# todas las 4K de la biblioteca- frente a los ~7,5 GiB que da 'techo'.
# Y el techo de $CeilGb (12 GiB) esta INERTE en ICQ, asi que no lo para nada.
#
# Lo que se pierde volviendo a 'techo' esta medido tambien y es lo contrario:
# Rapa Nui pide 6,21 y con target 7,5 recibira ~7,3, o sea que la pelicula facil
# se infla un ~17 %. Es el precio conocido del -b:v (ver icq-puro-vs-bv-iman).
# Se acepta a proposito: inflar un 17 % lo facil cuesta ~1 GiB, y dejar sin techo
# lo dificil cuesta 9. Con el disco apretando no hay duda.
#
# LO QUE DECIA LA NOTA ANTERIOR y ha quedado corregido: "en 1080p ICQ es ahorro
# sin contrapartida, siempre igual o mas pequenyo". No es cierto en material con
# grano real. La medicion de entonces (3 tramos de El resplandor, media -3 %) ya
# avisaba de que "por pelicula puede ir en cualquier direccion"; Traffic es esa
# direccion, y con una pelicula entera detras.
#
# El GQ se queda en 15 y ES LO CORRECTO bajo 'techo': se eligio el 07/08 para que
# NO fuera el limite, y con Traffic pidiendo 16 contra un target de 7,5 sigue sin
# serlo. No hay nada mas que tocar.
$CfgPerfil1080p = 'techo'
$CfgPerfil4K    = 'techo'
#
#  GQ de cada rama en modo 'icq'. En QSV un GQ MAS ALTO = MENOS calidad y
#  menos bitrate; cada punto vale del orden del 20 % de bitrate.
#  MEDIDO el 22/08/2026 (ver la memoria 'icq-puro-vs-bv-iman'):
#    4K   : GQ 18 salio indistinguible de la config vieja a ojo, y sobre 6
#           peliculas ORIGINALES de la biblioteca ahorra un 19,5 % (El reino
#           de los cielos, 194 min: 12,68 -> 8,59 GiB). GQ 19 empieza a alisar
#           el grano y GQ 20 ya deja ver banding en paredes lisas.
#    1080p: GQ 15, o sea EL MISMO de siempre. Aqui no se baja la calidad
#           pedida: solo se deja de inflar las escenas faciles.
#  Para probar otro punto, cambia el numero y encodea: no hay nada mas que
#  tocar. Sube el numero si quieres menos tamano, bajalo si quieres mas calidad.
$CfgGqIcq4K    = 18
$CfgGqIcq1080p = 15
# ============================================================================

# Estado del audio en segundo plano. Se declaran AQUI, y no donde se usan,
# porque el try/finally de limpieza y Exit-Requeue los miran antes de que la
# fase de audio los haya tocado.
$AudioBg     = $null    # estado devuelto por Start-DdpTracksParallel
$AudioJoined = $false   # $true en cuanto Wait- ha recogido los resultados
$VidTmp      = ''       # temporal de video de la pasada 1 (vive en $BigTmp)
$VideoProc   = $null    # ffmpeg de video en marcha, para poder matarlo al abortar
$UltimoAvisoAudio = [datetime]::MinValue   # ultima vez que se publico el avance del audio

# Verificacion de la fuente ANTES de gastar tiempo en ella: off | fast | full
#   fast -> decodifica 15s del principio y 20s del final (~10 s). El chequeo del
#           FINAL es el que importa: pilla descargas truncadas/incompletas.
#   full -> decodifica el video entero (5-15 min en 4K). Pilla danyos intermedios.
$VerifySource = "fast"

# -- Comentarios y audiodescripcion --------------------------------
# Son pistas de VOZ: no necesitan 640k ni 5.1. Se recodifican a estereo a
# $CommentBitrateK. Si la pista ya viene pequenya y en <=2ch se copia tal cual,
# porque recodificar lossy->lossy por ahorrar 30k es un mal cambio.
# En una peli larga esto es dinero: en ESDLA RdR (263 min) cada pista de
# comentarios ocupa ~390 MB, y las cuatro suman ~1.5 GB. Ademas el techo de
# tamano RESTA el audio, asi que cada bit de audio ahorrado se lo queda el video.
# -- TECHO DEL AUDIO QUE SE COPIA (27/08/2026) ---------------------------
# Los codecs que el TV decodifica (AC3/EAC3/AAC/MP3) se copian tal cual, y hasta
# hoy SIN NINGUN TOPE. Auditada la biblioteca por los sidecar *-mediainfo.xml:
# 1376 peliculas, 2590 pistas, 1045 GiB de audio, y hay E-AC-3 5.1 a 1536k y
# 2304k -tres a cinco veces el estandar de Blu-ray-. Con este tope el audio de la
# biblioteca pasaria de 1045 a 817 GiB: 227 GiB, de los cuales 226,6 salen justo
# de las pistas que hoy se copian (las DTS/FLAC/PCM ya se convierten via DEE, asi
# que su exceso ya estaba recortado).
#
# POR QUE 448k y no 640: DD+ es bastante mas eficiente que AC3, cuyo estandar de
# Blu-ray son 640k. 448k de DD+ 5.1 queda por ENCIMA de Disney+ (384k) y muy por
# encima de Netflix (192k), y dentro de la banda 448-640 que ya se dio por buena
# al auditar el AAC de la biblioteca (ver [[aac-51-bitrate-pobre]]).
#
# LO QUE NO TOCA, y son guardas, no matices:
#   - ATMOS. Un E-AC-3 con JOC lleva objetos y recodificarlo los pierde EN
#     SILENCIO. Se sondea el 'profile' de la pista y si trae Atmos se copia.
#   - Mas de 6 canales: el encoder eac3 de ffmpeg topa en 5.1, asi que capar un
#     7.1 le costaria CANALES, no solo bitrate. Se copia entero.
#   - Comentarios: ya los gobierna $CommentBitrateK mas abajo, que gana a esto.
#   - Lo que ya viene por debajo del tope (con un 10 % de margen, para no
#     recodificar un 460k a 448k y pagar una generacion por 12 kbps).
# Se recodifica con el eac3 de ffmpeg, no con DEE: son pistas YA con perdida, la
# diferencia de encoder pesa poco a este bitrate, y asi no cuesta ni un minuto
# extra -va en la misma pasada-.
# A 0 se desactiva el tope y el comportamiento vuelve a ser el de antes.
# ($MaxCopyAudioK y $MaxCopyAudioStereoK viven en atmos-lib.ps1, junto a la
#  funcion Get-CopyAudioCapK que los aplica: la misma regla la necesita tambien
#  audio_encode.ps1 y no puede haber dos copias.)

$CommentBitrateK = 128    # objetivo para comentarios (estereo)
$CommentKeepMaxK = 160    # si ya viene por debajo y en <=2ch, no se toca
$CommentPattern  = '(?i)comment|comentario|kommentar|commentaire|director|audio.?descri|descripci[oó]n|visually impaired|isolated score'

# -- Dedup de passthrough redundante -------------------------------
# Cuando un release trae DOS pistas del mismo idioma en passthrough (tipico:
# EAC3 5.1 + AC3 5.1 en ingles), las dos sobrevivian: el dedup solo sabia
# descartar 'transcode', y ac3/eac3/aac se clasifican como 'copy'.
# Con esto se queda la mejor y se tiran las redundantes.
# Ponlo a $false si prefieres conservar el AC3 como red de compatibilidad para
# algun reproductor viejo que no lleve DD+.
$DedupPassthrough = $true

# -- Subtitulos EXTERNOS (subsfetch) --------------------------------
# Busca subtitulos fuera SOLO si la pelicula se queda sin ninguno de TEXTO, que
# en la practica son dos casos: no traia subtitulos, o solo traia VobSub (que es
# imagen y no tiene OCR). Los PGS NO lo disparan: esos ya los OCrea el pipeline.
# Fuentes, por este orden: otra copia de la pelicula en la biblioteca, y despues
# OpenSubtitles. Nada se acepta sin verificar la sincronia contra el audio del
# propio fichero. Ver webpanel/subsfetch.py.
# A $false se desactiva por completo y el pipeline se comporta como antes.
$FetchSubs           = $true
$FetchSubsTimeoutMs  = 900000     # 15 min: incluye descarga + verificacion
$SubsFetch           = Join-Path $PSScriptRoot 'webpanel\subsfetch.py'
if (-not (Test-Path -LiteralPath $SubsFetch)) { $SubsFetch = 'C:\scripts\webpanel\subsfetch.py' }
$PYTHON              = 'C:\Users\HTPC\AppData\Local\Programs\Python\Python314\python.exe'
# Si falta cualquiera de las dos piezas, se desactiva solo y se avisa UNA vez,
# en vez de fallar por pelicula.
if ($FetchSubs -and -not (Test-Path -LiteralPath $PYTHON)) {
    $FetchSubs = $false
}

# -- Preset del encoder --------------------------------------------
# 30/07: cambiado de 'veryslow' a 'medium'. El driver COLAPSA los siete presets
# nominales en TRES comportamientos reales (mismo MD5 dentro de cada grupo):
#   {veryslow, slower}   {slow, medium}   {veryfast}
# Coste medido de veryslow -> medium: -0.0000331 de SSIM y +0.11 % de tamano.
# Ganancia: 67.9 fps -> 108.2 fps, o sea 93 min -> 58 min en ESDLA RdR.
# Para dimensionar ese coste: quitar el filtro 'detail' dio +0.000730 de SSIM,
# VEINTIDOS VECES mas de lo que cuesta este cambio. Con lo ganado en los filtros
# se puede pagar este preset de sobra y seguir muy por encima del punto de
# partida en las dos cosas.
# Si algun dia se quiere volver, 'veryslow' no estaba mal puesto: solo era caro.
$Preset = "medium"

# -- Mezclas y doblajes ALTERNATIVOS (exentos de dedup) -------------
# Mismo idioma y mismos canales NO significa misma pista. El caso clasico es el
# de Disney en Espanya: un REDOBLAJE moderno en 5.1 junto al DOBLAJE CLASICO en
# 2.0. Sin esta excepcion el dedup se quedaria el 5.1 y tiraria el historico,
# que para mucha gente es justo el que quiere conservar. Lo mismo con las
# mezclas de cine originales frente a las remasterizadas.
# El patron evita a proposito palabras sueltas como 'original' o 'castellano':
# aparecen en pistas normales constantemente y desactivarian el dedup entero.
# Se exige la pareja ('doblaje original', 'original mix'...) o un termino que
# por si solo ya es inequivoco ('redoblaje', 'remasterizado').
$AltMixPattern = '(?i)redoblaje|re-?doblaje|re-?dub\b|' +
                 'doblaje\s+(original|cl[aá]sico|antiguo|nuevo|moderno|simult[aá]neo|de\s+cine|de\s+tve|tve|sudamericano)|' +
                 'doblaje\s+(de\s+)?(19|20)\d{2}|' +
                 '(original|classic|theatrical|home\s*video|alternat\w+|vintage|restored|remaster\w*)\s+(mix|dub|audio|track)|' +
                 'mezcla\s+(original|teatral|restaurada|de\s+cine)|' +
                 '(19|20)\d{2}\s+(theatrical|mix|dub)|' +
                 'restaurad\w*|remasteriz\w*'

# -- OCR (PgsToSrt) configuration ----------------------------------
# La conversion a SRT (texto y OCR de PGS) vive en subs-lib.ps1, compartida con
# el remux del panel; alli estan tambien las rutas de PgsToSrt y tessdata.
$OcrTimeoutMs = 720000                                     # 12 min max por pista
# 12, no 5: aislado una pista tarda ~20s (36x de margen), asi que solo salta con
# contencion REAL de CPU. Y cuando salta, ya no degrada a PGS-imagen: reencola
# (ver la rama $ocr.TimedOut en el bucle de subtitulos). Medido el 14/08/2026.

# -- DDP+Atmos (deew) ----------------------------------------------
# Al detectar TrueHD+Atmos con TruehdMode="atmos_ddp", se transcodifica a
# DDP+Atmos (E-AC-3 JOC) con deew (que internamente usa truehdd -> DAMF y DEE).
# Conserva los objetos Atmos y ahorra muchisimo espacio (TrueHD ~4-8Mbps -> 768k).
# Bitrates validos DDP-Atmos: 384/448/576/640/768/1024. 768 = estandar streaming.
$DeewBitrateAtmos = 768

# -- Helpers -------------------------------------------------------
function Probe([string]$streams, [string]$entries, [string]$file) {
    if ([string]::IsNullOrEmpty($streams)) {
        $out = & $FFPROBE -v error -show_entries $entries -of csv=p=0 $file 2>$null
    } else {
        $out = & $FFPROBE -v error -select_streams $streams -show_entries $entries -of csv=p=0 $file 2>$null
    }
    if ($null -eq $out) { return "" }
    return ($out | Out-String).Trim()
}
function WriteNoBom([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}
function Repair-Mojibake([string]$s) {
    # Arregla el caso tipico: texto UTF-8 que se guardo como si fuera Latin1/1252
    # (p.ej. "Ingles" aparece como "InglÃ©s"). Solo actua si detecta las marcas
    # tipicas (Ã / Â) y descarta el arreglo si genera caracteres invalidos.
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    if ($s -notmatch '[\u00C2\u00C3]') { return $s }
    try {
        $bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($s)
        $fixed = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($fixed -and ($fixed -notmatch "\uFFFD")) { return $fixed }
    } catch {}
    return $s
}
function FmtSize([long]$bytes) {
    if ($bytes -ge 1GB) { return ("{0:N1} GB" -f ($bytes/1GB)) }
    if ($bytes -ge 1MB) { return ("{0:N0} MB" -f ($bytes/1MB)) }
    return ("{0:N0} KB" -f ($bytes/1KB))
}
function ParseRational($v) {
    # ffprobe emite el HDR10 estatico unas veces como racional ("34000/50000") y
    # otras como decimal (0.68), segun version. Tragamos ambos y devolvemos $null
    # si no es ninguno, para no escribir basura en el contenedor.
    if ($null -eq $v) { return $null }
    $s = "$v"
    if ($s -match '^\s*(-?[0-9.]+)\s*/\s*(-?[0-9.]+)\s*$') {
        $den = [double]$Matches[2]
        if ($den -eq 0) { return $null }
        return ([double]$Matches[1] / $den)
    }
    if ($s -match '^\s*-?[0-9.]+\s*$') { return [double]$s }
    return $null
}
# Mensajes que aparecen en stderr con -v error pero NO significan fichero danyado.
# Se descubrio el 04/08/2026: 'blackhawkext' (72 GB) y antes 'deadpool 2' se
# rechazaron como "truncados" estando PERFECTOS -se reproducen enteros sin fallo-.
# Las dos decodificaciones terminaban con EXIT 0; lo unico que pasaba es que
# escupian avisos, y el test daba por malo cualquier stderr no vacio.
#   - 'PPS/SPS/VPS changed between slices': normal en remuxes Dolby Vision perfil 7
#     (dual layer). Casi todas las fuentes 4K de aqui son dvhe.07, o sea que esto
#     iba a seguir pasando.
#   - 'non monotonically increasing dts to muxer': lo dice el muxer null DEL PROPIO
#     TEST, no el fichero. Lo provoca el -ss de la comprobacion.
#   - 'Could not find ref with POC' / 'co located POCs unavailable': artefactos de
#     EMPEZAR A DECODIFICAR EN MEDIO. El test de la cola hace -ss, asi que el
#     decodificador arranca sin las referencias de su GOP. Es esperado.
$BenignDecodeMsgs = @(
    'PPS changed between slices'
    'SPS changed between slices'
    'VPS changed between slices'
    'non monotonically increasing dts'
    'Last message repeated'
    'Could not find ref with POC'
    'co located POCs unavailable'
    # --- Dolby Vision (anyadidos el 07/08/2026) ---------------------------
    # Avisos del parser de RPU (los metadatos DV), NO del decodificador de
    # video. La imagen se decodifica perfectamente; lo unico que dicen es que
    # los metadatos DV no cuadran con lo que la especificacion espera para ese
    # perfil, y aqui la capa DV se descarta de todas formas (los Samsung no
    # hacen Dolby Vision, ver fuentes-dv-p7-y-samsung).
    #
    # Un Minority Report en DV perfil 5 se rechazo por esto el 07/08/2026 con
    # "Fuente danyada: inicio del fichero". El fichero estaba perfecto: minutos
    # antes se le habian decodificado los fotogramas uno a uno para una
    # correlacion de luminancia, con pearson 0,95-0,97. Mismo tipo de falso
    # positivo que el de blackhawkext del 04/08.
    'RPUs should not use NLQ'
    'Failed to parse RPU'
    'Invalid RPU'
    'dovi_rpu'
)

function Get-RealDecodeErrors([object]$out) {
    # Devuelve solo las lineas que SI delatan un fichero roto.
    $malas = @()
    foreach ($line in @($out)) {
        $l = ("$line").Trim()
        if (-not $l) { continue }
        $ok = $false
        foreach ($p in $BenignDecodeMsgs) { if ($l -like "*$p*") { $ok = $true; break } }
        if (-not $ok) { $malas += $l }
    }
    return $malas
}

function Test-Decode([string]$file, [string[]]$extra) {
    # Decodifica (sin encodear) y devuelve $true si el fichero esta sano.
    # Los flags de $extra van ANTES de -i a proposito: '-ss' asi hace seek rapido
    # de entrada y '-t' limita la lectura, no la salida.
    # Si el intento por QSV falla, se reintenta UNA vez por software: un codec que
    # la Arc no decodifique por hardware es el unico falso positivo realista, y no
    # queremos dar por malo un fichero sano por eso.
    #
    # CRITERIO (corregido el 04/08/2026): manda el CODIGO DE SALIDA, y del stderr
    # solo cuentan las lineas que no esten en la lista de avisos inocuos. Antes
    # bastaba un stderr no vacio para condenar el fichero, y eso rechazaba remuxes
    # perfectamente sanos. Se guarda el motivo real en $script:LastDecodeError para
    # poder LOGUEARLO: sin eso, "Fuente danyada" no decia que habia visto ffmpeg y
    # diagnosticarlo obligaba a reproducir el comando a mano.
    $script:LastDecodeError = ""

    $a1 = @('-v','error','-hwaccel','qsv') + $extra + @('-i',$file,'-map','0:v:0','-f','null','NUL')
    $o1 = & $FFMPEG @a1 2>&1
    $e1 = $LASTEXITCODE
    if ($e1 -eq 0 -and -not (Get-RealDecodeErrors $o1)) { return $true }

    $a2 = @('-v','error') + $extra + @('-i',$file,'-map','0:v:0','-f','null','NUL')
    $o2 = & $FFMPEG @a2 2>&1
    $e2 = $LASTEXITCODE
    $malas = Get-RealDecodeErrors $o2
    if ($e2 -eq 0 -and -not $malas) { return $true }

    $script:LastDecodeError = if ($malas) { ($malas | Select-Object -First 3) -join ' | ' }
                              else { "ffmpeg salio con codigo $e2 sin mensaje" }
    return $false
}

# Convert-TrueHDToDDP + Get-DdpBitrate viven en atmos-lib.ps1 (compartida con audio-convert.ps1)
# Y DESDE EL 31/08/2026 TAMBIEN Rebuild-Container, ademas de Move-FicheroEnSitio,
# Get-BigTmp y ConvertTo-DoubleInv. El aviso de abajo decia que sin esta libreria
# solo se caia el modo atmos_ddp, y eso ya no era verdad -ni lo era antes-: sin
# ella este script no llega ni a arrancar. No se corta aqui a proposito para no
# cambiar el flujo, pero que el mensaje no mienta.
$AtmosLib = Join-Path $PSScriptRoot 'atmos-lib.ps1'
if (Test-Path -LiteralPath $AtmosLib) { . $AtmosLib }
else { Write-Host "AVISO: no se encuentra atmos-lib.ps1 junto a encode.ps1; sin ella faltan Rebuild-Container, Move-FicheroEnSitio, Get-BigTmp y el modo atmos_ddp." }

# Convert-SubToSrt + Test-SubsOcrReady viven en subs-lib.ps1 (compartida con el
# remux del panel, que llama a Convert-SubToSrt directamente por pwsh).
$SubsLib = Join-Path $PSScriptRoot 'subs-lib.ps1'
if (Test-Path -LiteralPath $SubsLib) { . $SubsLib }
else { Write-Host "AVISO: no se encuentra subs-lib.ps1 junto a encode.ps1; los PGS no se podran pasar a SRT." }

if (-not (Test-Path -LiteralPath $InputFile)) { Write-Host "ERROR: Invalid input"; exit 1 }

New-Item -ItemType Directory -Force -Path $EncodedDir,$LogDir,$Tmp | Out-Null

$BaseName = Split-Path $InputFile -Leaf
if ($BaseName -match '^[0-9]{3}_') { $BaseName = $BaseName.Substring(4) }
$Name = [System.IO.Path]::GetFileNameWithoutExtension($BaseName)

$stamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogDir "${stamp}_${Name}.log"
# EL SELLO DEL LOG NO SE TOCA: las herramientas de rendimiento fechan cada
# trabajo parseando '^yyyyMMdd_HHmmss_' del nombre del fichero, asi que
# meterle la ranura ahi las romperia.
# Para los TEMPORALES hace falta otra cosa: el sello es al SEGUNDO, y dos
# trabajos que arranquen en el mismo segundo escribirian en el mismo
# vid_*.mkv. Con la ranura y el PID dentro, la colision es imposible, y el
# nombre sigue empezando por el prefijo que barre Clear-JobTemps.
$TmpTag  = "{0}_s{1}_{2}" -f $stamp, $Slot, $PID
function Log($msg) { Write-Host $msg; Add-Content -LiteralPath $LogFile -Value $msg }

# Se resuelve AQUI, no antes: Get-BigTmp avisa por Log si la unidad preferida no
# esta, y ese aviso tiene que acabar en el log del trabajo, no solo en la consola
# de un watcher que corre oculto. Valida que se pueda ESCRIBIR de verdad (que la
# carpeta exista no dice nada de permisos ni de que el disco siga conectado) y
# cae a $Tmp si no. Se resuelve UNA vez y se pasa a atmos-lib, para que todas las
# pistas del trabajo usen la misma carpeta.
$BigTmp = Get-BigTmp -Preferred $BigTmp -Fallback $Tmp

# Codigo de salida que le dice al watcher "esto NO ha fallado por culpa del
# fichero: devuelvelo a la cola y reintentalo". 75 = EX_TEMPFAIL de sysexits.h.
# Cualquier otro codigo mantiene el comportamiento de siempre (el fuente se queda
# en encode_running y nadie lo vuelve a tocar).
$EXIT_REQUEUE = 75

function Exit-Requeue([string]$Motivo) {
    <#
      Aborta el trabajo ENTERO y pide que se reencole, en vez de degradar a EAC3.

      Por que no degradar: un fallo por disco lleno es TRANSITORIO. El 31/07/2026
      el DEE de Interstellar murio asi y el pipeline, creyendo que era un fallo de
      DEE, lo bajo a EAC3 5.1 y dio el trabajo por bueno. El Atmos se perdio para
      siempre en un fichero que se reencodeo entero durante 40 minutos, y el log
      solo decia "FALLO dee.exe". Reintentarlo media hora despues, con el disco ya
      libre, lo habria conservado.

      El status queda en 'error' con el motivo a la vista del panel, y el marcador
      de salida se borra: es una salida CONTROLADA, el watcher no debe pisar el
      status ni tratar la salida como parcial-de-un-proceso-muerto.
    #>
    Log "ABORTADO: $Motivo"
    Log "  El trabajo vuelve a la cola sin tocar la fuente. No se degrada a EAC3:"
    Log "  eso perderia el Atmos de forma definitiva por un fallo que es pasajero."
    foreach ($e in $AtmosEc3.Values) { Remove-Item -LiteralPath $e -Force -ErrorAction SilentlyContinue }
    if ($Output -and (Test-Path -LiteralPath $Output)) { Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue }
    WriteNoBom $StatusFile "status=error`nfile=$CleanName.mkv`nduration=$Duration`nerror=$Motivo (reencolado)"
    Remove-Item -LiteralPath $OutMarker -ErrorAction SilentlyContinue
    exit $EXIT_REQUEUE
}

# Rebuild-Container VIVE EN atmos-lib.ps1 desde el 31/08/2026.
#
# Estaba aqui, y los otros CUATRO scripts que la necesitan (audio_encode.ps1,
# sanear.ps1, reconstruir-contenedor.ps1 y retrofit-reconstruir.ps1) no podian
# cargarla de forma normal: encode.ps1 tiene parametros obligatorios y
# dot-sourcearlo lo ejecutaria entero. Se la sacaban con el parser de
# PowerShell, un bloque de doce lineas REPETIDO CUATRO VECES.
#
# Eso mordio dos veces el 29/08/2026: el retrofit carga la funcion en memoria
# al arrancar, asi que cada arreglo obligaba a pararlo y relanzarlo, y una vez
# se dio por bueno un pase que estaba corriendo con la version vieja.
#
# atmos-lib.ps1 ya la cargan los cinco, asi que ahora un cambio se nota al
# instante y no hay cuatro copias del truco que mantener.
#
# La bateria de pruebas vive en pruebas/test-reconstruir.ps1.

# Ficheros de estado con nombre FIJO: el panel (app.py) los lee por estas rutas
# exactas para mostrar progreso en vivo y para que funcionen Stop/Skip.
# (Solo corre un encode a la vez, asi que no hay riesgo de colision.)
# Ficheros de estado. En modo SubsOnly usan su propio prefijo: si no, un trabajo
# de subtitulos escribiria en encode_status y apareceria en la pestana Encoder
# del panel, pisando el estado del pipeline de video.
# La ranura 1 conserva 'encode' a proposito (ver -Slot): el panel lee ese
# nombre y todo lo que ya funciona sigue igual. Solo la 2 en adelante
# cambian, y son las que hoy no existen.
$StatePfx    = if ($SubsOnly) { "subs" } elseif ($Slot -le 1) { "encode" } else { "encode$Slot" }
$ProgFile    = Join-Path $Tmp "${StatePfx}_ffprog"
$StatusFile  = Join-Path $Tmp "${StatePfx}_status"
$PidFile     = Join-Path $Tmp "${StatePfx}_pid"
# El stderr de ffmpeg si puede ser unico por encode (el panel no lo lee).
# Solo el stamp, NO $Name: los nombres de peli traen corchetes ("[UHDReescalado
# 2160p HDR]") y Start-Process -RedirectStandardError trata la ruta como patron
# WILDCARD -en PowerShell [...] es una clase de caracteres-, no la resuelve a un
# fichero y revienta con $proc=$null -> "Failed (ffmpeg no arranco)". El stamp
# basta (solo corre un encode a la vez) y el barrido encode_ff_stderr_* lo casa.
$FfErr       = Join-Path $Tmp "encode_ff_stderr_${stamp}.txt"

# El panel mata el trabajo por este PID. Escribimos el PID de ESTE proceso
# (encode.ps1) YA, no el de ffmpeg: durante la fase de audio (truehdd/dee, que en
# un Atmos son ~20 min) ffmpeg AUN NO EXISTE, y antes el fichero quedaba con el
# PID de ffmpeg de un encode anterior (muerto). Por eso Stop/Skip del panel no
# mataban nada en esa fase. Un taskkill /T /F sobre el PID de encode.ps1 se lleva
# TODO el arbol del trabajo (ffmpeg, dee, truehdd, deew, dotnet-OCR, mkvextract),
# en cualquier fase. El PID de ffmpeg, por si hace falta, va aparte mas abajo.
$PID | Set-Content -LiteralPath $PidFile

# -- Plex-friendly naming ------------------------------------------
if ($Name -match '^(.*)[._](S[0-9]{2}E[0-9]{2,3})') {
    $title = ($Matches[1] -replace '[._]', ' ').Trim()
    $CleanName = "$title - $($Matches[2])"
}
elseif ($Name -match '^(.*)[._]([12][0-9]{3})([._]|$)') {
    $title = ($Matches[1] -replace '[._]', ' ').Trim()
    $CleanName = "$title ($($Matches[2]))"
}
else {
    $CleanName = ($Name -replace '[._]', ' ').Trim()
}

if ($SubsOnly) {
    # SubsOnly conserva el nombre ORIGINAL. El renombrado "Plex-friendly" de
    # arriba (puntos y guiones bajos -> espacios, "Titulo (Anyo)") tiene sentido
    # cuando el fichero se reencoda y pasa a ser una version nueva; aqui solo
    # cambian los subtitulos y esperas que salga tal y como entro.
    $CleanName = $Name
}

# Marcador de "trabajo en vuelo" con la ruta de la SALIDA. encode.ps1 lo borra
# al terminar (bien o mal). Si el watcher lo encuentra despues de que este
# proceso muera, es que nos mataron (Stop/Skip del panel = taskkill /F /T, que
# NO ejecuta ni finally ni nada): el watcher borra la salida parcial de
# encoded/ y deja el status en idle. Se escribe AQUI, antes de la fase de
# audio, para que un Stop durante truehdd/dee tambien quede cubierto.
$Output    = Join-Path $EncodedDir "$CleanName.mkv"
$OutMarker = Join-Path $Tmp "${StatePfx}_outfile"
WriteNoBom $OutMarker $Output

Log "Analizando fuente..."

# ESTADO INMEDIATO PARA EL PANEL. Hasta hoy el primer estado no se escribia hasta
# bien entrado el trabajo, asi que durante el analisis y la VERIFICACION de la
# fuente -que lee el fichero entero, minutos en un MKV de 40-70 GB- el panel
# seguia mostrando el 'status=idle' que dejo el trabajo anterior: "No active
# encode" con la maquina trabajando.
# Aqui aun no se conoce la duracion (la saca el Probe de abajo), asi que va a 0:
# el panel lo tolera y lo unico que importa en esta fase es que aparezca el
# nombre del fichero y que algo se mueve.
WriteNoBom $StatusFile "status=encoding`nfile=$CleanName.mkv`nduration=0`nstage=analizando`npct=0"

# -- Probe ---------------------------------------------------------
$Width = Probe "v:0" "stream=width" $InputFile
if ($Width -match '^\d+') { $Width = [int]$Matches[0] } else { $Width = 1920 }
$Height = Probe "v:0" "stream=height" $InputFile
if ($Height -match '^\d+') { $Height = [int]$Matches[0] } else { $Height = 1080 }

# -- Resolucion: por LAS DOS DIMENSIONES, no solo por el ancho -------------
# Se decide AQUI, y no abajo junto al bitrate, porque la reserva de disco del
# temporal de video (fase de audio, mas arriba en el tiempo) necesita saber ya
# que techo aplica, y tener la regla escrita dos veces es como se empieza a
# divergir.
#
# 17/08/2026: esto miraba SOLO el ancho y un UHD ULTRAPANORAMICO se colaba como
# 1080p. Caso real: 'Obsession (2026)' viene a 3240x2160 -2160 lineas, 4K en
# todos los sentidos- y por medir 3240 de ancho caia en la rama de 1080p:
# target 8.0M en vez de 10.5, techo de 12 GB en vez de 16 y denoise 7 en vez de
# 10. O sea un 4K encodeado con perfil de 1080p.
# Se miran las dos dimensiones porque las dos formas de 4K existen:
#   3840x1606  (scope, con las barras ya recortadas) -> manda el ANCHO
#   3240x2160  (ultrapanoramico)                     -> manda el ALTO
# El umbral de alto es 1700 para NO tragarse un 1440p (2560x1440), que no es UHD.
$Downscale8K = $false
if     ($Width -ge 7600 -or $Height -ge 4000) { $Res = "4K"; $Downscale8K = $true }
elseif ($Width -ge 3800 -or $Height -ge 1700) { $Res = "4K" }
else                                          { $Res = "1080p" }

# 22/08/2026: derivado del perfil de ESTA resolucion (arriba, junto a
# $ParallelAudioVideo). $true = se ponen -b:v/-maxrate/-bufsize; $false = ICQ puro.
# Separado por resolucion el 25/08/2026: ver el comentario largo de alla arriba.
$CfgPerfil  = if ($Res -eq '4K') { $CfgPerfil4K } else { $CfgPerfil1080p }
# -RateMode manda sobre el perfil de la resolucion, SOLO en este trabajo. El
# porque de que exista: los dos modos tienen sesgos OPUESTOS y ninguno gana
# siempre -QVBR castiga por duracion (el techo de tamano baja el target de las
# largas) e ICQ castiga por grano (Traffic pide 15,98 Mbps en 1080p)-, asi que la
# eleccion buena depende de la pelicula y solo la puede hacer quien la mira.
# 'auto' deja exactamente el comportamiento de siempre.
$RateModeForzado = ($RateMode -ne 'auto')
if ($RateModeForzado) { $CfgPerfil = if ($RateMode -eq 'icq') { 'icq' } else { 'techo' } }
$UseRateCap = ($CfgPerfil -ne 'icq')

$ColorTr = Probe "v:0" "stream=color_transfer" $InputFile
$ColorRange = (Probe "v:0" "stream=color_range" $InputFile) -replace '[\s,]',''

# Codec y formato de pixel del ORIGEN. No se usan para decidir nada todavia:
# van al jsonl para poder responder con datos a una pregunta abierta -- si
# merece la pena NO recodificar los origenes que ya son HEVC eficiente y
# limitarse a remuxear el video en copy.
# Para contestarla hacen falta dos cosas que ahora mismo no se saben:
#   1. cuanto bitrate pide el GQ en 1080p (lo mide icq-probe.ps1 -Res 1080p)
#   2. que fraccion del catalogo llega ya en HEVC, que es lo que registra esto
# El pix_fmt importa porque muchos HEVC 1080p vienen en 8 bits: copiarlos tal
# cual perderia el paso a main10, que es la defensa principal contra el banding.
$SrcCodec  = (Probe "v:0" "stream=codec_name" $InputFile) -replace '[\s,]',''
$SrcPixFmt = (Probe "v:0" "stream=pix_fmt"    $InputFile) -replace '[\s,]',''

$durRaw = Probe "" "format=duration" $InputFile
$Duration = 0
if ($durRaw -match '^[0-9.]+') { $Duration = [int][double]$Matches[0] }
if ($Duration -le 0) {
    # Dos fallos MUY distintos acababan aqui con el mismo mensaje mudo:
    #   a) ffprobe lee el fichero pero el contenedor no declara duracion.
    #   b) ffprobe NO PUEDE LEER EL FICHERO EN ABSOLUTO (sale con codigo != 0 y
    #      sin escribir nada). Entonces han fallado TAMBIEN los sondeos de
    #      arriba: $Width se quedo en su valor por defecto (1920), $ColorTr y
    #      $SrcPixFmt vacios, y mas abajo no se encontraria ni una pista de audio.
    #
    # La diferencia importa mucho mas de lo que parece. El 07/08/2026 llego un
    # MKV 4K HDR con un VobSub roto ("Picture size 0x0 is invalid"): ffprobe abre
    # un decodificador por cada pista antes de informar de nada, ese subtitulo le
    # hacia abortar entero, y TODOS los sondeos devolvian vacio. El fichero estaba
    # perfectamente -mkvmerge lo leia sin pestanyear, 3840x2160, 145 min-.
    # Por eso NO se cae aqui a un plan B que saque la duracion de otro sitio
    # (ffmpeg -i y mkvmerge -J la dan sin problema, se comprobo): con la duracion
    # resuelta el script habria seguido adelante creyendo que es un 1080p SDR sin
    # audio, y habria encodeado una peli 4K HDR con ajustes de 1080p EN SILENCIO.
    # Un plan B aqui no arregla el trabajo: lo vuelve peligroso.
    #
    # Lo que si se hace es DECIR QUE PASA, porque diagnosticarlo a mano cuesta.
    $motivo = ''
    try {
        $tmpErr = Join-Path $Tmp ("probefail_{0}.txt" -f $PID)
        # -v WARNING, no -v error: la linea que de verdad senyala al culpable
        # ("Could not open codec for input stream N") ffprobe la emite a nivel
        # warning, asi que con -v error -el que usa Probe- NO aparece y solo
        # quedan avisos de adorno del decoder. Comprobado: error=5 lineas sin
        # ella, warning=10 con ella. Tampoco se sube a 'info', que son 96 lineas
        # de volcado de metadatos donde se pierde.
        $pp = Start-Process -FilePath $FFPROBE -NoNewWindow -Wait -PassThru `
              -ArgumentList @('-v','warning','-show_entries','format=duration',
                              '-of','default=nk=1:nw=1', ('"' + $InputFile + '"')) `
              -RedirectStandardOutput 'NUL' -RedirectStandardError $tmpErr
        if ($pp.ExitCode -ne 0) {
            $lineas = @(Get-Content -LiteralPath $tmpErr -ErrorAction SilentlyContinue)
            # 1a opcion: la que nombra la pista que no se pudo abrir. Es LA util:
            # dice exactamente que pista hay que quitar para desatascar el fichero.
            $clave = @($lineas | Where-Object { $_ -like '*Could not open codec*' } | Select-Object -First 1)
            # Si no la hay, la ultima que no sea ruido repetido del decoder.
            if (-not $clave.Count) {
                $clave = @($lineas | Where-Object { $_ -notmatch 'IMGUTILS|Picture size' } | Select-Object -Last 1)
            }
            if (-not $clave.Count) { $clave = @($lineas | Select-Object -Last 1) }
            $motivo = "ffprobe no puede leer el fichero (exit $($pp.ExitCode)): $($clave[0])"
        } else {
            $motivo = "el contenedor no declara duracion"
        }
        Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue
    } catch {
        $motivo = "no se pudo determinar el motivo ($_)"
    }
    Log "ERROR: cannot read duration -> $motivo"
    if ($motivo -like 'ffprobe no puede leer*') {
        Log "  El fichero puede estar PERFECTAMENTE: a ffprobe le basta UNA pista"
        Log "  ilegible (tipico: un VobSub sin dimensiones) para abortar el sondeo"
        Log "  entero. Comprueba con:  mkvmerge -J `"$InputFile`""
        Log "  Si mkvmerge lo lee bien, remuxea quitando la pista que ffprobe"
        Log "  nombra ahi arriba y vuelve a encolarlo."
    }
    # status=error: SIN esto el panel se quedaba con el 'status=encoding' que se
    # escribe al empezar y mostraba un encode fantasma para siempre (el marcador
    # se borra justo abajo, asi que Clean-JobLeftovers tampoco lo devolvia a idle).
    # Era el unico camino de salida temprana al que se le olvidaba; el de "Fuente
    # danyada", 30 lineas mas abajo, siempre lo hizo bien.
    WriteNoBom $StatusFile "status=error`nfile=$CleanName.mkv`nduration=0`nerror=$motivo"
    Remove-Item -LiteralPath $OutMarker -ErrorAction SilentlyContinue   # salida controlada
    exit 1
}

# -- Verificacion de la fuente -------------------------------------
# Va AQUI a proposito: antes de la fase de audio (truehdd/DEE, ~20 min en un
# Atmos) y antes del encode. Un fichero truncado reventaba al final de todo,
# despues de haber quemado horas. Salida controlada identica a la de arriba:
# status=error + borrado del marcador para que el watcher no lo pise.
if ($VerifySource -ne "off") {
    Log "Verificando la fuente ($VerifySource)..."
    # Aqui la duracion YA se conoce, asi que el panel puede pintar la barra.
    # Esta fase decodifica el fichero (entero si VerifySource='full'), o sea
    # minutos de trabajo real sin nada que mostrar si no se reporta.
    # SIN fps_src a proposito: se calcula mas abajo (L576) y aqui saldria vacio.
    # En esta fase no hace falta: el % viene de encode_status, no de fotogramas.
    WriteNoBom $StatusFile "status=encoding`nfile=$CleanName.mkv`nduration=$Duration`nstage=verificando`npct=0"
    $vWhere = ""
    if ($VerifySource -eq "full") {
        if (-not (Test-Decode $InputFile @())) { $vWhere = "decodificacion completa" }
    } else {
        if (-not (Test-Decode $InputFile @('-t','15'))) {
            $vWhere = "inicio del fichero"
        } elseif (-not (Test-Decode $InputFile @('-ss', "$([Math]::Max(0, $Duration - 20))"))) {
            $vWhere = "final del fichero (truncado?)"
        }
    }
    if ($vWhere) {
        Log "ERROR: la fuente NO supera la verificacion ($vWhere). No se encoda."
        # QUE vio ffmpeg. Sin esto el error era un callejon sin salida: habia que
        # reconstruir el comando a mano para averiguar si el fichero estaba roto de
        # verdad o era un aviso inocuo (ver Get-RealDecodeErrors).
        if ($script:LastDecodeError) { Log "  motivo: $($script:LastDecodeError)" }
        WriteNoBom $StatusFile "status=error`nfile=$CleanName.mkv`nduration=$Duration`nerror=Fuente danyada: $vWhere"
        Remove-Item -LiteralPath $OutMarker -ErrorAction SilentlyContinue
        exit 1
    }
    Log "Fuente verificada OK."
}

$BitrateSrc = 0
$bps = Probe "v:0" "stream_tags=BPS" $InputFile
if ($bps -match '^\d+') { $BitrateSrc = [long]$Matches[0] }
if ($BitrateSrc -eq 0) {
    $br = Probe "v:0" "stream=bit_rate" $InputFile
    if ($br -match '^\d+') { $BitrateSrc = [long]$Matches[0] }
}
$SourceBytes = (Get-Item -LiteralPath $InputFile).Length
if ($BitrateSrc -eq 0 -and $SourceBytes -gt 0) {
    $BitrateSrc = [long](($SourceBytes * 8) / $Duration)
    Log ("Video bitrate unavailable - estimated from size: {0:N1}M" -f ($BitrateSrc/1e6))
}

$FpsSrc = Probe "v:0" "stream=r_frame_rate" $InputFile
$FpsSrc = ($FpsSrc -split ',')[0].Trim()   # ffprobe csv a veces deja coma final ("24/1,") y rompe el parseo de fps_src en el panel

# -- Atmos detection -----------------------------------------------
$AudioCount = 0
$acIdx = Probe "a" "stream=index" $InputFile
if ($acIdx) { $AudioCount = ($acIdx -split "`n").Count }

$AtmosFlags = @{}
if ($TruehdMode -in @("atmos","atmos_ddp","convert")) {
    # Atmos por pista via ffprobe 'profile' (sin MediaInfo GUI). Se consulta por
    # indice para mantener la alineacion exacta con $AtmosFlags[$idx]. Se calcula
    # en todos los modos que convierten (para elegir bitrate DDP y titular la pista).
    for ($ai = 0; $ai -lt $AudioCount; $ai++) {
        $prof = Probe "a:$ai" "stream=profile" $InputFile
        $AtmosFlags[$ai] = ($prof -match '(?i)atmos')
    }
}
function TruehdAction([int]$idx) {
    # "ddp"  -> convertir a DDP (E-AC-3) via DEE (Atmos preservado si lo hay)
    # "copy" -> dejar el TrueHD tal cual
    switch ($TruehdMode) {
        "convert"   { return "ddp" }
        "atmos"     { if ($AtmosFlags[$idx]) { return "copy" } else { return "ddp" } }
        "atmos_ddp" { return "ddp" }
        default     { return "copy" }
    }
}

# -- Audio classification + dedup ----------------------------------
# Pass 1: clasificar cada pista (copy vs transcode), estimar su bitrate de
#         salida y detectar idioma/canales/titulo.
# Pass 2: descartar transcodes redundantes cuando ya existe una COPIA
#         (passthrough) del MISMO idioma con >= canales (asi nunca perdemos
#         canales: no se tira un 5.1 por un 2.0). Las pistas 'und' NUNCA se
#         descartan y siempre queda >= 1 pista por idioma.
$AudioPlan = @()
for ($ai = 0; $ai -lt $AudioCount; $ai++) {
    $codec = (Probe "a:$ai" "stream=codec_name" $InputFile).ToLower()
    $lang  = Probe "a:$ai" "stream_tags=language" $InputFile; if (-not $lang) { $lang = "und" }
    $chRaw = Probe "a:$ai" "stream=channels" $InputFile
    $ch = 2; if ($chRaw -match '^\d+') { $ch = [int]$Matches[0] }
    # Bitrate de la pista. En MKV 'stream=bit_rate' suele venir VACIO (Matroska no
    # lo guarda por stream), asi que se cae al tag BPS que escribe mkvmerge, que es
    # de donde lo saca el resto del script. Sin este apanyo, $abr era 0 en casi
    # todos los remux y las reglas que dependen de el no se disparaban nunca.
    $abrRaw = Probe "a:$ai" "stream=bit_rate" $InputFile
    $abr = 0; if ($abrRaw -match '^\d+') { $abr = [long]$Matches[0] }
    if ($abr -le 0) {
        $bpsRaw = Probe "a:$ai" "stream_tags=BPS" $InputFile
        if ($bpsRaw -match '^\d+') { $abr = [long]$Matches[0] }
    }
    $atitle      = Probe "a:$ai" "stream_tags=title" $InputFile
    $atitleClean = Repair-Mojibake $atitle
    # Comentarios/audiodescripcion: por la disposition del contenedor (fiable) o
    # por el titulo (para los releases que no la marcan).
    $adisp = Probe "a:$ai" "stream_disposition=comment" $InputFile
    $isComment = ($adisp -match '^1') -or ($atitleClean -match $CommentPattern)
    # Doblaje/mezcla alternativa: mismo idioma y canales pero CONTENIDO distinto.
    # No se recodifica (no es voz, es la pelicula entera), solo se exime del dedup.
    $isAltMix = [bool]($atitleClean -match $AltMixPattern)
    if ($isAltMix -and -not $isComment) {
        Log ("  Audio {0}: [{1}] '{2}' -> doblaje/mezcla alternativa, exenta de dedup" -f $ai,$lang,$atitleClean)
    }

    # $ddpK: los kbps QUE SE LE VAN A PEDIR A DEE. Se guarda en el plan porque
    # los tres sitios que lo necesitan despues -la conversion en paralelo, la
    # secuencial y el TITULO del MKV- lo recalculaban con Get-DdpBitrate, que
    # solo mira canales. Desde que una pista lossy multicanal puede ir a DEE con
    # un bitrate dimensionado sobre el origen, recalcular ahi daria otra cifra:
    # se convertiria a 256k y el MKV diria "DDP 640k". Es exactamente el fallo
    # que audio_encode.ps1 ya arreglo el 27/08/2026 con su campo Bps.
    $ddpK = 0
    $action = "transcode"; $tgt = ""; $est = 0
    if ($codec -in @('truehd','mlp')) {
        if ((TruehdAction $ai) -eq "ddp") {
            # TrueHD -> DDP via DEE (deew). Atmos preservado como JOC si lo hay.
            $isAtmos = [bool]$AtmosFlags[$ai]
            $bps = Get-DdpBitrate $isAtmos $ch $DeewBitrateAtmos
            $ddpK = $bps
            $action = "ddp"; $tgt = "${bps}k"; $est = ($bps * 1000)
        } else {
            $action = "copy"
            $b = Probe "a:$ai" "stream_tags=BPS" $InputFile
            if ($b -match '^\d+') { $est = [long]$Matches[0] } else { $est = 4000000 }
        }
    }
    elseif ($codec -in @('ac3','eac3','aac','mp3')) {
        # Los que el TV decodifica de forma nativa: se copian tal cual.
        # OPUS SALIO DE ESTA LISTA el 04/08/2026: los Samsung NO lo decodifican
        # ([[av-playback-setup]]), asi que copiarlo solo conseguia que Plex
        # acabara transcodificando en reproduccion, que es justo lo que este
        # pipeline existe para evitar. Ahora cae al bloque de abajo.
        # MP3 ENTRO el 05/08/2026. El TV lo decodifica, asi que reencodearlo a
        # EAC3 solo anyadia una generacion de perdida y CPU a cambio de nada. Era
        # ademas el ultimo desacuerdo entre los tres sitios que deciden esto: el
        # pipeline de solo-audio y el 'nativo' de remuxlib.py ya lo copiaban.
        # Esta lista es LA lista: si se toca, tocar tambien audio_encode.ps1
        # ($nativoTv) y remuxlib.py ('nativo').
        $action = "copy"
        # $estAdivinado: cuando no hay dato de bitrate se usa un defecto de
        # 640000, que es EXACTAMENTE el umbral del tope. Sin esta bandera, una
        # pista sin tag BPS se capaba sobre una suposicion. Visto en la prueba con
        # un AAC 5.1 de Pulp Fiction que no traia BPS.
        $estAdivinado = $false
        $b = Probe "a:$ai" "stream_tags=BPS" $InputFile
        if ($b -match '^\d+') { $est = [long]$Matches[0] }
        else {
            $b2 = Probe "a:$ai" "stream=bit_rate" $InputFile
            if ($b2 -match '^\d+') { $est = [long]$Matches[0] } else { $est = 640000; $estAdivinado = $true }
        }

        # -- TECHO del audio copiado (Get-CopyAudioCapK, en atmos-lib.ps1) ---
        # El 'profile' se sondea SIEMPRE que la pista se pase del tope: es lo
        # unico que delata un E-AC-3 con Atmos, y $AtmosFlags no vale porque solo
        # se rellena cuando el fichero trae TrueHD.
        $profAud = ''
        # El umbral mas BAJO de los dos (el de estereo): por debajo de el ninguna
        # pista puede ser capada, asi que sondear el profile seria un ffprobe en balde.
        if ($est -ge ($MinCopyAudioTriggerStereoK * 1000)) { $profAud = Probe "a:$ai" "stream=profile" $InputFile }
        $capK = if ($estAdivinado) { 0 } else { Get-CopyAudioCapK -Ch $ch -Bps $est -Profile $profAud -Codec $codec }
        if ($capK -gt 0) {
            Log ("  Audio {0}: {1} {2}ch a {3}k pasa del tope de {4}k -> eac3 {4}k" -f `
                 $ai, $codec, $ch, [int]($est/1000), $capK)
            $action = 'transcode'
            $tgt = "${capK}k"
            $est = ($capK * 1000)
        } elseif ($profAud -match '(?i)atmos|joc') {
            Log ("  Audio {0}: {1} {2}ch a {3}k -> se COPIA pese al tope: lleva Atmos (objetos)" -f `
                 $ai, $codec, $ch, [int]($est/1000))
        }
    }
    else {
        # AQUI CAE TODO LO QUE EL TV NO DECODIFICA: DTS, FLAC, PCM, Opus, Vorbis,
        # MP2, WMA... Ninguno se copia nunca. Copiarlos no "conserva" nada: el fichero
        # se reproduce por la app del TV, y lo que el TV no entiende lo acaba
        # transcodificando Plex en cada reproduccion, con peor resultado y sin
        # control. Ver [[av-playback-setup]].
        #
        # DOS DESTINOS, y LA REGLA NO VIVE AQUI (02/09/2026): esta en
        # Test-DeeWorthy, dentro de atmos-lib.ps1, porque la necesitan los dos
        # motores y las dos copias HABIAN DIVERGIDO. Hasta hoy esta linea era
        #     dts -or ((flac|pcm_*) -and ch>2)
        # o sea que un Opus 5.1 o un ALAC 5.1 se iban al eac3 de ffmpeg mientras
        # audio_encode.ps1 los mandaba a DEE, y un FLAC estereo al reves.
        # Ahora los dos preguntan a la misma funcion:
        #   - DD+ por DEE  : DTS (a cualquier numero de canales) y todo lo
        #     MULTICANAL. El encoder de Dolby es mejor a igual bitrate y maneja el
        #     7.1 solo.
        #   - eac3 ffmpeg  : estereo y mono. Pasar un estereo por DEE cuesta
        #     minutos y no aporta nada; mismo criterio que ya se aplica a los
        #     comentarios mas abajo.
        # Nota: la rama sin Atmos de Convert-TrueHDToDDP extrae la pista a .mka y
        # se la pasa a deew SIN mirar el codec, asi que le vale DTS, FLAC, PCM o
        # un Opus 5.1. DTS:X pierde los objetos de todas formas (no existe decoder
        # de objetos DTS:X): queda el lecho, aqui y en cualquier otra ruta.
        #
        # Codecs CON PERDIDA que suelen venir a bitrate bajo (Opus 128k, Vorbis
        # 96k...). Importa en LAS DOS ramas: para el eac3 fija el bitrate sobre el
        # origen, y para DEE evita que un Opus 5.1 de 256k se lleve los 640k de la
        # tabla por canales -que es justo lo que costaria mandarlo a DEE sin mirar.
        # 'mp3' YA NO esta aqui: desde el 05/08/2026 se copia (el TV lo decodifica)
        # y nunca llega a este bloque. Dejarlo en la lista habria sido una rama
        # muerta, que es justo el olor que delato el hueco de $noNativo en
        # audio_encode.ps1.
        $esLossyBajo = $codec -in @('opus','vorbis','mp2','wmav2','wmapro')
        $esDeeWorthy = Test-DeeWorthy -Codec $codec -Ch $ch

        if ($esDeeWorthy) {
            $ddpK = if ($esLossyBajo -and $abr -gt 0) { Get-DdpBitrateForLossy $ch $abr }
                    else { Get-DdpBitrate $false $ch $DeewBitrateAtmos }
            $action = "ddp"; $tgt = "${ddpK}k"; $est = ($ddpK * 1000)
            Log ("  Audio {0}: {1} {2}ch a {3}k -> DD+ {4}k (DEE)" -f `
                 $ai,$codec,$ch,[int]($abr/1000),$ddpK)
        }
        else {
            # Solo llega estereo/mono: Test-DeeWorthy ya se ha llevado a DEE todo
            # lo de mas de 2 canales. El "cuanto" tambien es compartido
            # (Get-Eac3BitrateK, en atmos-lib.ps1), que es donde estaban los suelos
            # y techos que antes se escribian a mano justo aqui.
            $k = Get-Eac3BitrateK -Ch $ch -SrcBps $abr -LossyBajo $esLossyBajo
            $tgt = "${k}k"; $est = ($k * 1000)
            Log ("  Audio {0}: {1} {2}ch a {3}k -> eac3 {4}k (ffmpeg)" -f `
                 $ai,$codec,$ch,[int]($abr/1000),$k)
        }
    }

    # -- Override de comentarios ------------------------------------
    # Va DESPUES de la clasificacion por codec para que gane a todo, incluido el
    # 'ddp' via DEE: un comentario TrueHD pasando por Dolby Encoder a 768k no
    # tiene ningun sentido.
    $forceAc = 0
    if ($isComment) {
        $curK = 0; if ($est -gt 0) { $curK = [int]($est / 1000) }
        if ($ch -le 2 -and $curK -gt 0 -and $curK -le $CommentKeepMaxK) {
            $action = 'copy'
            Log ("  Audio {0}: comentario [{1}] ya en {2}k {3}ch -> se copia sin tocar" -f $ai,$lang,$curK,$ch)
        } else {
            $action = 'transcode'; $forceAc = 2
            $tgt = "${CommentBitrateK}k"; $est = ($CommentBitrateK * 1000)
            Log ("  Audio {0}: comentario [{1}] {2} {3}ch {4}k -> eac3 estereo {5}k" -f `
                 $ai,$lang,$codec,$ch,$curK,$CommentBitrateK)
        }
    }

    $AudioPlan += [pscustomobject]@{
        Idx = $ai; Codec = $codec; Lang = $lang; Ch = $ch; Abr = $abr
        Action = $action; Tgt = $tgt; Est = $est; Keep = $true; DdpK = $ddpK
        Title = $atitle; TitleClean = $atitleClean
        IsComment = $isComment; ForceAc = $forceAc
        IsAltMix = $isAltMix; Exempt = ($isComment -or $isAltMix)
    }
}

# Pass 2: dedup por idioma (excepto 'und' y excepto pistas EXENTAS)
# Exentas = comentarios/audiodescripcion + doblajes y mezclas alternativas.
# Lo de los comentarios no es un detalle menor: al recodificarlos pasan a
# 'transcode', y como existe una copia del mismo idioma con mas canales (la
# pista principal), el dedup los BORRARIA. Tampoco valen como 'superset' para
# descartar a otros: son contenido distinto. Lo mismo vale para un redoblaje.
foreach ($grp in ($AudioPlan | Where-Object { $_.Lang -ne 'und' } | Group-Object Lang)) {
    $copies = @($grp.Group | Where-Object { $_.Action -eq 'copy' -and -not $_.Exempt })
    if ($copies.Count -eq 0) { continue }
    foreach ($t in @($grp.Group | Where-Object { $_.Action -eq 'transcode' -and -not $_.Exempt })) {
        $superset = $copies | Where-Object { $_.Ch -ge $t.Ch } | Select-Object -First 1
        if ($superset) {
            $t.Keep = $false
            Log ("  Audio {0}: DEDUP [{1}] {2} {3}ch transcode -> descartado (ya hay copia {4} {5}ch)" -f `
                 $t.Idx,$t.Lang,$t.Codec,$t.Ch,$superset.Codec,$superset.Ch)
        }
    }
}

# Pass 2b: dedup entre PASSTHROUGH del mismo idioma (copy/ddp contra copy/ddp)
# El hueco que tapa: 2a solo mira pistas 'transcode', y ac3/eac3/aac se
# clasifican como 'copy', asi que un EAC3 5.1 y un AC3 5.1 en el mismo idioma
# nunca se comparaban entre si y salian las dos en el fichero final.
# Criterio: gana la de MAS CANALES; a igualdad de canales, la de mas bitrate.
# Solo se descartan las que tienen <= canales que la ganadora, asi que es
# imposible perder canales por el camino. Siempre queda >= 1 pista por idioma.
# Comentarios, doblajes alternativos y 'und' quedan fuera, igual que en 2a.
if ($DedupPassthrough) {
    foreach ($grp in ($AudioPlan | Where-Object { $_.Lang -ne 'und' -and -not $_.Exempt } | Group-Object Lang)) {
        $pass = @($grp.Group | Where-Object { $_.Keep -and $_.Action -in @('copy','ddp') })
        if ($pass.Count -lt 2) { continue }
        $best = $pass | Sort-Object -Property @{Expression={$_.Ch};Descending=$true}, `
                                              @{Expression={$_.Est};Descending=$true} | Select-Object -First 1
        foreach ($o in $pass) {
            if ($o.Idx -eq $best.Idx) { continue }
            if ($o.Ch -le $best.Ch) {
                $o.Keep = $false
                # El mensaje se reescribio el 05/08/2026 porque se leia mal. Ponia
                # los dos bitrates seguidos como si fueran comparables, y NO lo son:
                # el de la descartada es su bitrate de ORIGEN, mientras que el de la
                # ganadora es su bitrate de DESTINO si va a convertirse. Un TrueHD
                # 8ch salia como "768k" -lo que va a ocupar el DD+ Atmos- al lado de
                # un AC3 "640k" que era su tasa real, y parecia que se estaba
                # quedando con la peor. Ahora se dice explicitamente en que se
                # convierte la ganadora, y el bitrate de origen va entre parentesis.
                $oBr   = [int]($o.Est/1000)
                $bBr   = [int]($best.Est/1000)
                $bDest = if ($best.Action -eq 'ddp') {
                             if ($AtmosFlags[$best.Idx]) { " -> DD+ Atmos ${bBr}k" }
                             else                        { " -> DD+ ${bBr}k" }
                         } else { " ({0}k)" -f $bBr }
                Log ("  Audio {0}: DEDUP [{1}] {2} {3}ch ({4}k) -> descartado; se queda a:{5} {6} {7}ch{8}" -f `
                     $o.Idx,$o.Lang,$o.Codec,$o.Ch,$oBr, `
                     $best.Idx,$best.Codec,$best.Ch,$bDest)
            }
        }
    }
}

# -- Pre-generar DDP (.ec3) via DEE para las pistas TrueHD marcadas ------
# Se hace ANTES del calculo de tamano para que la estimacion use el bitrate real.
# Si deew no esta o falla, la pista cae a EAC3 de ffmpeg (fallback, sigue reduciendo).
$AtmosEc3 = @{}
# Se comprueba el binario que REALMENTE se usa (el standalone de C:\scripts\bin,
# por ruta absoluta), no un 'deew' del PATH. Antes esto miraba el PATH, donde
# vive el deew 2.9.5 de pip: podia dar OK mientras atmos-lib llamaba a otro, o
# al reves, tirar las pistas al eac3 de ffmpeg teniendo el binario bueno ahi.
$DeewExe = 'C:\scripts\bin\deew.exe'
$DeewOk = Test-Path -LiteralPath $DeewExe

# Progreso durante la fase de AUDIO (para el panel).
# El problema: truehdd+dee tardan ~20 min por pelicula y ffmpeg todavia no ha
# arrancado, asi que encode_ffprog no existe (o peor: conserva los datos del
# trabajo ANTERIOR, y app.py los leeria como si fueran de este).
# (La nota vieja decia que app.py traducia 'progress=end' a status=idle/pct=100.
#  Eso dejo de ser cierto el 04/08/2026, cuando enc_read_progress paso a cortar
#  el fichero por 'progress=': el bloque que devuelve ya no incluye su propio
#  terminador. Corregido en las dos puntas el 26/08/2026 -app.py vuelve a
#  exponer la clave y su rama ya no puede tapar las fases de post-proceso-, pero
#  el borrado de aqui sigue siendo lo que de verdad evita el problema.)
# Resultado: el panel se queda en blanco todo ese rato y parece colgado.
# Se borra el ffprog viejo YA y se reporta stage/pct en encode_status, que es lo
# que app.py lee cuando no hay progreso de ffmpeg.
Remove-Item -LiteralPath $ProgFile -ErrorAction SilentlyContinue
$AudioProgress = {
    param($stage, $pct)
    WriteNoBom $StatusFile "status=encoding`nfile=$CleanName.mkv`nduration=$Duration`nfps_src=$FpsSrc`nstage=$stage`npct=$pct"
}

if ($SubsOnly) {
    # El audio no se toca: ni se convierte ni se descarta ninguna pista. El plan
    # ya esta construido, asi que basta con anularlo aqui; el bucle de conversion
    # de abajo no encontrara nada que hacer y el constructor de mapas lo pasara
    # todo a copy.
    foreach ($p in $AudioPlan) { $p.Action = 'copy'; $p.Keep = $true }
    Log "SubsOnly: video y audio intactos (copy, sin descartar pistas). Solo se procesan los subtitulos."
}

# -- PARALELISMO ENTRE PISTAS DE ESTA MISMA PELICULA -----------------------
# Muchas pelis traen 2 pistas Atmos (spa + eng) y hasta ahora se convertian una
# detras de otra. Medido el 06/08/2026 con peliculas completas:
#     K=2 -> 1,62x (81 % de eficiencia)    <- lo que se hace aqui
#     K=4 -> 2,65x (66 %)                  <- exigiria relajar el pipeline.lock
# Esto NO toca el lock: sigue habiendo un solo TRABAJO a la vez, asi que no se
# reabre ninguno de los fallos de concurrencia entre trabajos que el lock evita.
#
# Poner $ParallelDdpTracks = 1 lo desactiva por completo y se vuelve al bucle de
# siempre, sin tocar nada mas.
$ParallelDdpTracks = 2

$ddpPend = @($AudioPlan | Where-Object { $_.Keep -and $_.Action -eq 'ddp' -and
                                         ([bool]$AtmosFlags[$_.Idx] -or $DeewOk) })
# Ranuras de conversion. Se construyen SIEMPRE, las use el camino en serie o el
# solapado, para que los dos hablen de las mismas pistas y de los mismos .ec3.
$tracks = @($ddpPend | ForEach-Object {
    @{ Idx = $_.Idx
       Bitrate = $(if ($_.DdpK -gt 0) { $_.DdpK } else { Get-DdpBitrate ([bool]$AtmosFlags[$_.Idx]) $_.Ch $DeewBitrateAtmos })
       IsAtmos = [bool]$AtmosFlags[$_.Idx]
       Ch = $_.Ch
       OutFile = (Join-Path $BigTmp "ddp_${stamp}_$($_.Idx).ec3") }
})

# CUANTO TRABAJO DE AUDIO HAY POR DELANTE, en segundos. Hace falta para decidir
# si merece la pena solapar: el camino solapado ANADE una segunda pasada de
# ffmpeg (el mux en copy), que en un 4K de 7 GB cuesta 2-3 min. Si la conversion
# de audio dura MENOS que esa pasada, solapar sale a PERDER.
# Los factores salen de los 251 logs del pipeline (mediana de conversion real):
#   ruta Atmos (truehdd + dee) : 27 min en peliculas de ~110 min -> ~0,20 x duracion
#   ruta deew  (dts/flac/pcm)  : 8,8 min en dts                  -> ~0,07 x duracion
# Se toma el MAXIMO de las pistas y no la suma, porque entre ellas ya van en
# paralelo. El +60 es el arranque: extraccion y carga de DEE, que no escalan.
$AudioSegEstim = 0
foreach ($t in $tracks) {
    $factor = if ($t.IsAtmos) { 0.20 } else { 0.07 }
    $s = [int]($Duration * $factor) + 60
    if ($s -gt $AudioSegEstim) { $AudioSegEstim = $s }
}
# Umbral: por debajo de esto la segunda pasada se come la ganancia. 4 min deja
# fuera lo que no compensa (un FLAC corto) sin tocar lo que si (DTS ~9 min,
# TrueHD ~27). Bajarlo es tambien la forma de probar el camino solapado con
# clips cortos, que por diseno no lo dispararian.
$MinAudioParaleloSeg = 240

# Interruptor EFECTIVO del solapamiento audio+video (ver $ParallelAudioVideo
# arriba). En -SubsOnly no hay encode que solapar, y sin pistas que convertir no
# hay nada que adelantar: en los dos casos se hace lo de siempre.
$ParaleloAV = ($ParallelAudioVideo -and -not $SubsOnly -and $ddpPend.Count -gt 0 -and
               $AudioSegEstim -ge $MinAudioParaleloSeg)
if ($ParallelAudioVideo -and -not $SubsOnly -and $ddpPend.Count -gt 0 -and -not $ParaleloAV) {
    Log ("  Audio y video EN SERIE: el audio pendiente son ~{0:N1} min estimados y no compensan la segunda pasada de mux." -f ($AudioSegEstim/60))
}

function Complete-DdpPhase {
    <#
      Reparte los resultados de la conversion en paralelo y reconvierte en
      SECUENCIAL lo que haya fallado. Es el codigo de siempre, movido a una
      funcion sin cambiarle una coma: con el audio solapado esto ya no puede
      correr aqui, tiene que esperar al join de despues del encode de video, y
      duplicarlo habria sido duplicar la POLITICA de fallback (que es donde se
      decide si se pierde un Atmos o se reencola el trabajo).
      Lee y modifica $AudioPlan y $AtmosEc3 del ambito del script, igual que
      cuando era codigo suelto.
    #>
    param([array]$par = @())

    foreach ($r in $par) {
        $p = $AudioPlan | Where-Object { $_.Idx -eq $r.AudioIndex } | Select-Object -First 1
        if (-not $p) { continue }
        if ($r.Ok -and (Test-Path -LiteralPath $r.OutFile)) {
            $AtmosEc3[$p.Idx] = $r.OutFile
            if ($Duration -gt 0) { $p.Est = [long]((Get-Item -LiteralPath $r.OutFile).Length * 8 / $Duration) }
            Log ("    -> a:{0} OK en {1:N0}s: {2}" -f $p.Idx, $r.Seconds, (FmtSize (Get-Item -LiteralPath $r.OutFile).Length))
            # OJO: la pista se queda con Action='ddp'. NO se le pone un estado
            # nuevo tipo 'ddp_done': el constructor de mapas de mas abajo decide
            # con 'Action -eq ddp' si mete el .ec3 como entrada y si lo copia
            # (lineas ~1266 y ~1290), asi que cambiarlo la habria dejado FUERA del
            # muxeo final. Que el bucle secuencial no la repita se resuelve
            # filtrando por $AtmosEc3, que es el registro de "ya convertida".
        } elseif ($r.Failure -eq 'diskfull') {
            # Disco lleno: NO se degrada, se reencola. Igual que en el camino
            # secuencial; degradar perderia el Atmos por un fallo pasajero.
            Exit-Requeue "sin espacio en $BigTmp durante la conversion en paralelo de la pista $($p.Idx)"
        } else {
            # CUALQUIER otro fallo (incluido 'noresult', o sea worker muerto) NO
            # cae al eac3 aqui: se deja marcada como 'ddp' para que el bucle de
            # abajo la reintente en SECUENCIAL. Solo si tambien falla ahi se
            # degrada. Un fallo del mecanismo nuevo no puede costar el Atmos.
            Log "    -> a:$($p.Idx) fallo en paralelo ($($r.Failure)) -> se reintenta en secuencial."
        }
    }

    # Las que ya convirtio el paso en paralelo estan en $AtmosEc3 y se saltan aqui.
    # Las que fallaron alli NO estan, asi que caen a este bucle y se reintentan en
    # SECUENCIAL: un fallo del camino paralelo cuesta tiempo, nunca el Atmos.
    foreach ($p in ($AudioPlan | Where-Object { $_.Keep -and $_.Action -eq 'ddp' -and -not $AtmosEc3.ContainsKey($_.Idx) })) {
        $isAtmos = [bool]$AtmosFlags[$p.Idx]
        $bps = if ($p.DdpK -gt 0) { $p.DdpK } else { Get-DdpBitrate $isAtmos $p.Ch $DeewBitrateAtmos }
        $kind = if ($isAtmos) { "DDP+Atmos" } else { "DDP" }

        if (-not $DeewOk -and -not $isAtmos) {
            # Ojo: este gate SOLO aplica a las pistas SIN Atmos, que son las unicas
            # que pasan por deew (ver la rama else de Convert-TrueHDToDDP). La ruta
            # Atmos va por dee.exe directo y no toca deew para nada, asi que no debe
            # caer al eac3 de ffmpeg por esto: perderia los objetos en silencio.
            Log "  Audio $($p.Idx): 'deew' no esta en PATH -> fallback a EAC3 (ffmpeg)."
            $p.Action = 'transcode'
            $p.Tgt = if ($p.Ch -ge 6) { "640k" } else { "384k" }
            $p.Est = ([int]($p.Tgt -replace 'k','') * 1000)
            continue
        }
        # El .ec3 tambien a $BigTmp: es ~1 GB por pista y no pinta nada compitiendo
        # por C: con el pagefile. Lo lee ffmpeg en el encode, y lo barren tanto el
        # finally de atmos-lib como el Clean-JobLeftovers del watcher (patron ddp_*).
        $ec3 = Join-Path $BigTmp "ddp_${stamp}_$($p.Idx).ec3"
        Remove-Item -LiteralPath $ec3 -ErrorAction SilentlyContinue
        # El codec real, no "TrueHD" hardcodeado: por aqui pasan ahora tambien las
        # pistas DTS, y un log que miente sobre lo que esta haciendo no ayuda a nadie.
        Log "  Audio $($p.Idx): $($p.Codec) [$($p.Lang)] ($($p.Ch)ch) -> $kind ${bps}k (DEE)..."
        # -DurationSec y -Channels no son cosmeticos: con ellos la libreria calcula
        # cuanto sitio hace falta (.thd + DAMF + .ec3) y se niega a empezar si no cabe,
        # en vez de descubrirlo 13 minutos despues con un "write error" de DEE.
        # ...Cached: si esta pista YA se convirtio antes con los mismos parametros, se
        # reutiliza el .ec3 en vez de repetir 60-90 min de DEE. Importa sobre todo en
        # los REINTENTOS: un fallo transitorio de disco sale con 75 y el watcher
        # reencola, asi que hasta hoy el reintento rehacia un audio ya perfecto.
        # Mismo contrato que la funcion sin cache (incluido $global:DdpLastFailure);
        # la cache se valida por duracion y se salta sola si algo no cuadra.
        $ok = Convert-TrueHDToDDPCached -InputFile $InputFile -AudioIndex $p.Idx -Bitrate $bps -OutFile $ec3 `
                  -Tmp $Tmp -BigTmp $BigTmp -IsAtmos:$isAtmos -Channels $p.Ch -DurationSec $Duration `
                  -OnProgress $AudioProgress
        if ($ok -and (Test-Path -LiteralPath $ec3)) {
            $AtmosEc3[$p.Idx] = $ec3
            if ($Duration -gt 0) { $p.Est = [long]((Get-Item -LiteralPath $ec3).Length * 8 / $Duration) }
            Log "    -> OK: $(FmtSize (Get-Item -LiteralPath $ec3).Length)"
        } elseif ($global:DdpLastFailure -eq 'diskfull') {
            # Disco lleno: NO se degrada. Ver Exit-Requeue.
            Exit-Requeue "sin espacio en $BigTmp durante la conversion de la pista $($p.Idx)"
        } else {
            $why = if ($isAtmos) { "dee.exe" } else { "deew" }
            Log "    -> FALLO $why -> fallback a EAC3 (ffmpeg) para no perder la reduccion."
            if ($isAtmos) { Log "       AVISO: esta pista tenia Atmos y el fallback NO lo conserva." }
            $p.Action = 'transcode'
            $p.Tgt = if ($p.Ch -ge 6) { "640k" } else { "384k" }
            $p.Est = ([int]($p.Tgt -replace 'k','') * 1000)
        }
    }
}

# El try/finally llega hasta el final del script y NO se reindenta el cuerpo
# a proposito: reindentar 1.100 lineas para ganar una sangria es exactamente
# el tipo de diff en el que se cuela un error invisible. Ver el finally del
# final para que cubre.
try {
if ($ParaleloAV) {
    # RESERVA DEL TEMPORAL DE VIDEO. La reserva de espacio de DEE se calcula
    # ANTES de que ese fichero exista, asi que hay que sumarlo aqui o el video le
    # come el disco al Atmos a media conversion, que es el fallo del 31/07/2026.
    # Se estima por el TECHO DE TAMANO, que es lo unico que se conoce a estas
    # alturas ($Target se calcula mas abajo, ya con el audio estimado): 16 GB en
    # 4K y 12 en 1080p. Sale generoso a proposito -el fichero real suele ocupar
    # la mitad- porque aqui el margen vale mas que la exactitud.
    $VidTmp  = Join-Path $BigTmp ("vid_{0}.mkv" -f $TmpTag)
    $ceilGb  = if ($Res -eq '4K') { 16.0 } else { 12.0 }   # el MISMO $CeilGb de mas abajo
    $vidNeed = [long]($ceilGb * 1GB * 1.15) + 2GB
    Log "  Audio y video EN PARALELO: $($tracks.Count) pista(s) de audio en segundo plano."
    # SIN -OnProgress a proposito: mientras el video encodea, el unico que puede
    # escribir en encode_status es el video. Ver app.py:450, donde un stage
    # distinto de 'video' PISA el porcentaje del ffprog y ademas borra el ETA.
    $AudioBg = Start-DdpTracksParallel -Tracks $tracks -InputFile $InputFile -DurationSec $Duration `
                   -Tmp $Tmp -BigTmp $BigTmp -MaxParallel $ParallelDdpTracks -LibPath $AtmosLib `
                   -ExtraNeededBytes $vidNeed
    if (-not $AudioBg) {
        # No se pudo (falta el worker, o no cabe todo en G:): se hace como
        # siempre. Un fallo del mecanismo nuevo cuesta tiempo, nunca el trabajo.
        Log "  No se pudo arrancar el audio en segundo plano -> se hace en SERIE."
        $ParaleloAV = $false
        $VidTmp     = ''
    }
}

if (-not $ParaleloAV) {
    # CAMINO DE SIEMPRE: el audio entero aqui, y el video despues.
    $par = @()
    if ($ParallelDdpTracks -gt 1 -and $ddpPend.Count -gt 1) {
        Log "  Audio: $($tracks.Count) pistas a DDP en PARALELO (medido 1,62x a 2 pistas)..."
        $par = @(Invoke-DdpTracksParallel -Tracks $tracks -InputFile $InputFile -DurationSec $Duration `
                     -Tmp $Tmp -BigTmp $BigTmp -MaxParallel $ParallelDdpTracks -OnProgress $AudioProgress `
                     -LibPath $AtmosLib)
    }
    Complete-DdpPhase $par
}

# -- Output audio estimate (solo pistas conservadas) ---------------
$AudioTotalBps = 0
foreach ($p in ($AudioPlan | Where-Object { $_.Keep })) { $AudioTotalBps += $p.Est }
$AudioKept = @($AudioPlan | Where-Object { $_.Keep }).Count
$AudioMbps = [math]::Round($AudioTotalBps / 1e6, 1)
# Suelo de seguridad SOLO si no hay estimacion fiable. Antes era un suelo fijo de
# 2.0M, pensado para cuando la salida podia ser TrueHD o varias pistas; con una
# unica pista DD+ de 768k reservaba ~1,2M que nadie usaba y se los quitaba al
# video. Con Est calculado del tamano real del .ec3 (ver Convert-TrueHDToDDP) la
# estimacion es exacta y el suelo sobra.
if ($AudioTotalBps -le 0) { $AudioMbps = 2.0 }
# En SubsOnly todo el analisis de bitrate se calcula y se tira (el video va con
# -c:v copy), asi que no se loguea: un log que dice "QVBR GQ=19 preset=veryslow"
# cuando en realidad esta copiando confunde mas que ayuda.
if (-not $SubsOnly) {
    Log "Output audio estimate: ${AudioMbps}M ($AudioKept de $AudioCount tracks tras dedup)"
}

# -- Type / resolution / HDR ---------------------------------------
if     ($TypeOverride.ToLower() -eq "movie")  { $Type = "Movie" }
elseif ($TypeOverride.ToLower() -eq "series") { $Type = "Series" }
elseif ($Duration -ge 3600)                   { $Type = "Movie" }
else                                          { $Type = "Series" }

# ($Res y $Downscale8K se calculan ARRIBA, justo despues del sondeo: la fase de
#  audio ya necesita saber el techo de tamano para reservar disco. Ver alli el
#  porque de mirar alto Y ancho.)

$Hdr = "SDR"
$HdrArgs = @()
if ($ColorTr -match '(?i)smpte2084|arib-std-b67') {
    $Hdr = "HDR"
    $HdrArgs = @('-color_primaries','bt2020','-color_trc','smpte2084','-colorspace','bt2020nc')
    if ($ColorRange -and $ColorRange -ne "unknown") { $HdrArgs += @('-color_range',$ColorRange) }
}

# -- HDR10 estatico (mastering display) ----------------------------
# CORREGIDO EL 30/07. La premisa original era FALSA: se dijo que hevc_qsv perdia
# el mastering display, basandose en un ffprobe -show_streams sobre las salidas
# de ESDLA que no mostraba nada. Los logs de Keepers (2018) demuestran lo
# contrario: TANTO el del 17/07 (anterior a este bloque) COMO el del 30/07
# escriben en la salida "Mastering display metadata" y "MaxCLL=1000 MaxFALL=400",
# y el fichero terminado los tiene verificados a nivel de stream Y de frame.
# O sea: ffmpeg SI conserva el HDR10 estatico. Aqui no habia nada roto.
#
# Lo que si estaba roto era la comprobacion, y de la misma manera en los dos
# sitios: el HDR10 estatico puede viajar en DOS niveles distintos.
#   - elementos del contenedor (MKV Colour/MasteringMetadata) -> lo ve -show_streams
#   - SEI dentro del bitstream                                 -> NO lo ve; hay que
#     mirar -show_frames, que es lo que hace el decodificador de ffmpeg
# Los remuxes suelen traerlo SOLO como SEI. Por eso este bloque escribia "el
# origen NO trae mastering display" en peliculas donde ffmpeg lo estaba copiando.
# Un log que afirma algo falso es peor que no loguear, asi que se mira en los dos.
#
# Se conserva la reinyeccion como red de seguridad idempotente: si ffmpeg ya lo
# escribio, mkvpropedit reescribe los mismos valores y no pasa nada.
# MaxCLL/MaxFALL quedan FUERA: mkvpropedit de esta version no los expone
# (verificado con --list-property-names). Da igual, porque ffmpeg ya los escribe.
$MdcvProps = @()
if ($Hdr -eq "HDR") {
    try {
        # Nivel 1: elementos del contenedor.
        $sdJson = & $FFPROBE -v error -select_streams v:0 -show_streams -of json $InputFile 2>$null
        $sd = ($sdJson | Out-String | ConvertFrom-Json).streams[0].side_data_list
        $sdWhere = "contenedor"
        # Nivel 2: SEI del bitstream. Es el caso habitual en remuxes.
        if (-not $sd) {
            $sdJson = & $FFPROBE -v error -select_streams v:0 -read_intervals "%+#1" `
                                 -show_frames -of json $InputFile 2>$null
            $sd = ($sdJson | Out-String | ConvertFrom-Json).frames[0].side_data_list
            $sdWhere = "SEI del bitstream"
        }
        $fmt = '0.##########'
        $ic  = [System.Globalization.CultureInfo]::InvariantCulture
        foreach ($e in @($sd)) {
            if ($e.side_data_type -match '(?i)mastering display') {
                $map = [ordered]@{
                    'chromaticity-coordinates-red-x'   = (ParseRational $e.red_x)
                    'chromaticity-coordinates-red-y'   = (ParseRational $e.red_y)
                    'chromaticity-coordinates-green-x' = (ParseRational $e.green_x)
                    'chromaticity-coordinates-green-y' = (ParseRational $e.green_y)
                    'chromaticity-coordinates-blue-x'  = (ParseRational $e.blue_x)
                    'chromaticity-coordinates-blue-y'  = (ParseRational $e.blue_y)
                    'white-coordinates-x'              = (ParseRational $e.white_point_x)
                    'white-coordinates-y'              = (ParseRational $e.white_point_y)
                    'max-luminance'                    = (ParseRational $e.max_luminance)
                    'min-luminance'                    = (ParseRational $e.min_luminance)
                }
                foreach ($k in $map.Keys) {
                    if ($null -ne $map[$k]) { $MdcvProps += @('--set', ("{0}={1}" -f $k, $map[$k].ToString($fmt,$ic))) }
                }
            }
            elseif ($e.side_data_type -match '(?i)content light level') {
                Log ("  HDR10: el origen trae MaxCLL={0} MaxFALL={1} - NO reinyectables con mkvpropedit" -f $e.max_content,$e.max_average)
            }
        }
        # Volcado crudo: si tu ffprobe usara otros nombres de campo, esto lo delata
        # en el log en vez de fallar en silencio.
        if ($sd) { Log ("  HDR10 side_data del origen: " + ($sd | ConvertTo-Json -Compress -Depth 4)) }
    } catch { Log "  AVISO: no se pudo leer el HDR10 estatico del origen: $_" }
    if ($MdcvProps.Count -gt 0) { Log ("HDR10 mastering display capturado del origen ({0}): {1} propiedades" -f $sdWhere,($MdcvProps.Count/2)) }
    else { Log "HDR10: el origen no expone mastering display ni en el contenedor ni en el SEI" }
}

# -- Starting bitrate target ---------------------------------------
# EN MODO SubsOnly NO SE CALCULA NADA DE ESTO (19/08/2026). El video va en
# '-c:v copy', asi que el target, el suelo, el techo de tamano, el tope del 70 %
# y el GQ no se aplican a NADA: ni un solo bit de la salida depende de ellos.
#
# Se hacia igualmente, y ademas se ESCRIBIA EN EL LOG. Eso no es solo trabajo en
# balde: es un dato falso con pinta de verdadero. Al auditar los logs para ver
# cuantas veces el tope del 70 % recortaba la calidad, los trabajos de
# subtitulos entraron en la cuenta como si fueran encodes y torcieron el
# resultado (salia 1 de cada 4 peliculas; contando solo encodes reales es 1 de
# cada 5, y los tres casos mas escandalosos -Project Almanac al -75 %, Transito
# al -62 %, Alerta maxima al -24 %- eran los tres trabajos de SUBTITULOS donde
# ese numero no se usaba para nada).
#
# Las variables se dejan a 0 en vez de sin definir: el chequeo de espacio, el
# log de cabecera y los argumentos del encoder ya tienen su rama de SubsOnly,
# pero un 0 explicito no puede producir un '-b:v M' malformado si alguien anyade
# una ruta nueva sin acordarse. Y en completed.jsonl los campos salen a 0, que
# es la verdad: en un trabajo de subtitulos no hubo target.
if ($SubsOnly) {
    $Target = 0; $MaxRate = 0; $BufSize = 0; $Gq = 0; $QFloor = 0
    Log "Bitrate: no se calcula (SOLO SUBTITULOS; el video va en copy)"
    if ($TargetMbps -gt 0) {
        Log "  AVISO: se ha pedido -TargetMbps $TargetMbps pero en -SubsOnly el video se COPIA."
        Log "  El bitrate no se toca: no hay encode que gobernar. Se ignora."
    }
} else {
if ($Type -eq "Movie") {
    # 4K HDR: 9.0 -> 10.5 el 04/08/2026. MOTIVO MEDIDO, leido de completed.jsonl:
    # de los 11 encodes registrados, 8 salieron cap_bound (73 %), con el bitrate
    # logrado al 95-99 % del target. O sea que en 3 de cada 4 peliculas mandaba el
    # TECHO y el GQ no llegaba a expresarse: tocar el GQ no habria cambiado nada.
    # Subir el target es la unica palanca que mueve algo para esa mayoria.
    # OJO al pasar de 10.75: ahi habria que reintroducir el tope duro que se
    # elimino el 29/07 (ver la nota de "Bitrate rules" mas abajo).
    # El techo de tamano ($CeilGb, 16 GB) sigue mandando en metrajes largos: por
    # encima de ~190 min lo recorta antes de llegar a 10.5, que es lo que se quiere.
    # 1080p: 5.5 -> 7.0 (SDR) y 6.5 -> 8.0 (HDR) el 07/08/2026. MEDIDO con
    # ab-test sobre Blade Runner, y el resultado corrigio la hipotesis de partida.
    #
    # De completed.jsonl parecia que en 1080p mandaba el GQ y no el techo: solo el
    # 33 % salia cap_bound, frente al 78 % del 4K SDR. Pero medir el clip lo
    # desmintio por dos vias:
    #   1. Con las ataduras de produccion (-b:v 5.5M), bajar el GQ de 18 a 14
    #      -CUATRO puntos- solo movia +3.78 % de tamano: el GQ era inerte.
    #   2. Sin ataduras (-Icq), ese mismo GQ 18 solo pedia 3.97 Mbps... pero CON
    #      -b:v 5.5M el clip salio a 5.0. O sea que en QVBR el -b:v no es un tope
    #      sino un OBJETIVO A LLENAR: el encoder apunta a esa cifra y el GQ deja
    #      de decidir. La calidad de 1080p la fija el TARGET.
    # El 'cap_bound' de la media enganya ademas por otro lado: promedia escenas
    # complejas y simples. Este clip iba al 97-99 % del target aunque la media de
    # la pelicula entera fuera 86 %. Las escenas que marcan la calidad percibida
    # SI estaban recortadas.
    # 4K SDR: 8.5 -> 10.0 el 17/08/2026. MISMO MOTIVO MEDIDO que el 4K HDR, y
    # esta vez aun mas claro: de los 5 encodes 4K SDR posteriores al cambio de
    # targets del 07/08, los CINCO salieron cap_bound, con el bitrate logrado al
    # 99 % del target. O sea que el techo mandaba SIEMPRE y el GQ no llegaba a
    # expresarse ni una vez. Comparar con el 4K HDR en el mismo periodo: 31 % de
    # cap_bound y ratio 0,88, que es el regimen sano (decide el GQ y sobra techo).
    # Se sube a 10.0 y no a 10.5 a proposito: el SDR necesita menos bits para el
    # mismo resultado percibido, y por eso su GQ ya es 16 frente al 15 del HDR.
    # AVISO HONESTO: n=5. Es poca muestra. Si en las proximas 4K SDR el cap_bound
    # baja del 100 %, el cambio funciono; si sigue al 100 %, hay que subir mas.
    # El techo de 16 GB no estorba: 10.0M en 110 min son 8,25 GB.
    # 22/08/2026: RECORTE EN 4K, SUBIDA EN 1080p. Medido con 'ab-test.ps1 -Suite
    # target' sobre un clip de 180 s de 'El atlas de las nubes' (fuente ORIGINAL
    # HEVC 4K HDR a 16.2 Mbps), matriz 3x3 de target x detail:
    #     10.5M -> 9.5M : -9.61 % de tamano por -0.000234 de SSIM
    #     10.5M -> 9.0M : -14.35 %          por -0.000358
    # La curva es LINEAL en ese tramo (2.4e-5 de SSIM por cada 1 % de tamano):
    # NO hay rodilla ni punto optimo, solo un precio. 9.85 es el punto elegido:
    # -6.2 % de tamano por algo menos de la mitad del coste medido a 9.5M.
    # Vara de medir: el escalon veryslow->medium, aceptado como gratis, costo
    # -0.0000331 de SSIM. Esto es unas 5 veces aquello.
    # El SSIM NO MIDE BANDING y esto es UN SOLO CLIP: validar en el QN93A.
    # En la misma tirada quedo medido que a detail=6 el filtro NO es palanca
    # (quitarlo: +0.11 % de tamano y +0.0000074 de SSIM), y que detail<=2 da el
    # MD5 IDENTICO a detail=0 (el driver ignora valores tan bajos). Por eso el
    # detail se queda en 6 y no se toca.
    # 4K SDR baja lo mismo en proporcion, conservando el hueco de 0.5 que tenia
    # respecto al HDR (su GQ ya es 16 frente al 15 del HDR).
    # 1080p SUBE 0.5 en las dos ramas. OJO: solo muerde en fuentes gordas,
    # porque en la mayoria manda antes el cap del 70 % de la fuente (de los
    # ultimos 14 encodes 1080p, solo 3 llegaban a tocar el target de 7.0).
    # NO MEDIDO: la rama 1080p sigue pendiente de tirada propia.
    # 1080p: 8.5/7.5 -> 5.5/5.0 el 27/08/2026. MEDIDO sobre las 32 peliculas
    # 1080p de completed.jsonl, no estimado:
    #   - la mediana de video que ya estaban dando era 4,38 Mbps, o sea que el
    #     target de 7,5 solo mordia en el 42 % mas gordo;
    #   - con 5,5/5,0 el total simulado baja de 142,0 a 111,6 GiB (-21 %, unos
    #     0,95 GiB por pelicula nueva) y el target mediano pasa de 6,5 a 4,8.
    # Referencia de densidad: 2,46 Mbps en 1080p son los MISMOS bits por pixel
    # que 9,85 en 4K. O sea que 5,0 es el DOBLE de densidad que se da en 4K, con
    # margen de sobra para que 1080p compense su menor eficiencia por pixel.
    # AVISO HONESTO: en 1080p NO hay veredicto visual propio como el del 4K
    # (10,5 indistinguible / 8,5 casi nada / 5,8 perdida clara, del 19/08). El
    # primer caso a mirar es "Intercambiados" a 5,0M. Si se ve mal, aqui es donde
    # se sube.
    # 4K: 9,85/9,35 -> 9,5/9,0 el 02/09/2026, a peticion del usuario.
    # SIMULADO ANTES DE TOCAR sobre los 68 encodes 4K de completed.jsonl,
    # reproduciendo la cadena entera (tabla -> suelo -> techo -> tope 70 %):
    #   - manda la TABLA en 59 de 68, el suelo en 5 y el tope del 70 % en 4,
    #     o sea que el cambio SI muerde y no lo anula ninguna otra regla;
    #   - el suelo NO hay que bajarlo: $QFloor de 4K es 8,5 y 9,0 sigue por
    #     encima, asi que no se repite la trampa del 1080p del 27/08 -bajar el
    #     target dejando el suelo arriba y que el cambio no haga nada-;
    #   - video total simulado: 620,8 -> 601,2 GB (-3,2 %).
    # Coste esperado por la curva medida el 22/08 (2,4e-5 de SSIM por cada 1 %
    # de tamano, LINEAL en este tramo): unos -0,00008 de SSIM, algo mas del
    # doble de lo que costo el escalon veryslow->medium que se acepto como
    # gratis. NO MEDIDO A OJO: el SSIM no ve banding, asi que si en el QN93A se
    # notara, aqui es donde se vuelve a subir.
    if     ($Res -eq "4K" -and $Hdr -eq "HDR") { $Target = 9.5 }
    elseif ($Res -eq "4K")                     { $Target = 9.0 }
    elseif ($Hdr -eq "HDR")                    { $Target = 5.5 }
    else                                       { $Target = 5.0 }
} else {
    # 1080p baja 1,0 en las dos ramas para conservar el escalon respecto a
    # pelicula (5,5/5,0), que es de donde salia el 5,5/4,5 anterior.
    if     ($Res -eq "4K" -and $Hdr -eq "HDR") { $Target = 6.5 }
    elseif ($Res -eq "4K")                     { $Target = 5.5 }
    elseif ($Hdr -eq "HDR")                    { $Target = 4.5 }
    else                                       { $Target = 4.0 }
}

# -- Bitrate rules -------------------------------------------------
# (Aqui vivia un "tope duro" de 10.75M/7.5M que era CODIGO MUERTO: $Target
#  arranca como maximo en 9.0 -Movie 4K HDR- y el tope solo podia BAJAR, nunca
#  subir, asi que no se disparaba jamas. Eliminado el 29/07. Si algun dia
#  quieres dar mas margen al 4K corto, la palanca es el $Target inicial de
#  arriba; y si lo subes por encima de 10.75, reintroduce el tope.)

# -- Suelo de calidad (AHORA ANTES del techo de tamano) -------------
# El ORDEN era lo que estaba roto: este suelo se aplicaba DESPUES del techo y lo
# anulaba. Con 4K/QFloor=8.0, por encima de ~210 min el techo calculaba 6M, el
# suelo lo devolvia a 8M y el fichero crecia sin limite: ESDLA El Retorno del
# Rey (263 min) salio a 18.6 GB con un techo nominal de 15 GB.
# Ahora el suelo se fija PRIMERO y el techo tiene la ultima palabra.
# Suelo BLANDO para metraje largo: por encima de $LongMin la peli puede bajar
# hasta el suelo reducido. Solo afecta a pelis muy largas; por debajo, nada cambia.
$LongMin = 210
$IsLong  = (($Type -eq "Movie") -and (($Duration / 60) -ge $LongMin))
if ($Res -eq "4K") { $QFloor = if ($IsLong) { 6.5 } else { 8.5 } }
# 1080p: 6.5/5.5 -> 4.5/4.0 el 27/08/2026. El suelo ACOMPANYA al target y hay
# que bajarlo con el o el cambio no sirve de nada: con el suelo en 6,5 una
# pelicula cuyo target nuevo sea 5,0 volveria a subir a 6,5 sola, que es
# exactamente lo que hacia inutil bajar la tabla. Se deja 0,5 por debajo del
# target de pelicula SDR, igual que estaba antes la proporcion.
else               { $QFloor = if ($IsLong) { 4.0 } else { 4.5 } }
if ($Target -lt $QFloor) { $Target = $QFloor }

# Techo de TAMANO (no de calidad): fija el bitrate de video MAXIMO que el
# duration-scaling permitira. NO es una cuota a rellenar - QVBR gasta solo lo
# que necesita para su GQ y muchas veces queda MUY por debajo. Este techo solo
# muerde en fuentes gordas (remuxes) donde QVBR querria gastar mas del limite.
# 4K a 16 GB => ~19M en una peli de 120 min (no muerde) y ~6.5M en una de 263
# min (si muerde). Subir esto SOLO engorda las pelis que ya topaban.
# QUIEN MANDA, desde el principio (27/08/2026). Antes esto se llevaba solo
# dentro del bloque del tope del 70 % y arrancaba en 'duration scaling', asi que
# el TECHO DE TAMANO no podia figurar nunca como ganador aunque fuera el que
# habia decidido. Ahora se sigue toda la cadena, por dos motivos:
#   - el log deja de mentir sobre quien recorto;
#   - y es lo que consulta la guarda de ICQ de mas abajo, que necesita saber si
#     ha intervenido alguna regla que ICQ no sabe respetar.
$quien = 'tabla de targets'
$CeilGb = if ($Res -eq "4K") { 16.0 } else { 12.0 }   # 1080p: 10 -> 12 el 07/08/2026, o el techo anularia el target nuevo en metrajes largos
$maxVideo = ($CeilGb * 8 * 1GB / $Duration) / 1e6 - $AudioMbps
if ($maxVideo -lt $Target) { $Target = [math]::Round($maxVideo,1); $quien = 'techo de tamano' }
if ($Target -lt $QFloor)   { $Target = $QFloor; $quien = 'suelo de calidad' }   # el techo nunca baja del suelo
Log ("Duration scaling ({0}min, {1}GB, audio {2}M, suelo {3}M): target={4}M" -f [int]($Duration/60),$CeilGb,$AudioMbps,$QFloor,$Target)

# Tope del 70 % del bitrate de la FUENTE, ahora CONSCIENTE DEL CODEC (04/08/2026).
# La idea del tope es "no gastes mas del 70 % de lo que gastaba el original", y eso
# solo es comparable si el original estaba en el MISMO codec que la salida (HEVC).
# Si la fuente es AV1 -mas eficiente- sus megabits valen MAS que los nuestros, y
# recortar al 70 % de su cifra es mucho mas agresivo de lo que parece. Caso real de
# completed.jsonl: 'le llaman bodhi' venia en AV1 a 8.9M, el tope lo dejo en 6.2M y
# salio cap_bound al 99 %. Con H.264 pasa lo contrario: sus megabits valen menos y
# el tope resultaba demasiado generoso.
# Se convierte primero el bitrate de la fuente a su EQUIVALENTE EN HEVC y luego se
# aplica el 70 %.
# LOS FACTORES SON ESTIMACIONES de eficiencia relativa tipica, NO medidas de esta
# maquina. Estan aqui sueltos justamente para poder corregirlos cuando haya datos:
# si algun dia se mide, se cambia el numero y ya.
$CodecEquivHevc = @{
    'hevc' = 1.00; 'h265' = 1.00
    'av1'  = 1.30            # AV1 necesita ~30 % menos bits para lo mismo
    'vp9'  = 1.15
    'h264' = 0.65; 'avc' = 0.65
    'mpeg2video' = 0.35; 'vc1' = 0.70
}
if ($BitrateSrc -gt 0) {
    $srcM = $BitrateSrc / 1e6
    $eq   = $CodecEquivHevc[("$SrcCodec").ToLower()]
    if (-not $eq) { $eq = 1.00 }
    $srcEq = $srcM * $eq
    $cap = $srcEq * 0.70
    if ($cap -lt $Target) { $Target = [math]::Round($cap,1); $quien = 'tope 70%' }
    # EL TOPE NO BAJA DEL SUELO (19/08/2026). Faltaba, y era una asimetria:
    # tres lineas mas arriba el techo de TAMANO si lo comprueba ("el techo nunca
    # baja del suelo"), pero este tope -anadido despues, el 04/08- no, asi que
    # podia dejar el target por debajo del suelo de calidad. En el historico paso
    # en 11 de 75 encodes.
    #
    # MEDIDO Y JUZGADO A OJO el 19/08/2026 sobre el tramo de mayor demanda de
    # "El atlas de las nubes" (4K HDR, 33,9 Mbps de pico), mismo clip encodeado a
    # tres targets con el resto de ataduras identicas:
    #     10,5M -> indistinguible de la fuente
    #      8,5M -> "un poco, casi nada"
    #      5,8M -> PERDIDA DE CALIDAD CLARA
    # O sea que el suelo esta bien donde esta y dejar caer el target por debajo
    # cuesta calidad que se ve. El SSIM apenas lo delataba (0,9819 / 0,9806 /
    # 0,9782): sirvio para ordenar, no para decidir. Lo decidio mirarlo.
    #
    # El techo de tamano sigue mandando: se aplica ANTES, asi que este suelo
    # nunca puede empujar por encima del limite de $CeilGb.
    if ($Target -lt $QFloor) { $Target = $QFloor; $quien = 'suelo de calidad' }
    # NUNCA MAS QUE LA FUENTE (19/08/2026). Va DESPUES del suelo y le corrige el
    # unico efecto lateral que tenia: en fuentes pobres, el suelo hacia gastar mas
    # bits de los que traia el original. WALL-E venia a 5,6M y habria salido a 8M;
    # Tiempo de matar venia a 5,2M en equivalente HEVC y habria salido a 6,5M.
    # Esos bits de mas no recuperan nada: no se puede reconstruir detalle que la
    # fuente no tiene, solo se codifican con mas fidelidad sus propios artefactos.
    # Y en QVBR el -b:v es un objetivo A LLENAR, no un tope, asi que el fichero
    # crece de verdad (ver la nota de 'en 1080p manda el target').
    # Con esto la regla queda completa y sin contradicciones:
    #   - el tope del 70 % recorta lo que sobra en fuentes generosas
    #   - el suelo impide caer donde se ve la perdida (medido: 5,8M se nota)
    #   - y nunca se gasta mas de lo que el original traia
    # OJO: $absFloor (mas abajo) sigue siendo el ultimo recurso y puede volver a
    # subir el target por encima de la fuente en material patologico (4K por
    # debajo de 5M equivalente). Es deliberado: ahi el problema es la fuente.
    if ($Target -gt $srcEq) { $Target = [math]::Round($srcEq,1); $quien = 'bitrate de la fuente' }
    # LOG HONESTO (19/08/2026). Antes decia "after 70% cap: X" con la X ya pasada
    # por el tope, el suelo Y la guarda de la fuente, o sea que le atribuia al
    # tope un valor que podia haber fijado otra regla. No es cosmetico: esta es
    # la linea que se lee para auditar cuantas veces recorta el tope, y llego a
    # despistar en un analisis real. Ahora se dice la cadena entera y QUIEN gano.
    if ($eq -eq 1.00) {
        Log ("Source video: {0:N1}M | tope 70%={1:N1}M suelo={2}M -> target={3}M (manda: {4})" -f $srcM,$cap,$QFloor,$Target,$quien)
    } else {
        Log ("Source video: {0:N1}M {1} (x{2:N2} = {3:N1}M en HEVC) | tope 70%={4:N1}M suelo={5}M -> target={6}M (manda: {7})" -f $srcM,$SrcCodec,$eq,$srcEq,$cap,$QFloor,$Target,$quien)
    }
}

$absFloor = if ($Res -eq "4K") { 5.0 } else { 2.0 }
if ($Target -lt $absFloor) { $Target = $absFloor }

# -- ICQ SOLO CUANDO NO HAY NADA QUE RESPETAR (27/08/2026) ------------------
# ICQ puro (-global_quality a solas) reparte los bits por complejidad de escena,
# que es lo que se quiere. Pero NO SABE RESPETAR NINGUN LIMITE: no hay techo de
# tamano ni guarda de "nunca mas que la fuente" que se le pueda poner, porque
# cualquier opcion de bitrate lo saca del modo ICQ (medido: -maxrate a solas se
# dispara, -b:v lo convierte en QVBR).
#
# EL CASO QUE LO PROVOCO, "Intercambiados" (27/08/2026, 1080p SDR, 102 min):
#   fuente HEVC 10 bits a 4,96 Mbps
#   la cadena calculo target=5.0M y dijo "manda: bitrate de la fuente"
#   ICQ GQ 15 gasto 6,98 Mbps -> +41 % SOBRE LA FUENTE, 6,03 GiB
# Con 'techo' habrian sido 4,51 GiB. Ese 1,5 GiB de mas no compra nada: no se
# puede recuperar detalle que la fuente no tiene, solo se codifica con mas
# fidelidad la papilla de su compresion previa. Y la regla que existia justo
# para impedirlo -"nunca mas bitrate que la fuente", 19/08/2026- estaba INERTE
# en ICQ porque se queda sin vehiculo: sin -b:v no hay por donde aplicarla.
#
# LA REGLA: si el target final lo ha fijado una restriccion (el techo de tamano
# o cualquiera de las dos derivadas de la fuente), esa restriccion existe por
# algo y hay que poder respetarla -> ese trabajo pasa a 'techo'. Si ha ganado la
# tabla o el suelo, no hay nada que respetar y se usa ICQ, que es donde brilla:
# con una fuente generosa la guarda no salta nunca.
#
# ALCANCE, dicho claro: esto arregla el fallo de ICQ con fuentes POBRES. NO
# arregla el otro, el de las fuentes ricas con grano de verdad -"El Bueno El
# Feo Y El Malo" pidio 12,4 Mbps a GQ 18 sin que ninguna regla interviniera-.
# Para ese no hay guarda posible en ICQ, y por eso el 4K sigue en 'techo'.
# Si ICQ se ha pedido A MANO (-RateMode icq) NO se anula: es una decision
# explicita de quien encola, y aqui el trabajo del pipeline es obedecerla y
# decirlo, no corregirla por su cuenta. La guarda existe para el modo 'auto'.
$IcqRestringido = @('techo de tamano','tope 70%','bitrate de la fuente')
if ($RateModeForzado -and (-not $UseRateCap) -and ($quien -in $IcqRestringido)) {
    Log ("AVISO: ICQ pedido a mano y ademas el target lo fijaba '{0}' ({1}M)." -f $quien, $Target)
    Log  "  Se respeta ICQ porque lo has pedido tu, pero ese limite NO se va a cumplir:"
    Log  "  en ICQ el tamano queda libre. Si lo que quieres es respetarlo, usa qvbr."
}
if ((-not $RateModeForzado) -and (-not $UseRateCap) -and ($quien -in $IcqRestringido)) {
    $UseRateCap = $true
    Log ("Perfil ICQ ANULADO para este trabajo: el target lo fija '{0}' ({1}M)." -f $quien, $Target)
    Log  "  ICQ no sabe respetar ese limite (no admite techo sin dejar de ser ICQ),"
    Log  "  asi que se usa 'techo' y la restriccion se cumple de verdad."
}

# -- OVERRIDE MANUAL DEL BITRATE (-TargetMbps) -----------------------------
# Va AQUI, el ultimo de todos, a proposito: ver el comentario del parametro.
# Todo lo que se ha calculado arriba queda como referencia en el log, pero no
# gobierna: lo dice la linea de aviso para que nadie audite el log creyendo que
# el tope del 70 % recorto algo cuando en realidad mandaba una cifra a mano.
if ($TargetMbps -gt 0) {
    $auto = $Target
    $Target = [math]::Round($TargetMbps, 2)
    # SI EL PERFIL ERA 'icq', SE FUERZA 'techo' PARA ESTE TRABAJO. Pedir un
    # bitrate solo significa algo si se emite -b:v; en ICQ puro no se emite
    # ninguno y el numero seria decorativo -exactamente el fallo de log que se
    # arreglo hoy mismo, reintroducido por la puerta de atras-. Se dice.
    $forzadoTecho = -not $UseRateCap
    $UseRateCap = $true
    Log ("BITRATE A MANO: {0}M (-TargetMbps). El automatico habria sido {1}M." -f $Target, $auto)
    Log  "  Manda esta cifra por encima de TODO: duration scaling, tope del 70%,"
    Log ("  techo de {0} GB, suelo de calidad ({1}M) y suelo absoluto ({2}M)." -f $CeilGb, $QFloor, $absFloor)
    if ($forzadoTecho) {
        Log "  El perfil de esta resolucion era 'icq' (sin -b:v). Se cambia a 'techo'"
        Log "  SOLO para este trabajo: sin -b:v el numero que has pedido no se aplicaria."
    }
    if ($Target -lt $absFloor) {
        Log ("  AVISO: {0}M esta por debajo del suelo absoluto de esta resolucion ({1}M)." -f $Target, $absFloor)
        Log  "  Se respeta porque lo has pedido tu, pero es territorio de perdida visible."
    }
}

# Margen de pico para QVBR, POR RESOLUCION: el 4K se beneficia de mas pico en
# escenas complejas (y hay hueco de sobra hasta el ceiling de 13GB); el 1080p
# ya va holgado a su target y no necesita picos tan altos, asi que va mas
# ajustado. En QVBR el tamano flota por complejidad; esto es el TOPE DE PICO,
# no la media. Sube/baja estos factores para tunear (mas = mas margen y
# ficheros algo mayores en material complejo; menos = mas pegado al tamano
# actual, p.ej. 1.15 replica el comportamiento previo).
$MaxRateFactor = if ($Res -eq "4K") { 1.35 } else { 1.30 }   # 1080p: 1.20 -> 1.30 el 07/08/2026, margen para los picos de escena compleja
$MaxRate = [math]::Round($Target * $MaxRateFactor, 1)
$BufSize = [math]::Round($MaxRate * 1.5, 0)
Log "Final: target=${Target}M | maxrate=${MaxRate}M (x$MaxRateFactor) | bufsize=${BufSize}M"
# AVISO DE HONESTIDAD DEL LOG (26/08/2026). En perfil 'icq' no se pone ni -b:v ni
# -maxrate ni -bufsize, asi que TODO lo que acaban de decir las cuatro lineas de
# arriba -el duration scaling, el tope del 70 %, el suelo de calidad, la guarda de
# "nunca mas que la fuente" y el techo de $CeilGb GB- se calcula y se TIRA. Ni un
# solo bit de la salida depende de ello.
#
# Sin este aviso el log afirma algo falso con pinta de verdadero, que es
# exactamente el problema que ya obligo a meter la rama de -SubsOnly unas lineas
# mas arriba: al auditar cuantas veces recortaba el tope del 70 %, los trabajos de
# subtitulos entraron en la cuenta como si fueran encodes y torcieron el resultado.
#
# CASO REAL, "PAW Patrol Rocky's Cat-astrophe" (26/08/2026, 1080p SDR, perfil icq):
#   Source video: 9.3M h264 (x0.65 = 6.1M en HEVC) | tope 70%=4.2M suelo=6.5M
#                 -> target=6.1M (manda: bitrate de la fuente)
# y salio a 7,85 Mbps de video: un 29 % POR ENCIMA del target que esa linea anuncia
# y un 30 % por encima del equivalente HEVC de la fuente. O sea que la regla
# "nunca mas bitrate que el original" esta INERTE en la rama que hoy usa 1080p.
# Esto no es un fallo del calculo: es lo que significa ICQ. Pero hay que decirlo.
if (-not $UseRateCap) {
    Log "  OJO: perfil ICQ -> nada de lo anterior llega al encoder. Ni el target, ni el"
    Log "  tope del 70%, ni el suelo, ni la guarda de 'nunca mas que la fuente', ni el"
    Log ("  techo de {0} GB. Manda SOLO el GQ y el tamano final es libre." -f $CeilGb)
    Log "  Esas cifras quedan como REFERENCIA de lo que habria hecho el perfil 'techo'."
}
}   # fin del bloque de bitrate (no se ejecuta en SubsOnly)

# -- Quality -------------------------------------------------------
# QVBR global_quality (GQ): la PALANCA principal de calidad, mas que el cap del
# 70% del bitrate fuente (que en 4K HDR ni llegaba a apretar: QVBR gastaba ~6M de
# los 9M de maxrate, o sea alcanzaba la calidad pedida y sobraba techo). Bajado 1
# punto en cada rama respecto al ajuste anterior (era 16/19/19/20) para que QVBR
# aproveche ese margen y suba calidad. Sube el tamano del fichero, pero sigue
# acotado por maxrate y por el techo de 13GB/10GB. Si en tu TV aun quieres mas,
# baja otro punto (menor GQ = mas calidad y mas tamano).
# 02/08: la rama 4K SDR baja de 18 a 16. Motivo: al comparar Mandalorian y El dia
# de la revelacion encodeadas dos veces (26/07 desde fuente HDR, 01/08 desde fuente
# SDR) la de agosto salia bastante mas pequena. Parte era fuente mas ligera y parte
# el dedup de audio, pero el GQ 18 de la rama SDR era el escalon de calidad real.
# 16 la deja un punto por debajo del 4K HDR (15), que es razonable: el SDR necesita
# menos bits para el mismo resultado percibido.
# 07/08/2026: las dos ramas de 1080p bajan de 18 a 15. NO es para "ganar calidad
# por el GQ" -se midio que en esta configuracion el GQ es casi inerte, porque el
# -b:v manda-, sino para que el GQ NO SE CONVIERTA EN EL LIMITE con el target
# nuevo. Calibrado sin ataduras sobre Blade Runner: GQ 18 pide 3.97 Mbps, GQ 17
# pide 4.86, GQ 16 pide 6.07 y GQ 14 pide 9.27. Con el target en 7.0M, dejarlo en
# 18 habria hecho que el GQ cortase muy por debajo del techo y el cambio no habria
# servido de nada. En 15 el GQ pide mas de lo que el target permite, asi que quien
# decide vuelve a ser el target, que es lo que se quiere.
# 22/08/2026: en modo 'icq' el GQ es la UNICA palanca de calidad y sale de
# $CfgGqIcq4K / $CfgGqIcq1080p. La tabla de abajo es la del modo 'techo' y se
# conserva intacta para que $CfgPerfil='techo' revierta sin tocar nada mas.
if ($CfgPerfil -eq 'icq') {
    $BaseGq = if ($Res -eq "4K") { $CfgGqIcq4K } else { $CfgGqIcq1080p }
}
elseif ($Res -eq "4K" -and $Hdr -eq "HDR") { $BaseGq = 15 }
elseif ($Res -eq "4K")                     { $BaseGq = 16 }
elseif ($Hdr -eq "HDR")                    { $BaseGq = 15 }
else                                       { $BaseGq = 15 }
$Gq = if ($Mode -eq "quality") { $BaseGq - 1 } else { $BaseGq }
$Gop = if ($Type -eq "Series") { 120 } else { 240 }

# -- VPP filter chain (QSV) ----------------------------------------
# Denoise bajado a la mitad en 4K (32 -> 16) el 18/07: el denoise fuerte aplana
# el grano y el dithering natural que ESCONDE el banding en cielos, degradados y
# zonas oscuras. Al quitar ese ruido dejaba el degradado desnudo y con escalones,
# que es justo lo que Paco notaba. Menos denoise = se conserva el micro-detalle
# que disimula el banding. El detail (sharpening) se deja igual.
# 29/07: mismo tratamiento al 1080p (42 -> 20). Se habia quedado con el ajuste
# agresivo de antes, que es exactamente el que provocaba el banding en 4K; la
# fisica es la misma aunque haya menos pixeles. Contrapartida: al conservar mas
# grano, QVBR gasta algo mas de bitrate en 1080p. Si engorda mas de la cuenta,
# 30 es el punto intermedio.
# 29/07 (tarde): DETAIL bajado tambien, 45 -> 20 en 4K y 55 -> 20 en 1080p.
# Motivo medido: en la suite 'vpp' de ab-test.ps1, quitar el detail recuperaba
# el 67 % de la desviacion respecto al original sin filtrar, y quitar el
# denoise solo el 30 %. O sea que el sharpening estaba alterando la imagen mas
# del DOBLE que el denoise, y era la parte que nunca se habia revisado.
# Motivo de criterio: las fuentes son remuxes, ya vienen nitidas; el detail
# inventa alta frecuencia sobre material que no la necesita, y ademas deshace
# parte de lo que hace el denoise (uno quita alta frecuencia y el otro la mete
# de vuelta, amplificando el grano que quedo). Y en un ARCHIVO el sharpening es
# irreversible: si luego no gusta, la fuente ya se borro. El QN93A hace su
# propio realce al reproducir, y eso si se puede cambiar cuando sea.
# 30/07 MEDIDO EN ICQ (bitrate libre, que es donde esto se puede medir): los
# filtros NO ahorran bitrate, lo GASTAN, y ademas alejan la imagen del master.
#   base (denoise 16 + detail 20) : 210.39 MB   SSIM 0.985959
#   sin detail (solo denoise)     : 202.88 MB   SSIM 0.986049   -3.57 %
#   sin denoise (solo detail)     : 208.74 MB   SSIM 0.986584   -0.78 %
#   SIN NADA                      : 200.96 MB   SSIM 0.986689   -4.48 %
# O sea: detail cuesta ~3.8 % de bitrate y denoise ~1 %, y quitarlos mejora las
# dos metricas a la vez. La tanda anterior CON techo decia lo mismo (sinfiltro
# tenia el mejor SSIM a tamano practicamente igual), asi que no es artefacto del
# modo ICQ.
# PASO INTERMEDIO (30/07): detail a 0 y denoise reducido a 8/10, para validar
# visualmente antes de quitarlo del todo. La unica defensa que le queda al
# denoise es el BANDING, que el SSIM no mide; pero la experiencia propia apunta
# en la misma direccion (bajarlo de 32 a 16 REDUJO el banding, porque el denoise
# se lleva el grano que lo enmascara), asi que 0/0 seria el siguiente paso.
# ESTE CAMBIO ES VISUAL: la unica validacion real es mirarlo en la tele.
# Poner los dos a 0 equivale a $UseVppFilters = $false (solo conversion).
# 30/07 (barrido de denoise en ICQ sobre 1080p real): el denoise SI ahorra
# bitrate aqui, pero el NIVEL da igual. Medido sobre La chaqueta metalica:
#   sin denoise : 17.89 MB   (+5.4 %)
#   denoise 5   : 16.98 MB
#   denoise 10  : 16.98 MB
#   denoise 20  : 16.97 MB
# Los MD5 difieren, o sea que el filtro actua; simplemente satura por debajo de
# 5. Por eso 1080p baja de 10 a 5: mismo ahorro con menos alteracion de imagen.
# Contradice lo medido en 4K (alli el denoise COSTABA ~1 %), y la explicacion
# probable es que el clip 4K era una salida ya procesada con denoise=32, sin
# grano que quitar, mientras que una peli de 1987 tiene grano real. Hipotesis,
# no medido: pendiente repetir el barrido en 4K con la config actual.
# 02/08: detail vuelve de 0 a 4. El 29/07 se bajo a 0 por el banding, pero 0 es
# "ningun sharpening en absoluto". 4 es un toque minimo, muy lejos del 45/55 que
# si aplanaba el grano y dejaba los degradados desnudos. Si reaparece banding en
# cielos o zonas oscuras, volver a 0 antes de tocar el denoise.
# 19/08/2026: 4K de 10 -> 7, igualando al 1080p. MEDIDO en ICQ (sin -b:v, que es
# la UNICA forma de medir cuanto PIDE el video; con el bitrate fijado el encoder
# rellena el target y la medida sale plana). Sobre el tramo de mayor demanda de
# "El atlas de las nubes" (4K HDR, grano de pelicula, 33,9 Mbps de pico):
#     denoise=0  -> 34,70 Mbps  (+62 %)
#     denoise=5  -> 21,94 Mbps  (+2,1 %)
#     denoise=7  -> 21,84 Mbps  (+1,7 %)
#     denoise=10 -> 21,48 Mbps  (produccion anterior)
# O sea que TODO el coste del grano esta entre 0 y 5; de 5 a 10 la diferencia es
# ruido. Bajar a 7 conserva mas textura por un 1,7 % de bitrate, que ademas no se
# paga en tamano porque el target manda igual.
# Si reaparece banding en cielos o zonas oscuras, bajar $Detail a 0 ANTES de
# volver a tocar el denoise (ver el comentario de arriba).
# LAS DOS RAMAS ERAN IDENTICAS (31/08/2026). Esto era un if/else con los mismos
# valores a cada lado: no decidia nada. Lo peligroso no es el if de mas, es que
# los comentarios de aqui arriba hablan de ajuste por resolucion, asi que quien
# leyera esto se creeria que 4K y 1080p van por caminos distintos, y no. Si algun
# dia hace falta separarlas, se separan; hasta entonces, que se vea que no lo estan.
$Denoise = 7
$Detail  = 6

$scaleArgs = "format=p010le"
if ($Downscale8K) { $scaleArgs = "w=3840:h=2160:format=p010le:scale_mode=hq"; Log "8K input - downscaling to 4K (hq)" }

if ($UseVppFilters) {
    # Se omite lo que este a 0 en vez de escribir "denoise=0:detail=0": asi la
    # cadena refleja lo que de verdad se aplica y bajar un filtro a 0 es cambiar
    # un numero, sin tocar la construccion.
    $vppParts = @()
    if ($Denoise -gt 0) { $vppParts += "denoise=$Denoise" }
    if ($Detail  -gt 0) { $vppParts += "detail=$Detail" }
    $vppParts += $scaleArgs
    $Vf = "vpp_qsv=" + ($vppParts -join ':')
    if (-not $SubsOnly) { Log "QSV filters: denoise=$Denoise detail=$Detail" }
} else {
    $Vf = "vpp_qsv=${scaleArgs}"
    if (-not $SubsOnly) { Log "QSV filters: scaling only (denoise/detail disabled)" }
}

# ($Output ya esta definido arriba, junto al marcador ${StatePfx}_outfile)
if ($SubsOnly) {
    Log "$Type | $Res | $Hdr | SOLO SUBTITULOS: video y audio en copy (sin reencodear)"
} else {
    $RcDesc = if ($UseRateCap) { "QVBR GQ=$Gq maxrate=${MaxRate}M" } else { "ICQ GQ=$Gq (sin techo de bitrate)" }
    if ($RateModeForzado) { $RcDesc += " [modo pedido a mano: $RateMode]" }
    Log "$Type | $Res | $Hdr | $RcDesc | GOP=$Gop | preset=$Preset"
}
Log "Input:  $InputFile"
Log "Output: $Output"

# -- Audio mapping (segun $AudioPlan, ya deduplicado) --------------
# Las pistas 'ddp' NO se mapean desde el MKV origen: su .ec3 (DDP/DDP+Atmos ya
# generado por DEE) se anade como INPUT EXTRA y se copia. El resto (copy /
# transcode a eac3-ffmpeg) se mapea desde el input 0 como siempre.
# Registro COMPARTIDO de entradas extra de ffmpeg: los .ec3 del audio y los .srt
# de los subtitulos. Se inicializa AQUI, FUERA del bloque de mapeo, porque con el
# audio solapado ese bloque corre DESPUES de los subtitulos y ya no puede ser
# quien ponga esto a cero: se llevaria por delante los .srt ya registrados.
$AudioMap = @(); $AudioCodec = @(); $AudioMetaArgs = @(); $outIdx = 0
$ExtraInputs = @(); $inputIdx = 1        # <-- compartido con los SRT del OCR (mas abajo)
$AtmosInputMap = @{}

# El mapeo va en un SCRIPTBLOCK que se invoca con '.', o sea que corre en ESTE
# ambito: asi el cuerpo es exactamente el de siempre (asigna a $AudioMap,
# $ExtraInputs, $inputIdx... sin prefijos) y solo cambia CUANDO se ejecuta.
#   - en serie   : aqui mismo, como toda la vida
#   - solapado   : despues del join del audio, porque hasta entonces no se sabe
#                  que pistas tienen .ec3 y cuales cayeron a eac3
# El ORDEN DE LAS PISTAS en el fichero final no depende de esto: lo fija el orden
# de $AudioMap y $SubMap. Lo que si cambia en el camino solapado es el indice de
# ENTRADA de cada .ec3 (van despues de los .srt, no antes), y por eso el mapeo se
# construye con $inputIdx en vez de con numeros fijos.
$BuildAudioMaps = {
    # 1) Registrar los .ec3 como inputs extra (indices estables, antes que los SRT)
    foreach ($p in $AudioPlan) {
        if ($p.Keep -and $p.Action -eq 'ddp' -and $AtmosEc3.ContainsKey($p.Idx)) {
            $ExtraInputs += @('-i', $AtmosEc3[$p.Idx])
            $AtmosInputMap[$p.Idx] = $inputIdx
            $inputIdx++
        }
    }

    # 2) Construir el mapeo de audio en el orden original de las pistas
    foreach ($p in $AudioPlan) {
        if (-not $p.Keep) { continue }
        $i = $p.Idx

        # Limpiar titulo mal codificado (mojibake). No aplica a 'ddp' (le ponemos
        # nuestro propio titulo mas abajo) para no duplicar -metadata.
        if ($p.Action -ne 'ddp' -and $p.Title -and ($p.TitleClean -ne $p.Title)) {
            $AudioMetaArgs += @("-metadata:s:a:$outIdx", "title=$($p.TitleClean)")
            Log "  Audio ${i}: titulo corregido: '$($p.Title)' -> '$($p.TitleClean)'"
        }

        if ($p.Action -eq 'copy') {
            $AudioMap   += @('-map', "0:a:$i")
            $AudioCodec += @("-c:a:$outIdx","copy")
            Log "  Audio ${i}: $($p.Codec) [$($p.Lang)] ($($p.Ch)ch) -> copy"
        }
        elseif ($p.Action -eq 'ddp') {
            $ii = $AtmosInputMap[$i]
            $isAtmos = [bool]$AtmosFlags[$i]
            $kind = if ($isAtmos) { "DDP+Atmos" } else { "DDP" }
            $bps  = if ($p.DdpK -gt 0) { $p.DdpK } else { Get-DdpBitrate $isAtmos $p.Ch $DeewBitrateAtmos }
            $AudioMap   += @('-map', "${ii}:a:0")
            $AudioCodec += @("-c:a:$outIdx","copy")     # el .ec3 ya es DDP (via DEE)
            $AudioMetaArgs += @("-metadata:s:a:$outIdx", "title=$kind ${bps}k")
            if ($p.Lang -and $p.Lang -ne 'und') {
                $AudioMetaArgs += @("-metadata:s:a:$outIdx", "language=$($p.Lang)")
            }
            Log "  Audio ${i}: $($p.Codec) [$($p.Lang)] ($($p.Ch)ch) -> $kind (DEE, input $ii, copy)"
        }
        else {
            $AudioMap   += @('-map', "0:a:$i")
            # El encoder eac3 de ffmpeg topa en 5.1: una fuente >5.1 (6.1/7.1) hay que
            # downmixearla a 6 canales o el encode aborta ("channel layout not supported").
            if ($p.Ch -gt 6) {
                $AudioCodec += @("-c:a:$outIdx","eac3","-ac:a:$outIdx","6","-b:a:$outIdx",$p.Tgt)
                Log "  Audio ${i}: $($p.Codec) [$($p.Lang)] ($($p.Ch)ch) -> eac3 $($p.Tgt) (downmix 5.1, ffmpeg)"
            } elseif ($p.ForceAc -eq 2) {
                # Comentario/audiodescripcion: voz, a estereo. Da igual que la fuente
                # venga en 5.1, no aporta nada y cuesta el triple.
                $AudioCodec += @("-c:a:$outIdx","eac3","-ac:a:$outIdx","2","-b:a:$outIdx",$p.Tgt)
                Log "  Audio ${i}: $($p.Codec) [$($p.Lang)] ($($p.Ch)ch) -> eac3 $($p.Tgt) estereo (comentario)"
            } else {
                $AudioCodec += @("-c:a:$outIdx","eac3","-b:a:$outIdx",$p.Tgt)
                Log "  Audio ${i}: $($p.Codec) [$($p.Lang)] ($($p.Ch)ch) -> eac3 $($p.Tgt) (ffmpeg)"
            }
        }
        $outIdx++
    }
}

if (-not $ParaleloAV) { . $BuildAudioMaps }

# -- SUBTITULOS ------------------------------------------------------------
# Va en un scriptblock invocado con '.' (corre en ESTE ambito, asi que el cuerpo
# es el de siempre) porque el CUANDO cambia segun el camino:
#   - en serie : aqui mismo, antes de construir la llamada a ffmpeg, porque esa
#                llamada necesita $SubMap y $SubCodec
#   - solapado : DESPUES de lanzar la pasada de video, que no mapea subtitulos y
#                por tanto no los necesita. El OCR pasa a correr MIENTRAS
#                encodea el video en vez de antes.
# Por que importa (medido sobre 63 trabajos con OCR): la mediana es de solo 2,0
# min, pero el p90 son 8,6 y el maximo 31,8, y 16 de esos 63 pasan de 5 min. En
# la mediana no se nota; en la cola son minutos de reloj que hoy nadie aprovecha.
$DoSubsPhase = {
    # -- Subtitle processing (PGS -> SRT via PgsToSrt console OCR) ------
    $SubMap = @()
    $SubCodec = @()
    $SrtMetaArgs = @()   # <-- init AQUI: si no, el reset posterior borraba las
                         #     correcciones de titulo de subtitulos de texto nativos
    $SrtInputs = @()
    $subOut = 0
    $SubsDropped = 0     # <-- contador de pistas descartadas
    # Cuantas pistas de TEXTO nativas se conservan. Decide si al final hace falta
    # salir a buscar subtitulos fuera (ver el bloque de subsfetch, mas abajo).
    $TextoNativo = 0

    # Verificacion unica de que el OCR de consola esta disponible (ver subs-lib.ps1:
    # rutas absolutas a dotnet y a PgsToSrt.dll, no Get-Command, porque un PATH roto
    # dejo el OCR muerto semanas fallando en silencio).
    $OcrReady = $false
    if (Get-Command Convert-SubToSrt -ErrorAction SilentlyContinue) {
        $OcrReady = Test-SubsOcrReady
    }

    $SubCount = 0
    $sIdx = Probe "s" "stream=index" $InputFile
    if ($sIdx) { $SubCount = ($sIdx -split "`n").Count }

    for ($i = 0; $i -lt $SubCount; $i++) {
        $stitle = (Probe "s:$i" "stream_tags=title" $InputFile).ToLower()
        $scodec = (Probe "s:$i" "stream=codec_name" $InputFile).ToLower()
        $lang   = Probe "s:$i" "stream_tags=language" $InputFile; if (-not $lang) { $lang = "und" }

        if ($stitle -match '(?i)latin|latam|latino|neutro|neutral|caribe') {
            Log "  Sub ${i}: SKIPPED ($lang / $stitle)"; continue
        }

        if ($scodec -eq "hdmv_pgs_subtitle") {
            Log "  Sub ${i}: Pista PGS detectada ($lang). Convirtiendo a SRT por OCR de consola..."

            # ESTADO PARA EL PANEL. Sin esto el panel se queda en "No active encode"
            # durante TODO el OCR, que son 10-30 min por pista: parece que no hay nada
            # corriendo cuando la maquina esta trabajando (visto el 06/08/2026 con "La
            # Sociedad De La Nieve").
            #
            # POR QUE JUSTO AQUI: el orden del trabajo es audio -> subtitulos -> video.
            # La fase de audio solo escribe estado desde el callback de
            # Convert-TrueHDToDDP, asi que en una pelicula SIN pistas que convertir no
            # se escribe NADA, y encode_status conserva el 'status=idle' que dejo el
            # trabajo ANTERIOR al terminar. El panel lo lee y concluye, con razon, que
            # no hay nada en marcha.
            #
            # El % va por PISTAS, no por el avance del OCR: PgsToSrt informa de items
            # procesados sin decir cuantos hay en total, asi que un porcentaje real no
            # se puede calcular. Mejor un avance honesto y grueso que uno inventado.
            $pctSub = if ($SubCount -gt 0) { [math]::Round(($i / $SubCount) * 100, 1) } else { 0 }
            # Con el video solapado NO se escribe: ahi el dueno de encode_status
            # es el video, y un stage distinto de 'video' le pisa el porcentaje y
            # le borra el ETA (app.py:450). El panel seguira mostrando el avance
            # del encode, que es la fase larga y la que interesa mirar.
            if (-not $ParaleloAV) {
                WriteNoBom $StatusFile ("status=encoding`nfile=$CleanName.mkv`nduration=$Duration`nfps_src=$FpsSrc`nstage=subs`npct=$pctSub")
            }

            if (-not $OcrReady) {
                # OCR no disponible -> se COPIA el PGS tal cual en vez de tirarlo.
                # Un subtitulo de imagen es peor que uno de texto (no se busca, no
                # reescala, ocupa mas), pero es infinitamente mejor que ninguno.
                # Antes esto descartaba la pista entera y se perdia el subtitulo.
                Log "    -> OCR no disponible. Pista ${i} [$lang] se COPIA como PGS (sin OCR)."
                $SubMap += @('-map', "0:s:$i")
                $SubCodec += @("-c:s:$subOut","copy")
                $subOut++
                continue
            }

            # Nombre sin espacios: stamp + indice garantizan unicidad y evitan que
            # Start-Process trunque la ruta al primer espacio del titulo del film.
            # VAN A $BigTmp (04/08/2026): el .sup que extrae Convert-SubToSrt son
            # decenas o cientos de MB por pista, y no pintan nada en C: compitiendo con
            # el pagefile y la cola. El resto de temporales pesados ya vivia alli desde
            # el 31/07. Los dos watchers barren $Tmp y $BigTmp con el patron 'ocr_*',
            # asi que la limpieza sigue cubierta.
            $tmpSrt = Join-Path $BigTmp "ocr_${stamp}_${i}.srt"

            $ocr = Convert-SubToSrt -InputFile $InputFile -SubOrdinal $i -OutFile $tmpSrt `
                                    -Codec $scodec -Lang $lang -WorkDir $BigTmp -TimeoutMs $OcrTimeoutMs

            if ($ocr.Ok) {
                Log "    -> OK: pista ${i} [$lang] convertida."
                $SrtInputs += @{
                    Path  = $tmpSrt
                    Lang  = $lang
                    Title = if ($ocr.OcrLang -eq "spa") { "Castellano (OCR)" } else { "English (OCR)" }
                }
            } elseif ($ocr.Empty) {
                # Pista VACIA en origen: descartarla no pierde nada. Es la UNICA rama
                # que descarta; cualquier otro fallo copia el PGS.
                # $SubsDropped se declaraba, se logueaba y se escribia en
                # completed.jsonl, pero NINGUNA rama lo incrementaba: el panel y el
                # jsonl mostraban siempre subs_dropped=0.
                Log "    -> Pista ${i} [$lang] VACIA en origen ($($ocr.Reason)). Se DESCARTA."
                $SubsDropped++
            } elseif ($ocr.TimedOut) {
                # TIMEOUT del OCR = fallo TRANSITORIO, NO fallo del fichero. Medido el
                # 14/08/2026: este mismo .sup convierte en ~20s con la maquina libre y
                # tardo ~295s (y salto el timeout) por contencion de CPU en esa ventana.
                # Copiar el PGS aqui degradaria en silencio (se pierde el SRT de texto
                # para siempre, sin reintento). En vez de eso se reencola el trabajo
                # ENTERO, igual que con el disco lleno: se reintenta con la maquina
                # tranquila y sale el SRT de verdad. Mismo criterio que Exit-Requeue.
                Exit-Requeue "timeout del OCR en la pista $i [$lang] ($($ocr.Reason))"
            } else {
                # El OCR fallo sobre una pista CON contenido: se copia el PGS tal cual.
                # Un subtitulo de imagen es peor que uno de texto, pero es
                # infinitamente mejor que ninguno.
                Log "    -> ERROR: $($ocr.Reason). Pista ${i} [$lang] se COPIA como PGS."
                $SubMap += @('-map', "0:s:$i")
                $SubCodec += @("-c:s:$subOut","copy")
                $subOut++
            }
        } else {
            # Mapear pistas de texto nativas directamente (SRT / ASS)
            $SubMap += @('-map', "0:s:$i")
            if ($scodec -in @('mov_text','tx3g','ass','ssa')) {
                $SubCodec += @("-c:s:$subOut","srt")
                $TextoNativo++
                Log "  Sub ${i}: kept ($lang) [$scodec -> srt]"
            } else {
                $SubCodec += @("-c:s:$subOut","copy")
                # 'subrip' es texto y cuenta; 'dvd_subtitle' (VobSub) NO: es imagen y
                # no hay OCR para el, asi que deja la pelicula sin subtitulo utilizable
                # y es justo uno de los dos casos que disparan la busqueda externa.
                if ($scodec -in @('subrip','text','webvtt')) { $TextoNativo++ }
                Log "  Sub ${i}: kept ($lang) [$scodec -> copy]"
            }
            # Limpiar titulo mal codificado de la pista de subtitulos si lo tuviera
            $sTit = Probe "s:$i" "stream_tags=title" $InputFile
            $sTitClean = Repair-Mojibake $sTit
            if ($sTit -and ($sTitClean -ne $sTit)) {
                $SrtMetaArgs += @("-metadata:s:s:$subOut", "title=$sTitClean")
                Log "  Sub ${i}: titulo corregido: '$sTit' -> '$sTitClean'"
            }
            $subOut++
        }
    }

    # -- Subtitulos EXTERNOS (subsfetch) ---------------------------------------
    # CUANDO ACTUA: solo si la pelicula se queda SIN NINGUN SUBTITULO DE TEXTO.
    # Esa sola condicion cubre exactamente los dos casos que interesan:
    #   - la pelicula no traia subtitulos
    #   - solo traia VobSub (dvd_subtitle), que es imagen y NO tiene OCR
    #     (PgsToSrt solo entiende PGS), asi que se copiaria como imagen y Plex
    #     tendria que quemarlo en cada reproduccion
    # Los PGS NO disparan nada: el bucle de arriba ya los ha pasado por OCR y han
    # sumado a $SrtInputs. Un PGS cuyo OCR falle si dispara la busqueda, que es lo
    # razonable: mejor un SRT de fuera que una imagen.
    #
    # VA AQUI, justo antes de convertir $SrtInputs en entradas de ffmpeg, para que
    # lo que se encuentre entre por la MISMA maquinaria que los SRT del OCR. Asi no
    # hay que remuxear la fuente: los .srt se anaden como entradas extra del propio
    # encode, que ya iba a rehacer el contenedor de todas formas.
    if ($FetchSubs -and ($SrtInputs.Count + $TextoNativo) -eq 0) {
        Log "Sin subtitulos de texto: buscando fuera (subsfetch)..."
        if (-not $ParaleloAV) {   # ver arriba: con el video solapado, el estado es suyo
            WriteNoBom $StatusFile "status=encoding`nfile=$CleanName.mkv`nduration=$Duration`nstage=subtitulos`npct=0"
        }
        $sfDir = Join-Path $BigTmp ("sf_" + [System.IO.Path]::GetRandomFileName().Substring(0,8))
        New-Item -ItemType Directory -Force -Path $sfDir | Out-Null
        try {
            # ENTRECOMILLADO OBLIGATORIO: -ArgumentList con un ARRAY une los elementos
            # con espacios y NO protege los que ya llevan espacios dentro. Con eso,
            # "Minority Report (2002).mkv" llegaba a Python partido en tres y argparse
            # respondia "unrecognized arguments: Report (2002).mkv". Como el error se
            # iba por stderr y solo se leia stdout, el resultado era un silencioso
            # "no se consiguio ninguno" para CUALQUIER pelicula con espacios en el
            # nombre, o sea casi todas. Misma forma de citar que se usa para ffmpeg.
            $sfArgs = @($SubsFetch, $InputFile, '--idiomas', 'es,en', '--forzados',
                        '--out', $sfDir)
            $sfLine = ($sfArgs | ForEach-Object {
                if ($_ -match '[\s"()]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" }
            }) -join ' '
            $sfOut = Join-Path $sfDir 'salida.txt'
            $sfErr = Join-Path $sfDir 'err.txt'
            $p = Start-Process -FilePath $PYTHON -ArgumentList $sfLine -NoNewWindow -PassThru `
                               -RedirectStandardOutput $sfOut -RedirectStandardError $sfErr
            if (-not $p.WaitForExit($FetchSubsTimeoutMs)) {
                Log "  subsfetch tardo demasiado; se cancela y se sigue sin el."
                try { $p.Kill($true) } catch { }
            }
            foreach ($l in @(Get-Content -LiteralPath $sfOut -ErrorAction SilentlyContinue)) { Log "  [subs] $l" }
            # El stderr TAMBIEN al log: sin esto, un fallo de arranque o de argumentos
            # no deja ni rastro y parece que simplemente no habia subtitulos.
            $errLineas = @(Get-Content -LiteralPath $sfErr -ErrorAction SilentlyContinue)
            if ($errLineas.Count) {
                Log "  [subs] --- stderr ---"
                foreach ($l in $errLineas) { Log "  [subs] $l" }
            }
            # Los nombres los fija SUF en subsfetch.py: si se tocan alli, tocar aqui.
            # Los forzados van PRIMERO: asi quedan como pistas de subtitulo 0 y 1 del
            # resultado, delante de las completas. Ademas evita cualquier duda con el
            # filtro por sufijo (aunque '*.es.srt' no case con '...es.forced.srt',
            # el orden lo deja claro y el fichero se MUEVE al recogerlo).
            $mapa = @(
                @{ Suf = '.es.forced.srt'; Lang = 'spa'; Titulo = 'Castellano (forzados)'; Forzado = $true },
                @{ Suf = '.en.forced.srt'; Lang = 'eng'; Titulo = 'English (forced)';       Forzado = $true },
                @{ Suf = '.es.srt';        Lang = 'spa'; Titulo = 'Castellano';            Forzado = $false },
                @{ Suf = '.en.srt';        Lang = 'eng'; Titulo = 'English';               Forzado = $false }
            )
            foreach ($m in $mapa) {
                $f = @(Get-ChildItem -LiteralPath $sfDir -Filter "*$($m.Suf)" -File -ErrorAction SilentlyContinue)
                if ($f.Count -eq 0) { continue }
                # Se mueve FUERA de $sfDir: el finally de abajo borra la carpeta, y
                # ffmpeg todavia no ha leido nada (arranca mucho mas adelante).
                $destino = Join-Path $BigTmp ("sfsrt_{0}_{1}.srt" -f $TmpTag, $m.Lang + $(if($m.Forzado){'f'}else{''}))
                # -ErrorAction Stop y comprobacion del efecto (31/08/2026). Sin
                # esto el movimiento podia fallar en silencio -este script corre
                # con 'Continue'- y la ruta se anyadia igual a $SrtInputs: ffmpeg
                # reventaba mucho despues por un fichero que no existe, con un
                # error que no señala a esta linea. El nombre lleva sello de
                # tiempo, asi que el destino nunca deberia existir; si existe,
                # mejor saltarse ese subtitulo que pisar algo.
                try { Move-Item -LiteralPath $f[0].FullName -Destination $destino -ErrorAction Stop }
                catch {
                    Log "  [subs] AVISO: no se pudo preparar $($m.Titulo): $($_.Exception.Message)"
                    continue
                }
                if (-not (Test-Path -LiteralPath $destino)) {
                    Log "  [subs] AVISO: $($m.Titulo) no llego a $destino; se omite."
                    continue
                }
                $SrtInputs += @{ Path = $destino; Lang = $m.Lang; Title = $m.Titulo; Forzado = $m.Forzado }
                Log "  [subs] anadido: $($m.Titulo)"
            }
            if ($SrtInputs.Count -eq 0) { Log "  [subs] no se consiguio ninguno; la pelicula se queda sin subtitulos." }
        } catch {
            # Que NO tumbe el encode: esto es un extra, no un requisito.
            Log "  [subs] fallo la busqueda ($_). Se sigue sin subtitulos."
        } finally {
            Remove-Item -LiteralPath $sfDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Preparar argumentos extras de entradas para los SRT generados por el OCR
    # (NO reinicializar $SrtMetaArgs aqui: ya se creo antes del bucle de subtitulos
    #  y puede contener correcciones de titulo de pistas de texto nativas.)
    # OJO: $ExtraInputs / $inputIdx YA vienen inicializados de la seccion de audio
    # (los .ec3 DDP+Atmos ocupan los primeros indices). Aqui solo se ANADEN los SRT.
    foreach ($srt in $SrtInputs) {
        $ExtraInputs += @('-i', $srt.Path)
        $SubMap += @('-map', "${inputIdx}:s:0")
        $SubCodec += @("-c:s:$subOut", "srt")
        $SrtMetaArgs += @("-metadata:s:s:$subOut", "language=$($srt.Lang)", "-metadata:s:s:$subOut", "title=$($srt.Title)")
        # Bandera de FORZADO. Sin esto Plex no distingue la pista de forzados de la
        # completa y el usuario acaba con todo el dialogo subtitulado cuando solo
        # queria los rotulos. Solo la ponen los SRT de subsfetch; los del OCR no
        # traen la clave y el operador -eq sobre $null da $false, que es lo correcto.
        if ($srt.Forzado) { $SrtMetaArgs += @("-disposition:s:$subOut", "forced") }
        $subOut++
        $inputIdx++
    }

    if ($SubsDropped -gt 0) { Log "AVISO: $SubsDropped pista(s) de subtitulos descartada(s)." }
}

if (-not $ParaleloAV) { . $DoSubsPhase }

# -- Encode --------------------------------------------------------
Remove-Item -LiteralPath $ProgFile -ErrorAction SilentlyContinue
$statusEnc = @"
status=encoding
file=$(Split-Path $Output -Leaf)
duration=$Duration
fps_src=$FpsSrc
stage=video
pct=0
"@
WriteNoBom $StatusFile $statusEnc

if ($SubsOnly) {
    # Solo subtitulos: video y audio en copy. Sin -hwaccel qsv (no se decodifica
    # nada), sin -vf, sin parametros de encoder, y sin $HdrArgs: los metadatos HDR
    # viajan DENTRO del stream copiado, asi que reinyectarlos aqui sobraria.
    $ff = @(
        '-y',
        '-i', $InputFile
    ) + $ExtraInputs + @(
        '-map','0:v:0'
    ) + $AudioMap + $AudioCodec + $SubMap + $SubCodec + @(
        '-c:v','copy',
        '-map_metadata','0','-map_chapters','0'
    ) + $AudioMetaArgs + $SrtMetaArgs + @(
        '-progress', $ProgFile, '-nostats',
        $Output
    )
} else {
# Argumentos del ENCODER en su propia variable. Motivo: el camino solapado
# necesita una pasada de VIDEO SOLO con EXACTAMENTE estos mismos argumentos, y
# copiarlos seria la forma mas segura de que un dia dejen de coincidir. Estan
# medidos uno a uno (ver la skill arc-qsv-facts y el comentario largo de aqui
# debajo): no se tocan.
$VideoEncArgs = @(
    '-vf', $Vf,
    '-c:v','hevc_qsv',
    '-preset',$Preset,
    '-global_quality', "$Gq"
    # --- ICQ PURO EN 1080p (22/08/2026) -------------------------------------
    # Sin -b:v/-maxrate/-bufsize manda solo el GQ y el bitrate sigue a la
    # complejidad de cada escena. El GQ NO cambia: la calidad pedida es la
    # misma de antes, solo se reparte bien.
    # MEDIDO (El resplandor 1080p, 3 tramos de 180 s, args de produccion):
    #   escena dura : pedia 9.26 y con -b:v 7.5M recibia 7.41  -> hambre
    #   escena facil: pedia 5.55 y con -b:v 7.5M recibia 7.26  -> inflada
    #   media 7.21 -> 6.97 Mbps, o sea que ademas ocupa MENOS.
    # MEDIDO TAMBIEN: el -b:v es un IMAN, no un techo (un tramo que pide 4.15
    # gasta 9.10 con -b:v 12M), y -maxrate SIN -b:v se dispara a 12.42 donde
    # ICQ puro da 4.15. O van los tres o ninguno: no hay termino medio.
    # PENDIENTE DE VERIFICAR: el banding en degradados. El SSIM no lo mide y en
    # 4K a GQ 20 se aprecio a ojo. Aqui el GQ no baja, pero los tramos faciles
    # reciben menos bits que antes: comprobarlo en una pared oscura.
    if ($UseRateCap) {
        '-b:v', "${Target}M"
        '-maxrate', "${MaxRate}M"
        '-bufsize', "${BufSize}M"
    }
    # --- QUE AJUSTA DE VERDAD LA CALIDAD AQUI (medido, no supuesto) ----------
    # Medido el 29/07 con ab-test.ps1 sobre un clip de 3 min en 4K, comparando el
    # MD5 de los PAQUETES de video y el SSIM. Metodo: una opcion cada vez desde
    # esta misma configuracion.
    #
    # INERTES (0 y 1 producen el MISMO bitstream, byte a byte):
    #   -extbrc, -look_ahead_depth (0/10/30/60/100), -rdo,
    #   -adaptive_i, -adaptive_b, -scenario, -low_power (0 y 1)
    # Lo del lookahead se explica por extbrc: la ayuda de ffmpeg dice que solo
    # aplica con extbrc activo, y extbrc no hace nada, asi que nunca pudo entrar.
    #
    # ACTUAN, PERO EL EFECTO ES RUIDO:
    #   -mbbrc 1->0 : -0.06 % tamano, -0.0000019 SSIM
    #   -refs  4->6 : -0.06 % tamano, +0.0000050 SSIM
    #   -bf    3->4 : +0.53 % tamano, +0.0000310 SSIM  (peor: paga mucho por nada)
    #
    # IMPORTA DE VERDAD:
    #   -b_strategy 1->0 : +0.14 % tamano Y -0.0001110 SSIM (peor por los dos
    #   lados), y has_b_frames cae de 2 a 1. Es el unico mando cuyo efecto sale
    #   claramente del ruido: ~58 veces el de mbbrc. DEJARLO EN 1.
    #
    # CONFIRMADO EL 26/08/2026. Antes decia aqui que la hipotesis de "solo hay
    # una ruta de encode" quedaba descartada por falta de prueba. Ya esta
    # probada, y con un instrumento mejor que el MD5: 'ffmpeg -v verbose' vuelca
    # los parametros que el DRIVER DEVUELVE tras negociar, no los que se piden.
    # Ese volcado dice 'VDENC: ON' con -low_power 0, con 1 y con auto. La Arc
    # A730M SOLO tiene la ruta VDENC; no hay ruta legacy a la que caer, y por eso
    # el BRC de esta GPU no es configurable desde fuera.
    #
    # Los flags inertes se dejan puestos: no cuestan nada y un driver futuro
    # podria activarlos. Pero NO son lo que ajusta la calidad, y por eso el log ya
    # no anuncia "extbrc+LA60" (era falso). Las palancas reales de este pipeline
    # son el GQ, el par -b:v/-maxrate y la cadena vpp_qsv.
    #
    # -preset SI FUNCIONA, y es de las pocas que cambian algo apreciable. Pero el
    # driver COLAPSA presets en TRES grupos, con bitstream IDENTICO dentro de
    # cada uno: {veryslow, slower}, {slow, medium}, {veryfast}. De siete escalones
    # nominales hay tres reales. Medido sobre el mismo clip:
    #   veryslow -> slow/medium : -0.106 % tamano, -0.0000331 SSIM
    #   veryslow -> veryfast    : -0.183 % tamano, -0.0000853 SSIM
    # Lo grande es el tiempo: 67.9 fps en veryslow contra 108.2 en medium, o sea
    # 93 min contra 58 min en ESDLA RdR. Por eso el pipeline usa $Preset=medium
    # desde el 30/07 (ver la definicion arriba, con el razonamiento completo).
    #
    # -async_depth (8 y 16): SIN EFECTO. Da el mismo bitstream, como se esperaba,
    # pero tampoco acelera. El "10 % de mejora" que parecia tener en la primera
    # medida era CALENTAMIENTO de la GPU: tres configuraciones que producian el
    # bitstream identico salieron en 237, 218 y 212 s solo por el orden de
    # ejecucion. Leccion de metodo: para medir TIEMPOS hace falta una pasada de
    # calentamiento previa (ab-test.ps1 ya la hace) y no fiarse de una sola.
    #
    # PROBADAS Y DESCARTADAS el 29/07 (no se anyade ninguna):
    #   -min_qp_i/p/b   : INERTE (mismo MD5). Era la candidata mas prometedora
    #                     para dejar de malgastar bits en escenas faciles.
    #   -transform_skip : INERTE
    #   -gpb 0          : funciona, pero PEOR (+0.04 % tamano, -0.0000539 SSIM).
    #                     El default 1 ya es lo correcto; por eso no se pasa.
    #   -idr_interval 2 : funciona, pero es ruido (-0.01 %, +0.0000050 SSIM) y
    #                     encima haria el seek mas grueso.
    #   -dual_gfx 2     : el encoder no abre (HyperEncode con la iGfx).
    #
    # POR QUE HAY TANTA OPCION MUERTA (corregido el 26/08/2026). La explicacion
    # que habia aqui era EQUIVOCADA: decia que -adaptive_i y -adaptive_b estaban
    # muertos por depender de -extbrc. No es cierto. El volcado del driver los
    # reporta 'AdaptiveI: ON; AdaptiveB: ON' cuando se piden y 'OFF' cuando no,
    # o sea que los acepta; simplemente no cambian el bitstream aqui.
    #
    # La linea de corte real es otra, y las separa a todas limpiamente:
    #   - INERTE  todo lo que toca el BRC HARDWARE: -extbrc, -look_ahead_depth,
    #     -min_qp/-max_qp, -max_frame_size, low_delay_brc.
    #   - FUNCIONA todo lo que toca GOP y referencias: -bf (GopRefDist), -refs
    #     (NumRefFrame), -b_strategy, -gpb, -idr_interval, -preset (TargetUsage).
    # Es el BRC de VDENC, que va en hardware y no admite que le lleven la mano.
    #
    # Como lo dice el driver, medido el 26/08/2026:
    #   -extbrc        -> devuelve 'ExtBRC: OFF' pidiendo 1 Y pidiendo 0. Nunca
    #                     ON. El lookahead depende de el, asi que cae por arrastre.
    #   -min_qp_i/p/b  -> devuelve 'MinQPI: 30' (LO ACEPTA) y luego da el
    #                     bitstream IDENTICO byte a byte con 24, 27, 30 y 33.
    #                     Se reporta aceptado y se ignora: peor que un rechazo.
    #   -max_frame_size-> se le piden 5000 B/frame (forzaria ~1 Mbps) y devuelve
    #                     'MaxFrameSize: 0'. Bitstream identico al de sin tope.
    # El buffer de extension SI llega al driver: -mbbrc y -adaptive_i/b viven en
    # el MISMO buffer y siguen fielmente lo que se les pide. O sea que lo de
    # arriba son rechazos del hardware, no un fallo de cableado de ffmpeg.
    #
    # CONSECUENCIA: QSVEncC (rigaya) NO puede mejorar esto. Va contra el mismo
    # runtime oneVPL y el mismo driver, y el reseteo de ExtBRC lo hace
    # MFXVideoENCODE_Query, que es identico para cualquier cliente. Queda cerrado
    # el hilo 3.1 del TRASPASO_2026-08-25.md sin necesidad de instalarlo.
    # OJO con -qsv_params al reabrir esto: SOLO acepta campos base de mfxInfoMFX.
    # Una clave inventada da EXACTAMENTE el mismo error que ExtBRC=1, asi que ese
    # mensaje significa "ffmpeg no conoce la clave", NO "el driver la rechaza".
    # Lo que SI funciona es todo lo que toca estructura de GOP y referencias:
    # -bf, -refs, -b_strategy, -gpb, -idr_interval, ademas de -preset y el GQ.
    #
    # CONCLUSION: el encoder HEVC esta agotado como fuente de mejora. Las unicas
    # palancas reales que quedan son el GQ, el par -b:v/-maxrate y vpp_qsv.
    #
    # ALCANCE: "inerte" significa inerte EN ESTA configuracion, no en el vacio.
    '-extbrc','1','-look_ahead_depth','60',
    '-adaptive_i','1','-adaptive_b','1','-b_strategy','1',
    '-mbbrc','1','-rdo','1',
    '-scenario','archive',
    '-bf','3','-refs','4',
    '-profile:v','main10',
    '-g', "$Gop"
)

# El encode de SIEMPRE: video, audio y subtitulos en UNA llamada. Va en un
# scriptblock invocado con '.' (corre en este ambito) porque ahora hace falta en
# dos momentos distintos: el camino normal, y la RED del camino solapado cuando
# su pasada de video falla. Duplicarlo seria duplicar el mapeo entero.
$BuildClassicFf = {
    $ff = @(
        '-y',
        '-hwaccel','qsv','-hwaccel_output_format','qsv',
        '-i', $InputFile
    ) + $ExtraInputs + @(
        '-map','0:v:0'
    ) + $AudioMap + $AudioCodec + $SubMap + $SubCodec + $VideoEncArgs + @(
        '-map_metadata','0','-map_chapters','0'
    ) + $HdrArgs + $AudioMetaArgs + $SrtMetaArgs + @(
        '-progress', $ProgFile, '-nostats',
        $Output
    )
}

if ($ParaleloAV) {
    # PASADA 1: SOLO VIDEO, a un temporal en $BigTmp. Todavia no hay .ec3, asi
    # que no se mapea audio ni subtitulos y NO pueden ir $AudioMetaArgs ni
    # $SrtMetaArgs: un -metadata:s:a:0 sobre un fichero sin pista de audio hace
    # abortar a ffmpeg. Todo lo demas (filtros, encoder, HDR, capitulos) es
    # identico al camino de siempre.
    $ff = @(
        '-y',
        '-hwaccel','qsv','-hwaccel_output_format','qsv',
        '-i', $InputFile,
        '-map','0:v:0'
    ) + $VideoEncArgs + @(
        '-map_metadata','0','-map_chapters','0'
    ) + $HdrArgs + @(
        '-progress', $ProgFile, '-nostats',
        $VidTmp
    )
} else {
    . $BuildClassicFf
}
}

$argline = ($ff | ForEach-Object {
    if ($_ -match '[\s"()]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" }
}) -join ' '

# -- Espacio para la SALIDA -----------------------------------------------
# El otro sitio donde encode.ps1 entraba a ciegas. Un ffmpeg que se queda sin
# disco a la hora y media deja un MKV truncado y quema el encode entero; es
# exactamente lo que le paso al mkvmerge que escribia en encode_queue el
# 31/07/2026 (murio a los 56,7 GB y el fichero quedo sin duracion legible).
# En SubsOnly el video va en copy, asi que la salida pesa casi lo que la fuente.
# En un encode normal se estima con el target real ya calculado, con un 25 % de
# holgura porque el maxrate puede tirar por encima en tramos complejos.
$OutNeed = if ($SubsOnly) {
    [long]((Get-Item -LiteralPath $InputFile).Length * 1.05) + 5GB
} else {
    [long](($Target + $AudioMbps) * 1e6 * $Duration / 8 * 1.25) + 5GB
}
if (-not (Test-DdpSpace -Path $EncodedDir -NeededBytes $OutNeed -Label 'video')) {
    Exit-Requeue "sin espacio en $EncodedDir para la salida"
}

# --- Lanzar ffmpeg -------------------------------------------------------
# Es UNA PASADA, y ahora puede haber dos: en el camino de siempre solo esta la
# de encode; con el audio solapado hay una de VIDEO SOLO y otra de MUX. Va en un
# scriptblock invocado con '.' (corre en ESTE ambito) para no duplicar ni el
# arranque con red, ni el volcado del stderr, ni el PID.
$StartFfmpegPass = {
    param([string]$linea, [string]$etiqueta)

    Remove-Item -LiteralPath $FfErr -ErrorAction SilentlyContinue
    # El comando ffmpeg completo al log SIEMPRE: si falla, esto es lo que hay que
    # reproducir a mano para ver el error de verdad. No cuesta nada y ahorra horas.
    Log "ffmpeg cmd [$etiqueta]: `"$FFMPEG`" $linea"
    # Arranque con red: si Start-Process no consigue lanzar ffmpeg (antes, con
    # 'ffmpeg' del PATH, esto dejaba $proc a $null y el script moria contra
    # $proc.Handle -> "Failed (exit )" mudo), lo capturamos y registramos el motivo.
    $proc = $null
    try {
        $proc = Start-Process -FilePath $FFMPEG -ArgumentList $linea -NoNewWindow -PassThru `
            -RedirectStandardError $FfErr -ErrorAction Stop
    } catch {
        Log "ERROR: no se pudo lanzar ffmpeg ($FFMPEG): $_"
    }
    if ($null -eq $proc) {
        WriteNoBom $StatusFile "status=error`nfile=$(Split-Path $Output -Leaf)`nduration=$Duration`nerror=No se pudo lanzar ffmpeg (ver log)"
        Log "Failed (ffmpeg no arranco)"
        Remove-Item -LiteralPath $OutMarker -ErrorAction SilentlyContinue   # salida controlada: que el watcher no pise el status=error
        # Los .srt, los .ec3, el temporal de video y los workers de audio que
        # sigan vivos los limpia el finally del final: aqui ya no hay que
        # acordarse de nada.
        exit 1
    }
    $null = $proc.Handle
    # PID de ffmpeg aparte (referencia/debug). El que mata el panel es encode_pid,
    # que ya tiene el PID de encode.ps1 escrito al principio.
    $proc.Id | Set-Content -LiteralPath (Join-Path $Tmp "${StatePfx}_ffmpeg_pid")
    # Queda en el ambito del script para que el finally pueda matarlo si el
    # trabajo se aborta con el encode en marcha, y para que $WaitFfmpegPass lo
    # encuentre cuando se lanza y se espera por separado.
    $VideoProc = $proc
}

# La ESPERA, aparte del arranque: asi, en el camino solapado, entre lanzar el
# video y esperarlo se puede hacer otra cosa util (el OCR de los subtitulos).
$WaitFfmpegPass = {
    param($estadoAudio = $null)

    if ($estadoAudio) {
        # Con el audio solapado NO se puede bloquear en WaitForExit: si hay mas
        # pistas que ranuras, la siguiente solo arranca desde Step-.
        #
        # El audio de fondo NO puede publicar stage/pct -app.py:450 los usa para
        # PISAR el porcentaje del ffprog y ademas borra el ETA-, pero si puede
        # publicar su avance en dos campos APARTE (audio_stage/audio_pct) que el
        # panel pinta como linea secundaria. El fichero se reescribe entero con
        # stage=video, que es justo el valor que deja mandar al ffprog.
        # Cada 5 s y no cada segundo: el dato no cambia tan rapido y no hace
        # falta machacar el fichero que el panel esta leyendo.
        $cbAudio = {
            param($stage, $pct)
            if (((Get-Date) - $script:UltimoAvisoAudio).TotalSeconds -lt 5) { return }
            $script:UltimoAvisoAudio = Get-Date
            WriteNoBom $StatusFile ("status=encoding`nfile={0}`nduration={1}`nfps_src={2}`nstage=video`npct=0`naudio_stage={3}`naudio_pct={4}" -f `
                (Split-Path $Output -Leaf), $Duration, $FpsSrc, $stage, $pct)
        }
        while (-not $VideoProc.HasExited) {
            Start-Sleep -Milliseconds 1000
            $null = Step-DdpTracksParallel -State $estadoAudio -OnProgress $cbAudio
        }
    }
    $VideoProc.WaitForExit()
    $ExitCode = $VideoProc.ExitCode
    $VideoProc = $null
    Get-Content -LiteralPath $FfErr -ErrorAction SilentlyContinue | Add-Content -LiteralPath $LogFile
    $ffTail = Get-Content -LiteralPath $FfErr -Tail 20 -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $FfErr -ErrorAction SilentlyContinue
}

# Arrancar y esperar de una vez: es lo que quieren todas las llamadas menos la
# pasada de video del camino solapado.
$RunFfmpegPass = {
    param([string]$linea, [string]$etiqueta, $audioState = $null)
    . $StartFfmpegPass $linea $etiqueta
    . $WaitFfmpegPass $audioState
}

if (-not $ParaleloAV) {
    . $RunFfmpegPass $argline 'encode'
} else {
    # ---------- PASADA 1: el video, con el audio corriendo por detras --------
    # Se LANZA sin esperar, y mientras encodea se hace el OCR de los
    # subtitulos: la pasada de video no los mapea, asi que no los necesita. Con
    # eso, las tres cosas que tardan -audio, OCR y video- van a la vez.
    . $StartFfmpegPass $argline 'pasada 1: solo video'
    . $DoSubsPhase
    . $WaitFfmpegPass $AudioBg
    # RED DE SEGURIDAD. El 17/08/2026 esta pasada murio al 88 % con
    # '[hevc_qsv] Invalid FrameType:0' -> 'Error submitting video frame to the
    # encoder'. LA CAUSA NO SE ENCONTRO, y no se reproduce a voluntad:
    #   - la MISMA linea de ffmpeg, sola, termina bien (verificado)
    #   - el mismo ffmpeg con DEE corriendo a la vez, en un banco sin encode.ps1,
    #     termino bien 2 de 2 veces
    #   - ese error no aparece en NINGUNO de los 265 logs historicos del pipeline
    # O sea: 0 de 265 en el camino de siempre y 1 de 2 en el solapado. Apunta a
    # que solapar anyade un modo de fallo, pero con esa n no es demostracion.
    # En vez de tirar el trabajo, se rehace el video por el camino CLASICO: es el
    # encode de siempre, da el MISMO fichero (mismos argumentos de encoder) y ya
    # lleva 265 trabajos funcionando. Cuesta el tiempo del video perdido -unos 3
    # minutos mas que si el trabajo hubiera ido en serie desde el principio- y a
    # cambio no se pierde ni el trabajo ni el Atmos que DEE ya ha convertido.
    $VideoPass1Fallo = ($ExitCode -ne 0 -or -not (Test-Path -LiteralPath $VidTmp))
    if ($VideoPass1Fallo) {
        Log "AVISO: la pasada de VIDEO fallo (exit $ExitCode). NO se aborta el trabajo:"
        Log "  se espera al audio y se rehace el video por el camino CLASICO (mismo"
        Log "  encode de siempre, mismo fichero resultante)."
        if ($ffTail) { Log "---- ffmpeg error ----"; $ffTail | ForEach-Object { Log $_ } }
        Remove-Item -LiteralPath $VidTmp -Force -ErrorAction SilentlyContinue
    } else {
        Log ("Video listo en el temporal: {0}" -f (FmtSize (Get-Item -LiteralPath $VidTmp).Length))
    }

    # ---------- JOIN del audio ----------------------------------------------
    # El ffprog ya ha terminado y app.py lo leeria como progress=end -> idle, o
    # sea "no hay nada en marcha" mientras el audio sigue. Se BORRA y se pasa a
    # reportar por encode_status, que a partir de aqui vuelve a tener un unico
    # escritor (ver app.py:450: un stage != 'video' pisa el pct del ffprog y
    # ademas deja el ETA vacio, por eso no podian escribir los dos a la vez).
    Remove-Item -LiteralPath $ProgFile -ErrorAction SilentlyContinue
    WriteNoBom $StatusFile "status=encoding`nfile=$CleanName.mkv`nduration=$Duration`nstage=audio`npct=0"
    $tJoin = Get-Date
    $par = @(Wait-DdpTracksParallel -State $AudioBg -OnProgress $AudioProgress)
    $AudioJoined = $true
    Log ("Join del audio: {0:N0}s esperando al audio despues del video." -f ((Get-Date) - $tJoin).TotalSeconds)
    Complete-DdpPhase $par

    # El audio REAL ya se conoce. El $Target del video se calculo con el
    # ESTIMADO -no habia otra-, asi que la diferencia se deja escrita en el log
    # en vez de esconderla; y el registro de completed.jsonl usa el real.
    $AudioRealBps = 0
    foreach ($p in ($AudioPlan | Where-Object { $_.Keep })) { $AudioRealBps += $p.Est }
    $AudioRealM = [math]::Round($AudioRealBps / 1e6, 1)
    if ($AudioRealM -ne $AudioMbps) {
        Log ("Audio: estimado {0}M -> real {1}M (el target del video se fijo con el estimado)" -f $AudioMbps, $AudioRealM)
    }
    $AudioMbps = $AudioRealM

    # Los mapas de audio, AHORA: hasta el join no se sabe que pista trae .ec3 y
    # cual cayo a eac3, y de eso depende como se mapea cada una.
    . $BuildAudioMaps

    if ($VideoPass1Fallo) {
        # ---------- RED: el encode CLASICO, ya con el audio listo ------------
        # Mismos $VideoEncArgs, mismo mapeo, misma salida: lo unico que se ha
        # perdido es el tiempo del video que murio. El audio NO se rehace (los
        # .ec3 ya estan), asi que esto cuesta un encode de video, no un trabajo
        # entero.
        Log "Rehaciendo el video por el camino clasico (encode + mux en una sola llamada)..."
        if (-not (Test-DdpSpace -Path $EncodedDir -NeededBytes $OutNeed -Label 'video')) {
            Exit-Requeue "sin espacio en $EncodedDir para el encode de respaldo"
        }
        . $BuildClassicFf
        $argline = ($ff | ForEach-Object {
            if ($_ -match '[\s"()]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" }
        }) -join ' '
        Remove-Item -LiteralPath $ProgFile -ErrorAction SilentlyContinue
        WriteNoBom $StatusFile "status=encoding`nfile=$(Split-Path $Output -Leaf)`nduration=$Duration`nfps_src=$FpsSrc`nstage=video`npct=0"
        . $RunFfmpegPass $argline 'respaldo: encode clasico tras fallar la pasada de video'
    } else {
    # ---------- PASADA 2: mux en copy ---------------------------------------
    # El input 0 SIGUE SIENDO LA FUENTE: de ahi salen los capitulos, el
    # -map_metadata, los audios en copy y los subtitulos nativos. El video ya
    # encodeado entra como una entrada mas, la ultima, para no mover los indices
    # de los .ec3 ni de los .srt.
    # Se caen, respecto a la pasada 1: -hwaccel (no se decodifica nada), -vf
    # (con -c:v copy ffmpeg aborta: "Filtering and streamcopy cannot be used
    # together") y todo el bloque del encoder. $HdrArgs SI se queda: son
    # metadatos, valen con copy y dejan las etiquetas de color escritas por
    # nosotros en vez de a merced de lo que arrastre la copia.
    if (-not (Test-DdpSpace -Path $EncodedDir -NeededBytes $OutNeed -Label 'mux')) {
        Exit-Requeue "sin espacio en $EncodedDir para el mux final"
    }
    $vidIdx = $inputIdx
    $ff = @(
        '-y',
        '-i', $InputFile
    ) + $ExtraInputs + @(
        '-i', $VidTmp,
        '-map', "${vidIdx}:v:0"
    ) + $AudioMap + $AudioCodec + $SubMap + $SubCodec + @(
        '-c:v','copy',
        '-map_metadata','0','-map_chapters','0'
    ) + $HdrArgs + $AudioMetaArgs + $SrtMetaArgs + @(
        '-progress', $ProgFile, '-nostats',
        $Output
    )
    $argline = ($ff | ForEach-Object {
        if ($_ -match '[\s"()]') { '"' + ($_ -replace '"','\"') + '"' } else { "$_" }
    }) -join ' '
    Remove-Item -LiteralPath $ProgFile -ErrorAction SilentlyContinue
    WriteNoBom $StatusFile "status=encoding`nfile=$(Split-Path $Output -Leaf)`nduration=$Duration`nfps_src=$FpsSrc`nstage=video`npct=0"
    . $RunFfmpegPass $argline 'pasada 2: mux en copy'
    }
}

# Limpieza de los archivos SRT temporales creados para la inyeccion
foreach ($srt in $SrtInputs) {
    Remove-Item -LiteralPath $srt.Path -ErrorAction SilentlyContinue
}
# Limpieza de los .ec3 DDP+Atmos temporales
foreach ($ec3 in $AtmosEc3.Values) {
    Remove-Item -LiteralPath $ec3 -ErrorAction SilentlyContinue
}
# ...y del temporal de video del camino solapado.
if ($VidTmp) { Remove-Item -LiteralPath $VidTmp -Force -ErrorAction SilentlyContinue }

if ($ExitCode -eq 0 -and (Test-Path -LiteralPath $Output)) {
    $outBytes = (Get-Item -LiteralPath $Output).Length
    if ($outBytes -lt ($SourceBytes * 0.05)) {
        Log "ERROR: output too small - source may be corrupt"
        Remove-Item -LiteralPath $Output -ErrorAction SilentlyContinue
        WriteNoBom $StatusFile "status=error`nfile=$(Split-Path $Output -Leaf)`nduration=$Duration`nerror=Output too small"
        Remove-Item -LiteralPath $OutMarker -ErrorAction SilentlyContinue
        exit 1
    }
    # Progreso del POST-PROCESO para el panel. ffmpeg ya termino (la copia en
    # SubsOnly o el encode), pero reconstruir el contenedor y recalcular tags puede
    # tardar MUCHO mas que ffmpeg en un 4K: medido ~30 min con el disco en
    # contencion. Sin estas marcas el panel se congela en el ultimo out_time de
    # ffmpeg -que en '-c:v copy' ni siquiera llega al 100% (lo vimos parado al ~47%
    # con la copia YA terminada)- y parece colgado; eso hizo cancelar dos peliculas
    # que en realidad estaban listas. app.py lee stage/pct y muestra la fase.
    WriteNoBom $StatusFile "status=encoding`nfile=$(Split-Path $Output -Leaf)`nduration=$Duration`nstage=rebuild`npct=0"
    # Reconstruccion del contenedor. Va ANTES de los mkvpropedit de abajo porque
    # rehacer el fichero se lleva por delante las propiedades de color y los tags,
    # asi que el mastering display HDR10 y las estadisticas deben escribirse
    # DESPUES, sobre el fichero definitivo. Ver el bloque de Rebuild-Container.
    #
    # El 'pct' que se escribe aqui es el DE LA FASE (0-100). Quien lo reparte en la
    # barra global es app.py (ENC_BANDAS): asi el reparto vive en UN sitio y no hay
    # que tocar dos ficheros para mover un tramo.
    $UltPctRebuild = -1.0
    $cbRebuild = {
        param($pct)
        # Se escribe solo cuando cambia medio punto: el fichero de estado lo esta
        # sondeando el panel y no hace falta machacarlo 200 veces.
        if ([math]::Abs($pct - $script:UltPctRebuild) -lt 0.5) { return }
        $script:UltPctRebuild = $pct
        WriteNoBom $StatusFile ("status=encoding`nfile={0}`nduration={1}`nstage=rebuild`npct={2:N1}" -f `
            (Split-Path $Output -Leaf), $Duration, $pct)
    }
    $Reconstruido = $false
    if ($NoRebuild) {
        Log "RECONSTRUCCION SALTADA (-NoRebuild). Es una PRUEBA: si esta pelicula da pantalla negra en la TV de 2024, GUARDALA sin borrarla."
    } else {
        $Reconstruido = Rebuild-Container -File $Output -OnProgress $cbRebuild
        if ($Reconstruido) { $outBytes = (Get-Item -LiteralPath $Output).Length }
    }
    $sz = FmtSize $outBytes

    # Los tags de estadisticas (BPS, NUMBER_OF_BYTES, _STATISTICS_*) que escribio
    # mkvmerge en el ORIGEN se arrastran al destino via -map_metadata 0, y ahi
    # mienten: declaran el bitrate/tamano del fichero de partida, no del nuestro.
    # Importa porque este mismo script lee 'stream_tags=BPS' para estimar
    # ($BitrateSrc), asi que un fichero ya procesado se reprocesaria con datos
    # falsos. --add-track-statistics-tags los RECALCULA (si existen, los
    # actualiza), asi que el resultado queda correcto para MediaInfo, Plex y para
    # nosotros. No es critico: si falla, solo se pierde la correccion.
    #
    # SE SALTA SI LA RECONSTRUCCION FUE BIEN (19/08/2026). Rebuild-Container llama
    # a mkvmerge SIN --disable-track-statistics-tags, y mkvmerge escribe esos tags
    # por su cuenta. COMPROBADO, no leido en el manual: se genero un MKV con
    # ffmpeg (sin ningun tag BPS: '(sin tag)' en las dos pistas), se paso por
    # mkvmerge igual que hace la reconstruccion, y salio con BPS=162914 en video y
    # BPS=95973 en audio. O sea que recalcularlos despues es releer el fichero
    # ENTERO -10 GB en una pelicula normal- para reescribir lo que ya esta bien.
    # Sigue haciendo falta cuando NO hubo reconstruccion (-NoRebuild, o fallo, o
    # falta mkvmerge): ahi el fichero es el de ffmpeg y arrastra por -map_metadata
    # los tags MENTIROSOS del origen, que este mismo script lee luego como
    # 'stream_tags=BPS' para estimar el bitrate de un reproceso.
    WriteNoBom $StatusFile "status=encoding`nfile=$(Split-Path $Output -Leaf)`nduration=$Duration`nstage=finalizing`npct=0"
    if (Test-Path -LiteralPath $MKVPROPEDIT) {
        if ($Reconstruido) {
            Log "Stats tags: ya los escribio mkvmerge al reconstruir; se salta la pasada de mkvpropedit (una lectura completa del fichero menos)"
        } else {
            & $MKVPROPEDIT $Output --add-track-statistics-tags 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Log "Stats tags recalculados (mkvpropedit)" }
            else { Log "AVISO: mkvpropedit devolvio $LASTEXITCODE - los tags de estadisticas pueden quedar obsoletos" }
        }

        # Reinyeccion del mastering display HDR10 capturado del origen. Va en una
        # llamada APARTE a proposito: si mkvpropedit rechazara alguna propiedad,
        # se pierde solo esto y los stats tags de arriba quedan intactos.
        if ($MdcvProps.Count -gt 0) {
            & $MKVPROPEDIT $Output --edit track:v1 @MdcvProps 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Log ("HDR10 mastering display reinyectado ({0} propiedades)" -f ($MdcvProps.Count/2)) }
            else { Log "AVISO: mkvpropedit devolvio $LASTEXITCODE al reinyectar el mastering display HDR10" }
        }
    } else {
        Log "AVISO: no encuentro mkvpropedit en $MKVPROPEDIT - los tags de estadisticas quedan los del origen"
    }
    # --- Registro para completed.jsonl -----------------------------------
    # Antes solo guardaba output/source/size/subs_dropped/ts, y con eso era
    # IMPOSIBLE responder a lo unico que importa para afinar: si el encode lo
    # goberno el GQ o el techo de bitrate.
    # QVBR (verificado el 29/07 leyendo el log verbose de ffmpeg: "RateControl
    # Method: QVBR, QVBRQuality: 15") pide calidad $Gq y gasta HASTA $Target:
    #   - peli facil     -> el GQ cuesta menos que el techo y manda el GQ
    #   - peli exigente  -> el GQ pide mas de lo que hay y manda el techo
    # En un clip de ESDLA RdR, GQ 15 pedia 13.8 Mbps contra un techo de 8.
    # Sin duracion ni target en el registro no se puede distinguir un caso del
    # otro, y sin eso se afina a ciegas. Con estos campos, en 10-15 peliculas
    # se sabe medido en vez de discutido.
    $vidMbps = 0.0
    if ($Duration -gt 0) {
        $vidMbps = [math]::Round((($outBytes * 8.0 / $Duration) / 1e6) - $AudioMbps, 2)
    }
    # cap_bound: el bitrate de video logrado quedo pegado al target (>=95 %), o
    # sea que mando el TECHO y el GQ no llego a expresarse.
    # En ICQ puro no hay techo que topar: cap_bound es siempre false y
    # target_mbps queda solo como referencia de lo que habria sido el techo.
    $capBound = ($UseRateCap -and ($Target -gt 0) -and ($vidMbps -ge ($Target * 0.95)))
    # El if va fuera del hashtable a proposito: dentro es fragil segun version.
    $recMode = "encode"
    if ($SubsOnly) { $recMode = "subs_only" }
    $rec = @{
        output       = (Split-Path $Output -Leaf)
        source       = $InputFile
        size         = $sz
        size_bytes   = $outBytes
        subs_dropped = $SubsDropped
        mode         = $recMode
        type         = $Type
        res          = $Res
        hdr          = $Hdr
        duration_s   = $Duration
        gq           = $Gq
        target_mbps  = $Target
        maxrate_mbps = $MaxRate
        audio_mbps   = $AudioMbps
        video_mbps   = $vidMbps
        src_mbps     = [math]::Round($BitrateSrc / 1e6, 2)
        src_codec    = $SrcCodec
        src_pix_fmt  = $SrcPixFmt
        cap_bound    = $capBound
        # QUE PERFIL LO HIZO (26/08/2026). Hasta ahora esto habia que ADIVINARLO
        # del GQ, y adivinar mal es facil: 4K estuvo en 'icq' con GQ 18 del 22 al
        # 25/08 y volvio a 'techo' con GQ 15 despues. Sin este campo, cualquier
        # analisis futuro de completed.jsonl mezcla los dos regimenes -que no son
        # comparables, porque en 'icq' el target no gobierna nada- sin que nada
        # avise. 'techo' | 'icq'.
        rate_mode    = $CfgPerfil
        # 0 = automatico. Sin este campo, un encode con el bitrate puesto a mano
        # es indistinguible de uno normal al releer el jsonl, y contamina
        # cualquier analisis de "cuanto pide el GQ" o "cuantas veces recorta el
        # tope del 70 %". Mismo motivo que rate_mode.
        target_manual = $TargetMbps
        # 'auto' | 'icq' | 'qvbr': lo que se PIDIO. El modo realmente usado sale
        # de rate_mode. Los dos hacen falta: con 'auto' pueden diferir (la guarda
        # de ICQ), y sin este campo no se puede saber despues si una pelicula
        # rara se encodeo asi porque lo pediste tu o porque lo decidio el perfil.
        rate_mode_req = $RateMode
        ts           = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress
    Add-Content -LiteralPath (Join-Path $LogDir "completed.jsonl") $rec
    WriteNoBom $StatusFile "status=idle"
    Remove-Item -LiteralPath $OutMarker -ErrorAction SilentlyContinue   # trabajo terminado: la salida es buena, nadie debe borrarla
    if (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue) {
        $toastMsg = "$(Split-Path $Output -Leaf) - $sz"
        if ($SubsDropped -gt 0) { $toastMsg += " (faltan $SubsDropped subs)" }
        New-BurntToastNotification -Text "Encode completado", $toastMsg
    }
    Log "Done: $sz (subs_dropped=$SubsDropped)"
} else {
    if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -ErrorAction SilentlyContinue }
    WriteNoBom $StatusFile "status=error`nfile=$(Split-Path $Output -Leaf)`nduration=$Duration`nerror=ffmpeg exit $ExitCode"
    Remove-Item -LiteralPath $OutMarker -ErrorAction SilentlyContinue   # fallo CONTROLADO: el watcher no debe pisar el status=error
    Log "Failed (exit $ExitCode)"
    if ($ffTail) { Log "---- ffmpeg error ----"; $ffTail | ForEach-Object { Log $_ } }
}

} finally {
    # RED DE SEGURIDAD, no el camino normal: cuando todo va bien, los .ec3, los
    # .srt y el temporal ya se han borrado ahi arriba. Esto cubre las salidas por
    # 'exit', que son CUATRO y estan repartidas por el script (Exit-Requeue por
    # timeout de OCR o por disco, ffmpeg que no arranca, y salida demasiado
    # pequena), sin que nadie tenga que acordarse de limpiar en cada una.
    # Verificado: en PowerShell el finally SI se ejecuta cuando una funcion llama
    # a exit dentro del try, y el codigo de salida se respeta (75 sigue siendo 75).
    # Lo unico que NO cubre es un taskkill /F del panel: de eso se ocupa el
    # Clean-JobLeftovers del watcher, que barre por patron (vid_* incluido).
    if ($AudioBg -and -not $AudioJoined) {
        Log "Limpieza: el trabajo termina con workers de audio todavia vivos."
        $null = Stop-DdpTracksParallel -State $AudioBg
    }
    # Y el ffmpeg del video, si se aborta mientras encodea. Pasa a poder ocurrir
    # desde que el OCR corre EN PARALELO con la pasada de video: un timeout de
    # OCR llama a Exit-Requeue con el encode todavia en marcha, y sin esto
    # quedaria un ffmpeg huerfano comiendose la GPU y el disco.
    if ($VideoProc -and -not $VideoProc.HasExited) {
        Log "Limpieza: matando el ffmpeg de video que seguia en marcha."
        try { $VideoProc.Kill($true) } catch { }
    }
    if ($VidTmp) { Remove-Item -LiteralPath $VidTmp -Force -ErrorAction SilentlyContinue }
    foreach ($s in $SrtInputs)         { Remove-Item -LiteralPath $s.Path -ErrorAction SilentlyContinue }
    foreach ($e in $AtmosEc3.Values)   { Remove-Item -LiteralPath $e      -ErrorAction SilentlyContinue }
}
