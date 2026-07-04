-- =============================================================================
-- FILE: 05_sharing_agreements.sql
-- PROJECT: P02 - Data Governance Architecture | TRANSTRACK
-- =============================================================================

USE TRANSTRACK;
GO

-- =============================================================================
-- CLEANUP: drop FK child before parent
-- =============================================================================

IF OBJECT_ID('governance_control.DSA_VIOLATION_LOG',      'U') IS NOT NULL DROP TABLE governance_control.DSA_VIOLATION_LOG;
IF OBJECT_ID('governance_control.DATA_SHARING_AGREEMENT', 'U') IS NOT NULL DROP TABLE governance_control.DATA_SHARING_AGREEMENT;
GO

-- =============================================================================
-- SECTION 1: DATA_SHARING_AGREEMENT
-- =============================================================================

CREATE TABLE governance_control.DATA_SHARING_AGREEMENT (
    dsa_id                  INT IDENTITY(1,1)   NOT NULL,
    dsa_code                NVARCHAR(20)        NOT NULL,
    dsa_name                NVARCHAR(200)       NOT NULL,
    dsa_version             NVARCHAR(10)        NOT NULL DEFAULT '1.0',
    dsa_status              NVARCHAR(20)        NOT NULL DEFAULT 'DRAFT'
                            CONSTRAINT chk_dsa_status
                            CHECK (dsa_status IN ('DRAFT','UNDER_REVIEW','ACTIVE','SUSPENDED','EXPIRED')),
    producer_domain_id      INT                 NULL,
    consumer_domain_id      INT                 NULL,
    producer_schema         NVARCHAR(128)       NOT NULL,
    producer_table          NVARCHAR(128)       NOT NULL,
    consumer_schema         NVARCHAR(128)       NOT NULL,
    consumer_table          NVARCHAR(128)       NOT NULL,
    lineage_id              INT                 NULL,
    data_classification     NVARCHAR(30)        NOT NULL
                            CONSTRAINT chk_dsa_classification
                            CHECK (data_classification IN
                                ('PUBLIC','OPERATIONAL','PII','FINANCIAL_CRITICAL')),
    business_purpose        NVARCHAR(500)       NOT NULL,
    legal_basis             NVARCHAR(200)       NULL,
    completeness_sla_pct    DECIMAL(5,2)        NOT NULL DEFAULT 99.00,
    accuracy_sla_pct        DECIMAL(5,2)        NOT NULL DEFAULT 98.00,
    timeliness_sla_hours    INT                 NOT NULL DEFAULT 24,
    permitted_uses          NVARCHAR(500)       NOT NULL,
    prohibited_uses         NVARCHAR(500)       NOT NULL,
    retention_period_days   INT                 NOT NULL DEFAULT 1095,
    breach_notification_hours INT               NOT NULL DEFAULT 4,
    escalation_path         NVARCHAR(300)       NOT NULL,
    effective_date          DATE                NOT NULL,
    expiry_date             DATE                NULL,
    review_frequency_months INT                 NOT NULL DEFAULT 6,
    next_review_date        DATE                NOT NULL,
    approved_by             NVARCHAR(100)       NULL,
    approved_at             DATETIME2           NULL,
    created_at              DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    created_by              NVARCHAR(100)       NOT NULL DEFAULT SYSTEM_USER,
    CONSTRAINT PK_DATA_SHARING_AGREEMENT PRIMARY KEY CLUSTERED (dsa_id),
    CONSTRAINT UQ_DSA_CODE UNIQUE (dsa_code),
    CONSTRAINT FK_DSA_LINEAGE FOREIGN KEY (lineage_id)
        REFERENCES governance_control.DATA_LINEAGE (lineage_id)
);
GO

-- =============================================================================
-- SECTION 2: DSA VIOLATION LOG
-- =============================================================================

CREATE TABLE governance_control.DSA_VIOLATION_LOG (
    violation_id        INT IDENTITY(1,1)   NOT NULL,
    dsa_id              INT                 NOT NULL,
    violation_type      NVARCHAR(30)        NOT NULL
                        CONSTRAINT chk_violation_type
                        CHECK (violation_type IN
                            ('TIMELINESS','COMPLETENESS','ACCURACY',
                             'AVAILABILITY','UNAUTHORIZED_USE','BREACH')),
    detected_at         DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    description         NVARCHAR(500)       NOT NULL,
    actual_value        NVARCHAR(100)       NULL,
    sla_threshold       NVARCHAR(100)       NULL,
    resolution_status   NVARCHAR(20)        NOT NULL DEFAULT 'OPEN'
                        CONSTRAINT chk_violation_status
                        CHECK (resolution_status IN
                            ('OPEN','IN_PROGRESS','RESOLVED','WAIVED')),
    resolved_at         DATETIME2           NULL,
    resolution_notes    NVARCHAR(500)       NULL,
    reported_by         NVARCHAR(100)       NOT NULL DEFAULT SYSTEM_USER,
    CONSTRAINT PK_DSA_VIOLATION PRIMARY KEY CLUSTERED (violation_id),
    CONSTRAINT FK_DSA_VIOLATION FOREIGN KEY (dsa_id)
        REFERENCES governance_control.DATA_SHARING_AGREEMENT (dsa_id)
);
GO

-- =============================================================================
-- SECTION 3: INSERT DSAs
-- =============================================================================

-- DSA-OPS-BILL-001: operaciones.ENTREGA -> facturacion.FACTURA
INSERT INTO governance_control.DATA_SHARING_AGREEMENT (
    dsa_code, dsa_name, dsa_status,
    producer_schema, producer_table, consumer_schema, consumer_table,
    lineage_id, data_classification,
    business_purpose, legal_basis,
    completeness_sla_pct, accuracy_sla_pct, timeliness_sla_hours,
    permitted_uses, prohibited_uses, retention_period_days,
    breach_notification_hours, escalation_path,
    effective_date, review_frequency_months, next_review_date,
    approved_by, approved_at)
VALUES (
    'DSA-OPS-BILL-001',
    'Operations to Billing: Delivery Confirmation triggers Invoice Generation',
    'ACTIVE',
    'operaciones', 'ENTREGA',
    'facturacion', 'FACTURA',
    (SELECT lineage_id FROM governance_control.DATA_LINEAGE WHERE flow_name = 'ENTREGA_TO_FACTURA'),
    'FINANCIAL_CRITICAL',
    'Invoice generation based on confirmed deliveries. '
    + 'facturacion cannot create invoices without confirmed delivery data from operaciones.',
    'Contractual necessity. Client contracts require invoicing upon confirmed delivery.',
    99.50,
    98.00,
    6,
    'Invoice generation only. Billing dispute resolution. Aggregated financial reporting permitted.',
    'Consumer MUST NOT use conductor personal data. '
    + 'Consumer MUST NOT re-share delivery details to third parties without separate DSA. '
    + 'facturacion.FACTURA.pedido_id MUST NOT be left NULL in new invoices.',
    2190,
    4,
    'Billing Manager, CFO, CEO, Legal, Regulatory Authority',
    CAST(GETDATE() AS DATE), 6, DATEADD(MONTH,6,CAST(GETDATE() AS DATE)),
    'CFO', SYSDATETIME());
GO

-- DSA-FLEET-OPS-001: flota.TELEMETRIA_GPS -> operaciones.PEDIDO
INSERT INTO governance_control.DATA_SHARING_AGREEMENT (
    dsa_code, dsa_name, dsa_status,
    producer_schema, producer_table, consumer_schema, consumer_table,
    lineage_id, data_classification,
    business_purpose, legal_basis,
    completeness_sla_pct, accuracy_sla_pct, timeliness_sla_hours,
    permitted_uses, prohibited_uses, retention_period_days,
    breach_notification_hours, escalation_path,
    effective_date, review_frequency_months, next_review_date,
    approved_by, approved_at)
VALUES (
    'DSA-FLEET-OPS-001',
    'Fleet Telemetry to Operations: Vehicle Position for Order Tracking',
    'ACTIVE',
    'flota', 'TELEMETRIA_GPS',
    'operaciones', 'PEDIDO',
    (SELECT lineage_id FROM governance_control.DATA_LINEAGE WHERE flow_name = 'TELEMETRIA_GPS_TO_ORDER_CONTEXT'),
    'OPERATIONAL',
    'Real-time order tracking, ETA calculation, route deviation alerts, '
    + 'and incident response when vehicle stops in unauthorized location.',
    'Legitimate interest. Operational necessity for service delivery.',
    95.00,
    99.00,
    1,
    'Order ETA updates. Route adherence monitoring. Incident response. Fleet safety aggregate reporting.',
    'Consumer MUST NOT use GPS coordinates for driver performance evaluation '
    + 'without separate HR agreement. Historical GPS data MUST NOT be sold or shared externally.',
    1095,
    2,
    'Fleet Manager, Operations Director, CTO, Legal, Data Protection Authority',
    CAST(GETDATE() AS DATE), 12, DATEADD(MONTH,12,CAST(GETDATE() AS DATE)),
    'Operations Director', SYSDATETIME());
GO

-- DSA-VENTAS-FACT-001: ventas.CLIENTE -> facturacion.CLIENTE
INSERT INTO governance_control.DATA_SHARING_AGREEMENT (
    dsa_code, dsa_name, dsa_status,
    producer_schema, producer_table, consumer_schema, consumer_table,
    lineage_id, data_classification,
    business_purpose, legal_basis,
    completeness_sla_pct, accuracy_sla_pct, timeliness_sla_hours,
    permitted_uses, prohibited_uses, retention_period_days,
    breach_notification_hours, escalation_path,
    effective_date, review_frequency_months, next_review_date,
    approved_by, approved_at)
VALUES (
    'DSA-VENTAS-FACT-001',
    'Sales to Billing: Client Identity Synchronization',
    'ACTIVE',
    'ventas', 'CLIENTE',
    'facturacion', 'CLIENTE',
    (SELECT lineage_id FROM governance_control.DATA_LINEAGE WHERE flow_name = 'CLIENT_DUAL_MODULE_TO_MASTER'),
    'PII',
    'Billing module requires client identity (NIT, razon_social) to issue valid invoices. '
    + 'Two separate tables with no FK. This DSA formalizes the expected synchronization.',
    'Contractual necessity. Invoices must be issued to legally registered client identity.',
    100.00,
    99.00,
    24,
    'Invoice issuance to verified clients. Credit limit management. '
    + 'Client identity verification for billing disputes.',
    'facturacion MUST NOT create new records independently of ventas. '
    + 'All new clients must go through governance_control.MASTER_CLIENTE first. '
    + 'NIT discrepancies MUST be escalated to Data Steward, not silently overwritten.',
    2190,
    2,
    'Data Steward, Data Governance Lead, CFO, DPO',
    CAST(GETDATE() AS DATE), 6, DATEADD(MONTH,6,CAST(GETDATE() AS DATE)),
    'Data Governance Lead', SYSDATETIME());
GO

-- DSA-FLOTA-GOV-001: flota.CONDUCTOR/EMPLEADO/OPERADOR -> governance_control.MASTER_CONDUCTOR
INSERT INTO governance_control.DATA_SHARING_AGREEMENT (
    dsa_code, dsa_name, dsa_status,
    producer_schema, producer_table, consumer_schema, consumer_table,
    data_classification,
    business_purpose, legal_basis,
    completeness_sla_pct, accuracy_sla_pct, timeliness_sla_hours,
    permitted_uses, prohibited_uses, retention_period_days,
    breach_notification_hours, escalation_path,
    effective_date, review_frequency_months, next_review_date,
    approved_by, approved_at)
VALUES (
    'DSA-FLOTA-GOV-001',
    'Fleet Driver Tables to Governance Master: Driver Golden Record Synchronization',
    'ACTIVE',
    'flota', 'CONDUCTOR,EMPLEADO,OPERADOR',   -- comma-separated, no spaces or special chars
    'governance_control', 'MASTER_CONDUCTOR',
    'PII',
    'Maintain a single authoritative driver record for legal compliance, '
    + 'incident investigation, and regulatory audit. '
    + 'Resolves three-table fragmentation with no common key.',
    'Legal obligation. Transport regulations require certified driver records per vehicle.',
    100.00,
    99.00,
    24,
    'Driver identity verification for incident investigation. '
    + 'License compliance monitoring. Regulatory audit support.',
    'Driver PII MUST NOT be exposed to Billing or Sales domains without separate DSA. '
    + 'Salary and HR data from flota.EMPLEADO MUST NOT flow to MASTER_CONDUCTOR. '
    + 'Only operational attributes (license, category, status) are shared.',
    2555,
    2,
    'HR Manager, Data Steward, CTO, Legal, Transport Regulator',
    CAST(GETDATE() AS DATE), 6, DATEADD(MONTH,6,CAST(GETDATE() AS DATE)),
    'HR Manager', SYSDATETIME());
GO

-- =============================================================================
-- SECTION 4: VIOLATIONS — documented evidence of governance failures
-- =============================================================================

-- Violation 1: Orphan invoices in facturacion.FACTURA
INSERT INTO governance_control.DSA_VIOLATION_LOG (
    dsa_id, violation_type, description,
    actual_value, sla_threshold, resolution_status, reported_by)
VALUES (
    (SELECT dsa_id FROM governance_control.DATA_SHARING_AGREEMENT WHERE dsa_code = 'DSA-OPS-BILL-001'),
    'COMPLETENESS',
    'facturacion.FACTURA.pedido_id is NULLABLE with no constraint preventing NULL inserts. '
    + 'Invoices created without linked order cannot be attributed to a delivery. '
    + 'No UNIQUE constraint on numero_factura allows duplicate invoice numbers. '
    + 'Root cause: billing batch job inserts NULL when pedido lookup fails instead of rejecting.',
    'Unquantified. Diagnostic query required.',
    '99.50% completeness (zero orphan invoices)',
    'OPEN',
    'cblancogt');
GO

-- Violation 2: Telemetry has no order context
INSERT INTO governance_control.DSA_VIOLATION_LOG (
    dsa_id, violation_type, description,
    actual_value, sla_threshold, resolution_status, reported_by)
VALUES (
    (SELECT dsa_id FROM governance_control.DATA_SHARING_AGREEMENT WHERE dsa_code = 'DSA-FLEET-OPS-001'),
    'ACCURACY',
    'flota.TELEMETRIA_GPS has vehiculo_id (INT, no FK) but NO pedido_id column. '
    + '50M GPS records cannot be formally linked to any active order. '
    + 'flota.ASIGNACION_VEHICULO provides a temporal bridge but is not used in queries. '
    + 'Legal risk: incident reconstruction requires telemetry-vehicle-assignment-order chain.',
    '0%. No order context available in telemetry table.',
    '99.00% accuracy (GPS records linkable to active order)',
    'OPEN',
    'cblancogt');
GO

-- Violation 3: Dual client tables, incompatible NIT formats
INSERT INTO governance_control.DSA_VIOLATION_LOG (
    dsa_id, violation_type, description,
    actual_value, sla_threshold, resolution_status, reported_by)
VALUES (
    (SELECT dsa_id FROM governance_control.DATA_SHARING_AGREEMENT WHERE dsa_code = 'DSA-VENTAS-FACT-001'),
    'ACCURACY',
    'ventas.CLIENTE and facturacion.CLIENTE represent the same clients '
    + 'with different column names (nombre vs razon_social, email vs correo) and NO FK between modules. '
    + 'NIT formats are incompatible: ventas uses NIT-XXXXXX, facturacion uses plain integer. '
    + 'Zero cross-module NIT matches confirmed. Billing invoices may reference wrong legal entity.',
    '0 cross-module NIT matches out of 27,000 combined records.',
    '100% NIT match between ventas.CLIENTE and facturacion.CLIENTE',
    'IN_PROGRESS',
    'cblancogt');
GO

-- =============================================================================
-- SECTION 5: COMPLIANCE VIEW
-- =============================================================================

CREATE OR ALTER VIEW governance_control.vw_dsa_compliance_summary
AS
    SELECT
        dsa.dsa_code,
        dsa.dsa_name,
        dsa.dsa_status,
        dsa.data_classification,
        dsa.producer_schema + '.' + dsa.producer_table AS producer,
        dsa.consumer_schema + '.' + dsa.consumer_table AS consumer,
        dsa.effective_date,
        dsa.next_review_date,
        CASE
            WHEN dsa.next_review_date < CAST(GETDATE() AS DATE) THEN 'OVERDUE'
            WHEN dsa.next_review_date <= DATEADD(DAY,30,CAST(GETDATE() AS DATE)) THEN 'DUE_SOON'
            ELSE 'CURRENT'
        END AS review_status,
        ISNULL(v.open_violations, 0) AS open_violations,
        dsa.completeness_sla_pct,
        dsa.accuracy_sla_pct,
        dsa.timeliness_sla_hours
    FROM governance_control.DATA_SHARING_AGREEMENT dsa
    LEFT JOIN (
        SELECT dsa_id, COUNT(*) AS open_violations
        FROM governance_control.DSA_VIOLATION_LOG
        WHERE resolution_status = 'OPEN'
        GROUP BY dsa_id
    ) v ON v.dsa_id = dsa.dsa_id;
GO

-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT * FROM governance_control.vw_dsa_compliance_summary;
GO

SELECT
    d.dsa_code,
    v.violation_type,
    LEFT(v.description, 80) + '...' AS description_short,
    v.resolution_status,
    v.detected_at
FROM governance_control.DSA_VIOLATION_LOG v
JOIN governance_control.DATA_SHARING_AGREEMENT d ON d.dsa_id = v.dsa_id
ORDER BY v.detected_at;
GO
