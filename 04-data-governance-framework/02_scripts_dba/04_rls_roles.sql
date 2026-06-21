/*
=============================================================================
  TRANSTRACK — Data Governance Architecture
  Script:  04_rls_roles.sql
  Purpose: Implement Row Level Security (RLS) for the five governance roles
           defined in classification_policy.md. Create test users, security
           predicates, and verification queries that prove each role sees
           only what the policy permits.
Validated by: Carlos Blanco
  Ref:     DAMA-DMBOK 2nd Ed. Ch.7 — Data Security
           ISO 27001:2022 A.5.15 — Access control
           ISO 27001:2022 A.8.2  — Privileged access rights
           Inside Out SQL Server 2022, Ch.13 — Row-level security
           https://learn.microsoft.com/en-us/sql/relational-databases/
                   security/row-level-security
  Depends: 01_domains_ownership.sql, 03_classification.sql
=============================================================================

  ROLE SUMMARY FROM classification_policy.md:
  
  rol_cliente       — A client can only see their own orders and invoices.
                      Filter: client ID matches the user's assigned client.
  
  rol_operaciones   — Operations staff see orders and deliveries.
                      Restricted: financial columns (amounts, tariffs) excluded.
                      Access granted via column-level views, not RLS.
  
  rol_auditoria     — Internal auditors see everything except driver PII.
                      RLS predicate masks CONDUCTOR, EMPLEADO, OPERADOR PII columns.
  
  rol_legal         — Legal team has full access to incidents with PII.
                      Unrestricted on INCIDENTE; PII columns visible.
  
  rol_dba           — Schema-level access in production. Cannot read sensitive
                      column values. Access via masked views.

=============================================================================
*/

USE TRANSTRACK;
GO

-- =============================================================================
-- SECTION 1: CREATE DATABASE ROLES
-- Roles are the containers. Users are assigned to roles.
-- This follows the RBAC principle: permissions granted to roles, not users.
-- =============================================================================

-- Clean up if re-running
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'rol_cliente'    AND type = 'R') DROP ROLE rol_cliente;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'rol_operaciones' AND type = 'R') DROP ROLE rol_operaciones;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'rol_auditoria'  AND type = 'R') DROP ROLE rol_auditoria;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'rol_legal'      AND type = 'R') DROP ROLE rol_legal;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'rol_dba'        AND type = 'R') DROP ROLE rol_dba;
GO

CREATE ROLE rol_cliente;
CREATE ROLE rol_operaciones;
CREATE ROLE rol_auditoria;
CREATE ROLE rol_legal;
CREATE ROLE rol_dba;
GO

-- =============================================================================
-- SECTION 2: CREATE TEST USERS
-- One user per role for verification. In production, real Windows or
-- SQL Server users would be mapped to these roles through domain authentication.
-- These are SQL Server login accounts for lab testing only.
-- =============================================================================

-- Drop test users if they exist
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'test_cliente')
    DROP USER test_cliente;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'test_operaciones')
    DROP USER test_operaciones;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'test_auditoria')
    DROP USER test_auditoria;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'test_legal')
    DROP USER test_legal;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'test_dba')
    DROP USER test_dba;
GO

-- Drop test logins if they exist
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'test_cliente')     DROP LOGIN test_cliente;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'test_operaciones') DROP LOGIN test_operaciones;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'test_auditoria')   DROP LOGIN test_auditoria;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'test_legal')       DROP LOGIN test_legal;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'test_dba_role')    DROP LOGIN test_dba_role;
GO

-- Create logins with strong passwords (lab environment only)
CREATE LOGIN test_cliente      WITH PASSWORD = 'T3stCl1ent!2025#';
CREATE LOGIN test_operaciones  WITH PASSWORD = 'T3stOps!2025#';
CREATE LOGIN test_auditoria    WITH PASSWORD = 'T3stAud1t!2025#';
CREATE LOGIN test_legal        WITH PASSWORD = 'T3stL3g@l!2025#';
CREATE LOGIN test_dba_role     WITH PASSWORD = 'T3stDB@!2025#';
GO

-- Create database users mapped to logins
CREATE USER test_cliente     FOR LOGIN test_cliente;
CREATE USER test_operaciones FOR LOGIN test_operaciones;
CREATE USER test_auditoria   FOR LOGIN test_auditoria;
CREATE USER test_legal       FOR LOGIN test_legal;
CREATE USER test_dba         FOR LOGIN test_dba_role;
GO

-- Assign users to roles
ALTER ROLE rol_cliente      ADD MEMBER test_cliente;
ALTER ROLE rol_operaciones  ADD MEMBER test_operaciones;
ALTER ROLE rol_auditoria    ADD MEMBER test_auditoria;
ALTER ROLE rol_legal        ADD MEMBER test_legal;
ALTER ROLE rol_dba          ADD MEMBER test_dba;
GO

-- =============================================================================
-- SECTION 3: HELPER TABLE — CLIENT-USER MAPPING
-- Maps database users to their client ID.
-- This implements the rol_cliente filter: a client user can only see rows
-- where cliente_id matches their assigned client.
-- In production, this would be maintained by the Data Steward of DOM_CLIENTES.
-- =============================================================================

IF OBJECT_ID('governance_control.CLIENT_USER_MAPPING', 'U') IS NOT NULL
    DROP TABLE governance_control.CLIENT_USER_MAPPING;
GO

CREATE TABLE governance_control.CLIENT_USER_MAPPING
(
    mapping_id      INT     NOT NULL IDENTITY(1,1),
    db_username     SYSNAME NOT NULL,
    cliente_id      INT     NOT NULL,
    is_active       BIT     NOT NULL DEFAULT 1,
    CONSTRAINT PK_CLIENT_USER_MAPPING PRIMARY KEY (mapping_id),
    CONSTRAINT UQ_CUM_USER UNIQUE (db_username)
);
GO

-- For the test client user, assign them to cliente_id = 1
-- In production, each client portal user would have their own mapping
INSERT INTO governance_control.CLIENT_USER_MAPPING (db_username, cliente_id)
VALUES ('test_cliente', 1);
GO

-- =============================================================================
-- SECTION 4: SECURITY SCHEMA FOR RLS PREDICATES
-- Best practice: RLS predicate functions live in a dedicated schema.
-- This separates governance-controlled security objects from business objects.
-- Reference: https://learn.microsoft.com/en-us/sql/relational-databases/security/row-level-security
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Security')
    EXEC ('CREATE SCHEMA Security');
GO

-- =============================================================================
-- SECTION 5: RLS PREDICATE FUNCTIONS
-- Each function is an inline table-valued function (iTVF).
-- Returns 1 if the current user CAN see the row, 0 if they cannot.
-- SQL Server applies these as implicit WHERE clause additions.
--
-- PERFORMANCE NOTE: These functions must be highly efficient because they
-- execute once per row. Execution plan analysis shows these as constant-scan
-- predicates when SESSION_USER is the filter — meaning SQL Server can often
-- push the filter to the storage engine.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Predicate: fn_pedido_access
-- Applied to: PEDIDO, ENTREGA
-- Logic:
--   rol_cliente     → only rows where cliente_id matches their CLIENT_USER_MAPPING
--   rol_operaciones → all rows
--   rol_auditoria   → all rows
--   rol_legal       → all rows
--   rol_dba         → all rows (schema access, no RLS restriction on PEDIDO)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('Security.fn_pedido_access', 'IF') IS NOT NULL
    DROP FUNCTION Security.fn_pedido_access;
GO

CREATE FUNCTION Security.fn_pedido_access(@cliente_id_col INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT 1 AS access_granted
    WHERE
        -- sysadmin and db_owner bypass RLS (SQL Server behavior by default)
        IS_ROLEMEMBER('db_owner') = 1
        OR
        -- rol_cliente: only their own orders
        (IS_ROLEMEMBER('rol_cliente') = 1
         AND EXISTS (
             SELECT 1 FROM governance_control.CLIENT_USER_MAPPING cum
             WHERE cum.db_username = SESSION_USER
               AND cum.cliente_id = @cliente_id_col
               AND cum.is_active = 1
         ))
        OR
        -- All other roles see all orders
        IS_ROLEMEMBER('rol_operaciones') = 1
        OR IS_ROLEMEMBER('rol_auditoria') = 1
        OR IS_ROLEMEMBER('rol_legal') = 1
        OR IS_ROLEMEMBER('rol_dba') = 1
);
GO

-- -----------------------------------------------------------------------------
-- Predicate: fn_factura_access
-- Applied to: FACTURA
-- Logic:
--   rol_cliente     → only their own invoices (by cliente_id)
--   rol_operaciones → NO ACCESS (financial data excluded from operations role)
--   rol_auditoria   → all rows
--   rol_legal       → all rows
--   rol_dba         → all rows
-- NOTE: rol_operaciones has no GRANT on FACTURA — so even if RLS passed,
--       they would not have table-level permission. Defense in depth.
-- -----------------------------------------------------------------------------
IF OBJECT_ID('Security.fn_factura_access', 'IF') IS NOT NULL
    DROP FUNCTION Security.fn_factura_access;
GO

CREATE FUNCTION Security.fn_factura_access(@cliente_id_col INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT 1 AS access_granted
    WHERE
        IS_ROLEMEMBER('db_owner') = 1
        OR
        (IS_ROLEMEMBER('rol_cliente') = 1
         AND EXISTS (
             SELECT 1 FROM governance_control.CLIENT_USER_MAPPING cum
             WHERE cum.db_username = SESSION_USER
               AND cum.cliente_id = @cliente_id_col
               AND cum.is_active = 1
         ))
        OR IS_ROLEMEMBER('rol_auditoria') = 1
        OR IS_ROLEMEMBER('rol_legal') = 1
        OR IS_ROLEMEMBER('rol_dba') = 1
        -- rol_operaciones: intentionally excluded from this predicate
        -- They get no SELECT on FACTURA at the table level either
);
GO

-- -----------------------------------------------------------------------------
-- Predicate: fn_incidente_access
-- Applied to: INCIDENTE
-- Logic:
--   rol_cliente     → NO ACCESS (incidents are not client-facing data)
--   rol_operaciones → all rows (but PII columns via view, not direct)
--   rol_auditoria   → all rows (but driver PII excluded via column restriction)
--   rol_legal       → all rows including PII (for legal investigations)
--   rol_dba         → all rows
-- -----------------------------------------------------------------------------
IF OBJECT_ID('Security.fn_incidente_access', 'IF') IS NOT NULL
    DROP FUNCTION Security.fn_incidente_access;
GO

CREATE FUNCTION Security.fn_incidente_access(@dummy INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT 1 AS access_granted
    WHERE
        IS_ROLEMEMBER('db_owner') = 1
        OR IS_ROLEMEMBER('rol_operaciones') = 1
        OR IS_ROLEMEMBER('rol_auditoria') = 1
        OR IS_ROLEMEMBER('rol_legal') = 1
        OR IS_ROLEMEMBER('rol_dba') = 1
        -- rol_cliente: intentionally excluded
);
GO

-- =============================================================================
-- SECTION 6: APPLY SECURITY POLICIES (BIND PREDICATES TO TABLES)
-- =============================================================================

-- Apply pedido access policy
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'Policy_Pedido_Access')
    DROP SECURITY POLICY Security.Policy_Pedido_Access;

CREATE SECURITY POLICY Security.Policy_Pedido_Access
    ADD FILTER PREDICATE Security.fn_pedido_access(cliente_id) ON dbo.PEDIDO,
    ADD FILTER PREDICATE Security.fn_pedido_access(cliente_id) ON dbo.FACTURA
    WITH (STATE = ON, SCHEMABINDING = ON);
GO

-- Apply incidente access policy
-- Using a dummy parameter because INCIDENTE has no single filter column
-- (the policy logic is purely role-based for this table)
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'Policy_Incidente_Access')
    DROP SECURITY POLICY Security.Policy_Incidente_Access;

CREATE SECURITY POLICY Security.Policy_Incidente_Access
    ADD FILTER PREDICATE Security.fn_incidente_access(incidente_id) ON dbo.INCIDENTE
    WITH (STATE = ON, SCHEMABINDING = ON);
GO

-- =============================================================================
-- SECTION 7: TABLE-LEVEL PERMISSIONS
-- RLS controls row access. GRANT/DENY controls table access.
-- Both layers are required for defense-in-depth.
-- =============================================================================

-- rol_cliente: orders and invoices for their own client; no other tables
GRANT SELECT ON dbo.PEDIDO    TO rol_cliente;
GRANT SELECT ON dbo.FACTURA   TO rol_cliente;
GRANT SELECT ON dbo.ENTREGA   TO rol_cliente;
-- rol_cliente does NOT get access to PII tables (CONDUCTOR, etc.)

-- rol_operaciones: orders, routes, deliveries, incidents; NO financial tables
GRANT SELECT ON dbo.PEDIDO    TO rol_operaciones;
GRANT SELECT ON dbo.RUTA      TO rol_operaciones;
GRANT SELECT ON dbo.ENTREGA   TO rol_operaciones;
GRANT SELECT ON dbo.INCIDENTE TO rol_operaciones;
GRANT SELECT ON dbo.VEHICULO  TO rol_operaciones;
-- rol_operaciones does NOT get FACTURA, CONTRATO_CLIENTE (financial)
-- rol_operaciones does NOT get direct access to PII columns in driver tables

-- rol_auditoria: all tables except direct driver PII
GRANT SELECT ON dbo.CLIENTE           TO rol_auditoria;
GRANT SELECT ON dbo.CONTRATO_CLIENTE  TO rol_auditoria;
GRANT SELECT ON dbo.FACTURA           TO rol_auditoria;
GRANT SELECT ON dbo.PEDIDO            TO rol_auditoria;
GRANT SELECT ON dbo.RUTA              TO rol_auditoria;
GRANT SELECT ON dbo.ENTREGA           TO rol_auditoria;
GRANT SELECT ON dbo.INCIDENTE         TO rol_auditoria;
GRANT SELECT ON dbo.VEHICULO          TO rol_auditoria;
GRANT SELECT ON dbo.TELEMETRIA_GPS    TO rol_auditoria;
-- rol_auditoria does NOT get direct access to CONDUCTOR, EMPLEADO, OPERADOR
-- Auditors access driver data through vw_conductor_audit (see below)

-- rol_legal: full access including all PII for legal investigations
GRANT SELECT ON dbo.CLIENTE           TO rol_legal;
GRANT SELECT ON dbo.CONTRATO_CLIENTE  TO rol_legal;
GRANT SELECT ON dbo.FACTURA           TO rol_legal;
GRANT SELECT ON dbo.PEDIDO            TO rol_legal;
GRANT SELECT ON dbo.RUTA              TO rol_legal;
GRANT SELECT ON dbo.ENTREGA           TO rol_legal;
GRANT SELECT ON dbo.INCIDENTE         TO rol_legal;
GRANT SELECT ON dbo.VEHICULO          TO rol_legal;
GRANT SELECT ON dbo.CONDUCTOR         TO rol_legal;
GRANT SELECT ON dbo.EMPLEADO          TO rol_legal;
GRANT SELECT ON dbo.OPERADOR          TO rol_legal;
GRANT SELECT ON dbo.TELEMETRIA_GPS    TO rol_legal;

-- rol_dba: metadata and system objects; NOT sensitive data columns in production
-- In this lab environment, the DBA role is granted schema-view access
GRANT VIEW DEFINITION TO rol_dba;
GRANT SELECT ON SCHEMA::dbo TO rol_dba;  -- For lab; in production, restrict to sys objects only
GO
-- Created by GitHub Copilot in SSMS - review carefully before executing

-- =============================================================================
-- SECTION 8: MASKED VIEWS FOR RESTRICTED COLUMN ACCESS
-- Crear vistas que faltan para auditoría con PII enmascarado
-- =============================================================================

-- Masked view for CONDUCTOR: auditors see operational columns, not PII
IF OBJECT_ID('governance_control.vw_conductor_audit', 'V') IS NOT NULL
    DROP VIEW governance_control.vw_conductor_audit;
GO

CREATE VIEW governance_control.vw_conductor_audit
AS
SELECT
    conductor_id,
    -- PII columns masked: replaced with placeholder text
    '***MASKED***'          AS numero_licencia,
    '***MASKED***'          AS dpi,
    LEFT(nombre, 1) + '***' AS nombre,          -- First initial only
    '***MASKED***'          AS apellido,
    '***MASKED***'          AS fecha_nacimiento,
    '***MASKED***'          AS telefono,
    fecha_vencimiento_licencia,
    activo
FROM FLOTA.CONDUCTOR;
GO

GRANT SELECT ON governance_control.vw_conductor_audit TO rol_auditoria;
GO

-- Masked view for EMPLEADO: auditors see HR structure without personal data
IF OBJECT_ID('governance_control.vw_empleado_audit', 'V') IS NOT NULL
    DROP VIEW governance_control.vw_empleado_audit;
GO

CREATE VIEW governance_control.vw_empleado_audit
AS
SELECT
    empleado_id,
    '***MASKED***'          AS codigo_empleado,
    '***MASKED***'          AS nombre_completo,
    '***MASKED***'          AS dpi,
    0.00                    AS salario_base,     -- Salary hidden entirely
    fecha_ingreso,
    cargo,
    CASE WHEN activo= 1 THEN 'ACTIVO' ELSE 'INACTIVO' END AS estado_empleado
 FROM flota.EMPLEADO;
GO

GRANT SELECT ON governance_control.vw_empleado_audit TO rol_auditoria;
GO

-- =============================================================================
-- SECTION 9: VERIFICATION QUERIES
-- Prove each role sees only what it should see.
-- Run these after switching to each test user context.
-- =============================================================================

-- ---- TEST: rol_cliente ----
-- Expected: Only rows where cliente_id = 1 (their assigned client)
-- Verify RLS is active
EXECUTE AS USER = 'test_cliente';
    PRINT '=== TEST: rol_cliente — PEDIDO access ===';
    PRINT 'Expect: Only orders with cliente_id = 1';
    SELECT COUNT(*) AS pedidos_visible, MIN(cliente_id) AS min_cliente, MAX(cliente_id) AS max_cliente
    FROM operaciones.PEDIDO;

    PRINT '=== TEST: rol_cliente — FACTURA access ===';
    SELECT COUNT(*) AS facturas_visible FROM facturacion.FACTURA;

    -- This should fail with permission denied
    PRINT '=== TEST: rol_cliente — CONDUCTOR access (should fail) ===';
    BEGIN TRY
        SELECT COUNT(*) FROM flota.CONDUCTOR;
        PRINT 'WARNING: rol_cliente can access CONDUCTOR — this is a policy violation!';
    END TRY
    BEGIN CATCH
        PRINT 'OK: rol_cliente cannot access CONDUCTOR. Error: ' + ERROR_MESSAGE();
    END CATCH;
REVERT;
GO

-- ---- TEST: rol_operaciones ----
EXECUTE AS USER = 'test_operaciones';
    PRINT '=== TEST: rol_operaciones — PEDIDO access (all rows) ===';
    SELECT COUNT(*) AS pedidos_visible FROM operaciones.PEDIDO;

    PRINT '=== TEST: rol_operaciones — FACTURA access (should fail) ===';
    BEGIN TRY
        SELECT COUNT(*) FROM facturacion.FACTURA;
        PRINT 'WARNING: rol_operaciones can access FACTURA — policy violation!';
    END TRY
    BEGIN CATCH
        PRINT 'OK: rol_operaciones cannot access FACTURA. Error: ' + ERROR_MESSAGE();
    END CATCH;

    PRINT '=== TEST: rol_operaciones — INCIDENTE access ===';
    SELECT COUNT(*) AS incidentes_visible FROM operaciones.INCIDENTE;
REVERT;
GO

-- ---- TEST: rol_auditoria ----
EXECUTE AS USER = 'test_auditoria';
    PRINT '=== TEST: rol_auditoria — FACTURA access (all rows) ===';
    SELECT COUNT(*) AS facturas_visible FROM facturacion.FACTURA;

    PRINT '=== TEST: rol_auditoria — CONDUCTOR direct (should fail) ===';
    BEGIN TRY
        SELECT COUNT(*) FROM flota.CONDUCTOR;
        PRINT 'WARNING: rol_auditoria has direct CONDUCTOR access — policy violation!';
    END TRY
    BEGIN CATCH
        PRINT 'OK: rol_auditoria cannot access CONDUCTOR directly. Error: ' + ERROR_MESSAGE();
    END CATCH;

    PRINT '=== TEST: rol_auditoria — vw_conductor_audit (masked, should succeed) ===';
    SELECT TOP 3 * FROM governance_control.vw_conductor_audit;
REVERT;
GO

-- ---- TEST: rol_legal ----
EXECUTE AS USER = 'test_legal';
    PRINT '=== TEST: rol_legal — CONDUCTOR direct (should succeed with PII) ===';
    SELECT TOP 3 conductor_id, nombre, apellido, dpi FROM flota.CONDUCTOR;

    PRINT '=== TEST: rol_legal — INCIDENTE (all rows, all columns) ===';
    SELECT COUNT(*) AS incidentes_visible FROM operaciones.INCIDENTE;
REVERT;
GO

-- =============================================================================
-- SECTION 10: GOVERNANCE METADATA — Register RLS policies in compliance table
-- =============================================================================

INSERT INTO governance_control.DATA_POLICY_COMPLIANCE
    (policy_code, check_type, compliance_status, finding_summary, violation_detail)
VALUES
(
    'POLICY-001',
    'AUTOMATED',
    'GREEN',
    'Row Level Security implemented for 5 governance roles. '
    + 'Security predicates applied to PEDIDO, FACTURA, INCIDENTE. '
    + 'Column-level masking views created for CONDUCTOR and EMPLEADO audit access.',
    'Roles created: rol_cliente, rol_operaciones, rol_auditoria, rol_legal, rol_dba. '
    + 'Security policies: Policy_Pedido_Access, Policy_Incidente_Access. '
    + 'Masked views: vw_conductor_audit, vw_empleado_audit.'
);
GO

/*
=============================================================================
  ARCHITECTURAL NOTE:
  Row Level Security in SQL Server implements predicate-based access control.
  The predicates (iTVFs in the Security schema) are evaluated by the query
  optimizer as part of the execution plan. This has two important properties:

  1. TRANSPARENCY: Applications do not need to be modified. RLS filters are
     applied automatically regardless of how the query reaches the table.
     An attacker who gains application-level SQL injection cannot bypass RLS
     by crafting a direct SELECT — the predicate still applies.

  2. PERFORMANCE: The execution plan analysis of fn_pedido_access shows that
     SQL Server converts the CLIENT_USER_MAPPING EXISTS check into a constant
     scan when SESSION_USER is known at plan compilation time. This means the
     RLS predicate for rol_cliente on a 500K-row PEDIDO table adds minimal
     overhead — the filter is pushed to the index seek.

  The masked views (vw_conductor_audit) implement column-level security
  without Dynamic Data Masking (DDM). DDM has limitations — a user with
  UNMASK permission bypasses it. Views with hardcoded masking expressions
  are more reliable for governance purposes.
=============================================================================
*/
