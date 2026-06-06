-- =============================================================================
-- P02 | TRANSTRACK Data Governance Architecture
-- Week 03 | Script 06: Query Store Baseline & Wait Stats
-- File: 06_query_store_baseline.sql
-- Author: cblancogt
--
-- DBA sub-track: establishes performance baseline before and after running
-- the Week 03 diagnostic scripts (01 through 05).
--
-- Run order:
--   1. Execute STEP 1 (enable Query Store) — once
--   2. Execute STEP 2 (PRE snapshot) — before running scripts 01–05
--   3. Run scripts 01_duplicate_clients.sql through 05_business_impact.sql
--   4. Execute STEP 3 (POST snapshot) — after running scripts 01–05
--   5. Execute STEP 4 (delta analysis) — compares pre vs post
--   6. Execute STEP 5 (Query Store top consumers) — reads from QS
-- =============================================================================

USE master;
GO

-- =============================================================================
-- STEP 1: Enable and configure Query Store on TRANSTRACK
-- Safe to re-run — idempotent ALTER DATABASE
-- =============================================================================

-- Check current state first
SELECT
    actual_state_desc,
    desired_state_desc,
    current_storage_size_mb,
    max_storage_size_mb,
    query_capture_mode_desc,
    wait_stats_capture_mode_desc
FROM sys.database_query_store_options
WHERE database_id = DB_ID('TRANSTRACK');
GO

ALTER DATABASE TRANSTRACK
SET QUERY_STORE = ON
(
    OPERATION_MODE              = READ_WRITE,
    CLEANUP_POLICY              = (STALE_QUERY_THRESHOLD_DAYS = 30),
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES     = 60,
    MAX_STORAGE_SIZE_MB         = 500,
    QUERY_CAPTURE_MODE          = ALL,       -- Capture everything during diagnostic phase
    SIZE_BASED_CLEANUP_MODE     = AUTO,
    MAX_PLANS_PER_QUERY         = 200,
    WAIT_STATS_CAPTURE_MODE     = ON         -- SQL Server 2017+ feature
);
GO

-- Flush any pending QS data before PRE snapshot
EXEC sys.sp_query_store_flush_db;
GO

PRINT 'Query Store configured on TRANSTRACK. Now capture PRE snapshot.';
GO

-- =============================================================================
-- STEP 2: PRE-diagnostic wait stats snapshot
-- Run BEFORE executing scripts 01_duplicate_clients.sql through 05_business_impact.sql
-- =============================================================================

USE TRANSTRACK;
GO

-- Create snapshot table if not exists
IF OBJECT_ID('dbo.WAIT_STATS_BASELINE', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.WAIT_STATS_BASELINE
    (
        snapshot_id          INT IDENTITY(1,1)  NOT NULL,
        snapshot_label       VARCHAR(50)        NOT NULL,
        snapshot_time        DATETIME2          NOT NULL DEFAULT SYSUTCDATETIME(),
        wait_type            NVARCHAR(120)      NOT NULL,
        waiting_tasks_count  BIGINT             NOT NULL,
        wait_time_ms         BIGINT             NOT NULL,
        max_wait_time_ms     BIGINT             NOT NULL,
        signal_wait_time_ms  BIGINT             NOT NULL,
        CONSTRAINT PK_WAIT_BASELINE PRIMARY KEY CLUSTERED (snapshot_id)
    );
    PRINT 'Created dbo.WAIT_STATS_BASELINE';
END
GO

-- Benign waits to exclude (noise)
INSERT INTO dbo.WAIT_STATS_BASELINE
    (snapshot_label, wait_type, waiting_tasks_count, wait_time_ms, max_wait_time_ms, signal_wait_time_ms)
SELECT
    'PRE_DIAGNOSTIC',
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'SLEEP_TASK','BROKER_TO_FLUSH','BROKER_EVENTHANDLER','CHECKPOINT_QUEUE',
    'DBMIRROR_EVENTS_QUEUE','DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
    'HADR_WORK_QUEUE','LAZYWRITER_SLEEP','LOGMGR_QUEUE','ONDEMAND_TASK_QUEUE',
    'REQUEST_FOR_DEADLOCK_MONITOR','RESOURCE_QUEUE','SERVER_IDLE_CHECK',
    'SLEEP_DBSTARTUP','SLEEP_DCOMSTARTUP','SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY',
    'SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK','SLEEP_TEMPDBSTARTUP',
    'SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_BUFFER_FLUSH','WAITFOR',
    'XE_DISPATCHER_WAIT','XE_TIMER_EVENT','BROKER_TRANSMITTER','WAIT_XTP_OFFLINE_CKPT_NEW_LOG'
)
AND wait_time_ms > 0;

SELECT @@ROWCOUNT AS wait_types_captured_pre;
PRINT 'PRE_DIAGNOSTIC snapshot captured. NOW run scripts 01 through 05, then return for STEP 3.';
GO

-- =============================================================================
-- STEP 3: POST-diagnostic wait stats snapshot
-- Run AFTER all diagnostic scripts have completed
-- =============================================================================

INSERT INTO dbo.WAIT_STATS_BASELINE
    (snapshot_label, wait_type, waiting_tasks_count, wait_time_ms, max_wait_time_ms, signal_wait_time_ms)
SELECT
    'POST_DIAGNOSTIC',
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'SLEEP_TASK','BROKER_TO_FLUSH','BROKER_EVENTHANDLER','CHECKPOINT_QUEUE',
    'DBMIRROR_EVENTS_QUEUE','DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
    'HADR_WORK_QUEUE','LAZYWRITER_SLEEP','LOGMGR_QUEUE','ONDEMAND_TASK_QUEUE',
    'REQUEST_FOR_DEADLOCK_MONITOR','RESOURCE_QUEUE','SERVER_IDLE_CHECK',
    'SLEEP_DBSTARTUP','SLEEP_DCOMSTARTUP','SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY',
    'SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK','SLEEP_TEMPDBSTARTUP',
    'SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_BUFFER_FLUSH','WAITFOR',
    'XE_DISPATCHER_WAIT','XE_TIMER_EVENT','BROKER_TRANSMITTER','WAIT_XTP_OFFLINE_CKPT_NEW_LOG'
)
AND wait_time_ms > 0;

SELECT @@ROWCOUNT AS wait_types_captured_post;
PRINT 'POST_DIAGNOSTIC snapshot captured.';
GO

-- =============================================================================
-- STEP 4: Delta analysis — impact of diagnostic queries on wait stats
-- =============================================================================

WITH pre AS (
    SELECT wait_type, wait_time_ms, waiting_tasks_count
    FROM dbo.WAIT_STATS_BASELINE
    WHERE snapshot_label = 'PRE_DIAGNOSTIC'
),
post AS (
    SELECT wait_type, wait_time_ms, waiting_tasks_count
    FROM dbo.WAIT_STATS_BASELINE
    WHERE snapshot_label = 'POST_DIAGNOSTIC'
)
SELECT TOP 20
    COALESCE(post.wait_type, pre.wait_type)         AS wait_type,
    post.wait_time_ms - COALESCE(pre.wait_time_ms, 0) AS delta_wait_ms,
    post.waiting_tasks_count - COALESCE(pre.waiting_tasks_count, 0) AS delta_tasks,
    CASE
        WHEN COALESCE(post.wait_type, pre.wait_type) LIKE 'PAGEIO%'    THEN 'DISK_IO — table scans hitting disk (missing indexes)'
        WHEN COALESCE(post.wait_type, pre.wait_type) LIKE 'LCK%'       THEN 'LOCKING — long reads blocking other sessions'
        WHEN COALESCE(post.wait_type, pre.wait_type) LIKE 'PAGELATCH%' THEN 'MEMORY_LATCH — buffer pool contention'
        WHEN COALESCE(post.wait_type, pre.wait_type) IN ('CXPACKET','CXCONSUMER') THEN 'PARALLELISM — Hash Match joins on large tables'
        WHEN COALESCE(post.wait_type, pre.wait_type) = 'SOS_SCHEDULER_YIELD' THEN 'CPU — SOUNDEX computed per row, no index'
        ELSE 'OTHER'
    END                                             AS interpretation
FROM pre
FULL OUTER JOIN post ON pre.wait_type = post.wait_type
WHERE (post.wait_time_ms - COALESCE(pre.wait_time_ms, 0)) > 50
ORDER BY delta_wait_ms DESC;

-- =============================================================================
-- STEP 5: Query Store — top resource consumers from diagnostic run
-- =============================================================================

USE TRANSTRACK;
GO

SELECT TOP 20
    qs.query_id,
    SUBSTRING(qt.query_sql_text, 1, 300)                        AS query_snippet,
    rs.count_executions,
    CAST(rs.avg_duration / 1000.0 AS DECIMAL(10,2))             AS avg_duration_ms,
    CAST(rs.avg_cpu_time / 1000.0 AS DECIMAL(10,2))             AS avg_cpu_ms,
    CAST(rs.avg_logical_io_reads AS DECIMAL(18,0))              AS avg_logical_reads,
    CAST(rs.avg_physical_io_reads AS DECIMAL(18,0))             AS avg_physical_reads,
    -- Map to source script based on table names in query text
    CASE
        WHEN qt.query_sql_text LIKE '%SOUNDEX%'                 THEN '01_duplicate_clients'
        WHEN qt.query_sql_text LIKE '%EMPLEADO%' AND
             qt.query_sql_text LIKE '%OPERADOR%'                THEN '02_fragmented_drivers'
        WHEN qt.query_sql_text LIKE '%FACTURA%' AND
             qt.query_sql_text LIKE '%pedido_id IS NULL%'       THEN '03_orphan_records'
        WHEN qt.query_sql_text LIKE '%TELEMETRIA_GPS%'          THEN '04_telemetry_gaps'
        WHEN qt.query_sql_text LIKE '%sat_penalty%' OR
             qt.query_sql_text LIKE '%gtq_to_usd%'             THEN '05_business_impact'
        ELSE 'OTHER'
    END                                                         AS source_script
FROM sys.query_store_query qs
JOIN sys.query_store_query_text qt   ON qs.query_text_id = qt.query_text_id
JOIN sys.query_store_plan qp         ON qs.query_id = qp.query_id
JOIN sys.query_store_runtime_stats rs ON qp.plan_id = rs.plan_id
JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -2, GETDATE())
ORDER BY rs.avg_cpu_time DESC;
GO
