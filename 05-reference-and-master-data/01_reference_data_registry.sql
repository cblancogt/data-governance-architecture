-- =============================================================================
-- FILE: 01_reference_data_registry.sql
-- PROJECT: P02 - Data Governance Architecture | TRANSTRACK
-- =============================================================================

USE TRANSTRACK;
GO

-- =============================================================================
-- SECTION 0: CREATE MISSING SCHEMA
-- 'ref' schema does not exist yet
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ref')
    EXEC ('CREATE SCHEMA ref');
GO

-- =============================================================================
-- SECTION 1: REF_DATA_REGISTRY in governance_control (existing schema)
-- =============================================================================

IF OBJECT_ID('governance_control.REF_DATA_REGISTRY', 'U') IS NOT NULL
    DROP TABLE governance_control.REF_DATA_REGISTRY;
GO

CREATE TABLE governance_control.REF_DATA_REGISTRY (
    registry_id         INT IDENTITY(1,1)       NOT NULL,
    ref_table_name      NVARCHAR(128)           NOT NULL,
    ref_schema_name     NVARCHAR(128)           NOT NULL DEFAULT 'ref',
    domain_id           INT                     NULL,   -- FK to governance_control.DATA_DOMAIN (nullable)
    business_name       NVARCHAR(200)           NOT NULL,
    description         NVARCHAR(500)           NOT NULL,
    owner_domain        NVARCHAR(100)           NOT NULL,
    stability_class     NVARCHAR(20)            NOT NULL DEFAULT 'STABLE'
                        CONSTRAINT chk_ref_stability
                        CHECK (stability_class IN ('STATIC','STABLE','VOLATILE')),
    change_process      NVARCHAR(200)           NOT NULL,
    approval_required   BIT                     NOT NULL DEFAULT 1,
    current_version     NVARCHAR(20)            NOT NULL DEFAULT '1.0',
    last_review_date    DATE                    NOT NULL DEFAULT CAST(GETDATE() AS DATE),
    next_review_date    DATE                    NOT NULL,
    expected_row_count  INT                     NULL,
    is_active           BIT                     NOT NULL DEFAULT 1,
    created_at          DATETIME2               NOT NULL DEFAULT SYSDATETIME(),
    created_by          NVARCHAR(100)           NOT NULL DEFAULT SYSTEM_USER,
    updated_at          DATETIME2               NOT NULL DEFAULT SYSDATETIME(),
    updated_by          NVARCHAR(100)           NOT NULL DEFAULT SYSTEM_USER,
    CONSTRAINT PK_REF_DATA_REGISTRY PRIMARY KEY CLUSTERED (registry_id),
    CONSTRAINT UQ_REF_TABLE UNIQUE (ref_schema_name, ref_table_name)
);
GO

-- =============================================================================
-- SECTION 2: VERSION LOG
-- =============================================================================

IF OBJECT_ID('governance_control.REF_DATA_VERSION_LOG', 'U') IS NOT NULL
    DROP TABLE governance_control.REF_DATA_VERSION_LOG;
GO

CREATE TABLE governance_control.REF_DATA_VERSION_LOG (
    log_id              INT IDENTITY(1,1)   NOT NULL,
    registry_id         INT                 NOT NULL,
    version_number      NVARCHAR(20)        NOT NULL,
    change_type         NVARCHAR(20)        NOT NULL
                        CONSTRAINT chk_ref_change_type
                        CHECK (change_type IN ('ADD','MODIFY','DEPRECATE','DELETE')),
    change_description  NVARCHAR(500)       NOT NULL,
    changed_values      NVARCHAR(MAX)       NULL,
    requested_by        NVARCHAR(100)       NOT NULL,
    approved_by         NVARCHAR(100)       NULL,
    change_ticket       NVARCHAR(50)        NULL,
    applied_at          DATETIME2           NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_REF_VERSION_LOG PRIMARY KEY CLUSTERED (log_id),
    CONSTRAINT FK_REF_VERSION_REGISTRY FOREIGN KEY (registry_id)
        REFERENCES governance_control.REF_DATA_REGISTRY (registry_id)
);
GO

-- =============================================================================
-- SECTION 3: REFERENCE TABLES
-- Codes match the CHECK constraint values already in operaciones.* and flota.*
-- =============================================================================

-- 3.1 TIPO_INCIDENTE
-- Source: operaciones.INCIDENTE CHECK constraint has 6 values
-- These become the codes in this reference table
IF OBJECT_ID('ref.TIPO_INCIDENTE', 'U') IS NOT NULL DROP TABLE ref.TIPO_INCIDENTE;
GO
CREATE TABLE ref.TIPO_INCIDENTE (
    tipo_id                 TINYINT         NOT NULL,
    codigo                  NVARCHAR(20)    NOT NULL,
    nombre_display          NVARCHAR(100)   NOT NULL,
    descripcion             NVARCHAR(500)   NOT NULL,
    requiere_policia        BIT             NOT NULL DEFAULT 0,
    requiere_aseguradora    BIT             NOT NULL DEFAULT 0,
    sla_respuesta_horas     TINYINT         NOT NULL,
    es_activo               BIT             NOT NULL DEFAULT 1,
    CONSTRAINT PK_TIPO_INCIDENTE PRIMARY KEY CLUSTERED (tipo_id),
    CONSTRAINT UQ_TIPO_INCIDENTE_CODIGO UNIQUE (codigo)
);
GO
INSERT INTO ref.TIPO_INCIDENTE
    (tipo_id, codigo, nombre_display, descripcion,
     requiere_policia, requiere_aseguradora, sla_respuesta_horas)
VALUES
    (1,'ACCIDENTE',     'Accidente de tránsito',   'Colisión con otro vehículo o infraestructura',         1,1, 4),
    (2,'ROBO',          'Robo de carga',            'Sustracción total o parcial de la carga transportada', 1,1, 2),
    (3,'DEMORA',        'Demora injustificada',     'Retraso superior al 20% del tiempo estimado',          0,0,12),
    (4,'DANO_CARGA',    'Daño a la carga',          'Deterioro o daño de los bienes transportados',         0,1, 6),
    (5,'FALLA_MECANICA','Avería mecánica',          'Falla mecánica que detiene el vehículo en ruta',       0,0, 8),
    (6,'OTRO',          'Otro incidente',           'Incidente no clasificado en categorías anteriores',     0,0,24);
GO

-- 3.2 ESTADO_PEDIDO
-- Source: operaciones.PEDIDO CHECK constraint:
-- 'PENDIENTE','ASIGNADO','EN_RUTA','ENTREGADO','CANCELADO','INCIDENTE'
IF OBJECT_ID('ref.ESTADO_PEDIDO', 'U') IS NOT NULL DROP TABLE ref.ESTADO_PEDIDO;
GO
CREATE TABLE ref.ESTADO_PEDIDO (
    estado_id               TINYINT         NOT NULL,
    codigo                  NVARCHAR(20)    NOT NULL,
    nombre_display          NVARCHAR(80)    NOT NULL,
    descripcion             NVARCHAR(300)   NOT NULL,
    es_estado_final         BIT             NOT NULL DEFAULT 0,
    transiciones_validas    NVARCHAR(100)   NOT NULL,
    es_activo               BIT             NOT NULL DEFAULT 1,
    CONSTRAINT PK_ESTADO_PEDIDO PRIMARY KEY CLUSTERED (estado_id),
    CONSTRAINT UQ_ESTADO_PEDIDO_CODIGO UNIQUE (codigo)
);
GO
INSERT INTO ref.ESTADO_PEDIDO
    (estado_id, codigo, nombre_display, descripcion, es_estado_final, transiciones_validas)
VALUES
    (1,'PENDIENTE', 'Pendiente', 'Pedido registrado, sin conductor asignado',       0,'2,5'),
    (2,'ASIGNADO',  'Asignado',  'Conductor y vehículo confirmados',                0,'3,5'),
    (3,'EN_RUTA',   'En ruta',   'Vehículo en tránsito al destino',                 0,'4,6,5'),
    (4,'ENTREGADO', 'Entregado', 'Carga entregada y firmada por receptor',          1,''),
    (5,'CANCELADO', 'Cancelado', 'Pedido cancelado, no se realizará la entrega',    1,''),
    (6,'INCIDENTE', 'Incidente', 'Pedido detenido por incidente activo en ruta',    0,'3,4,5');
GO

-- 3.3 CATEGORIA_CLIENTE
-- Source: ventas.CLIENTE.categoria (DEFAULT 'ESTANDAR', free text today)
IF OBJECT_ID('ref.CATEGORIA_CLIENTE', 'U') IS NOT NULL DROP TABLE ref.CATEGORIA_CLIENTE;
GO
CREATE TABLE ref.CATEGORIA_CLIENTE (
    categoria_id        TINYINT         NOT NULL,
    codigo              NVARCHAR(30)    NOT NULL,
    nombre_display      NVARCHAR(80)    NOT NULL,
    volumen_min_pedidos INT             NOT NULL DEFAULT 0,
    descuento_base_pct  DECIMAL(5,2)   NOT NULL DEFAULT 0,
    sla_entrega_horas   INT             NOT NULL DEFAULT 72,
    es_activo           BIT             NOT NULL DEFAULT 1,
    CONSTRAINT PK_CATEGORIA_CLIENTE PRIMARY KEY CLUSTERED (categoria_id),
    CONSTRAINT UQ_CATEGORIA_CODIGO UNIQUE (codigo)
);
GO
INSERT INTO ref.CATEGORIA_CLIENTE
    (categoria_id, codigo, nombre_display, volumen_min_pedidos, descuento_base_pct, sla_entrega_horas)
VALUES
    (1,'ESTANDAR',   'Estándar',    0,   0.00,72),
    (2,'FRECUENTE',  'Frecuente',  20,   5.00,48),
    (3,'PREFERENTE', 'Preferente', 80,  10.00,36),
    (4,'CORPORATIVO','Corporativo',200, 15.00,24),
    (5,'ESTRATEGICO','Estratégico',500, 20.00,12);
GO

-- 3.4 TIPO_VEHICULO
-- Source: flota.VEHICULO.tipo_vehiculo (free text today)
IF OBJECT_ID('ref.TIPO_VEHICULO', 'U') IS NOT NULL DROP TABLE ref.TIPO_VEHICULO;
GO
CREATE TABLE ref.TIPO_VEHICULO (
    tipo_id             TINYINT         NOT NULL,
    codigo              NVARCHAR(20)    NOT NULL,
    nombre_display      NVARCHAR(100)   NOT NULL,
    capacidad_ton_max   DECIMAL(6,2)   NOT NULL,
    licencia_requerida  CHAR(3)         NOT NULL,
    es_activo           BIT             NOT NULL DEFAULT 1,
    CONSTRAINT PK_TIPO_VEHICULO PRIMARY KEY CLUSTERED (tipo_id),
    CONSTRAINT UQ_TIPO_VEHICULO_CODIGO UNIQUE (codigo)
);
GO
INSERT INTO ref.TIPO_VEHICULO
    (tipo_id, codigo, nombre_display, capacidad_ton_max, licencia_requerida)
VALUES
    (1,'MOTO',       'Motocicleta de carga',      0.10,'A2'),
    (2,'FURGONETA',  'Furgoneta',                 1.50,'B1'),
    (3,'CAMION_LVN', 'Camión liviano (< 5 ton)',  4.50,'C1'),
    (4,'CAMION_MED', 'Camión mediano (5-10 ton)', 9.50,'C2'),
    (5,'CAMION_PES', 'Camión pesado (> 10 ton)', 25.00,'C3'),
    (6,'TRACTOCAM',  'Tractocamión / trailer',   40.00,'C3');
GO

-- 3.5 ESTADO_ENTREGA
-- Source: operaciones.ENTREGA CHECK constraint:
-- 'PENDIENTE','EN_RUTA','ENTREGADO','FALLIDO','PARCIAL'
IF OBJECT_ID('ref.ESTADO_ENTREGA', 'U') IS NOT NULL DROP TABLE ref.ESTADO_ENTREGA;
GO
CREATE TABLE ref.ESTADO_ENTREGA (
    estado_id       TINYINT         NOT NULL,
    codigo          NVARCHAR(20)    NOT NULL,
    nombre_display  NVARCHAR(80)    NOT NULL,
    descripcion     NVARCHAR(300)   NOT NULL,
    es_estado_final BIT             NOT NULL DEFAULT 0,
    CONSTRAINT PK_ESTADO_ENTREGA PRIMARY KEY CLUSTERED (estado_id),
    CONSTRAINT UQ_ESTADO_ENTREGA_CODIGO UNIQUE (codigo)
);
GO
INSERT INTO ref.ESTADO_ENTREGA (estado_id, codigo, nombre_display, descripcion, es_estado_final)
VALUES
    (1,'PENDIENTE', 'Pendiente', 'Entrega programada, sin salida registrada',          0),
    (2,'EN_RUTA',   'En ruta',   'Vehículo en camino al punto de entrega',             0),
    (3,'ENTREGADO', 'Entregado', 'Entrega completada y firmada',                       1),
    (4,'FALLIDO',   'Fallido',   'Intento de entrega fallido, requiere reprogramación',0),
    (5,'PARCIAL',   'Parcial',   'Entrega parcial — parte de la carga no entregada',   0);
GO

-- =============================================================================
-- SECTION 4: POPULATE REGISTRY
-- =============================================================================

INSERT INTO governance_control.REF_DATA_REGISTRY
    (ref_table_name, ref_schema_name, domain_id, business_name, description,
     owner_domain, stability_class, change_process, approval_required,
     current_version, last_review_date, next_review_date, expected_row_count)
VALUES
    ('TIPO_INCIDENTE',    'ref', NULL,
     'Incident Types',
     'Formal catalog of incident categories. Codes mirror CHECK constraint in operaciones.INCIDENTE',
     'Operaciones','STABLE',
     'Submit via governance_control.DATA_CHANGE_REQUEST; Operations Director approves',
     1,'1.0', CAST(GETDATE() AS DATE), DATEADD(MONTH,6,CAST(GETDATE() AS DATE)), 6),

    ('ESTADO_PEDIDO',     'ref', NULL,
     'Order Status',
     'Finite state machine for order lifecycle. Codes mirror CHECK constraint in operaciones.PEDIDO',
     'Operaciones','STATIC',
     'Requires CTO approval — impacts SLA reporting and billing triggers',
     1,'1.0', CAST(GETDATE() AS DATE), DATEADD(MONTH,12,CAST(GETDATE() AS DATE)), 6),

    ('CATEGORIA_CLIENTE', 'ref', NULL,
     'Client Categories',
     'Client tier classification controlling pricing and SLA. Mirrors ventas.CLIENTE.categoria values',
     'Ventas','STABLE',
     'Commercial Director proposes; CFO approves; Data Steward implements',
     1,'1.0', CAST(GETDATE() AS DATE), DATEADD(MONTH,6,CAST(GETDATE() AS DATE)), 5),

    ('TIPO_VEHICULO',     'ref', NULL,
     'Vehicle Types',
     'Fleet classification by capacity and license. Mirrors flota.VEHICULO.tipo_vehiculo',
     'Flota','STATIC',
     'Fleet Manager requests; Operations Director approves',
     1,'1.0', CAST(GETDATE() AS DATE), DATEADD(MONTH,12,CAST(GETDATE() AS DATE)), 6),

    ('ESTADO_ENTREGA',    'ref', NULL,
     'Delivery Status',
     'Delivery lifecycle states. Codes mirror CHECK constraint in operaciones.ENTREGA',
     'Operaciones','STABLE',
     'Operations Director approves any change to delivery states',
     1,'1.0', CAST(GETDATE() AS DATE), DATEADD(MONTH,12,CAST(GETDATE() AS DATE)), 5);
GO

-- =============================================================================
-- SECTION 5: HEALTH VIEW
-- =============================================================================

CREATE OR ALTER VIEW governance_control.vw_ref_data_health
AS
    SELECT
        r.ref_schema_name + '.' + r.ref_table_name AS table_fullname,
        r.business_name,
        r.owner_domain,
        r.stability_class,
        r.current_version,
        r.last_review_date,
        r.next_review_date,
        CASE
            WHEN r.next_review_date < CAST(GETDATE() AS DATE) THEN 'OVERDUE'
            WHEN r.next_review_date <= DATEADD(DAY,30,CAST(GETDATE() AS DATE)) THEN 'DUE_SOON'
            ELSE 'OK'
        END AS review_status,
        r.is_active
    FROM governance_control.REF_DATA_REGISTRY r;
GO

-- =============================================================================
-- VERIFICATION
-- =============================================================================

SELECT 'governance_control.REF_DATA_REGISTRY' AS [table], COUNT(*) AS rows
FROM governance_control.REF_DATA_REGISTRY
UNION ALL
SELECT 'ref.TIPO_INCIDENTE',    COUNT(*) FROM ref.TIPO_INCIDENTE
UNION ALL
SELECT 'ref.ESTADO_PEDIDO',     COUNT(*) FROM ref.ESTADO_PEDIDO
UNION ALL
SELECT 'ref.CATEGORIA_CLIENTE', COUNT(*) FROM ref.CATEGORIA_CLIENTE
UNION ALL
SELECT 'ref.TIPO_VEHICULO',     COUNT(*) FROM ref.TIPO_VEHICULO
UNION ALL
SELECT 'ref.ESTADO_ENTREGA',    COUNT(*) FROM ref.ESTADO_ENTREGA;
GO

SELECT * FROM governance_control.vw_ref_data_health;
GO
