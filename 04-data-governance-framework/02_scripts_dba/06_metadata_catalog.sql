/*
=============================================================================
  TRANSTRACK — Data Governance Architecture
  Script:  06_metadata_catalog.sql
  Purpose: Implement formal metadata management (DAMA Ch.12).
           Create DATA_CATALOG and COLUMN_CATALOG. Populate from
           INFORMATION_SCHEMA and sys objects. DDL trigger to keep catalog
           current. Executive metadata report procedure.
Validated by: Carlos Blanco
  Ref:     DAMA-DMBOK 2nd Ed. Ch.12 — Metadata Management
           ISO 27001:2022 A.5.9 — Inventory of information assets
           Inside Out SQL Server 2022, Ch.7 — INFORMATION_SCHEMA, sys objects
           https://learn.microsoft.com/en-us/sql/relational-databases/
                   system-information-schema-views/system-information-schema-views
  Depends: 01_domains_ownership.sql, 03_classification.sql
=============================================================================

  METADATA STRATEGY — THREE TYPES (DAMA Ch.12):
  
  TECHNICAL METADATA:  Captured from sys.tables, sys.columns, sys.indexes.
                       Data types, constraints, sizes, partitioning.
  
  BUSINESS METADATA:   Manually curated descriptions, quality rules, SLAs.
                       Populated in this script with formal business definitions.
                       This is the business glossary.
  
  OPERATIONAL METADATA: Runtime statistics — row counts, last updated,
                        query frequency. Populated from sys.dm_db_index_usage_stats
                        and sys.partitions.

=============================================================================
*/

USE TRANSTRACK;
GO

-- =============================================================================
-- SECTION 0: METADATA SCHEMA
-- DATA_CATALOG, COLUMN_CATALOG, and related metadata objects live in the
-- metadata_catalog schema — separate from governance_control (Scripts 01-05)
-- because cataloging (inventory and business glossary) is conceptually
-- distinct from governance enforcement (policy, classification, access
-- control). This script reads from governance_control (DOMAIN_TABLE_REGISTRY,
-- DATA_OWNER, DATA_STEWARD, DATA_CLASSIFICATION) but writes to metadata_catalog.
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'metadata_catalog')
    EXEC('CREATE SCHEMA metadata_catalog');
GO

-- =============================================================================
-- SECTION 1: DATA_CATALOG TABLE (Table-level metadata)
-- =============================================================================

IF OBJECT_ID('metadata_catalog.DATA_CATALOG', 'U') IS NOT NULL
    DROP TABLE metadata_catalog.DATA_CATALOG;
GO

CREATE TABLE metadata_catalog.DATA_CATALOG
(
    catalog_id              INT             NOT NULL IDENTITY(1,1),
    -- Technical metadata
    table_schema            SYSNAME         NOT NULL,
    table_name              SYSNAME         NOT NULL,
    table_type              VARCHAR(30)     NOT NULL,   -- TABLE | VIEW | PARTITION
    filegroup_name          SYSNAME         NULL,       -- PRIMARY | ANALYTICS | ARCHIVE
    -- Governance metadata (from governance framework)
    domain                  VARCHAR(20)     NULL,
    owner                   NVARCHAR(200)   NULL,
    steward                 NVARCHAR(200)   NULL,
    classification_level    VARCHAR(30)     NULL,
    -- Business metadata
    description_business    NVARCHAR(1000)  NULL,
    description_technical   NVARCHAR(1000)  NULL,
    business_key            NVARCHAR(200)   NULL,       -- What uniquely identifies a row
    -- Operational metadata
    row_count_approx        BIGINT          NULL,
    size_mb                 DECIMAL(10,2)   NULL,
    last_updated            DATETIME2       NULL,
    -- SLA and retention
    sla_freshness_hours     INT             NULL,       -- How stale is acceptable (NULL = no SLA)
    retention_days          INT             NULL,       -- From POLICY-002
    is_partitioned          BIT             NOT NULL    DEFAULT 0,
    -- Catalog management
    catalog_version         VARCHAR(10)     NOT NULL    DEFAULT '1.0',
    catalog_created         DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    catalog_updated         DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_DATA_CATALOG PRIMARY KEY (catalog_id),
    CONSTRAINT UQ_DC_TABLE UNIQUE (table_schema, table_name)
);
GO

-- =============================================================================
-- SECTION 2: COLUMN_CATALOG TABLE (Column-level metadata = business glossary)
-- =============================================================================

IF OBJECT_ID('metadata_catalog.COLUMN_CATALOG', 'U') IS NOT NULL
    DROP TABLE metadata_catalog.COLUMN_CATALOG;
GO

CREATE TABLE metadata_catalog.COLUMN_CATALOG
(
    column_catalog_id       INT             NOT NULL IDENTITY(1,1),
    -- Technical metadata from sys.columns
    table_schema            SYSNAME         NOT NULL,
    table_name              SYSNAME         NOT NULL,
    column_name             SYSNAME         NOT NULL,
    ordinal_position        INT             NOT NULL,
    data_type               VARCHAR(50)     NOT NULL,
    max_length              INT             NULL,
    is_nullable             BIT             NOT NULL    DEFAULT 1,
    has_default             BIT             NOT NULL    DEFAULT 0,
    is_identity             BIT             NOT NULL    DEFAULT 0,
    is_primary_key          BIT             NOT NULL    DEFAULT 0,
    is_foreign_key          BIT             NOT NULL    DEFAULT 0,
    -- Business metadata (the glossary — written for non-technical readers)
    description_business    NVARCHAR(500)   NULL,
    source_system           VARCHAR(100)    NULL,       -- Which module/system originally owns this
    -- Quality metadata
    quality_rules           NVARCHAR(500)   NULL,       -- Human-readable quality expectation
    expected_values         NVARCHAR(200)   NULL,       -- For reference/enum columns
    -- Classification (from DATA_CLASSIFICATION)
    sensitivity_level       VARCHAR(30)     NULL,
    pii_flag                BIT             NOT NULL    DEFAULT 0,
    information_type        VARCHAR(100)    NULL,
    -- Catalog management
    catalog_created         DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    catalog_updated         DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_COLUMN_CATALOG PRIMARY KEY (column_catalog_id),
    CONSTRAINT UQ_CC_COLUMN UNIQUE (table_schema, table_name, column_name)
);
GO

-- =============================================================================
-- SECTION 3: POPULATE DATA_CATALOG FROM sys OBJECTS + GOVERNANCE METADATA
-- Technical metadata from sys; business descriptions and SLAs manually curated.
-- =============================================================================

-- Step 1: Insert technical metadata for all user tables
INSERT INTO metadata_catalog.DATA_CATALOG
    (table_schema, table_name, table_type, filegroup_name,
     domain, owner, steward, classification_level,
     description_business, description_technical, business_key,
     row_count_approx, size_mb, is_partitioned,
     sla_freshness_hours, retention_days)
SELECT
    s.name                          AS table_schema,
    t.name                          AS table_name,
    'TABLE'                         AS table_type,
    fg.name                         AS filegroup_name,
    -- Governance joins
    dtr.domain_code                 AS domain,
    do_owner.owner_name             AS owner,
    ds.steward_name                 AS steward,
    dtr.classification_level,
    -- Business and technical descriptions will be updated below
    NULL                            AS description_business,
    NULL                            AS description_technical,
    NULL                            AS business_key,
    -- Operational metadata: approximate row count
    SUM(p.rows)                     AS row_count_approx,
    -- Size from sys.allocation_units
    CAST(
        SUM(a.total_pages) * 8.0 / 1024
    AS DECIMAL(10,2))               AS size_mb,
    -- Partitioned if more than one partition
    CASE WHEN COUNT(p.partition_number) > 1 THEN 1 ELSE 0 END AS is_partitioned,
    NULL                            AS sla_freshness_hours,
    NULL                            AS retention_days
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
-- Get the filegroup for the clustered index or heap (index_id 0 or 1)
LEFT JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0, 1)
LEFT JOIN sys.filegroups fg ON i.data_space_id = fg.data_space_id
LEFT JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0, 1)
LEFT JOIN sys.allocation_units a ON p.partition_id = a.container_id
-- Governance metadata joins
LEFT JOIN governance_control.DOMAIN_TABLE_REGISTRY dtr
    ON s.name = dtr.table_schema AND t.name = dtr.table_name
LEFT JOIN governance_control.DATA_OWNER do_owner
    ON dtr.domain_code = do_owner.domain_code AND do_owner.is_active = 1
LEFT JOIN governance_control.DATA_STEWARD ds
    ON dtr.domain_code = ds.domain_code AND ds.is_active = 1
WHERE s.name IN ('ventas', 'facturacion', 'operaciones', 'flota', 'archivo')
  AND t.is_ms_shipped = 0                -- Exclude system tables
  AND t.name NOT LIKE 'DATA_%'           -- Exclude governance meta-tables from self-catalog
  AND t.name NOT LIKE 'DOMAIN_%'
  AND t.name NOT LIKE 'CLIENT_%'
  AND t.name NOT LIKE 'COLUMN_%'
GROUP BY
    s.name, t.name, fg.name,
    dtr.domain_code, do_owner.owner_name, ds.steward_name, dtr.classification_level;
GO

-- Step 2: Update business descriptions and SLAs for each table
-- This is the business glossary — written for a non-technical audience.

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'Records for every client that has ever contracted TRANSTRACK services. '
        + 'Each record represents one commercial entity (company or individual). '
        + 'KNOWN ISSUE: 15,000 records contain duplicates by NIT and similar names across Sales and Billing modules. '
        + 'Master data consolidation planned for Week 07.',
    description_technical = 'Source of truth for client identity. '
        + 'Referenced by CONTRATO_CLIENTE, FACTURA, PEDIDO. '
        + 'Contains modulo_origen to track which system inserted each record.',
    business_key = 'nit (Tax ID number)',
    sla_freshness_hours = 1,
    retention_days = 7 * 365  -- 7 years
WHERE table_name = 'CLIENTE';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'Commercial agreements between TRANSTRACK and each client. '
        + 'Defines the tariff structure, payment terms, and service type for billing purposes. '
        + 'Every invoice must trace back to a valid contract in this table.',
    description_technical = 'Contains tarifa_base and tarifa_km_adicional used by the billing engine. '
        + 'FINANCIAL_CRITICAL: changes directly affect invoice amounts.',
    business_key = 'contrato_id; (cliente_id + fecha_inicio) for uniqueness',
    sla_freshness_hours = 24,
    retention_days = 5 * 365
WHERE table_name = 'CONTRATO_CLIENTE';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'Official billing records issued to clients for services rendered. '
        + 'Each invoice should link to exactly one order. '
        + 'KNOWN ISSUE: Some invoices exist without a linked order (orphan invoices) — '
        + 'documented in Week 03 diagnostic as a data integrity failure.',
    description_technical = 'Contains es_duplicada flag to mark intentional duplicates inserted for diagnostic purposes. '
        + 'monto_total = monto_subtotal + monto_impuesto. Tax authority requires 5-year retention.',
    business_key = 'numero_factura (official invoice number for tax purposes)',
    sla_freshness_hours = 24,
    retention_days = 5 * 365
WHERE table_name = 'FACTURA';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'Every freight shipment request placed by a client since January 2019. '
        + 'An order is the central record that connects a client, a route, a vehicle, a driver, '
        + 'and eventually a delivery and an invoice.',
    description_technical = '500,000 records from 2019 to present. '
        + 'FK dependencies: CLIENTE, RUTA, VEHICULO, CONDUCTOR.',
    business_key = 'pedido_id',
    sla_freshness_hours = 1,
    retention_days = 5 * 365
WHERE table_name = 'PEDIDO';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'The defined routes between city pairs operated by TRANSTRACK. '
        + 'Reference data used to plan deliveries, calculate billing, and measure delivery performance.',
    description_technical = '2,500 city-pair routes. Relatively static — changes require Domain Owner approval.',
    business_key = 'ruta_id; (ciudad_origen + ciudad_destino) for business uniqueness',
    sla_freshness_hours = 168,  -- Weekly SLA — routes rarely change
    retention_days = 3 * 365
WHERE table_name = 'RUTA';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'Records the actual completion of each freight order — when it arrived, '
        + 'who received it, and whether an incident occurred. '
        + 'This is the operational evidence that TRANSTRACK delivered what the client paid for.',
    description_technical = '480,000 records. Some orders have no corresponding delivery — '
        + 'these are in-transit or cancelled orders.',
    business_key = 'entrega_id; pedido_id (one-to-one)',
    sla_freshness_hours = 2,
    retention_days = 5 * 365
WHERE table_name = 'ENTREGA';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'All recorded accidents, thefts, delays, and cargo damage events. '
        + 'This is the highest-stakes table for legal and insurance purposes. '
        + 'KNOWN ISSUE: Some incidents cannot be linked to a specific driver because '
        + 'driver identity is fragmented across three tables.',
    description_technical = '8,500 records. Legal hold applies to records under active investigation. '
        + 'conductor_id references CONDUCTOR table — fragmented identity means not all incidents '
        + 'have a resolvable driver.',
    business_key = 'incidente_id',
    sla_freshness_hours = 1,
    retention_days = 10 * 365  -- 10 years per POLICY-002
WHERE table_name = 'INCIDENTE';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'The 800 trucks operated by TRANSTRACK. '
        + 'Tracks asset details, capacity, and operational status.',
    description_technical = 'Vehicle assignment history maintained through PEDIDO and ENTREGA references. '
        + 'valor_adquisicion used for asset accounting.',
    business_key = 'vehiculo_id; placa (license plate)',
    sla_freshness_hours = 24,
    retention_days = 5 * 365
WHERE table_name = 'VEHICULO';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'Primary driver records from the Operations module. '
        + 'KNOWN ISSUE: Driver identity exists in three separate tables (CONDUCTOR, EMPLEADO, OPERADOR) '
        + 'with no common key. This makes it impossible to definitively identify a driver across systems. '
        + 'Master data consolidation planned for Week 07.',
    description_technical = 'Contains numero_licencia as the business key candidate. '
        + 'DPI is the government identity document. Neither field is shared with EMPLEADO or OPERADOR.',
    business_key = 'numero_licencia (driver license number — government issued)',
    sla_freshness_hours = 24,
    retention_days = 7 * 365
WHERE table_name = 'CONDUCTOR';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'HR records for drivers as employees of TRANSTRACK. '
        + 'Part of the fragmented driver identity problem — same drivers exist here as in CONDUCTOR and OPERADOR.',
    description_technical = 'Managed by HR system. Contains salary data (financial PII). '
        + 'No FK to CONDUCTOR despite representing the same population.',
    business_key = 'codigo_empleado (HR system code — not shared across systems)',
    sla_freshness_hours = 24,
    retention_days = 7 * 365
WHERE table_name = 'EMPLEADO';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = 'System access records for drivers in the operational platform. '
        + 'Third fragment of the driver identity problem.',
    description_technical = 'Managed by the operations application. Contains application credentials and '
        + 'device assignments. No FK to CONDUCTOR or EMPLEADO.',
    business_key = 'codigo_sistema (application login — not shared across systems)',
    sla_freshness_hours = 1,
    retention_days = 7 * 365
WHERE table_name = 'OPERADOR';

UPDATE metadata_catalog.DATA_CATALOG SET
    description_business = '50 million GPS coordinates recorded every 5 minutes from each vehicle since 2021. '
        + 'This is TRANSTRACK''s audit trail of all vehicle movements — essential for incident investigation, '
        + 'insurance claims, and route performance analysis.',
    description_technical = 'Partitioned by year and month. ARCHIVE filegroup holds data older than 3 years. '
        + 'GPS coordinates linked to conductor_id constitute personal data under GDPR. '
        + 'This table has no formal FK to PEDIDO — a known governance gap.',
    business_key = 'telemetria_id; (vehiculo_id + fecha_registro) for functional uniqueness',
    sla_freshness_hours = NULL,  -- Real-time ingestion — no freshness SLA, just availability
    retention_days = 3 * 365,    -- Active; then archived, not deleted
    is_partitioned = 1
WHERE table_name = 'TELEMETRIA_GPS';
GO

-- =============================================================================
-- SECTION 4: POPULATE COLUMN_CATALOG FROM INFORMATION_SCHEMA
-- Technical metadata is pulled automatically; business descriptions come from
-- DATA_CLASSIFICATION which was populated in Script 03.
-- =============================================================================

INSERT INTO metadata_catalog.COLUMN_CATALOG
    (table_schema, table_name, column_name, ordinal_position,
     data_type, max_length, is_nullable, has_default, is_identity,
     is_primary_key, is_foreign_key,
     description_business, source_system,
     quality_rules, expected_values,
     sensitivity_level, pii_flag, information_type)
SELECT
    c.TABLE_SCHEMA          AS table_schema,
    c.TABLE_NAME            AS table_name,
    c.COLUMN_NAME           AS column_name,
    c.ORDINAL_POSITION,
    c.DATA_TYPE             AS data_type,
    c.CHARACTER_MAXIMUM_LENGTH AS max_length,
    CASE WHEN c.IS_NULLABLE = 'YES' THEN 1 ELSE 0 END AS is_nullable,
    CASE WHEN c.COLUMN_DEFAULT IS NOT NULL THEN 1 ELSE 0 END AS has_default,
    -- is_identity: check sys.columns
    CASE WHEN sc.is_identity = 1 THEN 1 ELSE 0 END AS is_identity,
    -- is_primary_key: check sys.index_columns and sys.indexes
    CASE WHEN pk_check.column_name IS NOT NULL THEN 1 ELSE 0 END AS is_primary_key,
    -- is_foreign_key: check sys.foreign_key_columns
    CASE WHEN fk_check.column_name IS NOT NULL THEN 1 ELSE 0 END AS is_foreign_key,
    -- Business description from DATA_CLASSIFICATION (justification field)
    dc.justification        AS description_business,
    -- Source system: from DOMAIN_TABLE_REGISTRY notes (simplified)
    CASE
        WHEN dtr.notes LIKE '%ventas%' OR dtr.notes LIKE '%Sales%' THEN 'Sales Module'
        WHEN dtr.notes LIKE '%facturac%' OR dtr.notes LIKE '%Billing%' THEN 'Billing Module'
        WHEN dtr.notes LIKE '%operac%' OR dtr.notes LIKE '%Operations%' THEN 'Operations Module'
        WHEN dtr.notes LIKE '%HR%' OR dtr.notes LIKE '%RRHH%' THEN 'HR System'
        ELSE 'TRANSTRACK Core'
    END                     AS source_system,
    -- Quality rules: derive from classification
    CASE dc.classification_level
        WHEN 'PII'                  THEN 'Must not be NULL. Must not be blank. Access logged on every read.'
        WHEN 'FINANCIAL_CRITICAL'   THEN 'Must not be NULL for posted records. Value must be non-negative. Changes require audit trail.'
        WHEN 'OPERATIONAL_SENSITIVE' THEN 'NULL allowed per column definition. Referential integrity enforced where FK exists.'
        ELSE 'No quality rules beyond data type constraints.'
    END                     AS quality_rules,
    NULL                    AS expected_values,    -- Populated manually for reference columns
    -- Classification from DATA_CLASSIFICATION
    dc.classification_level AS sensitivity_level,
    CASE WHEN dc.classification_level = 'PII' THEN 1 ELSE 0 END AS pii_flag,
    dc.information_type
FROM INFORMATION_SCHEMA.COLUMNS c
-- Join to sys.columns for is_identity
JOIN sys.tables st ON st.name = c.TABLE_NAME
JOIN sys.schemas ss ON ss.schema_id = st.schema_id AND ss.name = c.TABLE_SCHEMA
JOIN sys.columns sc ON sc.object_id = st.object_id AND sc.name = c.COLUMN_NAME
-- Primary key check
LEFT JOIN (
    SELECT
        s2.name AS schema_name,
        t2.name AS table_name,
        c2.name AS column_name
    FROM sys.index_columns ic
    JOIN sys.indexes idx ON ic.object_id = idx.object_id AND ic.index_id = idx.index_id
    JOIN sys.tables t2 ON idx.object_id = t2.object_id
    JOIN sys.schemas s2 ON t2.schema_id = s2.schema_id
    JOIN sys.columns c2 ON ic.object_id = c2.object_id AND ic.column_id = c2.column_id
    WHERE idx.is_primary_key = 1
) pk_check ON pk_check.schema_name = c.TABLE_SCHEMA
          AND pk_check.table_name = c.TABLE_NAME
          AND pk_check.column_name = c.COLUMN_NAME
-- Foreign key check
LEFT JOIN (
    SELECT
        s3.name AS schema_name,
        t3.name AS table_name,
        c3.name AS column_name
    FROM sys.foreign_key_columns fkc
    JOIN sys.tables t3 ON fkc.parent_object_id = t3.object_id
    JOIN sys.schemas s3 ON t3.schema_id = s3.schema_id
    JOIN sys.columns c3 ON fkc.parent_object_id = c3.object_id
                        AND fkc.parent_column_id = c3.column_id
) fk_check ON fk_check.schema_name = c.TABLE_SCHEMA
          AND fk_check.table_name = c.TABLE_NAME
          AND fk_check.column_name = c.COLUMN_NAME
-- Classification from DATA_CLASSIFICATION
LEFT JOIN governance_control.DATA_CLASSIFICATION dc
    ON dc.schema_name = c.TABLE_SCHEMA
    AND dc.table_name = c.TABLE_NAME
    AND dc.column_name = c.COLUMN_NAME
-- Domain registry for source system
LEFT JOIN governance_control.DOMAIN_TABLE_REGISTRY dtr
    ON dtr.table_schema = c.TABLE_SCHEMA
    AND dtr.table_name = c.TABLE_NAME
WHERE c.TABLE_SCHEMA IN ('ventas', 'facturacion', 'operaciones', 'flota', 'archivo')
  AND st.is_ms_shipped = 0
  AND c.TABLE_NAME NOT LIKE 'DATA_%'
  AND c.TABLE_NAME NOT LIKE 'DOMAIN_%'
  AND c.TABLE_NAME NOT LIKE 'COLUMN_%'
  AND c.TABLE_NAME NOT LIKE 'CLIENT_%';
GO

-- =============================================================================
-- SECTION 5: DDL TRIGGER — KEEP CATALOG CURRENT ON SCHEMA CHANGES
-- When someone creates, alters, or drops a table, the catalog is updated.
-- This ensures the catalog stays synchronized with the actual schema.
-- =============================================================================

IF EXISTS (SELECT 1 FROM sys.triggers WHERE name = 'trg_UpdateDataCatalog' AND parent_class = 0)
    DROP TRIGGER trg_UpdateDataCatalog ON DATABASE;
GO

CREATE TRIGGER trg_UpdateDataCatalog
ON DATABASE
FOR CREATE_TABLE, ALTER_TABLE, DROP_TABLE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @event_data XML = EVENTDATA();

    DECLARE @event_type     NVARCHAR(100) = @event_data.value('(/EVENT_INSTANCE/EventType)[1]', 'NVARCHAR(100)');
    DECLARE @schema_name    NVARCHAR(100) = @event_data.value('(/EVENT_INSTANCE/SchemaName)[1]', 'NVARCHAR(100)');
    DECLARE @object_name    NVARCHAR(100) = @event_data.value('(/EVENT_INSTANCE/ObjectName)[1]', 'NVARCHAR(100)');
    DECLARE @login_name     NVARCHAR(100) = @event_data.value('(/EVENT_INSTANCE/LoginName)[1]', 'NVARCHAR(100)');
    DECLARE @tsql           NVARCHAR(MAX) = @event_data.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'NVARCHAR(MAX)');

    -- Log the DDL event to compliance table
    INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
        (policy_code, check_type, domain_code, table_name,
         compliance_status, finding_summary, violation_detail)
    VALUES
    (
        'POLICY-004',
        'AUTOMATED',
        (SELECT domain_code FROM governance_control.DOMAIN_TABLE_REGISTRY
         WHERE table_schema = @schema_name AND table_name = @object_name),
        @object_name,
        'YELLOW',   -- DDL change = YELLOW until review confirms it was authorized
        'DDL Event detected: ' + @event_type + ' on ' + @schema_name + '.' + @object_name
        + ' by ' + @login_name + '. Catalog update initiated.',
        LEFT(@tsql, 1000)
    );

    -- Update or remove the catalog entry based on the DDL event type
    IF @event_type = 'DROP_TABLE'
    BEGIN
        -- Mark as dropped, do not delete (preserve history)
        UPDATE metadata_catalog.DATA_CATALOG
        SET description_technical = ISNULL(description_technical, '') + ' [DROPPED by ' + @login_name + ' at ' + CAST(SYSUTCDATETIME() AS VARCHAR(30)) + ']',
            catalog_updated = SYSUTCDATETIME()
        WHERE table_schema = @schema_name AND table_name = @object_name;
    END
    ELSE IF @event_type IN ('CREATE_TABLE', 'ALTER_TABLE')
    BEGIN
        -- Upsert the catalog entry
        IF EXISTS (SELECT 1 FROM metadata_catalog.DATA_CATALOG WHERE table_schema = @schema_name AND table_name = @object_name)
        BEGIN
            UPDATE metadata_catalog.DATA_CATALOG
            SET catalog_updated = SYSUTCDATETIME(),
                description_technical = ISNULL(description_technical, '') + ' [Modified at ' + CAST(SYSUTCDATETIME() AS VARCHAR(30)) + ']'
            WHERE table_schema = @schema_name AND table_name = @object_name;
        END
        ELSE IF @event_type = 'CREATE_TABLE'
        BEGIN
            INSERT INTO metadata_catalog.DATA_CATALOG
                (table_schema, table_name, table_type, description_business, description_technical)
            VALUES
            (
                @schema_name,
                @object_name,
                'TABLE',
                'NEW TABLE — Business description required. Contact Data Steward for classification.',
                'Created by ' + @login_name + ' at ' + CAST(SYSUTCDATETIME() AS VARCHAR(30))
                + '. Auto-detected by DDL trigger. Classification and domain assignment pending.'
            );
        END
    END
END;
GO

-- =============================================================================
-- SECTION 6: EXECUTIVE METADATA REPORT PROCEDURE
-- What data does TRANSTRACK have? Who owns it? When was it last updated?
-- What quality rules apply? This is the catalog report for a CDO or auditor.
-- =============================================================================

IF OBJECT_ID('metadata_catalog.usp_MetadataExecutiveReport', 'P') IS NOT NULL
    DROP PROCEDURE metadata_catalog.usp_MetadataExecutiveReport;
GO

CREATE PROCEDURE metadata_catalog.usp_MetadataExecutiveReport
    @domain_filter  VARCHAR(20) = NULL  -- NULL = all domains
AS
BEGIN
    SET NOCOUNT ON;

    -- Section A: Catalog overview by domain
    PRINT '=== SECTION A: Data Asset Inventory by Domain ===';

    SELECT
        dc.domain                       AS [Domain],
        COUNT(dc.catalog_id)            AS [Total Tables],
        SUM(CAST(dtr.contains_pii AS INT)) AS [PII Tables],
        SUM(dc.row_count_approx)        AS [Total Records (approx)],
        SUM(dc.size_mb)                 AS [Total Size MB],
        MAX(dc.catalog_updated)         AS [Last Catalog Update]
    FROM metadata_catalog.DATA_CATALOG dc
    LEFT JOIN governance_control.DOMAIN_TABLE_REGISTRY dtr
        ON dc.table_schema = dtr.table_schema AND dc.table_name = dtr.table_name
    WHERE (@domain_filter IS NULL OR dc.domain = @domain_filter)
    GROUP BY dc.domain
    ORDER BY dc.domain;

    -- Section B: Table inventory with business descriptions
    PRINT '=== SECTION B: Table Inventory with Business Context ===';

    SELECT
        dc.table_name                   AS [Table],
        dc.domain                       AS [Domain],
        dc.owner                        AS [Data Owner],
        dc.steward                      AS [Data Steward],
        dc.classification_level         AS [Classification],
        dc.row_count_approx             AS [Records (approx)],
        dc.size_mb                      AS [Size MB],
        dc.business_key                 AS [Business Key],
        dc.sla_freshness_hours          AS [Freshness SLA (hrs)],
        dc.retention_days               AS [Retention (days)],
        dc.is_partitioned               AS [Partitioned],
        dc.description_business         AS [Business Description]
    FROM metadata_catalog.DATA_CATALOG dc
    WHERE (@domain_filter IS NULL OR dc.domain = @domain_filter)
    ORDER BY dc.domain, dc.table_name;

    -- Section C: Column-level sensitivity inventory
    PRINT '=== SECTION C: Sensitive Column Inventory ===';

    SELECT
        cc.table_name                   AS [Table],
        cc.column_name                  AS [Column],
        cc.data_type                    AS [Type],
        cc.sensitivity_level            AS [Sensitivity],
        cc.information_type             AS [Information Type],
        CASE WHEN cc.pii_flag = 1 THEN 'YES' ELSE 'NO' END AS [PII],
        cc.quality_rules                AS [Quality Rules],
        cc.description_business         AS [Business Definition]
    FROM metadata_catalog.COLUMN_CATALOG cc
    WHERE cc.sensitivity_level IN ('PII', 'FINANCIAL_CRITICAL')
      AND (@domain_filter IS NULL OR cc.table_name IN (
          SELECT table_name FROM governance_control.DOMAIN_TABLE_REGISTRY
          WHERE domain_code = @domain_filter
      ))
    ORDER BY cc.sensitivity_level, cc.table_name, cc.column_name;

    -- Section D: Governance gaps (tables without business description or owner)
    PRINT '=== SECTION D: Governance Gaps ===';

    SELECT
        dc.table_name                   AS [Table],
        CASE WHEN dc.description_business IS NULL THEN 'MISSING' ELSE 'OK' END AS [Business Description],
        CASE WHEN dc.owner IS NULL THEN 'MISSING' ELSE 'OK' END AS [Owner],
        CASE WHEN dc.steward IS NULL THEN 'MISSING' ELSE 'OK' END AS [Steward],
        CASE WHEN dc.classification_level IS NULL THEN 'MISSING' ELSE 'OK' END AS [Classification],
        CASE WHEN dc.retention_days IS NULL THEN 'MISSING' ELSE 'OK' END AS [Retention Policy]
    FROM metadata_catalog.DATA_CATALOG dc
    WHERE dc.description_business IS NULL
       OR dc.owner IS NULL
       OR dc.steward IS NULL
       OR dc.classification_level IS NULL
    ORDER BY dc.table_name;

END;
GO

-- =============================================================================
-- SECTION 7: EXECUTE AND VERIFY
-- =============================================================================

PRINT '=== DATA CATALOG VERIFICATION ===';

SELECT 'DATA_CATALOG row count:'    AS [Item], COUNT(*) AS [Value] FROM metadata_catalog.DATA_CATALOG
UNION ALL
SELECT 'COLUMN_CATALOG row count:', COUNT(*) FROM metadata_catalog.COLUMN_CATALOG;
GO

PRINT '=== EXECUTIVE METADATA REPORT — ALL DOMAINS ===';
EXEC metadata_catalog.usp_MetadataExecutiveReport;
GO

/*
=============================================================================
  ARCHITECTURAL NOTE:
  The DATA_CATALOG and COLUMN_CATALOG implement DAMA Ch.12's three-layer
  metadata strategy:

  TECHNICAL:   Populated automatically from INFORMATION_SCHEMA and sys objects.
               Always current. No manual maintenance required.

  BUSINESS:    Populated manually in this script. This IS the business glossary.
               The descriptions written here are what a business analyst,
               auditor, or new engineer reads to understand the data.
               Without these descriptions, sys.tables has 12 rows and no meaning.

  OPERATIONAL: Row counts and sizes from sys.partitions.
               Updated by the DDL trigger on schema changes.
               Full operational freshness metrics are implemented in Week 11
               (DATA_QUALITY_RESULTS table).

  The DDL trigger ensures the catalog never becomes stale after schema changes.
  This is the difference between a catalog that is maintained and one that
  becomes a historical artifact six months after its creation.

  DAMA Ch.12 Reference: https://www.dama.org/cpages/body-of-knowledge
  ISO 27001:2022 A.5.9 Reference: https://www.iso.org/standard/82875.html
  INFORMATION_SCHEMA: https://learn.microsoft.com/en-us/sql/relational-databases/
                      system-information-schema-views/system-information-schema-views
=============================================================================
*/
