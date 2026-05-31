-- =============================================
-- TRANSTRACK | Week 02 | Part 3: Tables
-- Domain: Operations
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- RUTA
-- -----------------------------------------------
CREATE TABLE operaciones.RUTA (
    ruta_id           INT IDENTITY(1,1)     NOT NULL,
    codigo_ruta       VARCHAR(20)           NOT NULL,
    ciudad_origen     VARCHAR(80)           NOT NULL,
    ciudad_destino    VARCHAR(80)           NOT NULL,
    distancia_km      DECIMAL(8,2)          NOT NULL,
    tiempo_estimado_h DECIMAL(5,2)          NOT NULL,
    tipo_via          VARCHAR(30)           NOT NULL DEFAULT 'TERRESTRE',
    activa            BIT                   NOT NULL DEFAULT 1,
    CONSTRAINT PK_RUTA PRIMARY KEY CLUSTERED (ruta_id)
        ON [PRIMARY],
    CONSTRAINT UQ_RUTA_CODIGO UNIQUE (codigo_ruta)
);
GO

-- -----------------------------------------------
-- PEDIDO
-- -----------------------------------------------
CREATE TABLE operaciones.PEDIDO (
    pedido_id         INT IDENTITY(1,1)     NOT NULL,
    numero_pedido     VARCHAR(30)           NOT NULL,
    cliente_id        INT                   NOT NULL,
    ruta_id           INT                   NOT NULL,
    fecha_pedido      DATETIME2             NOT NULL,
    fecha_requerida   DATE                  NOT NULL,
    peso_kg           DECIMAL(10,2)         NOT NULL,
    volumen_m3        DECIMAL(8,2)          NULL,
    tipo_carga        VARCHAR(50)           NOT NULL,
    estado            VARCHAR(30)           NOT NULL DEFAULT 'PENDIENTE',
    valor_declarado   DECIMAL(12,2)         NULL,
    observaciones     VARCHAR(500)          NULL,
    CONSTRAINT PK_PEDIDO PRIMARY KEY CLUSTERED (pedido_id)
        ON [PRIMARY],
    CONSTRAINT UQ_PEDIDO_NUMERO UNIQUE (numero_pedido),
    CONSTRAINT FK_PEDIDO_CLIENTE 
        FOREIGN KEY (cliente_id) REFERENCES ventas.CLIENTE(cliente_id),
    CONSTRAINT FK_PEDIDO_RUTA 
        FOREIGN KEY (ruta_id) REFERENCES operaciones.RUTA(ruta_id),
    CONSTRAINT CHK_PEDIDO_ESTADO CHECK (estado IN (
        'PENDIENTE','ASIGNADO','EN_RUTA','ENTREGADO','CANCELADO','INCIDENTE'
    ))
);
GO

-- -----------------------------------------------
-- ENTREGA
-- -----------------------------------------------
CREATE TABLE operaciones.ENTREGA (
    entrega_id            INT IDENTITY(1,1) NOT NULL,
    pedido_id             INT               NOT NULL,
    fecha_salida          DATETIME2         NULL,
    fecha_entrega_real    DATETIME2         NULL,
    fecha_entrega_est     DATETIME2         NOT NULL,
    estado_entrega        VARCHAR(30)       NOT NULL DEFAULT 'PENDIENTE',
    firma_receptor        VARCHAR(150)      NULL,
    observaciones         VARCHAR(500)      NULL,
    tiempo_demora_min     INT               NULL,
    CONSTRAINT PK_ENTREGA PRIMARY KEY CLUSTERED (entrega_id)
        ON [PRIMARY],
    CONSTRAINT FK_ENTREGA_PEDIDO 
        FOREIGN KEY (pedido_id) REFERENCES operaciones.PEDIDO(pedido_id),
    CONSTRAINT CHK_ENTREGA_ESTADO CHECK (estado_entrega IN (
        'PENDIENTE','EN_RUTA','ENTREGADO','FALLIDO','PARCIAL'
    ))
);
GO

-- -----------------------------------------------
-- INCIDENTE
-- -----------------------------------------------
CREATE TABLE operaciones.INCIDENTE (
    incidente_id      INT IDENTITY(1,1)     NOT NULL,
    pedido_id         INT                   NULL,  -- intentional: some without pedido
    fecha_incidente   DATETIME2             NOT NULL,
    tipo_incidente    VARCHAR(50)           NOT NULL,
    descripcion       VARCHAR(1000)         NOT NULL,
    severidad         VARCHAR(20)           NOT NULL DEFAULT 'MEDIA',
    estado_resolucion VARCHAR(30)           NOT NULL DEFAULT 'ABIERTO',
    costo_estimado    DECIMAL(12,2)         NULL,
    fecha_resolucion  DATETIME2             NULL,
    CONSTRAINT PK_INCIDENTE PRIMARY KEY CLUSTERED (incidente_id)
        ON [PRIMARY],
    CONSTRAINT FK_INCIDENTE_PEDIDO 
        FOREIGN KEY (pedido_id) REFERENCES operaciones.PEDIDO(pedido_id),
    CONSTRAINT CHK_INCIDENTE_TIPO CHECK (tipo_incidente IN (
        'ACCIDENTE','ROBO','DEMORA','DANO_CARGA','FALLA_MECANICA','OTRO'
    )),
    CONSTRAINT CHK_INCIDENTE_SEVERIDAD CHECK (severidad IN (
        'BAJA','MEDIA','ALTA','CRITICA'
    ))
);
GO