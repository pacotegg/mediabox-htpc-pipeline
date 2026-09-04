' ============================================================================
'  start-mediabox-hidden.vbs  -  Arranque OCULTO de MediaBox al iniciar sesion
' ----------------------------------------------------------------------------
'  Coloca un acceso directo a este .vbs en shell:startup para arranque
'  automatico totalmente invisible (ni ventana ni icono en la barra).
'
'  Este VBS ya NO arranca los procesos uno a uno: solo llama -oculto- al
'  lanzador robusto start-mediabox-core.ps1, que es quien espera a que C:\Media
'  exista, arranca cada pieza, VERIFICA que subio y REINTENTA si no. El VBS
'  aqui solo aporta la invisibilidad (el 0 de sh.Run).
'
'  Por que asi: el 19/07, tras reiniciar el PC, NINGUN watcher arranco. El VBS
'  viejo disparaba los 4 procesos a ciegas con esperas fijas y no comprobaba
'  nada; si algo no estaba listo en el arranque de Windows, el proceso moria y
'  nadie se enteraba. El lanzador nuevo lo verifica.
'
'  Para PARAR:   stop-mediabox.bat
'  Para depurar: start-mediabox.bat (ventanas visibles) o ejecutar
'                start-mediabox-core.ps1 a mano para ver el diagnostico.
' ============================================================================

Dim sh
Set sh = CreateObject("WScript.Shell")

' 0 = ventana oculta ; False = no esperar a que termine
sh.Run """C:\Program Files\PowerShell\7\pwsh.exe"" -ExecutionPolicy Bypass -File ""C:\scripts\start-mediabox-core.ps1""", 0, False

Set sh = Nothing
