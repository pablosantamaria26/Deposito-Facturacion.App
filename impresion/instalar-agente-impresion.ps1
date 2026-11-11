<#
  INSTALADOR DEL AGENTE DE IMPRESIÓN DE DEPÓSITO (11/11/2026)
  Se corre UNA vez en la PC que tiene la térmica, como administrador (el bloque de instalación lo pide solo).

  1. Copia el agente a C:\ProgramData\MLImpresion (solo Administradores, SYSTEM y este usuario pueden leerlo).
  2. Genera el token de la impresora en esta PC y lo guarda cifrado. NO se muestra ni sale de esta PC: lo que se
     comparte es su huella (código de vinculación), que no sirve para entrar.
  3. Prende el registro de impresión de Windows (así el agente sabe si una etiqueta se entregó o quedó en duda).
  4. Crea la tarea «ML Impresion Deposito»: arranca con Windows, sin necesidad de iniciar sesión ni de tener una
     pestaña abierta, y se revisa cada 5 minutos (si el agente se cerró, vuelve a arrancar).
  5. Imprime UNA «ETIQUETA DE PRUEBA» desde la tarea, para comprobar que imprime en ese contexto. Si no puede,
     cambia la tarea a «al iniciar sesión» y prueba de nuevo.

  Desinstalar: instalar-agente-impresion.ps1 -Desinstalar
#>
param([string]$Agente, [switch]$Desinstalar)
$ErrorActionPreference = "Stop"
$DIR = Join-Path $env:ProgramData "MLImpresion"
$TAREA = "ML Impresion Deposito"
$usuario = "$env:USERDOMAIN\$env:USERNAME"
function Paso($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Bien($t) { Write-Host "   OK  $t" -ForegroundColor Green }
function Mal($t) { Write-Host "   !!  $t" -ForegroundColor Yellow }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Hay que correrlo como administrador (el bloque de instalación lo abre así)."
}

if ($Desinstalar) {
  Unregister-ScheduledTask -TaskName $TAREA -Confirm:$false -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'agente-impresion\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item $DIR -Recurse -Force -ErrorAction SilentlyContinue
  Bien "Agente desinstalado (las etiquetas pendientes quedan en la cola del servidor)."
  return
}

Paso "1 · Copiar el agente"
if (-not $Agente -or -not (Test-Path $Agente)) { throw "Falta el archivo del agente." }
New-Item -ItemType Directory -Force -Path $DIR | Out-Null
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'agente-impresion\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Copy-Item $Agente (Join-Path $DIR "agente-impresion.ps1") -Force
& icacls $DIR /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "${usuario}:(OI)(CI)M" /T /Q | Out-Null
Bien "Agente en $DIR (acceso: Administradores, SYSTEM y $usuario)"

Paso "2 · Impresora"
$imp = Get-Printer | Where-Object { $_.DriverName -match '4BARCODE|4B-2054|LDT|3nstar' } | Select-Object -First 1
if (-not $imp) { throw "No se encontró la impresora térmica (controlador 4BARCODE)." }
Bien "Térmica: $($imp.Name) · puerto $($imp.PortName)"

Paso "3 · Token de la impresora (se genera acá y no sale de esta PC)"
Add-Type -AssemblyName System.Security
$cfgPath = Join-Path $DIR "config.json"
$cfg = if (Test-Path $cfgPath) { Get-Content $cfgPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$token = $null
if ($cfg.PSObject.Properties["token"]) {
  try { $token = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cfg.token), [Text.Encoding]::UTF8.GetBytes("MLImpresion"), "LocalMachine")); Bien "Se conserva el token que ya tenía esta PC" } catch { $token = $null }
}
if (-not $token) {
  $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  $token = "imp_" + (($b | ForEach-Object { $_.ToString("x2") }) -join "")
  Bien "Token nuevo generado"
}
$cifrado = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($token), [Text.Encoding]::UTF8.GetBytes("MLImpresion"), "LocalMachine"))
$sha = [Security.Cryptography.SHA256]::Create()
$huella = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($token)) | ForEach-Object { $_.ToString("x2") }) -join "")
[pscustomobject]@{ api = "https://queruclor-api.santamariapablodaniel.workers.dev"; agente = $env:COMPUTERNAME; impresora = $imp.Name; token = $cifrado } |
  ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8

Paso "4 · Registro de impresión de Windows"
& wevtutil sl Microsoft-Windows-PrintService/Operational /e:true
if ((Get-WinEvent -ListLog "Microsoft-Windows-PrintService/Operational").IsEnabled) { Bien "Registro de impresión prendido" } else { Mal "No se pudo prender el registro: los resultados van a quedar «inciertos»" }

function CrearTarea($modo) {
  Unregister-ScheduledTask -TaskName $TAREA -Confirm:$false -ErrorAction SilentlyContinue
  $accion = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$DIR\agente-impresion.ps1`" -Dir `"$DIR`"" -WorkingDirectory $DIR
  $cada5 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
  $ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
  if ($modo -eq "S4U") {
    $inicio = New-ScheduledTaskTrigger -AtStartup
    $quien = New-ScheduledTaskPrincipal -UserId $usuario -LogonType S4U -RunLevel Limited
  } else {
    $inicio = New-ScheduledTaskTrigger -AtLogOn -User $usuario
    $quien = New-ScheduledTaskPrincipal -UserId $usuario -LogonType Interactive -RunLevel Limited
  }
  Register-ScheduledTask -TaskName $TAREA -Action $accion -Trigger @($inicio, $cada5) -Settings $ajustes -Principal $quien -Description "Imprime las etiquetas que se piden desde Depósito (celular o PC). Mercado Limpio." | Out-Null
}
function ProbarTarea() {
  $res = Join-Path $DIR "imprimir-prueba.resultado"; Remove-Item $res -Force -ErrorAction SilentlyContinue
  Set-Content (Join-Path $DIR "imprimir-prueba.solicitud") "1"
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'agente-impresion\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-ScheduledTask -TaskName $TAREA
  for ($i = 0; $i -lt 120 -and -not (Test-Path $res); $i++) { Start-Sleep -Seconds 1 }
  if (-not (Test-Path $res)) { return @{ estado = "sin respuesta"; error = "La tarea no imprimió en 2 minutos." } }
  Get-Content $res -Raw | ConvertFrom-Json
}

Paso "5 · Tarea que arranca con Windows y prueba de impresión (sale UNA etiqueta de prueba)"
CrearTarea "S4U"
$r = ProbarTarea
if ($r.estado -eq "impresa") { Bien "Arranca con Windows aunque nadie inicie sesión · la prueba se imprimió (papel: $($r.papel))" }
else {
  Mal "Sin sesión iniciada no pudo imprimir ($($r.estado): $($r.error)). Se cambia a «al iniciar sesión»."
  CrearTarea "Interactive"
  $r = ProbarTarea
  if ($r.estado -eq "impresa") { Bien "Arranca al iniciar sesión el usuario $usuario · la prueba se imprimió (papel: $($r.papel))" }
  else { Mal "La prueba no se pudo confirmar ($($r.estado): $($r.error)). Revisar la impresora y volver a correr el instalador." }
}

Paso "6 · Código de vinculación"
try { Set-Clipboard -Value $huella } catch {}
$huella | Set-Content (Join-Path ([Environment]::GetFolderPath("Desktop")) "codigo-vinculacion-impresora.txt") -Encoding ASCII
Write-Host ""
Write-Host "   Código de vinculación (quedó copiado y en el Escritorio):" -ForegroundColor White
Write-Host "   $huella" -ForegroundColor White
Write-Host ""
Write-Host "   Mandáselo a Claude. No es el token: solo sirve para reconocer a esta PC." -ForegroundColor Gray
Write-Host "   ¿Salió la ETIQUETA DE PRUEBA completa y nítida? Avisá también eso." -ForegroundColor Gray
