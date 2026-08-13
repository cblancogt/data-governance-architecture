/* ============================================================================
   PROJECT  : P02 - Data Governance Architecture (TRANSTRACK)
   FOLDER   : 07-quality-program
   FILE     : 02_quality_measurements.sql
   PURPOSE  : Measurement engine that executes the rules stored in
              governance_control.DATA_QUALITY_RULES and writes every result
              to governance_control.DATA_QUALITY_RESULTS.

   DAMA-DMBOK2 alignment : Chapter 13 - Data Quality (measurement & monitoring).
              Reference: https://www.dama.org/  (DMBOK2, Ch.13)

   ----------------------------------------------------------------------------
   DEPLOYMENT ORDER
   ----------------------------------------------------------------------------
   Deploy scripts in this order:
        01_quality_rules.sql       (rule registry + seed)
        02_quality_measurements.sql (this file: procedures)
        03_quality_results.sql     (results table + baseline)

   SQL Server deferred name resolution lets these procedures be CREATED before
   DATA_QUALITY_RESULTS exists; they only require the table at EXECUTION time.
   Therefore run 03 before executing any procedure below.

   ----------------------------------------------------------------------------
   OBJECT MAP
   ----------------------------------------------------------------------------
   usp_MeasureRule          -- (worker) measures a single rule by rule_id
   usp_ExecuteRuleSet       -- (driver) loops rules, optionally filtered by dimension
   usp_MeasureCompleteness  -- entry point: dimension = completeness
   usp_MeasureAccuracy      -- entry point: dimension = accuracy
   usp_MeasureConsistency   -- entry point: dimension = consistency
   usp_MeasureTimeliness    -- entry point: dimension = timeliness
   usp_MeasureUniqueness    -- entry point: dimension = uniqueness
   usp_RunQualitySuite      -- runs all five dimensions as one batch

   Each dimension procedure is executable INDEPENDENTLY or as part of the suite.

   ----------------------------------------------------------------------------
   MEASUREMENT CONTRACT (defined in 01_quality_rules.sql)
   ----------------------------------------------------------------------------
   Every rule's measurement_sql returns ONE row: records_evaluated, records_failed.
        pass_rate_pct = (records_evaluated - records_failed) / records_evaluated * 100
        pass_rate >= threshold_pct         -> GREEN
        pass_rate >= warning_threshold_pct -> YELLOW
        otherwise                          -> RED
        records_evaluated = 0              -> NOT_APPLICABLE
        rule raised an error               -> ERROR (recorded, does not abort run)

   SCHEMA   : governance_control
   ============================================================================ */

SET NOCOUNT ON;
GO

/* ============================================================================
   1) WORKER : usp_MeasureRule
      Measures a SINGLE rule and writes one row to DATA_QUALITY_RESULTS.
      Isolated in its own TRY/CATCH so a broken rule never aborts a batch.
   ============================================================================ */
CREATE OR ALTER PROCEDURE governance_control.usp_MeasureRule
    @rule_id       INT,
    @run_batch_id  UNIQUEIDENTIFIER = NULL,   -- groups results of one suite run
    @is_baseline   BIT              = 0        -- 1 = folder-02 baseline measurement
AS
BEGIN
    SET NOCOUNT ON;

    -- ---- Load the rule definition -----------------------------------------
    DECLARE @rule_code   VARCHAR(20),
            @dimension   VARCHAR(20),
            @schema      SYSNAME,
            @tbl         SYSNAME,
            @col         SYSNAME,
            @sql         NVARCHAR(MAX),
            @threshold   DECIMAL(5,2),
            @warning     DECIMAL(5,2),
            @severity    VARCHAR(10);

    SELECT @rule_code = rule_code,
           @dimension = quality_dimension,
           @schema    = target_schema,
           @tbl       = target_table,
           @col       = target_column,
           @sql       = measurement_sql,
           @threshold = threshold_pct,
           @warning   = warning_threshold_pct,
           @severity  = severity
    FROM governance_control.DATA_QUALITY_RULES
    WHERE rule_id = @rule_id
      AND is_active = 1;

    -- Rule missing or inactive: nothing to measure
    IF @rule_code IS NULL
        RETURN;

    IF @run_batch_id IS NULL
        SET @run_batch_id = NEWID();

    -- ---- Execute the measurement and score it -----------------------------
    DECLARE @evaluated  INT           = NULL,
            @failed     INT           = NULL,
            @pass_rate  DECIMAL(9,4)   = NULL,
            @status     VARCHAR(20),
            @err        NVARCHAR(2000) = NULL,
            @t0         DATETIME2(3)   = SYSUTCDATETIME(),
            @ms         INT;

    -- Buffer that captures the rule's (records_evaluated, records_failed) row.
    -- INSERT...EXEC into a table variable works and does NOT nest, because the
    -- callers of this procedure use plain EXEC (no outer INSERT...EXEC).
    DECLARE @measure TABLE (records_evaluated INT, records_failed INT);

    BEGIN TRY
        INSERT INTO @measure (records_evaluated, records_failed)
        EXEC sys.sp_executesql @sql;

        SELECT TOP (1)
               @evaluated = records_evaluated,
               @failed    = records_failed
        FROM @measure;

        IF @evaluated IS NULL OR @evaluated = 0
        BEGIN
            -- No rows in scope -> the rule cannot be scored this run
            SET @status    = 'NOT_APPLICABLE';
            SET @pass_rate = NULL;
        END
        ELSE
        BEGIN
            SET @pass_rate = CAST(@evaluated - ISNULL(@failed, 0) AS DECIMAL(18,4))
                             / @evaluated * 100.0;

            SET @status = CASE
                              WHEN @pass_rate >= @threshold THEN 'GREEN'
                              WHEN @pass_rate >= @warning   THEN 'YELLOW'
                              ELSE 'RED'
                          END;
        END
    END TRY
    BEGIN CATCH
        -- Record the failure but let the batch continue with the next rule
        SET @status    = 'ERROR';
        SET @err       = LEFT(ERROR_MESSAGE(), 2000);
        SET @evaluated = NULL;
        SET @failed    = NULL;
        SET @pass_rate = NULL;
    END CATCH;

    SET @ms = DATEDIFF(MILLISECOND, @t0, SYSUTCDATETIME());

    -- ---- Persist the result -----------------------------------------------
    INSERT INTO governance_control.DATA_QUALITY_RESULTS
        (rule_id, rule_code, quality_dimension, target_schema, target_table, target_column,
         records_evaluated, records_failed, pass_rate_pct, threshold_pct, warning_threshold_pct,
         status, severity, is_baseline, run_batch_id, error_message, execution_ms, measured_by)
    VALUES
        (@rule_id, @rule_code, @dimension, @schema, @tbl, @col,
         @evaluated, @failed, CAST(@pass_rate AS DECIMAL(5,2)), @threshold, @warning,
         @status, @severity, @is_baseline, @run_batch_id, @err, @ms, SUSER_SNAME());
END;
GO

/* ============================================================================
   2) DRIVER : usp_ExecuteRuleSet
      Loops active rules (optionally filtered by dimension) and measures each.
      @show_summary = 1 emits a per-status summary (useful for standalone runs).
   ============================================================================ */
CREATE OR ALTER PROCEDURE governance_control.usp_ExecuteRuleSet
    @quality_dimension VARCHAR(20)      = NULL,  -- NULL = all dimensions
    @run_batch_id      UNIQUEIDENTIFIER = NULL,
    @is_baseline       BIT              = 0,
    @show_summary      BIT              = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF @run_batch_id IS NULL
        SET @run_batch_id = NEWID();

    DECLARE @rule_id INT;

    -- FAST_FORWARD read-only cursor over the target rule set
    DECLARE rule_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT rule_id
        FROM governance_control.DATA_QUALITY_RULES
        WHERE is_active = 1
          AND (@quality_dimension IS NULL OR quality_dimension = @quality_dimension)
        ORDER BY rule_code;

    BEGIN TRY
        OPEN rule_cur;
        FETCH NEXT FROM rule_cur INTO @rule_id;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC governance_control.usp_MeasureRule
                 @rule_id      = @rule_id,
                 @run_batch_id = @run_batch_id,
                 @is_baseline  = @is_baseline;

            FETCH NEXT FROM rule_cur INTO @rule_id;
        END

        CLOSE rule_cur;
        DEALLOCATE rule_cur;
    END TRY
    BEGIN CATCH
        -- Guarantee cursor cleanup on any unexpected failure
        IF CURSOR_STATUS('local', 'rule_cur') >= 0
        BEGIN
            CLOSE rule_cur;
            DEALLOCATE rule_cur;
        END;
        THROW;  -- re-raise: a driver-level failure is not a rule-level failure
    END CATCH;

    IF @show_summary = 1
        SELECT status,
               COUNT(*) AS rule_count
        FROM governance_control.DATA_QUALITY_RESULTS
        WHERE run_batch_id = @run_batch_id
        GROUP BY status
        ORDER BY status;
END;
GO

/* ============================================================================
   3) DIMENSION ENTRY POINTS (thin wrappers - one per DAMA dimension)
      Each can be executed independently, e.g. EXEC ...usp_MeasureAccuracy.
   ============================================================================ */
CREATE OR ALTER PROCEDURE governance_control.usp_MeasureCompleteness
    @run_batch_id UNIQUEIDENTIFIER = NULL,
    @is_baseline  BIT              = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC governance_control.usp_ExecuteRuleSet
         @quality_dimension = 'completeness',
         @run_batch_id      = @run_batch_id,
         @is_baseline       = @is_baseline;
END;
GO

CREATE OR ALTER PROCEDURE governance_control.usp_MeasureAccuracy
    @run_batch_id UNIQUEIDENTIFIER = NULL,
    @is_baseline  BIT              = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC governance_control.usp_ExecuteRuleSet
         @quality_dimension = 'accuracy',
         @run_batch_id      = @run_batch_id,
         @is_baseline       = @is_baseline;
END;
GO

CREATE OR ALTER PROCEDURE governance_control.usp_MeasureConsistency
    @run_batch_id UNIQUEIDENTIFIER = NULL,
    @is_baseline  BIT              = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC governance_control.usp_ExecuteRuleSet
         @quality_dimension = 'consistency',
         @run_batch_id      = @run_batch_id,
         @is_baseline       = @is_baseline;
END;
GO

CREATE OR ALTER PROCEDURE governance_control.usp_MeasureTimeliness
    @run_batch_id UNIQUEIDENTIFIER = NULL,
    @is_baseline  BIT              = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC governance_control.usp_ExecuteRuleSet
         @quality_dimension = 'timeliness',
         @run_batch_id      = @run_batch_id,
         @is_baseline       = @is_baseline;
END;
GO

CREATE OR ALTER PROCEDURE governance_control.usp_MeasureUniqueness
    @run_batch_id UNIQUEIDENTIFIER = NULL,
    @is_baseline  BIT              = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC governance_control.usp_ExecuteRuleSet
         @quality_dimension = 'uniqueness',
         @run_batch_id      = @run_batch_id,
         @is_baseline       = @is_baseline;
END;
GO

/* ============================================================================
   4) SUITE RUNNER : usp_RunQualitySuite
      Runs all five dimensions under a single batch id and returns the full
      scoreboard for that batch (consumed by quality_check.py).
   ============================================================================ */
CREATE OR ALTER PROCEDURE governance_control.usp_RunQualitySuite
    @is_baseline BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @batch UNIQUEIDENTIFIER = NEWID();
    PRINT CONCAT('Data quality suite started. Batch = ', CAST(@batch AS VARCHAR(40)),
                 ' | baseline = ', @is_baseline);

    -- Run every active rule (all dimensions) under the same batch id.
    -- @show_summary = 0 suppresses the intermediate summary; we emit our own below.
    EXEC governance_control.usp_ExecuteRuleSet
         @quality_dimension = NULL,
         @run_batch_id      = @batch,
         @is_baseline       = @is_baseline,
         @show_summary      = 0;

    -- Detailed scoreboard: worst status first (ERROR, RED, YELLOW, then the rest)
    SELECT rule_code,
           quality_dimension,
           target_schema,
           target_table,
           target_column,
           records_evaluated,
           records_failed,
           pass_rate_pct,
           threshold_pct,
           status,
           severity,
           execution_ms,
           run_batch_id
    FROM governance_control.DATA_QUALITY_RESULTS
    WHERE run_batch_id = @batch
    ORDER BY CASE status
                 WHEN 'ERROR'  THEN 0
                 WHEN 'RED'    THEN 1
                 WHEN 'YELLOW' THEN 2
                 ELSE 3
             END,
             severity,
             rule_code;

    PRINT 'Data quality suite finished.';
END;
GO

/* ============================================================================
   USAGE EXAMPLES (commented)
   ----------------------------------------------------------------------------
   -- Run a single dimension independently:
   --     EXEC governance_control.usp_MeasureUniqueness;

   -- Run the full suite (normal monitoring run):
   --     EXEC governance_control.usp_RunQualitySuite;

   -- Run the full suite as the folder-02 BASELINE (before-state evidence):
   --     EXEC governance_control.usp_RunQualitySuite @is_baseline = 1;

   -- NOTE: For workload isolation, run these under the session that the
   --       Resource Governor classifier (04_resource_governor.sql) routes to
   --       the dedicated quality-check pool.
   ============================================================================ */

/* ============================================================================
   ARCHITECTURAL CONCLUSION (for README)
   ----------------------------------------------------------------------------
   The measurement layer is fully decoupled from the rule definitions: it knows
   nothing about any specific table or defect. It reads rules, honours the
   uniform two-column contract, scores against per-rule thresholds, and records
   an auditable row per measurement with timing and error capture. Per-rule
   TRY/CATCH isolation makes the program resilient (one bad rule never blocks a
   run), while the batch id turns each execution into a coherent, reportable
   snapshot. This is what makes data quality a continuous, operable program
   rather than a one-off diagnostic script.
   ============================================================================ */
