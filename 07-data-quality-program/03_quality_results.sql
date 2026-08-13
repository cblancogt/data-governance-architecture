/* ============================================================================
   PROJECT  : P02 - Data Governance Architecture (TRANSTRACK)
   FOLDER   : 07-quality-program
   FILE     : 03_quality_results.sql
   PURPOSE  : Historical results table for the data quality program.
              Stores every measurement produced by the procedures in
              02_quality_measurements.sql, and runs the folder-02 BASELINE
              automatically at the end of this script.

   DAMA-DMBOK2 alignment : Chapter 13 - Data Quality (measurement history,
              trending, and before/after evidence).
              Reference: https://www.dama.org/  (DMBOK2, Ch.13)

   ----------------------------------------------------------------------------
   DEPLOYMENT ORDER
   ----------------------------------------------------------------------------
        01_quality_rules.sql        (rule registry + seed)      -- required
        02_quality_measurements.sql (measurement procedures)    -- required
        03_quality_results.sql      (this file: table + baseline)

   The column list below MUST match exactly what usp_MeasureRule writes in
   02_quality_measurements.sql (shared contract).

   ----------------------------------------------------------------------------
   BASELINE
   ----------------------------------------------------------------------------
   At the end of this script the full suite is executed once with
   @is_baseline = 1. That run freezes the CURRENT real state of TRANSTRACK as
   the "before" snapshot. Rules whose source tables still carry the folder-02
   defects (raw duplicate NITs, duplicated invoices, orphan invoices, etc.)
   will score RED/YELLOW; rules measuring already-governed master data may
   score GREEN. The contrast IS the business evidence.

   WARNING: the baseline run performs full scans over flota.TELEMETRIA_GPS
   (~50M rows). It is expected to take time. Do not cancel mid-run.

   SCHEMA   : governance_control
   ============================================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ----------------------------------------------------------------------------
   1) TABLE : governance_control.DATA_QUALITY_RESULTS
   Small-to-medium metadata/history table -> placed on PRIMARY.
   Created only if it does not exist (no history loss on re-run).
   ---------------------------------------------------------------------------- */
IF OBJECT_ID(N'governance_control.DATA_QUALITY_RESULTS', N'U') IS NULL
BEGIN
    CREATE TABLE governance_control.DATA_QUALITY_RESULTS
    (
        result_id             BIGINT IDENTITY(1,1) NOT NULL,   -- surrogate PK

        -- Which rule produced this result (see DATA_QUALITY_RULES)
        rule_id               INT            NOT NULL,
        rule_code             VARCHAR(20)    NOT NULL,          -- denormalized for fast reporting
        quality_dimension     VARCHAR(20)    NOT NULL,          -- completeness|accuracy|consistency|timeliness|uniqueness

        -- What was measured
        target_schema         SYSNAME        NOT NULL,
        target_table          SYSNAME        NOT NULL,
        target_column         SYSNAME        NULL,

        -- Raw measurement (contract from usp_MeasureRule)
        records_evaluated     INT            NULL,              -- denominator (NULL on ERROR)
        records_failed        INT            NULL,              -- numerator   (NULL on ERROR)
        pass_rate_pct         DECIMAL(5,2)   NULL,              -- score (NULL on NOT_APPLICABLE/ERROR)

        -- Thresholds captured at measurement time (rules may change later)
        threshold_pct         DECIMAL(5,2)   NOT NULL,          -- GREEN cutoff
        warning_threshold_pct DECIMAL(5,2)   NOT NULL,          -- YELLOW cutoff

        -- Verdict
        status                VARCHAR(20)    NOT NULL,          -- GREEN|YELLOW|RED|NOT_APPLICABLE|ERROR
        severity              VARCHAR(10)    NOT NULL,          -- critical|high|medium|low

        -- Run context
        is_baseline           BIT            NOT NULL,          -- 1 = folder-02 "before" snapshot
        run_batch_id          UNIQUEIDENTIFIER NOT NULL,        -- groups one suite execution
        error_message         NVARCHAR(2000) NULL,              -- populated only when status = ERROR
        execution_ms          INT            NULL,              -- per-rule duration (DBA metric)

        measured_at           DATETIME2(3)   NOT NULL CONSTRAINT DF_DQRES_measured_at DEFAULT (SYSUTCDATETIME()),
        measured_by           NVARCHAR(128)  NOT NULL CONSTRAINT DF_DQRES_measured_by DEFAULT (SUSER_SNAME()),

        CONSTRAINT PK_DATA_QUALITY_RESULTS PRIMARY KEY CLUSTERED (result_id),

        CONSTRAINT CK_DQRES_status CHECK
            (status IN ('GREEN','YELLOW','RED','NOT_APPLICABLE','ERROR')),
        CONSTRAINT CK_DQRES_dimension CHECK
            (quality_dimension IN ('completeness','accuracy','consistency','timeliness','uniqueness')),

        -- Results are historical: a rule may be deactivated later, but its past
        -- results must survive. Hence NO ON DELETE CASCADE.
        CONSTRAINT FK_DQRES_rule FOREIGN KEY (rule_id)
            REFERENCES governance_control.DATA_QUALITY_RULES (rule_id)
    ) ON [PRIMARY];

    -- Fast retrieval of a full suite run (used by quality_check.py)
    CREATE NONCLUSTERED INDEX IX_DQRES_batch
        ON governance_control.DATA_QUALITY_RESULTS (run_batch_id)
        INCLUDE (status, quality_dimension, target_schema, target_table, pass_rate_pct);

    -- Trend analysis per rule over time (before/after, historical charts)
    CREATE NONCLUSTERED INDEX IX_DQRES_rule_time
        ON governance_control.DATA_QUALITY_RESULTS (rule_id, measured_at)
        INCLUDE (status, pass_rate_pct, is_baseline);

    -- Quickly isolate the baseline snapshot
    CREATE NONCLUSTERED INDEX IX_DQRES_baseline
        ON governance_control.DATA_QUALITY_RESULTS (is_baseline, measured_at)
        INCLUDE (rule_code, status, pass_rate_pct);

    PRINT 'Created table governance_control.DATA_QUALITY_RESULTS';
END
ELSE
    PRINT 'Table governance_control.DATA_QUALITY_RESULTS already exists - skipping DDL';
GO

/* ----------------------------------------------------------------------------
   2) BASELINE GUARD
   Only run the baseline if one does not already exist. Re-running this whole
   script must NOT create duplicate baselines or wipe existing history.
   ---------------------------------------------------------------------------- */
DECLARE @baseline_exists INT =
    (SELECT COUNT(*) FROM governance_control.DATA_QUALITY_RESULTS WHERE is_baseline = 1);

IF @baseline_exists > 0
BEGIN
    PRINT CONCAT('Baseline already present (', @baseline_exists,
                 ' rows). Skipping automatic baseline run.');
    PRINT 'To force a new baseline, run: EXEC governance_control.usp_RunQualitySuite @is_baseline = 1;';
END
ELSE
BEGIN
    PRINT 'No baseline found. Running folder-02 BASELINE now (this may take a while - full TELEMETRIA_GPS scans)...';

    -- Freeze the current real state of TRANSTRACK as the "before" snapshot.
    EXEC governance_control.usp_RunQualitySuite @is_baseline = 1;

    PRINT 'Baseline run complete.';
END
GO

/* ----------------------------------------------------------------------------
   3) BASELINE SUMMARY (folder-02 "before" evidence)
   Reads back the baseline and shows the traffic-light distribution, with the
   folder-02-linked rules highlighted for the README before/after section.
   ---------------------------------------------------------------------------- */
-- 3a) Traffic-light distribution of the baseline
SELECT r.status,
       COUNT(*) AS rule_count
FROM governance_control.DATA_QUALITY_RESULTS r
WHERE r.is_baseline = 1
GROUP BY r.status
ORDER BY r.status;

-- 3b) Detail, worst first, flagging rules tied to intentional folder-02 problems
SELECT res.rule_code,
       res.quality_dimension,
       res.target_schema,
       res.target_table,
       res.pass_rate_pct,
       res.threshold_pct,
       res.status,
       res.severity,
       res.records_failed,
       res.execution_ms,
       rul.ties_to_folder02_problem,
       rul.folder02_problem_ref
FROM governance_control.DATA_QUALITY_RESULTS res
INNER JOIN governance_control.DATA_QUALITY_RULES rul
        ON rul.rule_id = res.rule_id
WHERE res.is_baseline = 1
ORDER BY CASE res.status
             WHEN 'ERROR'  THEN 0
             WHEN 'RED'    THEN 1
             WHEN 'YELLOW' THEN 2
             ELSE 3
         END,
         rul.ties_to_folder02_problem DESC,
         res.rule_code;
GO

/* ============================================================================
   ARCHITECTURAL CONCLUSION (for README)
   ----------------------------------------------------------------------------
   DATA_QUALITY_RESULTS turns quality from a momentary check into an auditable
   time series. Every measurement is retained with its batch, its verdict, its
   timing, and whether it belongs to the frozen baseline. Because thresholds
   are captured per result, historical verdicts remain interpretable even after
   rule definitions evolve. The automatically captured folder-02 baseline is the
   quantitative "before" that, compared against later governed runs, proves the
   value of the master-data and deduplication work in a way no narrative can.
   ============================================================================ */
