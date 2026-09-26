<#
============================================================================
 descargas-tanda.ps1  -  Bajar, extraer, codificar, catalogar y limpiar
                         POR TANDAS, sin llenar la unidad C:
============================================================================
 EL PROBLEMA QUE RESUELVE (07/09/2026)
 -------------------------------------
 JDownloader vacia su cola contra C: tan rapido como pueda, y el pipeline de
 video NO borra el fuente al terminar: se queda en encode_running a proposito
 para poder comparar con la salida. Las dos cosas juntas llenan C:, y llenarla
 a mitad de un encode ya paso el 31/07/2026 (CHANGELOG.md).

 La cuenta con un remux 4K, que es lo que cae aqui, sale asi POR EPISODIO:
   los .rar bajados      ~17 GB
   + el .mkv extraido    ~17 GB   (conviven: JD extrae ANTES de borrar)
   + el fuente en running ~17 GB
   + la salida codificada  ~8 GB
 Casi 60 GB por episodio, con TRES copias del mismo material vivas a la vez.
 Con tandas de 4 el pico ronda los 170 GB, que es lo que hay que vigilar.

 LA UNIDAD DE TANDA ES EL EPISODIO, NO EL PAQUETE
 ------------------------------------------------
 Un paquete de JD aqui es una TEMPORADA ENTERA: la S2 son 107 ficheros y
 255 GB, mas otro tanto al extraer. Eso no cabe en C: de ninguna manera.

 Lo que lo hace posible: dentro del paquete los .rar vienen en juegos
 INDEPENDIENTES por episodio (JuegazosS1E07.part01..11.rar, luego S1E08...),
 y cada juego se extrae por su cuenta. Get-GruposEpisodio los agrupa por
 nombre base y solo se mueven a la lista de descargas los enlaces de N
 episodios (moveToDownloadlist acepta linkIds, no solo packageIds).

 EL CICLO COMPLETO
 -----------------
   1. si YA hay trabajo en marcha -cola del encoder, encode_running, videos
      extraidos en Descargas o una descarga viva en JD-, ESO es la tanda y no
      se baja nada (Get-TandaAdoptada). Si no hay nada, coge N EPISODIOS
      completos del linkgrabber y arranca solo esos            (jd-lib.ps1)
   2. espera a que bajen Y a que la extraccion termine
   3. VACIA LA PAPELERA: JD manda ahi los .rar al extraer, asi que hasta este
      momento esos ~100 GB no han liberado ni un byte
   4. mueve los videos a C:\Media\encode_queue  -> los coge encode-watch.ps1
   5. espera al pipeline                (encode_logs\completed.jsonl)
   6. VERIFICA cada salida: existe, pesa, tiene pistas y su duracion casa
   7. la lleva al AREA DE PREPARACION, que es el data source de series de
      tinyMediaManager, con el nombre normalizado 'Serie - S01E03.mkv'
   8. borra el fuente de encode_running y los .rar DE ESTA TANDA (fichero a
      fichero: los de los episodios siguientes viven en la misma carpeta)
   9. CIERRA, y lo hace EN CADA TANDA y no al completar la temporada: tmm
      raspa los metadatos, la temporada preparada se copia a E: verificando
      fichero a fichero -con los metadatos de nivel serie de la raiz-, y solo
      entonces se borra de C:
  10. vuelta a empezar mientras quede sitio y haya episodios

 POR QUE EL AREA DE PREPARACION ESTA EN C:\Users\HTPC\Videos
 -----------------------------------------------------------
 Porque es el data source de series que tinyMediaManager YA tiene configurado
 (indice 1 de la lista, comprobado: 'tvshow.datasource.path=C:\Users\HTPC\
 Videos' en tmm.prop). tmm solo raspa lo que esta dentro de un data source
 suyo, asi que preparar la temporada ahi es lo que permite que el metadato se
 descargue ANTES de copiar a E:, que es como se pidio: a E: llega la carpeta
 ya completa, con sus .nfo y sus imagenes, de una vez.

 QUE SE VERIFICO EN ESTA MAQUINA ANTES DE ESCRIBIR ESTO
 ------------------------------------------------------
   - La API local de JD escucha en 127.0.0.1:3128 ('deprecatedapiport') y
     solo con 'deprecatedapienabled' en true. El 9666 es OTRO servidor -el
     External Interface de FlashGot-, que responde 501 a todo salvo /flash/.
   - tinyMediaManager es la 5.3.2 y su CLI FUNCIONA en esta instalacion: se
     lanzo 'tvshow --updateX=1' y escaneo el data source sin pedir licencia.
   - Los indices de --updateX son 1-BASED. Con 0 revienta con un
     IndexOutOfBounds -1, que es un mensaje que no se parece en nada a la
     causa. Aqui se pasa 1 y hay un solo data source de series.
   - La biblioteca usa 'Season 1', 'Season 2'... No hay ni una 'Season01'.

 LO QUE NO HACE, Y ES DELIBERADO
 -------------------------------
 - NO coge el pipeline.lock: no codifica nada, solo mueve y espera. Cogerlo
   pararia los tres pipelines durante horas.
 - NO borra NADA que no haya pasado antes por la verificacion, y en el paso
   a E: la copia se comprueba fichero a fichero antes de tocar el original.
 - NO sobrescribe nada que ya exista en la biblioteca.
 - NO mata procesos ni fuerza la salida de nada.

 SERIES Y PELICULAS: EL USO GENERAL
 ----------------------------------
 El titulo y el destino NO estan cableados. Por defecto:

   - El TITULO sale del NOMBRE DEL PAQUETE de JDownloader. O sea que la forma
     comoda de usar esto es renombrar el pack en JD a 'Interstellar (2014)' o
     'Expediente X (1993)' y lanzar el script sin mas.
   - El TIPO se detecta solo: si los videos extraidos traen SxxExx (o 1x02) es
     una serie, y si no, una pelicula. Se fuerza con -Tipo serie|pelicula.
   - El DESTINO va detras del tipo:
       serie    -> E:\Series\<titulo>\Season N\<titulo> - S01E03.mkv
       pelicula -> E:\Peliculas\<titulo>\<titulo>.mkv
   - Una tanda puede llevar VARIAS peliculas: el titulo es por fichero, cada
     una va a su carpeta.

 AREAS DE PREPARACION Y tinyMediaManager
 ---------------------------------------
 tmm SOLO raspa lo que esta dentro de un data source suyo, asi que cada area
 de preparacion tiene que ser (o estar dentro de) uno del tipo que toca:

     series    -> C:\Users\HTPC\Videos            (-PrepSeries)
     peliculas -> C:\Users\HTPC\Videos_Peliculas  (-PrepPeliculas)

 El indice de --updateX NO se escribe a mano: Get-TmmIndiceDataSource lo saca
 de tmm.prop buscando la posicion del area en la lista de data sources de su
 tipo. Si el area no es data source, Invoke-Tmm lo dice y no raspa a ciegas.

   Ejemplos:

     # Una pelicula, con el pack de JD ya renombrado a 'Interstellar (2014)'
     pwsh -File C:\scripts\descargas-tanda.ps1 -Filtro Interstellar -N 1

     # Varias peliculas de golpe, cada una a su carpeta
     pwsh -File C:\scripts\descargas-tanda.ps1 -Tipo pelicula -N 3

     # Una serie cuyo pack se llama algo ilegible: se le da el titulo a mano
     pwsh -File C:\scripts\descargas-tanda.ps1 -Filtro Juegazos -N 4 -Nombre 'Juego de Tronos (2011)'

     # Ensayo: dice lo que haria y no toca nada
     pwsh -File C:\scripts\descargas-tanda.ps1 -Filtro Juegazos -N 4 -Simular

     # Recoger lo que ya estuviera a medias en el pipeline, sin bajar nada
     pwsh -File C:\scripts\descargas-tanda.ps1 -Adoptar -UnaTanda

   Parada limpia (termina la tanda en curso y sale):
     New-Item C:\Media\tmp\tandas_stop -ItemType File

 NOTA: fichero en ASCII puro (codigo Y comentarios).
============================================================================
#>

[CmdletBinding()]
param(
    # EPISODIOS por tanda. La unidad NO es el paquete de JD: un paquete de
    # estos es una temporada entera (255 GB) y dentro los .rar vienen
    # agrupados por episodio. Ver Get-GruposEpisodio.
    [int]$N = 4,

    # Tope de tamanyo de la tanda. Un episodio que YA pase de esto entra igual
    # -si no, no entraria nunca-, pero no se le suma ningun otro.
    # 4 x 25,5 GB = 102, asi que 120 deja margen para el episodio gordo de la
    # S8 (33,5 GB) sin colar un quinto por error.
    [double]$MaxGbTanda = 120,

    # Freno de espacio: por debajo de esto en C: no se empieza otra tanda.
    [double]$MinLibreGb = 120,

    # Por debajo de esto se CIERRAN las temporadas que haya preparadas aunque
    # esten incompletas: se raspan y se van a E: antes de tiempo para hacer
    # sitio. Es el "si se queda con muy poco espacio, empieza antes".
    [double]$LibreParaCerrarGb = 180,

    # Cuantas veces el tamanyo de la tanda hay que tener libre ADEMAS del
    # freno. 2.1 cubre el caso peor real: .rar + extraido conviviendo.
    [double]$FactorEspacio = 2.1,

    # Regex sobre el nombre del paquete de JD. Para esta serie: 'Juegazos'.
    [string]$Filtro = '',

    # Regex sobre el nombre del FICHERO de video, y solo se usa al ADOPTAR.
    # Hace falta porque los dos nombres no se parecen en nada: el paquete es
    # 'JuegazosS1E06RemuxHeyshir' y el video que sale de el es
    # 'Game.Of.Thrones.S01E06.2160p...'. Sin este filtro, la adopcion cogeria
    # cualquier pelicula que hubiera en la cola del encoder y acabaria
    # metiendola en 'Juego de Tronos (2011)\Season 1'. Un fichero mal colocado
    # en una biblioteca de 10 TB no se encuentra nunca.
    [string]$FiltroVideo = '(?i)(game.?of.?thrones|juego.?de.?tronos)',

    # ---- QUE ES Y DONDE VA -----------------------------------------------
    # 'auto' lo decide por el nombre de los ficheros extraidos: si traen
    # SxxExx (o 1x02) es SERIE; si no, PELICULA. Se puede forzar cuando un
    # pack raro despiste al detector.
    [ValidateSet('auto','serie','pelicula')]
    [string]$Tipo = 'auto',

    # Nombre tal cual quedara en la biblioteca ('Interstellar (2014)',
    # 'Juego de Tronos (2011)').
    #
    # VACIO = se coge el NOMBRE DEL PAQUETE de JDownloader, que es el uso
    # normal: renombras el pack en JD y no hay que pasar nada por linea de
    # ordenes. Se rellena a mano solo cuando el pack se llama algo que no
    # sirve, como 'JuegazosS1E01RemuxHeyshir'.
    [Alias('Serie')]
    [string]$Nombre = '',

    # Raices de la biblioteca. La carpeta del titulo cuelga de la que toque
    # segun el tipo.
    [Alias('RaizBiblioteca')]
    [string]$RaizSeries    = 'E:\Series',
    [string]$RaizPeliculas = 'E:\Peliculas',

    # Areas de preparacion. CADA UNA TIENE QUE SER (o estar dentro de) UN
    # DATA SOURCE DE tmm DEL TIPO CORRESPONDIENTE, o el raspado no la vera:
    # tmm solo mira dentro de sus data sources. Ver la cabecera.
    [Alias('AreaPreparacion')]
    [string]$PrepSeries    = 'C:\Users\HTPC\Videos',
    [string]$PrepPeliculas = 'C:\Users\HTPC\Videos_Peliculas',

    # 'Season N' es la nomenclatura del resto de E:\Series (Season 1,
    # Season 2, ...). 'SeasonNN' da Season01..Season08.
    [ValidateSet('Season N','SeasonNN')]
    [string]$FormatoTemporada = 'Season N',

    # ---- tinyMediaManager -------------------------------------------------
    [string]$TmmExe = 'C:\Users\HTPC\AppData\Local\Programs\tinyMediaManagerV5\tinyMediaManagerCMD.exe',
    # Indice del data source que hay que escanear. Es 1-BASED: con 0 tmm
    # revienta con un IndexOutOfBounds -1 que no se parece en nada a la causa.
    #
    # 0 aqui significa "averigualo tu": Get-TmmIndiceDataSource lo saca de
    # tmm.prop buscando la posicion del area de preparacion en la lista de
    # data sources del tipo que toque. Asi no hay un numero a mano que se
    # queda obsoleto en cuanto se anyade o se quita un data source en tmm.
    [int]$TmmDataSourceIndex = 0,
    # Sin esto, tmm solo raspa; con esto ademas renombra segun TU plantilla.
    [switch]$NoRenombrarConTmm,
    [int]$TmmTimeoutMin = 45,
    # Seguir aunque tmm falle: la temporada se copia a E: sin metadatos en vez
    # de quedarse atascada en C: ocupando sitio.
    [switch]$SeguirSinMetadatos,

    # ---- Comportamiento ---------------------------------------------------
    # Ensayo: dice lo que haria y NO mueve, NO borra y NO arranca descargas.
    [switch]$Simular,
    [switch]$UnaTanda,
    [int]$MaxTandas = 0,

    # ADOPCION. Si al arrancar ya hay trabajo en marcha -ficheros en la cola
    # del encoder, fuentes en encode_running, .mkv extraidos en Descargas o
    # paquetes en la lista de JD-, ESO es la tanda y no se baja nada nuevo.
    #
    # Va activada por defecto y no es un adorno: el 08/09/2026 habia 6
    # episodios de la S1 metidos a mano (E01/E02 codificando, E03-E05 en cola,
    # E06 extrayendose) y sin esto la primera ejecucion habria pedido 4 mas
    # encima, que son 102 GB que no caben. -Adoptar existe solo para poder
    # decirlo de forma explicita en la linea de ordenes; para desactivarla,
    # -NoAdoptar.
    [switch]$Adoptar,
    [switch]$NoAdoptar,

    # La papelera se vacia por defecto: JD manda los .rar alli al extraer
    # ('deletearchivefilesafterextractionaction': RECYCLE), asi que sin esto
    # el espacio NO se libera. Ya hay 21 GB acumulados de esa forma.
    # OJO: vacia la papelera ENTERA de C:, no solo los .rar de la tanda.
    [switch]$NoVaciarPapelera,

    # Por debajo de esto un fichero no es un episodio (samples, extras).
    [double]$MinVideoMb = 150,

    [int]$TimeoutDescargaMin = 300,
    # Presupuesto de encode POR FICHERO. Un 4K largo ronda la hora y media.
    [int]$TimeoutEncodePorFicheroMin = 240,

    # Cuanto puede desviarse la duracion de la salida respecto de la fuente
    # para seguir considerandola buena.
    [double]$ToleranciaDuracionPct = 1.0,

    # ---- PRESUPUESTO DE DESCARGA -----------------------------------------
    # Tope de GB bajados en una VENTANA DESLIZANTE DE 24 HORAS. 0 = sin tope.
    #
    # POR QUE EXISTE (08/09/2026): el 1fichier de Real-Debrid dejo de servir a
    # media tanda -30 de 43 enlaces en 'Temporalmente no disponible',
    # FILE_UNAVAILABLE en el log de JD, velocidad 0- tras ~233 GB en un dia,
    # con la cuenta PREMIUM valida y la red perfecta. Es la cuota diaria del
    # multihoster. Sin tope, el bucle se come el plazo entero de 5 horas
    # esperando algo que no va a llegar.
    #
    # POR QUE 24 H DESLIZANTES Y NO "hasta medianoche": esas cuotas se reponen
    # por ventana movil, no a una hora fija. Contando lo bajado en las ultimas
    # 24 h se acierta en los dos casos.
    #
    # NO ES UN CORTE SECO: al llegar al tope el bucle ESPERA a que la ventana
    # libere sitio y sigue solo. Eso es el "para seguir luego" sin tener que
    # relanzar nada a mano.
    [double]$MaxGbDia = 0,

    # Cada cuanto se vuelve a mirar si ya cabe la tanda siguiente, y cuanto se
    # espera antes de reintentar una descarga atascada.
    [int]$EsperaPresupuestoMin = 20,

    # Minutos SIN QUE AVANCE UN BYTE tras los cuales se da la descarga por
    # atascada. Es el sintoma de la cuota agotada del multihoster: JD sigue en
    # RUNNING, los enlaces en 'Temporalmente no disponible' y la velocidad a 0.
    # Sin esto el bucle se comia las 5 horas de plazo esperando a nadie.
    [int]$EstancadoMin = 45,

    # SONDEO. Nuestro tope de 24 h es un calculo NUESTRO, no el limite real de
    # Real-Debrid. El 09/09/2026 se comprobo a mano que con 203 GB gastados y
    # el tope en 300 la cuenta bajaba de 1fichier sin problema: el tope iba
    # corto y el bucle se habria quedado 12 h parado para nada.
    #
    # Asi que en vez de esperar a que la ventana de 24 h se vacie, pasados
    # estos minutos DESDE EL ULTIMO INTENTO se lanza la tanda igualmente y el
    # que contesta es el multihoster. Si su cuota sigue agotada no entra ni un
    # byte, la deteccion de atasco lo sabe en $EstancadoInicialMin, se para JD
    # y se vuelve a probar dentro de otro intervalo.
    #
    # 0 = comportamiento antiguo: esperar a que la ventana libere sitio.
    [int]$SondeoCadaMin = 120,

    # Ventana de atasco MIENTRAS no ha entrado ni un byte. Corta a proposito
    # frente a los 45 de $EstancadoMin: aqui no se mide si la descarga va
    # lenta, se mide si el multihoster contesta, y eso se sabe enseguida.
    [int]$EstancadoInicialMin = 10,

    # Minutos que se le conceden a la cuota del multihoster antes de darla por
    # agotada. NO es un temporizador de atasco: aqui JD ya ha DICHO cual es el
    # problema. Existe solo porque JD reintenta solo cada pocos minutos y hay
    # que dejarle un par de vueltas por si la espera era pasajera.
    # Medido el 09/09/2026: no lo es. JD cuenta atras 2m27s, reintenta, falla,
    # y le dan 4m37s. El castigo CRECE, asi que insistir no lleva a nada.
    [int]$CuotaGraciaMin = 6
)

$ErrorActionPreference = 'Stop'

# Cuando se intento bajar algo por ultima vez. Es el reloj del SONDEO: se
# cuenta desde el ultimo intento y no desde que empezo la espera, para que un
# sondeo que rebota contra la cuota del multihoster no acabe sumando la espera
# del atasco MAS la del presupuesto y se vaya al doble del intervalo pedido.
$script:UltimoIntento = Get-Date

# GB ya apuntados, por UUID de paquete de JD, para no volver a contarlos en el
# sondeo siguiente. Ver Add-GbDeLaTanda. Se guarda en disco porque si viviera
# solo en memoria, un corte de luz a mitad de una tanda de 100 GB haria que al
# volver se apuntaran esos 100 GB OTRA VEZ, y el registro dejaria de servir
# para saber cuanto da de si el multihoster al dia.
$script:GbYaContados = @{}

# Lo ultimo que dijo JD al dar la cuota por agotada, para que el log lo cuente
# tal cual en vez de una frase nuestra que puede no ser lo que paso.
$script:MotivoCuota = ''

function Read-GbContados {
    if (-not (Test-Path -LiteralPath $ContadosFile)) { return }
    try {
        $o = Get-Content -LiteralPath $ContadosFile -Raw | ConvertFrom-Json
        foreach ($p in $o.PSObject.Properties) { $script:GbYaContados[$p.Name] = [double]$p.Value }
    } catch {
        Write-Log "  aviso: no pude leer '$ContadosFile' ($($_.Exception.Message)); lo ya bajado de la tanda en curso se contara otra vez."
    }
}

function Save-GbContados {
    try {
        $json = ($script:GbYaContados | ConvertTo-Json -Depth 3 -Compress)
        [System.IO.File]::WriteAllText($ContadosFile, $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Log "  aviso: no pude guardar '$ContadosFile' ($($_.Exception.Message)); si el bucle se reinicia se contara de mas."
    }
}

function Clear-GbContadosViejos {
    <#
      Quita las entradas de paquetes que ya no estan en la lista de JD: son de
      tandas cerradas y no vuelven. Sin esto el fichero crece sin fin y, peor,
      un UUID reciclado por JD empezaria con una deuda que no es suya.
      Si la API no contesta no se toca nada: mejor de mas que de menos.
    #>
    if (-not $script:GbYaContados.Count) { return }
    $vivos = @()
    try { $vivos = @(Get-JdPaquetesDescarga | ForEach-Object { [string]$_.uuid }) } catch { return }
    $fuera = @($script:GbYaContados.Keys | Where-Object { $vivos -notcontains $_ })
    if (-not $fuera.Count) { return }
    foreach ($k in $fuera) { $script:GbYaContados.Remove($k) }
    Save-GbContados
}

# ---------------------------------------------------------------------------
# LIBRERIAS. pipeline-lock.ps1 trae Get-OtraInstancia y Test-PipelinePaused, y
# arrastra mediabox-paths.ps1, que es de donde salen $FFPROBE y $MediaBoxTmp:
# la regla del proyecto es que esas rutas tienen UNA sola definicion.
# Dot-sourcearlo es inofensivo: fuera de sus funciones solo asigna variables.
# ---------------------------------------------------------------------------
$LockLib = Join-Path $PSScriptRoot 'pipeline-lock.ps1'
if (-not (Test-Path -LiteralPath $LockLib)) { $LockLib = 'C:\scripts\pipeline-lock.ps1' }
. $LockLib

$JdLib = Join-Path $PSScriptRoot 'jd-lib.ps1'
if (-not (Test-Path -LiteralPath $JdLib)) { $JdLib = 'C:\scripts\jd-lib.ps1' }
. $JdLib

$Base     = 'C:\Media'
$Queue    = Join-Path $Base 'encode_queue'
$Running  = Join-Path $Base 'encode_running'
$Encoded  = Join-Path $Base 'encoded'
$LogsDir  = Join-Path $Base 'encode_logs'
$Tmp      = if ($MediaBoxTmp) { $MediaBoxTmp } else { 'C:\Media\tmp' }

$CompletedJsonl = Join-Path $LogsDir 'completed.jsonl'
$LogFile        = Join-Path $LogsDir 'tandas.log'
$HistFile       = Join-Path $LogsDir 'tandas.jsonl'
$StopFile       = Join-Path $Tmp 'tandas_stop'
$PidFile        = Join-Path $Tmp 'tandas_pid'

# LA RED DE SEGURIDAD ANTE UN CORTE DE LUZ O UN REINICIO.
#
# Este fichero existe MIENTRAS el bucle deberia estar corriendo, y guarda con
# que argumentos se lanzo y por donde iba. La distincion que lo hace funcionar
# es simple: en cualquier salida NORMAL -parada pedida, -UnaTanda, no queda
# nada que bajar, un fallo que obliga a parar- el script lo BORRA al terminar;
# si el equipo se apaga de golpe, nadie lo borra y ahi se queda.
#
# tandas-keepalive.ps1, que corre desde una tarea programada al iniciar sesion
# y cada 10 min, mira exactamente eso: fichero presente + proceso ausente =
# se murio sin querer, hay que relanzarlo. Y si no esta el fichero, no hace
# nada: parar el bucle a proposito no debe resucitarlo.
$ActivoFile     = Join-Path $Tmp 'tandas_activo.json'
# Contabilidad de GB bajados, para el tope diario. Fichero aparte porque
# sobrevive a reinicios y se suma en cada tanda.
$DescargasFile  = Join-Path $Tmp 'tandas_descargado.jsonl'
$ContadosFile   = Join-Path $Tmp 'tandas_contados.json'
$MaxReintentos  = 10

# Los argumentos con los que se llamo, para que el keepalive pueda relanzar
# EXACTAMENTE lo mismo. Se reconstruyen de $PSBoundParameters y no se escriben
# a mano: asi un -Nombre o un -N nuevo viajan solos al relanzamiento.
$script:ArgsInvocacion = @()
foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [switch]) {
        if ($v.IsPresent) { $script:ArgsInvocacion += "-$k" }
    } else {
        $script:ArgsInvocacion += "-$k"
        $script:ArgsInvocacion += [string]$v
    }
}

# CONTEXTO DE LA TANDA. Antes eran dos constantes -una serie fija y una raiz
# fija-; ahora cada tanda decide que es y adonde va, porque el mismo script
# sirve para una serie y para una pelicula. Los rellena Set-ContextoTanda en
# cuanto se sabe que trae la tanda, y los leen la colocacion y el cierre.
$script:TipoTanda   = 'serie'   # 'serie' | 'pelicula'
$script:NombreTanda = ''        # 'Juego de Tronos (2011)', 'Interstellar (2014)'
$script:PrepRaiz    = $PrepSeries    # area de preparacion EN USO (data source de tmm)
$script:PrepItem    = ''             # <PrepRaiz>\<NombreTanda>
$script:DestinoItem = ''             # <RaizSeries|RaizPeliculas>\<NombreTanda>

# La configuracion de tmm, de donde sale el indice del data source. NO es
# tmm.prop: esa propiedad solo guarda el ULTIMO valor tocado en el dialogo
# de anyadir data source -UN string, no la lista completa-. La lista REAL, en
# el mismo orden que ve la CLI (su propia ayuda lo dice: "same order as in
# the UI/settings"), vive en estos dos JSON. Verificado en esta maquina: es
# AppData\Roaming\tinyMediaManager\data\, y NO tinyMediaManagerV5.
$TmmMovieJson = 'C:\Users\HTPC\AppData\Roaming\tinyMediaManager\data\movies.json'
$TmmTvJson    = 'C:\Users\HTPC\AppData\Roaming\tinyMediaManager\data\tvShows.json'
# Raiz de descargas: se lee de la config de JD en vez de escribirla a mano,
# que es la trampa que mediabox-paths.ps1 existe para matar.
$RaizDescargas = 'C:\Users\HTPC\Downloads'
try {
    $gs = Get-Content -LiteralPath 'C:\Users\HTPC\AppData\Local\JDownloader 2\cfg\org.jdownloader.settings.GeneralSettings.json' -Raw | ConvertFrom-Json
    if ($gs.defaultdownloadfolder) { $RaizDescargas = [string]$gs.defaultdownloadfolder }
} catch { }

$ExtVideo = @('.mkv','.mp4','.m2ts','.ts','.avi','.mov','.m4v')
# Restos que significan "la extraccion no ha terminado". Si siguen ahi cuando
# vence el plazo, lo mas probable es que el archivo pida contrasenya.
$PatronesRestos = @('*.part','*.rar','*.r[0-9][0-9]','*.zip','*.7z',
                    '*.z[0-9][0-9]','*.[0-9][0-9][0-9]','*.tmp','*.jdu')

# LO UNICO que Remove-RestosDescarga tiene permiso para borrar: los trozos de
# la descarga y la morralla que viene con ellos. Es una LISTA BLANCA a
# proposito: lo que no este aqui no se borra, aunque nos lo hayan pasado.
#
# POR QUE: esa funcion borra por NOMBRE lo que se le da, y el 09/09/2026 se
# le llego a pasar el nombre de una pelicula de 14,2 GB del usuario porque los
# paquetes de JD no se filtraban. Aquello se arreglo acotando el alcance, pero
# el alcance era TODA la proteccion que habia: si vuelve a colarse un nombre
# que no toca, esto es lo que impide que desaparezca un fichero.
$ExtRestosOk = '(?i)^\.(part|rar|r\d{2}|zip|7z|z\d{2}|\d{3}|tmp|jdu|sfv|nfo|txt|par2|md5|url|jpg|jpeg|png)$'

# Lo que dice JD cuando el multihoster no da mas. Son DOS mensajes y no uno:
#
#   'Multihoster: real-debrid.com: Wait 2m:27s Reason: Fair usage limit reached'
#   'Temporalmente no disponible'
#
# El segundo sale cuando JD ya agoto SUS PROPIOS reintentos y aparca el enlace.
# El 10/09/2026 eso dejo la deteccion muda: solo se buscaba el primero, asi que
# se caia al reloj de atasco y tardaba 45 min en vez de 6 -con JD dando golpes
# mientras tanto-. Se descarto el segundo mensaje por generico, y el error fue
# suponer que el primero volveria al reintentar. No vuelve.
#
# Que sea generico no importa aqui: la respuesta correcta es la misma -aparcar,
# esperar y reintentar- y se exige que TODOS los pendientes esten asi, con lo
# que un enlace muerto suelto no dispara nada. El motivo exacto se apunta en el
# log para no perder la distincion.
$PatronCuota = '(?i)fair\s*usage|fair\s*use|limit reached|temporalmente no disponible|temporarily unavailable'

New-Item -ItemType Directory -Force -Path $Queue,$Running,$Encoded,$LogsDir,$Tmp | Out-Null

# ---------------------------------------------------------------------------
# UTILIDADES
# ---------------------------------------------------------------------------

function Write-Log {
    # Write-Host + Add-Content -LiteralPath, y NO Tee-Object: aqui los nombres
    # traen corchetes ('[YTS.MX]', '[UHDReescalado 2160p HDR]') y Tee-Object
    # los interpreta como comodines. Ya rompio un log en este repositorio.
    param([Parameter(Mandatory)][string]$Texto)
    $linea = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Texto
    Write-Host $linea
    try { Add-Content -LiteralPath $LogFile -Value $linea -Encoding utf8 } catch { }
}

function Get-GbDescargadasHoy {
    <#
      GB bajados HOY -desde la medianoche local-, sumando el registro de
      tandas.

      POR QUE EL DIA NATURAL Y NO UNA VENTANA DESLIZANTE DE 24 H: porque es lo
      que hace Real-Debrid, medido el 10/09/2026. Corto tres dias seguidos tras
      233,6 / 330,9 / 301,0 GB contados por dia natural, y el bloqueo del
      10/09 -que duro mas de 15 horas- se levanto solo a los 4 minutos de
      medianoche. Con ventana deslizante la cuenta no se parecia a nada: servia
      tan tranquilo con 442,8 y 542,1 GB dentro de la ventana, y se negaba con
      428,8.

      Y no es solo cosmetico: con la ventana deslizante el tope saltaba cuando
      no debia -a las 00:28 del 11/09 decia 307,9 de 320 cuando la cuota de RD
      acababa de renovarse-, y eso mandaba la tanda a esperar un sondeo de dos
      horas para nada.

      Se guarda en su propio fichero y no en el log: hay que poder sumarlo
      rapido y que sobreviva a reinicios, que es cuando importa -la cuota del
      multihoster no se entera de que has reiniciado el PC-.
    #>
    $corte = (Get-Date).Date
    $total = 0.0
    if (-not (Test-Path -LiteralPath $DescargasFile)) { return 0.0 }
    foreach ($linea in @(Get-Content -LiteralPath $DescargasFile -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($linea)) { continue }
        try { $r = $linea | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $t = [DateTimeOffset]::FromUnixTimeSeconds([long]$r.ts).LocalDateTime
        if ($t -ge $corte) { $total += [double]$r.gb }
    }
    return $total
}

function Add-GbDescargadas {
    param([double]$Gb)
    if ($Simular -or $Gb -le 0) { return }
    $r = @{ ts = [long][math]::Floor(([DateTimeOffset](Get-Date)).ToUnixTimeSeconds())
            gb = [math]::Round($Gb, 2) }
    try {
        Add-Content -LiteralPath $DescargasFile -Value ($r | ConvertTo-Json -Compress) -Encoding utf8
    } catch {
        Write-Log "  aviso: no pude anotar los $([math]::Round($Gb,1)) GB bajados: $($_.Exception.Message)"
        return
    }
    # Poda a 48 h: el fichero no debe crecer sin fin, y con 24 h de margen
    # sobre la ventana no se pierde nada que se vaya a contar.
    try {
        $corte = (Get-Date).AddHours(-48)
        $vivas = @(Get-Content -LiteralPath $DescargasFile -ErrorAction Stop | Where-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return $false }
            try { $j = $_ | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
            ([DateTimeOffset]::FromUnixTimeSeconds([long]$j.ts).LocalDateTime) -ge $corte
        })
        Set-Content -LiteralPath $DescargasFile -Value $vivas -Encoding utf8
    } catch {
        # Que la poda falle no rompe nada -el fichero crece y ya-, pero si
        # falla siempre acabaria siendo un fichero enorme que hay que sumar
        # entero en cada tanda.
        Write-Log "  aviso: no pude podar '$DescargasFile': $($_.Exception.Message)"
    }
}


function Add-GbDeLaTanda {
    <#
      Anota en el presupuesto lo que JD dice que bajo DE VERDAD para estos
      paquetes. Hay que llamarla ANTES de sacarlos de su lista: despues ya no
      queda a quien preguntarle. Se anota tambien cuando la tanda falla,
      porque esos GB han gastado cuota igual y es justo el caso que hay que
      contar bien.

      VIVE AQUI Y NO DUPLICADA EN LAS DOS RAMAS porque el 09/09/2026 solo la
      tenia la rama que baja del linkgrabber: una tanda ADOPTADA -la que se
      reanuda tras un corte o un reinicio- bajaba sus 99 GB sin apuntar ni
      uno, y la tanda siguiente arrancaba creyendo que tenia sitio de sobra.
      Justo el camino por el que se llega otra vez al muro del multihoster.

      Cuenta lo NUEVO desde la ultima vez que se apunto ese mismo paquete, no
      su bytesLoaded total. Contar el total valia cuando esto se llamaba una
      vez por tanda, pero con el sondeo cada 2 h se llama en CADA intento: los
      20 GB ya bajados de un episodio a medias se volverian a apuntar en cada
      sondeo -20 GB fantasma cada dos horas- y en unas horas el registro no
      valdria ni para saber cuanto da de si el multihoster al dia, que es justo
      para lo que se guarda.

      La cuenta va por UUID de paquete. Al cerrar la tanda JD borra el paquete
      y su entrada se queda muerta sin molestar: un paquete nuevo trae UUID
      nuevo y se cuenta desde cero, que es lo correcto.
    #>
    param([long[]]$Ids = @())
    if (-not $Ids.Count) { return }
    try {
        $bajados = 0.0
        foreach ($pq in @(Get-JdPaquetesDescarga | Where-Object { $Ids -contains [long]$_.uuid })) {
            $gb = if ($pq.bytesLoaded) { [double]$pq.bytesLoaded / 1GB } else { 0.0 }
            $k  = [string]$pq.uuid
            $ya = if ($script:GbYaContados.ContainsKey($k)) { [double]$script:GbYaContados[$k] } else { 0.0 }
            # Solo lo NUEVO, y nunca negativo: JD reinicia el contador de un
            # enlace que reintenta desde cero, y restar eso de lo ya apuntado
            # seria regalarnos cuota que si se ha gastado.
            if ($gb -gt $ya) {
                $bajados += ($gb - $ya)
                $script:GbYaContados[$k] = $gb
            }
        }
        if ($bajados -gt 0) {
            Add-GbDescargadas -Gb $bajados
            Save-GbContados
            Write-Log ("  bajados {0:N1} GB. Hoy van {1:N1} GB." -f $bajados, (Get-GbDescargadasHoy))
        }
    } catch { Write-Log "  aviso: no pude contabilizar lo bajado: $($_.Exception.Message)" }
}
function Wait-ConParada {
    # Espera troceada para que una parada pedida no tenga que aguantar hasta el
    # final del sleep. Devuelve $false si hay que parar.
    param([int]$Minutos)
    for ($i = 0; $i -lt ($Minutos * 60); $i += 30) {
        if (Test-Path -LiteralPath $StopFile) { return $false }
        Start-Sleep -Seconds 30
    }
    return $true
}

function Test-CuotaMultihoster {
    <#
      Dice si los enlaces que faltan estan parados por la cuota de uso justo
      del multihoster. Se lo PREGUNTA a JD en vez de deducirlo del reloj: JD lo
      dice con todas las letras en el 'status' de cada enlace.

        Multihoster: real-debrid.com: Wait 2m:27s Reason: Fair usage limit reached

      Es mucho mejor senyal que el detector de atasco: se sabe en segundos y no
      en 45 min, y separa "la cuota esta agotada" de "este enlace esta muerto"
      o "va lento".

      Exige que esten TODOS los pendientes en ese estado. Con uno solo podria
      ser cosa de ese enlace mientras los demas siguen bajando tan tranquilos.
    #>
    param([long[]]$Ids = @())
    if (-not $Ids.Count) { return $false }
    $ls = @()
    try {
        $q = '{"packageUUIDs":[' + (($Ids | ForEach-Object { [string]$_ }) -join ',') + '],"status":true,"finished":true}'
        $ls = @(Invoke-JdApi -Ruta 'downloadsV2/queryLinks' -Params @($q))
    } catch { return $false }
    $pend = @($ls | Where-Object { -not $_.finished })
    if (-not $pend.Count) { return $false }
    $tocados = @($pend | Where-Object { "$($_.status)" -match $PatronCuota })
    if ($tocados.Count -ne $pend.Count) { return $false }
    $script:MotivoCuota = "$($tocados[0].status)"
    return $true
}

function Wait-EntreSondeos {
    <#
      Pausa despues de que la descarga rebote contra la cuota del multihoster.
      JD ya viene parado de la rama que llama aqui, asi que durante esta espera
      no hay nada corriendo: ni se baja, ni se reintenta, ni se ensucia el
      estado de los enlaces.

      Espera lo que FALTE para completar $SondeoCadaMin desde el ultimo
      intento, no un intervalo entero mas. Si esperara un intervalo completo se
      sumaria a la espera del presupuesto que viene despues y el sondeo caeria
      al doble del rato pedido.
    #>
    if ($SondeoCadaMin -le 0) { return (Wait-ConParada -Minutos $EsperaPresupuestoMin) }
    while ($true) {
        $faltan = $SondeoCadaMin - ((Get-Date) - $script:UltimoIntento).TotalMinutes
        if ($faltan -le 0) { return $true }
        $trozo = [int][math]::Ceiling([math]::Min($faltan, 10))
        if ($trozo -lt 1) { $trozo = 1 }
        if (-not (Wait-ConParada -Minutos $trozo)) { return $false }
    }
}

function Wait-PresupuestoDescarga {
    <#
      Decide cuando se puede lanzar la tanda. Dos caminos, y vale el primero
      que llegue:

        - lo bajado HOY deja sitio y la tanda CABE bajo el tope; o
        - han pasado $SondeoCadaMin desde el ultimo intento y se SONDEA: se
          lanza igualmente y el que contesta es el multihoster.

      El sondeo existe porque el tope es un calculo nuestro y puede ir corto:
      el 09/09/2026, con 203 GB gastados y el tope en 300, la cuenta bajaba
      perfectamente y el bucle se habria quedado 12 h parado para nada.

      Devuelve $true cuando hay que lanzar y $false si hay que parar (parada
      pedida, o la tanda no cabria ni con el dia entero por delante, que es
      un error de configuracion y no algo que se arregle esperando).
    #>
    param([double]$GbNecesarios)
    if ($MaxGbDia -le 0) { return $true }

    if ($GbNecesarios -gt $MaxGbDia) {
        Write-Log ("  La tanda pide {0:N1} GB y el tope diario es {1:N1}: no cabria ni con la ventana vacia." -f $GbNecesarios, $MaxGbDia)
        Write-Log '  Sube -MaxGbDia o baja -N. Saliendo.'
        return $false
    }

    $avisado = $false
    while ($true) {
        if (Test-Path -LiteralPath $StopFile) {
            Write-Log '  Parada solicitada mientras esperaba presupuesto de descarga.'
            return $false
        }
        # Se sigue mirando el tope en cada vuelta: al cambiar el dia la cuenta
        # se pone a cero y se arranca ya, sin esperar al sondeo. Lo que llegue
        # primero.
        $usadas = Get-GbDescargadasHoy
        if (($usadas + $GbNecesarios) -le $MaxGbDia) {
            Write-Log ("  presupuesto: {0:N1} de {1:N1} GB usados hoy; la tanda de {2:N1} GB cabe." -f $usadas, $MaxGbDia, $GbNecesarios)
            return $true
        }
        if (-not $avisado) {
            Write-Log ("  TOPE DE DESCARGA: {0:N1} de {1:N1} GB bajados HOY. La tanda pide {2:N1} GB mas." -f $usadas, $MaxGbDia, $GbNecesarios)
            if ($SondeoCadaMin -gt 0) {
                Write-Log "  SONDEO cada $SondeoCadaMin min desde el ultimo intento: pasado ese rato lo intento igualmente y que conteste el multihoster."
            } else {
                Write-Log "  Espero a que la ventana libere sitio (miro cada $EsperaPresupuestoMin min). No se baja ni se borra nada mientras tanto."
            }
            Save-EstadoActivo -Fase 'esperando presupuesto'
            $avisado = $true
        }

        $espera = $EsperaPresupuestoMin
        if ($SondeoCadaMin -gt 0) {
            $desde = ((Get-Date) - $script:UltimoIntento).TotalMinutes
            if ($desde -ge $SondeoCadaMin) {
                Write-Log ("  SONDEO: {0:N0} min desde el ultimo intento y seguimos sobre el tope ({1:N1} de {2:N1} GB). Lo intento igualmente." -f $desde, $usadas, $MaxGbDia)
                Write-Log '  Si la cuota del multihoster sigue agotada no entrara ni un byte, se parara JD y se repetira.'
                return $true
            }
            # No dormir mas alla del momento del sondeo.
            $faltan = [int][math]::Ceiling($SondeoCadaMin - $desde)
            if ($faltan -lt 1) { $faltan = 1 }
            if ($faltan -lt $espera) { $espera = $faltan }
        }

        if (-not (Wait-ConParada -Minutos $espera)) {
            Write-Log '  Parada solicitada mientras esperaba presupuesto.'
            return $false
        }
    }
}

function Read-EstadoActivo {
    if (-not (Test-Path -LiteralPath $ActivoFile)) { return $null }
    try { return (Get-Content -LiteralPath $ActivoFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-EstadoActivo {
    <#
      Deja constancia de que este bucle deberia estar vivo, con que argumentos
      se lanzo y por donde va. Lo lee tandas-keepalive.ps1 tras un reinicio.

      En SIMULACION no se escribe nada: un ensayo no debe dejar al keepalive
      creyendo que hay trabajo en marcha.

      Sin BOM, como todos los ficheros de estado del pipeline.
    #>
    param([string]$Fase = '', [int]$Tanda = 0, [int]$Reintentos = -1)
    if ($Simular) { return }
    $prev = Read-EstadoActivo
    $est = [ordered]@{
        ts_inicio   = if ($prev -and $prev.ts_inicio) { [long]$prev.ts_inicio } else { [long][math]::Floor(([DateTimeOffset](Get-Date)).ToUnixTimeSeconds()) }
        ts_latido   = [long][math]::Floor(([DateTimeOffset](Get-Date)).ToUnixTimeSeconds())
        argumentos  = @($script:ArgsInvocacion)
        tanda       = if ($Tanda -gt 0) { $Tanda } elseif ($prev) { [int]$prev.tanda } else { 0 }
        fase        = if ($Fase) { $Fase } elseif ($prev) { "$($prev.fase)" } else { '' }
        tipo        = $script:TipoTanda
        nombre      = $script:NombreTanda
        reintentos  = if ($Reintentos -ge 0) { $Reintentos } elseif ($prev) { [int]$prev.reintentos } else { 0 }
    }
    try {
        $json = ($est | ConvertTo-Json -Depth 5 -Compress)
        [System.IO.File]::WriteAllText($ActivoFile, $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        # No es cosmetico: si esto falla SIEMPRE, la red de seguridad ante
        # cortes de luz no existe y nadie se enteraria hasta el apagon.
        Write-Log "  AVISO: no pude escribir el estado '$ActivoFile': $($_.Exception.Message)"
        Write-Log '         la reanudacion automatica tras un corte NO funcionara.'
    }
}

function Remove-EstadoActivo {
    # Se llama en TODA salida normal. Que exista despues de que el proceso ya
    # no esta es justo la senyal de "esto se murio sin querer".
    if ($Simular) { return }
    try { Remove-Item -LiteralPath $ActivoFile -Force -ErrorAction Stop }
    catch {
        # Dejarlo puesto hace que el keepalive relance una vez de mas. No es
        # grave -la instancia nueva vera que no hay nada que hacer y saldra-,
        # pero conviene que conste.
        if (Test-Path -LiteralPath $ActivoFile) {
            Write-Log "  aviso: no pude borrar '$ActivoFile'; el keepalive puede relanzar una vez de mas."
        }
    }
}

function Get-LibreGb {
    param([string]$Unidad = 'C')
    $d = New-Object System.IO.DriveInfo($Unidad)
    return [math]::Round(($d.AvailableFreeSpace / 1GB), 1)
}

function Test-EncodeWatchVivo {
    # Sin watcher, lo que se deje en encode_queue no lo coge nadie y este
    # script esperaria hasta el timeout sin que pase nada. Se comprueba con
    # Get-OtraInstancia y no con un Get-Process a secas porque Windows recicla
    # los PID: el 04/09/2026 un svchost heredo el PID de subs-watch y dejo el
    # pipeline parado sin una linea que lo dijera.
    $pf = Join-Path $Tmp 'encode_watch_pid'
    return ((Get-OtraInstancia -PidFile $pf -Marca 'encode-watch.ps1') -gt 0)
}

function Test-FicheroLibre {
    # Abrir en exclusiva es la unica forma fiable de saber que NADIE lo tiene
    # abierto. Se usa antes de borrar un fuente: si un ffmpeg lo sigue
    # leyendo, el borrado no debe ni intentarse.
    param([Parameter(Mandatory)][string]$Ruta)
    try {
        $fs = [System.IO.File]::Open($Ruta, 'Open', 'Read', 'None')
        $fs.Close(); $fs.Dispose()
        return $true
    } catch { return $false }
}

function Get-DuracionSeg {
    param([Parameter(Mandatory)][string]$Ruta)
    # Quoting POR ELEMENTO del array de argumentos: los nombres de aqui traen
    # espacios, corchetes y acentos, y un quoting global no los sobrevive.
    $a = @('-v','error','-show_entries','format=duration','-of','csv=p=0',$Ruta)
    $txt = (& $FFPROBE @a 2>$null | Select-Object -First 1)
    $d = 0.0
    if (-not [double]::TryParse("$txt".Trim(),
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return 0.0 }
    return $d
}

function ConvertTo-SegundosHms {
    # 'HH:MM:SS.nnnnnnnnn' -> segundos. Es el formato del tag DURATION de MKV,
    # que es lo unico que da la duracion POR PISTA de forma fiable.
    param([string]$Texto)
    if ($Texto -match '(\d+):(\d+):([\d.]+)') {
        return ([double]$Matches[1] * 3600 + [double]$Matches[2] * 60 + [double]$Matches[3])
    }
    return 0.0
}

function Test-SalidaValida {
    <#
      La puerta que hay que pasar para que se borre algo. Devuelve un objeto
      con Ok y Motivo, para que el log diga QUE fallo y no solo que fallo.

      Test-Path a secas NO vale: en este repositorio ya hubo un encode "correcto"
      con un fichero de 0 bytes. Por eso se mira tamanyo, pistas y duracion.
    #>
    param(
        [Parameter(Mandatory)][string]$Salida,
        [double]$DuracionFuente = 0
    )
    if (-not (Test-Path -LiteralPath $Salida)) { return [pscustomobject]@{ Ok=$false; Motivo='no existe la salida' } }
    $fi = Get-Item -LiteralPath $Salida
    if ($fi.Length -lt 1MB) { return [pscustomobject]@{ Ok=$false; Motivo="salida de $($fi.Length) bytes" } }

    $a = @('-v','error','-select_streams','v','-show_entries','stream=codec_type','-of','csv=p=0',$Salida)
    $v = @(& $FFPROBE @a 2>$null)
    if (-not $v.Count) { return [pscustomobject]@{ Ok=$false; Motivo='la salida no tiene pista de video' } }

    $a = @('-v','error','-select_streams','a','-show_entries','stream=codec_type','-of','csv=p=0',$Salida)
    $au = @(& $FFPROBE @a 2>$null)
    if (-not $au.Count) { return [pscustomobject]@{ Ok=$false; Motivo='la salida no tiene pista de audio' } }

    # CADA PISTA DE AUDIO CONTRA EL VIDEO, no solo el contenedor.
    #
    # Comparar la duracion del CONTENEDOR no basta y costo un episodio: el
    # S01E04 llego a la biblioteca con la pista DD+ 220 s CORTA y corrupta
    # ('error decoding the audio block'), y paso la verificacion porque el
    # contenedor lo marca la pista MAS LARGA -el video-, asi que un audio
    # corto no lo mueve ni un segundo. Solo se detectaba el caso contrario.
    $tags = @()
    try {
        $js = (& $FFPROBE -v error -show_entries 'stream=index,codec_type:stream_tags=DURATION' -of json $Salida | ConvertFrom-Json)
        $tags = @($js.streams)
    } catch {
        # Si esto falla se pierde justo la comprobacion que caza una pista de
        # audio corta, que es la que dejo pasar el S01E04. Que conste.
        Write-Log "    aviso: no pude leer las duraciones por pista de '$Salida': $($_.Exception.Message)"
    }
    $durVid = 0.0
    foreach ($st in $tags) {
        if ($st.codec_type -ne 'video') { continue }
        $d = ConvertTo-SegundosHms "$($st.tags.DURATION)"
        if ($d -gt $durVid) { $durVid = $d }
    }
    if ($durVid -gt 0) {
        foreach ($st in $tags) {
            if ($st.codec_type -ne 'audio') { continue }
            $d = ConvertTo-SegundosHms "$($st.tags.DURATION)"
            if ($d -le 0) { continue }
            $desv = [math]::Abs($d - $durVid) / $durVid * 100.0
            if ($desv -gt $ToleranciaDuracionPct) {
                return [pscustomobject]@{ Ok=$false
                    Motivo=("la pista de audio {0} dura {1:N0}s y el video {2:N0}s ({3:N1}% de desvio)" -f $st.index, $d, $durVid, $desv) }
            }
        }
    }

    $dur = Get-DuracionSeg $Salida
    if ($dur -le 0) { return [pscustomobject]@{ Ok=$false; Motivo='ffprobe no da duracion de la salida' } }

    if ($DuracionFuente -gt 0) {
        $desvio = [math]::Abs($dur - $DuracionFuente) / $DuracionFuente * 100.0
        if ($desvio -gt $ToleranciaDuracionPct) {
            return [pscustomobject]@{ Ok=$false
                Motivo=("duracion {0:N0}s contra {1:N0}s de la fuente ({2:N1}% de desvio)" -f $dur,$DuracionFuente,$desvio) }
        }
    }
    return [pscustomobject]@{ Ok=$true; Motivo=("{0:N0}s, {1:N1} GB" -f $dur, ($fi.Length/1GB)) }
}

function Remove-Seguro {
    # Un solo sitio por donde pasa TODO lo que se borra: asi -Simular no se
    # puede olvidar en una rama, que es como se pierden ficheros.
    param([Parameter(Mandatory)][string]$Ruta, [switch]$Carpeta)
    if (-not (Test-Path -LiteralPath $Ruta)) { return $true }
    if ($Simular) { Write-Log "    [SIMULADO] borraria: $Ruta"; return $true }
    try {
        if ($Carpeta) { Remove-Item -LiteralPath $Ruta -Recurse -Force -ErrorAction Stop }
        else          { Remove-Item -LiteralPath $Ruta -Force -ErrorAction Stop }
        Write-Log "    borrado: $Ruta"
        return $true
    } catch {
        Write-Log "    NO se pudo borrar '$Ruta': $($_.Exception.Message)"
        return $false
    }
}

function Remove-RestosDescarga {
    <#
      Borra lo que queda de una tanda ya procesada. SIEMPRE FICHERO A FICHERO,
      nunca la carpeta de golpe.

      POR QUE NO SE BORRA LA CARPETA: todos los episodios de una temporada
      comparten el mismo 'saveTo'. La carpeta
      'Downloads\JuegazosS1E01RemuxHeyshir' tiene los .rar de E07, E08, E09 y
      E10 a la vez, asi que un 'Remove-Item -Recurse' al cerrar la tanda de E07
      se llevaria por delante los otros tres episodios ya bajados -75 GB de
      descarga- sin que nadie se enterase hasta que JD intentara extraerlos.
      La carpeta solo desaparece si queda VACIA, que es cuando ya no queda
      nada de esa temporada.

      LA PROTECCION DE LA RAIZ TAMPOCO ES PARANOIA: si un enlace llega sin
      nombre de paquete, su 'saveTo' es la carpeta de descargas A SECAS. Ahi
      no se borra la carpeta jamas, pase lo que pase.
    #>
    param(
        [Parameter(Mandatory)][string]$Carpeta,
        [string[]]$Ficheros = @()
    )
    if ([string]::IsNullOrWhiteSpace($Carpeta)) { return }
    if (-not (Test-Path -LiteralPath $Carpeta)) { return }

    $c = [System.IO.Path]::GetFullPath($Carpeta).TrimEnd('\')
    $r = [System.IO.Path]::GetFullPath($RaizDescargas).TrimEnd('\')
    $esSubcarpeta = $c.StartsWith(($r + '\'), [System.StringComparison]::OrdinalIgnoreCase)

    $borrados = 0
    foreach ($f in $Ficheros) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        # Solo el nombre: un 'f' con separadores apuntaria fuera de la carpeta.
        $hoja = Split-Path $f -Leaf
        $ruta = Join-Path $c $hoja
        if (-not (Test-Path -LiteralPath $ruta)) { continue }

        # LISTA BLANCA. Un video aqui no es "un resto raro", es una senyal de
        # que algo ha ido mal mas arriba, asi que se dice con todas las letras.
        $ext = [System.IO.Path]::GetExtension($hoja)
        if ($ExtVideo -contains $ext.ToLower()) {
            Write-Log "    NO BORRO '$hoja': es un VIDEO y aqui solo se borran restos de descarga."
            Write-Log '    Que un video llegue hasta aqui significa que la tanda esta mal acotada. Miralo.'
            continue
        }
        if ($ext -notmatch $ExtRestosOk) {
            Write-Log "    NO BORRO '$hoja': la extension '$ext' no es de un resto de descarga."
            continue
        }
        if (Remove-Seguro $ruta) { $borrados++ }
    }
    Write-Log "    restos de descarga borrados en '$c': $borrados fichero(s)."

    if (-not $esSubcarpeta) {
        Write-Log "    '$c' es la raiz de descargas (o esta fuera de ella): no la toco."
        return
    }
    if ($Simular) { return }
    # La carpeta se va SOLO si no queda nada: si aun tiene los .rar de los
    # episodios siguientes, se queda tal cual.
    $quedan = @(Get-ChildItem -LiteralPath $c -Force -ErrorAction SilentlyContinue)
    if ($quedan.Count) {
        Write-Log "    '$c' aun tiene $($quedan.Count) elemento(s) -otros episodios-: la dejo."
        return
    }
    $null = Remove-Seguro -Ruta $c -Carpeta
}

function Clear-Papelera {
    if ($NoVaciarPapelera) { return }
    if ($Simular) { Write-Log '    [SIMULADO] vaciaria la papelera de C:'; return }
    try {
        Clear-RecycleBin -DriveLetter C -Force -Confirm:$false -ErrorAction Stop
        Write-Log '    papelera de C: vaciada.'
    } catch {
        Write-Log "    no se pudo vaciar la papelera: $($_.Exception.Message)"
    }
}

function Get-VideosDe {
    # Los videos de verdad de una carpeta ya extraida. El filtro de tamanyo y
    # el de nombre estan para que no acaben en la cola del encoder los samples
    # y los extras, que aqui vienen casi siempre.
    param([Parameter(Mandatory)][string]$Carpeta)
    if (-not (Test-Path -LiteralPath $Carpeta)) { return @() }
    return @(Get-ChildItem -LiteralPath $Carpeta -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension.ToLower() -in $ExtVideo -and
            $_.Length -ge ($MinVideoMb * 1MB) -and
            $_.Name -notmatch '(?i)\b(sample|muestra|trailer|proof)\b'
        })
}

function Test-JdOtrosPendientes {
    <#
      Hay en JD algo pendiente que NO sea de esta tanda? Sirve para decidir si
      se puede parar el controlador entero o hay que dejarlo en marcha.

      Ante cualquier duda devuelve $true, o sea "si hay": equivocarse por ese
      lado deja JD corriendo sin nada que hacer, que no molesta a nadie.
      Equivocarse por el otro para las descargas del usuario.
    #>
    param([long[]]$MiosIds = @())
    try {
        foreach ($p in @(Get-JdPaquetesDescarga)) {
            if ($MiosIds -contains [long]$p.uuid) { continue }
            $q = '{"packageUUIDs":[' + $p.uuid + '],"enabled":true,"finished":true}'
            $ls = @(Invoke-JdApi -Ruta 'downloadsV2/queryLinks' -Params @($q))
            if (@($ls | Where-Object { $_.enabled -and -not $_.finished }).Count) { return $true }
        }
    } catch {
        Write-Log "    no pude mirar si JD tiene otras descargas ($($_.Exception.Message)): no lo paro."
        return $true
    }
    return $false
}

function Suspend-TandaEnJd {
    <#
      Aparca la descarga de ESTA tanda sin tocar lo que el usuario tenga
      bajando. Desactiva nuestros enlaces y solo para el controlador si no
      queda nada mas pendiente.

      POR QUE: 'downloadcontroller/stop' es GLOBAL. El 10/09/2026 el usuario se
      bajaba un fichero suyo mientras la tanda esperaba al multihoster; si el
      sondeo hubiera caido en ese momento, le habria parado su descarga sin
      avisar. Es el mismo problema que el -Filtro resolvio por el otro lado
      -"no adoptes lo que no es tuyo"-, aqui en version "no pares lo que no es
      tuyo".

      Si setEnabled falla se cae al comportamiento antiguo: mejor parar de mas
      que dejar a JD dando golpes contra una cuota agotada.
    #>
    param([long[]]$Ids = @())
    if (-not $Ids.Count) { Stop-JdDescargas; return }
    try {
        Set-JdEnlacesActivos -PackageIds $Ids -Activo $false
    } catch {
        Write-Log "    no pude desactivar los enlaces de la tanda ($($_.Exception.Message)): paro JD entero."
        Stop-JdDescargas
        return
    }
    if (Test-JdOtrosPendientes -MiosIds $Ids) {
        Write-Log '    enlaces de la tanda desactivados; JD sigue en marcha porque tiene descargas que no son de la tanda.'
    } else {
        Stop-JdDescargas
    }
}

function Resume-TandaEnJd {
    # Lo contrario: reactiva nuestros enlaces y arranca el controlador. Hay que
    # reactivar SIEMPRE antes de arrancar, o el sondeo miraria unos enlaces que
    # el aparcado anterior dejo desactivados y no bajaria nunca.
    param([long[]]$Ids = @())
    if ($Ids.Count) {
        try { Set-JdEnlacesActivos -PackageIds $Ids -Activo $true }
        catch { Write-Log "    aviso: no pude reactivar los enlaces de la tanda: $($_.Exception.Message)" }
    }
    Start-JdDescargas
}

function Restore-EnlacesDeLaTanda {
    <#
      Reactiva al arrancar los enlaces que casan con -Filtro.

      LA RED DE SEGURIDAD DE TODO ESTO: si el script muere con la tanda
      aparcada -corte de luz, un kill-, sus enlaces se quedan DESACTIVADOS y en
      silencio. JD no los bajaria nunca y el log no diria por que, que es
      exactamente la clase de fallo mudo que este proyecto no se permite. Una
      parada global se ve; unos enlaces desactivados, no.
    #>
    if (-not $ApiViva) { return }
    try {
        $mios = @(Get-JdPaquetesDescarga | Where-Object { -not $Filtro -or "$($_.name)" -match $Filtro })
        if (-not $mios.Count) { return }
        Set-JdEnlacesActivos -PackageIds @($mios | ForEach-Object { [long]$_.uuid }) -Activo $true
        Write-Log ("  reactivados los enlaces de {0} paquete(s) en JD, por si quedaron aparcados." -f $mios.Count)
    } catch {
        Write-Log "  aviso: no pude reactivar los enlaces en JD: $($_.Exception.Message)"
    }
}

function Get-VideosListosDe {
    <#
      Los videos de estas carpetas que YA estan enteros: su episodio no deja ni
      un resto de archivo detras y nadie tiene el fichero abierto.

      POR QUE SE MIRA POR EPISODIO Y NO POR CARPETA: todos los episodios de una
      temporada comparten el mismo 'saveTo'. Preguntar "quedan .rar en la
      carpeta?" contestaria que NO hay nada listo mientras al ultimo episodio le
      falten partes, que es exactamente el caso que esto viene a resolver.

      Un video SIN SxxExx reconocible -una pelicula suelta- no se puede separar
      de sus restos por episodio, asi que se le exige lo mas duro: que en la
      carpeta no quede ningun archivo. Mejor no adelantarlo que adelantarlo a
      medio extraer.
    #>
    param([Parameter(Mandatory)][string[]]$Carpetas)
    $out = @()
    foreach ($c in @($Carpetas | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }

        # De que episodios quedan restos AHORA MISMO.
        $conResto = @{}
        foreach ($p in $PatronesRestos) {
            foreach ($r in @(Get-ChildItem -LiteralPath $c -File -Recurse -Filter $p -ErrorAction SilentlyContinue)) {
                $s = Get-SxE -NombreFichero $r.Name
                if ($s.S -gt 0 -and $s.E -gt 0) { $conResto[(Get-ClaveSxE $s.S $s.E)] = $true }
            }
        }
        $hayRestos = (Test-RestosArchivo -Carpeta $c)

        foreach ($v in (Get-VideosDe $c)) {
            if ($FiltroVideo -and $v.Name -notmatch $FiltroVideo) { continue }
            $s = Get-SxE -NombreFichero $v.Name
            if ($s.S -gt 0 -and $s.E -gt 0) {
                if ($conResto.ContainsKey((Get-ClaveSxE $s.S $s.E))) { continue }
            } elseif ($hayRestos) {
                continue
            }
            # Abierto por otro proceso = todavia se esta extrayendo. Es la
            # unica comprobacion que no se puede deducir del nombre.
            if (-not (Test-FicheroLibre $v.FullName)) { continue }
            $out += [pscustomobject]@{ Fichero = $v; Paquete = (Split-Path $c -Leaf) }
        }
    }
    return @($out)
}

function Move-ListosALaCola {
    <#
      Adelanta a la cola del encoder los episodios que YA estan enteros cuando
      la descarga se atasca. Devuelve cuantos ha movido.

      POR QUE EXISTE: el 10/09/2026 la cuota del multihoster corto una tanda con
      3 de 4 episodios ya extraidos, y le faltaban 6,8 GB al cuarto. Las dos
      ranuras de codificacion se quedaron VACIAS 5 horas y media esperando esos
      6,8 GB. El encode es el cuello de botella de este pipeline -56 min por
      tanda frente a 27 de descarga-, asi que esas horas no se recuperan
      despues: son tiempo perdido y punto.

      NO HACE FALTA LLEVAR LA CUENTA de lo adelantado, y eso es lo que hace que
      esto sea seguro: al reintentar la tanda, Get-TandaAdoptada los encuentra
      en encode_queue -o en encode_running, o ya codificados- y los mete en la
      tanda por las ramas que ya existian. Sus claves salen de ahi igual que si
      se hubieran encolado todos a la vez, asi que la limpieza del final sigue
      cubriendo los cuatro episodios.

      Mover de Descargas a encode_queue es un rename en el MISMO volumen: es
      atomico y el watcher nunca ve un fichero a medias.
    #>
    param([Parameter(Mandatory)][string[]]$Carpetas)
    if ($Simular) { return 0 }
    $listos = @(Get-VideosListosDe -Carpetas $Carpetas)
    if (-not $listos.Count) { return 0 }
    $n = 0
    foreach ($item in $listos) {
        $v   = $item.Fichero
        $dst = Join-Path $Queue $v.Name
        if (Test-Path -LiteralPath $dst) { continue }
        $gb = $v.Length / 1GB
        try {
            Move-Item -LiteralPath $v.FullName -Destination $dst -ErrorAction Stop
            $n++
            Write-Log ("    adelantado a la cola: {0}  ({1:N1} GB)" -f $v.Name, $gb)
        } catch {
            Write-Log "    no pude adelantar '$($v.Name)': $($_.Exception.Message)"
        }
    }
    return $n
}

function Test-RestosArchivo {
    param([Parameter(Mandatory)][string]$Carpeta)
    if (-not (Test-Path -LiteralPath $Carpeta)) { return $false }
    foreach ($p in $PatronesRestos) {
        $hit = @(Get-ChildItem -LiteralPath $Carpeta -File -Recurse -Filter $p -ErrorAction SilentlyContinue)
        if ($hit.Count) { return $true }
    }
    return $false
}

function Get-HuellaCarpeta {
    # Nombre+tamanyo de todo lo que hay dentro. Dos lecturas iguales separadas
    # en el tiempo = nadie esta escribiendo (ni JD bajando, ni la extraccion).
    param([Parameter(Mandatory)][string]$Carpeta)
    if (-not (Test-Path -LiteralPath $Carpeta)) { return '' }
    $items = @(Get-ChildItem -LiteralPath $Carpeta -File -Recurse -ErrorAction SilentlyContinue |
               Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)" })
    return ($items -join "`n")
}

# ---------------------------------------------------------------------------
# TEMPORADA Y EPISODIO
# ---------------------------------------------------------------------------

function Get-SxE {
    <#
      Devuelve @{ S = <temporada>; E = <episodio> }, con 0 en lo que no se
      pueda averiguar.

      Se mira PRIMERO el nombre del fichero y solo despues el del paquete, y no
      al reves: el fichero real ('Game.Of.Thrones.S01.E01.2160p...') es el que
      sabe de verdad cual es; el paquete ('JuegazosS1E01RemuxHeyshir') es un
      titulo que ha puesto una persona.

      Si ninguno lo dice, se devuelve 0 y el llamante NO coloca el fichero:
      dejarlo en encoded\ es recuperable, meterlo en la temporada equivocada de
      una biblioteca de 10 TB no lo es.
    #>
    param([string]$NombreFichero = '', [string]$NombrePaquete = '')
    foreach ($txt in @($NombreFichero, $NombrePaquete)) {
        if ([string]::IsNullOrWhiteSpace($txt)) { continue }
        # S01E02 / S01.E02 / S01 E02 / S1E2
        $m = [regex]::Match($txt, '(?i)S\s*(\d{1,2})\s*[._ -]?\s*E\s*(\d{1,3})')
        if ($m.Success) { return @{ S = [int]$m.Groups[1].Value; E = [int]$m.Groups[2].Value } }
        # 1x02
        $m = [regex]::Match($txt, '(?i)(?<![0-9])(\d{1,2})\s*x\s*(\d{2})(?![0-9])')
        if ($m.Success) { return @{ S = [int]$m.Groups[1].Value; E = [int]$m.Groups[2].Value } }
        # 'Season 3' suelto: temporada si, episodio no
        $m = [regex]::Match($txt, '(?i)(?:season|temporada)\s*(\d{1,2})')
        if ($m.Success) { return @{ S = [int]$m.Groups[1].Value; E = 0 } }
    }
    return @{ S = 0; E = 0 }
}

function Get-NombreTemporada {
    param([Parameter(Mandatory)][int]$Numero)
    if ($FormatoTemporada -eq 'SeasonNN') { return ("Season{0:00}" -f $Numero) }
    return ("Season {0}" -f $Numero)
}

function Get-CarpetaPreparacion {
    <#
      Donde se prepara un fichero de la tanda.

      En una SERIE cuelga una carpeta de temporada; en una PELICULA no hay
      temporada y el fichero va directo a la carpeta del titulo, que es como
      esta montada E:\Peliculas (una carpeta por pelicula, sin nada en medio).
    #>
    param([string]$Titulo = '', [int]$Temporada = 0)
    $t = if ($Titulo) { $Titulo } else { $script:NombreTanda }
    $item = Join-Path $script:PrepRaiz $t
    if ($script:TipoTanda -eq 'pelicula') { return $item }
    return (Join-Path $item (Get-NombreTemporada $Temporada))
}

function Test-EsSerie {
    # Serie si ALGUN fichero de la tanda dice SxxExx (o 1x02). Con que uno lo
    # diga basta: una pelicula no lleva eso en el nombre ni por casualidad, y
    # un episodio suelto mal nombrado no debe convertir la serie en pelicula.
    param([string[]]$Nombres = @())
    foreach ($n in $Nombres) {
        $sxe = Get-SxE -NombreFichero $n
        if ($sxe.S -gt 0 -and $sxe.E -gt 0) { return $true }
    }
    return $false
}

function Set-ContextoTanda {
    <#
      Decide QUE es esta tanda y ADONDE va, y lo deja en las variables de
      script que usan la colocacion y el cierre.

      El nombre sale, por este orden: del parametro -Nombre, o del nombre del
      PAQUETE de JDownloader. Lo segundo es el uso previsto para el dia a dia:
      renombras el pack en JD a 'Interstellar (2014)' y el script no necesita
      que le digas nada mas.
    #>
    param(
        [string[]]$NombresFichero = @(),
        [string]$NombrePaquete = ''
    )
    $t = $Tipo
    if ($t -eq 'auto') {
        $t = if (Test-EsSerie -Nombres $NombresFichero) { 'serie' } else { 'pelicula' }
    }
    # Orden: lo que se pidio a mano, el paquete de JD, y de ultimo el nombre
    # que quedo guardado del intento anterior. Ese respaldo es lo que permite
    # RETOMAR tras un corte de luz una tanda que ya no tiene carpeta de
    # descarga de la que sacar el titulo, porque estaba a mitad de codificar.
    $n = if ($Nombre) { $Nombre }
         elseif ($NombrePaquete) { $NombrePaquete }
         else { $script:NombreGuardado }
    if ([string]::IsNullOrWhiteSpace($n)) { return $false }
    # Un nombre con caracteres prohibidos crearia una carpeta invalida.
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $n = $n.Replace($c, ' ') }
    $n = $n.Trim()

    $script:TipoTanda   = $t
    $script:NombreTanda = $n
    $script:PrepRaiz    = if ($t -eq 'pelicula') { $PrepPeliculas } else { $PrepSeries }
    $script:PrepItem    = Join-Path $script:PrepRaiz $n
    $script:DestinoItem = Join-Path $(if ($t -eq 'pelicula') { $RaizPeliculas } else { $RaizSeries }) $n

    Write-Log "  tipo: $t   titulo: '$n'"
    Write-Log "    preparacion: $script:PrepItem"
    Write-Log "    biblioteca : $script:DestinoItem"
    return $true
}

function Get-TmmIndiceDataSource {
    <#
      Posicion 1-BASED del area de preparacion dentro de la lista de data
      sources de tmm de su tipo, leida de la lista REAL. Devuelve 0 si no la
      encuentra.

      POR QUE NO ES UN NUMERO A MANO: --updateX es un INDICE, no una ruta, asi
      que en cuanto se anyade o se quita un data source en tmm el numero de
      antes apunta a otra carpeta y el raspado se hace sobre la biblioteca
      equivocada, en silencio. Sacarlo del fichero que manda es lo unico que
      no se queda obsoleto.

      POR QUE movies.json/tvShows.json Y NO tmm.prop: se probo con tmm.prop y
      fallaba en silencio para peliculas. 'movie.datasource.path' ahi vale UN
      string -'E:\Peques', el ultimo tocado en el dialogo de anyadir carpeta-
      mientras que la lista real ('movieDataSource' en movies.json) tiene
      CUATRO entradas. Con una sola area de series esto no se notaba -las dos
      fuentes coincidian por casualidad-, pero con varias areas de peliculas
      el indice salia siempre mal o en 0. Descubierto el 14/09/2026 revisando
      el camino de peliculas antes de que lo pisara una tanda de verdad.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('serie','pelicula')][string]$TipoMedia,
        [Parameter(Mandatory)][string]$Ruta
    )
    $archivo = if ($TipoMedia -eq 'pelicula') { $TmmMovieJson } else { $TmmTvJson }
    $clave   = if ($TipoMedia -eq 'pelicula') { 'movieDataSource' } else { 'tvShowDataSource' }
    if (-not (Test-Path -LiteralPath $archivo)) { return 0 }

    try {
        $cfg = Get-Content -LiteralPath $archivo -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { return 0 }

    # OJO al nombre: NO puede llamarse $ruta. PowerShell no distingue
    # mayusculas en los nombres de variable, asi que $ruta y el parametro
    # $Ruta son LA MISMA, y la comparacion de abajo saldria siempre cierta.
    $listaSources = @($cfg.$clave)
    if (-not $listaSources.Count) { return 0 }
    $buscada = $Ruta.Trim().TrimEnd('\')
    $i = 0
    foreach ($candidataBruta in $listaSources) {
        $i++
        $candidata = "$candidataBruta".Trim().TrimEnd('\')
        if ($candidata -eq $buscada) { return $i }
    }
    return 0
}

function Get-BaseArchivo {
    <#
      Nombre del archivo multi-parte al que pertenece un fichero, sin la parte.

        JuegazosS1E07RemuxHeyshir.part03.rar -> JuegazosS1E07RemuxHeyshir
        JuegazosS1E07RemuxHeyshir.r05        -> JuegazosS1E07RemuxHeyshir
        JuegazosS1E07RemuxHeyshir.7z.002     -> JuegazosS1E07RemuxHeyshir

      El orden de los reemplazos importa: '.part03.rar' tiene que morir ANTES
      de que la regla generica de '.rar' le quite solo la extension y deje un
      '.part03' que ya no agrupa con nada.
    #>
    param([Parameter(Mandatory)][string]$Nombre)
    $b = $Nombre
    $b = $b -replace '(?i)\.part\d+\.rar$', ''
    $b = $b -replace '(?i)\.(7z|zip|rar)\.\d{3}$', ''
    $b = $b -replace '(?i)\.(rar|zip|7z)$', ''
    $b = $b -replace '(?i)\.r\d{2,3}$', ''
    $b = $b -replace '(?i)\.z\d{2,3}$', ''
    return $b
}

function Get-NumeroParte {
    <#
      Que numero de parte es, 1-based, para poder comprobar que no falta
      ninguna. Devuelve 0 si el esquema no se reconoce.

      Los dos esquemas que conviven: el moderno ('.part01.rar', '.part02.rar')
      y el viejo de RAR, donde la PRIMERA parte es '.rar' a secas y las
      siguientes '.r00', '.r01'... (de ahi el +2).
    #>
    param([Parameter(Mandatory)][string]$Nombre)
    $m = [regex]::Match($Nombre, '(?i)\.part(\d+)\.rar$')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    $m = [regex]::Match($Nombre, '(?i)\.(?:7z|zip|rar)\.(\d{3})$')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    if ($Nombre -match '(?i)\.(rar|zip|7z)$') { return 1 }
    $m = [regex]::Match($Nombre, '(?i)\.r(\d{2,3})$')
    if ($m.Success) { return ([int]$m.Groups[1].Value + 2) }
    $m = [regex]::Match($Nombre, '(?i)\.z(\d{2,3})$')
    if ($m.Success) { return ([int]$m.Groups[1].Value + 1) }
    return 0
}

function Get-GruposEpisodio {
    <#
      Convierte los paquetes del linkgrabber en GRUPOS DE UN EPISODIO, que es
      la unidad con la que trabaja este script.

      EL PORQUE, que es lo que define todo el disenyo: un paquete de JD aqui es
      una TEMPORADA -107 ficheros, 255 GB en la S2-, y eso no cabe en C: ni de
      lejos. Pero dentro, los .rar vienen en juegos independientes por
      episodio (part01..part11 de 2,5 GB), y cada juego se extrae por su
      cuenta. Agrupando por nombre base se puede mover a la lista de descargas
      UN episodio y dejar los demas esperando.

      Un grupo al que le falte una parte se marca Completo=$false y el llamante
      NO lo coge: JD bajaria lo que hubiera y la extraccion se quedaria a
      medias para siempre, ocupando 25 GB sin dar un solo .mkv.
    #>
    param([Parameter(Mandatory)][object[]]$Paquetes)

    $grupos = @()
    foreach ($p in $Paquetes) {
        $enlaces = @()
        try {
            $enlaces = @(Get-JdEnlacesCola -PackageIds @([long]$p.uuid))
        } catch {
            Write-Log "    no pude leer los enlaces del paquete '$($p.name)': $($_.Exception.Message)"
            continue
        }
        if (-not $enlaces.Count) { continue }

        foreach ($g in ($enlaces | Group-Object { Get-BaseArchivo "$($_.name)" })) {
            $partes = @($g.Group | ForEach-Object { Get-NumeroParte "$($_.name)" })
            $bytes  = 0.0
            foreach ($l in $g.Group) { if ($l.bytesTotal) { $bytes += [double]$l.bytesTotal } }

            $completo = $true
            $motivo   = ''
            $offline  = @($g.Group | Where-Object { "$($_.availability)" -eq 'OFFLINE' })
            if ($offline.Count) {
                $completo = $false
                $motivo   = "$($offline.Count) parte(s) OFFLINE"
            } elseif ($g.Group.Count -eq 1 -and $partes[0] -eq 0) {
                # Un enlace SUELTO sin esquema de partes reconocible (un .mkv
                # directo de 1fichier, no un RAR multiparte): es un fichero de
                # una sola pieza, no le falta nada. Es el caso normal de una
                # pelicula. Si hubiera MAS de un enlace en el grupo y alguno no
                # se reconoce, eso si es sospechoso y cae en la rama de abajo.
            } elseif ($partes -contains 0) {
                $completo = $false
                $motivo   = 'no reconozco el esquema de partes'
            } else {
                $ordenadas = @($partes | Sort-Object -Unique)
                if ($ordenadas[0] -ne 1 -or $ordenadas.Count -ne $g.Group.Count -or
                    $ordenadas[$ordenadas.Count - 1] -ne $ordenadas.Count) {
                    $completo = $false
                    $motivo   = "faltan partes (tengo $($g.Group.Count), van de $($ordenadas[0]) a $($ordenadas[$ordenadas.Count-1]))"
                }
            }

            $sxe = Get-SxE -NombreFichero $g.Name -NombrePaquete "$($p.name)"
            $grupos += [pscustomobject]@{
                Base          = $g.Name
                LinkIds       = @($g.Group | ForEach-Object { [long]$_.uuid })
                Nombres       = @($g.Group | ForEach-Object { "$($_.name)" })
                Partes        = $g.Group.Count
                Bytes         = $bytes
                S             = $sxe.S
                E             = $sxe.E
                Completo      = $completo
                Motivo        = $motivo
                PaqueteUuid   = [long]$p.uuid
                PaqueteNombre = "$($p.name)"
                SaveTo        = "$($p.saveTo)"
            }
        }
    }
    # En orden de emision: asi las tandas van E01, E02... y no a saltos.
    return @($grupos | Sort-Object S, E, Base)
}

function Move-APreparacion {
    <#
      Lleva una salida verificada de encoded\ al area de preparacion, con el
      nombre normalizado: 'Serie - S01E03.mkv' o 'Pelicula (2014).mkv'.

      POR QUE SE RENOMBRA: encode.ps1 deja la salida con el nombre de la
      fuente ya "Plex-friendly" -los puntos pasan a espacios-, asi que un
      'Game.Of.Thrones.S01.E01...' acaba como 'Game Of Thrones S01 E01 ...'.
      Es legible para una persona, pero le pone facil equivocarse al scraper.
      Con el nombre limpio tmm no tiene que adivinar nada.

      Origen y destino estan los dos en C:, asi que esto es un rename atomico
      y no una copia.
    #>
    param(
        [Parameter(Mandatory)][string]$Salida,
        [string]$Titulo = '',
        [int]$Temporada = 0,
        [int]$Episodio = 0
    )
    # El titulo es POR FICHERO, no por tanda: una tanda de 4 peliculas son 4
    # titulos distintos, y con uno solo las cuatro se llamarian igual y se
    # pisarian. En una serie los 4 episodios comparten titulo y da lo mismo.
    $tit     = if ($Titulo) { $Titulo } else { $script:NombreTanda }
    $carpeta = Get-CarpetaPreparacion -Titulo $tit -Temporada $Temporada
    $ext     = [System.IO.Path]::GetExtension($Salida)
    $nombre  = if ($script:TipoTanda -eq 'pelicula') {
                   "{0}{1}" -f $tit, $ext
               } elseif ($Episodio -gt 0) {
                   "{0} - S{1:00}E{2:00}{3}" -f $tit, $Temporada, $Episodio, $ext
               } else {
                   Split-Path $Salida -Leaf
               }
    $destino = Join-Path $carpeta $nombre

    if (Test-Path -LiteralPath $destino) {
        Write-Log "    ya existe en preparacion: '$destino'. No lo sobrescribo."
        return ''
    }
    if ($Simular) { Write-Log "    [SIMULADO] llevaria '$nombre' a '$carpeta'"; return $destino }
    try {
        if (-not (Test-Path -LiteralPath $carpeta)) { New-Item -ItemType Directory -Force -Path $carpeta | Out-Null }
        Move-Item -LiteralPath $Salida -Destination $destino -ErrorAction Stop
        Write-Log "    a preparacion: $destino"
        return $destino
    } catch {
        Write-Log "    NO se pudo llevar a preparacion: $($_.Exception.Message)"
        return ''
    }
}

# ---------------------------------------------------------------------------
# CIERRE DE TEMPORADA: metadatos y copia a la biblioteca
# ---------------------------------------------------------------------------

function Invoke-Tmm {
    <#
      Raspa metadatos de lo que haya en el area de preparacion.

      --updateX es 1-BASED: con 0 tmm revienta con 'IndexOutOfBoundsException:
      Index -1 out of bounds for length 1', que no se parece en nada a la
      causa. COMPROBADO en esta maquina el 07/09/2026.

      Se escanea SOLO el data source de la preparacion (--updateX=N y no -u)
      para no ponerse a repasar la biblioteca entera de 10 TB en cada tanda.

      El modulo depende del tipo: 'tvshow' para series y 'movie' para
      peliculas, cada uno con su lista de data sources y su propio indice.
    #>
    if (-not (Test-Path -LiteralPath $TmmExe)) {
        Write-Log "    tinyMediaManager no esta en '$TmmExe': me salto el raspado."
        return $false
    }

    # El indice se resuelve contra tmm.prop salvo que se haya forzado a mano.
    $idx = $TmmDataSourceIndex
    if ($idx -le 0) {
        $idx = Get-TmmIndiceDataSource -TipoMedia $script:TipoTanda -Ruta $script:PrepRaiz
    }
    if ($idx -le 0) {
        Write-Log "    '$script:PrepRaiz' NO es un data source de $($script:TipoTanda) en tmm."
        Write-Log '    tmm solo raspa dentro de sus data sources, asi que no habria metadatos.'
        Write-Log "    Anyadelo en tmm (Configuracion > $(if ($script:TipoTanda -eq 'pelicula') { 'Peliculas' } else { 'Series' }) > Data sources) o pasa -TmmDataSourceIndex."
        return $false
    }
    if ($Simular) { Write-Log '    [SIMULADO] lanzaria tinyMediaManager para raspar metadatos'; return $true }

    # tmm y su GUI comparten base de datos: con la ventana abierta, la CLI no
    # puede tocarla. Es un fallo confuso, asi que se avisa antes.
    if (@(Get-Process -Name 'tinyMediaManager*' -ErrorAction SilentlyContinue).Count) {
        Write-Log '    tinyMediaManager esta ABIERTO: la CLI no puede usar su base de datos. Cierralo.'
        return $false
    }

    $modulo = if ($script:TipoTanda -eq 'pelicula') { 'movie' } else { 'tvshow' }
    $a = @($modulo, "--updateX=$idx", '-n')
    if (-not $NoRenombrarConTmm) { $a += '-r' }
    Write-Log "    tmm $($a -join ' ')"
    try {
        $p = Start-Process -FilePath $TmmExe -ArgumentList $a -PassThru -NoNewWindow -WorkingDirectory (Split-Path $TmmExe -Parent)
        # Materializar el handle ANTES de esperar: sin esto, ExitCode sale
        # $null. Es el mismo bug que ya mordio con ffmpeg y con el OCR.
        $null = $p.Handle
        if (-not $p.WaitForExit($TmmTimeoutMin * 60 * 1000)) {
            Write-Log "    tmm no termino en $TmmTimeoutMin min; sigo sin esperarlo mas."
            return $false
        }
        if ($p.ExitCode -ne 0) { Write-Log "    tmm salio con codigo $($p.ExitCode)."; return $false }
        Write-Log '    metadatos raspados.'
        return $true
    } catch {
        Write-Log "    fallo al lanzar tmm: $($_.Exception.Message)"
        return $false
    }
}

function Copy-TemporadaABiblioteca {
    <#
      Copia una temporada preparada (videos + .nfo + imagenes) a la biblioteca
      y devuelve $true solo si TODO llego bien.

      COPIA A '.partial' Y RENOMBRA DESPUES, fichero a fichero: C: y E: son
      volumenes distintos, asi que esto es una copia de verdad de decenas de
      GB. Si se corta a la mitad -corte de luz, el DAS que tarda en despertar-,
      con una copia directa quedaria un fichero con el NOMBRE BUENO y el
      contenido a medias, que la biblioteca no puede distinguir de uno sano.
      El rename final si es atomico: ya ocurre dentro de E:.

      NO SOBRESCRIBE NADA. Un fichero que ya exista en el destino se respeta y
      la temporada NO se da por copiada, asi que tampoco se borra de C:. Ver la
      regla 5 del README: un Move-Item -Force costo una pelicula el 29/08/2026.
    #>
    param(
        [Parameter(Mandatory)][string]$Origen,
        [Parameter(Mandatory)][string]$Destino,
        # Si se pasa, se copian EXACTAMENTE estos ficheros -que tienen que
        # colgar de $Origen- en vez de la carpeta entera. Es lo que permite
        # llevar los metadatos de la RAIZ de la serie sin arrastrar de paso las
        # carpetas de temporada que cuelgan de ella.
        #
        # OJO al nombre: no puede llamarse $Ficheros porque la variable local
        # de abajo se llamaria igual -PowerShell no distingue mayusculas- y el
        # parametro se pisaria a si mismo.
        [object[]]$Seleccion = @()
    )
    if (-not (Test-Path -LiteralPath $Origen)) { return $false }
    $lista = if ($Seleccion.Count) { @($Seleccion) }
             else { @(Get-ChildItem -LiteralPath $Origen -File -Recurse -Force -ErrorAction SilentlyContinue) }
    if (-not $lista.Count) { Write-Log "    '$Origen' esta vacia: nada que copiar."; return $false }

    if ($Simular) {
        Write-Log ("    [SIMULADO] copiaria {0} fichero(s) a '{1}'" -f $lista.Count, $Destino)
        return $true
    }
    try {
        if (-not (Test-Path -LiteralPath $Destino)) { New-Item -ItemType Directory -Force -Path $Destino | Out-Null }
    } catch {
        Write-Log "    no pude crear '$Destino': $($_.Exception.Message)"
        return $false
    }

    $raiz = [System.IO.Path]::GetFullPath($Origen).TrimEnd('\')
    $ok   = $true
    foreach ($f in $lista) {
        $rel = $f.FullName.Substring($raiz.Length).TrimStart('\')
        $dst = Join-Path $Destino $rel
        $dir = Split-Path $dst -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

        if (Test-Path -LiteralPath $dst) {
            if ((Get-Item -LiteralPath $dst).Length -eq $f.Length) {
                Write-Log "    ya estaba en destino con el mismo tamanyo: $rel"
                continue
            }
            # Un VIDEO que ya existe con otro tamanyo es motivo de parada: o es
            # otra version o es una copia a medias, y en los dos casos decidir
            # cual se queda es cosa de una persona (regla 5 del README).
            #
            # Un metadato o una imagen, NO. tmm baja un poster distinto cada
            # vez que raspa, y como el cierre es por tanda, la raiz de la serie
            # se vuelve a copiar cada 4 episodios: tratar eso como un fallo
            # dejaria la tanda sin cerrar -y sin liberar C:- por un JPG.
            if ($ExtVideo -contains $f.Extension.ToLower()) {
                Write-Log "    VIDEO ya existente y con OTRO tamanyo: '$dst'. No lo toco y paro la tanda."
                $ok = $false
            } else {
                Write-Log "    ya existe con otro tamanyo (metadato): $rel. Respeto el del destino."
            }
            continue
        }
        try {
            $tmpDst = "$dst.partial"
            if (Test-Path -LiteralPath $tmpDst) { Remove-Item -LiteralPath $tmpDst -Force -ErrorAction Stop }
            Copy-Item -LiteralPath $f.FullName -Destination $tmpDst -ErrorAction Stop
            $len = (Get-Item -LiteralPath $tmpDst).Length
            if ($len -ne $f.Length) {
                Remove-Item -LiteralPath $tmpDst -Force -ErrorAction SilentlyContinue
                Write-Log "    copia incompleta de '$rel' ($len de $($f.Length) bytes): la deshago."
                $ok = $false
                continue
            }
            Move-Item -LiteralPath $tmpDst -Destination $dst -ErrorAction Stop
            Write-Log ("    copiado: {0}  ({1:N1} GB)" -f $rel, ($f.Length/1GB))
        } catch {
            Write-Log "    fallo copiando '$rel': $($_.Exception.Message)"
            $ok = $false
        }
    }
    return $ok
}

function Get-CarpetasDeLaTanda {
    <#
      Que carpetas de PRIMER NIVEL del area de preparacion contienen lo que
      esta tanda acaba de colocar.

      POR QUE NO SE DA POR SUPUESTO QUE ES $script:PrepItem: tmm con -r
      RENOMBRA y puede MOVER, asi que despues del raspado la carpeta
      'Interstellar (2014)' puede llamarse como diga la plantilla del usuario,
      o una serie preparada como 'Juego de Tronos (2011)' puede acabar en
      'Juego de tronos'. Si se copiara a ciegas la ruta de antes, el cierre
      fallaria justo despues de haber hecho todo el trabajo.

      Se localizan por TAMANYO de los ficheros colocados, que el renombrado no
      cambia. Es fiable: son salidas de 3-8 GB y coincidir al byte con otra
      cosa del area de preparacion no pasa.
    #>
    param([string[]]$Colocadas = @())

    $tam = @{}
    foreach ($c in $Colocadas) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if (Test-Path -LiteralPath $c) { $tam[[long](Get-Item -LiteralPath $c).Length] = $true }
    }

    $raiz = [System.IO.Path]::GetFullPath($script:PrepRaiz).TrimEnd('\')
    $encontradas = @{}
    if ($tam.Count) {
        foreach ($f in @(Get-ChildItem -LiteralPath $script:PrepRaiz -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            if (-not $tam.ContainsKey([long]$f.Length)) { continue }
            $rel = $f.FullName.Substring($raiz.Length).TrimStart('\')
            $primero = ($rel -split '\\')[0]
            # Un fichero suelto en la raiz del area de preparacion no cuelga de
            # ninguna carpeta: no se toca.
            if ($rel -eq $primero) { continue }
            $encontradas[(Join-Path $script:PrepRaiz $primero)] = $true
        }
    }
    # Respaldo: si no se reconocio nada por tamanyo -ficheros ya movidos, o una
    # tanda sin colocadas- vale la carpeta que se preparo, si sigue ahi.
    if (-not $encontradas.Count -and (Test-Path -LiteralPath $script:PrepItem)) {
        $encontradas[$script:PrepItem] = $true
    }
    return @($encontradas.Keys)
}

function Close-Restos {
    <#
      Cierra lo que se haya quedado a medias en las areas de preparacion de
      una ejecucion anterior que se corto: raspa, copia y borra de C:.

      Se llama al empezar, ANTES de mirar el espacio libre, porque es
      justamente lo que puede liberar los 100 GB que hacen falta para que la
      tanda siguiente quepa. El tipo se deduce de en que area esta: lo que
      cuelga del area de peliculas es una pelicula y lo que cuelga de la de
      series es una serie, sin adivinar nada por el nombre.
    #>
    foreach ($par in @(@($PrepSeries, 'serie'), @($PrepPeliculas, 'pelicula'))) {
        $raiz = $par[0]; $tipoRaiz = $par[1]
        if (-not (Test-Path -LiteralPath $raiz)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $raiz -Directory -Force -ErrorAction SilentlyContinue)) {
            # Solo carpetas que tengan video dentro: en el area de series vive
            # tambien lo que el usuario tenga ahi por su cuenta.
            $vids = @(Get-ChildItem -LiteralPath $d.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
                      Where-Object { $ExtVideo -contains $_.Extension.ToLower() })
            if (-not $vids.Count) { continue }
            Write-Log "  resto de una ejecucion anterior en preparacion: '$($d.FullName)'"
            $script:TipoTanda   = $tipoRaiz
            $script:NombreTanda = $d.Name
            $script:PrepRaiz    = $raiz
            $script:PrepItem    = $d.FullName
            $script:DestinoItem = Join-Path $(if ($tipoRaiz -eq 'pelicula') { $RaizPeliculas } else { $RaizSeries }) $d.Name
            $null = Close-Preparacion -Colocadas @($vids | ForEach-Object { $_.FullName })
        }
    }
}

function Close-Preparacion {
    <#
      El cierre de la tanda: metadatos, copia verificada a la biblioteca y
      borrado de C:. Devuelve $true si todo quedo ya solo en E:.

      SE CIERRA EN CADA TANDA, no al completar la temporada. La version
      anterior esperaba a que no quedara ni un episodio pendiente de esa
      temporada en ningun sitio, y con estos tamanyos eso significaba tener los
      10 episodios codificados de la S1 (~40 GB) mas los .rar y los fuentes de
      la tanda en curso conviviendo en C:. Cerrando cada tanda, C: nunca
      acumula mas de una.

      Que la temporada quede a medias no es problema: 'Season 1' de E: se va
      rellenando tanda a tanda, y tmm raspa cada episodio nuevo por su cuenta.

      SE COPIA EL ARBOL ENTERO de la carpeta del titulo, no solo la temporada.
      Eso arrastra de paso los metadatos de nivel SERIE, que tmm deja en la
      raiz y no dentro de 'Season N': tvshow.nfo, poster.jpg, fanart*.jpg,
      clearlogo.png y .actors\. Copiando solo la temporada, la serie llegaria
      a la biblioteca sin caratula ni ficha.
    #>
    param([string[]]$Colocadas = @())

    if (-not $script:PrepItem) { return $false }
    if (-not (Test-Path -LiteralPath $script:PrepRaiz)) { return $false }

    Write-Log "  CERRANDO: $script:PrepItem"

    $conMetadatos = Invoke-Tmm
    if (-not $conMetadatos -and -not $SeguirSinMetadatos) {
        Write-Log '    sin metadatos y sin -SeguirSinMetadatos: lo dejo en C: y no borro nada.'
        return $false
    }

    $carpetas = @(Get-CarpetasDeLaTanda -Colocadas $Colocadas)
    if (-not $carpetas.Count) {
        Write-Log '    no encuentro en preparacion nada de esta tanda. No borro nada.'
        return $false
    }

    $raizDestino = if ($script:TipoTanda -eq 'pelicula') { $RaizPeliculas } else { $RaizSeries }
    $todo = $true
    foreach ($c in $carpetas) {
        $dst = Join-Path $raizDestino (Split-Path $c -Leaf)
        Write-Log "    copiando '$c' -> '$dst'"
        if (-not (Copy-TemporadaABiblioteca -Origen $c -Destino $dst)) {
            Write-Log '    la copia a la biblioteca NO fue limpia: se queda en C:.'
            $todo = $false
            continue
        }
        # Solo aqui, con todo verificado en el destino, se borra de C:.
        $null = Remove-Seguro -Ruta $c -Carpeta
        Write-Log "  cerrado: ya solo esta en '$dst'."
    }
    return $todo
}
# ---------------------------------------------------------------------------
# FASES DE UNA TANDA
# ---------------------------------------------------------------------------

function Wait-Extraccion {
    <#
      Espera a que unas carpetas queden EXTRAIDAS del todo, mirando solo el
      disco: sin restos de archivo (.rar/.part/.r00...) y con el contenido
      quieto entre dos lecturas.

      Se usa desde los dos caminos -la tanda que acaba de bajar y la tanda
      adoptada, donde JD ya no tiene nada que contar-, y por eso vive aparte.

      Devuelve 'ok', 'extraccion_fallida' (quedan .rar: casi siempre es que el
      archivo pide contrasenya, y eso no se arregla esperando) o 'timeout'.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Carpetas,
        [int]$TimeoutMin,
        [string]$Etiqueta = 'extrayendo'
    )
    $limite  = (Get-Date).AddMinutes($TimeoutMin)
    $huellas = @{}
    $ultimo  = ''

    while ((Get-Date) -lt $limite) {
        if (Test-Path -LiteralPath $StopFile) { return 'parada' }
        $conRestos = $false
        $quieto    = $true
        foreach ($c in $Carpetas) {
            if (Test-RestosArchivo $c) { $conRestos = $true }
            $h = Get-HuellaCarpeta $c
            if (-not $huellas.ContainsKey($c) -or $huellas[$c] -ne $h) { $quieto = $false }
            $huellas[$c] = $h
        }
        if (-not $conRestos -and $quieto) { return 'ok' }
        if ($conRestos -and $ultimo -ne $Etiqueta) {
            Write-Log "  $Etiqueta..."
            $ultimo = $Etiqueta
        }
        Start-Sleep -Seconds 15
    }
    foreach ($c in $Carpetas) { if (Test-RestosArchivo $c) { return 'extraccion_fallida' } }
    return 'timeout'
}

function Wait-DescargaYExtraccion {
    <#
      Espera a que los paquetes de la tanda esten bajados Y extraidos.

      NO BASTA CON EL 'finished' DE JD: ese flag se pone cuando termina la
      DESCARGA, y la extraccion de un multi-part de 17 GB va despues y tarda lo
      suyo. Si se encolara ahi, el encoder cogeria un .mkv a medio escribir.
      Por eso manda el DISCO: sin restos de archivo y con la carpeta quieta.
    #>
    param(
        [Parameter(Mandatory)][long[]]$Ids,
        [Parameter(Mandatory)][string[]]$Carpetas,
        [int]$TimeoutMin
    )
    $limite  = (Get-Date).AddMinutes($TimeoutMin)
    $avisado = (Get-Date)
    # Deteccion de atasco: si no entra ni un byte durante $EstancadoMin, no es
    # que vaya lento, es que no va. Ver la cabecera del parametro.
    $ultCargado = -1.0
    $ultAvance  = (Get-Date)
    $cuotaDesde = [datetime]::MinValue   # cuando JD empezo a decir 'fair usage'
    $ultCuota   = [datetime]::MinValue   # ultima vez que se le pregunto

    while ((Get-Date) -lt $limite) {
        Start-Sleep -Seconds 15
        # La parada se mira TAMBIEN aqui dentro. Antes solo se miraba al
        # empezar cada tanda, asi que con una descarga atascada -30 enlaces en
        # 'no disponible' y velocidad 0, el 08/09/2026- no habia forma de
        # cortar sin matar el proceso: habia que esperar las 5 h del plazo.
        if (Test-Path -LiteralPath $StopFile) { return 'parada' }

        $pk = @(Get-JdPaquetesDescarga | Where-Object { $Ids -contains [long]$_.uuid })
        if (-not $pk.Count) { return 'desaparecidos' }

        $todosFin = $true
        $cargado = 0.0; $total = 0.0
        foreach ($p in $pk) {
            if (-not $p.finished) { $todosFin = $false }
            if ($p.bytesLoaded) { $cargado += [double]$p.bytesLoaded }
            if ($p.bytesTotal)  { $total   += [double]$p.bytesTotal }
        }

        # LA CUOTA, PREGUNTADA. Va antes que el detector de atasco porque es la
        # misma situacion vista con mucha mejor luz: en vez de esperar 45 min a
        # que el reloj concluya "no avanza", JD dice el motivo en segundos.
        if ($CuotaGraciaMin -gt 0 -and ((Get-Date) - $ultCuota).TotalSeconds -ge 60) {
            $ultCuota = Get-Date
            if (Test-CuotaMultihoster -Ids $Ids) {
                if ($cuotaDesde -eq [datetime]::MinValue) {
                    $cuotaDesde = Get-Date
                    Write-Log "  el multihoster no da mas ('$script:MotivoCuota'); le doy $CuotaGraciaMin min por si era pasajero."
                } elseif (((Get-Date) - $cuotaDesde).TotalMinutes -ge $CuotaGraciaMin) {
                    return 'cuota'
                }
            } elseif ($cuotaDesde -ne [datetime]::MinValue) {
                Write-Log '  el multihoster ha vuelto: sigo con la descarga.'
                $cuotaDesde = [datetime]::MinValue
            }
        }

        if ($cargado -gt $ultCargado) { $ultCargado = $cargado; $ultAvance = Get-Date }
        else {
            # DOS ventanas de atasco, no una. Mientras no ha entrado NI UN BYTE
            # lo que se mide es si el multihoster contesta, y eso se sabe en
            # $EstancadoInicialMin: esperar los 45 completos solo alarga cada
            # sondeo. En cuanto entra el primer byte manda $EstancadoMin, que
            # es la ventana buena para una descarga que ya iba y se paro.
            $ventana = if ($ultCargado -le 0) { $EstancadoInicialMin } else { $EstancadoMin }
            if ($ventana -gt 0 -and ((Get-Date) - $ultAvance).TotalMinutes -ge $ventana) {
                return 'estancado'
            }
        }

        if (((Get-Date) - $avisado).TotalSeconds -ge 60) {
            $pct = if ($total -gt 0) { ($cargado / $total * 100.0) } else { 0 }
            Write-Log ("  descargando... {0:N1}% de {1:N1} GB" -f $pct, ($total/1GB))
            $avisado = Get-Date
        }
        if (-not $todosFin) { continue }

        # Descarga terminada: a partir de aqui manda el disco, que es lo unico
        # que sabe si la extraccion de 11 partes ha acabado.
        $quedan = [int]([math]::Ceiling(($limite - (Get-Date)).TotalMinutes))
        if ($quedan -lt 1) { break }
        return (Wait-Extraccion -Carpetas $Carpetas -TimeoutMin $quedan `
                                -Etiqueta 'descarga completa; extrayendo')
    }

    # Se agoto el plazo. Distinguir el motivo importa: con restos, casi seguro
    # que el archivo pide contrasenya y no se arregla esperando mas.
    foreach ($c in $Carpetas) { if (Test-RestosArchivo $c) { return 'extraccion_fallida' } }
    return 'timeout'
}

function Get-ClaveFuente {
    <#
      Clave con la que se casa un fuente nuestro contra el 'source' de
      completed.jsonl.

      NO vale comparar la ruta tal cual. El panel web renombra TODOS los
      ficheros de encode_queue con un prefijo 'NNN_' cada vez que alguien
      reordena la cola (webpanel/app.py, funcion de mover arriba/abajo), asi
      que la ruta que este script predijo al encolar puede dejar de existir
      sin que nadie se entere. El sintoma seria de los malos: la tanda espera
      hasta agotar el plazo, no encuentra "su" fichero y no borra nada, con el
      encode ya hecho.
    #>
    param([Parameter(Mandatory)][string]$Ruta)
    $n = Split-Path $Ruta -Leaf
    $n = $n -replace '^\d{3}_', ''
    return $n.ToLower()
}

function Wait-Encodes {
    <#
      Espera a que el pipeline termine los ficheros que hemos encolado.

      La fuente de la verdad es encode_logs\completed.jsonl, que encode.ps1
      solo escribe cuando un trabajo acaba BIEN. Se ignora todo lo anterior al
      momento de encolar para no confundirse con una pasada vieja de la misma
      pelicula, y todo lo que no venga de encode_running: subs-watch escribe
      sus registros en el MISMO fichero, con mode='subs_only'.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Fuentes,
        [Parameter(Mandatory)][long]$DesdeTs,
        [int]$TimeoutMin
    )
    $limite   = (Get-Date).AddMinutes($TimeoutMin)
    $hallados = @{}
    $avisado  = (Get-Date)

    $claveDe = @{}
    foreach ($f in $Fuentes) { $claveDe[(Get-ClaveFuente $f)] = $f }

    while ((Get-Date) -lt $limite) {
        if (Test-Path -LiteralPath $CompletedJsonl) {
            foreach ($linea in @(Get-Content -LiteralPath $CompletedJsonl -ErrorAction SilentlyContinue)) {
                if ([string]::IsNullOrWhiteSpace($linea)) { continue }
                $r = $null
                try { $r = $linea | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if (-not $r.source) { continue }
                if ([long]$r.ts -lt $DesdeTs) { continue }
                if ((Split-Path "$($r.source)" -Parent) -ne $Running) { continue }
                $k = Get-ClaveFuente "$($r.source)"
                if ($claveDe.ContainsKey($k)) { $hallados[$claveDe[$k]] = $r }
            }
        }
        if ($hallados.Count -ge $Fuentes.Count) { return $hallados }

        if (Test-Path -LiteralPath $StopFile) {
            Write-Log '  Parada solicitada mientras esperaba al pipeline: dejo los encodes en marcha.'
            return $hallados   # incompleto a proposito: el llamante no borrara nada
        }
        if (((Get-Date) - $avisado).TotalSeconds -ge 300) {
            Write-Log ("  codificando... {0} de {1} listos" -f $hallados.Count, $Fuentes.Count)
            $avisado = Get-Date
        }
        Start-Sleep -Seconds 30
    }
    return $hallados   # incompleto: el llamante lo detecta y no borra nada
}

function Get-ClaveSxE {
    param([int]$S, [int]$E)
    return ('S{0:00}E{1:00}' -f $S, $E)
}

function Get-RestosDeEpisodios {
    <#
      Nombres de los ficheros de una carpeta de descargas que pertenecen a
      unos episodios concretos y NO son video: los .rar de esos episodios y
      la morralla que suele venir con ellos (.sfv, .nfo, .txt).

      Es lo que permite limpiar la tanda sin tocar los .rar de los episodios
      siguientes, que viven en la MISMA carpeta.
    #>
    param(
        [Parameter(Mandatory)][string]$Carpeta,
        [Parameter(Mandatory)][string[]]$Claves
    )
    if (-not (Test-Path -LiteralPath $Carpeta)) { return @() }
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Carpeta -File -Force -ErrorAction SilentlyContinue)) {
        if ($ExtVideo -contains $f.Extension.ToLower()) { continue }
        $sxe = Get-SxE -NombreFichero $f.Name
        if ($sxe.S -le 0 -or $sxe.E -le 0) { continue }
        if ($Claves -contains (Get-ClaveSxE $sxe.S $sxe.E)) { $out += $f.Name }
    }
    return @($out)
}

function Get-TandaAdoptada {
    <#
      Busca trabajo QUE YA ESTA EN MARCHA y lo devuelve como tanda. Devuelve
      $null si no hay nada.

      POR QUE EXISTE: el 08/09/2026, antes de que este script se usara ni una
      vez, habia 6 episodios de la S1 metidos a mano -E01 y E02 codificando,
      E03/E04/E05 en la cola y E06 extrayendose-. Sin esto, la primera
      ejecucion habria pedido 4 episodios MAS al linkgrabber, 102 GB encima de
      los 186 GB libres que quedaban. Tambien cubre el caso normal de volver a
      lanzar el script despues de un corte.

      EL FILTRO NO ES OPCIONAL: solo se adopta lo que casa con -FiltroVideo. En
      encode_running conviven peliculas de otros trabajos, y adoptar una la
      acabaria metiendo en 'Juego de Tronos (2011)\Season 1'.

      Los fuentes de encode_running que YA tienen registro de exito en
      completed.jsonl no se adoptan: son restos de trabajos terminados que la
      red de seguridad de encode-watch todavia no ha reclamado, no trabajo
      pendiente.
    #>
    $yaHechos = @{}
    if (Test-Path -LiteralPath $CompletedJsonl) {
        foreach ($linea in @(Get-Content -LiteralPath $CompletedJsonl -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($linea)) { continue }
            try { $r = $linea | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            # El ultimo registro gana: si un fichero se reintento, la salida
            # buena es la de la ultima pasada.
            if ($r.source) { $yaHechos["$($r.source)".ToLower()] = $r }
        }
    }

    # Fuentes que un encode.ps1 esta procesando AHORA MISMO. Hace falta porque
    # un fichero puede tener un registro VIEJO de exito -de un intento que se
    # rehizo por salir mal- y estar codificandose otra vez: sin esto se le
    # daria por hecho, la tanda se quedaria sin el y nadie recogeria su salida.
    # Paso el 09/09/2026 al reencolar el S02E06.
    $enMarcha = @{}
    foreach ($pr in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
        $cl = "$($pr.CommandLine)"
        if ($cl -notlike '*encode.ps1*') { continue }
        if ($cl -match '-InputFile\s+(.+?\.mkv)') { $enMarcha[$Matches[1].Trim().ToLower()] = $true }
    }

    $enCola     = @()
    $fuentesYa  = @()
    $terminados = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Queue -File -ErrorAction SilentlyContinue)) {
        if ($ExtVideo -notcontains $f.Extension.ToLower()) { continue }
        if ($FiltroVideo -and $f.Name -notmatch $FiltroVideo) { continue }
        $enCola += $f
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $Running -File -ErrorAction SilentlyContinue)) {
        if ($ExtVideo -notcontains $f.Extension.ToLower()) { continue }
        if ($FiltroVideo -and $f.Name -notmatch $FiltroVideo) { continue }
        $reg = $yaHechos[$f.FullName.ToLower()]
        # Si lo esta codificando alguien AHORA, manda eso sobre cualquier
        # registro anterior: se adopta como pendiente y se espera su salida.
        if ($enMarcha.ContainsKey($f.FullName.ToLower())) { $reg = $null }
        if ($reg) {
            # YA codificado y su salida sigue en encoded\: no hay nada que
            # esperar, entra en la tanda directo a la verificacion. Este caso
            # es de lo mas normal -es el estado en que quedan los episodios si
            # el pipeline termino antes de que este script existiera, o si se
            # corto a mitad de una tanda- y si no se recogiera, esas salidas se
            # quedarian en encoded\ para siempre con su fuente ocupando 25 GB.
            $salida = Join-Path $Encoded "$($reg.output)"
            if (Test-Path -LiteralPath $salida) {
                $terminados += [pscustomobject]@{ Fuente = $f.FullName; Reg = $reg }
            } else {
                Write-Log "  (codificado pero su salida ya no esta en encoded\, no lo adopto: $($f.Name))"
            }
            continue
        }
        $fuentesYa += $f.FullName
    }

    # Videos ya extraidos en Descargas. Pueden estar a medio extraer -es el
    # caso de E06 ahora mismo-, asi que el llamante tiene que esperar a que la
    # carpeta quede limpia de .rar antes de encolarlos.
    $pendientes = @()
    $carpetas   = @()
    $dirs = @(Get-ChildItem -LiteralPath $RaizDescargas -Directory -ErrorAction SilentlyContinue)
    if ($Filtro) { $dirs = @($dirs | Where-Object { $_.Name -match $Filtro }) }
    foreach ($d in $dirs) {
        $vids = @(Get-VideosDe $d.FullName | Where-Object { -not $FiltroVideo -or $_.Name -match $FiltroVideo })
        if (-not $vids.Count) { continue }
        $carpetas += $d.FullName
        foreach ($v in $vids) { $pendientes += [pscustomobject]@{ Fichero = $v; Paquete = $d.Name } }
    }

    # Y lo que JD tenga a medio bajar: si hay una descarga viva, ESA es la
    # tanda. Apilarle 4 episodios encima es justo lo que este script existe
    # para no hacer.
    $paquetesJd = @()
    if ($ApiViva) {
        try { $paquetesJd = @(Get-JdPaquetesDescarga) } catch { $paquetesJd = @() }
        # El -Filtro manda TAMBIEN aqui. Sin el se adoptaba cualquier cosa que
        # hubiera en la lista de descargas de JD, incluida una descarga que el
        # usuario haya puesto a mano: paso el 09/09/2026 con una pelicula
        # suelta. El script la tomo por su tanda, se quedo esperandola, vacio
        # la papelera y acabo saliendo del bucle entero porque su video no
        # pasaba el -FiltroVideo. Lo que no es de esta tanda ni se toca ni nos
        # para: se ignora y se sigue con el linkgrabber.
        if ($Filtro) { $paquetesJd = @($paquetesJd | Where-Object { "$($_.name)" -match $Filtro }) }
        foreach ($p in $paquetesJd) { if ($p.saveTo) { $carpetas += "$($p.saveTo)" } }
    }

    if (-not $enCola.Count -and -not $fuentesYa.Count -and -not $terminados.Count -and
        -not $pendientes.Count -and -not $paquetesJd.Count) { return $null }

    return [pscustomobject]@{
        EnCola     = @($enCola)
        FuentesYa  = @($fuentesYa)
        Terminados = @($terminados)
        Pendientes = @($pendientes)
        PaquetesJd = @($paquetesJd)
        Carpetas   = @($carpetas | Select-Object -Unique)
    }
}

# ---------------------------------------------------------------------------
# ARRANQUE
# ---------------------------------------------------------------------------

# Una sola instancia. Misma trampa del PID reciclado que en los watchers, asi
# que se usa la misma funcion y no un Get-Process a pelo.
$otra = Get-OtraInstancia -PidFile $PidFile -Marca 'descargas-tanda.ps1'
if ($otra) {
    Write-Host "descargas-tanda ya esta corriendo (PID $otra) - saliendo."
    exit
}
$PID | Set-Content -LiteralPath $PidFile -Encoding utf8

if (Test-Path -LiteralPath $StopFile) { Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue }

# Si quedo un estado de la vez anterior, es que aquello no termino por su
# cuenta: o corte de luz, o el proceso se fue abajo. Lo unico que se rescata de
# ahi es el TITULO, que es lo que no se puede deducir de ningun otro sitio
# cuando la tanda ya iba por la fase de codificar.
$script:NombreGuardado = ''
$estadoPrevio = Read-EstadoActivo
if ($estadoPrevio) {
    $script:NombreGuardado = "$($estadoPrevio.nombre)"
    Write-Log "RETOMANDO: la ejecucion anterior no termino limpiamente."
    Write-Log ("  iba por la tanda {0}, fase '{1}'{2}" -f $estadoPrevio.tanda, $estadoPrevio.fase,
               $(if ($script:NombreGuardado) { ", titulo '$($script:NombreGuardado)'" } else { '' }))
    if ([int]$estadoPrevio.reintentos -gt 0) {
        Write-Log "  relanzamientos automaticos hasta ahora: $($estadoPrevio.reintentos)"
    }
}

Write-Log '=========================================================='
Write-Log ("descargas-tanda arranca  N=$N  tipo=$Tipo" + $(if ($Nombre) { "  titulo='$Nombre'" } else { '  (titulo = nombre del paquete de JD)' }) + $(if ($Simular) { '  [SIMULACION]' } else { '' }))
Write-Log "  descargas   : $RaizDescargas"
Write-Log "  preparacion : $PrepSeries  (series)  |  $PrepPeliculas  (peliculas)"
Write-Log "  biblioteca  : $RaizSeries  (series)  |  $RaizPeliculas  (peliculas)"
Write-Log "  freno C:    : $MinLibreGb GB   (cierre adelantado por debajo de $LibreParaCerrarGb GB)"

$UsarAdopcion = -not $NoAdoptar
Write-Log ("  adopcion    : " + $(if ($UsarAdopcion) { "SI (filtro de video: $FiltroVideo)" } else { 'NO' }))

# La API NO es motivo de parada por si sola: una tanda adoptada no baja nada y
# por tanto no la necesita, y esa es justamente la primera que se va a lanzar
# aqui -con JD ocupado extrayendo, que es cuando NO conviene reiniciarlo-. El
# error de verdad salta mas abajo, cuando haga falta pedirle episodios.
$ApiViva = Test-JdApi
if (-not $ApiViva) {
    Write-Log 'AVISO: la API local de JDownloader no responde (normal si aun no se ha abierto).'
    Write-Log '       Para bajar tandas nuevas hace falta:  pwsh -File C:\scripts\jd-api-setup.ps1'
    Write-Log '       Sigo: una tanda adoptada no necesita la API.'
}
Read-GbContados
if ($ApiViva) { Clear-GbContadosViejos }
Restore-EnlacesDeLaTanda

if (-not (Test-EncodeWatchVivo)) {
    Write-Log 'ERROR: encode-watch.ps1 no esta corriendo. Sin el, la cola de video no la coge nadie'
    Write-Log '       y este script esperaria hasta agotar el plazo. Arranca el pipeline primero.'
    exit 1
}
if (Test-Path -LiteralPath (Join-Path $Tmp 'encode_hold')) {
    Write-Log 'ERROR: la RETENCION del panel esta puesta (encode_hold). Con ella, un fichero sin'
    Write-Log '       decision explicita de modo en su .opts no arranca nunca. Quitala o este'
    Write-Log '       script se quedaria esperando. Saliendo.'
    exit 1
}
# Las areas de preparacion se crean si no estan: son carpetas de paso y no
# tiene sentido parar por eso. Lo que SI puede faltar y no se arregla creando
# la carpeta es que tmm la tenga como data source; de eso avisa Invoke-Tmm,
# con el nombre del sitio exacto donde anyadirla.
foreach ($a in @($PrepSeries, $PrepPeliculas)) {
    if (-not (Test-Path -LiteralPath $a)) {
        Write-Log "  creo el area de preparacion '$a'."
        if (-not $Simular) { New-Item -ItemType Directory -Force -Path $a | Out-Null }
    }
}

# Todas las comprobaciones pasadas: a partir de aqui el bucle DEBE estar vivo,
# y si desaparece sin borrar este fichero es que se murio sin querer.
Save-EstadoActivo -Fase 'arranque'

$tanda = 0
$fin   = $false

while (-not $fin) {
    $tanda++
    if ($MaxTandas -gt 0 -and $tanda -gt $MaxTandas) { Write-Log "Alcanzado -MaxTandas $MaxTandas."; break }

    Write-Log '----------------------------------------------------------'
    Write-Log "TANDA $tanda"

    if (Test-Path -LiteralPath $StopFile) {
        Write-Log 'Parada solicitada (tandas_stop). Saliendo limpiamente.'
        Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
        break
    }
    if (Test-PipelinePaused $Tmp) {
        Write-Log 'El pipeline esta en PAUSA global. Espero 5 min.'
        Start-Sleep -Seconds 300; $tanda--; continue
    }

    # Antes de nada: cerrar lo que haya quedado a medias de una ejecucion
    # anterior. Es lo que libera C: y lo que hace que la tanda siguiente quepa.
    Close-Restos

    $libre = Get-LibreGb 'C'
    Write-Log "  libre en C: $libre GB"
    if ($libre -lt $LibreParaCerrarGb) {
        # La papelera es medio disco escondido: JD manda ahi los .rar al
        # extraer, asi que hasta que se vacia esos 100 GB no existen.
        Write-Log '  poco espacio: vacio la papelera antes de seguir.'
        Clear-Papelera
        $libre = Get-LibreGb 'C'
        Write-Log "  libre en C: tras vaciar la papelera: $libre GB"
    }

    # --- Elegir la tanda ---------------------------------------------------
    $adoptada = $null
    if ($UsarAdopcion) { $adoptada = Get-TandaAdoptada }

    $carpetas   = @()   # carpetas de descarga implicadas en la tanda
    $videosPend = @()   # videos extraidos que hay que encolar
    $fuentesYa  = @()   # rutas de encode_running ya en marcha
    $terminados = @()   # ya codificados, con su salida esperando en encoded\
    $enCola     = @()   # ficheros ya puestos en encode_queue
    $idsJd      = @()   # paquetes de la lista de descargas de JD
    $nombresJd  = @()   # nombres de fichero segun JD, para el borrado fino
    $claves     = @()   # 'S01E07', ... : los episodios de esta tanda

    if ($adoptada) {
        # ---- TANDA ADOPTADA: no se baja nada ------------------------------
        Write-Log ("  ADOPTO lo que ya esta en marcha: {0} codificando, {1} ya codificado(s), {2} en cola, {3} extraido(s), {4} paquete(s) en JD." -f `
                   $adoptada.FuentesYa.Count, $adoptada.Terminados.Count, $adoptada.EnCola.Count, `
                   $adoptada.Pendientes.Count, $adoptada.PaquetesJd.Count)
        foreach ($f in $adoptada.FuentesYa)  { Write-Log "    - codificando : $(Split-Path $f -Leaf)" }
        foreach ($t in $adoptada.Terminados) { Write-Log "    - ya listo    : $($t.Reg.output)" }
        foreach ($f in $adoptada.EnCola)     { Write-Log "    - en cola     : $($f.Name)" }
        foreach ($p in $adoptada.Pendientes) { Write-Log "    - extraido    : $($p.Fichero.Name)" }
        foreach ($p in $adoptada.PaquetesJd) { Write-Log "    - bajando     : $($p.name)" }
        Write-Log '  esta tanda NO baja nada nuevo: primero se cierra lo que hay.'

        if ($Simular) { Write-Log '  [SIMULACION] fin del ensayo: no se ha tocado nada.'; break }

        $fuentesYa  = @($adoptada.FuentesYa)
        $terminados = @($adoptada.Terminados)
        $enCola     = @($adoptada.EnCola)
        $carpetas   = @($adoptada.Carpetas)
        $idsJd      = @($adoptada.PaquetesJd | ForEach-Object { [long]$_.uuid })

        if ($idsJd.Count) {
            # Hay descarga viva: se le deja terminar, con el mismo criterio de
            # siempre (JD dice 'finished' y luego manda el disco).
            try { $nombresJd = @(Get-JdEnlacesDescarga -PackageIds $idsJd | ForEach-Object { "$($_.name)" }) }
            catch { Write-Log "  aviso: no pude leer los nombres de fichero de JD ($($_.Exception.Message)); la limpieza usara los del disco." }
            # el reloj del SONDEO se pone aqui, que es donde de verdad se intenta
            $script:UltimoIntento = Get-Date
            Resume-TandaEnJd -Ids $idsJd
            $res = Wait-DescargaYExtraccion -Ids $idsJd -Carpetas $carpetas -TimeoutMin $TimeoutDescargaMin
            Suspend-TandaEnJd -Ids $idsJd
            Add-GbDeLaTanda -Ids $idsJd
            if ($res -eq 'estancado' -or $res -eq 'cuota') {
                # No es un fallo del que haya que salir: es un "vuelve luego". Se
                # para JD Y SE QUEDA PARADO -sin dar golpes cada dos minutos contra
                # una cuota agotada, que es lo que hace por su cuenta-, se espera al
                # siguiente sondeo y se reintenta la misma tanda. Eso es lo que hace
                # que esto se recupere solo sin que nadie mire.
                Write-Log $(if ($res -eq 'cuota') { '  CUOTA AGOTADA: el multihoster no da mas por ahora.' }
                            else   { '  DESCARGA ATASCADA: la descarga dejo de avanzar.' })
                Write-Log "  Aparco la tanda y no se toca nada hasta el siguiente sondeo (cada $SondeoCadaMin min desde el ultimo intento)."
                # Ya se aparco arriba, nada mas volver de la espera.
                # Con la descarga aparcada: lo que este entero, a codificar. Que las
                # ranuras no se pasen la espera vacias.
                $adelantados = Move-ListosALaCola -Carpetas $carpetas
                if ($adelantados -gt 0) {
                    Write-Log "  $adelantados episodio(s) ya enteros adelantados a la cola: el encoder no espera a la descarga."
                }
                Save-EstadoActivo -Fase 'descarga estancada' -Tanda $tanda
                if (-not (Wait-EntreSondeos)) {
                    Write-Log '  Parada solicitada. Saliendo sin tocar nada.'
                    break
                }
                $tanda--
                continue
            }
            if ($res -ne 'ok') {
                Write-Log "  La descarga en curso no quedo lista ($res). No se toca ni se borra nada. Saliendo."
                break
            }
        } elseif ($carpetas.Count) {
            # Sin paquetes en JD pero con videos en Descargas: puede haber una
            # extraccion a medias (E06 lo estaba el 08/09). Manda el disco.
            Write-Log '  esperando a que termine la extraccion en Descargas...'
            $res = Wait-Extraccion -Carpetas $carpetas -TimeoutMin $TimeoutDescargaMin
            if ($res -ne 'ok') {
                Write-Log "  La extraccion no termino ($res). No se toca ni se borra nada. Saliendo."
                if ($res -eq 'extraccion_fallida') {
                    Write-Log '  Quedan .rar sin extraer: lo normal es que pidan contrasenya. Miralo en JD.'
                }
                break
            }
        }
        if ($carpetas.Count) { Write-Log '  extraccion completa.' }

        # Se releen los videos: la extraccion pudo terminar de escribir el que
        # estaba a medias, o sacar alguno mas.
        $videosPend = @()
        foreach ($c in $carpetas) {
            foreach ($v in (Get-VideosDe $c)) {
                if ($FiltroVideo -and $v.Name -notmatch $FiltroVideo) { continue }
                $videosPend += [pscustomobject]@{ Fichero = $v; Paquete = (Split-Path $c -Leaf) }
            }
        }
    } else {
        # ---- TANDA NUEVA: N episodios del linkgrabber ---------------------
        if (-not $ApiViva) {
            Write-Log 'ERROR: no hay nada en marcha que adoptar y la API de JDownloader no responde.'
            Write-Log '       Ejecuta una vez:  pwsh -File C:\scripts\jd-api-setup.ps1   (con JD cerrado)'
            break
        }
        if ($libre -lt $MinLibreGb) {
            Write-Log "  Por debajo del freno ($MinLibreGb GB) y sin nada que adoptar. No arranco otra tanda. Saliendo."
            break
        }

        $cola = @(Get-JdPaquetesCola)
        if ($Filtro) { $cola = @($cola | Where-Object { "$($_.name)" -match $Filtro }) }
        if (-not $cola.Count) {
            Write-Log '  No queda nada pendiente en el linkgrabber.'
            Write-Log '  Cierro lo que quede preparado y termino.'
            Close-Restos
            break
        }

        Write-Log "  leyendo los enlaces de $($cola.Count) paquete(s) del linkgrabber..."
        $grupos = @(Get-GruposEpisodio -Paquetes $cola)
        foreach ($g in @($grupos | Where-Object { -not $_.Completo })) {
            Write-Log "    salto '$($g.Base)': $($g.Motivo)."
        }
        $buenos = @($grupos | Where-Object { $_.Completo })
        if (-not $buenos.Count) {
            Write-Log '  No hay ningun episodio completo que bajar. Saliendo.'
            break
        }

        $lote = @()
        $acum = 0.0
        foreach ($g in $buenos) {
            if ($lote.Count -ge $N) { break }
            $gb = $g.Bytes / 1GB
            # Un episodio que por si solo pasa del tope entra igual si es el
            # primero: si no, no entraria nunca y la cola se atascaria.
            if ($lote.Count -gt 0 -and ($acum + $gb) -gt $MaxGbTanda) { continue }
            $lote += $g
            $acum += $gb
        }
        if (-not $lote.Count) { Write-Log '  Ningun episodio cabe en la tanda. Terminado.'; break }

        $necesario = [math]::Round($MinLibreGb + ($acum * $FactorEspacio), 1)
        Write-Log ("  tanda: {0} episodio(s), {1:N1} GB. Hacen falta {2} GB libres y hay {3}." -f `
                   $lote.Count, $acum, $necesario, $libre)
        foreach ($g in $lote) {
            Write-Log ("    - {0}  S{1:00}E{2:00}  {3} partes, {4:N1} GB" -f `
                       $g.Base, $g.S, $g.E, $g.Partes, ($g.Bytes/1GB))
        }

        if ($libre -lt $necesario) {
            Write-Log '  No hay sitio para esta tanda con margen. Vacio papelera y reintento.'
            Clear-Papelera
            if ((Get-LibreGb 'C') -lt $necesario) {
                Write-Log '  Sigue sin haber sitio. Saliendo (baja -N, o deja que se cierren temporadas).'
                break
            }
        }

        if ($Simular) {
            Write-Log '  [SIMULACION] aqui moveria esos enlaces a la lista de descargas y arrancaria JD.'
            Write-Log '  [SIMULACION] fin del ensayo: no se ha tocado nada.'
            break
        }

        # El tope de 24 h se comprueba AQUI, antes de pedirle nada a JD: una
        # vez movidos los enlaces, JD ya esta bajando y parar a mitad deja
        # partes sueltas ocupando disco.
        if (-not (Wait-PresupuestoDescarga -GbNecesarios $acum)) { break }

        # Se mueven los ENLACES, no el paquete: el paquete es la temporada
        # entera y son 255 GB.
        $linkIds = @($lote | ForEach-Object { $_.LinkIds })
        Write-Log "  moviendo $($linkIds.Count) enlace(s) a la lista de descargas..."
        Move-JdALaDescarga -LinkIds $linkIds
        Start-Sleep -Seconds 3

        # Tras el movimiento, los UUID de la lista de descargas NO son los del
        # linkgrabber: hay que releer para saber quien es quien.
        $enDescarga = @(Get-JdPaquetesDescarga)
        if (-not $enDescarga.Count) {
            Write-Log '  ERROR: los enlaces no aparecen en la lista de descargas. Saliendo.'
            break
        }
        # Y el -Filtro OTRA VEZ, que este es el sitio donde hacia danyo de
        # verdad. Get-JdPaquetesDescarga devuelve la lista ENTERA de JD, asi
        # que sin filtrar aqui, una descarga ajena entraba en $idsJd -> su
        # carpeta entraba en $carpetas y su nombre de fichero en $nombresJd,
        # y al cerrar la tanda Remove-RestosDescarga lo borraba, porque borra
        # el nombre que se le da sin mirar la extension. El 09/09/2026 eso
        # apuntaba a una pelicula de 14,2 GB del usuario. Ademas se le cargaba
        # a nuestro presupuesto de 24 h lo que habia bajado otro.
        $enDescarga = @($enDescarga | Where-Object { -not $Filtro -or "$($_.name)" -match $Filtro })
        if (-not $enDescarga.Count) {
            Write-Log "  ERROR: ningun paquete de la lista de descargas casa con '$Filtro'. Saliendo."
            break
        }
        $idsJd    = @($enDescarga | ForEach-Object { [long]$_.uuid })
        $carpetas = @($enDescarga | ForEach-Object { "$($_.saveTo)" } | Where-Object { $_ } | Select-Object -Unique)
        $claves   = @($lote | ForEach-Object { Get-ClaveSxE $_.S $_.E })
        # Los nombres de fichero se capturan AHORA: despues de sacar el paquete
        # de la lista de JD ya no hay a quien preguntarselos, y hacen falta
        # para borrar SOLO los .rar de esta tanda.
        try { $nombresJd = @(Get-JdEnlacesDescarga -PackageIds $idsJd | ForEach-Object { "$($_.name)" }) }
        catch { Write-Log "  aviso: no pude leer los nombres de fichero de JD ($($_.Exception.Message)); la limpieza usara los del disco." }

        # el reloj del SONDEO se pone aqui, que es donde de verdad se intenta
        $script:UltimoIntento = Get-Date
        Resume-TandaEnJd -Ids $idsJd
        Save-EstadoActivo -Fase 'descargando' -Tanda $tanda
        Write-Log "  descargando en: $($carpetas -join ' | ')"

        $res = Wait-DescargaYExtraccion -Ids $idsJd -Carpetas $carpetas -TimeoutMin $TimeoutDescargaMin
        Suspend-TandaEnJd -Ids $idsJd   # aparca lo nuestro; lo del usuario sigue

        Add-GbDeLaTanda -Ids $idsJd

        if ($res -eq 'estancado' -or $res -eq 'cuota') {
            # No es un fallo del que haya que salir: es un "vuelve luego". Se
            # para JD Y SE QUEDA PARADO -sin dar golpes cada dos minutos contra
            # una cuota agotada, que es lo que hace por su cuenta-, se espera al
            # siguiente sondeo y se reintenta la misma tanda. Eso es lo que hace
            # que esto se recupere solo sin que nadie mire.
            Write-Log $(if ($res -eq 'cuota') { '  CUOTA AGOTADA: el multihoster no da mas por ahora.' }
                            else   { '  DESCARGA ATASCADA: la descarga dejo de avanzar.' })
            Write-Log "  Aparco la tanda y no se toca nada hasta el siguiente sondeo (cada $SondeoCadaMin min desde el ultimo intento)."
            # Ya se aparco arriba, nada mas volver de la espera.
            # Con la descarga aparcada: lo que este entero, a codificar. Que las
            # ranuras no se pasen la espera vacias.
            $adelantados = Move-ListosALaCola -Carpetas $carpetas
            if ($adelantados -gt 0) {
                Write-Log "  $adelantados episodio(s) ya enteros adelantados a la cola: el encoder no espera a la descarga."
            }
            Save-EstadoActivo -Fase 'descarga estancada' -Tanda $tanda
            if (-not (Wait-EntreSondeos)) {
                Write-Log '  Parada solicitada. Saliendo sin tocar nada.'
                break
            }
            $tanda--
            continue
        }
        if ($res -ne 'ok') {
            Write-Log "  La tanda no quedo lista ($res). No se toca ni se borra nada. Saliendo."
            if ($res -eq 'parada') {
                Write-Log '  Fue una parada pedida (tandas_stop). Lo bajado se queda y se adopta al volver.'
                Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
            }
            if ($res -eq 'extraccion_fallida') {
                Write-Log '  Quedan .rar sin extraer: lo normal es que pidan contrasenya. Miralo en JD.'
            }
            break
        }
        Write-Log '  descarga y extraccion completas.'

        $videosPend = @()
        foreach ($c in $carpetas) {
            foreach ($v in (Get-VideosDe $c)) {
                if ($FiltroVideo -and $v.Name -notmatch $FiltroVideo) { continue }
                $videosPend += [pscustomobject]@{ Fichero = $v; Paquete = (Split-Path $c -Leaf) }
            }
        }
    }

    # --- La papelera, AHORA --------------------------------------------
    # Justo despues de extraer y antes de encolar: los .rar que JD acaba de
    # reciclar son ~100 GB por tanda que hasta este momento no han liberado ni
    # un byte, y el encode que viene los necesita.
    Clear-Papelera

    # --- A la cola del encoder --------------------------------------------
    if (-not $videosPend.Count -and -not $enCola.Count -and
        -not $fuentesYa.Count -and -not $terminados.Count) {
        Write-Log '  No hay ningun video utilizable en la tanda. No borro nada. Saliendo.'
        break
    }

    # Fuera de la lista de JD ANTES de mover: si se mueve el fichero con el
    # paquete todavia en la lista, JD lo marca como perdido y ensucia la vista.
    if ($idsJd.Count) {
        try { Remove-JdPaquetesDescarga -PackageIds $idsJd } catch {
            Write-Log "  aviso: no pude quitar los paquetes de la lista de JD: $($_.Exception.Message)"
        }
    }

    $desdeTs    = [long][math]::Floor(([DateTimeOffset](Get-Date)).ToUnixTimeSeconds())
    $fuentes    = @()      # TODO lo de la tanda, se espere o no
    $porEsperar = @()      # solo lo que aun tiene que pasar por el pipeline
    $yaListos   = @{}      # fuente -> registro de completed.jsonl
    $duraciones = @{}
    $sxeDe      = @{}
    $paqueteDe  = @{}   # fuente -> nombre del paquete de JD del que salio

    # 0) Lo que ya esta codificado. No se espera: se va derecho a verificar.
    foreach ($t in $terminados) {
        $ruta = $t.Fuente
        $dur  = 0.0
        if (Test-Path -LiteralPath $ruta) { $dur = Get-DuracionSeg $ruta }
        if ($dur -le 0 -and $t.Reg.duration_s) { $dur = [double]$t.Reg.duration_s }
        $duraciones[$ruta] = $dur
        $sxeDe[$ruta]      = (Get-SxE -NombreFichero (Split-Path $ruta -Leaf))
        $yaListos[$ruta]   = $t.Reg
        $fuentes += $ruta
        Write-Log ("  ya codificado: {0}  (S{1:00}E{2:00})" -f `
                   $t.Reg.output, $sxeDe[$ruta].S, $sxeDe[$ruta].E)
    }

    # 1) Lo que ya estaba en encode_running o en la cola. La duracion se mide
    #    AHORA y no al verificar: encode-watch borra los fuentes por su cuenta
    #    cuando C: baja de 100 GB, y sin duracion de referencia la salida no
    #    se podria comprobar.
    foreach ($ruta in $fuentesYa) {
        # $hoja y NO $nombre: esto corre en el ambito del SCRIPT -un bucle no
        # abre ambito nuevo-, y PowerShell no distingue mayusculas, asi que
        # '$nombre' ES el parametro '$Nombre'. Le machacaba el titulo con el
        # nombre del ultimo fichero adoptado, y la tanda acababa yendo a
        # 'E:\Series\Game.Of.Thrones.S02E02...mkv\'. Solo se veia al ADOPTAR,
        # o sea justo al retomar tras un corte de luz (08/09/2026).
        $hoja = Split-Path $ruta -Leaf
        $duraciones[$ruta] = (Get-DuracionSeg $ruta)
        $sxeDe[$ruta]      = (Get-SxE -NombreFichero $hoja)
        $fuentes    += $ruta
        $porEsperar += $ruta
        Write-Log ("  ya codificando: {0}  (S{1:00}E{2:00})" -f $hoja, $sxeDe[$ruta].S, $sxeDe[$ruta].E)
    }
    foreach ($f in $enCola) {
        # encode-watch mueve de encode_queue a encode_running SIN renombrar, asi
        # que la ruta futura del fuente es previsible.
        $ruta = Join-Path $Running $f.Name
        if ($fuentes -contains $ruta) { continue }
        $duraciones[$ruta] = (Get-DuracionSeg $f.FullName)
        $sxeDe[$ruta]      = (Get-SxE -NombreFichero $f.Name)
        $fuentes    += $ruta
        $porEsperar += $ruta
        Write-Log ("  ya en cola: {0}  ({1:N1} GB, S{2:00}E{3:00})" -f `
                   $f.Name, ($f.Length/1GB), $sxeDe[$ruta].S, $sxeDe[$ruta].E)
    }

    # 2) Los recien extraidos.
    $abortar = $false
    foreach ($item in $videosPend) {
        $v   = $item.Fichero
        $dst = Join-Path $Queue $v.Name
        if (-not (Test-FicheroLibre $v.FullName)) {
            # Abierto por otro proceso = extraccion todavia en marcha. Encolarlo
            # aqui le daria al encoder un .mkv a medio escribir.
            Write-Log "  '$($v.Name)' sigue abierto por otro proceso (extrayendose?): paro la tanda."
            $abortar = $true
            break
        }
        if (Test-Path -LiteralPath $dst) {
            Write-Log "  '$($v.Name)' ya estaba en la cola: lo dejo como esta."
        } else {
            # Mismo volumen: rename atomico, sin ventana de fichero truncado.
            Move-Item -LiteralPath $v.FullName -Destination $dst -ErrorAction Stop
        }
        $ruta = Join-Path $Running $v.Name
        if ($fuentes -contains $ruta) { continue }
        $duraciones[$ruta] = (Get-DuracionSeg $dst)
        $sxeDe[$ruta]      = (Get-SxE -NombreFichero $v.Name -NombrePaquete $item.Paquete)
        $paqueteDe[$ruta]  = "$($item.Paquete)"
        $fuentes    += $ruta
        $porEsperar += $ruta
        Write-Log ("  a la cola: {0}  ({1:N1} GB, S{2:00}E{3:00})" -f `
                   $v.Name, ($v.Length/1GB), $sxeDe[$ruta].S, $sxeDe[$ruta].E)
    }

    if ($abortar) {
        Write-Log '  NO se ha borrado nada. Vuelve a lanzarlo cuando JD termine de extraer.'
        break
    }
    if (-not $fuentes.Count) {
        Write-Log '  No hay nada que esperar en esta tanda. Saliendo.'
        break
    }

    # Los episodios de la tanda, para saber DESPUES que .rar son suyos y cuales
    # son de la tanda siguiente, que viven en la misma carpeta.
    foreach ($ruta in $fuentes) {
        $s = $sxeDe[$ruta]
        if ($s.S -gt 0 -and $s.E -gt 0) { $claves += (Get-ClaveSxE $s.S $s.E) }
    }
    $claves = @($claves | Select-Object -Unique)

    # --- Que es esta tanda y adonde va ------------------------------------
    # Se decide AQUI, con los ficheros ya en la mano: el detector de serie
    # necesita ver los nombres reales de los videos, que son los unicos que
    # traen el SxxExx. El titulo sale de -Nombre o del paquete de JD.
    $paqueteTanda = ''
    foreach ($item in $videosPend) { if ($item.Paquete) { $paqueteTanda = $item.Paquete; break } }
    if (-not $paqueteTanda -and $carpetas.Count) { $paqueteTanda = Split-Path $carpetas[0] -Leaf }
    if (-not (Set-ContextoTanda -NombresFichero @($fuentes | ForEach-Object { Split-Path $_ -Leaf }) `
                                -NombrePaquete $paqueteTanda)) {
        Write-Log '  No se de que titulo es esta tanda: no hay -Nombre ni nombre de paquete.'
        Write-Log '  No se coloca ni se borra nada. Vuelve a lanzarlo con -Nombre "Titulo (anyo)".'
        break
    }

    # El titulo de CADA fichero: el de su propio paquete si se sabe -cuatro
    # peliculas en una tanda son cuatro titulos- y si no, el de la tanda, que
    # es lo que toca en una serie, donde los 4 episodios son del mismo titulo.
    $tituloDe = @{}
    foreach ($f in $fuentes) {
        $t = if ($Nombre) { $Nombre }
             elseif ($paqueteDe[$f]) { $paqueteDe[$f] }
             else { $script:NombreTanda }
        foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $t = $t.Replace($c, ' ') }
        $tituloDe[$f] = $t.Trim()
    }

    Save-EstadoActivo -Fase 'codificando' -Tanda $tanda

    # --- Esperar al pipeline ----------------------------------------------
    $hechos = @{}
    if ($porEsperar.Count) {
        $presupuesto = $TimeoutEncodePorFicheroMin * $porEsperar.Count
        Write-Log "  esperando al pipeline (hasta $presupuesto min para $($porEsperar.Count) fichero(s))..."
        $hechos = Wait-Encodes -Fuentes $porEsperar -DesdeTs $desdeTs -TimeoutMin $presupuesto

        if ($hechos.Count -lt $porEsperar.Count) {
            Write-Log "  Solo $($hechos.Count) de $($porEsperar.Count) terminaron dentro del plazo."
            Write-Log '  NO se borra nada. Revisa el panel; el resto sigue en la cola. Saliendo.'
            break
        }
    } else {
        Write-Log '  no hay nada que esperar: toda la tanda estaba ya codificada.'
    }
    # Los que ya venian hechos se suman ahora, con su registro de entonces.
    foreach ($k in $yaListos.Keys) { $hechos[$k] = $yaListos[$k] }

    # --- Verificar ANTES de mover y borrar --------------------------------
    $todoOk    = $true
    $colocadas = @()
    foreach ($f in $fuentes) {
        $reg    = $hechos[$f]
        $salida = Join-Path $Encoded "$($reg.output)"
        $durRef = $duraciones[$f]
        if ($durRef -le 0 -and $reg.duration_s) { $durRef = [double]$reg.duration_s }

        $v = Test-SalidaValida -Salida $salida -DuracionFuente $durRef
        if (-not $v.Ok) {
            Write-Log "  FALLA la verificacion de '$($reg.output)': $($v.Motivo)"
            $todoOk = $false
            continue
        }
        Write-Log "  OK  $($reg.output)  [$($v.Motivo)]"

        $sxe = $sxeDe[$f]
        # La temporada solo hace falta en una SERIE. Una pelicula no tiene, y
        # exigirsela la dejaria tirada en encoded\ para siempre.
        if ($script:TipoTanda -eq 'serie' -and $sxe.S -le 0) {
            Write-Log "    no se pudo determinar la temporada: lo dejo en encoded\ y no borro su fuente."
            Write-Log "    (si esto es una pelicula, lanza con -Tipo pelicula)"
            $todoOk = $false
            continue
        }
        $puesto = Move-APreparacion -Salida $salida -Titulo $tituloDe[$f] `
                                    -Temporada $sxe.S -Episodio $sxe.E
        if (-not $puesto) { $todoOk = $false; continue }
        $colocadas += $puesto
    }
    if (-not $todoOk) {
        Write-Log '  Algo no paso la verificacion o no se pudo colocar: NO se borra nada. Saliendo.'
        break
    }

    # --- Limpiar la tanda --------------------------------------------------
    Write-Log '  todo verificado y colocado; limpiando la tanda.'
    foreach ($f in $fuentes) {
        # La ruta buena es la que dice el registro de completed.jsonl, no la
        # que este script predijo: si el panel reordeno la cola, el fichero
        # lleva un prefijo 'NNN_' y esta en otro sitio del que creiamos.
        $real = $f
        if ($hechos[$f] -and $hechos[$f].source) { $real = "$($hechos[$f].source)" }
        if (-not (Test-Path -LiteralPath $real)) { continue }
        if (-not (Test-FicheroLibre $real)) {
            Write-Log "    '$real' sigue abierto por otro proceso: no lo borro."
            continue
        }
        $null = Remove-Seguro $real
    }
    foreach ($c in $carpetas) {
        # Los nombres que dio JD MAS los que quedan en disco y son de estos
        # episodios. Los .rar de los episodios siguientes no estan en ninguna
        # de las dos listas y por eso sobreviven.
        $restos = @($nombresJd) + @(Get-RestosDeEpisodios -Carpeta $c -Claves $claves)
        Remove-RestosDescarga -Carpeta $c -Ficheros @($restos | Select-Object -Unique)
    }
    Clear-Papelera

    Save-EstadoActivo -Fase 'cerrando' -Tanda $tanda

    # --- Cerrar: metadatos, copia a la biblioteca y borrado de C: ---------
    if (-not (Close-Preparacion -Colocadas $colocadas)) {
        Write-Log '  El cierre no fue limpio: lo preparado se queda en C:. Saliendo.'
        break
    }

    $libreFin = Get-LibreGb 'C'
    Write-Log "  tanda $tanda cerrada. Libre en C: $libreFin GB."
    # Una tanda cerrada entera demuestra que el bucle funciona: se perdona la
    # cuenta de relanzamientos para que un corte de luz de la semana que viene
    # no herede el cupo gastado por el de hoy.
    Save-EstadoActivo -Fase 'cerrada' -Tanda $tanda -Reintentos 0
    try {
        $h = @{ ts = [long][math]::Floor(([DateTimeOffset](Get-Date)).ToUnixTimeSeconds())
                tanda = $tanda; ficheros = $fuentes.Count
                colocadas = @($colocadas | ForEach-Object { Split-Path $_ -Leaf })
                libre_gb = $libreFin }
        Add-Content -LiteralPath $HistFile -Value ($h | ConvertTo-Json -Depth 5 -Compress) -Encoding utf8
    } catch { }

    if ($UnaTanda) { Write-Log 'Pedida una sola tanda (-UnaTanda). Fin.'; $fin = $true }
}

Write-Log 'descargas-tanda termina.'
# Salida NORMAL: se retira la senyal de "deberia estar vivo" para que el
# keepalive no lo resucite. Si el equipo se apaga de golpe, esta linea no llega
# a ejecutarse, el fichero se queda, y por eso se relanza solo al volver.
Remove-EstadoActivo
Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
