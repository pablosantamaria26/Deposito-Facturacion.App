<#
  AGENTE DE IMPRESIÓN DE DEPÓSITO (11/11/2026)

  Corre en la PC que tiene la térmica. Le pregunta al servidor (salida HTTPS al Worker queruclor-api, con el
  token del puesto «impresora») si hay etiquetas para imprimir; la impresora nunca queda expuesta a internet.

  Cada etiqueta llega como el mismo HTML que imprime hoy Depósito. Chrome (o Edge) sin ventana la pasa a PDF con
  el tamaño de página de siempre; Windows dibuja cada página punto por punto a la resolución de la impresora;
  se pasa a blanco y negro puro (barras nítidas) y se manda por el controlador instalado.

  Estados que informa: enviada (Windows la recibió) · impresa (el registro de impresión de Windows dice que se
  entregó) · fallida (no se llegó a mandar) · incierta (no se puede saber si salió). Lo incierto NUNCA se
  reimprime solo. Antes de mandar cada trabajo deja una marca en un diario local: si la PC se corta en el medio,
  al volver sabe qué quedó sin mandar (vuelve a la cola) y qué quedó en duda (incierta).

  Uso:
    agente-impresion.ps1                    corre en bucle (lo lanza la tarea programada)
    agente-impresion.ps1 -Prueba            imprime una ETIQUETA DE PRUEBA local, sin servidor
    agente-impresion.ps1 -Html x.html       imprime ese archivo, sin servidor (diagnóstico)
#>
param([switch]$Prueba, [string]$Html, [string]$Dir, [string]$ArchivoSalida, [int]$Vueltas = 0)
$ErrorActionPreference = "Stop"
$VERSION = "2026-11-11"
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
function EstadoImpresora($nombre) {
  if (-not $nombre) { return @{ lista = $false; texto = "no se encontró la impresora térmica" } }
  $w = Get-CimInstance Win32_Printer -Filter ("Name='" + $nombre.Replace("'", "''") + "'") -ErrorAction SilentlyContinue
  if (-not $w) { return @{ lista = $false; texto = "no existe la impresora «$nombre»" } }
  if ($w.WorkOffline) { return @{ lista = $false; texto = "desconectada o apagada" } }
  $err = @{ 1 = "con error"; 2 = "con error"; 4 = "sin papel"; 5 = "sin papel" }
  $det = $w.DetectedErrorState
  if ($det -and $det -gt 2 -and $det -ne 9) { $m = @{ 3 = "poco papel"; 4 = "sin papel"; 5 = "poca tinta"; 6 = "sin tinta"; 7 = "tapa abierta"; 8 = "atascada"; 10 = "requiere atención"; 11 = "desconectada" }[[int]$det]; if ($det -ne 3) { return @{ lista = $false; texto = $(if ($m) { $m } else { "con error ($det)" }) } } }
  $enCola = @(Get-PrintJob -PrinterName $nombre -ErrorAction SilentlyContinue).Count
  return @{ lista = $true; texto = $(if ($enCola) { "lista · $enCola en la cola de Windows" } else { "lista" }) }
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

# ── HTML → PDF (Chrome/Edge sin ventana, mismo tamaño de página que hoy) ──
function Navegador() {
  $c = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
         "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $c) { throw "No hay Chrome ni Edge para preparar la etiqueta." }
  return $c
}
function HtmlAPdf($htmlPath, $pdfPath) {
  if (Test-Path $pdfPath) { Remove-Item $pdfPath -Force }
  $perfil = Join-Path $Dir "perfil-navegador"
  $url = "file:///" + ($htmlPath -replace '\\', '/')
  $args = @("--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--user-data-dir=$perfil",
            "--no-pdf-header-footer", "--print-to-pdf-no-header", "--run-all-compositor-stages-before-draw", "--virtual-time-budget=4000", "--print-to-pdf=$pdfPath", $url)
  $p = Start-Process -FilePath (Navegador) -ArgumentList $args -PassThru -WindowStyle Hidden
  if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch {}; throw "El navegador no terminó de preparar la etiqueta." }
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

function PdfAImagenes($pdfPath) {
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
  }
  return , $imgs
}

# ── Imprimir un HTML: devuelve el nombre del documento en la cola de Windows ──
function ImprimirHtml($id, $html, $impresora, $aArchivo) {
  $hp = Join-Path $TRABAJO ("$id.html"); $pp = Join-Path $TRABAJO ("$id.pdf")
  [IO.File]::WriteAllText($hp, $html, (New-Object Text.UTF8Encoding $false))
  HtmlAPdf $hp $pp
  $imgs = PdfAImagenes $pp
  if (-not $imgs.Count) { throw "La etiqueta no tiene páginas." }
  $doc = "ML-etiqueta-$id"
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
  return @{ doc = $doc; jobId = $jobId; paginas = $n; desde = $desde }
}

function Diario($id, $datos) { ($datos | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $DIARIO "$id.json") -Encoding UTF8 }
function LeerDiario($id) { $f = Join-Path $DIARIO "$id.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null } }
function BorrarDiario($id) { Remove-Item (Join-Path $DIARIO "$id.json") -Force -ErrorAction SilentlyContinue }

# Espera a que el trabajo salga de la cola de Windows y dice si se entregó (impresa) o no se sabe (incierta).
function Seguir($doc, $jobId, $desde, $impresora, $paginas) {
  $limite = (Get-Date).AddMinutes(30)
  while ((Get-Date) -lt $limite) {
    $j = Get-PrintJob -PrinterName $impresora -ErrorAction SilentlyContinue | Where-Object { ($jobId -and $_.Id -eq $jobId) -or $_.DocumentName -eq $doc } | Select-Object -First 1
    if (-not $j) { break }
    if (-not $jobId) { $jobId = $j.Id }
    $st = [string]$j.JobStatus
    if ($st -match 'Error|PaperOut|Offline|Blocked|UserIntervention') { $script:estadoExtra = "trabajo detenido en Windows: $st" } else { $script:estadoExtra = $null }
    Start-Sleep -Seconds 2
  }
  $script:estadoExtra = $null
  if ((Get-Date) -ge $limite) { return @{ estado = "incierta"; error = "El trabajo sigue en la cola de Windows después de 30 minutos." } }
  for ($i = 0; $i -lt 5; $i++) {
    $c = Constancia $jobId $impresora $desde $paginas
    if ($c -eq "impresa") { return @{ estado = "impresa" } }
    if ($c -eq "cancelada") { return @{ estado = "incierta"; error = "El trabajo se borró de la cola de Windows: puede haber salido incompleto o no haber salido." } }
    Start-Sleep -Seconds 1
  }
  if (-not (RegistroActivo)) { return @{ estado = "incierta"; error = "El registro de impresión de Windows está apagado: no se puede saber si salió." } }
  return @{ estado = "incierta"; error = "El trabajo salió de la cola de Windows sin constancia de impresión." }
}

# ── Servidor ─────────────────────────────────────────────────────────
function Rpc($fn, $cuerpo) {
  $h = @{ "X-QR-Token" = $script:TOKEN; "X-QR-App" = "impresora/$($VERSION -replace '-', '')" }
  $json = $cuerpo | ConvertTo-Json -Depth 6 -Compress
  Invoke-RestMethod -Method Post -Uri "$API/rest/v1/rpc/$fn" -Headers $h -UserAgent "ML-AgenteImpresion/$VERSION" -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 30
}
function Avance($id, $estado, $error) {
  $c = @{ p = @{ id = $id; agente = $AGENTE; estado = $estado } }
  if ($error) { $c.p.error = [string]$error }
  for ($i = 0; $i -lt 30; $i++) {
    try { $r = Rpc "qr_imp_avance" $c; if (-not $r.ok) { Log "  aviso «$estado» rechazado: $($r.motivo)" }; return $r } catch { Log "  sin conexión para avisar «$estado»: reintento"; Start-Sleep -Seconds ([Math]::Min(60, 2 + $i * 2)) }
  }
  throw "No se pudo avisar «$estado» al servidor."
}

# Después de un corte: lo que el servidor dice que este agente tenía, contra el diario local.
function Reconciliar($pendientes, $impresora) {
  foreach ($p in $pendientes) {
    $d = LeerDiario $p.id
    if ($p.estado -eq "tomada" -and (-not $d -or $d.estado -eq "tomada")) { Log "Recupero $($p.id): no se llegó a mandar → vuelve a la cola"; Avance $p.id "devuelta" $null | Out-Null; BorrarDiario $p.id; continue }
    if (-not $d) { Log "Recupero $($p.id): sin diario local → incierta"; if ($p.estado -eq "tomada") { Avance $p.id "incierta" "La PC no tiene constancia de haberlo mandado." | Out-Null } else { Avance $p.id "incierta" "La PC se reinició y no tiene constancia del resultado." | Out-Null }; continue }
    $desde = [datetime]$d.desde
    if ($d.estado -eq "enviando") {
      $jid = TrabajoWindows $impresora $d.documento
      if ($jid) { if ($p.estado -eq "tomada") { Avance $p.id "enviada" $null | Out-Null }; $r = Seguir $d.documento $jid $desde $impresora $d.paginas; Avance $p.id $r.estado $r.error | Out-Null; Log "Recupero $($p.id): seguía en la cola de Windows → $($r.estado)" }
      elseif ((Constancia $null $impresora $desde $d.paginas) -eq "impresa") { if ($p.estado -eq "tomada") { Avance $p.id "enviada" $null | Out-Null }; Avance $p.id "impresa" $null | Out-Null; Log "Recupero $($p.id): Windows lo entregó" }
      else { Avance $p.id "incierta" "La PC se cortó mientras lo mandaba a la impresora." | Out-Null; Log "Recupero $($p.id): incierta" }
      BorrarDiario $p.id; continue
    }
    if ($d.estado -eq "enviada") {
      if ($p.estado -eq "tomada") { Avance $p.id "enviada" $null | Out-Null }
      $r = Seguir $d.documento $d.trabajo_windows $desde $impresora $d.paginas
      Avance $p.id $r.estado $r.error | Out-Null; BorrarDiario $p.id; Log "Recupero $($p.id): $($r.estado)"
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
    $d = LeerDiario $t.id
    if ($d -and $d.estado -eq "enviando") { Avance $t.id "incierta" ("Falló mientras se mandaba: " + $_.Exception.Message) | Out-Null; Log "  incierta: $($_.Exception.Message)" }
    else { Avance $t.id "fallida" $_.Exception.Message | Out-Null; Log "  fallida: $($_.Exception.Message)" }
    BorrarDiario $t.id; return
  }
  Avance $t.id "enviada" $null | Out-Null
  $r = Seguir $envio.doc $envio.jobId $envio.desde $impresora $envio.paginas
  Avance $t.id $r.estado $r.error | Out-Null
  BorrarDiario $t.id
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
  if (-not $ArchivoSalida) { $r = Seguir $envio.doc $envio.jobId $envio.desde $imp $envio.paginas; Log "Resultado: $($r.estado) $($r.error)"; BorrarDiario $id; if ($r.estado -ne "impresa") { exit 2 } } else { BorrarDiario $id }
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
  try { $i = ElegirImpresora; $e = ImprimirHtml ("instalador-" + (Get-Date).ToString("yyyyMMddHHmmss")) (HtmlPrueba) $i $null; $r = Seguir $e.doc $e.jobId $e.desde $i $e.paginas
        (@{ estado = $r.estado; error = $r.error; impresora = $i; papel = [MLEtiqueta]::UltimoPapel; usuario = $env:USERNAME; sesion = [Environment]::UserInteractive } | ConvertTo-Json) | Set-Content $res -Encoding UTF8 }
  catch { (@{ estado = "fallida"; error = $_.Exception.Message; usuario = $env:USERNAME } | ConvertTo-Json) | Set-Content $res -Encoding UTF8 }
  Get-ChildItem $DIARIO -Filter "instalador-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
PruebaPedida
if (-not $script:TOKEN) { Log "Falta el token: correr el instalador."; exit 1 }
Log "Agente $VERSION en $AGENTE · impresora «$imp» · registro de Windows: $(if (RegistroActivo) { 'activo' } else { 'APAGADO' })"
$ultimoTrabajo = [datetime]::MinValue; $fallasSeguidas = 0; $reconciliado = $false
while ($true) {
  PruebaPedida
  try {
    $imp = ElegirImpresora
    $e = EstadoImpresora $imp
    $texto = $e.texto; if ($script:estadoExtra) { $texto = $script:estadoExtra }
    if (-not (RegistroActivo)) { $texto += " · registro de impresión de Windows apagado" }
    $r = Rpc "qr_imp_tomar" @{ p = @{ agente = $AGENTE; impresora = $imp; estado_impresora = $texto; version = $VERSION; lista = [bool]($e.lista -and $reconciliado) } }
    $fallasSeguidas = 0
    if ($r.pendientes -and @($r.pendientes).Count) { Reconciliar @($r.pendientes) $imp }
    $reconciliado = $true
    if ($r.trabajo) { Procesar $r.trabajo $imp; $ultimoTrabajo = Get-Date; continue }
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
