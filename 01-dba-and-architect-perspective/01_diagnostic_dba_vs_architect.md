# Week 01 — DBA vs Data Architect: Diagnostic Analysis

## Project: P02 — Data Governance Architecture
## Context: High-volume logistics and freight transportation company (simulated)
## Author: cblancogt | Date: 2025-05

---

## 1. The Key Question

A highly transactional logistics company operates 800 trucks, 1,200 drivers, 15,000 clients, and 50 million GPS position records. The databases run. The business operates. But four fundamental decisions were never formally assigned:

- **Who decides what tables get created and with what structure?**
- **Who decides what data is sensitive and who can see it?**
- **Who decides how long 50M GPS records are retained?**
- **Who decides what happens when multiple systems hold conflicting versions of the same entity?**

Without formal ownership of these decisions, every answer depends on who gets asked.

---

## 2. Six Governance Questions

### 2.1 Who decides what tables get created and with what structure?

**Current state:** Each operational area built its own data structures independently over six years.

Evidence:
- The driver entity exists in **three separate tables**: `CONDUCTOR`, `EMPLEADO`, `OPERADOR` — created by operations, HR, and dispatch at different points in time. No shared key. No synchronization. Each table captures a different aspect of the same person but none references the others.
- Client records accumulated data quality issues over time: the same NIT appears with different name formats, abbreviated addresses, and inconsistent contact info — not because two departments maintain separate client tables, but because **no validation rules were enforced at entry** and **no deduplication process was ever implemented**.
- Table naming conventions, column data types, and constraint patterns vary across modules because no data standards were defined before development started.

**DBA perspective:** "The tables exist, they have indexes, backups run."

**Architect perspective:** "Three teams created three versions of the same entity with no coordination. There is no canonical definition of 'driver' in the organization. No naming convention, no data type standards, no entity governance. This is a structural failure."

### 2.2 Who decides what data is sensitive and who can see it?

**Current state:** No formal classification exists.

Evidence:
- `CONDUCTOR` contains license numbers and personal identification (PII) accessible to anyone with database read access.
- `FACTURA` contains financial amounts visible to operations staff with no business need for that data.
- `INCIDENTE` contains accident details, legal evidence, and driver identification — no access restriction differentiates a dispatcher from a legal investigator.
- GPS tracking records the real-time location of individual drivers — no privacy policy defines who can query this data or for what purpose.

**DBA perspective:** "Roles and permissions are managed as requested by managers."

**Architect perspective:** "No column in any table has been classified as PII, financially critical, or operationally sensitive. Without classification, access control has no foundation. A data breach audit would have no baseline to evaluate against."

### 2.3 Who decides how long 50M GPS records are retained?

**Current state:** Everything is kept forever by default.

Evidence:
- `TELEMETRIA_GPS` holds 50 million rows from 2021 to present, growing at ~1M/month.
- No retention policy. No archival strategy. No deletion criteria.
- The table sits in PRIMARY filegroup alongside transactional data — same backup window, same restore time, same storage cost.
- A query for "last known position of truck T-0451" scans years of irrelevant historical data.

**DBA perspective:** "Storage is cheap. More disk when it fills up."

**Architect perspective:** "Without a retention policy, the organization pays to store, back up, and scan GPS coordinates from four years ago that nobody queries. If regulators ask why driver location data from 2021 is still retained, there is no documented justification. Retention without policy is a liability."

### 2.4 Who decides what happens when systems hold conflicting data?

**Current state:** Conflicts exist and nobody arbitrates.

Evidence:
- The same client NIT appears in multiple records with different name formats ("Distribuidora Nacional S.A." vs "DIST. NACIONAL SA"), different address formats, and different contact details. This happened because data entry had no standardization rules — over thousands of records and years of operation, inconsistencies accumulated organically.
- Driver records in `CONDUCTOR`, `EMPLEADO`, and `OPERADOR` hold overlapping but contradictory information: one table has the current license number, another has an expired one, a third has no license field at all.
- When leadership asks "how many unique clients exist?", the answer depends on whether the query groups by NIT alone, by NIT + name, or by NIT + address. Each method returns a different number.

**DBA perspective:** "All tables return results. No errors in the log."

**Architect perspective:** "There is no golden record for clients. No master data strategy. No survivorship rules that define which value wins when records conflict. The organization cannot answer the most basic question about its own customer base. This is not a technical problem — it is a governance failure."

### 2.5 What does it cost to NOT make these decisions?

| Problem | Business Impact | Estimated Annual Cost |
|---|---|---|
| Client records with inconsistent names/addresses | Invoices sent to wrong addresses, payment matching failures, manual reconciliation effort | **$120K–$250K** in disputed invoices and rework |
| Driver identity fragmented across 3 tables | Cannot determine which driver operated which truck during a legal incident | **$500K+** per unresolved legal claim (insurance, liability) |
| No GPS-to-delivery linkage | Cannot prove delivery times, cannot defend against late-delivery penalty claims | **$80K–$150K** in uncontested penalty deductions |
| No data classification | All 1,200 drivers' PII exposed to all database users | **Incalculable** — one breach = regulatory fine + reputation damage |
| No retention policy on GPS data | Growing storage/backup costs, legal exposure for retaining location data without justification | **$50K+/year** in unnecessary infrastructure + unquantified legal risk |
| No metadata catalog | New analysts spend weeks understanding what tables mean; tribal knowledge lost when employees leave | **$200K+/year** in productivity loss across the data team |

**Conservative total: $950K–$1.15M/year in quantifiable impact, plus unquantified legal and regulatory exposure.**

### 2.6 DBA vs Data Architect — What is the real difference?

| Dimension | DBA | Data Architect |
|---|---|---|
| **Primary question** | "Is the database running?" | "Are the data decisions correct?" |
| **Scope** | Server, instance, database | Organization, domains, policies |
| **Client inconsistencies** | "Both queries return results" | "There is no system of record" |
| **Driver fragmentation** | "All three tables are backed up" | "No canonical entity definition exists" |
| **GPS data growth** | "More storage will be added" | "A retention policy and archival strategy are needed" |
| **Access control** | "Permissions match what was requested" | "Nobody classified what SHOULD be restricted" |
| **Success metric** | 99.9% uptime, backup completion | Data trust, auditability, regulatory readiness |
| **Reports to** | IT Manager | CTO / CDO |
| **DAMA reference** | Ch.6 — Database Operations | Ch.3 — Data Governance |

**The DBA keeps the engine running. The Data Architect decides where the road goes.**

The organization has excellent DBAs — the databases have been operational for 6+ years with no catastrophic failures. But nobody was assigned to answer the governance questions. That is why a company with 15,000 clients cannot determine how many unique clients it actually has.

---

## 3. Why This Pattern Repeats Everywhere

This diagnostic applies to any organization that grew its data systems organically:

- **Healthcare:** Patient records with inconsistent identifiers across admission, lab, and pharmacy modules → duplicate tests ordered, medication errors, billing discrepancies.
- **Banking:** Customer identity data accumulated over years of mergers and system migrations without consolidation → KYC failures, regulatory sanctions.
- **Government:** Citizen records spread across tax, social services, and identity systems with no master index → benefit fraud, resource misallocation.

The technical symptoms are always the same: duplicates, orphan records, missing lineage, no classification. The root cause is always the same: nobody was assigned to make the data decisions.

**Reference:** DAMA-DMBOK2, Chapter 3 — Data Governance. The governance function exists precisely to fill this decision vacuum.

---

## 4. Architectural Conclusion

> The operational databases are functional but ungoverned. The organization invested in
> database administration (uptime, backups, performance) but not in data architecture
> (ownership, classification, master data, retention). The result: a highly transactional
> operation that cannot answer fundamental questions about its own data — how many unique
> clients it has, which driver operated a truck during a legal incident, or why 50 million
> GPS position records are retained with no policy. This project implements the governance
> framework that bridges the gap between "the database runs" and "the data is trustworthy."
