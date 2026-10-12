-- 12/10/2026 — aplicado desde el dashboard de Supabase.
-- Cantidad que pidió el vendedor, guardada por deposito.html la primera vez que se edita la
-- cantidad de un artículo, para que facturación muestre "Cantidad pedida: 12 → depósito: 6".
-- (El nombre original ya se guardaba en nombre_original.)
alter table public.items_pedido add column if not exists cantidad_original numeric;
comment on column public.items_pedido.cantidad_original is
  'Cantidad que pidió el vendedor, guardada por depósito la primera vez que edita la cantidad (null = nunca se cambió)';
