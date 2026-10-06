"""Crea o cambia el usuario del panel. Se ejecuta en una terminal: la contrasena
se pide con getpass, sin eco, y nunca se escribe en ningun fichero en claro.

    python C:\\scripts\\webpanel\\crear_usuario.py
"""
import getpass, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import auth


def main():
    usuario = input("Usuario: ").strip()
    if not usuario:
        sys.exit("Usuario vacio. No se ha cambiado nada.")
    while True:
        clave = getpass.getpass("Contrasena (minimo %d caracteres): " % auth.CLAVE_MIN)
        if len(clave) < auth.CLAVE_MIN:
            print("Demasiado corta.")
            continue
        if clave != getpass.getpass("Repitela: "):
            print("No coinciden. Otra vez.")
            continue
        break
    auth.crear_credencial(usuario, clave)
    auth.revocar_todas()
    print("Listo. Usuario guardado (hash scrypt) en %s." % auth.RUTA_AUTH)
    print("Todas las sesiones anteriores quedan cerradas.")


if __name__ == "__main__":
    main()
