/*
=============================================================================
  TRANSTRACK — Data Governance Architecture
  Script:  03_classification.sql
  Purpose: Create DATA_CLASSIFICATION table and classify EVERY column
           of EVERY operational table in TRANSTRACK.
           This is the formal registry that an auditor reviews.
Validated by: Carlos Blanco
  Ref:     DAMA-DMBOK 2nd Ed. Ch.7 — Data Security
           ISO 27001:2022 A.5.12 — Classification of information
           ISO 27001:2022 A.5.9  — Inventory of information assets
           classification_policy.md — Classification criteria
  Depends: 01_domains_ownership.sql
=============================================================================
*/

USE TRANSTRACK;
GO

-- =============================================================================
-- SECTION 1: DATA_CLASSIFICATION TABLE
-- Formal registry of every column's sensitivity level.
-- An auditor reviewing TRANSTRACK's security posture would request this table
-- as the first artifact — it answers "what data do you have and how sensitive
-- is it?" in a structured, queryable format.
-- =============================================================================

IF OBJECT_ID('governance_control.DATA_CLASSIFICATION', 'U') IS NOT NULL
    DROP TABLE governance_control.DATA_CLASSIFICATION;
GO

CREATE TABLE governance_control.DATA_CLASSIFICATION
(
    classification_id       INT             NOT NULL IDENTITY(1,1),
    schema_name             SYSNAME         NOT NULL    DEFAULT 'dbo',
    table_name              SYSNAME         NOT NULL,
    column_name             SYSNAME         NOT NULL,
    classification_level    VARCHAR(30)     NOT NULL,
    -- PII | FINANCIAL_CRITICAL | OPERATIONAL_SENSITIVE | PUBLIC
    information_type        VARCHAR(100)    NOT NULL,
    -- More specific than level: e.g., 'National ID', 'GPS Location', 'Invoice Amount'
    classified_by           NVARCHAR(200)   NOT NULL    DEFAULT 'Data Architecture Lead',
    classified_date         DATE            NOT NULL    DEFAULT CAST(GETDATE() AS DATE),
    classification_version  VARCHAR(10)     NOT NULL    DEFAULT '1.0',
    justification           NVARCHAR(500)   NOT NULL,
    gdpr_applicable         BIT             NOT NULL    DEFAULT 0,
    sox_applicable          BIT             NOT NULL    DEFAULT 0,
    requires_masking        BIT             NOT NULL    DEFAULT 0,  -- In non-prod environments
    requires_audit_log      BIT             NOT NULL    DEFAULT 0,  -- SQL Server Audit required
    last_reviewed_date      DATE            NULL,
    reclassification_notes  NVARCHAR(500)   NULL,
    CONSTRAINT PK_DATA_CLASSIFICATION PRIMARY KEY (classification_id),
    CONSTRAINT UQ_DC_COLUMN UNIQUE (schema_name, table_name, column_name),
    CONSTRAINT CHK_DC_LEVEL CHECK (classification_level IN
        ('PII', 'FINANCIAL_CRITICAL', 'OPERATIONAL_SENSITIVE', 'PUBLIC'))
);
GO

CREATE NONCLUSTERED INDEX IX_DC_Level ON governance_control.DATA_CLASSIFICATION (classification_level)
    INCLUDE (table_name, column_name, requires_audit_log);
GO

CREATE NONCLUSTERED INDEX IX_DC_Table ON governance_control.DATA_CLASSIFICATION (table_name, schema_name)
    INCLUDE (column_name, classification_level);
GO

-- =============================================================================
-- SECTION 2: CLASSIFY ALL COLUMNS — TABLE BY TABLE
-- Order: CLIENTE, CONTRATO_CLIENTE, FACTURA, PEDIDO, RUTA, ENTREGA,
--        INCIDENTE, VEHICULO, CONDUCTOR, EMPLEADO, OPERADOR, TELEMETRIA_GPS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- TABLE: CLIENTE — Domain CLIENTES | 15,000 rows with intentional duplicates
-- Highest PII concentration in the domain. Every person-identifying field is PII.
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'CLIENTE', 'cliente_id',       'OPERATIONAL_SENSITIVE', 'System Identifier',
 'Surrogate key. Not PII alone but links to PII records. Sensitive in join context.',
 0, 0, 0, 0),
('dbo', 'CLIENTE', 'nit',              'PII', 'Tax Identification Number',
 'NIT identifies a legal person or company in Guatemala. Links to tax authority records.',
 1, 0, 1, 1),
('dbo', 'CLIENTE', 'nombre_cliente',   'PII', 'Full Name / Company Name',
 'Natural person or company name. PII by GDPR definition. Source of diagnostic duplicate problem.',
 1, 0, 1, 1),
('dbo', 'CLIENTE', 'email',            'PII', 'Email Address',
 'Direct personal identifier. GDPR Art.4 personal data.',
 1, 0, 1, 1),
('dbo', 'CLIENTE', 'telefono',         'PII', 'Phone Number',
 'Direct personal identifier.',
 1, 0, 1, 1),
('dbo', 'CLIENTE', 'direccion',        'PII', 'Physical Address',
 'Location data linked to natural person.',
 1, 0, 1, 1),
('dbo', 'CLIENTE', 'ciudad',           'PUBLIC', 'City Name',
 'General geographic reference. Not personal when separated from client identity.',
 0, 0, 0, 0),
('dbo', 'CLIENTE', 'departamento',     'PUBLIC', 'Department/Region',
 'Administrative region. Public reference data.',
 0, 0, 0, 0),
('dbo', 'CLIENTE', 'categoria_cliente','OPERATIONAL_SENSITIVE', 'Client Category',
 'Business segmentation. Sensitive for competitive analysis but not personal.',
 0, 0, 0, 0),
('dbo', 'CLIENTE', 'fecha_registro',   'OPERATIONAL_SENSITIVE', 'Registration Date',
 'Operational timestamp. Not PII alone.',
 0, 0, 0, 0),
('dbo', 'CLIENTE', 'modulo_origen',    'OPERATIONAL_SENSITIVE', 'Source Module',
 'Identifies which module created the record — key evidence field for duplicate diagnosis.',
 0, 0, 0, 0),
('dbo', 'CLIENTE', 'activo',           'PUBLIC', 'Active Flag',
 'Operational status flag. No sensitivity.',
 0, 0, 0, 0);
GO

-- -----------------------------------------------------------------------------
-- TABLE: CONTRATO_CLIENTE — Domain CLIENTES | 12,000 rows
-- Financial terms and tariffs. FINANCIAL_CRITICAL for billing amounts.
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'CONTRATO_CLIENTE', 'contrato_id',          'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key.', 0, 0, 0, 0),
('dbo', 'CONTRATO_CLIENTE', 'cliente_id',            'OPERATIONAL_SENSITIVE', 'Foreign Key to Client', 'Links to PII table; sensitive in join context.', 0, 1, 0, 1),
('dbo', 'CONTRATO_CLIENTE', 'fecha_inicio',          'FINANCIAL_CRITICAL', 'Contract Start Date', 'Defines financial obligation period.', 0, 1, 0, 1),
('dbo', 'CONTRATO_CLIENTE', 'fecha_fin',             'FINANCIAL_CRITICAL', 'Contract End Date', 'Defines billing validity window.', 0, 1, 0, 1),
('dbo', 'CONTRATO_CLIENTE', 'tarifa_base',           'FINANCIAL_CRITICAL', 'Base Tariff',  'Determines invoice amounts. SOX-relevant.', 0, 1, 1, 1),
('dbo', 'CONTRATO_CLIENTE', 'tarifa_km_adicional',   'FINANCIAL_CRITICAL', 'Additional KM Tariff', 'Variable billing rate. SOX-relevant.', 0, 1, 1, 1),
('dbo', 'CONTRATO_CLIENTE', 'descuento_pct',         'FINANCIAL_CRITICAL', 'Discount Percentage', 'Affects final billed amount.', 0, 1, 1, 1),
('dbo', 'CONTRATO_CLIENTE', 'tipo_servicio',         'OPERATIONAL_SENSITIVE', 'Service Type', 'Business classification, not personal.', 0, 0, 0, 0),
('dbo', 'CONTRATO_CLIENTE', 'condiciones_pago',      'FINANCIAL_CRITICAL', 'Payment Terms', 'Financial obligation terms.', 0, 1, 0, 1),
('dbo', 'CONTRATO_CLIENTE', 'activo',                'PUBLIC', 'Active Flag', 'Status flag. No sensitivity.', 0, 0, 0, 0);
GO

-- -----------------------------------------------------------------------------
-- TABLE: FACTURA — Domain CLIENTES | 490,000 rows
-- Financial records with intentional orphans and duplicates (diagnostic evidence).
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'FACTURA', 'factura_id',       'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key.', 0, 0, 0, 0),
('dbo', 'FACTURA', 'numero_factura',   'FINANCIAL_CRITICAL', 'Invoice Number', 'Official financial document identifier. Tax authority requires 5-year retention.', 0, 1, 0, 1),
('dbo', 'FACTURA', 'cliente_id',       'OPERATIONAL_SENSITIVE', 'FK to Client', 'Links to PII — sensitive in join.', 0, 1, 0, 1),
('dbo', 'FACTURA', 'pedido_id',        'OPERATIONAL_SENSITIVE', 'FK to Order', 'Referential integrity key — orphan invoices are the diagnostic problem.', 0, 1, 0, 1),
('dbo', 'FACTURA', 'fecha_emision',    'FINANCIAL_CRITICAL', 'Issue Date', 'Determines fiscal period.', 0, 1, 0, 1),
('dbo', 'FACTURA', 'monto_subtotal',   'FINANCIAL_CRITICAL', 'Subtotal Amount', 'Revenue recognition. SOX A.5 relevant.', 0, 1, 1, 1),
('dbo', 'FACTURA', 'monto_impuesto',   'FINANCIAL_CRITICAL', 'Tax Amount', 'Tax liability. SAT Guatemala regulatory.', 0, 1, 1, 1),
('dbo', 'FACTURA', 'monto_total',      'FINANCIAL_CRITICAL', 'Total Invoice Amount', 'Billable amount. SOX-relevant.', 0, 1, 1, 1),
('dbo', 'FACTURA', 'estado_factura',   'FINANCIAL_CRITICAL', 'Invoice Status', 'Paid/pending status affects revenue recognition.', 0, 1, 0, 1),
('dbo', 'FACTURA', 'es_duplicada',     'OPERATIONAL_SENSITIVE', 'Duplicate Flag', 'Intentional diagnostic field marking known duplicate invoices.', 0, 0, 0, 0);
GO

-- -----------------------------------------------------------------------------
-- TABLE: PEDIDO — Domain OPERACIONES | 500,000 rows from 2019
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'PEDIDO', 'pedido_id',         'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key.', 0, 0, 0, 0),
('dbo', 'PEDIDO', 'cliente_id',        'OPERATIONAL_SENSITIVE', 'FK to Client', 'Links to PII table.', 0, 0, 0, 0),
('dbo', 'PEDIDO', 'ruta_id',           'OPERATIONAL_SENSITIVE', 'FK to Route', 'Operational reference.', 0, 0, 0, 0),
('dbo', 'PEDIDO', 'vehiculo_id',       'OPERATIONAL_SENSITIVE', 'FK to Vehicle', 'Asset reference.', 0, 0, 0, 0),
('dbo', 'PEDIDO', 'conductor_id',      'OPERATIONAL_SENSITIVE', 'FK to Driver', 'Links to PII — sensitive in join.', 0, 0, 0, 0),
('dbo', 'PEDIDO', 'fecha_pedido',      'OPERATIONAL_SENSITIVE', 'Order Date', 'Operational timestamp.', 0, 0, 0, 0),
('dbo', 'PEDIDO', 'fecha_requerida',   'OPERATIONAL_SENSITIVE', 'Required Delivery Date', 'SLA reference.', 0, 0, 0, 0),
('dbo', 'PEDIDO', 'peso_carga_kg',     'OPERATIONAL_SENSITIVE', 'Cargo Weight', 'Operational metric. Could affect liability in incident.', 0, 0, 0, 0),
('dbo', 'PEDIDO', 'valor_carga',       'FINANCIAL_CRITICAL', 'Cargo Declared Value', 'Affects insurance and liability calculations.', 0, 1, 0, 1),
('dbo', 'PEDIDO', 'estado_pedido',     'OPERATIONAL_SENSITIVE', 'Order Status', 'Operational status.', 0, 0, 0, 0),
('dbo', 'PEDIDO', 'descripcion_carga', 'OPERATIONAL_SENSITIVE', 'Cargo Description', 'Operational detail. Could be sensitive for hazmat.', 0, 0, 0, 0);
GO

-- -----------------------------------------------------------------------------
-- TABLE: RUTA — Domain OPERACIONES | 2,500 routes
-- Reference data within Operaciones domain.
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'RUTA', 'ruta_id',             'PUBLIC', 'System Identifier', 'Surrogate key. Public entity.', 0, 0, 0, 0),
('dbo', 'RUTA', 'ciudad_origen',       'PUBLIC', 'Origin City', 'Geographic reference. Public information.', 0, 0, 0, 0),
('dbo', 'RUTA', 'ciudad_destino',      'PUBLIC', 'Destination City', 'Geographic reference. Public information.', 0, 0, 0, 0),
('dbo', 'RUTA', 'distancia_km',        'OPERATIONAL_SENSITIVE', 'Distance in KM', 'Used for billing calculations. Sensitive in tariff context.', 0, 0, 0, 0),
('dbo', 'RUTA', 'tiempo_estimado_hrs', 'OPERATIONAL_SENSITIVE', 'Estimated Duration', 'Operational planning data.', 0, 0, 0, 0),
('dbo', 'RUTA', 'tipo_ruta',           'PUBLIC', 'Route Type', 'Classification code. No sensitivity.', 0, 0, 0, 0),
('dbo', 'RUTA', 'activa',              'PUBLIC', 'Active Flag', 'Status flag.', 0, 0, 0, 0);
GO

-- -----------------------------------------------------------------------------
-- TABLE: ENTREGA — Domain OPERACIONES | 480,000 rows
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'ENTREGA', 'entrega_id',           'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key.', 0, 0, 0, 0),
('dbo', 'ENTREGA', 'pedido_id',            'OPERATIONAL_SENSITIVE', 'FK to Order', 'Operational reference.', 0, 0, 0, 0),
('dbo', 'ENTREGA', 'conductor_id',         'OPERATIONAL_SENSITIVE', 'FK to Driver', 'Links to PII — sensitive in join.', 0, 0, 0, 0),
('dbo', 'ENTREGA', 'vehiculo_id',          'OPERATIONAL_SENSITIVE', 'FK to Vehicle', 'Asset reference.', 0, 0, 0, 0),
('dbo', 'ENTREGA', 'fecha_entrega_real',   'OPERATIONAL_SENSITIVE', 'Actual Delivery Date', 'SLA compliance metric.', 0, 0, 0, 0),
('dbo', 'ENTREGA', 'fecha_entrega_estim',  'OPERATIONAL_SENSITIVE', 'Estimated Delivery Date', 'Planning reference.', 0, 0, 0, 0),
('dbo', 'ENTREGA', 'estado_entrega',       'OPERATIONAL_SENSITIVE', 'Delivery Status', 'Operational status.', 0, 0, 0, 0),
('dbo', 'ENTREGA', 'firma_receptor',       'PII', 'Recipient Signature',
 'Electronic signature identifies a natural person at delivery point.',
 1, 0, 1, 1),
('dbo', 'ENTREGA', 'nombre_receptor',      'PII', 'Recipient Name',
 'Natural person identity at delivery.',
 1, 0, 1, 1),
('dbo', 'ENTREGA', 'observaciones',        'OPERATIONAL_SENSITIVE', 'Delivery Notes', 'Free text. May contain incidental personal references.', 0, 0, 0, 0),
('dbo', 'ENTREGA', 'incidente_registrado', 'OPERATIONAL_SENSITIVE', 'Incident Flag', 'Boolean indicator. Not sensitive alone.', 0, 0, 0, 0);
GO

-- -----------------------------------------------------------------------------
-- TABLE: INCIDENTE — Domain OPERACIONES | 8,500 rows
-- Highest legal sensitivity. Contains PII when driver is identified.
-- 10-year retention per POLICY-002.
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'INCIDENTE', 'incidente_id',       'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key.', 0, 0, 0, 0),
('dbo', 'INCIDENTE', 'pedido_id',          'OPERATIONAL_SENSITIVE', 'FK to Order', 'Establishes operational context.', 0, 0, 0, 1),
('dbo', 'INCIDENTE', 'conductor_id',       'PII', 'FK to Driver',
 'Identifies the driver involved. Links to PII master record. Critical for legal chain-of-custody.',
 1, 0, 0, 1),
('dbo', 'INCIDENTE', 'vehiculo_id',        'OPERATIONAL_SENSITIVE', 'FK to Vehicle', 'Asset identifier in incident.', 0, 0, 0, 1),
('dbo', 'INCIDENTE', 'fecha_incidente',    'OPERATIONAL_SENSITIVE', 'Incident Date', 'Legal evidence timestamp.', 0, 0, 0, 1),
('dbo', 'INCIDENTE', 'tipo_incidente',     'PUBLIC', 'Incident Type Code', 'Reference code. Accident/theft/delay/damage.', 0, 0, 0, 0),
('dbo', 'INCIDENTE', 'descripcion',        'OPERATIONAL_SENSITIVE', 'Incident Description',
 'Free text narrative. May contain PII (witness names, third-party details). '
 + 'Treated as OPERATIONAL_SENSITIVE with PII caveat.',
 0, 0, 0, 1),
('dbo', 'INCIDENTE', 'monto_dano',         'FINANCIAL_CRITICAL', 'Damage Amount', 'Insurance/liability amount.', 0, 1, 0, 1),
('dbo', 'INCIDENTE', 'estado_resolucion',  'OPERATIONAL_SENSITIVE', 'Resolution Status', 'Legal proceeding status.', 0, 0, 0, 1),
('dbo', 'INCIDENTE', 'documentos_adjuntos','OPERATIONAL_SENSITIVE', 'Attached Documents Reference',
 'References to photos, reports, signatures stored externally (Week 12 governance).',
 0, 0, 0, 1),
('dbo', 'INCIDENTE', 'reportado_por',      'PII', 'Reported By',
 'Name of the person who filed the incident report.',
 1, 0, 1, 1);
GO

-- -----------------------------------------------------------------------------
-- TABLE: VEHICULO — Domain FLOTA | 800 rows
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'VEHICULO', 'vehiculo_id',         'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key.', 0, 0, 0, 0),
('dbo', 'VEHICULO', 'placa',               'OPERATIONAL_SENSITIVE', 'License Plate',
 'Vehicle identifier. Sensitive: links to incidents and insurance. Not PII but operationally sensitive.',
 0, 0, 0, 1),
('dbo', 'VEHICULO', 'marca',               'PUBLIC', 'Make/Brand', 'Vehicle manufacturer. Public information.', 0, 0, 0, 0),
('dbo', 'VEHICULO', 'modelo',              'PUBLIC', 'Model', 'Vehicle model. Public information.', 0, 0, 0, 0),
('dbo', 'VEHICULO', 'anio',                'PUBLIC', 'Year', 'Manufacturing year.', 0, 0, 0, 0),
('dbo', 'VEHICULO', 'capacidad_ton',       'OPERATIONAL_SENSITIVE', 'Capacity in Tons', 'Affects route assignment and billing.', 0, 0, 0, 0),
('dbo', 'VEHICULO', 'tipo_vehiculo',       'PUBLIC', 'Vehicle Type', 'Reference classification.', 0, 0, 0, 0),
('dbo', 'VEHICULO', 'estado_vehiculo',     'OPERATIONAL_SENSITIVE', 'Vehicle Status', 'Active/inactive/maintenance.', 0, 0, 0, 0),
('dbo', 'VEHICULO', 'fecha_adquisicion',   'FINANCIAL_CRITICAL', 'Acquisition Date', 'Asset accounting reference.', 0, 1, 0, 1),
('dbo', 'VEHICULO', 'valor_adquisicion',   'FINANCIAL_CRITICAL', 'Acquisition Value', 'Asset value for accounting.', 0, 1, 1, 1);
GO

-- -----------------------------------------------------------------------------
-- TABLE: CONDUCTOR — Domain FLOTA | Part of fragmented 1,200 driver records
-- Highest PII concentration in the Fleet domain.
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'CONDUCTOR', 'conductor_id',       'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key — not shared with EMPLEADO or OPERADOR (the fragmentation problem).', 0, 0, 0, 0),
('dbo', 'CONDUCTOR', 'numero_licencia',    'PII', 'Driver License Number',
 'Government-issued personal identifier. Primary business key for driver identity.',
 1, 0, 1, 1),
('dbo', 'CONDUCTOR', 'dpi',                'PII', 'National ID (DPI)',
 'National identification document. Direct personal identifier. Highest sensitivity.',
 1, 0, 1, 1),
('dbo', 'CONDUCTOR', 'nombre',             'PII', 'Full Name', 'Natural person identifier.', 1, 0, 1, 1),
('dbo', 'CONDUCTOR', 'apellido',           'PII', 'Last Name', 'Natural person identifier.', 1, 0, 1, 1),
('dbo', 'CONDUCTOR', 'fecha_nacimiento',   'PII', 'Date of Birth', 'Personal data per GDPR Art.4.', 1, 0, 1, 1),
('dbo', 'CONDUCTOR', 'telefono',           'PII', 'Phone Number', 'Direct personal contact.', 1, 0, 1, 1),
('dbo', 'CONDUCTOR', 'tipo_licencia',      'OPERATIONAL_SENSITIVE', 'License Type', 'Operational qualification. Not personal alone.', 0, 0, 0, 0),
('dbo', 'CONDUCTOR', 'fecha_vencimiento_licencia', 'OPERATIONAL_SENSITIVE', 'License Expiry', 'Operational compliance date.', 0, 0, 0, 1),
('dbo', 'CONDUCTOR', 'activo',             'PUBLIC', 'Active Flag', 'Status flag.', 0, 0, 0, 0);
GO

-- -----------------------------------------------------------------------------
-- TABLE: EMPLEADO — Domain FLOTA | Second fragment of driver records
-- Contains HR data — highest PII plus labor law implications.
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'EMPLEADO', 'empleado_id',         'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key.', 0, 0, 0, 0),
('dbo', 'EMPLEADO', 'codigo_empleado',     'PII', 'Employee Code', 'HR system identifier linked to person.', 1, 0, 1, 1),
('dbo', 'EMPLEADO', 'nombre_completo',     'PII', 'Full Name', 'Natural person identifier.', 1, 0, 1, 1),
('dbo', 'EMPLEADO', 'dpi',                 'PII', 'National ID (DPI)', 'Highest sensitivity. Government ID.', 1, 0, 1, 1),
('dbo', 'EMPLEADO', 'salario_base',        'PII', 'Base Salary',
 'Financial PII — salary is personal data under GDPR and labor privacy norms.',
 1, 0, 1, 1),
('dbo', 'EMPLEADO', 'fecha_contratacion',  'OPERATIONAL_SENSITIVE', 'Hire Date', 'HR operational date.', 0, 0, 0, 1),
('dbo', 'EMPLEADO', 'departamento_rrhh',   'OPERATIONAL_SENSITIVE', 'HR Department', 'Internal organizational reference.', 0, 0, 0, 0),
('dbo', 'EMPLEADO', 'estado_empleo',       'OPERATIONAL_SENSITIVE', 'Employment Status', 'Active/terminated.', 0, 0, 0, 1);
GO

-- -----------------------------------------------------------------------------
-- TABLE: OPERADOR — Domain FLOTA | Third fragment of driver records
-- System-oriented view of the same driver population.
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'OPERADOR', 'operador_id',         'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key — no FK to CONDUCTOR or EMPLEADO.', 0, 0, 0, 0),
('dbo', 'OPERADOR', 'nombre_operador',     'PII', 'Operator Name', 'Natural person identifier.', 1, 0, 1, 1),
('dbo', 'OPERADOR', 'codigo_sistema',      'OPERATIONAL_SENSITIVE', 'System Login Code', 'Application credential reference.', 0, 0, 0, 1),
('dbo', 'OPERADOR', 'nivel_acceso',        'OPERATIONAL_SENSITIVE', 'Access Level', 'Application permission tier.', 0, 0, 0, 1),
('dbo', 'OPERADOR', 'equipo_asignado',     'OPERATIONAL_SENSITIVE', 'Assigned Device', 'Asset tracking reference.', 0, 0, 0, 0),
('dbo', 'OPERADOR', 'activo',              'PUBLIC', 'Active Flag', 'Status flag.', 0, 0, 0, 0);
GO

-- -----------------------------------------------------------------------------
-- TABLE: TELEMETRIA_GPS — Domain FLOTA | 50,000,000 rows | Partitioned
-- GPS coordinates linked to a driver are PII by GDPR definition.
-- This is the largest table and the most complex classification.
-- -----------------------------------------------------------------------------
INSERT INTO governance_control.DATA_CLASSIFICATION
    (schema_name, table_name, column_name, classification_level, information_type,
     justification, gdpr_applicable, sox_applicable, requires_masking, requires_audit_log)
VALUES
('dbo', 'TELEMETRIA_GPS', 'telemetria_id',      'OPERATIONAL_SENSITIVE', 'System Identifier', 'Surrogate key.', 0, 0, 0, 0),
('dbo', 'TELEMETRIA_GPS', 'vehiculo_id',         'OPERATIONAL_SENSITIVE', 'FK to Vehicle', 'Asset reference.', 0, 0, 0, 0),
('dbo', 'TELEMETRIA_GPS', 'conductor_id',         'PII', 'FK to Driver',
 'When combined with timestamp and coordinates, identifies the precise location of a '
 + 'natural person at a specific moment. GDPR Art.4 location data = personal data.',
 1, 0, 0, 1),
('dbo', 'TELEMETRIA_GPS', 'latitud',             'PII', 'GPS Latitude',
 'Geographic coordinate. Personal data when linked to conductor_id.',
 1, 0, 1, 1),
('dbo', 'TELEMETRIA_GPS', 'longitud',            'PII', 'GPS Longitude',
 'Geographic coordinate. Personal data when linked to conductor_id.',
 1, 0, 1, 1),
('dbo', 'TELEMETRIA_GPS', 'fecha_registro',      'OPERATIONAL_SENSITIVE', 'Timestamp', 'Temporal context for location data.', 0, 0, 0, 0),
('dbo', 'TELEMETRIA_GPS', 'velocidad_kmh',       'OPERATIONAL_SENSITIVE', 'Speed in KMH',
 'Operational and insurance/incident data. Not personal alone, but linked to driver in join.',
 0, 0, 0, 0),
('dbo', 'TELEMETRIA_GPS', 'rpm_motor',           'OPERATIONAL_SENSITIVE', 'Engine RPM', 'Maintenance diagnostic data.', 0, 0, 0, 0),
('dbo', 'TELEMETRIA_GPS', 'temperatura_motor',   'OPERATIONAL_SENSITIVE', 'Engine Temperature', 'Operational health metric.', 0, 0, 0, 0),
('dbo', 'TELEMETRIA_GPS', 'nivel_combustible',   'OPERATIONAL_SENSITIVE', 'Fuel Level', 'Operational metric.', 0, 0, 0, 0),
('dbo', 'TELEMETRIA_GPS', 'anio_particion',      'PUBLIC', 'Partition Year', 'Administrative partition column. No sensitivity.', 0, 0, 0, 0),
('dbo', 'TELEMETRIA_GPS', 'mes_particion',       'PUBLIC', 'Partition Month', 'Administrative partition column. No sensitivity.', 0, 0, 0, 0);
GO

-- =============================================================================
-- SECTION 3: VERIFICATION QUERIES
-- =============================================================================

-- Classification summary by level
SELECT
    classification_level            AS [Level],
    COUNT(*)                        AS [Column Count],
    COUNT(DISTINCT table_name)      AS [Tables Affected],
    SUM(CAST(gdpr_applicable AS INT)) AS [GDPR Applicable],
    SUM(CAST(sox_applicable AS INT))  AS [SOX Applicable],
    SUM(CAST(requires_audit_log AS INT)) AS [Requires Audit Log]
FROM governance_control.DATA_CLASSIFICATION
GROUP BY classification_level
ORDER BY
    CASE classification_level
        WHEN 'PII'                  THEN 1
        WHEN 'FINANCIAL_CRITICAL'   THEN 2
        WHEN 'OPERATIONAL_SENSITIVE' THEN 3
        ELSE 4
    END;
GO

-- PII columns that require audit log — the SQL Server Audit spec (Script 05) targets these
SELECT
    table_name          AS [Table],
    column_name         AS [Column],
    information_type    AS [Information Type],
    justification       AS [Justification]
FROM governance_control.DATA_CLASSIFICATION
WHERE classification_level = 'PII'
  AND requires_audit_log = 1
ORDER BY table_name, column_name;
GO

-- Confirm all 12 operational tables are classified
SELECT
    table_name              AS [Table],
    COUNT(*)                AS [Columns Classified],
    MAX(CASE WHEN classification_level = 'PII'                  THEN 1 ELSE 0 END) AS [Has PII],
    MAX(CASE WHEN classification_level = 'FINANCIAL_CRITICAL'   THEN 1 ELSE 0 END) AS [Has Financial],
    MAX(CASE WHEN requires_audit_log = 1                        THEN 1 ELSE 0 END) AS [Needs Audit]
FROM governance_control.DATA_CLASSIFICATION
GROUP BY table_name
ORDER BY table_name;
GO

/*
=============================================================================
  ARCHITECTURAL NOTE:
  Classification is the upstream dependency for every security control.
  The five RLS roles in Script 04 are constructed based on this registry.
  The SQL Server Audit spec in Script 05 targets exactly the tables and
  columns flagged with requires_audit_log = 1 here.

  The TELEMETRIA_GPS classification demonstrates a key GDPR principle:
  GPS coordinates alone are not necessarily personal data, but GPS coordinates
  linked to a conductor_id are — because they identify a natural person's
  precise location at a specific time. This is classification by context,
  not by column type.
=============================================================================
*/
