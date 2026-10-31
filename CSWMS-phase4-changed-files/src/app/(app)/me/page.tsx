'use client';
import { useEffect, useState } from 'react';
import { MessageCircle, Type, Volume2 } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Button, Field, Input, Notice, PageHeader, Panel, Select, Spinner, cx } from '@/components/ui';
import { callRpc } from '@/hooks/use-transaction';
import { LANGS } from '@/lib/i18n';
import { feedback, setSoundOn, soundOn } from '@/lib/feedback';

type Prefs = { language: string; text_size: string; phone: string | null; whatsapp_opt_in: boolean; whatsapp_min_severity: string;
  whatsapp_system_enabled: boolean; undo_minutes: number };

export default function MySettingsPage() {
  const { t, refresh } = useApp();
  const [p, setP] = useState<Prefs | null>(null);
  const [phone, setPhone] = useState('');
  const [msg, setMsg] = useState<{ tone: 'ok' | 'bad'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [sound, setSound] = useState(true);

  useEffect(() => {
    setSound(soundOn());
    callRpc<Prefs>('my_preferences').then(({ data }) => { if (data) { setP(data); setPhone(data.phone ?? ''); } });
  }, []);
  if (!p) return <Spinner />;

  const save = async (args: Record<string, unknown>) => {
    setBusy(true); setMsg(null);
    const { data, error } = await callRpc<Prefs>('set_my_preferences', args);
    setBusy(false);
    if (error) { setMsg({ tone: 'bad', text: error.message }); return; }
    if (data) { setP(data); setPhone(data.phone ?? ''); }
    setMsg({ tone: 'ok', text: t('saved') });
    await refresh();
  };

  return (
    <div className="mx-auto max-w-2xl">
      <PageHeader title={t('settings')} description="Language and text size for the floor screens, scan sound on this phone, and WhatsApp alerts." />
      {msg && <Notice tone={msg.tone} className="mb-4">{msg.text}</Notice>}
      <div className="space-y-5">
        <Panel title={t('language')}>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            {LANGS.map((l) => (
              <button key={l.id} type="button" disabled={busy} onClick={() => save({ p_language: l.id })}
                className={cx('h-14 rounded-md border-2 text-base font-medium', p.language === l.id ? 'border-navy-900 bg-navy-900 text-white' : 'border-steel-200 bg-white hover:bg-steel-50')}>{l.label}</button>
            ))}
          </div>
          <p className="mt-2 text-xs text-steel-600">Used on My tasks, the counting screen, the quick-action bar and the undo button. Management screens stay in English.</p>
        </Panel>

        <Panel title={<span className="flex items-center gap-2"><Type className="size-4" />{t('big_text')}</span>}>
          <div className="grid grid-cols-3 gap-2">
            {([['normal', 'A', 'text-base'], ['large', 'A', 'text-xl'], ['xlarge', 'A', 'text-3xl']] as const).map(([id, l, cls]) => (
              <button key={id} type="button" disabled={busy} onClick={() => save({ p_text_size: id })} aria-label={id}
                className={cx('h-16 rounded-md border-2 font-semibold', cls, p.text_size === id ? 'border-navy-900 bg-navy-900 text-white' : 'border-steel-200 bg-white hover:bg-steel-50')}>{l}</button>
            ))}
          </div>
        </Panel>

        <Panel title={<span className="flex items-center gap-2"><Volume2 className="size-4" />{t('sound')}</span>}>
          <div className="flex flex-wrap gap-2">
            <Button variant={sound ? 'navy' : 'secondary'} onClick={() => { setSoundOn(true); setSound(true); feedback('ok'); }}>On</Button>
            <Button variant={!sound ? 'navy' : 'secondary'} onClick={() => { setSoundOn(false); setSound(false); }}>Off</Button>
            <Button variant="ghost" onClick={() => feedback('ok')}>Test: OK</Button>
            <Button variant="ghost" onClick={() => feedback('extra')}>Test: check</Button>
            <Button variant="ghost" onClick={() => feedback('bad')}>Test: error</Button>
          </div>
          <p className="mt-2 text-xs text-steel-600">Saved on this phone only. Vibration and the coloured flash always work.</p>
        </Panel>

        <Panel title={<span className="flex items-center gap-2"><MessageCircle className="size-4" />WhatsApp alerts</span>}>
          {!p.whatsapp_system_enabled && <Notice tone="info" className="mb-3">WhatsApp alerts are not switched on for your organisation yet. You can still save your number.</Notice>}
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Mobile number" hint="e.g. 082 123 4567"><Input inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} /></Field>
            <Field label="Send me">
              <Select value={p.whatsapp_min_severity} onChange={(e) => save({ p_whatsapp_min_severity: e.target.value })}>
                <option value="critical">Critical alerts only</option><option value="warning">Warnings and critical</option><option value="info">Everything</option>
              </Select>
            </Field>
          </div>
          <label className="mt-3 flex items-center gap-2 text-sm">
            <input type="checkbox" className="size-5" checked={p.whatsapp_opt_in} onChange={(e) => save({ p_phone: phone, p_whatsapp_opt_in: e.target.checked })} />
            Send my alerts to WhatsApp as well
          </label>
          <Button className="mt-3" busy={busy} onClick={() => save({ p_phone: phone })}>Save number</Button>
          <p className="mt-2 text-xs text-steel-600">Only alerts your role already receives (low stock, overdue transfers, integrity problems, approvals) — never stock figures you cannot see in the app.</p>
        </Panel>
      </div>
    </div>
  );
}
