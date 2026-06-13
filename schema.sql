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
  es_pedido_faltante BOOLEAN DEFAULT false,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

-- ⚠️ Si la tabla ya existe, correr esto manualmente en Supabase SQL Editor:
-- ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS es_pedido_faltante BOOLEAN DEFAULT false;

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

-- ============================================================
-- NUEVAS COLUMNAS EN PEDIDOS (quién armó / facturó)
-- ============================================================
ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS armado_por    TEXT;
ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS armado_at     TIMESTAMPTZ;
ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS facturado_at  TIMESTAMPTZ;

-- ============================================================
-- COLUMNAS FALTANTES EN ITEMS_PEDIDO
-- (usadas por deposito.html y facturacion.html)
-- ============================================================
ALTER TABLE items_pedido ADD COLUMN IF NOT EXISTS es_faltante     BOOLEAN DEFAULT false;
ALTER TABLE items_pedido ADD COLUMN IF NOT EXISTS modificado       BOOLEAN DEFAULT false;
ALTER TABLE items_pedido ADD COLUMN IF NOT EXISTS nombre_original  TEXT;
ALTER TABLE items_pedido ADD COLUMN IF NOT EXISTS cantidad_real    NUMERIC;

-- ============================================================
-- SUSTITUCIÓN DE ARTÍCULOS EN FACTURACIÓN
-- Cuando facturación envía un artículo distinto al pedido original:
--   - el item original queda es_faltante=true
--   - se inserta un nuevo item con es_reemplazo=true y reemplaza_item_id apuntando al original
-- ============================================================
ALTER TABLE items_pedido ADD COLUMN IF NOT EXISTS es_reemplazo      BOOLEAN DEFAULT false;
ALTER TABLE items_pedido ADD COLUMN IF NOT EXISTS reemplaza_item_id UUID REFERENCES items_pedido(id);

-- ============================================================
-- NOTAS POR CLIENTE (escribe/ve Laura en facturación)
-- ============================================================
CREATE TABLE IF NOT EXISTS notas_cliente (
  id         uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  cliente_id TEXT NOT NULL,
  nota       TEXT NOT NULL,
  created_by TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notas_cliente_id  ON notas_cliente(cliente_id);
CREATE INDEX IF NOT EXISTS idx_notas_created_at  ON notas_cliente(created_at DESC);

ALTER TABLE notas_cliente ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_all_notas" ON notas_cliente FOR ALL USING (true) WITH CHECK (true);

-- ============================================================
-- TABLA CLIENTES — fuente primaria para la app de vendedores
-- ============================================================
-- Columnas alineadas con codigo.gs (trigger cada 10 min desde Google Sheets)
CREATE TABLE IF NOT EXISTS clientes (
  id          TEXT PRIMARY KEY,          -- NumeroCliente (ej: "10001")
  nombre      TEXT,                      -- col Nombre del sheet
  apellido    TEXT,                      -- col Apellido del sheet (nombre del negocio)
  domicilio   TEXT,
  localidad   TEXT,
  lat         TEXT,
  lng         TEXT,
  vendedor    TEXT,
  activo      BOOLEAN DEFAULT true,
  updated_at  TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_clientes_vendedor  ON clientes(vendedor);
CREATE INDEX IF NOT EXISTS idx_clientes_activo    ON clientes(activo);
CREATE INDEX IF NOT EXISTS idx_clientes_updated   ON clientes(updated_at DESC);

-- Día de entrega habitual: 0=Dom 1=Lun 2=Mar 3=Mié 4=Jue 5=Vie 6=Sáb / NULL=sin dato
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS dia_entrega_frecuente INTEGER;

ALTER TABLE clientes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_all_clientes" ON clientes FOR ALL USING (true) WITH CHECK (true);

-- ============================================================
-- TABLA PRODUCTOS — catálogo para la app de vendedores
-- ============================================================
CREATE TABLE IF NOT EXISTS productos (
  id          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  nombre      TEXT NOT NULL,
  marca       TEXT,
  precio      NUMERIC,
  keywords    TEXT,                      -- palabras clave separadas por coma para búsqueda
  activo      BOOLEAN DEFAULT true,
  updated_at  TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_productos_activo   ON productos(activo);
CREATE INDEX IF NOT EXISTS idx_productos_marca    ON productos(marca);
CREATE INDEX IF NOT EXISTS idx_productos_updated  ON productos(updated_at DESC);

ALTER TABLE productos ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_all_productos" ON productos FOR ALL USING (true) WITH CHECK (true);

-- ============================================================
-- TABLA PEDIDOS_HISTORIAL — historial completo de pedidos de vendedores
-- Alimentado por GAS syncHistorialASupabase() cada 30 min
-- Usado por la app de vendedores para sugerencias ("Sugeridos")
-- ============================================================
CREATE TABLE IF NOT EXISTS pedidos_historial (
  id               BIGSERIAL PRIMARY KEY,
  sig              TEXT UNIQUE NOT NULL,   -- hash deduplicador (de GAS o calculado)
  timestamp_pedido TIMESTAMPTZ,            -- cuándo se registró el pedido
  fecha_entrega    DATE,                   -- fecha de entrega acordada
  cliente_id       TEXT NOT NULL,          -- número de cliente (mismo que clientes.id)
  vendedor         TEXT,                   -- nombre del vendedor
  productos        TEXT,                   -- texto libre: "CANT NOMBRE\nCANT NOMBRE"
  observaciones    TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_hist_cliente   ON pedidos_historial(cliente_id);
CREATE INDEX IF NOT EXISTS idx_hist_vendedor  ON pedidos_historial(vendedor);
CREATE INDEX IF NOT EXISTS idx_hist_fecha     ON pedidos_historial(fecha_entrega DESC);
CREATE INDEX IF NOT EXISTS idx_hist_ts        ON pedidos_historial(timestamp_pedido DESC);

ALTER TABLE pedidos_historial ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_read_historial" ON pedidos_historial FOR SELECT USING (true);
CREATE POLICY "service_write_historial" ON pedidos_historial FOR ALL USING (true) WITH CHECK (true);

-- ============================================================
-- NÚMERO DIARIO — Supabase lo asigna automáticamente en cada INSERT
-- Se reinicia cada día (cuenta los pedidos del mismo día UTC-3)
-- El worker NO lo envía; se calcula aquí con un trigger BEFORE INSERT
-- ============================================================
ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS numero_diario INTEGER;

CREATE OR REPLACE FUNCTION set_numero_diario()
RETURNS TRIGGER AS $$
DECLARE
  dia DATE;
BEGIN
  -- Usar fecha_pedido si está disponible, si no now() — ambas en UTC pero la lógica es la misma
  dia := COALESCE(NEW.fecha_pedido, now())::date;
  SELECT COALESCE(MAX(numero_diario), 0) + 1
    INTO NEW.numero_diario
    FROM pedidos
   WHERE fecha_pedido::date = dia;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_numero_diario ON pedidos;
CREATE TRIGGER trg_numero_diario
  BEFORE INSERT ON pedidos
  FOR EACH ROW EXECUTE FUNCTION set_numero_diario();
