-- =============================================
-- TRANSTRACK | Week 02 | Part 8: Data Load
-- Fleet domain: CONDUCTOR, EMPLEADO, OPERADOR
-- Intentional problems:
--   - Same people in 3 tables, no common key
--   - CONDUCTOR has no UNIQUE on numero_licencia
--   - EMPLEADO has no license column
--   - OPERADOR has no link to either table
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- CONDUCTOR — 1,200 records (operations module)
-- -----------------------------------------------
DECLARE @c INT = 1;

WHILE @c <= 1200
BEGIN
    INSERT INTO flota.CONDUCTOR (
        numero_licencia, nombre, apellido,
        telefono, categoria_licencia,
        fecha_vencimiento_licencia, activo
    )
    VALUES (
        'LIC-' + RIGHT('000000' + CAST(@c AS VARCHAR), 6),

        CASE @c % 15
            WHEN 0  THEN 'Carlos'    WHEN 1  THEN 'Juan'
            WHEN 2  THEN 'Pedro'     WHEN 3  THEN 'Miguel'
            WHEN 4  THEN 'Jose'      WHEN 5  THEN 'Luis'
            WHEN 6  THEN 'Roberto'   WHEN 7  THEN 'Diego'
            WHEN 8  THEN 'Fernando'  WHEN 9  THEN 'Andres'
            WHEN 10 THEN 'Mario'     WHEN 11 THEN 'Ricardo'
            WHEN 12 THEN 'Hector'    WHEN 13 THEN 'Oscar'
            ELSE 'Alejandro'
        END,

        CASE @c % 10
            WHEN 0 THEN 'Garcia'    WHEN 1 THEN 'Lopez'
            WHEN 2 THEN 'Martinez'  WHEN 3 THEN 'Perez'
            WHEN 4 THEN 'Gonzalez'  WHEN 5 THEN 'Rodriguez'
            WHEN 6 THEN 'Hernandez' WHEN 7 THEN 'Ramirez'
            WHEN 8 THEN 'Torres'    ELSE 'Flores'
        END,

        '502-' + RIGHT('00000000' + CAST(50000000 + @c * 7 AS VARCHAR), 8),

        CASE @c % 4
            WHEN 0 THEN 'A'
            WHEN 1 THEN 'B'
            WHEN 2 THEN 'C'
            ELSE 'E'
        END,

        DATEADD(DAY, 180 + (@c % 1200), GETDATE()),

        CASE WHEN @c % 20 = 0 THEN 0 ELSE 1 END
    );

    SET @c = @c + 1;
END
GO

-- -----------------------------------------------
-- EMPLEADO — 1,100 records (HR module)
-- Same drivers but registered differently
-- 900 match real conductors, 200 are HR-only staff
-- No license number, no link to CONDUCTOR
-- -----------------------------------------------
DECLARE @e INT = 1;

WHILE @e <= 1100
BEGIN
    INSERT INTO flota.EMPLEADO (
        codigo_empleado, nombres, apellidos,
        dpi, fecha_ingreso, cargo,
        salario, departamento, activo
    )
    VALUES (
        'EMP-' + RIGHT('000000' + CAST(@e AS VARCHAR), 6),

        CASE @e % 15
            WHEN 0  THEN 'Carlos Alberto'  WHEN 1  THEN 'Juan Carlos'
            WHEN 2  THEN 'Pedro Antonio'   WHEN 3  THEN 'Miguel Angel'
            WHEN 4  THEN 'Jose Luis'       WHEN 5  THEN 'Luis Fernando'
            WHEN 6  THEN 'Roberto Carlos'  WHEN 7  THEN 'Diego Armando'
            WHEN 8  THEN 'Fernando Jose'   WHEN 9  THEN 'Andres Felipe'
            WHEN 10 THEN 'Mario Roberto'   WHEN 11 THEN 'Ricardo Ivan'
            WHEN 12 THEN 'Hector Manuel'   WHEN 13 THEN 'Oscar Rene'
            ELSE 'Alejandro David'
        END,

        CASE @e % 10
            WHEN 0 THEN 'Garcia Lopez'      WHEN 1 THEN 'Lopez Martinez'
            WHEN 2 THEN 'Martinez Perez'    WHEN 3 THEN 'Perez Gonzalez'
            WHEN 4 THEN 'Gonzalez Rodriguez' WHEN 5 THEN 'Rodriguez Hernandez'
            WHEN 6 THEN 'Hernandez Ramirez' WHEN 7 THEN 'Ramirez Torres'
            WHEN 8 THEN 'Torres Flores'     ELSE 'Flores Garcia'
        END,

        -- DPI format Guatemala: 13 digits
        RIGHT('0000000000000' + CAST(1000000000000 + @e * 9999 AS VARCHAR), 13),

        DATEADD(DAY, -(@e % 2000), GETDATE()),

        CASE @e % 5
            WHEN 0 THEN 'CONDUCTOR'
            WHEN 1 THEN 'CONDUCTOR'
            WHEN 2 THEN 'CONDUCTOR'
            WHEN 3 THEN 'AUXILIAR'
            ELSE 'SUPERVISOR'
        END,

        ROUND(3500 + (@e % 6 * 500), 2),

        CASE @e % 4
            WHEN 0 THEN 'OPERACIONES'
            WHEN 1 THEN 'LOGISTICA'
            WHEN 2 THEN 'TRANSPORTE'
            ELSE 'ADMINISTRACION'
        END,

        CASE WHEN @e % 25 = 0 THEN 0 ELSE 1 END
    );

    SET @e = @e + 1;
END
GO

-- -----------------------------------------------
-- OPERADOR — 950 records (GPS/telemetry module)
-- Same drivers registered in GPS system
-- nombre_completo as single field (not split)
-- vehiculo_asignado as text plate, no FK
-- No link to CONDUCTOR or EMPLEADO
-- -----------------------------------------------
DECLARE @o INT = 1;

WHILE @o <= 950
BEGIN
    INSERT INTO flota.OPERADOR (
        id_operador, nombre_completo,
        email, turno,
        vehiculo_asignado, fecha_asignacion
    )
    VALUES (
        'OPR-' + RIGHT('000000' + CAST(@o AS VARCHAR), 6),

        -- Single field, different format than CONDUCTOR/EMPLEADO
        CASE @o % 10
            WHEN 0 THEN 'Garcia, Carlos'      WHEN 1 THEN 'Lopez, Juan'
            WHEN 2 THEN 'Martinez, Pedro'     WHEN 3 THEN 'Perez, Miguel'
            WHEN 4 THEN 'Gonzalez, Jose'      WHEN 5 THEN 'Rodriguez, Luis'
            WHEN 6 THEN 'Hernandez, Roberto'  WHEN 7 THEN 'Ramirez, Diego'
            WHEN 8 THEN 'Torres, Fernando'    ELSE 'Flores, Andres'
        END,

        'operador' + CAST(@o AS VARCHAR) + '@transtrack.gt',

        CASE @o % 3
            WHEN 0 THEN 'DIURNO'
            WHEN 1 THEN 'NOCTURNO'
            ELSE 'MIXTO'
        END,

        -- Plate as plain text, no FK to VEHICULO
        CASE WHEN @o % 8 = 0 THEN NULL
        ELSE
            CHAR(65 + (@o % 26)) +
            CHAR(65 + ((@o + 3) % 26)) +
            CHAR(65 + ((@o + 7) % 26)) +
            '-' + RIGHT('000' + CAST(1000 + (@o % 800) AS VARCHAR), 4)
        END,

        CASE WHEN @o % 8 = 0 THEN NULL
             ELSE DATEADD(DAY, -(@o % 365), GETDATE())
        END
    );

    SET @o = @o + 1;
END
GO

-- -----------------------------------------------
-- Verify
-- -----------------------------------------------
SELECT 'CONDUCTOR' AS tabla, COUNT(*) AS registros FROM flota.CONDUCTOR
UNION ALL
SELECT 'EMPLEADO',  COUNT(*) FROM flota.EMPLEADO
UNION ALL
SELECT 'OPERADOR',  COUNT(*) FROM flota.OPERADOR;
GO