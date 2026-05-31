-- =============================================
-- TRANSTRACK | Week 02 | Part 1: Infrastructure
-- Scheme for TELEMETRIA_GPS
-- Schemas by domain
-- =============================================

USE TRANSTRACK;
GO

-- -----------------------------------------------
-- SCHEMAS
-- -----------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ventas')
    EXEC('CREATE SCHEMA ventas');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'facturacion')
    EXEC('CREATE SCHEMA facturacion');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'operaciones')
    EXEC('CREATE SCHEMA operaciones');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'flota')
    EXEC('CREATE SCHEMA flota');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'archivo')
    EXEC('CREATE SCHEMA archivo');
GO
