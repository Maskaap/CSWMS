import type { Metadata, Viewport } from 'next';
import './globals.css';
import { ServiceWorker } from '@/components/service-worker';

export const metadata: Metadata = {
  title: { default: 'CSWMS', template: '%s · CSWMS' },
  description: 'Central Stock & Warehouse Management System',
  manifest: '/manifest.webmanifest',
  applicationName: 'CSWMS',
  appleWebApp: { capable: true, title: 'CSWMS', statusBarStyle: 'default' },
  icons: { icon: '/icons/icon-192.png', apple: '/icons/apple-touch-icon.png' },
};

export const viewport: Viewport = {
  themeColor: '#15233f',
  width: 'device-width',
  initialScale: 1,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en-ZA">
      <body className="min-h-dvh antialiased">
        {children}
        <ServiceWorker />
      </body>
    </html>
  );
}
