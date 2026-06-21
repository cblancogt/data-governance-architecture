# RACI Matrix - TRANSTRACK Data Governance

**Version:** 1.0  
**Owner:** Data Governance Council  
**Reference:** DAMA-DMBOK 2nd Edition, Chapter 3  
**Last Updated:** 2025

---

## How to Read This Matrix

| Code | Meaning |
|---|---|
| **R** | Responsible - executes the activity |
| **A** | Accountable - approves and owns the outcome |
| **C** | Consulted - provides input before action |
| **I** | Informed - notified after action |

Each row is a table. Each activity column applies to every table.  
Where a cell is blank, that role has no involvement in that activity for that table.

---

## Roles Defined

| Role | Description |
|---|---|
| **DO** | Domain Owner - VP-level business authority over the domain |
| **DS** | Data Steward - Operational data quality and compliance monitor |
| **DBA** | Database Administrator - technical execution authority |
| **DA** | Data Architect - structural and governance design authority |
| **DEV** | Application Developer - builds and maintains consuming applications |
| **BA** | Business Analyst - interprets data for business decisions |

---

## Domain: CLIENTES

| Table | Create/Modify Schema | Grant Access | Define Retention | Define Quality Rules | Approve Data Changes | Handle Incidents |
|---|---|---|---|---|---|---|
| **CLIENTE** | A:DO / R:DBA / C:DA | A:DO / R:DBA | A:DO / C:DA | A:DO / R:DS / C:DA | A:DO / R:DS | A:DO / R:DS / I:DBA |
| **CONTRATO_CLIENTE** | A:DO / R:DBA / C:DA | A:DO / R:DBA | A:DO / C:DA | A:DO / R:DS / C:DA | A:DO / R:DS | A:DO / R:DS / I:DBA |
| **FACTURA** | A:DO / R:DBA / C:DA | A:DO / R:DBA / I:CISO | A:DO / C:DA / C:CFO | A:DO / R:DS / C:DA | A:DO / R:DS | A:DO / R:DS / I:DBA / I:CFO |

**Notes for CLIENTES domain:**
- FACTURA access grants require CISO notification due to FINANCIAL_CRITICAL classification.
- FACTURA retention must be consulted with CFO because tax regulations require minimum 5-year retention.
- Data changes to CLIENTE master records (deduplication, NIT correction) require Domain Owner approval - this directly addresses the diagnostic finding of unauthorized duplicate creation.

---

## Domain: OPERACIONES

| Table | Create/Modify Schema | Grant Access | Define Retention | Define Quality Rules | Approve Data Changes | Handle Incidents |
|---|---|---|---|---|---|---|
| **PEDIDO** | A:DO / R:DBA / C:DA | A:DO / R:DBA | A:DO / C:DA | A:DO / R:DS / C:DA | A:DO / R:DS | A:DO / R:DS / I:DBA |
| **RUTA** | A:DO / R:DBA / C:DA | A:DO / R:DBA | A:DO | A:DO / R:DS | A:DO / R:DS | A:DO / R:DS |
| **ENTREGA** | A:DO / R:DBA / C:DA | A:DO / R:DBA | A:DO / C:DA | A:DO / R:DS / C:DA | A:DO / R:DS | A:DO / R:DS / I:DBA |
| **INCIDENTE** | A:DO / R:DBA / C:DA / C:Legal | A:DO / R:DBA / C:Legal | A:DO / C:Legal / C:DA | A:DO / R:DS / C:DA | A:DO / R:DS / C:Legal | A:DO / R:DS / R:Legal / I:DBA |

**Notes for OPERACIONES domain:**
- INCIDENTE has Legal as a Consulted party for schema changes, access grants, and retention - this table is frequently required in litigation and regulatory investigations.
- The diagnostic found 8,500 incident records where driver identity cannot be confirmed. Any schema change to INCIDENTE must consider the legal chain-of-custody implications.

---

## Domain: FLOTA

| Table | Create/Modify Schema | Grant Access | Define Retention | Define Quality Rules | Approve Data Changes | Handle Incidents |
|---|---|---|---|---|---|---|
| **VEHICULO** | A:DO / R:DBA / C:DA | A:DO / R:DBA | A:DO / C:DA | A:DO / R:DS | A:DO / R:DS | A:DO / R:DS / I:DBA |
| **CONDUCTOR** | A:DO / R:DBA / C:DA / C:HR | A:DO / R:DBA / I:CISO | A:DO / C:HR / C:DA | A:DO / R:DS / C:HR | A:DO / R:DS / C:HR | A:DO / R:DS / I:DBA / I:HR |
| **EMPLEADO** | A:DO / R:DBA / C:DA / C:HR | A:DO / R:DBA / I:CISO | A:DO / C:HR / C:DA | A:DO / R:DS / C:HR | A:DO / R:DS / C:HR | A:DO / R:DS / I:DBA / I:HR |
| **OPERADOR** | A:DO / R:DBA / C:DA / C:HR | A:DO / R:DBA / I:CISO | A:DO / C:HR / C:DA | A:DO / R:DS / C:HR | A:DO / R:DS / C:HR | A:DO / R:DS / I:DBA / I:HR |
| **TELEMETRIA_GPS** | A:DO / R:DBA / C:DA | A:DO / R:DBA / I:Legal | A:DO / C:DA / C:Legal | A:DO / R:DS / C:DA | A:DO / R:DS | A:DO / R:DS / I:DBA / I:Legal |

**Notes for FLOTA domain:**
- CONDUCTOR, EMPLEADO, and OPERADOR all require HR consultation because they contain employee personal data (PII). Any data changes have HR/labor law implications.
- CISO is informed of any access grants to driver PII tables - this is the highest personal data sensitivity in the system.
- TELEMETRIA_GPS access grants are communicated to Legal because GPS data is increasingly regulated under privacy frameworks and may be required in litigation.
- The diagnostic found driver identity fragmented across all three driver tables with no common key. Until master data consolidation is complete (Week 07), all three tables carry equal governance weight.

---

## Cross-Domain Activities

| Activity | Data Governance Council | Domain Owner | Data Steward | DBA | Data Architect |
|---|---|---|---|---|---|
| Cross-domain data sharing approval | **A** | C | C | I | R |
| Governance policy creation | **A** | C | I | I | R |
| Governance policy enforcement review | **A** | R | R | I | C |
| Data breach response | **A** | R | R | R | C |
| Regulatory data request (audit/legal) | **A** | R | R | R | C |
| Maturity assessment (annual) | **A** | C | C | C | R |
| New domain creation | **A** | C | I | I | R |

---

## Accountability Summary by Role

| Role | Primary Accountabilities |
|---|---|
| **Domain Owner** | All access decisions within domain; all data change approvals; retention policy; represents domain at DGC |
| **Data Steward** | Daily quality monitoring; executing approved data changes; escalating anomalies to Domain Owner |
| **DBA** | Technical execution of all approved schema and permission changes; backup and recovery; performance monitoring |
| **Data Architect** | Governance framework design; cross-domain conflict analysis; metadata catalog maintenance; ADR authorship |
| **Developer** | Consuming data per granted permissions; reporting schema issues to DBA; not creating tables independently |
| **Business Analyst** | Interpreting data for business decisions; requesting access through formal process; not bypassing access controls |

---

## RACI Enforcement Note

The diagnostic evidence from this project confirms what happens when RACI does not exist:

- Developers created OPERADOR without consulting CONDUCTOR or EMPLEADO owners - producing the three-table fragmentation.
- Sales team inserted duplicate clients without any Data Steward review process.
- Invoices were created in the billing module referencing client IDs from the sales module with no cross-domain validation.

The RACI matrix is the organizational control that prevents recurrence. It is enforced through the DATA_POLICY_COMPLIANCE table (see `02_data_policies.sql`).

---

## Reference

- DAMA-DMBOK 2nd Edition, Chapter 3: Governance activities and roles
- ISO 27001:2022, A.5.3: Segregation of duties
- COBIT 2019, EDM01.02: Direct the governance system
