# -*- coding: utf-8 -*-
"""
audio_plan.py - Plan de recorte de audio de E:\\Peliculas.

LOS DATOS SALEN DE LOS FICHEROS, NO DE LOS SIDECARS.

  El `*-mediainfo.xml` se genera cuando la pelicula entra en la biblioteca, y si
  el fichero se sustituye despues, MIENTE. Medido el 28/08/2026 sobre
  'El senyor de los anillos: El retorno del rey':

      el sidecar declaraba 6 pistas de audio (2 + 4 comentarios) y Atmos;
      el fichero real tiene 2 pistas y ninguna con Atmos.

  Eso no es un detalle cosmetico: el plan alimenta a `-DropTracks`, que borra
  pistas POR INDICE. Con un listado desfasado, los indices apuntan a otra cosa.
  Por eso el sidecar solo se usa para UNA cosa -saber que esa carpeta es una
  pelicula catalogada y no un featurette- y todo el contenido se lee en vivo con
  `MediaInfo --Output=JSON` (0,07 s por pelicula).

Fases:
  1  inventario en vivo con MediaInfo (JSON) -> pistas, bitrate, idioma, subs
  1b barrido de Atmos con ffprobe sobre las que podrian caparse
     -> se capa SOLO si los DOS parsers dicen que no hay Atmos

Salidas:
  C:\\scripts\\audio_plan.json          -> para audio_recap.ps1
  C:\\scripts\\audio_descartes.csv      -> para revisar a mano
  C:\\scripts\\audio_mi_sweep.jsonl     -> checkpoint del inventario
  C:\\scripts\\audio_atmos_sweep.jsonl  -> checkpoint del barrido ffprobe

Uso:  python audio_plan.py
"""
import os, re, csv, json, sys, subprocess

# Las bibliotecas que se barren salen de mediabox_rutas.py: UNA definicion para
# los cuatro barredores (04/09/2026). Antes estaba copiada aqui, y una lista de
# raices incompleta no da error, da un numero mas pequenyo que parece bueno.
# El sys.path explicito NO sobra: pruebas/test-espejo-audio.ps1 carga ESTE
# fichero con importlib.spec_from_file_location, y por esa via C:\scripts no
# entra en sys.path -el import fallaria justo dentro de la suite-.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mediabox_rutas import RAICES

# Subcarpetas que SI son contenido. Todo lo demas que cuelgue de la carpeta de un
# titulo se ignora, y no es una lista a ojo: enumerando las 8 bibliotecas salen
# 'Other' (74), 'Featurettes' (38), 'Behind the scenes' (10) y 'Extras' (4) con
# video dentro -son extras- frente a 'Season N' y 'Specials', que son episodios.
RE_TEMPORADA = re.compile(r'^(season\b|temporada\b|specials$)', re.I)
# MediaInfo de CONSOLA. El de 'C:\Program Files\MediaInfo' es la GUI: abre una
# ventana y no escribe en stdout, asi que parece mudo cuando en realidad no se le
# ha preguntado. Comprobado por el subsistema del PE (3=consola, 2=ventana).
MEDIAINFO = r"C:\scripts\DEE\MediaInfo.exe"
FFPROBE   = r"C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffprobe.exe"
VIDEXT    = ('.mkv', '.mp4', '.m2ts', '.ts', '.mov')

PLAN_OUT  = r"C:\scripts\audio_plan.json"
CSV_OUT   = r"C:\scripts\audio_descartes.csv"
MI_SWEEP  = r"C:\scripts\audio_mi_sweep.jsonl"
FF_SWEEP  = r"C:\scripts\audio_atmos_sweep.jsonl"

# --- Constantes: SE LEEN DE atmos-lib.ps1, no se copian --------------------
# Antes estaban a fuego aqui con un comentario pidiendo "si alli cambian, aqui
# tambien", que es justo la clase de acuerdo que se rompe sin que nadie se
# entere. Ahora se parsean del fichero de verdad: si alguien toca la politica en
# atmos-lib.ps1, el plan la sigue sola.
ATMOS_LIB = r"C:\scripts\atmos-lib.ps1"

def _leer_constantes():
    por_defecto = {'MaxCopyAudioK': 448, 'MaxCopyAudioStereoK': 224,
                   'MinCopyAudioTriggerK': 640, 'MinCopyAudioTriggerStereoK': 320}
    try:
        txt = open(ATMOS_LIB, encoding='utf-8', errors='replace').read()
    except OSError:
        print(f"   AVISO: no se pudo leer {ATMOS_LIB}; se usan los valores por defecto")
        return por_defecto
    for nombre in list(por_defecto):
        m = re.search(r'^\s*\$' + nombre + r'\s*=\s*(\d+)', txt, re.M)
        if m:
            por_defecto[nombre] = int(m.group(1))
        else:
            print(f"   AVISO: no encuentro ${nombre} en atmos-lib.ps1; se usa {por_defecto[nombre]}")
    return por_defecto

_C = _leer_constantes()
MAX_MULTI_K     = _C['MaxCopyAudioK']
MAX_STEREO_K    = _C['MaxCopyAudioStereoK']
TRIG_MULTI_K    = _C['MinCopyAudioTriggerK']
TRIG_STEREO_K   = _C['MinCopyAudioTriggerStereoK']

# Cuanto mas eficiente es el E-AC-3 que el AC-3. Sale de la equivalencia que ya
# razona Get-CopyAudioCapK: 448k de DD+ suenan como 640k de AC-3 -> 640/448.
# Se usa para NO tirar un AC-3 que lleve mas ventaja que esa sobre el E-AC-3 con
# el que compite (ver la regla 2 de clasificar()).
EAC3_EQ = 640 / 448

ES = ('spa', 'es')

# --- Ajustes manuales del usuario (28/08/2026) -------------------------------
EXCLUIDAS = {
    # Perdio el Atmos en algun cambio de fichero (el nombre y los titulos de
    # pista aun lo anuncian). El usuario va a reinyectarlo desde un release con
    # TrueHD Atmos, asi que hasta entonces no se toca NADA de esta pelicula.
    'La comunidad del anillo': 'el usuario va a reinyectar el Atmos',
}

# Exclusiones que SE LEVANTAN SOLAS cuando la pelicula recupera el Atmos.
# Asi no hay que acordarse de venir a borrar la linea de arriba: en cuanto el
# fichero traiga una pista con Atmos de verdad, entra en el plan como cualquier
# otra (y sus pistas Atmos quedan protegidas por las guardas de siempre).
EXCLUIDAS_HASTA_ATMOS = ('La comunidad del anillo',)
VO_MANUAL = {
    'Scream 2 (1997)': 'eng',   # ingles y aleman empataban a 640k 5.1
    # Pelicula francesa ('Avril et le monde truque'): frances e ingles empataban
    # a 448k 5.1. Sin decidirlo, se habrian ido las dos y la pelicula se quedaba
    # solo con un castellano 2.0 de 224k.
    'Avril y el mundo alterado (2015)': 'fra',
}
FIX_LANG = {
    'Cometieron dos errores (1968)': {1: 'spa'},   # dice "Castellano", venia 'und'
}
LANGS_FUERA = ('cat', 'ca')     # el catalan no interesa

# Idioma por defecto del audio, y de los subtitulos forzados.
DEFAULT_LANG = 'spa'

ISO2 = {'es': 'spa', 'en': 'eng', 'fr': 'fra', 'de': 'deu', 'it': 'ita',
        'ja': 'jpn', 'ko': 'kor', 'zh': 'chi', 'pt': 'por', 'ru': 'rus',
        'ca': 'cat', 'eu': 'eus', 'gl': 'glg', 'nl': 'nld', 'sv': 'swe',
        'da': 'dan', 'no': 'nob', 'nb': 'nob', 'fi': 'fin', 'pl': 'pol',
        'ar': 'ara', 'he': 'heb', 'hi': 'hin', 'tr': 'tur', 'el': 'ell',
        'cs': 'ces', 'hu': 'hun', 'ro': 'ron', 'la': 'lat', 'is': 'isl',
        'th': 'tha', 'vi': 'vie', 'fa': 'fas', 'uk': 'ukr', 'bg': 'bul'}

def iso3(v):
    if not v:
        return 'und'
    v = str(v).lower().split('-')[0].strip()
    return ISO2.get(v, v if len(v) == 3 else 'und')

FMT2CODEC = {'E-AC-3': 'eac3', 'AC-3': 'ac3', 'AAC': 'aac', 'MPEG Audio': 'mp3',
             'DTS': 'dts', 'FLAC': 'flac', 'TrueHD': 'truehd', 'MLP FBA': 'truehd',
             'Opus': 'opus', 'Vorbis': 'vorbis', 'PCM': 'pcm'}


def cap_for(ch, bps, codec, profile):
    """Espejo EXACTO de Get-CopyAudioCapK (atmos-lib.ps1).

    Dos cosas que se hicieron mal en el primer intento y hubo que corregir:
      - el corte multicanal/estereo va en Ch > 2, NO en Ch >= 6;
      - la exencion del AC-3 se compara contra EL DISPARO QUE TOQUE (320k en
        estereo), no contra 640k fijo.
    'profile' vacio en un E-AC-3 = "no se ha podido comprobar" = no tocar.
    """
    # EL INTERRUPTOR GENERAL. Get-CopyAudioCapK arranca con
    #     if ($MaxMultiK -le 0) { return 0 }
    # que es el "0 = sin tope" que anuncia el comentario de $MaxCopyAudioK.
    # Al espejo le faltaba: con el tope desactivado, el plan habria seguido
    # proponiendo recortes y audio_recap.ps1 habria remuxeado ~600 peliculas
    # mientras el motor se negaba a capar ni una. No se pierde nada -la
    # verificacion lo caza con "no ha encogido"- pero son ~11 TB de I/O en balde.
    if MAX_MULTI_K <= 0:
        return 0
    if ch > 6 or bps <= 0:
        return 0
    prof = (profile or '').strip()
    if re.search(r'atmos|joc', prof, re.I):
        return 0
    if codec in ('eac3', 'ec-3', 'e-ac-3') and not prof:
        return 0
    tope    = MAX_MULTI_K  if ch > 2 else MAX_STEREO_K
    disparo = TRIG_MULTI_K if ch > 2 else TRIG_STEREO_K
    if codec == 'ac3' and bps <= disparo * 1000:
        return 0
    if bps >= disparo * 1000:
        return tope
    return 0

def podria_caparse(ch, bps, codec):
    return cap_for(ch, bps, codec, 'unknown') > 0

def _clave_manual(path, tabla):
    for k in tabla:
        if k in path:
            return tabla[k]
    return None

def _f(d, k, defecto=0.0):
    try:
        return float(str(d.get(k, defecto)).replace(',', '.'))
    except (TypeError, ValueError):
        return defecto


# --- Fase 1: inventario EN VIVO ----------------------------------------------
def _leer_mediainfo(path):
    r = subprocess.run([MEDIAINFO, '--Output=JSON', path],
                       capture_output=True, text=True, timeout=300,
                       encoding='utf-8', errors='replace')
    j = json.loads(r.stdout)
    pistas = j['media']['track']
    if isinstance(pistas, dict):
        pistas = [pistas]

    dur_gen = 0.0
    for t in pistas:
        if t.get('@type') == 'General':
            dur_gen = _f(t, 'Duration')
            break

    audio, subs, ia, isub = [], [], 0, 0
    for t in pistas:
        tipo = t.get('@type')
        if tipo == 'Audio':
            fmt  = t.get('Format', '')
            comm = t.get('Format_Commercial_IfAny', '') or ''
            addf = t.get('Format_AdditionalFeatures', '') or ''
            d = _f(t, 'Duration') or dur_gen
            audio.append(dict(
                i=ia, fmt=fmt, codec=FMT2CODEC.get(fmt, fmt.lower()),
                bps=int(_f(t, 'BitRate')), ch=int(_f(t, 'Channels')), dur=d,
                lang=iso3(t.get('Language')), title=(t.get('Title') or ''),
                default=(str(t.get('Default', '')).lower() == 'yes'),
                atmos_mi=bool(re.search(r'atmos', comm, re.I)
                              or re.search(r'joc|16-ch', addf, re.I)),
                profile=None, cap=0, drop=None))
            ia += 1
        elif tipo == 'Text':
            subs.append(dict(
                i=isub, lang=iso3(t.get('Language')), title=(t.get('Title') or ''),
                forced=(str(t.get('Forced', '')).lower() == 'yes'),
                default=(str(t.get('Default', '')).lower() == 'yes')))
            isub += 1
    return audio, subs


def inventario():
    """Recorre la biblioteca y lee CADA fichero con MediaInfo. Con checkpoint."""
    # El checkpoint SE REVALIDA contra tamanyo y fecha del fichero. Sin esto, una
    # pelicula ya procesada seguiria describiendose con sus pistas de ANTES, y el
    # plan propondria recortar lo que ya esta recortado (o peor: descartar por un
    # indice que ya no existe). Mismo criterio que la cache de .ec3.
    hecho = {}
    if os.path.exists(MI_SWEEP):
        with open(MI_SWEEP, encoding='utf-8') as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                    hecho[r['path']] = r
                except Exception:
                    pass
    def _vigente(path, rec):
        try:
            st = os.stat(path)
        except OSError:
            return False
        return (rec.get('size') == st.st_size
                and abs(rec.get('mtime', 0) - st.st_mtime) < 2)
    hecho = {p: r for p, r in hecho.items() if _vigente(p, r)}

    # DESCUBRIMIENTO POR ESTRUCTURA, NO POR SIDECAR.
    #
    # Antes se buscaban las peliculas por su '*-mediainfo.xml', y eso tenia un
    # agujero que solo se ve al ejecutar: audio_recap.ps1 BORRA el sidecar al
    # terminar (para que no queden bitrates viejos declarados), asi que una
    # pelicula ya procesada DESAPARECIA del inventario y no se le podia aplicar
    # ninguna correccion posterior. Se detecto porque las tres primeras del
    # piloto se quedaron sin la bandera 'default' y el plan ya no las veia.
    #
    # Ahora se localizan por estructura: fichero de video colgando DIRECTAMENTE
    # de una carpeta 'Titulo (Anyo)'. Los extras viven en subcarpetas
    # (featurettes, Other, extrathumbs...) y quedan fuera solos.
    # Ya NO se exige que la carpeta acabe en '(Anyo)': en Docupelis hay titulos
    # sin anyo ("20 Anyos De Futbol En Canal Plus") que se quedaban fuera.
    objetivos = []
    for raiz in RAICES:
        if not os.path.isdir(raiz):
            print(f"   AVISO: no existe {raiz}")
            continue
        for entrada in sorted(os.listdir(raiz)):
            carpeta = os.path.join(raiz, entrada)
            if not os.path.isdir(carpeta):
                continue
            for f in sorted(os.listdir(carpeta)):
                p = os.path.join(carpeta, f)
                if os.path.isfile(p):
                    if f.lower().endswith(VIDEXT):
                        objetivos.append(p)
                elif RE_TEMPORADA.match(f):
                    # Episodios de una temporada (o los 'Specials').
                    for g in sorted(os.listdir(p)):
                        q = os.path.join(p, g)
                        if os.path.isfile(q) and g.lower().endswith(VIDEXT):
                            objetivos.append(q)

    pend = [p for p in objetivos if p not in hecho]
    print(f"inventario en vivo: {len(objetivos)} peliculas, {len(hecho)} ya leidas, {len(pend)} pendientes")
    with open(MI_SWEEP, 'a', encoding='utf-8') as fh:
        for n, path in enumerate(pend, 1):
            try:
                audio, subs = _leer_mediainfo(path)
            except Exception as e:
                # NO SE CACHEA UN FALLO DE LECTURA (01/09/2026). Antes se
                # guardaba igualmente un registro con tracks=[], y el checkpoint
                # solo se revalida por tamanyo y fecha: un fallo TRANSITORIO
                # -MediaInfo no puede abrir el fichero porque algo lo esta
                # copiando- dejaba esa pelicula fuera de TODOS los planes
                # futuros, para siempre y sin volver a avisar.
                #
                # Se distingue "no tiene audio" (registro legitimo, se cachea)
                # de "no se pudo leer" (no se cachea, se reintenta la proxima).
                # Comprobado el 01/09/2026: los 15 cacheados sin pistas que
                # habia NO tienen audio de verdad, asi que esto no ha llegado a
                # morder; es cerrar la puerta antes de que lo haga.
                print(f"   AVISO: no se pudo leer {os.path.basename(path)[:50]}: {e}")
                print("          no se cachea: se reintentara en la proxima pasada.")
                continue
            try:
                st = os.stat(path)
                sz, mt = st.st_size, st.st_mtime
            except OSError:
                sz, mt = 0, 0
            rec = {'path': path, 'tracks': audio, 'subs': subs, 'size': sz, 'mtime': mt}
            hecho[path] = rec
            fh.write(json.dumps(rec, ensure_ascii=False) + '\n')
            fh.flush()
            if n % 200 == 0 or n == len(pend):
                print(f"   {n}/{len(pend)}", flush=True)
    return [hecho[p] for p in objetivos if hecho.get(p, {}).get('tracks')]


# --- Fase 1b: Atmos con ffprobe ----------------------------------------------
def barrer_ffprobe(pelis):
    # Igual que el inventario: la clave lleva tamanyo y fecha. Si el fichero
    # cambio, el indice de pista puede referirse ya a OTRA pista y el profile
    # guardado seria de la equivocada.
    def _sig(path):
        try:
            st = os.stat(path)
            return f"{st.st_size}:{int(st.st_mtime)}"
        except OSError:
            return '?'
    hecho = {}
    if os.path.exists(FF_SWEEP):
        with open(FF_SWEEP, encoding='utf-8') as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                    if r.get('sig') == _sig(r['path']):
                        hecho[(r['path'], r['i'])] = r['profile']
                except Exception:
                    pass
    pend = []
    for p in pelis:
        for t in p['tracks']:
            if podria_caparse(t['ch'], t['bps'], t['codec']):
                k = (p['path'], t['i'])
                if k in hecho:
                    t['profile'] = hecho[k]
                else:
                    pend.append((p, t))
    print(f"barrido ffprobe: {len(hecho)} ya hechas, {len(pend)} pendientes")
    with open(FF_SWEEP, 'a', encoding='utf-8') as fh:
        for n, (p, t) in enumerate(pend, 1):
            try:
                # csv=p=0 y NO json: el JSON de ffprobe OMITE 'profile' cuando
                # vale 'unknown', que es justo el caso que hay que distinguir de
                # "no se ha podido comprobar".
                out = subprocess.run(
                    [FFPROBE, '-v', 'error', '-select_streams', f"a:{t['i']}",
                     '-show_entries', 'stream=profile', '-of', 'csv=p=0', p['path']],
                    capture_output=True, text=True, timeout=180)
                t['profile'] = out.stdout.strip()
            except Exception:
                t['profile'] = ''
            fh.write(json.dumps({'path': p['path'], 'i': t['i'], 'sig': _sig(p['path']),
                                 'profile': t['profile']}, ensure_ascii=False) + '\n')
            fh.flush()
            if n % 100 == 0 or n == len(pend):
                print(f"   {n}/{len(pend)}", flush=True)
    return pelis


# --- Clasificacion de descartes ----------------------------------------------
RE_COMENT  = re.compile(r"coment|commentary|isolated\s*score|score\s+only|making\s*of|"
                        r"entrevista|interview|featurette|behind\s+the\s+scenes", re.I)
RE_PROTEGE = re.compile(r"doblaje|redoblaje|redob|latino|castellano|neutro|original|v\.?o\.?", re.I)
# Titulos que delatan OTRA MEZCLA, no la misma pista en peor calidad.
RE_MEZCLA  = re.compile(r"doblaje|redoblaje|redob|latino|neutro|original|v\.?o\.?|"
                        r"theatrical|teatral|mono\b|\b(?:19|20)\d{2}\b", re.I)

RE_LATINO     = re.compile(r"latino|neutro|hispanoam|mexic|\bLAT\b", re.I)
RE_CASTELLANO = re.compile(r"castellano|espa[nñ]a|\bCAST\b|\bESP\b", re.I)

def variante(titulo):
    """Que DOBLAJE es, dentro del mismo idioma.

    El castellano y el latino van los dos etiquetados 'spa' en el contenedor, de
    modo que por idioma y canales son indistinguibles. Sin separarlos, la regla
    de duplicados los toma por la misma pista en dos codecs y tira uno de los dos
    doblajes -que es justo lo que el usuario pidio conservar-.

    Devuelve 'latino', 'castellano' o None (sin marca en el titulo, se compara
    con los demas que tampoco la tengan).
    """
    t = titulo or ''
    if RE_LATINO.search(t):
        return 'latino'
    if RE_CASTELLANO.search(t):
        return 'castellano'
    return None


def es_atmos(t):
    """Atmos por CUALQUIERA de los dos parsers en vivo. Nunca se descarta ni capa."""
    if t.get('profile') and re.search(r'atmos|joc', t['profile'], re.I):
        return True
    return bool(t.get('atmos_mi'))


def clasificar(p):
    ts = p['tracks']
    # EL ATMOS NO SE TOCA NUNCA, ni se ofrece a revision.
    protegidas = {t['i'] for t in ts if es_atmos(t)}

    # 1) comentarios y extras, por titulo
    vivos = []
    for t in ts:
        if t['title'] and RE_COMENT.search(t['title']) and not RE_PROTEGE.search(t['title']):
            t['drop'] = 'comentario'
        else:
            vivos.append(t)

    # 2) duplicado de CODEC: mismo idioma y mismos canales en E-AC-3 y AC-3.
    #
    # SE MIRA EL BITRATE, no solo el codec (28/08/2026). La version anterior
    # tiraba el AC-3 siempre, y medido sobre este mismo plan eso perdia calidad
    # de verdad en 5 peliculas, las cinco EN CASTELLANO:
    #     La sirenita (1989)  AC-3 640k 6ch  ->  se quedaba el E-AC-3 de 256k
    #     The Fare (2018)     AC-3 448k 2ch  ->  se quedaba el E-AC-3 de 128k
    # El E-AC-3 es mas eficiente, pero solo hasta EAC3_EQ. Por encima de esa
    # ventaja el AC-3 lleva mas informacion y descartarlo es degradar.
    # No se decide aqui cual sobra: se manda a REVISAR y lo mira una persona,
    # que es como ya se tratan los casos dudosos de VO. audio_recap.ps1 excluye
    # los REVISAR por defecto, asi que mientras tanto NO se borra nada.
    # Y SE AGRUPA TAMBIEN POR VARIANTE DE DOBLAJE, no solo por idioma y canales.
    # 'Latino' y 'Castellano' van los dos etiquetados 'spa', asi que sin esto se
    # tratan como la misma pista en dos codecs y uno de los DOBLAJES se pierde.
    # Visto en 'La sirenita (1989)', que trae los dos: el Latino AC-3 640k caia
    # por "duplicar" al Castellano E-AC-3 256k, con el que no tiene nada que ver.
    # No vale reutilizar RE_PROTEGE aqui: casa con "Castellano", que sale en casi
    # todos los titulos espanyoles y no distingue un doblaje de otro (medido: los
    # 3 casos que marcaba eran duplicados legitimos del mismo doblaje).
    por = {}
    for t in vivos:
        por.setdefault((t['lang'], t['ch'], variante(t['title'])), []).append(t)
    for _k, g in por.items():
        eac = [t for t in g if t['codec'] == 'eac3']
        ac  = [t for t in g if t['codec'] == 'ac3']
        if eac and ac:
            # SE CONSERVA LA MEJOR, SEA DEL CODEC QUE SEA, y caen las demas.
            #
            # Decision del usuario (28/08/2026): dentro de un mismo doblaje sobra
            # una, y la que se queda es la que mas informacion lleva. Antes esto
            # se mandaba a REVISAR, y REVISAR significa "no tocar": la pelicula
            # se quedaba con las DOS pistas, que es justo lo que se queria
            # evitar. Solo pasaba en 3 peliculas de 96 parejas, pero eran las 3
            # en las que el AC-3 era mejor -en 'The Fare', 448k contra 128k-.
            #
            # Para comparar hay que llevarlos a la misma escala: un E-AC-3 rinde
            # EAC3_EQ veces mas que un AC-3 al mismo numero. A igualdad gana el
            # E-AC-3, que es la preferencia de partida.
            # Solo compiten ac3 y eac3: un AAC del mismo grupo no se toca aqui.
            equiv = lambda t: (t['bps'] * EAC3_EQ if t['codec'] == 'eac3' else t['bps'])
            cand  = eac + ac
            mejor = max(cand, key=lambda t: (equiv(t), t['codec'] == 'eac3'))
            for t in cand:
                if t is mejor:
                    continue
                t['drop'] = 'dup_ac3' if t['codec'] == 'ac3' else 'dup_eac3_peor'
    vivos = [t for t in vivos if not t['drop']]

    # 3) "si hay version 5.1 o superior del mismo idioma/MEZCLA, borra la
    #    mono/estereo". La condicion es doble: se exceptua lo que el titulo
    #    delata como otra mezcla (teatral, mono de epoca, doblaje distinto).
    for lang in {t['lang'] for t in vivos}:
        g = [t for t in vivos if t['lang'] == lang and t['i'] not in protegidas]
        if not any(t['ch'] >= 6 for t in g):
            continue
        for t in g:
            if t['ch'] <= 2 and not t['drop'] and not RE_MEZCLA.search(t['title'] or ''):
                t['drop'] = 'dup_canales'
    vivos = [t for t in vivos if not t['drop']]

    # 4) idiomas: dejar solo el original y el castellano.
    idiomas = {t['lang'] for t in vivos if t['lang'] != 'und'}
    if len(idiomas) >= 3:
        for t in vivos:
            if not t['drop'] and t['lang'] in LANGS_FUERA:
                t['drop'] = 'idioma_no_interesa'
        resto = [t for t in vivos if not t['drop'] and t['lang'] not in ES and t['lang'] != 'und']
        if len(resto) > 1:
            clave = lambda t: (t['ch'], t['bps'])
            top = max(clave(t) for t in resto)
            empatan = [t for t in resto if clave(t) == top]
            vo_man = _clave_manual(p['path'], VO_MANUAL)
            if len(empatan) > 1 and not vo_man:
                for t in resto:
                    t['drop'] = 'REVISAR:cual_es_la_VO'
            else:
                # DOS DOBLAJES DEL MISMO IDIOMA NO SON DUPLICADOS (28/08/2026).
                # La regla 3 ya se protege con RE_MEZCLA; esta no lo hacia, y por
                # eso se llevaba el doblaje ORIGINAL de Akira
                #     a:3 'English 2.0 (Doblaje Original Streamline - 1988)'
                # para quedarse con el redoblaje Pioneer de 2001, que solo gana
                # en canales y bitrate. Eso no es elegir calidad, es cambiar la
                # interpretacion, y no se decide por bitrate.
                #
                # La guarda pide DOS cosas, no una: que el titulo delate otra
                # mezcla Y que quede otra pista del MISMO idioma. Si es el unico
                # representante de su lengua, la decision sigue siendo cual es la
                # VO -para eso esta esta regla- y ahi el titulo no la exime.
                multi = {l for l in {t['lang'] for t in resto}
                         if sum(1 for t in resto if t['lang'] == l) > 1}
                for t in resto:
                    if (t['lang'] != vo_man) if vo_man else (clave(t) != top):
                        if t['lang'] in multi and RE_MEZCLA.search(t['title'] or ''):
                            # Sin 'drop': se queda en el fichero y sigue pudiendo
                            # ser la pista por defecto. 'nota' es solo la traza.
                            t['nota'] = 'se conserva: otro doblaje del mismo idioma'
                            continue
                        t['drop'] = 'dub_secundario'
        for t in vivos:
            if not t['drop'] and t['lang'] == 'und' and len(vivos) > 2:
                t['drop'] = 'REVISAR:und'

    # La guarda, aplicada al final: cualquier regla que marque una pista con
    # Atmos queda anulada, incluidas las que se anyadan en el futuro.
    for t in ts:
        if t['i'] in protegidas and t['drop']:
            t['drop'] = None
    return ts


def preparar(pelis):
    """Todo lo que convierte una lectura cruda de MediaInfo en un plan: idiomas
    corregidos, bitrates imposibles a 0, Atmos por ffprobe, techo, clasificacion
    de descartes, exclusiones y banderas por defecto.

    SE SEPARO DE main() el 29/08/2026 para que la pestana de saneado del panel
    pueda pedir el plan de UN fichero sin duplicar una sola de estas reglas.
    Duplicarlas era el camino seguro a que la peli que entra por el panel se
    trate distinto que la que entra por la cola.
    """

    for p in pelis:
        fix = _clave_manual(p['path'], FIX_LANG)
        if fix:
            for t in p['tracks']:
                if t['i'] in fix and t['lang'] != fix[t['i']]:
                    print(f"   [fix] {os.path.basename(p['path'])[:44]} a:{t['i']} "
                          f"'{t['lang']}' -> '{fix[t['i']]}'")
                    t['lang'] = fix[t['i']]
                    t['fix_lang'] = fix[t['i']]

    # BITRATES DISPARATADOS. MediaInfo devolvio bps=533.271.042.860 -533 Gbps- en
    # una pista AAC estereo de un episodio de 0,31 GiB, y eso por si solo inflaba
    # la estimacion del lote a 86.000 GiB de "ahorro". Un audio no pasa de ~10
    # Mbps ni sin comprimir, y ademas una pista no puede pesar mas que su
    # fichero. Con el dato en duda se pone bps=0, que es exactamente lo que hace
    # el motor cuando no hay tag BPS: NO TOCAR la pista.
    malos = 0
    for p in pelis:
        try:
            fsz = os.path.getsize(p['path'])
        except OSError:
            fsz = 0
        for t in p['tracks']:
            if not t['bps']:
                continue
            implica = t['bps'] * t['dur'] / 8 if t['dur'] else 0
            if t['bps'] > 50_000_000 or (fsz and implica > fsz * 1.5):
                t['bps_descartado'] = t['bps']
                t['bps'] = 0
                malos += 1
    if malos:
        print(f"   {malos} pista(s) con bitrate imposible -> se dejan sin tocar")

    pelis = barrer_ffprobe(pelis)

    for p in pelis:
        for t in p['tracks']:
            t['cap'] = cap_for(t['ch'], t['bps'], t['codec'], t['profile'])
            # BASTA CON QUE UNO DE LOS DOS PARSERS VEA ATMOS.
            #
            # cap_for solo mira el 'profile' de ffprobe, y no es suficiente: en
            # 'La Patrulla Canina: La superpelicula' MediaInfo declara Atmos en
            # a:1 y ffprobe devuelve 'unknown'. Sin este veto esa pista se habria
            # recodificado a 448k perdiendo los objetos, en silencio y sin vuelta
            # atras. Al reves tambien pasa (ffprobe lo ve y MediaInfo no), asi
            # que la condicion es OR, nunca AND.
            if t['cap'] and es_atmos(t):
                t['cap'] = 0
                t['nota'] = 'no se recorta: un parser ve Atmos aunque el otro no'
        clasificar(p)

    for p in pelis:
        motivo = _clave_manual(p['path'], EXCLUIDAS)
        # Si la exclusion era "hasta que recupere el Atmos" y ya lo tiene, se
        # levanta sola y la pelicula entra en el plan con normalidad.
        if motivo and any(f in p['path'] for f in EXCLUIDAS_HASTA_ATMOS):
            if any(es_atmos(t) for t in p['tracks']):
                print(f"   [reincorporada] {os.path.basename(p['path'])[:48]} -> ya tiene Atmos")
                motivo = None
        if motivo:
            for t in p['tracks']:
                t['cap'] = 0
                t['drop'] = None
            p['excluida'] = motivo
            print(f"   [excluida] {os.path.basename(p['path'])[:52]} -> {motivo}")

    # --- Disposiciones: una sola pista por defecto -----------------------
    for p in pelis:
        vivas = [t for t in p['tracks'] if not t['drop']]
        # Entre las espanolas manda el CASTELLANO. Sin esto, en las peliculas que
        # traen los dos doblajes se llevaba el defecto la primera pista, que en
        # 'La sirenita' es la LATINA. Orden: castellano, sin marca, latino.
        orden = {'castellano': 0, None: 1, 'latino': 2}
        cand  = sorted([t for t in vivas if t['lang'] in ES],
                       key=lambda t: (orden.get(variante(t['title']), 1), t['i'])) or vivas
        p['default_audio'] = cand[0]['i'] if cand else None
        # Subtitulos: por defecto los FORZADOS en castellano, si los hay.
        forz = [s for s in p['subs'] if s['lang'] in ES and s['forced']]
        p['default_sub'] = forz[0]['i'] if forz else None

    return pelis


def main():
    pelis = preparar(inventario())

    cand = []
    for p in pelis:
        firmes = [t for t in p['tracks'] if t['drop'] and not t['drop'].startswith('REVISAR')]
        vivos  = [t for t in p['tracks'] if not t['drop']]
        # El ahorro se calcula con bitrate x duracion. El StreamSize del sidecar
        # esta inflado ~3,4x en E-AC-3 (medido: prediccion 3,67 GiB, real 1,37).
        ah_cap  = sum((t['bps'] - t['cap'] * 1000) * t['dur'] / 8
                      for t in vivos if t['cap'] and t['bps'] and t['dur'])
        ah_drop = sum(t['bps'] * t['dur'] / 8 for t in firmes if t['bps'] and t['dur'])
        # Tambien entra si solo hay que recolocar el 'default'.
        hay_disp = any(t['default'] != (t['i'] == p['default_audio']) for t in vivos)
        if ah_cap + ah_drop > 0 or firmes or hay_disp:
            p['ahorro_cap'], p['ahorro_drop'] = ah_cap, ah_drop
            p['solo_disp'] = (ah_cap + ah_drop == 0 and not firmes)
            cand.append(p)
    cand.sort(key=lambda x: -(x['ahorro_cap'] + x['ahorro_drop']))

    with open(PLAN_OUT, 'w', encoding='utf-8') as fh:
        json.dump(cand, fh, ensure_ascii=False, indent=1)

    with open(CSV_OUT, 'w', encoding='utf-8-sig', newline='') as fh:
        w = csv.writer(fh, delimiter=';')
        w.writerow(['pelicula', 'a:N', 'formato', 'kbps', 'ch', 'idioma',
                    'titulo_pista', 'motivo', 'GiB', 'QUE_QUEDA'])
        for p in cand:
            queda = ' + '.join(
                "a:{0} {1} {2}k {3}ch [{4}]{5}".format(
                    t['i'], t['fmt'], (t['cap'] or t['bps'] // 1000), t['ch'], t['lang'],
                    '*' if t['i'] == p['default_audio'] else '')
                for t in p['tracks'] if not t['drop'])
            for t in p['tracks']:
                if t['drop']:
                    w.writerow([os.path.basename(p['path']), t['i'], t['fmt'],
                                t['bps'] // 1000, t['ch'], t['lang'], t['title'],
                                t['drop'], f"{t['bps']*t['dur']/8/1024**3:.2f}", queda])

    G = 1024 ** 3
    tc = sum(p['ahorro_cap'] for p in cand)
    td = sum(p['ahorro_drop'] for p in cand)
    rev = sum(1 for p in cand for t in p['tracks'] if t['drop'] and t['drop'].startswith('REVISAR'))
    prof = [t['profile'] for p in pelis for t in p['tracks'] if t['profile'] is not None]
    atm = [x for x in prof if re.search(r'atmos|joc', x or '', re.I)]
    vac = [x for x in prof if not (x or '').strip()]
    mi_atm = sum(1 for p in pelis for t in p['tracks'] if t['atmos_mi'])
    print(f"""
candidatas ................... {len(cand)}
  ahorro por recorte ......... {tc/G:8.1f} GiB
  ahorro por pistas fuera .... {td/G:8.1f} GiB
  TOTAL ...................... {(tc+td)/G:8.1f} GiB
pistas sondeadas con ffprobe . {len(prof)}
  Atmos por ffprobe .......... {len(atm)}
  Atmos por MediaInfo (total)  {mi_atm}
  profile vacio (no se toca) . {len(vac)}
pistas A REVISAR ............. {rev}

plan -> {PLAN_OUT}
csv  -> {CSV_OUT}""")


def uno(path):
    """Plan de UN solo fichero. Mismas reglas que la cola, sin filtro de
    candidatas: aqui interesa el plan aunque no haya un solo byte que ahorrar,
    porque el motivo de pasar por aqui es RECONSTRUIR EL CONTENEDOR."""
    if not os.path.isfile(path):
        return {'path': path, 'error': 'no existe'}
    try:
        audio, subs = _leer_mediainfo(path)
    except Exception as e:
        return {'path': path, 'error': f'MediaInfo no lo puede leer: {e}'}
    if not audio:
        return {'path': path, 'error': 'no tiene ninguna pista de audio'}
    st = os.stat(path)
    p = {'path': path, 'tracks': audio, 'subs': subs,
         'size': st.st_size, 'mtime': st.st_mtime}
    q = preparar([p])[0]
    firmes = [t for t in q['tracks'] if t['drop'] and not t['drop'].startswith('REVISAR')]
    vivos  = [t for t in q['tracks'] if not t['drop']]
    q['ahorro_cap']  = sum((t['bps'] - t['cap'] * 1000) * t['dur'] / 8
                           for t in vivos if t['cap'] and t['bps'] and t['dur'])
    q['ahorro_drop'] = sum(t['bps'] * t['dur'] / 8
                           for t in firmes if t['bps'] and t['dur'])
    q['solo_disp']   = (q['ahorro_cap'] + q['ahorro_drop'] == 0 and not firmes)
    return q


if __name__ == '__main__':
    # --file <ruta> --out <json>: plan de UN fichero, para la pestana de saneado.
    # La salida va a un FICHERO y no a stdout a proposito: preparar() imprime
    # diagnosticos por su cuenta y mezclarlos con el JSON lo dejaria ilegible.
    if '--file' in sys.argv:
        ruta = sys.argv[sys.argv.index('--file') + 1]
        dest = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else None
        res = uno(ruta)
        txt = json.dumps(res, ensure_ascii=False, indent=1)
        if dest:
            with open(dest, 'w', encoding='utf-8') as fh:
                fh.write(txt)
            print(f'plan -> {dest}')
        else:
            print(txt)
    else:
        main()
