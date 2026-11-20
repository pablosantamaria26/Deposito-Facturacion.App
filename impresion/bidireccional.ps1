<#
  COMPATIBILIDAD BIDIRECCIONAL DEL PUERTO DE LA TÉRMICA (21/11/2026) — prueba REVERSIBLE

  Por qué: el 20/11 el trabajo de Pizzurno quedó retenido en Windows como «Complete» (entregado a la impresora, pero sin que el
  controlador confirmara nada), y cada vez que la impresora volvía Windows lo reenviaba. Con la compatibilidad bidireccional
  desactivada, Windows da por terminado el trabajo al mandarlo y lo saca de la cola. La contra: la impresora deja de informar
  «sin papel / tapa abierta» a Windows (y al agente): hay que medir las dos cosas, antes y después, con el mismo guion.

  Uso (PowerShell como administrador, en la PC de Depósito):
    bidireccional.ps1 -Ver            muestra cómo está (no cambia nada)
    bidireccional.ps1 -Desactivar     guarda el estado anterior en el Escritorio y desactiva
    bidireccional.ps1 -Activar        vuelve a activar (o restaura lo guardado)
  Guion de prueba para ANTES y DESPUÉS de cambiarlo (una etiqueta de prueba por caso, desde el celular o `agente-impresion.ps1 -Prueba`):
    1. con rollo: ¿el trabajo desaparece de la cola al terminar? (Get-PrintJob)      2. sin rollo antes de empezar: ¿qué informa el agente?
    3. rollo que se acaba a mitad de una tira corta: ¿detenida? ¿continúa sola al reponer?  4. tapa abierta   5. USB desenchufado
#>
param([switch]$Ver, [switch]$Desactivar, [switch]$Activar, [string]$Impresora)
$ErrorActionPreference = "Stop"
$imp = if ($Impresora) { Get-Printer -Name $Impresora } else { Get-Printer | Where-Object { $_.DriverName -match '4BARCODE|4B-2054|LDT|3nstar' } | Select-Object -First 1 }
if (-not $imp) { throw "No se encontró la impresora térmica." }
$w = Get-CimInstance Win32_Printer -Filter ("Name='" + $imp.Name.Replace("'", "''") + "'")
# Atributo PRINTER_ATTRIBUTE_ENABLE_BIDI = 0x800 (2048) en Win32_Printer.Attributes
$bidi = ([int]$w.Attributes -band 2048) -ne 0
$registro = Join-Path ([Environment]::GetFolderPath("Desktop")) "bidireccional-registro.txt"
function Anotar($t) { Add-Content -Path $registro -Value ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "  " + $t) -Encoding UTF8; Write-Host $t }
Write-Host "Impresora: $($imp.Name) · puerto $($imp.PortName) · bidireccional: $(if ($bidi) { 'ACTIVADA' } else { 'desactivada' }) · Attributes=$($w.Attributes) · trabajos en cola: $((Get-PrintJob -PrinterName $imp.Name | Measure-Object).Count)"
if ($Ver -or (-not $Desactivar -and -not $Activar)) { return }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Para cambiarlo hay que correrlo como administrador." }
if ((Get-PrintJob -PrinterName $imp.Name | Measure-Object).Count) { throw "Hay trabajos en la cola: resolvelos antes de cambiar el puerto." }
if ($Desactivar) {
  Anotar "ANTES de desactivar: bidireccional=$bidi Attributes=$($w.Attributes)"
  & rundll32 printui.dll,PrintUIEntry /Xs /n $imp.Name attributes -EnableBidi
  Start-Sleep -Seconds 2
} elseif ($Activar) {
  Anotar "ANTES de activar: bidireccional=$bidi Attributes=$($w.Attributes)"
  & rundll32 printui.dll,PrintUIEntry /Xs /n $imp.Name attributes +EnableBidi
  Start-Sleep -Seconds 2
}
$w2 = Get-CimInstance Win32_Printer -Filter ("Name='" + $imp.Name.Replace("'", "''") + "'")
$bidi2 = ([int]$w2.Attributes -band 2048) -ne 0
Anotar "DESPUÉS: bidireccional=$bidi2 Attributes=$($w2.Attributes)"
if ($Desactivar -and $bidi2) { Write-Host "No cambió. Alternativa manual: Propiedades de impresora → Puertos → destildar «Habilitar compatibilidad bidireccional»." -ForegroundColor Yellow }
if ($Activar -and -not $bidi2) { Write-Host "No cambió. Alternativa manual: Propiedades de impresora → Puertos → tildar «Habilitar compatibilidad bidireccional»." -ForegroundColor Yellow }
Write-Host "Registro en $registro"
