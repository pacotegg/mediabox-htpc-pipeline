#!/usr/bin/env python
"""Medir desfase por TAMANO DE PAQUETES de video. Sin decodificar nada.

Esto es solo la linea de comandos. La medicion vive en remuxlib
(`medir_por_paquetes`), que es la que usa el panel: tener aqui una segunda copia
del calculo condenaba a las dos a divergir, que en este proyecto ya ha pasado.

Uso:  python sync_paquetes.py A.mkv B.mkv [grano_s] [ventana_s]

QUE ESPERAR (validado el 19/08/2026 sobre 9 parejas con verdad conocida)
------------------------------------------------------------------------
Sirve para DESFASE FIJO y nada mas, y en lo que no puede DECLINA en vez de
inventarse un numero:

  5 parejas de desfase fijo (verdad 0, -10, -2560 ms) -> 89-100 % consenso, acierta
  2 parejas de MONTAJES distintos (Alien 3)           ->    0 % consenso, declina
  1 pareja con DERIVA de cadencia (25 contra 23.976)  ->    0 % consenso, declina

Precision ~1 fotograma (el grano), no el milisegundo: es para cuando el audio NO
engancha, no para sustituirlo.

DOS AVISOS SOBRE EL COSTE, por si se compara con los otros peldanos:
  - El coste es leer los dos ficheros enteros, asi que escala con su TAMANO: 4,9 s
    una pareja de 9,9 GB pero 49,1 s una de 17,1 GB. El "4 s" de la primera
    medicion era un fichero pequeno.
  - Es E/S pura, o sea que le afecta la contencion de disco mas que su velocidad.
"""
import os, sys, time

# dirname(abspath(...)) y no rsplit por la barra invertida: si la ruta llega
# con barras normales -python webpanel/sync_paquetes.py- el rsplit no corta
# nada y se mete el FICHERO en sys.path en vez de su carpeta (04/09/2026).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import remuxlib


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    grano = float(sys.argv[3]) if len(sys.argv) > 3 else remuxlib.PAQ_GRANO_S
    win   = float(sys.argv[4]) if len(sys.argv) > 4 else remuxlib.PAQ_WIN_S

    t0 = time.time()
    m = remuxlib.medir_por_paquetes(sys.argv[1], sys.argv[2],
                                    grano=grano, win=win)
    dt = time.time() - t0                 # reloj REAL, no solo el ffprobe

    if not m.get("ok"):
        print("NO MEDIBLE (%.1f s): %s" % (dt, m["error"]))
        return 1

    if m.get("escalera"):
        print("ESCALERA de %d tramos (%.1f s):" % (len(m["tramos"]), dt))
        for t in m["tramos"]:
            print("   de %6.1f s a %6.1f s  ->  %+9.1f ms  (--sync %+d, %d ventanas)"
                  % (t["desde_s"], t["hasta_s"], t["lag_ms"], t["sync_ms"], t["n"]))
        return 0

    print("desfase %+.1f ms   consenso %.0f%% (%d de %d ventanas)   "
          "precision ~%d ms   (%.1f s)"
          % (m["beta_ms"], m["consenso_pct"], m["used"], m["total"],
             m["precision_ms"], dt))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
