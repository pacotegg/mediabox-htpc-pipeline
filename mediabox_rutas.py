# -*- coding: utf-8 -*-
"""mediabox_rutas.py  -  Las bibliotecas que se barren. Una sola definicion.

POR QUE EXISTE (04/09/2026)
---------------------------
La lista de raices estaba escrita a mano en CUATRO ficheros: audio_plan.py,
buscar_ass.py, buscar_no_nativos.py y escanear_orden.py. Las cuatro coincidian
-comprobado-, que es exactamente como estaban 'G:\\MediaTmp' antes de
mediabox-paths.ps1 (nueve copias), las listas de temporales (cuatro) y las
rutas de las herramientas (41 en 20 ficheros).

LO QUE PASA SI DIVERGEN NO ES UN ERROR, ES SILENCIO. Un barrido al que le falta
una raiz no avisa: devuelve un numero MAS PEQUENYO que parece perfectamente
bueno. Ya paso una vez escribiendo 'las cuatro obvias' de memoria, y se quedaron
fuera 'Series Peques', 'Peques' y 'Pelis Animacion' -y con ellas 8 de los 13
ficheros que se buscaban-.

QUE NO ESTA AQUI, Y A PROPOSITO
-------------------------------
VIDEXT no se unifica: buscar_ass.py incluye '.avi' y los demas no. Esa
diferencia puede ser deliberada y no hay nada que la documente, asi que se deja
donde esta en vez de decidirlo de oficio.

Uso:  from mediabox_rutas import RAICES
"""

# Bibliotecas incluidas. FUERA a peticion del usuario (28/08/2026): Tricicle,
# Monologos y las tres carpetas de Baloncesto.
RAICES = [r"E:\Peliculas", r"E:\Series", r"E:\Series Peques", r"E:\Docuseries",
          r"E:\Peques", r"E:\Docupelis", r"E:\Pelis Animacion", r"E:\Conciertos"]
