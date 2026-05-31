-- =============================================
-- TRANSTRACK | Week 02 | Part 14: Data Load
-- TELEMETRIA_GPS — 15,000,000 records
-- No partition, no FK to PEDIDO or CONDUCTOR
-- Intentional: raw state, no governance applied
-- Batch: 50,000 per iteration
-- =============================================

USE TRANSTRACK;
GO

DECLARE @batchSize INT = 50000;
DECLARE @total     INT = 15000000;
DECLARE @inserted  INT = 0;

WHILE @inserted < @total
BEGIN
    INSERT INTO flota.TELEMETRIA_GPS (
        vehiculo_id, fecha_hora,
        latitud, longitud,
        velocidad_kmh, rumbo,
        altitud_m, evento
    )
    SELECT TOP (@batchSize)
        ABS(CHECKSUM(NEWID())) % 800 + 1,
        DATEADD(MINUTE,(ABS(CHECKSUM(NEWID())) % 525600) * 5,'2021-01-01'),
        ROUND(13.7 + (ABS(CHECKSUM(NEWID())) % 40000) * 0.0001, 7),
        ROUND(-92.2 + (ABS(CHECKSUM(NEWID())) % 40000) * 0.0001, 7),
        ROUND(ABS(CHECKSUM(NEWID())) % 120, 2),
        ROUND(ABS(CHECKSUM(NEWID())) % 360, 2),
        ROUND(ABS(CHECKSUM(NEWID())) % 3000, 2),
        CASE ABS(CHECKSUM(NEWID())) % 10
            WHEN 0 THEN 'PARADA'
            WHEN 1 THEN 'EXCESO_VELOCIDAD'
            WHEN 2 THEN 'MOTOR_APAGADO'
            WHEN 3 THEN 'MOTOR_ENCENDIDO'
            ELSE NULL
        END
    FROM master.dbo.spt_values v1
    CROSS JOIN master.dbo.spt_values v2
    WHERE v1.type = 'P' AND v2.type = 'P';

    SET @inserted = @inserted + @batchSize;

    IF @inserted % 2500000 = 0
        PRINT 'Progress: ' + CAST(@inserted AS VARCHAR) 
            + ' of 15,000,000 rows inserted';
END
GO

-- -----------------------------------------------
-- Verify
-- -----------------------------------------------
SELECT 'TELEMETRIA_GPS' AS tabla, COUNT(*) AS registros
FROM flota.TELEMETRIA_GPS;
GO