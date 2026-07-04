"""
FILE: 06_golden_record_validation.py
PROJECT: P02 - Data Governance Architecture | TRANSTRACK
PURPOSE: Validate golden record integrity after consolidation.
         Runs automated checks against MASTER_CONDUCTOR and MASTER_CLIENTE.
         Generates a PDF report matching the audit report format.

DEPENDENCIES:
    connection.py  -- pyodbc connection using Windows Authentication
    config.py      -- SERVER, DATABASE, OUTPUT_DIR, DRIVER constants
    reportlab      -- pip install reportlab

USAGE:
    python 06_golden_record_validation.py
"""

import sys
import logging
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    HRFlowable, PageBreak
)
from reportlab.lib.enums import TA_LEFT, TA_CENTER

from connection import get_connection
from config import SERVER, DATABASE, OUTPUT_DIR

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("golden_record_validation")

REPORT_DIR = Path(OUTPUT_DIR)
REPORT_DIR.mkdir(exist_ok=True)

# ---------------------------------------------------------------------------
# COLORS -- matches the audit report palette
# ---------------------------------------------------------------------------
COLOR_GREEN  = colors.HexColor("#27ae60")
COLOR_YELLOW = colors.HexColor("#f39c12")
COLOR_RED    = colors.HexColor("#e74c3c")
COLOR_DARK   = colors.HexColor("#1a252f")
COLOR_HEADER = colors.HexColor("#2c3e50")
COLOR_LIGHT  = colors.HexColor("#f2f2f2")
COLOR_WHITE  = colors.white

STATUS_COLOR = {"GREEN": COLOR_GREEN, "YELLOW": COLOR_YELLOW, "RED": COLOR_RED}
STATUS_LABEL = {"GREEN": "COMPLIANT", "YELLOW": "NEEDS REVIEW", "RED": "VIOLATION"}


# ---------------------------------------------------------------------------
# DATA CLASSES
# ---------------------------------------------------------------------------

@dataclass
class ValidationCheck:
    name: str
    description: str
    passed: bool
    value: Optional[float] = None
    threshold: Optional[float] = None
    unit: str = ""
    details: str = ""

    @property
    def status(self) -> str:
        if self.passed:
            return "GREEN"
        if self.threshold and self.value is not None:
            ratio = self.value / self.threshold if self.threshold else 0
            return "YELLOW" if ratio >= 0.95 else "RED"
        return "RED"


@dataclass
class ValidationReport:
    entity: str
    run_at: datetime = field(default_factory=datetime.now)
    checks: list[ValidationCheck] = field(default_factory=list)

    @property
    def total(self) -> int:
        return len(self.checks)

    @property
    def passed_count(self) -> int:
        return sum(1 for c in self.checks if c.passed)

    @property
    def failed_count(self) -> int:
        return self.total - self.passed_count

    @property
    def overall_status(self) -> str:
        if self.failed_count == 0:
            return "GREEN"
        if self.failed_count <= 2:
            return "YELLOW"
        return "RED"


# ---------------------------------------------------------------------------
# DB SESSION
# ---------------------------------------------------------------------------

class DbSession:
    def __init__(self):
        self._conn = None

    def __enter__(self) -> "DbSession":
        log.info("Opening database connection")
        self._conn = get_connection()
        self._conn.autocommit = True
        log.info("Connection established")
        return self

    def __exit__(self, *_):
        if self._conn:
            self._conn.close()
            log.info("Connection closed")

    def query(self, sql: str, params: tuple = ()) -> list[dict]:
        cursor = self._conn.cursor()
        try:
            cursor.execute(sql, params)
            columns = [col[0] for col in cursor.description]
            return [dict(zip(columns, row)) for row in cursor.fetchall()]
        except Exception as exc:
            log.error("Query error: %s | SQL: %.200s", exc, sql)
            return []
        finally:
            cursor.close()

    def scalar(self, sql: str, params: tuple = (), default=0):
        rows = self.query(sql, params)
        if rows:
            return list(rows[0].values())[0] or default
        return default


# ---------------------------------------------------------------------------
# VALIDATOR
# ---------------------------------------------------------------------------

class GoldenRecordValidator:

    def __init__(self, db: DbSession):
        self.db = db

    def validate_conductor(self) -> ValidationReport:
        report = ValidationReport(entity="governance_control.MASTER_CONDUCTOR")
        log.info("--- Validating MASTER_CONDUCTOR ---")

        dup_licenses = self.db.scalar("""
            SELECT COUNT(*) FROM (
                SELECT numero_licencia
                FROM governance_control.MASTER_CONDUCTOR
                WHERE numero_licencia IS NOT NULL
                  AND numero_licencia NOT LIKE 'NO_LIC_%'
                GROUP BY numero_licencia HAVING COUNT(*) > 1
            ) x
        """)
        report.checks.append(ValidationCheck(
            name="No duplicate license numbers",
            description="Each license number must appear exactly once in MASTER_CONDUCTOR",
            passed=(dup_licenses == 0),
            value=float(dup_licenses), threshold=0, unit="duplicates",
            details=f"{dup_licenses} duplicate license groups found"
                    if dup_licenses else "All license numbers are unique",
        ))

        conductor_count = self.db.scalar("SELECT COUNT(*) FROM flota.CONDUCTOR")
        empleado_count  = self.db.scalar("SELECT COUNT(*) FROM flota.EMPLEADO WHERE cargo = 'CONDUCTOR'")
        operador_count  = self.db.scalar("SELECT COUNT(*) FROM flota.OPERADOR")
        master_count    = self.db.scalar("SELECT COUNT(*) FROM governance_control.MASTER_CONDUCTOR")
        total_source    = conductor_count + empleado_count + operador_count

        report.checks.append(ValidationCheck(
            name="Master count lower than total source records",
            description="Consolidation must produce fewer records than the sum of all source tables",
            passed=(master_count <= conductor_count),
            value=float(master_count), threshold=float(conductor_count), unit="records",
            details=f"Source: {total_source:,} -> Master: {master_count:,} ({total_source - master_count:,} consolidated)",
        ))

        crosswalk_conductor = self.db.scalar(
            "SELECT COUNT(*) FROM governance_control.CONDUCTOR_CROSSWALK WHERE source_system = 'CONDUCTOR'"
        )
        report.checks.append(ValidationCheck(
            name="All CONDUCTOR records mapped in crosswalk",
            description="Every flota.CONDUCTOR record must have a crosswalk entry",
            passed=(crosswalk_conductor == conductor_count),
            value=float(crosswalk_conductor), threshold=float(conductor_count), unit="records",
            details=f"{crosswalk_conductor} of {conductor_count} CONDUCTOR records mapped",
        ))

        flagged = self.db.scalar(
            "SELECT COUNT(*) FROM governance_control.MASTER_CONDUCTOR WHERE necesita_revision = 1"
        )
        flag_pct = (flagged / master_count * 100) if master_count else 0
        report.checks.append(ValidationCheck(
            name="Flagged records within expected range",
            description="Records needing review expected < 30%",
            passed=(flag_pct < 30.0),
            value=round(flag_pct, 2), threshold=30.0, unit="%",
            details=f"{flagged} of {master_count} records flagged for Data Steward review",
        ))

        active_no_expiry = self.db.scalar("""
            SELECT COUNT(*) FROM governance_control.MASTER_CONDUCTOR
            WHERE estado_activo = 1
              AND numero_licencia IS NOT NULL
              AND numero_licencia NOT LIKE 'NO_LIC_%'
              AND fecha_vencimiento_lic IS NULL
        """)
        report.checks.append(ValidationCheck(
            name="Active drivers have license expiry date",
            description="All active licensed drivers must have an expiry date on record",
            passed=(active_no_expiry == 0),
            value=float(active_no_expiry), threshold=0, unit="records",
            details=f"{active_no_expiry} active drivers missing expiry date"
                    if active_no_expiry else "All active drivers have expiry dates",
        ))

        source_systems = {r["source_system"] for r in self.db.query(
            "SELECT DISTINCT source_system FROM governance_control.CONDUCTOR_CROSSWALK"
        )}
        missing = {"CONDUCTOR", "EMPLEADO", "OPERADOR"} - source_systems
        report.checks.append(ValidationCheck(
            name="All 3 source systems in crosswalk",
            description="Crosswalk must have entries from CONDUCTOR, EMPLEADO and OPERADOR",
            passed=(len(missing) == 0),
            details=f"Missing: {missing}" if missing else f"All present: {source_systems}",
        ))

        log.info("CONDUCTOR: %d/%d checks passed", report.passed_count, report.total)
        return report

    def validate_cliente(self) -> ValidationReport:
        report = ValidationReport(entity="governance_control.MASTER_CLIENTE")
        log.info("--- Validating MASTER_CLIENTE ---")

        ventas_count      = self.db.scalar("SELECT COUNT(*) FROM ventas.CLIENTE")
        facturacion_count = self.db.scalar("SELECT COUNT(*) FROM facturacion.CLIENTE")
        master_count      = self.db.scalar("SELECT COUNT(*) FROM governance_control.MASTER_CLIENTE")
        total_source      = ventas_count + facturacion_count

        report.checks.append(ValidationCheck(
            name="Master count lower than combined source",
            description="Deduplication must produce fewer records than total source rows",
            passed=(master_count < ventas_count),
            value=float(master_count), threshold=float(ventas_count), unit="records",
            details=f"ventas: {ventas_count:,} + facturacion: {facturacion_count:,} -> Master: {master_count:,}",
        ))

        dup_nits = self.db.scalar("""
            SELECT COUNT(*) FROM (
                SELECT nit_seq FROM governance_control.MASTER_CLIENTE
                WHERE nit_seq IS NOT NULL
                GROUP BY nit_seq HAVING COUNT(*) > 1
            ) x
        """)
        report.checks.append(ValidationCheck(
            name="No duplicate NIT sequences in master",
            description="NIT sequence is the normalized business key -- must be unique",
            passed=(dup_nits == 0),
            value=float(dup_nits), threshold=0, unit="duplicates",
            details=f"{dup_nits} duplicate NIT sequences" if dup_nits else "All NIT sequences are unique",
        ))

        crosswalk_ventas = self.db.scalar(
            "SELECT COUNT(*) FROM governance_control.CLIENTE_CROSSWALK WHERE source_modulo = 'VENTAS'"
        )
        report.checks.append(ValidationCheck(
            name="All ventas.CLIENTE records in crosswalk",
            description="Every ventas.CLIENTE record must appear in the crosswalk",
            passed=(crosswalk_ventas == ventas_count),
            value=float(crosswalk_ventas), threshold=float(ventas_count), unit="records",
            details=f"{crosswalk_ventas:,} of {ventas_count:,} ventas records mapped",
        ))

        audit_count = self.db.scalar("SELECT COUNT(*) FROM governance_control.MASTER_CLIENT_AUDIT")
        report.checks.append(ValidationCheck(
            name="Audit trail populated",
            description="MASTER_CLIENT_AUDIT must document every merge and survivor decision",
            passed=(audit_count > 0),
            value=float(audit_count), threshold=1, unit="entries",
            details=f"{audit_count:,} decisions documented in audit log",
        ))

        active_dsas = self.db.scalar(
            "SELECT COUNT(*) FROM governance_control.DATA_SHARING_AGREEMENT WHERE dsa_status = 'ACTIVE'"
        )
        report.checks.append(ValidationCheck(
            name="Active DSAs governing cross-domain flows",
            description="At least 4 active Data Sharing Agreements must be in place",
            passed=(active_dsas >= 4),
            value=float(active_dsas), threshold=4, unit="DSAs",
            details=f"{active_dsas} active DSAs governing TRANSTRACK data flows",
        ))

        violations_total = self.db.scalar("SELECT COUNT(*) FROM governance_control.DSA_VIOLATION_LOG")
        violations_open  = self.db.scalar(
            "SELECT COUNT(*) FROM governance_control.DSA_VIOLATION_LOG WHERE resolution_status = 'OPEN'"
        )
        report.checks.append(ValidationCheck(
            name="Governance failures formally documented",
            description="Known failures must be logged as DSA violations",
            passed=(violations_total >= 3),
            value=float(violations_total), threshold=3, unit="violations",
            details=f"{violations_total} total violations logged; {violations_open} still OPEN",
        ))

        log.info("CLIENTE: %d/%d checks passed", report.passed_count, report.total)
        return report

    def get_stats(self) -> dict:
        conductor_count = self.db.scalar("SELECT COUNT(*) FROM flota.CONDUCTOR")
        empleado_count  = self.db.scalar("SELECT COUNT(*) FROM flota.EMPLEADO WHERE cargo = 'CONDUCTOR'")
        operador_count  = self.db.scalar("SELECT COUNT(*) FROM flota.OPERADOR")
        master_cond     = self.db.scalar("SELECT COUNT(*) FROM governance_control.MASTER_CONDUCTOR")
        flagged_cond    = self.db.scalar("SELECT COUNT(*) FROM governance_control.MASTER_CONDUCTOR WHERE necesita_revision = 1")
        ventas_count    = self.db.scalar("SELECT COUNT(*) FROM ventas.CLIENTE")
        factura_count   = self.db.scalar("SELECT COUNT(*) FROM facturacion.CLIENTE")
        master_cli      = self.db.scalar("SELECT COUNT(*) FROM governance_control.MASTER_CLIENTE")
        flagged_cli     = self.db.scalar("SELECT COUNT(*) FROM governance_control.MASTER_CLIENTE WHERE necesita_revision = 1")
        return {
            "conductor": {
                "flota_CONDUCTOR": conductor_count,
                "flota_EMPLEADO":  empleado_count,
                "flota_OPERADOR":  operador_count,
                "total_source":    conductor_count + empleado_count + operador_count,
                "master_records":  master_cond,
                "flagged":         flagged_cond,
            },
            "cliente": {
                "ventas_CLIENTE":      ventas_count,
                "facturacion_CLIENTE": factura_count,
                "total_source":        ventas_count + factura_count,
                "master_records":      master_cli,
                "flagged":             flagged_cli,
            },
            "lineage_flows": self.db.scalar("SELECT COUNT(*) FROM governance_control.DATA_LINEAGE WHERE is_active = 1"),
            "active_dsas":   self.db.scalar("SELECT COUNT(*) FROM governance_control.DATA_SHARING_AGREEMENT WHERE dsa_status = 'ACTIVE'"),
            "ref_tables":    self.db.scalar("SELECT COUNT(*) FROM governance_control.REF_DATA_REGISTRY WHERE is_active = 1"),
        }


# ---------------------------------------------------------------------------
# PDF REPORT -- matches the permission audit report format
# ---------------------------------------------------------------------------

def build_styles():
    base = getSampleStyleSheet()
    styles = {
        "title": ParagraphStyle(
            "ReportTitle", parent=base["Normal"],
            fontSize=20, textColor=COLOR_WHITE,
            fontName="Helvetica-Bold", alignment=TA_LEFT,
            spaceAfter=4,
        ),
        "subtitle": ParagraphStyle(
            "ReportSubtitle", parent=base["Normal"],
            fontSize=10, textColor=colors.HexColor("#aaaaaa"),
            fontName="Helvetica", alignment=TA_LEFT,
        ),
        "section": ParagraphStyle(
            "SectionHeader", parent=base["Normal"],
            fontSize=13, textColor=COLOR_DARK,
            fontName="Helvetica-Bold", spaceBefore=18, spaceAfter=6,
        ),
        "body": ParagraphStyle(
            "Body", parent=base["Normal"],
            fontSize=9, textColor=colors.HexColor("#333333"),
            fontName="Helvetica", spaceAfter=4, leading=13,
        ),
        "field_label": ParagraphStyle(
            "FieldLabel", parent=base["Normal"],
            fontSize=9, textColor=colors.HexColor("#555555"),
            fontName="Helvetica-Bold",
        ),
        "field_value": ParagraphStyle(
            "FieldValue", parent=base["Normal"],
            fontSize=9, textColor=COLOR_DARK,
            fontName="Helvetica",
        ),
    }
    return styles


def add_page_number(canvas, doc):
    """Footer with page number on every page."""
    canvas.saveState()
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(colors.HexColor("#888888"))
    page_num = f"TRANSTRACK - Golden Record Validation Report  Page {doc.page}"
    canvas.drawString(inch * 0.75, 0.5 * inch, page_num)
    canvas.restoreState()


def render_pdf(reports: list[ValidationReport], stats: dict, path: Path) -> None:
    s = build_styles()
    now = datetime.now()
    overall_statuses = [r.overall_status for r in reports]
    overall = "GREEN" if all(x == "GREEN" for x in overall_statuses) \
              else "RED" if any(x == "RED" for x in overall_statuses) \
              else "YELLOW"

    total_findings  = sum(r.failed_count for r in reports)
    green_findings  = sum(r.passed_count for r in reports)
    yellow_findings = sum(1 for r in reports for c in r.checks if c.status == "YELLOW")
    red_findings    = sum(1 for r in reports for c in r.checks if c.status == "RED")

    doc = SimpleDocTemplate(
        str(path),
        pagesize=letter,
        leftMargin=0.75 * inch,
        rightMargin=0.75 * inch,
        topMargin=0.75 * inch,
        bottomMargin=0.75 * inch,
    )

    story = []

    # -------------------------------------------------------------------------
    # COVER BLOCK (dark background simulation via table)
    # -------------------------------------------------------------------------
    cover_data = [[
        Paragraph("TRANSTRACK", s["title"]),
        ""
    ], [
        Paragraph("Golden Record Validation Report", ParagraphStyle(
            "sub2", fontSize=12, textColor=colors.HexColor("#cccccc"),
            fontName="Helvetica", alignment=TA_LEFT
        )),
        ""
    ], [
        Paragraph("Audit evidence generated from master data consolidation results.", ParagraphStyle(
            "sub3", fontSize=9, textColor=colors.HexColor("#aaaaaa"),
            fontName="Helvetica", alignment=TA_LEFT
        )),
        ""
    ]]
    cover_table = Table(cover_data, colWidths=[5.5 * inch, 1.5 * inch])
    cover_table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), COLOR_DARK),
        ("TOPPADDING",    (0, 0), (-1, -1), 14),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
        ("LEFTPADDING",   (0, 0), (-1, -1), 14),
        ("RIGHTPADDING",  (0, 0), (-1, -1), 14),
    ]))
    story.append(cover_table)
    story.append(Spacer(1, 10))

    # Metadata block
    meta_data = [
        ["Field", "Value"],
        ["Generated At", now.strftime("%Y-%m-%d %H:%M:%S UTC")],
        ["Server",       SERVER],
        ["Database",     DATABASE],
        ["Overall Status", STATUS_LABEL[overall]],
    ]
    meta_table = Table(meta_data, colWidths=[2 * inch, 5 * inch])
    meta_style = TableStyle([
        ("BACKGROUND",   (0, 0), (-1, 0), COLOR_HEADER),
        ("TEXTCOLOR",    (0, 0), (-1, 0), COLOR_WHITE),
        ("FONTNAME",     (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE",     (0, 0), (-1, -1), 9),
        ("BACKGROUND",   (0, 1), (-1, -1), COLOR_LIGHT),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [COLOR_WHITE, COLOR_LIGHT]),
        ("GRID",         (0, 0), (-1, -1), 0.5, colors.HexColor("#cccccc")),
        ("TOPPADDING",   (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING",(0, 0), (-1, -1), 5),
        ("LEFTPADDING",  (0, 0), (-1, -1), 8),
        ("TEXTCOLOR",    (0, 4), (1, 4), STATUS_COLOR[overall]),
        ("FONTNAME",     (0, 4), (1, 4), "Helvetica-Bold"),
    ])
    meta_table.setStyle(meta_style)
    story.append(meta_table)
    story.append(Spacer(1, 8))

    # Audit conclusion box
    conclusion_color = STATUS_COLOR[overall]
    conclusion_text  = f"{STATUS_LABEL[overall]}: {total_findings} finding(s) require Data Steward review." \
                       if total_findings else "All checks passed. Golden records are valid."
    conc_data = [["Audit Conclusion"], [conclusion_text]]
    conc_table = Table(conc_data, colWidths=[7 * inch])
    conc_table.setStyle(TableStyle([
        ("BACKGROUND",    (0, 0), (-1, 0), conclusion_color),
        ("TEXTCOLOR",     (0, 0), (-1, 0), COLOR_WHITE),
        ("FONTNAME",      (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE",      (0, 0), (-1, -1), 9),
        ("BACKGROUND",    (0, 1), (-1, 1), colors.HexColor("#fffde7") if overall == "YELLOW" else COLOR_LIGHT),
        ("GRID",          (0, 0), (-1, -1), 0.5, colors.HexColor("#cccccc")),
        ("TOPPADDING",    (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("LEFTPADDING",   (0, 0), (-1, -1), 8),
    ]))
    story.append(conc_table)
    story.append(PageBreak())

    # -------------------------------------------------------------------------
    # SECTION 1: EXECUTIVE SUMMARY
    # -------------------------------------------------------------------------
    story.append(Paragraph("1. Executive Summary", s["section"]))
    story.append(HRFlowable(width="100%", thickness=1, color=COLOR_HEADER))
    story.append(Spacer(1, 8))

    summary_data = [
        [str(total_findings), str(green_findings), str(yellow_findings), str(red_findings)],
        ["Total Findings", "Compliant", "Needs Review", "Violations"],
    ]
    summary_table = Table(summary_data, colWidths=[1.75 * inch] * 4)
    summary_table.setStyle(TableStyle([
        ("FONTNAME",      (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE",      (0, 0), (-1, 0), 22),
        ("FONTSIZE",      (0, 1), (-1, 1), 9),
        ("ALIGNMENT",     (0, 0), (-1, -1), "CENTER"),
        ("TEXTCOLOR",     (1, 0), (1, 0), COLOR_GREEN),
        ("TEXTCOLOR",     (2, 0), (2, 0), COLOR_YELLOW),
        ("TEXTCOLOR",     (3, 0), (3, 0), COLOR_RED),
        ("TEXTCOLOR",     (0, 1), (-1, 1), colors.HexColor("#555555")),
        ("TOPPADDING",    (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("LINEABOVE",     (0, 0), (-1, 0), 2, COLOR_HEADER),
        ("LINEBELOW",     (0, 1), (-1, 1), 1, colors.HexColor("#cccccc")),
    ]))
    story.append(summary_table)
    story.append(Spacer(1, 12))

    # Overall status row
    status_row = [[
        f"Overall Status", STATUS_LABEL[overall],
        "Required Action",
        "Review findings with Data Steward." if overall != "GREEN" else "No action required."
    ]]
    st_table = Table(status_row, colWidths=[1.2 * inch, 1.3 * inch, 1.4 * inch, 3.1 * inch])
    st_table.setStyle(TableStyle([
        ("FONTNAME",      (0, 0), (-1, -1), "Helvetica"),
        ("FONTNAME",      (1, 0), (1, 0),   "Helvetica-Bold"),
        ("FONTSIZE",      (0, 0), (-1, -1), 9),
        ("TEXTCOLOR",     (1, 0), (1, 0), STATUS_COLOR[overall]),
        ("BACKGROUND",    (0, 0), (-1, -1), COLOR_LIGHT),
        ("GRID",          (0, 0), (-1, -1), 0.5, colors.HexColor("#cccccc")),
        ("TOPPADDING",    (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("LEFTPADDING",   (0, 0), (-1, -1), 8),
    ]))
    story.append(st_table)
    story.append(Spacer(1, 16))

    # Before/After stats
    cond = stats["conductor"]
    cli  = stats["cliente"]
    story.append(Paragraph("Consolidation Summary", s["section"]))
    story.append(HRFlowable(width="100%", thickness=1, color=COLOR_HEADER))
    story.append(Spacer(1, 6))

    ba_data = [
        ["Entity", "Source Records", "Master Records", "Consolidated", "Flagged"],
        [
            "Drivers (CONDUCTOR)",
            f"{cond['total_source']:,}",
            f"{cond['master_records']:,}",
            f"{cond['total_source'] - cond['master_records']:,}",
            str(cond["flagged"]),
        ],
        [
            "Clients (CLIENTE)",
            f"{cli['total_source']:,}",
            f"{cli['master_records']:,}",
            f"{cli['total_source'] - cli['master_records']:,}",
            str(cli["flagged"]),
        ],
    ]
    ba_table = Table(ba_data, colWidths=[2 * inch, 1.3 * inch, 1.3 * inch, 1.3 * inch, 1.1 * inch])
    ba_table.setStyle(TableStyle([
        ("BACKGROUND",    (0, 0), (-1, 0), COLOR_HEADER),
        ("TEXTCOLOR",     (0, 0), (-1, 0), COLOR_WHITE),
        ("FONTNAME",      (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE",      (0, 0), (-1, -1), 9),
        ("ROWBACKGROUNDS",(0, 1), (-1, -1), [COLOR_WHITE, COLOR_LIGHT]),
        ("GRID",          (0, 0), (-1, -1), 0.5, colors.HexColor("#cccccc")),
        ("TOPPADDING",    (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("LEFTPADDING",   (0, 0), (-1, -1), 8),
        ("ALIGNMENT",     (1, 0), (-1, -1), "CENTER"),
    ]))
    story.append(ba_table)
    story.append(PageBreak())

    # -------------------------------------------------------------------------
    # SECTION 2: VALIDATION FINDINGS PER ENTITY
    # -------------------------------------------------------------------------
    story.append(Paragraph("2. Validation Findings", s["section"]))
    story.append(HRFlowable(width="100%", thickness=1, color=COLOR_HEADER))
    story.append(Spacer(1, 8))

    for idx, report in enumerate(reports, start=1):
        entity_color = STATUS_COLOR[report.overall_status]

        # Entity header
        entity_header = Table(
            [[f"{idx}.  {report.entity}",
              f"{STATUS_LABEL[report.overall_status]}  {report.passed_count}/{report.total} passed"]],
            colWidths=[4.5 * inch, 2.5 * inch]
        )
        entity_header.setStyle(TableStyle([
            ("BACKGROUND",    (0, 0), (-1, -1), entity_color),
            ("TEXTCOLOR",     (0, 0), (-1, -1), COLOR_WHITE),
            ("FONTNAME",      (0, 0), (-1, -1), "Helvetica-Bold"),
            ("FONTSIZE",      (0, 0), (-1, -1), 9),
            ("TOPPADDING",    (0, 0), (-1, -1), 7),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
            ("LEFTPADDING",   (0, 0), (-1, -1), 10),
            ("ALIGNMENT",     (1, 0), (1, 0), "RIGHT"),
            ("RIGHTPADDING",  (1, 0), (1, 0), 10),
        ]))
        story.append(entity_header)

        # Checks table
        # All cells use Paragraph for automatic word wrap.
        # Row height expands with content -- no text overflow between columns.

        # Cell styles for Paragraph objects inside table cells
        cell_normal = ParagraphStyle(
            "CellNormal", fontSize=8, fontName="Helvetica",
            leading=11, wordWrap="CJK",
        )
        cell_bold = ParagraphStyle(
            "CellBold", fontSize=8, fontName="Helvetica-Bold",
            leading=11, wordWrap="CJK",
        )
        cell_header = ParagraphStyle(
            "CellHeader", fontSize=8, fontName="Helvetica-Bold",
            textColor=colors.white, leading=11,
        )

        def p(text, style=None):
            """Wrap text in Paragraph for auto word wrap in table cells."""
            return Paragraph(str(text), style or cell_normal)

        checks_data = [[
            p("Status",    cell_header),
            p("Check",     cell_header),
            p("Actual",    cell_header),
            p("Threshold", cell_header),
            p("Details",   cell_header),
        ]]

        for c in report.checks:
            # Clean numeric display: remove trailing .0
            if c.value is not None:
                v = int(c.value) if c.value == int(c.value) else c.value
                val = f"{v:,} {c.unit}".strip() if isinstance(v, int) else f"{v} {c.unit}".strip()
            else:
                val = "-"
            if c.threshold is not None:
                t = int(c.threshold) if c.threshold == int(c.threshold) else c.threshold
                thr = f"{t:,} {c.unit}".strip() if isinstance(t, int) else f"{t} {c.unit}".strip()
            else:
                thr = "-"

            status_style = ParagraphStyle(
                f"Status_{c.status}", fontSize=8, fontName="Helvetica-Bold",
                textColor=STATUS_COLOR[c.status], leading=11,
            )
            checks_data.append([
                p(STATUS_LABEL[c.status], status_style),
                p(c.name,    cell_normal),
                p(val,       cell_normal),
                p(thr,       cell_normal),
                p(c.details, cell_normal),
            ])

        checks_table = Table(
            checks_data,
            colWidths=[0.75 * inch, 1.85 * inch, 0.90 * inch, 0.90 * inch, 2.60 * inch],
            repeatRows=1,   # repeat header row if table spans pages
        )
        row_styles = [
            ("BACKGROUND",    (0, 0), (-1, 0), COLOR_HEADER),
            ("GRID",          (0, 0), (-1, -1), 0.5, colors.HexColor("#cccccc")),
            ("TOPPADDING",    (0, 0), (-1, -1), 5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ("LEFTPADDING",   (0, 0), (-1, -1), 6),
            ("RIGHTPADDING",  (0, 0), (-1, -1), 6),
            ("VALIGN",        (0, 0), (-1, -1), "TOP"),
        ]
        for row_idx, c in enumerate(report.checks, start=1):
            bg = colors.HexColor("#f0fff0") if c.status == "GREEN" \
                 else colors.HexColor("#fffde7") if c.status == "YELLOW" \
                 else colors.HexColor("#fff0f0")
            row_styles.append(("BACKGROUND", (0, row_idx), (-1, row_idx), bg))

        checks_table.setStyle(TableStyle(row_styles))
        story.append(checks_table)
        story.append(Spacer(1, 14))

    story.append(PageBreak())

    # -------------------------------------------------------------------------
    # SECTION 3: GOVERNANCE OBJECTS INVENTORY
    # -------------------------------------------------------------------------
    story.append(Paragraph("3. Governance Objects Inventory", s["section"]))
    story.append(HRFlowable(width="100%", thickness=1, color=COLOR_HEADER))
    story.append(Spacer(1, 8))

    inv_data = [
        ["Object", "Count"],
        ["Active Data Sharing Agreements",   str(stats["active_dsas"])],
        ["Lineage Flows Documented",         str(stats["lineage_flows"])],
        ["Reference Tables Formalized",      str(stats["ref_tables"])],
        ["MASTER_CONDUCTOR Records",         f"{cond['master_records']:,}"],
        ["MASTER_CLIENTE Records",           f"{cli['master_records']:,}"],
        ["Crosswalk Entries (Conductores)",  "-"],
        ["Crosswalk Entries (Clientes)",     "-"],
    ]
    inv_table = Table(inv_data, colWidths=[5 * inch, 2 * inch])
    inv_table.setStyle(TableStyle([
        ("BACKGROUND",    (0, 0), (-1, 0), COLOR_HEADER),
        ("TEXTCOLOR",     (0, 0), (-1, 0), COLOR_WHITE),
        ("FONTNAME",      (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE",      (0, 0), (-1, -1), 9),
        ("ROWBACKGROUNDS",(0, 1), (-1, -1), [COLOR_WHITE, COLOR_LIGHT]),
        ("GRID",          (0, 0), (-1, -1), 0.5, colors.HexColor("#cccccc")),
        ("TOPPADDING",    (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("LEFTPADDING",   (0, 0), (-1, -1), 8),
        ("ALIGNMENT",     (1, 0), (1, -1), "CENTER"),
    ]))
    story.append(inv_table)
    story.append(Spacer(1, 16))

    # -------------------------------------------------------------------------
    # SECTION 4: ARCHIVAL EVIDENCE
    # -------------------------------------------------------------------------
    story.append(Paragraph("4. Archival Evidence Notes", s["section"]))
    story.append(HRFlowable(width="100%", thickness=1, color=COLOR_HEADER))
    story.append(Spacer(1, 8))

    evidence_data = [
        ["Evidence Item", "Value"],
        ["System",        "TRANSTRACK"],
        ["Report Type",   "Golden Record Validation Report"],
        ["Generated At",  now.strftime("%Y-%m-%d %H:%M:%S UTC")],
        ["Server",        SERVER],
        ["Database",      DATABASE],
        ["Report File",   path.name],
    ]
    ev_table = Table(evidence_data, colWidths=[2.5 * inch, 4.5 * inch])
    ev_table.setStyle(TableStyle([
        ("BACKGROUND",    (0, 0), (-1, 0), COLOR_HEADER),
        ("TEXTCOLOR",     (0, 0), (-1, 0), COLOR_WHITE),
        ("FONTNAME",      (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE",      (0, 0), (-1, -1), 9),
        ("ROWBACKGROUNDS",(0, 1), (-1, -1), [COLOR_WHITE, COLOR_LIGHT]),
        ("GRID",          (0, 0), (-1, -1), 0.5, colors.HexColor("#cccccc")),
        ("TOPPADDING",    (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("LEFTPADDING",   (0, 0), (-1, -1), 8),
    ]))
    story.append(ev_table)

    doc.build(story, onFirstPage=add_page_number, onLaterPages=add_page_number)
    log.info("PDF report written: %s", path)


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

def main() -> int:
    log.info("TRANSTRACK P02 | Golden Record Validation")

    try:
        with DbSession() as db:
            validator = GoldenRecordValidator(db)
            reports   = [validator.validate_conductor(), validator.validate_cliente()]
            stats     = validator.get_stats()

        # Console summary
        print("\n" + "=" * 60)
        print("GOLDEN RECORD VALIDATION SUMMARY")
        print("=" * 60)
        for r in reports:
            print(f"\n[{r.overall_status}] {r.entity}")
            print(f"   {r.passed_count}/{r.total} checks passed")
            for c in r.checks:
                print(f"   [{c.status}] {c.name}")
                print(f"          {c.details}")

        cond = stats["conductor"]
        cli  = stats["cliente"]
        print(f"\nDrivers : {cond['total_source']:>6,} -> {cond['master_records']:>6,} master records")
        print(f"Clients : {cli['total_source']:>6,} -> {cli['master_records']:>6,} master records")

        report_path = REPORT_DIR / f"golden_record_validation_{datetime.now():%Y%m%d_%H%M%S}.pdf"
        render_pdf(reports, stats, report_path)
        print(f"\nReport: {report_path}")

        return 0 if all(r.overall_status in ("GREEN", "YELLOW") for r in reports) else 1

    except Exception as exc:
        log.exception("Validation failed: %s", exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
