'use client';
// Scan feedback that works with gloves on and in a noisy warehouse: a short tone,
// a vibration and a full-screen colour flash. Sound can be switched off per phone.
const SOUND_KEY = 'cswms.sound';
let ctx: AudioContext | null = null;

export function soundOn(): boolean {
  try { return localStorage.getItem(SOUND_KEY) !== 'off'; } catch { return true; }
}
export function setSoundOn(on: boolean) {
  try { localStorage.setItem(SOUND_KEY, on ? 'on' : 'off'); } catch { /* storage unavailable */ }
}

function tone(freq: number, ms: number, when = 0) {
  try {
    const AC = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AC) return;
    ctx ??= new AC();
    if (ctx.state === 'suspended') void ctx.resume();
    const o = ctx.createOscillator(); const g = ctx.createGain();
    o.type = 'square'; o.frequency.value = freq;
    const t0 = ctx.currentTime + when;
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(0.25, t0 + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + ms / 1000);
    o.connect(g).connect(ctx.destination);
    o.start(t0); o.stop(t0 + ms / 1000 + 0.02);
  } catch { /* audio not available */ }
}

function flash(color: string) {
  if (typeof document === 'undefined') return;
  const el = document.createElement('div');
  el.setAttribute('aria-hidden', 'true');
  el.style.cssText = `position:fixed;inset:0;z-index:9999;pointer-events:none;background:${color};opacity:.45;transition:opacity .35s ease-out`;
  document.body.appendChild(el);
  requestAnimationFrame(() => requestAnimationFrame(() => { el.style.opacity = '0'; }));
  setTimeout(() => el.remove(), 450);
}

export type Feedback = 'ok' | 'extra' | 'bad';
export function feedback(kind: Feedback) {
  const sound = soundOn();
  if (kind === 'ok') {
    if (sound) tone(1760, 90);
    navigator.vibrate?.(40);
    flash('#1baf7a');
  } else if (kind === 'extra') {          // accepted, but worth a look (e.g. item not expected in this bin)
    if (sound) { tone(1320, 90); tone(1760, 90, 0.12); }
    navigator.vibrate?.([40, 60, 40]);
    flash('#f2b84b');
  } else {
    if (sound) tone(220, 350);
    navigator.vibrate?.([120, 80, 120]);
    flash('#d64545');
  }
}
