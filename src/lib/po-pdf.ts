'use client';
// Printable / e-mailable purchase order document (PDF), generated in the browser.
type Head = { po_no: string; status: string; supplier_name: string; supplier_email: string | null; warehouse_code: string; warehouse_name: string;
  owner_company_code: string; expected_date: string | null; supplier_reference: string | null; notes: string | null; created_at: string;
  approved_by_name: string | null; approved_at: string | null; total_value: number };
type Line = { line_no: number; sku: string; description: string; qty_ordered: number; uom_code: string; unit_price: number; line_value: number };

export async function downloadPoPdf(org: string, h: Head, lines: Line[]) {
  const { jsPDF } = await import('jspdf');
  const autoTable = (await import('jspdf-autotable')).default;
  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const d = (v: string | null) => (v ? new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Johannesburg', day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date(v.length === 10 ? v + 'T12:00:00' : v)) : '—');
  const zar = new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR' });
  doc.setFontSize(18); doc.text('PURCHASE ORDER', 40, 50);
  doc.setFontSize(11); doc.text(h.po_no, 40, 68);
  doc.setFontSize(9); doc.setTextColor(80);
  doc.text(`${org} — buying company ${h.owner_company_code}`, 40, 86);
  if (h.status === 'draft' || h.status === 'pending_approval') { doc.setTextColor(180, 35, 24); doc.text('NOT APPROVED — DO NOT SUPPLY', 380, 50); doc.setTextColor(80); }
  const info: [string, string][] = [
    ['Supplier', h.supplier_name + (h.supplier_email ? ` (${h.supplier_email})` : '')], ['Deliver to', `${h.warehouse_code} — ${h.warehouse_name}`],
    ['Order date', d(h.created_at)], ['Expected delivery', d(h.expected_date)], ['Supplier reference', h.supplier_reference ?? '—'],
    ['Approved', h.approved_by_name ? `${h.approved_by_name}, ${d(h.approved_at)}` : '—'],
  ];
  info.forEach(([k, v], i) => { doc.setTextColor(110); doc.text(k, 40, 110 + i * 14); doc.setTextColor(20); doc.text(v, 150, 110 + i * 14); });
  autoTable(doc, {
    startY: 110 + info.length * 14 + 10,
    head: [['#', 'Code', 'Description', 'Qty', 'Unit', 'Unit price', 'Amount']],
    body: lines.map((l) => [l.line_no, l.sku, l.description, new Intl.NumberFormat('en-ZA', { maximumFractionDigits: 4 }).format(Number(l.qty_ordered)), l.uom_code, zar.format(Number(l.unit_price)), zar.format(Number(l.line_value))]),
    foot: [['', '', '', '', '', 'Total excl. VAT', zar.format(Number(h.total_value))]],
    styles: { fontSize: 8.5 }, headStyles: { fillColor: [21, 35, 63] }, footStyles: { fillColor: [243, 245, 248], textColor: 20, fontStyle: 'bold' },
    columnStyles: { 0: { cellWidth: 22 }, 3: { halign: 'right' }, 5: { halign: 'right' }, 6: { halign: 'right' } },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const y = (doc as any).lastAutoTable.finalY + 24;
  doc.setFontSize(9); doc.setTextColor(60);
  if (h.notes) doc.text(doc.splitTextToSize('Notes: ' + h.notes, 515), 40, y);
  doc.text('Please quote the order number on your delivery note and invoice.', 40, y + 40);
  doc.save(`${h.po_no}.pdf`);
}
