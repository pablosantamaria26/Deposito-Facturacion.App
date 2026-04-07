-- =============================================================================
-- analytics_views.sql
-- ACTUALIZADO: Se agregaron vistas de comparación semana/mes,
--              proyección del negocio y rendimiento detallado por vendedor.
-- Vistas analíticas para el sistema de pedidos
-- Timezone: America/Argentina/Buenos_Aires
-- Compatible con PostgreSQL 15 (Supabase)
-- Ejecutar en Supabase Dashboard → SQL Editor
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. v_kpi_hoy
--    Métricas del día actual:
--    - pedidos creados hoy
--    - pedidos facturados hoy
--    - items faltantes hoy (en pedidos creados hoy)
--    - pedidos pendientes ahora (estado = 'pendiente')
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_kpi_hoy AS
SELECT
    (
        SELECT COUNT(*)
        FROM pedidos
        WHERE DATE(created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
            = CURRENT_DATE AT TIME ZONE 'America/Argentina/Buenos_Aires'
    ) AS pedidos_creados_hoy,

    (
        SELECT COUNT(*)
        FROM pedidos
        WHERE estado = 'facturado'
          AND DATE(facturado_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
            = CURRENT_DATE AT TIME ZONE 'America/Argentina/Buenos_Aires'
    ) AS pedidos_facturados_hoy,

    (
        SELECT COUNT(*)
        FROM items_pedido ip
        JOIN pedidos p ON p.id = ip.pedido_id
        WHERE ip.es_faltante = TRUE
          AND DATE(p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
            = CURRENT_DATE AT TIME ZONE 'America/Argentina/Buenos_Aires'
    ) AS items_faltantes_hoy,

    (
        SELECT COUNT(*)
        FROM pedidos
        WHERE estado = 'pendiente'
    ) AS pedidos_pendientes_ahora;


-- -----------------------------------------------------------------------------
-- 2. v_pedidos_por_dia
--    Últimos 60 días: por cada fecha, cantidad de pedidos creados,
--    facturados y con al menos un item faltante.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_pedidos_por_dia AS
WITH dias AS (
    SELECT generate_series(
        (CURRENT_DATE AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '59 days',
        (CURRENT_DATE AT TIME ZONE 'America/Argentina/Buenos_Aires'),
        INTERVAL '1 day'
    )::DATE AS fecha
),
pedidos_dia AS (
    SELECT
        DATE(created_at AT TIME ZONE 'America/Argentina/Buenos_Aires') AS fecha,
        COUNT(*) AS cantidad_pedidos,
        COUNT(*) FILTER (WHERE estado = 'facturado') AS cantidad_facturados,
        id
    FROM pedidos
    WHERE DATE(created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        >= (CURRENT_DATE AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '59 days'
    GROUP BY DATE(created_at AT TIME ZONE 'America/Argentina/Buenos_Aires'), id
),
pedidos_agrupados AS (
    SELECT
        fecha,
        SUM(1) AS cantidad_pedidos,
        SUM(CASE WHEN estado = 'facturado' THEN 1 ELSE 0 END) AS cantidad_facturados
    FROM (
        SELECT
            DATE(p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires') AS fecha,
            p.id,
            p.estado
        FROM pedidos p
        WHERE DATE(p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
            >= (CURRENT_DATE AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '59 days'
    ) sub
    GROUP BY fecha
),
faltantes_dia AS (
    SELECT
        DATE(p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires') AS fecha,
        COUNT(ip.id) AS cantidad_faltantes
    FROM items_pedido ip
    JOIN pedidos p ON p.id = ip.pedido_id
    WHERE ip.es_faltante = TRUE
      AND DATE(p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        >= (CURRENT_DATE AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '59 days'
    GROUP BY DATE(p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
)
SELECT
    d.fecha,
    COALESCE(pa.cantidad_pedidos, 0)   AS cantidad_pedidos,
    COALESCE(pa.cantidad_facturados, 0) AS cantidad_facturados,
    COALESCE(fd.cantidad_faltantes, 0)  AS cantidad_faltantes
FROM dias d
LEFT JOIN pedidos_agrupados pa ON pa.fecha = d.fecha
LEFT JOIN faltantes_dia      fd ON fd.fecha = d.fecha
ORDER BY d.fecha DESC;


-- -----------------------------------------------------------------------------
-- 3. v_faltantes_frecuentes
--    Últimos 90 días: artículos que aparecieron como faltante, ordenados
--    por frecuencia descendente.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_faltantes_frecuentes AS
SELECT
    LOWER(TRIM(ip.descripcion))          AS descripcion,
    COUNT(*)                              AS veces_faltante,
    MAX(p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::DATE AS ultima_vez,
    COUNT(DISTINCT p.cliente_id)          AS clientes_distintos
FROM items_pedido ip
JOIN pedidos p ON p.id = ip.pedido_id
WHERE ip.es_faltante = TRUE
  AND p.created_at >= NOW() - INTERVAL '90 days'
GROUP BY LOWER(TRIM(ip.descripcion))
ORDER BY veces_faltante DESC;


-- -----------------------------------------------------------------------------
-- 4. v_top_productos
--    Últimos 90 días: productos más pedidos, con flag si son faltantes
--    frecuentes (>= 3 veces faltante en el mismo período).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_top_productos AS
WITH faltantes_freq AS (
    SELECT LOWER(TRIM(ip.descripcion)) AS descripcion
    FROM items_pedido ip
    JOIN pedidos p ON p.id = ip.pedido_id
    WHERE ip.es_faltante = TRUE
      AND p.created_at >= NOW() - INTERVAL '90 days'
    GROUP BY LOWER(TRIM(ip.descripcion))
    HAVING COUNT(*) >= 3
)
SELECT
    LOWER(TRIM(ip.descripcion))                     AS descripcion,
    COUNT(ip.id)                                     AS veces_pedido,
    SUM(COALESCE(ip.cantidad, 0))                    AS cantidad_total,
    EXISTS (
        SELECT 1 FROM faltantes_freq ff
        WHERE ff.descripcion = LOWER(TRIM(ip.descripcion))
    )                                                AS es_frecuente_faltante
FROM items_pedido ip
JOIN pedidos p ON p.id = ip.pedido_id
WHERE p.created_at >= NOW() - INTERVAL '90 days'
GROUP BY LOWER(TRIM(ip.descripcion))
ORDER BY veces_pedido DESC;


-- -----------------------------------------------------------------------------
-- 5. v_top_clientes
--    Últimos 90 días: clientes con más actividad.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_top_clientes AS
SELECT
    p.cliente_id,
    MAX(p.cliente_nombre)                   AS cliente_nombre,
    COUNT(DISTINCT p.id)                    AS pedidos_total,
    SUM(COALESCE(ip.cantidad, 0))           AS items_total,
    COUNT(ip.id) FILTER (WHERE ip.es_faltante = TRUE) AS faltantes_total,
    MAX(p.fecha_pedido AT TIME ZONE 'America/Argentina/Buenos_Aires')::DATE AS ultimo_pedido
FROM pedidos p
LEFT JOIN items_pedido ip ON ip.pedido_id = p.id
WHERE p.created_at >= NOW() - INTERVAL '90 days'
GROUP BY p.cliente_id
ORDER BY pedidos_total DESC;


-- -----------------------------------------------------------------------------
-- 6. v_tendencia_vendedor
--    Mes actual vs mes anterior: pedidos por vendedor y variación porcentual.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_tendencia_vendedor AS
WITH
mes_actual AS (
    SELECT
        vendedor,
        COUNT(*) AS pedidos
    FROM pedidos
    WHERE DATE_TRUNC('month', created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('month', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')
    GROUP BY vendedor
),
mes_anterior AS (
    SELECT
        vendedor,
        COUNT(*) AS pedidos
    FROM pedidos
    WHERE DATE_TRUNC('month', created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('month', (NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '1 month')
    GROUP BY vendedor
)
SELECT
    COALESCE(ma.vendedor, mant.vendedor)    AS vendedor,
    COALESCE(ma.pedidos, 0)                 AS pedidos_mes_actual,
    COALESCE(mant.pedidos, 0)               AS pedidos_mes_anterior,
    CASE
        WHEN COALESCE(mant.pedidos, 0) = 0 THEN NULL
        ELSE ROUND(
            ((COALESCE(ma.pedidos, 0)::NUMERIC - COALESCE(mant.pedidos, 0)::NUMERIC)
             / COALESCE(mant.pedidos, 0)::NUMERIC) * 100,
            2
        )
    END                                     AS variacion_pct
FROM mes_actual   ma
FULL OUTER JOIN mes_anterior mant ON mant.vendedor = ma.vendedor
ORDER BY pedidos_mes_actual DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 7. v_alertas_faltantes
--    Artículos que llevan faltando >= 2 semanas consecutivas:
--    por semana ISO, se detecta si el artículo tuvo al menos un faltante;
--    luego se cuentan semanas consecutivas hasta hoy (desde la semana más reciente).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_alertas_faltantes AS
WITH semanas_faltante AS (
    -- Por cada artículo y semana ISO: ¿tuvo algún faltante?
    SELECT
        LOWER(TRIM(ip.descripcion))                                         AS descripcion,
        DATE_TRUNC('week', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::DATE AS semana,
        COUNT(DISTINCT p.cliente_id)                                        AS clientes_en_semana,
        MIN(p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::DATE AS primera_en_semana
    FROM items_pedido ip
    JOIN pedidos p ON p.id = ip.pedido_id
    WHERE ip.es_faltante = TRUE
      AND p.created_at >= NOW() - INTERVAL '180 days'
    GROUP BY LOWER(TRIM(ip.descripcion)),
             DATE_TRUNC('week', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
),
semanas_esperadas AS (
    -- Semanas ISO de los últimos 180 días
    SELECT generate_series(
        DATE_TRUNC('week', (NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '180 days'),
        DATE_TRUNC('week',  NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires'),
        INTERVAL '1 week'
    )::DATE AS semana
),
consecutivas AS (
    -- Para cada artículo, contar cuántas semanas consecutivas lleva faltando
    -- desde la semana más reciente hacia atrás
    SELECT
        sf.descripcion,
        sf.semana,
        sf.clientes_en_semana,
        sf.primera_en_semana,
        -- Número de semana ordinal desde el inicio del rango (para detectar brechas)
        ROW_NUMBER() OVER (PARTITION BY sf.descripcion ORDER BY sf.semana DESC) AS rn,
        -- Diferencia entre semana esperada y semana real (si hay brecha, cambia)
        (DATE_TRUNC('week', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')::DATE
            - sf.semana) / 7 AS semanas_desde_hoy
    FROM semanas_faltante sf
),
racha AS (
    -- Racha consecutiva: semanas donde rn = semanas_desde_hoy (sin brechas)
    SELECT
        descripcion,
        semana,
        clientes_en_semana,
        primera_en_semana,
        rn,
        semanas_desde_hoy,
        (rn = semanas_desde_hoy) AS es_consecutiva
    FROM consecutivas
),
racha_continua AS (
    -- Contar cuántas semanas consecutivas desde hoy hacia atrás sin interrupción
    SELECT
        descripcion,
        COUNT(*) FILTER (WHERE es_consecutiva) AS semanas_faltando,
        SUM(clientes_en_semana) FILTER (WHERE es_consecutiva) AS clientes_sum,
        MIN(primera_en_semana) FILTER (WHERE es_consecutiva) AS primera_vez_faltante
    FROM racha
    GROUP BY descripcion
)
SELECT
    rc.descripcion,
    rc.semanas_faltando,
    -- clientes_afectados: distintos en todo el período consecutivo (aproximado via SUM)
    rc.clientes_sum                             AS clientes_afectados,
    rc.primera_vez_faltante
FROM racha_continua rc
WHERE rc.semanas_faltando >= 2
ORDER BY rc.semanas_faltando DESC, rc.descripcion;


-- -----------------------------------------------------------------------------
-- 8. v_comparacion_semanas
--    Semana actual vs semana anterior: pedidos, facturados, faltantes y
--    variación porcentual. Una sola fila de resultado.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_comparacion_semanas AS
WITH
tz AS (SELECT 'America/Argentina/Buenos_Aires' AS tz),
semana_actual AS (
    SELECT
        COUNT(*)                                             AS pedidos,
        COUNT(*) FILTER (WHERE p.estado = 'facturado')      AS facturados,
        COALESCE((
            SELECT COUNT(ip2.id)
            FROM items_pedido ip2
            JOIN pedidos p2 ON p2.id = ip2.pedido_id
            WHERE ip2.es_faltante = TRUE
              AND DATE_TRUNC('week', p2.created_at AT TIME ZONE (SELECT tz FROM tz))
                  = DATE_TRUNC('week', NOW() AT TIME ZONE (SELECT tz FROM tz))
        ), 0)                                                AS faltantes,
        COALESCE((
            SELECT COUNT(ip2.id)
            FROM items_pedido ip2
            JOIN pedidos p2 ON p2.id = ip2.pedido_id
            WHERE DATE_TRUNC('week', p2.created_at AT TIME ZONE (SELECT tz FROM tz))
                  = DATE_TRUNC('week', NOW() AT TIME ZONE (SELECT tz FROM tz))
        ), 0)                                                AS items_total
    FROM pedidos p
    WHERE DATE_TRUNC('week', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('week', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')
),
semana_anterior AS (
    SELECT
        COUNT(*)                                             AS pedidos,
        COUNT(*) FILTER (WHERE p.estado = 'facturado')      AS facturados,
        COALESCE((
            SELECT COUNT(ip2.id)
            FROM items_pedido ip2
            JOIN pedidos p2 ON p2.id = ip2.pedido_id
            WHERE ip2.es_faltante = TRUE
              AND DATE_TRUNC('week', p2.created_at AT TIME ZONE (SELECT tz FROM tz))
                  = DATE_TRUNC('week', (NOW() AT TIME ZONE (SELECT tz FROM tz)) - INTERVAL '1 week')
        ), 0)                                                AS faltantes,
        COALESCE((
            SELECT COUNT(ip2.id)
            FROM items_pedido ip2
            JOIN pedidos p2 ON p2.id = ip2.pedido_id
            WHERE DATE_TRUNC('week', p2.created_at AT TIME ZONE (SELECT tz FROM tz))
                  = DATE_TRUNC('week', (NOW() AT TIME ZONE (SELECT tz FROM tz)) - INTERVAL '1 week')
        ), 0)                                                AS items_total
    FROM pedidos p
    WHERE DATE_TRUNC('week', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('week', (NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '1 week')
)
SELECT
    sa.pedidos                                        AS pedidos_actual,
    sa.facturados                                     AS facturados_actual,
    sa.faltantes                                      AS faltantes_actual,
    sa.items_total                                    AS items_actual,
    sp.pedidos                                        AS pedidos_anterior,
    sp.facturados                                     AS facturados_anterior,
    sp.faltantes                                      AS faltantes_anterior,
    sp.items_total                                    AS items_anterior,
    CASE WHEN sp.pedidos > 0
         THEN ROUND(((sa.pedidos::NUMERIC - sp.pedidos::NUMERIC) / sp.pedidos::NUMERIC) * 100, 1)
         ELSE NULL END                                AS var_pedidos_pct,
    CASE WHEN sp.faltantes > 0
         THEN ROUND(((sa.faltantes::NUMERIC - sp.faltantes::NUMERIC) / sp.faltantes::NUMERIC) * 100, 1)
         ELSE NULL END                                AS var_faltantes_pct,
    CASE WHEN sp.facturados > 0
         THEN ROUND(((sa.facturados::NUMERIC - sp.facturados::NUMERIC) / sp.facturados::NUMERIC) * 100, 1)
         ELSE NULL END                                AS var_facturados_pct
FROM semana_actual sa, semana_anterior sp;


-- -----------------------------------------------------------------------------
-- 9. v_comparacion_meses
--    Mes actual vs mes anterior: pedidos, facturados, faltantes y variación %.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_comparacion_meses AS
WITH
mes_actual AS (
    SELECT
        COUNT(*)                                             AS pedidos,
        COUNT(*) FILTER (WHERE p.estado = 'facturado')      AS facturados,
        COALESCE((
            SELECT COUNT(ip2.id)
            FROM items_pedido ip2
            JOIN pedidos p2 ON p2.id = ip2.pedido_id
            WHERE ip2.es_faltante = TRUE
              AND DATE_TRUNC('month', p2.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
                  = DATE_TRUNC('month', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')
        ), 0)                                                AS faltantes,
        COALESCE((
            SELECT COUNT(ip2.id)
            FROM items_pedido ip2
            JOIN pedidos p2 ON p2.id = ip2.pedido_id
            WHERE DATE_TRUNC('month', p2.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
                  = DATE_TRUNC('month', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')
        ), 0)                                                AS items_total
    FROM pedidos p
    WHERE DATE_TRUNC('month', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('month', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')
),
mes_anterior AS (
    SELECT
        COUNT(*)                                             AS pedidos,
        COUNT(*) FILTER (WHERE p.estado = 'facturado')      AS facturados,
        COALESCE((
            SELECT COUNT(ip2.id)
            FROM items_pedido ip2
            JOIN pedidos p2 ON p2.id = ip2.pedido_id
            WHERE ip2.es_faltante = TRUE
              AND DATE_TRUNC('month', p2.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
                  = DATE_TRUNC('month', (NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '1 month')
        ), 0)                                                AS faltantes,
        COALESCE((
            SELECT COUNT(ip2.id)
            FROM items_pedido ip2
            JOIN pedidos p2 ON p2.id = ip2.pedido_id
            WHERE DATE_TRUNC('month', p2.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
                  = DATE_TRUNC('month', (NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '1 month')
        ), 0)                                                AS items_total
    FROM pedidos p
    WHERE DATE_TRUNC('month', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('month', (NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '1 month')
)
SELECT
    ma.pedidos                                        AS pedidos_actual,
    ma.facturados                                     AS facturados_actual,
    ma.faltantes                                      AS faltantes_actual,
    ma.items_total                                    AS items_actual,
    mant.pedidos                                      AS pedidos_anterior,
    mant.facturados                                   AS facturados_anterior,
    mant.faltantes                                    AS faltantes_anterior,
    mant.items_total                                  AS items_anterior,
    CASE WHEN mant.pedidos > 0
         THEN ROUND(((ma.pedidos::NUMERIC - mant.pedidos::NUMERIC) / mant.pedidos::NUMERIC) * 100, 1)
         ELSE NULL END                                AS var_pedidos_pct,
    CASE WHEN mant.faltantes > 0
         THEN ROUND(((ma.faltantes::NUMERIC - mant.faltantes::NUMERIC) / mant.faltantes::NUMERIC) * 100, 1)
         ELSE NULL END                                AS var_faltantes_pct,
    CASE WHEN mant.facturados > 0
         THEN ROUND(((ma.facturados::NUMERIC - mant.facturados::NUMERIC) / mant.facturados::NUMERIC) * 100, 1)
         ELSE NULL END                                AS var_facturados_pct
FROM mes_actual ma, mes_anterior mant;


-- -----------------------------------------------------------------------------
-- 10. v_proyeccion_semanal
--     Últimas 8 semanas: pedidos, facturados y faltantes por semana ISO.
--     Permite calcular tendencia, proyección de fin de mes y detectar si
--     los faltantes mejoran o empeoran.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_proyeccion_semanal AS
WITH semanas AS (
    SELECT generate_series(
        DATE_TRUNC('week', (NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '7 weeks'),
        DATE_TRUNC('week',  NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires'),
        INTERVAL '1 week'
    )::DATE AS semana_inicio
),
pedidos_sem AS (
    SELECT
        DATE_TRUNC('week', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::DATE AS semana_inicio,
        COUNT(*)                                           AS pedidos,
        COUNT(*) FILTER (WHERE p.estado = 'facturado')    AS facturados
    FROM pedidos p
    WHERE p.created_at >= NOW() - INTERVAL '8 weeks'
    GROUP BY 1
),
faltantes_sem AS (
    SELECT
        DATE_TRUNC('week', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::DATE AS semana_inicio,
        COUNT(ip.id)                                       AS faltantes,
        COUNT(ip.id) FILTER (WHERE ip.es_faltante)        AS faltantes_count
    FROM items_pedido ip
    JOIN pedidos p ON p.id = ip.pedido_id
    WHERE p.created_at >= NOW() - INTERVAL '8 weeks'
    GROUP BY 1
)
SELECT
    s.semana_inicio,
    COALESCE(ps.pedidos, 0)    AS pedidos,
    COALESCE(ps.facturados, 0) AS facturados,
    COALESCE(fs.faltantes_count, 0) AS faltantes,
    COALESCE(fs.faltantes, 0)  AS items_total,
    CASE WHEN COALESCE(fs.faltantes, 0) > 0
         THEN ROUND((COALESCE(fs.faltantes_count, 0)::NUMERIC / fs.faltantes::NUMERIC) * 100, 1)
         ELSE 0 END            AS tasa_faltantes_pct
FROM semanas s
LEFT JOIN pedidos_sem   ps ON ps.semana_inicio = s.semana_inicio
LEFT JOIN faltantes_sem fs ON fs.semana_inicio = s.semana_inicio
ORDER BY s.semana_inicio ASC;


-- -----------------------------------------------------------------------------
-- 11. v_rendimiento_vendedores_detalle
--     Esta semana y mes actual: pedidos, faltantes y tasa de faltantes
--     por vendedor, comparando con la semana/mes anterior.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_rendimiento_vendedores_detalle AS
WITH
sem_act AS (
    SELECT p.vendedor,
           COUNT(*) AS pedidos,
           COUNT(*) FILTER (WHERE p.estado = 'facturado') AS facturados
    FROM pedidos p
    WHERE DATE_TRUNC('week', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('week', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND p.vendedor IS NOT NULL
    GROUP BY p.vendedor
),
sem_ant AS (
    SELECT p.vendedor,
           COUNT(*) AS pedidos,
           COUNT(*) FILTER (WHERE p.estado = 'facturado') AS facturados
    FROM pedidos p
    WHERE DATE_TRUNC('week', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('week', (NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '1 week')
      AND p.vendedor IS NOT NULL
    GROUP BY p.vendedor
),
mes_act AS (
    SELECT p.vendedor,
           COUNT(*) AS pedidos,
           COUNT(*) FILTER (WHERE p.estado = 'facturado') AS facturados
    FROM pedidos p
    WHERE DATE_TRUNC('month', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('month', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND p.vendedor IS NOT NULL
    GROUP BY p.vendedor
),
mes_ant AS (
    SELECT p.vendedor,
           COUNT(*) AS pedidos
    FROM pedidos p
    WHERE DATE_TRUNC('month', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('month', (NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires') - INTERVAL '1 month')
      AND p.vendedor IS NOT NULL
    GROUP BY p.vendedor
),
faltantes_sem AS (
    SELECT p.vendedor, COUNT(ip.id) AS faltantes
    FROM items_pedido ip
    JOIN pedidos p ON p.id = ip.pedido_id
    WHERE ip.es_faltante = TRUE
      AND DATE_TRUNC('week', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('week', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND p.vendedor IS NOT NULL
    GROUP BY p.vendedor
),
faltantes_mes AS (
    SELECT p.vendedor, COUNT(ip.id) AS faltantes
    FROM items_pedido ip
    JOIN pedidos p ON p.id = ip.pedido_id
    WHERE ip.es_faltante = TRUE
      AND DATE_TRUNC('month', p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')
        = DATE_TRUNC('month', NOW() AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND p.vendedor IS NOT NULL
    GROUP BY p.vendedor
)
SELECT
    COALESCE(sa.vendedor, ma.vendedor)        AS vendedor,
    COALESCE(sa.pedidos, 0)                   AS pedidos_semana_actual,
    COALESCE(sa.facturados, 0)                AS facturados_semana_actual,
    COALESCE(sant.pedidos, 0)                 AS pedidos_semana_anterior,
    COALESCE(ma.pedidos, 0)                   AS pedidos_mes_actual,
    COALESCE(ma.facturados, 0)                AS facturados_mes_actual,
    COALESCE(mant.pedidos, 0)                 AS pedidos_mes_anterior,
    COALESCE(fs.faltantes, 0)                 AS faltantes_semana,
    COALESCE(fm.faltantes, 0)                 AS faltantes_mes,
    CASE WHEN sant.pedidos > 0
         THEN ROUND(((COALESCE(sa.pedidos,0)::NUMERIC - sant.pedidos::NUMERIC) / sant.pedidos::NUMERIC) * 100, 1)
         ELSE NULL END                        AS var_pedidos_semana_pct,
    CASE WHEN mant.pedidos > 0
         THEN ROUND(((COALESCE(ma.pedidos,0)::NUMERIC - mant.pedidos::NUMERIC) / mant.pedidos::NUMERIC) * 100, 1)
         ELSE NULL END                        AS var_pedidos_mes_pct
FROM sem_act sa
FULL OUTER JOIN sem_ant  sant ON sant.vendedor  = sa.vendedor
FULL OUTER JOIN mes_act  ma   ON ma.vendedor    = COALESCE(sa.vendedor, sant.vendedor)
FULL OUTER JOIN mes_ant  mant ON mant.vendedor  = COALESCE(sa.vendedor, sant.vendedor, ma.vendedor)
LEFT  JOIN faltantes_sem fs   ON fs.vendedor    = COALESCE(sa.vendedor, sant.vendedor, ma.vendedor)
LEFT  JOIN faltantes_mes fm   ON fm.vendedor    = COALESCE(sa.vendedor, sant.vendedor, ma.vendedor)
ORDER BY pedidos_mes_actual DESC NULLS LAST;
