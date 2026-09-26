#Requires -Version 7
<#
    Hook PostToolUse: comprueba la sintaxis de un .ps1/.psm1/.psd1 justo despues de que
    Claude lo edite. Convierte el "obligatorio" de la skill ps7-edit-guard en automatico.

    Se invoca con -File, NUNCA con -Command: segun la skill mediabox-ops, la logica dentro
    de pwsh -Command "..." lanzado desde cmd fallaba de formas mudas. -File no tiene ese problema.

    Entrada: JSON por stdin. NO existe la variable CLAUDE_FILE_PATHS (el ejemplo que circula
    por algunos tutoriales usandola no funciona: el hook corre y no hace nada).

    Salida: silencio si la sintaxis esta bien. Si esta rota, JSON con systemMessage.

    Fichero en ASCII puro a proposito, sin acentos.
#>

$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json
}
catch {
    # Un hook que revienta no debe estorbar la sesion. Salir en silencio.
    exit 0
}

$path = $payload.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($path)) { exit 0 }
if ($path -notmatch '\.ps(m|d)?1$')      { exit 0 }

# -LiteralPath obligatorio: los [corchetes] son comodines en PowerShell
if (-not (Test-Path -LiteralPath $path)) { exit 0 }

$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)

if ($errs) {
    $detalle = ($errs | ForEach-Object {
        "  linea {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message
    }) -join [Environment]::NewLine

    $msg = "SINTAXIS ROTA tras editar {0}{1}{2}" -f $path, [Environment]::NewLine, $detalle
    @{ systemMessage = $msg } | ConvertTo-Json -Compress
}

exit 0
