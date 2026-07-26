-- ============================================================
-- MIGRACIÓN: Catálogo de artículos + mapping con pedidos reales
-- Para el sandbox de prueba (Fase 2/3/4) — no toca nada existente.
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- Catálogo de artículos, viene de "Lista costo-previo venta ml.xlsx"
CREATE TABLE IF NOT EXISTS articulos (
  codigo       TEXT PRIMARY KEY,       -- "Artículo" del Excel (código numérico o interno)
  descripcion  TEXT NOT NULL,
  costo        NUMERIC,
  pct_util     NUMERIC,
  mayorista    NUMERIC,                -- precio de lista actual
  updated_at   TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_articulos_desc ON articulos USING gin (to_tsvector('spanish', descripcion));
ALTER TABLE articulos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS public_all_articulos ON articulos;
CREATE POLICY public_all_articulos ON articulos FOR ALL USING (true) WITH CHECK (true);

-- Mapping: qué código de articulos corresponde a cada frase real que
-- escriben los vendedores en los pedidos (igual patrón que productos_mapping
-- de cobertura.html, pero para precios en vez de stock).
CREATE TABLE IF NOT EXISTS articulo_mapping (
  id                  uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  descripcion_pedido  TEXT NOT NULL,   -- frase tal cual la escribió el vendedor
  codigo_articulo     TEXT REFERENCES articulos(codigo),
  confianza           NUMERIC,         -- 0 a 1, la que devuelve Gemini
  source              TEXT DEFAULT 'gemini',  -- 'gemini' | 'manual'
  aprobado            BOOLEAN DEFAULT false,  -- true = ya lo revisó una persona
  created_at          TIMESTAMPTZ DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_mapping_desc ON articulo_mapping (descripcion_pedido);
ALTER TABLE articulo_mapping ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS public_all_articulo_mapping ON articulo_mapping;
CREATE POLICY public_all_articulo_mapping ON articulo_mapping FOR ALL USING (true) WITH CHECK (true);
