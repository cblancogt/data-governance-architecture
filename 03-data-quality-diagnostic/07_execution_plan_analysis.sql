-- =============================================================================
-- P02 | TRANSTRACK Data Governance Architecture
-- Week 03 | Script 07: Execution Plan Analysis & Missing Index Recommendations
-- File: 07_execution_plan_analysis.sql
-- Author: cblancogt
--
-- Uses sys.dm_db_missing_index_details and sys.dm_exec_query_stats to identify
-- what the optimizer needed but didn't have during the Week 03 diagnostic run.
--
-- Also documents the Scan vs Seek analysis per diagnostic script with the exact
-- table and column names from the real TRANSTRACK schema.
-- =============================================================================

USE TRANSTRACK;
GO

-- =============================================================================
-- SECTION 1: SQL Server missing index recommendations (post-diagnostic run)
-- =============================================================================

SELECT 'SECTION 1 - SQL Server Missing Index Recommendations' AS diagnostic_section;

SELECT
    CAST(
        migs.avg_total_user_cost
        * migs.avg_user_impact
        * (migs.user_seeks + migs.user_scans)
    AS DECIMAL(18,2))                       AS impact_score,
    mid.statement                           AS full_table_name,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    migs.user_seeks,
    migs.user_scans,
    CAST(migs.avg_user_impact AS DECIMAL(5,2)) AS pct_improvement_if_created,
    migs.last_user_seek,
    -- Ready-to-use CREATE INDEX statement
    'CREATE INDEX IX_MISSING_' + CAST(mid.index_handle AS VARCHAR)
    + ' ON ' + mid.statement
    + ' (' + ISNULL(mid.equality_columns, '')
    + CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL
           THEN ', ' ELSE '' END
    + ISNULL(mid.inequality_columns, '') + ')'
    + CASE WHEN mid.included_columns IS NOT NULL
           THEN ' INCLUDE (' + mid.included_columns + ')' ELSE '' END
    + ';'                                   AS suggested_index_ddl
FROM sys.dm_db_missing_index_groups mig
JOIN sys.dm_db_missing_index_group_stats migs
    ON mig.index_group_handle = migs.group_handle
JOIN sys.dm_db_missing_index_details mid
    ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID('TRANSTRACK')
ORDER BY impact_score DESC;

-- =============================================================================
-- SECTION 2: Column data type audit — detect potential implicit conversions
-- The biggest silent performance killer: VARCHAR vs NVARCHAR in JOIN conditions
-- Check every key column used in the diagnostic scripts
-- =============================================================================

SELECT 'SECTION 2 - Key column data type audit (implicit conversion risk)' AS diagnostic_section;

SELECT
    s.name          AS schema_name,
    t.name          AS table_name,
    c.name          AS column_name,
    tp.name         AS data_type,
    c.max_length,
    c.is_nullable,
    -- Flag cross-table join columns for type consistency check
    CASE
        WHEN c.name IN ('nit','nit_cliente')            THEN 'CLIENT_KEY — must match across ventas/facturacion'
        WHEN c.name IN ('pedido_id','cliente_id',
                        'vehiculo_id','conductor_id',
                        'ruta_id','factura_id',
                        'entrega_id','incidente_id',
                        'empleado_id','operador_id')     THEN 'PK/FK — check INT vs BIGINT consistency'
        WHEN c.name IN ('numero_licencia','dpi',
                        'codigo_empleado','id_operador') THEN 'CROSS_TABLE_KEY — no FK, join by value'
        WHEN c.name IN ('placa','vehiculo_asignado')    THEN 'VEHICLE_KEY — free text in OPERADOR, no FK'
        ELSE '-'
    END             AS governance_note
FROM sys.tables t
JOIN sys.schemas s   ON t.schema_id = s.schema_id
JOIN sys.columns c   ON t.object_id = c.object_id
JOIN sys.types tp    ON c.user_type_id = tp.user_type_id
WHERE s.name IN ('ventas','facturacion','operaciones','flota')
  AND (
    c.name IN (
        'nit','nit_cliente',
        'pedido_id','cliente_id','vehiculo_id','conductor_id',
        'ruta_id','factura_id','entrega_id','incidente_id',
        'empleado_id','operador_id',
        'numero_licencia','dpi','codigo_empleado','id_operador',
        'placa','vehiculo_asignado'
    )
  )
ORDER BY c.name, s.name, t.name;

-- =============================================================================
-- SECTION 3: Top queries by logical reads from the diagnostic run
-- =============================================================================

SELECT 'SECTION 3 - Top queries by logical reads (last 2 hours)' AS diagnostic_section;

SELECT TOP 15
    qs.total_logical_reads / qs.execution_count     AS avg_logical_reads,
    qs.total_logical_reads,
    qs.execution_count,
    CAST(qs.total_elapsed_time / 1000000.0 / qs.execution_count AS DECIMAL(10,3)) AS avg_elapsed_sec,
    qs.total_physical_reads / qs.execution_count    AS avg_physical_reads,
    CASE WHEN qs.total_physical_reads > 0
         THEN 'COLD — data not in buffer pool (large scan)'
         ELSE 'WARM — served from memory'
    END                                             AS cache_status,
    SUBSTRING(
        qt.text,
        (qs.statement_start_offset / 2) + 1,
        (CASE qs.statement_end_offset
             WHEN -1 THEN DATALENGTH(qt.text)
             ELSE qs.statement_end_offset END
         - qs.statement_start_offset) / 2 + 1
    )                                               AS query_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
WHERE qs.last_execution_time >= DATEADD(HOUR, -2, GETDATE())
ORDER BY avg_logical_reads DESC;

-- =============================================================================
-- SECTION 4: Prioritized index implementation plan
-- Based on real TRANSTRACK schema and actual diagnostic query patterns
-- These are NOT yet implemented (intentional — Week 03 = before state)
-- =============================================================================

SELECT 'SECTION 4 - Prioritized Index Implementation Plan (Real Schema)' AS diagnostic_section;

SELECT *
FROM (VALUES
    -- CRITICAL: client NIT join (cross-module duplicate detection)
    (1, 'CRITICAL', '01_duplicate_clients',
     'CREATE INDEX IX_ventas_CLIENTE_NIT ON ventas.CLIENTE(nit) INCLUDE (nombre, email, categoria, activo);',
     'Enables Hash→NestedLoop seek for GROUP BY nit and cross-join to facturacion.CLIENTE. Eliminates Table Scan on 15K rows.'),

    (2, 'CRITICAL', '01_duplicate_clients',
     'CREATE INDEX IX_fact_CLIENTE_NIT ON facturacion.CLIENTE(nit_cliente) INCLUDE (razon_social, correo, limite_credito, dias_credito);',
     'Required counterpart for the ventas↔facturacion NIT join. Both sides must be indexed for Merge Join to activate.'),

    -- CRITICAL: orphan invoice detection
    (3, 'CRITICAL', '03_orphan_records',
     'CREATE INDEX IX_FACTURA_PEDIDO ON facturacion.FACTURA(pedido_id) INCLUDE (total, estado_pago, fecha_emision, cliente_fact_id);',
     'Enables Index Seek on NULL pedido_id and anti-join. Without it: Table Scan on 490K FACTURA rows per anti-join.'),

    -- HIGH: delivery anti-join
    (4, 'HIGH', '03_orphan_records',
     'CREATE INDEX IX_ENTREGA_PEDIDO ON operaciones.ENTREGA(pedido_id) INCLUDE (estado_entrega, fecha_entrega_real, fecha_salida);',
     'FK exists but no separate index. LEFT JOIN from 500K PEDIDO rows needs an Index Seek on ENTREGA.pedido_id.'),

    -- HIGH: assignment lookup (critical for driver traceability chain)
    (5, 'HIGH', '02_fragmented_drivers',
     'CREATE INDEX IX_ASIGNACION_PEDIDO ON flota.ASIGNACION_VEHICULO(pedido_id) INCLUDE (conductor_id, vehiculo_id, fecha_inicio, fecha_fin);',
     'Enables Seek for INCIDENTE→PEDIDO→ASIGNACION traceability chain. Central to legal chain reconstruction.'),

    -- HIGH: telemetry vehicle+time range seek
    (6, 'HIGH', '04_telemetry_gaps',
     'CREATE INDEX IX_TELEMETRIA_VEH_FECHA ON flota.TELEMETRIA_GPS(vehiculo_id, fecha_hora) INCLUDE (velocidad_kmh, evento) ON [ARCHIVE];',
     'CRITICAL for OUTER APPLY in Section 3. Without it: one Table Scan per assignment row = N × 50M rows.'),

    -- MEDIUM: incident lookup
    (7, 'MEDIUM', '02_fragmented_drivers / 05_business_impact',
     'CREATE INDEX IX_INCIDENTE_PEDIDO ON operaciones.INCIDENTE(pedido_id) INCLUDE (tipo_incidente, severidad, costo_estimado, estado_resolucion);',
     'FK exists but no index. Needed for NOT EXISTS subquery in business impact script.'),

    -- MEDIUM: pedido state filter
    (8, 'MEDIUM', '03_orphan_records',
     'CREATE INDEX IX_PEDIDO_ESTADO ON operaciones.PEDIDO(estado) INCLUDE (cliente_id, ruta_id, valor_declarado, fecha_pedido, fecha_requerida, peso_kg);',
     'Allows selective scan by estado=CANCELADO exclusion filter. Reduces working set before anti-join.')
) AS plan (priority, urgency, source_script, create_statement, rationale)
ORDER BY priority;

-- =============================================================================
-- SECTION 5: Scan vs Seek decision table — real schema operators
-- =============================================================================

SELECT 'SECTION 5 - Scan vs Seek Analysis Per Diagnostic Script' AS diagnostic_section;

SELECT *
FROM (VALUES
    ('01 S1 — GROUP BY ventas.CLIENTE.nit',
     'No index on nit',
     'Table Scan + Hash Aggregate',
     'Index Seek on IX_ventas_CLIENTE_NIT + Stream Aggregate',
     'IX_ventas_CLIENTE_NIT'),

    ('01 S2 — INNER JOIN ventas↔facturacion ON nit=nit_cliente',
     'No index on either nit column',
     'Table Scan × 2 + Hash Match Join',
     'Index Seek × 2 + Merge Join (if both indexed)',
     'IX_ventas_CLIENTE_NIT + IX_fact_CLIENTE_NIT'),

    ('01 S3 — SOUNDEX CROSS JOIN (near-duplicates)',
     'SOUNDEX() is not SARGable',
     'Nested Loops + Table Scan — O(n²) on 15K rows',
     'Persisted computed column SOUNDEX(nombre) + index on computed col',
     'ALTER TABLE ADD sdx_nombre AS SOUNDEX(nombre) PERSISTED; then index it'),

    ('02 S2 — SOUNDEX 3-way join CONDUCTOR+EMPLEADO+OPERADOR',
     'No shared key, SOUNDEX on all 3',
     '3× Table Scan + 2× Hash Match',
     'Computed column SOUNDEX on each table + index',
     'Add persisted SOUNDEX column to each table'),

    ('02 S5 — INCIDENTE→ASIGNACION→CONDUCTOR chain',
     'No index on ASIGNACION.pedido_id',
     'Table Scan on ASIGNACION per INCIDENTE row (Nested Loops)',
     'Index Seek on IX_ASIGNACION_PEDIDO per INCIDENTE',
     'IX_ASIGNACION_PEDIDO'),

    ('03 S1 — FACTURA WHERE pedido_id IS NULL',
     'No index on facturacion.FACTURA.pedido_id',
     'Table Scan on 490K FACTURA rows',
     'Index Seek on IX_FACTURA_PEDIDO (NULL values are indexed)',
     'IX_FACTURA_PEDIDO'),

    ('03 S2 — PEDIDO LEFT JOIN ENTREGA WHERE entrega_id IS NULL',
     'FK on ENTREGA.pedido_id but no supporting index',
     'Table Scan on ENTREGA + Hash Match',
     'Index Seek on IX_ENTREGA_PEDIDO',
     'IX_ENTREGA_PEDIDO'),

    ('04 S2 — TELEMETRIA LEFT JOIN ASIGNACION (date range overlap)',
     'No index on TELEMETRIA (vehiculo_id, fecha_hora)',
     'Hash Match after scanning 50M rows filtered by @window_start',
     'Index Range Seek per vehicle on IX_TELEMETRIA_VEH_FECHA',
     'IX_TELEMETRIA_VEH_FECHA ON [ARCHIVE]'),

    ('04 S3 — OUTER APPLY COUNT per ASIGNACION into TELEMETRIA',
     'Same missing index as above',
     'Nested Loops × N assignments × Table Scan on TELEMETRIA',
     'Nested Loops × N assignments × Index Seek per vehicle+date range',
     'IX_TELEMETRIA_VEH_FECHA ON [ARCHIVE]')
) AS scan_seek (script_section, root_cause, current_operator, optimal_operator, required_fix)
ORDER BY script_section;
