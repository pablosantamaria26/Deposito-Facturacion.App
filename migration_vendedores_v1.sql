-- ============================================================
-- MIGRACIÓN: app-vendedores → Supabase completo
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. VENDEDORES (credenciales, si no existe) ──────────────
CREATE TABLE IF NOT EXISTS vendedores (
  id         BIGSERIAL PRIMARY KEY,
  username   TEXT UNIQUE NOT NULL,
  pin        TEXT NOT NULL,
  nombre     TEXT NOT NULL,
  activo     BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE vendedores ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS service_all_vendedores ON vendedores;
CREATE POLICY service_all_vendedores ON vendedores FOR ALL USING (true) WITH CHECK (true);

-- Credenciales (mismas que GAS: martin/1095, ramiro/2011, fede/1234, admin/2817)
INSERT INTO vendedores (username, pin, nombre, activo) VALUES
  ('martin', '1095', 'MARTIN', true),
  ('ramiro', '2011', 'RAMIRO', true),
  ('fede',   '1234', 'FEDE',   true),
  ('admin',  '2817', 'TODOS',  true)
ON CONFLICT (username) DO NOTHING;

-- ── 2. VISITAS ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS visitas (
  id         BIGSERIAL PRIMARY KEY,
  cliente_id TEXT NOT NULL,
  vendedor   TEXT NOT NULL,
  tipo       TEXT NOT NULL,   -- 'venta' | 'visita' | 'no_compro' | 'no_llegue' | 'pedido'
  nota       TEXT,
  lat        TEXT,
  lng        TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_visitas_cliente   ON visitas(cliente_id);
CREATE INDEX IF NOT EXISTS idx_visitas_vendedor  ON visitas(vendedor);
CREATE INDEX IF NOT EXISTS idx_visitas_created   ON visitas(created_at DESC);
ALTER TABLE visitas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS service_all_visitas ON visitas;
CREATE POLICY service_all_visitas ON visitas FOR ALL USING (true) WITH CHECK (true);

-- ── 3. TIMELINE_CLIENTE ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS timeline_cliente (
  id         BIGSERIAL PRIMARY KEY,
  cliente_id TEXT NOT NULL,
  vendedor   TEXT NOT NULL,
  tipo       TEXT NOT NULL,
  resumen    TEXT,
  origen     TEXT DEFAULT 'manual',  -- 'manual' | 'ia'
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_timeline_cliente  ON timeline_cliente(cliente_id);
CREATE INDEX IF NOT EXISTS idx_timeline_vendedor ON timeline_cliente(vendedor);
CREATE INDEX IF NOT EXISTS idx_timeline_created  ON timeline_cliente(created_at DESC);
ALTER TABLE timeline_cliente ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS service_all_timeline ON timeline_cliente;
CREATE POLICY service_all_timeline ON timeline_cliente FOR ALL USING (true) WITH CHECK (true);

-- ── 4. JORNADAS ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS jornadas (
  id           BIGSERIAL PRIMARY KEY,
  jornada_id   TEXT UNIQUE NOT NULL,          -- J-MARTIN-2026-04-01-MANANA-1743500000000
  vendedor     TEXT NOT NULL,
  turno        TEXT NOT NULL,                 -- 'Mañana' | 'Tarde'
  zonas        JSONB DEFAULT '[]',            -- ["Glew","Burzaco",...]
  estado       TEXT NOT NULL DEFAULT 'ACTIVA', -- 'ACTIVA' | 'FINALIZADA'
  inicio_fecha DATE NOT NULL,
  inicio_at    TIMESTAMPTZ DEFAULT NOW(),
  fin_at       TIMESTAMPTZ,
  notas        TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_jornadas_vendedor_fecha ON jornadas(vendedor, inicio_fecha, estado);
ALTER TABLE jornadas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS service_all_jornadas ON jornadas;
CREATE POLICY service_all_jornadas ON jornadas FOR ALL USING (true) WITH CHECK (true);

-- ── 5. RPC: get_vendedor_data ────────────────────────────────
-- Retorna clientes + zonas con estadísticas de visitas
CREATE OR REPLACE FUNCTION get_vendedor_data(p_vendedor TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_clientes JSONB;
  v_zonas    JSONB;
BEGIN
  -- Clientes del vendedor con dias_sin_comprar calculado
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',              c.id,
      'nombre',          c.nombre,
      'apellido',        c.apellido,
      'nombre_full',     TRIM(COALESCE(c.apellido,'') || ' ' || COALESCE(c.nombre,'')),
      'direccion',       COALESCE(c.domicilio,''),
      'localidad',       COALESCE(c.localidad,''),
      'localidad_key',   LOWER(REGEXP_REPLACE(COALESCE(c.localidad,''), '[^a-zA-Z0-9]', '', 'g')),
      'lat',             c.lat,
      'lng',             c.lng,
      'vendedor',        c.vendedor,
      'dias_sin_comprar', COALESCE(
        (SELECT EXTRACT(DAY FROM NOW() - MAX(v.created_at))::int
         FROM visitas v
         WHERE v.cliente_id = c.id
           AND v.tipo IN ('venta','pedido')),
        999
      )
    )
  ), '[]'::jsonb)
  INTO v_clientes
  FROM clientes c
  WHERE UPPER(c.vendedor) = UPPER(p_vendedor)
    AND c.activo = true;

  -- Zonas agrupadas con totales y críticos (>30 días sin comprar)
  SELECT COALESCE(jsonb_agg(z ORDER BY z->>'nombre'), '[]'::jsonb)
  INTO v_zonas
  FROM (
    SELECT jsonb_build_object(
      'nombre',         COALESCE(c.localidad,''),
      'total_clientes', COUNT(*),
      'criticos',       COUNT(*) FILTER (WHERE
        COALESCE(
          (SELECT EXTRACT(DAY FROM NOW() - MAX(v.created_at))::int
           FROM visitas v WHERE v.cliente_id = c.id AND v.tipo IN ('venta','pedido')),
          999
        ) > 30
      ),
      'promedio_dias',  ROUND(AVG(
        COALESCE(
          (SELECT EXTRACT(DAY FROM NOW() - MAX(v.created_at))::int
           FROM visitas v WHERE v.cliente_id = c.id AND v.tipo IN ('venta','pedido')),
          999
        )
      ))::int
    ) AS z
    FROM clientes c
    WHERE UPPER(c.vendedor) = UPPER(p_vendedor)
      AND c.activo = true
    GROUP BY c.localidad
  ) q;

  RETURN jsonb_build_object(
    'clientes', COALESCE(v_clientes, '[]'::jsonb),
    'zonas',    COALESCE(v_zonas,    '[]'::jsonb)
  );
END;
$$;

-- ── 6. RPC: search_clientes ──────────────────────────────────
-- Búsqueda de texto en cartera del vendedor
CREATE OR REPLACE FUNCTION search_clientes(p_vendedor TEXT, p_query TEXT, p_limit INT DEFAULT 8)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id',         c.id,
      'nombre',     c.nombre,
      'apellido',   c.apellido,
      'nombre_full', TRIM(COALESCE(c.apellido,'') || ' ' || COALESCE(c.nombre,'')),
      'direccion',  COALESCE(c.domicilio,''),
      'localidad',  COALESCE(c.localidad,'')
    ))
    FROM (
      SELECT c.*
      FROM clientes c
      WHERE UPPER(c.vendedor) = UPPER(p_vendedor)
        AND c.activo = true
        AND (
          c.id ILIKE '%' || p_query || '%'
          OR COALESCE(c.apellido,'') ILIKE '%' || p_query || '%'
          OR COALESCE(c.nombre,'')   ILIKE '%' || p_query || '%'
          OR COALESCE(c.domicilio,'') ILIKE '%' || p_query || '%'
          OR COALESCE(c.localidad,'') ILIKE '%' || p_query || '%'
        )
      ORDER BY
        CASE WHEN c.id = p_query THEN 0
             WHEN c.id ILIKE p_query || '%' THEN 1
             ELSE 2 END,
        c.apellido
      LIMIT p_limit
    ) c
  ), '[]'::jsonb);
END;
$$;

-- ── 7. RPC: cliente_lookup ───────────────────────────────────
-- Detalle completo de un cliente + último pedido del historial
CREATE OR REPLACE FUNCTION cliente_lookup(p_vendedor TEXT, p_cliente_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cliente    JSONB;
  v_ult_pedido JSONB;
  v_ticket     TEXT;
BEGIN
  -- Buscar cliente (primero en cartera del vendedor, luego cualquiera)
  SELECT jsonb_build_object(
    'id',            c.id,
    'nombre',        c.nombre,
    'apellido',      c.apellido,
    'nombre_full',   TRIM(COALESCE(c.apellido,'') || ' ' || COALESCE(c.nombre,'')),
    'direccion',     COALESCE(c.domicilio,''),
    'localidad',     COALESCE(c.localidad,''),
    'localidad_key', LOWER(REGEXP_REPLACE(COALESCE(c.localidad,''), '[^a-zA-Z0-9]', '', 'g')),
    'lat',           c.lat,
    'lng',           c.lng,
    'vendedor',      c.vendedor,
    'dias_sin_comprar', COALESCE(
      (SELECT EXTRACT(DAY FROM NOW() - MAX(v.created_at))::int
       FROM visitas v WHERE v.cliente_id = c.id AND v.tipo IN ('venta','pedido')),
      999
    )
  )
  INTO v_cliente
  FROM clientes c
  WHERE c.id = p_cliente_id
  ORDER BY (UPPER(c.vendedor) = UPPER(p_vendedor)) DESC
  LIMIT 1;

  -- Último pedido del historial
  SELECT jsonb_build_object(
    'fecha_entrega',  ph.fecha_entrega,
    'productos',      ph.productos,
    'observaciones',  ph.observaciones,
    'timestamp',      ph.timestamp_pedido
  )
  INTO v_ult_pedido
  FROM pedidos_historial ph
  WHERE ph.cliente_id = p_cliente_id
  ORDER BY ph.timestamp_pedido DESC NULLS LAST
  LIMIT 1;

  -- Ticket = texto de productos del último pedido
  v_ticket := COALESCE(v_ult_pedido->>'productos', '');

  RETURN jsonb_build_object(
    'cliente',       v_cliente,
    'ultimoPedido',  v_ult_pedido,
    'ticket',        v_ticket
  );
END;
$$;
