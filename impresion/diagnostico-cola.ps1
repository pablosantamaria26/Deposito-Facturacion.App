<#
  DIAGNÓSTICO Y CONTENCIÓN DE LA COLA DE IMPRESIÓN DE DEPÓSITO (20/11/2026)

  Para el incidente de etiquetas repetidas. NO borra nada, NO imprime nada, NO toca pedidos.
    1. Pone la impresora térmica en PAUSA y suspende cada trabajo de su cola (así no sale nada más hasta que alguien decida).
    2. Guarda la evidencia en una carpeta del Escritorio (y un .zip con lo mismo):
       · la cola de Windows: cada trabajo con su número, documento, fecha, estado, páginas impresas / totales, tamaño
       · el estado que informa el controlador de la impresora
       · el registro de impresión de Windows (PrintService/Operational) de los últimos 7 días, exportado y en CSV
       · el registro del agente (agente.log) y su diario de trabajos. NUNCA config.json (tiene el token).
       · los procesos del agente que están corriendo y la tarea programada
    3. Muestra un resumen en pantalla.

  Uso (en la PC de Depósito, PowerShell normal, no hace falta administrador para listar):
    powershell -ExecutionPolicy Bypass -File diagnostico-cola.ps1
    powershell -ExecutionPolicy Bypass -File diagnostico-cola.ps1 -SinPausar     (solo mirar, sin pausar)
#>
param([switch]$SinPausar, [string]$Impresora, [string]$Salida, [int]$Dias = 7)
$ErrorActionPreference = "Continue"
$fecha = Get-Date -Format "yyyyMMdd-HHmm"
if (-not $Salida) { $Salida = Join-Path ([Environment]::GetFolderPath("Desktop")) "evidencia-impresion-$fecha" }
New-Item -ItemType Directory -Force -Path $Salida | Out-Null
$resumen = New-Object System.Collections.Generic.List[string]
function Paso($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Nota($t) { Write-Host "   $t"; $script:resumen.Add($t) }
function Guardar($nombre, $obj) {
  $p = Join-Path $Salida $nombre
  if ($obj -is [string]) { $obj | Set-Content -Path $p -Encoding UTF8 }
  elseif ($null -eq $obj -or @($obj).Count -eq 0) { "[]" | Set-Content -Path $p -Encoding UTF8 }
  else { ConvertTo-Json -InputObject @($obj) -Depth 6 | Set-Content -Path $p -Encoding UTF8 }
}

Paso "1 · Impresora"
$imp = if ($Impresora) { Get-Printer -Name $Impresora -ErrorAction SilentlyContinue } else { Get-Printer | Where-Object { $_.DriverName -match '4BARCODE|4B-2054|LDT|3nstar' } | Select-Object -First 1 }
if (-not $imp) { Write-Host "No se encontró la impresora térmica. Impresoras de esta PC:" -ForegroundColor Yellow; Get-Printer | Format-Table Name, DriverName, PortName -AutoSize; exit 1 }
$n = $imp.Name
Nota "Impresora: «$n» · controlador $($imp.DriverName) · puerto $($imp.PortName) · estado Windows: $($imp.PrinterStatus)"
$w = Get-CimInstance Win32_Printer -Filter ("Name='" + $n.Replace("'", "''") + "'") -ErrorAction SilentlyContinue
if ($w) {
  $est = $w | Select-Object Name, PrinterStatus, PrinterState, DetectedErrorState, ExtendedDetectedErrorState, ExtendedPrinterStatus, WorkOffline, Attributes, PortName, DriverName, Default, Shared, Availability
  Guardar "impresora-estado.json" $est
  Nota "Controlador: PrinterStatus=$($w.PrinterStatus) PrinterState=$($w.PrinterState) DetectedErrorState=$($w.DetectedErrorState) ExtendedDetectedErrorState=$($w.ExtendedDetectedErrorState) WorkOffline=$($w.WorkOffline)"
}

Paso "2 · La cola de Windows ANTES de tocar nada"
$jobs = @(Get-PrintJob -PrinterName $n -ErrorAction SilentlyContinue)
$wmi = @(Get-CimInstance Win32_PrintJob -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($n + ",*") })
$lista = foreach ($j in $jobs) {
  $x = $wmi | Where-Object { $_.JobId -eq $j.Id } | Select-Object -First 1
  [pscustomobject]@{
    Id = $j.Id; Documento = $j.DocumentName; Usuario = $j.UserName; Enviado = $j.SubmittedTime; Estado = [string]$j.JobStatus
    PaginasImpresas = $j.PagesPrinted; PaginasTotales = $j.TotalPages; Bytes = $j.Size; Posicion = $j.Position; Prioridad = $j.Priority
    WmiStatus = $(if ($x) { $x.Status } else { $null }); WmiStatusMask = $(if ($x) { $x.StatusMask } else { $null })
    WmiInicio = $(if ($x) { $x.StartTime } else { $null }); WmiTranscurrido = $(if ($x) { [string]$x.ElapsedTime } else { $null })
    WmiTipoDatos = $(if ($x) { $x.DataType } else { $null }); WmiPaginasImpresas = $(if ($x) { $x.PagesPrinted } else { $null }); WmiPaginasTotales = $(if ($x) { $x.TotalPages } else { $null })
    # Trabajo del agente de Depósito: el documento se llama ML-etiqueta-<id del trabajo en el sistema>
    TrabajoSistema = $(if ($j.DocumentName -match '^ML-etiqueta-(.+)$') { $Matches[1] } else { "" })
  }
}
Guardar "cola-windows.json" $lista
($lista | Format-Table Id, Documento, Enviado, Estado, PaginasImpresas, PaginasTotales, Bytes, TrabajoSistema -AutoSize | Out-String -Width 300) | Set-Content (Join-Path $Salida "cola-windows.txt") -Encoding UTF8
Nota "Trabajos en la cola: $($jobs.Count)"
foreach ($l in $lista) { Nota ("   #" + $l.Id + " · " + $l.Documento + " · " + $l.Enviado + " · " + $l.Estado + " · págs " + $l.PaginasImpresas + "/" + $l.PaginasTotales + " · " + [math]::Round($l.Bytes / 1MB, 1) + " MB" + $(if ($l.TrabajoSistema) { " · sistema " + $l.TrabajoSistema } else { " · NO es del agente" })) }

if (-not $SinPausar) {
  Paso "3 · Pausar (impresora y cada trabajo)"
  try { $r = Invoke-CimMethod -InputObject $w -MethodName Pause -ErrorAction Stop; Nota "Impresora en pausa (código $($r.ReturnValue); 0 = bien, 5 = sin permiso)" } catch { Nota "No se pudo pausar la impresora desde acá: $($_.Exception.Message)" }
  foreach ($j in $jobs) { try { Suspend-PrintJob -InputObject $j -ErrorAction Stop; Nota "Trabajo #$($j.Id) suspendido" } catch { Nota "Trabajo #$($j.Id): no se pudo suspender ($($_.Exception.Message))" } }
  $despues = @(Get-PrintJob -PrinterName $n -ErrorAction SilentlyContinue | Select-Object Id, DocumentName, JobStatus, PagesPrinted, TotalPages)
  Guardar "cola-windows-despues-de-pausar.json" $despues
} else { Paso "3 · (sin pausar, por pedido)" }

Paso "4 · Registro de impresión de Windows (últimos $Dias días)"
$LOGW = "Microsoft-Windows-PrintService/Operational"
try { $activo = (Get-WinEvent -ListLog $LOGW -ErrorAction Stop).IsEnabled } catch { $activo = $false }
Nota "Registro PrintService/Operational: $(if ($activo) { 'activo' } else { 'APAGADO' })"
try { & wevtutil epl $LOGW (Join-Path $Salida "PrintService-Operational.evtx") 2>$null; Nota "Exportado PrintService-Operational.evtx" } catch { Nota "No se pudo exportar el .evtx: $($_.Exception.Message)" }
try {
  $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $LOGW; StartTime = (Get-Date).AddDays(-$Dias) } -ErrorAction Stop)
  $filas = foreach ($e in $ev) {
    $props = @($e.Properties | ForEach-Object { [string]$_.Value })
    [pscustomobject]@{ Fecha = $e.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss"); Id = $e.Id; Nivel = $e.LevelDisplayName; Propiedades = ($props -join " | "); Mensaje = (($e.Message -replace "\s+", " ")).Trim() }
  }
  $filas | Export-Csv -Path (Join-Path $Salida "PrintService-eventos.csv") -NoTypeInformation -Encoding UTF8
  Nota ("Eventos: " + $ev.Count + " · por tipo: " + (($ev | Group-Object Id | Sort-Object Name | ForEach-Object { "$($_.Name)×$($_.Count)" }) -join ", "))
  # Lo que más importa: 307 = entregado a la impresora · 310 = borrado de la cola · 800/801/842 = recibido, imprimiendo, mandado al puerto
  $clave = $ev | Where-Object { $_.Id -in 307, 310, 800, 801, 805, 842 } | Sort-Object TimeCreated
  $txt = foreach ($e in $clave) { $p = @($e.Properties | ForEach-Object { [string]$_.Value }); $e.TimeCreated.ToString("dd/MM HH:mm:ss") + "  " + $e.Id + "  " + ($p -join " | ") }
  Guardar "PrintService-trabajos.txt" (($txt -join "`r`n"))
} catch { Nota "No se pudieron leer los eventos: $($_.Exception.Message)" }

Paso "5 · Agente de impresión (registro y diario; nunca config.json)"
$dirs = @((Join-Path $env:ProgramData "MLImpresion"), (Join-Path $env:LOCALAPPDATA "MLImpresion")) | Where-Object { Test-Path $_ }
foreach ($d in $dirs) {
  $dest = Join-Path $Salida ("agente-" + ($d -replace '[:\\]', '_')); New-Item -ItemType Directory -Force -Path $dest | Out-Null
  foreach ($f in "agente.log", "agente.log.anterior", "imprimir-prueba.resultado") { $src = Join-Path $d $f; if (Test-Path $src) { Copy-Item $src $dest -Force } }
  if (Test-Path (Join-Path $d "diario")) { Copy-Item (Join-Path $d "diario") (Join-Path $dest "diario") -Recurse -Force }
  if (Test-Path (Join-Path $d "trabajo")) { Get-ChildItem (Join-Path $d "trabajo") | Select-Object Name, Length, LastWriteTime | ConvertTo-Json | Set-Content (Join-Path $dest "trabajo-archivos.json") -Encoding UTF8 }
  $ag = Join-Path $d "agente-impresion.ps1"
  if (Test-Path $ag) { Copy-Item $ag (Join-Path $dest "agente-impresion.instalado.ps1") -Force; $v = (Select-String -Path $ag -Pattern '^\$VERSION\s*=\s*"([^"]+)"' | Select-Object -First 1); Nota ("Agente instalado en " + $d + ": versión " + $(if ($v) { $v.Matches[0].Groups[1].Value } else { "?" })) }
  Nota "Copiado el registro y el diario de $d (sin config.json)"
}
if (-not $dirs) { Nota "No hay carpeta MLImpresion en esta PC" }
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { [string]$_.CommandLine -match 'agente-impresion\.ps1' } | Select-Object ProcessId, CreationDate, CommandLine)
Guardar "agente-procesos.json" $procs
Nota "Procesos del agente corriendo: $($procs.Count)"
try { $t = Get-ScheduledTask -TaskName "ML Impresion Deposito" -ErrorAction Stop; $ti = $t | Get-ScheduledTaskInfo; Guardar "agente-tarea.json" ([pscustomobject]@{ Estado = [string]$t.State; UltimaCorrida = $ti.LastRunTime; UltimoResultado = $ti.LastTaskResult; ProximaCorrida = $ti.NextRunTime; Principal = $t.Principal.UserId; Logon = [string]$t.Principal.LogonType }); Nota "Tarea «ML Impresion Deposito»: $($t.State) · última corrida $($ti.LastRunTime) · resultado $($ti.LastTaskResult)" } catch { Nota "Tarea programada: no se pudo leer ($($_.Exception.Message))" }

Paso "6 · Resumen"
Guardar "RESUMEN.txt" (("Diagnóstico de la cola de impresión · " + (Get-Date).ToString("dd/MM/yyyy HH:mm") + " · PC " + $env:COMPUTERNAME + "`r`n`r`n") + ($resumen -join "`r`n"))
try { Compress-Archive -Path (Join-Path $Salida "*") -DestinationPath ($Salida + ".zip") -Force; Write-Host "   Evidencia: $Salida  y  $Salida.zip" -ForegroundColor Green } catch { Write-Host "   Evidencia en: $Salida (no se pudo comprimir: $($_.Exception.Message))" -ForegroundColor Yellow }
Write-Host ""
Write-Host "Listo. NO se borró nada. Mandá el .zip del Escritorio. Para cancelar trabajos puntuales, después: cancelar-trabajos.ps1 -Ids <números>" -ForegroundColor White
