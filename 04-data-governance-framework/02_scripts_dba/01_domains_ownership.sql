/*
=============================================================================
TRANSTRACK — Data Governance Architecture
Script:  01_domains_ownership.sql
Purpose: Create governance metadata tables for domains, owners, stewards,
           and policies. Populate with the three formal domains defined in
           governance_model.md. Generate a domain report stored procedure.
Validated by: Carlos Blanco
Ref:     DAMA-DMBOK 2nd Ed. Ch.3 — Data Governance
           ISO 27001:2022 A.5.2 — Information security roles and responsibilities
=============================================================================
*/

USE TRANSTRACK;
GO

-- =============================================================================
-- SECTION 0: GOVERNANCE SCHEMA
-- All governance control tables (domains, owners, stewards, policies, and
-- compliance tracking — Scripts 01-05) live in the governance_control schema.
-- This schema is created once and shared across the Week 04-05 deliverables.
-- Operational tables (CLIENTE, PEDIDO, CONDUCTOR, etc.) remain in their
-- existing operational schema (dbo) and are referenced as-is.
-- Metadata catalog tables (Script 06) live in a separate metadata_catalog
-- schema, since cataloging is conceptually distinct from governance
-- enforcement.
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'governance_control')
    EXEC('CREATE SCHEMA governance_control');
GO

-- =============================================================================
-- SECTION 1: GOVERNANCE METADATA TABLES
-- All governance tables live in the governance_control schema, logically
-- separated from operational tables (which remain in dbo).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: DATA_DOMAIN
-- Registers the three formal data domains of TRANSTRACK.
-- Each domain groups tables that share a business owner, a regulatory exposure,
-- and a governance lifecycle.
-- -----------------------------------------------------------------------------
IF OBJECT_ID('governance_control.DATA_DOMAIN', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_DOMAIN;
GO

CREATE TABLE governance_control.DATA_DOMAIN
(
    domain_id           INT             NOT NULL IDENTITY(1,1),
    domain_code         VARCHAR(20)     NOT NULL,   -- Short code used as FK in other tables
    domain_name         VARCHAR(100)    NOT NULL,
    domain_description  NVARCHAR(500)   NOT NULL,
    governance_model    VARCHAR(50)     NOT NULL    DEFAULT 'Hybrid-CenterLed',
    created_date        DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    created_by          SYSNAME         NOT NULL    DEFAULT SUSER_SNAME(),
    CONSTRAINT PK_DATA_DOMAIN PRIMARY KEY (domain_id),
    CONSTRAINT UQ_DATA_DOMAIN_CODE UNIQUE (domain_code)
);
GO

-- -----------------------------------------------------------------------------
-- Table: DATA_OWNER
-- Records the accountable business executive for each domain.
-- The Data Owner is the person who approves access, schema changes,
-- and retention decisions. This role maps to the A (Accountable) column
-- in the RACI matrix.
-- -----------------------------------------------------------------------------
IF OBJECT_ID('governance_control.DATA_OWNER', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_OWNER;
GO

CREATE TABLE governance_control.DATA_OWNER
(
    owner_id            INT             NOT NULL IDENTITY(1,1),
    domain_code         VARCHAR(20)     NOT NULL,
    owner_name          NVARCHAR(200)   NOT NULL,
    owner_title         NVARCHAR(200)   NOT NULL,
    owner_email         VARCHAR(200)    NOT NULL,
    is_active           BIT             NOT NULL    DEFAULT 1,
    effective_from      DATE            NOT NULL    DEFAULT CAST(GETDATE() AS DATE),
    effective_to        DATE            NULL,       -- NULL = currently active
    created_date        DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_DATA_OWNER PRIMARY KEY (owner_id),
    CONSTRAINT FK_DATA_OWNER_DOMAIN FOREIGN KEY (domain_code)
        REFERENCES governance_control.DATA_DOMAIN (domain_code)
);
GO

-- -----------------------------------------------------------------------------
-- Table: DATA_STEWARD
-- Records the operational data quality guardian for each domain.
-- The Data Steward is the person who monitors quality daily, executes
-- approved changes, and escalates issues to the Domain Owner.
-- This role maps to the R (Responsible) column in the RACI matrix
-- for quality and change activities.
-- -----------------------------------------------------------------------------
IF OBJECT_ID('governance_control.DATA_STEWARD', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_STEWARD;
GO

CREATE TABLE governance_control.DATA_STEWARD
(
    steward_id          INT             NOT NULL IDENTITY(1,1),
    domain_code         VARCHAR(20)     NOT NULL,
    steward_name        NVARCHAR(200)   NOT NULL,
    steward_title       NVARCHAR(200)   NOT NULL,
    steward_email       VARCHAR(200)    NOT NULL,
    responsibilities    NVARCHAR(1000)  NOT NULL,
    is_active           BIT             NOT NULL    DEFAULT 1,
    effective_from      DATE            NOT NULL    DEFAULT CAST(GETDATE() AS DATE),
    effective_to        DATE            NULL,
    created_date        DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_DATA_STEWARD PRIMARY KEY (steward_id),
    CONSTRAINT FK_DATA_STEWARD_DOMAIN FOREIGN KEY (domain_code)
        REFERENCES governance_control.DATA_DOMAIN (domain_code)
);
GO

-- -----------------------------------------------------------------------------
-- Table: DOMAIN_TABLE_REGISTRY
-- Maps each database table to its governing domain.
-- This is the operational join table between sys.tables and DATA_DOMAIN.
-- Without this registry, governance is aspirational — the registry makes it
-- enforceable by scripts and audit procedures.
-- -----------------------------------------------------------------------------
IF OBJECT_ID('governance_control.DOMAIN_TABLE_REGISTRY', 'U') IS NOT NULL
    DROP TABLE governance_control.DOMAIN_TABLE_REGISTRY;
GO

CREATE TABLE governance_control.DOMAIN_TABLE_REGISTRY
(
    registry_id         INT             NOT NULL IDENTITY(1,1),
    domain_code         VARCHAR(20)     NOT NULL,
    table_schema        SYSNAME         NOT NULL    DEFAULT 'dbo',  -- Schema of the OPERATIONAL table being registered (not governance_control)
    table_name          SYSNAME         NOT NULL,
    classification_level VARCHAR(30)    NOT NULL,   -- Populated after Week 05 classification
    contains_pii        BIT             NOT NULL    DEFAULT 0,
    is_master_data      BIT             NOT NULL    DEFAULT 0,  -- Golden record candidate
    is_reference_data   BIT             NOT NULL    DEFAULT 0,  -- Lookup/code table
    notes               NVARCHAR(500)   NULL,
    registered_date     DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    registered_by       SYSNAME         NOT NULL    DEFAULT SUSER_SNAME(),
    CONSTRAINT PK_DOMAIN_TABLE_REGISTRY PRIMARY KEY (registry_id),
    CONSTRAINT FK_DTR_DOMAIN FOREIGN KEY (domain_code)
        REFERENCES governance_control.DATA_DOMAIN (domain_code),
    CONSTRAINT UQ_DTR_TABLE UNIQUE (table_schema, table_name)
);
GO

-- -----------------------------------------------------------------------------
-- Table: DATA_POLICY
-- Stores the formal policies defined in data_policies.md.
-- Each policy has a code, owner, and enforcement mechanism.
-- This table makes policies machine-readable and auditable.
-- -----------------------------------------------------------------------------
IF OBJECT_ID('governance_control.DATA_POLICY', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_POLICY;
GO

CREATE TABLE governance_control.DATA_POLICY
(
    policy_id           INT             NOT NULL IDENTITY(1,1),
    policy_code         VARCHAR(20)     NOT NULL,   -- e.g. POLICY-001
    policy_name         VARCHAR(200)    NOT NULL,
    policy_description  NVARCHAR(2000)  NOT NULL,
    applies_to_domain   VARCHAR(20)     NULL,       -- NULL = applies to all domains
    policy_owner        NVARCHAR(200)   NOT NULL,
    enforcement_mechanism NVARCHAR(500) NOT NULL,
    review_frequency    VARCHAR(50)     NOT NULL    DEFAULT 'Annual',
    last_reviewed_date  DATE            NULL,
    next_review_date    DATE            NOT NULL,
    version_number      VARCHAR(10)     NOT NULL    DEFAULT '1.0',
    is_active           BIT             NOT NULL    DEFAULT 1,
    created_date        DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_DATA_POLICY PRIMARY KEY (policy_id),
    CONSTRAINT UQ_DATA_POLICY_CODE UNIQUE (policy_code)
);
GO

-- =============================================================================
-- SECTION 2: POPULATE THE THREE FORMAL DOMAINS
-- These inserts reflect the domain design documented in governance_model.md.
-- The domain codes are intentionally short to serve as FK values.
-- =============================================================================

INSERT INTO governance_control.DATA_DOMAIN (domain_code, domain_name, domain_description, governance_model)
VALUES
(
    'DOM_CLIENTES',
    'Clientes',
    'Governs commercial relationship data: clients, contracts, and invoices. '
    + 'This domain carries FINANCIAL_CRITICAL and PII classifications. '
    + 'Diagnostic finding: 15,000 client records with confirmed NIT duplicates across Sales and Billing modules.',
    'Hybrid-CenterLed'
),
(
    'DOM_OPERACIONES',
    'Operaciones',
    'Governs service execution data: orders, routes, deliveries, and incidents. '
    + 'This domain has legal exposure — incident records are required in litigation. '
    + 'Diagnostic finding: orders with no delivery records; incidents with unidentifiable drivers.',
    'Hybrid-CenterLed'
),
(
    'DOM_FLOTA',
    'Flota',
    'Governs asset and personnel data: vehicles, drivers (fragmented across 3 tables), '
    + 'and 50M GPS telemetry records. Highest PII concentration in the system. '
    + 'Diagnostic finding: driver identity split across CONDUCTOR, EMPLEADO, OPERADOR with no common key.',
    'Hybrid-CenterLed'
);
GO

-- =============================================================================
-- SECTION 3: REGISTER DOMAIN OWNERS
-- =============================================================================

INSERT INTO governance_control.DATA_OWNER (domain_code, owner_name, owner_title, owner_email)
VALUES
('DOM_CLIENTES',    'VP Comercial',         'Vice President Commercial & Sales',    'vp.comercial@transtrack.com'),
('DOM_OPERACIONES', 'VP Operaciones',        'Vice President Operations',            'vp.operaciones@transtrack.com'),
('DOM_FLOTA',       'VP Flota y Logistica', 'Vice President Fleet & Logistics',     'vp.flota@transtrack.com');
GO

-- =============================================================================
-- SECTION 4: REGISTER DATA STEWARDS
-- =============================================================================

INSERT INTO governance_control.DATA_STEWARD (domain_code, steward_name, steward_title, steward_email, responsibilities)
VALUES
(
    'DOM_CLIENTES',
    'Analista Senior Comercial',
    'Senior Commercial Data Analyst',
    'steward.clientes@transtrack.com',
    'Daily monitoring of NIT uniqueness and client completeness metrics. '
    + 'Executing approved deduplication procedures. Validating golden records after merge. '
    + 'Escalating quality violations to VP Comercial within 4 hours of detection.'
),
(
    'DOM_OPERACIONES',
    'Analista de Datos Operaciones',
    'Operations Data Analyst',
    'steward.operaciones@transtrack.com',
    'Monitoring delivery completion and incident record integrity daily. '
    + 'Validating that all incidents link to identifiable drivers and vehicles. '
    + 'Maintaining legal hold registry for incident data under investigation.'
),
(
    'DOM_FLOTA',
    'Coordinador de Datos de Flota',
    'Fleet Data Coordinator',
    'steward.flota@transtrack.com',
    'Monitoring telemetry partition health and ingestion completeness. '
    + 'Coordinating driver master record consolidation across CONDUCTOR, EMPLEADO, OPERADOR. '
    + 'Validating driver license uniqueness across all three driver tables daily.'
);
GO

-- =============================================================================
-- SECTION 5: MAP TABLES TO DOMAINS
-- Every table in the system is formally assigned to a domain.
-- Governance tables (DATA_*) are assigned to a meta-domain for governance.
-- =============================================================================

INSERT INTO governance_control.DOMAIN_TABLE_REGISTRY
    (domain_code, table_schema, table_name, classification_level, contains_pii, is_master_data, is_reference_data, notes)
VALUES
-- Domain: CLIENTES
('DOM_CLIENTES', 'dbo', 'CLIENTE',           'PII',                  1, 1, 0, 'Master client record. 15K rows with confirmed duplicates — Week 03 diagnostic.'),
('DOM_CLIENTES', 'dbo', 'CONTRATO_CLIENTE',  'FINANCIAL_CRITICAL',   0, 1, 0, 'Contract terms and tariffs. 12K rows. Authoritative source for billing amounts.'),
('DOM_CLIENTES', 'dbo', 'FACTURA',           'FINANCIAL_CRITICAL',   0, 0, 0, '490K rows. Diagnostic: some invoices have no linked PEDIDO — orphan invoice problem.'),

-- Domain: OPERACIONES
('DOM_OPERACIONES', 'dbo', 'PEDIDO',     'OPERATIONAL_SENSITIVE', 0, 0, 0, '500K rows from 2019. Core service record linking client to delivery.'),
('DOM_OPERACIONES', 'dbo', 'RUTA',       'OPERATIONAL_SENSITIVE', 0, 0, 1, '2,500 city-pair routes. Reference data within Operaciones domain.'),
('DOM_OPERACIONES', 'dbo', 'ENTREGA',    'OPERATIONAL_SENSITIVE', 0, 0, 0, '480K rows. Tracks actual vs estimated delivery times and incidents.'),
('DOM_OPERACIONES', 'dbo', 'INCIDENTE',  'OPERATIONAL_SENSITIVE', 1, 0, 0, '8,500 rows. Legal hold applicable. Contains PII when driver identified.'),

-- Domain: FLOTA
('DOM_FLOTA', 'dbo', 'VEHICULO',        'OPERATIONAL_SENSITIVE', 0, 1, 0, '800 truck records with assignment history.'),
('DOM_FLOTA', 'dbo', 'CONDUCTOR',       'PII',                   1, 1, 0, 'Driver master data — FRAGMENTED. No common key with EMPLEADO/OPERADOR.'),
('DOM_FLOTA', 'dbo', 'EMPLEADO',        'PII',                   1, 1, 0, 'Employee HR records for drivers — FRAGMENTED. Awaiting master consolidation.'),
('DOM_FLOTA', 'dbo', 'OPERADOR',        'PII',                   1, 1, 0, 'Operator system records for drivers — FRAGMENTED. Third leg of driver problem.'),
('DOM_FLOTA', 'dbo', 'TELEMETRIA_GPS',  'OPERATIONAL_SENSITIVE', 1, 0, 0, '50M rows partitioned by year/month. PII: GPS coordinates link to driver identity.');
GO

-- =============================================================================
-- SECTION 6: INSERT THE FOUR FORMAL POLICIES FROM data_policies.md
-- =============================================================================

INSERT INTO governance_control.DATA_POLICY
    (policy_code, policy_name, policy_description, applies_to_domain, policy_owner,
     enforcement_mechanism, review_frequency, next_review_date, version_number)
VALUES
(
    'POLICY-001',
    'Data Access Policy',
    'Defines who can access what data and under what conditions. '
    + 'Access is granted through five formal roles: rol_cliente, rol_operaciones, '
    + 'rol_auditoria, rol_legal, rol_dba. All PII and FINANCIAL_CRITICAL access '
    + 'requires Domain Owner written approval before DBA grants access.',
    NULL,  -- Applies to all domains
    'Chief Data Officer',
    'SQL Server Audit on classified tables. Weekly audit_permissions.py run. '
    + 'Violations reported to CISO and Domain Owner within 24 hours.',
    'Annual',
    DATEADD(YEAR, 1, CAST(GETDATE() AS DATE)),
    '1.0'
),
(
    'POLICY-002',
    'Data Retention Policy',
    'Defines how long each data category is retained and what happens at expiry. '
    + 'Key periods: FACTURA = 5 years minimum, INCIDENTE = 10 years, '
    + 'TELEMETRIA_GPS = 3 years active then archived to ARCHIVE filegroup, '
    + 'driver records = 7 years post-separation. Legal holds override all schedules.',
    NULL,
    'Chief Data Officer + Chief Financial Officer',
    'Monthly stored procedure checks retention compliance. Violations logged to '
    + 'DATA_POLICY_COMPLIANCE. Domain Owners receive monthly retention report.',
    'Annual',
    DATEADD(YEAR, 1, CAST(GETDATE() AS DATE)),
    '1.0'
),
(
    'POLICY-003',
    'Data Quality Policy',
    'Defines minimum acceptable quality thresholds by domain and table. '
    + 'Zero-tolerance violations (driver with no license, invoice with invalid NIT, '
    + 'incident with no vehicle or driver) trigger immediate Sev-1 escalation. '
    + 'Baseline is the diagnostic state documented in Week 03.',
    NULL,
    'Chief Data Officer',
    'Automated quality checks via stored procedures (Week 11). Results stored in '
    + 'DATA_QUALITY_RESULTS. Red status triggers Sev-1 IT incident within 1 hour.',
    'Annual',
    DATEADD(YEAR, 1, CAST(GETDATE() AS DATE)),
    '1.0'
),
(
    'POLICY-004',
    'Data Change Policy',
    'Defines how master data changes are requested, approved, and executed. '
    + 'No direct production writes without approved change request. '
    + 'Deduplication and master data consolidation are governed changes. '
    + 'Schema changes require Data Architect review before DBA execution.',
    NULL,
    'Chief Data Officer',
    'DATA_POLICY_COMPLIANCE logs every change request, approval, and execution. '
    + 'SQL Server Audit captures all DML on master data tables. '
    + 'Quarterly review confirms all changes have corresponding approvals.',
    'Annual',
    DATEADD(YEAR, 1, CAST(GETDATE() AS DATE)),
    '1.0'
);
GO

-- =============================================================================
-- SECTION 7: STORED PROCEDURE — DOMAIN REPORT
-- Generates a complete domain report: which tables belong to each domain,
-- who owns them, what steward monitors them, and what policies apply.
-- This is the governance dashboard that an executive or auditor would request.
-- =============================================================================

IF OBJECT_ID('governance_control.usp_DomainGovernanceReport', 'P') IS NOT NULL
    DROP PROCEDURE governance_control.usp_DomainGovernanceReport;
GO

CREATE PROCEDURE governance_control.usp_DomainGovernanceReport
    @domain_code    VARCHAR(20) = NULL  -- NULL returns all domains
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- SECTION A: Domain Summary with Owner and Steward
    -- -------------------------------------------------------------------------
    SELECT
        d.domain_code                       AS [Domain Code],
        d.domain_name                       AS [Domain Name],
        d.governance_model                  AS [Governance Model],
        o.owner_name                        AS [Data Owner],
        o.owner_title                       AS [Owner Title],
        s.steward_name                      AS [Data Steward],
        s.steward_title                     AS [Steward Title],
        COUNT(dtr.registry_id)              AS [Table Count],
        SUM(CAST(dtr.contains_pii AS INT))  AS [Tables with PII],
        SUM(CAST(dtr.is_master_data AS INT))AS [Master Data Tables]
    FROM governance_control.DATA_DOMAIN d
    LEFT JOIN governance_control.DATA_OWNER o
        ON d.domain_code = o.domain_code AND o.is_active = 1
    LEFT JOIN governance_control.DATA_STEWARD s
        ON d.domain_code = s.domain_code AND s.is_active = 1
    LEFT JOIN governance_control.DOMAIN_TABLE_REGISTRY dtr
        ON d.domain_code = dtr.domain_code
    WHERE (@domain_code IS NULL OR d.domain_code = @domain_code)
    GROUP BY
        d.domain_code, d.domain_name, d.governance_model,
        o.owner_name, o.owner_title, s.steward_name, s.steward_title
    ORDER BY d.domain_name;

    -- -------------------------------------------------------------------------
    -- SECTION B: Table Inventory by Domain with Row Counts
    -- Joins DOMAIN_TABLE_REGISTRY with actual sys.tables for row count.
    -- Uses INFORMATION_SCHEMA for portability.
    -- NOTE: Row counts from sys.partitions are approximate for non-partitioned
    -- tables; use this for governance reporting, not for billing.
    -- -------------------------------------------------------------------------
    SELECT
        d.domain_name                       AS [Domain],
        dtr.table_schema + '.' + dtr.table_name AS [Table],
        dtr.classification_level            AS [Classification],
        CASE WHEN dtr.contains_pii = 1 THEN 'YES' ELSE 'NO' END AS [Contains PII],
        CASE WHEN dtr.is_master_data = 1 THEN 'YES' ELSE 'NO' END AS [Master Data],
        CASE WHEN dtr.is_reference_data = 1 THEN 'YES' ELSE 'NO' END AS [Reference Data],
        -- Approximate row count from sys.partitions — fast, no locking
        COALESCE(p.row_count_approx, 0)    AS [Approx Row Count],
        dtr.notes                           AS [Governance Notes],
        o.owner_name                        AS [Domain Owner]
    FROM governance_control.DOMAIN_TABLE_REGISTRY dtr
    JOIN governance_control.DATA_DOMAIN d ON dtr.domain_code = d.domain_code
    LEFT JOIN governance_control.DATA_OWNER o
        ON d.domain_code = o.domain_code AND o.is_active = 1
    -- Subquery: get approximate row count from sys.partitions
    OUTER APPLY (
        SELECT SUM(sp.rows) AS row_count_approx
        FROM sys.tables st
        JOIN sys.schemas ss ON st.schema_id = ss.schema_id
        JOIN sys.partitions sp ON st.object_id = sp.object_id
        WHERE ss.name = dtr.table_schema
          AND st.name = dtr.table_name
          AND sp.index_id IN (0, 1)  -- heap or clustered index only
    ) p
    WHERE (@domain_code IS NULL OR dtr.domain_code = @domain_code)
    ORDER BY d.domain_name, dtr.table_name;

    -- -------------------------------------------------------------------------
    -- SECTION C: Applicable Policies per Domain
    -- -------------------------------------------------------------------------
    SELECT
        ISNULL(dp.applies_to_domain, 'ALL DOMAINS')  AS [Domain Scope],
        dp.policy_code                               AS [Policy Code],
        dp.policy_name                               AS [Policy Name],
        dp.policy_owner                              AS [Policy Owner],
        dp.version_number                            AS [Version],
        dp.next_review_date                          AS [Next Review],
        CASE WHEN dp.is_active = 1 THEN 'ACTIVE' ELSE 'INACTIVE' END AS [Status]
    FROM governance_control.DATA_POLICY dp
    WHERE dp.is_active = 1
      AND (dp.applies_to_domain IS NULL OR dp.applies_to_domain = @domain_code)
    ORDER BY dp.policy_code;

END;
GO

-- =============================================================================
-- SECTION 8: EXECUTE AND VERIFY
-- Run the domain report to confirm all inserts are correct.
-- =============================================================================

PRINT '=== DOMAIN GOVERNANCE REPORT — ALL DOMAINS ===';
EXEC governance_control.usp_DomainGovernanceReport;
GO

PRINT '=== DOMAIN GOVERNANCE REPORT — FLOTA ONLY ===';
EXEC governance_control.usp_DomainGovernanceReport @domain_code = 'DOM_FLOTA';
GO

-- =============================================================================
-- VERIFICATION: Quick counts to confirm inserts
-- =============================================================================
SELECT 'DATA_DOMAIN'           AS [Table], COUNT(*) AS [Row Count] FROM governance_control.DATA_DOMAIN
UNION ALL
SELECT 'DATA_OWNER',                       COUNT(*)               FROM governance_control.DATA_OWNER
UNION ALL
SELECT 'DATA_STEWARD',                     COUNT(*)               FROM governance_control.DATA_STEWARD
UNION ALL
SELECT 'DOMAIN_TABLE_REGISTRY',            COUNT(*)               FROM governance_control.DOMAIN_TABLE_REGISTRY
UNION ALL
SELECT 'DATA_POLICY',                      COUNT(*)               FROM governance_control.DATA_POLICY;
GO

/*
=============================================================================
  ARCHITECTURAL NOTE:
  The DOMAIN_TABLE_REGISTRY is the bridge between organizational governance
  decisions (who owns the data) and technical enforcement (which stored
  procedures, audit specs, and RLS policies apply to each table).
  
  Without this registry, governance exists only in documents. With it,
  every automated script in this project can query which domain a table
  belongs to and apply the correct rules automatically.

=============================================================================
*/
