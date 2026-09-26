<#
============================================================================
 jd-lib.ps1  -  Cliente de la API LOCAL de JDownloader 2
============================================================================
 POR QUE EXISTE (07/09/2026)
 ---------------------------
 Para poder bajar por TANDAS hace falta poder decirle a JDownloader "arranca
 estos N paquetes y ni uno mas". Sin eso, JD vacia la cola entera contra C: y
 el disco se llena a mitad de un encode, que es justo lo que paso el
 31/07/2026 (ver CHANGELOG.md).

 QUE SE VERIFICO EN ESTA MAQUINA (08/09/2026), Y EL ERROR QUE COSTO ENCONTRARLO

   - JD abre DOS servidores distintos y es facil confundirlos:
       * 127.0.0.1:9666 -> EXTERNAL INTERFACE (el de FlashGot). Esta siempre
         encendido y responde 200 a GET /flash/ con la cadena "JDownloader",
         pero **501 a todo lo demas**, porque no implementa nada mas.
       * 127.0.0.1:3128 -> la API DEPRECATED, que es la que usa esto. Solo
         escucha si 'deprecatedapienabled' esta en true.
   - De ahi el diagnostico equivocado que estuvo un rato en este fichero: con
     el interruptor apagado, 3128 no tiene a nadie escuchando y 9666 si, asi
     que parecia que "el puerto bueno es el 9666 y no el 3128 de los
     ejemplos". Era al reves: el 3128 de los ejemplos es correcto, y el 501
     de 9666 no significaba "puerta cerrada" sino "servidor equivocado".
   - El puerto NO se escribe a mano aqui: se lee de 'deprecatedapiport' en la
     config de JD, que es donde manda de verdad.
   - Si 3128 no responde, el interruptor esta apagado. Se activa desde el
     propio JD (Configuracion > Ajustes avanzados > filtrar por 'deprecated' >
     'RemoteAPI: Deprecated Api Enabled') o con jd-api-setup.ps1.

 EL FORMATO DE LA QUERY es la parte fragil de esta API: los parametros van
 POSICIONALES en la query string, serializados a JSON y separados por '&':
     /linkgrabberv2/moveToDownloadlist?[]&[123,456]
     /downloadsV2/queryPackages?{"bytesLoaded":true,"finished":true}
 Lo que NO esta claro en ninguna documentacion es si hay que URL-escapar las
 llaves y las comillas. Por eso Invoke-JdApi no lo adivina: prueba crudo,
 y si eso da error de protocolo reintenta escapado, RECUERDA cual funciono en
 $script:JdEscape y no vuelve a probar el otro. Test-JdApi hace ese
 aprendizaje a proposito al arrancar, para que el primer uso de verdad no sea
 tambien el primer experimento.

 NOTA: fichero en ASCII puro (codigo Y comentarios), como el resto de
 C:\scripts. Un caracter fuera de ASCII rompe el parseo bajo cp1252.
============================================================================
#>

# El puerto sale de la CONFIG DE JD, no de una constante: 'deprecatedapiport'
# es quien manda, y si alguien lo cambia en los ajustes esto lo sigue solo.
# 3128 es el valor de fabrica y el respaldo si el fichero no se puede leer.
$JdCfgRemoteApi = 'C:\Users\HTPC\AppData\Local\JDownloader 2\cfg\org.jdownloader.api.RemoteAPIConfig.json'
$JdApiPuerto = 3128
try {
    $cfgApi = Get-Content -LiteralPath $JdCfgRemoteApi -Raw | ConvertFrom-Json
    if ($cfgApi.deprecatedapiport) { $JdApiPuerto = [int]$cfgApi.deprecatedapiport }
} catch { }
$JdApiBase = "http://127.0.0.1:$JdApiPuerto"

# 'auto' hasta que Invoke-JdApi averigue cual de las dos formas traga esta
# version de JD. Despues vale 'crudo' o 'escapado' y ya no se prueba el otro.
$script:JdEscape = 'auto'

function ConvertTo-JdParam {
    # Un parametro de la API es JSON compacto. Las cadenas que YA vienen
    # serializadas (empiezan por '[' o '{') se pasan tal cual: asi el llamante
    # puede escribir '[]' para "array vacio" sin pelearse con ConvertTo-Json,
    # que para un array vacio de PowerShell escupe 'null' y no '[]'.
    param([object]$Valor)
    if ($Valor -is [string] -and $Valor -match '^\s*[\[\{]') { return $Valor }
    return ($Valor | ConvertTo-Json -Depth 8 -Compress)
}

function Invoke-JdApi {
    <#
      Llama a un metodo de la API local. $Ruta es 'namespace/metodo' y $Params
      son los parametros POSICIONALES (el orden importa: la API no los nombra).

      Devuelve el contenido de '.data' de la respuesta, que es donde JD mete
      siempre el resultado. Si la respuesta no trae 'data' devuelve el objeto
      entero, porque los metodos que no retornan nada contestan con un JSON
      sin ese campo.
    #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [object[]]$Params = @(),
        [int]$TimeoutSec = 60
    )

    $trozos = @()
    foreach ($p in $Params) { $trozos += (ConvertTo-JdParam $p) }

    # Orden de intentos: lo que ya sabemos que funciona primero. En 'auto' se
    # prueban los dos y se aprende; despues la lista tiene un solo elemento.
    $modos = switch ($script:JdEscape) {
        'crudo'    { ,'crudo' }
        'escapado' { ,'escapado' }
        default    { @('crudo','escapado') }
    }

    $ultimoError = $null
    foreach ($modo in $modos) {
        $qs = ''
        if ($trozos.Count) {
            $partes = if ($modo -eq 'escapado') {
                @($trozos | ForEach-Object { [uri]::EscapeDataString($_) })
            } else {
                @($trozos)
            }
            $qs = '?' + ($partes -join '&')
        }
        $url = "$JdApiBase/$Ruta$qs"

        try {
            # -UseBasicParsing: sin el, en algunos hosts Invoke-WebRequest
            # intenta levantar el motor de IE y se queda colgado.
            $r = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSec `
                                   -UseBasicParsing -ErrorAction Stop
            if ($script:JdEscape -eq 'auto') { $script:JdEscape = $modo }
            $txt = $r.Content
            if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
            $obj = $txt | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $obj.PSObject.Properties['data']) { return $obj.data }
            return $obj
        } catch {
            $ultimoError = $_
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            # 501 = la API deprecated sigue apagada. Reintentar con otro
            # escapado no arregla eso, asi que se corta aqui con un mensaje
            # que dice QUE hacer, en vez de dejar un 501 desnudo en el log.
            if ($code -eq 501) {
                throw ("JDownloader responde 501 en '$Ruta': la API local esta DESACTIVADA. " +
                       "Ejecuta C:\scripts\jd-api-setup.ps1 (una sola vez, con JD cerrado).")
            }
            # Cualquier otro error con el modo YA aprendido es un error de
            # verdad: no hay segundo intento que valga.
            if ($script:JdEscape -ne 'auto') { throw }
        }
    }
    throw ("Fallo la llamada '$Ruta' a la API de JDownloader: " + $ultimoError.Exception.Message)
}

function Test-JdApi {
    # Comprueba que la API responde Y deja aprendido el modo de escapado.
    # Devuelve $true/$false; no lanza, porque el llamante decide si eso es
    # motivo de parada (descargas-tanda.ps1) o solo de aviso.
    try {
        $null = Invoke-JdApi -Ruta 'device/ping' -TimeoutSec 10
        return $true
    } catch {
        Write-Host "  [jd] API no disponible: $($_.Exception.Message)"
        return $false
    }
}

function Get-JdPaquetesCola {
    # Paquetes del LINKGRABBER: la sala de espera. Aqui viven los cientos de
    # enlaces que todavia no se han bajado.
    $q = @{
        availableOnlineCount = $true
        bytesTotal           = $true
        enabled              = $true
        saveTo               = $true
        status               = $true
        startAt              = 0
        maxResults           = -1
    }
    return @(Invoke-JdApi -Ruta 'linkgrabberv2/queryPackages' -Params @($q))
}

function Get-JdEnlacesCola {
    <#
      Los FICHEROS que hay dentro de unos paquetes del LINKGRABBER.

      Esta es la funcion que hace posible bajar de 4 en 4. Un paquete de JD es
      una TEMPORADA entera -255 GB, que no caben en C:-, pero dentro los .rar
      vienen agrupados por episodio:

        JuegazosS1E07RemuxHeyshir.part01.rar .. part11.rar   <- un episodio
        JuegazosS1E08RemuxHeyshir.part01.rar .. part11.rar   <- otro

      Cada grupo se extrae por su cuenta, asi que se pueden mover a la lista de
      descargas los enlaces de UN episodio y dejar el resto esperando. Sin esto
      la unidad minima seria la temporada y no habria tandas que valgan.
    #>
    param([Parameter(Mandatory)][long[]]$PackageIds)
    if (-not $PackageIds.Count) { return @() }
    $q = @{
        packageUUIDs = @($PackageIds)
        availability = $true
        bytesTotal   = $true
        enabled      = $true
        status       = $true
        startAt      = 0
        maxResults   = -1
    }
    return @(Invoke-JdApi -Ruta 'linkgrabberv2/queryLinks' -Params @($q))
}

function Get-JdPaquetesDescarga {
    # Paquetes de la LISTA DE DESCARGAS: lo que esta bajando o ya bajado.
    $q = @{
        bytesLoaded = $true
        bytesTotal  = $true
        enabled     = $true
        finished    = $true
        saveTo      = $true
        status      = $true
        speed       = $true
        eta         = $true
        startAt     = 0
        maxResults  = -1
    }
    return @(Invoke-JdApi -Ruta 'downloadsV2/queryPackages' -Params @($q))
}

function Get-JdEnlacesDescarga {
    <#
      Los FICHEROS que componen unos paquetes de la lista de descargas.

      Existe para que el borrado sea por FICHERO y no por carpeta. Un paquete
      cuyo 'saveTo' apunte directamente a C:\Users\HTPC\Downloads -pasa cuando
      el enlace no trae nombre de paquete- convertiria un "borra la carpeta del
      paquete" en un borrado de la carpeta de descargas ENTERA, con los PDF y
      todo lo demas dentro. Con la lista de nombres se borra lo que es, y la
      carpeta solo si queda vacia y cuelga de la raiz de descargas.
    #>
    param([Parameter(Mandatory)][long[]]$PackageIds)
    if (-not $PackageIds.Count) { return @() }
    $q = @{
        packageUUIDs = @($PackageIds)
        bytesLoaded  = $true
        bytesTotal   = $true
        finished     = $true
        status       = $true
    }
    return @(Invoke-JdApi -Ruta 'downloadsV2/queryLinks' -Params @($q))
}

function Move-JdALaDescarga {
    <#
      linkgrabberv2/moveToDownloadlist(long[] linkIds, long[] packageIds).

      Los dos arrays son utiles y por eso los dos son opcionales:

      - -LinkIds  es el modo NORMAL aqui: mueve los .rar de UN episodio y deja
        el resto de la temporada esperando en el linkgrabber. Hay que pasarle
        el grupo COMPLETO (part01..partNN); si falta una parte, JD baja lo que
        le den y la extraccion se queda a medias para siempre.
      - -PackageIds mueve el paquete entero. Con estos paquetes eso es una
        temporada de 255 GB, asi que solo vale para paquetes pequenyos.

      ConvertTo-Json no sirve para el array vacio: para @() escupe 'null' y la
      API espera '[]'. Por eso se arma la cadena a mano.
    #>
    param([long[]]$LinkIds = @(), [long[]]$PackageIds = @())
    if (-not $LinkIds.Count -and -not $PackageIds.Count) { return }
    $l = '[' + (($LinkIds    | ForEach-Object { [string]$_ }) -join ',') + ']'
    $p = '[' + (($PackageIds | ForEach-Object { [string]$_ }) -join ',') + ']'
    $null = Invoke-JdApi -Ruta 'linkgrabberv2/moveToDownloadlist' -Params @($l, $p)
}

function Remove-JdPaquetesDescarga {
    # downloadsV2/removeLinks(long[] linkIds, long[] packageIds). Quita el
    # paquete de la LISTA de JD; NO borra ficheros del disco. El borrado real
    # lo hace descargas-tanda.ps1 y solo despues de verificar la salida.
    param([Parameter(Mandatory)][long[]]$PackageIds)
    if (-not $PackageIds.Count) { return }
    $ids = '[' + (($PackageIds | ForEach-Object { [string]$_ }) -join ',') + ']'
    $null = Invoke-JdApi -Ruta 'downloadsV2/removeLinks' -Params @('[]', $ids)
}

function Set-JdEnlacesActivos {
    <#
      downloadsV2/setEnabled(boolean enabled, long[] linkIds, long[] packageIds).
      Activa o desactiva enlaces SIN parar el controlador de descargas.

      Es lo que permite compartir JDownloader con una persona: parar el
      controlador entero -downloadcontroller/stop- se lleva por delante las
      descargas del usuario, que no tienen nada que ver con la tanda.
    #>
    param(
        [long[]]$PackageIds = @(),
        [long[]]$LinkIds = @(),
        [Parameter(Mandatory)][bool]$Activo
    )
    if (-not $PackageIds.Count -and -not $LinkIds.Count) { return }
    $pk = '[' + (($PackageIds | ForEach-Object { [string]$_ }) -join ',') + ']'
    $lk = '[' + (($LinkIds    | ForEach-Object { [string]$_ }) -join ',') + ']'
    $null = Invoke-JdApi -Ruta 'downloadsV2/setEnabled' -Params @($Activo.ToString().ToLower(), $lk, $pk)
}

function Start-JdDescargas { $null = Invoke-JdApi -Ruta 'downloadcontroller/start' }
function Stop-JdDescargas  { $null = Invoke-JdApi -Ruta 'downloadcontroller/stop'  }

function Get-JdEstadoDescargas {
    try { return [string](Invoke-JdApi -Ruta 'downloadcontroller/getCurrentState') }
    catch { return 'DESCONOCIDO' }
}
