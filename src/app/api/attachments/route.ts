import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';
import { supabaseAdmin } from '@/lib/supabase/admin';

export const dynamic = 'force-dynamic';
const TYPES = ['txn', 'stocktake_line', 'asset', 'stocktake'];
const MIMES = ['image/jpeg', 'image/png', 'image/webp'];
const MAX = 8 * 1024 * 1024;

/**
 * Upload a photo (damage, variance, tool condition …).
 * 1. The database checks, as the signed-in user, that they may add evidence to this record
 *    (register_attachment) and fixes the storage path.
 * 2. Only then the server stores the file in the PRIVATE bucket "evidence" with the secret key.
 * Users never get write access to storage directly.
 */
export async function POST(req: NextRequest) {
  const form = await req.formData().catch(() => null);
  const file = form?.get('file');
  const entityType = String(form?.get('entity_type') ?? '');
  const entityId = String(form?.get('entity_id') ?? '');
  const caption = form?.get('caption') ? String(form.get('caption')).slice(0, 200) : null;
  if (!(file instanceof File) || !TYPES.includes(entityType) || !/^[0-9a-f-]{36}$/i.test(entityId)) {
    return NextResponse.json({ error: 'Choose a photo to upload.' }, { status: 400 });
  }
  if (!MIMES.includes(file.type)) return NextResponse.json({ error: 'Only JPEG, PNG or WebP photos can be added.' }, { status: 400 });
  if (file.size <= 0 || file.size > MAX) return NextResponse.json({ error: 'The photo must be smaller than 8 MB.' }, { status: 400 });
  const bytes = new Uint8Array(await file.arrayBuffer());
  // magic numbers: the content must really be an image of the declared type
  const isJpeg = bytes[0] === 0xff && bytes[1] === 0xd8;
  const isPng = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  const isWebp = bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50;
  if (!((file.type === 'image/jpeg' && isJpeg) || (file.type === 'image/png' && isPng) || (file.type === 'image/webp' && isWebp))) {
    return NextResponse.json({ error: 'The file is not a valid photo.' }, { status: 400 });
  }

  const sb = await supabaseServer();
  const { data, error } = await sb.rpc('register_attachment', {
    p_entity_type: entityType, p_entity_id: entityId, p_mime: file.type, p_bytes: file.size, p_caption: caption,
  });
  if (error) return NextResponse.json({ error: error.message, code: error.code }, { status: error.code === 'CS401' || error.code === '42501' ? 403 : 400 });
  const reg = data as { id: string; storage_path: string };

  const admin = supabaseAdmin();
  let up = await admin.storage.from('evidence').upload(reg.storage_path, bytes, { contentType: file.type, upsert: false });
  if (up.error) up = await admin.storage.from('evidence').upload(reg.storage_path, bytes, { contentType: file.type, upsert: false });
  if (up.error) {
    await admin.rpc('log_system_event', { p_source: 'attachments', p_event: 'upload_failed', p_ok: false, p_detail: { id: reg.id, error: up.error.message } });
    return NextResponse.json({ error: 'The photo could not be stored. Try again.' }, { status: 502 });
  }
  return NextResponse.json({ ok: true, id: reg.id });
}
