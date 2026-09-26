<#
============================================================================
 ab-test.ps1     Comparativa A/B de parametros del encoder (hevc_qsv)
============================================================================
 Mide si un cambio de parametro mejora la calidad-por-bit SIN esperar a un
 encode completo: codifica un clip corto con varias configuraciones y compara
 bitstream + tamano + SSIM.

 --- COMO FUNCIONA -------------------------------------------------------
 Hay un mapa de opciones por defecto ($default) que replica EXACTAMENTE la
 configuracion de produccion de encode.ps1. Cada config de una suite solo
 declara lo que CAMBIA respecto a ese default:

     @{ Name='refs6'; Set=@{ refs=6 } }

 Asi es imposible que una variante arrastre sin querer otro cambio, que es el
 error clasico de este tipo de pruebas.

 Para cada config se hace, en este orden:
   1. Encode del clip.
   2. MD5 de los PAQUETES de video (-c copy, sin decodificar: ~1 segundo).
      Si coincide con el del baseline, el parametro NO HIZO NADA y se salta
      el paso 3, que es el caro.
   3. Solo si el bitstream difiere: pasada de SSIM contra la fuente.
 En 4K una pasada de SSIM son varios minutos y un encode de 3 min son ~70
 segundos, asi que este atajo es la diferencia entre 5 minutos y media hora.

 --- SUITES --------------------------------------------------------------
   params       look_ahead_depth=100 / refs=6 / bf=4    (los "clasicos")
   lookahead    barrido look_ahead_depth 0/10/30 vs 60
   ratecontrol  extbrc=0 / mbbrc=0 / rdo=0
   adaptive     adaptive_i=0 / adaptive_b=0 / b_strategy=0
   pathway      scenario=unknown / low_power=0 / low_power=1
   preset       veryslow / veryfast contra el medium de produccion
   detail       barrido de detail 6 / 4 / 0 (lanzar con -Icq)
   speed        slower / medium / async_depth 8 y 16  (mira la columna Seg)
   remaining    min_qp / gpb / idr_interval / transform_skip / dual_gfx
   vpp          quita denoise, quita detail, quita el filtro entero
   gq           global_quality 14/16/17 vs el de produccion

 Un override puede introducir opciones que NO estan en $default (low_power es
 el caso): el merge las anade. Asi se pueden probar flags nuevos sin tocar el
 mapa de produccion.

 La suite 'gq' no sirve para decidir nada por si sola: sirve para CALIBRAR.
 Te dice cuanto tamano y cuanta calidad mueve UN punto de GQ, que es la vara
 de medir con la que juzgar si el resto de cambios valen algo.
 Ojo: con QVBR y -b:v/-maxrate puestos, si el clip esta topando el bitrate el
 GQ se notara poco. Si la suite 'gq' da diferencias minusculas, sube -Rate y
 -MaxR y repite, o el resultado no significa nada.

 --- COMO LEER LA TABLA --------------------------------------------------
   Igual=SI                      -> mismo MD5: el driver ignoro la opcion
   MB menor o igual + SSIM mejor -> victoria limpia, adoptalo
   MB mayor + SSIM mejor         -> ambiguo: compara contra la suite 'gq'
   MB mayor + SSIM igual o peor  -> peor, descartalo

 refs y bf son opciones GENERICAS de AVCodecContext, no privadas de hevc_qsv
 (no salen en 'ffmpeg -h encoder=hevc_qsv'). ffmpeg las acepta siempre, pero
 quien decide respetarlas es el driver, y si no las soporta las ignora EN
 SILENCIO. La columna 'Igual' es lo unico que lo delata con certeza.

 El SSIM sale bajo en absoluto porque compara la salida FILTRADA contra el
 original sin filtrar. Da igual: el filtro es el mismo en todas las configs,
 asi que la comparacion RELATIVA es valida. Se imprime a 6 decimales porque
 las diferencias reales viven en el 5o y el 6o.

 Cada encode deja un cmd_<config>.txt con la linea de ffmpeg exacta, para que
 cualquier resultado sea reproducible a mano.

 --- MODO ICQ (-Icq) ------------------------------------------------------
 IMPORTANTE. Por defecto el script replica produccion, que lleva -b:v 8M. Con
 el bitrate puesto, en contenido exigente el TECHO manda y el tamano se queda
 clavado pase lo que pase: medido el 29/07, cuatro valores de GQ movieron el
 tamano un 0.47 %, y quitar la cadena de filtros ENTERA lo movio un 0.12 %.
 Eso no significa que el GQ o los filtros no hagan nada: significa que la
 prueba no los deja expresarse.
 Con -Icq se quitan -b:v/-maxrate/-bufsize y el tamano queda libre. USALO
 siempre que lo que quieras medir sea cuanto bitrate PIDE o AHORRA algo:
 suites 'gq' y 'vpp' en particular.

 El mapa $default y el $Vf por defecto son un ESPEJO de encode.ps1. Si cambias
 produccion, cambia esto o las pruebas dejan de medir lo que crees.
 Estado a 29/07: 4K = denoise 16 / detail 20, GQ 15, -b:v 8M, maxrate 10.8M.

 Ejemplos:
   .\ab-test.ps1 -Suite vpp -Icq
   .\ab-test.ps1 -Suite gq -Icq
   .\ab-test.ps1 -Source "E:\Peliculas\peli.mkv" -Start "01:20:00"
   .\ab-test.ps1 -Source "E:\Peliculas\peli.mkv" -Suite ratecontrol
   .\ab-test.ps1 -Source "E:\Peliculas\peli.mkv" -Suite gq
   .\ab-test.ps1 -Source "E:\Peliculas\p1080.mkv" -Vf "vpp_qsv=denoise=20:detail=55:format=p010le" -Rate 5M -MaxR 6M -Gq 19
============================================================================
#>

param(
    [string]$Source = "",
    [string]$Start  = "00:35:00",
    [int]$Seconds   = 180,
    # Rama de produccion a replicar. Con esto se cargan de golpe GQ, filtros,
    # bitrate y maxrate correctos de esa rama; no hay que acordarse de pasar
    # cinco parametros a mano ni arriesgarse a medir una config que no existe.
    [ValidateSet('4K','1080p')][string]$Res = '4K',
    # Los cinco siguientes, vacios o 0, se derivan de -Res. Solo se ponen a mano
    # para probar algo distinto de produccion a proposito.
    [int]$Gq        = 0,
    [string]$Vf     = "",
    [string]$Rate   = "",
    [string]$MaxR   = "",
    [string]$BufS   = "",
    [string]$OutDir = "C:\Media\tmp\ab",
    [ValidateSet('params','lookahead','ratecontrol','adaptive','pathway','preset','speed','remaining','vpp','detail','gq','target')][string]$Suite = 'params',
    # Quita -b:v/-maxrate/-bufsize: el tamano queda libre y se puede medir
    # cuanto bitrate pide o ahorra cada cosa. Ver la nota de la cabecera.
    [switch]$Icq,
    # Salta las pasadas de SSIM. Para la suite 'speed', donde lo que interesa es
    # el tiempo y la igualdad de bitstream (MD5), no la calidad. En clips largos
    # el SSIM se come mas de una hora y no aporta nada aqui.
    [switch]$NoSsim
)

# --- Perfiles de produccion (ESPEJO de encode.ps1, 04/08/2026) ------------
# Esto se ha desincronizado TRES veces durante la sesion, y cada vez medimos una
# configuracion que ya no existia. Si tocas encode.ps1, toca esto.
# Resincronizado el 04/08/2026, y estaba desfasado por DOS sitios:
#   - detail: produccion lo subio de 0 a 4 el 02/08 y aqui seguia en 0.
#   - target 4K: subido de 9.0M a 10.5M (maxrate x1.35 = 14.2M, bufsize x1.5 = 21M)
#     al ver en completed.jsonl que el 73 % de los encodes salian cap_bound.
#   (27/08/2026: este resumen se habia quedado viejo OTRA VEZ mientras el codigo
#    de abajo si estaba al dia. Un comentario desfasado en el fichero cuyo unico
#    trabajo es ser un espejo fiel es peor que no tenerlo: se lee y se cree.
#    Lo que vale son las dos lineas de $dDn/$dGq/$dRate, no esto.)
# COMPROBADO CONTRA encode.ps1 EL 04/09/2026, linea a linea:
#   4K    : GQ 15 | denoise 7 detail 6 | target 9.0M | maxrate x1.35 | bufsize x1.5
#   1080p : GQ 15 | denoise 7 detail 6 | target 5.0M | maxrate x1.30 | bufsize x1.5
# (Los valores de 1080p son los de Movie SDR, que es el caso mayoritario; los
#  de 4K, los de Movie HDR. Son dos convenios distintos y estan los dos aqui
#  escritos para no tener que adivinarlo.)
# El denoise y el detail NO dependen de la resolucion en encode.ps1: hay una
# sola pareja ($Denoise = 7 / $Detail = 6, lineas ~1898). Los comentarios de
# este fichero decian '4K: denoise 10' desde el 07/08 y ya no era cierto.
#
# QUINTA DESINCRONIZACION, corregida el 02/09/2026: el $dRate de 1080p se quedo
# en 7.5M cuando produccion bajo a 5,5/5,0 el 27/08. Se pone 5.0M porque la
# linea de arriba ya dice cual es el convenio de esta rama -"los valores de
# 1080p son los de Movie SDR"-, y el SDR es 5,0. La rama de 4K sigue copiando el
# HDR (9,5), que es lo que ha copiado siempre; son convenios distintos y estan
# los dos escritos aqui para que no haya que adivinarlo otra vez.
function BuildVf([int]$dn, [int]$dt) {
    $p = @()
    if ($dn -gt 0) { $p += "denoise=$dn" }
    if ($dt -gt 0) { $p += "detail=$dt" }
    $p += 'format=p010le'
    return ('vpp_qsv=' + ($p -join ':'))
}
# LAS DOS LINEAS DE ABAJO SON EL ESPEJO. Todo lo demas de este fichero es
# prosa; si discrepan, manda el codigo. Se ha desincronizado CINCO veces, asi
# que aqui no se escribe un resumen que pueda envejecer: los numeros vigentes
# estan en la cabecera con su fecha de comprobacion, y salen de encode.ps1
#   target  -> la tabla de $Target (~1547)
#   GQ      -> la tabla de $BaseGq (~1818)
#   filtros -> $Denoise / $Detail  (~1898)
#   maxrate -> target x1.35 en 4K, x1.30 en 1080p;  bufsize -> maxrate x1.5
if ($Res -eq '1080p') { $dDn = 7;  $dDt = 6; $dGq = 15; $dRate = '5.0M';  $dMaxR = '6.5M';  $dBufS = '10M' }   # 02/09/2026: 7.5 -> 5.0, siguiendo a encode.ps1 (bajo el 27/08 y el espejo se quedo atras)
else                  { $dDn = 7;  $dDt = 6; $dGq = 15; $dRate = '9.0M';  $dMaxR = '12.2M'; $dBufS = '18M' }   # 4K: 9.5 -> 9.0 el 21/09/2026, siguiendo a encode.ps1 (maxrate x1.35 = 12.15 -> 12.2 redondeado como hace encode.ps1, bufsize x1.5)
$dPreset = 'medium'   # produccion desde el 30/07 en las dos ramas
if ($Gq -le 0)  { $Gq   = $dGq }
if (-not $Vf)   { $Vf   = BuildVf $dDn $dDt }
if (-not $Rate) { $Rate = $dRate }
if (-not $MaxR) { $MaxR = $dMaxR }
if (-not $BufS) { $BufS = $dBufS }

$ErrorActionPreference = "Continue"
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

# Las rutas de herramientas salen de mediabox-paths.ps1, la unica definicion
# del pipeline (31/08/2026). Se carga explicitamente porque este script no
# usa ninguna de las dos librerias que ya la traen.
$PathsLib = 'C:\scripts\mediabox-paths.ps1'
if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
else { Write-Host 'ERROR: falta mediabox-paths.ps1'; exit 1 }

# $FFMPEG, $FFPROBE los da mediabox-paths.ps1 (31/08/2026: estaban copiados aqui).
# El respaldo al nombre suelto lo aplica ya mediabox-paths.ps1 (31/08/2026).

function Get-StreamHash([string]$file) {
    # MD5 de los PAQUETES de video (-c copy: no decodifica). Tarda un segundo.
    # No se hashea el fichero entero porque el muxer de Matroska escribe UIDs y
    # marcas que pueden variar entre ejecuciones aunque el video sea identico.
    $o = & $FFMPEG -v error -i $file -map 0:v:0 -c copy -f md5 - 2>&1
    if ("$o" -match 'MD5=([0-9a-fA-F]+)') { return $Matches[1] }
    return $null
}

# Si no se pasa -Source, se busca solo (igual que icq-probe.ps1): primero en
# C:\Media (NVMe) y luego en E:\Peliculas. Asi no hay que teclear la enye.
if (-not $Source) {
    $hit = Get-ChildItem "C:\Media" -File -Filter *.mkv -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'retorno.*rey' } | Select-Object -First 1
    if (-not $hit) {
        $hit = Get-ChildItem "E:\Peliculas" -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'retorno.*rey' } | Select-Object -First 1
    }
    if ($hit) { $Source = $hit.FullName }
}
if (-not $Source -or -not (Test-Path -LiteralPath $Source)) {
    Write-Host "No encuentro la fuente. Pasala con -Source." -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Push-Location $OutDir   # rutas RELATIVAS: evita tener que escapar 'C:\' dentro de -lavfi

# --- Configuracion de PRODUCCION (espejo de encode.ps1) -------------------
# Si cambias encode.ps1, cambia esto o las pruebas dejaran de ser validas.
$default = [ordered]@{
    'preset'           = $dPreset
    'global_quality'   = "$Gq"
    'b:v'              = $Rate
    'maxrate'          = $MaxR
    'bufsize'          = $BufS
    'extbrc'           = '1'
    'look_ahead_depth' = '60'
    'adaptive_i'       = '1'
    'adaptive_b'       = '1'
    'b_strategy'       = '1'
    'mbbrc'            = '1'
    'rdo'              = '1'
    'scenario'         = 'archive'
    'bf'               = '3'
    'refs'             = '4'
    'profile:v'        = 'main10'
    'g'                = '240'
}

# En modo ICQ se quitan las tres opciones de bitrate para que el tamano pueda
# moverse. Sin esto, cualquier medida de "cuanto bitrate pide X" sale plana.
if ($Icq) {
    foreach ($k in @('b:v','maxrate','bufsize')) {
        if ($default.Contains($k)) { $default.Remove($k) }
    }
}

# --- Suites: cada config declara SOLO lo que cambia -----------------------
$suites = @{
    params = @(
        @{ Name='base';   Set=@{} },
        @{ Name='lad100'; Set=@{ look_ahead_depth=100 } },
        @{ Name='refs6';  Set=@{ refs=6 } },
        @{ Name='bf4';    Set=@{ bf=4 } }
    )
    lookahead = @(
        @{ Name='base';  Set=@{} },
        @{ Name='lad0';  Set=@{ look_ahead_depth=0 } },
        @{ Name='lad10'; Set=@{ look_ahead_depth=10 } },
        @{ Name='lad30'; Set=@{ look_ahead_depth=30 } }
    )
    ratecontrol = @(
        @{ Name='base';    Set=@{} },
        @{ Name='extbrc0'; Set=@{ extbrc=0 } },
        @{ Name='mbbrc0';  Set=@{ mbbrc=0 } },
        @{ Name='rdo0';    Set=@{ rdo=0 } }
    )
    adaptive = @(
        @{ Name='base';    Set=@{} },
        @{ Name='adapti0'; Set=@{ adaptive_i=0 } },
        @{ Name='adaptb0'; Set=@{ adaptive_b=0 } },
        @{ Name='bstrat0'; Set=@{ b_strategy=0 } }
    )
    pathway = @(
        # low_power no esta en $default (su valor por defecto en ffmpeg es -1 =
        # auto). Si la Arc solo soporta una de las dos rutas para HEVC, la otra
        # fallara al inicializar y saldra como FALLO en la tabla: eso TAMBIEN es
        # informacion, y explicaria por que extbrc/rdo/lookahead son inertes.
        @{ Name='base';    Set=@{} },
        @{ Name='scenaru'; Set=@{ scenario='unknown' } },
        @{ Name='lp0';     Set=@{ low_power=0 } },
        @{ Name='lp1';     Set=@{ low_power=1 } }
    )
    preset = @(
        # El ultimo mando gordo sin medir. Si las cuatro salen identicas, TODO el
        # ajuste fino del encoder es decorativo y solo mandan GQ, bitrate y los
        # filtros. Si difieren, -preset es la segunda palanca real tras el GQ.
        # Aqui la columna Seg si importa: un preset que baje calidad pero no la
        # velocidad no tiene ningun sentido.
        # PUESTA AL DIA EL 04/09/2026. Cuando se escribio, el baseline era
        # veryslow; hoy es medium, asi que 'medium' era una copia del base y
        # 'slow' vive en el MISMO grupo que medium (bitstream identico): dos
        # de las cuatro filas no median nada. El driver colapsa los presets en
        # tres grupos -{veryslow,slower}, {slow,medium}, {veryfast}-, asi que
        # con base + veryslow + veryfast estan los tres y ni uno repetido.
        @{ Name='base';     Set=@{} },
        @{ Name='veryslow'; Set=@{ preset='veryslow' } },
        @{ Name='veryfast'; Set=@{ preset='veryfast' } }
    )
    speed = @(
        # Aqui lo que importa es la columna Seg, no el SSIM. Lanzala con
        # -NoSsim -Seconds 600: en clips de 3 min el ruido de medida es de +-15 %
        # (lo vimos: salidas IDENTICAS entre 64 y 80 s), asi que una mejora del
        # 10 % no se distinguiria del ruido.
        # -async_depth no cambia las decisiones de codificacion, solo cuantos
        # frames van en vuelo: deberia dar 'Igual=SI' con menos tiempo. Si es
        # asi, es velocidad gratis.
        # Datos ya conocidos (clip de 3 min, con techo): veryslow 64 fps,
        # slow=medium 90 fps (-0.0000331 SSIM), veryfast 98 fps (-0.0000853).
        # 'slower' y 'faster' no estaban mapeados: podrian ser escalones propios.
        @{ Name='base';    Set=@{} },
        @{ Name='slower';  Set=@{ preset='slower' } },
        @{ Name='medium';  Set=@{ preset='medium' } },
        @{ Name='async8';  Set=@{ async_depth=8 } },
        @{ Name='async16'; Set=@{ async_depth=16 } }
    )
    remaining = @(
        # Lo que queda sin medir del encoder. Prediccion del modelo que salio de
        # las tandas anteriores (lo que mapea a mfxInfoMFX funciona; lo que vive
        # en los buffers CO2/CO3 es inerte): idr_interval deberia FUNCIONAR, y
        # gpb, transform_skip y min_qp deberian salir INERTES. Si acierta, el
        # modelo sirve para predecir sin gastar 70 s por opcion.
        # 'minqp' toca tres opciones a la vez a proposito: son una sola funcion
        # (suelo de QP), no tiene sentido medirlas por separado.
        @{ Name='base';    Set=@{} },
        @{ Name='minqp';   Set=@{ min_qp_i=18; min_qp_p=20; min_qp_b=22 } },
        @{ Name='gpb0';    Set=@{ gpb=0 } },
        @{ Name='idr2';    Set=@{ idr_interval=2 } },
        @{ Name='tskip';   Set=@{ transform_skip=1 } },
        @{ Name='dualgfx'; Set=@{ dual_gfx=2 } }
    )
    vpp = @(
        # __vf es una clave ESPECIAL: sustituye la cadena de filtros entera en vez
        # de anyadir una opcion al encoder.
        # Esto es un BARRIDO DE DENOISE; el de detail vive en la suite 'detail'.
        # (Aqui ponia 'desde el 30/07 produccion lleva detail=0'. Era verdad ese
        #  dia y dejo de serlo el 07/08, cuando detail subio a 6. Corregido el
        #  04/09/2026: el fichero cuyo trabajo es ser un espejo fiel no puede
        #  llevar en la prosa una config que ya no existe.)
        # LANZALA CON -Icq: con el bitrate fijado el tamano no se puede mover y la
        # medida sale plana (paso el 29/07: quitar la cadena entera movio el
        # tamano un 0.12 %).
        # OJO al leer el SSIM: se compara contra el original SIN filtrar, asi que
        # menos denoise SUBE el SSIM por construccion y eso no significa "mejor".
        # Lo informativo es el TAMANO.
        @{ Name='base';  Set=@{} },
        @{ Name='dn0';   Set=@{ __vf=(BuildVf 0  $dDt) } },
        @{ Name='dn5';   Set=@{ __vf=(BuildVf 5  $dDt) } },
        @{ Name='dn20';  Set=@{ __vf=(BuildVf 20 $dDt) } }
    )
    detail = @(
        # BARRIDO DE DETAIL (04/09/2026). Produccion lleva detail=6 en las dos
        # ramas desde el 07/08/2026; aqui se mide contra 4 y contra 0.
        #
        # LANZALA CON -Icq. Con el bitrate fijado el tamano no se puede mover y
        # la medida sale plana (paso el 29/07: quitar la cadena de filtros
        # entera movio el tamano un 0.12 %). Lo que se quiere saber es cuanto
        # bitrate PIDE cada nivel, y eso solo se ve sin ataduras.
        #
        # EL SSIM NO DECIDE AQUI, y no es un matiz: se compara contra el
        # original SIN filtrar, asi que MENOS filtro sube el SSIM por
        # construccion. detail=0 ganaria siempre y no significaria nada. Lo
        # informativo es el TAMANO y el tiempo; la calidad la deciden los
        # fotogramas en el QN93A.
        #
        # Y ojo: el detail es IRREVERSIBLE en un archivo -inventa alta
        # frecuencia que el denoise acaba de quitar-. Si aparece banding en
        # cielos o zonas oscuras, este es el primer mando que hay que bajar.
        @{ Name='base';  Set=@{} },
        @{ Name='dt4';   Set=@{ __vf=(BuildVf $dDn 4) } },
        @{ Name='dt0';   Set=@{ __vf=(BuildVf $dDn 0) } }
    )
    target = @(
        # Recorte de tamano (21/08/2026). Matriz 3x3: tres targets x tres niveles
        # de detail, en una sola tirada y con un unico baseline.
        # El bitrate va FIJADO A PROPOSITO. La regla de "si mides bitrate no lo
        # fijes" NO aplica aqui: no se mide cuanto bitrate PIDE nada -para eso
        # esta -Icq-, sino CUANTA CALIDAD SE PIERDE A UN TAMANO DADO, que es el
        # uso correcto del bitrate fijo. NO lanzar esta suite con -Icq.
        # maxrate = target x 1.35 y bufsize = maxrate x 1.5, igual que encode.ps1.
        # LISTON, puesto ANTES de medir: se adopta el recorte si alguna variante
        # con target menor iguala o supera el SSIM del baseline. Recuerda que el
        # SSIM NO MIDE BANDING: si gana, el veredicto final sigue siendo el QN93A.
        @{ Name='base';   Set=@{} },
        @{ Name='t105d2'; Set=@{ __vf=(BuildVf $dDn 2) } },
        @{ Name='t105d0'; Set=@{ __vf=(BuildVf $dDn 0) } },
        @{ Name='t95d6';  Set=@{ 'b:v'='9.5M'; maxrate='12.8M'; bufsize='19M' } },
        @{ Name='t95d2';  Set=@{ 'b:v'='9.5M'; maxrate='12.8M'; bufsize='19M'; __vf=(BuildVf $dDn 2) } },
        @{ Name='t95d0';  Set=@{ 'b:v'='9.5M'; maxrate='12.8M'; bufsize='19M'; __vf=(BuildVf $dDn 0) } },
        @{ Name='t90d6';  Set=@{ 'b:v'='9.0M'; maxrate='12.2M'; bufsize='18M' } },
        @{ Name='t90d2';  Set=@{ 'b:v'='9.0M'; maxrate='12.2M'; bufsize='18M'; __vf=(BuildVf $dDn 2) } },
        @{ Name='t90d0';  Set=@{ 'b:v'='9.0M'; maxrate='12.2M'; bufsize='18M'; __vf=(BuildVf $dDn 0) } }
    )
    gq = @(
        @{ Name='base'; Set=@{} },
        @{ Name='gq14'; Set=@{ global_quality=14 } },
        @{ Name='gq16'; Set=@{ global_quality=16 } },
        @{ Name='gq17'; Set=@{ global_quality=17 } },
        @{ Name='gq18'; Set=@{ global_quality=18 } }
    )
}
$configs = $suites[$Suite]

$ssimVals = @{}   # SSIM por frame de cada config
$baseHash = $null # MD5 del bitstream del baseline

Write-Host "Fuente : $Source"
Write-Host "Rama   : $Res  (GQ $Gq | $Vf)"
Write-Host "Suite  : $Suite"
if ($Icq)    { Write-Host "Modo   : ICQ (sin -b:v/-maxrate: el tamano queda libre)" -ForegroundColor Cyan }
else         { Write-Host "Modo   : QVBR como produccion (-b:v $Rate -maxrate $MaxR)" }
if ($NoSsim) { Write-Host "SSIM   : OMITIDO (-NoSsim): solo tamano, MD5 y tiempo" -ForegroundColor Cyan }
Write-Host "Clip   : $Start + ${Seconds}s | GQ=$Gq"
Write-Host "Salida : $OutDir"
Write-Host ""

# --- Calentamiento (se descarta) ------------------------------------------
# La GPU arranca en frecuencias bajas y la primera pasada sale sistematicamente
# lenta. El 30/07 esto invalido media suite 'speed': TRES configuraciones que
# producian el bitstream IDENTICO salieron en 237, 218 y 212 s, unicamente por
# el orden de ejecucion, y por poco doy por buena una mejora de -async_depth que
# no existia. Un encode corto previo, tirado a la basura, deja la GPU caliente
# para que la primera fila medida no arrastre ese lastre.
# No arregla el sesgo por completo: para diferencias pequenyas hacen falta
# repeticiones. Pero elimina el error mas gordo y mas facil de creerse.
Write-Host "  calentando la GPU (30 s, se descarta)..."
$warmArgs = @('-y','-hwaccel','qsv','-hwaccel_output_format','qsv',
              '-ss',$Start,'-t','30','-i',$Source,
              '-map','0:v:0','-an','-sn','-vf',$Vf,
              '-c:v','hevc_qsv','-preset',$dPreset,'-global_quality',"$Gq",
              '-profile:v','main10','-g','240','-f','null','NUL')
& $FFMPEG @warmArgs 2>&1 | Out-Null
Write-Host ""

$rows = foreach ($c in $configs) {
    # Merge: copia de los defaults + overrides de esta config. En ese orden, para
    # que sea imposible que una variante arrastre un cambio que no ha declarado.
    $opts = [ordered]@{}
    foreach ($k in $default.Keys)  { $opts[$k] = $default[$k] }
    foreach ($k in $c.Set.Keys)    { $opts[$k] = "$($c.Set[$k])" }

    # '__vf' no es una opcion del encoder sino la cadena de filtros, que va ANTES
    # de -c:v. Se saca del mapa antes de construir los argumentos.
    $thisVf = $Vf
    if ($opts.Contains('__vf')) { $thisVf = $opts['__vf']; $opts.Remove('__vf') }

    $optArgs = @()
    foreach ($k in $opts.Keys) { $optArgs += @("-$k", "$($opts[$k])") }

    $desc = if ($c.Set.Count -eq 0) { 'produccion' }
            else { (($c.Set.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') }
    Write-Host ("  codificando {0} ({1})..." -f $c.Name,$desc)

    $out = "$($c.Name).mkv"
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue

    $enc = @(
        '-y','-hwaccel','qsv','-hwaccel_output_format','qsv',
        '-ss',$Start,'-t',"$Seconds",'-i',$Source,
        '-map','0:v:0','-an','-sn','-vf',$thisVf,
        '-c:v','hevc_qsv'
    ) + $optArgs + @($out)

    # Linea exacta al disco: cualquier resultado tiene que poder reproducirse.
    # UTF-8 SIN BOM y por ruta absoluta. Con 'Set-Content -Encoding ASCII' los
    # acentos de la ruta salian como '?' y el fichero dejaba de servir para lo
    # unico que existe. WriteAllText no sigue el Push-Location de PowerShell, de
    # ahi el Join-Path con (Get-Location).Path.
    [System.IO.File]::WriteAllText(
        (Join-Path (Get-Location).Path "cmd_$($c.Name).txt"),
        ('"' + $FFMPEG + '" ' + ($enc -join ' ')),
        (New-Object System.Text.UTF8Encoding($false)))

    # Measure-Command corre el bloque en un ambito hijo, asi que una asignacion
    # dentro no sobrevive. Se mide con Get-Date para poder quedarse con la salida.
    $t0 = Get-Date
    $encOut = & $FFMPEG @enc 2>&1
    $t = (Get-Date) - $t0

    # Un fichero de 0 BYTES es un FALLO. Antes solo se miraba Test-Path, y cuando
    # el encoder no abre ffmpeg deja el .mkv creado y vacio: el 29/07 'dual_gfx'
    # aparecio como fila valida de 0.00 MB en vez de como error.
    $failed = (-not (Test-Path -LiteralPath $out)) -or ((Get-Item -LiteralPath $out).Length -eq 0)
    if ($failed) {
        $why = $encOut | Select-String -Pattern 'not supported|Invalid|Error while opening|Conversion failed|No such' |
               Select-Object -First 1
        if ($why) {
            $w = $why.ToString()
            if ($w.Length -gt 76) { $w = $w.Substring(0,76) }
            Write-Host "    FALLO: $w" -ForegroundColor Red
        }
        [System.IO.File]::WriteAllText((Join-Path (Get-Location).Path "err_$($c.Name).txt"),
            ($encOut | Out-String), (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
        [pscustomobject]@{ Config=$c.Name; MB='FALLO'; SSIM='-'; Igual='-'; BFrames='-'; Seg=[int]$t.TotalSeconds }
        continue
    }

    # Paso 2: MD5 del bitstream. Si es el del baseline, nos saltamos el SSIM.
    $hash = Get-StreamHash $out
    if ($c.Name -eq 'base') { $baseHash = $hash }
    $igual = ($c.Name -ne 'base' -and $hash -and $baseHash -and $hash -eq $baseHash)

    $ssim = 'n/a'
    if ($NoSsim) {
        $ssim = 'omitido'
    } elseif ($igual) {
        $ssim = '= base'
        Write-Host "    bitstream identico al baseline: me salto el SSIM."
    } else {
        # Paso 3: SSIM contra el mismo tramo de la fuente.
        $stats = "$($c.Name)_ssim.txt"
        Remove-Item -LiteralPath $stats -ErrorAction SilentlyContinue
        & $FFMPEG -v error -ss $Start -t "$Seconds" -i $Source -i $out `
            -lavfi "[0:v]setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];[a][b]ssim=stats_file=$stats" `
            -f null NUL 2>&1 | Out-Null
        if (Test-Path -LiteralPath $stats) {
            $vals = @(Select-String -Path $stats -Pattern 'All:([0-9.]+)' |
                      ForEach-Object { [double]$_.Matches[0].Groups[1].Value })
            if ($vals.Count -gt 0) {
                $ssimVals[$c.Name] = $vals
                $ssim = '{0:F6}' -f ($vals | Measure-Object -Average).Average
            }
        }
    }

    # Contraste extra para 'bf': si el driver lo aplico, has_b_frames cambia.
    $bfr = & $FFPROBE -v error -select_streams v:0 -show_entries stream=has_b_frames -of csv=p=0 $out 2>$null

    [pscustomobject]@{
        Config  = $c.Name
        MB      = [math]::Round((Get-Item -LiteralPath $out).Length/1MB, 2)
        SSIM    = $ssim
        Igual   = if ($c.Name -eq 'base') { '-' } elseif ($igual) { 'SI' } else { 'NO' }
        BFrames = "$bfr".Trim()
        Seg     = [int]$t.TotalSeconds
    }
}

Pop-Location

Write-Host ""
$rows | Format-Table -AutoSize

# --- Veredicto ------------------------------------------------------------
# 'Igual=SI' sale del MD5 del bitstream: es exacto, no una aproximacion por
# tamano ni por metrica.
$baseRow  = $rows | Where-Object { $_.Config -eq 'base' }
$baseVals = $ssimVals['base']
Write-Host ""
foreach ($r in ($rows | Where-Object { $_.Config -ne 'base' })) {
    if ($r.Igual -eq 'SI') {
        Write-Host ("  {0}: bitstream IDENTICO al baseline (mismo MD5) -> el driver ignoro la opcion." -f $r.Config) -ForegroundColor Yellow
    }
    elseif ($baseVals -and $ssimVals[$r.Config]) {
        $dS = ((($ssimVals[$r.Config]) | Measure-Object -Average).Average - ($baseVals | Measure-Object -Average).Average) * 1000
        $dM = if ($baseRow -and $baseRow.MB -is [double] -and $r.MB -is [double] -and $baseRow.MB -gt 0) {
                  (($r.MB - $baseRow.MB) / $baseRow.MB) * 100
              } else { 0 }
        Write-Host ("  {0}: distinto. Tamano {1:+0.00;-0.00;0.00} % | Delta SSIM {2:+0.0000;-0.0000;0.0000} (x1000)" -f $r.Config,$dM,$dS)
    }
}

Write-Host ""
Write-Host "Los .mkv, los cmd_*.txt y los *_ssim.txt se quedan en $OutDir."
Write-Host "El script NO borra nada: limpialos tu cuando acabes."
