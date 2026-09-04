# -*- coding: utf-8 -*-
"""Busca pistas de audio que el TV NO decodifica de forma nativa.

Con Direct Play forzado, Plex ya no transcodifica: una pista DTS, TrueHD, FLAC u
Opus se quedaria MUDA. Nativos del televisor: AC-3, E-AC-3, AAC y MP3.
"""
import os, re, json, subprocess, collections, sys

MEDIAINFO = r"C:\scripts\DEE\MediaInfo.exe"
# Las bibliotecas que se barren salen de mediabox_rutas.py: UNA definicion para
# los cuatro barredores (04/09/2026). Antes estaba copiada aqui, y una lista de
# raices incompleta no da error, da un numero mas pequenyo que parece bueno.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mediabox_rutas import RAICES
RE_TEMP = re.compile(r'^(season\b|temporada\b|specials$)', re.I)
VIDEXT = ('.mkv', '.mp4', '.m2ts', '.ts', '.mov')
NATIVOS = ('AC-3', 'E-AC-3', 'AAC', 'MPEG Audio')

objetivos = []
for raiz in RAICES:
    if not os.path.isdir(raiz): continue
    for e in sorted(os.listdir(raiz)):
        c = os.path.join(raiz, e)
        if not os.path.isdir(c): continue
        for f in sorted(os.listdir(c)):
            p = os.path.join(c, f)
            if os.path.isfile(p):
                if f.lower().endswith(VIDEXT): objetivos.append(p)
            elif RE_TEMP.match(f):
                for g in sorted(os.listdir(p)):
                    q = os.path.join(p, g)
                    if os.path.isfile(q) and g.lower().endswith(VIDEXT): objetivos.append(q)

print(f"  revisando {len(objetivos)} ficheros...", flush=True)
malos, cuenta = [], collections.Counter()
for n, path in enumerate(objetivos, 1):
    try:
        r = subprocess.run([MEDIAINFO, '--Output=JSON', path], capture_output=True,
                           text=True, timeout=180, encoding='utf-8', errors='replace')
        tr = json.loads(r.stdout)['media']['track']
        if isinstance(tr, dict): tr = [tr]
    except Exception:
        continue
    for t in tr:
        if t.get('@type') != 'Audio': continue
        fmt = t.get('Format', '')
        if fmt not in NATIVOS:
            cuenta[fmt] += 1
            malos.append((path, fmt, t.get('Language', '?')))
    if n % 1000 == 0: print(f"   {n}/{len(objetivos)}", flush=True)

print(f"\n  pistas NO nativas: {len(malos)}  en {len({m[0] for m in malos})} ficheros")
for f, n in cuenta.most_common():
    print(f"     {n:5d}  {f}")
json.dump([{'path': p, 'fmt': f, 'lang': l} for p, f, l in malos],
          open(r'C:\scripts\no_nativos.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print("\n  ejemplos:")
for p, f, l in malos[:10]:
    print(f"     [{f:10s}] {os.path.basename(p)[:56]}")
