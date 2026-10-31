import { NextResponse, type NextRequest } from 'next/server';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { SITE_URL } from '@/lib/env';

export const dynamic = 'force-dynamic';
export const maxDuration = 300;

/**
 * Called by Vercel Cron (see vercel.json) with "Authorization: Bearer $CRON_SECRET".
 *  1. Runs the database dispatcher (idempotent): starts the Daily Stock Integrity
 *     check when due, retries failures, raises watchdog alerts. pg_cron runs the
 *     same dispatcher inside the database every 15 minutes; this is a second,
 *     independent trigger so a single scheduler failure cannot silently stop checks.
 *  2. Delivers queued alert e-mails (Resend), recording success or failure.
 *  3. Delivers queued WhatsApp alerts (WhatsApp Cloud API, approved template), same way.
 * On the Vercel Hobby plan this cron runs once a day; for prompt e-mail/WhatsApp delivery
 * call this URL every 10–15 minutes from an external scheduler (docs/DEPLOYMENT.md § 4).
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
  out.whatsapp = await deliverWhatsApp(admin);
  return NextResponse.json({ ok: !d.error, ...out });
}

/** WhatsApp template parameters may not contain new lines, tabs or long runs of spaces */
const clean = (s: string, max: number) => s.replace(/[\r\n\t]+/g, ' ').replace(/ {4,}/g, '   ').trim().slice(0, max);

async function deliverWhatsApp(admin: ReturnType<typeof supabaseAdmin>) {
  const token = process.env.WHATSAPP_TOKEN;
  const phoneId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  const template = process.env.WHATSAPP_TEMPLATE ?? 'cswms_alert';
  const lang = process.env.WHATSAPP_TEMPLATE_LANG ?? 'en';
  if (!token || !phoneId) return 'not configured (WHATSAPP_TOKEN / WHATSAPP_PHONE_NUMBER_ID)';
  const { data, error } = await admin.rpc('message_outbox_claim', { p_limit: 40 });
  if (error) return { error: error.message };
  let sent = 0; let failed = 0;
  for (const m of (data ?? []) as { id: string; to_phone: string; title: string; body: string; link: string | null }[]) {
    try {
      const body = clean(m.body + (m.link ? ` ${SITE_URL}${m.link}` : ''), 900);
      const r = await fetch(`https://graph.facebook.com/v21.0/${phoneId}/messages`, {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify({
          messaging_product: 'whatsapp', to: m.to_phone.replace(/^\+/, ''), type: 'template',
          template: { name: template, language: { code: lang },
            components: [{ type: 'body', parameters: [{ type: 'text', text: clean(m.title, 200) }, { type: 'text', text: body }] }] },
        }),
      });
      if (!r.ok) throw new Error(`${r.status} ${(await r.text()).slice(0, 300)}`);
      await admin.rpc('message_outbox_result', { p_id: m.id, p_ok: true });
      sent++;
    } catch (e) {
      await admin.rpc('message_outbox_result', { p_id: m.id, p_ok: false, p_error: String((e as Error).message ?? e) });
      failed++;
    }
  }
  if (sent || failed) await admin.rpc('log_system_event', { p_source: 'whatsapp', p_event: 'deliver', p_ok: failed === 0, p_detail: { sent, failed } });
  return { sent, failed };
}
