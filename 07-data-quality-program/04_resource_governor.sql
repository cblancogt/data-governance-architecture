/* ============================================================================
   PROJECT  : P02 - Data Governance Architecture (TRANSTRACK)
   FOLDER   : 07-quality-program
   FILE     : 04_resource_governor.sql
   PURPOSE  : Isolate the data quality workload from the OLTP workload using
              SQL Server Resource Governor, so heavy quality scans (notably
              the ~50M-row TELEMETRIA_GPS accuracy rules) cannot starve the
              transactional system.

   DBA PRACTICE : Resource Governor (Enterprise/Developer edition feature).
              Docs: https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/resource-governor

   ----------------------------------------------------------------------------
   *** INSTANCE-WIDE IMPACT - READ BEFORE RUNNING ***
   ----------------------------------------------------------------------------
   - Resource Governor is an INSTANCE-level feature. The pool, the workload
     group and the classifier affect EVERY database on this instance, not just
     TRANSTRACK.
   - The classifier function MUST live in the master database. This is a hard
     SQL Server requirement.
   - A broken classifier function can misroute or block sessions. If that
     happens, connect through the Dedicated Admin Connection (DAC), which
     bypasses the classifier, and disable Resource Governor (rollback block
     at the bottom of this file).
   - Recommended: run this on the lab instance only.

   ----------------------------------------------------------------------------
   ROUTING CONTRACT (ties to quality_check.py)
   ----------------------------------------------------------------------------
   Sessions whose application name is 'TRANSTRACK_QualityCheck' are routed to
   the dedicated quality pool. quality_check.py sets APP=TRANSTRACK_QualityCheck
   in its ODBC connection string. Everything else stays on the default group.

   SCHEMA   : classifier function -> master.dbo (RG requirement)
   ============================================================================ */

SET NOCOUNT ON;
GO

/* ----------------------------------------------------------------------------
   0) Show the CURRENT classifier (so you know if you are replacing one).
   ---------------------------------------------------------------------------- */
SELECT
    CASE WHEN classifier_function_id = 0 THEN 'NONE'
         ELSE QUOTENAME(OBJECT_SCHEMA_NAME(classifier_function_id, DB_ID('master')))
              + '.' + QUOTENAME(OBJECT_NAME(classifier_function_id, DB_ID('master')))
    END                                   AS current_classifier,
    is_reconfiguration_pending
FROM sys.dm_resource_governor_configuration;
GO

/* ----------------------------------------------------------------------------
   1) RESOURCE POOL : rp_quality_checks
   Caps CPU and (critically, on a 16GB box) memory so quality checks cannot
   dominate the instance. CAP_CPU_PERCENT is a HARD ceiling.
   ---------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.resource_governor_resource_pools WHERE name = N'rp_quality_checks')
BEGIN
    CREATE RESOURCE POOL rp_quality_checks
    WITH (
        MIN_CPU_PERCENT    = 0,
        MAX_CPU_PERCENT    = 40,   -- soft cap: only under CPU contention
        CAP_CPU_PERCENT    = 60,   -- hard ceiling: never exceed this
        MIN_MEMORY_PERCENT = 0,
        MAX_MEMORY_PERCENT = 25    -- protect OLTP buffer/workspace memory (16GB host)
    );
    PRINT 'Created resource pool rp_quality_checks';
END
ELSE
BEGIN
    ALTER RESOURCE POOL rp_quality_checks
    WITH (
        MIN_CPU_PERCENT    = 0,
        MAX_CPU_PERCENT    = 40,
        CAP_CPU_PERCENT    = 60,
        MIN_MEMORY_PERCENT = 0,
        MAX_MEMORY_PERCENT = 25
    );
    PRINT 'Altered existing resource pool rp_quality_checks';
END
GO

/* ----------------------------------------------------------------------------
   2) WORKLOAD GROUP : wg_quality_checks
   LOW importance so OLTP wins scheduling ties; capped DOP so a single quality
   scan cannot grab every core.
   ---------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.resource_governor_workload_groups WHERE name = N'wg_quality_checks')
BEGIN
    CREATE WORKLOAD GROUP wg_quality_checks
    WITH (
        IMPORTANCE                       = LOW,
        MAX_DOP                          = 2,   -- limit parallelism of quality scans
        REQUEST_MAX_MEMORY_GRANT_PERCENT = 25,
        GROUP_MAX_REQUESTS               = 0    -- unlimited concurrent requests within the pool
    )
    USING rp_quality_checks;
    PRINT 'Created workload group wg_quality_checks';
END
ELSE
BEGIN
    ALTER WORKLOAD GROUP wg_quality_checks
    WITH (
        IMPORTANCE                       = LOW,
        MAX_DOP                          = 2,
        REQUEST_MAX_MEMORY_GRANT_PERCENT = 25,
        GROUP_MAX_REQUESTS               = 0
    )
    USING rp_quality_checks;
    PRINT 'Altered existing workload group wg_quality_checks';
END
GO

/* ----------------------------------------------------------------------------
   3) CLASSIFIER FUNCTION : master.dbo.fn_rg_classifier_transtrack
   MUST be created in master and be schema-bound. Routes quality-check sessions
   (by application name) to wg_quality_checks; everyone else to 'default'.
   ---------------------------------------------------------------------------- */
USE master;
GO

CREATE OR ALTER FUNCTION dbo.fn_rg_classifier_transtrack()
RETURNS sysname
WITH SCHEMABINDING
AS
BEGIN
    -- Default: everything runs in the default workload group.
    DECLARE @group sysname = N'default';

    -- Route only the quality-check application to the dedicated group.
    -- quality_check.py connects with APP=TRANSTRACK_QualityCheck.
    IF APP_NAME() = N'TRANSTRACK_QualityCheck'
        SET @group = N'wg_quality_checks';

    RETURN @group;
END;
GO

/* ----------------------------------------------------------------------------
   4) Register the classifier and apply the configuration.
   ---------------------------------------------------------------------------- */
ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.fn_rg_classifier_transtrack);
GO

ALTER RESOURCE GOVERNOR RECONFIGURE;
GO

PRINT 'Resource Governor configured and reconfigured.';
GO

/* ----------------------------------------------------------------------------
   5) VERIFICATION
   ---------------------------------------------------------------------------- */
-- Pools and their caps
SELECT name, min_cpu_percent, max_cpu_percent, cap_cpu_percent,
       min_memory_percent, max_memory_percent
FROM sys.resource_governor_resource_pools
WHERE name IN (N'default', N'rp_quality_checks');

-- Groups and their pool binding
SELECT g.name AS workload_group, p.name AS resource_pool,
       g.importance, g.max_dop, g.request_max_memory_grant_percent
FROM sys.resource_governor_workload_groups g
INNER JOIN sys.resource_governor_resource_pools p ON g.pool_id = p.pool_id
WHERE g.name IN (N'default', N'wg_quality_checks');

-- Active classifier
SELECT OBJECT_SCHEMA_NAME(classifier_function_id, DB_ID('master')) + '.' +
       OBJECT_NAME(classifier_function_id, DB_ID('master')) AS active_classifier,
       is_reconfiguration_pending
FROM sys.dm_resource_governor_configuration;
GO

/* ============================================================================
   ROLLBACK / EMERGENCY (commented - run manually if needed)
   ----------------------------------------------------------------------------
   -- If sessions are misrouted, connect via the DAC (ADMIN:<server>) and run:
   --
   --   USE master;
   --   ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);
   --   ALTER RESOURCE GOVERNOR RECONFIGURE;
   --   DROP FUNCTION IF EXISTS dbo.fn_rg_classifier_transtrack;
   --   DROP WORKLOAD GROUP wg_quality_checks;
   --   DROP RESOURCE POOL  rp_quality_checks;
   --   ALTER RESOURCE GOVERNOR RECONFIGURE;
   --
   -- To fully disable Resource Governor:
   --   ALTER RESOURCE GOVERNOR DISABLE;
   ============================================================================ */

/* ============================================================================
   ARCHITECTURAL CONCLUSION (for README)
   ----------------------------------------------------------------------------
   Governance measurement must never degrade the system it measures. By pinning
   the quality workload to a capped pool (hard CPU ceiling, 25% memory, DOP 2,
   LOW importance) and routing it purely by application identity, the 50M-row
   telemetry scans run without competing with OLTP for scheduling or buffer
   memory. The classifier lives in master because Resource Governor is an
   instance-level control - the same reason this change carries an explicit
   blast-radius warning and a DAC-based rollback path.
   ============================================================================ */
