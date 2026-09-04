# -*- coding: utf-8 -*-
"""Localiza los ficheros cuya pista castellana NO es la primera.

Plex solo hace Direct Play de la PRIMERA pista de audio ("selected audio stream
is not the first audio stream"), asi que elegir el castellano en cualquier otro
sitio fuerza transcodificacion. La bandera 'default' no basta: manda el ORDEN.
"""
import os, re, json, subprocess, sys

MEDIAINFO = r"C:\scripts\DEE\MediaInfo.exe"
# Las bibliotecas que se barren salen de mediabox_rutas.py: UNA definicion para
# los cuatro barredores (04/09/2026). Antes estaba copiada aqui, y una lista de
# raices incompleta no da error, da un numero mas pequenyo que parece bueno.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mediabox_rutas import RAICES
RE_TEMPORADA = re.compile(r'^(season\b|temporada\b|specials$)', re.I)
VIDEXT = ('.mkv', '.mp4', '.m2ts', '.ts', '.mov')
ES = ('es', 'spa')
SALIDA = r"C:\scripts\orden_pistas.json"

objetivos = []
for raiz in RAICES:
    if not os.path.isdir(raiz):
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
                for g in sorted(os.listdir(p)):
                    q = os.path.join(p, g)
                    if os.path.isfile(q) and g.lower().endswith(VIDEXT):
                        objetivos.append(q)

print(f"  {len(objetivos)} ficheros a revisar", flush=True)
res = []
for n, path in enumerate(objetivos, 1):
    try:
        r = subprocess.run([MEDIAINFO, '--Output=JSON', path], capture_output=True,
                           text=True, timeout=180, encoding='utf-8', errors='replace')
        pistas = json.loads(r.stdout)['media']['track']
        if isinstance(pistas, dict):
            pistas = [pistas]
    except Exception:
        continue
    audio = [t for t in pistas if t.get('@type') == 'Audio']
    if not audio:
        continue
    langs = [str(t.get('Language', '') or 'und').lower().split('-')[0] for t in audio]
    pos_es = next((i for i, l in enumerate(langs) if l in ES), None)
    res.append({'path': path, 'langs': langs, 'pos_es': pos_es, 'n': len(audio)})
    if n % 500 == 0:
        print(f"   {n}/{len(objetivos)}", flush=True)

json.dump(res, open(SALIDA, 'w', encoding='utf-8'), ensure_ascii=False)
con_es   = [x for x in res if x['pos_es'] is not None]
mal      = [x for x in con_es if x['pos_es'] != 0]
un_audio = [x for x in mal if x['n'] == 1]
print(f"""
  ficheros con audio ............... {len(res)}
  con pista en castellano .......... {len(con_es)}
     ya es la PRIMERA .............. {len(con_es)-len(mal)}
     NO es la primera .............. {len(mal)}   <- transcodifican al elegirla
  sin castellano ................... {len(res)-len(con_es)}

  lista -> {SALIDA}""")
