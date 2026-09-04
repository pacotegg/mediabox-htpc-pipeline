"""
MediaBox — unified panel (port 8080)
Tabs: Encoder · Sync · YT-DLP

CAMBIOS v2:
  - Nuevo endpoint /api/enc/queue/move (reordenar la cola con las flechas ▲▼).
  - Campo subs_dropped expuesto en el listado de "Completed".
  - File browser arranca en BASE (Windows) en vez de "~".
"""
from flask import Flask, render_template, jsonify, Response, request, make_response
import os, sys, glob, json, signal, time, subprocess, threading, uuid, re, shutil, collections
import ctypes
from datetime import datetime

app = Flask(__name__, template_folder="templates", static_folder="static")
app.config["TEMPLATES_AUTO_RELOAD"] = True


# ══════════════════════════════════════════════════════════════════════════════
# ESCRITURAS SOLO DESDE EL PROPIO PANEL  (20/08/2026)
# ══════════════════════════════════════════════════════════════════════════════
# QUE PROBLEMA RESUELVE, medido y no supuesto:
#
#     POST /api/enc/resume  con  Origin: https://sitio-cualquiera.example
#     -> HTTP 200, ejecutado
#
# El panel no pide credenciales -no hacen falta: es una LAN domestica de un solo
# usuario- pero eso deja una puerta que NO depende de que nadie entre en la red:
# CUALQUIER pagina web que visites puede mandar un <form method=POST> a
# http://<htpc>:8080/api/enc/kill y abortarte un encode. No necesita JavaScript
# ni que el navegador le conceda CORS, porque un formulario normal no pide
# permiso para ENVIARSE, solo para leer la respuesta.
#
# Los alcanzables asi son los que no necesitan cuerpo: enc/kill, enc/skip,
# enc/resume, ytdlp/clear_history y audio|subs/cancel/live. Es decir: parar un
# trabajo de dos horas. Comprobado tambien lo que NO se puede: leer ninguna
# respuesta (sin cabeceras CORS el navegador bloquea el cuerpo, asi que no se
# filtra nada) ni mandar un cuerpo JSON, con lo que remux/add y sync/add no son
# accionables con rutas elegidas por otro.
#
# POR QUE ESTA REGLA Y NO UN LOGIN: un login se paga cincuenta veces al dia y no
# quita mas riesgo que esto. La regla es "rechazar una escritura SOLO si trae
# Origin y ese Origin no es el mio":
#   - un navegador SIEMPRE manda Origin en un POST a otro sitio -> se bloquea;
#   - el propio panel manda el suyo -> pasa;
#   - curl, los scripts y cualquier automatismo NO mandan Origin -> pasan, y
#     todo lo que hoy funciona a mano sigue funcionando igual.
# Las lecturas (GET) no se tocan: no cambian nada y bloquearlas solo estorbaria.
from urllib.parse import urlparse
import ipaddress, socket

_METODOS_SEGUROS = {"GET", "HEAD", "OPTIONS"}

# ── Nombres por los que se acepta que llamen a este panel ────────────────────
# LO QUE ESTO PARA, y es lo que hacia que la comprobacion de Origin de abajo NO
# bastara por si sola: **DNS REBINDING**.
#
# El ataque: una web cualquiera registra 'evil.com' con un TTL de un segundo. La
# primera resolucion apunta a su servidor -y asi te sirve la pagina-; la segunda
# apunta a 192.168.31.16, o sea AQUI. A partir de ese momento el navegador cree
# que 'evil.com' y el panel son EL MISMO SITIO, asi que:
#   - manda Origin: http://evil.com:8080 y Host: evil.com:8080 -> la regla de
#     Origin los ve iguales y los deja pasar;
#   - y como para el navegador es mismo-origen, el atacante ademas puede LEER
#     las respuestas, que es justo lo que las cabeceras CORS le impedian.
# O sea que sin esto se pasa de "puede abortarte un trabajo" a "puede listarte
# el disco entero con /api/browse y leerte los logs".
#
# LA DEFENSA es mirar el Host, no el Origin: **el rebinding necesita un NOMBRE**.
# Una IP literal no se puede reasignar por DNS, asi que cualquier IP pasa. De los
# nombres solo pasan los conocidos: 'localhost' y el nombre de esta maquina (que
# es tambien el que usa la MagicDNS de Tailscale, si algun dia se instala).
#
# Esto SI se aplica a las lecturas (GET), al reves que la regla de Origin: el
# premio del rebinding es leer, asi que protegerlo solo en las escrituras no
# serviria de nada.
#
# Si algun dia hace falta otro nombre, se anyade sin tocar codigo:
#     setx MEDIABOX_HOSTS "htpc.casa,mediabox.lan"
# y el 403 que sale cuando no cuadra ya lo dice, para que nadie se quede
# preguntando por que el panel "no va" desde una direccion nueva.
_HOST_NOMBRES_OK = {"localhost"}
try:
    _hn = socket.gethostname().lower()
    _HOST_NOMBRES_OK |= {_hn, _hn.split(".")[0], _hn.split(".")[0] + ".local"}
except Exception:
    pass
for _extra in (os.environ.get("MEDIABOX_HOSTS") or "").split(","):
    _extra = _extra.strip().lower()
    if _extra:
        _HOST_NOMBRES_OK.add(_extra)


def _host_permitido(host):
    if not host:
        return False
    h = host.lower().strip()
    if h.startswith("["):                       # IPv6 entre corchetes
        h = h[1:h.index("]")] if "]" in h else h[1:]
    elif ":" in h:
        h = h.rsplit(":", 1)[0]
    try:
        ipaddress.ip_address(h)
        return True          # una IP literal no se puede reapuntar por DNS
    except ValueError:
        pass
    return h in _HOST_NOMBRES_OK


@app.before_request
def _guarda_de_entrada():
    # 1) DE QUE NOMBRE dicen que vienen (para todo, tambien las lecturas).
    if not _host_permitido(request.host):
        return jsonify({
            "ok": False,
            "error": "Peticion rechazada: este panel no responde al nombre «%s». "
                     "Entra por su IP (p. ej. http://192.168.31.16:8080) o anyade "
                     "el nombre a la variable de entorno MEDIABOX_HOSTS y reinicia "
                     "el panel. Permitidos ahora: %s, o cualquier IP."
                     % (request.host, ", ".join(sorted(_HOST_NOMBRES_OK)))}), 403

    # 2) QUE PAGINA la lanza (solo escrituras). Una web ajena SIEMPRE manda
    #    Origin en un POST a otro sitio; curl y los scripts no mandan ninguno.
    if request.method in _METODOS_SEGUROS:
        return None
    origen = request.headers.get("Origin")
    if not origen:
        return None                       # curl / scripts / clientes no-navegador
    if urlparse(origen).netloc == request.host:
        return None                       # el propio panel
    return jsonify({
        "ok": False,
        "error": "Peticion rechazada: viene de %s, que no es este panel. "
                 "El panel solo acepta escrituras desde su propia pagina."
                 % origen}), 403


# ── Cabeceras de seguridad en TODA respuesta ─────────────────────────────────
# Ninguna cambia lo que se ve; son red de seguridad por si algo se escapa.
#
#   CSP  - la palanca de verdad. La pagina es autocontenida salvo las fuentes de
#          Google, asi que se permiten esas y NADA MAS: aunque colara texto con
#          HTML dentro (los titulos de pista de un MKV son texto libre), no
#          podria cargar un script de fuera NI MANDAR NADA a ningun sitio, que es
#          lo que convierte un fallo de escapado en una fuga. Hacen falta los
#          'unsafe-inline' porque el panel lleva su <style>, su <script> y sus
#          onclick dentro del propio HTML; aun asi, connect-src 'self' deja sin
#          salida a cualquier inyeccion.
#   frame-ancestors 'none' - que nadie pueda meter el panel en un iframe y
#          hacerte pulsar STOP sin que lo veas.
#   nosniff - que el navegador no adivine el tipo de un log y lo trate como HTML.
#   no-referrer - los nombres de tus peliculas no viajan en la cabecera Referer
#          cuando la pagina pide las fuentes a Google.
_CSP = ("default-src 'self'; "
        "script-src 'self' 'unsafe-inline'; "
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
        "font-src 'self' https://fonts.gstatic.com; "
        "img-src 'self' data:; "
        "connect-src 'self'; "
        "form-action 'self'; "
        "base-uri 'none'; "
        "object-src 'none'; "
        "frame-ancestors 'none'")


@app.after_request
def _cabeceras_seguras(resp):
    resp.headers.setdefault("Content-Security-Policy", _CSP)
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("Referrer-Policy", "no-referrer")
    resp.headers.setdefault("X-Frame-Options", "DENY")
    return resp

# ══════════════════════════════════════════════════════════════════════════════
# SHARED PATHS / HELPERS
# ══════════════════════════════════════════════════════════════════════════════
import tempfile
# ── Configuration ─────────────────────────────────────────────────
# BASE is your media root. Override with the MEDIABOX_BASE env var, or edit here.
# Must match $Base in encode.ps1 and encode-watch.ps1.
BASE = os.environ.get("MEDIABOX_BASE", r"C:\Media")
TMP  = os.path.join(BASE, "tmp")   # temp UNICO bajo C:\Media (debe coincidir con los .ps1)
os.makedirs(TMP, exist_ok=True)
# Where encode.ps1 lives (used to launch encodes if ever needed from the panel)
SCRIPT_DIR = os.environ.get("MEDIABOX_SCRIPTS", r"C:\scripts")

# ffmpeg/ffprobe por ruta ABSOLUTA (regla del proyecto: no depender del PATH,
# que ya dejo el OCR roto semanas cuando dotnet desaparecio de el). El panel los
# usa para probes (badges de la cola, Sync, Audio) y para los trabajos de Sync.
FFMPEG  = r"C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe"
FFPROBE = r"C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffprobe.exe"
if not os.path.isfile(FFMPEG):  FFMPEG  = "ffmpeg"
if not os.path.isfile(FFPROBE): FFPROBE = "ffprobe"

LOG_DIR   = os.path.join(BASE, "encode_logs")
DONE_DIR  = os.path.join(BASE, "encoded")
os.makedirs(LOG_DIR,  exist_ok=True)
os.makedirs(DONE_DIR, exist_ok=True)

VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".mov", ".ts", ".m2ts", ".wmv", ".flv", ".webm", ".mpg", ".mpeg"}

# TODO proceso hijo se lanza con esto. Sin el, cada ffprobe/taskkill/mkvmerge
# abre y cierra una consola; ya estaba puesto en powercfg justo por eso, pero
# faltaba en los otros dieciocho sitios. Vive AQUI ARRIBA, y no a medio fichero,
# porque lo usan funciones repartidas por todo el modulo.
_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
_K32 = None
if os.name == "nt":
    # Prototipos EXPLICITOS. Por defecto ctypes asume que una funcion devuelve un
    # c_int de 32 bits, y HANDLE en un Windows de 64 no lo es: sin esto el handle
    # llegaria truncado y el CloseHandle de despues cerraria vete a saber que.
    _K32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _K32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    _K32.OpenProcess.restype  = ctypes.c_void_p
    _K32.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    _K32.GetExitCodeProcess.restype  = ctypes.c_int
    _K32.CloseHandle.argtypes = [ctypes.c_void_p]
    _K32.CloseHandle.restype  = ctypes.c_int

def fmt_size(size):
    if size >= 1_073_741_824: return f"{size/1_073_741_824:.1f} GB"
    if size >= 1_048_576:     return f"{size/1_048_576:.0f} MB"
    return f"{size/1024:.0f} KB"


def _read_kv(path, base=None):
    """Lee un fichero de estado 'clave=valor' por lineas (encode_status,
    audio_status, subs_status). UNA sola copia: habia CUATRO, y cada una habia
    ido divergiendo un poco (una toleraba el BOM, otra no; una hacia strip antes
    de partir, otra despues). Devuelve `base` intacto si el fichero no existe:
    que el watcher aun no haya escrito nada NO es un error."""
    st = dict(base or {})
    try:
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                if "=" in line:
                    k, v = line.split("=", 1)
                    st[k.strip()] = v.strip()
    except OSError:
        pass
    return st


def _pid_vivo(pid):
    """True si ese PID existe. Sin lanzar 'tasklist'.

    POR QUE: esto lo consulta /api/remux/status, que el panel sondea CADA 3 s
    mientras esta abierto. Medido en este equipo, cada 'tasklist' cuesta 141 ms
    y arranca un proceso; o sea 141 ms de proceso nuevo cada 3 s justo mientras
    el pipeline trabaja, que es cuando el lock existe y la rama se ejecuta.
    OpenProcess cuesta microsegundos y contesta lo mismo.

    El STILL_ACTIVE hace falta ademas del OpenProcess: si otro proceso conserva
    un handle abierto al hijo ya muerto, el objeto de proceso sigue existiendo y
    OpenProcess tiene exito sobre un zombi.
    """
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if os.name != "nt":
        try:
            os.kill(pid, 0); return True
        except OSError:
            return False
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    ERROR_ACCESS_DENIED = 5
    STILL_ACTIVE = 259
    k32 = _K32
    h = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not h:
        # Existe pero no nos deja mirarlo (otro usuario, mas privilegios): vivo.
        # Hay que leer el error con get_last_error() -de ahi el use_last_error
        # del WinDLL-: llamar a GetLastError() por ctypes lo pisaria.
        return ctypes.get_last_error() == ERROR_ACCESS_DENIED
    try:
        code = ctypes.c_ulong()
        if k32.GetExitCodeProcess(h, ctypes.byref(code)):
            return code.value == STILL_ACTIVE
        return True
    finally:
        k32.CloseHandle(h)


# ── Encolar un fichero en una cola dirigida por carpeta ───────────────────────
# Los tres botones que mandan un MKV a una cola (Audio, Subs y "a cola de video")
# hacian shutil.copy2 DENTRO del request HTTP. Dos problemas:
#
#   1. Un MKV de 40 GB tarda varios minutos. El navegador se quedaba con el boton
#      en "Añadiendo..." todo ese rato, sin barra ni mensaje: no habia forma de
#      distinguir "copiando" de "colgado", y el hilo de Flask quedaba ocupado.
#   2. Se copiaba DIRECTAMENTE sobre el nombre final, dentro de la carpeta que
#      vigila el watcher. Los watchers esperan 3 s a que el tamano se estabilice
#      antes de coger nada, asi que en el caso normal no pasaba nada; pero un
#      atasco de disco de mas de 3 s -o el panel muriendose a mitad- dejan ahi un
#      fichero TRUNCADO con el nombre bueno y toda la pinta de estar entero.
#
# Ahora se copia a "<nombre>.partial" -extension que los watchers descartan
# explicitamente, con aviso en su log- y solo al terminar se renombra con
# os.replace, que es atomico. La copia va en un hilo y el request vuelve al
# momento; el avance se publica en el panel (ver 'copying' en los status).
copias      = []
copias_lock = threading.Lock()

# Cuanto se queda visible en el panel una copia ya terminada. Lo justo para que
# se vea que acabo bien: a partir de ahi el fichero ya sale en la cola de verdad,
# y dejarlo en las dos listas confunde.
COPIA_TTL_S = 20


def _copias_de(*destinos):
    """Copias en curso (o recien acabadas) hacia esos destinos, para el panel."""
    ahora = time.time()
    with copias_lock:
        for c in list(copias):
            if c["estado"] != "copiando" and ahora - c.get("ended", ahora) > COPIA_TTL_S:
                copias.remove(c)
        return [{"name": c["name"], "estado": c["estado"], "error": c["error"],
                 "dest": c["dest"],
                 "pct": round(100.0 * c["hecho"] / c["total"], 1) if c["total"] else 0}
                for c in copias if c["dest"] in destinos]


def _copiar(src, final, reg):
    tmp = final + ".partial"
    try:
        with open(src, "rb") as fi, open(tmp, "wb") as fo:
            while True:
                trozo = fi.read(8 << 20)
                if not trozo:
                    break
                fo.write(trozo)
                reg["hecho"] += len(trozo)
        shutil.copystat(src, tmp)      # lo que copy2 conserva y copyfile no
        os.replace(tmp, final)
        reg["estado"] = "listo"
    except Exception as e:
        reg["estado"] = "error"
        reg["error"]  = str(e)
        # El .partial es NUESTRO temporal: si la copia fallo no sirve para nada y
        # ocupa lo que llevara escrito. Se borra. (El original no se toca nunca.)
        try:    os.remove(tmp)
        except OSError: pass
    reg["ended"] = time.time()


def _encolar_async(src, dst_dir, destino):
    """Copia `src` a la cola `dst_dir` en segundo plano. Devuelve YA."""
    nombre = os.path.basename(src)
    try:
        os.makedirs(dst_dir, exist_ok=True)
    except OSError as e:
        return {"ok": False, "error": str(e)}
    final = os.path.join(dst_dir, nombre)
    if os.path.exists(final):
        return {"ok": False, "error": "ya hay un «%s» en esa cola" % nombre}
    with copias_lock:
        if any(c["estado"] == "copiando" and c["name"] == nombre and c["dest"] == destino
               for c in copias):
            return {"ok": False, "error": "ya se esta copiando «%s» a esa cola" % nombre}
    try:
        total = os.path.getsize(src)
    except OSError as e:
        return {"ok": False, "error": str(e)}
    # Espacio ANTES de empezar, misma politica que _remux_space_check: mas vale no
    # arrancar que llenar la unidad y dejar el destino a medias.
    try:
        libre = shutil.disk_usage(dst_dir).free
        if libre < total * 1.02:
            return {"ok": False,
                    "error": "no cabe en %s: hacen falta %s y hay %s libres"
                             % (dst_dir, fmt_size(total), fmt_size(libre))}
    except OSError:
        pass
    reg = {"name": nombre, "dest": destino, "total": total, "hecho": 0,
           "estado": "copiando", "error": "", "added": time.time()}
    with copias_lock:
        copias.append(reg)
    threading.Thread(target=_copiar, args=(src, final, reg), daemon=True).start()
    return {"ok": True, "queued": nombre, "copying": True,
            "size": fmt_size(total)}


# ── Listar una cola dirigida por carpeta ──────────────────────────────────────
# Estaban duplicados en audio_status y subs_status (y el de 'done', ademas, en
# _enc_rebuild_listing). Una sola copia, y con dos arreglos que solo tenia una:
#   - se descartan los '.partial' (copias en curso del propio panel), que si no
#     aparecerian en la cola como si fueran trabajos de verdad;
#   - glob.escape sobre la carpeta: un '[' en la ruta es un COMODIN para glob y
#     haria que no encontrase nada (el mismo mordisco que los corchetes dan en
#     PowerShell sin -LiteralPath).
# Sufijos que NUNCA son un trabajo, solo ficheros de servicio que viven en la
# misma carpeta que la cola:
#   .partial -> copia en curso del propio panel (_encolar_async)
#   .opts    -> ajustes por pelicula (el campo "Mbps"); viaja con el fichero de
#               la cola a _running, asi que hay que filtrarlo en las DOS.
# Si no se filtran, salen en el panel como si fueran peliculas y ademas se les
# lanza un ffprobe por cada refresco para sacarles el badge de audio.
_COLA_NO_TRABAJO = (".partial", ".opts")


def _cola_pendientes(d):
    try:
        return sorted(x for x in os.listdir(d) if not x.endswith(_COLA_NO_TRABAJO))
    except OSError:
        return []


def _cola_terminados(d, n=15):
    try:
        vids = [p for p in glob.glob(glob.escape(d) + "/*")
                if os.path.splitext(p)[1].lower() in VIDEO_EXTS]
        return sorted(vids, key=os.path.getmtime, reverse=True)[:n]
    except OSError:
        return []


def _tail_log(carpeta, n=40):
    """Ultimas n lineas del .log mas reciente de esa carpeta. Lo usaban Audio y
    Subs con el mismo codigo copiado."""
    try:
        logs = sorted(glob.glob(os.path.join(glob.escape(carpeta), "*.log")),
                      key=os.path.getmtime, reverse=True)
        if not logs:
            return []
        # encoding utf-8 EXPLICITO (01/09/2026): los logs los escribe
        # PowerShell 7 en UTF-8 y llevan nombres de pelicula acentuados. Sin
        # esto se leian como cp1252 y salian con mojibake en el panel.
        with open(logs[0], encoding="utf-8", errors="replace") as lf:
            return lf.read().splitlines()[-n:]
    except OSError:
        return []

# ══════════════════════════════════════════════════════════════════════════════
# SHARED: FILE BROWSER
# ══════════════════════════════════════════════════════════════════════════════
# Pseudo-carpeta "Equipo": lista las unidades. Hace falta porque en la raiz de una
# unidad os.path.dirname('C:\\') devuelve 'C:\\' otra vez, asi que no se generaba
# ".." y era IMPOSIBLE salir de C: para ir a G: o E:. El explorador nunca estuvo
# limitado a C: -acepta cualquier ruta-, simplemente no habia por donde subir.
DRIVES_ROOT = "::unidades"

def _list_drives():
    entries = []
    for letra in "CDEFGHIJKLMNOPQRSTUVWXYZ":
        raiz = "%s:\\" % letra
        if not os.path.isdir(raiz):
            continue
        libre = ""
        try:
            u = shutil.disk_usage(raiz)
            libre = "%s libres de %s" % (fmt_size(u.free), fmt_size(u.total))
        except Exception:
            pass
        entries.append({"name": "%s:\\" % letra, "path": raiz, "type": "dir", "size": libre})
    return entries


@app.route("/api/browse", methods=["POST"])
def browse():
    data = request.get_json(silent=True) or {}
    # Por defecto arranca en BASE (raiz de medios en Windows), no en ~
    path = (data.get("path") or BASE).strip()
    if path == DRIVES_ROOT:
        return jsonify({"ok": True, "path": DRIVES_ROOT, "entries": _list_drives()})
    path = os.path.expanduser(path)
    try:
        path = os.path.realpath(path)
    except:
        path = BASE
    if not os.path.isdir(path):
        path = os.path.dirname(path) or BASE
    try:
        entries = []
        parent = os.path.dirname(path)
        if parent != path:
            entries.append({"name": "..", "path": parent, "type": "dir", "size": ""})
        else:
            # Raiz de unidad: el ".." lleva a la lista de unidades.
            entries.append({"name": "..", "path": DRIVES_ROOT, "type": "dir",
                            "size": "unidades del equipo"})
        items = sorted(os.scandir(path), key=lambda e: (not e.is_dir(), e.name.lower()))
        for item in items:
            if item.name.startswith("."): continue
            if item.is_dir():
                entries.append({"name": item.name, "path": item.path, "type": "dir", "size": ""})
            elif os.path.splitext(item.name)[1].lower() in VIDEO_EXTS:
                try:    size_str = fmt_size(item.stat().st_size)
                except: size_str = ""
                entries.append({"name": item.name, "path": item.path, "type": "file", "size": size_str})
        return jsonify({"ok": True, "path": path, "entries": entries})
    except PermissionError:
        return jsonify({"ok": False, "error": "Permission denied", "path": path, "entries": []})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e), "path": path, "entries": []})


# ══════════════════════════════════════════════════════════════════════════════
# TAB 1 — ENCODER
# ══════════════════════════════════════════════════════════════════════════════
ENC_QUEUE   = os.path.join(BASE, "encode_queue")
ENC_RUNNING = os.path.join(BASE, "encode_running")
STATUS_F    = os.path.join(TMP, "encode_status")
PROG_F      = os.path.join(TMP, "encode_ffprog")
PID_F       = os.path.join(TMP, "encode_pid")
# Flag de PAUSA de la cola de video: lo escribe el Stop del panel y lo respeta
# encode-watch.ps1 (no coge nada nuevo mientras exista). Se quita con Resume.
PAUSE_F     = os.path.join(TMP, "encode_paused")
# RETENCION: mientras exista, encode-watch.ps1 no arranca ningun trabajo que no
# traiga una decision explicita de modo en su sidecar. NO es una pausa -la cola
# sigue viva y lo ya decidido entra- sino "preguntame antes de empezar".
# Existe porque QVBR e ICQ tienen sesgos OPUESTOS (QVBR castiga por duracion,
# ICQ por grano) y para algunas peliculas la eleccion buena solo la puede hacer
# quien las mira; sin esto el watcher las coge a los 8 s y decide el perfil.
HOLD_F      = os.path.join(TMP, "encode_hold")
HIST_F      = os.path.join(LOG_DIR, "completed.jsonl")
os.makedirs(ENC_QUEUE,   exist_ok=True)
os.makedirs(ENC_RUNNING, exist_ok=True)

def enc_load_history():
    """El historial de trabajos terminados, indexado por nombre de salida.

    encoding="utf-8" EXPLICITO, y no es cosmetico (01/09/2026). Sin el, open()
    usa la codificacion del sistema, que en esta maquina es cp1252, y
    completed.jsonl lo escriben dos scripts de PowerShell 7 en UTF-8 -con 232
    lineas acentuadas: 'Posesión Infernal', 'Océanos de fuego'...-.

    Lo que pasaba, medido: al llegar a un byte que cp1252 no define (0x81) el
    open lanzaba UnicodeDecodeError, el bucle estaba DENTRO del try y el
    'except: pass' se lo tragaba entero. Resultado: el panel cargaba 256
    entradas de 1.013 y ensenyaba un historial recortado al 25 % sin una sola
    senyal de que faltara nada.

    errors="replace" ademas de utf-8: si algun dia una linea entra con bytes
    rotos, se pierde ESA linea y no las 750 siguientes.
    """
    hist = {}
    try:
        with open(HIST_F, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try:
                    rec = json.loads(line)
                    key = rec.get("output", "")
                    if key: hist[key] = rec
                except Exception:
                    # Una linea suelta ilegible no es noticia: el jsonl se
                    # escribe con Add-Content desde dos procesos y una linea a
                    # medias es posible. Las demas se siguen leyendo.
                    pass
    except FileNotFoundError:
        # Normal la primera vez: aun no ha terminado ningun trabajo. No es un
        # fallo y no merece una linea de log en cada sondeo.
        pass
    except Exception as e:
        # Cualquier otro fallo SI se dice: es la diferencia entre "no hay
        # historial" y "el historial no se pudo leer", que es justo lo que
        # oculto este fallo durante meses.
        print("[hist] no se pudo leer %s: %s" % (HIST_F, e), flush=True)
    return hist

# ── Barra de progreso UNIFICADA ───────────────────────────────────────────────
# EL PROBLEMA (19/08/2026): la barra llegaba al 99,99 % con ffmpeg, RETROCEDIA al
# 97 % y se quedaba ahi un buen rato. Y ese 97 % no era optimista, era falso:
# medido sobre "Oceanos De Fuego" (salida de 10,24 GB), despues de ffmpeg quedan
# la reconstruccion del contenedor y los tags, que tardaron 13,6 min sobre un
# encode de 39,7. En "El informe Pelicano" fueron 19,6 min de 50,8. O sea que el
# ultimo 3 % de la barra escondia entre el 25 % y el 40 % del trabajo.
#
# LA SOLUCION: una sola barra que NUNCA va hacia atras y donde el 100 % significa
# terminado de verdad, para que al llegar enganche el siguiente fichero. Cada fase
# ocupa un tramo proporcional a lo que tarda DE VERDAD (medido, no inventado) y
# dentro de su tramo avanza con su progreso real.
#
# El tramo previo al video va comprimido a proposito: en el camino normal el audio
# corre EN PARALELO con el video (no es duenyo de la barra, se pinta aparte como
# 'audio_stage'), asi que ahi solo caen el analisis y la verificacion, que son
# segundos. Solo se estira si el audio va en serie, que hoy es el camino raro.
ENC_BANDAS = {
    "analizando":  (0.0,  4.0),
    "verificando": (0.0,  8.0),
    "subs":        (0.0,  8.0),   # OCR de subtitulos
    "extract":     (0.0,  8.0),   # audio en SERIE (si fuera paralelo no manda aqui)
    "truehdd":     (0.0,  8.0),
    "dee":         (0.0,  8.0),
    "ddp":         (0.0,  8.0),
    "video":       (8.0, 72.0),
    "rebuild":     (72.0, 96.0),
    "finalizing":  (96.0, 100.0),
}


def enc_pct_global(stage, pct_fase):
    """Lleva el % DE LA FASE a la barra global. Devuelve None si la fase no esta
    en la tabla, y entonces el llamante deja el valor como estaba (mejor un
    numero viejo que uno inventado)."""
    banda = ENC_BANDAS.get(stage or "video")
    if not banda:
        return None
    lo, hi = banda
    try:
        p = float(pct_fase or 0)
    except (TypeError, ValueError):
        p = 0.0
    p = max(0.0, min(100.0, p))
    return round(lo + (hi - lo) * p / 100.0, 1)


def enc_read_state():
    state = _read_kv(STATUS_F, {"status": "idle", "file": "", "duration": 0, "error": ""})
    try:
        state["duration"] = float(state.get("duration", 0) or 0)
    except (TypeError, ValueError):
        state["duration"] = 0
    return state

def enc_read_progress():
    """Ultimo bloque COMPLETO del fichero -progress de ffmpeg.

    Antes esto separaba bloques por linea en blanco ('\\n\\n'), y ffmpeg NO escribe
    lineas en blanco: los bloques terminan en 'progress=continue'. Comprobado el
    04/08/2026 sobre un fichero real: 13 bloques, 0 lineas en blanco. O sea que el
    split devolvia UN solo bloque -la ventana entera- y lo que salvaba el resultado
    era que, al recorrer todas las lineas, cada clave se quedaba con su ultima
    aparicion. Funcionaba por accidente.
    El problema de fiarse de eso: ffmpeg escribe el bloque CAMPO A CAMPO, asi que
    una lectura puede pillarlo a medias. Con el metodo viejo se mezclaban valores
    de dos instantes distintos (p.ej. 'fps' del bloque nuevo y 'speed' del
    anterior), que es justo el tipo de incoherencia que se veia en el panel: fps
    alto con speed absurdamente bajo.
    Ahora se corta por 'progress=' y se descarta el ultimo trozo si esta a medias,
    de modo que TODOS los valores salen del mismo instante.
    """
    last = {}
    try:
        with open(PROG_F, "rb") as f:
            f.seek(0, 2); size = f.tell()
            f.seek(max(0, size - 8192))
            tail = f.read().decode("utf-8", errors="replace")
        # Cada bloque termina en 'progress=continue' / 'progress=end'. Nos quedamos
        # con el ultimo que este COMPLETO (es decir, que ya tenga su terminador).
        partes = tail.split("progress=")
        if len(partes) >= 2:
            # partes[-1] es lo escrito DESPUES del ultimo terminador: bloque a
            # medias, se ignora. El bloque completo mas reciente es partes[-2],
            # cuyo contenido va desde el terminador anterior hasta el suyo.
            bloque = partes[-2]
            for line in bloque.split("\n"):
                line = line.strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    last[k.strip()] = v.strip()
            # Y SU TERMINADOR (26/08/2026). El corte por 'progress=' dejaba la
            # clave 'progress' FUERA del bloque devuelto -su valor vive al
            # principio del trozo siguiente-, asi que desde el 04/08/2026
            # prog["progress"] no existia nunca y la rama que la consulta era
            # codigo muerto. Verificado sobre un encode_ffprog real de 68 KB.
            # partes[-1] empieza justo por ese valor ('end' al terminar,
            # 'continue' mientras ffmpeg sigue), tanto si detras hay un bloque a
            # medias como si no hay nada.
            last["progress"] = partes[-1].split("\n", 1)[0].strip()
    except: pass
    return last

# Cache for the expensive directory/history work in enc_build_payload.
# Rebuilt only when the queue/done/running folders or history file change
# (cheap mtime+count signature), instead of every SSE tick.
_enc_cache = {"sig": None, "queue": [], "running": [], "done": []}

# Muestras (instante, segundos_de_video_codificados) para la ETA por ritmo
# reciente. Ver el bloque de ETA en enc_build_payload.
#
# El maxlen es GENEROSO a proposito. La ventana que importa es la de TIEMPO (120 s,
# podada mas abajo), pero quien alimenta esta cola es enc_build_payload, y eso
# corre una vez por segundo POR CADA CLIENTE conectado al SSE. Con 200 huecos y
# tres pestanyas abiertas la cola se llenaba en 66 s, o sea que la ventana de la
# ETA se encogia a la mitad sin que nada lo dijera. 4000 aguanta 120 s aunque haya
# treinta clientes.
_eta_hist = collections.deque(maxlen=4000)

def _enc_dir_sig(path):
    try:
        st = os.stat(path)
        n = len(os.listdir(path))
        return (int(st.st_mtime), n)
    except: return (0, 0)

def _enc_listing_signature():
    try: hist_sig = os.path.getsize(HIST_F)
    except: hist_sig = 0
    return (_enc_dir_sig(ENC_QUEUE), _enc_dir_sig(ENC_RUNNING),
            _enc_dir_sig(DONE_DIR), hist_sig)

# Detecta el tipo de audio "especial" de un fichero para el badge de la cola:
#   "ddp_atmos" -> TrueHD+Atmos (se convertira a DDP+Atmos)
#   "truehd"    -> TrueHD sin Atmos (se convertira a DD+ 640k via deew/DEE)
#   ""          -> nada que senalar
# Cachea por (path, mtime, size) para no lanzar ffprobe en cada rebuild.
_audio_tag_cache = {}

def _enc_audio_tag(path):
    try:
        st = os.stat(path)
        key = (path, int(st.st_mtime), st.st_size)
    except OSError:
        return ""
    cached = _audio_tag_cache.get(path)
    if cached and cached[0] == key:
        return cached[1]
    tag = ""
    try:
        r = subprocess.run(
            [FFPROBE, "-v", "error", "-select_streams", "a",
             "-show_entries", "stream=codec_name,profile", "-of", "json", path],
            capture_output=True, text=True, timeout=25, creationflags=_NO_WINDOW)
        data = json.loads(r.stdout or "{}")
        has_truehd = has_atmos = False
        for s in data.get("streams", []):
            if (s.get("codec_name") or "").lower() in ("truehd", "mlp"): has_truehd = True
            if "atmos" in (s.get("profile") or "").lower(): has_atmos = True
        if has_truehd and has_atmos: tag = "ddp_atmos"
        elif has_truehd:             tag = "truehd"
    except Exception:
        tag = ""
    # Tope: la cache es por RUTA y una ruta que sale de la cola ya no vuelve, asi
    # que sin esto crece para siempre. 500 entradas cubren cualquier cola real.
    if len(_audio_tag_cache) > 500:
        _audio_tag_cache.clear()
    _audio_tag_cache[path] = (key, tag)
    return tag

# ── Ajustes por pelicula: el sidecar '<fichero>.opts' ────────────────────────
# Lo lee encode-watch.ps1 justo antes de lanzar el trabajo y se lo pasa a
# encode.ps1 como -TargetMbps. Ver el comentario largo de ese parametro.
#
# POR QUE EXISTE: en 4K el GQ es INERTE (medido: cuatro puntos mueven el 1,3 %
# del tamano, porque manda el -b:v), asi que la unica forma de hacer una pelicula
# concreta mas pequena es tocarle el bitrate. Y tiene que ser por pelicula: el
# suelo de 8,5M sale de mirar fotogramas, y bajarlo para todas se llevaria por
# delante las peliculas exigentes.
#
# LIMITES: 1,0 a 30,0 Mbps. No son de calidad -eso lo decides tu mirando-, son
# para que un dedazo (un 60 en vez de un 6, o un 0,6) no lance un encode de horas
# que hay que tirar. 0 o vacio = quitar el ajuste y volver al automatico.
ENC_OPTS_MIN = 1.0
ENC_OPTS_MAX = 30.0


def _enc_opts_path(fname):
    """Ruta del sidecar de un fichero DE LA COLA. basename() a proposito: este
    valor viene del navegador y no puede componer rutas hacia otras carpetas."""
    return os.path.join(ENC_QUEUE, os.path.basename(fname) + ".opts")


ENC_MODOS = ("auto", "icq", "qvbr")


def _enc_opts_read(fname):
    """Ajustes a mano de ese fichero: {'mode','target_mbps'}. Nunca lanza: un
    sidecar roto tiene que degradar a 'automatico', no tumbar el listado."""
    d = {"mode": "auto", "target_mbps": 0}
    try:
        with open(_enc_opts_path(fname), encoding="utf-8") as fh:
            o = json.load(fh) or {}
        v = float(o.get("target_mbps") or 0)
        if v > 0:
            d["target_mbps"] = v
        m = (o.get("mode") or "auto").strip().lower()
        if m in ENC_MODOS:
            d["mode"] = m
    except Exception:
        pass
    return d


def _enc_rebuild_listing():
    hist = enc_load_history()
    queue_raw = _cola_pendientes(ENC_QUEUE)
    queue = []
    for qf in queue_raw:
        if qf.endswith(".thd"): continue  # decision sidecar, not a real queue item
        qpath = os.path.join(ENC_QUEUE, qf)
        try:    qsize = fmt_size(os.path.getsize(qpath))
        except: qsize = ""
        display = qf
        if len(qf) > 4 and qf[0:3].isdigit() and qf[3] == '_':
            display = qf[4:]
        queue.append({"file": qf, "display": display, "size": qsize,
                      "audio_tag": _enc_audio_tag(qpath),
                      # Ajustes a mano de esta pelicula: el desplegable de modo y
                      # el campo Mbps de su fila. mode='auto' + 0 = sin tocar.
                      **_enc_opts_read(qf)})
    running = _cola_pendientes(ENC_RUNNING)
    done_paths = _cola_terminados(DONE_DIR, 20)
    done = []
    for p in done_paths:
        name = os.path.basename(p); rec = hist.get(name)
        out_size = ""; src_size = ""; reduction = ""
        try:
            out_bytes = os.path.getsize(p)
            out_size = fmt_size(out_bytes)
            if rec and rec.get("source"):
                src_path = rec["source"]
                if not os.path.exists(src_path):
                    src_path = os.path.join(ENC_RUNNING, os.path.basename(src_path))
                if os.path.exists(src_path):
                    src_bytes = os.path.getsize(src_path)
                    src_size = fmt_size(src_bytes)
                    if src_bytes > 0:
                        reduction = f"-{round((1 - out_bytes / src_bytes) * 100)}%"
        except: pass
        done.append({"name": name, "size": out_size, "src_size": src_size,
                      "reduction": reduction, "logged": rec is not None,
                      "subs_dropped": int((rec or {}).get("subs_dropped", 0) or 0)})
    return queue, running, done

_enc_cache_lock = threading.Lock()


def _enc_refresh(sig):
    try:
        q, r, d = _enc_rebuild_listing()
        _enc_cache.update({"sig": sig, "queue": q, "running": r, "done": d})
    except Exception:
        pass          # que se reintente en el proximo tick, no que muera el hilo
    finally:
        _enc_cache_lock.release()


def _enc_get_listing():
    """Devuelve SIEMPRE al momento. Si la cola ha cambiado, la reconstruccion se
    lanza aparte y el resultado entra en el tick siguiente.

    POR QUE (20/08/2026). Reconstruir el listado incluye el badge de audio, que
    es un ffprobe POR FICHERO de la cola: 569 ms medidos sobre un fichero real,
    o sea ~8,5 s con quince peliculas encoladas. Y esto se llamaba EN LINEA desde
    enc_build_payload, que corre una vez por segundo Y POR CLIENTE conectado al
    SSE. Consecuencias que tenia:
      - nada mas arrancar el panel, con la cache vacia, el primer tick se
        quedaba esos segundos dentro del ffprobe y el panel parecia colgado;
      - con dos pestanyas abiertas, las dos entraban a la vez y hacian el MISMO
        trabajo por duplicado, cada una con su tanda de ffprobes.
    Con el lock no-bloqueante solo reconstruye uno, y nadie espera: los demas
    siguen sirviendo la copia anterior, que es exactamente lo que ya hacian
    mientras la firma no cambiaba.
    """
    sig = _enc_listing_signature()
    if sig != _enc_cache["sig"] and _enc_cache_lock.acquire(blocking=False):
        # El try/except NO es decorativo: quien suelta el lock es _enc_refresh,
        # dentro del hilo. Si Thread.start() fallara (el sistema sin poder crear
        # mas hilos), el lock se quedaria cogido PARA SIEMPRE y la cola, los
        # trabajos en curso y los completados dejarian de refrescarse en el panel
        # hasta reiniciarlo, sin ningun mensaje. Se suelta aqui y que se reintente
        # en el tick siguiente.
        try:
            threading.Thread(target=_enc_refresh, args=(sig,), daemon=True).start()
        except Exception:
            _enc_cache_lock.release()
    return _enc_cache["queue"], _enc_cache["running"], _enc_cache["done"]

def enc_build_payload():
    state  = enc_read_state()
    prog   = enc_read_progress()
    status = state.get("status", "idle")
    dur    = float(state.get("duration", 0) or 0)
    fps = prog.get("fps", ""); speed = prog.get("speed", "")
    bitrate = prog.get("bitrate", ""); out_time = prog.get("out_time", "")
    pct = 0; eta = ""
    secs = 0
    # Se calculan LOS DOS metodos y se toma el que mas haya avanzado.
    #
    # POR QUE (medido el 06/08/2026 en el encode de "El Destino De Jupiter"):
    # antes out_time era el primario y el metodo por fotogramas solo entraba si el
    # primero daba 0. Pero out_time no falla dando 0: se QUEDA CONGELADO en un
    # valor. En ese encode se paro en 00:19:33 mientras 'frame' seguia subiendo:
    # el panel marcaba 15 % con el trabajo por el 46 %, y ademas el 'speed' iba
    # BAJANDO (1,88x -> 1,51x) porque se calcula sobre ese reloj muerto. Parecia
    # un encode atascado cuando en realidad iba a 4,83x tiempo real.
    # Con el maximo de los dos, un out_time congelado deja de mandar en cuanto los
    # fotogramas lo adelantan, y si el que falla es el de fotogramas (sin fps_src)
    # sigue mandando out_time. Ninguno de los dos puede colgar la barra solo.
    secs_ot = 0.0; pct_ot = 0.0
    if dur > 0 and out_time and ":" in out_time:
        try:
            p = out_time.split(":")
            secs_ot = float(p[0])*3600 + float(p[1])*60 + float(p[2])
            pct_ot = min(99.9, round(secs_ot / dur * 100, 1))
        except: pass
    secs_fr = 0.0; pct_fr = 0.0
    if dur > 0:
        try:
            frame = float(prog.get("frame", 0) or 0)
            fps_raw = (state.get("fps_src", "") or "").replace(",", "").strip()
            fps_val = 0.0
            if "/" in fps_raw:
                a, b = fps_raw.split("/")
                fps_val = float(a) / float(b) if float(b) else 0.0
            elif fps_raw:
                fps_val = float(fps_raw)
            if frame > 0 and fps_val > 0:
                total_frames = dur * fps_val
                if total_frames > 0:
                    secs_fr = frame / fps_val
                    pct_fr = min(99.9, round(frame / total_frames * 100, 1))
        except: pass
    # 'secs' alimenta ademas la ETA por ritmo reciente (mas abajo): tiene que venir
    # del MISMO metodo que gano, o la ETA se calcularia sobre el reloj congelado y
    # daria tiempos disparatados justo cuando el encode va bien.
    if pct_fr > pct_ot:
        pct = pct_fr; secs = secs_fr
        # OUT_TIME NO ES DE FIAR. No basta con arreglar el porcentaje: 'speed',
        # 'bitrate' y el 'Encoded' que muestra el panel salen TODOS de ese mismo
        # reloj, asi que con el congelado enseñaban "0.0353x" y "1353468 kbits/s"
        # (1,35 Gbps) junto a un 85,6 % correcto. Se marca aqui y mas abajo se
        # recalculan los tres a partir de los fotogramas, que es lo unico que
        # avanza de verdad.
        out_time_roto = True
    else:
        pct = pct_ot; secs = secs_ot
        out_time_roto = False
    # ETA. Se calcula con el ritmo RECIENTE (ultimos ~2 min de muestras propias),
    # no con el 'speed' de ffmpeg.
    # POR QUE: el speed de ffmpeg es una media ACUMULADA desde que arranco. Si el
    # encode empieza lento -inicializacion de QSV, primeros minutos complejos,
    # disco ocupado- esa media tarda muchisimo en recuperarse y la ETA sale
    # disparatada mientras el encode ya va rapido: se veian 144 fps con "speed
    # 0.571x" y 2h30m restantes, y al rato lo mismo iba a 5.96x. El ritmo reciente
    # refleja lo que esta pasando AHORA, que es lo que uno quiere saber.
    # Se conserva el speed de ffmpeg para MOSTRARLO (es su dato, no lo falseamos);
    # lo que cambia es de donde sale la estimacion.
    if secs > 0:
        try:
            ahora = time.time()
            _eta_hist.append((ahora, secs))
            # Ventana de ~2 min; se descartan muestras viejas y las de otro trabajo
            # (si secs RETROCEDE es que empezo un encode nuevo: se limpia).
            while len(_eta_hist) >= 2 and _eta_hist[0][1] > secs:
                _eta_hist.clear(); _eta_hist.append((ahora, secs))
            while len(_eta_hist) >= 2 and ahora - _eta_hist[0][0] > 120:
                _eta_hist.popleft()
            ritmo = 0.0
            if len(_eta_hist) >= 2:
                dt = ahora - _eta_hist[0][0]
                dsec = secs - _eta_hist[0][1]
                if dt >= 10 and dsec > 0:
                    ritmo = dsec / dt          # segundos de video por segundo real
            if ritmo <= 0 and speed:           # aun sin historial: el de ffmpeg
                ritmo = float(speed.replace("x","").strip())
            if ritmo > 0:
                rem = (dur - secs) / ritmo
                h = int(rem//3600); m = int((rem%3600)//60); s = int(rem%60)
                eta = f"{h}h {m:02d}m" if h else f"{m}m {s:02d}s"
        except: pass
    # hevc_qsv manda speed/bitrate/out_time como "N/A" todo el encode, pero frame
    # y total_size si llegan: derivamos los tres para no mostrar "—" en el panel.
    #   Encoded = frame/fps_src | Speed = fps/fps_src | Bitrate = size*8/Encoded
    def _na(v): return (not v) or v == "N/A"
    try:
        fps_raw2 = (state.get("fps_src", "") or "").replace(",", "").strip()
        fps_src_val = 0.0
        if "/" in fps_raw2:
            a2, b2 = fps_raw2.split("/")
            fps_src_val = float(a2) / float(b2) if float(b2) else 0.0
        elif fps_raw2:
            fps_src_val = float(fps_raw2)
        frame_n = float(prog.get("frame", 0) or 0)
        enc_secs = 0.0
        # Si out_time quedo descartado arriba, NO se usa aqui tampoco: seria
        # volver a meter el reloj congelado por la puerta de atras.
        if not out_time_roto and not _na(out_time) and ":" in out_time:
            p = out_time.split(":"); enc_secs = float(p[0])*3600 + float(p[1])*60 + float(p[2])
        elif fps_src_val > 0 and frame_n > 0:
            enc_secs = frame_n / fps_src_val
        # Los tres campos se rehacen tanto si ffmpeg no los manda (_na) como si los
        # manda MAL (out_time_roto). Antes solo se cubria el primer caso, y por eso
        # el panel enseñaba un porcentaje bueno junto a una velocidad y un bitrate
        # delirantes: no eran "—", eran numeros calculados sobre un reloj parado.
        if (_na(out_time) or out_time_roto) and enc_secs > 0:
            h = int(enc_secs//3600); m = int((enc_secs%3600)//60); s = int(enc_secs%60)
            out_time = f"{h:02d}:{m:02d}:{s:02d}"
        if (_na(speed) or out_time_roto) and fps_src_val > 0 and not _na(fps):
            try:
                # fps que reporta ffmpeg / fps de la fuente = velocidad real.
                # Es ademas el ritmo ACTUAL, no la media acumulada desde el
                # arranque que da el 'speed' de ffmpeg.
                spd = float(str(fps).strip()) / fps_src_val
                if spd > 0: speed = f"{spd:.2f}x"
            except: pass
        if _na(bitrate) or out_time_roto:
            ts = float(prog.get("total_size", 0) or 0)
            if ts > 0 and enc_secs > 0:
                bitrate = f"{ts * 8 / enc_secs / 1000:.1f}kbits/s"
        if not eta and enc_secs > 0 and dur > 0 and not _na(speed):
            try:
                spd2 = float(str(speed).replace("x","").strip())
                if spd2 > 0:
                    rem = (dur - enc_secs) / spd2
                    if rem > 0:
                        h2 = int(rem//3600); m2 = int((rem%3600)//60); s2 = int(rem%60)
                        eta = f"{h2}h {m2:02d}m" if h2 else f"{m2}m {s2:02d}s"
            except: pass
    except: pass
    stage = state.get("stage", "")
    # 'progress=end' = ffmpeg termino. CON GUARDA desde el 26/08/2026: solo manda
    # si encode_status NO esta reportando una fase POSTERIOR a ffmpeg.
    #
    # Por que hace falta la guarda: tras la ultima pasada de ffmpeg, encode.ps1
    # NO borra encode_ffprog -se queda con su 'progress=end'- y entra en
    # 'rebuild' y 'finalizing', que juntas duran 13-20 min en un 4K. Sin la
    # guarda, esta linea las daria por 'idle / 100 %' y saltaria los tramos
    # rebuild(72-96) y finalizing(96-100) de ENC_BANDAS, o sea justo el fallo que
    # ENC_BANDAS vino a arreglar: la barra clavada y "No active encode" con la
    # maquina trabajando, que ya hizo cancelar dos peliculas que estaban listas.
    # (No se notaba porque la clave 'progress' no llegaba hasta hoy; al
    #  restaurarla arriba, la guarda pasa a ser imprescindible.)
    #
    # Lo que la rama SI sigue cubriendo: un encode_ffprog de un trabajo anterior
    # sobreviviendo junto a un encode_status que se quedo en 'encoding'.
    if prog.get("progress") == "end" and stage not in ("rebuild", "finalizing"):
        status = "idle"; pct = 100
    # Fase de AUDIO (truehdd/dee): ffmpeg aun no ha arrancado, asi que no hay
    # encode_ffprog y todo lo de arriba deja pct=0. encode.ps1 reporta stage/pct
    # en encode_status durante esa fase (stage='extract'|'truehdd'|'dee'), igual
    # que hace audio_encode.ps1 con audio_status. Sin esto el panel se queda en
    # blanco ~20 min por pelicula y parece colgado.
    if stage and stage != "video" and status == "encoding":
        try:
            pct = min(99.9, float(state.get("pct", 0) or 0))
        except: pass
        eta = ""
    # 'pct' es el porcentaje DE LA FASE en curso. Se guarda tal cual (el panel lo
    # enseña como "fase NN%") y ademas se lleva a la barra global, que es la que
    # avanza de 0 a 100 una sola vez por fichero y nunca retrocede.
    pct_fase = pct
    if status == "encoding":
        g = enc_pct_global(stage or "video", pct)
        if g is not None:
            pct = g
    queue, running, done = _enc_get_listing()
    return {"status": status, "file": state.get("file",""), "error": state.get("error",""),
            "fps": fps, "speed": speed, "bitrate": bitrate, "out_time": out_time,
            "pct": pct, "pct_fase": pct_fase, "eta": eta, "stage": stage,
            "queue": queue, "running": running, "done": done,
            # Avance del audio cuando corre EN PARALELO con el encode de video
            # (encode.ps1, $ParallelAudioVideo). Va en campos APARTE y no en
            # stage/pct a proposito: esos dos pisan el progreso del ffprog y
            # borran el ETA (ver el bloque de arriba), asi que el audio se pinta
            # como linea secundaria y el video sigue mandando en la barra.
            "audio_stage": state.get("audio_stage", ""),
            "audio_pct": state.get("audio_pct", ""),
            "paused": os.path.exists(PAUSE_F),
            # Retencion: distinta de 'paused'. Ver HOLD_F.
            "hold": os.path.exists(HOLD_F),
            # PAUSA GLOBAL de mantenimiento (los tres pipelines + el remux del
            # panel). Va en ESTE payload -y no en el de la pestanya Remux- porque
            # es el unico que llega SIEMPRE, por SSE, se mire la pestanya que se
            # mire: la pausa afecta a todo y tiene que verse desde cualquier sitio.
            # Sin esto era invisible: se quedaba puesta y el panel simplemente no
            # encolaba nada, sin decir por que.
            "global_paused": os.path.exists(PIPELINE_PAUSED)}

@app.route("/api/enc/status")
def enc_status():
    return jsonify(enc_build_payload())

def _kill_pid(pid):
    """Mata un proceso y TODO su arbol en Windows. os.kill(SIGTERM) no vale para
    ffmpeg; taskkill /F /T lo fuerza junto con sus hijos.
    Por ruta ABSOLUTA a taskkill: no dependemos del PATH (el mismo que rompio el
    OCR una vez). Con el PID de encode.ps1, /T se lleva ffmpeg, dee, truehdd,
    deew, dotnet-OCR y mkvextract de una vez. Devuelve True si mato algo."""
    if os.name == "nt":
        tk = r"C:\Windows\System32\taskkill.exe"
        if not os.path.isfile(tk): tk = "taskkill"
        # timeout (01/09/2026): taskkill normalmente tarda milisegundos, pero si
        # se queda esperando a un proceso que no muere, esta llamada bloquea el
        # hilo del panel para siempre y la interfaz deja de responder. 20 s es
        # holgadisimo para lo que hace.
        try:
            r = subprocess.run([tk, "/PID", str(pid), "/F", "/T"],
                               capture_output=True, text=True,
                               creationflags=_NO_WINDOW, timeout=20)
        except subprocess.TimeoutExpired:
            return False
        return r.returncode == 0
    else:
        try:
            os.kill(pid, signal.SIGTERM); return True
        except Exception:
            return False

@app.route("/api/enc/kill", methods=["POST"])
def enc_kill():
    # Stop = parar TODO: mata el trabajo en curso Y PAUSA la cola (el watcher no
    # coge el siguiente hasta que se pulse Reanudar). El flag se escribe ANTES
    # del kill para que el watcher no pueda colarse en la ventana entre ambos.
    # NO se borra ninguna fuente (queda en encode_running); la salida parcial y
    # los temporales los barre el watcher (Clean-JobLeftovers) al morir el hijo.
    try:
        open(PAUSE_F, "w").close()
    except Exception:
        pass
    killed = None
    try:
        with open(PID_F) as f: pid = int(f.read().strip())
        if _kill_pid(pid): killed = pid
    except: pass
    try:
        with open(STATUS_F, "w") as f: f.write("status=idle\n")
    except: pass
    return jsonify({"ok": True, "killed": killed, "paused": True})

@app.route("/api/enc/resume", methods=["POST"])
def enc_resume():
    # Quita la pausa: el watcher vuelve a coger ficheros de la cola.
    try: os.remove(PAUSE_F)
    except: pass
    return jsonify({"ok": True, "paused": False})

# ── Reordenar la cola (flechas ▲▼ del panel) ──────────────────────────────────
# La cola se ordena alfabeticamente por nombre de fichero (ver _enc_rebuild_listing,
# que usa sorted()). Para mover un item arriba/abajo renombramos el prefijo numerico
# "NNN_" que ya contempla el resto del codigo (encode.ps1 lo recorta del display y
# encode-watch.ps1 procesa por orden alfabetico). Reescribimos los prefijos de toda
# la cola para que el orden visual coincida con el de procesamiento.
@app.route("/api/enc/queue/move", methods=["POST"])
def enc_queue_move():
    data = request.get_json(silent=True) or {}
    fname = os.path.basename((data.get("file") or "").strip())
    direction = (data.get("direction") or "").strip().lower()
    if direction not in ("up", "down"):
        return jsonify({"ok": False, "error": "Invalid direction"})
    if not fname:
        return jsonify({"ok": False, "error": "No file"})

    try:
        # Lista actual de items reales (sin sidecars .thd), en orden alfabetico
        items = sorted(f for f in os.listdir(ENC_QUEUE) if not f.endswith(".thd"))
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})

    if fname not in items:
        return jsonify({"ok": False, "error": "File no longer in queue"})

    idx = items.index(fname)
    swap = idx - 1 if direction == "up" else idx + 1
    if swap < 0 or swap >= len(items):
        return jsonify({"ok": True, "noop": True})  # ya esta en el extremo

    # Intercambiar posiciones en la lista
    items[idx], items[swap] = items[swap], items[idx]

    # Reescribir todos los nombres con prefijo NNN_ segun el nuevo orden.
    # Se quita primero cualquier prefijo NNN_ existente para no acumularlos.
    def strip_prefix(n):
        if len(n) > 4 and n[0:3].isdigit() and n[3] == '_':
            return n[4:]
        return n

    renamed = []
    try:
        # Paso 1: a nombres temporales para evitar colisiones durante el renombrado
        tmp_map = []
        for i, n in enumerate(items):
            base = strip_prefix(n)
            tmp = f"__tmp_{i:03d}_{base}"
            os.rename(os.path.join(ENC_QUEUE, n), os.path.join(ENC_QUEUE, tmp))
            # mover tambien el sidecar .thd si existe
            thd = os.path.join(ENC_QUEUE, n + ".thd")
            if os.path.exists(thd):
                os.rename(thd, os.path.join(ENC_QUEUE, tmp + ".thd"))
            tmp_map.append((tmp, base))
        # Paso 2: del temporal al nombre final NNN_
        for i, (tmp, base) in enumerate(tmp_map):
            final = f"{i:03d}_{base}"
            os.rename(os.path.join(ENC_QUEUE, tmp), os.path.join(ENC_QUEUE, final))
            thd = os.path.join(ENC_QUEUE, tmp + ".thd")
            if os.path.exists(thd):
                os.rename(thd, os.path.join(ENC_QUEUE, final + ".thd"))
            renamed.append(final)
    except Exception as e:
        return jsonify({"ok": False, "error": f"Rename failed: {e}"})

    # Invalidar cache para que el cambio se vea en el proximo tick
    _enc_cache["sig"] = None
    return jsonify({"ok": True, "order": renamed})

# Aqui vivia /api/enc/truehd_decide, la consulta "TrueHD sin Atmos: keep o
# convert?". ELIMINADA el 19/08/2026: la politica es convertir TODO TrueHD desde
# hace tiempo, asi que encode-watch.ps1 ya no escribia nunca encode_truehd_pending
# y ni el modal ni esta ruta eran alcanzables. Costaba un open() fallido en CADA
# sondeo de estado. Ver el comentario de encode-watch.ps1 para la politica actual.

@app.route("/api/enc/queue/opts", methods=["POST"])
def enc_queue_opts():
    """Fija (o quita) el bitrate de video de UN fichero de la cola.

    Escribe/borra el sidecar que lee encode-watch.ps1. No toca nada mas: si el
    trabajo ya ha salido de la cola, esto no lo alcanza -y es lo correcto, porque
    el bitrate se decide al arrancar encode.ps1 y ya no se puede cambiar-.
    """
    data = request.get_json(silent=True) or {}
    fname = os.path.basename((data.get("file") or "").strip())
    if not fname:
        return jsonify({"ok": False, "error": "falta el fichero"})
    if not os.path.isfile(os.path.join(ENC_QUEUE, fname)):
        return jsonify({"ok": False, "error": "«%s» ya no esta en la cola" % fname})

    # El modo puede venir solo, el bitrate solo, o los dos. Lo que no venga se
    # conserva: asi tocar el desplegable no borra los Mbps que ya habias puesto.
    actual = _enc_opts_read(fname)
    modo = data.get("mode")
    if modo is None:
        modo = actual["mode"]
    modo = str(modo).strip().lower()
    if modo not in ENC_MODOS:
        return jsonify({"ok": False, "error": "modo «%s» desconocido" % modo})

    crudo = data.get("target_mbps")
    pide_mbps = crudo is not None
    if not pide_mbps:
        crudo = actual["target_mbps"] or None

    # ICQ Y UN BITRATE A MANO SON INCOMPATIBLES: en ICQ no se emite -b:v, asi que
    # el numero no se aplicaria. Dos casos y ninguno se resuelve en silencio:
    #   - pedir ICQ estando puesto un bitrate -> se BORRA el bitrate. Elegir ICQ
    #     es elegir "sin objetivo"; dejarlo guardado haria que el desplegable
    #     dijera ICQ y el fichero acabara en QVBR, que es justo lo que pasaba.
    #   - pedir los dos A LA VEZ -> se rechaza y se explica. La interfaz nunca
    #     manda los dos juntos (cada control manda solo lo suyo), asi que esto
    #     solo lo alcanza quien llame a la ruta a mano.
    pide_modo = data.get("mode") is not None
    # OJO al 'pide_modo': sin el, esto rechazaba tambien "pon 4.5 Mbps" sobre un
    # sidecar que ya tenia icq guardado -y ese caso NO es contradictorio, es
    # cambiar de opinion: se resuelve pasando a qvbr, mas abajo-. Solo es
    # contradiccion cuando las DOS cosas vienen en la misma peticion.
    if pide_modo and modo == "icq" and pide_mbps and crudo not in (None, "", 0, "0", 0.0):
        return jsonify({"ok": False,
                        "error": "ICQ y un bitrate a mano son incompatibles: en ICQ no hay "
                                 "-b:v donde aplicarlo. Elige QVBR si quieres fijar los Mbps."})
    if pide_modo and modo == "icq":
        crudo = None

    # Sin modo y sin bitrate no hay nada que guardar: se BORRA el sidecar en vez
    # de dejar un fichero que no dice nada.
    if modo == "auto" and crudo in (None, "", 0, "0", 0.0):
        try:
            os.remove(_enc_opts_path(fname))
        except OSError:
            pass
        return jsonify({"ok": True, "mode": "auto", "target_mbps": 0})

    if crudo in (None, "", 0, "0", 0.0):
        return _enc_opts_write(fname, modo, 0)

    try:
        # float() de Python es SIEMPRE punto decimal, sin importar el locale del
        # sistema; por eso el JSON que se escribe aqui lo lee bien el
        # ConvertFrom-Json de PowerShell en una maquina en es-ES. Ver
        # parseo-decimal-locale-es.
        v = float(str(crudo).replace(",", "."))
    except ValueError:
        return jsonify({"ok": False, "error": "«%s» no es un numero" % crudo})
    if not (ENC_OPTS_MIN <= v <= ENC_OPTS_MAX):
        return jsonify({"ok": False,
                        "error": "el bitrate tiene que estar entre %.0f y %.0f Mbps"
                                 % (ENC_OPTS_MIN, ENC_OPTS_MAX)})

    # Un bitrate a mano SOLO significa algo con -b:v, o sea en QVBR. Si se pidio
    # ICQ y ademas un numero, el numero no se aplicaria: se dice y se corrige a
    # qvbr en vez de guardar algo que no se va a cumplir.
    if modo == "icq":
        modo = "qvbr"
    return _enc_opts_write(fname, modo, round(v, 2))


def _enc_opts_write(fname, modo, mbps):
    """Escritura ATOMICA del sidecar: el watcher sondea la cola cada 5 s y medio
    JSON se lee como sidecar roto."""
    tmp = _enc_opts_path(fname) + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"mode": modo, "target_mbps": mbps}, fh)
        os.replace(tmp, _enc_opts_path(fname))
    except OSError as e:
        try:    os.remove(tmp)
        except OSError: pass
        return jsonify({"ok": False, "error": str(e)})
    return jsonify({"ok": True, "mode": modo, "target_mbps": mbps})


@app.route("/api/enc/hold", methods=["POST"])
def enc_hold():
    """Interruptor de RETENCION. No para lo que ya corre ni vacia la cola: solo
    hace que no arranque nada sin decision de modo."""
    on = bool((request.get_json(silent=True) or {}).get("on"))
    try:
        if on:
            open(HOLD_F, "w").close()
        else:
            os.remove(HOLD_F)
    except OSError:
        pass
    return jsonify({"ok": True, "hold": os.path.exists(HOLD_F)})


@app.route("/api/enc/skip", methods=["POST"])
def enc_skip():
    # Skip = matar el trabajo en curso y dejar que el watcher pase al siguiente
    # de la cola. NO BORRA NADA: la fuente se queda en encode_running (como
    # despues de cualquier encode, para decidir a mano). La version anterior
    # borraba TODO encode_running a ciegas, incluso cuando el kill no habia
    # funcionado (fase de audio, PID de un ffmpeg inexistente): eso borraba la
    # fuente del encode EN CURSO (que entonces fallaba) y de paso los fuentes
    # acumulados de encodes anteriores -> los "han fallado y se han borrado".
    # La salida parcial y los temporales los barre el watcher (Clean-JobLeftovers)
    # cuando el proceso muere, via el marcador encode_outfile.
    killed = None
    try:
        with open(PID_F) as f: pid = int(f.read().strip())
        if _kill_pid(pid): killed = pid
    except: pass
    with open(STATUS_F, "w") as f: f.write("status=idle\n")
    return jsonify({"ok": True, "killed": killed, "deleted": []})

@app.route("/api/enc/logs")
def enc_logs():
    if not os.path.exists(LOG_DIR): return jsonify([])
    files = sorted(glob.glob(os.path.join(LOG_DIR, "*.log")), key=os.path.getmtime, reverse=True)[:30]
    return jsonify([{"name": os.path.basename(f), "size": os.path.getsize(f),
                     "mtime": int(os.path.getmtime(f))} for f in files])

@app.route("/api/enc/log/<path:filename>")
def enc_log(filename):
    safe = os.path.basename(filename)
    if not safe.endswith(".log"): return jsonify({"error": "Invalid"}), 400
    full = os.path.join(LOG_DIR, safe)
    if not os.path.isfile(full): return jsonify({"error": "Not found"}), 404
    try:
        # Se DECLARA charset=utf-8 en la respuesta, asi que hay que LEERLO
        # como utf-8: sin encoding se decodificaba en cp1252 y se volvia a
        # codificar en utf-8, o sea doble estropicio en cada acento.
        with open(full, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        return content, 200, {"Content-Type": "text/plain; charset=utf-8"}
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ══════════════════════════════════════════════════════════════════════════════
# TAB 2 — SYNC (audio + subtitle offset)
# ══════════════════════════════════════════════════════════════════════════════
sync_jobs  = []   # list of dicts
sync_lock  = threading.Lock()
sync_worker_thread = None

def sync_probe_streams(filepath, con_error=False):
    """Pistas de audio y subtitulo: {index, codec_type, codec_name, language, title}.

    con_error=True devuelve (pistas, mensaje_de_error) en vez de solo la lista.
    HACE FALTA porque "no hay pistas" y "ffprobe no pudo leer el fichero" se
    contestaban IGUAL -una lista vacia- y la interfaz enseñaba "— No audio
    streams —" tan tranquila. Y el caso no es raro: ffprobe aborta el sondeo
    ENTERO si UNA sola pista esta rota, aunque el fichero sea perfectamente
    reproducible (ver ffprobe-aborta-por-una-pista-rota). Sin el mensaje, el
    usuario se queda mirando un fichero que "no tiene audio" y que si lo tiene.
    """
    err = ""
    try:
        r = subprocess.run(
            [FFPROBE, "-v", "error",
             "-show_entries", "stream=index,codec_type,codec_name:stream_tags=language,title",
             "-of", "json", filepath],
            capture_output=True, text=True, timeout=20, creationflags=_NO_WINDOW
        )
        data = json.loads(r.stdout or "{}")
        streams = []
        for s in data.get("streams", []):
            if s.get("codec_type") not in ("audio", "subtitle"): continue
            tags = s.get("tags", {})
            streams.append({
                "index":      s.get("index"),
                "codec_type": s.get("codec_type"),
                "codec_name": s.get("codec_name", ""),
                "language":   tags.get("language", ""),
                "title":      tags.get("title", ""),
            })
        if not streams:
            err = (r.stderr or "").strip()[:300] or (
                "ffprobe no devolvio ninguna pista de audio ni de subtitulos")
        return (streams, err) if con_error else streams
    except Exception as e:
        return ([], str(e)) if con_error else []

def sync_build_cmd(job):
    """Build the ffmpeg command for the sync job.

    Tanto el desfase de AUDIO como el de SUBTITULOS se aplican con -itsoffset
    sobre entradas adicionales del MISMO fichero, y todo se copia (-c copy).

    POR QUE NO FILTROS PARA EL AUDIO (adelay/atrim), que es lo que habia antes:
    un filtro obliga a decodificar y recodificar. La version anterior sacaba la
    pista desfasada como eac3 640k, asi que sincronizar una pista TrueHD+Atmos
    la convertia en eac3 SIN Atmos, en silencio. Con -itsoffset la pista se copia
    tal cual: mismo codec, mismos objetos, sin perdida.

    -itsoffset corre los timestamps de la ENTRADA entera, por eso hace falta una
    entrada extra por cada desfase DISTINTO (no por cada pista).

    Desfases NEGATIVOS: generan timestamps negativos, pero es seguro. Segun la
    doc de ffmpeg, avoid_negative_ts (modo 'auto', que matroska activa cuando lo
    necesita) corre TODAS las marcas de tiempo la misma cantidad y conserva las
    diferencias relativas entre audio, video y subtitulos. La sincronia se
    mantiene; el fichero entero empieza un pelin mas tarde, que es inocuo.
    """
    inp      = job["filepath"]
    out      = job["output"]
    # Listas de indices de stream (pueden ser varias pistas con el MISMO desfase).
    a_idxs   = job.get("audio_streams") or []
    a_offset = float(job.get("audio_offset", 0.0))
    s_idxs   = job.get("sub_streams") or []
    s_offset = float(job.get("sub_offset", 0.0))

    # Probe all audio/sub streams to build map list
    streams = sync_probe_streams(inp)
    audio_streams = [s for s in streams if s["codec_type"] == "audio"]
    sub_streams   = [s for s in streams if s["codec_type"] == "subtitle"]

    a_shift = (len(a_idxs) > 0 and a_offset != 0.0)
    s_shift = (len(s_idxs) > 0 and s_offset != 0.0)

    # Entrada 0 = original. Una entrada extra por cada desfase distinto.
    # Si audio y subs llevan el MISMO desfase (caso tipico: los dos vienen de la
    # misma fuente alternativa), comparten entrada.
    cmd = [FFMPEG, "-y", "-hide_banner", "-i", inp]
    input_for = {}
    nxt = 1
    for off in ([a_offset] if a_shift else []) + ([s_offset] if s_shift else []):
        if off not in input_for:
            cmd += ["-itsoffset", str(off), "-i", inp]
            input_for[off] = nxt
            nxt += 1

    cmd += ["-map", "0:v", "-c:v", "copy"]

    # Audio: las pistas marcadas se toman de la entrada con -itsoffset; el resto,
    # de la entrada 0. Todo copy.
    for i, s in enumerate(audio_streams):
        if a_shift and s["index"] in a_idxs:
            cmd += ["-map", f"{input_for[a_offset]}:a:{i}"]
        else:
            cmd += ["-map", f"0:a:{i}"]

    # Subtitulos: mismo criterio. Aqui es donde mas se nota poder marcar varias:
    # un ripeo alternativo suele traer audio + varios subs, todos con el mismo
    # desfase, y antes habia que pasar el fichero una vez por pista.
    for i, s in enumerate(sub_streams):
        if s_shift and s["index"] in s_idxs:
            cmd += ["-map", f"{input_for[s_offset]}:s:{i}"]
        else:
            cmd += ["-map", f"0:s:{i}"]

    cmd += ["-c:a", "copy", "-c:s", "copy"]
    cmd += ["-map_metadata", "0", "-map_chapters", "0", out]

    return cmd

def sync_worker():
    while True:
        job = None
        with sync_lock:
            pending = [j for j in sync_jobs if j["status"] == "pending"]
            if pending:
                job = pending[0]

        if not job:
            time.sleep(1)
            continue

        # EL pipeline.lock, ANTES DE TOCAR NADA (20/08/2026).
        #
        # Esto FALTABA: un trabajo de Sync reescribe la pelicula entera con
        # ffmpeg -c copy, o sea decenas de GB leidos y escritos, y era el unico
        # camino del panel que tocaba ficheros sin pedir turno. El remux y el
        # subsfetch si lo cogen; este se colaba, y podia arrancar en mitad de un
        # encode: un escritor mas en el mismo disco (ver
        # disco-contencion-manda-sobre-velocidad) y, peor, un MKV abierto por dos
        # procesos a la vez.
        #
        # Mismo contrato que fetch_worker: si no hay turno, el trabajo se queda
        # en la cola -visible como 'waiting'- y se reintenta.
        if os.path.isfile(PIPELINE_PAUSED):
            job["status"] = "waiting"
            job["last_log"] = "pipeline en PAUSA global (mantenimiento); esperando..."
            time.sleep(10)
            job["status"] = "pending"
            continue
        if not _remux_take_lock():
            job["status"] = "waiting"
            job["last_log"] = "esperando a que termine el pipeline en curso..."
            time.sleep(10)
            job["status"] = "pending"
            continue

        with sync_lock:
            job["status"]  = "running"
            job["started"] = datetime.now().isoformat()
            job["log"]     = []

        def log(msg): job["log"].append(msg); job["last_log"] = msg

        try:
            cmd = sync_build_cmd(job)
            log("Command: " + " ".join(cmd))
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True,
                                    errors="replace", creationflags=_NO_WINDOW)
            with sync_lock: job["pid"] = proc.pid
            for line in proc.stdout:
                line = line.rstrip()
                if line: log(line)
            proc.wait()
            with sync_lock:
                if proc.returncode == 0:
                    job["status"] = "done"
                else:
                    job["status"] = "error"
                    job["error"]  = f"ffmpeg exited {proc.returncode}"
        except Exception as e:
            with sync_lock:
                job["status"] = "error"
                job["error"]  = str(e)
        finally:
            _remux_free_lock()

        with sync_lock:
            job["finished"] = datetime.now().isoformat()
            finished = [j for j in sync_jobs if j["status"] in ("done","error")]
            for old in finished[5:]: sync_jobs.remove(old)

def sync_ensure_worker():
    global sync_worker_thread
    if sync_worker_thread is None or not sync_worker_thread.is_alive():
        sync_worker_thread = threading.Thread(target=sync_worker, daemon=True)
        sync_worker_thread.start()

# El hilo se arranca PEREZOSAMENTE, desde /api/sync/add (igual que fetch_worker).
# Antes se lanzaba aqui, al importar el modulo, y eso tenia dos pegas: un hilo
# despertandose cada segundo para siempre aunque nunca se use la pestanya, y -mas
# serio desde que el worker mira PIPELINE_PAUSED y _remux_take_lock- una carrera
# con el propio import, porque esos dos se definen 700 lineas mas abajo.

@app.route("/api/sync/probe", methods=["POST"])
def sync_probe():
    data = request.get_json(silent=True) or {}
    fp   = (data.get("filepath") or "").strip()
    if not fp or not os.path.isfile(fp):
        return jsonify({"ok": False, "error": "File not found"})
    streams, err = sync_probe_streams(fp, con_error=True)
    if not streams:
        # Se dice lo que dijo ffprobe, en vez de un "no hay pistas" que muchas
        # veces es MENTIRA (ver sync_probe_streams). Con el mensaje delante, el
        # camino a seguir -mkvmerge -i para ver que pista molesta- es evidente.
        return jsonify({"ok": False, "streams": [],
                        "error": "No se pudieron leer las pistas de «%s».\n\n%s\n\n"
                                 "Ojo: ffprobe aborta el sondeo entero si UNA pista "
                                 "esta danyada, aunque el fichero se reproduzca bien. "
                                 "Comprueba con:  mkvmerge -i \"%s\""
                                 % (os.path.basename(fp), err, fp)})
    return jsonify({"ok": True, "streams": streams})

@app.route("/api/sync/add", methods=["POST"])
def sync_add():
    data         = request.get_json(silent=True) or {}
    filepath     = (data.get("filepath") or "").strip()
    audio_offset = float(data.get("audio_offset", 0.0))
    sub_offset   = float(data.get("sub_offset", 0.0))

    # Ahora se aceptan VARIAS pistas por grupo, todas con el mismo desfase.
    # Se mantiene compatibilidad con las claves antiguas en singular por si algo
    # las sigue enviando.
    def _as_list(plural, singular):
        v = data.get(plural)
        if v is None:
            one = data.get(singular)
            v = [one] if one is not None else []
        out = []
        for x in (v or []):
            try: out.append(int(x))
            except (TypeError, ValueError): pass
        return out

    audio_streams = _as_list("audio_streams", "audio_stream")
    sub_streams   = _as_list("sub_streams",   "sub_stream")

    if not filepath or not os.path.isfile(filepath):
        return jsonify({"ok": False, "error": "File not found"})
    if not audio_streams and not sub_streams:
        return jsonify({"ok": False, "error": "Select at least one stream to adjust"})
    # Hay algo que hacer solo si algun grupo tiene pistas Y un desfase distinto de 0
    a_ok = bool(audio_streams) and audio_offset != 0.0
    s_ok = bool(sub_streams)   and sub_offset   != 0.0
    if not a_ok and not s_ok:
        return jsonify({"ok": False, "error": "Offset is 0 — nothing to do"})

    noext  = os.path.splitext(os.path.basename(filepath))[0]
    output = os.path.join(DONE_DIR, f"{noext}.synced.mkv")

    job = {
        "id":            str(uuid.uuid4())[:8],
        "filepath":      filepath,
        "audio_streams": audio_streams,
        "audio_offset":  audio_offset,
        "sub_streams":   sub_streams,
        "sub_offset":    sub_offset,
        "output":        output,
        "status":        "pending",
        "added":         datetime.now().isoformat(),
        "log":           [],
    }
    with sync_lock: sync_jobs.append(job)
    sync_ensure_worker()
    return jsonify({"ok": True, "id": job["id"], "output": output})

@app.route("/api/sync/status")
def sync_status():
    with sync_lock:
        active = next((j for j in sync_jobs if j["status"] == "running"), None)
        return jsonify({
            "active": {
                "id":     active["id"],
                "file":   os.path.basename(active["filepath"]),
                "status": active["status"],
                "log":    active.get("log", [])[-40:],
            } if active else None,
            "jobs": [
                {"id": j["id"], "file": os.path.basename(j["filepath"]),
                 "status": j["status"], "error": j.get("error",""),
                 "output": j.get("output","")}
                for j in sync_jobs
            ]
        })

@app.route("/api/sync/cancel/<job_id>", methods=["POST"])
def sync_cancel(job_id):
    with sync_lock:
        job = next((j for j in sync_jobs if j["id"] == job_id), None)
        if not job: return jsonify({"ok": False})
        # 'waiting' cuenta como pendiente: no ha empezado nada (el ffmpeg se lanza
        # DESPUES de coger el lock), asi que sacarlo de la lista basta. Sin esta
        # rama, cancelar un trabajo que estuviera esperando turno no hacia nada y
        # el boton parecia roto.
        if job["status"] in ("pending", "waiting"):
            sync_jobs.remove(job); return jsonify({"ok": True})
        if job["status"] == "running" and job.get("pid"):
            try: _kill_pid(job["pid"]); job["status"] = "error"
            except: pass
            return jsonify({"ok": True})
    return jsonify({"ok": False})


# ══════════════════════════════════════════════════════════════════════════════
# TAB — AUDIO  (TrueHD -> DDP+Atmos / EAC3, sin re-encodear el video)
# ══════════════════════════════════════════════════════════════════════════════
# Pipeline dirigido por carpetas (watcher de audio, dee.exe directo). El panel
# refleja su estado leyendo %TEMP%\audio_status y las carpetas
# audio_queue/running/done de C:\Media; NO lanza el encode (lo hace audio-watch.ps1).
# (Aqui vivia un worker en-proceso -audio_worker + AUDIO_SCRIPT/audio_jobs- que
#  apuntaba al motor viejo audio-convert.ps1 y arrancaba un hilo que no hacia
#  nada: el pipeline real va por carpetas/watcher. Eliminado.)
AUD_STATUS_F = os.path.join(TMP,  "audio_status")
AUD_PID_F    = os.path.join(TMP,  "audio_pid")
AUD_QUEUE    = os.path.join(BASE, "audio_queue")
AUD_RUNNING  = os.path.join(BASE, "audio_running")
AUD_DONE     = os.path.join(BASE, "audio_done")
AUD_LOGDIR   = os.path.join(BASE, "audio_logs")

def audio_probe_streams(fp):
    """Pistas de audio con codec/profile/canales + flags truehd/atmos."""
    try:
        r = subprocess.run(
            [FFPROBE, "-v", "error", "-select_streams", "a",
             "-show_entries", "stream=index,codec_name,profile,channels:stream_tags=language,title",
             "-of", "json", fp],
            capture_output=True, text=True, timeout=25, creationflags=_NO_WINDOW)
        data = json.loads(r.stdout or "{}")
        out = []
        for s in data.get("streams", []):
            tags = s.get("tags", {})
            codec = s.get("codec_name", "") or ""
            prof  = s.get("profile", "") or ""
            out.append({
                "index":      s.get("index"),
                "codec_name": codec,
                "profile":    prof,
                "channels":   s.get("channels"),
                "language":   tags.get("language", ""),
                "title":      tags.get("title", ""),
                "truehd":     codec.lower() in ("truehd", "mlp"),
                "dts":        codec.lower() == "dts",
                "atmos":      "atmos" in prof.lower(),
            })
        return out
    except Exception:
        return []

def _read_out_time_secs(path):
    """Lee out_time del fichero -progress de ffmpeg y lo devuelve en segundos."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 4096))
            tail = f.read().decode("utf-8", errors="replace")
        val = ""
        for line in tail.split("\n"):
            if line.startswith("out_time="): val = line.split("=", 1)[1].strip()
        if val and ":" in val:
            p = val.split(":")
            return float(p[0]) * 3600 + float(p[1]) * 60 + float(p[2])
    except Exception:
        pass
    return 0.0


def _ffprog_ended(path):
    """True si el fichero -progress de ffmpeg termina en 'progress=end'.
    En '-c:v copy' el out_time NO llega de forma fiable a la duracion real (medido:
    una copia terminada quedo con out_time al ~53% de la duracion), asi que el %
    por out_time se congela por debajo del 100 aunque ffmpeg ya haya acabado. Esto
    permite distinguir 'copia acabada' de 'copia a medias'."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 512))
            tail = f.read().decode("utf-8", errors="replace")
        return "progress=end" in tail
    except Exception:
        return False


# Aqui vivia /api/audio/probe, que devolvia las pistas de audio de un fichero.
# ELIMINADA el 20/08/2026: la pestanya Audio ya no enseña la lista de pistas -se
# decide sola- y ningun sitio del panel llamaba a esta ruta. La funcion que hacia
# el trabajo, audio_probe_streams(), SIGUE VIVA: la usa /api/audio/add para
# comprobar que el fichero tiene algo que convertir.

@app.route("/api/audio/add", methods=["POST"])
def audio_add():
    # Encola en el watcher NUEVO: copia el fichero a C:\Media\audio_queue.
    # (El original no se toca; el watcher mueve la copia a running -> done.)
    data = request.get_json(silent=True) or {}
    fp   = (data.get("filepath") or "").strip()
    if not fp or not os.path.isfile(fp):
        return jsonify({"ok": False, "error": "File not found"})
    streams = audio_probe_streams(fp)
    # DTS tambien vale: audio_encode.ps1 lo convierte a DD+ 640k via deew/DEE,
    # igual que el pipeline de video. Antes esto solo aceptaba TrueHD y rechazaba
    # los ficheros con solo DTS, aunque el motor supiera convertirlos.
    if not any(s["truehd"] or s["dts"] for s in streams):
        return jsonify({"ok": False, "error": "El fichero no tiene pistas TrueHD ni DTS que convertir"})
    return jsonify(_encolar_async(fp, AUD_QUEUE, "audio"))

@app.route("/api/audio/to_encoder", methods=["POST"])
def audio_to_encoder():
    # Envia el fichero a la cola del Encoder de VIDEO (encode_queue): lo copia alli
    # y el watcher de video lo recoge (reencoda video + convierte audio). El
    # original no se toca. Util cuando abres un MKV en la pestana Audio y decides
    # que quieres reencodear el video tambien, no solo tocar el audio.
    data = request.get_json(silent=True) or {}
    fp   = (data.get("filepath") or "").strip()
    if not fp or not os.path.isfile(fp):
        return jsonify({"ok": False, "error": "File not found"})
    return jsonify(_encolar_async(fp, ENC_QUEUE, "encoder"))

@app.route("/api/audio/status")
def audio_status():
    # Estado EN VIVO del watcher: audio_encode.ps1 escribe %TEMP%\audio_status
    # (status/file/duration/stage/pct). Las colas salen de las carpetas.
    st = _read_kv(AUD_STATUS_F, {"status": "idle", "file": "", "stage": "", "pct": 0})
    try: pct = float(st.get("pct", 0) or 0)
    except: pct = 0.0

    active = None
    if st.get("status") == "encoding":
        active = {"id": "live", "file": st.get("file", ""), "mode": "auto",
                  "pct": pct, "stage": st.get("stage", ""),
                  "log": _tail_log(AUD_LOGDIR)}

    jobs = [{"id": q, "file": q, "status": "pending", "mode": "auto"}
            for q in _cola_pendientes(AUD_QUEUE)]
    jobs += [{"id": os.path.basename(p), "file": os.path.basename(p),
              "status": "done", "output": p} for p in _cola_terminados(AUD_DONE)]

    # Copias en curso hacia esta cola y hacia la del encoder (el boton "a cola de
    # video" vive en esta misma pestanya).
    return jsonify({"active": active, "jobs": jobs,
                    "copying": _copias_de("audio", "encoder")})

@app.route("/api/audio/cancel/<job_id>", methods=["POST"])
def audio_cancel(job_id):
    # "live" -> matar el encode de audio en curso (audio_pid + arbol: dee/truehdd/ffmpeg)
    if job_id == "live":
        try:
            with open(AUD_PID_F) as f: pid = int(f.read().strip())
            _kill_pid(pid)
            return jsonify({"ok": True, "killed": pid})
        except Exception as e:
            return jsonify({"ok": False, "error": str(e)})
    # si no, quitar el fichero de la cola por nombre
    safe = os.path.basename(job_id)
    tgt  = os.path.join(AUD_QUEUE, safe)
    try:
        if os.path.isfile(tgt): os.remove(tgt); return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})
    return jsonify({"ok": False, "error": "not found"})


# ══════════════════════════════════════════════════════════════════════════════
# TAB — SUBS  (solo subtitulos: encode.ps1 -SubsOnly; video y audio en copy)
# ══════════════════════════════════════════════════════════════════════════════
# Pipeline dirigido por carpetas, igual que el de AUDIO: el panel NO lanza el
# encode, solo refleja lo que hace subs-watch.ps1. El estado en vivo sale de
# %TEMP%\subs_status (lo escribe encode.ps1 con StatePfx='subs') y las colas de
# las carpetas subs_queue/running/done de C:\Media. El progreso, de subs_ffprog.
# Los .log van a encode_logs (compartido con video); como el pipeline.lock
# serializa TODO, cuando subs esta 'encoding' el log mas reciente es el suyo.
SUBS_STATUS_F = os.path.join(TMP,  "subs_status")
SUBS_PID_F    = os.path.join(TMP,  "subs_pid")
SUBS_PROG_F   = os.path.join(TMP,  "subs_ffprog")
SUB_QUEUE     = os.path.join(BASE, "subs_queue")
SUB_RUNNING   = os.path.join(BASE, "subs_running")
SUB_DONE      = os.path.join(BASE, "subs_done")
os.makedirs(SUB_QUEUE, exist_ok=True)
os.makedirs(SUB_DONE,  exist_ok=True)

@app.route("/api/subs/add", methods=["POST"])
def subs_add():
    # Copia el fichero a C:\Media\subs_queue (el original no se toca; el watcher
    # lo mueve a running -> done). Tambien puedes soltar MKVs directamente en la
    # carpeta subs_queue sin pasar por aqui.
    data = request.get_json(silent=True) or {}
    fp   = (data.get("filepath") or "").strip()
    if not fp or not os.path.isfile(fp):
        return jsonify({"ok": False, "error": "File not found"})
    return jsonify(_encolar_async(fp, SUB_QUEUE, "subs"))

@app.route("/api/subs/status")
def subs_status():
    # Estado EN VIVO: encode.ps1 -SubsOnly escribe %TEMP%\subs_status
    # (status/file/duration/stage/pct) y -progress en subs_ffprog.
    st = _read_kv(SUBS_STATUS_F, {"status": "idle", "file": "", "duration": 0})
    try: dur = float(st.get("duration", 0) or 0)
    except: dur = 0.0

    # Fase de COPIA: % por el out_time de ffmpeg. Ojo: en '-c:v copy' out_time no
    # llega de forma fiable al 100% (ver _ffprog_ended), asi que este % puede
    # quedarse corto; se corrige abajo cuando la copia ha terminado.
    pct = 0.0
    if dur > 0:
        secs = _read_out_time_secs(SUBS_PROG_F)
        if secs > 0:
            pct = min(99.9, round(secs / dur * 100, 1))

    # Fase de POST-PROCESO (reconstruccion del contenedor + mkvpropedit): dura
    # MUCHO mas que la copia en un 4K -medido ~30 min- y ffmpeg ya no reporta nada.
    # encode.ps1 -SubsOnly escribe stage=rebuild|finalizing con su pct en
    # subs_status; se respeta por encima del out_time. Y si el ffprog trae
    # 'progress=end' la copia acabo aunque el out_time se quedara corto: no dejar el
    # % por debajo del arranque del post-proceso. Sin esto el panel se congelaba en
    # el ultimo out_time y parecia colgado, lo que provoco cancelar trabajos que ya
    # estaban terminados.
    stage = st.get("stage", "")
    try: stage_pct = float(st.get("pct", 0) or 0)
    except: stage_pct = 0.0
    if stage in ("rebuild", "finalizing"):
        pct = max(pct, stage_pct)
    elif _ffprog_ended(SUBS_PROG_F):
        pct = max(pct, 99.0)

    active = None
    if st.get("status") == "encoding":
        active = {"id": "live", "file": st.get("file", ""), "pct": pct,
                  "stage": stage, "log": _tail_log(LOG_DIR)}

    jobs = [{"id": q, "file": q, "status": "pending"}
            for q in _cola_pendientes(SUB_QUEUE)]
    jobs += [{"id": os.path.basename(p), "file": os.path.basename(p),
              "status": "done", "output": p} for p in _cola_terminados(SUB_DONE)]

    return jsonify({"active": active, "jobs": jobs,
                    "copying": _copias_de("subs")})

@app.route("/api/subs/cancel/<job_id>", methods=["POST"])
def subs_cancel(job_id):
    # "live" -> matar el trabajo en curso (subs_pid + arbol: ffmpeg/dotnet OCR)
    if job_id == "live":
        try:
            with open(SUBS_PID_F) as f: pid = int(f.read().strip())
            _kill_pid(pid)
            return jsonify({"ok": True, "killed": pid})
        except Exception as e:
            return jsonify({"ok": False, "error": str(e)})
    # si no, quitar el fichero de la cola por nombre
    safe = os.path.basename(job_id)
    tgt  = os.path.join(SUB_QUEUE, safe)
    try:
        if os.path.isfile(tgt): os.remove(tgt); return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})
    return jsonify({"ok": False, "error": "not found"})


# ── Buscar subtitulos A PETICION (subsfetch) ─────────────────────────────────
# Hasta ahora subsfetch solo se disparaba SOLO, desde encode.ps1, y unicamente
# cuando la pelicula no traia subtitulos de texto o solo traia VobSub. Eso cubre
# el caso automatico, pero deja fuera el mas obvio: "quiero subtitulos para ESTA
# pelicula, ahora". Esto lo aniade sin duplicar nada — es el mismo subsfetch.py
# con su interfaz de linea de comandos, no una segunda implementacion.
#
# COGE EL pipeline.lock: subsfetch no solo descarga, tambien REMUXEA el fichero
# con mkvmerge. Dejarlo correr en paralelo a un encode seria meter un escritor
# mas en el mismo disco y, peor, tocar un MKV mientras otro proceso trabaja.
# Se espera igual que hace el remux del panel.
SUBSFETCH_PY = os.path.join(SCRIPT_DIR, "webpanel", "subsfetch.py")
if not os.path.isfile(SUBSFETCH_PY):
    SUBSFETCH_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "subsfetch.py")
PYEXE = sys.executable or "python"

fetch_jobs = []
fetch_lock = threading.Lock()
fetch_worker_started = False


def fetch_worker():
    while True:
        job = None
        with fetch_lock:
            pend = [j for j in fetch_jobs if j["status"] == "pending"]
            if pend:
                job = pend[0]

        if not job:
            time.sleep(1)
            continue

        def log(m):
            job["log"].append(m)
            job["last_log"] = m

        # El lock, ANTES de tocar nada. Si no se consigue, se espera: el trabajo
        # sigue en 'pending' y se reintenta. Mismo contrato que el remux.
        if os.path.isfile(PIPELINE_PAUSED):
            job["status"] = "waiting"
            job["last_log"] = "pipeline en PAUSA global; esperando..."
            time.sleep(10)
            job["status"] = "pending"
            continue
        if not _remux_take_lock():
            job["status"] = "waiting"
            job["last_log"] = "esperando a que termine el pipeline en curso..."
            time.sleep(10)
            job["status"] = "pending"
            continue

        with fetch_lock:
            job["status"]  = "running"
            job["started"] = datetime.now().isoformat()
        try:
            cmd = [PYEXE, SUBSFETCH_PY, job["path"], "--mux",
                   "--idiomas", job.get("idiomas") or "es,en"]
            if job.get("forzados"):
                cmd.append("--forzados")
            if job.get("solo_local"):
                cmd.append("--solo-local")
            log("Comando: " + " ".join(cmd))
            # FORCE_COLOR/PYTHONUNBUFFERED: sin esto Python bufferiza su salida al
            # no ser una consola y el log llega de golpe al final, que es como no
            # tenerlo. Mismo problema que ya se arreglo con deew.
            env = dict(os.environ, PYTHONUNBUFFERED="1", PYTHONIOENCODING="utf-8")
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, encoding="utf-8", errors="replace",
                                    env=env, creationflags=_NO_WINDOW)
            with fetch_lock:
                job["pid"] = proc.pid
            for line in proc.stdout:
                line = line.rstrip()
                if line:
                    log(line)
            proc.wait()
            with fetch_lock:
                # subsfetch devuelve 0 = todo lo pedido, 2 = algo pero no todo.
                # Un 2 NO es un fallo: es informacion, y decirlo "error" haria
                # que el usuario buscara un problema que no existe.
                if proc.returncode == 0:
                    job["status"] = "done"
                elif proc.returncode == 2:
                    job["status"] = "warn"
                    job["error"]  = "se encontraron algunos subtitulos, pero no todos los pedidos"
                elif proc.returncode == 1 and any(
                        "no se consiguio ningun subtitulo" in l for l in job["log"]):
                    # EL 1 DE subsfetch MEZCLA DOS COSAS: "no encontre nada" y
                    # "fallo". Su propio docstring lo dice ("1 si no consiguio
                    # nada o hubo error"), asi que el codigo de salida no basta
                    # para distinguirlas. Se mira la linea de RESULTADO que el
                    # script imprime al acabar bien sin hallazgos.
                    # Importa: pintar de rojo "no hay subtitulos para esta
                    # pelicula" manda al usuario a buscar una averia que no
                    # existe. No encontrar nada es una respuesta, no un fallo.
                    job["status"] = "empty"
                    job["error"]  = ""
                else:
                    job["status"] = "error"
                    job["error"]  = "subsfetch salio con codigo %d" % proc.returncode
        except Exception as e:
            with fetch_lock:
                job["status"] = "error"
                job["error"]  = str(e)
        finally:
            _remux_free_lock()

        with fetch_lock:
            job["finished"] = datetime.now().isoformat()
            hechos = [j for j in fetch_jobs if j["status"] in ("done", "error", "warn", "empty")]
            for viejo in hechos[5:]:
                fetch_jobs.remove(viejo)


def fetch_ensure_worker():
    global fetch_worker_started
    with fetch_lock:
        if fetch_worker_started:
            return
        fetch_worker_started = True
    threading.Thread(target=fetch_worker, daemon=True).start()


@app.route("/api/subs/fetch", methods=["POST"])
def subs_fetch():
    """Busca subtitulos para UN fichero, a peticion del usuario."""
    d  = request.get_json(silent=True) or {}
    fp = (d.get("filepath") or "").strip()
    if not fp or not os.path.isfile(fp):
        return jsonify({"ok": False, "error": "No encuentro el fichero"})
    if not os.path.isfile(SUBSFETCH_PY):
        return jsonify({"ok": False, "error": "No encuentro subsfetch.py"})
    job = {
        "id": uuid.uuid4().hex, "path": fp, "name": os.path.basename(fp),
        "idiomas": (d.get("idiomas") or "es,en").strip(),
        "forzados": bool(d.get("forzados", True)),
        "solo_local": bool(d.get("solo_local")),
        "status": "pending", "log": [], "last_log": "en cola", "error": "",
        "added": datetime.now().isoformat(),
    }
    with fetch_lock:
        fetch_jobs.append(job)
    fetch_ensure_worker()
    return jsonify({"ok": True, "id": job["id"]})


@app.route("/api/subs/fetch/status")
def subs_fetch_status():
    with fetch_lock:
        return jsonify({"jobs": [
            {k: v for k, v in j.items() if k != "log"} | {"log_n": len(j["log"])}
            for j in fetch_jobs
        ]})


@app.route("/api/subs/fetch/log/<job_id>")
def subs_fetch_log(job_id):
    # TEXTO PLANO, no JSON: es lo que espera openLogModal() del panel, que hace
    # r.text() y parte por lineas. Devolver JSON aqui pintaria el objeto crudo.
    with fetch_lock:
        for j in fetch_jobs:
            if j["id"] == job_id:
                cuerpo = chr(10).join(j["log"]) or "(sin salida todavia)"
                return Response(cuerpo, mimetype="text/plain; charset=utf-8")
    return Response("no existe ese trabajo", mimetype="text/plain; charset=utf-8", status=404)


# ══════════════════════════════════════════════════════════════════════════════
# TAB 3 — YT-DLP
# ══════════════════════════════════════════════════════════════════════════════
# Por ruta ABSOLUTA, como ffmpeg/ffprobe/taskkill: la regla del proyecto es no
# depender del PATH, que ya dejo el OCR roto semanas cuando dotnet desaparecio de
# el. Era el ultimo binario del panel que se invocaba por nombre suelto; si el
# PATH del servicio no lo tiene, la descarga fallaba con un WinError 2 opaco.
YTDLP = r"C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\yt-dlp.exe"
if not os.path.isfile(YTDLP): YTDLP = "yt-dlp"

YTDLP_DIR      = os.path.join(os.path.expanduser("~"), "Videos", "YT_DLP")
YTDLP_HIST_F   = os.path.join(LOG_DIR, "ytdlp_history.jsonl")
os.makedirs(YTDLP_DIR, exist_ok=True)

ytdlp_queue   = []
ytdlp_history = []
ytdlp_lock    = threading.Lock()
ytdlp_worker_thread = None

QUALITY_PROFILES = {
    "auto":  "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best",
    "4k":    "bestvideo[height<=2160][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=2160]+bestaudio/best",
    "1080p": "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/best",
    "720p":  "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best",
    "480p":  "bestvideo[height<=480][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=480]+bestaudio/best",
}
PROG_RE = re.compile(r'\[download\]\s+([\d.]+)%\s+of\s+([\S]+)\s+at\s+([\S]+)\s+ETA\s+([\S]+)')
DEST_RE = re.compile(r'\[download\] Destination: (.+)')
MERGE_RE = re.compile(r'\[Merger\]')

def ytdlp_load_history():
    global ytdlp_history
    try:
        with open(YTDLP_HIST_F, encoding="utf-8", errors="replace") as f:
            todo = [json.loads(l) for l in f if l.strip()]
        # DOS cosas, y la segunda era un fallo de verdad:
        #
        # 1. El jsonl crece sin fin y de el solo se enseñan 20. Antes se cargaba
        #    ENTERO en memoria al arrancar y solo se podaba a 50 tras la
        #    siguiente descarga.
        # 2. EL ORDEN ESTABA DEL REVES. El fichero se escribe en orden
        #    cronologico (append), pero las entradas nuevas se meten con
        #    insert(0), o sea que la lista viva va de mas nueva a mas vieja. Al
        #    cargarla tal cual quedaba al reves, y como el panel enseña
        #    history[:20], DESPUES DE CADA REINICIO el historial mostraba las 20
        #    descargas MAS ANTIGUAS -las de hace meses- hasta que se hicieran 20
        #    nuevas. Se invierte al cargar para que coincida con el criterio del
        #    insert(0).
        ytdlp_history = todo[-50:][::-1]
    except Exception:
        ytdlp_history = []

def ytdlp_save_history(entry):
    with open(YTDLP_HIST_F, "a") as f: f.write(json.dumps(entry) + "\n")

ytdlp_load_history()

def ytdlp_parse_progress(line, job):
    m = PROG_RE.search(line)
    if m:
        job["pct"] = float(m.group(1)); job["size"] = m.group(2)
        job["speed"] = m.group(3); job["eta"] = m.group(4); return
    m = DEST_RE.search(line)
    if m: job["dest"] = m.group(1).strip(); return
    if MERGE_RE.search(line): job["merging"] = True

def ytdlp_worker():
    while True:
        job = None
        with ytdlp_lock:
            pending = [j for j in ytdlp_queue if j["status"] == "pending"]
            if pending:
                job = pending[0]
                job.update({"status":"downloading","started":datetime.now().isoformat(),
                             "pct":0,"speed":"","eta":"","size":"","dest":"","merging":False})
        if not job: time.sleep(1); continue

        fmt = QUALITY_PROFILES.get(job.get("quality","auto"), QUALITY_PROFILES["auto"])
        cmd = [YTDLP,"--newline","--no-playlist","--merge-output-format","mp4",
               "--embed-metadata","--retries","10","--fragment-retries","10",
               "--no-keep-fragments","--abort-on-unavailable-fragments",
               "-f", fmt,
               "-o", os.path.join(YTDLP_DIR, "%(title)s (%(upload_date>%Y)s) %(height)sp.%(ext)s"),
               job["url"]]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, bufsize=1, errors="replace",
                                    creationflags=_NO_WINDOW)
            with ytdlp_lock: job["pid"] = proc.pid
            for line in proc.stdout:
                line = line.rstrip()
                with ytdlp_lock:
                    ytdlp_parse_progress(line, job)
                    job.setdefault("log", []).append(line)
            proc.wait()
            with ytdlp_lock:
                job["status"]   = "done" if proc.returncode == 0 else "error"
                job["pct"]      = 100 if proc.returncode == 0 else job.get("pct", 0)
                job["finished"] = datetime.now().isoformat()
                log_fn = f"ytdlp_{job['id']}.log"
                try:
                    # ESCRITURA en utf-8 (01/09/2026). Sin esto se escribia en
                    # cp1252, y un titulo de YouTube con un caracter fuera de
                    # esa tabla -cirilico, japones, una raya larga- lanzaba
                    # UnicodeEncodeError. El except de abajo se lo tragaba y el
                    # log NO se guardaba, justo el de los videos con el titulo
                    # mas raro, que son los que mas ganas dan de mirar el log.
                    with open(os.path.join(LOG_DIR, log_fn), "w",
                              encoding="utf-8", errors="replace") as lf:
                        lf.write("\n".join(job.get("log", [])))
                except Exception as e:
                    print("[ytdlp] no se pudo guardar el log: %s" % e, flush=True)
                    log_fn = ""
                entry = {"id":job["id"],"url":job["url"],"title":job.get("title",job["url"]),
                         "quality":job.get("quality","auto"),"status":job["status"],
                         "dest":job.get("dest",""),"started":job.get("started",""),
                         "finished":job["finished"],"log_file":log_fn}
                ytdlp_history.insert(0, entry)
                if len(ytdlp_history) > 50: ytdlp_history.pop()
                ytdlp_save_history(entry)
        except Exception as e:
            with ytdlp_lock:
                job.update({"status":"error","error":str(e),"finished":datetime.now().isoformat()})
        with ytdlp_lock:
            finished = [j for j in ytdlp_queue if j["status"] in ("done","error")]
            for old in finished[5:]: ytdlp_queue.remove(old)

def ytdlp_ensure_worker():
    global ytdlp_worker_thread
    if ytdlp_worker_thread is None or not ytdlp_worker_thread.is_alive():
        ytdlp_worker_thread = threading.Thread(target=ytdlp_worker, daemon=True)
        ytdlp_worker_thread.start()

ytdlp_ensure_worker()

def ytdlp_build_payload():
    with ytdlp_lock:
        active = next((j for j in ytdlp_queue if j["status"] == "downloading"), None)
        return {
            "active": {"id":active["id"],"url":active["url"],"title":active.get("title",active["url"]),
                       "pct":active.get("pct",0),"speed":active.get("speed",""),"eta":active.get("eta",""),
                       "size":active.get("size",""),"dest":active.get("dest",""),
                       "merging":active.get("merging",False),"quality":active.get("quality","auto"),
                       "log":active.get("log",[])[-50:]} if active else None,
            "queue":  [{"id":j["id"],"url":j["url"],"title":j.get("title",j["url"]),
                        "status":j["status"],"quality":j.get("quality","auto"),
                        "pct":j.get("pct",0),"error":j.get("error",""),
                        "log":j.get("log",[])[-50:]}
                       for j in ytdlp_queue if j["status"] != "downloading"],
            "history":[{**h,"log_file":h.get("log_file","")} for h in ytdlp_history[:20]],
        }

@app.route("/api/ytdlp/add", methods=["POST"])
def ytdlp_add():
    data = request.get_json(silent=True) or {}
    url  = (data.get("url") or "").strip()
    quality = data.get("quality","auto"); title = data.get("title","")
    if not url: return jsonify({"ok":False,"error":"No URL"})
    if quality not in QUALITY_PROFILES: quality = "auto"
    job = {"id":str(uuid.uuid4())[:8],"url":url,"title":title or url,
           "quality":quality,"status":"pending","added":datetime.now().isoformat()}
    with ytdlp_lock: ytdlp_queue.append(job)
    ytdlp_ensure_worker()
    return jsonify({"ok":True,"id":job["id"]})

@app.route("/api/ytdlp/fetch_title", methods=["POST"])
def ytdlp_fetch_title():
    data = request.get_json(silent=True) or {}
    url  = (data.get("url") or "").strip()
    if not url: return jsonify({"ok":False,"title":""})
    try:
        r = subprocess.run([YTDLP,"--no-playlist","--print","%(title)s",url],
                           capture_output=True, text=True, timeout=15,
                           creationflags=_NO_WINDOW)
        return jsonify({"ok":True,"title":r.stdout.strip().split("\n")[0]})
    except: return jsonify({"ok":False,"title":""})

@app.route("/api/ytdlp/cancel/<job_id>", methods=["POST"])
def ytdlp_cancel(job_id):
    with ytdlp_lock:
        job = next((j for j in ytdlp_queue if j["id"] == job_id), None)
        if not job: return jsonify({"ok":False,"error":"Not found"})
        if job["status"] == "pending": ytdlp_queue.remove(job); return jsonify({"ok":True})
        if job["status"] == "downloading" and job.get("pid"):
            try: _kill_pid(job["pid"]); job["status"]="error"; job["error"]="Cancelled"
            except: pass
            return jsonify({"ok":True})
    return jsonify({"ok":False})

@app.route("/api/ytdlp/clear_history", methods=["POST"])
def ytdlp_clear_history():
    global ytdlp_history
    with ytdlp_lock: ytdlp_history = []
    try: open(YTDLP_HIST_F,"w").close()
    except: pass
    return jsonify({"ok":True})

@app.route("/api/ytdlp/log/<job_id>")
def ytdlp_log(job_id):
    # basename(), como en /api/enc/log. El saneado que habia aqui -quitar "/" y
    # ".."- dejaba pasar la BARRA INVERTIDA, que en Windows separa igual:
    # comprobado, "..\..\..\Windows\Temp\x" acababa en
    # C:\Media\encode_logs\ytdlp_\Windows\Temp\x.log, o sea fuera de la carpeta.
    # No se podia subir (los ".." si se quitaban) ni leer nada que no se llamara
    # ytdlp_*.log, asi que el alcance era pequenyo; pero un saneado a base de
    # quitar subcadenas siempre se deja algo, y basename() no.
    safe = os.path.basename(job_id)
    log_path = os.path.join(LOG_DIR, f"ytdlp_{safe}.log")
    if os.path.isfile(log_path):
        try:
            # Igual que el log del encoder: se declara utf-8, se lee utf-8.
            # Y con errors="replace": aqui NO habia, asi que un titulo con un
            # byte que cp1252 no define tiraba la peticion entera con un 500.
            with open(log_path, encoding="utf-8", errors="replace") as f:
                return f.read(), 200, {"Content-Type": "text/plain;charset=utf-8"}
        except Exception as e: return str(e), 500
    with ytdlp_lock:
        job = next((j for j in ytdlp_queue if j["id"] == safe), None)
        if job and job.get("log"):
            return "\n".join(job["log"]), 200, {"Content-Type":"text/plain;charset=utf-8"}
    return "Log not found", 404


# ══════════════════════════════════════════════════════════════════════════════
# UNIFIED SSE  — one stream, all tabs' data multiplexed
# ══════════════════════════════════════════════════════════════════════════════
@app.route("/stream")
def stream():
    def generate():
        while True:
            # 'except Exception', NO un except pelado: el pelado se traga tambien
            # GeneratorExit -que es lo que Python lanza cuando el navegador cierra
            # la conexion- e intentar hacer yield despues de eso revienta con un
            # RuntimeError en el log en vez de cerrar limpiamente.
            # (Aqui tambien viajaba un campo "sync": null fijo, resto de cuando la
            #  pestanya Sync iba por SSE. Sondea por /api/sync/status desde hace
            #  tiempo; el campo no lo leia nadie.)
            try:
                payload = {"enc": enc_build_payload(), "ytdlp": ytdlp_build_payload()}
            except Exception as e:
                # Decir que ha fallado, en vez de mandar un {} que el panel
                # interpreta como "no hay nada" y deja la pantalla en blanco sin
                # explicacion.
                payload = {"error": str(e)}
            yield f"data: {json.dumps(payload)}\n\n"
            time.sleep(1)
    return Response(generate(), mimetype="text/event-stream",
                    headers={"Cache-Control":"no-cache","X-Accel-Buffering":"no"})


# ══════════════════════════════════════════════════════════════════════════════
# REMUX  -  montar una pelicula a partir de varias fuentes
# ══════════════════════════════════════════════════════════════════════════════
# Coge el video de un fichero y las pistas de audio/subtitulos de ese y de otros,
# mide el desfase de cada fuente por correlacion cruzada, avisa de que hacer y
# monta el resultado. NUNCA recodifica video. El audio solo se toca si se pide
# explicitamente (TrueHD Atmos -> DD+ Atmos via DEE, que conserva los objetos).
#
# La medicion vive en remuxlib.py, aparte, para poder ejecutarla y verificarla
# sin levantar el panel.
import remuxlib

REMUX_LOCK = os.path.join(TMP, "pipeline.lock")
# Pausa GLOBAL de mantenimiento. El MISMO fichero que miran los tres watchers en
# Test-PipelinePaused (pipeline-lock.ps1). No confundir con PAUSE_F
# ('encode_paused'), que es la pausa SOLO del video y la crea el boton STOP.
PIPELINE_PAUSED = os.path.join(TMP, "pipeline_paused")
ATMOS_LIB  = os.path.join(SCRIPT_DIR, "atmos-lib.ps1")
# Convert-SubToSrt: la MISMA que usa encode.ps1 para el OCR de los PGS. Se llama
# a la libreria, no se reimplementa el OCR aqui: dos copias del mismo codigo ya
# divergieron dos veces en este proyecto (ver la cabecera de subs-lib.ps1).
SUBS_LIB   = os.path.join(SCRIPT_DIR, "subs-lib.ps1")
PWSH       = r"C:\Program Files\PowerShell\7\pwsh.exe"
if not os.path.isfile(PWSH): PWSH = "pwsh"
MKVMERGE   = r"C:\Program Files\MKVToolNix\mkvmerge.exe"
# UNA sola definicion para el lado Python: la de remuxlib, que a su vez usa el
# mismo valor y la misma variable de entorno que mediabox-paths.ps1 en el lado
# PowerShell. Antes cada modulo tenia la suya y podian discrepar DENTRO DEL MISMO
# PROCESO: poner MEDIABOX_BIGTMP movia los temporales del remux pero no los de la
# medicion de sync, que seguian cayendo en G:.
BIGTMP     = remuxlib.BIGTMP

remux_jobs   = {}
remux_queue  = []
remux_lock_t = threading.Lock()
remux_worker_started = False


def _remux_pipeline_busy():
    """True si OTRO pipeline (encode o audio) tiene el lock con un proceso vivo.

    Mismo protocolo que audio-watch.ps1: el fichero contiene el PID. Si el PID
    ya no existe, el lock es basura de un proceso muerto y se ignora.
    """
    try:
        if not os.path.isfile(REMUX_LOCK):
            return False
        # 'with' y no open(...).read() suelto (01/09/2026): en CPython el fichero
        # temporal se cierra al soltar la referencia, pero eso es un detalle de
        # implementacion y esto es un LOCK. En Windows un handle todavia abierto
        # impide borrar el fichero, que es exactamente como se queda un lock
        # huerfano bloqueando la cola.
        with open(REMUX_LOCK) as _fh:
            pid = (_fh.read() or "").strip()
        if not pid.isdigit():
            return False
        # Antes esto lanzaba 'tasklist' (141 ms y un proceso nuevo) en cada
        # sondeo del panel. Ver _pid_vivo.
        return _pid_vivo(int(pid))
    except Exception:
        return False


# --- Plan de energia, el MISMO contrato que pipeline-lock.ps1 --------------
# Los watchers suben el plan a 'Alto rendimiento' al coger el lock y lo bajan al
# soltarlo. MEDIDO el 16/08/2026 sobre el mismo clip: Equilibrado no baja el
# techo, estrangula A RATOS (media 49,3 s con 6,3 s de dispersion, frente a
# 46,0 s con 0,2 s). No se deja fijo porque este equipo esta encendido todo el
# dia y casi siempre ocioso.
#
# El remux del panel cogia el lock por SU lado (O_EXCL en Python) y no tocaba el
# plan: el mismo trabajo pagaba distinta tarifa segun por que puerta entrara. Da
# igual en un remux de copia pura -son minutos de I/O-, pero un remux que
# convierte Atmos son HORAS de DEE a un nucleo, y eso si corria estrangulado.
#
# Se comparten el fichero y el GUID a proposito: si el pipeline muere a lo bruto,
# quien restaure -este lado o el otro- encuentra el plan original. Y no se
# sobrescribe 'powerplan_prev' si ya existe, por lo mismo.
POWERPLAN_PREV = os.path.join(TMP, "powerplan_prev")
POWERPLAN_HIGH = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"   # Alto rendimiento
_GUID_RE = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
# (_NO_WINDOW vivia aqui. Movido a la cabecera del modulo: la razon por la que se
#  puso para powercfg -que no se abra una consola en la cara del usuario- vale
#  igual para ffprobe, taskkill, mkvmerge, pwsh y yt-dlp, y ahora la usan todos.)


def _powercfg(*args):
    return subprocess.run(["powercfg"] + list(args), capture_output=True,
                          text=True, timeout=15, creationflags=_NO_WINDOW)


def _powerplan_boost():
    """Sube a Alto rendimiento y recuerda el plan anterior. Best-effort: si
    powercfg falla o no existe el plan, se trabaja igual."""
    try:
        actual = _GUID_RE.search(_powercfg("/getactivescheme").stdout or "")
        if not actual:
            return
        actual = actual.group(0)
        if actual.lower() == POWERPLAN_HIGH:
            return                                  # ya estaba
        if not os.path.isfile(POWERPLAN_PREV):
            with open(POWERPLAN_PREV, "w", encoding="utf-8") as fh:
                fh.write(actual)
        _powercfg("/setactive", POWERPLAN_HIGH)
    except Exception:
        pass


def _powerplan_restore():
    try:
        if not os.path.isfile(POWERPLAN_PREV):
            return
        prev = (open(POWERPLAN_PREV, encoding="utf-8").read() or "").strip()
        if _GUID_RE.fullmatch(prev):
            _powercfg("/setactive", prev)
        os.remove(POWERPLAN_PREV)
    except Exception:
        pass


def _remux_take_lock():
    """Coge el pipeline.lock de forma ATOMICA. True solo si se ha conseguido.

    Antes hacia open(REMUX_LOCK, "w"), que crea o PISA el fichero sin mirar: si
    otro pipeline lo tenia cogido, este se lo llevaba por delante y los dos
    trabajaban a la vez. Es la misma carrera que tenian los watchers de
    PowerShell y que el 04/08/2026 hizo que la limpieza de un trabajo de video
    borrase el DAMF de un trabajo de audio en vuelo (ver pipeline-lock.ps1).

    O_CREAT|O_EXCL es el equivalente en Python del FileMode::CreateNew de alla:
    falla si el fichero existe, y la comprobacion y la creacion son una sola
    operacion del sistema de ficheros.
    """
    for _ in range(2):
        try:
            fd = os.open(REMUX_LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            try:
                os.write(fd, str(os.getpid()).encode())
            finally:
                os.close(fd)
            _powerplan_boost()     # ya es nuestro, igual que Enter-PipelineLock
            return True
        except FileExistsError:
            # Existe: ¿de un proceso vivo o huerfano? _remux_pipeline_busy ya
            # sabe distinguirlo. Si esta vivo, no es nuestro y se acabo.
            if _remux_pipeline_busy():
                return False
            # Huerfano: borrar y reintentar UNA vez. Si en ese hueco entra otro,
            # el O_EXCL volvera a fallar y devolveremos False, que es correcto.
            try:
                os.remove(REMUX_LOCK)
            except Exception:
                return False
        except Exception:
            return False
    return False


def _remux_free_lock():
    mio = False
    try:
        if os.path.isfile(REMUX_LOCK):
            # AQUI IMPORTA DE VERDAD: se lee el lock y en la linea siguiente se
            # BORRA. Con el handle sin cerrar, en Windows ese remove falla y el
            # lock se queda puesto para siempre -la cola de remux no vuelve a
            # arrancar y nada lo explica-.
            with open(REMUX_LOCK) as _fh:
                pid = (_fh.read() or "").strip()
            if pid == str(os.getpid()):
                os.remove(REMUX_LOCK)
                mio = True
    except Exception:
        pass
    # DESPUES de soltar el lock, igual que en Exit-PipelineLock: si powercfg se
    # atascara, que no retenga el lock por ello.
    if mio:
        _powerplan_restore()


def _stream_ordinal(path, abs_index, kind):
    """Convierte indice ABSOLUTO de stream en ordinal DENTRO de su tipo (el N de
    a:N / s:N). Sin esto se convierte la pista equivocada: en un fichero con
    video + 3 audios, el subtitulo #5 absoluto es el s:1, no el s:5."""
    n = 0
    for t in remuxlib.probe(path)["tracks"]:
        if t["type"] != kind:
            continue
        if t["index"] == abs_index:
            return n
        n += 1
    return None


def _audio_ordinal(path, abs_index):
    return _stream_ordinal(path, abs_index, "audio")


def _ps_q(s):
    """Comilla simple de PowerShell: dentro de '...' solo hay que doblar la '.
    Sin esto, una pelicula con apostrofo en el nombre (Ocean's Eleven) rompe el
    -Command y pwsh interpreta el resto de la ruta como codigo."""
    return str(s).replace("'", "''")


def _sync_args(tid, t):
    """Argumentos --sync de una pista: desfase fijo y, SOLO en subtitulos, tambien
    el factor de deriva (estiramiento lineal de los tiempos).

    mkvmerge aplica: nuevo = desfase + viejo * factor (comprobado: --sync 0:100,1.5
    lleva 600 s -> 900,1 s). Un subtitulo es texto, asi que estirar sus tiempos es
    SIN PERDIDA: corrige una deriva de fps de verdad sin recodificar nada.

    EN AUDIO NO se aplica el factor a proposito: estirar los timestamps de audio no
    resamplea las muestras (produce chasquidos/huecos); la deriva de audio se
    arregla resampleando (ffmpeg), que es otra cosa y decide el usuario a mano. Y
    en un Atmos ni eso: resamplear mata los objetos. Por eso el factor se gatea a
    type=='subtitle'.

    Desfase exacto con estiramiento: el desfase medido es -beta y el mapeo correcto
    es tiempo_base = tiempo_fuente/alpha - beta/alpha, o sea nuevo = viejo*stretch +
    sync_ms*stretch. De ahi el d = round(sync_ms*stretch) (para stretch=1 queda el
    sync_ms de siempre)."""
    off = int(t.get("sync_ms") or 0)
    st  = t.get("stretch")
    if t.get("type") == "subtitle" and st and abs(float(st) - 1.0) > 1e-6:
        st = float(st)
        d  = int(round(off * st))
        return ["--sync", "%d:%d,%.9f" % (tid, d, st)]
    if off:
        return ["--sync", "%d:%d" % (tid, off)]
    return []


def _remux_build_cmd(job, converted):
    """mkvmerge final. Cada pista entra con su idioma, titulo, flags y --sync.

    --sync mueve los timestamps SIN recodificar, asi que una pista Atmos entra
    intacta aunque haya que desplazarla. Ese es el motivo de que el desfase se
    aplique aqui y no antes: cualquier filtro obligaria a decodificar.
    """
    out = job["output"]
    cmd = [MKVMERGE, "-o", out]

    base = job["video"]["path"]
    # Fichero 0 = el del video. Solo el video: sus audios y subs, si se quieren,
    # se piden explicitamente como cualquier otra pista.
    cmd += ["--no-audio", "--no-subtitles", "--video-tracks",
            str(job["video"]["index"]), base]

    order = ["0:%d" % job["video"]["index"]]
    fidx = 1
    for t in job["tracks"]:
        src = converted.get(id(t)) or t["path"]
        if converted.get(id(t)):
            tid = 0                     # el .ec3 / .srt solo tiene una pista
            cmd += ["--language", "0:%s" % (t.get("lang") or "und")]
            if t.get("title"): cmd += ["--track-name", "0:%s" % t["title"]]
            cmd += ["--default-track-flag", "0:%d" % (1 if t.get("default") else 0)]
            cmd += ["--forced-display-flag", "0:%d" % (1 if t.get("forced") else 0)]
            cmd += _sync_args(0, t)
            if src.lower().endswith(".srt"):
                # mkvmerge asume la codepage del SISTEMA para un .srt externo, no
                # UTF-8. Sin esto cualquier acento entra como mojibake, y tanto
                # ffmpeg como PgsToSrt escriben UTF-8.
                cmd += ["--sub-charset", "0:UTF-8"]
            cmd += [src]
        else:
            tid = int(t["index"])
            sel = {"audio": "--audio-tracks", "subtitle": "--subtitle-tracks"}[t["type"]]
            drop = ["--no-video"]
            drop += ["--no-subtitles"] if t["type"] == "audio" else ["--no-audio"]
            cmd += drop + ["--no-chapters", sel, str(tid)]
            cmd += ["--language", "%d:%s" % (tid, t.get("lang") or "und")]
            if t.get("title"): cmd += ["--track-name", "%d:%s" % (tid, t["title"])]
            cmd += ["--default-track-flag", "%d:%d" % (tid, 1 if t.get("default") else 0)]
            cmd += ["--forced-display-flag", "%d:%d" % (tid, 1 if t.get("forced") else 0)]
            cmd += _sync_args(tid, t)
            cmd += [src]
        order.append("%d:%d" % (fidx, tid))
        fidx += 1

    cmd += ["--track-order", ",".join(order)]
    return cmd


def _remux_pick_ref(base_path, lang):
    """Pista de audio del fichero base contra la que medir. Prefiere el MISMO
    idioma: la correlacion sale a pearson ~0.95 en vez de ~0.5, y con eso la
    diferencia entre 'medida buena' y 'ruido' deja de ser una apuesta."""
    try:
        auds = [t for t in remuxlib.probe(base_path)["tracks"] if t["type"] == "audio"]
    except Exception:
        return None
    if not auds:
        return None
    same = [a for a in auds if a["lang"] == lang]
    a = (same or auds)[0]
    return {"index": a["index"], "lang": a["lang"],
            "name": a["title"] or a["codec"], "mismo_idioma": bool(same)}


_PROG_RE = re.compile(r"(\d+)\s*%")

# Progreso de la conversion de audio (atmos-lib) reenviado por -OnProgress.
# Formato: 'REMUXPROG <stage> <pct>'. Ver _remux_run y la llamada a
# Convert-TrueHDToDDP en remux_worker.
_REMUXPROG_RE = re.compile(r"^REMUXPROG\s+(\S+)\s+([0-9]+(?:\.[0-9]+)?)")
_REMUX_STAGE_TXT = {
    "extract": "audio → extrayendo pista",
    "truehdd": "audio → decodificando TrueHD (Atmos)",
    "dee":     "audio → codificando DD+ Atmos",
    "ddp":     "audio → codificando DD+",
}


def _remux_run(job, cmd, etiqueta, progress=False):
    """Lanza un proceso guardando el handle, para que Cancelar pueda matarlo.

    Antes se usaba subprocess.run y el flag de cancelacion solo se miraba ENTRE
    pasos: darle a la X con mkvmerge a medio escribir 20 GB no hacia nada.

    progress=True parsea las lineas 'Progress: NN%' que mkvmerge emite por stdout
    y las publica en job['pct'], para que el panel muestre avance en vez de
    quedarse mudo mientras se escriben 20 GB.
    """
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, errors="replace", creationflags=_NO_WINDOW)
    job["proc"] = p
    out = []
    try:
        for line in p.stdout:
            # Lineas de progreso de atmos-lib (-OnProgress): actualizan fase y % y
            # NO se guardan en 'out' (son cientos y taparian el error de verdad,
            # que es lo que se enseña cuando algo falla).
            if line.startswith("REMUXPROG"):
                m = _REMUXPROG_RE.match(line)
                if m:
                    try:
                        job["phase"] = _REMUX_STAGE_TXT.get(m.group(1), m.group(1))
                        job["pct"]   = min(100, int(float(m.group(2))))
                    except Exception: pass
                continue
            out.append(line)
            if len(out) > 400: out.pop(0)
            if progress and "%" in line:
                m = _PROG_RE.search(line)
                if m:
                    try: job["pct"] = min(100, int(m.group(1)))
                    except Exception: pass
    finally:
        p.wait()
        job["proc"] = None
    if job.get("cancel"):
        raise RuntimeError("cancelado durante %s" % etiqueta)
    return p.returncode, "".join(out)


# NOTA: aqui vivia _poll_filesize, que seguia el crecimiento del .ec3 para estimar
# el avance de DEE. Se ha borrado porque NUNCA pudo funcionar: vigilaba el -OutFile,
# y atmos-lib escribe en su propio temporal y solo copia al -OutFile al terminar, asi
# que el fichero vigilado no existia hasta el final. El progreso real llega ahora por
# el -OnProgress de Convert-TrueHDToDDP (ver _REMUXPROG_RE y _remux_run).


def _remux_space_check(job, log):
    """Espacio antes de empezar. El 31/07/2026 un DAMF a medias lleno C: y se
    perdio un Atmos en un fallback silencioso; aqui se prefiere no arrancar."""
    need_out = 0
    try:
        need_out = os.path.getsize(job["video"]["path"])
    except Exception:
        pass
    for t in job["tracks"]:
        try:
            pr = remuxlib.probe(t["path"])
            tr = next((x for x in pr["tracks"] if x["index"] == int(t["index"])), None)
            if tr and tr.get("bitrate"):
                need_out += int(tr["bitrate"] / 8 * pr["duration"])
        except Exception:
            pass
    need_out = int(need_out * 1.05) + (300 << 20)          # margen

    free_out = shutil.disk_usage(DONE_DIR).free
    log("espacio: salida necesita ~%.1f GB, libres %.1f GB en %s"
        % (need_out / 1073741824, free_out / 1073741824, DONE_DIR))
    if free_out < need_out:
        raise RuntimeError("no cabe la salida: hacen falta ~%.1f GB y hay %.1f GB"
                           % (need_out / 1073741824, free_out / 1073741824))

    if any(t.get("to_srt") and t.get("ocr") for t in job["tracks"]):
        # El .sup extraido de una pista PGS de una peli larga ronda 50-100 MB y
        # convive con el .srt. No es gran cosa, pero si BIGTMP esta a cero el OCR
        # muere a mitad y el mensaje de PgsToSrt no dice nada de disco.
        os.makedirs(BIGTMP, exist_ok=True)
        if shutil.disk_usage(BIGTMP).free < (2 << 30):
            raise RuntimeError("menos de 2 GB libres en %s para el OCR de subtitulos"
                               % BIGTMP)

    if any(t.get("convert") for t in job["tracks"]):
        # .thd + DAMF conviven: el DAMF son 16ch x 48k x 32bit = 3,07 MB/s.
        dur = 0
        try:
            dur = remuxlib.probe(job["video"]["path"])["duration"]
        except Exception:
            dur = 8000
        need_tmp = int(dur * (1e6 + 3072000) * 1.15)
        os.makedirs(BIGTMP, exist_ok=True)
        free_tmp = shutil.disk_usage(BIGTMP).free
        log("espacio: conversion Atmos necesita ~%.0f GB en %s, libres %.0f GB"
            % (need_tmp / 1073741824, BIGTMP, free_tmp / 1073741824))
        if free_tmp < need_tmp:
            raise RuntimeError("no cabe el DAMF en %s: hacen falta ~%.0f GB y hay %.0f GB"
                               % (BIGTMP, need_tmp / 1073741824, free_tmp / 1073741824))


def _remux_verify(job, log):
    """Mide el RESULTADO contra el original, y devuelve tambien las
    correcciones que se pueden aplicar SIN pedir permiso (ver mas abajo el
    criterio de cuando es seguro). Sin esto, 'mkvmerge devolvio 0' se
    confunde con 'el fichero esta bien', que no es lo mismo: el 01/08/2026 un mux
    correcto salio con el audio 90 ms desplazado y solo se vio al medirlo."""
    base = job["video"]["path"]
    problemas = []
    # AUTO-CORRECCION (25/08/2026). Motivo: xray.mkv salio 77 ms tarde DOS
    # veces en el mismo dia con dos --sync distintos (-21606 y -21607), porque
    # mkvmerge no rebasa el arranque de contenedor propio de la pista de audio
    # (0,077 s en ese caso) al aplicar --sync. Medido y confirmado a mano:
    # aplicar sync_pedido - 77 ms dejaba el resultado en +0,8 ms. topgunv2.mkv
    # el mismo dia tuvo el mismo patron por el otro lado (con referencia): un
    # DD+ Atmos espaniol salio "hasta 81.0 ms de desfase (offset +81.0, deriva
    # +0, residuo 0.0)", o sea un numero limpio y consistente, no ruido.
    # Como el mux cuesta 8-20 s (medido: xray 5,00 GB en 21 s), corregir una
    # vez y volver a medir es practicamente gratis, y evita que el usuario
    # tenga que restar el numero a mano cada vez.
    correcciones = {}   # {indice en job["tracks"]: nuevo sync_ms}
    CORR_MAX_MS = 1000  # por encima de esto no es este bug: no autocorregir
    # orden de salida = video (0) + las pistas en el orden en que se pidieron
    for i, t in enumerate(job["tracks"]):
        if t["type"] != "audio":
            continue
        etq = "%s [%s]" % (t.get("title") or "audio", t.get("lang"))
        ref = _remux_pick_ref(base, t.get("lang") or "und")

        # SIN REFERENCIA DEL MISMO IDIOMA NO SE MIDE LA SINCRONIA (24/08/2026).
        # Antes se medía igualmente contra la pista que hubiera, y correlacionar
        # un doblaje inglés contra uno español da un número sin sentido que se
        # presentaba como REVISAR. Caso real, Camp X-Ray (24/08/2026): el vídeo
        # venía de un fichero que solo trae español, y la pista inglesa salió con
        # "offset +235,0, deriva -560, residuo 0.0" -deriva enorme con residuo
        # cero es imposible- y mandó al usuario a revisar algo que no se había
        # podido medir. Avisar en falso es peor que no avisar: entrena a ignorar
        # los avisos, y el de al lado (español, +75,8 ms) sí era de verdad.
        #
        # Lo que SÍ se puede comprobar sin referencia es que el mux aplicó el
        # desfase que se le pidió. Eso NO dice si el desfase era el correcto
        # -para eso hace falta una referencia en el mismo idioma- pero pilla un
        # mux que ignoró el --sync, que es el fallo que esto vigila.
        # Y si la pista salió del mismo fichero que otra que sí se ha podido
        # verificar, hereda su sincronía: venían ya sincronizadas entre sí.
        if not ref or not ref["mismo_idioma"]:
            pedido = float(t.get("sync_ms") or 0)
            if t.get("convert"):
                # Convertida (TrueHD->DD+): su origen ya no es t["path"] sino el
                # .ec3, y el desfase se re-midió tras convertir. Medir contra el
                # original mezclaría el retardo pedido con el de la conversión.
                log("  no verificable  %s: el fichero de vídeo no trae audio en "
                    "[%s]. Pista convertida: su desfase se re-midió tras "
                    "convertir (%+d ms)." % (etq, t.get("lang"), pedido))
                continue
            try:
                ma = remuxlib.measure(t["path"], int(t["index"]), job["output"], i + 1)
            except Exception as e:
                ma = {"ok": False, "error": str(e)}
            if not ma.get("ok"):
                log("  no verificable  %s: el fichero de vídeo no trae audio en "
                    "[%s] y tampoco se pudo medir contra su origen (%s)"
                    % (etq, t.get("lang"), str(ma.get("error"))[:70]))
                continue
            aplicado = float(ma["beta_ms"])
            # Se comparan MAGNITUDES a propósito: el signo depende de la
            # convención de measure() y de mkvmerge, y aquí solo interesa si el
            # retardo aplicado es el pedido o no.
            if abs(abs(aplicado) - abs(pedido)) > remuxlib.UMBRAL_MS:
                problemas.append(etq)
                delta = pedido - aplicado
                # El mux es lineal (--sync desplaza, no recodifica), asi que
                # pedir pedido+delta otra vez debe acercar aplicado a pedido en
                # esa misma cantidad. Solo si el hueco es pequenyo: uno grande
                # significa que el problema es OTRO (pista equivocada, p.ej.),
                # y ahi inventar una correccion seria peor que avisar.
                if ma.get("residual_ms", 999) <= remuxlib.UMBRAL_MS and abs(delta) <= CORR_MAX_MS:
                    correcciones[i] = int(round(pedido + delta))
                log("  REVISAR  %s: el mux NO aplicó el desfase pedido "
                    "(pedido %+d ms, medido %+.0f ms contra su propio origen)"
                    % (etq, pedido, aplicado))
            else:
                log("  no verificable  %s: el fichero de vídeo no trae audio en "
                    "[%s], así que no hay contra qué medir su sincronía absoluta. "
                    "El mux sí aplicó el desfase pedido (%+d ms). Si salió del "
                    "mismo fichero que otra pista ya verificada, hereda la suya."
                    % (etq, t.get("lang"), pedido))
            continue

        try:
            m = remuxlib.measure(base, ref["index"], job["output"], i + 1)
        except Exception as e:
            log("  verificacion de la pista %d: no se pudo medir (%s)" % (i + 1, e))
            continue
        if not m.get("ok"):
            log("  verificacion de la pista %d: sin medida fiable" % (i + 1))
            continue
        # CRITERIO: el PEOR desfase real en CUALQUIER punto de la peli, no la
        # 'deriva' del ajuste lineal.
        #
        # La deriva se dispara con un ESCALON -un doblaje empalmado que salta a
        # mitad de peli- aunque cada tramo este perfectamente dentro de lo audible.
        # Paso con Legítima defensa (11/08/2026): el spa salio a offset +0,1 ms
        # -sincronia perfecta- pero avisaba de "deriva +110 ms" (residuo 20 ms, la
        # senyal de que la recta no encaja: es un escalon, no una rampa). El
        # usuario lo reprodujo en varios puntos y cuadraba; el aviso era falso.
        # Lo que importa es si en ALGUN punto medido el desfase supera el umbral
        # audible, y eso es max(|lag| de cada punto), no la pendiente de la recta.
        # Esto NO afloja la deteccion de fallos de verdad: un audio 1 s desplazado
        # (diarevelacion: eng a -1013 ms) o con 316 ms de offset da un peor-punto
        # muy por encima del umbral y sigue avisando.
        pts = m.get("points") or []
        peor = max((abs(p["lag_ms"]) for p in pts), default=abs(m["beta_ms"]))
        detalle = ("offset %+.1f, deriva %+.0f, residuo %.1f%s" %
                   (m["beta_ms"], m["drift_ms"], m["residual_ms"],
                    "" if ref["mismo_idioma"] else ", contra otro idioma"))
        if peor <= remuxlib.UMBRAL_MS:
            log("  OK  %s: peor desfase %.1f ms en toda la peli (%s)" % (etq, peor, detalle))
        else:
            problemas.append(etq)
            # Igual que arriba: solo se autocorrige un desfase FIJO y limpio.
            # Con escalera (montajes distintos) o deriva real, un solo numero
            # no arregla nada y podria empeorarlo -eso lo sigue decidiendo una
            # persona. 'residual_ms' es el residuo del AJUSTE lineal (no el
            # peor punto), asi que exige que la recta encaje de verdad.
            seguro = (not m.get("escalera")
                      and abs(m.get("drift_ms", 999)) <= remuxlib.UMBRAL_MS
                      and m.get("residual_ms", 999) <= remuxlib.UMBRAL_MS
                      and abs(m["beta_ms"]) <= CORR_MAX_MS)
            if seguro:
                antes = int(t.get("sync_ms") or 0)
                correcciones[i] = int(round(antes - m["beta_ms"]))
            log("  REVISAR  %s: hasta %.1f ms de desfase (%s)" % (etq, peor, detalle))
    return problemas, correcciones


def remux_worker():
    global remux_worker_started
    while True:
        job = None
        with remux_lock_t:
            if remux_queue:
                job = remux_jobs.get(remux_queue[0])
        if not job:
            time.sleep(2)
            continue

        # Pausa GLOBAL de mantenimiento, la misma que miran los tres watchers.
        # El panel no la miraba hasta el 05/08/2026, asi que "pausar todo" para
        # tocar los scripts dejaba libre justo la cola capaz de arrancar una
        # conversion Atmos de 30-40 GB y 20+ min de CPU.
        if os.path.isfile(PIPELINE_PAUSED):
            job["status"] = "waiting"
            job["last_log"] = "pipeline en PAUSA global (mantenimiento); esperando..."
            time.sleep(10)
            continue

        # EL LOCK, ANTES DE SACAR EL TRABAJO DE LA COLA.
        #
        # Esperar turno: la ruta Atmos come 30-40 GB en BigTmp y 20+ min de CPU.
        # Lanzarla junto a un encode es lo que lleno C: el 31/07/2026.
        #
        # Antes esto llamaba a _remux_pipeline_busy() -que es una comprobacion
        # BARATA y CON CARRERA, el gemelo de Test-PipelineLockBusy- y despues
        # guardaba el resultado de _remux_take_lock() en 'got_lock' SIN MIRARLO:
        # si otro pipeline entraba entre la comprobacion y la toma, el remux
        # seguia adelante igualmente, sin lock. Es la misma carrera que se
        # arreglo en los tres watchers el 04/08/2026 (ver pipeline-lock.ps1).
        #
        # Y va ANTES del pop por la misma razon que alli va antes del Move-Item:
        # perdiendo la carrera aqui, el trabajo sigue en la cola y se reintenta a
        # la vuelta siguiente; perdiendola despues del pop, se habria quedado
        # fuera de la cola sin que nadie lo ejecute.
        if not _remux_take_lock():
            job["status"] = "waiting"
            job["last_log"] = "esperando a que termine el pipeline en curso..."
            time.sleep(10)
            continue

        with remux_lock_t:
            if remux_queue and remux_queue[0] == job["id"]:
                remux_queue.pop(0)
            else:
                # Ya no es el primero (lo cancelaron, o se reordeno la cola).
                # Soltar el lock: si no, se queda cogido por un trabajo que no
                # llega a arrancar y bloquea los tres pipelines.
                _remux_free_lock()
                continue

        job["status"] = "running"
        job["started"] = time.time()
        def log(m):
            job["log"].append(m); job["last_log"] = m
        def phase(nombre, pct=None):
            # pct=None => barra indeterminada (paso sin % fiable, p.ej. verificar)
            # CRONOMETRO POR FASE (24/08/2026). El registro del job solo tenía
            # id/name/pct/phase/status, así que cuando un remux tardaba 9 minutos
            # no había forma de saber si se iban en el mux, en el OCR de los
            # subtítulos o en la verificación: había que adivinarlo. Ahora cada
            # fase acumula su tiempo en job["times"] y se resume en el log.
            ahora = time.time()
            ini = job.get("_fase_ini")
            if ini and job.get("phase"):
                # Se agrupa por el nombre sin el contador: 'subtítulos (1/3)' y
                # '(2/3)' suman en la misma entrada.
                k = job["phase"].split(" (")[0]
                job.setdefault("times", {})
                job["times"][k] = round(job["times"].get(k, 0.0) + ahora - ini, 1)
            job["_fase_ini"] = ahora
            job["phase"] = nombre
            job["pct"] = pct

        # El lock ya esta cogido (arriba, antes del pop): aqui es un hecho, no un
        # intento. Por eso el finally lo suelta sin condiciones.
        converted = {}
        try:
            phase("preparando", None)
            _remux_space_check(job, log)

            # 1) conversiones de audio pedidas (TrueHD Atmos -> DD+ Atmos)
            for t in job["tracks"]:
                if not t.get("convert"):
                    continue
                if job.get("cancel"): raise RuntimeError("cancelado")
                ordn = _audio_ordinal(t["path"], int(t["index"]))
                if ordn is None:
                    raise RuntimeError("no localizo la pista %s en %s"
                                       % (t["index"], os.path.basename(t["path"])))
                os.makedirs(BIGTMP, exist_ok=True)
                ec3 = os.path.join(BIGTMP, "remux_%s_%d.ec3" % (job["id"][:8], t["index"]))
                br  = int(t.get("bitrate") or 768)
                log("convirtiendo a DD+%s %dk (a:%d de %s)..."
                    % (" Atmos" if t.get("objects") else "", br, ordn,
                       os.path.basename(t["path"])))
                # PROGRESO REAL, via el -OnProgress de atmos-lib.
                # Antes esto vigilaba el TAMANO de $ec3 con _poll_filesize, y no
                # podia funcionar: atmos-lib escribe su propio temporal
                # (ddp_<stamp>_<idx>.ec3 en BigTmp) y solo lo copia a -OutFile
                # cuando YA ha terminado (ver el $samePath/Copy-Item de
                # Convert-TrueHDToDDP). El fichero vigilado no existia hasta el
                # final, asi que la barra se quedaba clavada en 0 durante MAS DE UNA
                # HORA (extraer .thd + truehdd + DEE) y saltaba a 100 de golpe.
                # Convert-TrueHDToDDP ya sabe reportar 'extract'/'truehdd'/'dee' con
                # su %, que es lo que usa encode.ps1; aqui se reenvia por stdout y
                # lo parsea _remux_run. -DurationSec es necesario para que la fase
                # de extraccion pueda dar % (si no, solo reporta el 0 inicial).
                try:
                    dur = remuxlib.probe(t["path"])["duration"] or 0
                except Exception:
                    dur = 0
                # -IsAtmos SOLO si la pista lleva objetos. Antes se pasaba SIEMPRE,
                # porque el panel solo ofrecia convertir pistas con Atmos/TrueHD.
                # Desde que tambien se ofrece para DTS/FLAC/PCM/Opus, mandar
                # -IsAtmos en una pista sin objetos meteria a DEE por la ruta JOC
                # con un DAMF que no existe.
                conObjetos = bool(t.get("objects"))
                etq = "DD+ Atmos" if conObjetos else "DD+"
                phase("audio → %s" % etq, 0)
                ps = (". '%s'; Convert-TrueHDToDDP -InputFile '%s' -AudioIndex %d "
                      "%s-Bitrate %d -OutFile '%s' -DurationSec %.3f "
                      "-OnProgress { param($s,$p) Write-Host ('REMUXPROG {0} {1}' -f $s,$p) }"
                      % (_ps_q(ATMOS_LIB), _ps_q(t["path"]), ordn,
                         "-IsAtmos " if conObjetos else "", br, _ps_q(ec3), dur))
                rc, out = _remux_run(job, [PWSH, "-NoProfile", "-Command", ps], "la conversion")
                if not os.path.isfile(ec3) or os.path.getsize(ec3) < 100000:
                    raise RuntimeError("la conversion a %s fallo: %s" % (etq, out[-400:]))
                converted[id(t)] = ec3
                log("  -> %s (%.0f MB)" % (os.path.basename(ec3),
                                           os.path.getsize(ec3) / 1048576))

                # RE-MEDIR TRAS CONVERTIR. El desfase que venia de la interfaz se
                # midio sobre la pista ORIGINAL, y la conversion puede desplazarla:
                # el 01/08/2026 un .ec3 salido de DEE quedo 84 ms por delante de su
                # TrueHD (dispersion 0.0 ms en 3 puntos, pearson 0.99). Aplicar el
                # desfase viejo al fichero nuevo es exactamente el fallo que obligo
                # a rehacer un mux de 30 GB.
                ref = _remux_pick_ref(job["video"]["path"], t.get("lang") or "und")
                if ref:
                    try:
                        m = remuxlib.measure(job["video"]["path"], ref["index"], ec3, 0)
                    except Exception as e:
                        m = {"ok": False, "error": str(e)}
                    if m.get("ok") and m["residual_ms"] <= remuxlib.UMBRAL_MS:
                        nuevo = int(round(-m["beta_ms"]))
                        if nuevo != int(t.get("sync_ms") or 0):
                            log("  sync ajustado tras convertir: %+d -> %+d ms "
                                "(medido contra «%s»%s)"
                                % (int(t.get("sync_ms") or 0), nuevo, ref["name"],
                                   "" if ref["mismo_idioma"] else ", otro idioma"))
                        t["sync_ms"] = nuevo
                    else:
                        log("  AVISO: no se pudo re-medir tras convertir; se deja "
                            "el desfase de la interfaz (%+d ms). Verifica a mano."
                            % int(t.get("sync_ms") or 0))

            # 1b) subtitulos que no son SRT -> SRT
            # Se llama a Convert-SubToSrt de subs-lib.ps1, la MISMA que usa
            # encode.ps1: ass/ssa salen por ffmpeg en segundos, los PGS pasan por
            # el OCR de PgsToSrt y tardan minutos por pista.
            #
            # La POLITICA ante un fallo se decide aqui, no en la libreria, y es la
            # de encode.ps1: si la pista venia VACIA de origen se descarta (no se
            # pierde nada); si el OCR fallo sobre una pista CON contenido se copia
            # la original tal cual. Un subtitulo de imagen es peor que uno de
            # texto, pero es infinitamente mejor que ninguno.
            subs_pend = [t for t in job["tracks"]
                         if t.get("type") == "subtitle" and t.get("to_srt")]
            descartadas = []
            for si, t in enumerate(subs_pend):
                if job.get("cancel"): raise RuntimeError("cancelado")
                # Los PGS (OCR) tardan minutos; el % por-pista al menos dice que
                # avanza. El texto es tan rapido que el numero ni se ve.
                phase("subtítulos (%d/%d)" % (si + 1, len(subs_pend)),
                      int(si / len(subs_pend) * 100))
                ordn = _stream_ordinal(t["path"], int(t["index"]), "subtitle")
                if ordn is None:
                    raise RuntimeError("no localizo el subtitulo %s en %s"
                                       % (t["index"], os.path.basename(t["path"])))
                os.makedirs(BIGTMP, exist_ok=True)
                srt = os.path.join(BIGTMP, "remux_%s_s%d.srt"
                                   % (job["id"][:8], int(t["index"])))
                modo = "OCR" if t.get("ocr") else "texto"
                log("subtitulo %s [%s] -> SRT (%s)..."
                    % (t.get("title") or "s:%d" % ordn, t.get("lang") or "und", modo))
                # El codigo 3 (TIMEOUT) va aparte a proposito: un timeout es
                # TRANSITORIO -la misma pista convierte en ~20 s con la maquina
                # tranquila- asi que degradar a PGS-imagen ahi seria perder el SRT
                # para siempre por algo pasajero. encode.ps1 reencola en ese caso;
                # aqui, que es interactivo, se para y se dice, para que el usuario
                # reintente. Mismo criterio que preferencia-fallar-alto-no-degradar.
                ps = (". '%s'; $r = Convert-SubToSrt -InputFile '%s' -SubOrdinal %d "
                      "-OutFile '%s' -Lang '%s' -WorkDir '%s'; "
                      "if ($r.Ok) { exit 0 } "
                      "elseif ($r.Empty) { Write-Host \"vacia: $($r.Reason)\"; exit 2 } "
                      "elseif ($r.TimedOut) { Write-Host \"timeout: $($r.Reason)\"; exit 3 } "
                      "else { Write-Host \"fallo: $($r.Reason)\"; exit 1 }"
                      % (_ps_q(SUBS_LIB), _ps_q(t["path"]), ordn, _ps_q(srt),
                         _ps_q(t.get("lang") or "und"), _ps_q(BIGTMP)))
                rc, out = _remux_run(job, [PWSH, "-NoProfile", "-Command", ps],
                                     "la conversion de subtitulos")
                ok = rc == 0 and os.path.isfile(srt) and os.path.getsize(srt) > 16
                if ok:
                    converted[id(t)] = srt
                    log("  -> %s (%d lineas)"
                        % (os.path.basename(srt),
                           sum(1 for _ in open(srt, encoding="utf-8", errors="replace"))))
                elif rc == 2:
                    descartadas.append(t)
                    log("  -> pista VACIA en origen, se DESCARTA")
                elif rc == 3:
                    # TIMEOUT: fallo transitorio. NO se degrada a PGS-imagen.
                    raise RuntimeError(
                        "el OCR de la pista '%s' se agoto (12 min). Es un fallo "
                        "TRANSITORIO: aislada, una pista tarda ~20 s, asi que esto "
                        "significa que la CPU estaba disputada (JDownloader, eMule, "
                        "otro trabajo...). No se degrada a subtitulo de imagen: "
                        "reintenta el remux con la maquina tranquila."
                        % (t.get("title") or "s:%d" % ordn))
                else:
                    log("  -> AVISO: no se pudo convertir (%s). Se copia la pista "
                        "original tal cual." % (out.strip().splitlines() or ["sin detalle"])[-1])
            for t in descartadas:
                job["tracks"].remove(t)

            # 2) mux final
            if job.get("cancel"): raise RuntimeError("cancelado")
            cmd = _remux_build_cmd(job, converted)
            job["cmd"] = " ".join(cmd)
            phase("mux", 0)
            log("muxeando...")
            rc, out = _remux_run(job, cmd, "el mux", progress=True)
            if not os.path.isfile(job["output"]):
                raise RuntimeError(out[-500:])
            sz = os.path.getsize(job["output"])
            log("muxeado: %.2f GB. Verificando sincronia..." % (sz / 1073741824))

            # 3) verificacion del RESULTADO
            phase("verificando", None)
            problemas, correcciones = _remux_verify(job, log)

            # AUTO-CORRECCION, UNA SOLA VEZ (25/08/2026). Si _remux_verify
            # encontro un desfase FIJO y limpio (ver los criterios 'seguro' de
            # alla), se corrige el sync y se remuxea sin volver a convertir
            # audio ni subtitulos -eso ya esta hecho y no cambia-. El mux en si
            # es barato (8-20 s medido), asi que esto sale practicamente gratis
            # comparado con dejar el aviso para que el usuario lo corrija a
            # mano la proxima vez, como paso con xray.mkv el 24/08/2026 (DOS
            # veces, con dos --sync distintos, mismo 77 ms de sobra).
            if correcciones:
                log("sync corregido automaticamente en %d pista(s); "
                    "remuxeando de nuevo (no hace falta reconvertir audio ni "
                    "subtitulos)..." % len(correcciones))
                for i, nuevo in correcciones.items():
                    tr = job["tracks"][i]
                    antes = int(tr.get("sync_ms") or 0)
                    tr["sync_ms"] = nuevo
                    log("  %s [%s]: sync %+d -> %+d ms"
                        % (tr.get("title") or "audio", tr.get("lang"), antes, nuevo))
                cmd = _remux_build_cmd(job, converted)
                job["cmd"] = " ".join(cmd)
                phase("mux (corrigiendo sync)", 0)
                rc, out = _remux_run(job, cmd, "el mux (reintento)", progress=True)
                if not os.path.isfile(job["output"]):
                    raise RuntimeError(out[-500:])
                sz = os.path.getsize(job["output"])
                log("re-muxeado: %.2f GB. Reverificando sincronia..." % (sz / 1073741824))
                phase("verificando (2)", None)
                problemas, correcciones2 = _remux_verify(job, log)
                if correcciones2:
                    # No se reintenta una segunda vez: si la correccion no
                    # convergio, seguir corrigiendo a ciegas es mas probable
                    # que enmascare un problema real que arreglarlo.
                    log("AVISO: tras corregir, sigue habiendo desfase medible "
                        "en %d pista(s); no se reintenta mas. Revisa a mano."
                        % len(correcciones2))
            # SANEADO DE LA SALIDA (29/08/2026).
            # Un remux de mkvmerge CONSERVA los timestamps, y eso NO arregla la
            # pantalla negra en Direct Play de las Samsung: esta medido con un
            # A/B/A: hace falta extraer+muxear, que los regenera. Asi que la
            # salida de un remux entra en la biblioteca con el mismo defecto que
            # cualquier otro fichero de fuera. Aqui se reconstruye y de paso se
            # dejan las banderas como toca: castellano por defecto y forzados en
            # castellano por defecto.
            #
            # NO se hace si el trabajo se va a encadenar al pipeline de VIDEO:
            # encode.ps1 reconstruye por su cuenta al final, y hacerlo dos veces
            # es reescribir 20 GB para nada.
            #
            # Un fallo aqui NO tumba el remux: el fichero muxeado es correcto, lo
            # que se pierde es el arreglo de la pantalla negra. Se dice y se sigue.
            if not job.get("encode_after") and not problemas:
                phase("saneando", 97)
                log("saneando la salida: reconstruccion del contenedor y banderas por defecto")
                try:
                    r = _sanear_lanzar(job["output"], False)
                    if r.get("ok"):
                        for a in (r.get("acciones") or []):
                            log("  sanear: %s" % a)
                    else:
                        log("AVISO: no se pudo sanear la salida (%s). El remux es "
                            "correcto, pero puede dar pantalla negra en Direct Play."
                            % r.get("motivo"))
                    for a in (r.get("avisos") or []):
                        log("  sanear AVISO: %s" % a)
                except Exception as e:
                    log("AVISO: fallo el saneado de la salida: %s" % e)

            phase("terminado", 100)
            tt = job.get("times") or {}
            if tt:
                log("tiempos: %s | TOTAL %.0f s"
                    % (" | ".join("%s %.0f s" % (k, v) for k, v in tt.items()),
                       time.time() - job["started"]))
            if problemas:
                job["status"] = "warn"
                log("HECHO CON AVISOS: revisa %s" % ", ".join(problemas))
            else:
                job["status"] = "done"
                log("listo: %s (%.2f GB) - sincronia verificada"
                    % (os.path.basename(job["output"]), sz / 1073741824))

            # ENCADENADO CON EL PIPELINE DE VIDEO.
            # Si se pidio encodear el video, la salida del remux se MUEVE a
            # encode_queue y encode-watch.ps1 la recoge sola. No hace falta nada
            # mas: el pipeline de video es dirigido por carpetas, asi que dejar el
            # fichero ahi ES encolarlo. Ventaja de reusarlo tal cual: el audio ya
            # convertido (EAC3) y los subtitulos ya en SRT se COPIAN, no se
            # reprocesan, porque encode.ps1 solo toca lo que hace falta.
            # Si el remux dio avisos NO se encadena: encadenar un mux con la
            # sincronia en duda solo multiplica el trabajo perdido.
            if job.get("encode_after"):
                if problemas:
                    log("NO se encola para encodear: el remux termino con avisos. "
                        "Revisa la sincronia y encolalo a mano si esta bien.")
                else:
                    try:
                        os.makedirs(ENC_QUEUE, exist_ok=True)
                        dst = os.path.join(ENC_QUEUE, os.path.basename(job["output"]))
                        if os.path.exists(dst):
                            log("NO se encola para encodear: ya hay un %s en la cola de video."
                                % os.path.basename(dst))
                        else:
                            shutil.move(job["output"], dst)
                            job["output"] = dst
                            log("encolado en el pipeline de VIDEO -> %s" % dst)
                    except Exception as e:
                        log("no se pudo encolar para encodear (%s). El fichero se "
                            "queda en %s" % (e, job["output"]))
        except Exception as e:
            job["status"] = "cancelled" if job.get("cancel") else "error"
            job["phase"] = None; job["pct"] = None
            job["error"] = str(e)
            log("ERROR: %s" % e)
            try:
                if os.path.isfile(job["output"]): os.remove(job["output"])
            except Exception:
                pass
        finally:
            # EL ORDEN IMPORTA (26/08/2026): primero borrar los temporales y
            # DESPUES soltar el lock, igual que hace Clear-JobTemps en el lado
            # PowerShell y por la misma razon que documenta su cabecera. Estaba al
            # reves: se soltaba el lock y luego se borraban los 'remux_*.ec3' y
            # '.srt'. La ventana era de milisegundos, pero es exactamente la forma
            # del fallo del 04/08/2026 (un barrido llevandose temporales de otro
            # trabajo), y darle la vuelta no cuesta nada.
            for p in converted.values():
                try: os.remove(p)
                except Exception: pass
            _remux_free_lock()   # solo lo borra si el PID de dentro es el nuestro
            job["ended"] = time.time()
            # PERSISTIR EL LOG. Hasta el 12/08/2026 el log del remux vivia SOLO en
            # memoria (job["log"]) y se perdia al reiniciar el panel: si un trabajo
            # terminaba con AVISOS, no habia forma de revisarlos despues. Ahora se
            # vuelca a encode_logs -junto a los del pipeline de video- con una
            # cabecera, y se anota una linea en remux_history.jsonl para localizar
            # de un vistazo los que salieron 'warn'/'error'. Todo en su propio try:
            # un fallo guardando el log NUNCA debe romper el cierre del trabajo.
            try:
                stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                safe  = re.sub(r'[<>:"/\\|?*\n\r\t]', "_",
                               os.path.splitext(job.get("name") or "remux")[0])[:120]
                log_name = "%s_remux_%s.log" % (stamp, safe)
                os.makedirs(LOG_DIR, exist_ok=True)
                cab = [
                    "=== REMUX %s ===" % job.get("status", "?").upper(),
                    "salida : %s" % job.get("output", ""),
                    "estado : %s" % job.get("status", "?"),
                    "fecha  : %s" % datetime.now().isoformat(timespec="seconds"),
                ]
                if job.get("error"): cab.append("error  : %s" % job["error"])
                with open(os.path.join(LOG_DIR, log_name), "w",
                          encoding="utf-8", errors="replace") as lf:
                    lf.write("\n".join(cab) + "\n\n" + "\n".join(job.get("log", [])))
                job["log_file"] = log_name
                # Indice compacto: una linea por trabajo. Para "que remuxes dieron
                # avisos" basta con:  grep '"status":"warn"' remux_history.jsonl
                entrada = {
                    "ts": int(job["ended"]), "id": job["id"],
                    "name": job.get("name", ""), "status": job.get("status", "?"),
                    "output": job.get("output", ""), "log": log_name,
                }
                with open(os.path.join(LOG_DIR, "remux_history.jsonl"), "a",
                          encoding="utf-8") as hf:
                    hf.write(json.dumps(entrada, ensure_ascii=False) + "\n")
            except Exception as e:
                # Que no se pierda del todo: al menos dejar rastro en el last_log.
                try: job["last_log"] = "aviso: no se pudo guardar el log (%s)" % e
                except Exception: pass


def remux_ensure_worker():
    global remux_worker_started
    if not remux_worker_started:
        remux_worker_started = True
        threading.Thread(target=remux_worker, daemon=True).start()


@app.route("/api/remux/probe", methods=["POST"])
def remux_probe():
    paths = (request.json or {}).get("paths") or []
    out = []
    for p in paths[:6]:
        if not os.path.isfile(p):
            out.append({"path": p, "error": "no existe"}); continue
        try:
            d = remuxlib.probe(p)
            d["path"] = p
            d["name"] = os.path.basename(p)
            d["size"] = os.path.getsize(p)
            out.append(d)
        except Exception as e:
            out.append({"path": p, "error": str(e)})
    return jsonify({"files": out})


@app.route("/api/remux/measure", methods=["POST"])
def remux_measure():
    j = request.json or {}
    b, s = j.get("base") or {}, j.get("src") or {}
    if not (b.get("path") and s.get("path")):
        return jsonify({"ok": False, "error": "faltan base/src"}), 400
    # QUE MEDICIONES QUIERE EL USUARIO (17/08/2026). El audio de 4 puntos va
    # SIEMPRE: cuesta 2 s y es la unica medida fina (0,5 ms frente a los ~83 ms
    # de la imagen y los ~200 ms de los subtitulos).
    # Las casillas anyaden mediciones y, ademas, LIMITAN la escalera automatica:
    # si el usuario ha elegido algo, no se le cuela un peldano que no pidio -la
    # pasada de imagen cuesta ~200 s en un fichero grande-. Si no elige nada, la
    # escalera queda completa, que es la red puesta el 14/08 para que esto
    # funcione sin saber marcar casillas.
    # POR DEFECTO, SOLO AUDIO (18/08/2026). Antes, si el audio no enganchaba, se
    # encadenaba solo subtitulos e imagen: correcto pero carisimo (199 s la de
    # imagen en un fichero de 17,6 GB) y sin que nadie lo hubiera pedido. Ahora
    # lo caro solo entra si se marca la casilla. La red que se pierde se cubre
    # de otra forma, y mejor: cuando el audio no engancha y no hay peldanos
    # permitidos, measure() devuelve ok=False DICIENDOLO, en vez del ok=True con
    # un beta inventado que devolvia hasta hoy.
    quiere_video = bool(j.get("video"))
    quiere_subs  = bool(j.get("subs"))
    quiere_paq   = bool(j.get("paquetes"))
    # LABIOS (02/09/2026). No entra en 'permitir' a proposito: no es un peldano
    # de la escalera, porque no contesta a la misma pregunta. Las tres de arriba
    # miden UNA PISTA CONTRA OTRO FICHERO; esta mide un fichero contra SU PROPIA
    # IMAGEN, y por eso es la unica que puede ver el caso en que todo el release
    # viene corrido -donde las otras dicen "ya esta sincronizada" y aciertan,
    # porque entre ellas lo estan-.
    quiere_voz   = bool(j.get("voz"))
    # El orden de la tupla NO decide nada -measure() prueba los peldanos en su
    # propio orden (paquetes, subs, imagen)-, pero se deja igual para que se lea.
    permitir = tuple(k for k, v in (("paquetes", quiere_paq),
                                    ("subs", quiere_subs),
                                    ("video", quiere_video)) if v)
    try:
        m = remuxlib.measure(b["path"], int(b["index"]), s["path"], int(s["index"]),
                             permitir=permitir)
        m["recommend"] = remuxlib.recommend(m, bool(s.get("objects")),
                                            for_subtitle=bool(j.get("for_subtitle")))
        m["permitir"] = list(permitir)
        # SEGUNDA OPINION POR IMAGEN, solo si la pide el usuario con la casilla.
        # Por defecto no se toca nada: esto decodifica video y tarda minutos,
        # mientras que la medida por audio son segundos.
        #
        # Para que sirve: cuando el audio no engancha (mezclas rehechas, pistas
        # sin nada en comun) o cuando se sospecha una diferencia de CADENCIA
        # (23.976 contra 24 son 7,2 s de deriva en dos horas) y se quiere
        # confirmar el alpha con una medida independiente.
        #
        # OJO A LA PRECISION: la serie de video se muestrea a 12 fps, o sea 83 ms
        # por muestra, frente a los 0,5 ms de la envolvente de audio. Para deriva
        # de cadencia sobra; para un desfase fijo de milisegundos, NO sustituye al
        # audio. Por eso se devuelve aparte y no se mezcla con el resultado bueno.
        #
        # Desde el 07/08/2026 _lum decodifica con -skip_frame bidir (40 veces mas
        # rapido: la pasada por imagen bajo de ~865 s a 21,5 s). El coste es que
        # el flujo efectivo queda en ~6 fps y el pico puede bailar un muestreo:
        # midiendo un fichero contra si mismo, donde la verdad es 0, salio 73,9 ms.
        # Por eso la tolerancia de "coinciden" subio de 120 a 200 ms: con ~83 ms de
        # vaiven posible en la medida de imagen, 120 ms habria empezado a dar
        # avisos de discrepancia FALSOS, que es peor que no avisar.
        # SUBTITULOS como medida adicional, si se ha pedido. Cuesta ~46 s en un
        # fichero de 17,6 GB (solo demultiplexa, no decodifica) y es inmune a la
        # mezcla de audio y al reencode. Da la ESTRUCTURA -tramos y huecos-, no
        # el milisegundo. No se repite si la medida principal YA vino por ahi.
        if quiere_subs and m.get("fallback") != "subs":
            try:
                m["subs"] = remuxlib.medir_por_subtitulos(b["path"], s["path"])
            except Exception as e:
                m["subs"] = {"ok": False, "error": str(e)}
        if quiere_video and m.get("fallback") != "video":
            try:
                mv = remuxlib.measure(b["path"], int(b["index"]),
                                      s["path"], int(s["index"]), mode="video")
                m["video"] = mv
                if mv.get("ok") and m.get("ok"):
                    da = abs(float(m.get("beta_ms", 0)) - float(mv.get("beta_ms", 0)))
                    m["video_agree"] = bool(da <= 200)   # ~2.5 muestras de video
                    m["video_delta_ms"] = round(da, 1)
            except Exception as e:
                m["video"] = {"ok": False, "error": str(e)}
        # LABIOS: voz contra los subtitulos DEL FICHERO BASE. Sobre el base y no
        # sobre el origen porque el MKV final hereda la linea de tiempo del que
        # pone el video: si ahi el audio va corrido respecto a su propia imagen,
        # todo lo que se sincronice contra el sale corrido igual, por muy bien
        # que case la medida entre pistas.
        # Se mide con la MISMA pista de referencia que usa la correlacion
        # (b["index"]), asi los dos numeros hablan del mismo audio.
        if quiere_voz:
            try:
                m["voz"] = remuxlib.medir_voz_contra_subs(b["path"], int(b["index"]))
            except Exception as e:
                m["voz"] = {"ok": False, "error": str(e)}
        # Duraciones muy distintas = probablemente montajes distintos. El ajuste
        # lineal puede salir limpio y el contenido divergir igualmente (una escena
        # cortada no es una deriva), asi que se avisa aparte.
        try:
            d0 = remuxlib.probe(b["path"])["duration"]
            d1 = remuxlib.probe(s["path"])["duration"]
            m["dur_base"], m["dur_src"] = round(d0, 1), round(d1, 1)
            if abs(d0 - d1) > 3.0:
                m["recommend"]["text"] += (
                    "  ATENCION: los dos ficheros duran distinto (%.1f s vs %.1f s). "
                    "Puede que sean montajes diferentes; un desfase fijo no arregla "
                    "escenas anadidas o cortadas." % (d0, d1))
                if m["recommend"]["level"] == "ok":
                    m["recommend"]["level"] = "warn"
        except Exception:
            pass
        return jsonify(m)
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.route("/api/remux/add", methods=["POST"])
def remux_add():
    j = request.json or {}
    vid = j.get("video") or {}
    trk = j.get("tracks") or []
    name = (j.get("output") or "").strip()
    if not vid.get("path") or not name:
        return jsonify({"error": "faltan video u output"}), 400
    if not name.lower().endswith(".mkv"):
        name += ".mkv"
    out = os.path.join(DONE_DIR, os.path.basename(name))
    if os.path.exists(out):
        return jsonify({"error": "ya existe %s" % os.path.basename(out)}), 400

    jid = uuid.uuid4().hex
    remux_jobs[jid] = {
        "id": jid, "status": "queued", "output": out,
        "name": os.path.basename(out),
        "video": {"path": vid["path"], "index": int(vid.get("index", 0))},
        "tracks": trk, "log": [], "last_log": "en cola",
        "phase": None, "pct": None,
        # Al terminar, mandar la salida al pipeline de video (ver remux_worker).
        "encode_after": bool(j.get("encode_after")),
        "added": time.time(),
    }
    with remux_lock_t:
        remux_queue.append(jid)
    remux_ensure_worker()
    return jsonify({"ok": True, "id": jid})


@app.route("/api/remux/status")
def remux_status():
    # PODA. remux_jobs no se vaciaba nunca: cada trabajo se quedaba ahi con su log
    # entero (cientos de lineas) hasta reiniciar el panel, y el panel vive
    # semanas. Se conservan los 40 mas recientes -el doble de los 20 que se
    # enseñan- y nunca se tira uno que siga vivo.
    if len(remux_jobs) > 40:
        vivos = {"queued", "waiting", "running"}
        viejos = sorted((j for j in remux_jobs.values() if j["status"] not in vivos),
                        key=lambda x: x["added"], reverse=True)[40:]
        for j in viejos:
            remux_jobs.pop(j["id"], None)
    jobs = sorted(remux_jobs.values(), key=lambda x: x["added"], reverse=True)[:20]
    return jsonify({"jobs": [{
        "id": j["id"], "name": j["name"], "status": j["status"],
        "last_log": j.get("last_log", ""), "error": j.get("error", ""),
        "phase": j.get("phase"), "pct": j.get("pct"),
        "log": j.get("log", [])[-40:],
        "log_file": j.get("log_file", ""),   # fichero persistente en encode_logs
    } for j in jobs], "busy": _remux_pipeline_busy()})


# ══════════════════════════════════════════════════════════════════════════════
# SANEAR: dejar UNA pelicula lista para entrar en la biblioteca.
#
# Toda la logica vive en sanear.ps1, no aqui, y eso es deliberado: ese script lo
# llaman TAMBIEN el final de un remux normal y la linea de comandos, y las reglas
# de "que pista es la castellana" o "que se recorta" salen de audio_plan.py, que
# es el mismo codigo que decide en la cola de la biblioteca. El panel solo lanza
# y enseña.
# ══════════════════════════════════════════════════════════════════════════════
SANEAR_PS   = r"C:\scripts\sanear.ps1"
SANEAR_STAT = os.path.join(TMP, "sanear_status")
sanear_estado = {"corriendo": False, "res": None, "path": ""}


def _sanear_json_tmp():
    return os.path.join(TMP, "sanear_res_%s.json" % uuid.uuid4().hex[:8])


# Tope de vida de sanear.ps1. NO estaba, y aqui se paga caro (02/09/2026): esta
# funcion la llama TAMBIEN remux_worker, dentro del try cuyo finally suelta el
# pipeline.lock. Un sanear.ps1 colgado no bloqueaba solo el remux: se quedaba con
# el lock PARA SIEMPRE, o sea con los tres watchers -video, audio y subtitulos-
# parados y sin un solo mensaje que lo explicara.
#
# La llamada llevaba 'timeout=None' escrito a mano. Eso no es "sin tope" por
# descuido: es indistinguible de un tope puesto, y ademas ENGANIABA al auditor
# (pruebas/auditar-python.py solo miraba si la palabra 'timeout' estaba, no su
# valor). Corregido tambien alli.
#
# 7200 s = 4 veces el peor caso MEDIDO. La reconstruccion del contenedor de un 4K
# son ~30 min (la misma que mide subs_status), y encode.ps1 registro 13,6 y 19,6
# min en sus dos casos. No es un tope de rendimiento, es un cortafuegos.
SANEAR_MAX_S = 7200


def _sanear_lanzar(path, analizar):
    """Ejecuta sanear.ps1 y devuelve su JSON. Bloquea; el llamante decide si va
    en un hilo."""
    dst = _sanear_json_tmp()
    cmd = [PWSH, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SANEAR_PS,
           "-File", path, "-Json", dst]
    if analizar:
        cmd.append("-Analizar")
    try:
        # Popen y NO subprocess.run(timeout=...) a proposito: al vencer el plazo,
        # subprocess.run mata SOLO al hijo directo, que aqui es pwsh.exe. Los que
        # trabajan de verdad -mkvmerge, ffmpeg- son NIETOS y se quedarian
        # huerfanos escribiendo. Es el mismo motivo por el que remux_cancel usa
        # _kill_pid (taskkill /T) en vez de p.terminate().
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True,
                             errors="replace", creationflags=_NO_WINDOW)
        try:
            p.communicate(timeout=SANEAR_MAX_S)
        except subprocess.TimeoutExpired:
            _kill_pid(p.pid)
            try:
                p.communicate(timeout=60)
            except Exception:
                pass
            raise RuntimeError(
                "sanear.ps1 no termino en %d s y se ha matado junto con sus "
                "procesos hijos. El fichero NO se ha tocado mas alla de lo que "
                "hubiera hecho hasta ahi; revisalo antes de volver a lanzarlo."
                % SANEAR_MAX_S)
        with open(dst, encoding="utf-8") as fh:
            res = json.load(fh)
    except Exception as e:
        res = {"ok": False, "file": path, "motivo": "no se pudo ejecutar: %s" % e,
               "acciones": [], "avisos": []}
    finally:
        try: os.remove(dst)
        except OSError: pass
    return res


@app.route("/api/sanear/analizar", methods=["POST"])
def sanear_analizar():
    path = ((request.json or {}).get("path") or "").strip()
    if not path:
        return jsonify({"ok": False, "motivo": "falta la ruta"}), 400
    return jsonify(_sanear_lanzar(path, True))


@app.route("/api/sanear/run", methods=["POST"])
def sanear_run():
    path = ((request.json or {}).get("path") or "").strip()
    if not path:
        return jsonify({"ok": False, "motivo": "falta la ruta"}), 400
    if sanear_estado["corriendo"]:
        return jsonify({"ok": False, "motivo": "ya hay un saneado en marcha"}), 409

    def _hilo():
        try:
            sanear_estado["res"] = _sanear_lanzar(path, False)
        finally:
            sanear_estado["corriendo"] = False

    sanear_estado.update(corriendo=True, res=None, path=path)
    threading.Thread(target=_hilo, daemon=True).start()
    return jsonify({"ok": True})


@app.route("/api/sanear/status")
def sanear_status():
    d = {"corriendo": sanear_estado["corriendo"], "path": sanear_estado["path"],
         "res": sanear_estado["res"], "stage": "", "pct": 0}
    # El script escribe su progreso en el mismo formato clave=valor que el resto.
    try:
        with open(SANEAR_STAT, encoding="utf-8") as fh:
            for ln in fh:
                if "=" in ln:
                    k, v = ln.strip().split("=", 1)
                    if k in ("stage", "pct"):
                        d[k] = v
    except OSError:
        pass
    return jsonify(d)


@app.route("/api/remux/cancel/<job_id>", methods=["POST"])
def remux_cancel(job_id):
    j = remux_jobs.get(job_id)
    if not j:
        return jsonify({"error": "no existe"}), 404
    j["cancel"] = True
    with remux_lock_t:
        if job_id in remux_queue:
            remux_queue.remove(job_id)
            j["status"] = "cancelled"
    # Matar el proceso en curso Y SU ARBOL. Marcar el flag no basta: solo se mira
    # ENTRE pasos, asi que un mkvmerge con 20 GB escritos seguia hasta el final.
    #
    # Y NO VALE p.terminate() (20/08/2026): mata SOLO al hijo directo, que en la
    # rama de conversion es pwsh.exe. Los que trabajan de verdad -truehdd.exe y
    # dee.exe- son NIETOS, y se quedaban huerfanos comiendose un nucleo durante
    # el resto de la conversion (que es de HORAS: ver dee-atmos-un-nucleo-sin-gpu)
    # con el panel dando el trabajo por cancelado. Lo mismo con el OCR, donde el
    # que trabaja es un dotnet nieto de pwsh.
    # _kill_pid usa 'taskkill /T', que es justo para esto y ya se usa en el resto
    # del panel (Stop y Skip del encoder, cancelar audio, cancelar subs).
    p = j.get("proc")
    if p is not None:
        try:
            _kill_pid(p.pid)
        except Exception:
            pass
    return jsonify({"ok": True})


# ══════════════════════════════════════════════════════════════════════════════
# MAIN ROUTE
# ══════════════════════════════════════════════════════════════════════════════
def _static_v(nombre):
    """Marca de version de un fichero de static/: su fecha de modificacion.

    POR QUE EXISTE (31/08/2026). El CSS y el JavaScript vivian INCRUSTADOS en
    index.html, y esa pagina se sirve con 'Cache-Control: no-store', asi que
    cualquier cambio se veia con solo recargar. Al sacarlos a static/ eso deja
    de ser cierto: un fichero estatico SI se cachea, y sin esta marca el
    navegador seguiria sirviendo el JavaScript viejo despues de cada edicion.

    Eso habria sido un paso atras, y ademas del tipo peor: no da error, no
    avisa, simplemente el panel ignora lo que acabas de escribir. Ya paso algo
    parecido con la plantilla cacheada, que obligaba a Ctrl+Shift+R para ver
    cualquier cambio.

    Con la fecha en el ?v=, el navegador cachea mientras el fichero no cambia y
    pide uno nuevo en cuanto cambia. No hay que acordarse de nada.

    Devuelve 0 si el fichero no esta: la pagina se sirve igual (rota, pero
    visible) en vez de tumbar el panel entero por un static que falta.
    """
    try:
        return int(os.path.getmtime(os.path.join(app.static_folder, nombre)))
    except OSError:
        return 0


@app.route("/")
def index():
    resp = make_response(render_template(
        "index.html",
        v_css=_static_v("panel.css"),
        v_js=_static_v("panel.js"),
    ))
    resp.headers["Cache-Control"] = "no-store"
    return resp

# ══════════════════════════════════════════════════════════════════════════════
# PERSISTENCIA DE LAS COLAS  (17/08/2026)
# ══════════════════════════════════════════════════════════════════════════════
# Las colas de remux y de yt-dlp vivian SOLO en memoria, y el panel se reinicia a
# menudo (los imports de Python no recargan en caliente, ver
# reiniciar-panel-cargar-codigo): cada reinicio perdia todo lo encolado sin decir
# nada. Diez trabajos preparados a mano desaparecian y el usuario no se enteraba
# hasta ir a mirar.
#
# POR QUE UN GUARDADO PERIODICO Y NO EN CADA MUTACION: las colas se tocan en una
# docena de sitios (append, pop, remove, cambios de estado en los dos workers).
# Hookear los doce es la forma segura de olvidarse de uno; un hilo que serializa
# el estado cada pocos segundos no puede olvidarse de nada. El coste es perder
# como mucho unos segundos de cambios si se corta la luz, que es irrelevante
# comparado con perder la cola entera en cada reinicio voluntario.
#
# QUE SE RESTAURA Y QUE NO:
#   - 'queued' / 'pending'  -> se restauran tal cual: no habian empezado.
#   - 'running' / 'downloading' -> NO se reanudan. El panel murio a mitad, y hay
#     una salida PARCIAL en disco. Se marcan como error explicando lo que paso y
#     el usuario decide; reanudar a ciegas chocaria con ese fichero a medias.
#     Tampoco se BORRA nada: destruir ficheros del usuario sin permiso, no.
QUEUES_FILE = os.path.join(TMP, "panel_queues.json")
# Firma de lo ultimo escrito, para no reescribir el fichero cuando nada ha
# cambiado. El hilo despierta cada 4 s y el panel esta encendido todo el dia: sin
# esto son ~21.600 escrituras diarias de un fichero que casi siempre dice
# exactamente lo mismo (con las colas vacias, 83 bytes). No es un problema de
# desgaste -ver salud-discos-smart- sino de ruido: un fichero cuya fecha cambia
# cada 4 s no sirve para saber CUANDO cambio la cola de verdad.
_queues_sig = None


def _queues_save():
    global _queues_sig
    try:
        with remux_lock_t:
            rq = list(remux_queue)
            # Solo los jobs que la cola referencia, y sin el log entero (puede
            # tener miles de lineas y esto se escribe cada pocos segundos).
            rj = {}
            for jid in rq:
                j = remux_jobs.get(jid)
                if j:
                    # Fuera 'log' (miles de lineas, y esto se escribe a menudo) y
                    # fuera 'proc': es un objeto Popen, que json NO sabe
                    # serializar. Hoy no llega aqui ninguno -un trabajo con proc
                    # ya salio de la cola- pero si algun dia llegara, la excepcion
                    # la tragaria el except de abajo y el guardado dejaria de
                    # funcionar EN SILENCIO, que es justo lo que no queremos de un
                    # mecanismo cuyo unico trabajo es no perder la cola.
                    rj[jid] = {k: v for k, v in j.items() if k not in ("log", "proc")}
        with ytdlp_lock:
            yq = [dict(j) for j in ytdlp_queue if j.get("status") == "pending"]
        datos = {"v": 1, "remux": {"queue": rq, "jobs": rj}, "ytdlp": yq}
        # La firma se calcula SIN el 'ts', que cambia siempre y haria que nada
        # pareciera nunca igual. El 'ts' se anyade despues, solo si se escribe.
        cuerpo = json.dumps(datos, ensure_ascii=False, sort_keys=True)
        if cuerpo == _queues_sig:
            return
        datos["ts"] = time.time()
        tmp = QUEUES_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(datos, fh, ensure_ascii=False)
        os.replace(tmp, QUEUES_FILE)      # atomico: nunca deja un JSON a medias
        _queues_sig = cuerpo
    except Exception:
        pass                              # nunca tumbar el panel por esto


def _queues_load():
    """Restaura al arrancar. Best-effort: si el fichero esta roto, se ignora."""
    try:
        if not os.path.isfile(QUEUES_FILE):
            return
        with open(QUEUES_FILE, encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception:
        return

    n_rest, n_int = 0, 0
    try:
        for jid in (d.get("remux", {}).get("queue") or []):
            j = (d.get("remux", {}).get("jobs") or {}).get(jid)
            if not j:
                continue
            j.setdefault("log", [])
            est = j.get("status")
            # 'waiting' ENTRA AQUI desde el 19/08/2026, y su ausencia era un
            # agujero grande: un trabajo pasa a 'waiting' -sin salir de la cola-
            # cada vez que el pipeline esta ocupado o hay pausa global (ver el
            # bucle del worker), o sea la MAYOR PARTE del tiempo. Como no casaba
            # con ninguna rama, al reiniciar el panel se caia por el desague:
            # ni restaurado, ni marcado como error, ni contado en el aviso de
            # "restaurados N". Desaparecia en silencio.
            # Es equivalente a 'queued' a todos los efectos: no ha empezado nada
            # (el pop de la cola va DESPUES de coger el lock) y no hay ninguna
            # salida a medias en disco. Se restaura tal cual.
            if est in ("queued", "waiting", "running"):
                if est == "running":
                    # Murio a mitad: no se reanuda, se avisa.
                    j["status"] = "error"
                    j["error"] = ("el panel se reinicio mientras este trabajo "
                                  "corria; la salida quedo a medias. Revisa "
                                  "%s y vuelve a encolarlo si hace falta."
                                  % os.path.basename(j.get("output", "")))
                    j["last_log"] = "interrumpido por reinicio del panel"
                    remux_jobs[jid] = j
                    n_int += 1
                    continue
                j["status"] = "queued"
                j["last_log"] = "en cola (restaurado tras reiniciar el panel)"
                remux_jobs[jid] = j
                remux_queue.append(jid)
                n_rest += 1
            elif est in ("done", "error", "warn", "cancelled"):
                # TERMINADOS. No hay nada que restaurar y no son ningun problema:
                # se dejan caer sin ruido. (Siguen en el fichero porque _queues_save
                # guarda la cola entera; el worker los saca al terminar, asi que
                # como mucho sobrevive el ultimo.)
                continue
            else:
                # Estado que NO conocemos. No se tira en silencio: eso es justo lo
                # que le pasaba a 'waiting' y por eso nadie lo vio en semanas. Se
                # conserva visible en el panel para que el usuario decida.
                j["status"] = "error"
                j["error"] = ("estado '%s' desconocido al restaurar la cola; "
                              "vuelve a encolarlo si hace falta." % est)
                j["last_log"] = "no restaurado tras reiniciar el panel"
                remux_jobs[jid] = j
                n_int += 1
        for j in (d.get("ytdlp") or []):
            if j.get("status") == "pending":
                ytdlp_queue.append(j)
                n_rest += 1
    except Exception:
        pass

    if n_rest:
        remux_ensure_worker()
        ytdlp_ensure_worker()
    if n_rest or n_int:
        print("[colas] restaurados %d en cola, %d interrumpidos por el reinicio"
              % (n_rest, n_int), flush=True)


def _queues_saver():
    while True:
        time.sleep(4)
        _queues_save()


_queues_load()
threading.Thread(target=_queues_saver, daemon=True).start()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
