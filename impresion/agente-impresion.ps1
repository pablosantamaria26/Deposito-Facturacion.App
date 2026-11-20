<#
  AGENTE DE IMPRESIÓN DE DEPÓSITO (11/11/2026 · versión 20/11/2026: impresión segura)

  Corre en la PC que tiene la térmica. Le pregunta al servidor (salida HTTPS al Worker queruclor-api, con el
  token del puesto «impresora») si hay etiquetas para imprimir; la impresora nunca queda expuesta a internet.

  Cada etiqueta llega como el mismo HTML que imprime hoy Depósito. Chrome (o Edge) sin ventana la pasa a PDF con
  el tamaño de página de siempre; Windows dibuja cada página punto por punto a la resolución de la impresora;
  se pasa a blanco y negro puro (barras nítidas) y se manda por el controlador instalado.

  Estados que informa: enviada (Windows la recibió) · detenida (está en Windows pero no avanza: sin papel, fuera
  de línea, pausada…) · impresa (el registro de impresión de Windows dice que se entregó) · fallida (no se llegó
  a mandar) · incierta (salió de la cola sin constancia). Lo incierto NUNCA se reimprime solo.

  20/11/2026 (incidente «Pizzurno», 64 etiquetas repetidas): el agente sigue un trabajo HASTA QUE SALE DE LA COLA
  de Windows (antes se cansaba a los 30 minutos y el trabajo quedaba retenido sin que el sistema lo supiera; cada
  vez que la impresora volvía, Windows lo mandaba otra vez). Mientras sigue, late cada 15 s con el detalle
  (páginas impresas / totales, estado de Windows) y con la LISTA de trabajos que hay en la cola de Windows, para
  que el servidor sepa qué está retenido. Si el trabajo queda detenido más de 2 minutos lo PAUSA en Windows, así
  no sale solo al volver la impresora: la persona decide desde el celular («Continuar» o «Cancelar en la PC») y
  la orden llega acá en el latido. Nunca borra ni reanuda nada sin orden.

  Antes de mandar cada trabajo deja una marca en un diario local: si la PC se corta en el medio, al volver sabe
  qué quedó sin mandar (vuelve a la cola), qué sigue en Windows (lo vuelve a seguir) y qué quedó en duda.

  Uso:
    agente-impresion.ps1                    corre en bucle (lo lanza la tarea programada)
    agente-impresion.ps1 -Prueba            imprime una ETIQUETA DE PRUEBA local, sin servidor
    agente-impresion.ps1 -Html x.html       imprime ese archivo, sin servidor (diagnóstico)
#>
param([switch]$Prueba, [string]$Html, [string]$Dir, [string]$ArchivoSalida, [int]$Vueltas = 0)
$ErrorActionPreference = "Stop"
$VERSION = "2026-11-22"
if (-not $Dir) { $Dir = Join-Path $env:LOCALAPPDATA "MLImpresion" }
$TRABAJO = Join-Path $Dir "trabajo"; $DIARIO = Join-Path $Dir "diario"
New-Item -ItemType Directory -Force -Path $TRABAJO, $DIARIO | Out-Null
$LOG = Join-Path $Dir "agente.log"

function Log($t) {
  $linea = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "  " + $t
  try {
    if ((Test-Path $LOG) -and (Get-Item $LOG).Length -gt 2MB) { Move-Item $LOG ($LOG + ".anterior") -Force }
    Add-Content -Path $LOG -Value $linea -Encoding UTF8
  } catch {}
  Write-Host $linea
}

# ── Configuración ────────────────────────────────────────────────────
$CFG_PATH = Join-Path $Dir "config.json"
$cfg = if (Test-Path $CFG_PATH) { Get-Content $CFG_PATH -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
function Valor($n, $def) { if ($cfg.PSObject.Properties[$n] -and $cfg.$n) { $cfg.$n } else { $def } }
$API = Valor "api" "https://queruclor-api.santamariapablodaniel.workers.dev"
$AGENTE = Valor "agente" $env:COMPUTERNAME
$IMPRESORA = Valor "impresora" ""
$ANCHO_MM = [double](Valor "ancho_mm" 100); $ALTO_MM = [double](Valor "alto_mm" 150)
# Solo pruebas: cuánto espera detenido antes de pausar el trabajo en Windows (producción: 120 s).
$PAUSAR_TRAS_SEG = [int](Valor "pausar_tras_seg" 120)
# Solo pruebas: tomar trabajos aunque Windows diga que la impresora no está lista (para ensayar un trabajo que queda detenido).
$IGNORAR_ESTADO = [bool](Valor "ignorar_estado_impresora" $false)
# Trabajo que NO cambia (mismo estado de Windows y mismas páginas) con la impresora «lista» y sin error: caso Pizzurno (22/11/2026).
# Windows lo dejó «Complete» (ya le entregó toda la tira) y la impresora nunca confirmó. Se lo da por detenido («retenida», o
# «sin_avance» si ni siquiera llegó a Complete) cuando pasa más de max(mínimo, segundos por etiqueta × etiquetas) sin cambiar.
# NO se usa PagesPrinted=0 solo: hay controladores que nunca actualizan ese contador y la tira sale igual (el trabajo se va de
# la cola y la constancia de Windows dice impreso). Si el trabajo cambia (páginas o estado), el reloj vuelve a cero.
$SIN_AVANCE_MIN_SEG = [int](Valor "sin_avance_min_seg" 180)
$SIN_AVANCE_POR_ETIQUETA_SEG = [int](Valor "sin_avance_por_etiqueta_seg" 3)

Add-Type -AssemblyName System.Security
function Token() {
  if (-not $cfg.PSObject.Properties["token"]) { return $null }
  $b = [Convert]::FromBase64String($cfg.token)
  # Alcance de máquina: la tarea corre aunque nadie haya iniciado sesión (sin contraseña guardada).
  [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b, [Text.Encoding]::UTF8.GetBytes("MLImpresion"), "LocalMachine"))
}

# ── Impresora: elegir y ver si está lista ────────────────────────────
function ElegirImpresora() {
  if ($IMPRESORA) { return $IMPRESORA }
  $p = Get-Printer | Where-Object { $_.DriverName -match '4BARCODE|4B-2054|LDT|3nstar' } | Select-Object -First 1
  if ($p) { return $p.Name } else { return "" }
}
# ── Interpretación del estado que informa Windows (Win32_Printer, tablas de Microsoft) ───────────────────────
# DetectedErrorState:          0 desconocido · 1 otro · 2 sin error · 3 poco papel · 4 SIN PAPEL · 5 poca tinta · 6 sin tinta · 7 tapa abierta ·
#                              8 atascada · 9 FUERA DE LÍNEA · 10 requiere atención · 11 bandeja de salida llena.
# ExtendedDetectedErrorState:  0 desconocido · 1 otro · 2 sin error · 3 poco papel · 4 SIN PAPEL · 5 poca tinta · 6 sin tinta · 7 tapa abierta ·
#                              8 atascada · 9 REQUIERE ATENCIÓN · 10 bandeja llena · 11 problema con el papel · 12 no puede imprimir la página ·
#                              13 intervención del usuario · 14 sin memoria · 15 servidor desconocido.
# Son dos tablas DISTINTAS (9, 10 y 11 no significan lo mismo): se interpretan por separado (21/11/2026; la 2026-11-20 usaba una sola).
# El código «sin_papel» es el ÚNICO con el que la pantalla dice «Falta rollo»: 4 en cualquiera de las dos. 3 (poco papel) no bloquea.
$MAPA_DET = @{ 1 = @("error", "con error"); 4 = @("sin_papel", "sin papel (falta rollo)"); 6 = @("sin_tinta", "sin cinta"); 7 = @("tapa_abierta", "tapa abierta"); 8 = @("atascada", "etiqueta atascada");
               9 = @("fuera_de_linea", "fuera de línea (apagada o desconectada)"); 10 = @("atencion", "requiere atención"); 11 = @("bandeja_llena", "bandeja de salida llena") }
$MAPA_EXT = @{ 1 = @("error", "con error"); 4 = @("sin_papel", "sin papel (falta rollo)"); 6 = @("sin_tinta", "sin cinta"); 7 = @("tapa_abierta", "tapa abierta"); 8 = @("atascada", "etiqueta atascada");
               9 = @("atencion", "requiere atención"); 10 = @("bandeja_llena", "bandeja de salida llena"); 11 = @("papel", "problema con el papel (no dice que falte)");
               12 = @("error", "no puede imprimir la página"); 13 = @("atencion", "requiere intervención"); 14 = @("error", "sin memoria") }
# Función pura (sin Windows): recibe los campos y devuelve @{lista; codigo; texto}. La prueba prueba-mapeo.ps1 la ejercita código por código.
function Interpretar($workOffline, $det, $ext, $printerStatus, $printerState, $enCola) {
  $det = [int]$det; $ext = [int]$ext; $printerStatus = [int]$printerStatus; $printerState = [int]$printerState
  if ($workOffline) { return @{ lista = $false; codigo = "fuera_de_linea"; texto = "fuera de línea (apagada o desconectada)" } }
  if ($det -eq 4 -or $ext -eq 4) { return @{ lista = $false; codigo = "sin_papel"; texto = "sin papel (falta rollo) (" + $(if ($det -eq 4) { "det 4" } else { "ext 4" }) + ")" } }
  if ($MAPA_DET[$det] -and $det -ne 1) { return @{ lista = $false; codigo = $MAPA_DET[$det][0]; texto = $MAPA_DET[$det][1] + " (det $det)" } }
  if ($MAPA_EXT[$ext] -and $ext -ne 1) { return @{ lista = $false; codigo = $MAPA_EXT[$ext][0]; texto = $MAPA_EXT[$ext][1] + " (ext $ext)" } }
  if ($det -eq 1 -or $ext -eq 1) { return @{ lista = $false; codigo = "error"; texto = "con error (" + $(if ($det -eq 1) { "det 1" } else { "ext 1" }) + ")" } }
  if ($printerStatus -eq 7) { return @{ lista = $false; codigo = "fuera_de_linea"; texto = "fuera de línea (apagada o desconectada)" } }
  if ($printerState -eq 1 -or $printerStatus -eq 6) { return @{ lista = $false; codigo = "pausada"; texto = "la cola de Windows está EN PAUSA" } }
  $poco = ($det -eq 3 -or $ext -eq 3)
  $txt = "lista"; if ($poco) { $txt += " · poco papel" }
  if ($enCola) { $txt += " · " + $enCola + " en la cola de Windows" }
  return @{ lista = $true; codigo = $(if ($poco) { "poco_papel" } else { "lista" }); texto = $txt }
}
function EstadoImpresora($nombre) {
  if (-not $nombre) { return @{ lista = $false; codigo = "sin_impresora"; texto = "no se encontró la impresora térmica" } }
  $w = Get-CimInstance Win32_Printer -Filter ("Name='" + $nombre.Replace("'", "''") + "'") -ErrorAction SilentlyContinue
  if (-not $w) { return @{ lista = $false; codigo = "sin_impresora"; texto = "no existe la impresora «$nombre»" } }
  $cola = @(Get-PrintJob -PrinterName $nombre -ErrorAction SilentlyContinue)
  return Interpretar $w.WorkOffline $w.DetectedErrorState $w.ExtendedDetectedErrorState $w.PrinterStatus $w.PrinterState $cola.Count
}
# Qué código le damos a un estado de trabajo de Windows (JobStatus): solo PaperOut → sin_papel.
function CodigoDeEstado($st, $impresora) {
  if ($st -match 'PaperOut') { return "sin_papel" }
  if ($st -match 'Offline') { return "fuera_de_linea" }
  if ($st -match 'Paused') { return "pausada" }
  if ($st -match 'UserIntervention') { return "atencion" }
  if ($st -match 'Deleting|Deleted') { return "borrando" }
  if ($st -match 'Error|Blocked') { $e = EstadoImpresora $impresora; if ($e.codigo -in @("sin_papel", "tapa_abierta", "atascada", "fuera_de_linea")) { return $e.codigo } else { return "error" } }
  return "imprimiendo"
}

# ── La cola de Windows, tal como la informa al servidor ──────────────
# Un trabajo del agente se llama ML-etiqueta-<id del trabajo en el sistema>; cualquier otro documento se informa sin trabajo.
function ColaWindows($impresora) {
  $r = @()
  if (-not $impresora) { return $r }
  foreach ($j in @(Get-PrintJob -PrinterName $impresora -ErrorAction SilentlyContinue)) {
    $id = $null; if ($j.DocumentName -match '^ML-etiqueta-(.+)$') { $id = $Matches[1] }
    $r += @{ documento = [string]$j.DocumentName; trabajo = $id; id_windows = $j.Id; paginas_impresas = [int]$j.PagesPrinted; paginas = [int]$j.TotalPages
             estado_windows = [string]$j.JobStatus; enviado = $(if ($j.SubmittedTime) { $j.SubmittedTime.ToString("o") } else { $null }) }
  }
  return $r
}

# ── Registro de impresión de Windows (para saber si se entregó) ──────
$LOGW = "Microsoft-Windows-PrintService/Operational"
function RegistroActivo() { try { (Get-WinEvent -ListLog $LOGW).IsEnabled } catch { $false } }
# Windows oculta el nombre de los documentos en este registro («Imprimir documento»): se identifica el trabajo por su
# número en la cola. 307 = impreso (entregado a la impresora) · 310 = borrado de la cola.
# Sin número (corte justo al mandar): vale solo si hay UN 307 de esta impresora, desde ese momento, con las mismas páginas.
function Constancia($jobId, $impresora, $desde, $paginas) {
  try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $LOGW; Id = 307, 310; StartTime = $desde.AddSeconds(-5) } -ErrorAction SilentlyContinue)
    if ($jobId) {
      foreach ($e in $ev) {
        $imp = if ($e.Id -eq 307) { [string]$e.Properties[4].Value } else { [string]$e.Properties[3].Value }
        if ([string]$e.Properties[0].Value -eq [string]$jobId -and $imp -eq $impresora) { if ($e.Id -eq 307) { return "impresa" } else { return "cancelada" } }
      }
      return $null
    }
    $c = @($ev | Where-Object { $_.Id -eq 307 -and [string]$_.Properties[4].Value -eq $impresora -and [int]$_.Properties[7].Value -eq [int]$paginas })
    if ($c.Count -eq 1) { return "impresa" }
  } catch {}
  return $null
}
function TrabajoWindows($impresora, $doc) { $j = Get-PrintJob -PrinterName $impresora -ErrorAction SilentlyContinue | Where-Object { $_.DocumentName -eq $doc } | Select-Object -First 1; if ($j) { $j.Id } else { $null } }

# ── Servidor ─────────────────────────────────────────────────────────
function Rpc($fn, $cuerpo) {
  $h = @{ "X-QR-Token" = $script:TOKEN; "X-QR-App" = "impresora/$($VERSION -replace '-', '')" }
  $json = $cuerpo | ConvertTo-Json -Depth 8 -Compress
  Invoke-RestMethod -Method Post -Uri "$API/rest/v1/rpc/$fn" -Headers $h -UserAgent "ML-AgenteImpresion/$VERSION" -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 30
}
# Aviso de estado de un trabajo (con detalle opcional). Reintenta si no hay conexión; un rechazo del servidor solo se anota.
function Avance($id, $estado, $error, $detalle) {
  $c = @{ p = @{ id = $id; agente = $AGENTE; estado = $estado } }
  if ($error) { $c.p.error = [string]$error }
  if ($detalle) { $c.p.detalle = $detalle }
  for ($i = 0; $i -lt 30; $i++) {
    try { $r = Rpc "qr_imp_avance" $c; if (-not $r.ok) { Log "  aviso «$estado» rechazado: $($r.motivo)" }; return $r } catch { Log "  sin conexión para avisar «$estado»: reintento"; Start-Sleep -Seconds ([Math]::Min(60, 2 + $i * 2)) }
  }
  throw "No se pudo avisar «$estado» al servidor."
}
# Latido con la cola de Windows y el detalle del trabajo que se sigue. Cada 15 s como mucho (salvo -Forzar). Nunca tira error.
# Guarda las órdenes pendientes que manda el servidor ($script:ordenes).
$script:ultimoLatido = [datetime]::MinValue; $script:ordenes = @(); $script:estadoExtra = $null
function Latir($impresora, $detalleTrabajo, [switch]$Forzar) {
  if (-not $Forzar -and ((Get-Date) - $script:ultimoLatido).TotalSeconds -lt 15) { return }
  try {
    $e = EstadoImpresora $impresora
    $texto = $e.texto; if ($script:estadoExtra) { $texto = $script:estadoExtra }
    if (-not (RegistroActivo)) { $texto += " · registro de impresión de Windows apagado" }
    $p = @{ agente = $AGENTE; impresora = $impresora; estado_impresora = $texto; version = $VERSION; cola = @(ColaWindows $impresora) }
    if ($detalleTrabajo) { $p.trabajo = $detalleTrabajo }
    $r = Rpc "qr_imp_latido" @{ p = $p }
    $script:ultimoLatido = Get-Date
    if ($r.ordenes) { $script:ordenes = @($r.ordenes) } else { $script:ordenes = @() }
  } catch { Log "  sin conexión para latir: $($_.Exception.Message)" }
}
# Ejecuta las órdenes pendientes (cancelar / reanudar) sobre los trabajos de la cola de Windows. Devuelve el id del trabajo
# en curso si la orden fue cancelarlo (para que Seguir corte).
function Ordenes($impresora, $actual) {
  $cancelado = $null
  foreach ($o in @($script:ordenes)) {
    $id = [string]$o.id; $doc = "ML-etiqueta-$id"; $enCurso = ($o.estado -in @("enviada", "detenida", "incierta"))
    $j = Get-PrintJob -PrinterName $impresora -ErrorAction SilentlyContinue | Where-Object { $_.DocumentName -eq $doc } | Select-Object -First 1
    try {
      if ($o.orden -eq "cancelar") {
        if ($j) { Remove-PrintJob -InputObject $j -ErrorAction Stop; Log "Orden de $($o.quien): borrado de la cola de Windows $doc (trabajo #$($j.Id), $($j.PagesPrinted)/$($j.TotalPages) págs)" }
        else { Log "Orden de $($o.quien): $doc ya no estaba en la cola de Windows" }
        $det = @{ estado_windows = "Deleted"; paginas_impresas = $(if ($j) { [int]$j.PagesPrinted } else { $null }); paginas = $(if ($j) { [int]$j.TotalPages } else { $null }) }
        if ($enCurso -and $j) { Avance $id "cancelada" $null $det | Out-Null; if ($id -eq $actual) { $cancelado = $id }; BorrarDiario $id }
        else { Avance $id "orden_hecha" $(if ($j) { $null } else { "ya no estaba en la cola de Windows" }) $det | Out-Null; if ($enCurso -and $id -eq $actual) { $cancelado = $id } }
      } elseif ($o.orden -eq "reanudar") {
        if ($j) {
          $w = Get-CimInstance Win32_Printer -Filter ("Name='" + $impresora.Replace("'", "''") + "'") -ErrorAction SilentlyContinue
          if ($w -and ([int]$w.PrinterState -eq 1 -or [int]$w.PrinterStatus -eq 6)) { try { Invoke-CimMethod -InputObject $w -MethodName Resume -ErrorAction Stop | Out-Null; Log "Orden de $($o.quien): impresora reanudada" } catch { Log "  no se pudo reanudar la impresora: $($_.Exception.Message)" } }
          Resume-PrintJob -InputObject $j -ErrorAction Stop; Log "Orden de $($o.quien): reanudado en Windows $doc (trabajo #$($j.Id))"
          $script:pausadoPorAgente = $null
        } else { Log "Orden de $($o.quien): $doc ya no estaba en la cola de Windows" }
        Avance $id "orden_hecha" $(if ($j) { $null } else { "ya no estaba en la cola de Windows" }) $null | Out-Null
      }
    } catch { Log "  no se pudo cumplir la orden «$($o.orden)» sobre $doc : $($_.Exception.Message)" }
  }
  $script:ordenes = @()
  return $cancelado
}

# ── HTML → PDF (Chrome/Edge sin ventana, mismo tamaño de página que hoy) ──
function Navegador() {
  $c = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
         "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $c) { throw "No hay Chrome ni Edge para preparar la etiqueta." }
  return $c
}
function HtmlAPdf($htmlPath, $pdfPath, $impresora) {
  if (Test-Path $pdfPath) { Remove-Item $pdfPath -Force }
  $perfil = Join-Path $Dir "perfil-navegador"
  $url = "file:///" + ($htmlPath -replace '\\', '/')
  $argumentos = @("--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--user-data-dir=$perfil",
            "--no-pdf-header-footer", "--print-to-pdf-no-header", "--run-all-compositor-stages-before-draw", "--virtual-time-budget=4000", "--print-to-pdf=$pdfPath", $url)
  $p = Start-Process -FilePath (Navegador) -ArgumentList $argumentos -PassThru -WindowStyle Hidden
  $inicio = Get-Date
  while (-not $p.HasExited) {
    if (((Get-Date) - $inicio).TotalSeconds -gt 90) { try { $p.Kill() } catch {}; throw "El navegador no terminó de preparar la etiqueta." }
    if ($impresora) { Latir $impresora $null }   # la pantalla sigue viendo a la PC viva mientras prepara (antes: silencio hasta 6 minutos)
    Start-Sleep -Milliseconds 500
  }
  for ($i = 0; $i -lt 20 -and -not (Test-Path $pdfPath); $i++) { Start-Sleep -Milliseconds 250 }
  if (-not (Test-Path $pdfPath) -or (Get-Item $pdfPath).Length -lt 500) { throw "No se pudo preparar la etiqueta (PDF vacío)." }
}

# ── PDF → imágenes a la resolución de la impresora (lector de PDF de Windows) ──
Add-Type -AssemblyName System.Runtime.WindowsRuntime, System.Drawing
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$script:asOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$script:asAct = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
function Esperar($op, [Type]$tipo) { $t = $script:asOp.MakeGenericMethod($tipo).Invoke($null, @($op)); [void]$t.Wait(60000); $t.Result }
function EsperarAccion($op) { $t = $script:asAct.Invoke($null, @($op)); [void]$t.Wait(60000) }

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Drawing.Printing; using System.Runtime.InteropServices;
public static class MLEtiqueta {
  // Blanco y negro puro: sin grises que el controlador convierta en puntitos sueltos sobre las barras.
  public static Bitmap BlancoYNegro(Bitmap src, int umbral) {
    Bitmap b = new Bitmap(src.Width, src.Height, PixelFormat.Format24bppRgb);
    using (Graphics g = Graphics.FromImage(b)) { g.Clear(Color.White); g.DrawImage(src, 0, 0, src.Width, src.Height); }
    Rectangle r = new Rectangle(0, 0, b.Width, b.Height);
    BitmapData d = b.LockBits(r, ImageLockMode.ReadWrite, PixelFormat.Format24bppRgb);
    int n = d.Stride * b.Height; byte[] px = new byte[n]; Marshal.Copy(d.Scan0, px, 0, n);
    for (int y = 0; y < b.Height; y++) for (int x = 0; x < b.Width; x++) {
      int i = y * d.Stride + x * 3; int lum = (px[i] * 114 + px[i + 1] * 587 + px[i + 2] * 299) / 1000; byte v = (byte)(lum < umbral ? 0 : 255);
      px[i] = v; px[i + 1] = v; px[i + 2] = v; }
    Marshal.Copy(px, 0, d.Scan0, n); b.UnlockBits(d);
    return b;
  }
  public static bool Existe(string impresora) { PrinterSettings s = new PrinterSettings(); s.PrinterName = impresora; return s.IsValid; }
  public static string UltimoPapel = "";
  // El tamaño del controlador que más se parece a la etiqueta (muchos controladores ignoran uno inventado).
  public static PaperSize Papel(PrinterSettings s, double anchoMm, double altoMm) {
    int w = (int)Math.Round(anchoMm / 25.4 * 100), h = (int)Math.Round(altoMm / 25.4 * 100);
    PaperSize mejor = null; int dif = int.MaxValue; bool aMedida = false;
    foreach (PaperSize p in s.PaperSizes) {
      string n = (p.PaperName ?? "").Trim().ToUpperInvariant();
      if (p.Kind == PaperKind.Custom || n == "USER" || n.Contains("PERSONALIZ") || n.Contains("CUSTOM") || n.Contains("DEFINIDO POR EL USUARIO")) aMedida = true;
      if (p.Width <= 0 || p.Height <= 0) continue;
      int d = Math.Abs(p.Width - w) + Math.Abs(p.Height - h);
      if (d < dif) { dif = d; mejor = p; }
    }
    // 1) la medida exacta del controlador (±1 mm); 2) a medida, si el controlador lo admite (la térmica tiene «USER»):
    //    una hoja apenas más larga que el rollo corre las etiquetas; 3) la más parecida, solo si no queda otra.
    if (mejor != null && Math.Abs(mejor.Width - w) <= 2 && Math.Abs(mejor.Height - h) <= 2) { }   // ±0,5 mm por lado
    else if (aMedida || mejor == null || dif > 24) mejor = new PaperSize("Etiqueta ML", w, h);
    UltimoPapel = mejor.PaperName + " " + mejor.Width + "x" + mejor.Height;
    return mejor;
  }
  // Una página por imagen, al tamaño de la etiqueta y sin márgenes. Devuelve cuando Windows ya tiene el trabajo.
  public static void Imprimir(string impresora, string documento, Bitmap[] paginas, double anchoMm, double altoMm, string aArchivo) {
    PrintDocument pd = new PrintDocument();
    pd.PrinterSettings.PrinterName = impresora;
    if (!pd.PrinterSettings.IsValid) throw new InvalidPrinterException(pd.PrinterSettings);
    if (!String.IsNullOrEmpty(aArchivo)) { pd.PrinterSettings.PrintToFile = true; pd.PrinterSettings.PrintFileName = aArchivo; }
    pd.DocumentName = documento;
    pd.PrintController = new StandardPrintController();
    pd.DefaultPageSettings.PaperSize = Papel(pd.PrinterSettings, anchoMm, altoMm); pd.DefaultPageSettings.Landscape = false;
    pd.DefaultPageSettings.Margins = new Margins(0, 0, 0, 0); pd.OriginAtMargins = false;
    int k = 0;
    pd.PrintPage += (o, e) => {
      Bitmap pg = paginas[k];
      e.Graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
      e.Graphics.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
      // La etiqueta mide anchoMm x altoMm: se dibuja a ese tamaño exacto (centésimas de pulgada), corrida lo que el controlador no imprime.
      float w = (float)(anchoMm / 25.4 * 100), h = (float)(altoMm / 25.4 * 100);
      e.Graphics.DrawImage(pg, new RectangleF(-e.PageSettings.HardMarginX, -e.PageSettings.HardMarginY, w, h));
      k++; e.HasMorePages = k < paginas.Length;
    };
    pd.Print();
  }
}
"@

function PdfAImagenes($pdfPath, $impresora) {
  $file = Esperar ([Windows.Storage.StorageFile]::GetFileFromPathAsync($pdfPath)) ([Windows.Storage.StorageFile])
  $doc = Esperar ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
  $imgs = @()
  for ($i = 0; $i -lt $doc.PageCount; $i++) {
    $pg = $doc.GetPage($i)
    $o = New-Object Windows.Data.Pdf.PdfPageRenderOptions
    $o.DestinationWidth = [uint32][Math]::Round($ANCHO_MM / 25.4 * 203); $o.DestinationHeight = [uint32][Math]::Round($ALTO_MM / 25.4 * 203)
    $ms = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    EsperarAccion ($pg.RenderToStreamAsync($ms, $o))
    $ms.Seek(0)
    $st = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($ms)
    $bmp = New-Object System.Drawing.Bitmap $st
    $imgs += [MLEtiqueta]::BlancoYNegro($bmp, 160)
    $bmp.Dispose(); $pg.Dispose()
    if ($impresora -and ($i % 8 -eq 7)) { $script:estadoExtra = "preparando la tira: $($i + 1)/$($doc.PageCount) etiquetas"; Latir $impresora $null }
  }
  $script:estadoExtra = $null
  return , $imgs
}

# ── Imprimir un HTML: devuelve el nombre del documento en la cola de Windows ──
function ImprimirHtml($id, $html, $impresora, $aArchivo) {
  $hp = Join-Path $TRABAJO ("$id.html"); $pp = Join-Path $TRABAJO ("$id.pdf")
  [IO.File]::WriteAllText($hp, $html, (New-Object Text.UTF8Encoding $false))
  $script:estadoExtra = "preparando la tira (PDF)"
  HtmlAPdf $hp $pp $impresora
  $imgs = PdfAImagenes $pp $impresora
  if (-not $imgs.Count) { throw "La etiqueta no tiene páginas." }
  $doc = "ML-etiqueta-$id"
  # Si por un corte anterior ese documento YA está en la cola de Windows, no se manda otra vez: se lo sigue.
  $ya = TrabajoWindows $impresora $doc
  if ($ya) { Log "  $doc ya estaba en la cola de Windows (#$ya): no se manda de nuevo"; Diario $id @{ estado = "enviada"; documento = $doc; paginas = $imgs.Count; desde = (Get-Date).ToString("o"); trabajo_windows = $ya }
             foreach ($b in $imgs) { $b.Dispose() }; Remove-Item $hp, $pp -Force -ErrorAction SilentlyContinue; return @{ doc = $doc; jobId = $ya; paginas = $imgs.Count; desde = (Get-Date) } }
  Diario $id @{ estado = "enviando"; documento = $doc; paginas = $imgs.Count; desde = (Get-Date).ToString("o") }
  if ($env:ML_SIMULAR_CORTE -eq "enviando") { Log "(prueba) corte simulado antes de mandar"; [Environment]::Exit(9) }
  $desde = Get-Date
  Diario $id @{ estado = "enviando"; documento = $doc; paginas = $imgs.Count; desde = $desde.ToString("o") }
  [MLEtiqueta]::Imprimir($impresora, $doc, $imgs, $ANCHO_MM, $ALTO_MM, $aArchivo)
  $jobId = TrabajoWindows $impresora $doc
  Diario $id @{ estado = "enviada"; documento = $doc; paginas = $imgs.Count; desde = $desde.ToString("o"); trabajo_windows = $jobId }
  if ($env:ML_SIMULAR_CORTE -eq "enviada") { Log "(prueba) corte simulado después de mandar"; [Environment]::Exit(9) }
  $n = $imgs.Count
  foreach ($b in $imgs) { $b.Dispose() }
  Remove-Item $hp, $pp -Force -ErrorAction SilentlyContinue
  $script:estadoExtra = $null
  return @{ doc = $doc; jobId = $jobId; paginas = $n; desde = $desde }
}

function Diario($id, $datos) { ($datos | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $DIARIO "$id.json") -Encoding UTF8 }
function LeerDiario($id) { $f = Join-Path $DIARIO "$id.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null } }
function BorrarDiario($id) { Remove-Item (Join-Path $DIARIO "$id.json") -Force -ErrorAction SilentlyContinue }

# Sigue el trabajo HASTA QUE SALE de la cola de Windows y dice si se entregó (impresa), si se borró por orden (cancelada) o
# si no se sabe (incierta). Mientras está detenido avisa «detenida» con el detalle; a los 2 minutos detenido lo pausa en
# Windows para que no salga solo al volver la impresora. Ejecuta las órdenes que llegan en el latido.
# 22/11/2026: también es «detenida» un trabajo que no cambia en nada durante demasiado tiempo con la impresora «lista»
# (retenida «Complete» como Pizzurno, o sin avance): antes quedaba «imprimiendo» para siempre y nadie se enteraba.
$script:pausadoPorAgente = $null
# El trabajo en la cola de Windows (función aparte para poder ensayar Seguir sin impresora: prueba-seguir.ps1 la reemplaza).
function LeerTrabajo($impresora, $jobId, $doc) { Get-PrintJob -PrinterName $impresora -ErrorAction SilentlyContinue | Where-Object { ($jobId -and $_.Id -eq $jobId) -or $_.DocumentName -eq $doc } | Select-Object -First 1 }
function Seguir($doc, $jobId, $desde, $impresora, $paginas, $id) {
  $detenidoDesde = $null; $firma = ""; $ultimoAvance = [datetime]::MinValue; $pp = 0
  $huella = $null; $sinCambioDesde = Get-Date; $impresoSegunWindows = $false
  $sinAvanceSeg = [Math]::Max($SIN_AVANCE_MIN_SEG, $SIN_AVANCE_POR_ETIQUETA_SEG * [int]$paginas)
  while ($true) {
    $j = LeerTrabajo $impresora $jobId $doc
    if (-not $j) { break }
    if (-not $jobId) { $jobId = $j.Id }
    $stWin = [string]$j.JobStatus; $st = $stWin; $pp = [int]$j.PagesPrinted
    # Windows dice «Printed» y el trabajo sigue en la cola (retención de impresos): salió; no hay nada que seguir.
    if ($stWin -match 'Printed' -and $stWin -notmatch 'Error|PaperOut|Offline|Blocked|UserIntervention|Paused') { $impresoSegunWindows = $true; break }
    $codigo = CodigoDeEstado $stWin $impresora
    $mal = $stWin -match 'Error|PaperOut|Offline|Blocked|UserIntervention|Paused'
    # El trabajo puede no decir nada y ser la IMPRESORA la que está mal (fuera de línea, sin papel, cola en pausa): también es «detenida».
    if (-not $mal) { $ei = EstadoImpresora $impresora; if (-not $ei.lista) { $mal = $true; $codigo = $ei.codigo; $st = "impresora: " + $ei.texto } }
    # Nada cambió (ni el estado de Windows ni las páginas) durante más de lo que tardaría la tira entera, con la impresora «lista»:
    # «retenida» si Windows ya la entregó entera (Complete) y la impresora no confirma; «sin_avance» si ni siquiera llegó a eso.
    $h = "$stWin|$pp"; if ($h -ne $huella) { $huella = $h; $sinCambioDesde = Get-Date }
    $quieto = [int]((Get-Date) - $sinCambioDesde).TotalSeconds
    if (-not $mal -and $quieto -ge $sinAvanceSeg) {
      $mal = $true
      if ($stWin -match 'Complete') { $codigo = "retenida"; $st = "retenida: Windows ya le entregó toda la tira a la impresora y ésta no confirma que haya salido ($stWin, $quieto s sin cambios)" }
      else { $codigo = "sin_avance"; $st = "sin avance: $quieto s sin cambiar ($stWin)" }
    }
    # Si la pausa es NUESTRA (ver más abajo), la causa que se informa sigue siendo la original (sin papel, fuera de línea…), no «pausada».
    if ($codigo -eq "pausada" -and $script:pausadoPorAgente -eq $id -and $script:causaPausa) { $codigo = $script:causaPausa; if ($script:causaTexto) { $st = $script:causaTexto } }
    if ($mal -and $codigo -ne "pausada") { $script:causaPausa = $codigo; $script:causaTexto = $st }
    $det = @{ paginas_impresas = $pp; paginas = [int]$paginas; estado_windows = $st; codigo = $codigo; trabajo_windows = $jobId }
    if ($mal) {
      if (-not $detenidoDesde) { $detenidoDesde = Get-Date }
      $det.detenida_desde = $detenidoDesde.ToString("o")
      if ($script:pausadoPorAgente -eq $id) { $det.pausada_por_agente = $true }
      $script:estadoExtra = "DETENIDA ($codigo): $st · $pp/$paginas etiquetas"
      $f = "detenida|$codigo"
      if ($id -and ($f -ne $firma -or ((Get-Date) - $ultimoAvance).TotalSeconds -ge 60)) { Avance $id "detenida" "trabajo detenido en Windows: $st" $det | Out-Null; $firma = $f; $ultimoAvance = Get-Date }
      # Más de 2 minutos detenido y Windows no lo tiene en pausa: lo pausamos NOSOTROS. Así, cuando vuelva la impresora, no sale
      # solo (ni repetido): la persona decide «Continuar» o «Cancelar en la PC». Vale también para la retenida: pausada, el
      # spooler no la vuelve a mandar cuando se reabre el puerto (lo que pasó el 20/11 a las 11:56 con la de Pizzurno).
      if (((Get-Date) - $detenidoDesde).TotalSeconds -ge $PAUSAR_TRAS_SEG -and $stWin -notmatch 'Paused' -and $script:pausadoPorAgente -ne $id) {
        try { Suspend-PrintJob -InputObject $j -ErrorAction Stop; $script:pausadoPorAgente = $id; $ultimoAvance = [datetime]::MinValue; $script:ultimoLatido = [datetime]::MinValue; Log "  $doc detenido $([int](((Get-Date) - $detenidoDesde).TotalSeconds)) s ($codigo): PAUSADO en Windows hasta que la persona decida" }
        catch { Log "  no se pudo pausar $doc en Windows: $($_.Exception.Message)" }
      }
    } else {
      if ($detenidoDesde) { $detenidoDesde = $null; if ($id) { Avance $id "enviada" $null $det | Out-Null; $firma = "enviada"; $ultimoAvance = Get-Date } }
      $script:estadoExtra = "imprimiendo: $pp/$paginas etiquetas"
      if ($id -and ((Get-Date) - $ultimoAvance).TotalSeconds -ge 60) { Avance $id "enviada" $null $det | Out-Null; $ultimoAvance = Get-Date }
    }
    Latir $impresora (@{ id = $id; paginas_impresas = $pp; paginas = [int]$paginas; estado_windows = $st; codigo = $codigo; pausada_por_agente = ($script:pausadoPorAgente -eq $id) })
    $cancelado = Ordenes $impresora $id
    if ($cancelado -and $cancelado -eq $id) { $script:estadoExtra = $null; return @{ estado = "cancelada" } }
    Start-Sleep -Seconds 2
  }
  $script:estadoExtra = $null
  if ($impresoSegunWindows) { Log "  $doc figura «Printed» en la cola de Windows (retención de impresos): se da por impresa"; return @{ estado = "impresa"; detalle = @{ paginas_impresas = [int]$paginas; paginas = [int]$paginas; estado_windows = "Printed" } } }
  for ($i = 0; $i -lt 5; $i++) {
    $c = Constancia $jobId $impresora $desde $paginas
    if ($c -eq "impresa") { return @{ estado = "impresa"; detalle = @{ paginas_impresas = [int]$paginas; paginas = [int]$paginas; estado_windows = "Printed" } } }
    if ($c -eq "cancelada") { return @{ estado = "incierta"; error = "El trabajo se borró de la cola de Windows: puede haber salido incompleto o no haber salido."; detalle = @{ paginas_impresas = $pp; paginas = [int]$paginas; estado_windows = "Deleted" } } }
    Start-Sleep -Seconds 1
  }
  if (-not (RegistroActivo)) { return @{ estado = "incierta"; error = "El registro de impresión de Windows está apagado: no se puede saber si salió." } }
  return @{ estado = "incierta"; error = "El trabajo salió de la cola de Windows sin constancia de impresión."; detalle = @{ paginas_impresas = $pp; paginas = [int]$paginas } }
}

# Después de un corte: lo que el servidor dice que este agente tenía, contra el diario local y la cola de Windows.
function Reconciliar($pendientes, $impresora) {
  foreach ($p in $pendientes) {
    $d = LeerDiario $p.id
    $doc = "ML-etiqueta-$($p.id)"
    if ($p.estado -eq "tomada" -and (-not $d -or $d.estado -eq "tomada")) {
      if (TrabajoWindows $impresora $doc) { Log "Recupero $($p.id): tomada pero YA está en Windows → se sigue"; $d = [pscustomobject]@{ estado = "enviada"; documento = $doc; paginas = 0; desde = (Get-Date).ToString("o"); trabajo_windows = (TrabajoWindows $impresora $doc) } }
      else { Log "Recupero $($p.id): no se llegó a mandar → vuelve a la cola"; Avance $p.id "devuelta" $null $null | Out-Null; BorrarDiario $p.id; continue }
    }
    if (-not $d) {
      $jid = TrabajoWindows $impresora $doc
      if ($jid) { Log "Recupero $($p.id): sin diario local pero sigue en la cola de Windows → se sigue"; $r = Seguir $doc $jid (Get-Date).AddDays(-1) $impresora 0 $p.id; Avance $p.id $r.estado $r.error $r.detalle | Out-Null; continue }
      Log "Recupero $($p.id): sin diario local → incierta"
      if ($p.estado -eq "tomada") { Avance $p.id "incierta" "La PC no tiene constancia de haberlo mandado." $null | Out-Null } else { Avance $p.id "incierta" "La PC se reinició y no tiene constancia del resultado." $null | Out-Null }
      continue
    }
    $desde = [datetime]$d.desde
    if ($d.estado -eq "enviando") {
      $jid = TrabajoWindows $impresora $d.documento
      if ($jid) { if ($p.estado -eq "tomada") { Avance $p.id "enviada" $null $null | Out-Null }; $r = Seguir $d.documento $jid $desde $impresora $d.paginas $p.id; Avance $p.id $r.estado $r.error $r.detalle | Out-Null; Log "Recupero $($p.id): seguía en la cola de Windows → $($r.estado)" }
      elseif ((Constancia $null $impresora $desde $d.paginas) -eq "impresa") { if ($p.estado -eq "tomada") { Avance $p.id "enviada" $null $null | Out-Null }; Avance $p.id "impresa" $null $null | Out-Null; Log "Recupero $($p.id): Windows lo entregó" }
      else { Avance $p.id "incierta" "La PC se cortó mientras lo mandaba a la impresora." $null | Out-Null; Log "Recupero $($p.id): incierta" }
      BorrarDiario $p.id; continue
    }
    if ($d.estado -eq "enviada") {
      if ($p.estado -eq "tomada") { Avance $p.id "enviada" $null $null | Out-Null }
      $r = Seguir $d.documento $d.trabajo_windows $desde $impresora $d.paginas $p.id
      Avance $p.id $r.estado $r.error $r.detalle | Out-Null; BorrarDiario $p.id; Log "Recupero $($p.id): $($r.estado)"
    }
  }
}

function Procesar($t, $impresora) {
  Log "Trabajo $($t.id) · $($t.tipo) · pedido $($t.pedido_id) · $($t.etiquetas) etiqueta(s)"
  Diario $t.id @{ estado = "tomada"; desde = (Get-Date).ToString("o") }
  $desde = Get-Date
  $aArch = if (Valor "salida_dir" "") { Join-Path (Valor "salida_dir" "") ("$($t.id).pdf") } else { $null }   # solo pruebas: imprimir a archivo
  try { $envio = ImprimirHtml $t.id $t.html $impresora $aArch }
  catch {
    $script:estadoExtra = $null
    $d = LeerDiario $t.id
    if ($d -and $d.estado -eq "enviando") { Avance $t.id "incierta" ("Falló mientras se mandaba: " + $_.Exception.Message) $null | Out-Null; Log "  incierta: $($_.Exception.Message)" }
    else { Avance $t.id "fallida" $_.Exception.Message $null | Out-Null; Log "  fallida: $($_.Exception.Message)" }
    BorrarDiario $t.id; return
  }
  Avance $t.id "enviada" $null (@{ paginas_impresas = 0; paginas = $envio.paginas; estado_windows = "Spooling"; trabajo_windows = $envio.jobId }) | Out-Null
  Latir $impresora (@{ id = $t.id; paginas_impresas = 0; paginas = $envio.paginas; estado_windows = "Spooling" }) -Forzar
  $r = Seguir $envio.doc $envio.jobId $envio.desde $impresora $envio.paginas $t.id
  if ($r.estado -ne "cancelada") { Avance $t.id $r.estado $r.error $r.detalle | Out-Null }
  BorrarDiario $t.id
  Latir $impresora $null -Forzar
  Log ("  " + $r.estado + " · papel: " + [MLEtiqueta]::UltimoPapel + $(if ($r.error) { ": " + $r.error } else { "" }))
}

# ── Modos sin servidor ───────────────────────────────────────────────
function HtmlPrueba() {
  $ahora = (Get-Date).ToString("dd/MM/yyyy HH:mm")
  return @"
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
@page { size: ${ANCHO_MM}mm ${ALTO_MM}mm; margin: 0 } html, body { margin: 0; padding: 0 }
.e { width: ${ANCHO_MM}mm; height: ${ALTO_MM}mm; box-sizing: border-box; border: 1.2mm solid #000; padding: 6mm; font-family: Arial, sans-serif; display: flex; flex-direction: column; gap: 5mm }
h1 { margin: 0; font-size: 30px; text-align: center; background: #000; color: #fff; padding: 3mm } p { margin: 0; font-size: 16px; font-weight: 700 }
.x { flex: 1; border: 0.6mm dashed #000; display: flex; align-items: center; justify-content: center; font-size: 22px; font-weight: 900; text-align: center }
.b { height: 22mm; background: repeating-linear-gradient(90deg, #000 0 0.5mm, #fff 0.5mm 1mm, #000 1mm 2mm, #fff 2mm 2.5mm) }
</style></head><body><div class="e"><h1>ETIQUETA DE PRUEBA</h1><p>NO PEGAR EN NINGUNA CAJA</p><p>PC: $AGENTE · $ahora</p>
<div class="x">Impresión remota de Depósito<br>prueba de formato 100 x 150 mm</div><div class="b"></div><p>Si esta etiqueta salió completa y nítida, la impresora quedó lista.</p></div></body></html>
"@
}

$imp = ElegirImpresora
if ($Prueba -or $Html) {
  if (-not $imp -and -not $ArchivoSalida) { throw "No se encontró la impresora térmica." }
  $contenido = if ($Html) { Get-Content $Html -Raw -Encoding UTF8 } else { HtmlPrueba }
  $id = "local-" + (Get-Date).ToString("yyyyMMddHHmmss")
  $desde = Get-Date
  $envio = ImprimirHtml $id $contenido $(if ($imp) { $imp } else { "Microsoft Print to PDF" }) $ArchivoSalida
  Log ("Prueba local enviada a «" + $imp + "» como " + $envio.doc + " · papel: " + [MLEtiqueta]::UltimoPapel)
  if (-not $ArchivoSalida) { $r = Seguir $envio.doc $envio.jobId $envio.desde $imp $envio.paginas $null; Log "Resultado: $($r.estado) $($r.error)"; BorrarDiario $id; if ($r.estado -ne "impresa") { exit 2 } } else { BorrarDiario $id }
  exit 0
}

# ── Bucle ────────────────────────────────────────────────────────────
$creado = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\MLImpresionDeposito", [ref]$creado)
if (-not $creado) { exit 0 }   # ya hay un agente corriendo
$script:TOKEN = Token
# Prueba pedida por el instalador: se imprime en el mismo contexto en que corre la tarea (antes de vincular con el servidor).
function PruebaPedida() {
  $sol = Join-Path $Dir "imprimir-prueba.solicitud"; if (-not (Test-Path $sol)) { return }
  Remove-Item $sol -Force -ErrorAction SilentlyContinue
  $res = Join-Path $Dir "imprimir-prueba.resultado"
  $aArch = if (Valor "salida_dir" "") { Join-Path (Valor "salida_dir" "") "prueba-instalador.pdf" } else { $null }   # solo pruebas: a archivo
  try { $i = ElegirImpresora; $e = ImprimirHtml ("instalador-" + (Get-Date).ToString("yyyyMMddHHmmss")) (HtmlPrueba) $i $aArch; $r = Seguir $e.doc $e.jobId $e.desde $i $e.paginas $null
        (@{ estado = $r.estado; error = $r.error; impresora = $i; papel = [MLEtiqueta]::UltimoPapel; usuario = $env:USERNAME; sesion = [Environment]::UserInteractive } | ConvertTo-Json) | Set-Content $res -Encoding UTF8 }
  catch { (@{ estado = "fallida"; error = $_.Exception.Message; usuario = $env:USERNAME } | ConvertTo-Json) | Set-Content $res -Encoding UTF8 }
  Get-ChildItem $DIARIO -Filter "instalador-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
PruebaPedida
if (-not $script:TOKEN) { Log "Falta el token: correr el instalador."; exit 1 }
$e0 = EstadoImpresora $imp
Log "Agente $VERSION en $AGENTE · impresora «$imp» ($($e0.texto)) · registro de Windows: $(if (RegistroActivo) { 'activo' } else { 'APAGADO' })"
$ultimoTrabajo = [datetime]::MinValue; $fallasSeguidas = 0; $reconciliado = $false; $pausaAvisada = $false
while ($true) {
  PruebaPedida
  try {
    $imp = ElegirImpresora
    $e = EstadoImpresora $imp
    $texto = $e.texto; if ($script:estadoExtra) { $texto = $script:estadoExtra }
    if (-not (RegistroActivo)) { $texto += " · registro de impresión de Windows apagado" }
    $r = Rpc "qr_imp_tomar" @{ p = @{ agente = $AGENTE; impresora = $imp; estado_impresora = $texto; version = $VERSION; lista = [bool](($e.lista -or $IGNORAR_ESTADO) -and $reconciliado); cola = @(ColaWindows $imp) } }
    $script:ultimoLatido = Get-Date
    $fallasSeguidas = 0
    if ($r.ordenes) { $script:ordenes = @($r.ordenes); Ordenes $imp $null | Out-Null }
    if ($r.pausa -and $r.pausa.activa) { if (-not $pausaAvisada) { Log "Impresión PAUSADA por oficina ($($r.pausa.quien)): $($r.pausa.motivo)"; $pausaAvisada = $true } } else { $pausaAvisada = $false }
    if ($r.pendientes -and @($r.pendientes).Count) { Reconciliar @($r.pendientes) $imp }
    $reconciliado = $true
    if ($r.trabajo) { Procesar $r.trabajo $imp; $ultimoTrabajo = Get-Date; continue }
    # Actualización ordenada por oficina (21/11/2026): si el servidor dice que la versión esperada es otra, se baja del sitio
    # publicado, se comprueba la huella SHA-256 que fijó oficina y la sintaxis, se reemplaza este archivo y se sale con código 3:
    # la tarea programada lo vuelve a arrancar. Solo en reposo (nunca con un trabajo en curso). Sin huella no se actualiza nada.
    if ($r.agente_esperado -and $r.agente_esperado.version -and $r.agente_esperado.version -ne $VERSION -and $r.agente_esperado.url -and $r.agente_esperado.sha256 -and -not (Valor "sin_actualizar" $false)) {
      try {
        $tmp = Join-Path $Dir ("agente-" + $r.agente_esperado.version + ".ps1.nuevo")
        Invoke-WebRequest -Uri $r.agente_esperado.url -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        $sha = ([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($tmp)) | ForEach-Object { $_.ToString("x2") }) -join ""
        if ($sha -ne ([string]$r.agente_esperado.sha256).ToLower()) { throw "la huella no coincide (bajado $sha)" }
        $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errs); if ($errs) { throw "el archivo bajado no es un script válido" }
        if (-not (Select-String -Path $tmp -Pattern ('^\$VERSION = "' + [regex]::Escape($r.agente_esperado.version) + '"') -Quiet)) { throw "el archivo bajado no es la versión esperada" }
        Copy-Item $tmp $PSCommandPath -Force; Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Log "Actualizado a la versión $($r.agente_esperado.version) por orden de oficina: se reinicia"
        [Environment]::Exit(3)
      } catch { if (-not $script:actualizacionAvisada) { Log "No se pudo actualizar a $($r.agente_esperado.version): $($_.Exception.Message)"; $script:actualizacionAvisada = $true }; Remove-Item (Join-Path $Dir "*.ps1.nuevo") -Force -ErrorAction SilentlyContinue }
    }
  } catch {
    $fallasSeguidas++
    if ($fallasSeguidas -le 3 -or $fallasSeguidas % 30 -eq 0) { Log "Sin conexión con el servidor ($fallasSeguidas): $($_.Exception.Message)" }
  }
  if ($Vueltas -gt 0) { $Vueltas--; if ($Vueltas -eq 0) { break } }
  $h = (Get-Date).Hour
  $espera = if (((Get-Date) - $ultimoTrabajo).TotalSeconds -lt 120) { 4 } elseif ($h -ge 21 -or $h -lt 6) { 30 } else { 10 }
  if ($fallasSeguidas -gt 3) { $espera = [Math]::Min(60, 10 * ($fallasSeguidas - 2)) }
  if ([int](Valor "intervalo_seg" 0) -gt 0) { $espera = [int](Valor "intervalo_seg" 0) }   # solo pruebas
  Start-Sleep -Seconds $espera
}
