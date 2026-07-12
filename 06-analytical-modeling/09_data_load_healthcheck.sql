/* ============================================================================
   FILE:        00_diagnostico_carga.sql
   PROJECT:     P02 - Data Governance Architecture | TRANSTRACK
   FOLDER:      06-analytical-modeling
   PURPOSE:     Quick row-count check across dw and vault schemas, to confirm
                which load procedures have actually been executed vs which
                only had their structure created.
   ============================================================================ */

USE TRANSTRACK;
GO

SELECT 'dw.Dim_Cliente'                    AS tabla, COUNT(*) AS filas FROM dw.Dim_Cliente
UNION ALL SELECT 'dw.Dim_Conductor',            COUNT(*) FROM dw.Dim_Conductor
UNION ALL SELECT 'dw.Dim_Vehiculo',             COUNT(*) FROM dw.Dim_Vehiculo
UNION ALL SELECT 'dw.Dim_Ruta',                 COUNT(*) FROM dw.Dim_Ruta
UNION ALL SELECT 'dw.Dim_EstadoEntrega',        COUNT(*) FROM dw.Dim_EstadoEntrega
UNION ALL SELECT 'dw.Dim_Tiempo',               COUNT(*) FROM dw.Dim_Tiempo
UNION ALL SELECT 'dw.Fact_Pedido',              COUNT(*) FROM dw.Fact_Pedido
UNION ALL SELECT 'dw.Fact_Entrega',             COUNT(*) FROM dw.Fact_Entrega
UNION ALL SELECT 'dw.Fact_Incidente',           COUNT(*) FROM dw.Fact_Incidente
UNION ALL SELECT 'vault.Hub_Conductor',         COUNT(*) FROM vault.Hub_Conductor
UNION ALL SELECT 'vault.Hub_Vehiculo',          COUNT(*) FROM vault.Hub_Vehiculo
UNION ALL SELECT 'vault.Hub_Pedido',            COUNT(*) FROM vault.Hub_Pedido
UNION ALL SELECT 'vault.Hub_Incidente',         COUNT(*) FROM vault.Hub_Incidente
UNION ALL SELECT 'vault.Link_IncidenteConductor', COUNT(*) FROM vault.Link_IncidenteConductor
UNION ALL SELECT 'vault.Link_IncidenteVehiculo',  COUNT(*) FROM vault.Link_IncidenteVehiculo
UNION ALL SELECT 'vault.Link_IncidentePedido',    COUNT(*) FROM vault.Link_IncidentePedido
UNION ALL SELECT 'vault.Sat_Conductor_Detalle',   COUNT(*) FROM vault.Sat_Conductor_Detalle
UNION ALL SELECT 'vault.Sat_Incidente_Detalle',   COUNT(*) FROM vault.Sat_Incidente_Detalle
ORDER BY tabla;
GO

-- If vault.Hub_Incidente has rows but comes back empty for a specific ID,
-- use this to find a real incidente_id that DOES have both a hub row and
-- a resolved conductor/vehiculo link - a good candidate to test 07 against.
SELECT TOP 5
    hi.incidente_id,
    CASE WHEN lic.incidente_hash_key IS NOT NULL THEN 1 ELSE 0 END AS tiene_conductor,
    CASE WHEN liv.incidente_hash_key IS NOT NULL THEN 1 ELSE 0 END AS tiene_vehiculo,
    CASE WHEN lip.incidente_hash_key IS NOT NULL THEN 1 ELSE 0 END AS tiene_pedido
FROM vault.Hub_Incidente hi
LEFT JOIN vault.Link_IncidenteConductor lic ON lic.incidente_hash_key = hi.incidente_hash_key
LEFT JOIN vault.Link_IncidenteVehiculo  liv ON liv.incidente_hash_key = hi.incidente_hash_key
LEFT JOIN vault.Link_IncidentePedido    lip ON lip.incidente_hash_key = hi.incidente_hash_key
WHERE lic.incidente_hash_key IS NOT NULL
  AND liv.incidente_hash_key IS NOT NULL
  AND lip.incidente_hash_key IS NOT NULL;
GO
