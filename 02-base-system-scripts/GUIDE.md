# 02 - Base System with Real Volume

## Database
SQL Server 2022 | SISTEM HIGHT TRANSACTIONS | Collation: SQL_Latin1_General_CP1_CI_AS | Recovery: FULL

## Volume
| Table | Records | Size |
|---|---|---|
| flota.TELEMETRIA_GPS | 15,000,000 | 1.5 GB |
| operaciones.PEDIDO | 500,000 | 99 MB |
| facturacion.FACTURA | 488,595 | 79 MB |
| operaciones.ENTREGA | 480,000 | 38 MB |
| facturacion.DETALLE_FACTURA | 488,595 | 37 MB |
| flota.ASIGNACION_VEHICULO | 195,340 | 17 MB |
| ventas.CLIENTE | 15,000 | 3 MB |
| facturacion.CLIENTE | 12,000 | 2 MB |
| ventas.CONTRATO_CLIENTE | 12,000 | — |
| operaciones.RUTA | 2,388 | — |
| operaciones.INCIDENTE | 8,473 | — |
| flota.CONDUCTOR | 1,200 | — |
| flota.EMPLEADO | 1,100 | — |
| flota.OPERADOR | 950 | — |
| flota.VEHICULO | 800 | — |

## Scripts
| File | Description |
|---|---|
| 01_schemas.sql | Domain schemas: ventas, facturacion, operaciones, flota, archivo |
| 02_tables_customers.sql | ventas.CLIENTE, facturacion.CLIENTE, CONTRATO_CLIENTE |
| 03_tables_operations.sql | RUTA, PEDIDO, ENTREGA, INCIDENTE |
| 04_tables_fleet.sql | VEHICULO, CONDUCTOR, EMPLEADO, OPERADOR, ASIGNACION_VEHICULO, TELEMETRIA_GPS |
| 05_tables_billing.sql | FACTURA, DETALLE_FACTURA |
| 06_indexes.sql | Base indexes |
| 07_load_routes_vehicles.sql | RUTA — VEHICULO |
| 08_load_drivers.sql | CONDUCTOR — EMPLEADO — OPERADOR |
| 09_load_customers.sql | ventas.CLIENTE — facturacion.CLIENTE |
| 10_load_contracts_orders.sql | CONTRATO_CLIENTE — PEDIDO |
| 11_load_deliveries_incidents.sql | ENTREGA — INCIDENTE |
| 12_load_invoices.sql | FACTURA — DETALLE_FACTURA |
| 13_load_assignments.sql | ASIGNACION_VEHICULO |
| 14_load_telemetry.sql | TELEMETRIA_GPS |
| 15_volume_stats.sql | Row counts and disk size verification |

---

<div align="center">

**Carlos Blanco** · Data Base Administration & Data Architecture

[![GitHub](https://img.shields.io/badge/GitHub-cblancogt-181717?logo=github)](https://github.com/cblancogt)

*P02 — Data Governance Architecture*

</div>