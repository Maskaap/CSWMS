'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase/client';
import { Button, Field, Input, Notice, Spinner } from '@/components/ui';

type Factor = { id: string; friendly_name?: string; factor_type: string; status: string };

/** Multi-factor authentication (TOTP authenticator app) — required for administrative roles. */
export default function MfaPage() {
  const router = useRouter();
  const sb = supabaseBrowser();
  const [factors, setFactors] = useState<Factor[] | null>(null);
  const [enroll, setEnroll] = useState<{ id: string; qr: string; secret: string } | null>(null);
  const [code, setCode] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    sb.auth.mfa.listFactors().then(({ data }) => setFactors(((data?.totp ?? []) as Factor[]).filter((f) => f.status === 'verified')));
  }, [sb]);

  const startEnroll = async () => {
    setBusy(true); setError(null);
    // remove unfinished enrolments first
    const { data: all } = await sb.auth.mfa.listFactors();
    for (const f of (all?.all ?? []) as Factor[]) if (f.status !== 'verified') await sb.auth.mfa.unenroll({ factorId: f.id });
    const { data, error } = await sb.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'Authenticator ' + new Date().toISOString().slice(0, 10) });
    setBusy(false);
    if (error || !data) { setError(error?.message ?? 'Could not start enrolment'); return; }
    setEnroll({ id: data.id, qr: data.totp.qr_code, secret: data.totp.secret });
  };

  const verify = async (factorId: string) => {
    setBusy(true); setError(null);
    const { error } = await sb.auth.mfa.challengeAndVerify({ factorId, code: code.trim() });
    setBusy(false);
    if (error) { setError('The code was not accepted. Check the time on your phone and try the newest code.'); return; }
    router.replace('/');
    router.refresh();
  };

  if (!factors) return <Spinner />;
  const factor = factors[0];
  return (
    <main className="grid min-h-dvh place-items-center bg-navy-900 p-4">
      <div className="w-full max-w-md space-y-4 rounded-lg bg-white p-6">
        <h1 className="text-lg font-semibold text-navy-900">Two-step verification</h1>
        <p className="text-sm text-steel-600">Your role can approve stock changes and manage the system, so a second step is required: a 6-digit code from an authenticator app (Google Authenticator, Microsoft Authenticator, Authy).</p>
        {factor && !enroll && (
          <form onSubmit={(e) => { e.preventDefault(); verify(factor.id); }} className="space-y-3">
            <Field label="6-digit code"><Input inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code} onChange={(e) => setCode(e.target.value)} autoFocus /></Field>
            <Button type="submit" variant="primary" className="w-full" busy={busy}>Verify</Button>
          </form>
        )}
        {!factor && !enroll && <Button variant="primary" className="w-full" onClick={startEnroll} busy={busy}>Set up authenticator app</Button>}
        {enroll && (
          <form onSubmit={(e) => { e.preventDefault(); verify(enroll.id); }} className="space-y-3">
            <p className="text-sm">1. Scan this QR code with your authenticator app.</p>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={enroll.qr} alt="Authenticator QR code" className="mx-auto size-48" />
            <p className="text-xs text-steel-600">Cannot scan? Enter this key: <span className="font-mono break-all">{enroll.secret}</span></p>
            <p className="text-sm">2. Enter the 6-digit code it shows.</p>
            <Field label="6-digit code"><Input inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code} onChange={(e) => setCode(e.target.value)} /></Field>
            <Button type="submit" variant="primary" className="w-full" busy={busy}>Confirm and continue</Button>
          </form>
        )}
        {error && <Notice tone="bad">{error}</Notice>}
        <button className="text-sm text-navy-800 underline" onClick={async () => { await sb.auth.signOut(); router.replace('/login'); }}>Sign out</button>
      </div>
    </main>
  );
}
