-- =============================================
-- TRANSTRACK | Week 02 | Part 9: Data Load
-- Customers: ventas.CLIENTE + facturacion.CLIENTE
-- Intentional problems:
--   - Same NIT registered in both modules
--   - Similar names with slight variations
--   - ventas has 15,000 records with duplicates
--   - facturacion has 12,000 records with duplicates
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- ventas.CLIENTE — 15,000 records
-- ~2,000 are intentional duplicates by NIT
-- ~1,500 are similar name variations
-- -----------------------------------------------
DECLARE @cl INT = 1;

WHILE @cl <= 15000
BEGIN
    INSERT INTO ventas.CLIENTE (
        nit, nombre, email, telefono,
        direccion, ciudad, categoria, activo
    )
    VALUES (
        -- Intentional: every 8th record reuses a NIT from first 2000
        CASE
            WHEN @cl > 2000 AND @cl % 8 = 0
                THEN 'NIT-' + RIGHT('000000' + CAST(@cl % 2000 + 1 AS VARCHAR), 6)
            ELSE
                'NIT-' + RIGHT('000000' + CAST(@cl AS VARCHAR), 6)
        END,

        -- Intentional: name variations for same client
        CASE
            WHEN @cl > 3000 AND @cl % 12 = 0
                THEN
                    CASE @cl % 5
                        WHEN 0 THEN 'Transportes del Sur S.A.'
                        WHEN 1 THEN 'Transportes Del Sur SA'
                        WHEN 2 THEN 'Trans del Sur S.A.'
                        WHEN 3 THEN 'Transportes del Sur'
                        ELSE 'TRANSPORTES DEL SUR S.A.'
                    END
            ELSE
                CASE @cl % 20
                    WHEN 0  THEN 'Distribuidora Nacional S.A.'
                    WHEN 1  THEN 'Grupo Logistico GT'
                    WHEN 2  THEN 'Importaciones del Norte'
                    WHEN 3  THEN 'Comercial Pacifico Ltda.'
                    WHEN 4  THEN 'Exportadora Centroamericana'
                    WHEN 5  THEN 'Industrias Unidas S.A.'
                    WHEN 6  THEN 'Agro Exportaciones GT'
                    WHEN 7  THEN 'Corporacion Logistica SA'
                    WHEN 8  THEN 'Suministros Generales Ltda'
                    WHEN 9  THEN 'Almacenadora del Este S.A.'
                    WHEN 10 THEN 'Frigorifico Nacional'
                    WHEN 11 THEN 'Constructora Regional GT'
                    WHEN 12 THEN 'Ferretera Industrial SA'
                    WHEN 13 THEN 'Farmaceutica Central'
                    WHEN 14 THEN 'Textilera Guatemalteca'
                    WHEN 15 THEN 'Procesadora de Alimentos GT'
                    WHEN 16 THEN 'Maquinaria Pesada SA'
                    WHEN 17 THEN 'Electrodomesticos del Sur'
                    WHEN 18 THEN 'Materiales de Construccion GT'
                    ELSE 'Servicios Integrados SA'
                END
                + ' ' + CAST(@cl AS VARCHAR)
        END,

        'contacto' + CAST(@cl AS VARCHAR) + '@empresa.gt',

        '502-' + RIGHT('00000000' + CAST(20000000 + @cl * 3 AS VARCHAR), 8),

        'Calle ' + CAST(@cl % 50 + 1 AS VARCHAR) 
            + ' Avenida ' + CAST(@cl % 20 + 1 AS VARCHAR),

        CASE @cl % 10
            WHEN 0 THEN 'Guatemala City'
            WHEN 1 THEN 'Quetzaltenango'
            WHEN 2 THEN 'Escuintla'
            WHEN 3 THEN 'Coban'
            WHEN 4 THEN 'Mazatenango'
            WHEN 5 THEN 'Puerto Barrios'
            WHEN 6 THEN 'Chiquimula'
            WHEN 7 THEN 'Huehuetenango'
            WHEN 8 THEN 'Zacapa'
            ELSE 'Jalapa'
        END,

        CASE @cl % 4
            WHEN 0 THEN 'ESTANDAR'
            WHEN 1 THEN 'PREFERENTE'
            WHEN 2 THEN 'CORPORATIVO'
            ELSE 'ESTANDAR'
        END,

        CASE WHEN @cl % 30 = 0 THEN 0 ELSE 1 END
    );

    SET @cl = @cl + 1;
END
GO

-- -----------------------------------------------
-- facturacion.CLIENTE — 12,000 records
-- Same companies registered differently
-- Different column names, different NIT format
-- No link to ventas.CLIENTE
-- -----------------------------------------------
DECLARE @fc INT = 1;

WHILE @fc <= 12000
BEGIN
    INSERT INTO facturacion.CLIENTE (
        nit_cliente, razon_social, correo,
        telefono_contacto, direccion_fiscal,
        limite_credito, dias_credito
    )
    VALUES (
        -- Intentional: NIT format slightly different (no leading zeros)
        CASE
            WHEN @fc > 1500 AND @fc % 8 = 0
                THEN CAST(@fc % 1500 + 1 AS VARCHAR)  -- numeric only, no prefix
            ELSE
                CAST(@fc AS VARCHAR)
        END,

        -- Same companies but razon_social format differs
        CASE @fc % 20
            WHEN 0  THEN 'DISTRIBUIDORA NACIONAL, S.A.'
            WHEN 1  THEN 'GRUPO LOGISTICO GT, S.A.'
            WHEN 2  THEN 'IMPORTACIONES DEL NORTE S.A.'
            WHEN 3  THEN 'COMERCIAL PACIFICO, LTDA.'
            WHEN 4  THEN 'EXPORTADORA CENTROAMERICANA S.A.'
            WHEN 5  THEN 'INDUSTRIAS UNIDAS, S.A.'
            WHEN 6  THEN 'AGRO EXPORTACIONES GT S.A.'
            WHEN 7  THEN 'CORPORACION LOGISTICA, S.A.'
            WHEN 8  THEN 'SUMINISTROS GENERALES, LTDA.'
            WHEN 9  THEN 'ALMACENADORA DEL ESTE S.A.'
            WHEN 10 THEN 'FRIGORIFICO NACIONAL S.A.'
            WHEN 11 THEN 'CONSTRUCTORA REGIONAL GT S.A.'
            WHEN 12 THEN 'FERRETERA INDUSTRIAL, S.A.'
            WHEN 13 THEN 'FARMACEUTICA CENTRAL S.A.'
            WHEN 14 THEN 'TEXTILERA GUATEMALTECA S.A.'
            WHEN 15 THEN 'PROCESADORA DE ALIMENTOS GT S.A.'
            WHEN 16 THEN 'MAQUINARIA PESADA, S.A.'
            WHEN 17 THEN 'ELECTRODOMESTICOS DEL SUR S.A.'
            WHEN 18 THEN 'MATERIALES DE CONSTRUCCION GT S.A.'
            ELSE 'SERVICIOS INTEGRADOS, S.A.'
        END
        + ' - ' + CAST(@fc AS VARCHAR),

        'facturacion' + CAST(@fc AS VARCHAR) + '@empresa.gt',

        '(502) ' + RIGHT('00000000' + CAST(20000000 + @fc * 3 AS VARCHAR), 8),

        'Zona ' + CAST(@fc % 25 + 1 AS VARCHAR) 
            + ', Ciudad de Guatemala',

        ROUND(10000 + (@fc % 50 * 5000), 2),

        CASE @fc % 3
            WHEN 0 THEN 30
            WHEN 1 THEN 60
            ELSE 90
        END
    );

    SET @fc = @fc + 1;
END
GO

-- -----------------------------------------------
-- Verify
-- -----------------------------------------------
SELECT 'ventas.CLIENTE'       AS tabla, COUNT(*) AS registros FROM ventas.CLIENTE
UNION ALL
SELECT 'facturacion.CLIENTE', COUNT(*) FROM facturacion.CLIENTE;
GO