'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase/client';
import { Button, Field, Input, Notice } from '@/components/ui';

export default function ResetPasswordPage() {
  const router = useRouter();
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    if (pw.length < 10) { setError('Use at least 10 characters.'); return; }
    if (pw !== pw2) { setError('The passwords do not match.'); return; }
    setBusy(true); setError(null);
    const { error } = await supabaseBrowser().auth.updateUser({ password: pw });
    setBusy(false);
    if (error) { setError(error.message); return; }
    router.replace('/');
  };

  return (
    <main className="grid min-h-dvh place-items-center bg-navy-900 p-4">
      <form onSubmit={save} className="w-full max-w-sm space-y-4 rounded-lg bg-white p-6">
        <h1 className="text-lg font-semibold text-navy-900">Choose your password</h1>
        <Field label="New password" hint="At least 10 characters. Do not reuse a password from another site.">
          <Input type="password" autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} required />
        </Field>
        <Field label="Repeat password"><Input type="password" autoComplete="new-password" value={pw2} onChange={(e) => setPw2(e.target.value)} required /></Field>
        {error && <Notice tone="bad">{error}</Notice>}
        <Button type="submit" variant="primary" className="w-full" busy={busy}>Save password</Button>
      </form>
    </main>
  );
}
