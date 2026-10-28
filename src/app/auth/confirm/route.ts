import { NextResponse, type NextRequest } from 'next/server';
import type { EmailOtpType } from '@supabase/supabase-js';
import { supabaseServer } from '@/lib/supabase/server';

// Handles invitation, password-recovery and e-mail-change links that use token_hash
// (see docs/DEPLOYMENT.md for the e-mail templates).
export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const token_hash = url.searchParams.get('token_hash');
  const type = url.searchParams.get('type') as EmailOtpType | null;
  const next = url.searchParams.get('next') ?? '/';
  const safeNext = next.startsWith('/') ? next : '/';
  if (token_hash && type) {
    const supabase = await supabaseServer();
    const { error } = await supabase.auth.verifyOtp({ type, token_hash });
    if (!error) return NextResponse.redirect(new URL(type === 'invite' || type === 'recovery' ? '/reset-password' : safeNext, url.origin));
  }
  return NextResponse.redirect(new URL('/login?error=link', url.origin));
}
