-- =============================================
-- TRANSTRACK | Week 02 | Part 2: Tables
-- Domain: Customers (ventas + facturacion)
-- Intentional problems: duplicated clients by NIT
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- CLIENTE (ventas schema — sales module)
-- -----------------------------------------------
CREATE TABLE ventas.CLIENTE (
    cliente_id        INT IDENTITY(1,1)     NOT NULL,
    nit               VARCHAR(20)           NOT NULL,
    nombre            VARCHAR(150)          NOT NULL,
    email             VARCHAR(100)          NULL,
    telefono          VARCHAR(20)           NULL,
    direccion         VARCHAR(250)          NULL,
    ciudad            VARCHAR(80)           NULL,
    categoria         VARCHAR(30)           NOT NULL DEFAULT 'ESTANDAR',
    fecha_registro    DATETIME2             NOT NULL DEFAULT GETDATE(),
    activo            BIT                   NOT NULL DEFAULT 1,
    CONSTRAINT PK_ventas_CLIENTE PRIMARY KEY CLUSTERED (cliente_id)
        ON [PRIMARY]
);
GO

-- -----------------------------------------------
-- CLIENTE (facturacion schema — billing module)
-- Intentional: same entity, different structure
-- Different columns, no foreign key to ventas
-- -----------------------------------------------
CREATE TABLE facturacion.CLIENTE (
    cliente_fact_id   INT IDENTITY(1,1)     NOT NULL,
    nit_cliente       VARCHAR(20)           NOT NULL,  -- different column name
    razon_social      VARCHAR(200)          NOT NULL,  -- different column name
    correo            VARCHAR(100)          NULL,      -- different column name
    telefono_contacto VARCHAR(20)           NULL,
    direccion_fiscal  VARCHAR(300)          NULL,
    limite_credito    DECIMAL(12,2)         NULL,
    dias_credito      INT                   NULL DEFAULT 30,
    fecha_alta        DATETIME2             NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_facturacion_CLIENTE PRIMARY KEY CLUSTERED (cliente_fact_id)
        ON [PRIMARY]
);
GO

-- -----------------------------------------------
-- CONTRATO_CLIENTE
-- -----------------------------------------------
CREATE TABLE ventas.CONTRATO_CLIENTE (
    contrato_id       INT IDENTITY(1,1)     NOT NULL,
    cliente_id        INT                   NOT NULL,
    numero_contrato   VARCHAR(30)           NOT NULL,
    fecha_inicio      DATE                  NOT NULL,
    fecha_fin         DATE                  NULL,
    tarifa_base       DECIMAL(10,2)         NOT NULL,
    tipo_servicio     VARCHAR(50)           NOT NULL,
    activo            BIT                   NOT NULL DEFAULT 1,
    CONSTRAINT PK_CONTRATO_CLIENTE PRIMARY KEY CLUSTERED (contrato_id)
        ON [PRIMARY],
    CONSTRAINT FK_CONTRATO_CLIENTE 
        FOREIGN KEY (cliente_id) REFERENCES ventas.CLIENTE(cliente_id)
);
GO