---
paths:
  - "**/*.ps1"
  - "**/*.psm1"
  - "**/*.psd1"
---

<!-- Destino: ~/.claude/rules/powershell7.md  (nivel usuario: aplica a TODOS tus proyectos). -->
<!-- Solo se carga cuando Claude abre un .ps1/.psm1/.psd1, no en todas las sesiones. -->
<!-- Fuente: gotchas ya medidos y documentados en las skills ps7-edit-guard, mediabox-ops, -->
<!-- encode-ab-test y sincronizar-doblaje-montajes. Este fichero es ahora la copia canónica. -->

# PowerShell 7

Todo el código es para **PowerShell 7** (`pwsh`), nunca Windows PowerShell 5.1. Invocar siempre
`pwsh.exe` por ruta completa en tareas programadas y lanzadores: `powershell` a secas resuelve a 5.1.

## Gotchas que ya han costado tiempo — no reintroducirlos

| Síntoma | Causa | Arreglo |
|---|---|---|
| Ruta rota al interpolar variable seguida de `:` | `$i:` se lee como *drive qualifier* | `${i}` |
| Falla con rutas con espacios, corchetes o acentos | quoting global insuficiente | quoting **por elemento** del array de argumentos |
| `Test-Path`/`Remove-Item`/`Get-Item` dan falso negativo | `[corchetes]` son comodines (clase de caracteres) | `-LiteralPath` siempre |
| `-LiteralPath "carpeta\*"` → "no existe" | `-LiteralPath` **no expande comodines**: busca una carpeta llamada `*` | `Get-ChildItem -LiteralPath $dir \| Copy-Item -Destination $dst` |
| `ExitCode` sale `null` en `Start-Process` | el handle no se ha materializado | `$null = $proc.Handle` antes de esperar |
| Se pierde un parámetro nombrado | el splatting de **array** pasa por POSICIÓN | splatting de **hashtable** si hay parámetros nombrados |
| Un proceso "correcto" con fichero de 0 bytes | `Test-Path` a secas lo da por bueno | comprobar además el tamaño |
| `[double]::TryParse('34.5')` → `345` | cultura `es-ES`: `.` es separador de miles | parsear en `InvariantCulture` (el *cast* `[double]` ya lo hace) |
| No se ven los argumentos de un proceso | `tasklist /v` no los expone | consultar por CIM (`Win32_Process`) |
| PATH truncado | `setx` corta a 1024 caracteres | escribir en el registro |
| Temporales huérfanos tras matar un proceso | `Stop-Process -Force` **no ejecuta el `finally`** | barrido explícito por patrón |

## Logging
- `Write-Host` **no pasa por la tubería**: `Tee-Object` no lo captura, `Start-Transcript` sí.
- Para capturar una ejecución completa, transcript. Un log que oculta errores es peor que no tener log.
- Nombres con corchetes (`[YTS.MX]`) rompen `Tee-Object`: `Write-Host` + `Add-Content -LiteralPath`.

## Codificación de fichero
- Editar preservando el BOM existente. No introducir caracteres no ASCII nuevos en ficheros que son ASCII.
- Ficheros de estado que lee otro proceso: sin BOM, `[System.Text.UTF8Encoding]::new($false)`.

## Después de tocar un .ps1 — obligatorio antes de darlo por bueno
```powershell
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
if ($errs) { $errs } else { "Sintaxis OK" }
```
Comprobar además que el BOM sigue como estaba y el balance de llaves del bloque tocado.
