# Data Governance Operating Model - TRANSTRACK

**Version:** 1.1
**Status:** Approved  
**Owner:** Chief Data Officer (define Owner) 
**Reference:** DAMA-DMBOK 2nd Edition, Chapter 3 - Data Governance  
**Last Updated:** 2025-09-21
**Note:** This template is designed for TRANSTRACK (a laboratory company) but can be used in your company by adjusting the data domain.

---

## 1. Purpose

This document defines the formal Data Governance operating model for TRANSTRACK. It establishes who has authority over data decisions, how those decisions are made, and how conflicts are resolved.

The diagnostic phase of this project (03-data-quality-diagnostic) demonstrated that the absence of a governance operating model produced measurable damage: 15,000 client records contain unresolvable duplicates, driver identity is fragmented across three tables with no common key, and invoices cannot be reliably tied to source orders. These failures are organizational - not technical.
They occurred because no structure existed to answer the fundamental question: *who decides?*

---

## 2. Governance Model Selection

### 2.1 Model Evaluated

Operating model archetypes:

| Model | Description | Risk |
|---|---|---|
| **Centralized** | One enterprise data team makes all decisions | Bottleneck; too slow for operational business |
| **Federated** | Each business unit governs its own data independently | Produces the exact fragmentation this Company already has |
| **Hybrid** | Central authority defines standards; domains apply them locally | Balances consistency with operational speed |

### 2.2 Model Selected: **Hybrid (Center-Led)**

This Company Adopted a **hybrid center-led model** for the following reasons:

1. The company already operates three functionally distinct units (Sales/Billing, Operations, Fleet).
   These units have different rhythms, regulatory exposures, and data ownership needs.
2. A purely centralized model would require a data governance team with authority over operational decisions that business units are better positioned to make daily.
3. A purely federated model already failed - it produced the duplicates, fragmentation, and orphaned records documented in the diagnostic phase.
4. The hybrid model allows the Data Governance Council (central) to define standards, policies, and resolution mechanisms while Domain Owners apply them within their areas.

---

## 3. Governance Structure

### 3.1 Data Governance Council (Central Authority)

The Data Governance Council (DGC) is the highest decision-making body for data.

**Composition:**
- Chief Data Officer (CDO) - Chair
- Chief Information Security Officer (CISO)
- Chief Financial Officer (CFO) - for financial data disputes
- VP Operations
- Data Architecture Lead

**Responsibilities:**
- Approve enterprise-wide data policies
- Resolve cross-domain conflicts (see Section 6)
- Approve changes to classification levels
- Set data quality thresholds
- Review governance maturity quarterly

**Meeting cadence:** Monthly for standard governance; emergency session within 48 hours for
data breach or regulatory inquiry.

---

## 4. Data Domains

### Domain 1: CLIENTES

**Tables:** CLIENTE, CONTRATO_CLIENTE, FACTURA

**Business rationale:** These three entities form the commercial relationship lifecycle of TRANSTRACK. A client exists, signs a contract that defines tariffs and conditions, and generates invoices through fulfilled orders. They are governed together because a compliance or quality failure in one directly impacts the integrity of the others.

| Role | Position | Responsibilities |
|---|---|---|
| **Data Owner** | VP Commercial / Head of Sales | Approves schema changes, access grants, retention decisions, master data changes |
| **Data Steward** | Senior Sales Analyst | Monitors data quality daily, executes deduplication procedures, validates client master records |

**Critical issue from diagnostic:** 15,000 client records with confirmed NIT duplicates and
name similarity across Sales and Billing modules. The Data Steward of this domain is
accountable for resolution and prevention going forward.

---

### Domain 2: OPERACIONES

**Tables:** PEDIDO, RUTA, ENTREGA, INCIDENTE

**Business rationale:** These entities represent the execution of TRANSTRACK's core service.
An order is placed, assigned to a route, delivered (or not), and any incidents are recorded.
This domain has regulatory exposure - incidents may require legal evidence preservation.

| Role | Position | Responsibilities |
|---|---|---|
| **Data Owner** | VP Operations | Approves schema changes, access for legal/audit teams, retention policy for incident data |
| **Data Steward** | Operations Data Analyst | Monitors delivery completion rates, validates incident records, ensures orders link to deliveries |

**Critical issue from diagnostic:** 480,000 delivery records where some have no linked incident
when incidents exist, and orders exist with no delivery record - creating legal exposure when
regulators or lawyers request route-specific data.

---

### Domain 3: FLOTA

**Tables:** VEHICULO, CONDUCTOR, EMPLEADO, OPERADOR, TELEMETRIA_GPS

**Business rationale:** Fleet data is the operational asset data of TRANSTRACK. Vehicles
are assets, drivers are the humans operating them, and telemetry is the audit trail of every
vehicle movement. This domain carries the highest PII exposure (driver personal data) and
the highest volume (50M telemetry records).

| Role | Position | Responsibilities |
|---|---|---|
| **Data Owner** | VP Fleet & Logistics | Approves driver record changes, access to GPS telemetry, data retention for historical telemetry |
| **Data Steward** | Fleet Data Coordinator | Maintains driver master records, monitors telemetry partitions, validates vehicle-driver assignments |

**Critical issue from diagnostic:** Driver identity is fragmented across CONDUCTOR, EMPLEADO,
and OPERADOR with no common business key. TRANSTRACK cannot legally certify which driver
operated which vehicle during an incident investigation.

---

## 5. Decision Rights Matrix

| Decision | Domain Owner | Data Steward | DBA | Data Architect | DGC |
|---|---|---|---|---|---|
| Add new column to domain table | Approve | Propose | Execute | Review | - |
| Add new table to domain | Approve | - | Execute | Design | Inform |
| Change classification level of a column | Inform | - | - | Propose | **Approve** |
| Grant access to PII data | **Approve** | - | Execute | - | Inform |
| Grant access to FINANCIAL_CRITICAL data | **Approve** | - | Execute | - | Inform |
| Define retention period for a table | **Approve** | Propose | Execute | Advise | Inform |
| Change master data record (client, driver) | **Approve** | Execute | - | - | - |
| Approve bulk data load from external source | **Approve** | Validate | Execute | Review | - |
| Approve cross-domain data sharing | - | - | - | Design | **Approve** |
| Respond to regulatory data request | **Approve** | Compile | - | - | Inform |

**Legend:** Approve = must approve before action; Execute = carries out the action;
Propose = initiates the request; Review = provides technical review; Inform = must be notified.

---

## 6. Escalation Path - Cross-Domain Conflicts

When two domains disagree about data, the following path applies:

```
Step 1 - Direct resolution (48 hours)
  The two Domain Owners discuss and attempt to agree.
  Example: Clientes domain and Operaciones domain disagree on the
  canonical client name - Sales says "DISTRIBUIDORA INCA S.A." and
  Billing says "DISTRIBUIDORA INCA" for the same NIT.

Step 2 - Data Steward mediation (72 hours)
  If Step 1 fails, both Data Stewards research the source-of-truth
  question and present evidence to both Domain Owners.

Step 3 - Data Architect decision (96 hours)
  If Step 2 fails, the Data Architect reviews the lineage, identifies
  the authoritative source system, and issues a binding recommendation.

Step 4 - DGC ruling (5 business days)
  If Step 3 is contested, the Data Governance Council convenes and
  issues a final binding ruling. This ruling is recorded in
  DATA_POLICY_COMPLIANCE and cannot be reversed without a new DGC session.
```

---

## 7. Governance Scope Statement

This governance model covers:

- All data stored in the TRANSTRACK SQL Server instance
- All data processed by TRANSTRACK applications that read or write to these tables
- All third-party integrations that receive or send data involving TRANSTRACK domains

This governance model does **not** cover:

- Data stored exclusively in external partner systems with no TRANSTRACK copy
- Anonymized or aggregated data published externally (governed by separate publication policy)

---

## 8. Model Review

This operating model must be reviewed:

- Annually in Q1 of each calendar year
- Within 30 days of any data breach or regulatory finding
- Upon addition of a new business unit or major system integration

**Review owner:** CDO with DGC participation.

---

## 9. Reference

- DAMA-DMBOK 2nd Edition, Chapter 3: Data Governance - Operating Model Types
- ISO 27001:2022, A.5.2: Information security roles and responsibilities
- COBIT 2019, EDM01: Ensured Governance Framework Setting and Maintenance
