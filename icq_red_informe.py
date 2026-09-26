"""Informe de la red ICQ: cuanto se pasa ICQ, donde aborta y como de fiable es
la proyeccion parcial. Cruza los logs de C:\\Media\\encode_logs (lineas
'RED ICQ: hito N %') con completed.jsonl (icq_red, icq_video_mbps, target).

Uso:  python C:\\scripts\\icq_red_informe.py [--desde 2026-09-21]

Sirve para dos decisiones:
  1. afinar los margenes del aborto temprano de encode.ps1 (hoy x1,30 al
     25-50 % y x1,12 al 50-75 %, sacados de n=3 del 26/08/2026);
  2. saber si compensa codificar ICQ y 'techo' A LA VEZ en las dos ranuras
     (compensa si se repite/aborta mas de ~1 de cada 3).
"""
import argparse, glob, json, os, re, sys
from datetime import datetime

LOGS = r"C:\Media\encode_logs"
JSONL = os.path.join(LOGS, "completed.jsonl")

def leer_jsonl(desde_ts):
    filas = []
    for l in open(JSONL, encoding="utf-8", errors="replace"):
        l = l.strip()
        if not l:
            continue
        try:
            r = json.loads(l)
        except Exception:
            continue
        if r.get("mode") != "encode" or (r.get("ts") or 0) < desde_ts:
            continue
        if "prueba" in str(r.get("source", "")).lower():
            continue
        if not r.get("icq_red"):
            continue
        filas.append(r)
    return filas

def hitos_de(nombre_salida, ts):
    """Busca el log de ese trabajo (por nombre de salida y fecha) y saca los hitos."""
    base = os.path.splitext(nombre_salida)[0]
    # El log se abre al EMPEZAR y el jsonl se escribe al ACABAR: el log que
    # toca es el ultimo cuyo sello de inicio va ANTES del ts del registro. Si
    # la misma pelicula se ha codificado dos veces (reencolada), coger el mas
    # nuevo emparejaria el registro viejo con el log nuevo.
    cands = []
    for p in glob.glob(os.path.join(LOGS, "2026*.log")):
        nb = os.path.basename(p)
        if base[:30] not in nb:
            continue
        m = re.match(r"(\d{8})_(\d{6})_", nb)
        if not m:
            continue
        t0 = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").timestamp()
        if t0 <= ts:
            cands.append((t0, p))
    if not cands:
        return {}, None
    log = max(cands)[1]
    hitos = {}
    aborto = None
    for l in open(log, encoding="utf-8", errors="replace"):
        m = re.search(r"RED ICQ: hito (\d+) %: media ([\d.]+)M \(limite ([\d.]+)M, x([\d.]+)\), CV del bitrate por tramos (\d+) %", l)
        if m:
            hitos[int(m.group(1))] = dict(media=float(m.group(2)), limite=float(m.group(3)), ratio=float(m.group(4)), cv=int(m.group(5)))
        m = re.search(r"ABORTO TEMPRANO al (\d+) % del metraje: media ([\d.]+)M", l)
        if m:
            aborto = (int(m.group(1)), float(m.group(2)))
    return hitos, aborto

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--desde", default="2026-09-21")
    a = ap.parse_args()
    desde_ts = datetime.strptime(a.desde, "%Y-%m-%d").timestamp()
    filas = leer_jsonl(desde_ts)
    if not filas:
        print("Sin trabajos con red ICQ desde", a.desde)
        return
    print(f"{'pelicula':38} {'min':>4} {'lim':>5} {'25%':>6} {'50%':>6} {'75%':>6} {'final':>6} {'x':>5}  resultado")
    errores = {25: [], 50: [], 75: []}
    n_ok = n_rep = n_ab = 0
    for r in sorted(filas, key=lambda r: r["ts"]):
        hitos, aborto = hitos_de(r["output"], r["ts"])
        lim = r["target_mbps"]
        final = r.get("icq_video_mbps") or 0
        estado = r["icq_red"]
        if estado == "ok": n_ok += 1
        elif estado == "repetido": n_rep += 1
        elif estado == "abortado": n_ab += 1
        cols = []
        for h in (25, 50, 75):
            v = hitos.get(h)
            cols.append(f"{v['media']:6.2f}" if v else "     -")
            # error de la proyeccion: solo si la pasada ICQ termino entera
            if v and estado in ("ok", "repetido") and final > 0:
                errores[h].append((v["media"] / final - 1, r["output"][:30], v["cv"]))
        ratio = (final / lim) if lim else 0
        res = estado
        if aborto:
            res += f" al {aborto[0]} %"
        print(f"{r['output'][:38]:38} {r['duration_s']/60:4.0f} {lim:5.1f} {' '.join(cols)} {final:6.2f} {ratio:5.2f}  {res}")
    n = n_ok + n_rep + n_ab
    print()
    print(f"{n} pasadas ICQ: {n_ok} se quedaron, {n_rep} repetidas al final, {n_ab} abortadas a mitad "
          f"-> se tira trabajo en {100*(n_rep+n_ab)/n:.0f} % (umbral para codificar ICQ y techo a la vez: ~33 %).")
    print("Error de la media parcial contra la final (positivo = la parcial iba ALTA, o sea que abortar por ella era seguro):")
    for h in (25, 50, 75):
        e = errores[h]
        if not e:
            print(f"  al {h} %: sin datos todavia (hacen falta pasadas ICQ completas con hitos en el log)")
            continue
        vals = [x[0] for x in e]
        peor_alto = max(vals); peor_bajo = min(vals)
        print(f"  al {h} %: n={len(e)}  medio {100*sum(abs(v) for v in vals)/len(vals):.1f} %  "
              f"peor por arriba {100*peor_alto:+.1f} %  peor por abajo {100*peor_bajo:+.1f} %  "
              f"-> margen seguro para abortar: x{1+max(0,peor_alto):.2f}")
    print("Margenes en encode.ps1 hoy: x1.30 (25-50 %), x1.12 (50-75 %), nunca antes del 25 % ni despues del 75 %.")

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    main()
