'use client';
import { useEffect } from 'react';

/** Registers the PWA service worker (installable app; it never caches stock data or transactions). */
export function ServiceWorker() {
  useEffect(() => {
    if ('serviceWorker' in navigator && process.env.NODE_ENV === 'production') {
      navigator.serviceWorker.register('/sw.js').catch(() => {});
    }
  }, []);
  return null;
}
