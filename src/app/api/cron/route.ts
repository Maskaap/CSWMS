import { NextResponse, type NextRequest } from 'next/server';
import { supabaseAdmin } from '@/lib/supabase/admin';

export const dynamic = 'force-dynamic';
export const maxDuration = 300;

/**
 * Called by Vercel Cron (see vercel.json) with "Authorization: Bearer $CRON_SECRET".
 *  1. Runs the database dispatcher (idempotent): starts the Daily Stock Integrity
 *     check when due, retries failures, raises watchdog alerts. pg_cron runs the
 *     same dispatcher inside the database every 15 minutes; this is a second,
 *     independent trigger so a single scheduler failure cannot silently stop checks.
 *  2. Delivers queued alert e-mails (Resend), recording success or failure.
 */
export async function GET(req: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (!secret || req.headers.get('authorization') !== `Bearer ${secret}`) {
    return NextResponse.json({ error: 'unauthorised' }, { status: 401 });
  }
  const admin = supabaseAdmin();
  const out: Record<string, unknown> = {};

  const d = await admin.rpc('cron_dispatch');
  out.dispatch = d.error ? { error: d.error.message } : d.data;
  await admin.rpc('log_system_event', { p_source: 'cron', p_event: 'dispatch', p_ok: !d.error, p_detail: d.error ? { error: d.error.message } : null });

  const key = process.env.RESEND_API_KEY;
  const from = process.env.ALERT_EMAIL_FROM;
  if (key && from) {
    const { data: mails, error } = await admin.rpc('email_outbox_claim', { p_limit: 40 });
    if (error) out.email = { error: error.message };
    else {
      let sent = 0; let failed = 0;
      for (const m of (mails ?? []) as { id: string; to_email: string; subject: string; body_text: string }[]) {
        try {
          const r = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
            body: JSON.stringify({ from, to: [m.to_email], subject: m.subject, text: m.body_text }),
          });
          if (!r.ok) throw new Error(`${r.status} ${(await r.text()).slice(0, 300)}`);
          await admin.rpc('email_outbox_result', { p_id: m.id, p_ok: true });
          sent++;
        } catch (e) {
          await admin.rpc('email_outbox_result', { p_id: m.id, p_ok: false, p_error: String((e as Error).message ?? e) });
          failed++;
        }
      }
      out.email = { sent, failed };
      if (sent || failed) await admin.rpc('log_system_event', { p_source: 'email', p_event: 'deliver', p_ok: failed === 0, p_detail: { sent, failed } });
    }
  } else {
    out.email = 'not configured (RESEND_API_KEY / ALERT_EMAIL_FROM)';
  }
  return NextResponse.json({ ok: !d.error, ...out });
}
