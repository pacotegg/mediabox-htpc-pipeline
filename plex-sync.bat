@echo off
cd /d C:\tvwatch\server
"C:\Program Files\nodejs\node.exe" src\cli\plex-sync.ts >> "C:\tvwatch\data\plex-sync.log" 2>&1
