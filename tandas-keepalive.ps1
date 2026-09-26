<#
============================================================================
 tandas-keepalive.ps1  -  Relanza descargas-tanda.ps1 si se murio sin querer
============================================================================
 QUE PROBLEMA RESUELVE (08/09/2026)
 ---------------------------------
 Una tanda entera son una hora y media entre descarga, extraccion, codificado
 y copia a la biblioteca, y las 16 que quedan son un dia largo. Un corte de
 luz o un reinicio de Windows a mitad se llevaba el bucle por delante y no lo
 volvia a arrancar nadie: los watchers si vuelven -los arranca la carpeta de
 Inicio- y JDownloader tambien reanuda sus descargas, pero el orquestador de
 tandas se quedaba muerto y el trabajo a medias en C: sin que nadie lo
 recogiera.

 COMO DISTINGUE "SE MURIO" DE "LO PARE YO", que es lo unico delicado aqui:

   descargas-tanda.ps1 escribe C:\Media\tmp\tandas_activo.json en cuanto pasa
   sus comprobaciones de arranque, y lo BORRA en toda salida normal: parada
   pedida con tandas_stop, -UnaTanda, no queda nada que bajar, o un fallo que
   obliga a parar. O sea:

     fichero presente + proceso ausente -> se murio sin querer  -> RELANZAR
     fichero ausente                    -> termino a proposito  -> NO TOCAR

   Si el equipo se apaga de golpe, esa linea de borrado no llega a ejecutarse
   y el fichero se queda. Esa es toda la senyal, y es fiable porque no depende
   de adivinar nada: depende de que el proceso llegara o no a su final.

 SE RELANZA CON LOS MISMOS ARGUMENTOS con los que se lanzo la primera vez,
 que van guardados en el propio fichero de estado. Asi un -Nombre o un -N
 distintos viajan solos y no hay una copia de la linea de ordenes aqui que se
 quede obsoleta.

 EL TOPE DE RELANZAMIENTOS existe para no montar un bucle infinito si lo que
 falla es el propio script: a los $MaxReintentos intentos deja de insistir, lo
 apunta en el log y se queda quieto. La cuenta se pone a cero sola en cuanto
 una tanda se cierra entera, que es la prueba de que el bucle funciona.

 NO arranca nada por su cuenta: si nunca se ha lanzado descargas-tanda.ps1,
 aqui no hay fichero de estado y este script no hace absolutamente nada.

 Lo llama la tarea programada "MediaBox - keepalive tandas", al iniciar sesion
 y cada 10 minutos, que es el mismo patron que "MediaBox - reparar watchers".

   Manual:  pwsh -ExecutionPolicy Bypass -File C:\scripts\tandas-keepalive.ps1
            pwsh -File C:\scripts\tandas-keepalive.ps1 -SoloVerificar

 NOTA: fichero en ASCII puro (codigo Y comentarios).
============================================================================
#>

[CmdletBinding()]
param(
    # Dice que haria y no relanza nada.
    [switch]$SoloVerificar
)

$ErrorActionPreference = 'Stop'

$Script     = 'C:\scripts\descargas-tanda.ps1'
$Tmp        = 'C:\Media\tmp'
$ActivoFile = Join-Path $Tmp 'tandas_activo.json'
$PidFile    = Join-Path $Tmp 'tandas_pid'
$Log        = 'C:\Media\encode_logs\tandas.log'
$PwshExe    = 'C:\Program Files\PowerShell\7\pwsh.exe'
$MaxReintentos = 10

# Get-OtraInstancia mira TAMBIEN la linea de comandos: Windows recicla los PID
# y un proceso cualquiera que herede el numero guardado daria un falso "sigue
# vivo" para siempre. Paso el 04/09/2026 con un svchost y el PID de subs-watch.
$LockLib = 'C:\scripts\pipeline-lock.ps1'
. $LockLib

function Apunta([string]$txt) {
    $linea = "{0}  [keepalive] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $txt
    Write-Host $linea
    try { Add-Content -LiteralPath $Log -Value $linea -Encoding utf8 } catch { }
}

# --- Hay algo que vigilar? -------------------------------------------------
if (-not (Test-Path -LiteralPath $ActivoFile)) { exit 0 }   # nada en marcha: silencio

$est = $null
try { $est = Get-Content -LiteralPath $ActivoFile -Raw | ConvertFrom-Json } catch { }
if (-not $est) {
    Apunta "el estado '$ActivoFile' no se puede leer. Lo aparto para no reintentar en bucle."
    if (-not $SoloVerificar) {
        try { Move-Item -LiteralPath $ActivoFile -Destination "$ActivoFile.roto" -Force -ErrorAction Stop }
        catch { Apunta "tampoco pude apartarlo: $($_.Exception.Message)" }
    }
    exit 1
}

# --- Sigue vivo? -----------------------------------------------------------
$vivo = Get-OtraInstancia -PidFile $PidFile -Marca 'descargas-tanda.ps1'
if ($vivo) { exit 0 }   # corriendo: no hay nada que hacer y no se ensucia el log

$reintentos = 0
try { $reintentos = [int]$est.reintentos } catch { }

Apunta ("descargas-tanda NO esta corriendo pero deberia: se quedo en la tanda {0}, fase '{1}'." -f $est.tanda, $est.fase)

if ($reintentos -ge $MaxReintentos) {
    Apunta "ya se ha relanzado $reintentos veces sin llegar a cerrar una tanda: NO insisto mas."
    Apunta "Miralo a mano. Cuando este resuelto, borra '$ActivoFile' o vuelve a lanzar el script."
    exit 2
}

$argumentos = @()
try { $argumentos = @($est.argumentos | ForEach-Object { [string]$_ }) }
catch { Apunta "el estado no trae argumentos legibles: relanzo sin ellos." }

function Entrecomilla([string]$s) {
    <#
      QUOTING POR ELEMENTO, que es la trampa de siempre en este proyecto.

      Start-Process -ArgumentList con un ARRAY une los elementos con espacios y
      NO los entrecomilla. O sea que un titulo como 'Juego de Tronos (2011)'
      llegaria al script como cuatro argumentos sueltos y -Nombre se quedaria
      con 'Juego': el relanzamiento tras un corte de luz habria creado
      'E:\Series\Juego\'. Por eso se arma UNA cadena ya entrecomillada.
    #>
    if ([string]::IsNullOrEmpty($s)) { return '""' }
    if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
    return $s
}

$partes = @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Script) + $argumentos
$linea  = ($partes | ForEach-Object { Entrecomilla $_ }) -join ' '
Apunta ("relanzando (intento {0} de {1}): {2}" -f ($reintentos + 1), $MaxReintentos, $linea)

if ($SoloVerificar) { Apunta '(-SoloVerificar: no lo lanzo)'; exit 0 }

# La cuenta se sube ANTES de lanzar. Si se subiera despues y el arranque
# tumbara el proceso al instante, el contador no avanzaria nunca y esto seria
# un bucle infinito, que es justo lo que el tope existe para evitar.
try {
    $est.reintentos = $reintentos + 1
    $json = $est | ConvertTo-Json -Depth 5 -Compress
    [System.IO.File]::WriteAllText($ActivoFile, $json, [System.Text.UTF8Encoding]::new($false))
} catch {
    Apunta "no pude actualizar la cuenta de reintentos: $($_.Exception.Message)"
}

try {
    # Sin -PassThru: no se espera ni se mira el ExitCode del bucle relanzado.
    Start-Process -FilePath $PwshExe -ArgumentList $linea -WindowStyle Hidden
    Apunta 'relanzado.'
    exit 0
} catch {
    Apunta "FALLO al relanzar: $($_.Exception.Message)"
    exit 1
}
