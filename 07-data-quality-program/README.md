# 07 — Quality Program

Continuous, automated data quality for **TRANSTRACK** (logistics & freight).
This folder turns data quality from a one-time diagnostic into a permanent,
governed program: formal rules with thresholds, an execution engine, historical
results, workload isolation, document lifecycle governance, and automated
traffic-light reporting.

> Governance without measurement does not exist. Everything here exists to make
> quality **measurable, repeatable, and auditable over time**.

---

## Architecture Decision

**Decision:** implement quality as *metadata-driven rules* executed by a *generic
engine*, not as hand-written diagnostic scripts.

- **Rules are data** (`DATA_QUALITY_RULES`). Each rule declares its DAMA
  dimension, target object, a self-contained measurement query, and its
  acceptance thresholds. Adding a rule is an `INSERT`, not a code change.
- **One measurement contract.** Every rule's query returns `records_evaluated`
  and `records_failed`. A single engine (`usp_MeasureRule` + `usp_ExecuteRuleSet`)
  scores every rule the same way and writes to `DATA_QUALITY_RESULTS`.
- **History is immutable.** Results are never deleted; a deactivated rule keeps
  its past results. Thresholds are snapshotted per result so old verdicts stay
  interpretable after rules evolve.
- **Measurement must not harm OLTP.** Resource Governor pins the quality
  workload (notably the ~50M-row telemetry scans) to a capped pool, routed by
  application identity.
- **Documents are records.** Incident attachments get retention, classification,
  a controlled lifecycle, and a no-hard-delete guarantee.

**Why not ad-hoc scripts?** Diagnostic scripts answer "how bad is it today?"
once. A rule registry answers "is it getting better?" forever — which is the
question a governance program must answer.

---

## DAMA Alignment (Ch.13 — Data Quality Management)

| DAMA Ch.13 concept | Implementation in this folder |
|---|---|
| Data quality dimensions | 18 rules across **completeness, accuracy, consistency, timeliness, uniqueness** |
| Rules & thresholds | `DATA_QUALITY_RULES` (per-rule green/yellow cutoffs, severity) |
| Measurement & monitoring | `usp_Measure*` procedures + `DATA_QUALITY_RESULTS` history |
| Data quality reporting | `quality_check.py` traffic-light console + PDF |
| Root-cause / issue evidence | rules flagged `ties_to_folder02_problem` link defects to the business case |

Document lifecycle governance additionally aligns with **DAMA Ch.9 — Document &
Content Management** (retention, records lifecycle, chain of custody).

Reference: DAMA-DMBOK2 — https://www.dama.org/

---

## Data Policies Defined

- **Threshold policy.** Every rule has a formal GREEN cutoff (`threshold_pct`)
  and a YELLOW cutoff (`warning_threshold_pct`); below yellow is RED. Financial
  and uniqueness rules use the strictest cutoffs (critical severity).
- **Retention policy.** Per document type (accident photos and damage reports
  10 years; signatures and insurance claims 7 years), with legal-hold defaults
  for legally sensitive types.
- **Deletion policy.** Incident documents cannot be hard-deleted. Retirement is
  a soft, **authorized, audited** action; legal-hold documents cannot be
  retired at all.
- **Isolation policy.** Quality checks run in a LOW-importance, CPU/memory-capped
  Resource Governor pool so they never degrade transactional workloads.

---

## Technical Evidence

Deliverables are listed in [Files in this folder](#files-in-this-folder) above.

**Baseline run:** full suite, 18 rules, ~4 minutes wall-clock (dominated by the
telemetry accuracy scans). Distribution: **12 GREEN · 2 YELLOW · 3 RED · 1 N/A.**

---

## Before / After (folder-02 defects vs. folder-05 master data)

The baseline is the honest "before": it measures the **real current state**,
where raw source tables still carry the intentional folder-02 defects while the
governed master layer built in folder-05 is already clean. The contrast is the
proof.

| Evidence | Source (before governance) | Governed (after folder-05) |
|---|---|---|
| **Client uniqueness** | `ventas.CLIENTE` by NIT — **89.17%**, **1,625** duplicate rows RED (`DQ-UNQ-001`) | mastered `MASTER_CLIENTE` deduplicated in folder-05 (golden record) |
| **Driver identity** | fragmented across `CONDUCTOR / EMPLEADO / OPERADOR`, no common key | `MASTER_CONDUCTOR` by license — **100%** GREEN (`DQ-UNQ-003`) |
| **Invoice → order** | `facturacion.FACTURA.pedido_id` — **5,000** invoices with no order YELLOW (`DQ-CMP-002`) | remediation tracked as a governed data-quality issue |

**Unplanned findings** (defects the program surfaced that were *not* seeded —
the strongest argument for continuous monitoring):

- `DQ-ACC-001` — **5,000** invoices where `total ≠ subtotal + impuesto` RED (financial integrity).
- `DQ-CON-004` — **25,487** vehicle assignments with `km_fin < km_inicio` RED (operational integrity).
- `DQ-CON-002` — **0 rows evaluable**: `ventas.CLIENTE` and `facturacion.CLIENTE`
  share **no joinable NIT** → N/A is itself a finding — the two modules cannot
  match a client by key, the literal "each module built separately" problem.

The recurring **5,000** across `DQ-ACC-001`, `DQ-CMP-002`, and `DQ-CON-003` is
one defective invoice batch failing three dimensions at once — a single root
cause with a multi-dimension signature.

> The "after" for client dedup is captured by the governed `MASTER_CLIENTE`
> layer; a symmetric rule (`MASTER_CLIENTE` uniqueness) can be added to make the
> before/after fully rule-to-rule.

---

## Azure Equivalent

| This folder (SQL Server) | Azure equivalent |
|---|---|
| `DATA_QUALITY_RULES` + engine | **Microsoft Purview Data Quality** rules & scans (dimension-based, threshold-scored) |
| `DATA_QUALITY_RESULTS` history & trends | Purview DQ scan history / quality score trending |
| Resource Governor isolation | **Azure SQL / Synapse** workload isolation & workload groups |
| `quality_check.py` scheduled run | **Azure Data Factory / Synapse Pipelines** triggering DQ scans; alerting via Azure Monitor |
| `DOCUMENT_REGISTRY` + retention | **Azure Blob Storage lifecycle & immutability policies** + Purview classification |

Purview docs: https://learn.microsoft.com/en-us/purview/

---

## Service Value

What a logistics client pays for in this deliverable:

- **A quantified quality baseline** — a defensible "state of the data" number
  (12/2/3/1) instead of anecdote, produced in minutes and repeatable on demand.
- **Continuous monitoring** that catches defects nobody seeded — here it found
  25,487 impossible odometer readings and a 5,000-invoice financial-integrity
  gap the business did not know about.
- **Regulator-ready evidence** — immutable results history and an auditable,
  no-hard-delete document chain of custody for incident records.
- **Zero OLTP disruption** — quality runs are provably isolated from the
  transactional system, so measurement is safe to run in production.
- **A before/after story** that converts the master-data investment into a
  measurable outcome, not a promise.

---

## Files in this folder

*Technical reference — deployment order 01 → 05, then run the Python report.*

| File | What it is |
|---|---|
| `01_quality_rules.sql` | Rule registry (`DATA_QUALITY_RULES`) — 18 threshold-based rules across the five DAMA dimensions (completeness, accuracy, consistency, timeliness, uniqueness). |
| `02_quality_measurements.sql` | Metadata-driven measurement engine: one stored procedure per dimension plus a suite runner, with per-rule error isolation. |
| `03_quality_results.sql` | Historical results table (`DATA_QUALITY_RESULTS`) and the guarded, automatic folder-02 baseline capture. |
| `04_resource_governor.sql` | Resource Governor pool, workload group and master classifier that isolate quality checks from the OLTP workload. |
| `05_document_registry.sql` | Incident-document governance: retention policy, registry, lifecycle log, no-hard-delete trigger and controlled register/retire/evaluate procedures. |
| `quality_check.py` | Python runner: executes the suite and produces a traffic-light console + PDF report; env-var credentials, structured logging, Resource-Governor-routed connection. |
| `README.md` | This document — architecture decision, DAMA alignment, policies, technical evidence and before/after. |
