'use client';

import { useState } from 'react';
import Icon from './Icon';
import { Toggle, SectionHeader } from './shared';
import { useStore } from './StoreProvider';
import { CATEGORIES } from '../lib/data';

function MoneyInput({ value, onChange, cur }: {
  value: number; onChange: (v: number) => void; cur: string;
}) {
  return <MoneyInputEditor key={value} value={value} onChange={onChange} cur={cur} />;
}

function MoneyInputEditor({ value, onChange, cur }: {
  value: number; onChange: (v: number) => void; cur: string;
}) {
  const [draft, setDraft] = useState(String(value));

  const handleChange = (raw: string) => {
    const digits = raw.replace(/\D/g, '');
    setDraft(digits.replace(/^0+(?=\d)/, ''));
  };

  const handleBlur = () => {
    const nextValue = draft === '' ? 0 : Number(draft);
    setDraft(String(nextValue));
    onChange(nextValue);
  };

  return (
    <div className="budget-pill">
      <span className="budget-currency">{cur}</span>
      <input className="budget-input" type="text" inputMode="numeric" value={draft}
        onChange={e => handleChange(e.target.value)}
        onBlur={handleBlur}
        onFocus={e => e.currentTarget.select()} />
    </div>
  );
}

function CatBadgeSmall({ cat }: { cat: string }) {
  const c = CATEGORIES.find(x => x.id === cat);
  if (!c) return null;
  return (
    <div style={{ width: 32, height: 32, borderRadius: 9, background: c.bg, color: c.ink,
      display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
      <Icon name={c.icon} size={17} sw={2} />
    </div>
  );
}

export default function SettingsScreen() {
  const { settings, updateSettings, updateBudget, theme, setTheme, resetData, currency, money } = useStore();
  const [curOpen, setCurOpen] = useState(false);
  const [appearanceOpen, setAppearanceOpen] = useState(false);
  const totalBudget = CATEGORIES.reduce((s, c) => s + (settings.budgets[c.id] || 0), 0);
  const planned = settings.savingTarget + settings.investTarget + totalBudget;

  const currencies = [
    { code: 'RM', name: 'Malaysian Ringgit' },
    { code: '$',  name: 'US Dollar' },
    { code: 'S$', name: 'Singapore Dollar' },
    { code: '€',  name: 'Euro' },
    { code: '£',  name: 'British Pound' },
  ];
  const appearances = [
    { code: 'light', name: 'Light' },
    { code: 'dark', name: 'Dark' },
    { code: 'auto', name: 'Auto' },
  ] as const;

  return (
    <div className="screen-fade settings-screen col gap-16">
      <div className="t-h1 page-header">Settings</div>

      {/* monthly plan summary */}
      <div className="hero monthly-plan fade-up">
        <div className="t-sec" style={{ marginBottom: 10 }}>Monthly plan</div>
        <div className="monthly-plan-grid">
          <div className="col gap-2 monthly-plan-item">
            <span className="muted" style={{ fontSize: 13, fontWeight: 600 }}>Income</span>
            <span className="t-num monthly-plan-value" style={{ color: 'var(--green)' }}>{money(settings.income)}</span>
          </div>
          <div className="col gap-2 monthly-plan-item">
            <span className="muted" style={{ fontSize: 13, fontWeight: 600 }}>Allocated</span>
            <span className="t-num monthly-plan-value" style={{ color: planned > settings.income ? 'var(--warm)' : 'var(--ink)' }}>
              {money(planned)}
            </span>
          </div>
          <div className="col gap-2 monthly-plan-item">
            <span className="muted" style={{ fontSize: 13, fontWeight: 600 }}>Unassigned</span>
            <span className="t-num monthly-plan-value" style={{ color: 'var(--blue)' }}>
              {money(Math.max(0, settings.income - planned))}
            </span>
          </div>
        </div>
      </div>

      {/* income & targets */}
      <div className="col gap-8">
        <SectionHeader title="Income & targets" />
        <div className="set-group">
          <div className="budget-row">
            <div className="set-ico" style={{ background: 'var(--c-inc-bg)', color: 'var(--c-inc)' }}>
              <Icon name="inc" size={18} sw={2} />
            </div>
            <span className="set-lbl">Monthly income</span>
            <MoneyInput cur={currency} value={settings.income} onChange={v => updateSettings({ income: v })} />
          </div>
          <div className="budget-row">
            <div className="set-ico" style={{ background: 'var(--green-soft)', color: 'var(--green)' }}>
              <Icon name="save" size={18} sw={2} />
            </div>
            <span className="set-lbl">Saving target</span>
            <MoneyInput cur={currency} value={settings.savingTarget} onChange={v => updateSettings({ savingTarget: v })} />
          </div>
          <div className="budget-row">
            <div className="set-ico" style={{ background: 'var(--blue-soft)', color: 'var(--blue)' }}>
              <Icon name="target" size={18} sw={2} />
            </div>
            <span className="set-lbl">Investing target</span>
            <MoneyInput cur={currency} value={settings.investTarget} onChange={v => updateSettings({ investTarget: v })} />
          </div>
        </div>
      </div>

      {/* category budgets */}
      <div className="col gap-8">
        <SectionHeader title="Category budgets" />
        <div className="set-group">
          {CATEGORIES.map(c => (
            <div key={c.id} className="budget-row">
              <CatBadgeSmall cat={c.id} />
              <span className="set-lbl">{c.name}</span>
              <MoneyInput cur={currency} value={settings.budgets[c.id]} onChange={v => updateBudget(c.id, v)} />
            </div>
          ))}
        </div>
        <div className="row between" style={{ padding: '4px 10px' }}>
          <span className="muted-3" style={{ fontSize: 12.5, fontWeight: 700 }}>Total budget</span>
          <span className="t-num" style={{ fontSize: 13.5, fontWeight: 800, color: 'var(--ink)' }}>{money(totalBudget)}</span>
        </div>
      </div>

      {/* preferences */}
      <div className="col gap-8">
        <SectionHeader title="Preferences" />
        <div className="set-group">
          {/* currency */}
          <div className="set-row" onClick={() => setCurOpen(o => !o)} style={{ cursor: 'pointer' }}>
            <div className="set-ico" style={{ background: 'var(--c-inv-bg)', color: 'var(--c-inv)' }}>
              <Icon name="currency" size={18} sw={2} />
            </div>
            <span className="set-lbl">Currency</span>
            <span className="set-val">{currencies.find(c => c.code === currency)?.name || currency}</span>
            <div style={{ color: 'var(--ink-3)', marginLeft: 6, transform: curOpen ? 'rotate(90deg)' : 'none', transition: 'transform .2s' }}>
              <Icon name="chevron" size={16} sw={2.2} />
            </div>
          </div>
          {curOpen && (
            <div className="col" style={{ padding: '4px 16px 12px', gap: 6 }}>
              {currencies.map(c => (
                <button key={c.code} className="row between press"
                  onClick={() => { updateSettings({ currency: c.code }); setCurOpen(false); }}
                  style={{ padding: '10px 14px', borderRadius: 12, background: currency === c.code ? 'var(--green-soft)' : 'var(--bg-2)' }}>
                  <span style={{ fontSize: 14, fontWeight: 700, color: currency === c.code ? 'var(--green)' : 'var(--ink)' }}>
                    {c.code} · {c.name}
                  </span>
                  {currency === c.code && <span style={{ color: 'var(--green)' }}><Icon name="check" size={18} sw={2.2} /></span>}
                </button>
              ))}
            </div>
          )}

          {/* theme */}
          <div className="set-row" onClick={() => setAppearanceOpen(o => !o)} style={{ cursor: 'pointer' }}>
            <div className="set-ico" style={{ background: 'var(--c-ent-bg)', color: 'var(--c-ent)' }}>
              <Icon name="palette" size={18} sw={2} />
            </div>
            <span className="set-lbl">Appearance</span>
            <span className="set-val">{appearances.find(a => a.code === theme)?.name}</span>
            <div style={{ color: 'var(--ink-3)', marginLeft: 6, transform: appearanceOpen ? 'rotate(90deg)' : 'none', transition: 'transform .2s' }}>
              <Icon name="chevron" size={16} sw={2.2} />
            </div>
          </div>
          {appearanceOpen && (
            <div className="col" style={{ padding: '4px 16px 12px', gap: 6 }}>
              {appearances.map(a => (
                <button key={a.code} className="row between press"
                  onClick={() => { setTheme(a.code); setAppearanceOpen(false); }}
                  style={{ padding: '10px 14px', borderRadius: 12, background: theme === a.code ? 'var(--green-soft)' : 'var(--bg-2)' }}>
                  <span style={{ fontSize: 14, fontWeight: 700, color: theme === a.code ? 'var(--green)' : 'var(--ink)' }}>
                    {a.name}
                  </span>
                  {theme === a.code && <span style={{ color: 'var(--green)' }}><Icon name="check" size={18} sw={2.2} /></span>}
                </button>
              ))}
            </div>
          )}

          <div className="set-row">
            <div className="set-ico" style={{ background: 'var(--c-edu-bg)', color: 'var(--c-edu)' }}>
              <Icon name="bell" size={18} sw={2} />
            </div>
            <span className="set-lbl">Coach notifications</span>
            <Toggle on={settings.notifications} onToggle={() => updateSettings({ notifications: !settings.notifications })} />
          </div>
          <div className="set-row">
            <div className="set-ico" style={{ background: 'var(--green-soft)', color: 'var(--green)' }}>
              <Icon name="leaf" size={18} sw={2} />
            </div>
            <span className="set-lbl">Round-up savings</span>
            <Toggle on={settings.roundUps} onToggle={() => updateSettings({ roundUps: !settings.roundUps })} />
          </div>
        </div>
      </div>

      {/* data */}
      <div className="col gap-8">
        <SectionHeader title="Data" />
        <div className="set-group">
          <button className="set-row press" style={{ width: '100%', textAlign: 'left' }} onClick={resetData}>
            <div className="set-ico" style={{ background: 'var(--warm-soft)', color: 'var(--warm)' }}>
              <Icon name="repeat" size={18} sw={2} />
            </div>
            <span className="set-lbl">Reset to sample data</span>
            <div style={{ color: 'var(--ink-3)' }}><Icon name="chevron" size={16} sw={2.2} /></div>
          </button>
        </div>
        <div style={{ textAlign: 'center', padding: '8px 0 0' }}>
          <span className="muted-3" style={{ fontSize: 12, fontWeight: 600 }}>Pace · v1.0 · Spend at your own pace</span>
        </div>
      </div>
    </div>
  );
}
