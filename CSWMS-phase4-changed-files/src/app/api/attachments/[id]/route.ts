import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';
import { supabaseAdmin } from '@/lib/supabase/admin';

export const dynamic = 'force-dynamic';

/** Open a photo: the database decides whether this user may see it; the link expires after 5 minutes. */
export async function GET(_req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const { id } = await ctx.params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) return NextResponse.json({ error: 'not found' }, { status: 404 });
  const sb = await supabaseServer();
  const { data: path, error } = await sb.rpc('attachment_path', { p_id: id });
  if (error || !path) return NextResponse.json({ error: 'not found' }, { status: 404 });
  const { data, error: e2 } = await supabaseAdmin().storage.from('evidence').createSignedUrl(String(path), 300);
  if (e2 || !data?.signedUrl) return NextResponse.json({ error: 'not available' }, { status: 404 });
  const res = NextResponse.redirect(data.signedUrl, 302);
  res.headers.set('cache-control', 'private, max-age=240');
  return res;
}
