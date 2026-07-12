/* ============================================================================
   FILE:        05_data_vault_links.sql
   PROJECT:     P02 - Data Governance Architecture | TRANSTRACK
   FOLDER:      06-analytical-modeling
   PURPOSE:     Data Vault 2.0 links - relationships between hubs
   AUTHOR:      cblancogt

   Links record the RELATIONSHIP between business keys at a point in time.
   A link row is a fact of association, not a fact of measurement (that is
   what satellites are for). Like hubs, links are append-only.
   ============================================================================ */

USE TRANSTRACK;
GO

/* ============================================================================
   LINK_INCIDENTECONDUCTOR
   Resolves which driver was linked to a given incident. Sourced the same way
   as the point-in-time join in 03_scd2_load_procedure.sql: through
   flota.ASIGNACION_VEHICULO at the incident's fecha_incidente.
   ============================================================================ */
CREATE TABLE vault.Link_IncidenteConductor
(
    link_incidente_conductor_hash_key  CHAR(40)        NOT NULL,
    incidente_hash_key                 CHAR(40)        NOT NULL CONSTRAINT FK_LinkIncCond_Incidente REFERENCES vault.Hub_Incidente(incidente_hash_key),
    conductor_hash_key                 CHAR(40)        NOT NULL CONSTRAINT FK_LinkIncCond_Conductor REFERENCES vault.Hub_Conductor(conductor_hash_key),
    load_date                          DATETIME2(0)    NOT NULL CONSTRAINT DF_LinkIncCond_LoadDate DEFAULT (SYSUTCDATETIME()),
    record_source                      VARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Link_IncidenteConductor PRIMARY KEY CLUSTERED (link_incidente_conductor_hash_key)
)
ON [ANALYTICS];
GO

/* ============================================================================
   LINK_INCIDENTEVEHICULO
   ============================================================================ */
CREATE TABLE vault.Link_IncidenteVehiculo
(
    link_incidente_vehiculo_hash_key   CHAR(40)        NOT NULL,
    incidente_hash_key                 CHAR(40)        NOT NULL CONSTRAINT FK_LinkIncVeh_Incidente REFERENCES vault.Hub_Incidente(incidente_hash_key),
    vehiculo_hash_key                  CHAR(40)        NOT NULL CONSTRAINT FK_LinkIncVeh_Vehiculo  REFERENCES vault.Hub_Vehiculo(vehiculo_hash_key),
    load_date                          DATETIME2(0)    NOT NULL CONSTRAINT DF_LinkIncVeh_LoadDate DEFAULT (SYSUTCDATETIME()),
    record_source                      VARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Link_IncidenteVehiculo PRIMARY KEY CLUSTERED (link_incidente_vehiculo_hash_key)
)
ON [ANALYTICS];
GO

/* ============================================================================
   LINK_INCIDENTEPEDIDO
   Direct: operaciones.INCIDENTE.pedido_id is nullable in source (not every
   incident is tied to an order - e.g. a warehouse-only theft). Rows are only
   created when pedido_id IS NOT NULL, consistent with Data Vault practice of
   not fabricating relationships the source data does not actually assert.
   ============================================================================ */
CREATE TABLE vault.Link_IncidentePedido
(
    link_incidente_pedido_hash_key     CHAR(40)        NOT NULL,
    incidente_hash_key                 CHAR(40)        NOT NULL CONSTRAINT FK_LinkIncPed_Incidente REFERENCES vault.Hub_Incidente(incidente_hash_key),
    pedido_hash_key                    CHAR(40)        NOT NULL CONSTRAINT FK_LinkIncPed_Pedido    REFERENCES vault.Hub_Pedido(pedido_hash_key),
    load_date                          DATETIME2(0)    NOT NULL CONSTRAINT DF_LinkIncPed_LoadDate DEFAULT (SYSUTCDATETIME()),
    record_source                      VARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Link_IncidentePedido PRIMARY KEY CLUSTERED (link_incidente_pedido_hash_key)
)
ON [ANALYTICS];
GO

/* ============================================================================
   LOAD PROCEDURES
   ============================================================================ */
CREATE OR ALTER PROCEDURE vault.usp_Load_Link_IncidenteConductor
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH IncidenteConductorResuelto AS (
        SELECT
            i.incidente_id,
            av.conductor_id,
            ROW_NUMBER() OVER (PARTITION BY i.incidente_id ORDER BY av.fecha_inicio DESC) AS rn
        FROM operaciones.INCIDENTE i
        INNER JOIN operaciones.PEDIDO p ON p.pedido_id = i.pedido_id
        LEFT JOIN flota.ASIGNACION_VEHICULO av
            ON av.pedido_id = p.pedido_id
           AND av.fecha_inicio <= i.fecha_incidente
           AND (av.fecha_fin IS NULL OR av.fecha_fin >= i.fecha_incidente)
        WHERE i.pedido_id IS NOT NULL
    )
    INSERT INTO vault.Link_IncidenteConductor
        (link_incidente_conductor_hash_key, incidente_hash_key, conductor_hash_key, record_source)
    SELECT
        CONVERT(CHAR(40), HASHBYTES('SHA1', hi.incidente_hash_key + hc.conductor_hash_key), 2),
        hi.incidente_hash_key,
        hc.conductor_hash_key,
        'operaciones.INCIDENTE + flota.ASIGNACION_VEHICULO (point-in-time resolved)'
    FROM IncidenteConductorResuelto icr
    INNER JOIN vault.Hub_Incidente hi ON hi.incidente_id = icr.incidente_id
    -- source_system matches 'CONDUCTOR' specifically: ASIGNACION_VEHICULO.conductor_id
    -- carries an enforced FK constraint, which can only reference one table (flota.CONDUCTOR),
    -- not EMPLEADO or OPERADOR.
    INNER JOIN governance_control.CONDUCTOR_CROSSWALK cwc
        ON cwc.source_pk = icr.conductor_id AND cwc.source_system = 'CONDUCTOR'
    INNER JOIN vault.Hub_Conductor hc ON hc.master_conductor_id = cwc.master_conductor_id
    WHERE icr.rn = 1
      AND NOT EXISTS (
        SELECT 1 FROM vault.Link_IncidenteConductor l
        WHERE l.incidente_hash_key = hi.incidente_hash_key AND l.conductor_hash_key = hc.conductor_hash_key
      );
END;
GO

CREATE OR ALTER PROCEDURE vault.usp_Load_Link_IncidenteVehiculo
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH IncidenteVehiculoResuelto AS (
        SELECT
            i.incidente_id,
            av.vehiculo_id,
            ROW_NUMBER() OVER (PARTITION BY i.incidente_id ORDER BY av.fecha_inicio DESC) AS rn
        FROM operaciones.INCIDENTE i
        INNER JOIN operaciones.PEDIDO p ON p.pedido_id = i.pedido_id
        LEFT JOIN flota.ASIGNACION_VEHICULO av
            ON av.pedido_id = p.pedido_id
           AND av.fecha_inicio <= i.fecha_incidente
           AND (av.fecha_fin IS NULL OR av.fecha_fin >= i.fecha_incidente)
        WHERE i.pedido_id IS NOT NULL
    )
    INSERT INTO vault.Link_IncidenteVehiculo
        (link_incidente_vehiculo_hash_key, incidente_hash_key, vehiculo_hash_key, record_source)
    SELECT
        CONVERT(CHAR(40), HASHBYTES('SHA1', hi.incidente_hash_key + hv.vehiculo_hash_key), 2),
        hi.incidente_hash_key,
        hv.vehiculo_hash_key,
        'operaciones.INCIDENTE + flota.ASIGNACION_VEHICULO (point-in-time resolved)'
    FROM IncidenteVehiculoResuelto ivr
    INNER JOIN vault.Hub_Incidente hi ON hi.incidente_id = ivr.incidente_id
    INNER JOIN flota.VEHICULO v ON v.vehiculo_id = ivr.vehiculo_id
    INNER JOIN vault.Hub_Vehiculo hv ON hv.placa = v.placa
    WHERE ivr.rn = 1
      AND NOT EXISTS (
        SELECT 1 FROM vault.Link_IncidenteVehiculo l
        WHERE l.incidente_hash_key = hi.incidente_hash_key AND l.vehiculo_hash_key = hv.vehiculo_hash_key
      );
END;
GO

CREATE OR ALTER PROCEDURE vault.usp_Load_Link_IncidentePedido
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO vault.Link_IncidentePedido
        (link_incidente_pedido_hash_key, incidente_hash_key, pedido_hash_key, record_source)
    SELECT
        CONVERT(CHAR(40), HASHBYTES('SHA1', hi.incidente_hash_key + hp.pedido_hash_key), 2),
        hi.incidente_hash_key,
        hp.pedido_hash_key,
        'operaciones.INCIDENTE'
    FROM operaciones.INCIDENTE i
    INNER JOIN vault.Hub_Incidente hi ON hi.incidente_id = i.incidente_id
    INNER JOIN operaciones.PEDIDO p ON p.pedido_id = i.pedido_id
    INNER JOIN vault.Hub_Pedido hp ON hp.numero_pedido = p.numero_pedido
    WHERE i.pedido_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM vault.Link_IncidentePedido l
        WHERE l.incidente_hash_key = hi.incidente_hash_key AND l.pedido_hash_key = hp.pedido_hash_key
      );
END;
GO
