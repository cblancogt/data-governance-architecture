-- =============================================
-- TRANSTRACK | Week 02 | Part 13: Data Load
-- ASIGNACION_VEHICULO
-- One assignment per delivered/in-route pedido
-- =============================================

USE TRANSTRACK;
GO

INSERT INTO flota.ASIGNACION_VEHICULO (
    vehiculo_id, conductor_id, pedido_id,
    fecha_inicio, fecha_fin,
    km_inicio, km_fin
)
SELECT TOP 400000
    -- vehiculo_id: 1 to 800
    ABS(CHECKSUM(NEWID())) % 800 + 1,

    -- conductor_id: 1 to 1200
    ABS(CHECKSUM(NEWID())) % 1200 + 1,

    p.pedido_id,

    DATEADD(HOUR, 6, p.fecha_pedido),

    CASE
        WHEN p.estado IN ('ENTREGADO','CANCELADO')
            THEN DATEADD(
                    HOUR,
                    10 + ABS(CHECKSUM(NEWID())) % 62,
                    p.fecha_pedido
                 )
        ELSE NULL
    END,

    ROUND(10000 + (ABS(CHECKSUM(NEWID())) % 490000), 2),

    CASE
        WHEN p.estado IN ('ENTREGADO','CANCELADO')
            THEN ROUND(
                    10000 + (ABS(CHECKSUM(NEWID())) % 490000) + 
                    (50 + ABS(CHECKSUM(NEWID())) % 450),
                 2)
        ELSE NULL
    END

FROM operaciones.PEDIDO p
WHERE p.estado IN ('ENTREGADO','EN_RUTA','ASIGNADO')
ORDER BY p.fecha_pedido;
GO

-- -----------------------------------------------
-- Verify
-- -----------------------------------------------
SELECT 'ASIGNACION_VEHICULO' AS tabla, COUNT(*) AS registros 
FROM flota.ASIGNACION_VEHICULO;
GO