/* ============================================================================
   FILE:        07_incident_reconstruction.sql
   PROJECT:     P02 - Data Governance Architecture | TRANSTRACK
   FOLDER:      06-analytical-modeling
   PURPOSE:     Legal reconstruction query - given one incident, produce the
                full evidentiary chain: driver, vehicle, client, route, and
                GPS speed at the moment of the event.
   AUTHOR:      cblancogt

   This is the query that justifies building a Data Vault at all. It answers
   a question the star schema is not designed to answer well: "walk me
   through everything connected to incident #X, as it was known at that time,
   with a defensible trail back to source."

   USAGE: replace @IncidenteId below with the incidente_id under investigation.
   ============================================================================ */

USE TRANSTRACK;
GO

DECLARE @IncidenteId INT = 4521;  -- <-- parameter: the incident being investigated

-- STEP 1: core incident facts, as currently known (load_end_date IS NULL = current version)
SELECT
    'INCIDENTE' AS seccion,
    i.incidente_id,
    sid.fecha_incidente,
    sid.tipo_incidente,
    sid.severidad,
    sid.estado_resolucion,
    sid.costo_estimado,
    sid.descripcion
FROM operaciones.INCIDENTE i
INNER JOIN vault.Hub_Incidente hi ON hi.incidente_id = i.incidente_id
INNER JOIN vault.Sat_Incidente_Detalle sid
    ON sid.incidente_hash_key = hi.incidente_hash_key AND sid.load_end_date IS NULL
WHERE i.incidente_id = @IncidenteId;

-- STEP 2: the driver linked to this incident, WITH the license status as it
-- stood at the moment of the incident (not the current status - a driver's
-- license could have been suspended AFTER the incident, which is a different
-- fact than "was it valid when this happened").
SELECT
    'CONDUCTOR' AS seccion,
    mc.master_conductor_id,
    scd.nombre_completo,
    scd.numero_licencia,
    scd.categoria_licencia,
    scd.fecha_vencimiento_lic,
    scd.licencia_vigente AS licencia_vigente_en_ese_momento,
    scd.load_date AS version_conocida_desde
FROM vault.Hub_Incidente hi
INNER JOIN vault.Link_IncidenteConductor lic ON lic.incidente_hash_key = hi.incidente_hash_key
INNER JOIN vault.Hub_Conductor hc ON hc.conductor_hash_key = lic.conductor_hash_key
INNER JOIN governance_control.MASTER_CONDUCTOR mc ON mc.master_conductor_id = hc.master_conductor_id
-- point-in-time satellite lookup: the version of the record that was
-- effective AT the incident date, not the current one
CROSS APPLY (
    SELECT TOP (1) s.*
    FROM vault.Sat_Conductor_Detalle s
    INNER JOIN operaciones.INCIDENTE i2 ON i2.incidente_id = @IncidenteId
    WHERE s.conductor_hash_key = hc.conductor_hash_key
      AND s.load_date <= i2.fecha_incidente
    ORDER BY s.load_date DESC
) scd
WHERE hi.incidente_id = @IncidenteId;

-- STEP 3: the vehicle linked to this incident
SELECT
    'VEHICULO' AS seccion,
    v.vehiculo_id,
    hv.placa,
    v.marca,
    v.modelo,
    v.tipo_vehiculo,
    v.capacidad_ton
FROM vault.Hub_Incidente hi
INNER JOIN vault.Link_IncidenteVehiculo liv ON liv.incidente_hash_key = hi.incidente_hash_key
INNER JOIN vault.Hub_Vehiculo hv ON hv.vehiculo_hash_key = liv.vehiculo_hash_key
INNER JOIN flota.VEHICULO v ON v.placa = hv.placa
WHERE hi.incidente_id = @IncidenteId;

-- STEP 4: the order and client involved (order is optional - see Link_IncidentePedido notes)
SELECT
    'PEDIDO_Y_CLIENTE' AS seccion,
    p.pedido_id,
    hp.numero_pedido,
    p.tipo_carga,
    p.peso_kg,
    p.valor_declarado,
    mcli.master_cliente_id,
    mcli.nombre AS cliente_nombre,
    mcli.nit_ventas,
    mcli.nit_facturacion,
    r.codigo_ruta,
    r.ciudad_origen,
    r.ciudad_destino
FROM vault.Hub_Incidente hi
INNER JOIN vault.Link_IncidentePedido lip ON lip.incidente_hash_key = hi.incidente_hash_key
INNER JOIN vault.Hub_Pedido hp ON hp.pedido_hash_key = lip.pedido_hash_key
INNER JOIN operaciones.PEDIDO p ON p.numero_pedido = hp.numero_pedido
INNER JOIN operaciones.RUTA r ON r.ruta_id = p.ruta_id
INNER JOIN governance_control.CLIENTE_CROSSWALK cw
    ON cw.source_pk = p.cliente_id AND cw.source_modulo = 'ventas' AND cw.is_survivor = 1
INNER JOIN governance_control.MASTER_CLIENTE mcli ON mcli.master_cliente_id = cw.master_cliente_id
WHERE hi.incidente_id = @IncidenteId;

-- STEP 5: GPS telemetry for the linked vehicle in a +/- 15 minute window around
-- the incident timestamp - this is the "how fast was it going" evidentiary piece.
-- TELEMETRIA_GPS is partitioned by year/month (see 00-environment-setup), so this
-- predicate on fecha_hora also drives partition elimination for the scan.
SELECT
    'TELEMETRIA_GPS' AS seccion,
    tg.fecha_hora,
    tg.latitud,
    tg.longitud,
    tg.velocidad_kmh,
    tg.rumbo,
    tg.evento
FROM vault.Hub_Incidente hi
INNER JOIN vault.Link_IncidenteVehiculo liv ON liv.incidente_hash_key = hi.incidente_hash_key
INNER JOIN vault.Hub_Vehiculo hv ON hv.vehiculo_hash_key = liv.vehiculo_hash_key
INNER JOIN flota.VEHICULO v ON v.placa = hv.placa
INNER JOIN vault.Sat_Incidente_Detalle sid
    ON sid.incidente_hash_key = hi.incidente_hash_key AND sid.load_end_date IS NULL
INNER JOIN flota.TELEMETRIA_GPS tg
    ON tg.vehiculo_id = v.vehiculo_id
   AND tg.fecha_hora BETWEEN DATEADD(MINUTE, -15, sid.fecha_incidente)
                          AND DATEADD(MINUTE, 15, sid.fecha_incidente)
WHERE hi.incidente_id = @IncidenteId
ORDER BY tg.fecha_hora;

/* ============================================================================
   READING THIS OUTPUT AS EVIDENCE:
   - Section CONDUCTOR shows the license status AS IT WAS on the incident
     date, resolved via the satellite's load_date, not today's status.
   - Section TELEMETRIA_GPS gives a speed trace bracketing the event, which
     is the kind of detail a star-schema aggregate (average speed per route
     per month) actively throws away.
   - Every hash key in this chain traces back to record_source in the hubs/
     links/satellites tables, so a regulator asking "where did this number
     come from" gets a straight answer, not a shrug.
   ============================================================================ */
