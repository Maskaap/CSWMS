'use client';
import { Suspense, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase/client';
import { Button, Field, Input, Notice } from '@/components/ui';

function LoginForm() {
  const router = useRouter();
  const next = useSearchParams().get('next') || '/';
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mode, setMode] = useState<'login' | 'forgot' | 'sent'>('login');

  const signIn = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    const { error } = await supabaseBrowser().auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (error) { setError(error.message === 'Invalid login credentials' ? 'E-mail or password is incorrect.' : error.message); return; }
    router.replace(next.startsWith('/') ? next : '/');
    router.refresh();
  };

  const forgot = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    const { error } = await supabaseBrowser().auth.resetPasswordForEmail(email.trim(), {
      redirectTo: `${window.location.origin}/auth/callback?next=/reset-password`,
    });
    setBusy(false);
    if (error) setError(error.message); else setMode('sent');
  };

  return (
    <main className="grid min-h-dvh place-items-center bg-navy-900 p-4">
      <div className="w-full max-w-sm">
        <div className="mb-6 text-white">
          <div className="text-3xl font-bold tracking-tight">CSWMS</div>
          <div className="text-sm text-navy-100">Central Stock &amp; Warehouse Management</div>
        </div>
        <div className="rounded-lg bg-white p-6">
          {mode === 'login' && (
            <form onSubmit={signIn} className="space-y-4">
              <h1 className="text-lg font-semibold text-navy-900">Sign in</h1>
              <Field label="Work e-mail"><Input type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
              <Field label="Password"><Input type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
              {error && <Notice tone="bad">{error}</Notice>}
              <Button type="submit" variant="primary" className="w-full" busy={busy}>Sign in</Button>
              <button type="button" className="text-sm text-navy-800 underline" onClick={() => setMode('forgot')}>Forgot password?</button>
            </form>
          )}
          {mode === 'forgot' && (
            <form onSubmit={forgot} className="space-y-4">
              <h1 className="text-lg font-semibold text-navy-900">Reset password</h1>
              <p className="text-sm text-steel-600">We will e-mail you a link to choose a new password.</p>
              <Field label="Work e-mail"><Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
              {error && <Notice tone="bad">{error}</Notice>}
              <Button type="submit" variant="primary" className="w-full" busy={busy}>Send reset link</Button>
              <button type="button" className="text-sm text-navy-800 underline" onClick={() => setMode('login')}>Back to sign in</button>
            </form>
          )}
          {mode === 'sent' && <Notice tone="ok" title="Check your e-mail">If an account exists for {email}, a reset link has been sent.</Notice>}
        </div>
        <p className="mt-4 text-xs text-navy-100">Accounts are created by your administrator. Every action is recorded against your name.</p>
      </div>
    </main>
  );
}

export default function LoginPage() {
  return <Suspense><LoginForm /></Suspense>;
}
