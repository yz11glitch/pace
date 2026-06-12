'use client';

import { useState } from 'react';
import { TxnRow, SectionHeader, EmptyState } from './shared';
import { useStore } from './StoreProvider';
import {
  CATEGORIES, Transaction, categoryTotals, summary,
  dailyTrend, weeklyTrend, recentTxns, dateLabel,
} from '../lib/data';

function getInkColor(cssVar: string): string {
  if (typeof window === 'undefined') return '#888';
  if (!cssVar.startsWith('var(')) return cssVar;
  const name = cssVar.slice(4, -1).trim();
  try {
    const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    return v || '#888';
  } catch { return '#888'; }
}

function DonutRing({ segments, total, size = 168, stroke = 22 }: {
  segments: { value: number; color: string }[];
  total: number; size?: number; stroke?: number;
}) {
  const r = (size - stroke) / 2;
  const cx = size / 2;
  const circ = 2 * Math.PI * r;
  const gap = 2.5;
  const rings = segments.map((seg, index) => {
    const frac = total > 0 ? seg.value / total : 0;
    const len = Math.max(0, frac * circ - gap);
    const priorFrac = segments
      .slice(0, index)
      .reduce((sum, prior) => sum + (total > 0 ? prior.value / total : 0), 0);
    return { ...seg, dash: `${len} ${circ - len}`, offset: -priorFrac * circ };
  });

  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ transform: 'rotate(-90deg)' }}>
      <circle cx={cx} cy={cx} r={r} fill="none" stroke="var(--bg-2)" strokeWidth={stroke} />
      {rings.map((seg, i) => {
        if (seg.value <= 0) return null;
        return (
          <circle key={i} cx={cx} cy={cx} r={r} fill="none"
            stroke={seg.color} strokeWidth={stroke} strokeLinecap="round"
            strokeDasharray={seg.dash} strokeDashoffset={seg.offset} />
        );
      })}
    </svg>
  );
}

function BreakdownCard() {
  const { txns, settings, money } = useStore();
  const totals = categoryTotals(txns);
  const totalSpent = summary(txns, settings).totalSpent;
  const rows = CATEGORIES
    .map(c => ({ cat: c, value: totals[c.id], budget: settings.budgets[c.id] }))
    .filter(r => r.value > 0)
    .sort((a, b) => b.value - a.value);
  const segments = rows.map(r => ({ value: r.value, color: getInkColor(r.cat.ink) }));

  return (
    <div className="card card-pad col gap-16 fade-up">
      <div className="row between">
        <div className="t-h2">Where it goes</div>
        <span className="muted-3" style={{ fontSize: 13, fontWeight: 700 }}>{rows.length} categories</span>
      </div>
      <div style={{ display: 'flex', justifyContent: 'center' }}>
        <div className="donut-wrap">
          <DonutRing segments={segments} total={totalSpent} />
          <div className="donut-center">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--ink-3)', textTransform: 'uppercase', letterSpacing: '.5px' }}>Spent</div>
            <div className="t-num" style={{ fontSize: 24, fontWeight: 800, color: 'var(--ink)', letterSpacing: '-.6px' }}>
              {money(totalSpent)}
            </div>
          </div>
        </div>
      </div>
      <div className="col gap-12">
        {rows.map(r => {
          const pct = totalSpent > 0 ? Math.round(r.value / totalSpent * 100) : 0;
          const over = r.value > r.budget;
          return (
            <div key={r.cat.id} className="col gap-6">
              <div className="row between">
                <div className="row" style={{ gap: 8, minWidth: 0, flex: 1 }}>
                  <span className="legend-dot" style={{ background: r.cat.ink }} />
                  <span style={{ fontSize: 14, fontWeight: 700, color: 'var(--ink)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    {r.cat.name}
                  </span>
                  {over && <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--warm)', flexShrink: 0 }}>over</span>}
                </div>
                <div className="row" style={{ gap: 8, flexShrink: 0 }}>
                  <span className="t-num" style={{ fontSize: 14, fontWeight: 700, color: 'var(--ink)' }}>
                    {money(r.value, { cents: true })}
                  </span>
                  <span className="muted-3" style={{ fontSize: 12, fontWeight: 700, width: 30, textAlign: 'right' }}>{pct}%</span>
                </div>
              </div>
              <div className="bar-track">
                <div className="bar-fill" style={{ width: (totalSpent > 0 ? Math.min(100, r.value / totalSpent * 100) : 0) + '%', background: r.cat.ink }} />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function TrendCard() {
  const { txns, money } = useStore();
  const [mode, setMode] = useState<'daily' | 'weekly'>('daily');
  const daily = dailyTrend(txns);
  const weekly = weeklyTrend(txns);
  const data = mode === 'daily'
    ? daily.map(d => ({ label: String(d.day), total: d.total }))
    : weekly.map(w => ({ label: w.label, total: w.total }));
  const max = Math.max(1, ...data.map(d => d.total));
  const avg = data.reduce((s, d) => s + d.total, 0) / (data.length || 1);
  const showLabel = (i: number) => mode === 'weekly' || i % 2 === 0 || i === data.length - 1;

  return (
    <div className="card card-pad col gap-14 fade-up">
      <div className="row between">
        <div className="t-h2">Spending trend</div>
        <div className="seg-sm">
          {(['daily', 'weekly'] as const).map(m => (
            <button key={m} className={'seg-sm-btn' + (mode === m ? ' active' : '')}
              onClick={() => setMode(m)} style={{ textTransform: 'capitalize' }}>{m}</button>
          ))}
        </div>
      </div>
      <div className="row" style={{ marginTop: -4 }}>
        <span className="t-num" style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink-2)' }}>
          Avg {money(avg)}{mode === 'daily' ? '/day' : '/week'}
        </span>
      </div>
      <div className="trend">
        {data.map((d, i) => {
          const h = (d.total / max) * 100;
          const hot = d.total > avg * 1.4;
          return (
            <div key={i} className="trend-col">
              <div className="trend-bar" style={{
                height: Math.max(3, h) + '%',
                background: hot ? 'var(--warm)' : 'var(--green)',
                opacity: d.total === 0 ? 0.25 : 1,
              }} />
              <span className="trend-lbl">{showLabel(i) ? d.label : ''}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function InvestCard() {
  const { txns, settings, money } = useStore();
  const s = summary(txns, settings);
  const targetPct = settings.investTarget > 0 ? Math.min(100, s.totalInvest / settings.investTarget * 100) : 0;
  const ratePct = Math.round(s.investRate * 100);
  const r = 34;
  const circ = 2 * Math.PI * r;

  return (
    <div className="card card-pad col gap-14 fade-up">
      <div className="t-h2">Investing</div>
      <div className="row" style={{ gap: 16 }}>
        <div style={{ position: 'relative', width: 84, height: 84, flexShrink: 0 }}>
          <svg width="84" height="84" viewBox="0 0 84 84" style={{ transform: 'rotate(-90deg)' }}>
            <circle cx="42" cy="42" r={r} fill="none" stroke="var(--bg-2)" strokeWidth="9" />
            <circle cx="42" cy="42" r={r} fill="none" stroke="var(--blue)" strokeWidth="9"
              strokeLinecap="round" strokeDasharray={`${targetPct / 100 * circ} ${circ}`} />
          </svg>
          <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>
            <span className="t-num" style={{ fontSize: 17, fontWeight: 800, color: 'var(--blue)' }}>{Math.round(targetPct)}%</span>
            <span style={{ fontSize: 9, fontWeight: 700, color: 'var(--ink-3)' }}>of target</span>
          </div>
        </div>
        <div className="col gap-10" style={{ flex: 1 }}>
          {[
            { label: 'Invested this month', val: money(s.totalInvest), color: 'var(--ink)', weight: 800 },
            { label: 'Monthly target',      val: money(settings.investTarget), color: 'var(--ink-3)', weight: 700 },
            { label: 'Investing rate',      val: `${ratePct}% of income`, color: 'var(--blue)', weight: 800 },
          ].map(row => (
            <div key={row.label} className="row between">
              <span className="muted" style={{ fontSize: 13.5, fontWeight: 600 }}>{row.label}</span>
              <span className="t-num" style={{ fontSize: 15, fontWeight: row.weight, color: row.color }}>{row.val}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function HistoryCard({ onDelete }: { onDelete: (id: string) => void }) {
  const { txns, money } = useStore();
  const sorted = recentTxns(txns);

  if (!sorted.length) {
    return (
      <div className="card card-pad fade-up">
        <EmptyState icon="note" title="No transactions yet"
          sub="Your spending history will show up here once you start logging." />
      </div>
    );
  }

  const groups: string[] = [];
  const byLabel: Record<string, Transaction[]> = {};
  sorted.forEach(t => {
    const k = dateLabel(t.date);
    if (!byLabel[k]) { byLabel[k] = []; groups.push(k); }
    byLabel[k].push(t);
  });

  return (
    <div className="col gap-10">
      {groups.map(label => {
        const items = byLabel[label];
        const dayTotal = items.filter(t => t.type === 'expense').reduce((s, t) => s + t.amt, 0);
        return (
          <div key={label} className="col gap-6">
            <div className="row between" style={{ padding: '2px 8px' }}>
              <span className="t-sec">{label}</span>
              {dayTotal > 0 && (
                <span className="t-num muted-3" style={{ fontSize: 12, fontWeight: 700 }}>
                  −{money(dayTotal, { cents: true })}
                </span>
              )}
            </div>
            <div className="card" style={{ padding: '4px 4px' }}>
              {items.map((t, i) => (
                <TxnRow key={t.id} txn={t} showSep={i < items.length - 1} onDelete={onDelete} />
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}

interface StatsScreenProps {
  onDelete: (id: string) => void;
}

export default function StatsScreen({ onDelete }: StatsScreenProps) {
  return (
    <div className="screen-fade col gap-16">
      <div className="t-h1 page-header">Stats</div>
      <BreakdownCard />
      <TrendCard />
      <InvestCard />
      <div className="col gap-10">
        <SectionHeader title="All transactions" />
        <HistoryCard onDelete={onDelete} />
      </div>
    </div>
  );
}
