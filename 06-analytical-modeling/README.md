# 06 - Analytical Modeling

## Why This Week Matters

Before this folder, TRANSTRACK could not answer two kinds of questions that
actually cost money and carry legal risk:

- **"What tier was this client in when this invoice was issued?"** With no
  historized view of client category, a billing dispute was unwinnable -
  there was no way to prove what rate applied on a past date.
- **"Who was driving during incident #4521, and was their license valid that
  day?"** Reconstructing this manually meant joining three fragmented driver
  tables by hand, with no guarantee of getting the right person.

This folder builds the two models that answer those questions defensibly: a
**Kimball star schema** (`Dim_Cliente` with full SCD2 history) for the first,
and a **Data Vault** (append-only hubs, links, satellites) for the second.

**The validation process itself is part of the deliverable.** Running the
load procedures against real data surfaced a defect where `Fact_Entrega`
loaded all 415,329 expected rows with `conductor_sk` silently `NULL` for
every one of them - a broken join predicate that produced a complete-looking
table with an invisible data quality hole. That is the exact class of defect
that justified this entire project in Week 01: data that looks fine and
isn't, with nobody positioned to catch it. Finding and fixing it here, with
a documented root cause, is the proof that this governance model actually
holds up against real data - not just against a clean demo.

## Files in this folder

| File | Purpose |
|---|---|
| `01_star_schema_dimensions.sql` | Creates `Dim_Cliente` (SCD2), `Dim_Conductor`, `Dim_Vehiculo`, `Dim_Ruta`, `Dim_EstadoEntrega`, and the self-loading `Dim_Tiempo` calendar (2019-2028). |
| `02_star_schema_facts.sql` | Creates `Fact_Pedido`, `Fact_Entrega`, `Fact_Incidente` with grain declarations and foreign keys to the dimensions above. |
| `03_scd2_load_procedure.sql` | Load procedures for every dimension and fact table: the SCD2 pattern for `Dim_Cliente`, Type-1 upserts for the rest, and the point-in-time resolution logic (via `flota.ASIGNACION_VEHICULO`) used by `Fact_Entrega` and `Fact_Incidente`. Includes execution-plan and indexing notes. |
| `04_data_vault_hubs.sql` | Creates `Hub_Conductor`, `Hub_Vehiculo`, `Hub_Pedido`, `Hub_Incidente` with SHA1 hash keys, plus their load procedures. |
| `05_data_vault_links.sql` | Creates `Link_IncidenteConductor`, `Link_IncidenteVehiculo`, `Link_IncidentePedido`, plus their load procedures. |
| `06_data_vault_satellites.sql` | Creates `Sat_Conductor_Detalle` and `Sat_Incidente_Detalle` (append-only historized detail), plus their load procedures. |
| `07_incident_reconstruction.sql` | Legal reconstruction query: given one `incidente_id`, returns the full evidentiary chain - driver (with license status as of the incident date), vehicle, client/order, and a bracketed GPS speed trace. |
| `08_run_data_loads.sql` | Orchestration script: executes every load procedure from files 03-06 in strict dependency order, with a row-count checkpoint after each stage. |
| `09_data_load_healthcheck.sql` | Reusable row-count check across every `dw`/`vault` table - run this after any future load to confirm population, not just structure. |
| `adr_datavault_vs_kimball.md` | Formal ADR: when to use each model, decision criteria applied to TRANSTRACK specifically, and a qualitative TCO comparison. |

## Before / After

**Before:** analytical questions required ad hoc joins across fragmented
OLTP tables, with no historized view of change and no defensible chain of
custody for legal review.

**After:** business trend questions run against a governed star schema with
proper history; legal/audit questions run against an append-only Data Vault
that can reconstruct exact past states.

## The Seven Dimensions

### 1. Technical
Set-based ETL throughout (no cursors, no `WHILE` loops). SCD2 change
detection uses a single `HASHBYTES('MD5', ...)` column (`hash_diff`) instead
of comparing every tracked attribute individually. The point-in-time join
against `flota.ASIGNACION_VEHICULO` resolves driver/vehicle for deliveries
and incidents - and is also where the load-validation defect described above
actually surfaced, which is why that join carries explicit inline comments
on the exact foreign key constraint that determines its correct filter.
Both `dw` and `vault` schemas are physically placed on the `ANALYTICS`
filegroup, isolating analytical I/O from the OLTP workload on `PRIMARY`.

### 2. Architecture
Reference: DAMA-DMBOK Ch.5 (Data Modeling and Design) and Ch.6 (Data Storage
and Operations). Building both a Kimball model and a Data Vault instead of
one compromise model is documented formally in `adr_datavault_vs_kimball.md`.
Dimensions are sourced from governed master data (folder 05), never from the
raw fragmented OLTP tables, so the star schema cannot silently reintroduce
the duplication problem this whole project exists to solve.

### 3. Security
ISO 27001 Annex A.8 (Asset Management) and A.5.12 (Classification of
information) apply: dimensional and vault tables inherit classification from
`governance_control.DATA_CLASSIFICATION` (folder 05) - PII fields like
`Dim_Conductor.email`/`telefono` and `Sat_Conductor_Detalle` license data
carry the same sensitivity as their source, and access should be scoped
through the RLS roles built in folder 05, not re-opened at the analytics
layer.

### 4. GRC
The Data Vault directly serves regulatory/legal discovery requests: given an
incident, a full chain of custody with source attribution (`record_source`
on every hub/link/satellite row) can be produced without reconstructing it
manually. This is the technical backbone for compliance with insurance and
liability documentation requirements typical of freight/logistics operators.
The load-validation process is itself a GRC-relevant fact: defects were
found and root-caused before handoff, not discovered later by a client.

### 5. BCP
Reference: ISO 22301. If the ETL that loads `dw`/`vault` fails or is
delayed, OLTP operations are unaffected - the analytical layer is a
downstream, non-blocking consumer. `vault` schema recovery takes precedence
over `dw` in a disaster scenario, since legal/audit obligations carry harder
deadlines than a delayed BI refresh. Both schemas are covered by the FULL
recovery model established in `00-environment-setup`.

### 6. Azure
- **Kimball star schema** → Azure Synapse Analytics (dedicated SQL pool), or
  Azure Analysis Services / Power BI import mode on top for BI consumption.
- **Data Vault** → also viable in Synapse; the hash-key/append-only pattern
  maps naturally onto Azure Data Factory + a Lakehouse pattern if incident/
  telemetry volume outgrows a single SQL Server instance.
- **Metadata/lineage linking both models back to source** → Microsoft
  Purview, extending the `DATA_LINEAGE` work from folder 08.

### 7. Service
This is the deliverable a logistics client pays a consultant for: two
purpose-built, defensible analytical products, with the reasoning for why
they're separate written down (the ADR) rather than left as tribal
knowledge - and evidence that the pipeline was validated against real data
before handoff, not delivered as untested DDL.

## Architectural Conclusion

Splitting the analytical layer into a Kimball model and a Data Vault is
recognition that "answer a business question" and "produce legal evidence"
are different problems with different correctness requirements. Feeding
both from the same governed master data (folder 05) ensures neither model
can regress into the duplicate-client, fragmented-driver problems that
motivated this project in the first place - and the defect found while
validating the load sequence is the concrete proof that this discipline has
to survive first contact with real data, not just look good on paper.
