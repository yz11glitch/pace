'use client';

import { useState, useRef, useEffect, useCallback } from 'react';
import Icon from './Icon';
import { Toast } from './shared';
import HomeScreen from './HomeScreen';
import StatsScreen from './StatsScreen';
import SettingsScreen from './SettingsScreen';
import AddSheet from './AddSheet';
import { useStore } from './StoreProvider';

function BottomNav() {
  const { tab, setTab } = useStore();
  const items = [
    { k: 'stats',    icon: 'stats',    label: 'Stats'    },
    { k: 'home',     icon: 'home',     label: 'Home'     },
    { k: 'settings', icon: 'settings', label: 'Settings' },
  ] as const;
  return (
    <nav className="navbar">
      {items.map(it => (
        <button key={it.k} className={'navbtn' + (tab === it.k ? ' active' : '')} onClick={() => setTab(it.k)}>
          <span className="navdot" />
          <Icon name={it.icon} size={24} sw={tab === it.k ? 2.3 : 2} />
          <span>{it.label}</span>
        </button>
      ))}
    </nav>
  );
}

export default function PaceApp() {
  const { tab, setTab, deleteTxn } = useStore();
  const [sheet, setSheet] = useState(false);
  const [toast, setToast] = useState({ show: false, text: '', icon: 'check' });
  const scrollRef = useRef<HTMLDivElement>(null);
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (scrollRef.current) scrollRef.current.scrollTop = 0;
  }, [tab]);

  const showToast = useCallback((text: string, icon = 'check') => {
    setToast({ show: true, text, icon });
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(t => ({ ...t, show: false })), 2200);
  }, []);

  const onSaved = useCallback((type: string, amt: number, cur: string) => {
    const label = type === 'expense' ? 'Expense' : type === 'income' ? 'Income' : 'Investment';
    showToast(`${label} added · ${cur}${amt.toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
  }, [showToast]);

  const onDelete = useCallback((id: string) => {
    deleteTxn(id);
    showToast('Transaction deleted', 'trash');
  }, [deleteTxn, showToast]);

  return (
    <div className="app-shell">
      <main ref={scrollRef} className="app-content">
        {tab === 'home' && (
          <HomeScreen
            onOpenAdd={() => setSheet(true)}
            onSignalTap={() => setTab('stats')}
            goStats={() => setTab('stats')}
          />
        )}
        {tab === 'stats' && <StatsScreen onDelete={onDelete} />}
        {tab === 'settings' && <SettingsScreen />}
      </main>

      <button
        className={'fab' + (sheet ? ' sheet-open' : '')}
        onClick={() => setSheet(s => !s)}
        aria-label="Add transaction"
      >
        <span style={{ color: '#fff', display: 'flex' }}>
          <Icon name="plus" size={28} sw={2.6} />
        </span>
      </button>

      <BottomNav />
      <Toast show={toast.show} text={toast.text} icon={toast.icon} />
      <AddSheet open={sheet} onClose={() => setSheet(false)} onSaved={onSaved} />
    </div>
  );
}
