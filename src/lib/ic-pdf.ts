'use client';
// Inter-company order and (tax) invoice / credit note documents, generated in the browser as PDF.
export type Party = { code: string; name: string; legal_name: string; address: string | null; vat_number: string | null;
  registration_number: string | null; email: string | null; phone: string | null };

const zar = new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR' });
const num = new Intl.NumberFormat('en-ZA', { maximumFractionDigits: 4 });
const d = (v: string | null | undefined) => (v ? new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Johannesburg', day: '2-digit', month: '2-digit', year: 'numeric' })
  .format(new Date(v.length === 10 ? v + 'T12:00:00' : v)) : '—');

async function lib() {
  const { jsPDF } = await import('jspdf');
  const autoTable = (await import('jspdf-autotable')).default;
  return { doc: new jsPDF({ unit: 'pt', format: 'a4' }), autoTable };
}

type Doc = InstanceType<typeof import('jspdf').jsPDF>;
function partyBlock(doc: Doc, x: number, y: number, label: string, p: Party) {
  doc.setFontSize(8); doc.setTextColor(110); doc.text(label, x, y);
  doc.setFontSize(10); doc.setTextColor(20); doc.text(p.legal_name || p.name, x, y + 14);
  doc.setFontSize(8.5); doc.setTextColor(60);
  const rows = [
    ...(p.address ? doc.splitTextToSize(p.address, 230) as string[] : []),
    p.vat_number ? `VAT no. ${p.vat_number}` : null,
    p.registration_number ? `Reg. no. ${p.registration_number}` : null,
    [p.phone, p.email].filter(Boolean).join(' · ') || null,
  ].filter(Boolean) as string[];
  rows.forEach((r, i) => doc.text(r, x, y + 28 + i * 11));
  return y + 28 + rows.length * 11;
}

export type OrderDoc = { order_no: string; status: string; requested_at: string; needed_by: string | null; reference: string | null; notes: string | null;
  buyer: Party; seller: Party; from_warehouse: { code: string; name: string }; to_warehouse: { code: string; name: string };
  requested_by_name: string | null; decided_by_name: string | null; decided_at: string | null; show_prices: boolean; value: number | null;
  lines: { line_no: number; sku: string; description: string; entered_qty: number; entered_uom: string; qty_base: number; base_uom: string; unit_price: number | null; line_value: number | null }[] };

export async function downloadIcOrderPdf(o: OrderDoc) {
  const { doc, autoTable } = await lib();
  doc.setFontSize(18); doc.setTextColor(20); doc.text('INTER-COMPANY ORDER', 40, 50);
  doc.setFontSize(11); doc.text(o.order_no, 40, 68);
  if (o.status === 'submitted') { doc.setFontSize(9); doc.setTextColor(180, 35, 24); doc.text('NOT YET APPROVED BY THE SUPPLYING COMPANY', 330, 50); }
  if (o.status === 'rejected' || o.status === 'cancelled') { doc.setFontSize(9); doc.setTextColor(180, 35, 24); doc.text(o.status.toUpperCase() + ' — DO NOT SUPPLY', 330, 50); }
  const y1 = partyBlock(doc, 40, 96, 'ORDERED BY (BUYER)', o.buyer);
  const y2 = partyBlock(doc, 310, 96, 'SUPPLIED BY (SELLER)', o.seller);
  let y = Math.max(y1, y2) + 14;
  const info: [string, string][] = [
    ['Order date', d(o.requested_at)], ['Needed by', d(o.needed_by)], ['Supply from', `${o.from_warehouse.code} — ${o.from_warehouse.name}`],
    ['Deliver to', `${o.to_warehouse.code} — ${o.to_warehouse.name}`], ['Reference', o.reference ?? '—'],
    ['Requested by', o.requested_by_name ?? '—'], ['Approved', o.decided_by_name ? `${o.decided_by_name}, ${d(o.decided_at)}` : '—'],
  ];
  doc.setFontSize(9);
  info.forEach(([k, v], i) => { doc.setTextColor(110); doc.text(k, 40, y + i * 13); doc.setTextColor(20); doc.text(v, 140, y + i * 13); });
  y += info.length * 13 + 8;
  const head = o.show_prices ? [['#', 'Code', 'Description', 'Qty', 'Unit', 'Base qty', 'Price / base unit', 'Amount']] : [['#', 'Code', 'Description', 'Qty', 'Unit', 'Base qty']];
  autoTable(doc, {
    startY: y, head,
    body: o.lines.map((l) => [l.line_no, l.sku, l.description, num.format(Number(l.entered_qty)), l.entered_uom, `${num.format(Number(l.qty_base))} ${l.base_uom}`,
      ...(o.show_prices ? [zar.format(Number(l.unit_price ?? 0)), zar.format(Number(l.line_value ?? 0))] : [])]),
    foot: o.show_prices ? [['', '', '', '', '', '', 'Total excl. VAT', zar.format(Number(o.value ?? 0))]] : undefined,
    styles: { fontSize: 8.5 }, headStyles: { fillColor: [21, 35, 63] }, footStyles: { fillColor: [243, 245, 248], textColor: 20, fontStyle: 'bold' },
    columnStyles: { 0: { cellWidth: 22 }, 3: { halign: 'right' }, 5: { halign: 'right' }, 6: { halign: 'right' }, 7: { halign: 'right' } },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const fy = (doc as any).lastAutoTable.finalY + 22;
  doc.setFontSize(8.5); doc.setTextColor(60);
  if (o.notes) doc.text(doc.splitTextToSize('Notes: ' + o.notes, 515), 40, fy);
  doc.text('Ownership passes to the buyer when the stock is received. The seller invoices what is received (good and damaged in transit).', 40, fy + 30);
  doc.save(`${o.order_no}.pdf`);
}

export type InvoiceDoc = { title: string; invoice_no: string; kind: string; issue_date: string; due_date: string; seller_snapshot: Party; buyer_snapshot: Party;
  vat_rate: number; subtotal: number; vat_amount: number; total: number; reason: string | null; order_no: string | null; original_invoice_no: string | null;
  receipt_txn_no: string | null; transfer: { transfer_no: string; from: string; to: string } | null; status: string; paid_on: string | null; paid_reference: string | null;
  lines: { line_no: number; description: string; qty: number; uom: string; unit_price: number; line_total: number }[] };

export async function downloadIcInvoicePdf(i: InvoiceDoc) {
  const { doc, autoTable } = await lib();
  doc.setFontSize(18); doc.setTextColor(20); doc.text(i.title, 40, 50);
  doc.setFontSize(11); doc.text(i.invoice_no, 40, 68);
  doc.setFontSize(9); doc.setTextColor(60);
  doc.text(`Date: ${d(i.issue_date)}`, 400, 50);
  if (i.kind === 'invoice') doc.text(`Due: ${d(i.due_date)}`, 400, 63);
  if (i.status === 'paid') { doc.setTextColor(30, 127, 79); doc.text(`PAID ${d(i.paid_on)} · ${i.paid_reference ?? ''}`, 400, 76); }
  if (i.status === 'credited') { doc.setTextColor(180, 35, 24); doc.text('FULLY CREDITED', 400, 76); }
  const y1 = partyBlock(doc, 40, 96, 'FROM (SUPPLIER)', i.seller_snapshot);
  const y2 = partyBlock(doc, 310, 96, 'TO (RECIPIENT)', i.buyer_snapshot);
  let y = Math.max(y1, y2) + 14;
  const info: [string, string][] = [
    ...(i.original_invoice_no ? [['Credit against invoice', i.original_invoice_no] as [string, string]] : []),
    ...(i.reason ? [['Reason', i.reason] as [string, string]] : []),
    ['Order', i.order_no ?? '—'], ['Transfer', i.transfer ? `${i.transfer.transfer_no}: ${i.transfer.from} → ${i.transfer.to}` : '—'],
    ...(i.receipt_txn_no ? [['Goods received', i.receipt_txn_no] as [string, string]] : []),
  ];
  doc.setFontSize(9);
  info.forEach(([k, v], n) => { doc.setTextColor(110); doc.text(k, 40, y + n * 13); doc.setTextColor(20); doc.text(String(v).slice(0, 95), 160, y + n * 13); });
  y += info.length * 13 + 8;
  autoTable(doc, {
    startY: y,
    head: [['#', 'Description', 'Qty', 'Unit', 'Unit price excl. VAT', 'Amount excl. VAT']],
    body: i.lines.map((l) => [l.line_no, l.description, num.format(Number(l.qty)), l.uom, zar.format(Number(l.unit_price)), zar.format(Number(l.line_total))]),
    foot: [
      ['', '', '', '', 'Total excl. VAT', zar.format(Number(i.subtotal))],
      ['', '', '', '', `VAT ${num.format(Number(i.vat_rate))} %`, zar.format(Number(i.vat_amount))],
      ['', '', '', '', i.kind === 'credit_note' ? 'Total credited' : 'Total due incl. VAT', zar.format(Number(i.total))],
    ],
    styles: { fontSize: 8.5 }, headStyles: { fillColor: [21, 35, 63] }, footStyles: { fillColor: [243, 245, 248], textColor: 20, fontStyle: 'bold' },
    columnStyles: { 0: { cellWidth: 22 }, 2: { halign: 'right' }, 4: { halign: 'right' }, 5: { halign: 'right' } },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const fy = (doc as any).lastAutoTable.finalY + 24;
  doc.setFontSize(8.5); doc.setTextColor(60);
  doc.text(i.kind === 'credit_note' ? 'This credit note reduces the amount owed on the invoice named above.'
    : `Inter-company supply of goods. Please pay by ${d(i.due_date)} quoting ${i.invoice_no}.`, 40, fy);
  doc.save(`${i.invoice_no}.pdf`);
}
