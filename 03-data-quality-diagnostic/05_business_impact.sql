-- =============================================================================
-- P02 | Data Governance Architecture
-- File: 05_business_impact.sql
-- Author: cblancogt
--
-- Translates governance failures into financial and legal exposure.
-- All monetary values from real schema columns:
--   facturacion.FACTURA.total          - invoice amount
--   operaciones.PEDIDO.valor_declarado - declared cargo value
--   operaciones.INCIDENTE.costo_estimado - estimated incident cost
--   ventas.CONTRATO_CLIENTE.tarifa_base - contracted rate
--
-- Exchange rate GTQ to USD configurable. All figures output in both currencies.
-- =============================================================================

USE TRANSTRACK;
GO

DECLARE @gtq_to_usd              DECIMAL(10,4) = 7.80;
DECLARE @legal_cost_per_incident DECIMAL(10,2) = 15000.00;  -- USD per unresolvable incident
DECLARE @sat_penalty_rate        DECIMAL(5,4)  = 0.15;      -- 15% SAT fine on unlinked invoices
DECLARE @corporate_tax_rate      DECIMAL(5,4)  = 0.25;      -- 25% ISR Guatemala

-- =============================================================================
-- IMPACT 1: Billing integrity risk - client duplicates between modules
-- =============================================================================

SELECT 'IMPACT 1 - Billing risk from cross-module client duplicates' AS impact_category;

WITH ventas_unique AS (
    SELECT
        CAST(SUBSTRING(nit, 5, 10) AS INT) AS nit_num,
        MIN(cliente_id)                     AS cliente_id
    FROM ventas.CLIENTE
    GROUP BY SUBSTRING(nit, 5, 10)
),
cross_module AS (
    SELECT
        v.nit_num,
        v.cliente_id,
        f.cliente_fact_id,
        f.limite_credito,
        f.dias_credito
    FROM ventas_unique v
    INNER JOIN facturacion.CLIENTE f
        ON v.nit_num = CAST(f.nit_cliente AS INT)
    WHERE f.limite_credito IS NOT NULL
)
SELECT
    COUNT(*)                                                            AS clients_with_duplicate_credit_records,
    SUM(limite_credito)                                                 AS total_credit_extended_gtq,
    CAST(SUM(limite_credito) / @gtq_to_usd AS DECIMAL(18,2))          AS total_credit_extended_usd,
    CAST(SUM(limite_credito) * 0.50 / @gtq_to_usd AS DECIMAL(18,2))  AS duplicate_credit_exposure_usd,
    AVG(limite_credito)                                                 AS avg_credit_limit_gtq
FROM cross_module;

SELECT
    'Intra-module ventas.CLIENTE duplicates'    AS metric,
    COUNT(*)                                    AS duplicate_nit_groups,
    SUM(excess)                                 AS excess_records
FROM (
    SELECT nit, COUNT(*) - 1 AS excess
    FROM ventas.CLIENTE
    GROUP BY nit
    HAVING COUNT(*) > 1
) x;

-- =============================================================================
-- IMPACT 2: Revenue leakage - delivered orders never invoiced
-- =============================================================================

SELECT 'IMPACT 2 - Revenue leakage (delivered, never invoiced)' AS impact_category;

SELECT
    COUNT(*)                                                                    AS deliveries_never_invoiced,
    SUM(p.valor_declarado)                                                      AS revenue_leakage_gtq,
    CAST(SUM(p.valor_declarado) / @gtq_to_usd AS DECIMAL(18,2))               AS revenue_leakage_usd,
    AVG(p.valor_declarado)                                                      AS avg_uninvoiced_cargo_gtq,
    CAST(
        SUM(p.valor_declarado)
        / NULLIF(DATEDIFF(YEAR, MIN(p.fecha_pedido), GETDATE()), 0)
        / @gtq_to_usd
    AS DECIMAL(18,2))                                                           AS annual_leakage_rate_usd,
    MIN(e.fecha_entrega_real)                                                   AS earliest_uninvoiced_delivery,
    COUNT(DISTINCT p.cliente_id)                                                AS clients_affected
FROM operaciones.PEDIDO p
INNER JOIN operaciones.ENTREGA e
    ON p.pedido_id = e.pedido_id
    AND e.estado_entrega = 'ENTREGADO'
LEFT JOIN facturacion.FACTURA f
    ON p.pedido_id = f.pedido_id
WHERE f.factura_id IS NULL;

-- =============================================================================
-- IMPACT 3: SAT audit exposure - invoices with no pedido_id
-- =============================================================================

SELECT 'IMPACT 3 - SAT audit exposure (orphan invoices, NULL pedido_id)' AS impact_category;

SELECT
    COUNT(*)                                                                    AS orphan_invoice_count,
    SUM(f.total)                                                                AS orphan_billing_gtq,
    CAST(SUM(f.total) / @gtq_to_usd AS DECIMAL(18,2))                         AS orphan_billing_usd,
    CAST(SUM(f.total) * @sat_penalty_rate / @gtq_to_usd AS DECIMAL(18,2))     AS sat_fine_exposure_usd,
    CAST(SUM(f.total) * @corporate_tax_rate / @gtq_to_usd AS DECIMAL(18,2))   AS tax_deduction_at_risk_usd,
    CAST(SUM(CASE WHEN f.estado_pago = 'PAGADA'    THEN f.total ELSE 0 END)
         / @gtq_to_usd AS DECIMAL(18,2))                                       AS already_collected_usd,
    CAST(SUM(CASE WHEN f.estado_pago = 'PENDIENTE' THEN f.total ELSE 0 END)
         / @gtq_to_usd AS DECIMAL(18,2))                                       AS pending_collection_usd
FROM facturacion.FACTURA f
WHERE f.pedido_id IS NULL;

-- =============================================================================
-- IMPACT 4: Legal liability - incidents without traceable driver
-- =============================================================================

SELECT 'IMPACT 4 - Legal liability (incidents, no traceable driver)' AS impact_category;

WITH incident_traceability AS (
    SELECT
        i.incidente_id,
        i.tipo_incidente,
        i.severidad,
        i.costo_estimado,
        CASE
            WHEN i.pedido_id IS NULL      THEN 'NO_PEDIDO'
            WHEN av.asignacion_id IS NULL THEN 'NO_ASSIGNMENT'
            WHEN c.conductor_id IS NULL   THEN 'NO_CONDUCTOR'
            ELSE 'DRIVER_IDENTIFIED'
        END AS traceability
    FROM operaciones.INCIDENTE i
    LEFT JOIN flota.ASIGNACION_VEHICULO av ON i.pedido_id = av.pedido_id
    LEFT JOIN flota.CONDUCTOR c            ON av.conductor_id = c.conductor_id
)
SELECT
    traceability,
    COUNT(*)                                                                    AS incident_count,
    SUM(costo_estimado)                                                         AS reported_cost_gtq,
    CAST(SUM(costo_estimado) / @gtq_to_usd AS DECIMAL(18,2))                  AS reported_cost_usd,
    CAST(
        SUM(CASE WHEN traceability <> 'DRIVER_IDENTIFIED' THEN 1 ELSE 0 END)
        * @legal_cost_per_incident
    AS DECIMAL(18,2))                                                           AS legal_exposure_usd,
    SUM(CASE WHEN severidad = 'CRITICA' THEN 1 ELSE 0 END)                    AS critical_incidents,
    SUM(CASE WHEN severidad = 'ALTA'    THEN 1 ELSE 0 END)                    AS high_incidents
FROM incident_traceability
GROUP BY traceability
ORDER BY incident_count DESC;

-- =============================================================================
-- IMPACT 5: Duplicate invoice financial exposure
-- =============================================================================

SELECT 'IMPACT 5 - Duplicate invoice exposure' AS impact_category;

SELECT
    COUNT(*)                                                                    AS pedidos_billed_twice,
    SUM(total_billed - min_invoice)                                             AS overbilled_amount_gtq,
    CAST(SUM(total_billed - min_invoice) / @gtq_to_usd AS DECIMAL(18,2))      AS overbilled_usd
FROM (
    SELECT
        pedido_id,
        COUNT(*)    AS invoice_count,
        SUM(total)  AS total_billed,
        MIN(total)  AS min_invoice
    FROM facturacion.FACTURA
    WHERE pedido_id IS NOT NULL
    GROUP BY pedido_id
    HAVING COUNT(*) > 1
) dup;

-- =============================================================================
-- CONSOLIDATED FINANCIAL IMPACT TABLE
-- =============================================================================

SELECT 'CONSOLIDATED FINANCIAL IMPACT - TRANSTRACK DATA GOVERNANCE FAILURES' AS report_title;
SELECT GETDATE() AS generated_at;

SELECT
    impact_category,
    financial_exposure_usd,
    risk_level,
    regulatory_reference
FROM (
    SELECT
        'Credit double-exposure (cross-module client duplicates)'       AS impact_category,
        CAST(
            (
                SELECT SUM(f.limite_credito) * 0.50 / @gtq_to_usd
                FROM ventas.CLIENTE v
                INNER JOIN facturacion.CLIENTE f
                    ON CAST(SUBSTRING(v.nit, 5, 10) AS INT) = CAST(f.nit_cliente AS INT)
                WHERE f.limite_credito IS NOT NULL
            )
        AS DECIMAL(18,2))                                               AS financial_exposure_usd,
        'HIGH'                                                          AS risk_level,
        'Internal credit policy violation'                              AS regulatory_reference

    UNION ALL

    SELECT
        'Revenue leakage (delivered, never invoiced)',
        CAST(SUM(p.valor_declarado) / @gtq_to_usd AS DECIMAL(18,2)),
        'CRITICAL',
        'NIIF 15 - Revenue recognition requirement'
    FROM operaciones.PEDIDO p
    INNER JOIN operaciones.ENTREGA e ON p.pedido_id = e.pedido_id AND e.estado_entrega = 'ENTREGADO'
    LEFT  JOIN facturacion.FACTURA f ON p.pedido_id = f.pedido_id
    WHERE f.factura_id IS NULL

    UNION ALL

    SELECT
        'SAT fine exposure (invoices with no commercial origin)',
        CAST(SUM(f.total) * @sat_penalty_rate / @gtq_to_usd AS DECIMAL(18,2)),
        'HIGH',
        'SAT Decreto 27-92 - IVA Law Guatemala'
    FROM facturacion.FACTURA f
    WHERE f.pedido_id IS NULL

    UNION ALL

    SELECT
        'Legal liability (incidents with no traceable driver)',
        CAST(
            (SELECT COUNT(*) FROM operaciones.INCIDENTE i
             WHERE NOT EXISTS (
                 SELECT 1 FROM flota.ASIGNACION_VEHICULO av
                 JOIN flota.CONDUCTOR c ON av.conductor_id = c.conductor_id
                 WHERE av.pedido_id = i.pedido_id
             )) * @legal_cost_per_incident
        AS DECIMAL(18,2)),
        'CRITICAL',
        'Ley de Transito Guatemala + Codigo de Comercio'

    UNION ALL

    SELECT
        'Overbilling exposure (duplicate invoices)',
        CAST(
            (SELECT ISNULL(SUM(total_billed - min_invoice), 0)
             FROM (
                 SELECT pedido_id, SUM(total) AS total_billed, MIN(total) AS min_invoice
                 FROM facturacion.FACTURA
                 WHERE pedido_id IS NOT NULL
                 GROUP BY pedido_id
                 HAVING COUNT(*) > 1
             ) d) / @gtq_to_usd
        AS DECIMAL(18,2)),
        'MEDIUM',
        'Client relations + audit findability'
) AS summary
ORDER BY financial_exposure_usd DESC;