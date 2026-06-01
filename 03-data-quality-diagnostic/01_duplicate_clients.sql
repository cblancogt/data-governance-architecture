-- =============================================================================
-- P02 | 01_duplicate_clients.sql
-- Two separate client tables, no shared key, no synchronization:
--   - ventas.CLIENTE: Sales module (nit, nombre)
--   - facturacion.CLIENTE: Billing module (nit_cliente, razon_social)
-- Detects intra-module NIT duplicates, cross-module conflicts, and name variations.
-- =============================================================================

USE TRANSTRACK;
GO

-- -----------------------------------------------------------------------------
-- SECTION 1: Intra-module duplicates inside ventas.CLIENTE
-- Same NIT registered more than once within Sales module
-- -----------------------------------------------------------------------------

SELECT 'SECTION 1 - Intra-module NIT duplicates (ventas.CLIENTE)' AS diagnostic_section;

SELECT
    nit,
    COUNT(*)                    AS total_records,
    MIN(nombre)                 AS name_variant_a,
    MAX(nombre)                 AS name_variant_b,
    MIN(fecha_registro)         AS first_registered,
    MAX(fecha_registro)         AS last_registered,
    -- If names differ, the same legal entity was typed differently
    CASE
        WHEN MIN(nombre) <> MAX(nombre) THEN 'NAME_CONFLICT'
        WHEN MIN(email)  <> MAX(email)  THEN 'EMAIL_CONFLICT'
        ELSE 'DATA_CONSISTENT'
    END                         AS conflict_type
FROM ventas.CLIENTE
GROUP BY nit
HAVING COUNT(*) > 1
ORDER BY total_records DESC;


-- -----------------------------------------------------------------------------
-- SECTION 2: Cross-module duplicates — same NIT in ventas AND facturacion
-- This is the main governance failure: two modules, same client, no link
-- Column mapping: ventas.nit = facturacion.nit_cliente
--                 ventas.nombre <-> facturacion.razon_social
-- -----------------------------------------------------------------------------

SELECT 'SECTION 2 - Cross-module duplicates (ventas vs facturacion)' AS diagnostic_section;

WITH ventas_unique AS (
    SELECT DISTINCT
        CAST(SUBSTRING(nit, 5, 10) AS INT) AS nit_num,
        MIN(nombre) AS nombre,
        MIN(email)  AS email
    FROM ventas.CLIENTE
    GROUP BY SUBSTRING(nit, 5, 10)
),
facturacion_unique AS (
    SELECT DISTINCT
        CAST(nit_cliente AS INT)  AS nit_num,
        MIN(razon_social)         AS razon_social,
        MIN(correo)               AS correo,
        MAX(limite_credito)       AS limite_credito
    FROM facturacion.CLIENTE
    GROUP BY nit_cliente
)
SELECT
    v.nit_num,
    v.nombre                AS name_in_sales,
    f.razon_social          AS name_in_billing,
    v.email                 AS email_sales,
    f.correo                AS email_billing,
    f.limite_credito,
    CASE
        WHEN v.nombre <> f.razon_social THEN 'NAME_MISMATCH'
        WHEN v.email  <> f.correo       THEN 'EMAIL_MISMATCH'
        ELSE 'DATA_CONSISTENT'
    END                     AS conflict_flag
FROM ventas_unique v
INNER JOIN facturacion_unique f ON v.nit_num = f.nit_num
WHERE v.nombre <> f.razon_social
ORDER BY conflict_flag;

-- How many clients exist in both modules?
SELECT
    (SELECT COUNT(DISTINCT nit) FROM ventas.CLIENTE)                   AS unique_nits_in_sales,
    (SELECT COUNT(DISTINCT nit_cliente) FROM facturacion.CLIENTE)      AS unique_nits_in_billing,
    (
        SELECT COUNT(*)
        FROM ventas.CLIENTE v
        INNER JOIN facturacion.CLIENTE f
            ON CAST(SUBSTRING(v.nit, 5, 10) AS INT) = CAST(f.nit_cliente AS INT)
    )                                                                   AS records_in_both_modules,
    (
        SELECT COUNT(*)
        FROM facturacion.CLIENTE f
        WHERE NOT EXISTS (
            SELECT 1 FROM ventas.CLIENTE v
            WHERE CAST(SUBSTRING(v.nit, 5, 10) AS INT) = CAST(f.nit_cliente AS INT)
        )
    )                                                                   AS billing_only_no_sales_record;
-- -----------------------------------------------------------------------------
-- SECTION 3: SOUNDEX near-duplicate detection within ventas.CLIENTE
-- Catches "TRANSPORTES EL SOL" vs "TRANSPORTE EL SOL S.A." — same company
-- -----------------------------------------------------------------------------

SELECT 'SECTION 3 - SOUNDEX near-duplicates (ventas.CLIENTE)' AS diagnostic_section;

WITH client_sdx AS (
    SELECT
        cliente_id,
        nit,
        nombre,
        categoria,
        activo,
        SOUNDEX(nombre) AS sdx
    FROM ventas.CLIENTE
)
SELECT TOP 50
    a.cliente_id                AS id_a,
    b.cliente_id                AS id_b,
    a.nit                       AS nit_a,
    b.nit                       AS nit_b,
    a.nombre                    AS name_a,
    b.nombre                    AS name_b,
    DIFFERENCE(a.nombre, b.nombre) AS similarity_score,  -- 4 = best match
    CASE
        WHEN a.nit = b.nit AND a.nombre = b.nombre  THEN 'EXACT_DUPLICATE'
        WHEN a.nit = b.nit AND a.nombre <> b.nombre THEN 'SAME_NIT_DIFF_NAME'
        WHEN a.nit <> b.nit AND DIFFERENCE(a.nombre, b.nombre) = 4
                                                    THEN 'SAME_NAME_DIFF_NIT'
        ELSE 'FUZZY_MATCH'
    END                         AS duplicate_classification
FROM client_sdx a
JOIN client_sdx b
    ON  a.sdx = b.sdx
    AND a.cliente_id < b.cliente_id
    AND DIFFERENCE(a.nombre, b.nombre) >= 3
ORDER BY similarity_score DESC, duplicate_classification;

-- Same analysis cross-module: ventas.nombre vs facturacion.razon_social
SELECT 'SECTION 3b - Cross-module SOUNDEX (ventas.nombre vs facturacion.razon_social)' AS diagnostic_section;

SELECT TOP 30
    v.cliente_id,
    f.cliente_fact_id,
    v.nit,
    f.nit_cliente,
    v.nombre,
    f.razon_social,
    DIFFERENCE(v.nombre, f.razon_social) AS name_similarity
FROM ventas.CLIENTE v
CROSS JOIN facturacion.CLIENTE f
WHERE DIFFERENCE(v.nombre, f.razon_social) = 4        -- Solo match perfecto
  AND CAST(SUBSTRING(v.nit, 5, 20) AS INT)            -- Mismo cliente por NIT
    = CAST(f.nit_cliente AS INT)
  AND v.nombre <> f.razon_social                      -- Pero nombre diferente
ORDER BY name_similarity DESC;

-- -----------------------------------------------------------------------------
-- SECTION 4: Executive summary
-- -----------------------------------------------------------------------------

SELECT 'SECTION 4 - Executive Summary' AS diagnostic_section;

SELECT
    (SELECT COUNT(*) FROM ventas.CLIENTE)                               AS total_ventas_records,
    (SELECT COUNT(*) FROM facturacion.CLIENTE)                          AS total_facturacion_records,
    (SELECT COUNT(*) FROM ventas.CLIENTE) +
    (SELECT COUNT(*) FROM facturacion.CLIENTE)                          AS total_client_records_system,
    (
        SELECT COUNT(*) FROM (
            SELECT CAST(SUBSTRING(nit, 5, 10) AS INT) AS nit_num FROM ventas.CLIENTE
            UNION
            SELECT CAST(nit_cliente AS INT) FROM facturacion.CLIENTE
        ) x
    )                                                                   AS estimated_truly_unique_clients,
    (SELECT COUNT(*) FROM ventas.CLIENTE) +
    (SELECT COUNT(*) FROM facturacion.CLIENTE) -
    (
        SELECT COUNT(*) FROM (
            SELECT CAST(SUBSTRING(nit, 5, 10) AS INT) AS nit_num FROM ventas.CLIENTE
            UNION
            SELECT CAST(nit_cliente AS INT) FROM facturacion.CLIENTE
        ) x
    )                                                                   AS excess_duplicate_records;
