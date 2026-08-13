/* ============================================================================
   PROJECT  : P02 - Data Governance Architecture (TRANSTRACK)
   FOLDER   : 07-quality-program
   FILE     : 01_quality_rules.sql
   PURPOSE  : Define the formal Data Quality Rule Registry.
              One row = one measurable, threshold-based quality rule.

   DAMA-DMBOK2 alignment : Chapter 13 - Data Quality.
              Reference: https://www.dama.org/  (DMBOK2, Ch.13)

   ----------------------------------------------------------------------------
   DESIGN CONTRACT (read before writing file 02_quality_measurements.sql)
   ----------------------------------------------------------------------------
   Every rule stores its own measurement query in column [measurement_sql].
   That query is CONTRACTUALLY REQUIRED to return exactly ONE row with two
   integer columns:

        records_evaluated   -- denominator: rows in scope of the rule
        records_failed      -- numerator  : rows that VIOLATE the rule

   The generic executor (file 02) computes:

        pass_rate_pct = (records_evaluated - records_failed)
                        / NULLIF(records_evaluated, 0) * 100

   and maps it to a traffic light:

        pass_rate_pct >= threshold_pct           - GREEN
        pass_rate_pct >= warning_threshold_pct   - YELLOW
        otherwise                                - RED
        records_evaluated = 0                    - NOT_APPLICABLE

   This makes the quality engine data-driven: new rules are added by INSERTing
   rows here, never by editing procedural code.

   ----------------------------------------------------------------------------
   SECURITY NOTE (hardened in file 04_resource_governor.sql)
   ----------------------------------------------------------------------------
   [measurement_sql] is executed dynamically (sp_executesql) by the measurement
   procedure. Therefore this table is a code surface: only the governance role
   may INSERT/UPDATE/DELETE rows. DML permissions are restricted in folder 04.

   ----------------------------------------------------------------------------
   IDEMPOTENCY
   ----------------------------------------------------------------------------
   - The table is created only if it does not already exist (no data loss).
   - Rules are loaded via MERGE keyed on [rule_code], so re-running this script
     UPDATES existing definitions and INSERTs new ones, preserving [rule_id]
     and any linked history in DATA_QUALITY_RESULTS.

   SCHEMA   : governance_control
   ============================================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ----------------------------------------------------------------------------
   1) TABLE : governance_control.DATA_QUALITY_RULES
   Small metadata table -> placed on PRIMARY (DBA hygiene, explicit filegroup).
   ---------------------------------------------------------------------------- */
IF OBJECT_ID(N'governance_control.DATA_QUALITY_RULES', N'U') IS NULL
BEGIN
    CREATE TABLE governance_control.DATA_QUALITY_RULES
    (
        rule_id                  INT IDENTITY(1,1) NOT NULL,   -- surrogate PK
        rule_code                VARCHAR(20)    NOT NULL,      -- business key, e.g. DQ-UNQ-001
        rule_name                NVARCHAR(150)  NOT NULL,      -- human-readable rule name

        -- One of the 5 DAMA-DMBOK2 Ch.13 intrinsic quality dimensions
        quality_dimension        VARCHAR(20)    NOT NULL,      -- completeness|accuracy|consistency|timeliness|uniqueness

        -- Target object the rule measures (column may be NULL for table-level rules)
        target_schema            SYSNAME        NOT NULL,
        target_table             SYSNAME        NOT NULL,
        target_column            SYSNAME        NULL,

        rule_description         NVARCHAR(500)  NOT NULL,      -- what the rule checks, in business terms

        -- Measurement query. MUST return one row: records_evaluated, records_failed
        measurement_sql          NVARCHAR(MAX)  NOT NULL,

        -- Acceptance thresholds (percent of rows that must PASS)
        threshold_pct            DECIMAL(5,2)   NOT NULL,      -- >= this  - GREEN
        warning_threshold_pct    DECIMAL(5,2)   NOT NULL,      -- >= this  - YELLOW (below -> RED)

        severity                 VARCHAR(10)    NOT NULL,      -- critical|high|medium|low

        -- Governance context
        domain_code              VARCHAR(20)    NULL,          -- soft link to DATA_DOMAIN (backfilled below)
        business_impact          NVARCHAR(500)  NULL,          -- cost of failure, ties to the business case

        -- Traceability to the intentional problems seeded in folder 02
        ties_to_folder02_problem BIT            NOT NULL CONSTRAINT DF_DQR_ties DEFAULT (0),
        folder02_problem_ref     NVARCHAR(200)  NULL,

        is_active                BIT            NOT NULL CONSTRAINT DF_DQR_active   DEFAULT (1),
        created_at               DATETIME2(3)   NOT NULL CONSTRAINT DF_DQR_created  DEFAULT (SYSUTCDATETIME()),
        created_by               NVARCHAR(128)  NOT NULL CONSTRAINT DF_DQR_createdby DEFAULT (SUSER_SNAME()),
        updated_at               DATETIME2(3)   NOT NULL CONSTRAINT DF_DQR_updated  DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_DATA_QUALITY_RULES PRIMARY KEY CLUSTERED (rule_id),
        CONSTRAINT UQ_DATA_QUALITY_RULES_code UNIQUE (rule_code),

        CONSTRAINT CK_DQR_dimension CHECK
            (quality_dimension IN ('completeness','accuracy','consistency','timeliness','uniqueness')),
        CONSTRAINT CK_DQR_severity CHECK
            (severity IN ('critical','high','medium','low')),
        CONSTRAINT CK_DQR_threshold_range CHECK
            (threshold_pct BETWEEN 0 AND 100 AND warning_threshold_pct BETWEEN 0 AND 100),
        -- YELLOW cutoff can never be stricter than the GREEN cutoff
        CONSTRAINT CK_DQR_threshold_order CHECK
            (warning_threshold_pct <= threshold_pct)
    ) ON [PRIMARY];

    -- Supports the executor filtering active rules by dimension
    CREATE NONCLUSTERED INDEX IX_DQR_active_dimension
        ON governance_control.DATA_QUALITY_RULES (is_active, quality_dimension)
        INCLUDE (rule_code, target_schema, target_table);

    PRINT 'Created table governance_control.DATA_QUALITY_RULES';
END
ELSE
    PRINT 'Table governance_control.DATA_QUALITY_RULES already exists - skipping DDL';
GO

/* ----------------------------------------------------------------------------
   2) SEED / UPSERT the 18 quality rules (5 dimensions).
   Loaded into a table variable, then MERGEd on rule_code for idempotency.
   Rules flagged ties_to_folder02_problem=1 are the ones whose "before/after"
   scores become the evidence in the README.
   ---------------------------------------------------------------------------- */
DECLARE @rules TABLE
(
    rule_code                VARCHAR(20),
    rule_name                NVARCHAR(150),
    quality_dimension        VARCHAR(20),
    target_schema            SYSNAME,
    target_table             SYSNAME,
    target_column            SYSNAME NULL,
    rule_description         NVARCHAR(500),
    measurement_sql          NVARCHAR(MAX),
    threshold_pct            DECIMAL(5,2),
    warning_threshold_pct    DECIMAL(5,2),
    severity                 VARCHAR(10),
    business_impact          NVARCHAR(500),
    ties_to_folder02_problem BIT,
    folder02_problem_ref     NVARCHAR(200)
);

/* ===== DIMENSION 1: COMPLETENESS =========================================== */

INSERT INTO @rules VALUES
('DQ-CMP-001','Sales client email is populated','completeness',
 'ventas','CLIENTE','email',
 'Percentage of sales clients that have a contact email captured.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN email IS NULL OR LTRIM(RTRIM(email)) = '''' THEN 1 ELSE 0 END) AS records_failed
   FROM ventas.CLIENTE;',
 90.00, 80.00, 'medium',
 'Missing email blocks automated billing/notification and increases collection cost.',
 0, NULL);

INSERT INTO @rules VALUES
('DQ-CMP-002','Invoice is linked to an order','completeness',
 'facturacion','FACTURA','pedido_id',
 'Percentage of invoices that reference a source order (pedido_id NOT NULL).',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN pedido_id IS NULL THEN 1 ELSE 0 END) AS records_failed
   FROM facturacion.FACTURA;',
 99.00, 95.00, 'high',
 'Invoices with no order cannot be audited against delivered service -> revenue leakage / fraud risk.',
 1, 'Folder 02: invoices intentionally inserted without an associated order.');

INSERT INTO @rules VALUES
('DQ-CMP-003','Order declared value is populated','completeness',
 'operaciones','PEDIDO','valor_declarado',
 'Percentage of orders with a declared cargo value (needed for insurance/claims).',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN valor_declarado IS NULL THEN 1 ELSE 0 END) AS records_failed
   FROM operaciones.PEDIDO;',
 95.00, 85.00, 'medium',
 'Missing declared value undermines incident cost estimation and insurance recovery.',
 0, NULL);

INSERT INTO @rules VALUES
('DQ-CMP-004','Final-state deliveries have a real delivery date','completeness',
 'operaciones','ENTREGA','fecha_entrega_real',
 'For deliveries in a final state (ref.ESTADO_ENTREGA.es_estado_final=1), the actual delivery date must be present.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN e.fecha_entrega_real IS NULL THEN 1 ELSE 0 END) AS records_failed
   FROM operaciones.ENTREGA e
   INNER JOIN ref.ESTADO_ENTREGA re ON e.estado_entrega = re.codigo
   WHERE re.es_estado_final = 1;',
 98.00, 90.00, 'high',
 'A "delivered" record with no timestamp cannot prove SLA compliance in a dispute.',
 0, NULL);

/* ===== DIMENSION 2: ACCURACY =============================================== */

INSERT INTO @rules VALUES
('DQ-ACC-001','Invoice total equals subtotal plus tax','accuracy',
 'facturacion','FACTURA',NULL,
 'total must equal subtotal + impuesto within a 0.01 tolerance.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN ABS(total - (subtotal + impuesto)) > 0.01 THEN 1 ELSE 0 END) AS records_failed
   FROM facturacion.FACTURA;',
 100.00, 99.00, 'critical',
 'Arithmetic errors in invoices are a direct SOX/financial-integrity finding.',
 0, NULL);

INSERT INTO @rules VALUES
('DQ-ACC-002','GPS speed within plausible range','accuracy',
 'flota','TELEMETRIA_GPS','velocidad_kmh',
 'Recorded speed must be between 0 and 140 km/h.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN velocidad_kmh < 0 OR velocidad_kmh > 140 THEN 1 ELSE 0 END) AS records_failed
   FROM flota.TELEMETRIA_GPS;',
 99.50, 98.00, 'medium',
 'Impossible speeds invalidate telemetry used as legal evidence in incidents.',
 0, NULL);

INSERT INTO @rules VALUES
('DQ-ACC-003','GPS coordinates within national bounds','accuracy',
 'flota','TELEMETRIA_GPS',NULL,
 'Latitude/longitude must fall inside the operating country bounding box.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN latitud  NOT BETWEEN 13.5 AND 18.0
                     OR longitud NOT BETWEEN -92.5 AND -88.0 THEN 1 ELSE 0 END) AS records_failed
   FROM flota.TELEMETRIA_GPS;',
 99.50, 98.00, 'medium',
 'Out-of-bounds points break route reconstruction and geofencing analytics.',
 0, NULL);

INSERT INTO @rules VALUES
('DQ-ACC-004','Order weight is positive','accuracy',
 'operaciones','PEDIDO','peso_kg',
 'peso_kg must be strictly greater than zero.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN peso_kg <= 0 THEN 1 ELSE 0 END) AS records_failed
   FROM operaciones.PEDIDO;',
 100.00, 99.00, 'high',
 'Zero/negative weight corrupts capacity planning and freight pricing.',
 0, NULL);

/* ===== DIMENSION 3: CONSISTENCY ============================================ */

INSERT INTO @rules VALUES
('DQ-CON-001','Invoice order reference is valid (no orphans)','consistency',
 'facturacion','FACTURA','pedido_id',
 'Every non-null pedido_id in FACTURA must exist in operaciones.PEDIDO.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN f.pedido_id IS NOT NULL AND p.pedido_id IS NULL THEN 1 ELSE 0 END) AS records_failed
   FROM facturacion.FACTURA f
   LEFT JOIN operaciones.PEDIDO p ON f.pedido_id = p.pedido_id;',
 99.00, 95.00, 'high',
 'Orphan invoices point to a broken integration between billing and operations.',
 1, 'Folder 02: invoices referencing non-existent / missing orders.');

INSERT INTO @rules VALUES
('DQ-CON-002','Same client is consistent across sales and billing','consistency',
 'ventas','CLIENTE',NULL,
 'For a NIT present in both ventas.CLIENTE and facturacion.CLIENTE, the email must match.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN v.email IS NOT NULL AND fc.correo IS NOT NULL
                    AND v.email <> fc.correo THEN 1 ELSE 0 END) AS records_failed
   FROM ventas.CLIENTE v
   INNER JOIN facturacion.CLIENTE fc ON v.nit = fc.nit_cliente;',
 95.00, 85.00, 'high',
 'Divergent client data between modules is the root cause of duplicate identities.',
 1, 'Folder 02: same client duplicated with divergent data across sales and billing.');

INSERT INTO @rules VALUES
('DQ-CON-003','Invoice total reconciles with its line items','consistency',
 'facturacion','FACTURA',NULL,
 'FACTURA.total must equal SUM(DETALLE_FACTURA.subtotal) + FACTURA.impuesto within 0.01.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN ABS(f.total - (ISNULL(d.detalle_sum,0) + f.impuesto)) > 0.01 THEN 1 ELSE 0 END) AS records_failed
   FROM facturacion.FACTURA f
   LEFT JOIN (SELECT factura_id, SUM(subtotal) AS detalle_sum
              FROM facturacion.DETALLE_FACTURA GROUP BY factura_id) d
          ON d.factura_id = f.factura_id;',
 99.00, 95.00, 'high',
 'Header/line mismatches indicate tampering or partial loads in the billing feed.',
 0, NULL);

INSERT INTO @rules VALUES
('DQ-CON-004','Vehicle assignment odometer is coherent','consistency',
 'flota','ASIGNACION_VEHICULO',NULL,
 'When km_fin is present it must be greater than or equal to km_inicio.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN km_fin IS NOT NULL AND km_fin < km_inicio THEN 1 ELSE 0 END) AS records_failed
   FROM flota.ASIGNACION_VEHICULO;',
 100.00, 99.00, 'medium',
 'Backwards odometer readings break mileage-based maintenance and cost allocation.',
 0, NULL);

/* ===== DIMENSION 4: TIMELINESS ============================================= */

INSERT INTO @rules VALUES
('DQ-TIM-001','Vehicle telemetry is fresh','timeliness',
 'flota','TELEMETRIA_GPS',NULL,
 'Each vehicle must have a GPS ping within 24h of the dataset as-of (latest ping overall).',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN t.last_ping IS NULL
                     OR DATEDIFF(HOUR, t.last_ping, ref.as_of) > 24 THEN 1 ELSE 0 END) AS records_failed
   FROM flota.VEHICULO v
   OUTER APPLY (SELECT MAX(fecha_hora) AS last_ping
                FROM flota.TELEMETRIA_GPS g WHERE g.vehiculo_id = v.vehiculo_id) t
   CROSS JOIN (SELECT MAX(fecha_hora) AS as_of FROM flota.TELEMETRIA_GPS) ref;',
 90.00, 80.00, 'medium',
 'Stale telemetry means blind spots in fleet tracking and delayed incident response.',
 0, NULL);

INSERT INTO @rules VALUES
('DQ-TIM-002','Invoices are issued on time','timeliness',
 'facturacion','FACTURA','fecha_emision',
 'For invoices linked to an order, fecha_emision must be within 30 days of the order date and not earlier.',
 N'SELECT COUNT(*) AS records_evaluated,
          SUM(CASE WHEN f.fecha_emision < p.fecha_pedido
                     OR DATEDIFF(DAY, p.fecha_pedido, f.fecha_emision) > 30 THEN 1 ELSE 0 END) AS records_failed
   FROM facturacion.FACTURA f
   INNER JOIN operaciones.PEDIDO p ON f.pedido_id = p.pedido_id;',
 90.00, 80.00, 'medium',
 'Late billing directly delays cash collection and inflates days-sales-outstanding.',
 0, NULL);

/* ===== DIMENSION 5: UNIQUENESS ============================================= */

INSERT INTO @rules VALUES
('DQ-UNQ-001','Sales clients are unique by NIT','uniqueness',
 'ventas','CLIENTE','nit',
 'Count of surplus duplicate rows sharing the same NIT in ventas.CLIENTE.',
 N'SELECT COUNT(*) AS records_evaluated,
          COUNT(*) - COUNT(DISTINCT nit) AS records_failed
   FROM ventas.CLIENTE;',
 100.00, 98.00, 'critical',
 'Duplicate clients make the "how many unique clients?" question unanswerable.',
 1, 'Folder 02: intentional client duplicates by repeated NIT / similar name.');

INSERT INTO @rules VALUES
('DQ-UNQ-002','Invoice numbers are unique','uniqueness',
 'facturacion','FACTURA','numero_factura',
 'Count of surplus rows sharing the same numero_factura.',
 N'SELECT COUNT(*) AS records_evaluated,
          COUNT(*) - COUNT(DISTINCT numero_factura) AS records_failed
   FROM facturacion.FACTURA;',
 100.00, 99.00, 'critical',
 'Duplicate invoice numbers cause double billing and tax-reporting errors.',
 1, 'Folder 02: intentionally duplicated invoices.');

INSERT INTO @rules VALUES
('DQ-UNQ-003','Master driver license is unique','uniqueness',
 'governance_control','MASTER_CONDUCTOR','numero_licencia',
 'After mastering, each license number must map to exactly one master driver record.',
 N'SELECT COUNT(*) AS records_evaluated,
          COUNT(*) - COUNT(DISTINCT numero_licencia) AS records_failed
   FROM governance_control.MASTER_CONDUCTOR
   WHERE numero_licencia IS NOT NULL;',
 100.00, 99.00, 'high',
 'Proves the fragmented driver problem is resolved: one license = one master driver.',
 1, 'Folder 02: driver fragmented across CONDUCTOR / EMPLEADO / OPERADOR with no common key.');

INSERT INTO @rules VALUES
('DQ-UNQ-004','Order numbers are unique','uniqueness',
 'operaciones','PEDIDO','numero_pedido',
 'Count of surplus rows sharing the same numero_pedido.',
 N'SELECT COUNT(*) AS records_evaluated,
          COUNT(*) - COUNT(DISTINCT numero_pedido) AS records_failed
   FROM operaciones.PEDIDO;',
 100.00, 99.00, 'high',
 'Duplicate order numbers corrupt traceability from order to delivery to invoice.',
 0, NULL);

/* ----------------------------------------------------------------------------
   3) MERGE the staged rules into the registry (idempotent upsert on rule_code).
      Existing rows are UPDATED (definition refresh); new rows are INSERTED.
      Rows not present in the seed are intentionally left untouched
      (do NOT delete: custom/ad-hoc rules must survive re-runs).
   ---------------------------------------------------------------------------- */
MERGE governance_control.DATA_QUALITY_RULES AS tgt
USING @rules AS src
      ON tgt.rule_code = src.rule_code
WHEN MATCHED THEN
    UPDATE SET
        tgt.rule_name                = src.rule_name,
        tgt.quality_dimension        = src.quality_dimension,
        tgt.target_schema            = src.target_schema,
        tgt.target_table             = src.target_table,
        tgt.target_column            = src.target_column,
        tgt.rule_description         = src.rule_description,
        tgt.measurement_sql          = src.measurement_sql,
        tgt.threshold_pct            = src.threshold_pct,
        tgt.warning_threshold_pct    = src.warning_threshold_pct,
        tgt.severity                 = src.severity,
        tgt.business_impact          = src.business_impact,
        tgt.ties_to_folder02_problem = src.ties_to_folder02_problem,
        tgt.folder02_problem_ref     = src.folder02_problem_ref,
        tgt.updated_at               = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (rule_code, rule_name, quality_dimension, target_schema, target_table,
            target_column, rule_description, measurement_sql, threshold_pct,
            warning_threshold_pct, severity, business_impact,
            ties_to_folder02_problem, folder02_problem_ref)
    VALUES (src.rule_code, src.rule_name, src.quality_dimension, src.target_schema, src.target_table,
            src.target_column, src.rule_description, src.measurement_sql, src.threshold_pct,
            src.warning_threshold_pct, src.severity, src.business_impact,
            src.ties_to_folder02_problem, src.folder02_problem_ref);

-- Assign the count to a scalar variable first:
-- CONCAT/PRINT only accept scalar expressions, not subqueries.
DECLARE @rule_count INT =
    (SELECT COUNT(*) FROM governance_control.DATA_QUALITY_RULES WHERE is_active = 1);
PRINT CONCAT('Rules upserted. Total active rules: ', @rule_count);
GO

/* ----------------------------------------------------------------------------
   4) Backfill domain_code from the EXISTING domain registry (no guessing).
      DOMAIN_TABLE_REGISTRY already maps schema+table -> domain_code (folder 04).
   ---------------------------------------------------------------------------- */
IF OBJECT_ID(N'governance_control.DOMAIN_TABLE_REGISTRY', N'U') IS NOT NULL
BEGIN
    UPDATE r
       SET r.domain_code = dtr.domain_code,
           r.updated_at  = SYSUTCDATETIME()
    FROM governance_control.DATA_QUALITY_RULES r
    INNER JOIN governance_control.DOMAIN_TABLE_REGISTRY dtr
            ON dtr.table_schema = r.target_schema
           AND dtr.table_name   = r.target_table
    WHERE r.domain_code IS NULL;

    PRINT 'domain_code backfilled from DOMAIN_TABLE_REGISTRY.';
END
ELSE
    PRINT 'DOMAIN_TABLE_REGISTRY not found - domain_code left NULL (backfill later).';
GO

/* ----------------------------------------------------------------------------
   5) Quick verification: rule inventory by dimension.
   ---------------------------------------------------------------------------- */
SELECT quality_dimension,
       COUNT(*)                                        AS rule_count,
       SUM(CAST(ties_to_folder02_problem AS INT))      AS folder02_linked_rules
FROM governance_control.DATA_QUALITY_RULES
WHERE is_active = 1
GROUP BY quality_dimension
ORDER BY quality_dimension;
GO

/* ============================================================================
   ARCHITECTURAL CONCLUSION
   ----------------------------------------------------------------------------
   This file turns "data quality" from a one-time diagnostic into a governed,
   declarative asset. Rules are metadata, not code: each one is auditable,
   versioned by update timestamp, tied to a DAMA dimension, a severity, a
   business impact, and (where relevant) to a specific defect seeded in folder
   02. The uniform measurement contract (records_evaluated / records_failed)
   lets a single generic executor score every rule, so the quality program
   scales by data, not by procedural code. The rules that carry
   ties_to_folder02_problem = 1 are the ones whose scores move from RED to
   GREEN across the project, providing the quantitative before/after evidence
   that justifies the governance investment.
   ============================================================================ */
