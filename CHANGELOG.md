# Changelog — MediaBox (HTPC Encode Pipeline & Webpanel)

Formato libre por sesión de trabajo (no SemVer: esto es un pipeline casero,
no una librería versionada). Cada entrada resume el `TRASPASO_*.md`
correspondiente, que queda en la raíz con el detalle completo.

## 2026-09-21 — Perfil 'icq-red': ICQ con red a posteriori (la única "mezcla" ICQ/QVBR posible)

- **Target 4K 9,5/9,0 → 9,0/8,5 y suelo 4K 8,5 → 8,0** (noche, a petición
  del usuario; DD+ se deja como está). Datos: de las 42 películas 4K desde el
  02/09, 35 van pegadas al target (≥90 %), así que −0,5 M muerde: ~−4 %
  (13 GB sobre 327). Bajo `icq-red` es también el límite de la red, o sea que
  más películas caerán a `techo`. El suelo baja con el target o anularía el
  SDR (la trampa del 27/08). Referencia visual: 8,5 fue «un poco, casi nada»
  en el tramo más duro de *El atlas*; 9,0 está en el borde de lo aceptado.
  Espejos de `ab-test.ps1`, `av1-vs-hevc.ps1` e `icq-probe.ps1` a 9.0M /
  12.2M / 18M (la batería los cazó los tres). Verificado ejecutando: `target=9M
  maxrate=12.2M bufsize=18M`, y en QVBR forzado `-b:v 9M`.
- `icq_red_informe.py` (nuevo): informe de la red ICQ por película (hitos,
  final, ratio, resultado), tasa de trabajo tirado y error de la proyección
  por hito con el margen que habría bastado. Es lo que hay que pasar antes de
  tocar `$IcqRedHolgura` o los márgenes del aborto.
- **Hitos del vigilante en el log** (noche). Cada pasada ICQ escribe al
  25/50/75 % su media, la relación con el límite y el CV del bitrate por
  tramos de 10 s (`RED ICQ: hito 50 %: media 5.93M (limite 9.5M, x0.62), CV
  39 %`). Es la materia prima para afinar los márgenes del aborto con datos
  propios (hoy n=3 del 26/08) y decidir si conviene codificar ICQ y `techo`
  a la vez en las dos ranuras (compensa si se repite más de ~1 de cada 3).
  Verificado con un clip de *Mystic River*. Primer dato real: *Gremlins 2*
  abortó al 50 % (11,22 M contra 9,5 × 1,12): media pasada ahorrada.
- **Holgura de la red a 1,03** y arreglo de etiqueta (noche). *Sangre por
  sangre* se repitió entera (30 min) por pasarse 0,03 M (9,53 contra 9,5) y la
  repetición salió a 9,45: el mismo fichero. Con 1,03 no se repite por un pelo,
  a cambio de hasta un 3 % sobre el target. Y en el camino clásico se pasaba
  `$IcqAbortFrac` a `$PasarATecho` aunque no hubiera aborto: el log decía
  «abortada al 0 %» y el jsonl `abortado` en una repetición normal (corregido
  el registro de *Sangre por sangre* a `repetido`). *Gremlins 2* y *John
  Carter* se han borrado y reencolado para que pasen por la regla nueva.
- **Aborto temprano de la pasada ICQ** (noche). Cuando la media parcial va
  claramente por encima del target no hace falta acabar la pasada para saber
  que se repetirá: `$WaitFfmpegPass` lee `encode_ffprog` cada 10 s (out_time y
  frames, el mayor de los dos, como app.py) y mata ffmpeg si la media supera el
  límite × 1,30 entre el 25 y el 50 % del metraje, o × 1,12 entre el 50 y el
  75 %; nunca antes del 25 % ni después del 75 %. Los márgenes salen del error
  medido de la proyección en ICQ el 26/08 (27,6 % al 25 %, 8,8 % al 50 %, en
  los dos sentidos; n=3). Un aborto en falso cuesta el ahorro de ICQ de esa
  película, no abortar cuesta solo tiempo. Registro: `icq_red: 'abortado'` con
  `icq_video_mbps` = media PARCIAL. Verificado con una copia del script a GQ 12
  sobre 5 min del original de *Gremlins 2* por los dos caminos (clásico: aborto
  al 27 %; solapado con DEE: al 31 %), repetición en `techo` reutilizando el
  `.ec3`. Suite en verde, restos limpiados.
- **x265 por CPU, medido para descartarlo como vía "rápida"**: 20 s de 4K 10
  bits (*John Carter*, original) con `libx265 -preset medium -crf 20` en el
  i7-12650H: **1,36 fps** (con un encode QSV al lado, que usa 1/3 de núcleo).
  *El Bueno* (256.942 fotogramas) serían **~50 h** frente a los **29,5 min** de
  la GPU (145 fps): unas 100 veces más lento. `slow` se canceló: no aporta
  nada a la conclusión. Sin medir la calidad/tamaño a igual calidad visual
  (típicamente 20-40 % menos que HEVC por hardware); solo importaría si el
  espacio pesara más que el tiempo, y no es el caso.
- *Gremlins 2* y *John Carter* arrancaron a las 15:56 (dos ranuras) ANTES de
  la corrección del límite: Gremlins 2 quedó en ICQ a 10,93 Mbps → 9,1 GB
  (`techo` habría dado ~7,7). Son las dos últimas con la regla vieja.
- **La red compara contra el TARGET, no contra el techo de 16 GiB** (misma
  sesión, más tarde). El primer trabajo real destapó el fallo de diseño: *El
  Bueno, el Feo y el Malo* (179 min) salió a **15,0 GB** (ICQ GQ 19 a 10,77
  Mbps, dentro del techo de 11,5 M para ese metraje) donde `techo` había dado
  11,9 GB (8,64 Mbps). La red frenaba el disparo grande pero dejaba crecer el
  grano hasta `$CeilGb`, que no es lo pedido ("que no penalice tanto el
  grano"). Ahora `$IcqRedLimite = min(techo de tamaño, fuente, $Target)` y
  `$IcqRedHolgura = 1.0`: ICQ donde ahorra, `techo` donde ICQ engordaría; el
  fichero no sale mayor que con `techo` (salvo el ~10 % de relleno que `techo`
  deja sin usar). Verificado con un clip de Sad Hill: ICQ 20,12 M > 9,5 M →
  repetido en `techo` (`GQ=15 -b:v 9.5M`, 9,45 M). Esa película hay que
  reencodearla desde el original si se quiere recuperar el tamaño.
- **GQ de ICQ en 4K: 18 → 19** (misma sesión, después). El usuario preguntó si
  se podía "bajar un poco el grano" y se midió sobre el UHD ORIGINAL de *El
  Bueno, el Feo y el Malo* (34 GB, grano de 35 mm), dos tramos de 60 s en ICQ
  con los args de producción: el denoise, de 0 a 20, mueve el **0,2 %** en Sad
  Hill y el 0,8 % en el nocturno (no muerde el grano grueso; en *Obsession* y
  *El atlas* sí porque era ruido fino), mientras que GQ 19 ahorra −9,5 % y
  −12,8 %. Decidido mirando recortes 1:1 de fuente / GQ18 / GQ19 / dn0 / dn20.
  El denoise se queda en 7. Verificado ejecutando `encode.ps1` (`-global_quality
  19`, `gq: 19` en el jsonl). El 1080p sigue en GQ 15.

- Se pidió mezclar lo bueno de ICQ (reparte por complejidad, no infla lo
  fácil) con lo bueno de QVBR (tamaño acotado). Dentro de ffmpeg/QSV NO
  existe: está medido que cualquier opción de bitrate saca al encoder de ICQ y
  que proyectar el tamaño a mitad de encode falla (26/08). Lo que sí: encodear
  el vídeo en ICQ y, cuando termina, medir lo gastado contra las reglas duras
  que ya existían —techo de `$CeilGb` escalado por duración y "nunca más que la
  fuente"—; si se pasa (con `$IcqRedHolgura` = 1,05), se repite SOLO el vídeo
  en 'techo' con el target que 'techo' habría usado. El audio ya convertido
  (.ec3) se reutiliza por el mismo camino de respaldo que ya existía para la
  pasada de vídeo fallida. Peor caso = lo de hoy + la pasada tirada.
- `$CfgPerfil4K` y `$CfgPerfil1080p` a `'icq-red'`. Con 'icq-red' la guarda
  previa del 27/08 ya no anula ICQ por 'techo de tamaño' (la red lo vigila
  después y las largas son donde ICQ más gana); sí sigue anulándolo por 'tope
  70%' y 'bitrate de la fuente' (fuentes pobres, donde ICQ gasta más que el
  original y repetir sería tirar una pasada segura). `-RateMode icq` a mano
  sigue siendo ICQ puro, sin red.
- **Fallo latente arreglado**: al anular ICQ (guarda o `-TargetMbps`) solo se
  tocaba `$UseRateCap` y `$CfgPerfil` seguía en 'icq', así que en 4K se habría
  emitido `-b:v` con GQ 18 en vez de 15 y `completed.jsonl` habría dicho
  `rate_mode: icq` en un trabajo QVBR. Dormido mientras las dos ramas estaban
  en 'techo'. Ahora `$CfgPerfil` cambia con el modo y el GQ se recalcula.
- `completed.jsonl`: campos nuevos `icq_red` ('' | 'ok' | 'repetido') e
  `icq_video_mbps` (lo que gastó el vídeo ICQ, se quedara o no). `rate_mode`
  sigue siendo 'icq' | 'techo' según el régimen REAL de la salida.
- Verificado ejecutando `encode.ps1` de verdad sobre clips de 90 s (4K con
  EAC3 → camino clásico; 4K con FLAC → camino solapado con DEE; 1080p) en las
  dos direcciones: 'ok' con el script de producción y 'repetido' con una copia
  con `$CeilGb` minúsculo (el comando de la segunda pasada salió `-global_quality
  15 -b:v 8.5M -maxrate 11.5M`, reutilizando el `ddp_*.ec3`). También
  `-TargetMbps 6` → `QVBR GQ=15`, `rate_mode: techo`. Suite `correr-todo` en
  verde. Restos limpiados (salidas, logs, 5 líneas del jsonl, caché DDP).
- (Superado por la corrección de la tarde: con el target como límite, este
  riesgo desaparece.) Lo que cambiaba de riesgo con la primera versión: en
  1080p el peor caso ya no era el target de 5,0 sino el techo de 12 GiB. Un 1080p con grano a GQ 15 pide
  15-17 Mbps (Traffic: 17,25 en el clip); a 147 min se pasa del techo y la
  red lo devuelve a 'techo', pero a 100 min cabe (~11 GiB) y se queda. Si eso
  no gusta, la palanca es `$CfgPerfil1080p = 'techo'` (una línea).

## 2026-09-15 — Remux: la pasada por imagen se hacía DOS veces y el panel prometía 199 s

- Con todas las casillas marcadas, `measure()` baja la escalera (paquetes →
  subtítulos → imagen) y, si la imagen no engancha, el endpoint
  `/api/remux/measure` volvía a lanzar la MISMA pasada de imagen entera como
  "segunda opinión" (solo se la ahorraba si `fallback == "video"`, o sea si
  había ENGANCHADO). Medido con Influencer (2022): dos pasadas de ~9 min con
  resultado idéntico, dentro de una medición anunciada como "~199 s".
  `measure()` acepta ahora `intentos=dict` y anota lo que midió cada peldaño;
  el endpoint lo reutiliza (también los subtítulos) y devuelve `reutilizado`.
- Los 199 s eran 4 puntos con ventana ±30 s. Si las duraciones difieren la
  ventana crece (dif×1,2+30, tope 300 s → hasta 3,2× por punto) y si los lags
  discrepan se remide con 16 puntos (×5). El aviso del panel lo calcula ahora
  con las duraciones de los dos ficheros y da una horquilla real.
- Descartado, medido: no es contención (2,5 núcleos de 16 ociosos);
  `-skip_loop_filter` da 10 %, QSV nada, `-skip_frame nokey` 5× pero deja la
  serie a escalones de un GOP. En H.264 `-skip_frame bidir` es incluso más
  lento en reloj que decodificar entero (4,2 vs 3,1 s) porque pierde el
  paralelismo por fotogramas; se mantiene porque usa 2 núcleos en vez de 11.

## 2026-09-14 (tarde) — Revisado el camino de PELICULAS: dos fallos reales, nunca usado a fuego

- El usuario bajó/codificó/scrapeó/colocó 4 películas a mano; aproveché para
  revisar `descargas-tanda.ps1` en ese camino, que hasta hoy solo se había
  probado con la serie. Aparecieron dos fallos que lo habrían dejado atascado
  la primera vez que se usara de verdad:
  - **`Get-TmmIndiceDataSource` leía `tmm.prop`**, que para películas solo
    guarda UN valor (el último tocado en el diálogo de añadir carpeta:
    `E:\Peques`). La lista real que usa la CLI para `--updateX` —su propia
    ayuda lo dice, *"the same order as in the UI/settings"*— vive en
    `movies.json`/`tvShows.json`. Con una sola área de series esto no se
    notaba (las dos fuentes coincidían por casualidad); con las CUATRO áreas
    de películas que hay registradas de verdad, el índice salía siempre mal o
    en 0 y tmm nunca habría raspado una película, en silencio. Reescrita para
    leer del JSON.
  - **`Get-GruposEpisodio` rechazaba un enlace suelto sin RAR** ("no reconozco
    el esquema de partes") — justo como bajan las películas en esta máquina
    ahora mismo: JD las trae como un link directo de 1fichier
    (`Magnolia (1999)`, `Orígenes (2014)`...), sin `.part01.rar` ni nada
    parecido. El script nunca las habría movido a la lista de descargas.
    Arreglado: un enlace solo en su grupo, sin esquema de partes reconocible,
    es un fichero de una sola pieza — no una descarga a medias.
- Nueva batería `pruebas\test-peliculas-tmm.ps1` (20 comprobaciones, las dos
  correcciones verificadas por mutación), registrada en `correr-todo.ps1`.
  Suite completa en verde: 15 baterías.
- **Queda un paso manual, una sola vez**: registrar
  `C:\Users\HTPC\Videos_Peliculas` como fuente de datos de películas en tmm
  (Configuración > Películas > Fuentes de datos) — no toqué la configuración
  de tmm por mi cuenta. Sin eso, `Invoke-Tmm` avisa y no raspa, pero no pierde
  nada: sin `-SeguirSinMetadatos` la tanda se queda aparcada en C: hasta que
  se resuelva, no se borra nunca a ciegas.

## 2026-09-14 — Juego de Tronos completa (73/73) y estreno de las guardas de Atmos

- **El bucle de tandas terminó solo** a la 01:24:50 con *"No queda nada pendiente
  en el linkgrabber"*: 73 episodios en `E:\Series\Juego de Tronos (2011)`,
  ocho temporadas. Desde el 07/09: 1,72 TB bajados en tandas que nunca pasaron
  de ~105 GB en C:, 73 codificaciones verificadas pista a pista, dos cortes de
  luz/reinicios superados por el keepalive, y la cuota diaria de Real-Debrid
  (~300 GB, reseteo a medianoche) gestionada por sondeo sin intervención.
- El último episodio arrancó solo a las 00:49 tras el reseteo; la tarea de
  respaldo de las 00:53 lo comprobó, no tocó nada y se borró sola.
- **S08E06 fue el primer trabajo con las verificaciones nuevas de Atmos**, y
  las pasó: `[truehdd info]` (Atmos true, 4 substreams), `DAMF de a:0: 16,0
  canales`, `integridad 4.716,9s contra 4.716,8s`, `verificado: .ec3 con JOC y
  15 objetos`.
- Y esa evidencia recién estrenada destapó que el log del dialnorm mentía:
  truehdd dice `Dialogue Level -37 dBFS` y el pipeline apuntaba
  `custom_dialnorm=-31 (Dialogue Level del master)`. Era el tope de DEE, no el
  máster — y por eso todas las pistas del 04/08 decían "-31 del master". El
  valor no puede ser otro; el log ahora dice que se recortó y desde cuánto.

## 2026-09-13 — La ruta TrueHD Atmos → DD+ JOC verificaba solo la duración

- **Incidente:** *Robot salvaje* y *Cómo entrenar a tu dragón (2025)*, las dos
  con doble pista TrueHD Atmos convertidas por `audio_encode.ps1` el 4-5/08,
  llegaron a la biblioteca con la **segunda pista sin Atmos efectivo**: la barra
  de sonido reconoce Atmos en la castellana y no marca nada en la inglesa, en
  Direct Play, con Plex y con Jellyfin. ffprobe, MediaInfo (parseo completo) y
  un recorrido trama a trama del bitstream no distinguen las dos pistas: JOC,
  15 objetos, cabeceras idénticas, cero errores de decodificación. Lo que
  difiere está en el contenido de los metadatos de objetos, que solo lee un
  decodificador Dolby. **Mandalorian**, que sí funciona en las dos pistas, no
  pasó por DEE: su fuente ya traía DD+ Atmos y `encode.ps1` lo copió.
- **La pista de qué pasó** está en el log del 04/08: la pista 0 dejó 21,9 GB de
  temporales y la pista 1 **15,6 GB** con la misma duración. Un DAMF de 16
  canales (objetos) son 17,3 GB; 15,6 cuadra con uno de 10 (7.1.2). truehdd
  decodificó la segunda pista a un máster más pobre y DEE lo codificó igual.
  Dos comentarios del código ya hablaban de *"el fallo de la 2ª pista Atmos"*
  con un `GC + Sleep` de parche y sin causa.
- **Por qué nadie lo vio:** la única verificación de la salida era la duración
  del `.ec3`, y la salida de truehdd (qué presentación decodificó) se borraba
  con los temporales si todo "salía bien".
- **Arreglos en `atmos-lib.ps1`:**
  - `Write-TrueHDInfoLog`: `truehdd info` de cada pista al log del trabajo
    (presentaciones, canales, Atmos, dialnorm).
  - `Write-TruehddSalidaLog`: la salida de `truehdd decode` se conserva en el
    log —sin progreso ni `drc_start_up_gain`— también cuando termina bien, en
    los dos caminos (tubería y `.thd`).
  - `Get-DamfCanales`: canales del máster decodificado, medidos por el tamaño
    del `.atmos.audio` (PCM 24 bits/48 kHz). Se apuntan por pista y se devuelven
    al llamante (`$script:DdpUltimoDamfCanales`; el hijo paralelo los mete en su
    JSON de resultado).
  - `Test-Ec3EsJoc`: MediaInfo sobre el `.ec3` tras DEE. Sin JOC o con 0
    objetos → **fallo alto** (`DdpLastFailure='sinjoc'`), no entra en la caché y
    el llamante conserva la pista TrueHD original en vez de meter un Atmos roto.
- **`audio_encode.ps1`:** compara los canales del DAMF entre las pistas Atmos de
  la misma película y avisa ALTO si difieren en ≥1,5 (no aborta: un doblaje
  puede traer menos objetos legítimamente). Y el `.ec3` por trabajo lleva ahora
  `$PID`: sin él, dos películas de la granja arrancando el mismo segundo se
  pisaban `a_ddp_<sello>_<N>.ec3` — la familia del cruce del 08/09.
- **Pruebas** en `test-ayudantes.ps1`: 22 comprobaciones nuevas, con audio real
  (un E-AC-3 plano de ffmpeg rechazado, el JOC real de Mandalorian aceptado con
  sus objetos) y un MediaInfo falso en `.ps1` para el caso "JOC con 0 objetos"
  que no se puede fabricar. **4 mutaciones, todas detectadas.** Guardas
  estáticas por AST para que nadie pueda quitar la verificación de
  `Convert-TrueHDToDDP` sin que salte. Trampa del andamiaje: un falso en `.cmd`
  no vale, porque `cmd.exe` lee el `|` del `--Inform=` como tubería.
- Sin reiniciar nada: cada trabajo carga la librería en su propio `pwsh`. El
  primero con las guardas nuevas será el S08E06 de Juego de Tronos esta noche.
- **Sin arreglar y sin arreglo posible:** las dos películas afectadas. No queda
  el TrueHD original y de un `.ec3` no se recupera el máster.

## 2026-09-11 — El presupuesto pasa a contar por día natural

- **Consecuencia directa de haber entendido la cuota.** Nuestro tope usaba una
  ventana **deslizante de 24 h** y Real-Debrid usa el **día natural**, así que
  la cuenta no se parecía a nada: a las 00:28, con la cuota de RD recién
  renovada y bajando a 45 MB/s, nuestro presupuesto decía «307,9 de 320» y
  mandaba la tanda a esperar un sondeo de dos horas para nada.
- `Get-GbDescargadas24h` → **`Get-GbDescargadasHoy`**, cortando en
  `(Get-Date).Date`. Se renombra en vez de sólo cambiar el corte: una función
  llamada `...24h` que cuenta el día sería una mentira, y aquí los nombres que
  mienten ya han costado caro.
- Efecto inmediato: la tanda arrancó al instante (`6,8 de 320,0 GB usados hoy`)
  en lugar de esperar a las 02:04. Y ahora el tope vuelve a significar algo:
  con `-MaxGbDia` cerca de los ~300 GB reales, frena **antes** de chocar.
- **Pruebas:** la batería del presupuesto pasa a probar el día natural. La
  comprobación clave usa una entrada de **ayer a las 23:59**: con ventana
  deslizante contaría y con día natural no, así que distingue de verdad los dos
  comportamientos en vez de dar por bueno cualquiera. 2 mutaciones detectadas
  (volver a la ventana deslizante, y contar también lo de ayer).

### Y una parada que necesitó mano

Al cerrar la tanda de S04E06–E09 el bucle **salió solo**: la siguiente tanda de
4 pedía 342,4 GB libres y había 338,4 — corto por **4 GB**, con `-FactorEspacio
2.1`. Como es una salida normal, borra su fichero de estado y el keepalive
(correctamente) no lo relanza.

Se relanzó con **`-N 3`**, que es el remedio que sugiere el propio script y no
toca el margen de seguridad. Con la cuota diaria de ~300 GB el rendimiento no
cambia: 4 tandas de 79 GB en vez de 3 de 105.

Se comprobó antes que **no hay fuga del pipeline** —`encode_queue`,
`encode_running`, `encoded`, el área de preparación y la papelera, todos a
cero—. La bajada de C: durante el día (353 → 338 GB) es la carpeta `Downloads`
del usuario (8,6 → 19,2 GB) y el crecimiento del log de encodes.

## 2026-09-10 — Adelantar a la cola lo que ya está entero cuando la descarga se atasca

- **El problema, medido:** la cuota del multihoster cortó la tanda 4 con **3 de
  4 episodios ya extraídos** y 6,8 GB pendientes del cuarto. Las dos ranuras de
  codificación se quedaron **vacías 5 horas y media** esperando esos 6,8 GB. El
  encode es el cuello de botella (56 min por tanda frente a 27 de descarga), así
  que esas horas no se recuperan después.
- **`Get-VideosListosDe`** decide qué está entero **por episodio, no por
  carpeta**: todos los episodios de una temporada comparten `saveTo`, así que
  preguntar «¿quedan `.rar` en la carpeta?» contestaría que no hay nada listo
  mientras al último le falten partes — justo el caso a resolver. Un vídeo sin
  `SxxExx` reconocible (una película suelta) no se puede separar de sus restos,
  así que se le exige lo más duro: que no quede ningún archivo en la carpeta.
  Y siempre `Test-FicheroLibre`: un `.mkv` abierto se está extrayendo.
- **`Move-ListosALaCola`** los mueve a `encode_queue` (rename en el mismo
  volumen, atómico) desde las dos ramas de atasco, con JD ya parado.
- **Por qué es seguro, que era el riesgo:** no lleva ninguna contabilidad de lo
  adelantado. Al reintentar la tanda, `Get-TandaAdoptada` los encuentra en
  `encode_queue` (o en `encode_running`, o ya codificados) y los incorpora por
  las ramas que **ya existían y ya estaban probadas**. Sus claves salen de ahí
  igual que si se hubieran encolado todos a la vez, así que la limpieza del
  final sigue cubriendo los cuatro episodios. No se tocó el cierre.
- **Pruebas:** 14 comprobaciones nuevas en `test-sondeo.ps1` (44 en total), y
  **5 mutaciones, todas detectadas**: mirar los restos por carpeta en vez de por
  episodio, saltarse el fichero abierto, ignorar el `-FiltroVideo`, adelantar un
  vídeo sin `SxxExx` con archivos al lado, y saltarse el freno de `-Simular`.
  Fichero restaurado y verificado por hash SHA256.
- **Aparcar la tanda sin parar JDownloader entero.** `downloadcontroller/stop`
  es **global**: mientras la tanda esperaba al multihoster, el usuario se bajaba
  un fichero suyo, y si el sondeo hubiera caído en ese momento le habría parado
  la descarga sin avisar. Es el mismo problema que el `-Filtro` resolvió por el
  otro lado —«no adoptes lo que no es tuyo»— en versión «no pares lo que no es
  tuyo».
  - `Set-JdEnlacesActivos` (`downloadsV2/setEnabled`) en `jd-lib.ps1`.
  - `Suspend-TandaEnJd` desactiva **sólo nuestros** paquetes y para el
    controlador **únicamente** si no queda nada más pendiente; así, cuando el
    script está solo, el comportamiento visible es el de siempre.
  - `Test-JdOtrosPendientes` ante cualquier duda contesta «sí hay»: equivocarse
    por ese lado deja JD corriendo sin nada que hacer, que no molesta a nadie;
    equivocarse por el otro para las descargas del usuario.
  - Si `setEnabled` falla se cae al comportamiento antiguo: mejor parar de más
    que dejar a JD dando golpes contra una cuota agotada.
  - **`Restore-EnlacesDeLaTanda` es la red de seguridad**: si el script muere con
    la tanda aparcada (corte de luz, un kill), sus enlaces se quedan
    DESACTIVADOS y en silencio — JD no los bajaría nunca y el log no diría por
    qué. Al arrancar se reactiva todo lo que casa con `-Filtro`. Una parada
    global se ve; unos enlaces desactivados, no.
- **Pruebas:** 14 comprobaciones más (58 en total) y **5 mutaciones detectadas**:
  parar el controlador aunque el usuario tenga descargas, contar como pendiente
  lo ya terminado, concluir «no hay otros» ante un fallo de la API, no reactivar
  al reanudar, y quedarse sin parar nada cuando `setEnabled` falla.

## 2026-09-09 (tarde) — Sondeo cada 2 h en vez de esperar a la ventana de 24 h

- **Punto de partida:** el tope de 24 h es un **cálculo nuestro**, no el límite
  de Real-Debrid. Se comprobó a mano que con 203 GB gastados y el tope en 300
  la cuenta bajaba de 1fichier sin problema: el bucle se habría quedado 12 h
  parado para nada.
- **Cambio:** cuando el tope bloquea, en vez de esperar a que la ventana se
  vacíe se **sondea**: pasados `-SondeoCadaMin` (120 por defecto) desde el
  último intento se lanza la tanda igualmente y contesta el multihoster. Si la
  ventana libera sitio antes, se arranca ya: vale lo que llegue primero.
- **El reloj cuelga del último INTENTO, no del inicio de la espera.** Una tanda
  adoptada —la que reanuda una descarga ya en marcha— no pasa por el
  presupuesto, así que se pone en `Start-JdDescargas`, que es donde de verdad
  se intenta. Con el reloj en `Wait-PresupuestoDescarga` se habría quedado en
  la hora de arranque del script y `Wait-EntreSondeos` no habría esperado nada:
  reintentos sin parar contra una cuota agotada.
- **La cuota, preguntada y no deducida.** `Test-CuotaMultihoster` lee el
  `status` de los enlaces, donde JD lo dice con todas las letras:
  `Multihoster: real-debrid.com: Wait 2m:27s Reason: Fair usage limit reached`.
  Se sabe en **16 segundos** en vez de en los 45 min que tardaba el detector de
  atasco, y distingue "la cuota está agotada" de "este enlace está muerto".
  Exige que estén **todos** los pendientes en ese estado.
- **Por qué no se deja que JD insista:** medido: cuenta atrás 2m27s → 1m05s →
  19s, reintenta, falla, y le dan **4m37s**. El castigo crece. Así que se para
  JD y se queda parado hasta el siguiente sondeo.
- **Dos ventanas de atasco, no una.** Mientras no ha entrado ni un byte manda
  `-EstancadoInicialMin` (10); en cuanto entra el primero, `-EstancadoMin` (45).
  Lo primero mide si el multihoster contesta, lo segundo si una descarga que ya
  iba se paró.
- **La contabilidad pasó a contar el INCREMENTO, no el total.** Contar el
  `bytesLoaded` entero del paquete valía cuando `Add-GbDeLaTanda` se llamaba una
  vez por tanda; con el sondeo se llama en cada intento, así que los 20 GB ya
  bajados del episodio a medias se apuntaban **otra vez cada 2 horas**. A las 9
  de la mañana el registro habría dicho 430 GB sin haber bajado ni uno más — y
  ese registro es justo el que sirve para saber cuánto da de sí el multihoster.
  Se lleva la cuenta por UUID de paquete, y nunca resta (JD reinicia el contador
  de un enlace que reintenta desde cero, y restar eso sería regalarse cuota).
- **El contador se persiste** en `tandas_contados.json`. En memoria, un corte de
  luz a mitad de una tanda de 100 GB habría hecho que al volver se apuntaran esos
  100 GB de nuevo. Se poda al arrancar quitando los paquetes que ya no están en
  JD, para que el fichero no crezca y para que un UUID reciclado no herede deuda
  ajena.
- **La auditoría de código cazó dos `catch { }` mudos** en las funciones nuevas
  de guardar/leer el contador. Corregido: ahora avisan. Un catch mudo ahí dejaba
  el contador sin persistir en silencio, que es exactamente el fallo que el
  contador venía a evitar.
- **Corrección del 10/09 de madrugada: no es un tope diario.** Los números de
  corte (233 / 383,6 / 330,9 GB) invitaban a leerlo como una cuota diaria, y esa
  lectura era falsa. Los dos primeros sondeos automáticos la deshicieron: a la
  01:50 pasó y terminó el episodio, y a las 03:51 bajó **105,8 GB de una vez**,
  dejando la ventana de 24 h en **442,8 GB** — muy por encima de cualquiera de
  los tres cortes — y siguió sirviendo a toda velocidad. Lo que limita se
  recupera en **un par de horas**, así que es un límite de ventana corta, no del
  día. Consecuencia: `-MaxGbDia` ha quedado como el disparador del sondeo y poco
  más, y `-SondeoCadaMin 120` resulta estar bien calibrado. No hay número mágico
  que buscar.
- **Y corrección de la corrección (10/09 tarde): sí es un tope diario.** El
  bullet de arriba también estaba mal. Sumando por **día natural**: 233,6 GB
  (08/09), 330,9 (09/09), 301,0 (10/09) — y cortó las tres veces. La
  «recuperación en 2 h» del 09 al 10 era el **cambio de día**, no un descanso:
  el corte de las 08:21 del 10/09 se mantuvo **10 horas**, mientras la ventana
  deslizante de 24 h *bajaba* de 631,9 a 428,8 GB sin que RD cediera. Es una
  asignación diaria de ~300 GB que se resetea a medianoche.
  **Lección de método:** una sola recuperación no define el periodo. Hacía falta
  un corte a otra hora del día para separar «descansa 2 h» de «cambia el día», y
  eso no apareció hasta el segundo día. Dos lecturas equivocadas seguidas por
  generalizar de un solo dato.
- **Lista blanca de extensiones en `Remove-RestosDescarga`.** Esa función borra
  por NOMBRE lo que se le da, sin mirar qué es. El alcance por `-Filtro` era
  toda la protección que tenía. Ahora hay una segunda capa: un vídeo se rechaza
  con un aviso explícito (`es un VIDEO y aquí solo se borran restos`) porque que
  llegue uno significa que la tanda está mal acotada; y cualquier extensión que
  no sea de resto de descarga (`.rar`, `.r00`, `.part`, `.sfv`, `.nfo`, `.txt`…)
  se rechaza también.
- **Batería nueva: `pruebas\test-sondeo.ps1`,** registrada en `correr-todo.ps1`.
  30 comprobaciones sobre `Test-CuotaMultihoster`, `Add-GbDeLaTanda`,
  `Remove-RestosDescarga` y `Wait-EntreSondeos`. Las funciones se sacan del
  script real por AST — y también `$ExtRestosOk`, para que la prueba no use una
  copia congelada de la lista blanca.
- **Verificada con 4 mutaciones**, todas detectadas: dar la cuota por agotada
  con un solo enlace tocado, volver a contar el total en vez del incremento,
  quitar la guarda de vídeo y aceptar cualquier extensión. El fichero se
  restauró y se comprobó por hash SHA256.
- Una trampa del andamiaje que costó un cuelgue: el `Wait-ConParada` de mentira
  no hacía pasar el tiempo, así que `$faltan` nunca bajaba y `Wait-EntreSondeos`
  giraba para siempre. El mock mueve el ancla hacia atrás.
- **Medición limpia: Real-Debrid cortó esta noche en 330,9 GB** de ventana de
  24 h, con el mensaje literal `Reason: Fair usage limit reached`. La vez
  anterior fue sobre 383. No es un número fijo.
- Suite completa en verde. La detección se probó contra JD en vivo con la cuota
  realmente agotada: acierta en el paquete bloqueado, no en uno terminado.

## 2026-09-09 — El bucle de tandas adoptaba descargas ajenas de JDownloader

- **Incidente:** con el bucle parado esperando presupuesto, el usuario se bajó
  a mano una película por JDownloader (`Coherence (2013)`, 14,2 GB). Al
  relanzar el bucle, éste la **adoptó como si fuera su tanda**: se quedó
  esperándola, vació la papelera y acabó saliendo del bucle entero porque el
  `.mkv` no pasaba el `-FiltroVideo`. Una descarga ajena paraba el pipeline.
- **Causa:** `Get-JdPaquetesDescarga` devuelve la lista **entera** de JD y se
  usaba sin filtrar en dos sitios. El `-Filtro` sí se aplicaba a las carpetas
  de `Downloads` y a los paquetes del linkgrabber, pero no a la lista de
  descargas.
- **Lo que no llegó a pasar, y era lo grave:** el segundo sitio sin filtrar
  metía el paquete ajeno en `$idsJd`, y de ahí su carpeta en `$carpetas` y su
  nombre de fichero en `$nombresJd`. Al cerrar la tanda,
  `Remove-RestosDescarga` **borra el nombre que se le da sin mirar la
  extensión**: habría borrado los 14,2 GB de la película. Se cortó el bucle a
  mitad de descarga antes de llegar ahí; el fichero se verificó intacto.
- **Tercer hueco, encontrado al revisar:** `Add-GbDescargadas` sólo se llamaba
  desde la rama que baja del linkgrabber. Una tanda **adoptada** —la que se
  reanuda tras un corte o un reinicio— bajaba sus ~99 GB **sin apuntar ni
  uno**, así que la tanda siguiente arrancaba creyendo que tenía presupuesto
  de sobra. Es el camino exacto por el que se vuelve al muro del multihoster.
- **Fix:** `-Filtro` aplicado en los dos sitios (`Get-TandaAdoptada` y la
  relectura tras `moveToDownloadlist`), de modo que `$idsJd`, `$carpetas`,
  `$nombresJd` y la contabilidad quedan acotados de golpe; y la contabilidad
  extraída a `Add-GbDeLaTanda`, llamada desde **las dos** ramas. Cuenta el
  `bytesLoaded` total y no el incremento: pasarse por arriba sólo frena de
  más, quedarse corto es lo que hace daño.
- **Presupuesto:** un apunte de 22,5 GB llevaba dentro los 14,23 de la
  película ajena; corregido a 8,27 (comprobado contra el `bytesLoaded` de los
  dos paquetes de la serie). Tope diario subido de 300 a 320 GB para dejar
  pasar la tanda de 99,4 GB con 203,2 ya gastados — sigue 63 GB por debajo de
  los 383,6 en que se midió que Real-Debrid corta.
- Suite completa en verde tras cada uno de los tres arreglos.

## 2026-09-08 — Colisión de temporales entre las dos ranuras + descarga por tandas

- **Incidente:** de 6 episodios de Juego de Tronos codificados en pareja,
  fallaron exactamente 3 — uno de cada pareja (E01 ✓/E02 ✗, E03 ✓/E04 ✗,
  E05 ✓/E06 ✗), todos con `ffmpeg exit -2` y
  `Error opening input file ...ocr_<sello>_0.srt`.
- **Causa:** `encode.ps1` fechaba varios temporales solo con `$stamp`
  (`yyyyMMdd_HHmmss`) y `encode-watch.ps1` lanza las dos ranuras en la misma
  vuelta del bucle, o sea **el mismo segundo y el mismo nombre de fichero**.
  El trabajo que muxeaba primero borraba los temporales compartidos y el
  segundo moría al no encontrarlos. El propio fichero ya documentaba el riesgo
  en la línea 556 y lo había resuelto para el vídeo con `$TmpTag`
  (`<sello>_s<ranura>_<PID>`), pero `ocr_`, `ddp_` y `encode_ff_stderr_` se
  quedaron atrás.
- **El fallo peligroso no era el que dio la cara:** `ddp_<sello>_<idx>.ec3`
  colisionaba igual, y con otro orden de muxeo un episodio se habría llevado
  **el audio DD+ del otro** pasando todas las verificaciones (duración, pistas
  y tamaño correctos). Se comprobó pista a pista que las 3 salidas buenas
  llevan su propio audio (E01 3700 s/fuente 3702, E03 3437/3438, E05
  3259/3261) — se salvaron por el orden en que terminó DEE, no por diseño.
- **Fix:** `${stamp}` → `${TmpTag}` en las 4 rutas de temporal por trabajo de
  `encode.ps1` (líneas 641, 1211, 1305, 2159). Los prefijos no cambian, así que
  `Clear-JobTemps` y `$PipelineTempPatterns` siguen casando. Verificado en
  vivo: dos trabajos arrancados en el mismo segundo (`20260908_072425`) ahora
  escriben en `..._s1_8248` y `..._s2_26760`.
- **Nuevo: descarga por tandas** (`descargas-tanda.ps1`, `jd-lib.ps1`,
  `jd-api-setup.ps1`). Baja N episodios de JDownloader, extrae, vacía papelera,
  codifica, verifica, raspa con tinyMediaManager y copia a `E:\Series` antes de
  borrar nada de C:. La unidad es el **episodio**, no el paquete: un paquete de
  JD es una temporada entera (255 GB) pero sus `.rar` vienen agrupados por
  episodio, así que se mueven enlaces sueltos con `moveToDownloadlist`.
  Sirve igual para **películas y series**: el título sale del nombre del
  paquete de JD (renombras el pack y ya), el tipo se detecta por si los vídeos
  traen `SxxExx`, y el destino va detrás — `E:\Series\<t>\Season N` o
  `E:\Peliculas\<t>`. Una tanda puede llevar varias películas: el título es
  por fichero.
- **La API de JD escucha en `127.0.0.1:3128`**, no en el 9666. Costó
  encontrarlo porque JD levanta **dos** servidores: el 9666 es el *External
  Interface* de FlashGot, siempre encendido y que devuelve 501 a todo salvo
  `/flash/`; la API *deprecated* es el 3128 y solo escucha con
  `deprecatedapienabled` en true. Con el interruptor apagado el 3128 no tiene
  a nadie y el 9666 sí, así que parecía que el puerto bueno era el 9666 y que
  su 501 significaba "puerta cerrada"; significaba "servidor equivocado". El
  puerto se lee ahora de `deprecatedapiport`, no de una constante.
- `jd-api-setup.ps1`: `CloseMainWindow()` no sirve con JD minimizado en la
  bandeja (`MainWindowHandle = 0`, la llamada no hace nada y el script esperaba
  90 s en balde). Se le añadió `WM_CLOSE` a la ventana oculta — que tampoco
  basta, porque JD lo trata como "minimizar". Se cierra desde el menú de la
  bandeja, o se marca la casilla en Ajustes avanzados sin cerrar nada.
- **Red de seguridad ante cortes de luz** (`tandas-keepalive.ps1` + tarea
  "MediaBox - keepalive tandas", al iniciar sesión y cada 10 min). La señal es
  `C:\Media\tmp\tandas_activo.json`: el bucle lo escribe al arrancar y lo
  **borra en toda salida normal**, así que *fichero presente + proceso ausente*
  = se murió sin querer. Parar el bucle a propósito no lo resucita. Guarda los
  argumentos de la invocación, así que el relanzamiento es idéntico, y el
  título, que es lo único que no se puede deducir del disco cuando el corte
  pilla la tanda a mitad de codificar. Tope de 10 relanzamientos, que se
  perdona en cuanto una tanda cierra entera.
- Tercer bug de quoting de la sesión, en el relanzamiento: `Start-Process
  -ArgumentList` con un **array** une los elementos con espacios y no los
  entrecomilla, así que `-Nombre "Juego de Tronos (2011)"` habría llegado como
  cuatro argumentos y creado `E:\Series\Juego\`. Se arma una sola cadena ya
  entrecomillada.
- Dos veces el mismo bug de PowerShell en una sesión: una variable local con
  el nombre de un parámetro **es** el parámetro (`$ruta` / `$Ruta`), y la
  comparación salía siempre cierta. Habría hecho que tmm raspara la biblioteca
  equivocada. Está en la tabla de `ps7-edit-guard`; no basta con conocerla.

## 2026-08-29 — Pérdida de una película + saneado del patrón de sustitución

- **Incidente:** `retrofit-reconstruir.ps1` destruyó de forma irrecuperable
  una película (`Move-Item -Force` no es atómico + `ErrorActionPreference=Continue`
  ocultó el fallo + el `finally` borró el único sustituto que quedaba).
- **Fix de fondo:** nueva `Move-FicheroEnSitio` en `atmos-lib.ps1` — apartar
  nunca borrar, `-ErrorAction Stop` siempre, comprobar el efecto, deshacer al
  fallar, reintentos por el handle. Adoptada por `Rebuild-Container`,
  `audio_recap.ps1`, `audio_compat.ps1`, `inyectar-atmos.ps1`, `reordenar-pistas.ps1`.
- Pérdida menor: `Rebuild-Container` no conservaba adjuntos (fuentes ASS de
  9 películas) — arreglado y verificado por MD5.
- `Rebuild-Container`: guarda de framerate, dos intentos de timestamps,
  adjuntos conservados, pistas de subtítulos vacías apartadas (no tumban el
  muxeo), ASS/SSA → SRT siempre, stderr de mkvmerge capturado.
- Retrofit de reconstrucción de contenedores cerrado: 640/648 hechas
  (4 `.mp4` no aplican, 3 con bitstream problemático, 1 la perdida).
- Compatibilidad de códecs cerrada: 0 códecs no nativos en 5.452 ficheros.
- `sanear.ps1` (nuevo): deja una película lista para biblioteca en un paso.
- Revisión de arquitectura publicada — veredicto: no reescribir; batería de
  pruebas mínima y sacar `Rebuild-Container` de `encode.ps1` como prioridades.

## 2026-08-26/27 — Auditoría completa + rediseño de la política de tamaño

- Auditoría de los tres pipelines: **10 fallos reales encontrados y arreglados**
  (fuga de 10-20 GB de `_recon_*` sin barrer, `.partial` colándose en la cola
  de vídeo, ciclo infinito de reintentos en `exit 75`, `pwsh` lanzado por PATH
  que podía colgar los tres pipelines a la vez, XSS en título de pista MKV,
  código muerto, lock que podía quedar cogido para siempre, pérdida de título
  de contenedor, poda de caché solo al guardar, y un log de limpieza que
  mentía sobre si había borrado algo).
- Watchers ahora dejan log persistente (`C:\Media\encode_logs\watcher-*.log`).
- **QSVEncC descartado en firme**: con `ffmpeg -v verbose` se confirmó que
  `extbrc`/lookahead/min-max QP/`MaxFrameSize` son inertes porque la Arc A730M
  solo tiene ruta VDENC con BRC en hardware — no es límite de ffmpeg, es
  límite del driver. QSVEncC pasaría por el mismo runtime oneVPL: no
  compraría nada.
- Política de tamaño redefinida (1080p bajó de 8.5/7.5 a 5.5/5.0 GB, −21%
  sobre la biblioteca) y **1080p volvió de ICQ a QVBR** (ICQ no tiene control
  de tamaño: medido 2.6× de diferencia entre dos películas del mismo bitrate
  de fuente).
- Panel: selector por película `auto | ICQ | QVBR` + Mbps manual + sidecar `.opts`.
- Nuevos campos en `completed.jsonl`: `rate_mode`, `rate_mode_req`, `target_manual`.

## 2026-08-25 — Perfil de calidad por resolución + autocorrección de sync

- 1080p pasa a ICQ puro (GQ 15, mismo nivel pedido de siempre, sin inflar
  escenas fáciles); 4K se queda en QVBR con techo por tabla (en ICQ el
  contenido con grano real podía pedir más que el techo, medido en
  *El Bueno El Feo Y El Malo*: +23% de tamaño).
- Autocorrección de sync en remux (`webpanel/app.py::_remux_verify` /
  `remux_worker`) y cronómetro por fase.
- `Test-PieceMatch` cierra el autoemparejamiento de procesos en
  `start-mediabox-core.ps1`.

## 2026-07-17 — Pestaña Subs + arreglo de Stop/Skip + endurecimiento de PATH

- Pestaña **Subs** completa en el panel (`app.py` + `index.html`): añadir a
  cola, estado en vivo, cancelar — mismo patrón que la pestaña Audio.
- **Diagnóstico y arreglo de Stop/Skip rotos**: escribían/mataban el PID de
  ffmpeg, que no existe durante las fases de audio (~20 min) — pasan a
  escribir el PID del propio `encode.ps1` desde el arranque.
- El `Skip` antiguo borraba **todo** `encode_running` a ciegas al pulsarse,
  incluso si el kill fallaba — causó pérdida de fuentes en producción.
  Rehecho: nunca borra, solo mata.
- Semántica nueva de botones: **Stop** mata y pausa la cola entera (flag
  `encode_paused`); **Skip** mata y pasa al siguiente; nuevo botón
  **Reanudar cola**.
- Mecanismo de limpieza marcador+barrido (`${StatePfx}_outfile` +
  `Clean-JobLeftovers`) para que `taskkill /F` (que no dispara `finally`) no
  deje huérfanos de 12-21 GB en `C:\Media\tmp`.
- Barrido de todas las llamadas a ffmpeg/ffprobe por PATH que quedaban
  (`encode.ps1::Probe`, extracción PGS, `atmos-lib.ps1`, `app.py`) — todas a
  ruta absoluta.
