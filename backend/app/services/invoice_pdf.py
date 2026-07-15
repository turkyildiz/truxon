"""Simple invoice PDF generation with reportlab."""

import io
from decimal import Decimal

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet

from app.models import Invoice

NAVY = colors.HexColor("#1e3a5f")


def build_invoice_pdf(invoice: Invoice, company_name: str = "TrucksOn Logistics") -> bytes:
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=letter, topMargin=0.75 * inch, bottomMargin=0.75 * inch)
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle("Company", parent=styles["Title"], textColor=NAVY, spaceAfter=2)

    story = [
        Paragraph(company_name, title_style),  # logo placeholder — replace with Image() later
        Paragraph(f"<b>INVOICE {invoice.invoice_number}</b>", styles["Heading2"]),
        Spacer(1, 8),
        Paragraph(f"<b>Bill To:</b> {invoice.customer.company_name}", styles["Normal"]),
        Paragraph(invoice.customer.billing_address.replace("\n", "<br/>"), styles["Normal"]),
        Paragraph(f"<b>Date:</b> {invoice.invoice_date:%B %d, %Y}", styles["Normal"]),
    ]
    if invoice.due_date:
        story.append(Paragraph(f"<b>Due:</b> {invoice.due_date:%B %d, %Y}", styles["Normal"]))
    story.append(Paragraph(f"<b>Terms:</b> {invoice.customer.payment_terms}", styles["Normal"]))
    story.append(Spacer(1, 16))

    rows = [["Load #", "Pickup", "Delivery", "Miles", "Rate/Mile", "Amount"]]
    for load in invoice.loads:
        rpm = load.rate_per_mile
        rows.append([
            load.load_number,
            (load.pickup_address or "")[:38],
            (load.delivery_address or "")[:38],
            f"{load.miles:,.1f}",
            f"${rpm:,.2f}" if rpm is not None else "—",
            f"${Decimal(load.rate):,.2f}",
        ])
    rows.append(["", "", "", "", "TOTAL", f"${Decimal(invoice.total):,.2f}"])

    table = Table(rows, colWidths=[0.95 * inch, 2.1 * inch, 2.1 * inch, 0.6 * inch, 0.75 * inch, 0.9 * inch])
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), NAVY),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTSIZE", (0, 0), (-1, -1), 8),
        ("GRID", (0, 0), (-1, -2), 0.5, colors.grey),
        ("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold"),
        ("ROWBACKGROUNDS", (0, 1), (-1, -2), [colors.white, colors.HexColor("#f0f4f8")]),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    story.append(table)

    doc.build(story)
    return buf.getvalue()
