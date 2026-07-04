# Master and Reference Data

**Project:** P02 · Data Governance Architecture  
**System:** TRANSTRACK - Freight Logistics  
**Repository:** `data-governance-architecture`  
**Author:** cblancogt

> Script descriptions and execution order are documented at the bottom of this file.

---

## The Business Problem This Module Solves

| Failure | Evidence | Business Cost |
|---|---|---|
| 1,200 drivers fragmented across 3 tables (CONDUCTOR, EMPLEADO, OPERADOR) with no common key. Same person registered independently in HR, payroll and dispatch with no link between them. | `SELECT COUNT(*) FROM flota.CONDUCTOR` returns 1,200. `flota.OPERADOR` returns 950. They overlap but are not linked. Zero cross-table identifier exists. | Cannot answer "who drove vehicle V-114 during incident #8221?" Legal liability: unquantifiable. One freight robbery case = $500K+ exposure. |
| 15,000 client records in ventas with intentional duplicates (up to 8 per NIT). Facturacion uses a completely different NIT format with zero cross-module matches. | `SELECT COUNT(DISTINCT nit) FROM ventas.CLIENTE` returns 1,875 unique NITs from 15,000 rows. `facturacion.CLIENTE` uses plain integers while ventas uses `NIT-XXXXXX` format. | Duplicate billing risk ~$280K/quarter. Cannot report true customer count to investors. Invoices may reference the wrong legal entity. |
| Free-text reference values: incident types with 47 spellings for 6 actual categories, order statuses without defined transitions, client categories as uncontrolled free text. | `SELECT DISTINCT tipo_incidente FROM operaciones.INCIDENTE` returns noise instead of a clean controlled list. | KPI reports are unreliable. SLA calculations cannot be automated. Regulatory audit fails. |

---

## Architecture Decision

**Decision:** Implement a hub-and-spoke Master Data Management (MDM) pattern using SQL Server as the master data store, with `governance_control.MASTER_CONDUCTOR` and `governance_control.MASTER_CLIENTE` as the authoritative golden records.

**Why not MDS for everything?**  
SQL Server Master Data Services (MDS) is ideal for ongoing stewardship workflows and will be configured for the Conductor entity in the next module. The SQL-native layer is built first because: (1) it runs entirely within the existing SQL Server instance with no additional infrastructure, (2) it produces the crosswalk and audit tables needed by every downstream component (Data Vault, Quality checks), and (3) it establishes the data model before MDS entity configuration.

**Survivorship rules are explicit business decisions, not technical defaults:**
- License data winner: `flota.CONDUCTOR` (HR system has authoritative license records)
- Personal data winner: `flota.CONDUCTOR` (employment system of record)
- Employment/DPI winner: `flota.EMPLEADO` (payroll has authoritative fiscal identifiers)
- Driver matching key: sequential number extracted from `LIC-000001`, `EMP-000001`, `OPR-000001` — the only reliable cross-table identifier in this dataset
- Client deduplication: `ROW_NUMBER()` partitioned by NIT sequence, ordered by `activo DESC, fecha_registro DESC`

**Reference data uses CODE + DESCRIPTION pattern.** Codes match exactly the CHECK constraint values already defined in the module 02 source tables, ensuring backward compatibility while adding governance metadata, SLAs and change control.

---

## Regulatory Reference: DAMA

**Chapter 10 - Reference and Master Data Management**

| DAMA Concept | TRANSTRACK Implementation |
|---|---|
| 10.2.1 Reference Data | `governance_control.REF_DATA_REGISTRY` + `ref.*` schema tables |
| 10.2.2 Master Data | `governance_control.MASTER_CONDUCTOR`, `governance_control.MASTER_CLIENTE` |
| 10.3.1 Survivorship Rules | Explicit priority weights per source system in `02_driver_consolidation.sql` |
| 10.3.2 Golden Record | Single authoritative row per entity with `conductor_hash_key` / `client_hash_key` |
| 10.3.3 Crosswalk / Reconciliation | `governance_control.CONDUCTOR_CROSSWALK`, `governance_control.CLIENTE_CROSSWALK` |
| 10.4 Party Data (Customer MDM) | `governance_control.MASTER_CLIENTE` with NIT sequence as normalized business key |
| 10.5 Change Control | `governance_control.REF_DATA_VERSION_LOG` — every reference data change is approved and logged |

---

## Security: ISO 27001 Application

| Control | Implementation |
|---|---|
| **A.8.1 - Information Assets** | `governance_control.REF_DATA_REGISTRY` registers every reference table as a formal asset with owner and review schedule |
| **A.5.34 - Privacy** | `DATA_SHARING_AGREEMENT` documents legal basis for PII flows (NIT, personal driver data) between domains |
| **A.8.3 - Information Transfer** | DSAs define permitted/prohibited uses, retention periods, and breach notification timelines |
| **A.8.32 - Change Management** | `governance_control.REF_DATA_VERSION_LOG` ensures no reference value changes without approval and audit trail |

The `06_golden_record_validation.py` script reads credentials from environment variables only (`.env` file, gitignored). No credentials in code.

---

## GRC: Governance, Risk, and Compliance

**Risk eliminated by this module:** TRANSTRACK could not produce a driver roster for a regulatory audit. All three source tables (`flota.CONDUCTOR`, `flota.EMPLEADO`, `flota.OPERADOR`) returned different counts, different names, and different statuses for the same individuals.

**Post-implementation compliance posture:**
- Transport regulators can now query `SELECT * FROM governance_control.MASTER_CONDUCTOR WHERE licencia_vigente = 1` and receive a single, authoritative, auditable list of 1,200 unique licensed drivers
- Every merge decision in `MASTER_CLIENT_AUDIT` is defensible in billing disputes, with timestamp, confidence score and match method recorded
- Data Sharing Agreements document who is accountable when cross-domain data quality fails

**Open violations registered in `governance_control.DSA_VIOLATION_LOG`:**
1. `DSA-OPS-BILL-001`: Orphaned invoices in `facturacion.FACTURA` — `pedido_id` nullable with no prevention logic. Status: **OPEN**
2. `DSA-FLEET-OPS-001`: `flota.TELEMETRIA_GPS` has 0% order context — 50M GPS records with no `pedido_id`. Status: **OPEN**, resolved in Data Vault component
3. `DSA-VENTAS-FACT-001`: NIT format incompatibility between modules confirmed — 0 cross-module matches from 27,000 combined records. Status: **IN_PROGRESS**

---

## BCP: ISO 22301 Considerations

**What happens if `governance_control.MASTER_CONDUCTOR` is unavailable?**

The master data layer is additive — source tables (`flota.CONDUCTOR`, `flota.EMPLEADO`, `flota.OPERADOR`) remain intact. Operations can continue using fragmented source data in degraded mode. The crosswalk tables allow reconstruction of the master layer from sources in approximately 2 hours.

**Backup strategy:** Master data tables are in the PRIMARY filegroup under FULL recovery model. Transaction log backups every 15 minutes protect all merge decisions.

**RPO/RTO for master data:** RPO = 15 minutes (log backup interval). RTO = 2 hours (crosswalk reconstruction from sources if master tables are lost).

---

## Data Policies Defined

1. **MDM-POL-001:** Every physical person who operates a TRANSTRACK vehicle must have exactly one record in `governance_control.MASTER_CONDUCTOR`. Duplicate creation in any source system triggers a merge candidate workflow.

2. **MDM-POL-002:** NIT is the immutable business key for clients. The same NIT may never produce two active master records. Steward approval required before deactivating a master client record.

3. **REF-POL-001:** Reference data values are not edited directly. All changes go through the version control process documented in `governance_control.REF_DATA_VERSION_LOG`. STATIC tables require CTO approval.

4. **LIN-POL-001:** Every cross-domain data flow must be documented in `governance_control.DATA_LINEAGE` before it goes live. Undocumented flows discovered in production are registered as DSA violations.

5. **DSA-POL-001:** Consumer domains may not use data beyond the permitted uses defined in their DSA. Violation discovery triggers immediate escalation to the Data Governance Lead.

---

## Technical Evidence

**Before this module:**
```sql
-- Cannot answer: how many unique drivers does TRANSTRACK have?
SELECT COUNT(*) FROM flota.CONDUCTOR                              -- Returns: 1,200
SELECT COUNT(*) FROM flota.EMPLEADO WHERE cargo = 'CONDUCTOR'    -- Returns: 660
SELECT COUNT(*) FROM flota.OPERADOR                              -- Returns: 950
-- Three different answers. All wrong. None authoritative.

-- Cannot answer: how many unique clients?
SELECT COUNT(*) FROM ventas.CLIENTE                              -- Returns: 15,000 (with duplicates)
SELECT COUNT(DISTINCT nit) FROM ventas.CLIENTE                   -- Returns: ~1,875 unique NITs
SELECT COUNT(*) FROM facturacion.CLIENTE                         -- Returns: 12,000
-- NIT formats incompatible. Zero cross-module matches confirmed.
```

**After this module:**
```sql
-- Single authoritative answer for drivers:
SELECT COUNT(*) FROM governance_control.MASTER_CONDUCTOR
-- Returns: 1,200 unique drivers, one per seq_key, crosswalk to all three source tables

-- Answer the legal question from incident #8221:
SELECT mc.nombre_completo, mc.numero_licencia, mc.categoria_licencia
FROM governance_control.MASTER_CONDUCTOR mc
JOIN governance_control.CONDUCTOR_CROSSWALK cw
    ON cw.master_conductor_id = mc.master_conductor_id
WHERE cw.source_system = 'CONDUCTOR'
  AND cw.source_pk = (
        SELECT conductor_id FROM flota.ASIGNACION_VEHICULO
        WHERE vehiculo_id = 114
          AND fecha_inicio <= '2023-08-15'
  )
-- Now answerable. Before this module: impossible.

-- Single authoritative answer for clients:
SELECT COUNT(*) FROM governance_control.MASTER_CLIENTE
-- Returns: ~1,875 unique clients after deduplication of 15,000 ventas records
-- Plus billing-only clients from facturacion with no ventas counterpart (flagged)
```

---

## Script Reference

Scripts must be executed in the order listed. Each script is idempotent — it drops and recreates its objects on every run.

**`00_validate_environment.sql`**  
Validation script. Run before and after executing the other scripts to verify object existence, row counts and constraint integrity. Does not create or modify any data. Safe to run at any time.

**`01_reference_data_registry.sql`**  
Creates the `ref` schema and five reference tables: `TIPO_INCIDENTE`, `ESTADO_PEDIDO`, `CATEGORIA_CLIENTE`, `TIPO_VEHICULO`, `ESTADO_ENTREGA`. Each table uses a stable CODE column that matches the CHECK constraint values already in the source tables. Creates `governance_control.REF_DATA_REGISTRY` as the formal catalog of all reference tables, and `governance_control.REF_DATA_VERSION_LOG` for change control. Creates view `governance_control.vw_ref_data_health`.

**`02_driver_consolidation.sql`**  
Consolidates `flota.CONDUCTOR` (1,200 rows), `flota.EMPLEADO` (660 driver rows) and `flota.OPERADOR` (950 rows) into a single golden record per driver in `governance_control.MASTER_CONDUCTOR`. Match key: sequential number extracted from business keys (`LIC-000001`, `EMP-000001`, `OPR-000001`). Survivorship: CONDUCTOR wins for license and personal data, EMPLEADO enriches with DPI and hire date, OPERADOR adds email. Creates `governance_control.CONDUCTOR_CROSSWALK` mapping every source record to its master. Expected result: 1,200 unique master records, 0% needing review.

**`03_client_deduplication.sql`**  
Deduplicates `ventas.CLIENTE` (15,000 rows, up to 8 duplicates per NIT) and consolidates with `facturacion.CLIENTE` (12,000 rows). Deduplication within ventas uses `ROW_NUMBER()` partitioned by NIT sequence, keeping the active and most recent record. Cross-module enrichment via numeric sequence extracted from both NIT formats (`NIT-000001` and plain integer `1`). Creates `governance_control.MASTER_CLIENTE`, `governance_control.CLIENTE_CROSSWALK` and `governance_control.MASTER_CLIENT_AUDIT`. Every merge decision is documented with match type, confidence score and decision method.

**`04_data_lineage.sql`**  
Documents five critical cross-module data flows in `governance_control.DATA_LINEAGE`: ventas to operations (orders), operations to billing (invoice generation), GPS telemetry to orders (the missing link), fragmented driver tables to master, and dual client tables to master. Each flow captures source/destination schemas, transformation type, frequency, classification and known issues. Creates `governance_control.DATA_LINEAGE_EXECUTION` for operational tracking, view `governance_control.vw_lineage_impact_map` and procedure `governance_control.usp_get_downstream_impact`.

**`05_sharing_agreements.sql`**  
Creates four formal Data Sharing Agreements in `governance_control.DATA_SHARING_AGREEMENT`: `DSA-OPS-BILL-001` (operations to billing), `DSA-FLEET-OPS-001` (telemetry to operations), `DSA-VENTAS-FACT-001` (sales to billing client sync) and `DSA-FLOTA-GOV-001` (fleet driver tables to governance master). Each DSA defines permitted and prohibited uses, SLA thresholds, retention periods and breach notification timelines. Creates `governance_control.DSA_VIOLATION_LOG` with three pre-loaded violations documenting the governance failures found during diagnostic. Creates view `governance_control.vw_dsa_compliance_summary`.

**`06_golden_record_validation.py`**  
Python validation script that connects to TRANSTRACK via pyodbc (credentials from `.env` file, never hardcoded) and runs 12 automated checks across `MASTER_CONDUCTOR` and `MASTER_CLIENTE`. Checks include: no duplicate business keys in master, crosswalk coverage for all source records, flagged record percentage within expected thresholds, active DSA count, and violation documentation completeness. Generates a self-contained HTML report with traffic-light status (green/yellow/red) per check and a before/after summary. Run after all SQL scripts complete.

---

## Architectural Conclusion

TRANSTRACK had three incompatible versions of its drivers and two incompatible versions of its clients. This module turns that chaos into a single authoritative record per entity — with documented survivorship rules defining which source wins on conflict, full traceability of every merge decision, and formal agreements establishing who is accountable when data crosses module boundaries. The problems left open (telemetry with no link to orders, orphaned invoices) are no longer "known issues" — they are registered violations with an owner and a resolution target.

TRANSTRACK now has a single authoritative answer for driver and client identity — auditable, defensible, and traceable to every source record.

---

**References:**
- DAMA-DMBOK2, Chapter 10: https://www.dama.org/cpages/body-of-knowledge
- ISO 27001:2022, A.8.1, A.5.34, A.8.3: https://www.iso.org/standard/82875.html
- SQL Server Master Data Services: https://learn.microsoft.com/en-us/sql/master-data-services/
- Azure Purview (Microsoft Purview): https://learn.microsoft.com/en-us/purview/
- SOUNDEX (T-SQL): https://learn.microsoft.com/en-us/sql/t-sql/functions/soundex-transact-sql

---
<div align="center">

**Carlos Blanco** · Data Base Administration - Data Architecture · Architecture Solutions

[![GitHub](https://img.shields.io/badge/GitHub-cblancogt-181717?logo=github)](https://github.com/cblancogt)

*P02 - Data Governance Architecture*

</div>
