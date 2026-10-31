'use client';
import { useEffect, useRef, useState } from 'react';
import { Camera, ScanLine, X } from 'lucide-react';
import { Button, cx } from './ui';

/**
 * Scan input that works with:
 *  - USB and Bluetooth scanners (they type the code and press Enter),
 *  - the phone / tablet camera (barcode and QR),
 *  - manual typing.
 * Identical codes read by the camera within 1.5 s are ignored (prevents double reads).
 */
export function ScanInput({ onScan, placeholder = 'Scan or type a barcode, SKU or location', autoFocus = true, disabled, label = 'Scan', big, continuous, cameraHint }: {
  onScan: (code: string) => void; placeholder?: string; autoFocus?: boolean; disabled?: boolean; label?: string; big?: boolean;
  /** keep the camera open after each read (scan-to-count) */
  continuous?: boolean; cameraHint?: string;
}) {
  const [value, setValue] = useState('');
  const [camera, setCamera] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => { if (autoFocus && !disabled) inputRef.current?.focus(); }, [autoFocus, disabled]);

  const submit = (code: string) => {
    const c = code.trim();
    if (!c) return;
    onScan(c);
    setValue('');
    inputRef.current?.focus();
  };

  return (
    <div className={cx('bin-label rounded-md px-3 pb-3 pt-4', disabled && 'opacity-60')}>
      <label className="mb-1 flex items-center gap-2 text-sm font-semibold text-navy-900"><ScanLine className="size-4" />{label}</label>
      <div className="flex gap-2">
        <input
          ref={inputRef}
          value={value}
          disabled={disabled}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); submit(value); } }}
          placeholder={placeholder}
          inputMode="text"
          autoComplete="off"
          autoCorrect="off"
          spellCheck={false}
          aria-label={label}
          className={cx('w-full rounded-md border-2 border-navy-900 bg-white px-3 font-mono text-navy-950 placeholder:font-sans placeholder:text-steel-400 focus:outline-none focus:ring-4 focus:ring-signal-300',
            big ? 'h-14 text-lg' : 'h-11 text-base')}
        />
        <Button type="button" variant="navy" size={big ? 'lg' : 'md'} onClick={() => setCamera(true)} disabled={disabled} aria-label="Scan with camera">
          <Camera className="size-5" /><span className="hidden sm:inline">Camera</span>
        </Button>
      </div>
      {camera && <CameraScanner hint={cameraHint} onClose={() => setCamera(false)} onResult={(c) => { if (!continuous) setCamera(false); submit(c); }} />}
    </div>
  );
}

function CameraScanner({ onResult, onClose, hint }: { onResult: (code: string) => void; onClose: () => void; hint?: string }) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const resultRef = useRef(onResult);
  resultRef.current = onResult;
  const [error, setError] = useState<string | null>(null);
  const last = useRef<{ code: string; at: number }>({ code: '', at: 0 });

  useEffect(() => {
    let controls: { stop: () => void } | null = null;
    let cancelled = false;
    (async () => {
      try {
        const { BrowserMultiFormatReader } = await import('@zxing/browser');
        const reader = new BrowserMultiFormatReader();
        if (cancelled || !videoRef.current) return;
        controls = await reader.decodeFromConstraints(
          { video: { facingMode: { ideal: 'environment' } } },
          videoRef.current,
          (result) => {
            if (!result) return;
            const code = result.getText();
            const now = Date.now();
            if (code === last.current.code && now - last.current.at < 1500) return;
            last.current = { code, at: now };
            if (navigator.vibrate) navigator.vibrate(60);
            resultRef.current(code);
          },
        );
      } catch (e) {
        setError(e instanceof Error && /Permission|NotAllowed/i.test(e.message)
          ? 'Camera permission was refused. Allow camera access for this site, or type the code.'
          : 'The camera could not be started on this device. Use a scanner or type the code.');
      }
    })();
    return () => { cancelled = true; controls?.stop(); };
  }, []);

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-navy-950/95 p-4" role="dialog" aria-label="Camera scanner">
      <div className="mb-3 flex items-center justify-between text-white">
        <span className="font-medium">{hint ?? 'Point the camera at the barcode or QR code'}</span>
        <Button variant="secondary" size="sm" onClick={onClose}><X className="size-4" />Close</Button>
      </div>
      <div className="relative mx-auto w-full max-w-lg flex-1 overflow-hidden rounded-lg border-2 border-signal-400">
        <video ref={videoRef} className="h-full w-full object-cover" muted playsInline />
        <div className="pointer-events-none absolute inset-x-8 top-1/2 h-0.5 -translate-y-1/2 bg-signal-400 shadow-[0_0_12px_#f5b700]" />
      </div>
      {error && <p className="mx-auto mt-3 max-w-lg rounded bg-bad-50 p-3 text-sm text-bad-600">{error}</p>}
    </div>
  );
}
