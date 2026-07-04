-- =============================================================================
-- FILE: 03_client_deduplication.sql
-- PROJECT: P02 - Data Governance Architecture | TRANSTRACK
-- SOURCE TABLES:
--   ventas.CLIENTE      15,000 rows, NIT format 'NIT-000001', intentional duplicates
--                       Same NIT appears up to 8 times (confirmed intentional problem)
--   facturacion.CLIENTE 12,000 rows, NIT format plain integer '1'
--                       No cross-module NIT standard was enforced
--
-- DEDUPLICATION STRATEGY:
--   Step 1: Within ventas — group by NIT sequence, pick one survivor per NIT
--           Survivorship: most recent fecha_registro + activo = 1 wins
--   Step 2: Enrich survivors with facturacion data via sequence number match
--   Step 3: facturacion records with no ventas match = billing-only masters (flagged)
-- =============================================================================

USE TRANSTRACK;
GO

-- =============================================================================
-- CLEANUP
-- =============================================================================

IF OBJECT_ID('governance_control.CLIENTE_CROSSWALK',   'U') IS NOT NULL DROP TABLE governance_control.CLIENTE_CROSSWALK;
IF OBJECT_ID('governance_control.MASTER_CLIENT_AUDIT', 'U') IS NOT NULL DROP TABLE governance_control.MASTER_CLIENT_AUDIT;
IF OBJECT_ID('governance_control.MASTER_CLIENTE',      'U') IS NOT NULL DROP TABLE governance_control.MASTER_CLIENTE;
GO

-- =============================================================================
-- STEP 1: DEDUPLICATE ventas.CLIENTE
-- Extract numeric sequence from 'NIT-000001' -> 1
-- Pick ONE record per NIT: active first, then most recent fecha_registro
-- =============================================================================

IF OBJECT_ID('tempdb..#ventas_dedup', 'U') IS NOT NULL DROP TABLE #ventas_dedup;

WITH ranked AS (
    SELECT
        cliente_id,
        nit,
        nombre,
        email,
        telefono,
        ciudad,
        categoria,
        fecha_registro,
        activo,
        -- Extract numeric part of NIT: 'NIT-000001' -> 1
        CAST(RIGHT(nit, LEN(nit) - CHARINDEX('-', nit)) AS INT) AS nit_seq,
        -- Rank duplicates: active first, then most recent
        ROW_NUMBER() OVER (
            PARTITION BY RIGHT(nit, LEN(nit) - CHARINDEX('-', nit))
            ORDER BY activo DESC, fecha_registro DESC
        ) AS rn
    FROM ventas.CLIENTE
    WHERE CHARINDEX('-', nit) > 0   -- skip malformed NITs
)
SELECT
    cliente_id,
    nit,
    nombre,
    email,
    telefono,
    ciudad,
    categoria,
    fecha_registro,
    activo,
    nit_seq
INTO #ventas_dedup
FROM ranked
WHERE rn = 1;   -- one survivor per NIT

-- How many duplicates were eliminated?
SELECT
    (SELECT COUNT(*) FROM ventas.CLIENTE)    AS ventas_source_rows,
    (SELECT COUNT(*) FROM #ventas_dedup)     AS unique_nits,
    (SELECT COUNT(*) FROM ventas.CLIENTE) -
    (SELECT COUNT(*) FROM #ventas_dedup)     AS duplicates_eliminated;

-- =============================================================================
-- STEP 2: BRIDGE to facturacion via sequence number
-- ventas:      nit_seq = 1  (from 'NIT-000001')
-- facturacion: TRY_CAST(nit_cliente AS INT) = 1
-- =============================================================================

IF OBJECT_ID('tempdb..#enrichment', 'U') IS NOT NULL DROP TABLE #enrichment;

SELECT
    TRY_CAST(fc.nit_cliente AS INT) AS nit_seq,
    MAX(fc.limite_credito)          AS limite_credito,
    MAX(fc.dias_credito)            AS dias_credito,
    MIN(fc.nit_cliente)             AS nit_facturacion
INTO #enrichment
FROM facturacion.CLIENTE fc
WHERE TRY_CAST(fc.nit_cliente AS INT) IS NOT NULL
GROUP BY TRY_CAST(fc.nit_cliente AS INT);

-- Match preview
SELECT
    (SELECT COUNT(*) FROM #ventas_dedup)                                AS ventas_unique,
    (SELECT COUNT(*) FROM #enrichment)                                  AS facturacion_unique,
    (SELECT COUNT(*) FROM #ventas_dedup v
     JOIN #enrichment e ON e.nit_seq = v.nit_seq)                      AS matched,
    (SELECT COUNT(*) FROM #ventas_dedup v
     LEFT JOIN #enrichment e ON e.nit_seq = v.nit_seq
     WHERE e.nit_seq IS NULL)                                           AS ventas_only,
    (SELECT COUNT(*) FROM #enrichment e
     LEFT JOIN #ventas_dedup v ON v.nit_seq = e.nit_seq
     WHERE v.nit_seq IS NULL)                                           AS facturacion_only_flagged;
GO

-- =============================================================================
-- STEP 3: MASTER CLIENT TABLE
-- =============================================================================

CREATE TABLE governance_control.MASTER_CLIENTE (
    master_cliente_id       INT IDENTITY(1,1)   NOT NULL,
    client_hash_key         CHAR(32)            NOT NULL,
    -- Normalized business key (numeric sequence, bridges both NIT formats)
    nit_seq                 INT                 NOT NULL,
    nit_ventas              NVARCHAR(20)        NULL,   -- 'NIT-000001' format
    nit_facturacion         NVARCHAR(20)        NULL,   -- '1' format
    -- Golden record: ventas wins
    nombre                  NVARCHAR(200)       NOT NULL,
    email                   NVARCHAR(100)       NULL,
    telefono                NVARCHAR(20)        NULL,
    ciudad                  NVARCHAR(80)        NULL,
    categoria               NVARCHAR(30)        NULL,
    -- Enrichment from facturacion
    limite_credito          DECIMAL(12,2)       NULL,
    dias_credito            INT                 NULL,
    -- Provenance
    fuente_principal        NVARCHAR(20)        NOT NULL,
    fecha_primer_registro   DATE                NOT NULL,
    estado_activo           BIT                 NOT NULL DEFAULT 1,
    -- Quality flags
    necesita_revision       BIT                 NOT NULL DEFAULT 0,
    razon_revision          NVARCHAR(300)       NULL,
    record_version          INT                 NOT NULL DEFAULT 1,
    created_at              DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    created_by              NVARCHAR(100)       NOT NULL DEFAULT SYSTEM_USER,
    CONSTRAINT PK_MASTER_CLIENTE PRIMARY KEY CLUSTERED (master_cliente_id),
    CONSTRAINT UQ_MASTER_CLIENTE_HASH    UNIQUE (client_hash_key),
    CONSTRAINT UQ_MASTER_CLIENTE_NIT_SEQ UNIQUE (nit_seq)
);
GO

-- =============================================================================
-- STEP 4: AUDIT TABLE
-- =============================================================================

CREATE TABLE governance_control.MASTER_CLIENT_AUDIT (
    audit_id            INT IDENTITY(1,1)   NOT NULL,
    master_cliente_id   INT                 NOT NULL,
    source_pk           INT                 NOT NULL,
    source_modulo       NVARCHAR(20)        NOT NULL,
    decision            NVARCHAR(20)        NOT NULL
                        CONSTRAINT chk_audit_decision
                        CHECK (decision IN ('SURVIVOR','MERGED','FLAGGED','REJECTED')),
    match_type          NVARCHAR(30)        NULL,
    confidence_pct      DECIMAL(5,2)        NULL,
    source_nit          NVARCHAR(20)        NULL,
    source_nombre       NVARCHAR(200)       NULL,
    master_nit_seq      INT                 NULL,
    master_nombre       NVARCHAR(200)       NULL,
    decided_by          NVARCHAR(100)       NOT NULL DEFAULT SYSTEM_USER,
    decision_method     NVARCHAR(20)        NOT NULL DEFAULT 'AUTOMATED',
    notes               NVARCHAR(500)       NULL,
    decided_at          DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_MASTER_CLIENT_AUDIT PRIMARY KEY CLUSTERED (audit_id)
);
GO

-- =============================================================================
-- STEP 5: INSERT GOLDEN RECORDS
-- PASS 1: ventas survivors enriched with facturacion data
-- =============================================================================

INSERT INTO governance_control.MASTER_CLIENTE
    (client_hash_key, nit_seq, nit_ventas, nit_facturacion,
     nombre, email, telefono, ciudad, categoria,
     limite_credito, dias_credito,
     fuente_principal, fecha_primer_registro, estado_activo,
     necesita_revision, razon_revision)
SELECT
    CONVERT(CHAR(32), HASHBYTES('MD5', 'SEQ_' + CAST(v.nit_seq AS VARCHAR)), 2),
    v.nit_seq,
    v.nit,
    e.nit_facturacion,
    v.nombre,
    v.email,
    v.telefono,
    v.ciudad,
    v.categoria,
    e.limite_credito,
    e.dias_credito,
    'VENTAS',
    CAST(v.fecha_registro AS DATE),
    v.activo,
    0,
    NULL
FROM #ventas_dedup v
LEFT JOIN #enrichment e ON e.nit_seq = v.nit_seq;
GO

-- PASS 2: facturacion records with no ventas match = billing-only (flagged)
INSERT INTO governance_control.MASTER_CLIENTE
    (client_hash_key, nit_seq, nit_facturacion,
     nombre, email, telefono,
     limite_credito, dias_credito,
     fuente_principal, fecha_primer_registro, estado_activo,
     necesita_revision, razon_revision)
SELECT
    CONVERT(CHAR(32), HASHBYTES('MD5', 'FACT_SEQ_' + CAST(e.nit_seq AS VARCHAR)), 2),
    e.nit_seq,
    e.nit_facturacion,
    fc.razon_social,
    fc.correo,
    fc.telefono_contacto,
    fc.limite_credito,
    fc.dias_credito,
    'FACTURACION',
    CAST(fc.fecha_alta AS DATE),
    1,
    1,
    'Billing-only client. NIT formats incompatible between modules '
    + '(ventas: NIT-XXXXXX, facturacion: plain integer). '
    + 'No cross-module NIT standard was enforced at build time. '
    + 'Data Steward must confirm whether a ventas.CLIENTE record should exist.'
FROM #enrichment e
JOIN facturacion.CLIENTE fc
    ON TRY_CAST(fc.nit_cliente AS INT) = e.nit_seq
LEFT JOIN #ventas_dedup v ON v.nit_seq = e.nit_seq
WHERE v.nit_seq IS NULL
-- One row per nit_seq (facturacion may also have duplicates)
AND fc.cliente_fact_id = (
    SELECT MIN(fc2.cliente_fact_id)
    FROM facturacion.CLIENTE fc2
    WHERE TRY_CAST(fc2.nit_cliente AS INT) = e.nit_seq
);
GO

-- =============================================================================
-- STEP 6: CROSSWALK
-- =============================================================================

CREATE TABLE governance_control.CLIENTE_CROSSWALK (
    crosswalk_id        INT IDENTITY(1,1)   NOT NULL,
    master_cliente_id   INT                 NOT NULL,
    source_pk           INT                 NOT NULL,
    source_modulo       NVARCHAR(20)        NOT NULL,
    is_survivor         BIT                 NOT NULL DEFAULT 0,
    match_type          NVARCHAR(30)        NOT NULL,
    match_confidence    DECIMAL(5,2)        NOT NULL,
    created_at          DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_CLIENTE_CROSSWALK PRIMARY KEY CLUSTERED (crosswalk_id),
    CONSTRAINT FK_CLIENTE_CROSSWALK_MASTER FOREIGN KEY (master_cliente_id)
        REFERENCES governance_control.MASTER_CLIENTE (master_cliente_id)
);
GO

-- All ventas.CLIENTE records -> crosswalk (survivors and merged duplicates)
INSERT INTO governance_control.CLIENTE_CROSSWALK
    (master_cliente_id, source_pk, source_modulo, is_survivor, match_type, match_confidence)
SELECT
    mc.master_cliente_id,
    vc.cliente_id,
    'VENTAS',
    CASE WHEN vc.cliente_id = mc_survivor.cliente_id THEN 1 ELSE 0 END,
    CASE WHEN vc.cliente_id = mc_survivor.cliente_id THEN 'SURVIVOR' ELSE 'DUPLICATE_MERGED' END,
    CASE WHEN vc.cliente_id = mc_survivor.cliente_id THEN 100.00 ELSE 85.00 END
FROM ventas.CLIENTE vc
JOIN governance_control.MASTER_CLIENTE mc
    ON mc.nit_seq = CAST(RIGHT(vc.nit, LEN(vc.nit) - CHARINDEX('-', vc.nit)) AS INT)
JOIN (SELECT cliente_id, nit_seq FROM #ventas_dedup) mc_survivor
    ON mc_survivor.nit_seq = mc.nit_seq
WHERE CHARINDEX('-', vc.nit) > 0;
GO

-- facturacion.CLIENTE records -> crosswalk
INSERT INTO governance_control.CLIENTE_CROSSWALK
    (master_cliente_id, source_pk, source_modulo, is_survivor, match_type, match_confidence)
SELECT
    mc.master_cliente_id,
    fc.cliente_fact_id,
    'FACTURACION',
    CASE WHEN mc.fuente_principal = 'FACTURACION' THEN 1 ELSE 0 END,
    CASE WHEN mc.fuente_principal = 'FACTURACION' THEN 'BILLING_ONLY_MASTER'
         ELSE 'SEQ_ENRICHMENT' END,
    CASE WHEN mc.fuente_principal = 'FACTURACION' THEN 50.00 ELSE 90.00 END
FROM facturacion.CLIENTE fc
JOIN governance_control.MASTER_CLIENTE mc
    ON mc.nit_seq = TRY_CAST(fc.nit_cliente AS INT)
WHERE TRY_CAST(fc.nit_cliente AS INT) IS NOT NULL;
GO

-- Audit table
INSERT INTO governance_control.MASTER_CLIENT_AUDIT
    (master_cliente_id, source_pk, source_modulo, decision,
     match_type, confidence_pct,
     source_nit, source_nombre, master_nit_seq, master_nombre,
     decision_method, notes)
SELECT
    cx.master_cliente_id,
    cx.source_pk,
    cx.source_modulo,
    CASE
        WHEN cx.match_type = 'SURVIVOR'          THEN 'SURVIVOR'
        WHEN cx.match_type = 'DUPLICATE_MERGED'  THEN 'MERGED'
        WHEN cx.match_type = 'SEQ_ENRICHMENT'    THEN 'MERGED'
        ELSE 'FLAGGED'
    END,
    cx.match_type,
    cx.match_confidence,
    CASE WHEN cx.source_modulo = 'VENTAS'
         THEN (SELECT nit FROM ventas.CLIENTE WHERE cliente_id = cx.source_pk)
         ELSE (SELECT nit_cliente FROM facturacion.CLIENTE WHERE cliente_fact_id = cx.source_pk)
    END,
    CASE WHEN cx.source_modulo = 'VENTAS'
         THEN (SELECT nombre FROM ventas.CLIENTE WHERE cliente_id = cx.source_pk)
         ELSE (SELECT razon_social FROM facturacion.CLIENTE WHERE cliente_fact_id = cx.source_pk)
    END,
    mc.nit_seq,
    mc.nombre,
    CASE WHEN mc.necesita_revision = 1 THEN 'MANUAL' ELSE 'AUTOMATED' END,
    CASE WHEN mc.fuente_principal = 'FACTURACION'
         THEN 'NIT format mismatch: ventas uses NIT-XXXXXX, facturacion uses plain integer.'
         WHEN cx.match_type = 'DUPLICATE_MERGED'
         THEN 'Duplicate within ventas.CLIENTE. Same NIT, multiple records. Intentional governance problem.'
         ELSE NULL END
FROM governance_control.CLIENTE_CROSSWALK cx
JOIN governance_control.MASTER_CLIENTE mc ON mc.master_cliente_id = cx.master_cliente_id;
GO

-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT
    'ventas.CLIENTE source'             AS metric, CAST(COUNT(*) AS NVARCHAR(20)) AS value FROM ventas.CLIENTE
UNION ALL
SELECT 'facturacion.CLIENTE source',    CAST(COUNT(*) AS NVARCHAR(20)) FROM facturacion.CLIENTE
UNION ALL
SELECT 'MASTER_CLIENTE golden records', CAST(COUNT(*) AS NVARCHAR(20)) FROM governance_control.MASTER_CLIENTE
UNION ALL
SELECT 'ventas survivors',              CAST(COUNT(*) AS NVARCHAR(20)) FROM governance_control.MASTER_CLIENTE WHERE fuente_principal = 'VENTAS'
UNION ALL
SELECT 'facturacion-only (flagged)',    CAST(COUNT(*) AS NVARCHAR(20)) FROM governance_control.MASTER_CLIENTE WHERE fuente_principal = 'FACTURACION'
UNION ALL
SELECT 'Enriched with credit data',    CAST(COUNT(*) AS NVARCHAR(20)) FROM governance_control.MASTER_CLIENTE WHERE limite_credito IS NOT NULL
UNION ALL
SELECT 'Records needing review',       CAST(COUNT(*) AS NVARCHAR(20)) FROM governance_control.MASTER_CLIENTE WHERE necesita_revision = 1
UNION ALL
SELECT 'Crosswalk entries',            CAST(COUNT(*) AS NVARCHAR(20)) FROM governance_control.CLIENTE_CROSSWALK
UNION ALL
SELECT 'Audit entries',                CAST(COUNT(*) AS NVARCHAR(20)) FROM governance_control.MASTER_CLIENT_AUDIT
UNION ALL
SELECT 'Duplicates eliminated (ventas)',(SELECT CAST(COUNT(*) - COUNT(DISTINCT RIGHT(nit, LEN(nit)-CHARINDEX('-',nit))) AS NVARCHAR(20)) FROM ventas.CLIENTE WHERE CHARINDEX('-',nit)>0);
GO

-- Sample golden records
SELECT TOP 10
    mc.nit_seq,
    mc.nit_ventas,
    mc.nit_facturacion,
    mc.nombre,
    mc.ciudad,
    mc.categoria,
    mc.limite_credito,
    mc.fuente_principal,
    mc.necesita_revision
FROM governance_control.MASTER_CLIENTE mc
ORDER BY mc.nit_seq;
GO
