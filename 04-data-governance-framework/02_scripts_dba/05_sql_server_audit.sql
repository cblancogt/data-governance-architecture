/*
=============================================================================
  TRANSTRACK — Data Governance Architecture
  Script:  05_sql_server_audit.sql
  Purpose: Enable SQL Server Audit at server level. Create database audit
           specification targeting classified tables. Generate compliance
           reports from audit logs.
Validated by: Carlos Blanco
  Ref:     DAMA-DMBOK 2nd Ed. Ch.7 — Data Security
           ISO 27001:2022 A.8.15 — Logging
           ISO 27001:2022 A.5.12 — Classification of information
           Inside Out SQL Server 2022, Ch.13 — SQL Server Audit
           https://learn.microsoft.com/en-us/sql/relational-databases/
                   security/auditing/sql-server-audit-database-engine
  Depends: 01_domains_ownership.sql, 03_classification.sql, 04_rls_roles.sql
=============================================================================
*/

USE master;
GO

-- =============================================================================
-- SECTION 1: SERVER AUDIT
-- SQL Server Audit is configured at the server level.
-- The audit writes to a file — in production this would be a UNC path on a
-- dedicated audit server separate from the SQL Server instance.
-- In this lab environment, the file goes to the SQL Server data directory.
--
-- CRITICAL: The audit path must be accessible and the SQL Server service
-- account must have write permissions. Adjust the path to your environment.
-- =============================================================================

-- Drop existing audit if re-running
IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = 'TRANSTRACK_ServerAudit')
BEGIN
    ALTER SERVER AUDIT TRANSTRACK_ServerAudit WITH (STATE = OFF);
    DROP SERVER AUDIT TRANSTRACK_ServerAudit;
END;
GO

-- Create server audit writing to file
-- ADJUST PATH: Change 'C:\SQLAudit\TRANSTRACK\' to your environment's audit directory
-- The SQL Server service account must have WRITE access to this path
CREATE SERVER AUDIT TRANSTRACK_ServerAudit
TO FILE
(
    FILEPATH = 'C:\SQL_AUDIT\TRANSTRACK\',   -- Adjust for your environment
    MAXSIZE = 100 MB,
    MAX_ROLLOVER_FILES = 10,                 -- Keep last 10 files = up to 1GB history
    RESERVE_DISK_SPACE = OFF
)
WITH
(
    QUEUE_DELAY = 1000,         -- 1 second async flush (performance vs immediacy tradeoff)
    ON_FAILURE = CONTINUE       -- Do not stop SQL Server if audit fails to write
    -- In high-security environments, use ON_FAILURE = SHUTDOWN
    -- CONTINUE is appropriate for this lab and for most compliance scenarios
);
GO

-- Enable the server audit
ALTER SERVER AUDIT TRANSTRACK_ServerAudit WITH (STATE = ON);
GO

-- =============================================================================
-- SECTION 2: SERVER AUDIT SPECIFICATION
-- Captures server-level events: failed logins, permission changes.
-- These are security events that apply regardless of which database is accessed.
-- =============================================================================

IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = 'TRANSTRACK_ServerAuditSpec')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION TRANSTRACK_ServerAuditSpec WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION TRANSTRACK_ServerAuditSpec;
END;
GO

CREATE SERVER AUDIT SPECIFICATION TRANSTRACK_ServerAuditSpec
FOR SERVER AUDIT TRANSTRACK_ServerAudit
ADD (FAILED_LOGIN_GROUP),           -- Failed authentication attempts
ADD (SUCCESSFUL_LOGIN_GROUP),       -- Successful logins to server
ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP), -- Server role changes
ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP), -- Database role changes (user added to rol_legal etc.)
ADD (AUDIT_CHANGE_GROUP)            -- Changes to the audit itself (tamper detection)
WITH (STATE = ON);
GO

-- =============================================================================
-- SECTION 3: DATABASE AUDIT SPECIFICATION
-- Captures data access events on classified tables.
-- Targets: SELECT on PII tables, all DML on FINANCIAL_CRITICAL tables.
-- Reference: DATA_CLASSIFICATION table (Script 03) drives what we audit.
-- =============================================================================

USE TRANSTRACK;
GO

IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = 'TRANSTRACK_DbAuditSpec')
BEGIN
    ALTER DATABASE AUDIT SPECIFICATION TRANSTRACK_DbAuditSpec WITH (STATE = OFF);
    DROP DATABASE AUDIT SPECIFICATION TRANSTRACK_DbAuditSpec;
END;
GO

CREATE DATABASE AUDIT SPECIFICATION TRANSTRACK_DbAuditSpec
FOR SERVER AUDIT TRANSTRACK_ServerAudit

-- ============================================================
-- PII TABLES: Audit SELECT, INSERT, UPDATE, DELETE
-- Any access to personal data must be logged.
-- ============================================================

-- CLIENTE: PII — NIT, name, contact data
ADD (SELECT, INSERT, UPDATE, DELETE ON ventas.CLIENTE          BY PUBLIC),

-- ENTREGA: PII — recipient name and signature
ADD (SELECT, INSERT, UPDATE, DELETE ON operaciones.ENTREGA          BY PUBLIC),

-- INCIDENTE: PII — conductor_id links to driver identity
ADD (SELECT, INSERT, UPDATE, DELETE ON operaciones.INCIDENTE        BY PUBLIC),

-- CONDUCTOR: Highest PII — DPI, license, personal data
ADD (SELECT, INSERT, UPDATE, DELETE ON flota.CONDUCTOR        BY PUBLIC),

-- EMPLEADO: PII + salary (financial PII)
ADD (SELECT, INSERT, UPDATE, DELETE ON flota.EMPLEADO         BY PUBLIC),

-- OPERADOR: PII — operator name linked to driver
ADD (SELECT, INSERT, UPDATE, DELETE ON flota.OPERADOR         BY PUBLIC),

-- TELEMETRIA_GPS: PII when joined with conductor_id
-- Only audit DML (not SELECT — volume is 50M rows; SELECT audit would be impractical)
ADD (INSERT, UPDATE, DELETE ON flota.TELEMETRIA_GPS           BY PUBLIC),

-- ============================================================
-- FINANCIAL_CRITICAL TABLES: Audit all DML + SELECT
-- Any read or modification of financial data is logged.
-- ============================================================

ADD (SELECT, INSERT, UPDATE, DELETE ON facturacion.FACTURA          BY PUBLIC),
ADD (SELECT, INSERT, UPDATE, DELETE ON ventas.CONTRATO_CLIENTE BY PUBLIC),

-- ============================================================
-- GOVERNANCE METADATA TABLES: Audit modifications
-- Changes to the governance framework itself are logged.
-- ============================================================

ADD (INSERT, UPDATE, DELETE ON governance_control.DATA_CLASSIFICATION      BY PUBLIC),
ADD (INSERT, UPDATE, DELETE ON governance_control.DATA_POLICY              BY PUBLIC),
ADD (INSERT, UPDATE, DELETE ON governance_control.DOMAIN_TABLE_REGISTRY    BY PUBLIC),
ADD (INSERT, UPDATE, DELETE ON governance_control.CLIENT_USER_MAPPING      BY PUBLIC),

-- ============================================================
-- SCHEMA CHANGES: DDL audit (via SCHEMA_OBJECT_CHANGE_GROUP)
-- When someone alters the classification of a table, this is logged.
-- ============================================================
ADD (SCHEMA_OBJECT_CHANGE_GROUP)

WITH (STATE = ON);
GO

-- =============================================================================
-- SECTION 4: VERIFY AUDIT CONFIGURATION
-- =============================================================================

-- Confirm server audit is active
SELECT
    name                AS [Audit Name],
    audit_guid          AS [Audit GUID],
    type_desc           AS [Destination Type],
    on_failure_desc     AS [On Failure],
    is_state_enabled    AS [Enabled]
FROM sys.server_audits
WHERE name = 'TRANSTRACK_ServerAudit';
GO

-- Confirm database audit specification is active
SELECT
    name            AS [Spec Name],
    is_state_enabled AS [Enabled]
FROM sys.database_audit_specifications
WHERE name = 'TRANSTRACK_DbAuditSpec';
GO

-- List what is being audited (resolved object names from catalog views)
SELECT
    s.name                                   AS [Spec Name],
    dba.audit_action_name                    AS [Action Audited],
    CASE dba.class_desc
        WHEN 'OBJECT_OR_COLUMN' THEN OBJECT_SCHEMA_NAME(dba.major_id) + '.' + OBJECT_NAME(dba.major_id)
        ELSE dba.class_desc
    END                                       AS [Object],
    dba.audited_result                       AS [Result Tracked]
FROM sys.database_audit_specification_details dba
JOIN sys.database_audit_specifications s
    ON dba.database_specification_id = s.database_specification_id
WHERE s.name = 'TRANSTRACK_DbAuditSpec'
  AND dba.audit_action_name IS NOT NULL
ORDER BY [Object], dba.audit_action_name;
GO

-- =============================================================================
-- SECTION 5: COMPLIANCE REPORT FROM AUDIT LOG
-- Reads from sys.fn_get_audit_file() and generates a summary.
--
-- NOTE: This query reads the binary audit file. Adjust the path to match
-- the FILEPATH defined in Section 1.
-- The wildcard *.sqlaudit matches all rotation files.
-- =============================================================================

-- Raw audit log read — last 7 days
-- Reference: https://learn.microsoft.com/en-us/sql/relational-databases/
--                    system-functions/sys-fn-get-audit-file-transact-sql

/*
-- Uncomment when the audit path contains actual files:

SELECT TOP 100
    event_time                  AS [Event Time (UTC)],
    session_server_principal_name AS [User],
    action_id                   AS [Action],
    object_name                 AS [Object Accessed],
    statement                   AS [SQL Statement (truncated)],
    client_ip                   AS [Client IP],
    application_name            AS [Application],
    succeeded                   AS [Succeeded]
FROM sys.fn_get_audit_file('C:\SQLAudit\TRANSTRACK\*.sqlaudit', DEFAULT, DEFAULT)
WHERE event_time >= DATEADD(DAY, -7, GETUTCDATE())
ORDER BY event_time DESC;
*/

-- =============================================================================
-- SECTION 6: COMPLIANCE REPORT PROCEDURE
-- Generates a human-readable audit compliance report.
-- Answers the questions an auditor or regulator would ask:
--   - Who accessed PII data?
--   - Were any financial records modified?
--   - Did any user access data outside their role?
-- =============================================================================

IF OBJECT_ID('governance_control.usp_AuditComplianceReport', 'P') IS NOT NULL
    DROP PROCEDURE governance_control.usp_AuditComplianceReport;
GO

CREATE PROCEDURE governance_control.usp_AuditComplianceReport
    @days_back      INT = 30,
    @audit_path     NVARCHAR(500) = 'C:\SQLAudit\TRANSTRACK\*.sqlaudit'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cutoff DATETIME2 = DATEADD(DAY, -@days_back, GETUTCDATE());

    -- -------------------------------------------------------------------------
    -- Section A: Access summary by user and action
    -- -------------------------------------------------------------------------
    PRINT '=== SECTION A: Access Summary ===';

    SELECT
        session_server_principal_name   AS [User],
        action_id                       AS [Action],
        object_name                     AS [Object],
        COUNT(*)                        AS [Event Count],
        MIN(event_time)                 AS [First Event],
        MAX(event_time)                 AS [Last Event]
    FROM sys.fn_get_audit_file(@audit_path, DEFAULT, DEFAULT)
    WHERE event_time >= @cutoff
      AND database_name = 'TRANSTRACK'
    GROUP BY
        session_server_principal_name,
        action_id,
        object_name
    ORDER BY [Event Count] DESC;

    -- -------------------------------------------------------------------------
    -- Section B: PII access events
    -- Cross-reference with DATA_CLASSIFICATION to flag any SELECT on PII columns
    -- -------------------------------------------------------------------------
    PRINT '=== SECTION B: PII Table Access Events ===';

    SELECT
        af.event_time                           AS [Event Time (UTC)],
        af.session_server_principal_name        AS [User],
        af.action_id                            AS [Action],
        af.object_name                          AS [Object],
        af.client_ip                            AS [Client IP],
        af.application_name                     AS [Application],
        af.succeeded                            AS [Succeeded],
        -- Flag if user should have access based on role
        CASE
            WHEN af.session_server_principal_name IN (
                SELECT dp.name FROM sys.database_role_members drm
                JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
                JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id
                WHERE r.name IN ('rol_legal', 'rol_auditoria')
            ) THEN 'AUTHORIZED'
            ELSE 'REVIEW REQUIRED'
        END                                     AS [Access Status]
    FROM sys.fn_get_audit_file(@audit_path, DEFAULT, DEFAULT) af
    WHERE af.event_time >= @cutoff
      AND af.database_name = 'TRANSTRACK'
      AND af.object_name IN (
          SELECT DISTINCT table_name
          FROM governance_control.DATA_CLASSIFICATION
          WHERE classification_level = 'PII'
            AND requires_audit_log = 1
      )
    ORDER BY af.event_time DESC;

    -- -------------------------------------------------------------------------
    -- Section C: Failed access attempts (potential unauthorized access)
    -- -------------------------------------------------------------------------
    PRINT '=== SECTION C: Failed Access Attempts ===';

    SELECT
    event_time                              AS [Event Time (UTC)],
    session_server_principal_name           AS [User],
    action_id                               AS [Action],
    object_name                             AS [Object],
    client_ip                               AS [Client IP],
    LEFT(statement, 200)                    AS [Statement Preview]
    FROM sys.fn_get_audit_file(@audit_path, DEFAULT, DEFAULT)
    WHERE event_time >= @cutoff
      AND database_name = 'TRANSTRACK'
      AND succeeded = 0
    ORDER BY event_time DESC;

    -- -------------------------------------------------------------------------
    -- Section D: Financial data modifications
    -- Any INSERT/UPDATE/DELETE on FACTURA or CONTRATO_CLIENTE is high-risk
    -- -------------------------------------------------------------------------
    PRINT '=== SECTION D: Financial Data Modifications ===';

    SELECT
        event_time                              AS [Event Time (UTC)],
        session_server_principal_name           AS [User],
        action_id                               AS [Action],
        object_name                             AS [Object],
        LEFT(statement, 200)                    AS [Statement Preview],
        client_ip                               AS [Client IP]
    FROM sys.fn_get_audit_file(@audit_path, DEFAULT, DEFAULT)
    WHERE event_time >= @cutoff
      AND database_name = 'TRANSTRACK'
      AND action_id IN ('IN', 'UP', 'DL')  -- INSERT, UPDATE, DELETE
      AND object_name IN ('FACTURA', 'CONTRATO_CLIENTE')
    ORDER BY event_time DESC;

END;
GO

-- =============================================================================
-- SECTION 7: LOG THE AUDIT CONFIGURATION TO COMPLIANCE TABLE
-- =============================================================================

INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
    (policy_code, check_type, compliance_status, finding_summary, violation_detail)
VALUES
(
    'POLICY-001',
    'AUTOMATED',
    'GREEN',
    'SQL Server Audit configured and enabled. '
    + 'Server Audit: TRANSTRACK_ServerAudit. '
    + 'Database Audit Spec: TRANSTRACK_DbAuditSpec. '
    + 'Targets: All PII tables (SELECT+DML) and FINANCIAL_CRITICAL tables (SELECT+DML). '
    + 'Schema change auditing enabled.',
    'ISO 27001:2022 A.8.15 implemented. '
    + 'Audit path: C:\SQLAudit\TRANSTRACK\. '
    + 'Retention: 10 rotation files of 100MB each (approx 1GB audit history).'
);
GO

/*
=============================================================================
  ARCHITECTURAL NOTE:
  SQL Server Audit has a key advantage over application-level logging:
  it operates below the application layer. Even if an attacker bypasses
  the application and connects directly to SQL Server with valid credentials,
  the audit captures the access.

  The ON_FAILURE = CONTINUE setting is a deliberate tradeoff for this lab:
    - ON_FAILURE = SHUTDOWN: Maximum security — if audit fails, SQL Server stops.
      Appropriate for financial systems under SOX or payment systems under PCI-DSS.
    - ON_FAILURE = CONTINUE: Maximum availability — audit failure is logged but
      SQL Server continues. Appropriate for operational systems where downtime
      cost exceeds the audit gap risk.
  
  For TRANSTRACK's FINANCIAL_CRITICAL data (FACTURA, CONTRATO_CLIENTE),
  the recommendation to the DGC is ON_FAILURE = FAIL_OPERATION for those
  specific tables — meaning the transaction fails if audit cannot write,
  but SQL Server stays up.

  TELEMETRIA_GPS audit strategy: Auditing SELECT on 50M rows at 5-minute
  intervals would generate an audit log larger than the data itself.
  This script audits DML only on TELEMETRIA_GPS. SELECT access is governed
  through RLS and the access report from sys.dm_exec_query_stats.

  ISO 27001:2022 A.8.15 Reference:
  https://www.iso.org/standard/82875.html
  SQL Server Audit Reference:
  https://learn.microsoft.com/en-us/sql/relational-databases/security/auditing/sql-server-audit-database-engine
=============================================================================
*/
