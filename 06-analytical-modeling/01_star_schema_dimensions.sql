/* ============================================================================
   FILE:        01_star_schema_dimensions.sql
   PROJECT:     P02 - Data Governance Architecture | TRANSTRACK
   FOLDER:      06-analytical-modeling
   PURPOSE:     Kimball dimensional model - dimension tables (SCD1 and SCD2)
   AUTHOR:      cblancogt

   ARCHITECTURE NOTE (DAMA-DMBOK Ch.5 - Data Modeling, Ch.6 - Data Storage):
   These dimensions are NOT built on top of the raw fragmented source tables
   (ventas.CLIENTE, facturacion.CLIENTE, flota.CONDUCTOR/EMPLEADO/OPERADOR).
   They are built on top of the GOVERNED master data produced in folder
   05-reference-and-master-data (governance_control.MASTER_CLIENTE,
   governance_control.MASTER_CONDUCTOR). This is intentional: a star schema
   is a consumption layer, not a cleansing layer. If dimensions consumed the
   raw duplicated sources, every KPI built on top would inherit the same
   "how many unique clients do we have" problem that justified this entire
   project (see 02-base-system-scripts and 03-data-quality-diagnostic).

   All dimensional tables are physically placed on the ANALYTICS filegroup,
   isolating dimensional/analytical I/O from OLTP I/O on PRIMARY.
   ============================================================================ */

USE TRANSTRACK;
GO

-- ----------------------------------------------------------------------------
-- Schema for the Kimball dimensional model. Kept separate from governance_control
-- and the OLTP schemas (ventas, facturacion, flota, operaciones) so ownership,
-- permissions (see 05-...RLS roles) and backup/recovery strategy can differ.
-- ----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dw')
BEGIN
    EXEC('CREATE SCHEMA dw AUTHORIZATION dbo');
END
GO

/* ============================================================================
   DIM_CLIENTE  (Slowly Changing Dimension Type 2)
   ----------------------------------------------------------------------------
   Business case link: this dimension is the direct answer to the question
   TRANSTRACK could not answer in folder 01: "How many unique clients do we
   have?". Source is governance_control.MASTER_CLIENTE (1 golden record per
   real-world client), not the 15,000 raw + duplicate rows in ventas/facturacion.

   SCD2 tracks changes to CATEGORIA (client tier: pequeño/mediano/corporativo)
   because tier changes drive rate changes in ventas.CONTRATO_CLIENTE, and the
   business needs to know "what tier was this client in when this order/invoice
   happened" - not just what tier they are today. Address/contact fields are
   tracked as Type 1 (overwrite) since they carry no analytical/financial
   consequence for historical facts.
   ============================================================================ */
CREATE TABLE dw.Dim_Cliente
(
    cliente_sk              INT             IDENTITY(1,1)   NOT NULL,   -- surrogate key, used in fact tables
    master_cliente_id       INT             NOT NULL,                   -- business key -> governance_control.MASTER_CLIENTE
    client_hash_key         CHAR(32)        NOT NULL,                   -- traceability back to MASTER_CLIENTE.client_hash_key

    -- Type 1 attributes (overwritten in place, no history needed)
    nit_ventas              NVARCHAR(40)    NULL,
    nit_facturacion         NVARCHAR(40)    NULL,
    nombre                  NVARCHAR(400)   NOT NULL,
    email                   NVARCHAR(200)   NULL,
    telefono                NVARCHAR(40)    NULL,
    ciudad                  NVARCHAR(160)   NULL,

    -- Type 2 attributes (versioned - this is what makes it SCD2)
    categoria               NVARCHAR(60)    NULL,                       -- pequeño / mediano / corporativo
    limite_credito          DECIMAL(12,2)   NULL,
    dias_credito            INT             NULL,

    -- SCD2 control columns
    fecha_inicio_vigencia   DATETIME2(0)    NOT NULL,
    fecha_fin_vigencia      DATETIME2(0)    NULL,                       -- NULL = current version
    es_version_actual       BIT             NOT NULL CONSTRAINT DF_DimCliente_EsActual DEFAULT (1),
    numero_version          INT             NOT NULL CONSTRAINT DF_DimCliente_Version DEFAULT (1),
    hash_diff               CHAR(32)        NOT NULL,                   -- MD5/HASHBYTES of type-2 attrs, used to detect change

    -- Row metadata
    fecha_carga             DATETIME2(0)    NOT NULL CONSTRAINT DF_DimCliente_FechaCarga DEFAULT (SYSUTCDATETIME()),
    fuente_carga            NVARCHAR(100)   NOT NULL CONSTRAINT DF_DimCliente_Fuente DEFAULT ('governance_control.MASTER_CLIENTE'),

    CONSTRAINT PK_Dim_Cliente PRIMARY KEY NONCLUSTERED (cliente_sk)
)
ON [ANALYTICS];
GO

-- Clustered index on the natural query pattern: find current row for a business key fast.
CREATE CLUSTERED INDEX CIX_Dim_Cliente_MasterId_Version
    ON dw.Dim_Cliente (master_cliente_id, numero_version)
    ON [ANALYTICS];
GO

-- Optimizes SCD2 lookups: "give me the currently active row for this client"
CREATE NONCLUSTERED INDEX IX_Dim_Cliente_Actual
    ON dw.Dim_Cliente (master_cliente_id)
    INCLUDE (cliente_sk, categoria, limite_credito, dias_credito)
    WHERE es_version_actual = 1
    ON [ANALYTICS];
GO

/* ============================================================================
   DIM_CONDUCTOR  (Slowly Changing Dimension Type 1)
   ----------------------------------------------------------------------------
   Source: governance_control.MASTER_CONDUCTOR - the golden record that
   consolidates the intentionally fragmented flota.CONDUCTOR + flota.EMPLEADO
   + flota.OPERADOR (three tables, no common key, per the folder 02 business
   case). This confirms the "how many unique drivers do we have" question.

   Kept as Type 1 here on purpose: full license/employment HISTORY with legal
   traceability (license renewals, status changes over time) is the job of
   Sat_Conductor_Detalle in the Data Vault (file 06), not of this dimension.
   The star schema only needs "who is this driver, right now" for fast
   aggregation of Fact_Pedido / Fact_Entrega / Fact_Incidente by driver.
   ============================================================================ */
CREATE TABLE dw.Dim_Conductor
(
    conductor_sk            INT             IDENTITY(1,1)   NOT NULL,
    master_conductor_id     INT             NOT NULL,                   -- business key -> governance_control.MASTER_CONDUCTOR
    conductor_hash_key      CHAR(32)        NOT NULL,

    numero_licencia         NVARCHAR(40)    NULL,
    codigo_empleado         NVARCHAR(40)    NULL,
    id_operador             NVARCHAR(40)    NULL,
    nombre_completo         NVARCHAR(402)   NOT NULL,
    telefono                NVARCHAR(40)    NULL,
    email                   NVARCHAR(200)   NULL,
    categoria_licencia      NVARCHAR(20)    NULL,
    fecha_vencimiento_lic   DATE            NULL,
    licencia_vigente        BIT             NOT NULL,
    estado_activo           BIT             NOT NULL,
    num_fuentes_origen      TINYINT         NOT NULL,                   -- 1, 2 or 3: how many of the 3 legacy tables fed this record

    fecha_carga             DATETIME2(0)    NOT NULL CONSTRAINT DF_DimConductor_FechaCarga DEFAULT (SYSUTCDATETIME()),
    fuente_carga            NVARCHAR(100)   NOT NULL CONSTRAINT DF_DimConductor_Fuente DEFAULT ('governance_control.MASTER_CONDUCTOR'),

    CONSTRAINT PK_Dim_Conductor PRIMARY KEY CLUSTERED (conductor_sk)
)
ON [ANALYTICS];
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_Conductor_MasterId
    ON dw.Dim_Conductor (master_conductor_id)
    ON [ANALYTICS];
GO

/* ============================================================================
   DIM_VEHICULO (Type 1) - source: flota.VEHICULO (800 rows, no MDM problem here)
   ============================================================================ */
CREATE TABLE dw.Dim_Vehiculo
(
    vehiculo_sk         INT             IDENTITY(1,1)   NOT NULL,
    vehiculo_id         INT             NOT NULL,                       -- business key -> flota.VEHICULO.vehiculo_id
    placa               VARCHAR(10)     NOT NULL,
    marca               VARCHAR(50)     NOT NULL,
    modelo              VARCHAR(50)     NOT NULL,
    anio                INT             NOT NULL,
    tipo_vehiculo       VARCHAR(50)     NOT NULL,
    capacidad_ton       DECIMAL(6,2)    NOT NULL,
    estado              VARCHAR(20)     NOT NULL,                       -- operativo / mantenimiento / baja
    fecha_adquisicion   DATE            NOT NULL,
    km_actuales         DECIMAL(10,2)   NOT NULL,

    fecha_carga         DATETIME2(0)    NOT NULL CONSTRAINT DF_DimVehiculo_FechaCarga DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT PK_Dim_Vehiculo PRIMARY KEY CLUSTERED (vehiculo_sk)
)
ON [ANALYTICS];
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_Vehiculo_VehiculoId
    ON dw.Dim_Vehiculo (vehiculo_id)
    ON [ANALYTICS];
GO

/* ============================================================================
   DIM_RUTA (Type 1) - source: operaciones.RUTA (2,500 rows, reference-style)
   ============================================================================ */
CREATE TABLE dw.Dim_Ruta
(
    ruta_sk             INT             IDENTITY(1,1)   NOT NULL,
    ruta_id             INT             NOT NULL,                       -- business key -> operaciones.RUTA.ruta_id
    codigo_ruta         VARCHAR(20)     NOT NULL,
    ciudad_origen       VARCHAR(80)     NOT NULL,
    ciudad_destino      VARCHAR(80)     NOT NULL,
    distancia_km        DECIMAL(8,2)    NOT NULL,
    tiempo_estimado_h   DECIMAL(5,2)    NOT NULL,
    tipo_via            VARCHAR(30)     NOT NULL,
    activa              BIT             NOT NULL,

    fecha_carga         DATETIME2(0)    NOT NULL CONSTRAINT DF_DimRuta_FechaCarga DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT PK_Dim_Ruta PRIMARY KEY CLUSTERED (ruta_sk)
)
ON [ANALYTICS];
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_Ruta_RutaId
    ON dw.Dim_Ruta (ruta_id)
    ON [ANALYTICS];
GO

/* ============================================================================
   DIM_ESTADO_ENTREGA (Type 1) - small conformed dimension for delivery status
   Sourced from the distinct values of operaciones.ENTREGA.estado_entrega.
   Kept as a proper dimension (not a varchar degenerate attribute in the fact)
   so business-friendly labels and sort order can evolve independently of
   the source system's raw status codes - governed via REF_DATA_REGISTRY.
   ============================================================================ */
CREATE TABLE dw.Dim_EstadoEntrega
(
    estado_entrega_sk   INT             IDENTITY(1,1)   NOT NULL,
    codigo_estado       VARCHAR(30)     NOT NULL,                       -- raw value from operaciones.ENTREGA.estado_entrega
    descripcion         NVARCHAR(200)   NOT NULL,
    es_estado_final     BIT             NOT NULL,                       -- 1 = entregado/cancelado, 0 = en tránsito/pendiente
    orden_presentacion  TINYINT         NOT NULL,

    CONSTRAINT PK_Dim_EstadoEntrega PRIMARY KEY CLUSTERED (estado_entrega_sk)
)
ON [ANALYTICS];
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_EstadoEntrega_Codigo
    ON dw.Dim_EstadoEntrega (codigo_estado)
    ON [ANALYTICS];
GO

/* ============================================================================
   DIM_TIEMPO - standard date dimension.
   Range: 2019-01-01 (earliest PEDIDO) through 2028-12-31 (buffer for planning).
   Generated once via a numbers-table pattern, not via a loop (DBA best
   practice: set-based generation avoids RBAR and is fast even for ~3,650 rows).
   ============================================================================ */
CREATE TABLE dw.Dim_Tiempo
(
    tiempo_sk           INT             NOT NULL,                       -- surrogate key = YYYYMMDD (also human-readable)
    fecha               DATE            NOT NULL,
    anio                SMALLINT        NOT NULL,
    trimestre           TINYINT         NOT NULL,
    mes                 TINYINT         NOT NULL,
    nombre_mes          VARCHAR(20)     NOT NULL,
    dia_mes             TINYINT         NOT NULL,
    dia_semana          TINYINT         NOT NULL,                       -- 1 = Sunday ... 7 = Saturday (SQL Server default)
    nombre_dia          VARCHAR(20)     NOT NULL,
    semana_anio         TINYINT         NOT NULL,
    es_fin_semana        BIT            NOT NULL,
    anio_mes            CHAR(7)         NOT NULL,                       -- 'YYYY-MM', used for partition-aligned reporting

    CONSTRAINT PK_Dim_Tiempo PRIMARY KEY CLUSTERED (tiempo_sk)
)
ON [ANALYTICS];
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_Tiempo_Fecha
    ON dw.Dim_Tiempo (fecha)
    ON [ANALYTICS];
GO

-- Set-based date generation using a tally table (no cursors, no WHILE loop).
DECLARE @FechaInicio DATE = '2019-01-01';
DECLARE @FechaFin    DATE = '2028-12-31';

;WITH Tally AS (
    SELECT TOP (DATEDIFF(DAY, @FechaInicio, @FechaFin) + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
),
Fechas AS (
    SELECT DATEADD(DAY, n, @FechaInicio) AS fecha
    FROM Tally
)
INSERT INTO dw.Dim_Tiempo
(
    tiempo_sk, fecha, anio, trimestre, mes, nombre_mes,
    dia_mes, dia_semana, nombre_dia, semana_anio, es_fin_semana, anio_mes
)
SELECT
    CAST(FORMAT(fecha, 'yyyyMMdd') AS INT)     AS tiempo_sk,
    fecha,
    YEAR(fecha)                                AS anio,
    DATEPART(QUARTER, fecha)                   AS trimestre,
    MONTH(fecha)                               AS mes,
    DATENAME(MONTH, fecha)                     AS nombre_mes,
    DAY(fecha)                                 AS dia_mes,
    DATEPART(WEEKDAY, fecha)                   AS dia_semana,
    DATENAME(WEEKDAY, fecha)                   AS nombre_dia,
    DATEPART(WEEK, fecha)                      AS semana_anio,
    CASE WHEN DATEPART(WEEKDAY, fecha) IN (1,7) THEN 1 ELSE 0 END AS es_fin_semana,
    FORMAT(fecha, 'yyyy-MM')                   AS anio_mes
FROM Fechas;
GO

PRINT 'Dim_Tiempo loaded: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' rows (2019-01-01 to 2028-12-31).';
GO

/* ============================================================================
   VALIDATION QUERIES - run after this script to confirm dimensions loaded
   correctly before proceeding to 02_star_schema_facts.sql
   ============================================================================ */
SELECT 'dw.Dim_Cliente'        AS tabla, COUNT(*) AS filas FROM dw.Dim_Cliente
UNION ALL
SELECT 'dw.Dim_Conductor',            COUNT(*) FROM dw.Dim_Conductor
UNION ALL
SELECT 'dw.Dim_Vehiculo',             COUNT(*) FROM dw.Dim_Vehiculo
UNION ALL
SELECT 'dw.Dim_Ruta',                 COUNT(*) FROM dw.Dim_Ruta
UNION ALL
SELECT 'dw.Dim_EstadoEntrega',        COUNT(*) FROM dw.Dim_EstadoEntrega
UNION ALL
SELECT 'dw.Dim_Tiempo',               COUNT(*) FROM dw.Dim_Tiempo;
GO

/* ============================================================================
   NOTE: Dim_Cliente, Dim_Conductor, Dim_Vehiculo, Dim_Ruta and Dim_EstadoEntrega
   are created here EMPTY (structure only). They are populated by the initial
   load logic inside 03_scd2_load_procedure.sql, which implements the SCD2
   MERGE pattern for Dim_Cliente and simple upsert logic for the Type-1
   dimensions. Dim_Tiempo is the only dimension fully loaded in this script
   because it is calendar-driven, not source-driven.
   ============================================================================ */
