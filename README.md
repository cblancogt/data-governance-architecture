# Data Governance Architecture

Governance framework for a high-volume logistics company — 800 trucks, 1,200 drivers, 15,000 clients, 50M GPS records — that grew six years without formal data ownership, classification, or quality controls.

Core problems: duplicated clients with no single source of truth, driver identity fragmented across three tables without shared key, orphan invoices, and 50M telemetry records with no retention policy.

This project diagnoses the gap, quantifies the business impact (~$1M/year exposure), and builds the governance framework to resolve it.

## Repository Structure

```
data-governance-architecture/
├── README.md
├── requirements.txt
├── .gitignore
├── 00-environment-setup/
└── 01-dba-and-architect-perspective/
```

## Technical Stack

| Component | Version / Detail |
|---|---|
| SQL Server | 2022 Developer Edition |
| Collation | SQL\_Latin1\_General\_CP1\_CI\_AS |
| Recovery Model | FULL |
| Python | 3.11 + pyodbc |

## Data Profile

| Entity | Volume | Known Issues |
|---|---|---|
| CLIENTE | 15,000 | Duplicates by NIT with divergent names and addresses |
| CONDUCTOR / EMPLEADO / OPERADOR | 1,200 | Same person across three tables, no shared key |
| VEHICULO | 800 | — |
| PEDIDO | 500,000 | — |
| RUTA | 2,500 | — |
| ENTREGA | 480,000 | — |
| FACTURA | 490,000 | Orphan invoices without source orders, duplicates |
| INCIDENTE | 8,500 | — |
| TELEMETRIA\_GPS | 50,000,000 | No partition, no retention policy, no formal link to orders |
| CONTRATO\_CLIENTE | 12,000 | — |

## Key Findings

The company cannot answer how many unique clients it has. Driver identity cannot be resolved across operational, HR, and dispatch systems for legal investigations. No column in any table is classified as PII, financial, or operational. GPS telemetry has no retention strategy — five years of data at 50 million rows with no archival plan.

Conservative annual exposure estimate: **~$1M/year** before regulatory risk.

## Framework References

| Framework | Application |
|---|---|
| DAMA-DMBOK2 | Governance model, maturity assessment |
| ISO 27001 | Data classification and access control |
| ISO 22301 | Business continuity for data assets |

---

<div align="center">

**Carlos Blanco** · Data Base Administration & Data Architecture

[![GitHub](https://img.shields.io/badge/GitHub-cblancogt-181717?logo=github)](https://github.com/cblancogt)

*P02 — Data Governance Architecture*

</div>