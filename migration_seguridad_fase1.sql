-- Seguridad fase 1 (29/9/2026) — aplicado desde el dashboard de Supabase.
-- Cierra las 4 tablas que Supabase marcaba "rls_disabled_in_public" (cualquiera con la URL
-- podía leer, editar y borrar) dando a la clave pública SOLO lo que las apps usan de verdad.
-- Relevado en el código (stock-app-pwa, cobertura.html, faltantes.html, worker de stock) y en
-- los logs de la API: estas tablas solo reciben GET y POST. Los borrados/ediciones que hubo
-- fueron limpiezas manuales desde el dashboard, que no pasa por RLS y sigue funcionando.

begin;

-- proveedores: las apps solo la leen
alter table public.proveedores enable row level security;
create policy proveedores_leer on public.proveedores
  for select to anon, authenticated using (true);

-- stock_inventario: se lee y se cargan conteos nuevos; nunca se edita ni se borra desde apps
alter table public.stock_inventario enable row level security;
create policy stock_inventario_leer on public.stock_inventario
  for select to anon, authenticated using (true);
create policy stock_inventario_cargar on public.stock_inventario
  for insert to anon, authenticated with check (true);

-- productos_mapping: cobertura.html lee y agrega (POST con ignore-duplicates)
alter table public.productos_mapping enable row level security;
create policy productos_mapping_leer on public.productos_mapping
  for select to anon, authenticated using (true);
create policy productos_mapping_cargar on public.productos_mapping
  for insert to anon, authenticated with check (true);

-- productos_catalogo: vacía y sin uso → cerrada del todo (sin políticas = nadie con la clave pública)
alter table public.productos_catalogo enable row level security;

-- TRUNCATE vacía una tabla entera y NO respeta RLS: ninguna app lo usa
revoke truncate on all tables in schema public from anon, authenticated;

commit;
