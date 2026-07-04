-- =============================================================================
-- FILE: 04_data_lineage.sql
-- PROJECT: P02 - Data Governance Architecture | TRANSTRACK
-- =============================================================================

USE TRANSTRACK;
GO

-- =============================================================================
-- SECTION 1: DATA_LINEAGE table in governance_control
-- =============================================================================

IF OBJECT_ID('governance_control.DATA_LINEAGE', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_LINEAGE;
GO

-- Drop child first, then parent
IF OBJECT_ID('governance_control.DATA_LINEAGE_EXECUTION', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_LINEAGE_EXECUTION;
GO


CREATE TABLE governance_control.DATA_LINEAGE (
    lineage_id              INT IDENTITY(1,1)   NOT NULL,
    flow_name               NVARCHAR(100)       NOT NULL,
    flow_description        NVARCHAR(500)       NOT NULL,
    -- Source
    source_system           NVARCHAR(100)       NOT NULL,
    source_schema           NVARCHAR(128)       NULL,
    source_table            NVARCHAR(128)       NOT NULL,
    source_columns          NVARCHAR(MAX)       NULL,
    -- Transformation
    transformation_type     NVARCHAR(30)        NOT NULL
                            CONSTRAINT chk_lineage_transform
                            CHECK (transformation_type IN
                                ('DIRECT','ETL','API','MANUAL','TRIGGER','REPLICATION','EVENT')),
    transformation_logic    NVARCHAR(MAX)       NULL,
    -- Destination
    destination_system      NVARCHAR(100)       NOT NULL,
    destination_schema      NVARCHAR(128)       NULL,
    destination_table       NVARCHAR(128)       NOT NULL,
    destination_columns     NVARCHAR(MAX)       NULL,
    -- Flow characteristics
    flow_frequency          NVARCHAR(20)        NOT NULL
                            CONSTRAINT chk_lineage_frequency
                            CHECK (flow_frequency IN
                                ('REALTIME','HOURLY','DAILY','WEEKLY','MONTHLY','ON_DEMAND','EVENT')),
    data_classification     NVARCHAR(30)        NOT NULL
                            CONSTRAINT chk_lineage_classification
                            CHECK (data_classification IN
                                ('PUBLIC','OPERATIONAL','PII','FINANCIAL_CRITICAL')),
    avg_records_per_run     INT                 NULL,
    peak_records_per_run    INT                 NULL,
    has_data_validation     BIT                 NOT NULL DEFAULT 0,
    validation_description  NVARCHAR(300)       NULL,
    -- Problem flags from Week 02 diagnosis
    has_known_issues        BIT                 NOT NULL DEFAULT 0,
    known_issues_desc       NVARCHAR(500)       NULL,
    flow_owner              NVARCHAR(100)       NOT NULL,
    is_active               BIT                 NOT NULL DEFAULT 1,
    created_at              DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    created_by              NVARCHAR(100)       NOT NULL DEFAULT SYSTEM_USER,
    last_verified_date      DATE                NULL,
    CONSTRAINT PK_DATA_LINEAGE PRIMARY KEY CLUSTERED (lineage_id),
    CONSTRAINT UQ_DATA_LINEAGE_FLOW UNIQUE (flow_name)
);
GO

-- =============================================================================
-- SECTION 2: LINEAGE EXECUTION LOG
-- =============================================================================

IF OBJECT_ID('governance_control.DATA_LINEAGE_EXECUTION', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_LINEAGE_EXECUTION;
GO

CREATE TABLE governance_control.DATA_LINEAGE_EXECUTION (
    execution_id        INT IDENTITY(1,1)   NOT NULL,
    lineage_id          INT                 NOT NULL,
    execution_start     DATETIME2           NOT NULL,
    execution_end       DATETIME2           NULL,
    status              NVARCHAR(20)        NOT NULL DEFAULT 'RUNNING'
                        CONSTRAINT chk_exec_status
                        CHECK (status IN ('RUNNING','SUCCESS','FAILED','PARTIAL')),
    records_processed   INT                 NULL,
    records_rejected    INT                 NULL DEFAULT 0,
    error_message       NVARCHAR(MAX)       NULL,
    executed_by         NVARCHAR(100)       NOT NULL DEFAULT SYSTEM_USER,
    CONSTRAINT PK_LINEAGE_EXECUTION PRIMARY KEY CLUSTERED (execution_id),
    CONSTRAINT FK_LINEAGE_EXEC FOREIGN KEY (lineage_id)
        REFERENCES governance_control.DATA_LINEAGE (lineage_id)
);
GO

-- =============================================================================
-- SECTION 3: POPULATE REAL LINEAGE FLOWS
-- =============================================================================

-- FLOW 1: ventas.CLIENTE → operaciones.PEDIDO
-- Orders reference client_id from ventas schema
INSERT INTO governance_control.DATA_LINEAGE (
    flow_name, flow_description,
    source_system, source_schema, source_table, source_columns,
    transformation_type, transformation_logic,
    destination_system, destination_schema, destination_table, destination_columns,
    flow_frequency, data_classification, avg_records_per_run,
    has_data_validation, has_known_issues, known_issues_desc,
    flow_owner, last_verified_date)
VALUES (
    'VENTAS_CLIENTE_TO_PEDIDO',
    'Orders in operaciones.PEDIDO reference cliente_id from ventas.CLIENTE. '
    + 'No cross-module validation: if ventas.CLIENTE is duplicated, PEDIDO inherits wrong client.',
    'VENTAS', 'ventas', 'CLIENTE',
    'cliente_id, nit, nombre, categoria',
    'DIRECT',
    'FK constraint: operaciones.PEDIDO.cliente_id → ventas.CLIENTE.cliente_id. '
    + 'No validation that nit in ventas matches nit in facturacion for the same business entity.',
    'OPERACIONES', 'operaciones', 'PEDIDO',
    'pedido_id, cliente_id, ruta_id, estado, fecha_pedido',
    'EVENT', 'OPERATIONAL', 1500,
    0,
    1, 'Week 02 finding: ventas.CLIENTE has duplicate NITs across records. '
     + 'Orders referencing these duplicates cannot be reconciled to a unique client for reporting.',
    'Operations Director', CAST(GETDATE() AS DATE));
GO

-- FLOW 2: operaciones.ENTREGA → facturacion.FACTURA
-- Deliveries trigger invoice creation — the billing integration point
INSERT INTO governance_control.DATA_LINEAGE (
    flow_name, flow_description,
    source_system, source_schema, source_table, source_columns,
    transformation_type, transformation_logic,
    destination_system, destination_schema, destination_table, destination_columns,
    flow_frequency, data_classification, avg_records_per_run,
    has_data_validation, validation_description,
    has_known_issues, known_issues_desc,
    flow_owner, last_verified_date)
VALUES (
    'ENTREGA_TO_FACTURA',
    'Confirmed deliveries (estado_entrega=ENTREGADO) in operaciones.ENTREGA trigger invoice '
    + 'creation in facturacion.FACTURA. This is the revenue recognition control point.',
    'OPERACIONES', 'operaciones', 'ENTREGA',
    'entrega_id, pedido_id, fecha_entrega_real, estado_entrega, firma_receptor',
    'ETL',
    'Nightly batch reads operaciones.ENTREGA WHERE estado_entrega = ''ENTREGADO'' '
    + 'and inserts into facturacion.FACTURA. References facturacion.CLIENTE via pedido→ventas.CLIENTE NIT lookup.',
    'FACTURACION', 'facturacion', 'FACTURA',
    'factura_id, pedido_id, cliente_fact_id, subtotal, impuesto, total, estado_pago',
    'DAILY', 'FINANCIAL_CRITICAL', 1300,
    1, 'Validates pedido_id exists before inserting. Does NOT validate cliente_fact_id matches '
     + 'the same business entity as operaciones.PEDIDO.cliente_id.',
    1, 'CRITICAL - Week 02 intentional problem: facturacion.FACTURA.pedido_id is NULLABLE. '
     + 'Some invoices created without linked order (orphan invoices). '
     + 'Additionally: no UNIQUE constraint on numero_factura allows duplicate invoice numbers. '
     + 'Financial exposure: unquantified until Week 03 diagnostic query runs.',
    'CFO / Billing Manager', CAST(GETDATE() AS DATE));
GO

-- FLOW 3: flota.TELEMETRIA_GPS → operaciones.PEDIDO (the missing link)
-- GPS has vehicle but no order — the core telemetry governance gap
INSERT INTO governance_control.DATA_LINEAGE (
    flow_name, flow_description,
    source_system, source_schema, source_table, source_columns,
    transformation_type, transformation_logic,
    destination_system, destination_schema, destination_table, destination_columns,
    flow_frequency, data_classification, avg_records_per_run, peak_records_per_run,
    has_data_validation,
    has_known_issues, known_issues_desc,
    flow_owner, last_verified_date)
VALUES (
    'TELEMETRIA_GPS_TO_ORDER_CONTEXT',
    'GPS units on 800 trucks transmit coordinates every 5 minutes into flota.TELEMETRIA_GPS. '
    + 'System SHOULD update order ETA and alert on route deviations. Currently: no formal link exists.',
    'GPS_SYSTEM', 'flota', 'TELEMETRIA_GPS',
    'telemetria_id, vehiculo_id, fecha_hora, latitud, longitud, velocidad_kmh, evento',
    'REALTIME',
    'GPS vendor pushes via HTTP to SQL Server insert. '
    + 'flota.TELEMETRIA_GPS.vehiculo_id is INT but has NO FK to flota.VEHICULO (intentional Week 02). '
    + 'There is NO pedido_id in TELEMETRIA_GPS — cannot link GPS record to active order.',
    'OPERACIONES', 'operaciones', 'PEDIDO',
    'pedido_id, estado',
    'REALTIME', 'OPERATIONAL', 2400, 4800,
    0,
    1, 'CRITICAL Week 02 finding: flota.TELEMETRIA_GPS has vehiculo_id (no FK) but NO pedido_id. '
     + 'Cannot determine which cargo was on vehicle at any GPS timestamp. '
     + 'Legal risk: incident investigation cannot reconstruct vehicle→order→client chain. '
     + 'Resolution: Week 10 Data Vault will implement temporal join via flota.ASIGNACION_VEHICULO.',
    'Fleet Manager / CTO', CAST(GETDATE() AS DATE));
GO

-- FLOW 4: flota.CONDUCTOR/EMPLEADO/OPERADOR → governance_control.MASTER_CONDUCTOR
INSERT INTO governance_control.DATA_LINEAGE (
    flow_name, flow_description,
    source_system, source_schema, source_table, source_columns,
    transformation_type, transformation_logic,
    destination_system, destination_schema, destination_table, destination_columns,
    flow_frequency, data_classification,
    has_data_validation, validation_description,
    has_known_issues, known_issues_desc,
    flow_owner, last_verified_date)
VALUES (
    'DRIVER_FRAGMENTED_TO_MASTER',
    'Three fragmented driver tables (flota.CONDUCTOR, flota.EMPLEADO, flota.OPERADOR) '
    + 'are consolidated into governance_control.MASTER_CONDUCTOR as a single golden record.',
    'FLOTA', 'flota', 'CONDUCTOR',
    'conductor_id, numero_licencia, nombre, apellido, categoria_licencia, fecha_vencimiento_licencia',
    'ETL',
    'Week 05 consolidation script 02_driver_consolidation.sql. '
    + 'Survivorship: CONDUCTOR wins for license data, EMPLEADO wins for employment data. '
    + 'No common key between tables — name matching required.',
    'GOVERNANCE', 'governance_control', 'MASTER_CONDUCTOR',
    'master_conductor_id, numero_licencia, primer_nombre, primer_apellido, categoria_licencia',
    'DAILY', 'PII',
    1, 'License expiry validated; expired licenses flagged for Fleet Manager alert.',
    1, 'Week 02 finding: CONDUCTOR, EMPLEADO, OPERADOR have NO common key. '
     + 'flota.OPERADOR.vehiculo_asignado is VARCHAR (plate text), not FK to flota.VEHICULO. '
     + 'Name matching is the only available link — confidence varies 50-100%.',
    'HR Manager / Data Steward', CAST(GETDATE() AS DATE));
GO

-- FLOW 5: ventas.CLIENTE + facturacion.CLIENTE → governance_control.MASTER_CLIENTE
INSERT INTO governance_control.DATA_LINEAGE (
    flow_name, flow_description,
    source_system, source_schema, source_table, source_columns,
    transformation_type, transformation_logic,
    destination_system, destination_schema, destination_table, destination_columns,
    flow_frequency, data_classification,
    has_data_validation, validation_description,
    has_known_issues, known_issues_desc,
    flow_owner, last_verified_date)
VALUES (
    'CLIENT_DUAL_MODULE_TO_MASTER',
    'ventas.CLIENTE (nombre, ciudad, categoria) and facturacion.CLIENTE (razon_social, limite_credito) '
    + 'represent the same business entities with different column names and no FK between them. '
    + 'Consolidated into governance_control.MASTER_CLIENTE via NIT matching.',
    'VENTAS+FACTURACION', 'ventas', 'CLIENTE',
    'cliente_id, nit, nombre, email, telefono, ciudad, categoria',
    'ETL',
    'Week 05 deduplication script 03_client_deduplication.sql. '
    + 'ventas.CLIENTE wins for business data. facturacion.CLIENTE enriches with credit terms. '
    + 'NIT is the matching key; phonetic matching for cases with NIT discrepancies.',
    'GOVERNANCE', 'governance_control', 'MASTER_CLIENTE',
    'master_cliente_id, nit, nombre, email, ciudad, categoria, limite_credito',
    'DAILY', 'PII',
    1, 'NIT validated (min 6 chars); duplicate NITs within same module flagged for steward review.',
    1, 'Week 02 finding: ventas.CLIENTE.nombre vs facturacion.CLIENTE.razon_social '
     + 'are different column names for the same data. No FK between modules. '
     + 'facturacion.CLIENTE has no ciudad column. ventas.CLIENTE has no limite_credito column.',
    'Data Governance Lead', CAST(GETDATE() AS DATE));
GO

-- =============================================================================
-- SECTION 4: IMPACT ANALYSIS VIEW AND PROCEDURE
-- =============================================================================

CREATE OR ALTER VIEW governance_control.vw_lineage_impact_map
AS
    SELECT
        dl.flow_name,
        dl.source_schema + '.' + dl.source_table       AS source_full,
        dl.transformation_type,
        dl.destination_schema + '.' + dl.destination_table AS destination_full,
        dl.flow_frequency,
        dl.data_classification,
        dl.has_known_issues,
        dl.known_issues_desc,
        dl.flow_owner,
        dl.last_verified_date,
        DATEDIFF(DAY, dl.last_verified_date, CAST(GETDATE() AS DATE)) AS days_since_verification,
        CASE
            WHEN dl.last_verified_date IS NULL THEN 'NEVER_VERIFIED'
            WHEN DATEDIFF(DAY, dl.last_verified_date, CAST(GETDATE() AS DATE)) > 180 THEN 'STALE'
            WHEN DATEDIFF(DAY, dl.last_verified_date, CAST(GETDATE() AS DATE)) > 90  THEN 'DUE_REVIEW'
            ELSE 'CURRENT'
        END AS verification_status
    FROM governance_control.DATA_LINEAGE dl
    WHERE dl.is_active = 1;
GO

CREATE OR ALTER PROCEDURE governance_control.usp_get_downstream_impact
    @source_table   NVARCHAR(128),
    @source_schema  NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        flow_name,
        source_full,
        transformation_type,
        destination_full,
        data_classification,
        has_known_issues,
        flow_owner
    FROM governance_control.vw_lineage_impact_map
    WHERE source_full LIKE '%' + @source_table + '%'
       OR (@source_schema IS NOT NULL AND source_full LIKE @source_schema + '.%')
    ORDER BY data_classification DESC;
END;
GO

-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT flow_name, source_schema + '.' + source_table AS source,
       destination_schema + '.' + destination_table AS destination,
       data_classification, has_known_issues
FROM governance_control.DATA_LINEAGE
ORDER BY data_classification DESC;
GO

SELECT * FROM governance_control.vw_lineage_impact_map ORDER BY data_classification DESC;
GO

EXEC governance_control.usp_get_downstream_impact @source_table = 'ENTREGA', @source_schema = 'operaciones';
GO
