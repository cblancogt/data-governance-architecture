/* ============================================================================
   FILE:        06_data_vault_satellites.sql
   PROJECT:     P02 - Data Governance Architecture | TRANSTRACK
   FOLDER:      06-analytical-modeling
   PURPOSE:     Data Vault 2.0 satellites - descriptive, historized attributes
   AUTHOR:      cblancogt

   Satellites hold the "what changed and when" detail hung off a hub or link.
   Unlike Dim_Cliente's SCD2 (which tracks ONE business attribute deliberately
   chosen for BI relevance), satellites track the FULL descriptive record,
   because the legal/audit use case requires reconstructing exactly what was
   known at any given moment - not just the attributes an analyst cared about.
   The composite key (hash_key, load_date) is what makes a satellite a proper
   append-only history table: every load that detects a change inserts a new
   row instead of updating, so no state is ever destroyed.
   ============================================================================ */

USE TRANSTRACK;
GO

/* ============================================================================
   SAT_CONDUCTOR_DETALLE
   License and employment history for a driver. This is what makes it
   possible to answer, months or years after the fact, "was this driver's
   license valid on the date of the incident" - a question the OLTP tables
   (which only store current state) cannot answer once the license record
   has been updated.
   ============================================================================ */
CREATE TABLE vault.Sat_Conductor_Detalle
(
    conductor_hash_key     CHAR(40)        NOT NULL CONSTRAINT FK_SatConductor_Hub REFERENCES vault.Hub_Conductor(conductor_hash_key),
    load_date              DATETIME2(0)    NOT NULL,

    numero_licencia         NVARCHAR(40)    NULL,
    categoria_licencia      NVARCHAR(20)    NULL,
    fecha_vencimiento_lic    DATE            NULL,
    licencia_vigente        BIT             NOT NULL,
    estado_activo           BIT             NOT NULL,
    nombre_completo         NVARCHAR(402)   NOT NULL,
    telefono                NVARCHAR(40)    NULL,
    email                   NVARCHAR(200)   NULL,

    hash_diff               CHAR(32)        NOT NULL,                  -- MD5 of all attributes above, change-detection
    load_end_date           DATETIME2(0)    NULL,                       -- NULL = this is the current version
    record_source           VARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Sat_Conductor_Detalle PRIMARY KEY CLUSTERED (conductor_hash_key, load_date)
)
ON [ANALYTICS];
GO

CREATE NONCLUSTERED INDEX IX_SatConductor_Vigente
    ON vault.Sat_Conductor_Detalle (conductor_hash_key)
    INCLUDE (numero_licencia, categoria_licencia, fecha_vencimiento_lic, licencia_vigente)
    WHERE load_end_date IS NULL
    ON [ANALYTICS];
GO

/* ============================================================================
   SAT_INCIDENTE_DETALLE
   Full descriptive record of an incident, including resolution lifecycle.
   Hangs off Hub_Incidente (not off a link) because these attributes describe
   the incident itself, independent of which driver/vehicle/order it relates to.
   ============================================================================ */
CREATE TABLE vault.Sat_Incidente_Detalle
(
    incidente_hash_key     CHAR(40)        NOT NULL CONSTRAINT FK_SatIncidente_Hub REFERENCES vault.Hub_Incidente(incidente_hash_key),
    load_date              DATETIME2(0)    NOT NULL,

    fecha_incidente          DATETIME2(0)    NOT NULL,
    tipo_incidente           VARCHAR(50)     NOT NULL,
    descripcion              VARCHAR(1000)   NOT NULL,
    severidad                VARCHAR(20)     NOT NULL,
    estado_resolucion         VARCHAR(30)     NOT NULL,
    costo_estimado            DECIMAL(12,2)   NULL,
    fecha_resolucion          DATETIME2(0)    NULL,

    hash_diff                CHAR(32)        NOT NULL,
    load_end_date            DATETIME2(0)    NULL,
    record_source             VARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Sat_Incidente_Detalle PRIMARY KEY CLUSTERED (incidente_hash_key, load_date)
)
ON [ANALYTICS];
GO

CREATE NONCLUSTERED INDEX IX_SatIncidente_Vigente
    ON vault.Sat_Incidente_Detalle (incidente_hash_key)
    INCLUDE (estado_resolucion, severidad, costo_estimado)
    WHERE load_end_date IS NULL
    ON [ANALYTICS];
GO

/* ============================================================================
   LOAD PROCEDURES - same hash-diff append pattern as Dim_Cliente's SCD2,
   applied at the satellite level instead of the dimension level.
   ============================================================================ */
CREATE OR ALTER PROCEDURE vault.usp_Load_Sat_Conductor_Detalle
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Source AS (
        SELECT
            hc.conductor_hash_key,
            mc.numero_licencia, mc.categoria_licencia, mc.fecha_vencimiento_lic,
            CAST(mc.licencia_vigente AS BIT) AS licencia_vigente,
            mc.estado_activo, mc.nombre_completo, mc.telefono, mc.email,
            CONVERT(CHAR(32), HASHBYTES('MD5', CONCAT_WS('|',
                ISNULL(mc.numero_licencia, ''), ISNULL(mc.categoria_licencia, ''),
                ISNULL(CAST(mc.fecha_vencimiento_lic AS VARCHAR(10)), ''),
                CAST(mc.licencia_vigente AS VARCHAR(1)), CAST(mc.estado_activo AS VARCHAR(1)),
                ISNULL(mc.telefono, ''), ISNULL(mc.email, '')
            )), 2) AS hash_diff
        FROM governance_control.MASTER_CONDUCTOR mc
        INNER JOIN vault.Hub_Conductor hc ON hc.master_conductor_id = mc.master_conductor_id
    )
    -- close out the current row for anything that changed
    UPDATE s
    SET load_end_date = SYSUTCDATETIME()
    FROM vault.Sat_Conductor_Detalle s
    INNER JOIN Source src ON src.conductor_hash_key = s.conductor_hash_key
    WHERE s.load_end_date IS NULL
      AND s.hash_diff <> src.hash_diff;

    -- insert the new current version (or the very first version)
    INSERT INTO vault.Sat_Conductor_Detalle
        (conductor_hash_key, load_date, numero_licencia, categoria_licencia, fecha_vencimiento_lic,
         licencia_vigente, estado_activo, nombre_completo, telefono, email, hash_diff, record_source)
    SELECT
        src.conductor_hash_key, SYSUTCDATETIME(), src.numero_licencia, src.categoria_licencia,
        src.fecha_vencimiento_lic, src.licencia_vigente, src.estado_activo, src.nombre_completo,
        src.telefono, src.email, src.hash_diff, 'governance_control.MASTER_CONDUCTOR'
    FROM Source src
    WHERE NOT EXISTS (
        SELECT 1 FROM vault.Sat_Conductor_Detalle s
        WHERE s.conductor_hash_key = src.conductor_hash_key
          AND s.load_end_date IS NULL
          AND s.hash_diff = src.hash_diff
    );
END;
GO

CREATE OR ALTER PROCEDURE vault.usp_Load_Sat_Incidente_Detalle
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Source AS (
        SELECT
            hi.incidente_hash_key,
            i.fecha_incidente, i.tipo_incidente, i.descripcion, i.severidad,
            i.estado_resolucion, i.costo_estimado, i.fecha_resolucion,
            CONVERT(CHAR(32), HASHBYTES('MD5', CONCAT_WS('|',
                i.estado_resolucion, ISNULL(CAST(i.costo_estimado AS VARCHAR(20)), ''),
                ISNULL(CAST(i.fecha_resolucion AS VARCHAR(30)), '')
            )), 2) AS hash_diff
        FROM operaciones.INCIDENTE i
        INNER JOIN vault.Hub_Incidente hi ON hi.incidente_id = i.incidente_id
    )
    UPDATE s
    SET load_end_date = SYSUTCDATETIME()
    FROM vault.Sat_Incidente_Detalle s
    INNER JOIN Source src ON src.incidente_hash_key = s.incidente_hash_key
    WHERE s.load_end_date IS NULL
      AND s.hash_diff <> src.hash_diff;

    INSERT INTO vault.Sat_Incidente_Detalle
        (incidente_hash_key, load_date, fecha_incidente, tipo_incidente, descripcion,
         severidad, estado_resolucion, costo_estimado, fecha_resolucion, hash_diff, record_source)
    SELECT
        src.incidente_hash_key, SYSUTCDATETIME(), src.fecha_incidente, src.tipo_incidente,
        src.descripcion, src.severidad, src.estado_resolucion, src.costo_estimado,
        src.fecha_resolucion, src.hash_diff, 'operaciones.INCIDENTE'
    FROM Source src
    WHERE NOT EXISTS (
        SELECT 1 FROM vault.Sat_Incidente_Detalle s
        WHERE s.incidente_hash_key = src.incidente_hash_key
          AND s.load_end_date IS NULL
          AND s.hash_diff = src.hash_diff
    );
END;
GO
