'use client';
// Report exports: CSV, Excel (.xlsx) and PDF. All generated in the browser
// from the rows the user is authorised to see (RLS has already filtered them).

export type Col<T = Record<string, unknown>> = {
  key: string;
  label: string;
  num?: boolean;
  get?: (row: T) => unknown;
  width?: number;
};

function cell<T>(row: T, c: Col<T>): unknown {
  const v = c.get ? c.get(row) : (row as Record<string, unknown>)[c.key];
  return v === undefined ? null : v;
}

function fileName(base: string, ext: string) {
  const d = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Johannesburg' }).format(new Date());
  return `${base.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '')}-${d}.${ext}`;
}

function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = name;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

export function exportCSV<T>(title: string, cols: Col<T>[], rows: T[]) {
  const esc = (v: unknown) => {
    if (v === null || v === undefined) return '';
    let s = typeof v === 'object' ? JSON.stringify(v) : String(v);
    // neutralise spreadsheet formula injection
    if (/^[=+\-@\t\r]/.test(s) && !/^-?\d+(\.\d+)?$/.test(s)) s = "'" + s;
    return /[",\n;]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [cols.map((c) => esc(c.label)).join(','), ...rows.map((r) => cols.map((c) => esc(cell(r, c))).join(','))];
  download(new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' }), fileName(title, 'csv'));
}

export async function exportXLSX<T>(title: string, cols: Col<T>[], rows: T[], meta?: string) {
  const ExcelJS = (await import('exceljs')).default;
  const wb = new ExcelJS.Workbook();
  wb.creator = 'CSWMS';
  wb.created = new Date();
  const ws = wb.addWorksheet(title.slice(0, 31).replace(/[\\/*?:[\]]/g, ' '));
  ws.addRow([title]).font = { bold: true, size: 14 };
  ws.addRow([meta ?? `Generated ${new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Johannesburg', dateStyle: 'short', timeStyle: 'short' }).format(new Date())} (Africa/Johannesburg)`]);
  ws.addRow([]);
  const header = ws.addRow(cols.map((c) => c.label));
  header.font = { bold: true, color: { argb: 'FFFFFFFF' } };
  header.eachCell((c) => { c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF15233F' } }; });
  for (const r of rows) {
    ws.addRow(cols.map((c) => {
      const v = cell(r, c);
      if (c.num && v !== null && v !== '' && !isNaN(Number(v))) return Number(v);
      if (v !== null && typeof v === 'object') return JSON.stringify(v);
      return v as string | number | null;
    }));
  }
  cols.forEach((c, i) => {
    const col = ws.getColumn(i + 1);
    col.width = c.width ?? Math.min(48, Math.max(10, c.label.length + 2, ...rows.slice(0, 200).map((r) => String(cell(r, c) ?? '').length + 2)));
    if (c.num) col.numFmt = '#,##0.####';
  });
  ws.views = [{ state: 'frozen', ySplit: 4 }];
  ws.autoFilter = { from: { row: 4, column: 1 }, to: { row: 4, column: cols.length } };
  const buf = await wb.xlsx.writeBuffer();
  download(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), fileName(title, 'xlsx'));
}

export async function exportPDF<T>(title: string, cols: Col<T>[], rows: T[], subtitle?: string) {
  const { jsPDF } = await import('jspdf');
  const autoTable = (await import('jspdf-autotable')).default;
  const doc = new jsPDF({ orientation: cols.length > 6 ? 'landscape' : 'portrait', unit: 'pt', format: 'a4' });
  doc.setFontSize(14);
  doc.text(`CSWMS — ${title}`, 40, 40);
  doc.setFontSize(9);
  doc.setTextColor(90);
  doc.text(subtitle ?? `Generated ${new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Johannesburg', dateStyle: 'short', timeStyle: 'short' }).format(new Date())} · ${rows.length} rows`, 40, 56);
  const fmt = new Intl.NumberFormat('en-ZA', { maximumFractionDigits: 4 });
  autoTable(doc, {
    startY: 68,
    head: [cols.map((c) => c.label)],
    body: rows.map((r) => cols.map((c) => {
      const v = cell(r, c);
      if (v === null || v === undefined) return '';
      if (c.num && !isNaN(Number(v))) return fmt.format(Number(v));
      return typeof v === 'object' ? JSON.stringify(v) : String(v);
    })),
    styles: { fontSize: 7.5, cellPadding: 3 },
    headStyles: { fillColor: [21, 35, 63] },
    columnStyles: Object.fromEntries(cols.map((c, i) => [i, c.num ? { halign: 'right' } : {}])),
    didDrawPage: () => {
      const n = doc.getNumberOfPages();
      doc.setFontSize(8);
      doc.text(`Page ${n}`, doc.internal.pageSize.getWidth() - 70, doc.internal.pageSize.getHeight() - 20);
    },
  });
  doc.save(fileName(title, 'pdf'));
}
