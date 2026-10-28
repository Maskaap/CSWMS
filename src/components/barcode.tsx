'use client';
import { useEffect, useState } from 'react';

/** Renders a CODE128 / EAN / QR symbol as SVG (crisp when printed). */
export function BarcodeSVG({ value, kind = 'code128', height = 12, text = true, className }: { value: string; kind?: 'code128' | 'qrcode' | 'ean13'; height?: number; text?: boolean; className?: string }) {
  const [svg, setSvg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    import('bwip-js/browser').then((bwip) => {
      try {
        const opts: Parameters<typeof bwip.toSVG>[0] = kind === 'qrcode'
          ? { bcid: 'qrcode', text: value, scale: 3 }
          : { bcid: kind === 'ean13' && /^\d{12,13}$/.test(value) ? 'ean13' : 'code128', text: value, scale: 2, height, includetext: text, textxalign: 'center', textsize: 9 };
        const out = bwip.toSVG(opts);
        if (live) { setSvg(out); setErr(null); }
      } catch (e) { if (live) setErr((e as Error).message); }
    });
    return () => { live = false; };
  }, [value, kind, height, text]);
  if (err) return <span className="text-xs text-bad-600">Cannot encode “{value}”</span>;
  if (!svg) return <span className="text-xs text-steel-400">…</span>;
  // bwip-js output is generated locally from the code value, not from user HTML
  return <span className={className} dangerouslySetInnerHTML={{ __html: svg }} />;
}
