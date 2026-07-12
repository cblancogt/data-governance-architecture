# ADR-06: Data Vault vs Kimball Star Schema for TRANSTRACK Analytical Modeling

**Status:** Accepted
**Date:** 2026-07
**Author:** cblancogt
**Project:** P02 - Data Governance Architecture

## Context

TRANSTRACK needs to answer two categories of questions that are structurally
different, not just different in scope:

1. **Business/trend questions** - "What's our on-time delivery rate by route
   this quarter?", "How has this client's tier evolved and what did that do
   to their rate?" These need fast aggregation, are read by BI tools, and
   tolerate a curated, business-defined grain.

2. **Legal/audit questions** - "For incident #4521, produce every fact known
   about the driver, vehicle, order, and GPS trace, with a defensible source
   trail." These need full history of every raw attribute, immutability, and
   traceability to the exact source record - not a business-curated summary.

Building one model to serve both forces a compromise that serves neither
well. A star schema wide enough for legal-grade audit becomes unusable for
BI (too many slowly-changing dimensions, unclear "current" state). A Data
Vault flattened for BI convenience loses the very append-only guarantees
that make it defensible as evidence.

## Decision

Build **both**, deliberately, as separate consumption-layer models fed by the
same governed source (folder 05's golden records):

- **Kimball star schema** (`dw` schema): `Dim_Cliente` (SCD2 on `categoria`),
  `Dim_Conductor`, `Dim_Vehiculo`, `Dim_Ruta`, `Dim_Tiempo`,
  `Dim_EstadoEntrega`, `Fact_Pedido`, `Fact_Entrega`, `Fact_Incidente`.
- **Data Vault 2.0** (`vault` schema): `Hub_Conductor`, `Hub_Vehiculo`,
  `Hub_Pedido`, `Hub_Incidente`, three links, and two satellites
  (`Sat_Conductor_Detalle`, `Sat_Incidente_Detalle`).

## Decision Criteria (applied to TRANSTRACK specifically)

| Criterion | Star Schema (Kimball) | Data Vault |
|---|---|---|
| Query pattern | Aggregate/trend, BI tool consumption | Point lookup, full reconstruction |
| History granularity | Only business-relevant attributes (client tier) | Every attribute, every load |
| Mutability | Type-1 dims overwritten; only Dim_Cliente is Type-2 | Fully append-only, nothing ever overwritten |
| Load complexity | Moderate (MERGE + hash-diff) | Higher (hash keys, satellite versioning) |
| Query complexity for end users | Low (star join, BI-tool friendly) | High (multi-hop hub/link/satellite joins) |
| Legal defensibility | Not designed for it | Designed for it |
| Parallel/multi-source loading | Not a design goal here (single governed source) | Native strength, relevant if TRANSTRACK acquires another carrier's system later |

## Why Not Just One

- **Star schema alone** would require Type-2 tracking on every attribute of
  every dimension to be audit-safe, which destroys BI usability (a `Dim_Conductor`
  with 20 SCD2 attributes has dozens of open/closed rows per driver and no
  clean "give me the current roster" query).
- **Data Vault alone** would require every BI/reporting consumer to write
  multi-hop joins through hubs, links, and point-in-time satellite lookups
  for even a simple "orders by month" chart - unnecessary friction for the
  90% of TRANSTRACK's actual reporting need.

## TCO Comparison (qualitative, order-of-magnitude for a 16GB dev machine)

| Factor | Star Schema | Data Vault |
|---|---|---|
| Storage growth | Lower - only tracked attributes are versioned | Higher - every load can insert a new satellite row even for cosmetic changes |
| ETL development cost | Lower - one well-known MERGE/SCD2 pattern | Higher - hash key strategy, multiple link resolution queries |
| Query development cost (BI) | Low | High without a virtualized star-schema layer on top of the Vault |
| Audit/legal readiness cost if built later | High (retrofitting history is lossy - past states are gone) | N/A - built in from day one |

**Conclusion for TRANSTRACK:** the incremental cost of maintaining both
models is justified because the legal exposure from incidents (8,500 records,
insurance and liability implications) makes retrofitting history after the
fact a real risk, while the BI need is real and immediate enough that it
can't wait for Vault-only reporting maturity.

## Consequences

- Two load pipelines must be kept in sync with the same governed source
  (`governance_control.MASTER_CLIENTE` / `MASTER_CONDUCTOR`); a schema
  change there means updating both `03_scd2_load_procedure.sql` and
  `04_data_vault_hubs.sql` / `06_data_vault_satellites.sql`.
- `Hub_Incidente`'s business key is a known limitation: `operaciones.INCIDENTE`
  has no independent business/report number, so `incidente_id` is used as
  the business key. A production remediation would be to require the source
  system to issue a formal incident report number.
- Analysts should be pointed to the star schema by default; the Data Vault
  is a specialist tool for legal/audit teams, not a general reporting surface.

## References

- Kimball, R. & Ross, M. - *The Data Warehouse Toolkit*, 3rd ed.
- Linstedt, D. & Olschimke, M. - *Building a Scalable Data Warehouse with Data Vault 2.0*
- DAMA International - *DAMA-DMBOK: Data Management Body of Knowledge*, 2nd ed., Ch.5 (Data Modeling and Design), Ch.6 (Data Storage and Operations)
