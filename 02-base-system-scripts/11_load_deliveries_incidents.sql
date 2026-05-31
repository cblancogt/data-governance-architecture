-- =============================================
-- TRANSTRACK | Week 02 | Part 11: Data Load
-- ENTREGA (480,000) + INCIDENTE (8,500)
-- Intentional problems:
--   - Some PEDIDO without ENTREGA
--   - Some INCIDENTE without PEDIDO (orphan)
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- ENTREGA — 480,000 records
-- Not all pedidos have entrega (intentional)
-- Uses top 480,000 pedido_ids ordered by date
-- -----------------------------------------------
INSERT INTO operaciones.ENTREGA (
    pedido_id,
    fecha_salida,
    fecha_entrega_real,
    fecha_entrega_est,
    estado_entrega,
    firma_receptor,
    observaciones,
    tiempo_demora_min
)
SELECT TOP 480000
    p.pedido_id,

    -- fecha_salida: 1-3 days after pedido
    DATEADD(DAY, 1 + ABS(CHECKSUM(NEWID())) % 3, p.fecha_pedido),

    -- fecha_entrega_real: nullable for pending/in route
    CASE
        WHEN p.estado IN ('ENTREGADO')
            THEN DATEADD(
                    HOUR,
                    ABS(CHECKSUM(NEWID())) % 72,
                    DATEADD(DAY, 1 + ABS(CHECKSUM(NEWID())) % 3, p.fecha_pedido)
                 )
        WHEN p.estado IN ('FALLIDO','PARCIAL')
            THEN DATEADD(
                    HOUR,
                    ABS(CHECKSUM(NEWID())) % 96,
                    DATEADD(DAY, 1 + ABS(CHECKSUM(NEWID())) % 3, p.fecha_pedido)
                 )
        ELSE NULL
    END,

    -- fecha_entrega_est: based on route estimated time
    DATEADD(
        HOUR,
        CAST(r.tiempo_estimado_h * 1.2 AS INT),
        DATEADD(DAY, 1, p.fecha_pedido)
    ),

    CASE p.estado
        WHEN 'ENTREGADO'  THEN 'ENTREGADO'
        WHEN 'CANCELADO'  THEN 'FALLIDO'
        WHEN 'EN_RUTA'    THEN 'EN_RUTA'
        WHEN 'PENDIENTE'  THEN 'PENDIENTE'
        ELSE 'PARCIAL'
    END,

    -- firma_receptor: only for delivered
    CASE
        WHEN p.estado = 'ENTREGADO'
            THEN 'Receptor-' + CAST(p.pedido_id AS VARCHAR)
        ELSE NULL
    END,

    CASE
        WHEN ABS(CHECKSUM(NEWID())) % 5 = 0
            THEN 'Entrega con observacion en pedido ' + CAST(p.pedido_id AS VARCHAR)
        ELSE NULL
    END,

    -- tiempo_demora_min: negative means early, positive means late
    CASE
        WHEN p.estado = 'ENTREGADO'
            THEN (ABS(CHECKSUM(NEWID())) % 241) - 60
        ELSE NULL
    END

FROM operaciones.PEDIDO p
INNER JOIN operaciones.RUTA r ON p.ruta_id = r.ruta_id
ORDER BY p.fecha_pedido;
GO

-- -----------------------------------------------
-- INCIDENTE — 8,500 records
-- ~7,500 linked to a pedido
-- ~1,000 orphan (no pedido_id) — intentional
-- -----------------------------------------------
DECLARE @inc INT = 1;

WHILE @inc <= 8500
BEGIN
    INSERT INTO operaciones.INCIDENTE (
        pedido_id,
        fecha_incidente,
        tipo_incidente,
        descripcion,
        severidad,
        estado_resolucion,
        costo_estimado,
        fecha_resolucion
    )
    VALUES (
        -- Intentional: every 8th record is orphan (no pedido)
        CASE
            WHEN @inc % 8 = 0 THEN NULL
            ELSE ABS(CHECKSUM(NEWID())) % 500000 + 1
        END,

        DATEADD(
            DAY,
            -(ABS(CHECKSUM(NEWID())) % 2190),
            GETDATE()
        ),

        CASE @inc % 6
            WHEN 0 THEN 'ACCIDENTE'
            WHEN 1 THEN 'ROBO'
            WHEN 2 THEN 'DEMORA'
            WHEN 3 THEN 'DANO_CARGA'
            WHEN 4 THEN 'FALLA_MECANICA'
            ELSE 'OTRO'
        END,

        'Incident description for record ' + CAST(@inc AS VARCHAR)
            + '. Type: ' +
            CASE @inc % 6
                WHEN 0 THEN 'Vehicle accident on route'
                WHEN 1 THEN 'Cargo theft reported'
                WHEN 2 THEN 'Delivery delay due to road conditions'
                WHEN 3 THEN 'Cargo damage during transport'
                WHEN 4 THEN 'Mechanical failure reported'
                ELSE 'Other incident type'
            END,

        CASE @inc % 4
            WHEN 0 THEN 'BAJA'
            WHEN 1 THEN 'MEDIA'
            WHEN 2 THEN 'ALTA'
            ELSE 'CRITICA'
        END,

        CASE @inc % 3
            WHEN 0 THEN 'ABIERTO'
            WHEN 1 THEN 'EN_PROCESO'
            ELSE 'CERRADO'
        END,

        CASE
            WHEN @inc % 4 IN (2,3)
                THEN ROUND(500 + (ABS(CHECKSUM(NEWID())) % 49500), 2)
            ELSE NULL
        END,

        CASE
            WHEN @inc % 3 = 2
                THEN DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 30,
                     DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 2190), GETDATE()))
            ELSE NULL
        END
    );

    SET @inc = @inc + 1;
END
GO

-- -----------------------------------------------
-- Verify
-- -----------------------------------------------
SELECT 'ENTREGA'   AS tabla, COUNT(*) AS registros FROM operaciones.ENTREGA
UNION ALL
SELECT 'INCIDENTE', COUNT(*) FROM operaciones.INCIDENTE;
GO