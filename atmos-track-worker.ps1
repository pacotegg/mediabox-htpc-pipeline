#requires -Version 7.0
<#
============================================================================
 atmos-track-worker.ps1  -  convierte UNA pista a DD+ (E-AC-3/JOC)
============================================================================
 Lo lanza Invoke-DdpTracksParallel (atmos-lib.ps1) como proceso independiente,
 uno por pista, para convertir en paralelo las 2-3 pistas Atmos de una MISMA
 pelicula. Medido el 06/08/2026: K=2 rinde 1,62x (81 % de eficiencia).

 POR QUE UN PROCESO Y NO ForEach-Object -Parallel:
   - La libreria escribe por su funcion Log, que en encode.ps1 apunta al log del
     trabajo. Desde varios runspaces a la vez, esas escrituras se entrelazan y el
     log queda ilegible justo cuando hace falta para diagnosticar. Aqui cada
     worker escribe en SU fichero y el padre los vuelca ordenados al terminar.
   - Es exactamente el patron que ya se ejercito en el benchmark (7 tandas, 4
     instancias simultaneas, cero fallos), asi que no estrena mecanismo.

 Contrato: escribe SIEMPRE $ResultFile (JSON) pase lo que pase. Si el fichero no
 aparece, el padre lo trata como fallo estructural y reconvierte esa pista en
 SECUENCIAL: nunca cae directo al eac3, que perderia el Atmos en silencio.
============================================================================
#>
param(
    [Parameter(Mandatory=$true)][string]$InputFile,
    [Parameter(Mandatory=$true)][int]$AudioIndex,
    [Parameter(Mandatory=$true)][int]$Bitrate,
    [Parameter(Mandatory=$true)][string]$OutFile,
    [int]$IsAtmos = 1,
    [int]$Channels = 8,
    [double]$DurationSec = 0,
    [string]$Tmp = 'C:\Media\tmp',
    [string]$BigTmp = '',
    [Parameter(Mandatory=$true)][string]$LibPath,
    [Parameter(Mandatory=$true)][string]$SlotLog,
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [string]$ProgressFile = ''
)

# La libreria resuelve Log en tiempo de ejecucion, asi que definirla aqui basta
# para que TODA su salida (incluidas las lineas de dee y truehdd) acabe en el log
# de esta pista y no mezclada con la de las otras.
function Log($m) {
    Add-Content -LiteralPath $SlotLog -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ErrorAction SilentlyContinue
}

. $LibPath

# Progreso a fichero: el padre lo sondea y compone el porcentaje conjunto para el
# panel. Se escribe entero de una vez (no append) para que el padre lea siempre
# un estado coherente.
$cb = $null
if ($ProgressFile) {
    $cb = {
        param($stage, $pct)
        try {
            [System.IO.File]::WriteAllText($ProgressFile, "stage=$stage`npct=$pct")
        } catch { }
    }.GetNewClosure()
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ok = $false
$fail = ''
try {
    $ok = Convert-TrueHDToDDPCached -InputFile $InputFile -AudioIndex $AudioIndex -Bitrate $Bitrate `
              -OutFile $OutFile -IsAtmos:([bool]$IsAtmos) -Channels $Channels -DurationSec $DurationSec `
              -Tmp $Tmp -BigTmp $BigTmp -OnProgress $cb
    $fail = "$global:DdpLastFailure"
} catch {
    $fail = 'other'
    Log "  [worker] EXCEPCION: $($_.Exception.Message)"
}
$sw.Stop()

$sz = 0L
if (Test-Path -LiteralPath $OutFile) { $sz = (Get-Item -LiteralPath $OutFile).Length }

# El JSON se escribe SIEMPRE: su ausencia es la senyal de "el worker murio" que
# usa el padre para reconvertir en secuencial.
[pscustomobject]@{
    audioIndex = $AudioIndex
    ok         = [bool]$ok
    failure    = $fail
    outFile    = $OutFile
    outBytes   = $sz
    seconds    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultFile -Encoding UTF8
