@echo off
REM ============================================================================
REM  MediaBox - arranque del panel web + watchers (video + audio)
REM ----------------------------------------------------------------------------
REM  Arranque VISIBLE (ventanas minimizadas), util para depurar.
REM  Para el arranque automatico al encender el PC se usa
REM  start-mediabox-hidden.vbs en shell:startup (ese va oculto del todo).
REM
REM  Rutas COMPLETAS a proposito: no dependemos del PATH.
REM  pwsh 7 explicito: 'powershell' a secas resolveria a Windows PowerShell 5.1,
REM  que NO es el host con el que se han probado los scripts.
REM ============================================================================

set PYTHON="C:\Users\HTPC\AppData\Local\Programs\Python\Python314\python.exe"
set PWSH="C:\Program Files\PowerShell\7\pwsh.exe"

REM Panel web (Flask) -> http://localhost:8080
start "MediaBox Panel" /min %PYTHON% "C:\scripts\webpanel\app.py"

REM Espera 2s para que el panel ocupe el puerto antes de lanzar los watchers
timeout /t 2 /nobreak >nul

REM Watcher de VIDEO: vigila C:\Media\encode_queue
start "Encode Watcher" /min %PWSH% -ExecutionPolicy Bypass -File "C:\scripts\encode-watch.ps1"

REM Watcher de AUDIO: vigila C:\Media\audio_queue (solo audio, no toca el video)
start "Audio Watcher" /min %PWSH% -ExecutionPolicy Bypass -File "C:\scripts\atmosENC\audio-watch.ps1"

REM Watcher de SUBTITULOS: vigila C:\Media\subs_queue (llama a encode.ps1 -SubsOnly:
REM video y audio en copy, solo se procesan los subtitulos)
start "Subs Watcher" /min %PWSH% -ExecutionPolicy Bypass -File "C:\scripts\subs-watch.ps1"

exit
