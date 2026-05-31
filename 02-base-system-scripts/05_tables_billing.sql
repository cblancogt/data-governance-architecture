-- =============================================
-- TRANSTRACK | Week 02 | Part 5: Tables
-- Domain: Billing
-- Intentional problems:
--   - FACTURA without pedido_id (orphan invoices)
--   - Duplicate invoices (same pedido, two records)
--   - No FK to ventas.CLIENTE, references facturacion.CLIENTE
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- FACTURA
-- -----------------------------------------------
CREATE TABLE facturacion.FACTURA (
    factura_id        INT IDENTITY(1,1)     NOT NULL,
    numero_factura    VARCHAR(30)           NOT NULL,
    cliente_fact_id   INT                   NULL,  -- FK to facturacion.CLIENTE
    pedido_id         INT                   NULL,  -- intentional: nullable, orphan invoices
    fecha_emision     DATETIME2             NOT NULL DEFAULT GETDATE(),
    fecha_vencimiento DATE                  NOT NULL,
    subtotal          DECIMAL(12,2)         NOT NULL,
    impuesto          DECIMAL(12,2)         NOT NULL DEFAULT 0,
    total             DECIMAL(12,2)         NOT NULL,
    estado_pago       VARCHAR(20)           NOT NULL DEFAULT 'PENDIENTE',
    metodo_pago       VARCHAR(30)           NULL,
    fecha_pago        DATETIME2             NULL,
    observaciones     VARCHAR(500)          NULL,
    -- Intentional: no UNIQUE on numero_factura (allows duplicates)
    -- Intentional: no UNIQUE on pedido_id (same pedido can have 2 invoices)
    CONSTRAINT PK_FACTURA PRIMARY KEY CLUSTERED (factura_id)
        ON [PRIMARY],
    CONSTRAINT FK_FACTURA_CLIENTE
        FOREIGN KEY (cliente_fact_id) REFERENCES facturacion.CLIENTE(cliente_fact_id),
    CONSTRAINT FK_FACTURA_PEDIDO
        FOREIGN KEY (pedido_id) REFERENCES operaciones.PEDIDO(pedido_id),
    CONSTRAINT CHK_FACTURA_ESTADO CHECK (estado_pago IN (
        'PENDIENTE','PAGADA','VENCIDA','ANULADA','PARCIAL'
    ))
);
GO

-- -----------------------------------------------
-- DETALLE_FACTURA
-- -----------------------------------------------
CREATE TABLE facturacion.DETALLE_FACTURA (
    detalle_id        INT IDENTITY(1,1)     NOT NULL,
    factura_id        INT                   NOT NULL,
    concepto          VARCHAR(200)          NOT NULL,
    cantidad          DECIMAL(8,2)          NOT NULL DEFAULT 1,
    precio_unitario   DECIMAL(10,2)         NOT NULL,
    descuento         DECIMAL(5,2)          NOT NULL DEFAULT 0,
    subtotal          DECIMAL(12,2)         NOT NULL,
    CONSTRAINT PK_DETALLE_FACTURA PRIMARY KEY CLUSTERED (detalle_id)
        ON [PRIMARY],
    CONSTRAINT FK_DETALLE_FACTURA
        FOREIGN KEY (factura_id) REFERENCES facturacion.FACTURA(factura_id)
);
GO