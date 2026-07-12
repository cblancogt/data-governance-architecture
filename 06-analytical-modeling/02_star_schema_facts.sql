/* ============================================================================
   FILE:        02_star_schema_facts.sql
   PROJECT:     P02 - Data Governance Architecture | TRANSTRACK
   FOLDER:      06-analytical-modeling
   PURPOSE:     Kimball dimensional model - fact tables
   AUTHOR:      cblancogt

   GRAIN DECLARATIONS (mandatory Kimball discipline - state the grain before
   writing a single column):
     - Fact_Pedido:    one row per PEDIDO (order placed).
     - Fact_Entrega:   one row per ENTREGA (physical delivery attempt/result).
     - Fact_Incidente: one row per INCIDENTE (accident/theft/delay/damage event).

   ARCHITECTURE NOTE - the "point-in-time" join problem:
   operaciones.ENTREGA and operaciones.INCIDENTE do not store conductor_id or
   vehiculo_id directly. That relationship lives in flota.ASIGNACION_VEHICULO,
   which is itself a dated range (fecha_inicio/fecha_fin) tied to pedido_id.
   Loading Fact_Entrega/Fact_Incidente therefore requires resolving "which
   driver/vehicle was assigned to this order AT THE TIME the event happened" -
   a classic point-in-time dimensional join, not a simple FK lookup. This is
   documented explicitly in 03_scd2_load_procedure.sql. Getting this join wrong
   is exactly the kind of silent data-quality defect this whole project exists
   to prevent (see 03-data-quality-diagnostic).
   ============================================================================ */

USE TRANSTRACK;
GO

/* ============================================================================
   FACT_PEDIDO
   ============================================================================ */
CREATE TABLE dw.Fact_Pedido
(
    pedido_id           INT             NOT NULL,                   -- degenerate dimension (natural key, no separate Dim_Pedido needed)
    numero_pedido        VARCHAR(30)     NOT NULL,

    cliente_sk           INT             NOT NULL    CONSTRAINT FK_FactPedido_Cliente   REFERENCES dw.Dim_Cliente(cliente_sk),
    ruta_sk              INT             NOT NULL    CONSTRAINT FK_FactPedido_Ruta      REFERENCES dw.Dim_Ruta(ruta_sk),
    tiempo_pedido_sk      INT             NOT NULL    CONSTRAINT FK_FactPedido_TiempoPed REFERENCES dw.Dim_Tiempo(tiempo_sk),
    tiempo_requerido_sk   INT             NOT NULL    CONSTRAINT FK_FactPedido_TiempoReq REFERENCES dw.Dim_Tiempo(tiempo_sk),

    -- local, non-key copies of the two dates. Kept alongside the surrogate keys
    -- (a standard Kimball practice) so the computed measure below can be a true
    -- persisted computed column - SQL Server does not allow a computed column
    -- to reference another table, only columns within the same row.
    fecha_pedido_real     DATE            NOT NULL,
    fecha_requerida_real  DATE            NOT NULL,

    -- degenerate attributes (low cardinality, kept in the fact instead of a mini-dimension
    -- to avoid an unnecessary join for a handful of values already governed via
    -- governance_control.REF_DATA_REGISTRY)
    tipo_carga           VARCHAR(50)     NOT NULL,
    estado_pedido        VARCHAR(30)     NOT NULL,

    -- measures (additive)
    peso_kg              DECIMAL(10,2)   NOT NULL,
    volumen_m3           DECIMAL(8,2)    NULL,
    valor_declarado       DECIMAL(12,2)   NULL,

    -- measure (semi-additive: valid to average/analyze, not to sum across time)
    dias_lead_time        AS DATEDIFF(DAY, fecha_pedido_real, fecha_requerida_real) PERSISTED,

    fecha_carga           DATETIME2(0)    NOT NULL CONSTRAINT DF_FactPedido_FechaCarga DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT PK_Fact_Pedido PRIMARY KEY NONCLUSTERED (pedido_id)
)
ON [ANALYTICS];
GO

-- Fact tables are queried mostly by time range + dimension slice, so the
-- clustered index goes on the primary time key, not on the PK.
CREATE CLUSTERED INDEX CIX_Fact_Pedido_TiempoPedido
    ON dw.Fact_Pedido (tiempo_pedido_sk)
    ON [ANALYTICS];
GO

CREATE NONCLUSTERED INDEX IX_Fact_Pedido_Cliente ON dw.Fact_Pedido (cliente_sk) ON [ANALYTICS];
CREATE NONCLUSTERED INDEX IX_Fact_Pedido_Ruta    ON dw.Fact_Pedido (ruta_sk)    ON [ANALYTICS];
GO

/* ============================================================================
   FACT_ENTREGA
   ----------------------------------------------------------------------------
   conductor_sk and vehiculo_sk are resolved at load time via
   flota.ASIGNACION_VEHICULO, matched to the order's pedido_id AND validated
   so fecha_salida (or fecha_entrega_real as fallback) falls inside
   [fecha_inicio, fecha_fin] of the assignment. See 03_scd2_load_procedure.sql
   for the exact point-in-time join logic and why a naive "latest assignment"
   join would silently misattribute deliveries to the wrong driver.
   ============================================================================ */
CREATE TABLE dw.Fact_Entrega
(
    entrega_id            INT             NOT NULL,                   -- degenerate dimension
    pedido_id              INT             NOT NULL,                   -- degenerate dimension, links back to Fact_Pedido

    cliente_sk             INT             NOT NULL CONSTRAINT FK_FactEntrega_Cliente    REFERENCES dw.Dim_Cliente(cliente_sk),
    conductor_sk            INT             NULL     CONSTRAINT FK_FactEntrega_Conductor  REFERENCES dw.Dim_Conductor(conductor_sk),
    vehiculo_sk             INT             NULL     CONSTRAINT FK_FactEntrega_Vehiculo   REFERENCES dw.Dim_Vehiculo(vehiculo_sk),
    ruta_sk                 INT             NOT NULL CONSTRAINT FK_FactEntrega_Ruta       REFERENCES dw.Dim_Ruta(ruta_sk),
    estado_entrega_sk        INT             NOT NULL CONSTRAINT FK_FactEntrega_Estado     REFERENCES dw.Dim_EstadoEntrega(estado_entrega_sk),

    tiempo_salida_sk         INT             NULL     CONSTRAINT FK_FactEntrega_TSalida    REFERENCES dw.Dim_Tiempo(tiempo_sk),
    tiempo_entrega_est_sk     INT             NOT NULL CONSTRAINT FK_FactEntrega_TEst       REFERENCES dw.Dim_Tiempo(tiempo_sk),
    tiempo_entrega_real_sk    INT             NULL     CONSTRAINT FK_FactEntrega_TReal      REFERENCES dw.Dim_Tiempo(tiempo_sk),

    -- NOTE: conductor_sk and vehiculo_sk are NULLable on purpose. Not every
    -- ENTREGA row will resolve to a clean assignment (this is itself a data
    -- quality metric fed into 11-data-quality's completeness dimension).
    -- A load that resolved a driver/vehicle is flagged below.
    asignacion_resuelta     BIT             NOT NULL,

    -- measures
    tiempo_demora_min        INT             NULL,                      -- source column, negative = early
    cumplio_sla_flag         BIT             NOT NULL,                  -- 1 = fecha_entrega_real <= fecha_entrega_est

    fecha_carga             DATETIME2(0)    NOT NULL CONSTRAINT DF_FactEntrega_FechaCarga DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT PK_Fact_Entrega PRIMARY KEY NONCLUSTERED (entrega_id)
)
ON [ANALYTICS];
GO

CREATE CLUSTERED INDEX CIX_Fact_Entrega_TiempoEst
    ON dw.Fact_Entrega (tiempo_entrega_est_sk)
    ON [ANALYTICS];
GO

CREATE NONCLUSTERED INDEX IX_Fact_Entrega_Conductor ON dw.Fact_Entrega (conductor_sk) ON [ANALYTICS];
CREATE NONCLUSTERED INDEX IX_Fact_Entrega_Vehiculo  ON dw.Fact_Entrega (vehiculo_sk)  ON [ANALYTICS];
CREATE NONCLUSTERED INDEX IX_Fact_Entrega_Pedido    ON dw.Fact_Entrega (pedido_id)    ON [ANALYTICS];
GO

/* ============================================================================
   FACT_INCIDENTE
   ----------------------------------------------------------------------------
   Same point-in-time resolution problem as Fact_Entrega applies here, with
   higher stakes: this fact is the analytical (aggregate/trend) counterpart
   to the row-level legal reconstruction done in 07_incident_reconstruction.sql
   against the Data Vault. This fact answers "how many incidents by driver/
   route/month", NOT "produce the evidentiary chain for incident #4521" -
   that is a Data Vault job, on purpose (see adr_datavault_vs_kimball.md).
   ============================================================================ */
CREATE TABLE dw.Fact_Incidente
(
    incidente_id           INT             NOT NULL,                   -- degenerate dimension
    pedido_id               INT             NULL,                       -- degenerate dimension, nullable per source (INCIDENTE.pedido_id is nullable)

    cliente_sk              INT             NULL     CONSTRAINT FK_FactIncidente_Cliente   REFERENCES dw.Dim_Cliente(cliente_sk),
    conductor_sk             INT             NULL     CONSTRAINT FK_FactIncidente_Conductor REFERENCES dw.Dim_Conductor(conductor_sk),
    vehiculo_sk              INT             NULL     CONSTRAINT FK_FactIncidente_Vehiculo  REFERENCES dw.Dim_Vehiculo(vehiculo_sk),
    ruta_sk                  INT             NULL     CONSTRAINT FK_FactIncidente_Ruta      REFERENCES dw.Dim_Ruta(ruta_sk),
    tiempo_incidente_sk       INT             NOT NULL CONSTRAINT FK_FactIncidente_Tiempo    REFERENCES dw.Dim_Tiempo(tiempo_sk),

    -- degenerate attributes
    tipo_incidente           VARCHAR(50)     NOT NULL,                  -- accidente / robo / demora / daño
    severidad                VARCHAR(20)     NOT NULL,
    estado_resolucion         VARCHAR(30)     NOT NULL,

    -- measures
    costo_estimado            DECIMAL(12,2)   NULL,
    dias_hasta_resolucion      INT             NULL,

    fecha_carga              DATETIME2(0)    NOT NULL CONSTRAINT DF_FactIncidente_FechaCarga DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT PK_Fact_Incidente PRIMARY KEY NONCLUSTERED (incidente_id)
)
ON [ANALYTICS];
GO

CREATE CLUSTERED INDEX CIX_Fact_Incidente_Tiempo
    ON dw.Fact_Incidente (tiempo_incidente_sk)
    ON [ANALYTICS];
GO

CREATE NONCLUSTERED INDEX IX_Fact_Incidente_Conductor ON dw.Fact_Incidente (conductor_sk) ON [ANALYTICS];
CREATE NONCLUSTERED INDEX IX_Fact_Incidente_Vehiculo  ON dw.Fact_Incidente (vehiculo_sk)  ON [ANALYTICS];
GO

/* ============================================================================
   These three fact tables are created here EMPTY (structure only), same as
   the dimensions in 01_star_schema_dimensions.sql. They are populated by
   03_scd2_load_procedure.sql, which also contains the point-in-time join
   logic against flota.ASIGNACION_VEHICULO described above.
   ============================================================================ */

