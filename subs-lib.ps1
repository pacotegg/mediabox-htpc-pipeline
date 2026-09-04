<#
============================================================================
 subs-lib.ps1  -  conversion de una pista de subtitulos a SRT
============================================================================
 Una sola entrada: Convert-SubToSrt. Decide sola que hacer segun el codec:

   subrip / text          -> se extrae tal cual (ya es SRT)
   ass / ssa / mov_text   -> ffmpeg -c:s srt   (se pierde el estilado, no el texto)
   hdmv_pgs_subtitle      -> .sup + OCR con PgsToSrt (Tesseract)
   dvd_subtitle (VobSub)  -> NO se puede: PgsToSrt solo entiende PGS

 POR QUE ESTA LIBRERIA EXISTE
 ----------------------------
 El OCR vivia dentro de encode.ps1, en linea, dentro del bucle de subtitulos.
 Al querer usarlo tambien desde el remux del panel habia dos salidas: copiar
 esas ~110 lineas a otro sitio, o sacarlas a una libreria. Copiarlas es
 exactamente lo que ya paso con New-DeeAtmosXml y con el motor de audio, las dos
 veces divergieron y las dos veces hubo que deshacerlo. Asi que se saca aqui,
 igual que atmos-lib.ps1 para el audio, y encode.ps1 la dot-sourcea.

 LO QUE **NO** DECIDE ESTA LIBRERIA
 ----------------------------------
 Que hacer cuando falla. Convert-SubToSrt informa (.Ok, .Empty, .Reason) y el
 llamante decide: encode.ps1 copia el PGS tal cual si el OCR falla y descarta la
 pista solo si venia vacia de origen. Esa politica es del pipeline, no de aqui.

 NOTA: fichero en ASCII puro (codigo Y comentarios).
============================================================================
#>

# Misma red de seguridad que atmos-lib.ps1: quien nos dot-sourcea define su Log.
if (-not (Get-Command Log -ErrorAction SilentlyContinue)) {
    function Log($m) { Write-Host $m }
}

# Rutas ABSOLUTAS a proposito. Un PATH de maquina con un '%PATH%' literal se
# comio la entrada de .NET y dejo el OCR roto SEMANAS, fallando en silencio y
# descartando subtitulos. El PATH ya esta arreglado, pero no dependemos de el.
# EL GUARD SE QUEDA, LA RUTA NO (31/08/2026). Que esta libreria respete lo
# que ya haya definido quien la carga es deliberado; lo que sobraba era
# tener otra copia de la ruta literal. El respaldo sale ahora de
# mediabox-paths.ps1, que es la unica definicion del pipeline y trae ademas
# el fallback al nombre suelto si la ruta de WinGet cambiara.
if (-not $FFMPEG -or -not $FFPROBE) {
    $PathsLib = 'C:\scripts\mediabox-paths.ps1'
    if (Test-Path -LiteralPath $PathsLib) { . $PathsLib }
}

# PgsToSrt (https://github.com/Tentacule/PgsToSrt): descomprimir el release aqui
# y dejar los idiomas (spa.traineddata, eng.traineddata) en 'tessdata'.
if (-not $PgsToSrtDir) { $PgsToSrtDir = "C:\scripts\PgsToSrt" }
$PgsToSrtDll = Join-Path $PgsToSrtDir "PgsToSrt.dll"
$TessdataDir = Join-Path $PgsToSrtDir "tessdata"

# Codecs de subtitulo de TEXTO que ffmpeg sabe pasar a SRT sin OCR.
$SubTextCodecs = @('subrip','srt','text','ass','ssa','mov_text','tx3g','webvtt','subviewer','microdvd')


function Get-OcrLang([string]$Lang) {
    # PgsToSrt usa codigos de Tesseract (3 letras). Sin traineddata para el
    # idioma, el OCR sale ilegible: se cae a 'eng' antes que producir basura.
    switch ($Lang) {
        "spa" { "spa" } "es" { "spa" } "esp" { "spa" }
        "eng" { "eng" } "en" { "eng" }
        default { "eng" }
    }
}


function Test-SubsOcrReady {
    <#
      True si el OCR de consola se puede ejecutar. Se comprueba UNA vez por
      trabajo y se avisa por Log de lo que falta: un OCR que no arranca no debe
      descubrirse pista por pista.
    #>
    $dotnet = Get-DotnetExe
    if (-not $dotnet) {
        Log "  AVISO: no encuentro dotnet. PgsToSrt no podra ejecutarse."
        return $false
    }
    if (-not (Test-Path -LiteralPath $PgsToSrtDll)) {
        Log "  AVISO: no se encuentra PgsToSrt.dll en '$PgsToSrtDll'. Las pistas PGS no se podran pasar a SRT."
        return $false
    }
    return $true
}


function Get-DotnetExe {
    $d = 'C:\Program Files\dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $d) { return $d }
    $c = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}


function Convert-SubToSrt {
    <#
      Convierte la pista de subtitulos numero $SubOrdinal (el N de 0:s:N) de
      $InputFile y deja un .srt en $OutFile.

      Devuelve un objeto con:
        Ok      - $true si $OutFile es un SRT valido
        Method  - 'copy' (ya era SRT) | 'text' (ass/ssa/... via ffmpeg) | 'ocr'
        Empty   - $true si la pista venia VACIA de origen (no es un fallo)
        TimedOut- $true si el OCR fue MATADO por timeout. Es un fallo TRANSITORIO
                  (el mismo .sup convierte en ~20s con la maquina libre): el
                  llamante debe REENCOLAR, no degradar a PGS-imagen. Ver encode.ps1.
        OcrLang - idioma de Tesseract usado, solo en OCR
        Reason  - motivo cuando Ok es $false
    #>
    param(
        [Parameter(Mandatory)][string]$InputFile,
        [Parameter(Mandatory)][int]$SubOrdinal,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Codec     = '',
        [string]$Lang      = 'und',
        [string]$WorkDir   = '',
        # 12 min, no 5. El default lo usan los llamantes que no lo pasan -hoy el
        # remux del panel-, y con 5 min ese camino se quedaba con el timeout viejo
        # mientras encode.ps1 ya pedia 12: la MISMA libreria con dos politicas.
        # Aislada, una pista tarda ~20 s (36x de margen), asi que 12 min solo salta
        # con contencion real de CPU. Ver ocr-pgs-velocidad-y-timeout.
        [int]   $TimeoutMs = 720000
    )

    $r = [pscustomobject]@{ Ok = $false; Method = ''; Empty = $false; TimedOut = $false; OcrLang = ''; Reason = '' }

    if (-not $Codec) {
        $Codec = (& $FFPROBE -v error -select_streams "s:$SubOrdinal" `
                  -show_entries stream=codec_name -of csv=p=0 $InputFile 2>$null)
        $Codec = "$Codec".Trim()
    }
    $Codec = $Codec.ToLower()
    if (-not $WorkDir) { $WorkDir = Split-Path $OutFile -Parent }

    Remove-Item -LiteralPath $OutFile -ErrorAction SilentlyContinue

    # ---- texto: ffmpeg lo pasa a SRT directamente ----------------------
    if ($Codec -in $SubTextCodecs) {
        & $FFMPEG -y -v error -i $InputFile -map "0:s:$SubOrdinal" -c:s srt $OutFile 2>$null
        $r.Method = if ($Codec -in @('subrip','srt','text')) { 'copy' } else { 'text' }
        if ((Test-Path -LiteralPath $OutFile) -and (Get-Item -LiteralPath $OutFile).Length -gt 16) {
            $r.Ok = $true
        } else {
            # Un .srt de <16 bytes no distingue "pista vacia" de "ffmpeg fallo",
            # pero en texto no hay OCR de por medio: si no sale nada, no habia nada.
            $r.Empty = $true
            $r.Reason = "la pista de texto salio vacia"
        }
        return $r
    }

    # ---- VobSub: fuera de alcance -------------------------------------
    if ($Codec -eq 'dvd_subtitle') {
        $r.Reason = "VobSub (dvd_subtitle): PgsToSrt solo entiende PGS, no hay OCR para esto"
        return $r
    }

    if ($Codec -ne 'hdmv_pgs_subtitle') {
        $r.Reason = "codec '$Codec' no convertible a SRT"
        return $r
    }

    # ---- PGS: extraer .sup y pasarle el OCR ---------------------------
    $r.Method  = 'ocr'
    $r.OcrLang = Get-OcrLang $Lang
    $dotnet = Get-DotnetExe
    if (-not $dotnet -or -not (Test-Path -LiteralPath $PgsToSrtDll)) {
        $r.Reason = "OCR no disponible (dotnet o PgsToSrt.dll)"
        return $r
    }

    # Nombre sin espacios: si la ruta lleva el titulo del film, Start-Process la
    # trunca en el primer espacio.
    $tag    = "{0}_{1}" -f ([System.IO.Path]::GetFileNameWithoutExtension($OutFile)), $SubOrdinal
    $tag    = $tag -replace '[^A-Za-z0-9_]','_'
    $tmpSup = Join-Path $WorkDir "$tag.sup"
    $ocrOut = Join-Path $WorkDir "pgs2srt_out_$tag.txt"
    $ocrErr = Join-Path $WorkDir "pgs2srt_err_$tag.txt"
    Remove-Item -LiteralPath $tmpSup -ErrorAction SilentlyContinue

    try {
        & $FFMPEG -y -i $InputFile -map "0:s:$SubOrdinal" -c:s copy $tmpSup 2>$null
        if (-not (Test-Path -LiteralPath $tmpSup)) {
            $r.Reason = "no se pudo extraer el .sup de la pista $SubOrdinal"
            return $r
        }

        $ocrArgs = @($PgsToSrtDll,
                     "--input",  $tmpSup,
                     "--output", $OutFile,
                     "--tesseractlanguage", $r.OcrLang,
                     "--tesseractdata",     $TessdataDir)

        $p = Start-Process -FilePath $dotnet -ArgumentList $ocrArgs -NoNewWindow -PassThru `
                           -RedirectStandardOutput $ocrOut -RedirectStandardError $ocrErr
        # Sin tocar .Handle, el objeto Process no cachea el handle nativo y
        # .ExitCode puede venir a $null tras el WaitForExit: los logs decian
        # "(exit )" y no habia forma de saber si habia ido bien.
        $null = $p.Handle

        # PRIORIDAD DEL HIJO, EXPLICITA (14/08/2026). Windows PROPAGA a los hijos
        # BELOW_NORMAL_PRIORITY_CLASS e IDLE (el resto de clases no se heredan), y
        # la tarea programada que arranca los watchers lleva <Priority>7</Priority>,
        # que es BelowNormal. Resultado: este dotnet nacia en BelowNormal y lo
        # adelantaba cualquier cosa a Normal (JDownloader, eMule, Plex).
        # Medido con la MISMA pista (1114 items): 20 s con la maquina libre, 193 s
        # dentro del pipeline, y >29 min a BelowNormal con 12 competidores a Normal
        # (inanicion, no lentitud). A Normal/AboveNormal el problema desaparece.
        # El SRT sale identico byte a byte en todos los casos: esto es velocidad,
        # no calidad. Mismo criterio y misma clase que atmos-prio-booster.ps1.
        try { $p.PriorityClass = 'AboveNormal' } catch { }

        if (-not $p.WaitForExit($TimeoutMs)) {
            Log "    -> TIMEOUT: PgsToSrt colgado en la pista $SubOrdinal. Se mata el proceso."
            $r.TimedOut = $true
            try { $p.Kill() } catch {}
        }

        # PgsToSrt emite el progreso con retornos de carro y a veces bytes de
        # control / NUL. Escritos crudos en el log, cualquier visor de texto
        # "corta" el fichero ahi: el resto seguia estando pero no se veia.
        $txt = (Get-Content -LiteralPath $ocrOut,$ocrErr -Raw -ErrorAction SilentlyContinue) -join "`n"
        if ($txt) {
            $txt = $txt -replace "`r","`n" -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]',''
            $txt.Split("`n") | Where-Object { $_.Trim() -ne "" } | ForEach-Object { Log "      [ocr] $_" }
        }

        if ((Test-Path -LiteralPath $OutFile) -and (Get-Item -LiteralPath $OutFile).Length -gt 16) {
            $r.Ok = $true
            return $r
        }

        # Pista VACIA en origen (el .sup sale a ~0 bytes) frente a OCR que fallo
        # sobre una pista CON contenido: solo la primera se puede descartar sin
        # perder nada. El llamante necesita la diferencia para decidir.
        $supLen = if (Test-Path -LiteralPath $tmpSup) { (Get-Item -LiteralPath $tmpSup).Length } else { 0 }
        if ($supLen -lt 64) {
            $r.Empty  = $true
            $r.Reason = "pista vacia en origen (.sup $supLen bytes)"
        } else {
            $r.Reason = "PgsToSrt no genero SRT valido (exit $($p.ExitCode), .sup $supLen bytes)"
        }
        return $r
    }
    finally {
        Remove-Item -LiteralPath $tmpSup,$ocrOut,$ocrErr -ErrorAction SilentlyContinue
    }
}


# ------------------------------------------------------------------ cli ---
# Para poder probar una pista suelta sin levantar ningun pipeline:
#   pwsh -File subs-lib.ps1 "peli.mkv" 0 "salida.srt" spa
if ($MyInvocation.InvocationName -ne '.' -and $args.Count -ge 3) {
    $res = Convert-SubToSrt -InputFile $args[0] -SubOrdinal ([int]$args[1]) `
                            -OutFile $args[2] -Lang $(if ($args.Count -ge 4) { $args[3] } else { 'und' })
    $res | Format-List
    if (-not $res.Ok) { exit 1 }
}
