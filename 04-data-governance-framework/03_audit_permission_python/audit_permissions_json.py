"""
TRANSTRACK — Data Governance Architecture
Script:  audit_permissions.py
Purpose: Connect to SQL Server, query actual permissions, cross-reference
         against DATA_CLASSIFICATION, generate compliance report with
         GREEN/YELLOW/RED status by role and table.
Week:    04 — Domains and Ownership (Block B — Automation)
Author:  Data Architecture Lead
Ref:     DAMA-DMBOK 2nd Ed. Ch.7 — Data Security
         ISO 27001:2022 A.5.15 — Access control
         ISO 27001:2022 A.8.2  — Privileged access rights
         ISO 27001:2022 A.8.15 — Logging
"""

import os
import sys
import logging
import datetime
import json
from pathlib import Path
from typing import Optional

try:
    import pyodbc
except ImportError:
    print("ERROR: pyodbc not installed. Run: pip install pyodbc")
    sys.exit(1)

# =============================================================================
# LOGGING CONFIGURATION
# Structured logging with timestamp. Output to both console and file.
# =============================================================================

LOG_DIR = Path(os.environ.get("TRANSTRACK_LOG_DIR", "."))
LOG_FILE = LOG_DIR / f"audit_permissions_{datetime.datetime.utcnow().strftime('%Y%m%d_%H%M%S')}.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S UTC",
    handlers=[
        logging.StreamHandler(sys.stderr),
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
    ],
)
logger = logging.getLogger("transtrack.audit")


# =============================================================================
# CONFIGURATION — CENTRALIZED CONNECTION MODULES
# Connection parameters are defined in config.py and the database connection
# is created through connection.py.
# =============================================================================

from config import SERVER, DATABASE
from connection import get_connection as create_db_connection


def get_connection() -> pyodbc.Connection:
    """Establish and return a database connection using connection.py."""
    logger.info(f"Connecting to {SERVER}/{DATABASE}")
    try:
        conn = create_db_connection()
        conn.timeout = 60
        logger.info("Connection established successfully.")
        return conn
    except pyodbc.Error as e:
        logger.error(f"Connection failed: {e}")
        raise


# =============================================================================
# QUERY DEFINITIONS
# =============================================================================

# All database principals with their role memberships
QUERY_ROLE_MEMBERS = """
SELECT
    r.name          AS role_name,
    p.name          AS member_name,
    p.type_desc     AS principal_type,
    p.create_date   AS created_date
FROM sys.database_role_members rm
JOIN sys.database_principals r  ON rm.role_principal_id  = r.principal_id
JOIN sys.database_principals p  ON rm.member_principal_id = p.principal_id
WHERE r.name IN ('rol_cliente', 'rol_operaciones', 'rol_auditoria', 'rol_legal', 'rol_dba')
ORDER BY r.name, p.name;
"""

# All permissions granted in the database
QUERY_PERMISSIONS = """
SELECT
    pr.name             AS principal_name,
    pr.type_desc        AS principal_type,
    r.name              AS role_name,
    perm.state_desc     AS permission_state,  -- GRANT | DENY | REVOKE
    perm.permission_name AS permission,
    COALESCE(obj.name, 'DATABASE') AS object_name,
    obj.type_desc       AS object_type
FROM sys.database_permissions perm
JOIN sys.database_principals pr ON perm.grantee_principal_id = pr.principal_id
LEFT JOIN sys.database_role_members drm ON pr.principal_id = drm.member_principal_id
LEFT JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
LEFT JOIN sys.objects obj ON perm.major_id = obj.object_id
WHERE pr.type NOT IN ('R')  -- Exclude role-to-role grants from this view
  AND pr.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys', 'public')
ORDER BY principal_name, object_name;
"""

# Classification of every table/column with sensitivity level
QUERY_CLASSIFICATION = """
SELECT
    table_name,
    column_name,
    classification_level,
    information_type,
    requires_audit_log
FROM governance_control.DATA_CLASSIFICATION
WHERE classification_level IN ('PII', 'FINANCIAL_CRITICAL')
ORDER BY classification_level, table_name;
"""

# Authorized roles per classification level (from classification_policy.md)
AUTHORIZED_ROLES = {
    "PII": {
        "rol_legal",       # Full access including PII for legal investigations
        "rol_auditoria",   # Access to client PII; masked access to driver PII via views
    },
    "FINANCIAL_CRITICAL": {
        "rol_legal",
        "rol_auditoria",
    },
}

# Tables directly accessible by each role (from 04_rls_roles.sql)
AUTHORIZED_TABLE_ROLES = {
    "CLIENTE":           {"rol_auditoria", "rol_legal"},
    "CONTRATO_CLIENTE":  {"rol_auditoria", "rol_legal"},
    "FACTURA":           {"rol_cliente", "rol_auditoria", "rol_legal"},
    "PEDIDO":            {"rol_cliente", "rol_operaciones", "rol_auditoria", "rol_legal"},
    "RUTA":              {"rol_operaciones", "rol_auditoria", "rol_legal"},
    "ENTREGA":           {"rol_cliente", "rol_operaciones", "rol_auditoria", "rol_legal"},
    "INCIDENTE":         {"rol_operaciones", "rol_auditoria", "rol_legal"},
    "VEHICULO":          {"rol_operaciones", "rol_auditoria", "rol_legal"},
    "CONDUCTOR":         {"rol_legal"},                      # Direct access: legal only
    "EMPLEADO":          {"rol_legal"},
    "OPERADOR":          {"rol_legal"},
    "TELEMETRIA_GPS":    {"rol_auditoria", "rol_legal"},
}


# =============================================================================
# COMPLIANCE STATUS DETERMINATION
# =============================================================================

def determine_status(role: str, table: str, permission: str) -> str:
    """
    Determine compliance status for a given role/table/permission combination.
    
    Returns:
        'GREEN'  — Permission aligns with policy
        'YELLOW' — Permission exists but requires review
        'RED'    — Unauthorized access detected
    """
    authorized = AUTHORIZED_TABLE_ROLES.get(table, set())

    if role in authorized:
        return "GREEN"
    elif role == "rol_dba":
        # DBA has schema-level access; individual table grants are YELLOW for review
        return "YELLOW"
    else:
        return "RED"


# =============================================================================
# REPORT GENERATION
# =============================================================================

COLORS = {
    "GREEN":  "\033[32m",   # Green
    "YELLOW": "\033[33m",   # Yellow
    "RED":    "\033[31m",   # Red
    "RESET":  "\033[0m",
    "BOLD":   "\033[1m",
}


def colorize(text: str, status: str) -> str:
    """Apply ANSI color to status text for terminal output."""
    color = COLORS.get(status, "")
    reset = COLORS["RESET"]
    return f"{color}{text}{reset}"


def print_section(title: str) -> None:
    """Print a formatted section header."""
    print("\n" + "=" * 70)
    print(f"  {title}")
    print("=" * 70)


def run_audit(output_file: Optional[str] = None) -> dict:
    """
    Execute the full permission audit.
    
    Returns:
        dict with keys: findings, summary (GREEN/YELLOW/RED counts)
    """
    findings = []
    summary = {"GREEN": 0, "YELLOW": 0, "RED": 0}

    conn = get_connection()
    cursor = conn.cursor()

    # -------------------------------------------------------------------------
    # Step 1: Retrieve role memberships
    # -------------------------------------------------------------------------
    logger.info("Querying role memberships...")
    cursor.execute(QUERY_ROLE_MEMBERS)
    role_members = cursor.fetchall()
    columns = [col[0] for col in cursor.description]
    role_members_dict = [dict(zip(columns, row)) for row in role_members]

    # -------------------------------------------------------------------------
    # Step 2: Retrieve all permissions
    # -------------------------------------------------------------------------
    logger.info("Querying database permissions...")
    cursor.execute(QUERY_PERMISSIONS)
    permissions = cursor.fetchall()
    perm_columns = [col[0] for col in cursor.description]
    permissions_list = [dict(zip(perm_columns, row)) for row in permissions]

    # -------------------------------------------------------------------------
    # Step 3: Retrieve classification for sensitive tables
    # -------------------------------------------------------------------------
    logger.info("Querying data classification...")
    cursor.execute(QUERY_CLASSIFICATION)
    classification = cursor.fetchall()
    class_columns = [col[0] for col in cursor.description]
    classification_list = [dict(zip(class_columns, row)) for row in classification]

    # Build lookup: table_name -> max classification level
    table_classification = {}
    for row in classification_list:
        tbl = row["table_name"]
        lvl = row["classification_level"]
        if tbl not in table_classification:
            table_classification[tbl] = lvl
        elif lvl == "PII":  # PII overrides FINANCIAL_CRITICAL
            table_classification[tbl] = "PII"

    conn.close()

    # -------------------------------------------------------------------------
    # Step 4: Cross-reference permissions against policy
    # -------------------------------------------------------------------------
    logger.info("Cross-referencing permissions against classification policy...")

    for perm in permissions_list:
        role       = perm.get("role_name") or ""
        table      = perm.get("object_name") or ""
        permission = perm.get("permission") or ""
        user       = perm.get("principal_name") or ""
        state      = perm.get("permission_state") or ""

        if table == "DATABASE" or not role:
            continue  # Skip database-level permissions and direct user grants

        classification_level = table_classification.get(table, "PUBLIC")
        status = determine_status(role, table, permission)

        finding = {
            "user":        user,
            "role":        role,
            "permission":  permission,
            "state":       state,
            "table":       table,
            "classification": classification_level,
            "status":      status,
        }
        findings.append(finding)
        summary[status] += 1

    # -------------------------------------------------------------------------
    # Step 5: Check for PII/FINANCIAL tables with no policy-defined role access
    # -------------------------------------------------------------------------
    for table, cls_level in table_classification.items():
        if cls_level in ("PII", "FINANCIAL_CRITICAL"):
            # Check if any user has access outside authorized roles
            granted_roles = {
                f["role"] for f in findings
                if f["table"] == table and f["status"] == "GREEN"
            }
            if not granted_roles:
                findings.append({
                    "user":        "N/A",
                    "role":        "N/A",
                    "permission":  "NO GRANT FOUND",
                    "state":       "N/A",
                    "table":       table,
                    "classification": cls_level,
                    "status":      "YELLOW",
                })
                summary["YELLOW"] += 1

    return {
        "findings":        findings,
        "summary":         summary,
        "role_members":    role_members_dict,
        "classification":  classification_list,
    }


def print_report(audit_result: dict) -> None:
    """Format and print the audit compliance report to console."""
    now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    findings    = audit_result["findings"]
    summary     = audit_result["summary"]
    role_members = audit_result["role_members"]

    print("\n")
    print("=" * 70)
    print(f"  TRANSTRACK — Permission Audit Compliance Report")
    print(f"  Generated: {now}")
    print(f"  Server:    {SERVER}/{DATABASE}")
    print("=" * 70)

    # --- Role membership summary ---
    print_section("SECTION 1: Role Membership Inventory")
    if role_members:
        current_role = None
        for m in role_members:
            if m["role_name"] != current_role:
                current_role = m["role_name"]
                print(f"\n  Role: {COLORS['BOLD']}{current_role}{COLORS['RESET']}")
            print(f"    ├─ {m['member_name']} ({m['principal_type']})")
    else:
        print("  WARNING: No governance roles found. Execute 04_rls_roles.sql.")

    # --- Compliance findings ---
    print_section("SECTION 2: Permission Compliance Findings")
    print(f"  {'Role':<20} {'User':<20} {'Table':<25} {'Permission':<12} {'Classification':<20} {'Status'}")
    print(f"  {'-'*20} {'-'*20} {'-'*25} {'-'*12} {'-'*20} {'-'*10}")

    for f in sorted(findings, key=lambda x: (x["status"] != "RED", x["status"] != "YELLOW", x["table"])):
        status_display = colorize(f["status"], f["status"])
        print(
            f"  {f['role']:<20} {f['user']:<20} {f['table']:<25} "
            f"{f['permission']:<12} {f['classification']:<20} {status_display}"
        )

    # --- Summary ---
    print_section("SECTION 3: Compliance Summary")
    total = sum(summary.values())
    print(f"\n  Total findings evaluated: {total}")
    print(f"  {colorize('GREEN  (Compliant):', 'GREEN'):<35} {summary['GREEN']}")
    print(f"  {colorize('YELLOW (Needs Review):', 'YELLOW'):<35} {summary['YELLOW']}")
    print(f"  {colorize('RED    (Violation):', 'RED'):<35} {summary['RED']}")

    # --- Overall status ---
    if summary["RED"] > 0:
        overall = "RED"
        message = f"ACTION REQUIRED: {summary['RED']} unauthorized access finding(s) detected."
    elif summary["YELLOW"] > 0:
        overall = "YELLOW"
        message = f"REVIEW REQUIRED: {summary['YELLOW']} finding(s) need Domain Owner review."
    else:
        overall = "GREEN"
        message = "All permissions align with the Data Access Policy."

    print(f"\n  Overall Status: {colorize(overall, overall)}")
    print(f"  {message}")

    # --- Recommendations ---
    if summary["RED"] > 0 or summary["YELLOW"] > 0:
        print_section("SECTION 4: Recommended Actions")
        red_findings   = [f for f in findings if f["status"] == "RED"]
        yellow_findings = [f for f in findings if f["status"] == "YELLOW"]

        if red_findings:
            print(f"\n  {colorize('RED FINDINGS — Immediate action required:', 'RED')}")
            for f in red_findings:
                print(f"    → REVOKE {f['permission']} ON {f['table']} FROM {f['role']} ({f['user']})")
                print(f"      Classification: {f['classification']} | Action: Contact CISO + Domain Owner")

        if yellow_findings:
            print(f"\n  {colorize('YELLOW FINDINGS — Review within 5 business days:', 'YELLOW')}")
            for f in yellow_findings[:10]:  # Limit to 10 to keep report readable
                print(f"    → Review {f['permission']} ON {f['table']} for role {f['role']}")

    print("\n" + "=" * 70)
    print(f"  Log file: {LOG_FILE}")
    print("=" * 70 + "\n")


def save_report_text(audit_result: dict, output_file: str) -> None:
    """Save report to a text file (no ANSI colors)."""
    summary = audit_result["summary"]
    findings = audit_result["findings"]
    now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

    with open(output_file, "w", encoding="utf-8") as f:
        f.write(f"TRANSTRACK Permission Audit Report\n")
        f.write(f"Generated: {now}\n")
        f.write(f"Server: {SERVER}/{DATABASE}\n\n")
        f.write(f"SUMMARY\n")
        f.write(f"-------\n")
        f.write(f"GREEN  (Compliant):     {summary['GREEN']}\n")
        f.write(f"YELLOW (Needs Review):  {summary['YELLOW']}\n")
        f.write(f"RED    (Violation):     {summary['RED']}\n\n")
        f.write(f"FINDINGS\n")
        f.write(f"--------\n")
        for finding in findings:
            f.write(
                f"{finding['status']:<8} | {finding['role']:<20} | {finding['table']:<25} | "
                f"{finding['permission']:<12} | {finding['classification']}\n"
            )

    logger.info(f"Report saved to: {output_file}")


def json_default(value):
    """Serialize datetime and non-native values for JSON output."""
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    return str(value)


def build_audit_json_response(audit_result: dict) -> dict:
    """
    Build the canonical JSON response for the permission audit.

    This response is the source format for future outputs:
    console, PDF, HTML, API endpoint, dashboard, or archival evidence.
    """
    now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    summary = audit_result["summary"]
    findings = audit_result["findings"]
    role_members = audit_result["role_members"]
    classification = audit_result["classification"]

    total = sum(summary.values())

    if summary["RED"] > 0:
        overall_status = "RED"
        message = f"ACTION REQUIRED: {summary['RED']} unauthorized access finding(s) detected."
    elif summary["YELLOW"] > 0:
        overall_status = "YELLOW"
        message = f"REVIEW REQUIRED: {summary['YELLOW']} finding(s) need Domain Owner review."
    else:
        overall_status = "GREEN"
        message = "All permissions align with the Data Access Policy."

    role_inventory = {}
    for member in role_members:
        role_name = member.get("role_name")
        if role_name not in role_inventory:
            role_inventory[role_name] = []
        role_inventory[role_name].append({
            "member_name": member.get("member_name"),
            "principal_type": member.get("principal_type"),
            "created_date": member.get("created_date"),
        })

    recommendations = []

    for finding in findings:
        if finding["status"] == "RED":
            recommendations.append({
                "severity": "RED",
                "action": "REVOKE_PERMISSION",
                "message": (
                    f"Revoke {finding['permission']} on {finding['table']} "
                    f"from role {finding['role']} for user {finding['user']}."
                ),
                "table": finding["table"],
                "role": finding["role"],
                "user": finding["user"],
                "classification": finding["classification"],
            })

    for finding in findings:
        if finding["status"] == "YELLOW":
            recommendations.append({
                "severity": "YELLOW",
                "action": "REVIEW_PERMISSION",
                "message": (
                    f"Review {finding['permission']} on {finding['table']} "
                    f"for role {finding['role']}."
                ),
                "table": finding["table"],
                "role": finding["role"],
                "user": finding["user"],
                "classification": finding["classification"],
            })

    return {
        "metadata": {
            "system": "TRANSTRACK",
            "report_type": "Permission Audit Compliance Report",
            "generated_at": now,
            "server": SERVER,
            "database": DATABASE,
            "log_file": str(LOG_FILE),
        },
        "summary": {
            "total_findings_evaluated": total,
            "green": summary["GREEN"],
            "yellow": summary["YELLOW"],
            "red": summary["RED"],
            "overall_status": overall_status,
            "message": message,
        },
        "role_membership_inventory": role_inventory,
        "permission_compliance_findings": findings,
        "data_classification_inventory": classification,
        "recommendations": recommendations,
    }


def print_json_response(response: dict) -> None:
    """Print canonical JSON response to stdout."""
    print(json.dumps(response, indent=2, ensure_ascii=False, default=json_default))


def save_report_json(response: dict, output_file: str) -> None:
    """Save canonical JSON response to file."""
    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(response, f, indent=2, ensure_ascii=False, default=json_default)
    logger.info(f"JSON report saved to: {output_file}")


# =============================================================================
# ENTRY POINT
# =============================================================================

def main():
    """Main entry point for the audit script."""
    logger.info("=" * 50)
    logger.info("TRANSTRACK — Permission Audit Starting")
    logger.info(f"Target: {SERVER}/{DATABASE}")
    logger.info("=" * 50)

    # Optional: save JSON report to file
    report_output = os.environ.get("TRANSTRACK_JSON_OUTPUT", None)

    try:
        audit_result = run_audit()
        response = build_audit_json_response(audit_result)
        
        json_dir = Path("json")
        json_dir.mkdir(parents=True, exist_ok=True)
        # Canonical output: JSON to stdout
        print_json_response(response)

        report_output = json_dir / (
            f"audit_permissions_"
            f"{datetime.datetime.utcnow().strftime('%Y%m%d_%H%M%S')}.json"
        )
        
        save_report_json(response, str(report_output))

        # Exit code communicates compliance status to calling systems (CI/CD, monitoring)
        summary = audit_result["summary"]
        if summary["RED"] > 0:
            logger.warning(f"Audit completed with {summary['RED']} RED finding(s). Exiting with code 2.")
            sys.exit(2)   # Red = non-zero exit for monitoring systems
        elif summary["YELLOW"] > 0:
            logger.info(f"Audit completed with {summary['YELLOW']} YELLOW finding(s). Exiting with code 1.")
            sys.exit(1)   # Yellow = needs attention
        else:
            logger.info("Audit completed. All findings GREEN. Exiting with code 0.")
            sys.exit(0)

    except pyodbc.Error as db_err:
        error_response = {
            "metadata": {
                "system": "TRANSTRACK",
                "report_type": "Permission Audit Compliance Report",
                "generated_at": datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC"),
                "server": SERVER,
                "database": DATABASE,
                "log_file": str(LOG_FILE),
            },
            "summary": {
                "overall_status": "ERROR",
                "message": "Database error during audit.",
            },
            "error": {
                "type": "pyodbc.Error",
                "message": str(db_err),
            },
        }
        print_json_response(error_response)
        logger.error(f"Database error during audit: {db_err}")
        sys.exit(3)
    except Exception as ex:
        error_response = {
            "metadata": {
                "system": "TRANSTRACK",
                "report_type": "Permission Audit Compliance Report",
                "generated_at": datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC"),
                "server": SERVER,
                "database": DATABASE,
                "log_file": str(LOG_FILE),
            },
            "summary": {
                "overall_status": "ERROR",
                "message": "Unexpected error during audit.",
            },
            "error": {
                "type": type(ex).__name__,
                "message": str(ex),
            },
        }
        print_json_response(error_response)
        logger.exception(f"Unexpected error during audit: {ex}")
        sys.exit(3)


if __name__ == "__main__":
    main()


# =============================================================================
# USAGE EXAMPLES:
#
# Windows Auth (domain environment):
#   set TRANSTRACK_SERVER=localhost\SQLEXPRESS
#   set TRANSTRACK_DATABASE=TRANSTRACK
#   python audit_permissions.py
#
# SQL Server Auth:
#   set TRANSTRACK_SERVER=localhost
#   set TRANSTRACK_DATABASE=TRANSTRACK
#   set TRANSTRACK_USER=governance_audit
#   set TRANSTRACK_PASSWORD=SecurePassword123!
#   python audit_permissions.py
#
# Save JSON report to file:
#   set TRANSTRACK_JSON_OUTPUT=audit_report_20250101.json
#   python audit_permissions.py
#
# Linux/Mac:
#   export TRANSTRACK_SERVER=localhost
#   export TRANSTRACK_DATABASE=TRANSTRACK
#   python audit_permissions.py
# =============================================================================
