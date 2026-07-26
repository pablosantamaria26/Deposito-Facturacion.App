-- ============================================================
-- MIGRACIÓN: Reactivación de clientes inactivos/nuevos + descuento
-- Ejecutar en: Supabase Dashboard → SQL Editor (una sola vez)
-- ============================================================

-- es_inactivo: marca clientes sin compras recientes (0% con aclaración en la app)
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS es_inactivo BOOLEAN DEFAULT false;

-- descuento_auto: clientes gestionados por la regla de reactivación (nuevos/inactivos),
-- para diferenciarlos de la cartera existente que ya tiene su descuento fijo/manual.
-- No dispara ninguna automatización hoy — es solo para reportes futuros.
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS descuento_auto BOOLEAN DEFAULT false;

-- reactivacion_pendiente: el vendedor marcó "este cliente vuelve a comprar" al cargar
-- un pedido. Queda pendiente hasta que Laura lo confirma en facturación (ahí se le
-- pone descuento=5, es_inactivo=false y este flag vuelve a false).
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS reactivacion_pendiente BOOLEAN DEFAULT false;
