#!/usr/bin/env python3
# =============================================================================
# PROJECT : P02 - Data Governance Architecture (TRANSTRACK)
# FOLDER  : 07-quality-program
# FILE    : quality_check.py
# PURPOSE : Execute the data quality suite in SQL Server, read the results
#           from governance_control.DATA_QUALITY_RESULTS, and produce a
#           traffic-light report (GREEN / YELLOW / RED) per table, both to the
#           console and to a PDF (reportlab).
#
# DESIGN NOTES
#   - Credentials come ONLY from environment variables (never hardcoded).
#   - The ODBC connection sets APP=TRANSTRACK_QualityCheck so that the
#     Resource Governor classifier (04_resource_governor.sql) routes this
#     workload to the dedicated, capped quality pool.
#   - The authoritative verdict is the `status` column computed in SQL against
#     each rule's own thresholds. Python does NOT recompute the light with a
#     hardcoded margin; it renders what governance already decided. (The
#     per-rule warning_threshold_pct in DATA_QUALITY_RULES is the formal
#     expression of the "within X% of threshold = YELLOW" idea.)
#   - Structured logging on every operation.
#
# ENVIRONMENT VARIABLES
#   DB_SERVER    e.g. "localhost\\SQLDEV2019" or "10.0.0.5,1433"
#   DB_NAME      e.g. "TRANSTRACK"
#   DB_DRIVER    optional, default "ODBC Driver 17 for SQL Server"
#   DB_TRUSTED   optional, "yes" to use Windows auth (then user/pwd ignored)
#   DB_USER      SQL login (if not using trusted auth)
#   DB_PASSWORD  SQL password (if not using trusted auth)
#   DQ_PDF_PATH  optional, output PDF path (default "quality_report.pdf")
#
# USAGE
#   python quality_check.py                 # normal monitoring run
#   python quality_check.py --baseline      # mark run as folder-02 baseline
#   python quality_check.py --no-run        # skip execution, report last batch
# =============================================================================

import argparse
import logging
import os
import sys
from datetime import datetime, timezone

import pyodbc

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle


# ------------------------------------------------------------------ logging ---
def build_logger() -> logging.Logger:
    """Configure a structured logger writing to console and a rotating-ish file."""
    logger = logging.getLogger("quality_check")
    logger.setLevel(logging.INFO)
    if logger.handlers:  # avoid duplicate handlers on re-import
        return logger

    fmt = logging.Formatter(
        "%(asctime)s | %(levelname)-7s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(fmt)
    logger.addHandler(console)

    try:
        file_handler = logging.FileHandler("quality_check.log", encoding="utf-8")
        file_handler.setFormatter(fmt)
        logger.addHandler(file_handler)
    except OSError:
        # Console-only logging is acceptable if the log file cannot be opened.
        logger.warning("Could not open quality_check.log; continuing with console logging only.")

    return logger


LOG = build_logger()

# Status ordering: lower number = worse. Used to compute a table's worst status.
STATUS_SEVERITY = {"ERROR": 0, "RED": 1, "YELLOW": 2, "GREEN": 3, "NOT_APPLICABLE": 4}

# Traffic-light colors for the PDF.
STATUS_COLOR = {
    "GREEN": colors.HexColor("#1B7F3B"),
    "YELLOW": colors.HexColor("#C7930A"),
    "RED": colors.HexColor("#B00020"),
    "ERROR": colors.HexColor("#5A5A5A"),
    "NOT_APPLICABLE": colors.HexColor("#9AA0A6"),
}


# --------------------------------------------------------------- connection ---
def get_connection() -> pyodbc.Connection:
    """Build a pyodbc connection from environment variables only.

    Sets APP=TRANSTRACK_QualityCheck so Resource Governor routes this session
    to the dedicated quality pool. Raises RuntimeError if required variables
    are missing.
    """
    server = os.environ.get("DB_SERVER")
    database = os.environ.get("DB_NAME")
    driver = os.environ.get("DB_DRIVER", "ODBC Driver 17 for SQL Server")
    trusted = os.environ.get("DB_TRUSTED", "").strip().lower() in ("1", "yes", "true")

    missing = [k for k, v in (("DB_SERVER", server), ("DB_NAME", database)) if not v]
    if missing:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")

    parts = [
        f"DRIVER={{{driver}}}",
        f"SERVER={server}",
        f"DATABASE={database}",
        "APP=TRANSTRACK_QualityCheck",   # <-- Resource Governor routing key
        "Encrypt=yes",
        "TrustServerCertificate=yes",
    ]

    if trusted:
        parts.append("Trusted_Connection=yes")
        LOG.info("Connecting with Windows (trusted) authentication.")
    else:
        user = os.environ.get("DB_USER")
        password = os.environ.get("DB_PASSWORD")
        if not user or not password:
            raise RuntimeError("DB_USER and DB_PASSWORD are required unless DB_TRUSTED=yes.")
        parts.append(f"UID={user}")
        parts.append(f"PWD={password}")
        LOG.info("Connecting with SQL authentication as user '%s'.", user)

    conn_str = ";".join(parts)
    conn = pyodbc.connect(conn_str, autocommit=True)
    LOG.info("Connected to %s / %s.", server, database)
    return conn


# ----------------------------------------------------------------- run suite ---
def run_suite(conn: pyodbc.Connection, is_baseline: bool) -> str:
    """Execute usp_RunQualitySuite and return the run_batch_id of this run.

    The procedure returns the scoreboard as a result set whose rows include
    run_batch_id; we read it from there rather than issuing a second query.
    """
    LOG.info("Executing usp_RunQualitySuite (baseline=%s). This may take minutes "
             "due to full TELEMETRIA_GPS scans...", is_baseline)
    cursor = conn.cursor()
    cursor.execute(
        "EXEC governance_control.usp_RunQualitySuite @is_baseline = ?",
        1 if is_baseline else 0,
    )

    # Skip past any non-row-returning statements to reach the scoreboard set.
    batch_id = None
    while True:
        if cursor.description is not None:
            cols = [c[0] for c in cursor.description]
            if "run_batch_id" in cols:
                idx = cols.index("run_batch_id")
                for row in cursor.fetchall():
                    batch_id = str(row[idx])
                    break
                if batch_id:
                    break
        if not cursor.nextset():
            break

    if not batch_id:
        # Fallback: read the most recent batch.
        LOG.warning("Could not read run_batch_id from the procedure result; "
                    "falling back to the latest batch.")
        batch_id = fetch_latest_batch(conn)

    LOG.info("Suite completed. run_batch_id = %s", batch_id)
    return batch_id


def fetch_latest_batch(conn: pyodbc.Connection) -> str:
    """Return the run_batch_id of the most recent measurement."""
    cursor = conn.cursor()
    cursor.execute(
        "SELECT TOP (1) run_batch_id FROM governance_control.DATA_QUALITY_RESULTS "
        "ORDER BY measured_at DESC"
    )
    row = cursor.fetchone()
    if not row:
        raise RuntimeError("DATA_QUALITY_RESULTS is empty; nothing to report.")
    return str(row[0])


# ------------------------------------------------------------- read results ---
def fetch_results(conn: pyodbc.Connection, batch_id: str) -> list[dict]:
    """Read all rule results for a given batch as a list of dicts."""
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT rule_code, quality_dimension, target_schema, target_table,
               target_column, records_evaluated, records_failed, pass_rate_pct,
               threshold_pct, status, severity, execution_ms
        FROM governance_control.DATA_QUALITY_RESULTS
        WHERE run_batch_id = ?
        ORDER BY target_schema, target_table, rule_code
        """,
        batch_id,
    )
    cols = [c[0] for c in cursor.description]
    results = [dict(zip(cols, row)) for row in cursor.fetchall()]
    LOG.info("Fetched %d rule results for batch %s.", len(results), batch_id)
    return results


def summarize_by_table(results: list[dict]) -> list[dict]:
    """Collapse rule results into one worst-status row per schema.table."""
    tables: dict[tuple, dict] = {}
    for r in results:
        key = (r["target_schema"], r["target_table"])
        entry = tables.setdefault(
            key,
            {
                "schema": r["target_schema"],
                "table": r["target_table"],
                "rules": 0,
                "worst": "GREEN",
                "reds": 0,
                "yellows": 0,
            },
        )
        entry["rules"] += 1
        status = r["status"]
        if status == "RED":
            entry["reds"] += 1
        elif status == "YELLOW":
            entry["yellows"] += 1
        # Track the worst status seen for this table.
        if STATUS_SEVERITY.get(status, 5) < STATUS_SEVERITY.get(entry["worst"], 5):
            entry["worst"] = status

    return sorted(
        tables.values(),
        key=lambda e: (STATUS_SEVERITY.get(e["worst"], 5), e["schema"], e["table"]),
    )


# --------------------------------------------------------------- console out ---
def print_console(results: list[dict], table_summary: list[dict], batch_id: str) -> None:
    """Human-readable traffic-light summary to stdout."""
    counts = {"GREEN": 0, "YELLOW": 0, "RED": 0, "NOT_APPLICABLE": 0, "ERROR": 0}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1

    print("\n" + "=" * 68)
    print(f"  TRANSTRACK - DATA QUALITY REPORT   batch {batch_id}")
    print(f"  generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC}")
    print("=" * 68)
    print(f"  GREEN  {counts['GREEN']:>3}   "
          f"YELLOW {counts['YELLOW']:>3}   "
          f"RED {counts['RED']:>3}   "
          f"N/A {counts['NOT_APPLICABLE']:>3}   "
          f"ERR {counts['ERROR']:>3}")
    print("-" * 68)
    print("  WORST STATUS PER TABLE")
    for e in table_summary:
        print(f"    [{e['worst']:<14}] {e['schema']}.{e['table']:<22} "
              f"(rules={e['rules']}, red={e['reds']}, yellow={e['yellows']})")
    print("=" * 68 + "\n")


# ------------------------------------------------------------------- pdf out ---
def build_pdf(results: list[dict], table_summary: list[dict], batch_id: str, path: str) -> None:
    """Render the traffic-light report to a PDF using reportlab."""
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle("t", parent=styles["Title"], fontSize=16)
    small = ParagraphStyle("s", parent=styles["Normal"], fontSize=8, textColor=colors.grey)

    doc = SimpleDocTemplate(path, pagesize=A4,
                            leftMargin=15 * mm, rightMargin=15 * mm,
                            topMargin=15 * mm, bottomMargin=15 * mm)
    story = []

    story.append(Paragraph("TRANSTRACK - Data Quality Report", title_style))
    story.append(Paragraph(
        f"Batch {batch_id} &nbsp;|&nbsp; generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC}",
        small))
    story.append(Spacer(1, 6 * mm))

    # ---- Worst-status-per-table block ----
    story.append(Paragraph("Worst status per table", styles["Heading2"]))
    tbl_data = [["Status", "Schema.Table", "Rules", "Red", "Yellow"]]
    tbl_style = [
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#222222")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTSIZE", (0, 0), (-1, -1), 8),
        ("GRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#DDDDDD")),
    ]
    for i, e in enumerate(table_summary, start=1):
        tbl_data.append([e["worst"], f"{e['schema']}.{e['table']}",
                         str(e["rules"]), str(e["reds"]), str(e["yellows"])])
        # Color the status cell.
        tbl_style.append(("TEXTCOLOR", (0, i), (0, i),
                          STATUS_COLOR.get(e["worst"], colors.black)))
        tbl_style.append(("FONTNAME", (0, i), (0, i), "Helvetica-Bold"))

    t1 = Table(tbl_data, colWidths=[28 * mm, 70 * mm, 20 * mm, 18 * mm, 22 * mm])
    t1.setStyle(TableStyle(tbl_style))
    story.append(t1)
    story.append(Spacer(1, 8 * mm))

    # ---- Rule-level detail block ----
    story.append(Paragraph("Rule-level detail", styles["Heading2"]))
    det_data = [["Rule", "Dim", "Table", "Pass%", "Thr%", "Failed", "ms", "Status"]]
    det_style = [
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#222222")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTSIZE", (0, 0), (-1, -1), 7),
        ("GRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#DDDDDD")),
    ]
    # Show worst first for readability.
    ordered = sorted(results, key=lambda r: (STATUS_SEVERITY.get(r["status"], 5), r["rule_code"]))
    for i, r in enumerate(ordered, start=1):
        pass_txt = "" if r["pass_rate_pct"] is None else f"{r['pass_rate_pct']:.2f}"
        det_data.append([
            r["rule_code"], r["quality_dimension"][:4],
            f"{r['target_schema']}.{r['target_table']}"[:26],
            pass_txt, f"{r['threshold_pct']:.0f}",
            "" if r["records_failed"] is None else str(r["records_failed"]),
            "" if r["execution_ms"] is None else str(r["execution_ms"]),
            r["status"],
        ])
        det_style.append(("TEXTCOLOR", (7, i), (7, i),
                          STATUS_COLOR.get(r["status"], colors.black)))
        det_style.append(("FONTNAME", (7, i), (7, i), "Helvetica-Bold"))

    t2 = Table(det_data, colWidths=[24 * mm, 12 * mm, 46 * mm, 16 * mm,
                                    12 * mm, 18 * mm, 14 * mm, 26 * mm])
    t2.setStyle(TableStyle(det_style))
    story.append(t2)

    doc.build(story)
    LOG.info("PDF report written to %s", path)


# ---------------------------------------------------------------------- main ---
def main() -> int:
    parser = argparse.ArgumentParser(description="TRANSTRACK data quality check runner.")
    parser.add_argument("--baseline", action="store_true",
                        help="Mark this run as the folder-02 baseline (is_baseline=1).")
    parser.add_argument("--no-run", action="store_true",
                        help="Do not execute the suite; report the latest existing batch.")
    parser.add_argument("--pdf", default=os.environ.get("DQ_PDF_PATH", "quality_report.pdf"),
                        help="Output PDF path.")
    args = parser.parse_args()

    try:
        conn = get_connection()
    except Exception as exc:  # connection/config failure is fatal
        LOG.error("Connection failed: %s", exc)
        return 2

    try:
        if args.no_run:
            batch_id = fetch_latest_batch(conn)
            LOG.info("Reporting latest existing batch %s (no execution).", batch_id)
        else:
            batch_id = run_suite(conn, is_baseline=args.baseline)

        results = fetch_results(conn, batch_id)
        if not results:
            LOG.error("No results found for batch %s.", batch_id)
            return 3

        table_summary = summarize_by_table(results)
        print_console(results, table_summary, batch_id)
        build_pdf(results, table_summary, batch_id, args.pdf)

        # Exit code reflects worst finding: 1 if any RED/ERROR, else 0.
        worst = min((STATUS_SEVERITY.get(r["status"], 5) for r in results), default=5)
        return 1 if worst <= STATUS_SEVERITY["RED"] else 0

    except Exception as exc:
        LOG.exception("Quality check failed: %s", exc)
        return 4
    finally:
        conn.close()
        LOG.info("Connection closed.")


if __name__ == "__main__":
    sys.exit(main())
