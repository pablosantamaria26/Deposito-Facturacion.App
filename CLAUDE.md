# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Two-PWA internal order management system for a distributor, deployed on GitHub Pages. No build step, no framework, no package manager — all files are plain HTML/CSS/JS served directly.

- **`deposito.html`** — Mobile-first PWA for warehouse workers to assemble orders
- **`facturacion.html`** — Desktop two-panel PWA for billing staff to invoice orders
- **`index.html`** — Landing page with links to both apps
- **`service-worker.js`** — PWA offline caching (cache-first, own domain only)
- **`schema.sql`** — Run manually in Supabase Dashboard → SQL Editor (not auto-applied)
- **`worker.txt`** — Source for the Cloudflare Worker (deployed separately via Cloudflare dashboard)
- **`codigo,gs.txt`** — Google Apps Script source (deployed via Google Drive)

## Deployment

- Push to `main` → GitHub Pages auto-deploys (no CI pipeline)
- Cloudflare Worker and Google Apps Script are deployed manually from their respective dashboards
- After schema changes, run the SQL manually in Supabase Dashboard → SQL Editor

## Architecture

### Data flow
```
Google Sheets (vendedores) → Google Apps Script → Cloudflare Worker → Supabase PostgreSQL
                                                                              ↓
                                                deposito.html / facturacion.html (Supabase REST + Realtime)
```

The Cloudflare Worker (`worker.txt`) acts as:
1. **Proxy** for the Google Apps Script (preserves original GAS behavior for vendors)
2. **Sync engine** — on each POST, fire-and-forgets a `syncPedidoASupabase()` to duplicate order data into Supabase
3. **AI proxy** — if POST body contains `{ prompt, sys }`, calls Gemini API and returns response
4. **REST API** — GET `/pedidos`, GET `/pedido/:id`, GET `/auditoria/:id`

### Supabase usage in the PWAs

Both HTML apps talk **directly to Supabase REST API** (not via the Worker). The anon key is embedded in the source. All state changes go through:
- `sbGet(table, params)` — GET with query string
- `sbPatch(table, matchParam, data)` — PATCH to update rows
- `sbInsert(table, data)` — POST to insert rows

Realtime is via a raw WebSocket to Supabase's realtime endpoint. On any change to `pedidos` or `items_pedido`, the app re-renders.

### Order lifecycle

`pendiente` → `armado` → `en_facturacion` → `facturado`

- `pendiente`: created by Worker from GAS sync
- `armado`: set by deposito.html when warehouse marks order complete; saves `armado_por` + `armado_at` on the `pedidos` row
- `en_facturacion`: set automatically when facturacion.html opens an `armado` order
- `facturado`: set by facturacion.html on final invoice action

### Key fields

**`pedidos`:** `cliente_id` (text, the client number), `cliente_nombre`, `fecha_entrega` (DATE), `estado`, `armado_por`, `armado_at`, `sig` (unique identifier from GAS, used for upsert deduplication)

**`items_pedido`:** per-item tracking of `armado`, `armado_por`, `armado_at`, `facturado`, `facturado_por`, `facturado_at`, `es_faltante`, `modificado`, `nombre_original`, `cantidad_real`

**`notas_cliente`:** free-text notes per `cliente_id`, written by billing staff, shown most-recent-first

### deposito.html specifics

- 3 tabs: **HOY** (urgente = fecha_entrega ≤ viernes this week, estado ≠ armado) / **PENDIENTES** (not urgent, not armado) / **ARMADOS** (estado = armado)
- Opening an order always shows a modal to confirm the assembler's name (saved in `localStorage` as `depositoArmador`)
- Inline edit bar per item (description + quantity) shows with ✏️ toggle; saves `modificado: true` to flag it in facturación
- Unmarking a checked item requires confirmation modal (marks as `es_faltante` in facturación)
- `viernesISO()` determines the urgency cutoff (orders due this week = urgent)

### facturacion.html specifics

- Login screen: choose A or C (saved to `localStorage` as `factUser`)
- Left panel has two tabs: **Pedidos** (current armado/en_facturacion/facturado) and **Historial** (search by exact `cliente_id` among `estado=facturado`)
- Right panel shows: client header with chips (Nº, armado_por, facturado status) → IA toolbar → items list → notas section (collapsible) → footer with stats + WA + invoice button
- Items have: checkbox (facturado), editable quantity (`cantidad_real`), faltante toggle (⚠️)
- **Notas**: loaded per `cliente_id` on every order open; anyone can write; `escHtml()` sanitizes output

### Service Worker

Cache version is hardcoded (`pedidos-ml-v25`). **Increment `CACHE_NAME` when deploying changes** so users get the new version. Only caches same-origin GET requests; all Supabase/Worker/Gemini calls bypass cache.

## Credentials (embedded in source)

- `SB_URL` / `SUPABASE_URL`: `https://gjeyvbidomxzofcdycya.supabase.co`
- `SB_ANON` / `SUPABASE_ANON`: `sb_publishable_CjdA8GwtCljm_PzT8pqk3g_QIhTmUHT` (anon/publishable key, safe to expose)
- `WORKER_URL`: `https://frosty-term-20ea.santamariapablodaniel.workers.dev`
- Worker env vars (`GEMINI_API_KEY`, `SUPABASE_SERVICE_KEY`) are set in Cloudflare dashboard, never in source
