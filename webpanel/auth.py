"""Acceso al panel: un usuario, contrasena con scrypt y sesiones en cookie.

El usuario y el hash viven en auth.json; las sesiones en sesiones.json. Los dos
estan en .gitignore: nada de esto llega al repo publico.

Las sesiones guardan el HASH del token, no el token: quien lea sesiones.json no
puede usar ninguna sesion. Cambiar la contrasena cierra todas las sesiones.
"""
import hashlib, hmac, json, os, secrets, threading, time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
RUTA_AUTH = os.environ.get("MEDIABOX_AUTH") or os.path.join(BASE_DIR, "auth.json")
RUTA_SESIONES = os.environ.get("MEDIABOX_SESIONES") or os.path.join(BASE_DIR, "sesiones.json")

COOKIE = "mb_sesion"
DURACION = 30 * 24 * 3600      # 30 dias, renovados con el uso
RENOVAR_CADA = 3600             # como mucho una escritura por hora y sesion
MAX_FALLOS = 5                  # intentos fallidos por IP...
VENTANA_FALLOS = 15 * 60        # ...en 15 minutos
CLAVE_MIN = 12
SCRYPT = {"n": 2 ** 15, "r": 8, "p": 1, "dklen": 32}

_lock = threading.Lock()
_fallos = {}


def hay_usuario():
    return os.path.isfile(RUTA_AUTH)


def _leer(ruta, por_defecto):
    try:
        with open(ruta, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return por_defecto


def _escribir(ruta, datos):
    tmp = ruta + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(datos, f)
    os.replace(tmp, ruta)


def _derivar(clave, salt, parametros):
    return hashlib.scrypt(clave.encode("utf-8"), salt=salt, maxmem=64 * 1024 * 1024, **parametros)


def crear_credencial(usuario, clave):
    salt = secrets.token_bytes(16)
    datos = {"usuario": usuario, "salt": salt.hex(), "scrypt": SCRYPT,
              "hash": _derivar(clave, salt, SCRYPT).hex()}
    _escribir(RUTA_AUTH, datos)


def comprobar(usuario, clave):
    d = _leer(RUTA_AUTH, None)
    if not d:
        return False
    h = _derivar(clave, bytes.fromhex(d["salt"]), d["scrypt"])
    ok_usuario = hmac.compare_digest(usuario.encode("utf-8"), d["usuario"].encode("utf-8"))
    ok_clave = hmac.compare_digest(h, bytes.fromhex(d["hash"]))
    return ok_usuario and ok_clave


def _sesiones():
    return _leer(RUTA_SESIONES, [])


def _guardar_sesiones(lista):
    _escribir(RUTA_SESIONES, lista)


def _hash_token(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def crear_sesion(ip, agente):
    token = secrets.token_urlsafe(32)
    ahora = time.time()
    with _lock:
        vivas = [s for s in _sesiones() if s["hasta"] > ahora]
        vivas.append({"id": _hash_token(token), "creada": ahora, "renovada": ahora,
                      "hasta": ahora + DURACION, "ip": ip, "agente": (agente or "")[:120]})
        _guardar_sesiones(vivas)
    return token


def validar_sesion(token):
    if not token:
        return False
    h = _hash_token(token)
    ahora = time.time()
    with _lock:
        lista = _sesiones()
        ok = False
        cambio = False
        for s in lista:
            if hmac.compare_digest(s["id"], h) and s["hasta"] > ahora:
                ok = True
                if ahora - s["renovada"] > RENOVAR_CADA:
                    s["renovada"] = ahora
                    s["hasta"] = ahora + DURACION
                    cambio = True
        vivas = [s for s in lista if s["hasta"] > ahora]
        if cambio or len(vivas) != len(lista):
            _guardar_sesiones(vivas)
    return ok


def revocar_sesion(token):
    if not token:
        return
    h = _hash_token(token)
    with _lock:
        _guardar_sesiones([s for s in _sesiones() if not hmac.compare_digest(s["id"], h)])


def revocar_todas():
    with _lock:
        _guardar_sesiones([])


def bloqueado(ip):
    ahora = time.time()
    recientes = [t for t in _fallos.get(ip, []) if ahora - t < VENTANA_FALLOS]
    _fallos[ip] = recientes
    return len(recientes) >= MAX_FALLOS


def registrar_fallo(ip):
    _fallos.setdefault(ip, []).append(time.time())


def limpiar_fallos(ip):
    _fallos.pop(ip, None)
