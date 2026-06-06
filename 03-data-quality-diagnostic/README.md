# 03: Data Quality Diagnostic

**Project:** P02 - Data Governance Architecture  
**Repository:** `data-governance-architecture/03-data-quality-diagnostic/`  
**Author:** cblancogt  

---

## Executive Report - Data Quality Diagnostic

---

### Diagnostic Summary Table

| # | Problem | Tables | Key Finding | Risk |
|---|---------|--------|-------------|------|
| 1 | **Two separate CLIENT tables** with no link | `ventas.CLIENTE` ↔ `facturacion.CLIENTE` | Same NIT recorded independently in Sales and Billing. Credit limits assessed per-record, not per legal entity. Double credit exposure. | CRITICAL |
| 2 | **Driver identity split across 3 tables** | `flota.CONDUCTOR`, `flota.EMPLEADO`, `flota.OPERADOR` | No shared key. CONDUCTOR has license, EMPLEADO has DPI, OPERADOR has free-text plate. `INCIDENTE` has no conductor column at all. | CRITICAL |
| 3 | **Orphan billing records** | `facturacion.FACTURA`, `operaciones.PEDIDO`, `operaciones.ENTREGA` | `FACTURA.pedido_id` is nullable - invoices bypass FK. Deliveries confirmed with no invoice. | HIGH |
| 4 | **Telemetry disconnected from operations** | `flota.TELEMETRIA_GPS`, `flota.ASIGNACION_VEHICULO` | No `pedido_id` or `conductor_id` in GPS table. Linkage requires date-range join through ASIGNACION with no supporting index. | HIGH |

---

### Finding 1: Two Client Tables, No Reconciliation

The most fundamental structural problem is that a "client" is two different things depending on which module you're in:

- **`ventas.CLIENTE`** - the Sales module's view. Has `nit`, `nombre`, `categoria`. Referenced by `operaciones.PEDIDO`.
- **`facturacion.CLIENTE`** - the Billing module's view. Has `nit_cliente`, `razon_social`, `limite_credito`. Referenced by `facturacion.FACTURA`.

These tables share no foreign key. A client with NIT=12345 can exist in both tables with conflicting names, emails, and credit limits - with no system mechanism to detect or resolve the conflict.

**This Company cannot answer:** "What is the total credit exposure for client X?" - because client X has two independent credit limits in two unlinked tables.

**Script:** `01_duplicate_clients.sql` - Sections 1 and 2

---

### Finding 2: Driver Identity Requires Three Tables and Probabilistic Matching

A truck driver appears in three separate tables built by three separate teams:

```
flota.CONDUCTOR  > numero_licencia, nombre, apellido    (Operations module)
flota.EMPLEADO   > dpi, nombres, apellidos, salario     (HR module)
flota.OPERADOR   > nombre_completo, vehiculo_asignado   (GPS module)
```

The name columns don't even have the same structure - CONDUCTOR splits `nombre` and `apellido`, EMPLEADO splits `nombres` and `apellidos`, OPERADOR uses `nombre_completo` as a single field. Matching across tables requires SOUNDEX and DIFFERENCE() - which is probabilistic, not definitive.

**The legal consequence is in the INCIDENTE table:** `operaciones.INCIDENTE` has a `pedido_id` but **no `conductor_id`**. The only path to identify a driver in an incident is:

```
INCIDENTE > PEDIDO > ASIGNACION_VEHICULO > CONDUCTOR > (SOUNDEX match) > EMPLEADO (DPI)
```

If any link in that chain is missing - and missing links are common - the driver is legally unidentifiable.

**Script:** `02_fragmented_drivers.sql` - Section 5 (traceability chain)

---

### Finding 3: Nullable `pedido_id` Breaks Billing Integrity

`facturacion.FACTURA.pedido_id` is `NULL`-able by design. A foreign key on a nullable column in SQL Server does not enforce referential integrity when the value is NULL - NULL bypasses the FK check.

This means:
- Invoices can be created with no associated order (Type A orphans)
- The same pedido can appear on two FACTURA records (no UNIQUE constraint on `pedido_id`)
- Delivered orders may have no invoice (revenue leakage - Type C)

**SAT audit exposure:** Under Guatemala's Decreto 27-92 (IVA Law), every invoice must document the commercial activity it represents. A FACTURA with NULL `pedido_id` has no documentary evidence of the transaction.

**Script:** `03_orphan_records.sql`

---

### Finding 4: Telemetry Is an Isolated Island

`flota.TELEMETRIA_GPS` contains 50 million GPS records. It has:
- `vehiculo_id` (INT) - but **no foreign key** to `flota.VEHICULO`
- No `pedido_id` column
- No `conductor_id` column

Linking a GPS point to an order requires a date-range overlap join through `flota.ASIGNACION_VEHICULO`. This join has no supporting index and produces a full table scan on 50M rows if not carefully filtered.

**Script:** `04_telemetry_gaps.sql` - Section 2 and 3

---
## Architectural Conclusion - 7 Dimensions

### TECHNICAL
7 diagnostic scripts executed against real schema. Query Store enabled with pre/post wait stats capture. 
SOUNDEX, anti-join patterns, and OUTER APPLY used across 5 domains.

### ARCHITECTURE - DAMA DMBOK Ch. 13
| Dimension | Evidence |
|-----------|---------|
| **Uniqueness** | Same NIT in two unlinked client tables |
| **Consistency** | Nullable `pedido_id` breaks billing chain; driver name format differs across 3 tables |
| **Completeness** | `INCIDENTE` has no conductor column; `TELEMETRIA_GPS` has no `pedido_id` |
| **Accuracy** | Financial figures untrustworthy without cross-module reconciliation |

### SECURITY - ISO 27001
- **A.18.1.3:** Invoices with NULL `pedido_id` have no verifiable origin - records integrity failure.
- **A.9.4.1:** Driver PII scattered across 3 tables with no access policy or classification.
- **A.12.4.1:** Unregistered `vehiculo_id` values in telemetry = unattributed activity in a safety-critical system.

### GRC
- **SAT Decreto 27-92:** 5,000 invoices with no commercial origin - direct audit exposure.
- **Ley de Tránsito + Código de Comercio:** Broken `INCIDENTE→CONDUCTOR` chain = institutional liability by default.
- **NIIF 15:** Delivered-but-uninvoiced orders distort revenue recognition.

### BCP - ISO 22301
- No conductor column in `INCIDENTE` = legal defense capability depends on a 4-table join chain.
- No FK in `TELEMETRIA_GPS` = GPS data has no evidentiary value if `vehiculo_id` is unregistered.
- Two `CLIENTE` tables = no canonical reference if either is corrupted.

### CLOUD
| On-Premises | Azure Equivalent |
|-------------|-----------------|
| SOUNDEX fuzzy matching | Azure AI Search |
| Nullable FK gaps | Azure Purview Data Quality |
| Missing index DMVs | Azure SQL Automatic Tuning |
| Wait stats delta | Azure SQL Intelligent Insights |
| Unpartitioned telemetry | Azure Synapse Analytics |
| Manual lineage chain | Azure Purview Data Lineage |

### SERVICE VALUE
---
This diagnostic gives the company its first quantified view of data fragmentation - specific numbers per problem, per domain, and per regulatory risk. Decision makers can now prioritize remediation based on financial exposure rather than assumptions.
---

## Files

| File  | Purpose |
|------|--------|
| `01_duplicate_clients.sql` | NIT duplicates across ventas + facturacion CLIENTE tables |
| `02_fragmented_drivers.sql` | 3-table driver identity analysis + INCIDENTE traceability chain |
| `03_orphan_records.sql` | Type A/B/C orphan records + duplicate invoices |
| `04_telemetry_gaps.sql` | Ghost vehicles, dark windows, assignment gap analysis |
| `05_business_impact.sql` | Financial exposure quantification per governance failure |
| `README.md` | This file |

---
<div align="center">

**Carlos Blanco** · Data Base Administration & Data Architecture

[![GitHub](https://img.shields.io/badge/GitHub-cblancogt-181717?logo=github)](https://github.com/cblancogt)

*P02 - Data Governance Architecture*

</div>