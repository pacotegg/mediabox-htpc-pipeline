<#
============================================================================
 jd-api-setup.ps1  -  Abre la API local de JDownloader. Se ejecuta UNA vez.
============================================================================
 QUE HACE Y POR QUE HACE FALTA
 -----------------------------
 La API DEPRECATED de JD -la que usa descargas-tanda.ps1- escucha en el
 puerto 'deprecatedapiport' (3128 de fabrica) y SOLO si
 'deprecatedapienabled' esta en true. Este script pone ese interruptor.

 OJO CON EL 9666: ese puerto es el EXTERNAL INTERFACE (FlashGot), otro
 servidor distinto que esta siempre encendido y responde 501 a todo lo que
 no sea /flash/. Confundirlos manda a diagnosticar la puerta equivocada.

 POR QUE HAY QUE CERRAR JD PARA TOCAR LA CONFIG: JD mantiene su configuracion
 en memoria y la REESCRIBE ENTERA al salir. Si se edita el JSON con JD vivo,
 el cambio parece aplicado -el fichero lo tiene- y desaparece en cuanto se
 cierra el programa. Es un fallo silencioso de manual: nada da error y a la
 siguiente sesion la API vuelve a responder 501.

 EL CIERRE ES SUAVE Y NO SE FUERZA NUNCA. CloseMainWindow() es el equivalente
 a darle a la X: JD guarda la lista de descargas y el linkgrabber -que aqui
 son cientos de enlaces- antes de irse. Un Stop-Process -Force se los saltaria
 y la cola podria retroceder a su ultimo autoguardado. Si JD no cierra en el
 plazo, este script NO insiste: lo dice y sale sin tocar nada.

 Las descargas EN CURSO no se pierden al reiniciar JD: quedan como parciales
 y se reanudan solas al volver. Solo se pierde lo que el host no permita
 reanudar, que es cosa del host y no de esto.

   Uso:  pwsh -File C:\scripts\jd-api-setup.ps1
         pwsh -File C:\scripts\jd-api-setup.ps1 -SoloVerificar

 NOTA: fichero en ASCII puro (codigo Y comentarios).
============================================================================
#>

[CmdletBinding()]
param(
    # Comprueba el estado y no cambia nada. Para saber si hace falta o no.
    [switch]$SoloVerificar,
    # Segundos de margen para que JD cierre por su cuenta y para que arranque.
    [int]$TimeoutCierreSeg   = 90,
    [int]$TimeoutArranqueSeg = 180
)

$ErrorActionPreference = 'Stop'

$JdDir  = 'C:\Users\HTPC\AppData\Local\JDownloader 2'
$JdExe  = Join-Path $JdDir 'JDownloader2.exe'
$CfgFic = Join-Path $JdDir 'cfg\org.jdownloader.api.RemoteAPIConfig.json'

# La libreria da Test-JdApi y el puerto. Ruta absoluta con respaldo, regla del
# proyecto: nada depende del PATH ni del directorio de trabajo.
$Lib = Join-Path $PSScriptRoot 'jd-lib.ps1'
if (-not (Test-Path -LiteralPath $Lib)) { $Lib = 'C:\scripts\jd-lib.ps1' }
. $Lib

function Write-Paso([string]$txt) { Write-Host "[jd-api-setup] $txt" }

# ---------------------------------------------------------------------------
# CIERRE SUAVE DE UNA APP QUE VIVE EN LA BANDEJA
# ---------------------------------------------------------------------------
# CloseMainWindow() NO BASTA AQUI, y el sintoma es de los que se tragan una
# hora: JDownloader corre minimizado en la bandeja del sistema, y entonces
# MainWindowHandle vale 0, CloseMainWindow() no tiene ventana a la que mandar
# el mensaje, devuelve false y NO HACE NADA. El script esperaba sus 90 s y se
# rendia sin que hubiera pasado absolutamente nada (08/09/2026).
#
# El plan B es mandar WM_CLOSE directamente a la ventana del proceso -la que
# se titula 'JDownloader 2', aunque este oculta-, que es EXACTAMENTE el mensaje
# que manda la X. JD hace su cierre normal y guarda el linkgrabber al salir.
# SIGUE SIN FORZARSE NADA: aqui no hay ni un Stop-Process ni un -Force.
if (-not ('JdVentanas' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class JdVentanas {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    const uint WM_CLOSE = 0x0010;
    public static int CerrarDe(uint pidBuscado, string titulo) {
        int enviados = 0;
        EnumWindows((h, l) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == pidBuscado) {
                int len = GetWindowTextLength(h);
                StringBuilder sb = new StringBuilder(len + 1);
                GetWindowText(h, sb, sb.Capacity);
                if (sb.ToString() == titulo) {
                    PostMessage(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                    enviados++;
                }
            }
            return true;
        }, IntPtr.Zero);
        return enviados;
    }
}
'@
}

if (-not (Test-Path -LiteralPath $CfgFic)) {
    Write-Paso "ERROR: no encuentro la config de JD en '$CfgFic'."
    exit 1
}

# --- Estado actual ---------------------------------------------------------
$cfg = Get-Content -LiteralPath $CfgFic -Raw | ConvertFrom-Json
$yaActiva = [bool]$cfg.deprecatedapienabled
$externOn = [bool]$cfg.externinterfaceenabled

Write-Paso "config    : deprecatedapienabled=$yaActiva  externinterfaceenabled=$externOn"
$responde = Test-JdApi
Write-Paso "API $JdApiPuerto  : $(if ($responde) { 'RESPONDE' } else { 'no responde' })"

if ($responde) {
    Write-Paso "Nada que hacer: la API local ya esta abierta."
    exit 0
}
if ($SoloVerificar) {
    Write-Paso "Hace falta abrirla. Ejecuta este mismo script sin -SoloVerificar."
    exit 2
}

# --- Cerrar JD suavemente --------------------------------------------------
# Se busca por nombre de proceso Y por el .pid que deja JD, porque el proceso
# visible puede ser el lanzador y no el que tiene la ventana.
$procs = @(Get-Process -Name 'JDownloader2' -ErrorAction SilentlyContinue)
if ($procs.Count) {
    Write-Paso "Cerrando JDownloader (PID $($procs.Id -join ', ')) - guarda su lista al salir..."
    foreach ($p in $procs) {
        $cerrado = $false
        if ($p.MainWindowHandle -ne 0) { $cerrado = $p.CloseMainWindow() }
        if (-not $cerrado) {
            # Ventana principal a 0 = esta en la bandeja. Ver la cabecera.
            $n = [JdVentanas]::CerrarDe([uint32]$p.Id, 'JDownloader 2')
            Write-Paso "  esta en la bandeja del sistema: WM_CLOSE a $n ventana(s)."
        }
    }

    $limite = (Get-Date).AddSeconds($TimeoutCierreSeg)
    while ((Get-Date) -lt $limite) {
        $vivos = @(Get-Process -Name 'JDownloader2' -ErrorAction SilentlyContinue)
        if (-not $vivos.Count) { break }
        Start-Sleep -Seconds 2
    }
    $vivos = @(Get-Process -Name 'JDownloader2' -ErrorAction SilentlyContinue)
    if ($vivos.Count) {
        # No se fuerza. Un JD matado a lo bruto puede perder la cola entera,
        # y aqui son cientos de enlaces: no compensa por un interruptor.
        Write-Paso "JDownloader sigue abierto tras $TimeoutCierreSeg s (dialogo abierto?)."
        Write-Paso "Cierralo tu a mano y vuelve a ejecutar este script. No se ha tocado nada."
        exit 3
    }
    Write-Paso "JDownloader cerrado."
} else {
    Write-Paso "JDownloader no estaba corriendo."
}

# --- Editar la config ------------------------------------------------------
$copia = "$CfgFic.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $CfgFic -Destination $copia -ErrorAction Stop
Write-Paso "Copia de seguridad: $copia"

$cfg = Get-Content -LiteralPath $CfgFic -Raw | ConvertFrom-Json
$cfg.deprecatedapienabled = $true
# externinterfaceenabled ya estaba en true aqui, pero se fuerza igual: sin el
# no escucha nadie en el interface externo y el sintoma seria parecido.
$cfg | Add-Member -NotePropertyName 'externinterfaceenabled' -NotePropertyValue $true -Force
# localhostonly se DEJA COMO ESTA (true): la API no debe salir de la maquina.

# Sin BOM, como todos los ficheros de estado del pipeline: JD lee este JSON
# con un parser de Java y un BOM delante lo puede tumbar.
$json = $cfg | ConvertTo-Json -Depth 10 -Compress
[System.IO.File]::WriteAllText($CfgFic, $json, [System.Text.UTF8Encoding]::new($false))
Write-Paso "deprecatedapienabled = true escrito."

# --- Arrancar JD y verificar ----------------------------------------------
if (-not (Test-Path -LiteralPath $JdExe)) {
    Write-Paso "AVISO: no encuentro '$JdExe'. Arranca JDownloader tu y comprueba con -SoloVerificar."
    exit 0
}
Write-Paso "Arrancando JDownloader..."
# Sin -PassThru: aqui no se mira el ExitCode, y pedirlo sin materializar el
# handle es el patron que deja ExitCode en \$null y confunde al que lo lea.
Start-Process -FilePath $JdExe -WorkingDirectory $JdDir

$limite = (Get-Date).AddSeconds($TimeoutArranqueSeg)
while ((Get-Date) -lt $limite) {
    Start-Sleep -Seconds 5
    # El aprendizaje del escapado vive en $script:JdEscape de la libreria; en
    # cada intento se reinicia para que un fallo temprano no lo deje fijado
    # en un modo que en realidad no se llego a probar.
    $script:JdEscape = 'auto'
    if (Test-JdApi) {
        Write-Paso "LISTO: la API local responde en $JdApiBase (modo query: $script:JdEscape)."
        Write-Paso "Ya puedes usar descargas-tanda.ps1."
        exit 0
    }
}
Write-Paso "JD arranco pero la API sigue sin responder tras $TimeoutArranqueSeg s."
Write-Paso "Comprueba en JD: Configuracion > Ajustes avanzados > 'RemoteAPI: Deprecated Api Enabled'."
exit 4
