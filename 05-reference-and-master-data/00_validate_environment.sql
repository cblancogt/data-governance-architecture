-- =============================================================================
-- FILE: 00_validate_environment.sql
-- TRANSTRACK P02 — Object Existence Validation
-- Run in SSMS or: sqlcmd -S localhost -d TRANSTRACK -E -i
-- =============================================================================

USE TRANSTRACK;
GO

PRINT '============================================================';
PRINT 'ENVIRONMENT VALIDATION — ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '============================================================';

-- ============================================================
-- 1. SCHEMAS — all must exist
-- ============================================================
PRINT '';
PRINT '--- 1. SCHEMAS ---';

SELECT
    name AS schema_name,
    CASE WHEN name IN ('governance_control','ref','ventas','facturacion',
                       'operaciones','flota','archivo')
         THEN 'OK' ELSE 'UNEXPECTED' END AS status
FROM sys.schemas
WHERE name IN ('governance_control','ref','ventas','facturacion',
               'operaciones','flota','archivo')
ORDER BY name;

-- ============================================================
-- 2. SOURCE TABLES
-- ============================================================
PRINT '';
PRINT '--- 2.SOURCE TABLES (prerequisites) ---';

SELECT
    n.fullname,
    CASE WHEN t.object_id IS NOT NULL THEN 'EXISTS' ELSE '*** MISSING - Run base scripts first ***' END AS status,
    ISNULL(p.rows, 0) AS row_count
FROM (VALUES
    ('ventas',        'CLIENTE'),
    ('ventas',        'CONTRATO_CLIENTE'),
    ('facturacion',   'CLIENTE'),
    ('facturacion',   'FACTURA'),
    ('facturacion',   'DETALLE_FACTURA'),
    ('operaciones',   'RUTA'),
    ('operaciones',   'PEDIDO'),
    ('operaciones',   'ENTREGA'),
    ('operaciones',   'INCIDENTE'),
    ('flota',         'VEHICULO'),
    ('flota',         'CONDUCTOR'),
    ('flota',         'EMPLEADO'),
    ('flota',         'OPERADOR'),
    ('flota',         'ASIGNACION_VEHICULO'),
    ('flota',         'TELEMETRIA_GPS')
) AS expected(sname, tname)
CROSS APPLY (SELECT expected.sname + '.' + expected.tname AS fullname) AS n
LEFT JOIN sys.tables t
    ON t.name = expected.tname
   AND SCHEMA_NAME(t.schema_id) = expected.sname
LEFT JOIN sys.partitions p
    ON p.object_id = t.object_id
   AND p.index_id IN (0,1)
ORDER BY expected.sname, expected.tname;

-- ============================================================
-- 3. GOVERNANCE TABLES
-- ============================================================
PRINT '';
PRINT '--- 3. GOVERNANCE_CONTROL TABLES (prerequisites) ---';

SELECT
    'governance_control.' + expected.tname AS fullname,
    CASE WHEN t.object_id IS NOT NULL THEN 'EXISTS' ELSE '*** MISSING — Run  04 first ***' END AS status,
    ISNULL(p.rows, 0) AS row_count
FROM (VALUES
    ('DATA_DOMAIN'),
    ('DATA_OWNER'),
    ('DATA_POLICY'),
    ('DATA_STEWARD'),
    ('DATA_CLASSIFICATION'),
    ('DOMAIN_TABLE_REGISTRY'),
    ('DATA_CATALOG'),
    ('COLUMN_CATALOG')
) AS expected(tname)
LEFT JOIN sys.tables t
    ON t.name = expected.tname
   AND SCHEMA_NAME(t.schema_id) = 'governance_control'
LEFT JOIN sys.partitions p
    ON p.object_id = t.object_id
   AND p.index_id IN (0,1)
ORDER BY expected.tname;

-- ============================================================
-- 4. NEW TABLES — what this  creates
-- ============================================================
PRINT '';
PRINT '--- 4.  05 NEW TABLES ---';

SELECT
    expected.sname + '.' + expected.tname AS fullname,
    CASE WHEN t.object_id IS NOT NULL THEN 'EXISTS' ELSE 'MISSING — Run script' END AS status,
    ISNULL(p.rows, 0) AS row_count,
    expected.script AS created_by_script
FROM (VALUES
    ('governance_control', 'REF_DATA_REGISTRY',      '01_reference_data_registry.sql'),
    ('governance_control', 'REF_DATA_VERSION_LOG',   '01_reference_data_registry.sql'),
    ('ref',                'TIPO_INCIDENTE',          '01_reference_data_registry.sql'),
    ('ref',                'ESTADO_PEDIDO',           '01_reference_data_registry.sql'),
    ('ref',                'CATEGORIA_CLIENTE',       '01_reference_data_registry.sql'),
    ('ref',                'TIPO_VEHICULO',           '01_reference_data_registry.sql'),
    ('ref',                'ESTADO_ENTREGA',          '01_reference_data_registry.sql'),
    ('governance_control', 'MASTER_CONDUCTOR',        '02_driver_consolidation.sql'),
    ('governance_control', 'CONDUCTOR_CROSSWALK',     '02_driver_consolidation.sql'),
    ('governance_control', 'MASTER_CLIENTE',          '03_client_deduplication.sql'),
    ('governance_control', 'MASTER_CLIENT_AUDIT',     '03_client_deduplication.sql'),
    ('governance_control', 'CLIENTE_CROSSWALK',       '03_client_deduplication.sql'),
    ('governance_control', 'DATA_LINEAGE',            '04_data_lineage.sql'),
    ('governance_control', 'DATA_LINEAGE_EXECUTION',  '04_data_lineage.sql'),
    ('governance_control', 'DATA_SHARING_AGREEMENT',  '05_sharing_agreements.sql'),
    ('governance_control', 'DSA_VIOLATION_LOG',       '05_sharing_agreements.sql')
) AS expected(sname, tname, script)
LEFT JOIN sys.tables t
    ON t.name = expected.tname
   AND SCHEMA_NAME(t.schema_id) = expected.sname
LEFT JOIN sys.partitions p
    ON p.object_id = t.object_id
   AND p.index_id IN (0,1)
ORDER BY expected.script, expected.sname, expected.tname;

-- ============================================================
-- 5. VIEWS AND PROCEDURES
-- ============================================================
PRINT '';
PRINT '--- 5. VIEWS ---';

SELECT
    'governance_control.' + expected.vname AS fullname,
    CASE WHEN v.object_id IS NOT NULL THEN 'EXISTS' ELSE 'MISSING' END AS status
FROM (VALUES
    ('vw_ref_data_health'),
    ('vw_lineage_impact_map'),
    ('vw_dsa_compliance_summary')
) AS expected(vname)
LEFT JOIN sys.views v
    ON v.name = expected.vname
   AND SCHEMA_NAME(v.schema_id) = 'governance_control'
ORDER BY expected.vname;

PRINT '';
PRINT '--- STORED PROCEDURES ---';

SELECT
    'governance_control.' + expected.pname AS fullname,
    CASE WHEN p.object_id IS NOT NULL THEN 'EXISTS' ELSE 'MISSING' END AS status
FROM (VALUES
    ('usp_get_downstream_impact')
) AS expected(pname)
LEFT JOIN sys.procedures p
    ON p.name = expected.pname
   AND SCHEMA_NAME(p.schema_id) = 'governance_control'
ORDER BY expected.pname;

-- ============================================================
-- 6. REFERENCE DATA ROW COUNTS (must have rows)
-- ============================================================
PRINT '';
PRINT '--- 6. REFERENCE DATA CONTENT ---';

IF OBJECT_ID('ref.TIPO_INCIDENTE','U') IS NOT NULL
BEGIN
    SELECT 'ref.TIPO_INCIDENTE' AS [table], COUNT(*) AS rows,
           CASE WHEN COUNT(*) = 6 THEN 'OK (6 rows expected)'
                WHEN COUNT(*) > 0 THEN 'HAS DATA (verify count)'
                ELSE 'EMPTY — rerun 01_reference_data_registry.sql' END AS status
    FROM ref.TIPO_INCIDENTE
    UNION ALL
    SELECT 'ref.ESTADO_PEDIDO', COUNT(*),
           CASE WHEN COUNT(*) = 6 THEN 'OK' WHEN COUNT(*) > 0 THEN 'HAS DATA'
                ELSE 'EMPTY' END
    FROM ref.ESTADO_PEDIDO
    UNION ALL
    SELECT 'ref.CATEGORIA_CLIENTE', COUNT(*),
           CASE WHEN COUNT(*) = 5 THEN 'OK' WHEN COUNT(*) > 0 THEN 'HAS DATA'
                ELSE 'EMPTY' END
    FROM ref.CATEGORIA_CLIENTE
    UNION ALL
    SELECT 'ref.TIPO_VEHICULO', COUNT(*),
           CASE WHEN COUNT(*) = 6 THEN 'OK' WHEN COUNT(*) > 0 THEN 'HAS DATA'
                ELSE 'EMPTY' END
    FROM ref.TIPO_VEHICULO
    UNION ALL
    SELECT 'ref.ESTADO_ENTREGA', COUNT(*),
           CASE WHEN COUNT(*) = 5 THEN 'OK' WHEN COUNT(*) > 0 THEN 'HAS DATA'
                ELSE 'EMPTY' END
    FROM ref.ESTADO_ENTREGA;
END
ELSE
    PRINT 'ref.TIPO_INCIDENTE does not exist — run 01_reference_data_registry.sql first';

-- ============================================================
-- 7. MASTER DATA BEFORE/AFTER
-- ============================================================
PRINT '';
PRINT '--- 7. MASTER DATA BEFORE / AFTER ---';

IF OBJECT_ID('governance_control.MASTER_CONDUCTOR','U') IS NOT NULL
BEGIN
    SELECT
        'flota.CONDUCTOR (source)'  AS entity, COUNT(*) AS records, 'SOURCE' AS type
    FROM flota.CONDUCTOR
    UNION ALL
    SELECT 'flota.EMPLEADO drivers', COUNT(*), 'SOURCE'
    FROM flota.EMPLEADO WHERE cargo IN ('CONDUCTOR','CHOFER','DRIVER','OPERADOR')
    UNION ALL
    SELECT 'flota.OPERADOR', COUNT(*), 'SOURCE'
    FROM flota.OPERADOR
    UNION ALL
    SELECT 'governance_control.MASTER_CONDUCTOR', COUNT(*), 'MASTER (AFTER)'
    FROM governance_control.MASTER_CONDUCTOR
    UNION ALL
    SELECT '  → needing_review=1', COUNT(*), 'FLAGGED'
    FROM governance_control.MASTER_CONDUCTOR WHERE necesita_revision=1;
END
ELSE PRINT 'MASTER_CONDUCTOR does not exist — run 02_driver_consolidation.sql';

PRINT '';

IF OBJECT_ID('governance_control.MASTER_CLIENTE','U') IS NOT NULL
BEGIN
    SELECT
        'ventas.CLIENTE (source)'       AS entity, COUNT(*) AS records, 'SOURCE' AS type
    FROM ventas.CLIENTE
    UNION ALL
    SELECT 'facturacion.CLIENTE (source)', COUNT(*), 'SOURCE'
    FROM facturacion.CLIENTE
    UNION ALL
    SELECT 'governance_control.MASTER_CLIENTE', COUNT(*), 'MASTER (AFTER)'
    FROM governance_control.MASTER_CLIENTE
    UNION ALL
    SELECT '  → needing_review=1', COUNT(*), 'FLAGGED'
    FROM governance_control.MASTER_CLIENTE WHERE necesita_revision=1
    UNION ALL
    SELECT 'MASTER_CLIENT_AUDIT entries', COUNT(*), 'AUDIT'
    FROM governance_control.MASTER_CLIENT_AUDIT;
END
ELSE PRINT 'MASTER_CLIENTE does not exist — run 03_client_deduplication.sql';

-- ============================================================
-- 8. DSA AND LINEAGE CONTENT
-- ============================================================
PRINT '';
PRINT '--- 8. DSA AND LINEAGE ---';

IF OBJECT_ID('governance_control.DATA_SHARING_AGREEMENT','U') IS NOT NULL
BEGIN
    SELECT dsa_code, dsa_status,
           producer_schema + '.' + producer_table AS producer,
           consumer_schema + '.' + consumer_table AS consumer,
           data_classification,
           CASE WHEN dsa_code IN ('DSA-OPS-BILL-001','DSA-FLEET-OPS-001',
                                  'DSA-VENTAS-FACT-001','DSA-FLOTA-GOV-001')
                THEN 'OK' ELSE 'UNEXPECTED CODE' END AS code_check
    FROM governance_control.DATA_SHARING_AGREEMENT
    ORDER BY dsa_code;

    PRINT '';
    SELECT dsa_code, violation_type, resolution_status,
           LEFT(description, 80) + '...' AS description_short
    FROM governance_control.DSA_VIOLATION_LOG vl
    JOIN governance_control.DATA_SHARING_AGREEMENT dsa ON dsa.dsa_id = vl.dsa_id
    ORDER BY dsa_code;
END
ELSE PRINT 'DATA_SHARING_AGREEMENT does not exist — run 05_sharing_agreements.sql';

PRINT '';

IF OBJECT_ID('governance_control.DATA_LINEAGE','U') IS NOT NULL
BEGIN
    SELECT flow_name,
           source_schema + '.' + source_table AS source,
           destination_schema + '.' + destination_table AS destination,
           has_known_issues,
           CASE WHEN flow_name IN (
               'VENTAS_CLIENTE_TO_PEDIDO',
               'ENTREGA_TO_FACTURA',
               'TELEMETRIA_GPS_TO_ORDER_CONTEXT',
               'DRIVER_FRAGMENTED_TO_MASTER',
               'CLIENT_DUAL_MODULE_TO_MASTER')
           THEN 'OK' ELSE 'UNEXPECTED' END AS name_check
    FROM governance_control.DATA_LINEAGE
    ORDER BY flow_name;
END
ELSE PRINT 'DATA_LINEAGE does not exist — run 04_data_lineage.sql';

-- ============================================================
-- 9. CONSTRAINTS — PK and UQ must exist
-- ============================================================
PRINT '';
PRINT '--- 9. KEY CONSTRAINTS ---';

SELECT
    tc.CONSTRAINT_NAME,
    tc.TABLE_SCHEMA + '.' + tc.TABLE_NAME AS full_table,
    tc.CONSTRAINT_TYPE,
    'EXISTS' AS status
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
WHERE tc.TABLE_SCHEMA IN ('governance_control','ref')
  AND tc.CONSTRAINT_TYPE IN ('PRIMARY KEY','UNIQUE')
ORDER BY tc.TABLE_SCHEMA, tc.TABLE_NAME, tc.CONSTRAINT_TYPE;

-- ============================================================
-- SUMMARY
-- ============================================================
PRINT '';
PRINT '============================================================';
PRINT 'VALIDATION COMPLETE';
PRINT 'Look for MISSING in sections 4-8 — those scripts need to run.';
PRINT 'Look for EMPTY in section 6 — those INSERTs did not execute.';
PRINT '============================================================';
GO
