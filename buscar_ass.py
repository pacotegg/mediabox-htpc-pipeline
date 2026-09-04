# -*- coding: utf-8 -*-
"""Inventario de pistas de subtitulos ASS/SSA en la biblioteca.

POR QUE: se convierten SIEMPRE a SRT (decision del 29/08/2026). El ASS trae
estilos y posicionamiento propios y pide sus FUENTES como adjuntos del MKV; el
SRT es texto plano y lo pinta el reproductor. Ademas de simplificar, esto vuelve
irrelevantes las fuentes incrustadas, que es justo lo que la reconstruccion del
contenedor perdia sin decir nada.

Solo MIRA. No toca ni un fichero.
"""
import os, json, subprocess, sys

FFPROBE = r'C:\Users\HTPC\AppData\Local\Microsoft\WinGet\Links\ffprobe.exe'
# Las bibliotecas que se barren salen de mediabox_rutas.py: UNA definicion para
# los cuatro barredores (04/09/2026). Antes estaba copiada aqui, y una lista de
# raices incompleta no da error, da un numero mas pequenyo que parece bueno.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mediabox_rutas import RAICES
VIDEXT = ('.mkv', '.mp4', '.m2ts', '.ts', '.mov', '.avi')
LOG  = r'C:\scripts\ass_tracks.log'
JSON = r'C:\scripts\ass_tracks.json'


def di(msg):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace"); print(msg, flush=True)
    with open(LOG, 'a', encoding='utf-8') as fh:
        fh.write(msg + '\n')


def main():
    open(LOG, 'w', encoding='utf-8').close()
    objetivos = []
    for raiz in RAICES:
        for dp, _, fs in os.walk(raiz):
            for f in fs:
                if f.lower().endswith(VIDEXT):
                    objetivos.append(os.path.join(dp, f))
    di(f'revisando {len(objetivos)} ficheros...')

    conass, npistas, nadj = [], 0, 0
    for n, p in enumerate(objetivos, 1):
        try:
            r = subprocess.run(
                [FFPROBE, '-v', 'error', '-show_entries',
                 'stream=index,codec_type,codec_name:stream_tags=language,title',
                 '-of', 'json', '--', p],
                capture_output=True, text=True, encoding='utf-8',
                errors='replace', timeout=120)
            st = json.loads(r.stdout).get('streams', [])
        except Exception:
            continue
        ass = [s for s in st if s.get('codec_name') in ('ass', 'ssa')]
        adj = [s for s in st if s.get('codec_type') == 'attachment']
        if not ass:
            continue
        npistas += len(ass)
        nadj += len(adj)
        conass.append({
            'path': p,
            'ass': [{'i': s['index'],
                     'lang': (s.get('tags') or {}).get('language', 'und'),
                     'title': (s.get('tags') or {}).get('title', '')} for s in ass],
            'adjuntos': len(adj),
        })
        if len(conass) <= 25:
            di('   [%d ASS, %d adj] %s' % (len(ass), len(adj), os.path.basename(p)[:62]))
        if n % 500 == 0:
            di(f'   {n}/{len(objetivos)}')

    with open(JSON, 'w', encoding='utf-8') as fh:
        json.dump(conass, fh, ensure_ascii=False, indent=1)
    di(f'''
ficheros con ASS/SSA ....... {len(conass)}
  pistas ASS/SSA ........... {npistas}
  adjuntos en esos ficheros  {nadj}
detalle -> {JSON}''')


if __name__ == '__main__':
    main()
