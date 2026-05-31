-- =============================================
-- TRANSTRACK | Week 02 | Part 6: Base Indexes
-- Only what's needed for bulk insert performance
-- Not optimized — that's Week 03 diagnostic work
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- ventas.CLIENTE
-- -----------------------------------------------
CREATE NONCLUSTERED INDEX IX_ventas_CLIENTE_nit
    ON ventas.CLIENTE (nit)
    ON [PRIMARY];

CREATE NONCLUSTERED INDEX IX_ventas_CLIENTE_ciudad
    ON ventas.CLIENTE (ciudad)
    ON [PRIMARY];
GO

-- -----------------------------------------------
-- facturacion.CLIENTE
-- -----------------------------------------------
CREATE NONCLUSTERED INDEX IX_fact_CLIENTE_nit
    ON facturacion.CLIENTE (nit_cliente)
    ON [PRIMARY];
GO

-- -----------------------------------------------
-- operaciones.PEDIDO
-- -----------------------------------------------
CREATE NONCLUSTERED INDEX IX_PEDIDO_cliente
    ON operaciones.PEDIDO (cliente_id)
    ON [PRIMARY];

CREATE NONCLUSTERED INDEX IX_PEDIDO_fecha
    ON operaciones.PEDIDO (fecha_pedido)
    ON [PRIMARY];

CREATE NONCLUSTERED INDEX IX_PEDIDO_estado
    ON operaciones.PEDIDO (estado)
    ON [PRIMARY];
GO

-- -----------------------------------------------
-- operaciones.ENTREGA
-- -----------------------------------------------
CREATE NONCLUSTERED INDEX IX_ENTREGA_pedido
    ON operaciones.ENTREGA (pedido_id)
    ON [PRIMARY];
GO

-- -----------------------------------------------
-- operaciones.INCIDENTE
-- -----------------------------------------------
CREATE NONCLUSTERED INDEX IX_INCIDENTE_pedido
    ON operaciones.INCIDENTE (pedido_id)
    ON [PRIMARY];

CREATE NONCLUSTERED INDEX IX_INCIDENTE_fecha
    ON operaciones.INCIDENTE (fecha_incidente)
    ON [PRIMARY];
GO

-- -----------------------------------------------
-- facturacion.FACTURA
-- -----------------------------------------------
CREATE NONCLUSTERED INDEX IX_FACTURA_pedido
    ON facturacion.FACTURA (pedido_id)
    ON [PRIMARY];

CREATE NONCLUSTERED INDEX IX_FACTURA_cliente
    ON facturacion.FACTURA (cliente_fact_id)
    ON [PRIMARY];

CREATE NONCLUSTERED INDEX IX_FACTURA_estado
    ON facturacion.FACTURA (estado_pago)
    ON [PRIMARY];
GO

-- -----------------------------------------------
-- flota.TELEMETRIA_GPS
-- Critical: date filter will be the main access pattern
-- -----------------------------------------------
CREATE NONCLUSTERED INDEX IX_TELEMETRIA_vehiculo_fecha
    ON flota.TELEMETRIA_GPS (vehiculo_id, fecha_hora)
    ON [ARCHIVE];
GO

-- -----------------------------------------------
-- flota.CONDUCTOR
-- -----------------------------------------------
CREATE NONCLUSTERED INDEX IX_CONDUCTOR_licencia
    ON flota.CONDUCTOR (numero_licencia)
    ON [PRIMARY];
GO

-- -----------------------------------------------
-- flota.ASIGNACION_VEHICULO
-- -----------------------------------------------
CREATE NONCLUSTERED INDEX IX_ASIGNACION_vehiculo
    ON flota.ASIGNACION_VEHICULO (vehiculo_id)
    ON [PRIMARY];

CREATE NONCLUSTERED INDEX IX_ASIGNACION_conductor
    ON flota.ASIGNACION_VEHICULO (conductor_id)
    ON [PRIMARY];
GO