-- =============================================
-- TRANSTRACK | Week 02 | Part 10: Data Load
-- CONTRATO_CLIENTE (12,000) + PEDIDO (500,000)
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- CONTRATO_CLIENTE — 12,000 records
-- One contract per active client (not all clients)
-- -----------------------------------------------
DECLARE @ct INT = 1;

WHILE @ct <= 12000
BEGIN
    INSERT INTO ventas.CONTRATO_CLIENTE (
        cliente_id, numero_contrato,
        fecha_inicio, fecha_fin,
        tarifa_base, tipo_servicio, activo
    )
    VALUES (
        -- References valid cliente_id from ventas.CLIENTE
        @ct,

        'CON-' + RIGHT('000000' + CAST(@ct AS VARCHAR), 6),

        DATEADD(DAY, -(@ct % 1825), GETDATE()),

        CASE
            WHEN @ct % 10 = 0 THEN NULL  -- open ended contract
            ELSE DATEADD(DAY, 365 + (@ct % 730), 
                 DATEADD(DAY, -(@ct % 1825), GETDATE()))
        END,

        ROUND(500 + (@ct % 20 * 250), 2),

        CASE @ct % 5
            WHEN 0 THEN 'CARGA_GENERAL'
            WHEN 1 THEN 'CARGA_REFRIGERADA'
            WHEN 2 THEN 'CARGA_PELIGROSA'
            WHEN 3 THEN 'CARGA_SOBREDIMENSIONADA'
            ELSE 'MENSAJERIA'
        END,

        CASE WHEN @ct % 15 = 0 THEN 0 ELSE 1 END
    );

    SET @ct = @ct + 1;
END
GO

-- -----------------------------------------------
-- PEDIDO — 500,000 records
-- Date range: Jan 2019 to present
-- Uses batch insert for performance
-- -----------------------------------------------
DECLARE @batch INT = 1;
DECLARE @batchSize INT = 10000;
DECLARE @total INT = 500000;

WHILE (@batch - 1) * @batchSize < @total
BEGIN

    ;WITH N AS
    (
        SELECT TOP (@batchSize)
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
        FROM master..spt_values a
        CROSS JOIN master..spt_values b
    )
   INSERT INTO operaciones.PEDIDO (
    numero_pedido, cliente_id, ruta_id,
    fecha_pedido, fecha_requerida,
    peso_kg, volumen_m3, tipo_carga,
    estado, valor_declarado, observaciones
)
SELECT
    'PED-' + RIGHT('000000000' + CAST(
        (@batch - 1) * @batchSize + ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    AS VARCHAR), 9),

    -- cliente_id between 1 and 15000
    ABS(CHECKSUM(NEWID())) % 15000 + 1,

    -- ruta_id between 1 and 2388
    ABS(CHECKSUM(NEWID())) % 2388 + 1,

    DATEADD(
        DAY,
        ABS(CHECKSUM(NEWID())) % DATEDIFF(DAY, '2019-01-01', GETDATE()),
        '2019-01-01'
    ),

    DATEADD(
        DAY,
        1 + ABS(CHECKSUM(NEWID())) % 15,
        DATEADD(
            DAY,
            ABS(CHECKSUM(NEWID())) % DATEDIFF(DAY, '2019-01-01', GETDATE()),
            '2019-01-01'
        )
    ),

    ROUND(100 + (ABS(CHECKSUM(NEWID())) % 29900), 2),

    CASE WHEN ABS(CHECKSUM(NEWID())) % 5 = 0
        THEN NULL
        ELSE ROUND(1 + (ABS(CHECKSUM(NEWID())) % 80), 2)
    END,

    CASE ABS(CHECKSUM(NEWID())) % 5
        WHEN 0 THEN 'CARGA_GENERAL'
        WHEN 1 THEN 'CARGA_REFRIGERADA'
        WHEN 2 THEN 'CARGA_PELIGROSA'
        WHEN 3 THEN 'CARGA_SOBREDIMENSIONADA'
        ELSE 'MENSAJERIA'
    END,

    CASE ABS(CHECKSUM(NEWID())) % 5
        WHEN 0 THEN 'PENDIENTE'
        WHEN 1 THEN 'ASIGNADO'
        WHEN 2 THEN 'EN_RUTA'
        WHEN 3 THEN 'ENTREGADO'
        ELSE 'CANCELADO'
    END,

    ROUND(1000 + (ABS(CHECKSUM(NEWID())) % 99000), 2),

    CASE WHEN ABS(CHECKSUM(NEWID())) % 4 = 0
        THEN 'Observacion pedido batch ' + CAST(@batch AS VARCHAR)
        ELSE NULL
    END

    FROM N;

    PRINT 'Batch ' + CAST(@batch AS VARCHAR) + ' cargado';

    SET @batch += 1;

END;

-- -----------------------------------------------
-- Verify
-- -----------------------------------------------
SELECT 'CONTRATO_CLIENTE' AS tabla, COUNT(*) AS registros 
    FROM ventas.CONTRATO_CLIENTE
UNION ALL
SELECT 'PEDIDO', COUNT(*) FROM operaciones.PEDIDO;
GO