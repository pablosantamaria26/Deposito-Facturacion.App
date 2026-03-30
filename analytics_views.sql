-- =============================================================================
-- analytics_views.sql
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
