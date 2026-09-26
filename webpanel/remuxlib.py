"""
remuxlib.py  -  sondeo de pistas y medicion de desfase para la pestana Remux.

Separado de app.py a proposito: la medicion es la parte que mas se puede
equivocar y aqui se puede ejecutar y verificar sola, sin levantar el panel.

    python remuxlib.py probe   "peli.mkv"
    python remuxlib.py measure "base.mkv" 1 "otra.mkv" 2
    python remuxlib.py voz     "peli.mkv" [idx_audio]   (contra su propia imagen)

QUE MIDE Y POR QUE ASI (leccion del 01/08/2026)
-----------------------------------------------
Se correlacionan las ENVOLVENTES de volumen de dos pistas en varios puntos de
la pelicula y se ajusta una recta:  tiempo_fuente = alpha * tiempo_base + beta

  - beta  = desfase fijo    -> se arregla con --sync, SIN recodificar
  - alpha = deriva (fps)    -> obliga a resamplear, y eso DESTRUYE Atmos/objetos

Medir en 3+ puntos separados es lo que distingue un caso del otro. Con un solo
punto no se puede saber si hay deriva, y una deriva de 1 s en 2 h pasa
desapercibida al principio de la peli y arruina el final.

La correlacion funciona incluso entre IDIOMAS distintos (la musica y los efectos
son los mismos), solo baja el pearson: ~0.9 mismo idioma, ~0.5-0.8 distinto.
"""

import json, os, re, subprocess, sys, tempfile, threading, wave

# UN SOLO HILO DE BLAS, y hay que ponerlo ANTES de importar numpy: OpenBLAS lee
# estas variables al cargarse, no despues.
#
# QUE ARREGLA (medido el 20/08/2026 en esta maquina, 16 nucleos). OpenBLAS
# reserva un juego de buffers POR HILO en cuanto se toca, y se dimensiona segun
# los nucleos que ve. El proceso del panel, que importa numpy por esta libreria,
# quedaba en 535 MB de commit y 19 hilos sin estar haciendo nada. Con el limite a
# 1: 52 MB y 4 hilos. Son 483 MB de reserva y 15 hilos ociosos que desaparecen.
#
# QUE NO CUESTA. Aqui no hay una sola multiplicacion de matrices: el trabajo duro
# son FFT (np.fft, que es pocketfft y va aparte de BLAS) y operaciones elemento a
# elemento. Lo unico que pasa por LAPACK es el np.polyfit que ajusta una recta a
# CUATRO puntos, donde repartir entre hilos cuesta mas que calcularlo.
#
# La RAM residente apenas cambia (35 -> 32 MB): lo que se recupera es reserva de
# commit. Pero un proceso que vive encendido todo el dia no tiene por que
# reservar medio giga para no usarlo.
for _v in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import numpy as np

FFMPEG  = r"C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe"
FFPROBE = r"C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffprobe.exe"
if not os.path.exists(FFMPEG):  FFMPEG  = "ffmpeg"
if not os.path.exists(FFPROBE): FFPROBE = "ffprobe"

# MISMA variable de entorno que app.py (19/08/2026). Antes esto era una ruta fija
# y app.py leia MEDIABOX_BIGTMP: los dos BIGTMP viven en EL MISMO proceso, asi que
# poner la variable movia los temporales del remux pero no los de la medicion de
# sync, que seguian cayendo en G: aunque G: fuera justo lo que se queria evitar.
BIGTMP = os.environ.get("MEDIABOX_BIGTMP", r"G:\MediaTmp")
UMBRAL_MS = 40.0      # por debajo de esto no es audible; es el listón de "OK"
# Residuo por encima del cual la RECTA no describe los datos y no se puede
# hablar de deriva (19/08/2026). Es 6x el umbral audible -asi que queda muy por
# encima del ruido de medida: casos buenos reales dan 0.1, 7.9 y 20 ms- y 4x por
# debajo de PASO_MIN_S, el escalon mas pequeno que esta libreria llama escalon.
RESID_MAX_MS = 250.0

# Tope de vida de un hijo ffmpeg/ffprobe. Es el que ya usaba a mano el resto del
# fichero para lo pesado (demultiplexar la pelicula entera); aqui pasa a tener
# nombre porque lo comparte el vigilante de _envolvente_voz.
FFMPEG_MAX_S = 900

# Subtítulos de TEXTO que ffmpeg pasa a SRT sin OCR. Debe coincidir con
# $SubTextCodecs de subs-lib.ps1, que es quien hace la conversión de verdad:
# aquí solo se decide qué ofrecer en la interfaz.
SUB_TEXT_CODECS = ("subrip", "srt", "text", "ass", "ssa", "mov_text",
                   "tx3g", "webvtt", "subviewer", "microdvd")


# ----------------------------------------------------------------- sondeo ---

def probe(path):
    """Todas las pistas con codec, idioma, titulo y FLAGS (default/forced).

    Las flags salen de ffprobe (stream_disposition), no de mkvmerge, para no
    depender de dos herramientas en el camino caliente. Se detecta ademas si la
    pista lleva OBJETOS (Atmos), que es lo que decide si se puede resamplear.
    """
    r = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries",
         "format=duration:stream=index,codec_type,codec_name,profile,channels,"
         "width,height,r_frame_rate,color_transfer,bit_rate:"
         "stream_disposition=default,forced:stream_tags=language,title",
         "-of", "json", path],
        capture_output=True, text=True, timeout=120)
    data = json.loads(r.stdout or "{}")
    dur = float(data.get("format", {}).get("duration") or 0)

    tracks = []
    for s in data.get("streams", []):
        tags = s.get("tags", {}) or {}
        disp = s.get("disposition", {}) or {}
        codec = (s.get("codec_name") or "").lower()
        prof  = s.get("profile") or ""
        ttype = s.get("codec_type")
        if ttype not in ("video", "audio", "subtitle"):
            continue
        atmos = "atmos" in prof.lower()
        t = {
            "index":    s.get("index"),
            "type":     ttype,
            "codec":    codec,
            "profile":  prof,
            "lang":     tags.get("language", "") or "und",
            "title":    tags.get("title", "") or "",
            "default":  bool(disp.get("default")),
            "forced":   bool(disp.get("forced")),
            "channels": s.get("channels"),
            "bitrate":  int(s["bit_rate"]) if s.get("bit_rate", "").isdigit() else None,
            "atmos":    atmos,
            # objetos = no se puede resamplear sin destruirlos
            "objects":  atmos or codec in ("truehd", "mlp"),
            # Lo que el TV decodifica de forma nativa. Todo lo demas -DTS, TrueHD,
            # FLAC, PCM, Opus...- hay que convertirlo a DD+: copiarlo solo consigue
            # que Plex transcodifique en cada reproduccion (ver av-playback-setup).
            # Se usa para OFRECER la conversion en el panel y marcarla por defecto;
            # los pipelines automaticos ya la aplican solos.
            "nativo":   codec in ("ac3", "eac3", "aac", "mp3"),
            "lossless": codec in ("truehd", "mlp", "flac", "pcm_s24le", "pcm_s16le"),
        }
        if ttype == "subtitle":
            # srt      = ya es texto plano, no hay nada que convertir
            # text     = ass/ssa/... -> ffmpeg lo pasa a SRT en segundos
            # ocr      = PGS -> OCR con PgsToSrt, MINUTOS por pista
            # ninguna  = VobSub y demas: no hay camino a SRT (ver subs-lib.ps1)
            t["srt"]  = codec in ("subrip", "srt", "text")
            t["text"] = codec in SUB_TEXT_CODECS
            t["ocr"]  = codec == "hdmv_pgs_subtitle"
            t["srtable"] = t["text"] or t["ocr"]
        if ttype == "video":
            t["width"]  = s.get("width")
            t["height"] = s.get("height")
            t["fps"]    = s.get("r_frame_rate")
            trc = (s.get("color_transfer") or "").lower()
            t["hdr"] = "HDR" if trc in ("smpte2084", "arib-std-b67") else "SDR"
        tracks.append(t)
    return {"duration": dur, "tracks": tracks}


# -------------------------------------------------------------- medicion ---

def _wav(path, stream_index, start, dur, out):
    subprocess.run(
        [FFMPEG, "-v", "error", "-y", "-ss", f"{start:.3f}", "-t", f"{dur:.3f}",
         "-i", path, "-map", f"0:{stream_index}", "-ac", "1", "-ar", "16000",
         "-c:a", "pcm_s16le", out],
        capture_output=True, timeout=300)
    return os.path.exists(out) and os.path.getsize(out) > 4096


def _env(path, dec=8):
    """Envolvente de volumen normalizada. dec=8 sobre 16 kHz -> 0.5 ms por muestra.

    (El comentario decia "2 ms" y era falso: 16000/8 = 2000 Hz, o sea 0.5 ms.
     Corregido el 04/08/2026. La cifra importa porque es la cota inferior del
     error de cada punto, y aqui se discuten milisegundos.)
    """
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        s = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)
    if s.size < 1000:
        return None, 0
    e = np.abs(s)
    m = (len(e) // dec) * dec
    e = e[:m].reshape(-1, dec).mean(axis=1)
    e -= e.mean()
    sd = e.std()
    if sd == 0:
        return None, 0
    return e / sd, sr / dec


def _corr(ae, be, er, T, b_start, res):
    """Correlacion cruzada normalizada de dos series 1D ya centradas y escaladas.

    Vive aparte porque la usan las DOS formas de medir -envolvente de audio y
    luminancia de video- y son exactamente el mismo calculo: lo unico que cambia
    es de donde sale la senyal. Copiarla habria sido condenar a las dos copias a
    divergir, que en este proyecto ya ha pasado con otras funciones.
    'er' son las muestras por segundo de las series (Hz).
    Anyade un punto a `res` si engancha; si no, no toca nada.
    """
    La, Lb = len(ae), len(be)
    if Lb <= La:
        return
    nf = 1 << int(np.ceil(np.log2(La + Lb)))
    cc = np.fft.irfft(np.fft.rfft(be, nf) * np.conj(np.fft.rfft(ae, nf)), nf)
    v = cc[:Lb - La + 1]
    # CORRELACION NORMALIZADA (04/08/2026). Antes se cogia el maximo de la
    # correlacion CRUDA, que no compara peras con peras: el producto crece
    # con la energia del tramo, asi que el pico se iba al trozo mas fuerte
    # de la ventana de busqueda en vez de al mejor alineado. Dividiendo por
    # la desviacion LOCAL de cada posicion, el valor pasa a ser el pearson
    # de esa posicion (ae ya viene con media 0 y sigma 1), y el maximo es
    # el que de verdad encaja. Importa sobre todo entre idiomas distintos,
    # que es el caso que esta libreria dice soportar y donde el pearson ya
    # baja a 0.5-0.8 de por si.
    c1 = np.concatenate(([0.0], np.cumsum(be)))
    c2 = np.concatenate(([0.0], np.cumsum(be * be)))
    n_pos = Lb - La + 1
    s1 = c1[La:La + n_pos] - c1[:n_pos]
    s2 = c2[La:La + n_pos] - c2[:n_pos]
    var = np.maximum(s2 / La - (s1 / La) ** 2, 1e-12)
    ncc = v / (La * np.sqrt(var))          # = pearson en cada posicion
    k = int(np.argmax(ncc))
    pear = float(ncc[k])
    # nitidez: cuanto destaca el pico sobre el mejor rival lejano.
    # <1.3 = la correlacion no ha enganchado nada claro. Se calcula sobre
    # la MISMA curva normalizada, para que pearson y nitidez sean
    # coherentes entre si (antes salian de dos curvas distintas).
    g = max(1, int(er * 0.5))
    mk = ncc.copy()
    mk[max(0, k - g):min(len(mk), k + g + 1)] = -1e18
    best = float(mk.max())
    sharp = float(ncc[k] / best) if best > 0 else 99.0
    # PICO PEGADO AL BORDE (14/08/2026). Si el desfase real excede la ventana de
    # busqueda, el maximo no puede caer donde toca y se queda en el extremo: la
    # medida es basura pero salia con ok=True y nadie lo notaba. Visto midiendo
    # Toy Story 5 (offset real -42 s con search=30): devolvio alpha=0.992 y una
    # deriva de -47 s inventadas, con pearson 0.1. Marcarlo aqui permite que
    # measure() reintente con la ventana ancha en vez de contestar una mentira.
    margen = max(1, int(0.05 * n_pos))
    en_borde = bool(k < margen or k >= n_pos - margen)
    # _t y _lag van SIN redondear: son los que entran en el ajuste. Los
    # redondeados de al lado son solo para mostrar. Mezclarlos fue un bug
    # real (02/08/2026): 't' redondeado a 0.1 s metia hasta 50 ms de error
    # en un ajuste que busca precision de milisegundos.
    lag = (b_start + k / er) - T
    res.append({"t": round(T, 1), "_t": T, "_lag": lag,
                "src_t": round(b_start + k / er, 4),
                "lag_ms": round(lag * 1000, 1),
                "pearson": round(pear, 2),
                "sharp": round(sharp, 2),
                "edge": en_borde})


_RX_YAVG = re.compile(r"lavfi\.signalstats\.YAVG=([\d.]+)")


def _lum(path, start, dur, fps=12.0):
    """Serie 1D de LUMINANCIA MEDIA por fotograma, normalizada igual que _env.

    Es el equivalente en video de la envolvente de volumen: una senyal 1D que
    describe el contenido a lo largo del tiempo, para meterla en la MISMA
    correlacion cruzada. Los cortes de plano son escalones muy marcados, asi que
    engancha con mucha fuerza (medido: pearson 1.000 entre dos rips distintos de
    la misma pelicula, frente al ~0.95 que da el audio entre idiomas distintos).

    POR QUE SIRVE AUNQUE LOS FICHEROS SEAN MUY DISTINTOS: la media de luminancia
    la determina el CONTENIDO, no como este comprimido. Sobrevive a cambios de
    bitrate, de resolucion y de codec. Y como la serie se centra y se divide por
    su desviacion, tambien sobrevive a un grading distinto o a HDR contra SDR:
    se compara la FORMA de la curva, no valores absolutos.

    'fps' fija la cadencia de muestreo de las DOS series: asi un fichero a 23.976
    y otro a 24 se comparan sobre la misma rejilla temporal, y su diferencia de
    cadencia aparece donde tiene que aparecer -en el alpha del ajuste- en vez de
    ensuciar cada punto por separado.

    Se escala a 160x90 antes de medir: la MEDIA de luminancia no cambia y
    decodificar es mucho mas barato.

    POR QUE '-skip_frame bidir' (07/08/2026)
    ----------------------------------------
    Decodifica solo fotogramas I y P, saltandose los B. Como el pipeline encoda
    con -bf 3, eso es saltarse ~3 de cada 4: **10,7 veces mas rapido** (medido:
    12,3 s contra 131,1 s para el mismo par de ventanas). Una medicion completa
    de 4 puntos baja de ~15 min a ~1,5 min.

    Cuesta resolucion temporal: de los 83 ms de la rejilla de 12 fps se pasa a
    ~167 ms, porque el flujo efectivo queda en ~6 fps y el filtro fps= duplica
    lo que falta. Se acepta a proposito: este modo NUNCA fue el preciso -para un
    desfase fijo manda el audio, con 0,5 ms- sino el ROBUSTO, el que engancha
    cuando el audio no tiene nada en comun. Cambiar 83 ms por 167 ms a cambio de
    13 minutos es un buen trato.
    Validado con respuesta conocida (dos recortes separados 10,01 s, que es el
    GOP): completo y rapido dieron los dos +10,000 s, con pearson 0,999.

    Lo que NO sirvio, para no volver a probarlo:
      - '-hwaccel qsv'      : falla ("Conversion failed!") con este HEVC 10 bits.
      - '-hwaccel auto'     : 39,6 s contra 22,4 s. MAS LENTO: el cuello no es
                              decodificar, es bajar los fotogramas de la GPU
                              para signalstats, que es un filtro de software.
      - '-hwaccel d3d11va'  : 31,3 s. Mas lento por lo mismo.
      - '-lowres 2/3'       : sin efecto, el decodificador HEVC no lo soporta.
      - paralelizar las 4 ventanas: solo 1,26x, un ffmpeg ya usa media maquina.
    """
    p = subprocess.run(
        [FFMPEG, "-hide_banner", "-loglevel", "info",
         "-skip_frame", "bidir",
         "-ss", f"{start:.3f}", "-t", f"{dur:.3f}", "-i", path,
         "-an", "-sn",
         "-vf", f"fps={fps},scale=160:90,signalstats,"
                f"metadata=print:key=lavfi.signalstats.YAVG",
         "-f", "null", "-"],
        capture_output=True, text=True, errors="ignore", timeout=900)
    v = np.array([float(m.group(1)) for m in _RX_YAVG.finditer(p.stderr)],
                 dtype=np.float64)
    if v.size < 16:
        return None, 0
    v -= v.mean()
    sd = v.std()
    if sd == 0:            # plano fijo o negro: no hay nada que correlacionar
        return None, 0
    return v / sd, fps


# ------------------------------------------------ medicion por SUBTITULOS ---
# TERCERA forma de medir, ademas de la envolvente de audio y la luminancia.
#
# POR QUE (14/08/2026, idea del usuario). El audio y el video son senales
# CONTINUAS y se comparan por correlacion, que contesta "cuanto hay que
# desplazar" pero no "que trozo sobra". Los subtitulos son otra cosa: un TREN DE
# EVENTOS. Y dos trenes de eventos se pueden alinear como un diff, asi que las
# inserciones y los borrados salen DIRECTAMENTE, que es justo lo que define un
# montaje distinto (extendido, director's cut, creditos mas largos).
#
# Ventajas sobre las otras dos:
#   - No descodifica NADA: solo demultiplexa los paquetes de una pista. Frente a
#     los 86-442 s que costo cada pasada por imagen en Toy Story 5.
#   - Es inmune a la mezcla de audio Y al reencode del video: solo mira tiempos.
#   - Vale con PGS: no hace falta OCR ni texto, porque lo que se usa son los
#     TIEMPOS de los paquetes, no lo que ponga en ellos.
#
# Limite, y hay que decirlo claro: los tiempos de un subtitulo son DE AUTOR, no
# medidos. Cada version entra y sale con su propio margen (lo normal es aparecer
# 100-300 ms antes de la voz), asi que el desfase absoluto sale con ~+-200 ms de
# incertidumbre. Es MUCHO peor que el audio, que da milisegundos. Por eso esto se
# usa para la ESTRUCTURA (tramos, huecos, que master es) y se deja que el audio o
# el video afinen el desfase de cada tramo.
BIN_SUBS_S  = 0.20     # resolucion del histograma de diferencias
TOL_SUBS_S  = 0.40     # cuanto puede separarse un par para contar como el mismo


def _cues(path, index, max_cues=8000):
    """Tiempos de los paquetes de una pista de subtitulos. No descodifica nada.

    Sale el pts de CADA paquete. En PGS eso incluye el paquete que borra el
    subtitulo, asi que el tren lleva inicios y finales mezclados; da igual, el
    alineamiento por histograma no necesita que los dos trenes tengan la misma
    forma, solo que compartan eventos.
    """
    r = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", str(index),
         "-show_entries", "packet=pts_time", "-of", "csv=p=0", path],
        capture_output=True, text=True, timeout=900)
    ts = []
    for linea in (r.stdout or "").splitlines():
        linea = linea.strip().rstrip(",")
        if not linea or linea == "N/A":
            continue
        try:
            ts.append(float(linea))
        except ValueError:
            continue
    ts.sort()
    return np.array(ts[:max_cues], dtype=float)


def _pares_subs(pb, ps):
    """Elige que pista de subtitulos usar en cada fichero. Prefiere el MISMO
    idioma: dos versiones del mismo idioma marcan los mismos dialogos y enganchan
    mucho mejor que un ingles contra un aleman."""
    sb = [t for t in pb["tracks"] if t["type"] == "subtitle"]
    ss = [t for t in ps["tracks"] if t["type"] == "subtitle"]
    if not sb or not ss:
        return None, None
    for a in sb:
        for b in ss:
            if a["lang"] != "und" and a["lang"] == b["lang"]:
                return a["index"], b["index"]
    return sb[0]["index"], ss[0]["index"]


def medir_por_subtitulos(base_path, src_path, base_index=None, src_index=None,
                         tol=TOL_SUBS_S, max_off=400.0):
    """Estructura entre dos ficheros a partir de los tiempos de sus subtitulos.

    Metodo: histograma de las diferencias (b - a) de todos los pares cercanos.
    Cada tramo con desfase propio deja su PROPIO pico en el histograma; luego se
    mira que eventos caen en cada pico y en que zona de la pelicula, y de ahi
    salen los tramos. Es un RANSAC pobre pero muy robusto: los eventos que no
    casan con ningun pico simplemente no votan, no estropean el resultado.
    """
    pb, ps = probe(base_path), probe(src_path)
    if base_index is None or src_index is None:
        base_index, src_index = _pares_subs(pb, ps)
    if base_index is None:
        return {"ok": False, "mode": "subs",
                "error": "hace falta una pista de subtitulos en CADA fichero"}

    A, B = _cues(base_path, base_index), _cues(src_path, src_index)
    if len(A) < 20 or len(B) < 20:
        return {"ok": False, "mode": "subs",
                "error": "muy pocos subtitulos para medir (%d y %d)" % (len(A), len(B))}

    # -- histograma de diferencias -------------------------------------------
    difs = []
    for a in A:
        lo = np.searchsorted(B, a - max_off)
        hi = np.searchsorted(B, a + max_off)
        if hi > lo:
            difs.append(B[lo:hi] - a)
    if not difs:
        return {"ok": False, "mode": "subs", "error": "sin pares en rango"}
    difs = np.concatenate(difs)
    bordes = np.arange(-max_off, max_off + BIN_SUBS_S, BIN_SUBS_S)
    hist, _ = np.histogram(difs, bins=bordes)
    centros = (bordes[:-1] + bordes[1:]) / 2.0

    # Picos: un desfase real hace coincidir MUCHOS eventos a la vez. El umbral va
    # en proporcion al numero de subtitulos, no fijo, para que valga igual en una
    # pelicula con 400 lineas que en una con 2000.
    minimo = max(8, int(0.04 * len(A)))
    cand = []
    for i in range(1, len(hist) - 1):
        if hist[i] >= minimo and hist[i] >= hist[i - 1] and hist[i] >= hist[i + 1]:
            cand.append((int(hist[i]), float(centros[i])))
    cand.sort(reverse=True)
    if not cand:
        return {"ok": False, "mode": "subs",
                "error": "los subtitulos no casan en ningun desfase: "
                         "seguramente no son la misma pelicula"}

    # UMBRAL RELATIVO AL MEJOR PICO. Un desfase REAL hace casar a casi todas las
    # marcas; los picos de coincidencia casual se quedan muy por debajo. Con un
    # umbral absoluto entraban los dos: midiendo un fichero contra si mismo, el
    # pico bueno saco 1093 votos (el 100 %) y habia espurios de 80-93 (un 8 %)
    # que pasaban el corte del 4 %. Y esos falsos desfases son justo lo que
    # PARTIA los tramos en decenas de trozos con el mismo lag.
    mejor_votos = cand[0][0]
    cand = [c for c in cand if c[0] >= max(minimo, 0.25 * mejor_votos)]

    # Se quitan picos casi pegados (el mismo desfase repartido en dos bins) y se
    # AFINA cada uno con las diferencias de verdad: el centro del bin arrastra
    # medio bin de sesgo (con bins de 0,2 s, un desfase real de 0 salia +100 ms).
    offsets = []
    for votos, off in cand[:24]:
        if all(abs(off - o) > max(1.0, tol * 2) for _, o in offsets):
            cerca = difs[np.abs(difs - off) <= BIN_SUBS_S]
            fino = float(np.median(cerca)) if len(cerca) else off
            offsets.append((votos, fino))
    offsets = offsets[:6]

    # -- a que desfase pertenece cada subtitulo del destino -------------------
    asign = []
    for a in A:
        mejor, mejor_d = None, tol
        for votos, off in offsets:
            j = np.searchsorted(B, a + off)
            for k in (j - 1, j):
                if 0 <= k < len(B):
                    d = abs(B[k] - (a + off))
                    if d < mejor_d:
                        mejor, mejor_d = off, d
        asign.append(mejor)

    # -- tramos: rachas contiguas con el mismo desfase ------------------------
    # SUAVIZADO: un cambio de regimen solo se acepta si lo CONFIRMAN K marcas
    # seguidas. Sin esto una sola marca mal casada parte un tramo en dos, y el
    # resultado eran decenas de tramos con el mismo lag y huecos falsos de 0,0 s.
    K = 3
    casadas = [(float(A[i]), off) for i, off in enumerate(asign) if off is not None]
    suave = []
    actual = None
    for j, (t, off) in enumerate(casadas):
        if actual is None or abs(off - actual) <= tol:
            actual = off if actual is None else actual
            suave.append((t, actual))
            continue
        siguientes = [o for _, o in casadas[j:j + K]]
        if len(siguientes) >= K and all(abs(o - off) <= tol for o in siguientes):
            actual = off                      # cambio confirmado
            suave.append((t, actual))
        else:
            suave.append((t, actual))         # marca suelta: se ignora el salto

    tramos = []
    for t, off in suave:
        if tramos and abs(off - tramos[-1]["lag_s"]) <= tol:
            tramos[-1]["hasta_s"] = round(t, 1)
            tramos[-1]["n"] += 1
        else:
            tramos.append({"desde_s": round(t, 1), "hasta_s": round(t, 1),
                           "lag_s": round(float(off), 3),
                           "lag_ms": round(float(off) * 1000, 1),
                           "sync_ms": round(-float(off) * 1000), "n": 1})
    # Tramos con muy pocas marcas no son un tramo: son ruido que sobrevivio.
    tramos = [t for t in tramos if t["n"] >= 5]

    # QUITAR PICOS QUE VAN Y VUELVEN (14/08/2026). Un cambio de montaje es un
    # ESCALON: se cambia de desfase y se sigue. Si un tramo corto queda metido
    # entre dos que tienen el MISMO desfase, no es un montaje distinto, es ruido
    # de casado -y en un cruce entre idiomas salen a puñados, porque la pista con
    # mas lineas ofrece marcas de sobra con las que casar por casualidad-.
    # Visto midiendo castellano contra ingles del MISMO fichero: 3 tramos falsos
    # de 6-17 marcas (+61 s, +2,3 s, -7,7 s) entre tramos correctos de +40 ms.
    MIN_TRAMO_S, MIN_TRAMO_N, MAX_PICO_S = 45.0, 8, 120.0
    cambiado = True
    while cambiado and len(tramos) > 1:
        cambiado = False
        for i, t in enumerate(tramos):
            dur = t["hasta_s"] - t["desde_s"]
            entre_iguales = (0 < i < len(tramos) - 1 and
                             abs(tramos[i - 1]["lag_s"] - tramos[i + 1]["lag_s"]) <= tol)
            if (dur < MIN_TRAMO_S or t["n"] < MIN_TRAMO_N or
                    (entre_iguales and dur < MAX_PICO_S)):
                v = i - 1 if i > 0 else i + 1
                if 0 < i < len(tramos) - 1:
                    v = i - 1 if tramos[i - 1]["n"] >= tramos[i + 1]["n"] else i + 1
                tramos[v]["desde_s"] = min(tramos[v]["desde_s"], t["desde_s"])
                tramos[v]["hasta_s"] = max(tramos[v]["hasta_s"], t["hasta_s"])
                tramos[v]["n"] += t["n"]
                tramos.pop(i)
                cambiado = True
                break

    # Tras fusionar pueden quedar contiguos con el mismo desfase: se juntan.
    juntos = []
    for t in tramos:
        if juntos and abs(t["lag_s"] - juntos[-1]["lag_s"]) <= tol:
            juntos[-1]["hasta_s"] = max(juntos[-1]["hasta_s"], t["hasta_s"])
            juntos[-1]["n"] += t["n"]
        else:
            juntos.append(t)
    tramos = juntos

    if not tramos:
        return {"ok": False, "mode": "subs",
                "error": "no se consolido ningun tramo (subtitulos muy dispersos)"}

    casados = sum(t["n"] for t in tramos)
    escalera = len(tramos) > 1 and any(
        abs(tramos[i + 1]["lag_s"] - tramos[i]["lag_s"]) > PASO_MIN_S
        for i in range(len(tramos) - 1))

    return {
        "ok": True, "mode": "subs", "escalera": bool(escalera),
        "tramos": tramos,
        "cobertura": _cobertura(tramos, pb["duration"], ps["duration"]),
        "alpha": 1.0,
        "beta_ms": max(tramos, key=lambda t: t["n"])["lag_ms"],
        "drift_ms": 0.0, "drift_se_ms": None, "residual_ms": 0.0,
        "used": casados, "total": int(len(A)), "points": [],
        "subs_base_idx": int(base_index), "subs_src_idx": int(src_index),
        "n_cues": [int(len(A)), int(len(B))],
        "casados_pct": round(100.0 * casados / len(A), 1),
        # Los tiempos son de AUTOR: sirven para la estructura, no para afinar ms.
        "precision_ms": 200,
    }


# Un ESCALON es un salto de lag entre puntos contiguos que ninguna deriva puede
# explicar. La deriva mas bestia que se ha visto aqui (24 contra 23.976) son 7,2 s
# en DOS HORAS; entre dos puntos contiguos del muestreo eso es menos de 1 s. Asi
# que por encima de 1 s no es deriva: es que falta o sobra metraje.
PASO_MIN_S = 1.0
# Cuanto puede separarse un punto de la mediana de su tramo y seguir siendo del
# tramo. Holgado a proposito: el modo video muestrea a 12 fps (83 ms) y los puntos
# de un mismo tramo bailan varias muestras.
TOL_TRAMO_S = 0.5


def _tramos(res, paso_min=PASO_MIN_S, tol=TOL_TRAMO_S, pmin=0.5):
    """Parte los puntos en TRAMOS de lag constante. Devuelve [] si no hay dos.

    POR QUE EXISTE (14/08/2026). measure() ajustaba UNA RECTA a todos los puntos.
    Cuando los dos ficheros son montajes distintos eso no es una recta sino una
    ESCALERA, y ajustarle una recta da un alpha y una deriva que no existen.
    Medido con Toy Story 5 (un solo escalon de -42 s a mitad de pelicula): salio
    alpha=0.984 y deriva -89,6 s. Aplicar ese alpha habria resampleado el audio un
    1,6 %, o sea destrozarlo, para arreglar algo que era un corte de montaje.

    Se agrupa por MEDIANA acumulada y no por diferencias contra el vecino: un solo
    punto malo en medio partiria el tramo en tres. Un punto suelto que discrepa se
    marca como transicion (los tramos de 1 punto no cuentan como tramo).

    Solo entran puntos con pearson creible: los que no enganchan dan un lag
    aleatorio que se inventaria escalones a mansalva.
    """
    pts = sorted([p for p in res if p["pearson"] >= pmin], key=lambda p: p["_t"])
    if len(pts) < 3:
        return []

    grupos, actual = [], [pts[0]]
    for p in pts[1:]:
        med = sorted(q["_lag"] for q in actual)[len(actual) // 2]
        if abs(p["_lag"] - med) <= max(tol, paso_min * 0.5):
            actual.append(p)
        else:
            grupos.append(actual)
            actual = [p]
    grupos.append(actual)

    # Los grupos de 1 punto son ruido o ventanas que CABALGAN el corte (la ventana
    # contiene material de los dos lados y el pico sale a medio camino). No son un
    # tramo: se descartan del resultado pero su tiempo marca la zona de transicion.
    tramos = []
    for g in grupos:
        if len(g) < 2:
            continue
        lags = sorted(q["_lag"] for q in g)
        tramos.append({
            "desde_s": round(g[0]["_t"], 1),
            "hasta_s": round(g[-1]["_t"], 1),
            "lag_s":   round(lags[len(lags) // 2], 3),
            "lag_ms":  round(lags[len(lags) // 2] * 1000, 1),
            "sync_ms": round(-lags[len(lags) // 2] * 1000),
            "n":       len(g),
        })
    if len(tramos) < 2:
        return []
    # Solo es escalera si algun salto entre tramos contiguos supera el umbral.
    if not any(abs(tramos[i + 1]["lag_s"] - tramos[i]["lag_s"]) > paso_min
               for i in range(len(tramos) - 1)):
        return []
    return tramos


def _cobertura(tramos, dur_base, dur_src):
    """Que parte del DESTINO tiene audio disponible en el origen, y donde no.

    Distingue lo que antes se confundia: que falte MATERIAL no es estar
    desincronizado. El caso tipico son los creditos finales, mas largos en una
    version que en otra; tambien una escena que un montaje tiene y el otro no.
    Con esto el mux sabe donde meter silencio en vez de arrastrar el audio.

    El origen cubre src_t en [0, dur_src]; en un tramo de lag L, el instante T del
    destino se sirve con src_t = T + L, asi que el tramo cubre T en [-L, dur_src-L].
    """
    if not dur_base:
        return None
    if tramos:
        rangos = []
        for i, tr in enumerate(tramos):
            L = tr["lag_s"]
            # El tramo manda desde su primer punto (o desde 0 si es el primero)
            # hasta donde empiece el siguiente.
            ini = 0.0 if i == 0 else max(0.0, (tramos[i - 1]["hasta_s"] + tr["desde_s"]) / 2.0)
            fin = dur_base if i == len(tramos) - 1 else (tr["hasta_s"] + tramos[i + 1]["desde_s"]) / 2.0
            rangos.append((max(ini, -L), min(fin, dur_src - L)))
    else:
        rangos = [(0.0, dur_base)]

    rangos = [(a, b) for a, b in rangos if b > a]
    cubierto = sum(b - a for a, b in rangos)
    huecos = []
    cursor = 0.0
    for a, b in rangos:
        if a - cursor > 1.0:
            huecos.append({"desde_s": round(cursor, 1), "hasta_s": round(a, 1),
                           "dura_s": round(a - cursor, 1)})
        cursor = max(cursor, b)
    if dur_base - cursor > 1.0:
        huecos.append({"desde_s": round(cursor, 1), "hasta_s": round(dur_base, 1),
                       "dura_s": round(dur_base - cursor, 1), "final": True})
    return {"cubierto_s": round(cubierto, 1),
            "pct": round(100.0 * cubierto / dur_base, 1),
            "huecos": huecos}


# ------------------------------------------------- medir por PAQUETES ---
# Cuarto peldano (19/08/2026). Correlaciona la serie de BYTES POR TIEMPO de la
# pista de video: un corte de plano o una escena compleja es cara en CUALQUIER
# encode, asi que esa serie esta correlacionada entre dos masters distintos.
# Se lee con 'ffprobe -show_entries packet', que solo DEMULTIPLEXA: no decodifica
# nada. No necesita subtitulos, ni audios que se parezcan, ni capitulos.
#
# ALCANCE, medido sobre 9 parejas con verdad conocida: sirve para DESFASE FIJO y
# nada mas. Acierta a 1 fotograma entre encodes completamente distintos (HEVC
# 2160p contra x265 DV, dos x264 de rippers distintos), y en lo que no puede
# DECLINA en vez de inventarse un numero:
#
#   5 parejas de desfase fijo (verdad 0, -10, -2560 ms)  -> 89-100 % consenso, acierta
#   2 parejas de MONTAJES distintos (Alien 3)            ->    0 % consenso, declina
#   1 pareja con DERIVA de cadencia (25 contra 23.976)   ->    0 % consenso, declina
#
# Por que no vale para montajes distintos ni para deriva: hacen falta ventanas de
# ~300 s para que la estructura compartida emerja del ruido de rate-control (con
# 90 s solo engancha 1 de cada 4), y ni una deriva ni unas inserciones densas
# sobreviven a una ventana tan larga. En Alien 3 la escalera va de -4,5 s a
# +108,7 s sin repetir un solo valor: no existe ningun tramo de 300 s con lag
# constante. Es una limitacion estructural, no de ajuste.
#
# LO QUE NO SE PUEDE USAR COMO CREDIBILIDAD: ninguna metrica por ventana separa
# una ventana acertada de una fallada. Medido: a 600 s las ventanas que FALLAN
# tienen sharp medio MAS ALTO (1,45) que las que aciertan (1,38), y los pearson
# se solapan enteros. Manda el CONSENSO entre ventanas, y el margen es enorme
# (87-100 % cuando es medible contra 0 % cuando no).

PAQ_GRANO_S  = 0.20    # bin de la serie. Barrido de 1000 a 40 ms: de 500 a 60 ms
                       # el error es 0-160 ms; los dos extremos fallan. El de
                       # 40 ms se equivoca 600 ms porque manda el GOP.
PAQ_WIN_S    = 300.0   # 90 s -> 51 % de aciertos, 300 s -> 70 %, 600 s -> 82 %.
                       # 300 s es el punto donde ya resuelve sin perder tramos.
PAQ_TOL_S    = 0.9     # temblor del metodo. Por encima de 3 s el caso de deriva
                       # empieza a producir un tramo falso: hay 3x de margen.
PAQ_CONSENSO = 0.50    # fraccion minima de ventanas de acuerdo


def _paquetes(path):
    """(pts, tamanos) de los paquetes del v:0. Solo demultiplexa."""
    # TIMEOUT (02/09/2026). Era la UNICA llamada a subprocess de todo el lado
    # Python sin tope de tiempo, y es de las mas caras: demultiplexa la pelicula
    # ENTERA y medir_por_paquetes la llama DOS veces. Con un fichero roto -que en
    # esta biblioteca aparecen- ffprobe puede no volver nunca, y entonces el
    # worker del panel se queda colgado para siempre y la cola se para sin decir
    # nada. 900 s es el valor que ya usa el resto del fichero para lo pesado.
    # Se devuelve la MISMA forma que el fallo de ffprobe -(None, motivo)- para
    # que medir_por_paquetes pueda seguir diciendo CUAL de los dos fallo.
    try:
        r = subprocess.run(
            [FFPROBE, "-v", "error", "-select_streams", "v:0",
             "-show_entries", "packet=pts_time,size", "-of", "csv=p=0", path],
            capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        return None, "ffprobe no termino en 900 s (fichero danyado?)"
    if r.returncode:
        return None, "ffprobe fallo (%s)" % (r.stderr or "").strip()[:120]
    # PARSEO TOLERANTE (19/08/2026). Antes era 't_, s_ = ln.split(",")', que
    # exige EXACTAMENTE dos campos. ffprobe emite una coma final en algunos
    # ficheros ("0.000000,3286,"), asi que saltaba ValueError en TODAS las lineas
    # y el metodo contestaba "no se pudieron leer los paquetes" sobre ficheros
    # perfectamente sanos. Visto con los cinco Toy Story 5; el sync_paquetes.py
    # original tenia el mismo split, o sea que fallaba igual y sin decir por que.
    pts, siz, leidas = [], [], 0
    for ln in r.stdout.splitlines():
        if not ln:
            continue
        leidas += 1
        campos = ln.split(",")
        if len(campos) < 2:
            continue
        try:
            t_ = float(campos[0]); s_ = int(campos[1])
        except ValueError:
            continue      # paquetes sin timestamp (pts 'N/A'): se ignoran
        pts.append(t_); siz.append(s_)
    if len(pts) < 100:
        # Decir CUANTO se leyo y cuanto se pudo parsear: si vuelve a cambiar el
        # formato de ffprobe, el mensaje lo delata en vez de callarselo.
        return None, ("ffprobe devolvio %d lineas y solo %d parsearon como "
                      "(tiempo, tamano)" % (leidas, len(pts)))
    o = np.argsort(np.array(pts))
    return np.array(pts)[o], np.array(siz, dtype=float)[o]


def _serie_paq(pts, siz, bin_s, t0, t1):
    """Bytes por intervalo entre t0 y t1."""
    m = (pts >= t0) & (pts < t1)
    if not m.any():
        return np.zeros(1)
    k = ((pts[m] - t0) / bin_s).astype(np.int64)
    v = np.zeros(int(k.max()) + 1)
    np.add.at(v, k, siz[m])
    return v


def medir_por_paquetes(base_path, src_path, grano=PAQ_GRANO_S, win=PAQ_WIN_S,
                       search=40.0):
    """Desfase de src respecto a base por tamano de paquetes de video."""
    pa, sa = _paquetes(base_path)
    pb, sb = _paquetes(src_path)
    if pa is None or pb is None:
        # Decir CUAL de los dos y POR QUE: "no se pudieron leer los dos" no
        # permite ni empezar a diagnosticar.
        cual = []
        if pa is None: cual.append("base: %s" % sa)
        if pb is None: cual.append("origen: %s" % sb)
        return {"ok": False, "points": [], "mode": "paquetes",
                "error": "no se pudieron leer los paquetes de video (%s)"
                         % "; ".join(cual)}
    dur_a, dur_b = float(pa.max()), float(pb.max())
    dif = abs(dur_a - dur_b)
    if dif > search:                     # misma logica que measure()
        search = min(300.0, max(search, dif * 1.2 + 30.0))

    # Se empieza DESPUES de 'search': una ventana en T<search no puede encontrar
    # un lag negativo (el origen no puede empezar antes de 0) y devuelve un cero
    # o un tope que luego contamina el consenso.
    res, T = [], search + 5.0
    while T + win <= dur_a:
        b0 = max(0.0, T - search)
        a = _serie_paq(pa, sa, grano, T, T + win)
        b = _serie_paq(pb, sb, grano, b0, T + win + search)
        La, Lb = len(a), len(b)
        if Lb > La:
            an = (a - a.mean()) / (a.std() or 1)
            bn = (b - b.mean()) / (b.std() or 1)
            _corr(an, bn, 1.0 / grano, T, b0, res)
        T += win / 2.0                   # ventanas solapadas

    if len(res) < 3:
        return {"ok": False, "points": res, "mode": "paquetes",
                "error": "pocas ventanas validas (%d): los ficheros son "
                         "demasiado cortos para este metodo, que necesita "
                         "ventanas de %d s" % (len(res), int(win))}

    # EL CONSENSO VA PRIMERO, y las dos puertas de abajo son RELATIVAS al numero
    # de ventanas. Con las puertas absolutas que trae _tramos() (grupos de >=2
    # puntos) esta misma pareja de montajes distintos salia como "ESCALERA de 9
    # tramos": 9 grumos de ruido presentados como estructura, con su desfase
    # cada uno. Un veredicto de 'conformar' acertado por casualidad pero con
    # nueve numeros inventados dentro (19/08/2026).
    # LA ESCALERA SE MIRA SIEMPRE, Y ANTES QUE EL CONSENSO. Fue un error ponerlo
    # al reves (19/08/2026): el consenso es una MAYORIA, y si un tramo se come
    # mas de la mitad de la pelicula gana la votacion y la escalera desaparece.
    # Medido con Toy Story 5, HDTC contra DCPRIP: el escalon de +42 s cae en el
    # minuto 18, o sea que solo el 19 % del metraje esta en el primer tramo ->
    # 85 % de consenso en el segundo y salia "FIJO +42000 ms, action=sync". Ese
    # --sync habria desincronizado los primeros 18 minutos por 42 SEGUNDOS.
    # Las puertas siguen siendo relativas: cada tramo >=10 % de las ventanas y
    # entre todos >=50 %. Con las puertas absolutas de _tramos() (grupos de >=2)
    # una pareja de montajes distintos daba 9 tramos de puro ruido.
    # ANTES DE HABLAR DE ESCALERA, DESCARTAR QUE SEA UNA DERIVA (19/08/2026).
    # Una deriva muestreada por ventanas da lags que suben poco a poco, y
    # _tramos() los agrupa en bandas: sale una "escalera" perfecta que en
    # realidad es una recta. Probado con una deriva sintetica del 0,1 % (el caso
    # clasico 23,976 contra 24, 5,7 s en toda la peli): devolvia 5 tramos con
    # lags +400/+1000/+2000/+3600/+5000 ms -monotonos crecientes, la firma de una
    # recta- y action='conformar', o sea "son montajes distintos". Diagnostico
    # equivocado. La deriva del 4,3 % no colaba porque ahi ni siquiera hay
    # consenso, pero la LENTA es justo la que hay que distinguir bien.
    #
    # Se separa por la forma: una escalera son tramos PLANOS con SALTOS, asi que
    # ninguna recta la explica; una deriva cae sobre la recta dentro del propio
    # temblor del metodo. Se usa el residuo MEDIANO, no el maximo, para que unas
    # pocas ventanas malas no disfracen una deriva de escalera.
    _t = np.array([p["_t"] for p in res], float)
    _l = np.array([p["_lag"] for p in res], float)
    _pend, _ord = np.polyfit(_t - _t.mean(), _l, 1)
    _resid_med = float(np.median(np.abs(_l - (_pend * (_t - _t.mean()) + _ord))))
    _deriva = abs(float(_pend)) * (_t.max() - _t.min())
    if _resid_med <= PAQ_TOL_S / 2 and _deriva > 2 * PAQ_TOL_S:
        return {"ok": False, "points": res, "mode": "paquetes",
                "error": "los desfases caen sobre una RECTA (%+.1f s de deriva a "
                         "lo largo de la pelicula, residuo mediano %.0f ms): esto "
                         "no es un desfase fijo ni un montaje distinto, es una "
                         "DERIVA de cadencia. Este metodo no sabe medirla -haria "
                         "falta ventana corta, y con ventana corta no resuelve-: "
                         "mide por imagen, que da el alpha fino."
                         % (_deriva, _resid_med * 1000)}

    nmin = max(3, int(0.10 * len(res)))
    tramos = [t for t in _tramos(res, tol=PAQ_TOL_S, pmin=0.0)
              if t["n"] >= nmin]
    cubre = sum(t["n"] for t in tramos) / len(res)
    if len(tramos) >= 2 and cubre >= PAQ_CONSENSO:
        return {"ok": True, "escalera": True, "tramos": tramos,
                "mode": "paquetes", "alpha": 1.0,
                "cobertura": _cobertura(tramos, dur_a, dur_b),
                "beta_ms": max(tramos, key=lambda t: t["n"])["lag_ms"],
                "drift_ms": 0.0, "drift_se_ms": None, "residual_ms": 0.0,
                "used": sum(t["n"] for t in tramos), "total": len(res),
                "points": res, "precision_ms": int(grano * 1000)}

    lags = np.array([p["_lag"] for p in res])
    med = float(np.median(lags))
    de_acuerdo = int((np.abs(lags - med) <= PAQ_TOL_S).sum())
    frac = de_acuerdo / len(res)

    if frac < PAQ_CONSENSO:
        return {"ok": False, "points": res, "mode": "paquetes",
                "error": "las ventanas no se ponen de acuerdo (solo %d de %d, "
                         "%.0f %%) y tampoco forman tramos que cubran la "
                         "pelicula: por tamano de paquetes no se puede medir "
                         "esta pareja. Suele significar montajes distintos con "
                         "muchos cortes, o cadencias distintas; prueba por "
                         "subtitulos o imagen."
                         % (de_acuerdo, len(res), 100 * frac)}

    buenos = [p for p in res if abs(p["_lag"] - med) <= PAQ_TOL_S]
    beta = float(np.median([p["_lag"] for p in buenos]))
    return {
        "ok": True, "escalera": False, "mode": "paquetes",
        # Este metodo NO mide deriva: para verla harian falta ventanas cortas y
        # con ventanas cortas no resuelve. Se declara alpha=1 y deriva 0 en vez
        # de ajustar una recta a la que no se le puede creer la pendiente.
        "alpha": 1.0, "beta_ms": round(beta * 1000, 1),
        "drift_ms": 0.0, "drift_se_ms": None,
        "residual_ms": round(float(np.abs(
            np.array([p["_lag"] for p in buenos]) - beta).max()) * 1000, 1),
        "used": len(buenos), "total": len(res),
        "consenso_pct": round(100 * frac, 1),
        "precision_ms": int(grano * 1000),
        "points": res,
        "cobertura": _cobertura(
            [{"desde_s": 0.0, "hasta_s": dur_a, "lag_s": beta,
              "lag_ms": round(beta * 1000, 1), "sync_ms": round(-beta * 1000),
              "n": len(buenos)}], dur_a, dur_b),
    }


# ------------------------------ VOZ contra SUBTITULOS del MISMO fichero ---
# CUARTA forma de medir, y la unica que mira DENTRO de un solo fichero.
#
# POR QUE (02/09/2026). Las otras tres comparan DOS ficheros: contestan si la
# pista que traes va a la par de la REFERENCIA, no si el conjunto va a la par de
# la IMAGEN. Midiendo un MKV suelto -"quiero comprobar esta peli"- la referencia
# es otra pista del mismo fichero, asi que si el release trae TODOS los audios
# corridos medio segundo respecto al video, la medida sale +7 ms y el panel dice
# "ya esta sincronizada" mientras los labios van descuadrados. Es un punto ciego
# de las tres, no un fallo de ninguna: encontrado con «Star Trek into Darkness
# 2013 IMAX REPACK», donde el usuario tuvo que dar con el -500 a ojo.
# La casilla de imagen tampoco lo cubre: compara el video del base con el video
# del origen, y con un solo fichero eso es cero por definicion.
#
# LA IDEA. Los tiempos de un subtitulo estan escritos contra la IMAGEN: el
# subtitulador los cuadra VIENDO la pelicula. Son, por tanto, un testigo del
# video que no depende del audio. Comparando cuando aparece cada subtitulo con
# cuando empieza a hablarse de verdad en la pista sale el desfase del fichero
# contra su propia imagen, sin decodificar un solo fotograma de video.
#
# PRECISION, y hay que decirla clara: los tiempos de un subtitulo son DE AUTOR.
# Un subtitulo entra tipicamente entre 0 y 300 ms ANTES de la voz, y ese margen
# cambia de un estudio a otro. Esto NO afina un desfase: caza el error GRUESO
# (>=400 ms), que es justo el que se ve en los labios y el que las otras tres no
# pueden ver. Para el milisegundo sigue mandando la envolvente de audio.
#
# POR QUE EL CANAL CENTRAL. En una mezcla 5.1 el dialogo vive casi entero en el
# central, y separarlo es lo que convierte "hay energia" en "hay voz": con la
# mezcla completa, la musica y los efectos mantienen el nivel alto entre frases
# y los arranques dejan de existir. Con 2 canales no hay central y se mezcla a
# mono, que engancha peor pero todavia sirve en pistas de dialogo limpio.

VOZ_BIN_S     = 0.02   # bloque de la envolvente: 20 ms
VOZ_TRAMO_S   = 30.0   # cada cuanto se recalcula el umbral de "aqui hay voz"
VOZ_RANGO_DB  = 6.0    # si un tramo no tiene ni esta horquilla, no hay dialogo
VOZ_MIN_VOZ_S = 0.12   # una intervencion mas corta que esto no cuenta
VOZ_HUECO_S   = 0.18   # respiros mas cortos que esto no parten una intervencion
VOZ_SESGO_S   = 0.15   # un subtitulo entra ~150 ms ANTES de la voz...
VOZ_MARGEN_S  = 0.25   # ...con este vaiven de un estudio a otro
VOZ_MAX_OFF_S = 4.0    # rango de busqueda del desfase
VOZ_HIST_S    = 0.10   # bin del histograma de diferencias
VOZ_MIN_PARES = 40     # menos dialogos casados que esto no es una medida
VOZ_MIN_FRAC  = 0.20   # ...ni menos de esta fraccion de los subtitulos


def _envolvente_voz(path, index, centro, sr=4000, bin_s=VOZ_BIN_S):
    """Envolvente de volumen de una pista de audio ENTERA, leida por tuberia.

    4 kHz basta: aqui no se escucha nada, solo se mide energia. Y se consume
    SEGUN LLEGA, acumulando ya la envolvente (50 valores por segundo), en vez de
    juntar el PCM entero: una pelicula de 2 h son 57 MB de PCM a 4 kHz y este
    proceso vive encendido semanas -el mismo motivo por el que arriba se limita
    OpenBLAS a un hilo-. Asi el pico de memoria queda en unos pocos MB.

    stderr va a un fichero temporal a proposito: con stderr=PIPE y sin leerlo
    hasta el final, un ffmpeg que escupa muchos avisos llena el buffer de la
    tuberia y se queda bloqueado para siempre.
    """
    n = int(sr * bin_s)
    cmd = [FFMPEG, "-v", "error", "-i", path, "-map", "0:%d" % index]
    if centro:
        # c2 por INDICE, no 'FC' por nombre: hay pistas de 6 canales que llegan
        # sin layout declarado y 'pan=mono|c0=FC' falla al montar el filtro. El
        # orden estandar es L R C LFE ... en 5.1 y en 7.1, asi que c2 es el
        # central en las dos.
        cmd += ["-af", "pan=mono|c0=c2"]
    cmd += ["-ac", "1", "-ar", str(sr), "-f", "s16le", "-"]
    errf = tempfile.TemporaryFile()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=errf)

    # VIGILANTE (02/09/2026). p.stdout.read() BLOQUEA. Si ffmpeg se atasca con un
    # fichero danyado -que en esta biblioteca aparecen- este bucle no vuelve
    # NUNCA, y entonces el worker del panel se queda parado para siempre y la
    # cola se para sin decir nada. Es exactamente el fallo que se tapo el mismo
    # dia en _paquetes(), pero alli bastaba el 'timeout=' de subprocess.run y
    # aqui no lo hay: esto lee la tuberia a mano a proposito, para no juntar los
    # 57 MB de PCM de una pelicula en memoria.
    #
    # Un temporizador mata al hijo; entonces read() devuelve b'' y el bucle sale
    # solo. Se anota aparte que ha caducado porque desde fuera un hijo matado se
    # parece demasiado a un hijo que fallo, y el mensaje tiene que decir cual de
    # las dos cosas paso.
    caducado = []

    def _matar():
        caducado.append(True)
        try:
            p.kill()
        except Exception:
            pass

    reloj = threading.Timer(FFMPEG_MAX_S, _matar)
    reloj.daemon = True
    reloj.start()

    partes, resto = [], b""
    try:
        while True:
            buf = p.stdout.read(1 << 20)
            if not buf:
                break
            buf = resto + buf
            usable = (len(buf) // (2 * n)) * (2 * n)
            resto = buf[usable:]
            if usable:
                x = np.frombuffer(buf[:usable], dtype=np.int16).astype(np.float32)
                partes.append(np.abs(x).reshape(-1, n).mean(axis=1))
    finally:
        reloj.cancel()
        p.stdout.close()
        # El wait tambien se protege: si saltara aqui dentro, la excepcion
        # sustituiria al valor que se estaba devolviendo y el hijo quedaria vivo.
        try:
            p.wait(timeout=120)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=30)
        errf.seek(0)
        err = errf.read().decode("utf-8", "ignore").strip()
        errf.close()
    if caducado:
        return None, ("ffmpeg no termino en %d s decodificando el audio "
                      "(fichero danyado?)" % FFMPEG_MAX_S)
    if p.returncode or not partes:
        return None, (err[-160:] or "ffmpeg no devolvio audio")
    return np.concatenate(partes).astype(np.float64), None


def _inicio_pista(path, index):
    """pts del PRIMER paquete de una pista, en la linea de tiempo del contenedor.

    HACE FALTA (02/09/2026, encontrado probando). La envolvente sale de PCM
    CRUDO, y un formato crudo no lleva tiempos: ffmpeg entrega las muestras
    decodificadas uno detras de otro empezando en cero. O sea que un retardo
    guardado EN EL CONTENEDOR -que es justo como lo escribe 'mkvmerge --sync' y
    como vienen los delays de muchos releases- se perdia por el camino y esta
    medida no lo veia. Comprobado: un fichero con --sync 1:500 daba exactamente
    lo mismo que el original.
    Sumando este t0 a los arranques de voz, la envolvente vuelve a la linea de
    tiempo del fichero, que es donde ya estan los subtitulos.
    """
    r = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", str(index),
         "-read_intervals", "%+#1", "-show_entries", "packet=pts_time",
         "-of", "csv=p=0", path],
        capture_output=True, text=True, timeout=120)
    for linea in (r.stdout or "").splitlines():
        linea = linea.strip().rstrip(",")
        if linea and linea != "N/A":
            try:
                return float(linea)
            except ValueError:
                pass
    return 0.0


def _voz_onsets(env, hz):
    """Instantes (s) en que ARRANCA una intervencion hablada.

    Umbral ADAPTATIVO por tramos de 30 s: uno global no vale porque una pelicula
    tiene escenas susurradas y escenas de accion, y un solo corte o se come los
    dialogos flojos o da por hablada una batalla entera. En cada tramo el corte
    va a medio camino entre su fondo (percentil 20) y lo mas fuerte (percentil
    90); si esa horquilla es estrecha, ahi no hay dialogo que separar y el tramo
    se descarta entero en vez de inventarse arranques a base de ruido.
    """
    db = 20.0 * np.log10(env + 1.0)
    tramo = max(1, int(VOZ_TRAMO_S * hz))
    umbral = np.empty_like(db)
    for i in range(0, len(db), tramo):
        t = db[i:i + tramo]
        p20, p90 = np.percentile(t, 20), np.percentile(t, 90)
        umbral[i:i + tramo] = (p20 + 0.45 * (p90 - p20)
                               if (p90 - p20) >= VOZ_RANGO_DB else np.inf)
    v = (db > umbral).astype(np.int8)
    d = np.diff(np.concatenate(([0], v, [0])))
    ini, fin = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
    if not len(ini):
        return np.array([])
    # Se cierran los respiros cortos ANTES de exigir duracion minima: si no, una
    # frase con una coma en medio cuenta como dos arranques y el segundo es
    # ruido que no casa con ningun subtitulo.
    hueco  = max(1, int(VOZ_HUECO_S * hz))
    minimo = max(1, int(VOZ_MIN_VOZ_S * hz))
    ii, ff = [int(ini[0])], [int(fin[0])]
    for a, b in zip(ini[1:], fin[1:]):
        if a - ff[-1] <= hueco:
            ff[-1] = int(b)
        else:
            ii.append(int(a)); ff.append(int(b))
    ii, ff = np.array(ii), np.array(ff)
    return ii[(ff - ii) >= minimo] / float(hz)


def _cue_inicios(path, index, max_cues=8000):
    """Instantes en que APARECE cada subtitulo. No descodifica nada.

    A diferencia de _cues(), que devuelve el pts de TODOS los paquetes, aqui hay
    que quedarse con los INICIOS: en PGS viene ademas el paquete que borra el
    subtitulo, y un borrado no marca ningun dialogo. Se filtran por duracion
    (>=0,3 s), que es lo que separa una aparicion de un borrado. Si la pista no
    declara duraciones se usan todos: el histograma tolera los que sobran, solo
    pierde algo de nitidez.
    """
    r = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", str(index),
         "-show_entries", "packet=pts_time,duration_time", "-of", "csv=p=0", path],
        capture_output=True, text=True, timeout=900)
    todos, largos = [], []
    for linea in (r.stdout or "").splitlines():
        campos = [c for c in linea.strip().split(",") if c and c != "N/A"]
        if not campos:
            continue
        try:
            t = float(campos[0])
        except ValueError:
            continue
        todos.append(t)
        if len(campos) > 1:
            try:
                if float(campos[1]) >= 0.3:
                    largos.append(t)
            except ValueError:
                pass
    ts = sorted(largos if len(largos) >= 20 else todos)
    return np.array(ts[:max_cues], dtype=float)


def _sub_para_voz(pr, lang):
    """Que pista de subtitulos usar como testigo de la imagen.

    Se prefiere el MISMO idioma que el audio -son los dialogos de esa voz- y NO
    forzada: una pista forzada solo trae las lineas en otro idioma, o sea cuatro
    marcas sueltas que no dan para medir nada.
    """
    subs = [t for t in pr["tracks"] if t["type"] == "subtitle"]
    for cond in (lambda t: t["lang"] == lang and not t["forced"],
                 lambda t: t["lang"] == lang,
                 lambda t: not t["forced"],
                 lambda t: True):
        for t in subs:
            if cond(t):
                return t
    return None


def medir_voz_contra_subs(path, audio_index=None, sub_index=None,
                          max_off=VOZ_MAX_OFF_S):
    """Desfase de una pista de audio contra la IMAGEN de su propio fichero.

    Metodo: histograma de las diferencias (arranque de voz - aparicion del
    subtitulo) de todos los pares cercanos, igual que medir_por_subtitulos()
    hace entre dos ficheros. Los pares que no casan simplemente no votan.

    Devuelve `desfase_ms` (positivo = el audio va TARDE respecto a la imagen) y
    el `sync_ms` que lo corrige, ya con el signo del panel.
    """
    pr = probe(path)
    auds = [t for t in pr["tracks"] if t["type"] == "audio"]
    if not auds:
        return {"ok": False, "mode": "voz", "error": "el fichero no tiene audio"}
    if audio_index is None:
        a = auds[0]
    else:
        a = next((t for t in auds if t["index"] == audio_index), None)
        if a is None:
            return {"ok": False, "mode": "voz",
                    "error": "la pista %d no es de audio" % audio_index}
    if sub_index is None:
        s = _sub_para_voz(pr, a["lang"])
    else:
        s = next((t for t in pr["tracks"]
                  if t["type"] == "subtitle" and t["index"] == sub_index), None)
    if s is None:
        return {"ok": False, "mode": "voz",
                "error": "el fichero no trae subtitulos, y sin ellos no hay "
                         "ningun testigo de la imagen con el que comparar la voz"}

    cues = _cue_inicios(path, s["index"])
    if len(cues) < VOZ_MIN_PARES:
        return {"ok": False, "mode": "voz",
                "error": "solo %d subtitulos en la pista [%s]: muy pocos para medir"
                         % (len(cues), s["lang"])}

    # 5 canales o mas = hay central donde vive el dialogo.
    centro = (a.get("channels") or 2) >= 5
    env, err = _envolvente_voz(path, a["index"], centro)
    if env is None and centro:
        centro = False                        # el central no se pudo extraer
        env, err = _envolvente_voz(path, a["index"], False)
    if env is None:
        return {"ok": False, "mode": "voz",
                "error": "no se pudo decodificar el audio (%s)" % (err or "?")}
    onsets = _voz_onsets(env, 1.0 / VOZ_BIN_S) + _inicio_pista(path, a["index"])
    if len(onsets) < VOZ_MIN_PARES:
        return {"ok": False, "mode": "voz",
                "error": "solo %d arranques de voz en la pista: la mezcla no deja "
                         "separar el dialogo (se uso %s)"
                         % (len(onsets), "el canal central" if centro
                            else "la mezcla a mono")}

    difs, dueno = [], []
    for i, c in enumerate(cues):
        lo = np.searchsorted(onsets, c - max_off)
        hi = np.searchsorted(onsets, c + max_off)
        for o in onsets[lo:hi]:
            difs.append(o - c)
            dueno.append(i)
    if len(difs) < VOZ_MIN_PARES:
        return {"ok": False, "mode": "voz",
                "error": "los subtitulos y la voz no se solapan en el tiempo: "
                         "revisa que la pista de subtitulos sea de esta pelicula"}
    difs, dueno = np.array(difs), np.array(dueno)
    bordes = np.arange(-max_off, max_off + VOZ_HIST_S, VOZ_HIST_S)
    hist, _ = np.histogram(difs, bins=bordes)
    centros = (bordes[:-1] + bordes[1:]) / 2.0
    k = int(np.argmax(hist))
    pico = float(centros[k])
    # Nitidez, con el mismo criterio que _corr(): cuanto destaca el pico sobre el
    # mejor rival LEJANO. Sin esto, una nube de coincidencias casuales puede
    # tener un maximo y pasar por medida.
    lejos = np.abs(centros - pico) > 0.5
    rival = float(hist[lejos].max()) if lejos.any() else 0.0
    nitidez = float(hist[k] / rival) if rival > 0 else 99.0
    # Afinado con las diferencias de verdad: el centro del bin arrastra medio bin
    # de sesgo (misma correccion que en medir_por_subtitulos).
    cerca = np.abs(difs - pico) <= VOZ_HIST_S * 1.5
    fino = float(np.median(difs[cerca]))
    n_cues = int(len(np.unique(dueno[cerca])))
    frac = n_cues / float(len(cues))
    if n_cues < VOZ_MIN_PARES or frac < VOZ_MIN_FRAC or nitidez < 1.3:
        return {"ok": False, "mode": "voz",
                "error": "la voz no casa con los subtitulos (%d de %d dialogos, "
                         "%.0f %%, nitidez %.1f): no se puede afirmar nada. Suele "
                         "ser una mezcla en la que el dialogo no se separa, o unos "
                         "subtitulos que no son de este montaje."
                         % (n_cues, len(cues), 100 * frac, nitidez)}

    desfase = fino - VOZ_SESGO_S
    return {
        "ok": True, "mode": "voz",
        "voz_ms": round(fino * 1000, 1),        # crudo: voz - subtitulo
        "sesgo_ms": int(VOZ_SESGO_S * 1000),    # lo que se le descuenta y por que
        "desfase_ms": int(round(desfase * 1000)),
        "sync_ms": int(round(-desfase * 1000)),
        "margen_ms": int(VOZ_MARGEN_S * 1000),
        "sospecha": bool(abs(desfase) > VOZ_MARGEN_S),
        "n": n_cues, "total": int(len(cues)), "frac_pct": round(100 * frac, 1),
        "nitidez": round(nitidez, 2), "onsets": int(len(onsets)),
        "audio_index": a["index"], "audio_lang": a["lang"],
        "sub_index": s["index"], "sub_lang": s["lang"], "sub_codec": s["codec"],
        "canal": "central" if centro else "mezcla",
    }


def measure(base_path, base_index, src_path, src_index,
            points=None, win=90.0, search=30.0, duration=None, mode="audio",
            _sin_reintento=False, _denso=False,
            permitir=("paquetes", "subs", "video"), intentos=None):
    """Desfase de src respecto a base. Devuelve alpha, beta y los puntos.

    intentos: si se pasa un dict, se escribe en el lo que la escalera automatica
    haya llegado a medir ('paquetes', 'subs', 'video' -> su resultado), lo haya
    elegido o no como respuesta. Sirve para que quien llama REUTILICE esas
    medidas en vez de repetirlas: la pasada por imagen puede costar 10-15 min
    (ver el bloque de REINTENTO 2), y el panel la volvia a lanzar entera como
    "segunda opinion" justo despues de que la escalera la hubiera hecho (15/09).

    Ventana de busqueda +-`search` s: si el desfase real la excede, el pico cae
    fuera y la medida es basura. Por eso se reporta `pearson` y `nitidez` de cada
    punto: sin ellos no se distingue un enganche bueno de uno aleatorio.

    mode='audio' (por defecto): correlaciona envolventes de volumen. Es lo de
    siempre y lo que se usa salvo que se pida otra cosa.

    mode='video': correlaciona la luminancia media por fotograma. Sirve para los
    casos en que el audio no engancha -mezclas rehechas, pistas sin nada en
    comun- y da un alpha mas fino cuando lo que se busca es una diferencia de
    CADENCIA (23.976 contra 24 son 7,2 s de deriva en dos horas), porque los
    cortes de plano son transiciones mucho mas nitidas que la envolvente de
    volumen. A cambio es bastante mas lento: hay que decodificar video.
    En modo video los indices de pista se IGNORAN: se usa el v:0 de cada fichero,
    porque lo que se mide es la linea de tiempo del FICHERO.

    mode='paquetes': correlaciona el TAMANO DE LOS PAQUETES de video. Solo
    demultiplexa. Da desfase FIJO a un fotograma sin necesitar subtitulos ni que
    los audios se parezcan; no sabe medir deriva y declina ante montajes
    distintos. Ver la nota larga de medir_por_paquetes().

    permitir: que peldanos puede usar la escalera automatica si el audio no
    engancha. Por defecto los tres ('paquetes','subs','video'), y se prueban en
    ese orden: de menos a mas caro y de menos a mas exigente con lo que los
    ficheros tengan dentro. Pasar ('subs',) o () lo limita -util cuando quien
    llama ya sabe que la pasada de imagen no le compensa: cuesta ~200 s en un
    fichero grande.
    """
    if mode == "subs":
        return medir_por_subtitulos(base_path, src_path, base_index, src_index)
    if mode == "paquetes":
        return medir_por_paquetes(base_path, src_path)

    pb, ps = probe(base_path), probe(src_path)
    if duration is None:
        duration = min(pb["duration"], ps["duration"])

    # VENTANA DE BUSQUEDA SEGUN LO DISTINTAS QUE SEAN LAS DURACIONES (14/08/2026).
    # Los +-30 s de siempre valen cuando los dos ficheros son el mismo montaje. Si
    # duran muy distinto, el desfase puede ser mucho mayor y entonces el pico ni
    # siquiera se pega al borde -donde se detectaria-: la correlacion encuentra un
    # maximo ESPURIO dentro de la ventana y devuelve un numero con buena pinta.
    # Paso en Toy Story 5: offset real -42 s con ventana de 30, y salio +9,5 s.
    # Los ficheros diferian 328 s, que era el aviso desde el principio.
    # Si duran lo mismo (el caso normal) esto no cambia nada.
    dif_dur = abs(pb["duration"] - ps["duration"])
    if dif_dur > search:
        search = min(300.0, max(search, dif_dur * 1.2 + 30.0))

    # Las dos puntas TIENEN que ser audio: esto correlaciona formas de onda.
    # Antes no se comprobaba, y pedir la medida de un subtitulo (el panel ofrecia
    # el boton en todas las pistas) acababa en "pocas ventanas validas", que no
    # dice nada del problema real. Un subtitulo no tiene forma de onda que
    # correlacionar; su desfase se hereda del AUDIO del mismo fichero, porque lo
    # que se mide es la linea de tiempo del FICHERO, no la de la pista.
    def _tipo(pr, idx):
        for t in pr["tracks"]:
            if t["index"] == idx:
                return t["type"]
        return None

    # En modo VIDEO no se valida nada de esto: no se usa ninguna pista de audio,
    # se mide sobre el v:0 de cada fichero.
    if mode != "video":
        for etq, pr, idx in (("base", pb, base_index), ("origen", ps, src_index)):
            ty = _tipo(pr, idx)
            if ty != "audio":
                return {"ok": False, "points": [], "error":
                        "la pista %d de %s no es audio (es %s): el desfase se mide "
                        "correlacionando formas de onda, asi que solo puede medirse "
                        "entre pistas de audio" % (idx, etq, ty or "inexistente")}
    else:
        for etq, pr, pth in (("base", pb, base_path), ("origen", ps, src_path)):
            if not any(t["type"] == "video" for t in pr["tracks"]):
                return {"ok": False, "points": [], "error":
                        "%s no tiene pista de video: no se puede medir por imagen"
                        % etq}

    # OJO: 'points' se reasigna justo debajo, asi que si mas adelante hace falta
    # saber si los eligio el llamante o los pusimos nosotros, hay que apuntarlo
    # AHORA. (El reintento denso comprobaba 'points is None' aqui abajo y nunca se
    # cumplia: para entonces ya valia la lista por defecto.)
    puntos_automaticos = points is None
    if points is None:
        # 4 puntos repartidos, evitando creditos de inicio y fin
        points = [duration * f for f in (0.12, 0.35, 0.60, 0.85)]

    tmpdir = BIGTMP if os.path.isdir(BIGTMP) else tempfile.gettempdir()
    work = tempfile.mkdtemp(prefix="_rmx_", dir=tmpdir)
    res = []
    try:
        for T in points:
            if mode == "video":
                # Misma estructura que la rama de audio: ventana estrecha en la
                # base, ventana ancha en el origen, y el mismo recorte a 0 del
                # inicio (con -ss negativo ffmpeg empieza en 0 y el lag saldria
                # desplazado en silencio).
                b_start = max(0.0, T - search)
                ae, er = _lum(base_path, T, win)
                be, _  = _lum(src_path, b_start, win + 2 * search)
                if ae is None or be is None or len(be) <= len(ae):
                    continue
                _corr(ae, be, er, T, b_start, res)
                continue

            a_wav = os.path.join(work, f"a{int(T)}.wav")
            b_wav = os.path.join(work, f"b{int(T)}.wav")
            if not _wav(base_path, base_index, T, win, a_wav):
                continue
            # El inicio de la ventana de busqueda NO puede ser negativo: con
            # -ss negativo ffmpeg empieza en 0 y el segmento deja de estar donde
            # creemos, asi que el lag sale desplazado en silencio. Solo pasaba con
            # ficheros de menos de ~4 min (T=0.12*dur < search), pero el error era
            # mudo. Se recorta y se usa el inicio REAL en la formula del lag.
            b_start = max(0.0, T - search)
            if not _wav(src_path, src_index, b_start, win + 2 * search, b_wav):
                continue
            ae, er = _env(a_wav)
            be, _  = _env(b_wav)
            if ae is None or be is None or len(be) <= len(ae):
                continue
            _corr(ae, be, er, T, b_start, res)
    finally:
        try:
            for f in os.listdir(work): os.remove(os.path.join(work, f))
            os.rmdir(work)
        except Exception:
            pass

    # Solo los puntos con enganche creible entran en el ajuste. Sin este filtro
    # un punto malo arrastra el alpha y se inventa una deriva que no existe.
    good = [p for p in res if p["pearson"] >= 0.35 and p["sharp"] >= 1.3]

    # Peldanos que se han probado y han declinado, para poder decirlo al final.
    _intentos = []

    # -- REINTENTO 1: la ventana de busqueda se ha quedado corta ---------------
    # Si los picos se apoyan en el borde, el desfase real esta FUERA de +-search
    # y lo medido no vale (ver el bloque de 'edge' en _corr). Se reintenta una vez
    # con la ventana muy ancha antes de contestar. Sin esto, la respuesta era un
    # alpha inventado con pinta de valido.
    if not _sin_reintento and res:
        en_borde = [p for p in res if p.get("edge")]
        if len(en_borde) >= max(2, len(res) // 2) and search < 300:
            # points=None si los elegimos nosotros: si se pasan los ya calculados,
            # el hijo cree que se los pidieron a mano y se salta sus reintentos.
            ancho = measure(base_path, base_index, src_path, src_index,
                            points=(None if puntos_automaticos else points),
                            win=win, search=min(search * 8, 300.0),
                            duration=duration, mode=mode, _sin_reintento=True)
            if ancho.get("ok"):
                ancho["ventana_ampliada"] = True
                ancho["search_usado"] = min(search * 8, 300.0)
                return ancho

    # -- REINTENTO 2: el audio no engancha -> SUBTITULOS y luego IMAGEN --------
    # ORDEN CAMBIADO EL 17/08/2026, con los tres peldanos cronometrados sobre un
    # fichero de 17,6 GB (pista spa contra eng, que no engancha por audio):
    #     audio 4 puntos ....  2,0 s
    #     SUBTITULOS ....... 46,4 s   (solo demultiplexa)
    #     IMAGEN .......... 199,1 s   (decodifica video)
    # El mas barato se probaba el ULTIMO. Y ademas, cuando los subtitulos dicen
    # que hay ESCALERA (montajes distintos), la pasada de imagen no habria
    # servido para nada: la recomendacion ya no es un desfase fijo sino
    # 'conformar'. Asi que ese caso se corta aqui y se ahorran ~200 s.
    #
    # Lo que NO cambia: si hay un solo tramo, los subtitulos dan la ESTRUCTURA
    # pero no el milisegundo (+-200 ms, son tiempos de autor), asi que se sigue
    # a imagen para afinar, que muestrea a ~83 ms. La precision no se sacrifica.
    #
    # 'permitir' deja al llamante elegir que peldanos se pueden usar. Por defecto
    # los dos, que es la red que se puso el 14/08 para que esto funcione sin que
    # el usuario tenga que saber marcar ninguna casilla.
    if mode != "video" and not _sin_reintento and len(good) < 2:
        # SIN PELDANOS PERMITIDOS: no se puede medir, y hay que DECIRLO.
        # Medido el 18/08/2026: con 0 de 4 puntos creibles, esta funcion devolvia
        # ok=True y beta=-66,3 ms. Un numero con buena pinta salido de nada, que
        # es justo el fallo que motivo la escalera del 14/08. Mas puntos no lo
        # arreglan: con 4, 6 y 8 salieron 0 creibles igual (el contenido no
        # correlaciona, no es cuestion de muestrear mejor).
        if not permitir:
            return {"ok": False, "points": res, "mode": mode,
                    "error": ("el audio no engancho: %d de %d puntos creibles. "
                              "Marca 'por paquetes de video' (coste = leer los dos "
                              "ficheros, da el desfase fijo a un fotograma), 'por "
                              "subtitulos' (~46 s, da la estructura) o 'por imagen' "
                              "(~199 s, mas fino) para medirlo de otra forma."
                              % (len(good), len(res)))}
        # PELDANO POR PAQUETES, antes que subtitulos (19/08/2026). Va primero
        # porque no necesita que los ficheros traigan subtitulos -el caso Toy
        # Story 5 era justo ese: ninguno de los dos los traia y acabo en la
        # pasada de imagen, ~200 s- y porque cuando contesta, contesta con el
        # 87-100 % de las ventanas de acuerdo. Solo sabe dar DESFASE FIJO; si no
        # puede, declina y se sigue bajando la escalera como siempre.
        if "paquetes" in permitir:
            paq = medir_por_paquetes(base_path, src_path)
            if intentos is not None:
                intentos["paquetes"] = paq
            if not paq.get("ok"):
                # Que se intento y por que no salio tiene que llegar al usuario:
                # si no, un peldano que ha costado leer los dos ficheros enteros
                # desaparece del mensaje final y parece que la casilla no hizo nada.
                _intentos.append("por paquetes de video: " + paq.get("error", "no salio"))
            if paq.get("ok"):
                paq["fallback"] = "paquetes"
                paq["fallback_motivo"] = (
                    "el audio no engancho (%d de %d puntos creibles): medido "
                    "por TAMANO DE PAQUETES de video, con %s%% de las ventanas "
                    "de acuerdo. Precision ~%d ms (un fotograma), no el "
                    "milisegundo: si hace falta afinar mas, mide por imagen."
                    % (len(good), len(res), paq.get("consenso_pct", "?"),
                       paq.get("precision_ms", 200)))
                return paq

        sub = None
        if "subs" in permitir:
            sub = medir_por_subtitulos(base_path, src_path)
            if intentos is not None:
                intentos["subs"] = sub
            if sub.get("ok") and sub.get("escalera"):
                sub["fallback"] = "subs"
                sub["fallback_motivo"] = (
                    "el audio no engancho (%d de %d puntos creibles) y los "
                    "TIEMPOS de los subtitulos (%d y %d marcas, %s%% casadas) "
                    "muestran %d tramos distintos: son MONTAJES distintos, no un "
                    "desfase fijo. No se mide por imagen porque no cambiaria la "
                    "conclusion."
                    % (len(good), len(res), sub["n_cues"][0], sub["n_cues"][1],
                       sub["casados_pct"], len(sub.get("tramos", []))))
                return sub

        vid = {"ok": False}
        if "video" in permitir:
            # LO QUE CUESTA DE VERDAD (15/09/2026). Los 199 s de arriba son 4
            # puntos con ventana +-30 s: 4 x (90 + 150) = 960 s de video. Si las
            # duraciones difieren, 'search' crece (223 s de diferencia -> +-298
            # s, ventana de origen de 686 s) y si ademas los lags discrepan, el
            # REINTENTO 3 remide con 16 puntos. Influencer (2022), dos 1080p:
            # 20 x (90 + 686) = 15.500 s de video a ~29x -> unos 9 min, y en
            # ese caso el peldano ni siquiera contesto (montajes distintos).
            # No es contencion (ffmpeg usa 2,5 nucleos con 16 ociosos) ni se
            # arregla con el decodificador: medido, '-skip_loop_filter all' da
            # un 10 %, QSV no da nada (el cuello no es decodificar) y '-skip_
            # frame nokey' es 5x mas rapido pero deja la serie a escalones de
            # un GOP, que no sirve para correlacionar.
            vid = measure(base_path, base_index, src_path, src_index,
                          points=(None if puntos_automaticos else points),
                          win=win, search=search, duration=duration,
                          mode="video", _sin_reintento=False)
            if intentos is not None:
                intentos["video"] = vid
            # La regla de la libreria es pearson Y sharp; aqui se miraba solo el
            # pearson (19/08/2026). La luminancia media de dos copias de la misma
            # pelicula correlaciona alto AUNQUE el pico no localice nada: en El
            # chip prodigioso pasaban 16 puntos con pearson 0.56-0.88 y sharp
            # 1.00-1.04, o sea ni un solo enganche real.
            vid_bien = vid.get("ok") and len([p for p in vid.get("points", [])
                                              if p["pearson"] >= 0.5
                                              and p["sharp"] >= 1.3]) >= 2
            if vid_bien:
                vid["fallback"] = "video"
                vid["fallback_motivo"] = (
                    "el audio no engancho (%d de %d puntos creibles): medido por imagen"
                    % (len(good), len(res)))
                if sub is not None and sub.get("ok"):
                    vid["subs_estructura"] = {
                        "tramos": len(sub.get("tramos", [])),
                        "beta_ms": sub.get("beta_ms"),
                        "casados_pct": sub.get("casados_pct"),
                    }
                return vid

        # Ni imagen (o no se permitia) ni escalera en los subtitulos: si los
        # subtitulos midieron algo, vale mas que nada.
        if sub is not None and sub.get("ok"):
            sub["fallback"] = "subs"
            sub["fallback_motivo"] = (
                "no engancharon ni el audio ni la imagen: medido con los TIEMPOS "
                "de los subtitulos (%d y %d marcas, %s%% casadas). Da la "
                "ESTRUCTURA; el desfase tiene ~+-%d ms de incertidumbre porque "
                "los tiempos de un subtitulo son de autor, no medidos."
                % (sub["n_cues"][0], sub["n_cues"][1], sub["casados_pct"],
                   sub["precision_ms"]))
            return sub
        if vid.get("ok"):
            vid["fallback"] = "video"
            vid["fallback_motivo"] = (
                "el audio no engancho (%d de %d puntos creibles): medido por "
                "imagen, pero la imagen tampoco engancha bien (%s)"
                % (len(good), len(res),
                   (sub or {}).get("error", "no se probaron los subtitulos")))
            return vid

    # -- REINTENTO 3: hay ESTRUCTURA y faltan puntos para verla ---------------
    # Con los 4 puntos de siempre, un montaje distinto puede dejar UN solo punto
    # en uno de los niveles, y un punto suelto no puede confirmarse como tramo:
    # el resultado se cae al ajuste lineal y vuelve a inventarse una deriva.
    # Si los lags creibles discrepan entre si mas de lo que ninguna deriva puede
    # explicar, es que hay escalones, y entonces MERECE la pena gastar mas puntos.
    # Visto en Toy Story 5: con 4 puntos salia "deriva -23 s +-42 s"; con 14 se ve
    # la escalera limpia.
    creibles = [p for p in res if p["pearson"] >= 0.5]
    if not _denso and puntos_automaticos and len(creibles) >= 2:
        disp = max(p["_lag"] for p in creibles) - min(p["_lag"] for p in creibles)
        if disp > PASO_MIN_S:
            densos = [duration * f for f in
                      (0.04, 0.10, 0.16, 0.22, 0.28, 0.34, 0.40, 0.46,
                       0.52, 0.58, 0.64, 0.70, 0.76, 0.82, 0.88, 0.94)]
            mm = measure(base_path, base_index, src_path, src_index,
                         points=densos, win=win, search=search, duration=duration,
                         mode=mode, _sin_reintento=True, _denso=True)
            if mm.get("ok"):
                mm["densificado"] = True
                mm["densificado_motivo"] = (
                    "los lags discrepaban %.1f s entre si: se remidio con %d puntos "
                    "para ver la estructura" % (disp, len(densos)))
                return mm
            # 'montajes_distintos' NO es un intento fallido, es la conclusion de
            # haber mirado con 16 puntos. Sin esto se descartaba y se caia al
            # ajuste de los 4 puntos originales, donde solo 2 son creibles, la
            # recta pasa exacta por ambos y sale "deriva 177565 ms, residuo 0.0":
            # una medida mucho peor presentada como perfecta (19/08/2026).
            if mm.get("montajes_distintos"):
                mm["densificado"] = True
                return mm

    if len(res) < 2:
        return {"ok": False, "error": "no se pudo medir (pocas ventanas validas)",
                "points": res, "mode": mode}

    # -- ESCALERA: montajes distintos, no hay UNA recta que valga --------------
    tramos = _tramos(res)
    if tramos:
        cob = _cobertura(tramos, pb["duration"], ps["duration"])
        return {
            "ok": True, "escalera": True, "tramos": tramos, "mode": mode,
            "cobertura": cob,
            # Se mantienen las claves de siempre para no romper a quien las lea,
            # pero apuntando al tramo MAS LARGO, que es el unico desfase con
            # sentido si alguien insiste en tratar esto como un numero suelto.
            "alpha": 1.0,
            "beta_ms": max(tramos, key=lambda t: t["n"])["lag_ms"],
            "drift_ms": 0.0, "drift_se_ms": None, "residual_ms": 0.0,
            "used": sum(t["n"] for t in tramos), "total": len(res),
            "points": res,
        }

    # CON MENOS DE 2 PUNTOS CREIBLES NO HAY MEDIDA (19/08/2026). Antes esto era
    # 'fit = good if len(good) >= 2 else res': si el filtro de arriba descartaba
    # casi todo, se ajustaba 'res' ENTERO, incluidos los puntos que acababan de
    # suspender. Y como 'used' = len(fit), salia "16 de 16", que es justo lo que
    # recommend() lee (used < total) para avisar de duda: el caso de credibilidad
    # CERO se disfrazaba del caso de credibilidad MAXIMA y no avisaba de nada.
    # Visto en mode='video' sobre El chip prodigioso: beta=-7612 ms y una deriva
    # de +8977 ms salidas de 16 puntos con sharp entre 1.00 y 1.04.
    if len(good) < 2:
        msg = ("solo %d de %d puntos engancharon de forma creible "
               "(hace falta pearson>=0.35 y sharp>=1.3): no hay medida que dar"
               % (len(good), len(res)))
        if _intentos:
            msg += ". Tambien se probo " + "; y ".join(_intentos)
        return {"ok": False, "points": res, "mode": mode, "error": msg}
    fit = good
    x = np.array([p["_t"] for p in fit], float)

    # Se ajusta el LAG (y-x, del orden de ms) contra el tiempo CENTRADO, no
    # y contra x directamente. Ajustar y~x parece lo natural y esta MAL: con
    # tiempos de miles de segundos y pendientes de partes por millon, polyfit
    # se queda sin digitos y devuelve deriva inventada. Medido el 02/08/2026 con
    # Master and commander: cuatro lags de +5.5 ms constantes salian como
    # "alpha=1.0000022, deriva +18 ms, residuo 27.8 ms". Centrando y ajustando
    # el lag: alpha=1.0000000, deriva -0.2 ms, residuo 0.1 ms.
    d  = np.array([p["_lag"] for p in fit], float)
    xm = float(x.mean())
    m, c = np.polyfit(x - xm, d, 1)
    alpha = 1.0 + float(m)
    beta  = float(c - m * xm)
    resid = (d - (m * (x - xm) + c)) * 1000

    # LA RECTA TIENE QUE DESCRIBIR LOS DATOS (19/08/2026). Que la pendiente sea
    # significativa (el contraste de mas abajo) NO dice que el modelo valga: con
    # una escalera los puntos suben de verdad, asi que la pendiente sale
    # significativa aunque la recta no pase ni cerca de ellos. `_tramos()` no
    # cazaba este caso porque necesita varios puntos con el MISMO lag, y si cada
    # punto cae en un escalon distinto no ve ninguno.
    # Medido con Alien 3, Extended Edition 2160p contra Assembly Cut (montajes
    # distintos): 16 lags repartidos entre -4,5 s y +108,7 s, ningun par igual.
    # Devolvia ok=True, alpha=1.009805, deriva +84320 ms y residuo 31238 ms, y
    # recommend() contestaba action='resample' con "resamplear es seguro": o sea,
    # resamplear el audio un 1 % para 'arreglar' un montaje distinto. Es
    # exactamente el fallo que motivo el trabajo del 14/08.
    # El residuo se calculaba y se reportaba, pero no gateaba nada.
    resid_max = float(np.abs(resid).max())
    if resid_max > RESID_MAX_MS:
        lags_ord = sorted(p["lag_ms"] for p in fit)
        return {"ok": False, "points": res, "mode": mode,
                "residual_ms": round(resid_max, 1),
                # No es "no se ha podido medir": es un VEREDICTO. Quien llame por
                # encima (el reintento denso) tiene que propagarlo en vez de
                # tratarlo como un intento fallido y caer a una medida peor.
                "montajes_distintos": True,
                "error": ("los desfases medidos no caen sobre ninguna recta "
                          "(residuo %.0f ms sobre %d puntos, de %.0f a %.0f ms): "
                          "no es un desfase fijo ni una deriva, son MONTAJES "
                          "DISTINTOS. Ni --sync ni resamplear lo arreglan; hay "
                          "que conformar la pista por trozos. Mide por "
                          "subtitulos para ver los tramos."
                          % (resid_max, len(fit), lags_ord[0], lags_ord[-1]))}

    # ERROR TIPICO DE LA DERIVA (04/08/2026). La deriva es la decision cara de
    # todo esto: si se declara, la salida es "hay que resamplear", y resamplear
    # DESTRUYE los objetos Atmos. Hasta hoy se decidia comparando la deriva contra
    # el umbral a pelo, sin ninguna medida de cuanto se fia uno de esa pendiente.
    # Simulado con 4 puntos y deriva REAL nula: con +-15 ms de ruido por punto la
    # regla vieja se inventaba deriva el 14 % de las veces, y con +-30 ms el 46 %.
    # Y ese ruido NO disparaba el aviso de "medida poco fina", porque el residuo
    # se queda por debajo del umbral. Con la pendiente contrastada contra su propio
    # error tipico baja al 8 % y al 16 %, sin perder deteccion: una deriva real de
    # 500 ms se sigue detectando el 100 % de las veces en los tres niveles.
    #
    # Con 2 puntos NO hay error tipico posible: la recta pasa exacta por ambos, el
    # residuo sale 0.0 y la medida MENOS fiable de todas se presentaba como la mas
    # perfecta (comprobado: lags de 5 y 120 ms daban "deriva +197 ms, residuo 0.0").
    # Se devuelve None para que recommend() no pueda afirmar deriva en ese caso.
    n = len(fit)
    if n > 2:
        rs = d - (m * (x - xm) + c)                       # residuos en segundos
        s2 = float((rs ** 2).sum()) / (n - 2)
        sxx = float(((x - xm) ** 2).sum())
        se_m = (s2 / sxx) ** 0.5 if sxx > 0 else float("inf")
        drift_se_ms = round(se_m * duration * 1000, 1)
    else:
        drift_se_ms = None

    return {
        "ok": True,
        "alpha": float(alpha),
        "beta_ms": round(float(beta) * 1000, 1),
        "drift_ms": round(float(alpha - 1) * duration * 1000, 1),
        "drift_se_ms": drift_se_ms,          # None = 2 puntos, deriva no evaluable
        "residual_ms": round(float(np.abs(resid).max()), 1),
        "used": len(fit), "total": len(res),
        "points": res,
        "escalera": False,
        "mode": mode,
        # Aunque la curva sea plana el origen puede no cubrir todo el destino
        # (creditos finales mas largos, sobre todo). Eso NO es desincronia y hay
        # que decirlo aparte: se rellena con silencio, no se mueve la pista.
        "cobertura": _cobertura(
            [{"desde_s": 0.0, "hasta_s": duration, "lag_s": float(beta),
              "lag_ms": round(beta * 1000, 1), "sync_ms": round(-beta * 1000),
              "n": len(fit)}],
            pb["duration"], ps["duration"]),
    }


# --------------------------------------------------------- recomendacion ---

def recommend(m, has_objects=False, for_subtitle=False):
    """Traduce la medida a QUE HACER. Es la parte que decide si se pierde Atmos.

    for_subtitle cambia el consejo ante DERIVA: un subtitulo es texto con marcas
    de tiempo, no una forma de onda. Su deriva NO se 'resamplea' (eso es de audio)
    ni pone en riesgo ningun Atmos; se corrige ESTIRANDO los tiempos, que es sin
    perdida. El mensaje de audio ('hace falta resamplear el audio... se pierde el
    Atmos') no tenia ningun sentido cuando se heredaba tal cual a un subtitulo.
    """
    if not m.get("ok"):
        # Si measure() dijo POR QUE, decirlo: el texto generico manda a revisar
        # las pistas cuando el problema real puede ser otro muy concreto (que
        # sean montajes distintos, o que ningun punto enganchara).
        if m.get("montajes_distintos"):
            return {"action": "conformar", "level": "danger",
                    "text": m["error"]}
        if m.get("error"):
            return {"action": "manual", "level": "error", "text": m["error"]}
        return {"action": "manual", "level": "error",
                "text": "No se ha podido medir. Revisa que las dos pistas sean "
                        "de la misma pelicula y tengan audio en esos puntos."}

    # -- ESCALERA: lo primero, porque invalida todo lo demas ------------------
    # Un montaje distinto no se arregla con --sync ni resampleando: hay material
    # que sobra o falta. Decirlo antes que nada evita el peor final posible, que
    # es aplicar un alpha ajustado a una escalera y destrozar la pista.
    if m.get("escalera"):
        tr = m["tramos"]
        lineas = ["Los dos ficheros NO siguen el mismo montaje: el desfase va a "
                  "SALTOS, no es un numero unico.", ""]
        for t in tr:
            lineas.append("  de %d:%02d a %d:%02d  ->  %+.0f ms  (--sync %+d, %d puntos)"
                          % (t["desde_s"] // 60, t["desde_s"] % 60,
                             t["hasta_s"] // 60, t["hasta_s"] % 60,
                             t["lag_ms"], t["sync_ms"], t["n"]))
        for i in range(len(tr) - 1):
            salto = tr[i + 1]["lag_s"] - tr[i]["lag_s"]
            donde = (tr[i]["hasta_s"] + tr[i + 1]["desde_s"]) / 2
            lineas.append("  entre ellos, sobre el minuto %d: el %s tiene %.1f s que "
                          "el otro no trae"
                          % (donde // 60, "DESTINO" if salto < 0 else "ORIGEN", abs(salto)))
        cob = m.get("cobertura") or {}
        for h in cob.get("huecos", []):
            lineas.append("  SIN AUDIO de %d:%02d a %d:%02d (%.0f s)%s"
                          % (h["desde_s"] // 60, h["desde_s"] % 60,
                             h["hasta_s"] // 60, h["hasta_s"] % 60, h["dura_s"],
                             " = el origen se acaba antes (creditos)" if h.get("final") else ""))
        if cob:
            lineas.append("")
            lineas.append("  El origen cubre el %.1f %% del destino." % cob.get("pct", 0))
        lineas.append("")
        lineas.append("Un --sync unico NO vale. Hay que montar la pista por trozos, "
                      "con su desfase cada uno y silencio donde no haya material.")
        if m.get("mode") == "paquetes":
            lineas.append("")
            lineas.append("MEDIDO POR TAMANO DE PAQUETES de video: la ESTRUCTURA "
                          "(cuantos tramos y donde) es de fiar, pero cada desfase "
                          "lleva ~+-%d ms de incertidumbre (es el grano de la "
                          "medida) y el punto exacto del escalon queda a +-1 "
                          "ventana, que son varios minutos. Afina por audio antes "
                          "de dar por buena la sincronia fina."
                          % m.get("precision_ms", 200))
        if m.get("mode") == "subs":
            lineas.append("")
            lineas.append("MEDIDO CON SUBTITULOS: los tramos y los huecos son de fiar "
                          "(es lo que mejor hace este metodo), pero cada desfase lleva "
                          "~+-%d ms de incertidumbre. Afina cada tramo por audio antes "
                          "de dar por buena la sincronia fina." % m.get("precision_ms", 200))
        return {"action": "conformar", "level": "danger",
                "tramos": tr, "sync_ms": tr[0]["sync_ms"],
                "text": "\n".join(lineas)}

    drift = abs(m["drift_ms"])
    off   = m["beta_ms"]
    noisy = m["residual_ms"] > UMBRAL_MS

    # Fiabilidad de la medida, ANTES de recomendar nada.
    # 1) Puntos creibles: measure() ya los cuenta (used/total) pero nadie los
    #    miraba, asi que 1 punto bueno de 4 sonaba igual de rotundo que 4 de 4.
    # 2) Deriva: solo se afirma si supera el umbral Y destaca sobre su propio
    #    error tipico (2 sigma). Ver el bloque largo de measure().
    se = m.get("drift_se_ms")
    pocos = m.get("used", 0) < m.get("total", 0)
    dudoso = []
    if pocos:
        dudoso.append("solo %d de %d puntos engancharon bien" % (m["used"], m["total"]))
    if se is None and m.get("mode") != "subs":
        dudoso.append("con 2 puntos la recta pasa exacta por ellos: el residuo de "
                      "0 ms NO significa que la medida sea buena, significa que no "
                      "hay con que contrastarla")
    if m.get("mode") == "subs":
        # En subs no hay recta ni deriva: hay marcas que casan o no casan. El
        # aviso util es OTRO: la precision del metodo.
        dudoso.append("medido con los TIEMPOS de los subtitulos (%s%% de %d marcas "
                      "casadas): el desfase lleva ~+-%d ms de incertidumbre porque "
                      "son tiempos de autor, no medidos. Para el milisegundo, afina "
                      "por audio" % (m.get("casados_pct", "?"), m.get("total", 0),
                                     m.get("precision_ms", 200)))
    if m.get("mode") == "paquetes":
        # Dos cosas que el usuario NO puede adivinar del numero que ve.
        # La segunda importa de verdad: este metodo mide la linea de tiempo del
        # VIDEO y el de audio la del AUDIO. Si en uno de los ficheros el audio va
        # corrido respecto a su propio video, los dos son correctos y NO dan lo
        # mismo. Medido con Toy Story 5, pilongo contra DCPRIP: audio -337 ms,
        # paquetes +400 ms, 737 ms de diferencia sin ningun retardo de contenedor
        # que lo explique.
        dudoso.append("medido por TAMANO DE PAQUETES de video (%s%% de %d ventanas "
                      "de acuerdo): el desfase lleva ~+-%d ms de incertidumbre, que "
                      "es el grano de la medida. Y mide la linea de tiempo del "
                      "VIDEO: si en alguno de los dos ficheros el audio va corrido "
                      "respecto a su propio video, este numero y el del audio "
                      "discrepan siendo los dos correctos. Para el milisegundo, "
                      "afina por audio"
                      % (m.get("consenso_pct", "?"), m.get("total", 0),
                         m.get("precision_ms", 200)))
    aviso = ("  OJO: " + "; ".join(dudoso) + ".") if dudoso else ""

    # HUECOS (14/08/2026): que el origen no llegue hasta el final del destino NO
    # es desincronia -no se arregla moviendo la pista- sino material que no
    # existe. El caso de siempre son los creditos finales, mas largos en una
    # version. Se dice aparte para que nadie lo confunda con un desfase.
    cob = m.get("cobertura") or {}
    for h in cob.get("huecos", []):
        if h["dura_s"] >= 2.0:
            aviso += ("  NOTA: de %d:%02d a %d:%02d (%.0f s) el origen NO tiene audio%s; "
                      "ahi hay que poner silencio, no mover la pista."
                      % (h["desde_s"] // 60, h["desde_s"] % 60,
                         h["hasta_s"] // 60, h["hasta_s"] % 60, h["dura_s"],
                         " porque se acaba antes (creditos finales)" if h.get("final") else ""))

    # Deriva creible = grande Y significativa. Sin error tipico (2 puntos) no se
    # puede afirmar, asi que se trata como "no hay deriva demostrable".
    drift_real = drift > UMBRAL_MS and se is not None and drift > 2 * se

    if drift > UMBRAL_MS and not drift_real:
        return {"action": "sync", "level": "warn", "sync_ms": round(-off),
                "text": (f"Sale una deriva de {m['drift_ms']:+.0f} ms, pero NO es "
                         f"de fiar: " + (f"su margen de error es de +-{se:.0f} ms "
                         f"(hace falta que la deriva lo doble para tomarsela en "
                         f"serio)" if se is not None else "se ha medido con solo 2 "
                         f"puntos y no tiene margen de error calculable") +
                         f". Lo prudente es tratarlo como desfase fijo de "
                         f"{off:+.0f} ms (--sync {round(-off):+d} ms, sin recodificar "
                         f"y conservando el Atmos) y comprobar el final de la "
                         f"pelicula. Si de verdad hubiera deriva, se veria ahi." + aviso)}

    if drift_real:
        if for_subtitle:
            # Un subtitulo con deriva se arregla estirando sus tiempos: es texto,
            # no hay onda que resamplear ni objetos que perder. mkvmerge lo hace
            # con el factor lineal de --sync, sin recodificar. (El mux aplica hoy
            # solo el desfase fijo; si al final se ve descuadre, es que la deriva
            # es real y hay que estirar.) Nada de "resamplear el audio" aqui.
            return {"action": "sync", "level": "warn",
                    "sync_ms": round(-off), "stretch": 1.0 / m["alpha"],
                    "text": (f"Sale una deriva de {m['drift_ms']:+.0f} ms (+-{se:.0f} ms) "
                             f"a lo largo de la pelicula (alpha={m['alpha']:.6f}). En un "
                             f"SUBTITULO la deriva se corrige estirando los tiempos, sin "
                             f"recodificar ni perder nada (no hay audio ni objetos de por "
                             f"medio). Se aplica el desfase de {off:+.0f} ms (--sync "
                             f"{round(-off):+d} ms); comprueba el FINAL de la pelicula: si "
                             f"ahi se descuadra, la deriva es real y hay que estirar.{aviso}")}
        base = (f"Hay DERIVA de {m['drift_ms']:+.0f} ms (+-{se:.0f} ms) a lo largo "
                f"de la pelicula (alpha={m['alpha']:.6f}). Un desfase fijo no la "
                f"corrige: hace falta resamplear el audio.{aviso}")
        if has_objects:
            return {"action": "resample", "level": "danger",
                    "sync_ms": round(-off), "stretch": 1.0 / m["alpha"],
                    "text": base + " OJO: esta pista lleva OBJETOS (Atmos). "
                            "Resamplear obliga a decodificar y los objetos se "
                            "PIERDEN. Alternativa: aceptar la deriva, o buscar "
                            "otra fuente ya alineada."}
        return {"action": "resample", "level": "warn",
                "sync_ms": round(-off), "stretch": 1.0 / m["alpha"],
                "text": base + " La pista no lleva objetos, asi que resamplear "
                        "es seguro (solo pierde lo propio de recodificar)."}

    if abs(off) <= UMBRAL_MS and not noisy and not dudoso:
        return {"action": "copy", "level": "ok", "sync_ms": 0,
                "text": f"Ya esta sincronizada ({off:+.0f} ms). Se copia tal cual, "
                        f"sin tocar nada."}

    if abs(off) <= UMBRAL_MS and not noisy:
        # Desfase despreciable pero medida floja: se copia igual, avisando.
        return {"action": "copy", "level": "warn", "sync_ms": 0,
                "text": f"Sale sincronizada ({off:+.0f} ms), pero la medida es "
                        f"floja.{aviso}"}

    r = {"action": "sync", "level": "ok" if not dudoso else "warn",
         "sync_ms": round(-off),
         "text": f"Desfase fijo de {off:+.0f} ms y sin deriva demostrable "
                 f"({m['drift_ms']:+.0f} ms en toda la peli). Se corrige con "
                 f"--sync {round(-off):+d} ms al muxear, SIN recodificar: "
                 f"el Atmos y todo lo demas se conservan intactos.{aviso}"}
    if noisy:
        r["level"] = "warn"
        r["text"] += (f" AVISO: los puntos discrepan hasta {m['residual_ms']:.0f} ms, "
                      f"asi que la medida no es fina. Suele pasar cuando las dos "
                      f"pistas son doblajes o mezclas distintas. Comprueba a mano.")
    return r


# ------------------------------------------------------------------- cli ---

if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "probe":
        d = probe(sys.argv[2])
        print(f"duracion: {d['duration']:.3f} s")
        for t in d["tracks"]:
            extra = ""
            if t["type"] == "video":
                extra = f" {t.get('width')}x{t.get('height')} {t.get('hdr')} {t.get('fps')}"
            elif t["type"] == "audio":
                extra = f" {t.get('channels')}ch" + (" ATMOS" if t["atmos"] else "")
            elif t["type"] == "subtitle":
                extra = (" ya-srt" if t["srt"] else " ->srt" if t["text"]
                         else " ->srt(OCR)" if t["ocr"] else " NO-convertible")
            print(f"  #{t['index']:<3} {t['type']:<8} {t['codec']:<10} "
                  f"[{t['lang']}] def={int(t['default'])} for={int(t['forced'])}"
                  f"{extra}  {t['title'][:34]}")
    elif len(sys.argv) >= 4 and sys.argv[1] == "subs":
        # python remuxlib.py subs "base.mkv" "otra.mkv" [idx_base idx_otra]
        ia = int(sys.argv[4]) if len(sys.argv) >= 6 else None
        ib = int(sys.argv[5]) if len(sys.argv) >= 6 else None
        m = medir_por_subtitulos(sys.argv[2], sys.argv[3], ia, ib)
        if not m.get("ok"):
            print("  " + str(m.get("error")))
        else:
            print(f"  pistas {m['subs_base_idx']} / {m['subs_src_idx']}   "
                  f"marcas {m['n_cues'][0]} y {m['n_cues'][1]}   "
                  f"casadas {m['casados_pct']}%")
            for t in m["tramos"]:
                print(f"    {t['desde_s']:>8.1f} -> {t['hasta_s']:>8.1f} s   "
                      f"lag={t['lag_ms']:+9.1f} ms  ({t['n']} marcas)")
            print("\n  " + recommend(m)["text"])
    elif len(sys.argv) >= 3 and sys.argv[1] == "voz":
        # python remuxlib.py voz "peli.mkv" [idx_audio] [idx_sub]
        ia = int(sys.argv[3]) if len(sys.argv) >= 4 else None
        ib = int(sys.argv[4]) if len(sys.argv) >= 5 else None
        m = medir_voz_contra_subs(sys.argv[2], ia, ib)
        if not m.get("ok"):
            print("  " + str(m.get("error")))
        else:
            print(f"  audio #{m['audio_index']} [{m['audio_lang']}] ({m['canal']}) "
                  f"contra subtitulos #{m['sub_index']} [{m['sub_lang']}]")
            print(f"  la voz entra {m['voz_ms']:+.0f} ms despues del subtitulo "
                  f"(lo normal es +{m['sesgo_ms']})")
            print(f"  -> desfase contra la imagen {m['desfase_ms']:+d} ms "
                  f"(+-{m['margen_ms']}), --sync {m['sync_ms']:+d}"
                  + ("   SOSPECHOSO" if m["sospecha"] else "   dentro del margen"))
            print(f"  {m['n']} de {m['total']} dialogos ({m['frac_pct']} %), "
                  f"nitidez {m['nitidez']}, {m['onsets']} arranques de voz")
    elif len(sys.argv) >= 6 and sys.argv[1] == "measure":
        m = measure(sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5]))
        for p in m.get("points", []):
            print(f"  t={p['t']:>8.1f}s  lag={p['lag_ms']:+8.1f} ms  "
                  f"pearson={p['pearson']:.2f}  nitidez={p['sharp']:.2f}")
        if m["ok"]:
            print(f"\n  alpha={m['alpha']:.7f}  offset={m['beta_ms']:+.1f} ms  "
                  f"deriva={m['drift_ms']:+.0f} ms  residuo={m['residual_ms']:.1f} ms "
                  f"({m['used']}/{m['total']} puntos)")
        print("\n  " + recommend(m)["text"])
    else:
        print(__doc__)
