-- =============================================
-- TRANSTRACK | Week 02 | Part 7: Data Load
-- Base tables: RUTA (2,500) and VEHICULO (800)
-- No dependencies
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- RUTA — 2,500 records
-- -----------------------------------------------
DECLARE @i INT = 1;
DECLARE @ciudades TABLE (ciudad VARCHAR(80));

INSERT INTO @ciudades VALUES
('Guatemala City'),('Quetzaltenango'),('Escuintla'),('Mazatenango'),
('Coban'),('Huehuetenango'),('Puerto Barrios'),('Zacapa'),
('Chiquimula'),('Jalapa'),('Jutiapa'),('Santa Rosa'),
('Retalhuleu'),('San Marcos'),('Solola'),('Totonicapan'),
('Chimaltenango'),('Sacatepequez'),('El Progreso'),('Baja Verapaz'),
('Alta Verapaz'),('Peten'),('Izabal'),('Zacapa'),('El Quiche');

WHILE @i <= 2500
BEGIN
    INSERT INTO operaciones.RUTA (
        codigo_ruta, ciudad_origen, ciudad_destino,
        distancia_km, tiempo_estimado_h, tipo_via, activa
    )
    SELECT
        'RUT-' + RIGHT('00000' + CAST(@i AS VARCHAR), 5),
        c1.ciudad,
        c2.ciudad,
        ROUND(50 + (RAND(CHECKSUM(NEWID())) * 450), 2),
        ROUND(1 + (RAND(CHECKSUM(NEWID())) * 10), 2),
        CASE WHEN @i % 10 = 0 THEN 'MARITIMA' ELSE 'TERRESTRE' END,
        CASE WHEN @i % 20 = 0 THEN 0 ELSE 1 END
    FROM
        (SELECT TOP 1 ciudad FROM @ciudades ORDER BY NEWID()) c1,
        (SELECT TOP 1 ciudad FROM @ciudades ORDER BY NEWID()) c2
    WHERE c1.ciudad <> c2.ciudad;

    SET @i = @i + 1;
END
GO

-- -----------------------------------------------
-- VEHICULO — 800 records
-- -----------------------------------------------
DECLARE @v INT = 1;

WHILE @v <= 800
BEGIN
    INSERT INTO flota.VEHICULO (
        placa, marca, modelo, anio,
        tipo_vehiculo, capacidad_ton,
        estado, fecha_adquisicion, km_actuales
    )
    VALUES (
        -- Guatemalan plate format
        CHAR(65 + (@v % 26)) +
        CHAR(65 + ((@v + 3) % 26)) +
        CHAR(65 + ((@v + 7) % 26)) +
        '-' + RIGHT('000' + CAST(1000 + @v AS VARCHAR), 4),

        CASE @v % 5
            WHEN 0 THEN 'KENWORTH'
            WHEN 1 THEN 'FREIGHTLINER'
            WHEN 2 THEN 'INTERNATIONAL'
            WHEN 3 THEN 'VOLVO'
            ELSE 'MERCEDES'
        END,

        CASE @v % 4
            WHEN 0 THEN 'T680'
            WHEN 1 THEN 'CASCADIA'
            WHEN 2 THEN 'LT625'
            ELSE 'FH16'
        END,

        2015 + (@v % 9),

        CASE @v % 4
            WHEN 0 THEN 'TRAILER'
            WHEN 1 THEN 'FURGON'
            WHEN 2 THEN 'PLATAFORMA'
            ELSE 'CISTERNA'
        END,

        ROUND(5 + (@v % 30), 2),

        CASE
            WHEN @v % 15 = 0 THEN 'MANTENIMIENTO'
            WHEN @v % 40 = 0 THEN 'BAJA'
            WHEN @v % 25 = 0 THEN 'RESERVA'
            ELSE 'ACTIVO'
        END,

        DATEADD(DAY, -(@v * 3) % 3650, GETDATE()),

        ROUND(10000 + (RAND(CHECKSUM(NEWID())) * 490000), 2)
    );

    SET @v = @v + 1;
END
GO

-- -----------------------------------------------
-- Verify
-- -----------------------------------------------
SELECT 'RUTA'    AS tabla, COUNT(*) AS registros FROM operaciones.RUTA
UNION ALL
SELECT 'VEHICULO', COUNT(*) FROM flota.VEHICULO;
GO