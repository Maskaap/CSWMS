'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Camera, ImageOff, X } from 'lucide-react';
import { Button, Input, Notice, cx } from './ui';
import { callRpc } from '@/hooks/use-transaction';
import { useOnline } from '@/hooks/use-online';
import { fmtDateTime } from '@/lib/format';

type Att = { id: string; caption: string | null; created_at: string; uploaded_by: string };

/** shrink a phone photo (often 4–8 MB) to a clear ~1600 px JPEG before upload */
async function compress(file: File): Promise<Blob> {
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale);
    c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
    const blob = await new Promise<Blob | null>((r) => c.toBlob(r, 'image/jpeg', 0.82));
    return blob ?? file;
  } catch {
    return file;
  }
}

/**
 * Photo evidence for a record (damage, stocktake variance, tool condition …).
 * Photos are private: each view is checked by the database and opened through a
 * short-lived link. Photos cannot be deleted (evidence) — add a corrected one instead.
 */
export function Photos({ entityType, entityId, title = 'Photos', canAdd = true, compact }: {
  entityType: 'txn' | 'stocktake_line' | 'asset' | 'stocktake'; entityId: string; title?: string; canAdd?: boolean; compact?: boolean;
}) {
  const online = useOnline();
  const [list, setList] = useState<Att[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [caption, setCaption] = useState('');
  const [view, setView] = useState<Att | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const load = useCallback(async () => {
    const { data } = await callRpc<Att[]>('list_attachments', { p_entity_type: entityType, p_entity_id: entityId });
    setList(data ?? []);
  }, [entityType, entityId]);
  useEffect(() => { void load(); }, [load]);

  const upload = async (f: File | undefined) => {
    if (!f) return;
    setBusy(true); setErr(null);
    try {
      const blob = await compress(f);
      const fd = new FormData();
      fd.append('file', new File([blob], 'photo.jpg', { type: blob.type || 'image/jpeg' }));
      fd.append('entity_type', entityType); fd.append('entity_id', entityId);
      if (caption.trim()) fd.append('caption', caption.trim());
      const r = await fetch('/api/attachments', { method: 'POST', body: fd });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(j.error ?? 'Upload failed');
      setCaption('');
      await load();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  };

  return (
    <div className={cx(!compact && 'rounded-lg border border-steel-200 bg-white p-4')}>
      {!compact && <div className="mb-2 text-sm font-semibold text-navy-900">{title} {list.length > 0 && <span className="font-normal text-steel-600">({list.length})</span>}</div>}
      {list.length > 0 && (
        <ul className="mb-3 flex flex-wrap gap-2">
          {list.map((a) => (
            <li key={a.id}>
              <button type="button" onClick={() => setView(a)} className="block size-20 overflow-hidden rounded-md border border-steel-200 bg-steel-50" aria-label={a.caption ?? 'Photo'}>
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={`/api/attachments/${a.id}`} alt={a.caption ?? 'Photo'} className="size-full object-cover" loading="lazy" />
              </button>
            </li>
          ))}
        </ul>
      )}
      {canAdd && (
        <div className="flex flex-wrap items-center gap-2">
          <Input value={caption} onChange={(e) => setCaption(e.target.value)} placeholder="What does the photo show? (optional)" className="max-w-xs" maxLength={200} />
          <input ref={fileRef} type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => upload(e.target.files?.[0])} />
          <Button size="sm" variant="navy" busy={busy} disabled={!online || list.length >= 10} onClick={() => fileRef.current?.click()}>
            <Camera className="size-4" />Add photo
          </Button>
          {!online && <span className="text-xs text-steel-600">Photos need a connection.</span>}
        </div>
      )}
      {err && <Notice tone="bad" className="mt-2">{err}</Notice>}
      {view && (
        <div className="fixed inset-0 z-50 flex flex-col bg-navy-950/90 p-4" role="dialog" aria-label="Photo" onClick={() => setView(null)}>
          <div className="mb-2 flex items-center justify-between text-white">
            <span className="text-sm">{view.caption ?? 'Photo'} · {view.uploaded_by} · {fmtDateTime(view.created_at)}</span>
            <Button size="sm" onClick={() => setView(null)}><X className="size-4" />Close</Button>
          </div>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={`/api/attachments/${view.id}`} alt={view.caption ?? 'Photo'} className="m-auto max-h-full max-w-full rounded object-contain"
            onError={(e) => { (e.target as HTMLImageElement).replaceWith(Object.assign(document.createElement('div'), { className: 'm-auto text-white', textContent: 'The photo is not available.' })); }} />
        </div>
      )}
      {list.length === 0 && !canAdd && <p className="flex items-center gap-1 text-sm text-steel-600"><ImageOff className="size-4" />No photos.</p>}
    </div>
  );
}
