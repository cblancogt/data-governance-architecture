/* ============================================================================
   FILE:        04_data_vault_hubs.sql
   PROJECT:     P02 - Data Governance Architecture | TRANSTRACK
   FOLDER:      06-analytical-modeling
   PURPOSE:     Data Vault 2.0 hubs - the legal traceability model
   AUTHOR:      cblancogt

   WHY A SEPARATE MODEL FROM THE STAR SCHEMA (see adr_datavault_vs_kimball.md
   for the full ADR): the star schema answers "how many/how much/trend"
   business questions and is optimized for BI tools. It is NOT designed to
   answer "produce every fact known about incident #4521, as it existed at
   each point in time, admissible as evidence" - that is a fundamentally
   different requirement (auditability, non-destructive history, hash-based
   business-key independence) that Data Vault is purpose-built for.

   Hash keys (not natural keys, not identity integers) are used per Data
   Vault 2.0 standard so that:
     1) Hubs can be loaded in parallel from multiple sources without an
        identity-column bottleneck or lookup round-trip.
     2) The same business key computes to the same hash regardless of which
        source system it arrived from - critical here because CONDUCTOR is
        fragmented across 3 legacy tables with 3 different natural keys
        (numero_licencia, codigo_empleado, id_operador).
   ============================================================================ */

USE TRANSTRACK;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'vault')
BEGIN
    EXEC('CREATE SCHEMA vault AUTHORIZATION dbo');
END
GO

/* ============================================================================
   HUB_CONDUCTOR
   Business key: governance_control.MASTER_CONDUCTOR.conductor_hash_key is
   itself already a business-key hash (built in folder 05 from numero_licencia
   with fallbacks). We re-key it here through SHA1 explicitly per Data Vault
   2.0 convention (hash_key = HASHBYTES('SHA1', business_key)), keeping the
   Vault's hashing strategy independent of how folder 05 computed its MD5
   golden-record key - the Vault must not assume folder 05's implementation
   never changes.
   ============================================================================ */
CREATE TABLE vault.Hub_Conductor
(
    conductor_hash_key     CHAR(40)        NOT NULL,                   -- SHA1, hex-encoded
    master_conductor_id    INT             NOT NULL,                   -- business key (natural key surrogate from folder 05)
    load_date              DATETIME2(0)    NOT NULL CONSTRAINT DF_HubConductor_LoadDate DEFAULT (SYSUTCDATETIME()),
    record_source          VARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Hub_Conductor PRIMARY KEY CLUSTERED (conductor_hash_key)
)
ON [ANALYTICS];
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Hub_Conductor_BusinessKey
    ON vault.Hub_Conductor (master_conductor_id)
    ON [ANALYTICS];
GO

/* ============================================================================
   HUB_VEHICULO
   Business key: flota.VEHICULO.placa (license plate - the true real-world
   business identifier for a vehicle, not the surrogate vehiculo_id, which is
   only meaningful inside this specific database instance).
   ============================================================================ */
CREATE TABLE vault.Hub_Vehiculo
(
    vehiculo_hash_key      CHAR(40)        NOT NULL,
    placa                  VARCHAR(10)     NOT NULL,
    load_date              DATETIME2(0)    NOT NULL CONSTRAINT DF_HubVehiculo_LoadDate DEFAULT (SYSUTCDATETIME()),
    record_source          VARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Hub_Vehiculo PRIMARY KEY CLUSTERED (vehiculo_hash_key)
)
ON [ANALYTICS];
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Hub_Vehiculo_Placa
    ON vault.Hub_Vehiculo (placa)
    ON [ANALYTICS];
GO

/* ============================================================================
   HUB_PEDIDO
   Business key: operaciones.PEDIDO.numero_pedido (the human/business-facing
   order number, not the internal identity pedido_id).
   ============================================================================ */
CREATE TABLE vault.Hub_Pedido
(
    pedido_hash_key        CHAR(40)        NOT NULL,
    numero_pedido          VARCHAR(30)     NOT NULL,
    load_date              DATETIME2(0)    NOT NULL CONSTRAINT DF_HubPedido_LoadDate DEFAULT (SYSUTCDATETIME()),
    record_source          VARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Hub_Pedido PRIMARY KEY CLUSTERED (pedido_hash_key)
)
ON [ANALYTICS];
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Hub_Pedido_NumeroPedido
    ON vault.Hub_Pedido (numero_pedido)
    ON [ANALYTICS];
GO

/* ============================================================================
   HUB_INCIDENTE
   Business key: a synthetic-but-stable composite here is unavoidable, since
   operaciones.INCIDENTE has no independent business identifier (no incident
   report number in source). We use incidente_id itself as the business key
   for the Vault (documented explicitly as a known limitation) rather than
   inventing one - a real remediation would be to require the source system
   to issue a formal incident report number, which is flagged as a
   recommendation in the README of this folder.
   ============================================================================ */
CREATE TABLE vault.Hub_Incidente
(
    incidente_hash_key     CHAR(40)        NOT NULL,
    incidente_id           INT             NOT NULL,                   -- documented limitation: source has no independent business key
    load_date              DATETIME2(0)    NOT NULL CONSTRAINT DF_HubIncidente_LoadDate DEFAULT (SYSUTCDATETIME()),
    record_source          VARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Hub_Incidente PRIMARY KEY CLUSTERED (incidente_hash_key)
)
ON [ANALYTICS];
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_Hub_Incidente_IncidenteId
    ON vault.Hub_Incidente (incidente_id)
    ON [ANALYTICS];
GO

/* ============================================================================
   LOAD PROCEDURES - hubs only ever INSERT new business keys, never UPDATE
   (append-only is a Data Vault 2.0 hard rule - it is what makes the model
   auditable and safe to reload/replay).
   ============================================================================ */
CREATE OR ALTER PROCEDURE vault.usp_Load_Hub_Conductor
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO vault.Hub_Conductor (conductor_hash_key, master_conductor_id, record_source)
    SELECT
        CONVERT(CHAR(40), HASHBYTES('SHA1', CAST(mc.master_conductor_id AS VARCHAR(20))), 2),
        mc.master_conductor_id,
        'governance_control.MASTER_CONDUCTOR'
    FROM governance_control.MASTER_CONDUCTOR mc
    WHERE NOT EXISTS (
        SELECT 1 FROM vault.Hub_Conductor h WHERE h.master_conductor_id = mc.master_conductor_id
    );
END;
GO

CREATE OR ALTER PROCEDURE vault.usp_Load_Hub_Vehiculo
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO vault.Hub_Vehiculo (vehiculo_hash_key, placa, record_source)
    SELECT
        CONVERT(CHAR(40), HASHBYTES('SHA1', UPPER(LTRIM(RTRIM(v.placa)))), 2),
        v.placa,
        'flota.VEHICULO'
    FROM flota.VEHICULO v
    WHERE NOT EXISTS (
        SELECT 1 FROM vault.Hub_Vehiculo h WHERE h.placa = v.placa
    );
END;
GO

CREATE OR ALTER PROCEDURE vault.usp_Load_Hub_Pedido
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO vault.Hub_Pedido (pedido_hash_key, numero_pedido, record_source)
    SELECT
        CONVERT(CHAR(40), HASHBYTES('SHA1', UPPER(LTRIM(RTRIM(p.numero_pedido)))), 2),
        p.numero_pedido,
        'operaciones.PEDIDO'
    FROM operaciones.PEDIDO p
    WHERE NOT EXISTS (
        SELECT 1 FROM vault.Hub_Pedido h WHERE h.numero_pedido = p.numero_pedido
    );
END;
GO

CREATE OR ALTER PROCEDURE vault.usp_Load_Hub_Incidente
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO vault.Hub_Incidente (incidente_hash_key, incidente_id, record_source)
    SELECT
        CONVERT(CHAR(40), HASHBYTES('SHA1', CAST(i.incidente_id AS VARCHAR(20))), 2),
        i.incidente_id,
        'operaciones.INCIDENTE'
    FROM operaciones.INCIDENTE i
    WHERE NOT EXISTS (
        SELECT 1 FROM vault.Hub_Incidente h WHERE h.incidente_id = i.incidente_id
    );
END;
GO
