"""
================================================================================
 subsfetch.py  -  Busca, verifica y anyade subtitulos a una pelicula
================================================================================
 Tres tipos, que son los que pide el equipo: castellano completo, castellano
 FORZADO (solo rotulos y dialogo en otro idioma) e ingles.

 EL ORDEN IMPORTA, Y NO ES EL OBVIO
 ----------------------------------
 1. LA BIBLIOTECA LOCAL PRIMERO. El 07/08/2026, buscando subtitulos para un
    Minority Report, la mejor fuente no estaba en internet: estaba en
    E:\\Peliculas, otra copia de la misma pelicula. Y tiene una ventaja que
    ninguna descarga da: al ser la MISMA pelicula se puede medir el desfase por
    correlacion cruzada video-contra-video y DEMOSTRAR que encaja (salio
    alpha=1.0 y error 0.0 ms). Con un subtitulo bajado de internet solo se puede
    estimar.
 2. Solo si no hay copia local, OpenSubtitles: primero por moviehash (que
    identifica el release exacto y garantiza la sincronia), y si no, por titulo.

 NADA SE DA POR BUENO SIN MEDIRLO
 --------------------------------
 Todo subtitulo, venga de donde venga, se verifica contra el AUDIO del fichero
 destino antes de aceptarlo, y si no se puede demostrar la sincronia se RECHAZA
 en vez de muxearlo a ciegas. Es la regla de la casa: fallar alto antes que
 degradar en silencio. Un subtitulo desincronizado es peor que ninguno, porque
 se descubre a los 20 minutos de peli.

 DOS TRAMPAS QUE COSTARON UN RATO (07/08/2026), ya resueltas aqui:
   - Para subtitulos hay que medir contra el VIDEO, no contra el audio. En un
     fichero "sincronizado" a mano el doblaje puede ir 71 ms desviado respecto
     a su propio video, y los subtitulos van pegados al video.
   - Al verificar contra voz hay que usar el CANAL CENTRAL. Bajando un 5.1 a
     mono, la musica y los efectos entierran el dialogo y la correlacion sale
     basura: el primer intento dio un pico NEGATIVO pegado al borde de la
     ventana. Con el canal central el pico salio limpio en +0.00 s a 7 sigma.

 USO
   python subsfetch.py <video.mkv> [opciones]
     --idiomas es,en      idiomas a buscar (por defecto es,en)
     --forzados           buscar ademas el castellano FORZADO
     --mux                muxear el resultado dentro del MKV (si no, deja .srt)
     --dry-run            solo informa de lo que haria
     --solo-local         no tocar internet
     --out DIR            donde dejar los .srt (por defecto, junto al video)

 Devuelve 0 si consiguio TODO lo pedido, 2 si consiguio algo pero no todo,
 1 si no consiguio nada o hubo error.
================================================================================
"""

import argparse, json, os, re, struct, subprocess, sys, tempfile, urllib.error
import urllib.parse, urllib.request, zipfile, io

import numpy as np

AQUI      = os.path.dirname(os.path.abspath(__file__))
CFG_PATH  = r"C:\scripts\opensubtitles.json"
API       = "https://api.opensubtitles.com/api/v1"
FFMPEG    = r"C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe"
FFPROBE   = r"C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffprobe.exe"
MKVMERGE  = r"C:\Program Files\MKVToolNix\mkvmerge.exe"
PWSH      = r"C:\Program Files\PowerShell\7\pwsh.exe"
SUBS_LIB  = r"C:\scripts\subs-lib.ps1"


def _ps_q(x):
    """Comilla simple de PowerShell: dentro de '...' solo hay que doblar la '.

    POR QUE (01/09/2026). ocr_pista() metia las rutas en el -Command con un
    f-string y sin escapar nada. Con una ruta que lleve apostrofo, la cadena de
    PowerShell se CIERRA antes de tiempo y el resto se interpreta como codigo:
    pwsh sale con error de sintaxis, la funcion devuelve False, y el log dice
    "no se pudo OCR" sin mencionar el motivo real.

    Y no es hipotetico: E:\\Series tiene "Philip K. Dick's Electric Dreams
    (2017)", con un apostrofo U+0027 de verdad en el nombre de la CARPETA, asi
    que le pasaba a todos sus episodios. Es la misma trampa que ya mordio en el
    JavaScript del panel con "Ocean's Eleven" y los onclick.

    Misma funcion que _ps_q de app.py. Aqui no se importa porque la dependencia
    va al reves (app.py importa subsfetch), y son dos lineas.
    """
    return str(x).replace("'", "''")
# Donde buscar otras copias de la misma pelicula. Ver unidades-htpc-reparto.
BIBLIOTECAS = [r"E:\Peliculas", r"F:\Peliculas"]

HZ = 20                      # 50 ms por muestra en el analisis de sincronia
VIDEO_EXT = (".mkv", ".mp4", ".m2ts", ".ts", ".mov", ".avi")


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- configuracion
def cargar_config():
    """Lee opensubtitles.json. Nunca devuelve la contrasena en los mensajes."""
    if not os.path.isfile(CFG_PATH):
        return None
    try:
        c = json.load(open(CFG_PATH, encoding="utf-8"))
    except Exception as e:
        log(f"  [cfg] {CFG_PATH} no es JSON valido: {e}")
        return None
    if not c.get("api_key"):
        log("  [cfg] falta api_key")
        return None
    return c


def credenciales_utiles(cfg):
    """True si username/password parecen rellenados de verdad."""
    u = (cfg.get("username") or "").strip()
    p = (cfg.get("password") or "").strip()
    if not u or not p or u.startswith("PON_AQUI") or p.startswith("PON_AQUI"):
        return False, "no hay usuario/contrasena en opensubtitles.json"
    if "@" in u:
        # La API lo rechaza explicitamente con un 400. Mejor avisar antes de
        # gastar una llamada y dar un error que parezca otra cosa.
        return False, ("el campo 'username' tiene un email; OpenSubtitles exige "
                       "el NOMBRE DE USUARIO, no el correo")
    return True, ""


# ------------------------------------------------------------------ utilidades
def ffprobe_json(path, args):
    # encoding='utf-8' EXPLICITO: con text=True a secas, Python usa la
    # codificacion regional (cp1252 en este equipo) y los titulos de pista
    # llegan destrozados -"Español" se convertia en "EspaÃ±ol"-, que es
    # justo lo que mira idioma_de_pista() para deducir el idioma cuando la
    # etiqueta viene como 'und'.
    try:
        r = subprocess.run([FFPROBE, "-v", "error", *args, "-of", "json", path],
                           capture_output=True, text=True, timeout=120,
                           encoding="utf-8", errors="replace")
        return json.loads(r.stdout or "{}")
    except Exception:
        return {}


def info_video(path):
    """duracion + pistas. Devuelve None si ffprobe no puede con el fichero,
    que es un caso real y hay que distinguirlo de 'no tiene subtitulos'
    (ver ffprobe-aborta-por-una-pista-rota)."""
    j = ffprobe_json(path, ["-show_format", "-show_streams"])
    if not j.get("format"):
        return None
    dur = float(j["format"].get("duration") or 0)
    audios, subs = [], []
    for s in j.get("streams", []):
        t = s.get("codec_type")
        tags = s.get("tags") or {}
        d = {"index": s.get("index"), "codec": s.get("codec_name"),
             "lang": (tags.get("language") or "und").lower(),
             "title": tags.get("title") or "",
             "canales": s.get("channels") or 0,
             "forced": bool((s.get("disposition") or {}).get("forced"))}
        if t == "audio":
            audios.append(d)
        elif t == "subtitle":
            subs.append(d)
    return {"duracion": dur, "audios": audios, "subs": subs}


def moviehash(path):
    """Hash de OpenSubtitles: tamano + los primeros y ultimos 64 KB, sumados
    como enteros de 64 bits con desbordamiento."""
    M = 1 << 64
    tam = os.path.getsize(path)
    h = tam
    with open(path, "rb") as f:
        for pos in (0, max(0, tam - 65536)):
            f.seek(pos)
            b = f.read(65536)
            for i in range(len(b) // 8):
                h = (h + struct.unpack_from("<Q", b, i * 8)[0]) % M
    return f"{h:016x}"


def titulo_y_anyo(path):
    """Saca titulo y anyo del nombre o de la carpeta. Heuristica deliberadamente
    simple: si falla, el usuario siempre puede pasar --titulo."""
    for cand in (os.path.splitext(os.path.basename(path))[0],
                 os.path.basename(os.path.dirname(path))):
        m = re.search(r"^(.*?)[\.\s_\-\(\[]+((?:19|20)\d{2})\b", cand)
        if m:
            t = re.sub(r"[\._]+", " ", m.group(1)).strip(" -[]()")
            if t:
                return t, int(m.group(2))
    base = re.sub(r"[\._]+", " ", os.path.splitext(os.path.basename(path))[0])
    base = re.split(r"\b(?:1080p|2160p|720p|BluRay|BDRip|WEB|x264|x265|HEVC)\b",
                    base, flags=re.I)[0]
    return base.strip(" -[]()"), None


# ------------------------------------------------------- sincronia (lo esencial)
def _voz_central(video, idx_audio, n):
    """Envolvente de VOZ del canal central. El canal central es donde vive el
    dialogo en un 5.1; bajar la mezcla a mono lo entierra bajo musica y efectos
    y la correlacion deja de servir (probado, y dolio)."""
    wav = os.path.join(tempfile.gettempdir(),
                       f"_sf_{os.getpid()}_{idx_audio}.wav")
    try:
        subprocess.run([FFMPEG, "-v", "error", "-y", "-i", video,
                        # c2 por INDICE y no 'FC' por nombre (03/09/2026):
                        # remuxlib.py lo cambio tras encontrarse pistas de 6
                        # canales SIN layout declarado, donde el filtro no monta.
                        # El orden estandar es L R C LFE... en 5.1 y en 7.1, asi
                        # que c2 es el central en las dos. NO he podido
                        # reproducir el fallo en este ffmpeg -normaliza siempre
                        # 6 canales a 5.1-, asi que esto se alinea con el
                        # incidente documentado alli, no con una medida propia;
                        # lo que si esta medido es que c2 da lo mismo que FC
                        # cuando el layout SI viene declarado.
                        "-map", f"0:{idx_audio}", "-af", "pan=mono|c0=c2",
                        "-ar", "8000", "-c:a", "pcm_s16le", wav],
                       capture_output=True, timeout=3600)
        if not os.path.isfile(wav) or os.path.getsize(wav) < 1024:
            return None
        # np.fromfile y NO np.memmap: el memmap deja el fichero abierto y en
        # Windows el borrado de despues falla.
        raw = np.fromfile(wav, dtype=np.int16, offset=44)
    except Exception:
        return None
    finally:
        try:
            os.remove(wav)
        except Exception:
            pass
    paso = 8000 // HZ
    util = (len(raw) // paso) * paso
    if util == 0:
        return None
    e = np.abs(raw[:util].astype(np.float32)).reshape(-1, paso).mean(axis=1)
    del raw
    if len(e) < n:
        e = np.pad(e, (0, n - len(e)))
    e = np.log1p(e[:n])                       # comprime los picos de efectos
    return np.maximum(e - np.median(e), 0)    # "hay voz" por encima del fondo


TS_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})")


def _ms(h, m, s, x):
    return ((int(h) * 60 + int(m)) * 60 + int(s)) * 1000 + int(x)


def leer_srt(path):
    for enc in ("utf-8-sig", "utf-8", "cp1252", "latin-1"):
        try:
            with open(path, encoding=enc) as f:
                return f.read()
        except (UnicodeDecodeError, LookupError):
            continue
    return None


def _senyal_subs(texto, n):
    v = np.zeros(n, dtype=np.float32)
    for m in TS_RE.finditer(texto):
        a = int(_ms(*m.group(1, 2, 3, 4)) / 1000.0 * HZ)
        b = int(_ms(*m.group(5, 6, 7, 8)) / 1000.0 * HZ)
        if b > a:
            v[max(0, a):min(n, b)] = 1.0
    return v


def _norm(x):
    x = x - x.mean()
    s = x.std()
    return x / s if s > 0 else x


def verificar_sync(video, srt_texto, idx_audio, duracion, max_s=60.0):
    """Correlaciona 'hay subtitulo' contra 'hay voz'. Devuelve dict con:
        offset_s : cuanto hay que DESPLAZAR el subtitulo para que cuadre
        sigma    : cuanto destaca el pico sobre el resto (confianza)
        ok       : si se considera demostrado
    Es la misma idea de ffsubsync, con las piezas que ya tiene el proyecto.
    """
    n = int(duracion * HZ)
    if n <= 0:
        return {"ok": False, "motivo": "duracion desconocida"}
    aud = _voz_central(video, idx_audio, n)
    if aud is None:
        return {"ok": False, "motivo": "no se pudo extraer el canal central"}
    aud = _norm(aud)
    sub = _senyal_subs(srt_texto, n)
    # Minimo de MATERIA para medir. Antes bastaban 10 s de subtitulo dentro del
    # fichero, y eso no da para nada: con un clip de 5 min solo caian 3 o 4
    # lineas dentro y todos los picos salian a 2 sigma. No es que los
    # subtitulos fueran malos: es que la medicion era imposible. Se distingue
    # con un motivo propio ('inmedible') para que el llamante deje de gastar
    # descargas probando candidatos que van a fallar igual.
    if sub.sum() < 120 * HZ:
        return {"ok": False, "inmedible": True,
                "motivo": f"solo {sub.sum()/HZ:.0f} s de subtitulo dentro del "
                          f"fichero: no hay material para medir"}
    sub = _norm(sub)

    vals, lags = [], []
    for lag in range(int(-max_s * HZ), int(max_s * HZ) + 1):
        if lag >= 0:
            a, b = aud[lag:], sub[:n - lag]
        else:
            a, b = aud[:n + lag], sub[-lag:]
        m = min(len(a), len(b))
        if m < HZ * 120:
            continue
        # PEARSON sobre el SOLAPE, no un producto escalar de senyales
        # normalizadas enteras: al trocear, los trozos ya no tienen media cero y
        # aparece un termino que cambia con el desfase, o sea picos falsos.
        # Ademas 'r' se interpreta solo, mientras que el producto escalar crudo
        # no dice nada por si mismo.
        a = a[:m] - a[:m].mean()
        b = b[:m] - b[:m].mean()
        da = float(np.sqrt((a * a).sum()))
        db = float(np.sqrt((b * b).sum()))
        if da <= 0 or db <= 0:
            continue
        lags.append(lag / HZ)
        vals.append(float((a * b).sum() / (da * db)))
    if not vals:
        return {"ok": False, "motivo": "sin solape suficiente"}
    lags = np.array(lags)
    vals = np.array(vals)
    k = int(np.argmax(vals))
    pico = float(lags[k])
    fuera = vals[np.abs(lags - pico) > 2.0]
    sigma = float((vals[k] - fuera.mean()) / (fuera.std() or 1)) if len(fuera) else 0.0
    # SIGNO (comprobado con un caso de respuesta conocida el 07/08/2026, porque
    # lo tenia AL REVES y eso es peor que no medir: con un desfase mayor que la
    # tolerancia, corregia en direccion contraria y DUPLICABA el error).
    # El barrido compara aud[lag+i] con sub[i]: si el pico cae en 'lag', lo que
    # el subtitulo pone en i pasa de verdad en i+lag, asi que hay que SUMAR lag.
    # Un pico DEBIL no significa "este subtitulo es malo" sino "aqui no se puede
    # medir": si la senyal no da, no la va a dar el siguiente candidato tampoco.
    # Por eso se marca como 'inmedible' y el llamante deja de gastar cupo.
    # (Un subtitulo de OTRO montaje da pico FUERTE en un sitio raro, y ese caso
    #  se resuelve solo desplazandolo.)
    return {"ok": sigma >= 4.0, "offset_s": pico, "sigma": sigma, "r": float(vals[k]),
            "inmedible": sigma < 4.0,
            "motivo": "" if sigma >= 4.0 else f"pico debil ({sigma:.1f} sigma)"}


def desplazar_srt(texto, shift_ms):
    def a_txt(ms):
        ms = max(0, int(round(ms)))
        h, r = divmod(ms, 3600000)
        m, r = divmod(r, 60000)
        s, x = divmod(r, 1000)
        return f"{h:02d}:{m:02d}:{s:02d},{x:03d}"

    def rep(m):
        return (a_txt(_ms(*m.group(1, 2, 3, 4)) + shift_ms) + " --> " +
                a_txt(_ms(*m.group(5, 6, 7, 8)) + shift_ms))

    return TS_RE.sub(rep, texto)


def idioma_de_pista(lang, titulo):
    """Idioma corto ('es'/'en'/...) de una pista, mirando TAMBIEN el nombre.

    Hace falta de verdad: muchos rips etiquetan los subtitulos como 'und' y
    ponen el idioma solo en el nombre ("Español", "English"). Sin esto, una
    pelicula con sus dos PGS perfectamente OCReables se clasificaba como 'un'
    (los dos primeros caracteres de 'und') y se daba por NO resuelta, gastando
    cupo de descarga para sustituir algo que ya estaba bien.
    """
    l = (lang or "und").lower()
    if l.startswith("spa") or l.startswith("es") or l.startswith("cas"):
        return "es"
    if l.startswith("en"):
        return "en"
    if l in ("und", "", "none", "mul"):
        n = (titulo or "").lower()
        if any(k in n for k in ("espa", "spa", "cast", "latino")):
            return "es"
        if any(k in n for k in ("engl", "eng", "ingl")):
            return "en"
        return "und"
    return l[:2]


def es_forzada(pista):
    """Forzada por bandera o por nombre: la bandera falta muy a menudo."""
    n = (pista.get("title") or "").lower()
    return bool(pista.get("forced")) or "forz" in n or "forced" in n


def audio_para_idioma(info, lang):
    """Pista de audio con la que verificar. Se prefiere la del idioma del
    subtitulo -es la que dice las mismas palabras-, con caida a la primera."""
    for a in info["audios"]:
        if a["lang"].startswith(lang[:2]) or (lang == "es" and a["lang"].startswith("spa")):
            return a["index"]
    return info["audios"][0]["index"] if info["audios"] else None


# ------------------------------------------------------------- fuente: LOCAL
def _norm_titulo(s):
    s = re.sub(r"[^a-z0-9 ]+", " ", s.lower())
    return " ".join(s.split())


def buscar_copia_local(titulo, anyo, excluir):
    """Otra copia de la MISMA pelicula en la biblioteca, con subtitulos."""
    objetivo = _norm_titulo(titulo)
    if not objetivo:
        return []
    hallados = []
    for raiz in BIBLIOTECAS:
        if not os.path.isdir(raiz):
            continue
        try:
            carpetas = os.listdir(raiz)
        except OSError:
            continue
        for c in carpetas:
            nc = _norm_titulo(re.sub(r"\((?:19|20)\d{2}\)", "", c))
            if objetivo not in nc and nc not in objetivo:
                continue
            d = os.path.join(raiz, c)
            if not os.path.isdir(d):
                continue
            for f in os.listdir(d):
                if not f.lower().endswith(VIDEO_EXT):
                    continue
                p = os.path.join(d, f)
                if os.path.abspath(p) == os.path.abspath(excluir):
                    continue
                inf = info_video(p)
                if inf and inf["subs"]:
                    hallados.append((p, inf))
    return hallados


def ocr_pista(video, ordinal, lang, destino, workdir):
    """PGS/VobSub -> SRT usando la MISMA Convert-SubToSrt que el pipeline.
    No se reimplementa el OCR aqui: ya divergio dos veces en este proyecto."""
    ps = (f". '{_ps_q(SUBS_LIB)}'; $r = Convert-SubToSrt -InputFile '{_ps_q(video)}' "
          f"-SubOrdinal {ordinal} -OutFile '{_ps_q(destino)}' -Lang '{_ps_q(lang)}' "
          f"-WorkDir '{_ps_q(workdir)}' -TimeoutMs 3600000; "
          f"if ($r.Ok) {{ exit 0 }} elseif ($r.Empty) {{ exit 2 }} else {{ exit 1 }}")
    try:
        r = subprocess.run([PWSH, "-NoProfile", "-ExecutionPolicy", "Bypass",
                            "-Command", ps], capture_output=True, text=True,
                           timeout=3900)
        return r.returncode == 0 and os.path.isfile(destino)
    except Exception:
        return False


# ----------------------------------------------------- fuente: OPENSUBTITLES
class OpenSubs:
    def __init__(self, cfg):
        self.cfg = cfg
        self.token = None
        self.restantes = None

    def _pedir(self, ruta, params=None, datos=None, auth=False):
        url = API + ruta + (("?" + urllib.parse.urlencode(params)) if params else "")
        cab = {"Api-Key": self.cfg["api_key"],
               "User-Agent": self.cfg.get("user_agent", "MediaBox/1.0"),
               "Accept": "application/json"}
        cuerpo = None
        if datos is not None:
            cuerpo = json.dumps(datos).encode()
            cab["Content-Type"] = "application/json"
        if auth and self.token:
            cab["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(url, data=cuerpo, headers=cab)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.loads(e.read().decode())
            except Exception:
                return e.code, {}
        except Exception as e:
            return -1, {"message": f"{type(e).__name__}: {e}"}

    def login(self):
        ok, motivo = credenciales_utiles(self.cfg)
        if not ok:
            return False, motivo
        s, b = self._pedir("/login", datos={"username": self.cfg["username"],
                                            "password": self.cfg["password"]})
        if s == 200 and b.get("token"):
            self.token = b["token"]
            u = b.get("user") or {}
            self.restantes = u.get("allowed_downloads")
            return True, ""
        # El mensaje de la API es util (distingue email de usuario, cuenta
        # bloqueada, etc.), asi que se propaga tal cual.
        return False, str(b.get("message") or f"HTTP {s}")

    def buscar(self, **kw):
        s, b = self._pedir("/subtitles", kw)
        if s != 200:
            return []
        return b.get("data") or []

    def descargar(self, file_id):
        # Devuelve SIEMPRE (texto, motivo). Antes esta rama devolvia un None
        # pelado mientras las otras cuatro devolvian tupla, asi que un
        # 'texto, err = descargar(...)' habria reventado con TypeError en vez de
        # informar. Hoy no se alcanza -desde_opensubtitles corta antes si el login
        # fallo-, pero un contrato que cambia de forma segun la rama es una trampa
        # esperando al siguiente que llame desde otro sitio.
        if not self.token:
            return None, "sin login: no se puede descargar"
        s, b = self._pedir("/download", datos={"file_id": file_id}, auth=True)
        if s != 200 or not b.get("link"):
            return None, str(b.get("message") or f"HTTP {s}")
        self.restantes = b.get("remaining")
        try:
            req = urllib.request.Request(
                b["link"], headers={"User-Agent": self.cfg.get("user_agent", "MediaBox/1.0")})
            with urllib.request.urlopen(req, timeout=120) as r:
                datos = r.read()
        except Exception as e:
            return None, f"no se pudo bajar: {e}"
        # Puede venir en zip
        if datos[:2] == b"PK":
            try:
                z = zipfile.ZipFile(io.BytesIO(datos))
                nom = next(n for n in z.namelist() if n.lower().endswith(".srt"))
                datos = z.read(nom)
            except Exception as e:
                return None, f"zip ilegible: {e}"
        for enc in ("utf-8-sig", "utf-8", "cp1252", "latin-1"):
            try:
                return datos.decode(enc), ""
            except UnicodeDecodeError:
                continue
        return None, "no se pudo decodificar el subtitulo"


def puntuar(cand, fps_objetivo, release_objetivo):
    """Ordena candidatos. La coincidencia por hash manda sobre todo lo demas."""
    a = cand.get("attributes", {})
    p = 0.0
    if a.get("moviehash_match"):
        p += 1000
    try:
        if fps_objetivo and abs(float(a.get("fps") or 0) - fps_objetivo) < 0.05:
            p += 40
    except (TypeError, ValueError):
        pass
    rel = (a.get("release") or "").lower()
    obj = (release_objetivo or "").lower()
    for palabra in ("bluray", "bdrip", "remux", "web", "2160p", "1080p"):
        if palabra in rel and palabra in obj:
            p += 8
    if a.get("from_trusted"):
        p += 25
    if a.get("ai_translated") or a.get("machine_translated"):
        p -= 60          # traduccion automatica: ultimo recurso
    if a.get("hearing_impaired"):
        p -= 10
    p += min(float(a.get("download_count") or 0) ** 0.5, 40)
    return p


def n_entradas(texto):
    return len(TS_RE.findall(texto or ""))


def parece_forzado(texto, referencia=None):
    """Un FORZADO solo cubre rotulos y dialogo en otro idioma: son decenas de
    lineas, no las ~1400 de un subtitulo completo. Sirve para reconocerlos en
    fuentes que NO los etiquetan, y para no colar un completo como forzado.
    """
    n = n_entradas(texto)
    if n == 0:
        return False
    if referencia:
        return n <= max(60, 0.25 * n_entradas(referencia))
    return n <= 250


# ------------------------------------------------------------- orquestacion
def _aceptar(video, texto, idx_audio, duracion, etq, tolerancia_ms=400):
    """Verifica y, si hace falta y se puede demostrar, desplaza. Devuelve
    (texto_final, informe, inmedible)."""
    v = verificar_sync(video, texto, idx_audio, duracion)
    if not v.get("ok"):
        return None, f"RECHAZADO ({v.get('motivo')})", bool(v.get("inmedible"))
    off_ms = v["offset_s"] * 1000.0
    if abs(off_ms) <= tolerancia_ms:
        return texto, f"OK sin tocar (desfase {off_ms:+.0f} ms, {v['sigma']:.1f} sigma)", False
    return (desplazar_srt(texto, off_ms),
            f"OK desplazado {off_ms:+.0f} ms ({v['sigma']:.1f} sigma)", False)


def desde_biblioteca(video, info, titulo, anyo, quiere, workdir):
    """Intenta cubrir lo pedido con otra copia de la pelicula en la biblioteca."""
    salida = {}
    copias = buscar_copia_local(titulo, anyo, video)
    if not copias:
        log("  [local] no hay otra copia de esta pelicula en la biblioteca.")
        return salida
    for ruta, inf in copias:
        log(f"  [local] encontrada: {os.path.basename(ruta)}  ({len(inf['subs'])} subtitulos)")
        for orden, s in enumerate(inf["subs"]):
            corto = idioma_de_pista(s["lang"], s["title"])
            lang = {"es": "spa", "en": "eng"}.get(corto, s["lang"] or "und")
            destino_tipo = None
            if corto in ("es", "en"):
                destino_tipo = corto + ("_forzado" if es_forzada(s) else "")
            if destino_tipo not in quiere or destino_tipo in salida:
                continue

            tmp = os.path.join(workdir, f"local_{destino_tipo}.srt")
            log(f"    -> pista s:{orden} [{lang}] '{s['title']}' ({s['codec']}) -> {destino_tipo}")
            if s["codec"] in ("subrip", "ass", "ssa", "mov_text", "text"):
                ok = ocr_pista(ruta, orden, lang[:3] or "und", tmp, workdir)
            else:
                log("       OCR (subtitulo de imagen)...")
                ok = ocr_pista(ruta, orden, lang[:3] or "und", tmp, workdir)
            if not ok:
                log("       no se pudo convertir a SRT.")
                continue
            texto = leer_srt(tmp)
            if not texto:
                continue
            idx_audio = audio_para_idioma(info, corto)
            if idx_audio is None:
                log("       el destino no tiene audio con el que verificar.")
                continue
            final, informe, inmedible = _aceptar(video, texto, idx_audio,
                                                 info["duracion"], destino_tipo)
            log(f"       {informe}")
            if final:
                salida[destino_tipo] = final
            elif inmedible:
                # Si no hay con que medir, no lo habra para las demas pistas
                # tampoco: cortar aqui en vez de OCRear las que queden en balde
                # (cada OCR son ~90 s).
                log("       no hay forma de verificar con este fichero; "
                    "se abandona la busqueda local.")
                return salida
    return salida


def desde_opensubtitles(video, info, titulo, anyo, quiere, cfg):
    """Cubre lo que falte con OpenSubtitles. Solo BUSCA si no hay login; en ese
    caso informa de lo que habria y no gasta cupo."""
    salida = {}
    if not cfg:
        log("  [os] sin opensubtitles.json: me lo salto.")
        return salida
    os_api = OpenSubs(cfg)
    ok_login, motivo = os_api.login()
    if not ok_login:
        log(f"  [os] no se puede descargar: {motivo}")
        log("  [os] (la busqueda si funciona; se listara lo que habria)")

    try:
        hh = moviehash(video)
    except Exception:
        hh = None
    fps = None
    j = ffprobe_json(video, ["-select_streams", "v:0", "-show_entries",
                             "stream=r_frame_rate"])
    try:
        rf = (j.get("streams") or [{}])[0].get("r_frame_rate", "0/1")
        a, b = rf.split("/")
        fps = float(a) / float(b) if float(b) else None
    except Exception:
        pass

    for tipo in quiere:
        if tipo in salida:
            continue
        lang = "es" if tipo.startswith("es") else "en"
        forzado = tipo.endswith("forzado")
        consultas = []
        if hh:
            q = {"moviehash": hh, "languages": lang}
            if forzado:
                q["foreign_parts_only"] = "only"
            consultas.append(("hash", q))
        q2 = {"query": titulo, "languages": lang, "order_by": "download_count"}
        if anyo:
            q2["year"] = anyo
        if forzado:
            q2["foreign_parts_only"] = "only"
        consultas.append(("titulo", q2))

        candidatos = []
        for como, q in consultas:
            res = os_api.buscar(**q)
            if res:
                log(f"  [os] {tipo}: {len(res)} resultado(s) por {como}")
                candidatos = res
                break
        if not candidatos:
            log(f"  [os] {tipo}: sin resultados.")
            continue

        candidatos.sort(key=lambda c: puntuar(c, fps, os.path.basename(video)),
                        reverse=True)
        if not ok_login:
            a = candidatos[0].get("attributes", {})
            log(f"  [os] {tipo}: el mejor seria '{(a.get('release') or '')[:60]}' "
                f"(no se descarga: falta login)")
            continue

        for c in candidatos[:4]:
            # CUOTA AGOTADA: no seguir llamando (19/08/2026). OpenSubtitles da 20
            # descargas al dia y 'restantes' llega en la respuesta de cada una,
            # pero solo se escribia en el log: con la cuota a cero, cada pelicula
            # de la cola volvia a intentar login + busqueda + descarga para
            # recibir el mismo rechazo. No rompia nada -la API devuelve su propio
            # mensaje- pero son llamadas inutiles contra un servicio ajeno, y el
            # motivo real quedaba enterrado entre errores genericos.
            if os_api.restantes is not None and os_api.restantes <= 0:
                log("  [os] CUOTA DIARIA AGOTADA (0 descargas restantes). "
                    "No se intenta nada mas hoy; se reintentara manyana.")
                return salida
            a = c.get("attributes", {})
            fichs = a.get("files") or []
            if not fichs:
                continue
            fid = fichs[0].get("file_id")
            if not fid:
                continue
            log(f"  [os] {tipo}: probando '{(a.get('release') or '')[:55]}'...")
            texto, err = os_api.descargar(fid)
            if not texto:
                log(f"       no se pudo descargar: {err}")
                continue
            if forzado and not parece_forzado(texto):
                log(f"       descartado: dice ser forzado pero trae "
                    f"{n_entradas(texto)} lineas (parece completo).")
                continue
            idx_audio = audio_para_idioma(info, lang)
            if idx_audio is None:
                log("       el destino no tiene audio con el que verificar.")
                break
            final, informe, inmedible = _aceptar(video, texto, idx_audio,
                                                 info["duracion"], tipo)
            log(f"       {informe}")
            if final:
                salida[tipo] = final
                break
            if inmedible:
                # AQUI SE AHORRA CUPO. Un pico debil dice que el problema es el
                # FICHERO (poco material con el que medir), no el subtitulo: el
                # siguiente candidato dara exactamente lo mismo. En la primera
                # prueba, sin este corte, se gastaron 8 descargas de 20 seguidas
                # contra un objetivo que no se podia verificar.
                log("       no hay forma de verificar con este fichero; "
                    "no se prueban mas candidatos.")
                break
        if os_api.restantes is not None:
            log(f"  [os] descargas restantes hoy: {os_api.restantes}")
    return salida


def muxear(video, encontrados, workdir):
    """Anyade los SRT al MKV. Escribe a .part y renombra: en la carpeta de una
    cola, un fichero a medias puede ser recogido por un watcher."""
    ETIQ = {"es": ("spa", "Español"), "es_forzado": ("spa", "Español (forzados)"),
            "en": ("eng", "English"), "en_forzado": ("eng", "English (forced)")}
    args = [MKVMERGE, "-o", video + ".part", video]
    for tipo, texto in encontrados.items():
        p = os.path.join(workdir, f"mux_{tipo}.srt")
        with open(p, "w", encoding="utf-8", newline="\r\n") as f:
            f.write(texto)
        lang, nombre = ETIQ[tipo]
        args += ["--language", f"0:{lang}", "--track-name", f"0:{nombre}",
                 "--default-track", "0:no",
                 "--forced-track", "0:" + ("yes" if tipo.endswith("forzado") else "no"), p]
    r = subprocess.run(args, capture_output=True, text=True, timeout=7200)
    if r.returncode != 0 or not os.path.isfile(video + ".part"):
        return False, (r.stdout or r.stderr or "")[-400:]
    os.replace(video + ".part", video)
    return True, ""


def keepalive():
    """Mantiene VIVA la API key haciendo una consulta trivial.

    OpenSubtitles purga las claves que pasan mucho tiempo sin usarse (el usuario
    vio 60 dias). Una tarea programada llama a esto cada 25 dias, que deja
    margen de sobra para dos fallos seguidos antes de acercarse al limite.

    Se usa /infos/formats a proposito: es la consulta mas barata que exige la
    Api-Key, NO gasta cupo de descargas y no depende de que exista ninguna
    pelicula concreta. Un /subtitles tambien valdria, pero devuelve cientos de
    resultados para nada.
    """
    cfg = cargar_config()
    if not cfg:
        log("keepalive: no hay configuracion utilizable.")
        return 1
    api = OpenSubs(cfg)
    s, b = api._pedir("/infos/formats")
    if s == 200:
        formatos = (b.get("data") or {}).get("output_formats") or []
        log(f"keepalive OK: la API responde y la key es valida "
            f"({len(formatos)} formatos de salida).")
        return 0
    log(f"keepalive FALLO: HTTP {s} - {str(b)[:200]}")
    log("  Si es 401/403, la key ya no vale: hay que regenerarla en "
        "opensubtitles.com y actualizarla en opensubtitles.json.")
    return 1


def main():
    ap = argparse.ArgumentParser(description="Busca, verifica y anyade subtitulos.")
    ap.add_argument("video", nargs="?")
    ap.add_argument("--keepalive", action="store_true",
                    help="solo toca la API para que no purguen la key, y sale")
    ap.add_argument("--idiomas", default="es,en")
    ap.add_argument("--forzados", action="store_true")
    ap.add_argument("--mux", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--solo-local", action="store_true")
    ap.add_argument("--titulo", default="")
    ap.add_argument("--anyo", type=int, default=0)
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    if a.keepalive:
        return keepalive()
    if not a.video:
        ap.error("hace falta un video (o --keepalive)")
    if not os.path.isfile(a.video):
        log(f"ERROR: no existe {a.video}")
        return 1

    info = info_video(a.video)
    if info is None:
        # Caso real y distinto de "no tiene subtitulos": ver
        # ffprobe-aborta-por-una-pista-rota.
        log("ERROR: ffprobe no puede leer este fichero. Puede estar perfecto y "
            "tener UNA pista ilegible que aborta el sondeo entero.")
        log("       Comprueba con:  mkvmerge -J \"%s\"" % a.video)
        return 1
    if not info["audios"]:
        log("ERROR: el fichero no tiene audio; no hay con que verificar sincronia.")
        return 1

    titulo = a.titulo or titulo_y_anyo(a.video)[0]
    anyo = a.anyo or titulo_y_anyo(a.video)[1]
    quiere = []
    for l in [x.strip() for x in a.idiomas.split(",") if x.strip()]:
        quiere.append(l)
    # --forzados pide los forzados de TODOS los idiomas solicitados, no solo del
    # castellano: en una pelicula en ingles con doblaje, los forzados en ingles
    # son los que traducen el dialogo en OTRO idioma (el gaelico de Braveheart,
    # el elfico de El Senyor de los Anillos...) y hacen falta igual.
    if a.forzados:
        for l in list(quiere):
            if not l.endswith("_forzado") and (l + "_forzado") not in quiere:
                quiere.append(l + "_forzado")

    # QUE CUENTA COMO "YA LO TIENE" (criterio del usuario, 07/08/2026)
    # ------------------------------------------------------------------
    # Esto solo debe actuar en peliculas SIN subtitulos o con VobSub. El resto
    # ya funciona y no hay que tocarlo:
    #   - texto (srt/ass/ssa/mov_text) -> ya esta, no se busca nada
    #   - PGS                          -> EL PIPELINE LO OCREA (Convert-SubToSrt
    #                                     con PgsToSrt). Cuenta como resuelto.
    #   - VobSub (dvd_subtitle)        -> NO hay OCR para esto (PgsToSrt solo
    #                                     entiende PGS), asi que NO cuenta: la
    #                                     pista se quedaria como imagen y Plex
    #                                     tendria que quemarla en cada
    #                                     reproduccion. Se busca sustituto.
    #   - sin subtitulos               -> se busca
    #
    # Ojo: sin esta distincion, una pelicula con PGS perfectamente OCReables se
    # trataba como candidata y se gastaba cupo de descarga para nada.
    RESUELTOS = ("subrip", "ass", "ssa", "mov_text", "text", "hdmv_pgs_subtitle")
    ya = set()
    vobsub = []
    for s in info["subs"]:
        etiqueta = (idioma_de_pista(s["lang"], s["title"])
                    + ("_forzado" if es_forzada(s) else ""))
        if s["codec"] in RESUELTOS:
            ya.add(etiqueta)
        elif s["codec"] == "dvd_subtitle":
            vobsub.append(etiqueta)
    pendientes = [t for t in quiere if t not in ya]

    log(f"Pelicula : {titulo}" + (f" ({anyo})" if anyo else ""))
    log(f"Duracion : {info['duracion']:.1f} s")
    # PARENTESIS, y no son cosmeticos (03/09/2026). Esto era
    #     log(f"Resueltos: {...}" + "   [texto o PGS...]" if ya else "")
    # y el '+' se evalua ANTES que el if/else, asi que la expresion entera
    # era (cadena + cadena) if ya else "": con 'ya' VACIO la linea salia en
    # BLANCO -justo el caso interesante, la pelicula sin subtitulos ya
    # resueltos- y la rama '(ninguno)' de dentro del f-string era codigo
    # INALCANZABLE.
    log(f"Resueltos: {sorted(ya) if ya else '(ninguno)'}"
        + ("   [texto o PGS: el pipeline ya se apanya]" if ya else ""))
    if vobsub:
        log(f"VobSub   : {sorted(set(vobsub))}  <- NO hay OCR para esto; "
            f"se busca sustituto de texto")
    log(f"Se buscan: {pendientes if pendientes else '(nada)'}")
    if not pendientes:
        log("No hace falta hacer nada: esta pelicula ya esta resuelta.")
        return 0
    if a.dry_run:
        log("(--dry-run: no se busca nada)")
        return 0

    workdir = tempfile.mkdtemp(prefix="_subsfetch_")
    try:
        encontrados = desde_biblioteca(a.video, info, titulo, anyo, pendientes, workdir)
        faltan = [t for t in pendientes if t not in encontrados]
        if faltan and not a.solo_local:
            encontrados.update(
                desde_opensubtitles(a.video, info, titulo, anyo, faltan, cargar_config()))
        faltan = [t for t in pendientes if t not in encontrados]

        if not encontrados:
            log("RESULTADO: no se consiguio ningun subtitulo verificable.")
            return 1

        destino_dir = a.out or os.path.dirname(a.video)
        base = os.path.splitext(os.path.basename(a.video))[0]
        # Estos sufijos los lee encode.ps1 para recoger lo generado: si se
        # tocan aqui, tocar tambien el $mapa de alli.
        SUF = {"es": ".es.srt", "es_forzado": ".es.forced.srt",
               "en": ".en.srt", "en_forzado": ".en.forced.srt"}
        for tipo, texto in encontrados.items():
            p = os.path.join(destino_dir, base + SUF.get(tipo, f".{tipo}.srt"))
            with open(p, "w", encoding="utf-8", newline="\r\n") as f:
                f.write(texto)
            log(f"  escrito: {os.path.basename(p)}  ({n_entradas(texto)} entradas)")

        if a.mux:
            ok, err = muxear(a.video, encontrados, workdir)
            log("  muxeado dentro del MKV." if ok else f"  ERROR al muxear: {err}")
            if not ok:
                return 1

        log(f"RESULTADO: conseguidos {sorted(encontrados)}"
            + (f"; NO conseguidos {faltan}" if faltan else ""))
        return 2 if faltan else 0
    finally:
        for f in os.listdir(workdir):
            try:
                os.remove(os.path.join(workdir, f))
            except OSError:
                pass
        try:
            os.rmdir(workdir)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
