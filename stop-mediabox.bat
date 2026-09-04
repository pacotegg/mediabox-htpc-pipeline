@echo off
REM ============================================================================
REM  stop-mediabox.bat  -  Lanzador fino de stop-mediabox.ps1
REM ----------------------------------------------------------------------------
REM  Toda la logica esta en el .ps1. Este .bat solo existe para poder pararlo
REM  con doble clic o desde cmd.
REM
REM  NO volver a meter la logica aqui dentro de un `pwsh -Command "..."`: esa
REM  version fallaba de formas no explicadas (primero un "Force: The term
REM  'Force' is not recognized", luego un fallo mudo que no mataba nada aunque
REM  la misma consulta funcionase pegada a mano en pwsh). El escapado cmd->pwsh
REM  no merece la pelea: -File no tiene ese problema.
REM ============================================================================

"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\stop-mediabox.ps1"
timeout /t 3 /nobreak >nul
