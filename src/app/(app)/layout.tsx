import { AppContextProvider } from '@/components/app-context';
import { Shell } from '@/components/shell';

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <AppContextProvider>
      <Shell>{children}</Shell>
    </AppContextProvider>
  );
}
