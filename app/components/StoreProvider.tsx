'use client';

import {
  createContext, useContext, useState, useEffect, useCallback,
  useSyncExternalStore, ReactNode,
} from 'react';
import {
  Transaction, Settings, INITIAL_TXNS, DEFAULT_SETTINGS,
  money,
} from '../lib/data';

type Theme = 'light' | 'dark' | 'auto';
type Tab = 'home' | 'stats' | 'settings';

interface Store {
  txns: Transaction[];
  settings: Settings;
  theme: Theme;
  effectiveTheme: 'light' | 'dark';
  tab: Tab;
  currency: string;
  addTxn: (t: Omit<Transaction, 'id' | 'date'>) => void;
  deleteTxn: (id: string) => void;
  updateSettings: (patch: Partial<Settings>) => void;
  updateBudget: (catId: string, val: number) => void;
  setTheme: (t: Theme) => void;
  setTab: (t: Tab) => void;
  resetData: () => void;
  money: typeof money;
}

const Ctx = createContext<Store | null>(null);
export const useStore = () => useContext(Ctx)!;

function load<T>(key: string, fallback: T): T {
  if (typeof window === 'undefined') return fallback;
  try {
    const raw = localStorage.getItem(key);
    if (raw == null) return fallback;
    return JSON.parse(raw) as T;
  } catch { return fallback; }
}

function save(key: string, val: unknown) {
  try { localStorage.setItem(key, JSON.stringify(val)); } catch {}
}

const subscribeToHydration = () => () => {};

function StoreState({ children, persisted }: { children: ReactNode; persisted: boolean }) {
  const [txns, setTxns] = useState<Transaction[]>(() =>
    persisted ? load('pace_txns_v1', INITIAL_TXNS) : INITIAL_TXNS
  );
  const [settings, setSettings] = useState<Settings>(() => {
    if (!persisted) return DEFAULT_SETTINGS;
    const savedSettings = load<Partial<Settings>>('pace_settings_v1', {});
    return {
      ...DEFAULT_SETTINGS,
      ...savedSettings,
      budgets: { ...DEFAULT_SETTINGS.budgets, ...(savedSettings.budgets || {}) },
    };
  });
  const [theme, setThemeState] = useState<Theme>(() =>
    persisted ? load<Theme>('pace_theme_v1', 'light') : 'light'
  );
  const [effectiveTheme, setEffective] = useState<'light' | 'dark'>('light');
  const [tab, setTab] = useState<Tab>('home');

  useEffect(() => { if (persisted) save('pace_txns_v1', txns); }, [txns, persisted]);
  useEffect(() => { if (persisted) save('pace_settings_v1', settings); }, [settings, persisted]);

  useEffect(() => {
    if (!persisted) return;
    save('pace_theme_v1', theme);
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const apply = () => {
      const eff = theme === 'auto' ? (mq.matches ? 'dark' : 'light') : theme;
      document.documentElement.setAttribute('data-theme', eff);
      setEffective(eff);
    };
    apply();
    if (theme === 'auto') {
      mq.addEventListener('change', apply);
      return () => mq.removeEventListener('change', apply);
    }
  }, [theme, persisted]);

  const addTxn = useCallback((t: Omit<Transaction, 'id' | 'date'>) => {
    const id = 'u' + Date.now();
    const date = new Date(2026, 5, 11).toISOString();
    setTxns(prev => [{ id, date, ...t }, ...prev]);
  }, []);

  const deleteTxn = useCallback((id: string) => {
    setTxns(prev => prev.filter(t => t.id !== id));
  }, []);

  const updateSettings = useCallback((patch: Partial<Settings>) => {
    setSettings(prev => ({ ...prev, ...patch }));
  }, []);

  const updateBudget = useCallback((catId: string, val: number) => {
    setSettings(prev => ({ ...prev, budgets: { ...prev.budgets, [catId]: val } }));
  }, []);

  const setTheme = useCallback((t: Theme) => setThemeState(t), []);

  const resetData = useCallback(() => {
    setTxns(INITIAL_TXNS);
    setSettings({ ...DEFAULT_SETTINGS });
  }, []);

  const cur = settings.currency;

  const moneyWithCur = useCallback(
    (n: number, opts: { cents?: boolean; sign?: boolean } = {}) => money(n, { ...opts, cur }),
    [cur]
  );

  return (
    <Ctx.Provider value={{
      txns, settings, theme, effectiveTheme, tab, currency: cur,
      addTxn, deleteTxn, updateSettings, updateBudget,
      setTheme, setTab, resetData,
      money: moneyWithCur,
    }}>
      {children}
    </Ctx.Provider>
  );
}

export function StoreProvider({ children }: { children: ReactNode }) {
  const hydrated = useSyncExternalStore(
    subscribeToHydration,
    () => true,
    () => false,
  );

  return (
    <StoreState key={hydrated ? 'persisted' : 'server'} persisted={hydrated}>
      {children}
    </StoreState>
  );
}
