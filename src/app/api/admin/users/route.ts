import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { SITE_URL } from '@/lib/env';

/**
 * Invite a new employee. Only callers who hold users.manage may do this.
 * 1. Verify the caller's session and permission (checked in the database).
 * 2. Create the auth account with an invitation e-mail (secret key, server only).
 * 3. Create the CSWMS profile AS THE CALLER, so the database applies its own
 *    permission and scope checks and records who did it.
 */
export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => null) as { email?: string; full_name?: string; employee_number?: string; phone?: string } | null;
  const email = body?.email?.trim().toLowerCase() ?? '';
  const name = body?.full_name?.trim() ?? '';
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !name) {
    return NextResponse.json({ error: 'A valid e-mail address and full name are required.' }, { status: 400 });
  }

  const sb = await supabaseServer();
  const { data: claims } = await sb.auth.getClaims();
  if (!claims?.claims) return NextResponse.json({ error: 'Not signed in.' }, { status: 401 });
  const { data: ctx, error: ctxErr } = await sb.rpc('my_context');
  if (ctxErr || !(ctx?.permissions ?? []).includes('users.manage')) {
    return NextResponse.json({ error: 'You do not have permission to add users.' }, { status: 403 });
  }

  const admin = supabaseAdmin();
  let userId: string | null = null;
  const invited = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo: `${SITE_URL}/auth/confirm?next=/reset-password`,
    data: { full_name: name },
  });
  if (invited.error) {
    // Already has an auth account (e.g. re-invite): look it up instead of failing.
    if (/already|registered|exists/i.test(invited.error.message)) {
      const { data: list } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
      userId = list?.users.find((u) => u.email?.toLowerCase() === email)?.id ?? null;
    }
    if (!userId) return NextResponse.json({ error: `Invitation failed: ${invited.error.message}` }, { status: 400 });
  } else {
    userId = invited.data.user?.id ?? null;
  }

  const { error } = await sb.rpc('admin_upsert_user', {
    p_user_id: userId, p_email: email, p_full_name: name,
    p_employee_number: body?.employee_number?.trim() || null, p_phone: body?.phone?.trim() || null, p_is_active: true,
  });
  if (error) return NextResponse.json({ error: error.message, code: error.code }, { status: 400 });
  return NextResponse.json({ ok: true, user_id: userId });
}
