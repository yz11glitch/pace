'use client';

import Icon from './Icon';
import { SignalCard, TxnRow, SectionHeader, EmptyState } from './shared';
import { useStore } from './StoreProvider';
import { summary, computeSignals, recentTxns, MONTH_LABEL } from '../lib/data';

function SummaryHero() {
  const { txns, settings, money } = useStore();
  const s = summary(txns, settings);
  const overBudget = s.remaining < 0;
  const fillColor = overBudget ? 'var(--warm)' : (s.onTrack ? 'var(--green)' : 'var(--warm)');
  const pct = Math.min(100, s.pacePct * 100);
  const paceMarkerPct = Math.min(100, (s.day / s.daysInMonth) * 100);

  return (
    <div className="hero fade-up">
      <div className="row between" style={{ marginBottom: 14 }}>
        <div className="row" style={{ color: 'var(--ink-2)', gap: 6 }}>
          <Icon name="calendar" size={15} sw={2} />
          <span style={{ fontSize: 13.5, fontWeight: 700 }}>{MONTH_LABEL}</span>
        </div>
        <div className="chip" style={{
          background: s.onTrack ? 'var(--green-soft)' : 'var(--warm-soft)',
          color: s.onTrack ? 'var(--green)' : 'var(--warm)',
        }}>
          <Icon name={s.onTrack ? 'leaf' : 'fire'} size={13} sw={2.2} />
          {s.onTrack ? 'On track' : 'Watch your pace'}
        </div>
      </div>

      <div className="row" style={{ alignItems: 'baseline', gap: 8 }}>
        <span className="hero-spent t-num">{money(s.totalSpent)}</span>
        <span className="hero-of">spent</span>
      </div>
      <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--ink-3)', marginTop: 4, marginBottom: 14 }}>
        of {money(s.totalBudget)} budget · {overBudget
          ? <span style={{ color: 'var(--warm)' }}>{money(-s.remaining)} over</span>
          : <span style={{ color: 'var(--green)' }}>{money(s.remaining)} left</span>}
      </div>

      <div className="track">
        <div className="track-fill" style={{ width: pct + '%', background: fillColor }} />
        <div className="pace-marker" style={{ left: paceMarkerPct + '%' }} />
      </div>
      <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--ink-3)', marginTop: 7 }}>
        Marker shows where day {s.day} of {s.daysInMonth} should land
      </div>

      <div style={{ height: 1, background: 'var(--hair-2)', margin: '16px 0 14px' }} />

      <div className="row" style={{ gap: 6 }}>
        {[
          { lbl: 'Per day left', val: s.remaining > 0 ? money(s.dailyLeft) : money(0), ink: 'var(--blue)' },
          { lbl: 'Invested',     val: money(s.totalInvest), ink: 'var(--green)' },
          { lbl: 'Saved',        val: money(Math.max(0, s.saved)), ink: 'var(--ink)' },
        ].map((m, i) => (
          <div key={i} className="col gap-2" style={{ flex: 1, textAlign: 'center' }}>
            <div className="t-num" style={{ fontSize: 18, fontWeight: 800, color: m.ink, letterSpacing: '-.4px' }}>
              {m.val}
            </div>
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--ink-3)' }}>{m.lbl}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

interface HomeScreenProps {
  onOpenAdd: () => void;
  onSignalTap: () => void;
  goStats: () => void;
}

export default function HomeScreen({ onOpenAdd, onSignalTap, goStats }: HomeScreenProps) {
  const { txns, settings } = useStore();
  const sigs = computeSignals(txns, settings);
  const recent = recentTxns(txns, 5);

  return (
    <div className="screen-fade col gap-16">
      {/* greeting */}
      <div className="row between" style={{ marginBottom: 2 }}>
        <div className="col gap-2">
          <div className="t-greet">Good morning</div>
          <div className="t-h1">Aisyah</div>
        </div>
        <div style={{
          width: 46, height: 46, borderRadius: 99, background: 'var(--green-soft)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontWeight: 800, fontSize: 18, color: 'var(--green)',
          fontFamily: "'Bricolage Grotesque', system-ui, sans-serif",
        }}>A</div>
      </div>

      <SummaryHero />

      <div className="col gap-12">
        <SectionHeader title="Your coach" />
        <div className="col gap-10">
          {sigs.length ? sigs.map((sig, i) => (
            <SignalCard key={sig.id} sig={sig} index={i} onClick={onSignalTap} />
          )) : (
            <div className="card card-pad">
              <EmptyState icon="sparkle" title="No signals yet"
                sub="Add a few transactions and Pace will start coaching your spending." />
            </div>
          )}
        </div>
      </div>

      <div className="col gap-10">
        <SectionHeader title="Recent" action="See all" onAction={goStats} />
        <div className="card" style={{ padding: '4px 10px' }}>
          {recent.length ? recent.map((t, i) => (
            <TxnRow key={t.id} txn={t} showSep={i < recent.length - 1} />
          )) : (
            <EmptyState icon="wallet2" title="Nothing yet"
              sub="Tap the + button to log your first expense." cta="Add transaction" onCta={onOpenAdd} />
          )}
        </div>
      </div>
    </div>
  );
}
