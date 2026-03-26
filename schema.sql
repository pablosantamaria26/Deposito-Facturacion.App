-- ============================================================
-- SCHEMA SUPABASE — Pedidos ML
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- PEDIDOS
CREATE TABLE IF NOT EXISTS pedidos (
  id            uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  numero        TEXT,
  cliente_id    TEXT,
  cliente_nombre TEXT,
  vendedor      TEXT,
  fecha_pedido  TIMESTAMPTZ DEFAULT now(),
  fecha_entrega DATE,
  observaciones TEXT,
  productos_raw TEXT,
  estado        TEXT DEFAULT 'pendiente'
                  CHECK (estado IN ('pendiente','armado','en_facturacion','facturado','cancelado')),
  archivo_drive_id TEXT,
  sig           TEXT UNIQUE,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

-- ITEMS DE CADA PEDIDO
CREATE TABLE IF NOT EXISTS items_pedido (
  id            uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  pedido_id     uuid REFERENCES pedidos(id) ON DELETE CASCADE,
  descripcion   TEXT NOT NULL,
  cantidad      NUMERIC DEFAULT 1,
  armado        BOOLEAN DEFAULT false,
  armado_por    TEXT,
  armado_at     TIMESTAMPTZ,
  facturado     BOOLEAN DEFAULT false,
  facturado_por TEXT,
  facturado_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT now()
);

-- AUDITORÍA COMPLETA
CREATE TABLE IF NOT EXISTS auditoria (
  id         uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  pedido_id  uuid REFERENCES pedidos(id) ON DELETE SET NULL,
  accion     TEXT NOT NULL,
  usuario    TEXT,
  detalle    JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- ÍNDICES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_pedidos_estado       ON pedidos(estado);
CREATE INDEX IF NOT EXISTS idx_pedidos_fecha_entrega ON pedidos(fecha_entrega);
CREATE INDEX IF NOT EXISTS idx_pedidos_created_at   ON pedidos(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_items_pedido_id      ON items_pedido(pedido_id);
CREATE INDEX IF NOT EXISTS idx_auditoria_pedido_id  ON auditoria(pedido_id);
CREATE INDEX IF NOT EXISTS idx_auditoria_created_at ON auditoria(created_at DESC);

-- ============================================================
-- UPDATED_AT AUTOMÁTICO
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pedidos_updated_at ON pedidos;
CREATE TRIGGER trg_pedidos_updated_at
  BEFORE UPDATE ON pedidos
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- REALTIME — habilitar para websockets
-- ============================================================
ALTER PUBLICATION supabase_realtime ADD TABLE pedidos;
ALTER PUBLICATION supabase_realtime ADD TABLE items_pedido;

-- ============================================================
-- RLS — Row Level Security (todo público por ahora, ajustar con auth)
-- ============================================================
ALTER TABLE pedidos      ENABLE ROW LEVEL SECURITY;
ALTER TABLE items_pedido ENABLE ROW LEVEL SECURITY;
ALTER TABLE auditoria    ENABLE ROW LEVEL SECURITY;

-- Políticas abiertas (reemplazar con auth cuando tengan login)
CREATE POLICY "public_all_pedidos"      ON pedidos      FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "public_all_items"        ON items_pedido FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "public_all_auditoria"    ON auditoria    FOR ALL USING (true) WITH CHECK (true);
