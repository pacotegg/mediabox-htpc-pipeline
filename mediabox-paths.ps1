<#
============================================================================
 mediabox-paths.ps1  -  Las rutas que TODOS comparten. Una sola definicion.
============================================================================
 POR QUE EXISTE (19/08/2026)
 ---------------------------
 'G:\MediaTmp' estaba escrito a mano en NUEVE sitios: encode.ps1,
 encode-watch.ps1, atmos-lib.ps1, subs-watch.ps1, audio_encode.ps1,
 audio-watch.ps1, stop-mediabox.ps1, app.py y remuxlib.py. Cinco de ellos
 llevaban ademas el comentario "<-- EDIT: igual que en X", que es la senyal de
 que todo el mundo sabia que era una trampa y nadie la habia desactivado.

 Lo que pasa si divergen no es un error: es SILENCIO. El barrido de temporales
 de los watchers limpia la carpeta que le digan; si apunta a otro sitio del que
 usa el que trabaja, barre una carpeta vacia, no se queja, y los 30-40 GB de un
 trabajo muerto se quedan ahi para siempre. Ya paso lo mismo con las cuatro
 listas de patrones de temporales, que tambien habian divergido (ver
 pipeline-lock.ps1).

 COMO LLEGA A TODAS PARTES
 -------------------------
 No hay ninguna libreria que carguen los siete scripts, pero si hay dos que
 entre las dos los cubren:
   pipeline-lock.ps1 <- encode-watch, subs-watch, audio-watch, stop-mediabox
   atmos-lib.ps1     <- encode.ps1, audio_encode.ps1, atmos-track-worker
 Las dos cargan ESTE fichero, asi que todos lo heredan sin tocar nada mas.
 Cargarlo dos veces es inofensivo: aqui solo se asignan variables.

 EL LADO PYTHON tiene su propia cadena: remuxlib.py define BIGTMP y app.py lo
 toma de ahi (from remuxlib), asi que tambien hay una sola definicion. Las dos
 mitades coinciden en el valor y en la variable de entorno.

 SIEMPRE EN G:  Los temporales pesados van a G: a proposito y no es negociable:
 un DAMF son 12-21 GB (hasta 31 en Interstellar) y un RF64 de deew unos 10, y
 en C: compiten con el pagefile y con las colas. MEDIDO ademas que la CONTENCION
 manda sobre la velocidad del disco: un SATA ocioso bate a un NVMe disputado.
 La variable de entorno MEDIABOX_BIGTMP existe solo para pruebas; sin ella, G:.

 OJO: esto es la ruta PREFERIDA, no la definitiva. Get-BigTmp (atmos-lib.ps1)
 hace ademas una prueba de escritura real y, si G: no responde, cae a C: DEJANDO
 AVISO en el log. Eso es deliberado: preferimos un trabajo que corre con un
 aviso visible a uno que no corre porque alguien movio un disco.

 NOTA: fichero en ASCII puro (codigo Y comentarios).
============================================================================
#>

# Temporales PESADOS: .thd, DAMF, RF64 de deew, .ec3, el vid_ del solapamiento.
if ($env:MEDIABOX_BIGTMP) { $MediaBoxBigTmp = $env:MEDIABOX_BIGTMP }
else                      { $MediaBoxBigTmp = 'G:\MediaTmp' }

# Temporales de ESTADO: los ficheros que se leen entre procesos (status, pid,
# ffprog, locks, marcadores). Son diminutos y viven en C: a proposito, junto a
# las colas: el panel y los watchers los sondean constantemente.
if ($env:MEDIABOX_TMP) { $MediaBoxTmp = $env:MEDIABOX_TMP }
else                   { $MediaBoxTmp = 'C:\Media\tmp' }

# ---------------------------------------------------------------------------
# LAS HERRAMIENTAS. Una sola definicion, igual que las rutas de arriba.
# ---------------------------------------------------------------------------
# POR QUE (31/08/2026). Estas cinco rutas estaban escritas a mano en 41 sitios
# repartidos por 20 ficheros -todas con el mismo valor, de momento-. Es la misma
# trampa que ya salio con 'G:\MediaTmp' (nueve copias) y con las cuatro listas
# de patrones de temporales: mientras coinciden no molesta, y el dia que una
# diverge no da error, da SILENCIO.
#
# Se definen con los nombres que YA usaban los scripts ($FFMPEG, $FFPROBE, ...)
# para que quitar la copia local sea un borrado limpio y nada mas.
#
# OJO CON EL ORDEN: dot-sourcear esto SOBRESCRIBE lo que hubiera antes. Hoy da
# igual porque los 41 valores son identicos, pero si algun script necesita una
# version distinta de una herramienta, tiene que definirla DESPUES de cargar
# este fichero, no antes.
#
# NO SE HAN TOCADO LOS 15 FICHEROS RESTANTES a proposito: la mayoria no carga
# esta libreria, asi que borrarles la definicion los romperia. Quedan como
# estan hasta que se les anyada la carga.

# MKVToolNix. Por ruta absoluta y no por PATH: setx corta el PATH a 1024
# caracteres y este pipeline ya se quedo sin una herramienta por eso.
$MKVMERGE    = 'C:\Program Files\MKVToolNix\mkvmerge.exe'
$MKVEXTRACT  = 'C:\Program Files\MKVToolNix\mkvextract.exe'
$MKVPROPEDIT = 'C:\Program Files\MKVToolNix\mkvpropedit.exe'

# ffmpeg/ffprobe por ruta ABSOLUTA, con respaldo al nombre suelto por si algun
# dia cambia la ruta de WinGet. El respaldo NO es un adorno: cuando la llamada
# principal de encode usaba 'ffmpeg' a secas via Start-Process y el PATH no lo
# resolvia, $proc quedaba en $null y el script petaba en silencio -"Failed
# (exit )" y ni una pista-.
$FFMPEG  = 'C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe'
if (-not (Test-Path -LiteralPath $FFMPEG))  { $FFMPEG  = 'ffmpeg' }
$FFPROBE = 'C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffprobe.exe'
if (-not (Test-Path -LiteralPath $FFPROBE)) { $FFPROBE = 'ffprobe' }
