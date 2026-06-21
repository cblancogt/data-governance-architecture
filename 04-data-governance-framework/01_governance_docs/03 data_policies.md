# TRANSTRACK - Formal Data Policies

**Version:** 1.0  
**Status:** Approved by Data Governance Council  
**Owner:** Chief Data Officer  
**Reference:** DAMA-DMBOK 2nd Edition, Chapter 3  
**Review Frequency:** Annual (Q1) or upon material system change  
**Last Updated:** 2025-09-xx

---

> These policies are written in business language. They describe what TRANSTRACK has decided to do with its data. Technical implementation details are in the accompanying SQL scripts.
> If a technical decision conflicts with a policy statement here, the policy takes precedence and the technical implementation must be corrected.

---

## Policy 1: Data Access Policy

**Policy ID:** POLICY-001  
**Owner:** Chief Data Officer (CDO)  
**Enforcement:** Data Governance Council + Domain Owners  

### Purpose
To ensure that TRANSTRACK employees and systems access only the data they need to perform
their specific functions, and that all access is documented, approved, and auditable.

### Scope
All data stored in the TRANSTRACK database system, all users (internal and external),
and all applications that connect to TRANSTRACK data.

### Policy Statements

1.1 **Need-to-know principle.** No individual or system shall have access to data that is
not required to perform their specific job function. Access is granted by job function,
not by seniority.

1.2 **Formal approval required.** All access to data classified as PII or FINANCIAL_CRITICAL
requires written approval from the Domain Owner before the DBA grants access. Email or
ticketing system records constitute written approval.

1.3 **Role-based access.** Access is granted through roles, not to individuals directly.
The five roles defined in the classification policy govern database-level access:
`rol_cliente`, `rol_operaciones`, `rol_auditoria`, `rol_legal`, `rol_dba`.
Individual assignments to roles are reviewed quarterly.

1.4 **Third-party access.** No external party (vendors, partners, regulators) shall receive
direct database access. Data requests from external parties are fulfilled through approved
exports executed by a DBA, with Domain Owner approval and audit log entry.

1.5 **Access revocation.** When an employee changes role, leaves the company, or is placed
on leave, their database access is revoked within 24 hours. HR is responsible for notifying
IT Security. IT Security is responsible for notifying the DBA.

1.6 **Privilege review.** All role memberships are reviewed quarterly by Domain Owners and
the DBA. The DATA_POLICY_COMPLIANCE table records the outcome of each review.

### Enforcement Mechanism
- SQL Server Audit logs all access to PII and FINANCIAL_CRITICAL tables.
- The `audit_permissions.py` script runs weekly and flags any access that does not match
  an approved role assignment.
- Violations are reported to the CISO and relevant Domain Owner within 24 hours.

---

## Policy 2: Data Retention Policy

**Policy ID:** POLICY-002  
**Owner:** Chief Data Officer + Chief Financial Officer (for financial data)  
**Enforcement:** Domain Owners + DBA  

### Purpose
To define how long TRANSTRACK retains each category of data, what happens when data reaches
its retention limit, and who must authorize deletion or archival.

### Scope
All tables in the TRANSTRACK database, including the 50 million GPS telemetry records.

### Policy Statements

2.1 **Retention by classification.** Data retention is determined by its classification
and its regulatory requirements. Business convenience is not a retention justification.

| Data Category | Table(s) | Retention Period | Action at Expiry | Regulatory Basis |
|---|---|---|---|---|
| Client master data | CLIENTE, CONTRATO_CLIENTE | 7 years after contract end | Archive to cold storage | Tax authority requirements |
| Financial records | FACTURA | 5 years minimum | Archive, then delete with CFO approval | Tax law |
| Operational orders | PEDIDO, ENTREGA | 5 years | Archive, then delete with Domain Owner approval | Contract disputes statute |
| Incident records | INCIDENTE | 10 years | Never deleted without Legal counsel approval | Litigation exposure |
| Route reference data | RUTA | Indefinite while operational; 3 years after deactivation | Archive | None |
| GPS telemetry | TELEMETRIA_GPS | 3 years in active partitions | Year 4+ moves to ARCHIVE filegroup | Insurance/litigation |
| Driver records | CONDUCTOR, EMPLEADO, OPERADOR | 7 years after driver separation | Archive, then delete with HR approval | Labor law |
| Vehicle records | VEHICULO | Duration of ownership + 5 years | Archive | Insurance |

2.2 **Deletion requires authorization.** No data shall be deleted from production tables
without a deletion request recorded in DATA_POLICY_COMPLIANCE, approved by the Domain Owner,
and executed by the DBA. Automated deletion of records that have not completed the approval
process is prohibited.

2.3 **Telemetry archival schedule.** TELEMETRIA_GPS is partitioned by year and month.
On January 1 of each year, partitions from 3 years prior are migrated to the ARCHIVE
filegroup. This migration is scheduled, logged, and verified by checksum.

2.4 **Legal hold override.** If any data is subject to a legal hold, litigation, or
regulatory investigation, it is exempt from retention schedule expiry until the hold is
formally released by Legal counsel. A legal hold overrides all automatic archival or
deletion processes.

### Enforcement Mechanism
- The `02_data_policies.sql` stored procedure checks retention compliance monthly.
- Any partition or table section with data older than the defined retention period generates
  a compliance finding in DATA_POLICY_COMPLIANCE with status VIOLATION.
- Domain Owners receive a monthly retention compliance report.

---

## Policy 3: Data Quality Policy

**Policy ID:** POLICY-003  
**Owner:** Chief Data Officer  
**Enforcement:** Data Stewards + Domain Owners  

### Purpose
To define the minimum acceptable quality level for data in each domain, and to establish
the process for detecting, reporting, and resolving quality violations.

### Scope
All operational tables in the TRANSTRACK database.

### Policy Statements

3.1 **Quality thresholds by domain.** The following minimum thresholds are mandatory.
Data below these thresholds triggers a quality incident:

| Domain | Table | Dimension | Minimum Threshold | Measurement |
|---|---|---|---|---|
| Clientes | CLIENTE | Uniqueness (NIT) | 98% | Duplicate NITs / total records |
| Clientes | CLIENTE | Completeness (name, NIT, phone) | 99% | NULL or blank in required fields |
| Clientes | FACTURA | Referential integrity | 100% | Invoices with no linked order |
| Operaciones | PEDIDO | Completeness | 99% | Required fields populated |
| Operaciones | ENTREGA | Timeliness | 95% | Deliveries with FECHA_ENTREGA populated within 24h of completion |
| Flota | CONDUCTOR | Uniqueness (license number) | 100% | Duplicate license numbers across tables |
| Flota | TELEMETRIA_GPS | Completeness | 99.5% | Records with NULL coordinates |

3.2 **Quality measurement frequency.** Quality measurements are executed:
- Daily for PII and FINANCIAL_CRITICAL tables.
- Weekly for OPERATIONAL_SENSITIVE tables.
- Monthly for reference tables.

3.3 **Quality incident process.** When a threshold violation is detected:
- The Data Steward is notified within 4 hours.
- The Data Steward has 48 hours to assess root cause.
- If root cause requires schema change or data correction beyond the Steward's authority,
  the Domain Owner is notified and must approve a remediation plan within 5 business days.

3.4 **Historical benchmark.** The quality state documented at Week 03 of this project
(diagnostic phase) constitutes the baseline. Every quality metric must show improvement
from that baseline at each subsequent measurement.

3.5 **Zero-tolerance rules.** The following violations have no acceptable tolerance and
require immediate escalation to the Domain Owner:
- Driver records with no valid license number.
- Invoices referencing a client NIT that does not exist in CLIENTE.
- Incident records with no vehicle or driver identifier.

### Enforcement Mechanism
- Quality checks are automated through stored procedures defined in Week 11 deliverables.
- Results are stored in DATA_QUALITY_RESULTS (to be implemented Week 11).
- Red status on any zero-tolerance rule triggers a Sev-1 incident in the IT ticketing system.

---

## Policy 4: Data Change Policy

**Policy ID:** POLICY-004  
**Owner:** Chief Data Officer  
**Enforcement:** Domain Owners + Data Stewards + DBA  

### Purpose
To define how changes to master data (clients, drivers, contracts) are requested,
reviewed, approved, and executed - ensuring no master data changes occur without
authorization and audit trail.

### Scope
All master data records: CLIENTE, CONDUCTOR, EMPLEADO, OPERADOR, VEHICULO, CONTRATO_CLIENTE.
Schema changes (DDL) are governed by the RACI matrix and this policy jointly.

### Policy Statements

4.1 **No direct production writes.** No application, developer, or analyst shall
execute INSERT, UPDATE, or DELETE directly against master data tables in production
outside of an approved change process. All changes go through a defined request.

4.2 **Change request required.** All master data changes require a change request that
documents: what is being changed, why, who requested it, what the data looked like before,
and what it will look like after.

4.3 **Approval before execution.** Master data changes require Domain Owner approval
before the DBA executes them. The approval is recorded in DATA_POLICY_COMPLIANCE before
the change is made.

4.4 **Deduplication is a governed change.** Merging duplicate client records or
consolidating driver tables is not a technical cleanup activity - it is a master data
change that follows this policy. The Data Steward proposes the merge, the Domain Owner
approves it, and the DBA executes it with a full before/after audit log.

4.5 **Golden record designation.** When conflicting versions of the same entity exist
(as documented in the diagnostic for CLIENTE and CONDUCTOR), the Domain Owner designates
the authoritative version. The designation is recorded in the master data management system.
The other versions are not deleted - they are linked to the golden record with a superseded
status and full history.

4.6 **Schema changes require Data Architect review.** Any change to table structure
(adding columns, changing data types, dropping columns) requires the Data Architect to
review for cross-domain impact before the DBA executes it.

4.7 **Emergency changes.** In a production incident that requires immediate data change,
the DBA may execute with verbal approval from the Domain Owner, provided: a written
approval is obtained within 2 hours, the change is documented in DATA_POLICY_COMPLIANCE
within 4 hours, and the change is reviewed at the next DGC meeting.

### Enforcement Mechanism
- DATA_POLICY_COMPLIANCE logs every change request, approval, and execution.
- SQL Server Audit captures all DML on master data tables, creating an immutable record.
- The DBA is prohibited from executing unapproved changes to master data tables in production.
- Quarterly compliance review confirms that all recorded changes have corresponding approvals.

---

## Policy Review History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 1.0 | 2025 | Data Architect | Initial version - established all four policies |

---

## Reference

- DAMA-DMBOK 2nd Edition, Chapter 3: Data Governance
- ISO 27001:2022, A.5.1: Policies for information security
- ISO 27001:2022, A.5.15: Access control
- GDPR Article 5: Principles relating to processing of personal data
- GDPR Article 25: Data protection by design and by default
