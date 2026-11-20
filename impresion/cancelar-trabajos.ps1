<#
  CANCELAR TRABAJOS PUNTUALES DE LA COLA DE LA TÉRMICA Y, SI SE PIDE, REANUDAR (20/11/2026)

  Borra SOLO los trabajos cuyos números se pasan en -Ids (los números son los de diagnostico-cola.ps1 / «Ver lo que se
  está imprimiendo»). Antes de borrar guarda otra vez la cola en el Escritorio. Los demás trabajos quedan como están.
  Con -Reanudar, al final saca la impresora de pausa y reanuda los trabajos que quedaron (si no se pasa, sigue en pausa).

  Uso:
    powershell -ExecutionPolicy Bypass -File cancelar-trabajos.ps1 -Ids 12,13,15
    powershell -ExecutionPolicy Bypass -File cancelar-trabajos.ps1 -Ids 12 -Reanudar
    powershell -ExecutionPolicy Bypass -File cancelar-trabajos.ps1 -Reanudar          (no borra nada: solo reanuda)
#>
param([string[]]$Ids = @(), [switch]$Reanudar, [string]$Impresora)
# Llamado con -File, «46,4» llega como UN texto y en español se lee 464: se separa por coma y por espacio.
$Ids = @($Ids | ForEach-Object { [string]$_ -split "[,; ]+" } | Where-Object { $_ -match "^d+$" } | ForEach-Object { [int]$_ })
$ErrorActionPreference = "Continue"
$fecha = Get-Date -Format "yyyyMMdd-HHmmss"
$Salida = Join-Path ([Environment]::GetFolderPath("Desktop")) "evidencia-impresion-cancelacion-$fecha"
New-Item -ItemType Directory -Force -Path $Salida | Out-Null
$imp = if ($Impresora) { Get-Printer -Name $Impresora -ErrorAction SilentlyContinue } else { Get-Printer | Where-Object { $_.DriverName -match '4BARCODE|4B-2054|LDT|3nstar' } | Select-Object -First 1 }
if (-not $imp) { Write-Host "No se encontró la impresora térmica." -ForegroundColor Yellow; exit 1 }
$n = $imp.Name
$antes = @(Get-PrintJob -PrinterName $n -ErrorAction SilentlyContinue | Select-Object Id, DocumentName, UserName, SubmittedTime, @{ n = "Estado"; e = { [string]$_.JobStatus } }, PagesPrinted, TotalPages, Size)
$antes | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Salida "cola-antes.json") -Encoding UTF8
Write-Host "Cola antes ($($antes.Count) trabajos):"; $antes | Format-Table Id, DocumentName, SubmittedTime, Estado, PagesPrinted, TotalPages -AutoSize | Out-Host
$registro = New-Object System.Collections.Generic.List[string]
foreach ($id in $Ids) {
  $j = $antes | Where-Object { $_.Id -eq $id } | Select-Object -First 1
  if (-not $j) { $registro.Add("#$id no está en la cola: no se tocó"); Write-Host "   #$id no está en la cola" -ForegroundColor Yellow; continue }
  try { Remove-PrintJob -PrinterName $n -ID $id -ErrorAction Stop; $registro.Add("#$id BORRADO · " + $j.DocumentName + " · " + $j.SubmittedTime + " · " + $j.Estado + " · págs " + $j.PagesPrinted + "/" + $j.TotalPages); Write-Host "   #$id borrado ($($j.DocumentName))" -ForegroundColor Green }
  catch { $registro.Add("#$id NO se pudo borrar: " + $_.Exception.Message); Write-Host "   #$id no se pudo borrar: $($_.Exception.Message)" -ForegroundColor Red }
}
Start-Sleep -Seconds 2
if ($Reanudar) {
  $w = Get-CimInstance Win32_Printer -Filter ("Name='" + $n.Replace("'", "''") + "'") -ErrorAction SilentlyContinue
  try { $r = Invoke-CimMethod -InputObject $w -MethodName Resume -ErrorAction Stop; $registro.Add("Impresora reanudada (código $($r.ReturnValue))"); Write-Host "   Impresora reanudada" -ForegroundColor Green } catch { $registro.Add("No se pudo reanudar la impresora: " + $_.Exception.Message); Write-Host "   No se pudo reanudar la impresora: $($_.Exception.Message)" -ForegroundColor Red }
  foreach ($j in @(Get-PrintJob -PrinterName $n -ErrorAction SilentlyContinue)) { try { Resume-PrintJob -InputObject $j -ErrorAction Stop; $registro.Add("Trabajo #$($j.Id) reanudado") } catch { $registro.Add("Trabajo #$($j.Id): no se pudo reanudar (" + $_.Exception.Message + ")") } }
} else { $registro.Add("La impresora sigue EN PAUSA (no se pidió -Reanudar)") }
$despues = @(Get-PrintJob -PrinterName $n -ErrorAction SilentlyContinue | Select-Object Id, DocumentName, SubmittedTime, @{ n = "Estado"; e = { [string]$_.JobStatus } }, PagesPrinted, TotalPages)
$despues | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Salida "cola-despues.json") -Encoding UTF8
(("Cancelación de trabajos · " + (Get-Date).ToString("dd/MM/yyyy HH:mm:ss") + " · PC " + $env:COMPUTERNAME + " · impresora " + $n + "`r`n") + ($registro -join "`r`n")) | Set-Content (Join-Path $Salida "REGISTRO.txt") -Encoding UTF8
Write-Host ""; Write-Host "Cola después ($($despues.Count) trabajos):"; $despues | Format-Table Id, DocumentName, SubmittedTime, Estado, PagesPrinted, TotalPages -AutoSize | Out-Host
Write-Host "Registro guardado en $Salida" -ForegroundColor White
