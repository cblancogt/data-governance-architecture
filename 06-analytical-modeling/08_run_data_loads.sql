/* ============================================================================
   FILE:        08_ejecutar_cargas.sql
   PROJECT:     P02 - Data Governance Architecture | TRANSTRACK
   FOLDER:      06-analytical-modeling
   PURPOSE:     Orchestrates execution of every load procedure created in
                files 03, 04, 05, 06, in strict dependency order, with a
                row-count checkpoint after each stage so a failure is caught
                immediately instead of silently cascading.
   AUTHOR:      cblancogt

   RUN THIS AFTER: 01, 02, 03, 04, 05, 06 have already been executed (those
   files only CREATE tables/procedures - this file is what actually POPULATES
   them).
   ============================================================================ */

USE TRANSTRACK;
GO

PRINT '=== STAGE 1: Star schema dimensions (Type 1) ===';
EXEC dw.usp_Load_Dim_Conductor;
EXEC dw.usp_Load_Dim_Vehiculo;
EXEC dw.usp_Load_Dim_Ruta;
EXEC dw.usp_Load_Dim_EstadoEntrega;
GO

PRINT '=== STAGE 2: Dim_Cliente (SCD2) ===';
EXEC dw.usp_Load_Dim_Cliente_SCD2;
GO

PRINT '=== CHECKPOINT 1: dimensions should be populated now ===';
SELECT 'dw.Dim_Cliente' AS tabla, COUNT(*) AS filas FROM dw.Dim_Cliente
UNION ALL SELECT 'dw.Dim_Conductor', COUNT(*) FROM dw.Dim_Conductor
UNION ALL SELECT 'dw.Dim_Vehiculo', COUNT(*) FROM dw.Dim_Vehiculo
UNION ALL SELECT 'dw.Dim_Ruta', COUNT(*) FROM dw.Dim_Ruta
UNION ALL SELECT 'dw.Dim_EstadoEntrega', COUNT(*) FROM dw.Dim_EstadoEntrega;
GO

PRINT '=== STAGE 3: Star schema facts (depend on dimensions above) ===';
EXEC dw.usp_Load_Fact_Pedido;
EXEC dw.usp_Load_Fact_Entrega;
GO

PRINT '=== CHECKPOINT 2: facts should be populated now ===';
SELECT 'dw.Fact_Pedido' AS tabla, COUNT(*) AS filas FROM dw.Fact_Pedido
UNION ALL SELECT 'dw.Fact_Entrega', COUNT(*) FROM dw.Fact_Entrega;
GO

PRINT '=== STAGE 4: Data Vault hubs (no dependencies) ===';
EXEC vault.usp_Load_Hub_Conductor;
EXEC vault.usp_Load_Hub_Vehiculo;
EXEC vault.usp_Load_Hub_Pedido;
EXEC vault.usp_Load_Hub_Incidente;
GO

PRINT '=== CHECKPOINT 3: hubs should be populated now ===';
SELECT 'vault.Hub_Conductor' AS tabla, COUNT(*) AS filas FROM vault.Hub_Conductor
UNION ALL SELECT 'vault.Hub_Vehiculo', COUNT(*) FROM vault.Hub_Vehiculo
UNION ALL SELECT 'vault.Hub_Pedido', COUNT(*) FROM vault.Hub_Pedido
UNION ALL SELECT 'vault.Hub_Incidente', COUNT(*) FROM vault.Hub_Incidente;
GO

-- If any hub above is 0, STOP HERE. Links and satellites below will silently
-- insert 0 rows too, since they all depend on hubs already having data.
PRINT '=== STAGE 5: Data Vault links (depend on hubs above) ===';
EXEC vault.usp_Load_Link_IncidenteConductor;
EXEC vault.usp_Load_Link_IncidenteVehiculo;
EXEC vault.usp_Load_Link_IncidentePedido;
GO

PRINT '=== STAGE 6: Data Vault satellites (depend on hubs above) ===';
EXEC vault.usp_Load_Sat_Conductor_Detalle;
EXEC vault.usp_Load_Sat_Incidente_Detalle;
GO

PRINT '=== FINAL CHECKPOINT: everything should now be populated ===';
SELECT 'vault.Link_IncidenteConductor' AS tabla, COUNT(*) AS filas FROM vault.Link_IncidenteConductor
UNION ALL SELECT 'vault.Link_IncidenteVehiculo', COUNT(*) FROM vault.Link_IncidenteVehiculo
UNION ALL SELECT 'vault.Link_IncidentePedido', COUNT(*) FROM vault.Link_IncidentePedido
UNION ALL SELECT 'vault.Sat_Conductor_Detalle', COUNT(*) FROM vault.Sat_Conductor_Detalle
UNION ALL SELECT 'vault.Sat_Incidente_Detalle', COUNT(*) FROM vault.Sat_Incidente_Detalle;
GO
