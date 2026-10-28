export const metadata = { title: 'Offline' };
export default function Offline() {
  return (
    <main className="grid min-h-dvh place-items-center bg-steel-50 p-6 text-center">
      <div className="max-w-sm">
        <h1 className="text-xl font-semibold text-navy-900">No connection</h1>
        <p className="mt-2 text-sm text-steel-600">CSWMS needs a live connection to the central database. Stock is never saved offline, so nothing can be lost or duplicated. Reconnect and reload the page.</p>
      </div>
    </main>
  );
}
