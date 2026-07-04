-- =============================================================================
-- FILE: 02_driver_consolidation.sql
-- PROJECT: P02 - Data Governance Architecture | TRANSTRACK
-- MATCH STRATEGY: Sequential number extracted from business keys
--   CONDUCTOR.numero_licencia = 'LIC-000001' -> seq '000001'
--   EMPLEADO.codigo_empleado  = 'EMP-000001' -> seq '000001'
--   OPERADOR.id_operador      = 'OPR-000001' -> seq '000001'
-- =============================================================================

USE TRANSTRACK;
GO

-- =============================================================================
-- CLEANUP: drop FK child first, then parent
-- Cannot DROP MASTER_CONDUCTOR while CONDUCTOR_CROSSWALK has a FK pointing to it
-- =============================================================================

IF OBJECT_ID('governance_control.CONDUCTOR_CROSSWALK', 'U') IS NOT NULL
    DROP TABLE governance_control.CONDUCTOR_CROSSWALK;
GO

IF OBJECT_ID('governance_control.MASTER_CONDUCTOR', 'U') IS NOT NULL
    DROP TABLE governance_control.MASTER_CONDUCTOR;
GO

-- =============================================================================
-- STEP 1: STAGING
-- NOTE: No GO between staging inserts — all in one batch so #driver_staging
--       remains visible to subsequent statements in the same session.
-- =============================================================================

IF OBJECT_ID('tempdb..#driver_staging', 'U') IS NOT NULL DROP TABLE #driver_staging;

CREATE TABLE #driver_staging (
    staging_id          INT IDENTITY(1,1),
    source_system       NVARCHAR(20)    NOT NULL,
    source_pk           INT             NOT NULL,
    seq_key             NVARCHAR(10)    NOT NULL,
    numero_licencia     NVARCHAR(20)    NULL,
    codigo_empleado     NVARCHAR(20)    NULL,
    id_operador         NVARCHAR(20)    NULL,
    documento_id        NVARCHAR(20)    NULL,
    primer_nombre       NVARCHAR(100)   NULL,
    primer_apellido     NVARCHAR(100)   NULL,
    nombre_completo_raw NVARCHAR(200)   NULL,
    cargo               NVARCHAR(50)    NULL,
    activo              TINYINT         NULL,   -- TINYINT, not BIT (MAX works on TINYINT)
    fecha_ingreso       DATE            NULL,
    categoria_licencia  NVARCHAR(10)    NULL,
    fecha_vencimiento_lic DATE          NULL,
    telefono            NVARCHAR(20)    NULL,
    email               NVARCHAR(100)   NULL,
    trust_score         TINYINT         NOT NULL
);

-- flota.CONDUCTOR
INSERT INTO #driver_staging
    (source_system, source_pk, seq_key,
     numero_licencia, primer_nombre, primer_apellido,
     categoria_licencia, fecha_vencimiento_lic,
     telefono, activo, trust_score)
SELECT
    'CONDUCTOR',
    conductor_id,
    RIGHT(numero_licencia, 6),
    UPPER(LTRIM(RTRIM(numero_licencia))),
    LTRIM(RTRIM(nombre)),
    LTRIM(RTRIM(apellido)),
    categoria_licencia,
    fecha_vencimiento_licencia,
    telefono,
    CAST(activo AS TINYINT),
    3
FROM flota.CONDUCTOR;

-- flota.EMPLEADO (cargo = 'CONDUCTOR' only — confirmed 660 rows)
INSERT INTO #driver_staging
    (source_system, source_pk, seq_key,
     codigo_empleado, documento_id,
     primer_nombre, primer_apellido,
     cargo, fecha_ingreso, activo, trust_score)
SELECT
    'EMPLEADO',
    empleado_id,
    RIGHT(codigo_empleado, 6),
    codigo_empleado,
    LTRIM(RTRIM(dpi)),
    LTRIM(RTRIM(nombres)),
    LTRIM(RTRIM(apellidos)),
    cargo,
    fecha_ingreso,
    CAST(activo AS TINYINT),
    2
FROM flota.EMPLEADO
WHERE cargo = 'CONDUCTOR';

-- flota.OPERADOR (all 950 rows)
INSERT INTO #driver_staging
    (source_system, source_pk, seq_key,
     id_operador, documento_id,
     nombre_completo_raw, email, trust_score)
SELECT
    'OPERADOR',
    operador_id,
    RIGHT(id_operador, 6),
    id_operador,
    id_operador,
    LTRIM(RTRIM(nombre_completo)),
    email,
    1
FROM flota.OPERADOR;

-- Verify staging counts
SELECT source_system, COUNT(*) AS staged_rows
FROM #driver_staging
GROUP BY source_system;
GO

-- =============================================================================
-- STEP 2: MATCH GROUPS
-- All in one batch (no GO) so #driver_staging stays visible.
-- MAX(activo) works because activo is TINYINT now.
-- =============================================================================

IF OBJECT_ID('tempdb..#match_groups', 'U') IS NOT NULL DROP TABLE #match_groups;

SELECT
    seq_key,
    MAX(CASE WHEN source_system = 'CONDUCTOR' THEN source_pk END)          AS conductor_pk,
    MAX(CASE WHEN source_system = 'CONDUCTOR' THEN numero_licencia END)    AS numero_licencia,
    MAX(CASE WHEN source_system = 'CONDUCTOR' THEN primer_nombre END)      AS nombre_conductor,
    MAX(CASE WHEN source_system = 'CONDUCTOR' THEN primer_apellido END)    AS apellido_conductor,
    MAX(CASE WHEN source_system = 'CONDUCTOR' THEN categoria_licencia END) AS categoria_licencia,
    MAX(CASE WHEN source_system = 'CONDUCTOR' THEN fecha_vencimiento_lic END) AS fecha_vencimiento_lic,
    MAX(CASE WHEN source_system = 'CONDUCTOR' THEN telefono END)           AS telefono,
    MAX(CASE WHEN source_system = 'CONDUCTOR' THEN activo END)             AS activo_conductor,
    MAX(CASE WHEN source_system = 'EMPLEADO'  THEN source_pk END)          AS empleado_pk,
    MAX(CASE WHEN source_system = 'EMPLEADO'  THEN codigo_empleado END)    AS codigo_empleado,
    MAX(CASE WHEN source_system = 'EMPLEADO'  THEN documento_id END)       AS dpi,
    MAX(CASE WHEN source_system = 'EMPLEADO'  THEN primer_nombre END)      AS nombre_empleado,
    MAX(CASE WHEN source_system = 'EMPLEADO'  THEN primer_apellido END)    AS apellido_empleado,
    MAX(CASE WHEN source_system = 'EMPLEADO'  THEN fecha_ingreso END)      AS fecha_ingreso,
    MAX(CASE WHEN source_system = 'OPERADOR'  THEN source_pk END)          AS operador_pk,
    MAX(CASE WHEN source_system = 'OPERADOR'  THEN id_operador END)        AS id_operador,
    MAX(CASE WHEN source_system = 'OPERADOR'  THEN nombre_completo_raw END) AS nombre_operador,
    MAX(CASE WHEN source_system = 'OPERADOR'  THEN email END)              AS email,
    COUNT(DISTINCT source_system)                                           AS num_fuentes,
    STRING_AGG(source_system, ',') WITHIN GROUP (ORDER BY source_system)   AS fuentes
INTO #match_groups
FROM #driver_staging
GROUP BY seq_key;

-- Preview match quality before inserting
SELECT
    CASE
        WHEN conductor_pk IS NOT NULL AND empleado_pk IS NOT NULL AND operador_pk IS NOT NULL THEN 'ALL_3'
        WHEN conductor_pk IS NOT NULL AND empleado_pk IS NOT NULL THEN 'CONDUCTOR+EMPLEADO'
        WHEN conductor_pk IS NOT NULL AND operador_pk IS NOT NULL THEN 'CONDUCTOR+OPERADOR'
        WHEN conductor_pk IS NOT NULL THEN 'CONDUCTOR_ONLY'
        WHEN empleado_pk  IS NOT NULL THEN 'EMPLEADO_ONLY'
        ELSE 'OPERADOR_ONLY'
    END AS match_type,
    COUNT(*) AS groups
FROM #match_groups
GROUP BY
    CASE
        WHEN conductor_pk IS NOT NULL AND empleado_pk IS NOT NULL AND operador_pk IS NOT NULL THEN 'ALL_3'
        WHEN conductor_pk IS NOT NULL AND empleado_pk IS NOT NULL THEN 'CONDUCTOR+EMPLEADO'
        WHEN conductor_pk IS NOT NULL AND operador_pk IS NOT NULL THEN 'CONDUCTOR+OPERADOR'
        WHEN conductor_pk IS NOT NULL THEN 'CONDUCTOR_ONLY'
        WHEN empleado_pk  IS NOT NULL THEN 'EMPLEADO_ONLY'
        ELSE 'OPERADOR_ONLY'
    END
ORDER BY groups DESC;
GO

-- =============================================================================
-- STEP 3: MASTER CONDUCTOR TABLE
-- =============================================================================

CREATE TABLE governance_control.MASTER_CONDUCTOR (
    master_conductor_id     INT IDENTITY(1,1)   NOT NULL,
    conductor_hash_key      CHAR(32)            NOT NULL,
    seq_key                 NVARCHAR(10)        NOT NULL,
    numero_licencia         NVARCHAR(20)        NULL,
    codigo_empleado         NVARCHAR(20)        NULL,
    id_operador             NVARCHAR(20)        NULL,
    documento_id            NVARCHAR(20)        NULL,
    primer_nombre           NVARCHAR(100)       NOT NULL,
    primer_apellido         NVARCHAR(100)       NOT NULL,
    nombre_completo         AS (LTRIM(COALESCE(primer_nombre,'') + ' ' + COALESCE(primer_apellido,''))),
    telefono                NVARCHAR(20)        NULL,
    email                   NVARCHAR(100)       NULL,
    fecha_ingreso           DATE                NULL,
    categoria_licencia      NVARCHAR(10)        NULL,
    fecha_vencimiento_lic   DATE                NULL,
    licencia_vigente        AS (CASE
                                    WHEN fecha_vencimiento_lic IS NULL THEN 0
                                    WHEN fecha_vencimiento_lic >= CAST(GETDATE() AS DATE) THEN 1
                                    ELSE 0
                                END),
    estado_activo           BIT                 NOT NULL DEFAULT 1,
    fuentes_origen          NVARCHAR(100)       NOT NULL,
    num_fuentes             TINYINT             NOT NULL DEFAULT 1,
    necesita_revision       BIT                 NOT NULL DEFAULT 0,
    razon_revision          NVARCHAR(300)       NULL,
    record_version          INT                 NOT NULL DEFAULT 1,
    created_at              DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    created_by              NVARCHAR(100)       NOT NULL DEFAULT SYSTEM_USER,
    last_updated_at         DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_MASTER_CONDUCTOR PRIMARY KEY CLUSTERED (master_conductor_id),
    CONSTRAINT UQ_MASTER_CONDUCTOR_HASH UNIQUE (conductor_hash_key),
    CONSTRAINT UQ_MASTER_CONDUCTOR_SEQ  UNIQUE (seq_key)
);
GO

-- =============================================================================
-- STEP 4: INSERT GOLDEN RECORDS
-- One row per seq_key. CONDUCTOR data wins; EMPLEADO enriches; OPERADOR adds email.
-- =============================================================================

INSERT INTO governance_control.MASTER_CONDUCTOR
    (conductor_hash_key, seq_key,
     numero_licencia, codigo_empleado, id_operador, documento_id,
     primer_nombre, primer_apellido,
     telefono, email, fecha_ingreso,
     categoria_licencia, fecha_vencimiento_lic,
     estado_activo, fuentes_origen, num_fuentes,
     necesita_revision, razon_revision)
SELECT
    CONVERT(CHAR(32), HASHBYTES('MD5', 'SEQ_' + mg.seq_key), 2),
    mg.seq_key,
    mg.numero_licencia,
    mg.codigo_empleado,
    mg.id_operador,
    mg.dpi,
    COALESCE(
        mg.nombre_conductor,
        mg.nombre_empleado,
        LEFT(LTRIM(RTRIM(COALESCE(mg.nombre_operador,'UNKNOWN'))),
             CASE WHEN CHARINDEX(' ', LTRIM(RTRIM(COALESCE(mg.nombre_operador,'')))) > 0
                  THEN CHARINDEX(' ', LTRIM(RTRIM(mg.nombre_operador))) - 1
                  ELSE LEN(LTRIM(RTRIM(COALESCE(mg.nombre_operador,'UNKNOWN')))) END)
    ),
    COALESCE(
        mg.apellido_conductor,
        mg.apellido_empleado,
        CASE WHEN CHARINDEX(' ', LTRIM(RTRIM(COALESCE(mg.nombre_operador,'')))) > 0
             THEN SUBSTRING(LTRIM(RTRIM(mg.nombre_operador)),
                            CHARINDEX(' ', LTRIM(RTRIM(mg.nombre_operador))) + 1, 200)
             ELSE 'UNKNOWN' END
    ),
    mg.telefono,
    mg.email,
    mg.fecha_ingreso,
    mg.categoria_licencia,
    mg.fecha_vencimiento_lic,
    COALESCE(CAST(mg.activo_conductor AS BIT), 1),
    mg.fuentes,
    mg.num_fuentes,
    CASE WHEN mg.conductor_pk IS NULL THEN 1 ELSE 0 END,
    CASE WHEN mg.conductor_pk IS NULL
         THEN 'No CONDUCTOR record for seq ' + mg.seq_key + '. No license data. Manual review required.'
         ELSE NULL
    END
FROM #match_groups mg;
GO

-- =============================================================================
-- STEP 5: CROSSWALK TABLE
-- =============================================================================

CREATE TABLE governance_control.CONDUCTOR_CROSSWALK (
    crosswalk_id        INT IDENTITY(1,1)   NOT NULL,
    master_conductor_id INT                 NOT NULL,
    source_system       NVARCHAR(20)        NOT NULL,
    source_pk           INT                 NOT NULL,
    source_key          NVARCHAR(20)        NOT NULL,
    match_method        NVARCHAR(30)        NOT NULL,
    match_confidence    DECIMAL(5,2)        NOT NULL,
    created_at          DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_CONDUCTOR_CROSSWALK PRIMARY KEY CLUSTERED (crosswalk_id),
    CONSTRAINT FK_CROSSWALK_MASTER FOREIGN KEY (master_conductor_id)
        REFERENCES governance_control.MASTER_CONDUCTOR (master_conductor_id)
);
GO

-- CONDUCTOR
INSERT INTO governance_control.CONDUCTOR_CROSSWALK
    (master_conductor_id, source_system, source_pk, source_key, match_method, match_confidence)
SELECT
    mc.master_conductor_id,
    'CONDUCTOR',
    c.conductor_id,
    c.numero_licencia,
    'SEQ_KEY_MATCH',
    100.00
FROM flota.CONDUCTOR c
JOIN governance_control.MASTER_CONDUCTOR mc ON mc.seq_key = RIGHT(c.numero_licencia, 6);
GO

-- EMPLEADO
INSERT INTO governance_control.CONDUCTOR_CROSSWALK
    (master_conductor_id, source_system, source_pk, source_key, match_method, match_confidence)
SELECT
    mc.master_conductor_id,
    'EMPLEADO',
    e.empleado_id,
    e.codigo_empleado,
    CASE WHEN mc.numero_licencia IS NOT NULL THEN 'SEQ_KEY_MATCH' ELSE 'SEQ_KEY_NO_CONDUCTOR' END,
    CASE WHEN mc.numero_licencia IS NOT NULL THEN 95.00 ELSE 70.00 END
FROM flota.EMPLEADO e
JOIN governance_control.MASTER_CONDUCTOR mc ON mc.seq_key = RIGHT(e.codigo_empleado, 6)
WHERE e.cargo = 'CONDUCTOR';
GO

-- OPERADOR
INSERT INTO governance_control.CONDUCTOR_CROSSWALK
    (master_conductor_id, source_system, source_pk, source_key, match_method, match_confidence)
SELECT
    mc.master_conductor_id,
    'OPERADOR',
    o.operador_id,
    o.id_operador,
    CASE WHEN mc.numero_licencia IS NOT NULL THEN 'SEQ_KEY_MATCH' ELSE 'SEQ_KEY_NO_CONDUCTOR' END,
    CASE WHEN mc.numero_licencia IS NOT NULL THEN 95.00 ELSE 70.00 END
FROM flota.OPERADOR o
JOIN governance_control.MASTER_CONDUCTOR mc ON mc.seq_key = RIGHT(o.id_operador, 6);
GO

-- =============================================================================
-- STEP 6: RESULTS
-- =============================================================================

SELECT
    'BEFORE consolidation' AS phase,
    (SELECT COUNT(*) FROM flota.CONDUCTOR)                           AS conductor_rows,
    (SELECT COUNT(*) FROM flota.EMPLEADO WHERE cargo = 'CONDUCTOR') AS empleado_conductor_rows,
    (SELECT COUNT(*) FROM flota.OPERADOR)                            AS operador_rows,
    NULL AS unique_masters,
    NULL AS pct_needing_review
UNION ALL
SELECT
    'AFTER consolidation',
    NULL, NULL, NULL,
    (SELECT COUNT(*) FROM governance_control.MASTER_CONDUCTOR),
    CAST(
        100.0 * (SELECT COUNT(*) FROM governance_control.MASTER_CONDUCTOR WHERE necesita_revision = 1)
              / NULLIF((SELECT COUNT(*) FROM governance_control.MASTER_CONDUCTOR), 0)
    AS DECIMAL(5,2));
GO

-- Crosswalk breakdown
SELECT
    source_system,
    match_method,
    COUNT(*)              AS records,
    AVG(match_confidence) AS avg_confidence_pct
FROM governance_control.CONDUCTOR_CROSSWALK
GROUP BY source_system, match_method
ORDER BY source_system;
GO

-- Sample of golden records with all 3 sources
SELECT TOP 10
    mc.seq_key,
    mc.numero_licencia,
    mc.codigo_empleado,
    mc.id_operador,
    mc.primer_nombre + ' ' + mc.primer_apellido AS nombre,
    mc.categoria_licencia,
    mc.email,
    mc.fecha_ingreso,
    mc.fuentes_origen,
    mc.num_fuentes
FROM governance_control.MASTER_CONDUCTOR mc
WHERE mc.num_fuentes = 3
ORDER BY mc.seq_key;
GO
