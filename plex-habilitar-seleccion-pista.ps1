<#
============================================================================
 plex-habilitar-seleccion-pista.ps1   (EJECUTAR COMO ADMINISTRADOR)
============================================================================
 QUE ARREGLA
 Al elegir en Plex una pista de audio que NO es la primera, el servidor
 transcodifica en vez de hacer Direct Play. En 4K eso deja la app de la TV en
 pantalla negra y colgada. El log lo dice sin rodeos:

     MDE: selected audio stream is not the first audio stream
          and direct play stream selection is not enabled

 POR QUE PASA
 Plex no reconoce el televisor:

     Unable to find client profile for device; platform=Tizen,
     platformVersion=6, device=21_NIKEM2_QTV, model=QE65QN93AATXXC

 ...asi que le aplica el perfil 'Generic', que viene LITERALMENTE VACIO:

     <Client name="Generic" />

 Sin ajustes no hay 'DirectPlayStreamSelection', y sin eso solo la primera
 pista puede ir en Direct Play. Medido: 65 de 65 decisiones con perfil Generic.

 QUE HACE ESTE SCRIPT
 Anyade a Generic.xml el mismo ajuste que ya traen otros 10 perfiles de Plex
 (entre ellos 'Universal TV', que no contiene otra cosa):

     <Setting name="DirectPlayStreamSelection" value="true" />

 Es un cambio de una linea, con copia previa, y reversible con -Deshacer.

 AVISOS
  - Hay que REINICIAR Plex Media Server para que lo lea.
  - Una actualizacion de Plex sobrescribira el fichero y habra que repetirlo.
    La copia queda al lado como .bak-<fecha>.

 Uso (PowerShell COMO ADMINISTRADOR):
   pwsh -File C:\scripts\plex-habilitar-seleccion-pista.ps1
   pwsh -File C:\scripts\plex-habilitar-seleccion-pista.ps1 -Deshacer
============================================================================
#>
param(
    [string]$Perfil = 'C:\Program Files\Plex\Plex Media Server\Resources\Profiles\Generic.xml',
    [switch]$Deshacer,
    [switch]$NoReiniciar
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Ok($m)   { Write-Host "  $m" }
function Mal($m)  { Write-Host "  ERROR: $m"; exit 1 }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Mal "hay que ejecutarlo COMO ADMINISTRADOR (Program Files no deja escribir si no)."
}
if (-not (Test-Path -LiteralPath $Perfil)) { Mal "no encuentro $Perfil" }

if ($Deshacer) {
    $bak = Get-ChildItem -LiteralPath (Split-Path $Perfil) -Filter 'Generic.xml.bak-*' -EA SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $bak) { Mal "no hay copia de seguridad que restaurar." }
    Copy-Item -LiteralPath $bak.FullName -Destination $Perfil -Force -ErrorAction Stop
    Ok "restaurado desde $($bak.Name)"
} else {
    $txt = Get-Content -LiteralPath $Perfil -Raw
    if ($txt -match 'DirectPlayStreamSelection') {
        Ok "el ajuste YA estaba puesto; no se toca nada."
    } else {
        $bak = "$Perfil.bak-{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
        Copy-Item -LiteralPath $Perfil -Destination $bak -Force -ErrorAction Stop
        Ok "copia previa: $(Split-Path $bak -Leaf)"

        # SE COMPRUEBA QUE NO HAY NADA QUE PERDER (04/09/2026).
        # Abajo se reescribe el fichero ENTERO con un texto fijo. Eso vale
        # mientras Generic.xml sea lo que Plex envia hoy: un unico
        # '<Client name="Generic" />' sin hijos -medido, y por eso el perfil
        # no sirve para nada-. Si una actualizacion le mete ajustes de verdad,
        # la reescritura se los lleva por delante y nadie relaciona el cambio
        # de comportamiento de Plex con este script. Mejor negarse que borrar.
        $xin = New-Object System.Xml.XmlDocument
        $xin.Load($Perfil)
        $raiz = $xin.DocumentElement
        # get_Name() y NO .Name: el adaptador XML de PowerShell expone los
        # ATRIBUTOS como propiedades, asi que el atributo name="Generic" TAPA la
        # propiedad Name del nodo. Con .Name esta guarda leia "Generic" en vez de
        # "Client" y rechazaba el fichero bueno (visto al probarla, 04/09/2026).
        $nombreRaiz = $raiz.get_Name()
        $hijos = @($raiz.ChildNodes | Where-Object { $_.NodeType -ne 'Comment' })
        if ($nombreRaiz -ne 'Client' -or $hijos.Count -gt 0) {
            # El mensaje en DOS llamadas y no con un "+" detras de Mal(...): en
            # PowerShell eso no concatena, pasa "+" y la cadena como argumentos
            # SUELTOS que la funcion tira, y se perderia justo la mitad que dice
            # que hacer.
            Write-Host ("  este Generic.xml YA trae contenido (<{0}> con {1} hijo(s)). No lo piso." -f $nombreRaiz, $hijos.Count)
            Mal 'anyade a mano <Settings><Setting name="DirectPlayStreamSelection" value="true" /></Settings>, o vacia el fichero tu si sabes que ese contenido sobra.'
        }

        # '<Client name="Generic" />' pasa a llevar el bloque de ajustes.
        $nuevo = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- Author: Plex Inc. -->
<!-- Modificado: se habilita DirectPlayStreamSelection para que el Direct Play
     funcione tambien al elegir una pista de audio que no sea la primera.
     Sin esto, el televisor cae en este perfil (vacio) y Plex transcodifica. -->
<Client name="Generic">
  <Settings>
    <Setting name="DirectPlayStreamSelection" value="true" />
  </Settings>
</Client>
'@
        [System.IO.File]::WriteAllText($Perfil, $nuevo, (New-Object System.Text.UTF8Encoding($false)))
        Ok "ajuste anyadido."
    }
}

# Comprobacion: que el XML sigue siendo valido. Un perfil roto seria peor que
# el problema que arregla.
try {
    $x = New-Object System.Xml.XmlDocument
    $x.Load($Perfil)
    Ok "XML valido (raiz <$($x.DocumentElement.Name) name='$($x.DocumentElement.GetAttribute('name'))'>)"
} catch { Mal "el XML ha quedado invalido: $_" }

if (-not $NoReiniciar) {
    $p = Get-Process 'Plex Media Server' -EA SilentlyContinue
    if ($p) {
        Ok "reiniciando Plex Media Server..."
        Stop-Process -Id $p.Id -Force
        Start-Sleep -Seconds 4
        $exe = 'C:\Program Files\Plex\Plex Media Server\Plex Media Server.exe'
        if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe | Out-Null; Ok "arrancado." }
        else { Ok "AVISO: no encuentro el ejecutable; arrancalo tu." }
    } else { Ok "Plex no estaba corriendo; arrancalo cuando quieras." }
}
Write-Host ""
Write-Host "  Ahora reproduce en la TV eligiendo la pista que antes transcodificaba."
Write-Host "  Si sigue igual, deshaz con:  -Deshacer"
