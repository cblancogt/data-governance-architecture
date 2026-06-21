# Data Classification Policy - TRANSTRACK

**Policy ID:** CLASS-POLICY-001  
**Version:** 1.0  
**Owner:** Chief Information Security Officer (CISO)  
**Approved by:** Data Governance Council  
**Reference:** ISO 27001:2022 A.5.12 - Classification of information  
**Review Frequency:** Annual  
**Last Updated:** 2025

---

## 1. Purpose

This policy defines how TRANSTRACK classifies its data before protecting it.
Classification is the prerequisite to all security controls: without knowing
*what* a piece of data is, no system can determine *how* to protect it.

This policy resolves a foundational problem documented in the TRANSTRACK
diagnostic phase: when every table is treated with equal sensitivity (or none),
the result is that PII like driver license numbers and GPS coordinates receive
the same protection as city names in a route reference table - which is no
protection at all.

**The classification performed under this policy is the first act of the
TRANSTRACK security program.**

---

## 2. Scope

This policy applies to:
- All data stored in the TRANSTRACK SQL Server database
- All data transmitted between TRANSTRACK systems
- All data exported from TRANSTRACK systems to partners, regulators, or third parties
- All persons who create, process, or access TRANSTRACK data

---

## 3. Classification Levels

TRANSTRACK uses four classification levels. Every column in every table must
be assigned exactly one level. Ambiguous columns default to the higher
(more protective) classification.

---

### Level 1: PII (Personally Identifiable Information)

**Definition:** Data that identifies, or can identify, a natural person -
directly or in combination with other data in the system.

**Examples in TRANSTRACK:**
- Driver license numbers (DPI/NIT), names, phone numbers, addresses
- Client NIT (business identifier linked to legal person in Guatemala)
- GPS coordinates in TELEMETRIA_GPS (because they track an individual driver's movements)
- Employee ID numbers that link to HR records

**Who can see it:**
- Domain Owner (for their domain only), upon documented business need
- `rol_legal`: full access for active legal investigations, with audit log entry
- `rol_auditoria`: access to client PII; excluded from driver PII
- No other role has default access to PII columns

**Conditions for access:**
- Written Domain Owner approval required
- Access logged by SQL Server Audit on every SELECT
- Access reviewed quarterly; revoked immediately upon role change

**Required protections:**
- Column-level access control through views or RLS predicates
- SQL Server Audit enabled on all tables containing PII columns
- Data masking applied when data is used in non-production environments
- Never included in exports without explicit Domain Owner authorization

**Regulatory basis:**
- GDPR Article 4: definition of personal data
- GDPR Article 25: data protection by design and by default
- Guatemala Ley de Protección de Datos Personales (framework reference)

---

### Level 2: FINANCIAL_CRITICAL

**Definition:** Data that represents financial transactions, contractual
obligations, tariffs, or amounts that affect TRANSTRACK's revenue, tax
position, or contractual commitments.

**Examples in TRANSTRACK:**
- Invoice amounts, dates, payment status in FACTURA
- Contract tariffs and validity periods in CONTRATO_CLIENTE
- Any column that determines how much a client is billed

**Who can see it:**
- Domain Owner (DOM_CLIENTES)
- CFO and Finance team members with explicit approval
- `rol_auditoria`: read-only access for internal audit
- `rol_legal`: full access when financial data is relevant to investigation

**Conditions for access:**
- Written Domain Owner and CFO approval required
- All access logged
- Exports require CFO co-approval

**Required protections:**
- SQL Server Audit on all DML
- Change data capture or audit trigger for any modification
- SOX Section 404 controls apply: internal control review annually

**Regulatory basis:**
- SOX Section 404: internal control over financial reporting
- Tax authority requirements (Guatemala SAT): 5-year minimum retention

---

### Level 3: OPERATIONAL_SENSITIVE

**Definition:** Data that describes TRANSTRACK's operational performance,
route information, delivery metrics, or incident details that could be
competitively sensitive or relevant to insurance/legal proceedings.

**Examples in TRANSTRACK:**
- Order status and delivery times in PEDIDO, ENTREGA
- Route definitions and performance data in RUTA
- Incident details (type, resolution) in INCIDENTE - note: the PII within
  incidents (driver name, vehicle plate) is classified as PII, not OPERATIONAL_SENSITIVE
- Vehicle assignment history in VEHICULO

**Who can see it:**
- `rol_operaciones`: standard access
- `rol_auditoria`: read access
- `rol_legal`: full access
- Domain Owner and Steward

**Required protections:**
- Standard RBAC through role membership
- SQL Server Audit for INSERT, UPDATE, DELETE (not SELECT)
- Not included in external reports without Domain Owner approval

---

### Level 4: PUBLIC

**Definition:** Data that contains no personal information, no financial
figures, no competitive intelligence, and no operational sensitivity.
This data could be published externally without harm to TRANSTRACK or any
individual.

**Examples in TRANSTRACK:**
- City names in RUTA (the origin and destination names - not the performance data)
- Vehicle type categories (truck, flatbed, refrigerated)
- Incident type codes (accident, theft, delay, damage) - the codes, not the details
- Status codes and reference values

**Who can see it:** All authenticated users and applications.

**Required protections:** None beyond standard authentication. Still governed
by the Data Change Policy - reference data changes require Domain Owner approval.

---

## 4. Classification Decision Tree

When classifying a column, apply these questions in order:

```
1. Does this data identify a natural person, directly or through linkage?
   YES → PII

2. Does this data affect billing, revenue, contractual amounts, or
   tax reporting?
   YES → FINANCIAL_CRITICAL

3. Does this data describe operational performance, routes, incidents,
   or vehicle assignments in ways that are sensitive to litigation,
   insurance, or competitive intelligence?
   YES → OPERATIONAL_SENSITIVE

4. None of the above.
   → PUBLIC
```

When in doubt, classify higher. Reclassifying down requires CISO approval.

---

## 5. Classification Inheritance

When a table is joined with another table, the combined result inherits
the **highest** classification of any column included in the result set.
A query that joins CLIENTE (PII) with FACTURA (FINANCIAL_CRITICAL) produces
a result classified as PII - the higher of the two.

This has implications for:
- Query logging and auditing
- Export controls
- Data sharing agreements between domains

---

## 6. Reclassification

Data may need to be reclassified when:
- A new use case is identified (e.g., GPS coordinates used for employee monitoring)
- A regulatory change creates new sensitivity requirements
- Data is aggregated or anonymized sufficiently to reduce sensitivity

**Reclassification upward (to higher sensitivity):** CISO may approve.  
**Reclassification downward (to lower sensitivity):** DGC approval required.

All reclassifications are recorded in DATA_CLASSIFICATION with the previous
level, new level, approver, and justification.

---

## 7. Third-Party Data Sharing

Before sharing any data classified above PUBLIC with any third party:
1. The data must be identified with its classification level
2. The Domain Owner must provide written approval
3. The receiving party must have equivalent or stronger controls in place
4. A Data Sharing Agreement must be in place (formalized in Week 08)

---

## 8. Labelling

TRANSTRACK implements classification through:
- The DATA_CLASSIFICATION table (database-level registry)
- Column comments/extended properties in SQL Server
- Azure Purview Sensitivity Labels (for cloud implementation)
- Report headers that declare the classification level of exported data

Physical labels are not used for database records. The classification label
lives in the DATA_CLASSIFICATION table and is enforced through RLS predicates
and role-based access controls.

---

## Reference

- ISO 27001:2022, A.5.12: Classification of information
- ISO 27001:2022, A.5.13: Labelling of information
- ISO 27001:2022, A.5.15: Access control
- DAMA-DMBOK 2nd Edition, Chapter 7: Data Security
- GDPR Article 4, 25, 32
- SOX Section 404
