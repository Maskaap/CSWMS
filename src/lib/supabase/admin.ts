import 'server-only';
import { createClient } from '@supabase/supabase-js';
import { SUPABASE_URL, serverSecretKey } from '../env';

/**
 * Privileged server client (secret / service-role key). Bypasses RLS.
 * Used ONLY for: creating auth users (invitations), the cron job, and nothing else.
 * Never import this from a client component.
 */
export function supabaseAdmin() {
  return createClient(SUPABASE_URL, serverSecretKey(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
