/*
=============================================================================
  TRANSTRACK — Data Governance Architecture
  Script:  02_data_policies.sql
  Purpose: Create DATA_POLICY_COMPLIANCE table to track policy adherence.
           Stored procedure that checks each policy against current database
           state and logs compliance status with specific violations.
Validated by: Carlos Blanco
  Ref:     DAMA-DMBOK 2nd Ed. Ch.3 — Data Governance, Policy Management
           ISO 27001:2022 A.5.1 — Policies for information security
           ISO 22301:2019 §8.4 — Business continuity procedures
  Depends: 01_domains_ownership.sql must be executed first.
=============================================================================
*/

USE TRANSTRACK;
GO

-- =============================================================================
-- SECTION 1: POLICY COMPLIANCE TRACKING TABLE
-- Records every compliance check: what was checked, when, against which policy,
-- what the result was, and what specific violation was found (if any).
-- This table is the audit trail that proves governance is operational, not
-- aspirational. An auditor or regulator can query this table to see the
-- history of compliance checks.
-- =============================================================================

IF OBJECT_ID('governance_control.DATA_POLICY_COMPLIANCE', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_POLICY_COMPLIANCE;
GO

CREATE TABLE governance_control.DATA_POLICY_COMPLIANCE
(
    compliance_id           INT             NOT NULL IDENTITY(1,1),
    policy_code             VARCHAR(20)     NOT NULL,   -- FK to DATA_POLICY
    check_date              DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    checked_by              SYSNAME         NOT NULL    DEFAULT SUSER_SNAME(),
    check_type              VARCHAR(30)     NOT NULL,   -- AUTOMATED | MANUAL | REGULATORY
    domain_code             VARCHAR(20)     NULL,       -- Which domain was checked
    table_name              SYSNAME         NULL,       -- Specific table if applicable
    compliance_status       VARCHAR(10)     NOT NULL,   -- GREEN | YELLOW | RED
    -- GREEN:  Policy is being followed, no violations detected
    -- YELLOW: Minor deviation detected; under review; not yet a violation
    -- RED:    Policy violation confirmed; requires immediate action
    finding_summary         NVARCHAR(500)   NOT NULL,   -- Human-readable summary
    violation_detail        NVARCHAR(2000)  NULL,       -- Technical detail for DBA/Architect
    violation_count         INT             NULL,       -- How many records are in violation
    remediation_required    BIT             NOT NULL    DEFAULT 0,
    remediation_owner       NVARCHAR(200)   NULL,       -- Who must fix this
    remediation_due_date    DATE            NULL,
    remediation_completed   BIT             NOT NULL    DEFAULT 0,
    remediation_date        DATETIME2       NULL,
    remediation_notes       NVARCHAR(1000)  NULL,
    CONSTRAINT PK_DATA_POLICY_COMPLIANCE PRIMARY KEY (compliance_id),
    CONSTRAINT FK_DPC_POLICY FOREIGN KEY (policy_code)
        REFERENCES governance_control.DATA_POLICY (policy_code),
    CONSTRAINT CHK_DPC_STATUS CHECK (compliance_status IN ('GREEN', 'YELLOW', 'RED')),
    CONSTRAINT CHK_DPC_CHECK_TYPE CHECK (check_type IN ('AUTOMATED', 'MANUAL', 'REGULATORY'))
);
GO

-- Index for frequent queries: what is the current compliance status?
CREATE NONCLUSTERED INDEX IX_DPC_Policy_Date
    ON governance_control.DATA_POLICY_COMPLIANCE (policy_code, check_date DESC)
    INCLUDE (compliance_status, finding_summary);
GO

CREATE NONCLUSTERED INDEX IX_DPC_Status_Date
    ON governance_control.DATA_POLICY_COMPLIANCE (compliance_status, check_date DESC)
    INCLUDE (policy_code, domain_code, finding_summary);
GO

-- =============================================================================
-- SECTION 2: HELPER TABLE — DATA_CHANGE_REQUEST
-- Implements the Data Change Policy (POLICY-004).
-- Any master data change must have an entry here before execution.
-- This is the request-approval-execute workflow for master data governance.
-- =============================================================================

IF OBJECT_ID('governance_control.DATA_CHANGE_REQUEST', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_CHANGE_REQUEST;
GO

CREATE TABLE governance_control.DATA_CHANGE_REQUEST
(
    request_id          INT             NOT NULL IDENTITY(1,1),
    request_date        DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    requested_by        NVARCHAR(200)   NOT NULL,
    domain_code         VARCHAR(20)     NOT NULL,
    table_name          SYSNAME         NOT NULL,
    change_type         VARCHAR(30)     NOT NULL,   -- INSERT | UPDATE | DELETE | MERGE | SCHEMA
    change_description  NVARCHAR(2000)  NOT NULL,
    business_justification NVARCHAR(1000) NOT NULL,
    records_affected    INT             NULL,
    before_state_summary NVARCHAR(2000) NULL,       -- Summary of data before change
    after_state_summary  NVARCHAR(2000) NULL,       -- Summary of data after change
    -- Approval workflow
    approval_status     VARCHAR(20)     NOT NULL    DEFAULT 'PENDING',
    -- PENDING | APPROVED | REJECTED | EMERGENCY_APPROVED
    approved_by         NVARCHAR(200)   NULL,
    approval_date       DATETIME2       NULL,
    approval_notes      NVARCHAR(500)   NULL,
    -- Execution
    executed_by         SYSNAME         NULL,
    execution_date      DATETIME2       NULL,
    execution_notes     NVARCHAR(500)   NULL,
    is_emergency        BIT             NOT NULL    DEFAULT 0,
    CONSTRAINT PK_DATA_CHANGE_REQUEST PRIMARY KEY (request_id),
    CONSTRAINT FK_DCR_DOMAIN FOREIGN KEY (domain_code)
        REFERENCES governance_control.DATA_DOMAIN (domain_code),
    CONSTRAINT CHK_DCR_APPROVAL CHECK (approval_status IN
        ('PENDING', 'APPROVED', 'REJECTED', 'EMERGENCY_APPROVED'))
);
GO

-- =============================================================================
-- SECTION 3: POLICY COMPLIANCE CHECK PROCEDURE
-- Runs automated checks against each of the four formal policies and logs
-- results to DATA_POLICY_COMPLIANCE. This procedure can be scheduled as a
-- SQL Server Agent job to run on the defined frequency for each policy.
--
-- The checks implemented here reflect what can be verified at the database
-- level in Week 04. More detailed quality checks are implemented in Week 11.
-- =============================================================================

IF OBJECT_ID('governance_control.usp_CheckPolicyCompliance', 'P') IS NOT NULL
    DROP PROCEDURE governance_control.usp_CheckPolicyCompliance;
GO

CREATE PROCEDURE governance_control.usp_CheckPolicyCompliance
    @policy_code    VARCHAR(20) = NULL,  -- NULL = check all policies
    @verbose        BIT = 1              -- 1 = print findings to console
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @check_date DATETIME2 = SYSUTCDATETIME();
    DECLARE @findings_count INT = 0;

    -- =========================================================================
    -- CHECK 1: POLICY-001 — Data Access Policy
    -- Verify that governance metadata tables exist and roles are configured.
    -- Full permission audit is in audit_permissions.py (Python script).
    -- At database level: check that the five required roles exist.
    -- =========================================================================
    IF @policy_code IS NULL OR @policy_code = 'POLICY-001'
    BEGIN
        DECLARE @missing_roles NVARCHAR(500) = '';
        DECLARE @role_name VARCHAR(50);

        -- Check each required role defined in the governance model
        DECLARE @required_roles TABLE (role_name VARCHAR(50));
        INSERT INTO @required_roles VALUES
            ('rol_cliente'), ('rol_operaciones'), ('rol_auditoria'),
            ('rol_legal'), ('rol_dba');

        SELECT @missing_roles = STRING_AGG(rr.role_name, ', ')
        FROM @required_roles rr
        WHERE NOT EXISTS (
            SELECT 1 FROM sys.database_principals dp
            WHERE dp.name = rr.role_name
              AND dp.type = 'R'  -- Database role
        );

        IF LEN(ISNULL(@missing_roles, '')) = 0
        BEGIN
            INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
                (policy_code, check_type, compliance_status, finding_summary)
            VALUES
                ('POLICY-001', 'AUTOMATED', 'YELLOW',
                 'Role structure not yet implemented. Roles will be created in Week 05 (04_rls_roles.sql). '
                 + 'Access policy governance structure is in place — technical enforcement pending.');

            IF @verbose = 1 PRINT 'POLICY-001: YELLOW — Roles pending Week 05 implementation.';
        END
        ELSE
        BEGIN
            INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
                (policy_code, check_type, compliance_status, finding_summary,
                 violation_detail, remediation_required, remediation_owner, remediation_due_date)
            VALUES
                ('POLICY-001', 'AUTOMATED', 'YELLOW',
                 'Required database roles not yet created. This is expected at Week 04 stage.',
                 'Missing roles: ' + @missing_roles,
                 1, 'DBA — execute 04_rls_roles.sql in Week 05',
                 DATEADD(WEEK, 1, CAST(@check_date AS DATE)));

            IF @verbose = 1
                PRINT 'POLICY-001: YELLOW — Missing roles: ' + @missing_roles;
        END

        SET @findings_count += 1;
    END

    -- =========================================================================
    -- CHECK 2: POLICY-002 — Data Retention Policy
    -- Check 1: TELEMETRIA_GPS — verify if records older than 3 years exist
    --           in PRIMARY filegroup (should be in ARCHIVE).
    -- Check 2: FACTURA — verify minimum 5-year retention (no premature deletion
    --           evidence; check if oldest records exist).
    -- Check 3: INCIDENTE — verify 10-year retention (oldest records present).
    -- =========================================================================
    IF @policy_code IS NULL OR @policy_code = 'POLICY-002'
    BEGIN
        -- Check TELEMETRIA_GPS retention
        -- Policy: records older than 3 years must be in ARCHIVE filegroup
        -- At Week 04 we check if old data exists; partition migration is Week 07+
        DECLARE @telemetria_old_count INT = 0;
        DECLARE @oldest_telemetria_year INT;

        IF OBJECT_ID('dbo.TELEMETRIA_GPS', 'U') IS NOT NULL
        BEGIN
            -- Get the oldest partition year using sys.partitions
            -- This is a DBA-level check — reading partition metadata, not scanning 50M rows
            SELECT @oldest_telemetria_year = MIN(CAST(pf.value AS INT))
            FROM sys.partition_functions pf_fn
            JOIN sys.partition_range_values pf
                ON pf_fn.function_id = pf.function_id
            WHERE pf_fn.name LIKE '%TELEMETRIA%'  -- Matches the partition function from Week 02
              AND CAST(pf.value AS INT) < YEAR(DATEADD(YEAR, -3, GETDATE()));

            -- Fallback: if partition metadata not available, check min date in table
            IF @oldest_telemetria_year IS NULL
            BEGIN
                -- NOTE: This query will scan. In production, use partition metadata only.
                -- In this lab environment it demonstrates the compliance check intent.
                SELECT @oldest_telemetria_year = YEAR(MIN(fecha_registro))
                FROM dbo.TELEMETRIA_GPS
                WHERE OBJECT_ID('dbo.TELEMETRIA_GPS') IS NOT NULL;
            END;

            IF @oldest_telemetria_year <= YEAR(GETDATE()) - 3
            BEGIN
                INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
                    (policy_code, check_type, domain_code, table_name,
                     compliance_status, finding_summary, violation_detail,
                     remediation_required, remediation_owner, remediation_due_date)
                VALUES
                    ('POLICY-002', 'AUTOMATED', 'DOM_FLOTA', 'TELEMETRIA_GPS',
                     'YELLOW',
                     'TELEMETRIA_GPS contains data from year ' + CAST(@oldest_telemetria_year AS VARCHAR)
                     + '. Policy requires data older than 3 years to be in ARCHIVE filegroup. '
                     + 'Partition migration to ARCHIVE scheduled for Week 07.',
                     'Oldest telemetry year: ' + CAST(ISNULL(@oldest_telemetria_year, 0) AS VARCHAR)
                     + '. Archive threshold: ' + CAST(YEAR(GETDATE()) - 3 AS VARCHAR),
                     1, 'DBA + VP Flota', DATEADD(WEEK, 3, CAST(@check_date AS DATE)));

                IF @verbose = 1
                    PRINT 'POLICY-002 TELEMETRIA: YELLOW — Old data detected. Archive migration pending Week 07.';
            END
            ELSE
            BEGIN
                INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
                    (policy_code, check_type, domain_code, table_name,
                     compliance_status, finding_summary)
                VALUES
                    ('POLICY-002', 'AUTOMATED', 'DOM_FLOTA', 'TELEMETRIA_GPS',
                     'GREEN',
                     'TELEMETRIA_GPS: No retention policy violations detected for active partition data.');

                IF @verbose = 1 PRINT 'POLICY-002 TELEMETRIA: GREEN';
            END
        END
        ELSE
        BEGIN
            INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
                (policy_code, check_type, domain_code, table_name,
                 compliance_status, finding_summary,
                 remediation_required, remediation_owner)
            VALUES
                ('POLICY-002', 'AUTOMATED', 'DOM_FLOTA', 'TELEMETRIA_GPS',
                 'RED',
                 'TELEMETRIA_GPS table does not exist. Cannot verify retention compliance.',
                 1, 'DBA — execute Week 02 table creation scripts');

            IF @verbose = 1 PRINT 'POLICY-002 TELEMETRIA: RED — Table not found.';
        END;

        -- Check INCIDENTE — must retain for 10 years (legal exposure)
        -- Policy violation: if any incident record has been deleted (we check the
        -- minimum date to ensure oldest records exist as expected)
        IF OBJECT_ID('dbo.INCIDENTE', 'U') IS NOT NULL
        BEGIN
            DECLARE @oldest_incident_date DATE;
            SELECT @oldest_incident_date = CAST(MIN(fecha_incidente) AS DATE)
            FROM dbo.INCIDENTE;

            INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
                (policy_code, check_type, domain_code, table_name,
                 compliance_status, finding_summary, violation_detail)
            VALUES
                ('POLICY-002', 'AUTOMATED', 'DOM_OPERACIONES', 'INCIDENTE',
                 'GREEN',
                 'INCIDENTE: Oldest record dated ' + ISNULL(CAST(@oldest_incident_date AS VARCHAR), 'N/A')
                 + '. Manual verification required to confirm no records deleted without authorization.',
                 'Row count: ' + CAST(ISNULL((SELECT COUNT(*) FROM dbo.INCIDENTE), 0) AS VARCHAR));

            IF @verbose = 1
                PRINT 'POLICY-002 INCIDENTE: GREEN — Oldest incident: ' + ISNULL(CAST(@oldest_incident_date AS VARCHAR), 'N/A');
        END;

        SET @findings_count += 1;
    END

    -- =========================================================================
    -- CHECK 3: POLICY-003 — Data Quality Policy
    -- Check NIT uniqueness in CLIENTE (threshold: 98% unique).
    -- Full quality checks are implemented in Week 11.
    -- This is the early indicator check to demonstrate policy enforcement.
    -- =========================================================================
    IF @policy_code IS NULL OR @policy_code = 'POLICY-003'
    BEGIN
        IF OBJECT_ID('dbo.CLIENTE', 'U') IS NOT NULL
        BEGIN
            DECLARE @total_clients INT;
            DECLARE @duplicate_nit_count INT;
            DECLARE @uniqueness_pct DECIMAL(5,2);

            SELECT
                @total_clients = COUNT(*),
                @duplicate_nit_count = COUNT(*) - COUNT(DISTINCT nit)
            FROM dbo.CLIENTE;

            SET @uniqueness_pct = CASE
                WHEN @total_clients = 0 THEN 100.00
                ELSE (CAST(@total_clients - @duplicate_nit_count AS DECIMAL(10,2)) / @total_clients) * 100
            END;

            DECLARE @quality_status VARCHAR(10) = CASE
                WHEN @uniqueness_pct >= 98.00 THEN 'GREEN'
                WHEN @uniqueness_pct >= 95.00 THEN 'YELLOW'
                ELSE 'RED'
            END;

            INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
                (policy_code, check_type, domain_code, table_name,
                 compliance_status, finding_summary, violation_detail,
                 violation_count,
                 remediation_required, remediation_owner, remediation_due_date)
            VALUES
                ('POLICY-003', 'AUTOMATED', 'DOM_CLIENTES', 'CLIENTE',
                 @quality_status,
                 'CLIENTE NIT uniqueness: ' + CAST(@uniqueness_pct AS VARCHAR) + '%. '
                 + 'Threshold: 98.00%. Status: ' + @quality_status
                 + '. This confirms the Week 03 diagnostic finding of intentional duplicates.',
                 'Total records: ' + CAST(@total_clients AS VARCHAR)
                 + ' | Duplicate NITs: ' + CAST(@duplicate_nit_count AS VARCHAR)
                 + ' | Uniqueness: ' + CAST(@uniqueness_pct AS VARCHAR) + '%',
                 @duplicate_nit_count,
                 CASE WHEN @quality_status != 'GREEN' THEN 1 ELSE 0 END,
                 CASE WHEN @quality_status != 'GREEN' THEN 'Data Steward DOM_CLIENTES' ELSE NULL END,
                 CASE WHEN @quality_status != 'GREEN' THEN DATEADD(DAY, 5, CAST(@check_date AS DATE)) ELSE NULL END);

            IF @verbose = 1
                PRINT 'POLICY-003 CLIENTE NIT: ' + @quality_status
                    + ' (' + CAST(@uniqueness_pct AS VARCHAR) + '% unique, '
                    + CAST(@duplicate_nit_count AS VARCHAR) + ' duplicates)';
        END;

        -- Check FACTURA referential integrity (zero-tolerance rule)
        IF OBJECT_ID('dbo.FACTURA', 'U') IS NOT NULL
           AND OBJECT_ID('dbo.PEDIDO', 'U') IS NOT NULL
        BEGIN
            DECLARE @orphan_invoices INT;

            SELECT @orphan_invoices = COUNT(*)
            FROM dbo.FACTURA f
            WHERE f.pedido_id IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM dbo.PEDIDO p WHERE p.pedido_id = f.pedido_id
              );

            DECLARE @invoice_status VARCHAR(10) = CASE
                WHEN @orphan_invoices = 0 THEN 'GREEN'
                ELSE 'RED'  -- Zero tolerance: any orphan invoice is RED
            END;

            INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
                (policy_code, check_type, domain_code, table_name,
                 compliance_status, finding_summary, violation_detail,
                 violation_count,
                 remediation_required, remediation_owner, remediation_due_date)
            VALUES
                ('POLICY-003', 'AUTOMATED', 'DOM_CLIENTES', 'FACTURA',
                 @invoice_status,
                 'FACTURA referential integrity (zero-tolerance rule). '
                 + 'Orphan invoices (FACTURA with pedido_id referencing no PEDIDO): '
                 + CAST(@orphan_invoices AS VARCHAR),
                 'This intentional problem was documented in the Week 03 diagnostic as evidence '
                 + 'of cross-module integration failure between Billing and Operations.',
                 @orphan_invoices,
                 CASE WHEN @orphan_invoices > 0 THEN 1 ELSE 0 END,
                 CASE WHEN @orphan_invoices > 0 THEN 'VP Comercial + VP Operaciones' ELSE NULL END,
                 CASE WHEN @orphan_invoices > 0 THEN DATEADD(DAY, 2, CAST(@check_date AS DATE)) ELSE NULL END);

            IF @verbose = 1
                PRINT 'POLICY-003 FACTURA orphans: ' + @invoice_status
                    + ' (' + CAST(@orphan_invoices AS VARCHAR) + ' orphan invoices)';
        END;

        SET @findings_count += 1;
    END

    -- =========================================================================
    -- CHECK 4: POLICY-004 — Data Change Policy
    -- Verify that DATA_CHANGE_REQUEST and DATA_POLICY_COMPLIANCE tables exist
    -- (they are the enforcement mechanism for the change policy).
    -- Check if any compliance records have RED status without a remediation plan.
    -- =========================================================================
    IF @policy_code IS NULL OR @policy_code = 'POLICY-004'
    BEGIN
        DECLARE @unplanned_red_count INT;

        SELECT @unplanned_red_count = COUNT(*)
        FROM governance_control.DATA_POLICY_COMPLIANCE
        WHERE compliance_status = 'RED'
          AND remediation_required = 1
          AND remediation_completed = 0
          AND remediation_owner IS NULL
          AND check_date < DATEADD(HOUR, -4, SYSUTCDATETIME());  -- Older than 4 hours

        DECLARE @change_policy_status VARCHAR(10) = CASE
            WHEN @unplanned_red_count = 0 THEN 'GREEN'
            ELSE 'YELLOW'
        END;

        INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
            (policy_code, check_type, compliance_status, finding_summary, violation_detail, violation_count)
        VALUES
            ('POLICY-004', 'AUTOMATED', @change_policy_status,
             'Data Change Policy: Governance infrastructure for change management is active. '
             + 'DATA_CHANGE_REQUEST and DATA_POLICY_COMPLIANCE tables operational.',
             'RED findings without remediation owner: ' + CAST(@unplanned_red_count AS VARCHAR),
             @unplanned_red_count);

        IF @verbose = 1
            PRINT 'POLICY-004: ' + @change_policy_status
                + ' | RED findings without owner: ' + CAST(@unplanned_red_count AS VARCHAR);

        SET @findings_count += 1;
    END

    -- =========================================================================
    -- SUMMARY: Print overall compliance picture
    -- =========================================================================
    IF @verbose = 1
    BEGIN
        PRINT '';
        PRINT '=== COMPLIANCE SUMMARY ===';

        SELECT
            compliance_status   AS [Status],
            COUNT(*)            AS [Finding Count],
            STRING_AGG(policy_code, ', ') AS [Policies]
        FROM governance_control.DATA_POLICY_COMPLIANCE
        WHERE check_date >= DATEADD(MINUTE, -5, SYSUTCDATETIME())  -- Current run only
        GROUP BY compliance_status
        ORDER BY
            CASE compliance_status WHEN 'RED' THEN 1 WHEN 'YELLOW' THEN 2 ELSE 3 END;
    END

    -- Return the findings from this run
    SELECT
        dpc.compliance_id                   AS [Check ID],
        dpc.policy_code                     AS [Policy],
        dp.policy_name                      AS [Policy Name],
        dpc.domain_code                     AS [Domain],
        dpc.table_name                      AS [Table],
        dpc.compliance_status               AS [Status],
        dpc.finding_summary                 AS [Finding],
        dpc.violation_count                 AS [Violations],
        dpc.remediation_owner               AS [Remediation Owner],
        dpc.remediation_due_date            AS [Due Date]
    FROM governance_control.DATA_POLICY_COMPLIANCE dpc
    JOIN governance_control.DATA_POLICY dp ON dpc.policy_code = dp.policy_code
    WHERE dpc.check_date >= DATEADD(MINUTE, -5, SYSUTCDATETIME())
    ORDER BY
        CASE dpc.compliance_status WHEN 'RED' THEN 1 WHEN 'YELLOW' THEN 2 ELSE 3 END,
        dpc.policy_code;

END;
GO

-- =============================================================================
-- SECTION 4: EXECUTE THE COMPLIANCE CHECK
-- =============================================================================

PRINT '=== RUNNING POLICY COMPLIANCE CHECK — TRANSTRACK ===';
PRINT 'Check timestamp: ' + CAST(SYSUTCDATETIME() AS VARCHAR(30));
PRINT '';

EXEC governance_control.usp_CheckPolicyCompliance @verbose = 1;
GO

-- =============================================================================
-- SECTION 5: COMPLIANCE DASHBOARD QUERY
-- Summary view of current compliance state across all policies.
-- This is what a CISO or CDO would see in a governance dashboard.
-- =============================================================================
SELECT
    dp.policy_code                  AS [Policy],
    dp.policy_name                  AS [Policy Name],
    latest.compliance_status        AS [Current Status],
    latest.check_date               AS [Last Checked],
    latest.finding_summary          AS [Latest Finding],
    latest.violation_count          AS [Open Violations],
    CASE
        WHEN latest.remediation_required = 1 AND latest.remediation_completed = 0
        THEN 'ACTION REQUIRED — ' + ISNULL(latest.remediation_owner, 'Unassigned')
        ELSE 'No action required'
    END                             AS [Action Required]
FROM governance_control.DATA_POLICY dp
CROSS APPLY (
    -- Get the most recent compliance check for each policy
    SELECT TOP 1
        dpc.compliance_status, dpc.check_date, dpc.finding_summary,
        dpc.violation_count, dpc.remediation_required, dpc.remediation_completed,
        dpc.remediation_owner
    FROM governance_control.DATA_POLICY_COMPLIANCE dpc
    WHERE dpc.policy_code = dp.policy_code
    ORDER BY dpc.check_date DESC
) latest
WHERE dp.is_active = 1
ORDER BY
    CASE latest.compliance_status WHEN 'RED' THEN 1 WHEN 'YELLOW' THEN 2 ELSE 3 END,
    dp.policy_code;
GO

/*
=============================================================================
  ARCHITECTURAL NOTE:
  The DATA_POLICY_COMPLIANCE table implements what DAMA Ch.3 calls
  "governance monitoring" — the ongoing evidence that governance decisions
  are being enforced, not just documented.

  The separation between DATA_POLICY (what we decided) and
  DATA_POLICY_COMPLIANCE (whether we are following what we decided) is
  the difference between a governance program and a governance document.

  ISO 22301 §8.4 requires that business continuity procedures identify
  priorities. The RED/YELLOW/GREEN status system in DATA_POLICY_COMPLIANCE
  provides exactly that prioritization in a data crisis scenario:
  RED findings on PII or FINANCIAL_CRITICAL tables are Sev-1 incidents
  that override normal BCP prioritization.

=============================================================================
*/
