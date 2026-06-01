-- =============================================================================
-- P02 | 03_orphan_records.sql
-- Detects broken links in the billing chain:
--   Type A: FACTURA with NULL pedido_id (no commercial origin)
--   Type B: PEDIDO with no ENTREGA (untracked delivery)
--   Type C: PEDIDO delivered but never invoiced (revenue leakage)
--   Type D: Same pedido invoiced twice (duplicate billing)
-- =============================================================================
USE TRANSTRACK;
GO

-- -----------------------------------------------------------------------------
-- SECTION 1: Type A — FACTURA with NULL pedido_id (no commercial origin)
-- The FK allows NULL, so these invoices bypass referential integrity entirely.
-- This is the SAT audit risk: an invoice with no traceable business transaction.
-- -----------------------------------------------------------------------------

SELECT 'SECTION 1 - Type A: Invoices with NULL pedido_id (no commercial origin)' AS diagnostic_section;

SELECT
    f.factura_id,
    f.numero_factura,
    f.cliente_fact_id,
    fc.nit_cliente,
    fc.razon_social,
    f.pedido_id,                    -- This is NULL — the problem
    f.fecha_emision,
    f.fecha_vencimiento,
    f.total,
    f.estado_pago,
    f.observaciones,
    DATEDIFF(DAY, f.fecha_emision, GETDATE()) AS days_since_issued,
    'NULL_PEDIDO_ID'                AS orphan_type
FROM facturacion.FACTURA f
LEFT JOIN facturacion.CLIENTE fc ON f.cliente_fact_id = fc.cliente_fact_id
WHERE f.pedido_id IS NULL
ORDER BY f.total DESC;

-- Financial summary for type A
SELECT
    COUNT(*)                        AS orphan_invoice_count,
    SUM(f.total)                    AS total_orphan_value,
    AVG(f.total)                    AS avg_orphan_value,
    MIN(f.fecha_emision)            AS earliest_orphan,
    MAX(f.fecha_emision)            AS latest_orphan,
    COUNT(DISTINCT f.cliente_fact_id) AS clients_with_orphan_invoices,
    SUM(CASE WHEN f.estado_pago = 'PAGADA'   THEN f.total ELSE 0 END) AS already_collected,
    SUM(CASE WHEN f.estado_pago = 'PENDIENTE' THEN f.total ELSE 0 END) AS pending_collection
FROM facturacion.FACTURA f
WHERE f.pedido_id IS NULL;

-- -----------------------------------------------------------------------------
-- SECTION 2: Type B — PEDIDO with no ENTREGA
-- Order was created and accepted, but no delivery record exists.
-- Could be abandoned orders, or deliveries entered in a different system.
-- -----------------------------------------------------------------------------

SELECT 'SECTION 2 - Type B: Orders with no delivery record' AS diagnostic_section;

SELECT
    p.pedido_id,
    p.numero_pedido,
    p.cliente_id,
    vc.nit                          AS client_nit,
    vc.nombre                       AS client_name,
    p.ruta_id,
    r.ciudad_origen,
    r.ciudad_destino,
    p.fecha_pedido,
    p.fecha_requerida,
    p.estado,
    p.peso_kg,
    p.tipo_carga,
    p.valor_declarado,
    -- SLA breach: required date passed with no delivery
    CASE
        WHEN p.fecha_requerida < CAST(GETDATE() AS DATE)
         AND p.estado NOT IN ('CANCELADO')
        THEN 'SLA_BREACHED'
        ELSE 'NO_SLA_BREACH_YET'
    END                             AS sla_status,
    DATEDIFF(DAY, p.fecha_requerida, GETDATE()) AS days_past_required
FROM operaciones.PEDIDO p
LEFT JOIN operaciones.ENTREGA e ON p.pedido_id = e.pedido_id
LEFT JOIN ventas.CLIENTE vc ON p.cliente_id = vc.cliente_id
LEFT JOIN operaciones.RUTA r ON p.ruta_id = r.ruta_id
WHERE e.entrega_id IS NULL                  -- No delivery record
  AND p.estado NOT IN ('CANCELADO')         -- Not cancelled
ORDER BY p.valor_declarado DESC, p.fecha_requerida ASC

SELECT
    COUNT(*)                        AS orders_without_delivery,
    SUM(p.valor_declarado)          AS declared_value_untracked,
    SUM(CASE WHEN p.fecha_requerida < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END) AS confirmed_sla_breaches
FROM operaciones.PEDIDO p
LEFT JOIN operaciones.ENTREGA e ON p.pedido_id = e.pedido_id
WHERE e.entrega_id IS NULL AND p.estado NOT IN ('CANCELADO');

-- -----------------------------------------------------------------------------
-- SECTION 3: Type C — PEDIDO delivered but never invoiced (revenue leakage)
-- Estado ENTREGADO exists in ENTREGA, but no FACTURA points to this pedido_id
-- -----------------------------------------------------------------------------

SELECT 'SECTION 3 - Type C: Delivered orders with no invoice (revenue leakage)' AS diagnostic_section;

SELECT
    p.pedido_id,
    p.numero_pedido,
    p.cliente_id,
    vc.nit,
    vc.nombre                       AS client_name,
    p.ruta_id,
    r.ciudad_origen + ' → ' + r.ciudad_destino AS route,
    e.fecha_entrega_real,
    e.estado_entrega,
    p.valor_declarado,
    p.peso_kg,
    p.tipo_carga,
    DATEDIFF(DAY, e.fecha_entrega_real, GETDATE()) AS days_delivered_no_invoice
FROM operaciones.PEDIDO p
INNER JOIN operaciones.ENTREGA e
    ON p.pedido_id = e.pedido_id
    AND e.estado_entrega = 'ENTREGADO'      -- Confirmed delivery
LEFT JOIN facturacion.FACTURA f
    ON p.pedido_id = f.pedido_id            -- No invoice for this order
LEFT JOIN ventas.CLIENTE vc ON p.cliente_id = vc.cliente_id
LEFT JOIN operaciones.RUTA r ON p.ruta_id = r.ruta_id
WHERE f.factura_id IS NULL                  -- No invoice found
ORDER BY p.valor_declarado DESC ;

SELECT
    COUNT(*)                        AS delivered_never_invoiced,
    SUM(p.valor_declarado)          AS revenue_leakage_total,
    AVG(p.valor_declarado)          AS avg_uninvoiced_delivery,
    COUNT(DISTINCT p.cliente_id)    AS clients_with_uninvoiced_deliveries
FROM operaciones.PEDIDO p
INNER JOIN operaciones.ENTREGA e ON p.pedido_id = e.pedido_id AND e.estado_entrega = 'ENTREGADO'
LEFT  JOIN facturacion.FACTURA f  ON p.pedido_id = f.pedido_id
WHERE f.factura_id IS NULL;

-- -----------------------------------------------------------------------------
-- SECTION 4: Duplicate invoices — same pedido billed twice
-- pedido_id has no UNIQUE constraint on FACTURA → this is possible
-- -----------------------------------------------------------------------------

SELECT 'SECTION 4 - Duplicate invoices (same pedido, two FACTURA records)' AS diagnostic_section;

SELECT
    f.pedido_id,
    COUNT(*)                        AS invoice_count,
    SUM(f.total)                    AS total_billed,
    MIN(f.total)                    AS min_invoice,
    MAX(f.total)                    AS max_invoice,
    MAX(f.total) - MIN(f.total)     AS amount_discrepancy,
    STRING_AGG(
        CAST(f.factura_id AS VARCHAR) + ':' + f.numero_factura + '($' + CAST(f.total AS VARCHAR) + ')',
        ' | '
    )                               AS invoice_details,
    MIN(f.fecha_emision)            AS first_issued,
    MAX(f.fecha_emision)            AS last_issued
FROM facturacion.FACTURA f
WHERE f.pedido_id IS NOT NULL
GROUP BY f.pedido_id
HAVING COUNT(*) > 1
ORDER BY total_billed DESC;

SELECT
    COUNT(*)                        AS pedidos_billed_twice,
    SUM(total_billed - min_invoice) AS overbilled_amount
FROM (
    SELECT
        pedido_id,
        SUM(total)  AS total_billed,
        MIN(total)  AS min_invoice
    FROM facturacion.FACTURA
    WHERE pedido_id IS NOT NULL
    GROUP BY pedido_id
    HAVING COUNT(*) > 1
) dup;

-- -----------------------------------------------------------------------------
-- SECTION 5: Consolidated orphan summary for CTO report
-- -----------------------------------------------------------------------------

SELECT 'SECTION 5 - Consolidated Orphan Summary' AS diagnostic_section;

SELECT orphan_type, record_count, financial_exposure
FROM (
    SELECT
        'Type A: Invoices with no order (NULL pedido_id)' AS orphan_type,
        COUNT(*)        AS record_count,
        SUM(f.total)    AS financial_exposure
    FROM facturacion.FACTURA f
    WHERE f.pedido_id IS NULL

    UNION ALL

    SELECT
        'Type B: Orders with no delivery record',
        COUNT(*),
        SUM(p.valor_declarado)
    FROM operaciones.PEDIDO p
    LEFT JOIN operaciones.ENTREGA e ON p.pedido_id = e.pedido_id
    WHERE e.entrega_id IS NULL AND p.estado NOT IN ('CANCELADO')

    UNION ALL

    SELECT
        'Type C: Delivered, never invoiced (revenue leakage)',
        COUNT(*),
        SUM(p.valor_declarado)
    FROM operaciones.PEDIDO p
    INNER JOIN operaciones.ENTREGA e ON p.pedido_id = e.pedido_id AND e.estado_entrega = 'ENTREGADO'
    LEFT  JOIN facturacion.FACTURA f ON p.pedido_id = f.pedido_id
    WHERE f.factura_id IS NULL

    UNION ALL

    SELECT
        'Type D: Duplicate invoices (same pedido billed twice)',
        SUM(invoice_count - 1),  -- excess invoices
        SUM(excess_billed)
    FROM (
        SELECT
            COUNT(*) AS invoice_count,
            SUM(total) - MIN(total) AS excess_billed
        FROM facturacion.FACTURA
        WHERE pedido_id IS NOT NULL
        GROUP BY pedido_id
        HAVING COUNT(*) > 1
    ) dup
) AS summary
ORDER BY financial_exposure DESC;

-- =============================================================================
