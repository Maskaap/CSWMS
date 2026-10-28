import { NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';
import { SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL } from '@/lib/env';

export const dynamic = 'force-dynamic';

/** Liveness + database connectivity probe for uptime monitoring (no data is exposed). */
export async function GET() {
  const started = Date.now();
  try {
    const sb = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
    // Anonymous access is refused by design (401/403) — any non-5xx answer proves the API and database are up.
    const { status } = await sb.from('provinces').select('id', { head: true, count: 'exact' }).limit(1);
    const ok = status > 0 && status < 500;
    return NextResponse.json({ ok, database: ok ? 'reachable' : 'error', ms: Date.now() - started }, { status: ok ? 200 : 503 });
  } catch {
    return NextResponse.json({ ok: false, database: 'unreachable', ms: Date.now() - started }, { status: 503 });
  }
}
