' ============================================================================
'  plex-sync-hidden.vbs  -  Lanza plex-sync.bat sin ventana visible
'
'  Solo aporta la invisibilidad (el 0 de sh.Run), igual que
'  start-mediabox-hidden.vbs. La logica esta en plex-sync.bat, que llama a
'  node contra server/src/cli/plex-sync.ts y deja el registro en
'  C:\tvwatch\data\plex-sync.log.
' ============================================================================

Dim sh
Set sh = CreateObject("WScript.Shell")

' 0 = ventana oculta ; True = esperar a que termine (evita solapar dos pasadas)
sh.Run """C:\scripts\plex-sync.bat""", 0, True

Set sh = Nothing
