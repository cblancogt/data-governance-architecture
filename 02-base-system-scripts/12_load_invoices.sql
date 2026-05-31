-- =============================================
-- TRANSTRACK | Week 02 | Part 12: Data Load
-- FACTURA (490,000) + DETALLE_FACTURA
-- Intentional problems:
--   - ~5,000 invoices without pedido (orphan)
--   - ~3,000 duplicate invoices (same pedido, 2 records)
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- FACTURA — 490,000 records
-- Block 1: 480,000 linked to pedidos (one per pedido)
-- Block 2: 5,000 orphan (no pedido_id)
-- Block 3: 5,000 duplicates (reuses pedido_ids 1-5000)
-- -----------------------------------------------

-- Block 1: normal invoices linked to pedido
INSERT INTO facturacion.FACTURA (
    numero_factura, cliente_fact_id, pedido_id,
    fecha_emision, fecha_vencimiento,
    subtotal, impuesto, total,
    estado_pago, metodo_pago, fecha_pago
)
SELECT TOP 480000
    'FAC-' + RIGHT('000000000' + CAST(p.pedido_id AS VARCHAR), 9),

    -- cliente_fact_id: map roughly to facturacion.CLIENTE
    ABS(CHECKSUM(NEWID())) % 12000 + 1,

    p.pedido_id,

    DATEADD(DAY, 1, p.fecha_pedido),

    DATEADD(DAY, 30 + (ABS(CHECKSUM(NEWID())) % 60), p.fecha_pedido),

    ROUND(p.valor_declarado * 0.85, 2),
    ROUND(p.valor_declarado * 0.85 * 0.12, 2),
    ROUND(p.valor_declarado * 0.85 * 1.12, 2),

    CASE p.estado
        WHEN 'ENTREGADO' THEN
            CASE ABS(CHECKSUM(NEWID())) % 3
                WHEN 0 THEN 'PAGADA'
                WHEN 1 THEN 'PENDIENTE'
                ELSE 'VENCIDA'
            END
        WHEN 'CANCELADO' THEN 'ANULADA'
        ELSE 'PENDIENTE'
    END,

    CASE ABS(CHECKSUM(NEWID())) % 4
        WHEN 0 THEN 'TRANSFERENCIA'
        WHEN 1 THEN 'CHEQUE'
        WHEN 2 THEN 'EFECTIVO'
        ELSE NULL
    END,

    CASE
        WHEN p.estado = 'ENTREGADO' AND ABS(CHECKSUM(NEWID())) % 2 = 0
            THEN DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 45, p.fecha_pedido)
        ELSE NULL
    END

FROM operaciones.PEDIDO p
ORDER BY p.fecha_pedido;
GO

-- Block 2: orphan invoices — no pedido_id (intentional)
DECLARE @oi INT = 1;

WHILE @oi <= 5000
BEGIN
    INSERT INTO facturacion.FACTURA (
        numero_factura, cliente_fact_id, pedido_id,
        fecha_emision, fecha_vencimiento,
        subtotal, impuesto, total,
        estado_pago, metodo_pago
    )
    VALUES (
        'FAC-ORPHAN-' + RIGHT('00000' + CAST(@oi AS VARCHAR), 5),
        ABS(CHECKSUM(NEWID())) % 12000 + 1,
        NULL,  -- intentional: no pedido
        DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1825), GETDATE()),
        DATEADD(DAY, 30, DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1825), GETDATE())),
        ROUND(500 + (ABS(CHECKSUM(NEWID())) % 49500), 2),
        ROUND((500 + (ABS(CHECKSUM(NEWID())) % 49500)) * 0.12, 2),
        ROUND((500 + (ABS(CHECKSUM(NEWID())) % 49500)) * 1.12, 2),
        CASE @oi % 3
            WHEN 0 THEN 'PAGADA'
            WHEN 1 THEN 'PENDIENTE'
            ELSE 'VENCIDA'
        END,
        CASE @oi % 3
            WHEN 0 THEN 'TRANSFERENCIA'
            WHEN 1 THEN 'CHEQUE'
            ELSE 'EFECTIVO'
        END
    );
    SET @oi = @oi + 1;
END
GO

-- Block 3: duplicate invoices — same pedido, second record (intentional)
DECLARE @di INT = 1;

WHILE @di <= 5000
BEGIN
    INSERT INTO facturacion.FACTURA (
        numero_factura, cliente_fact_id, pedido_id,
        fecha_emision, fecha_vencimiento,
        subtotal, impuesto, total,
        estado_pago, observaciones
    )
    VALUES (
        -- Different invoice number, same pedido_id
        'FAC-DUP-' + RIGHT('00000' + CAST(@di AS VARCHAR), 5),
        ABS(CHECKSUM(NEWID())) % 12000 + 1,
        @di,  -- reuses pedido_id 1 to 5000
        DATEADD(DAY, 2, GETDATE()),
        DATEADD(DAY, 32, GETDATE()),
        ROUND(1000 + (@di % 50 * 500), 2),
        ROUND((1000 + (@di % 50 * 500)) * 0.12, 2),
        ROUND((1000 + (@di % 50 * 500)) * 1.12, 2),
        'PENDIENTE',
        'DUPLICATE - second invoice for pedido ' + CAST(@di AS VARCHAR)
    );
    SET @di = @di + 1;
END
GO

-- -----------------------------------------------
-- DETALLE_FACTURA — one detail per invoice
-- -----------------------------------------------
INSERT INTO facturacion.DETALLE_FACTURA (
    factura_id, concepto, cantidad,
    precio_unitario, descuento, subtotal
)
SELECT
    f.factura_id,
    CASE f.factura_id % 5
        WHEN 0 THEN 'Servicio de transporte de carga general'
        WHEN 1 THEN 'Flete terrestre nacional'
        WHEN 2 THEN 'Transporte carga refrigerada'
        WHEN 3 THEN 'Servicio logistico especial'
        ELSE 'Flete y manejo de mercaderia'
    END,
    1,
    f.subtotal,
    CASE WHEN f.factura_id % 10 = 0 THEN 5.00 ELSE 0.00 END,
    f.subtotal
FROM facturacion.FACTURA f;
GO

-- -----------------------------------------------
-- Verify
-- -----------------------------------------------
SELECT 'FACTURA'         AS tabla, COUNT(*) AS registros FROM facturacion.FACTURA
UNION ALL
SELECT 'DETALLE_FACTURA', COUNT(*) FROM facturacion.DETALLE_FACTURA
UNION ALL
SELECT 'Orphan invoices (no pedido)',
       COUNT(*) FROM facturacion.FACTURA WHERE pedido_id IS NULL
UNION ALL
SELECT 'Duplicate invoices',
       COUNT(*) FROM facturacion.FACTURA 
       WHERE numero_factura LIKE 'FAC-DUP-%';
GO