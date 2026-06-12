'use client';

import Icon from './Icon';
import { useStore } from './StoreProvider';
import { CAT_MAP, Signal, Transaction, dateLabel } from '../lib/data';

/* ---- CatBadge ---- */
export function CatBadge({ cat, size = 40, radius = 12, iconSize = 21 }: {
  cat: string; size?: number; radius?: number; iconSize?: number;
}) {
  const c = CAT_MAP[cat] || CAT_MAP['misc'];
  return (
    <div style={{
      width: size, height: size, borderRadius: radius, background: c.bg,
      display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
    }}>
      <div style={{ color: c.ink, display: 'flex' }}>
        <Icon name={c.icon} size={iconSize} sw={2} />
      </div>
    </div>
  );
}

/* ---- SignalCard ---- */
const TONE = {
  warm:  { ink: 'var(--warm)',  bg: 'var(--warm-soft)' },
  green: { ink: 'var(--green)', bg: 'var(--green-soft)' },
  blue:  { ink: 'var(--blue)',  bg: 'var(--blue-soft)' },
};

export function SignalCard({ sig, onClick, index = 0 }: {
  sig: Signal; onClick?: () => void; index?: number;
}) {
  const t = TONE[sig.tone] || TONE.green;
  return (
    <button className="signal press fade-up" onClick={onClick}
      style={{ animationDelay: (index * 55) + 'ms' }}>
      <div className="signal-accent" style={{ background: t.ink }} />
      <div className="signal-ico" style={{ background: t.bg, color: t.ink }}>
        <Icon name={sig.icon} size={22} sw={2} />
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div className="signal-title">{sig.title}</div>
        <div className="signal-sub">{sig.sub}</div>
      </div>
      <div style={{ color: 'var(--ink-3)', alignSelf: 'center', marginLeft: 2, opacity: .6 }}>
        <Icon name="chevron" size={17} sw={2.2} />
      </div>
    </button>
  );
}

/* ---- TxnRow ---- */
export function TxnRow({ txn, onDelete, showSep = true }: {
  txn: Transaction; onDelete?: (id: string) => void; showSep?: boolean;
}) {
  const { money } = useStore();
  const c = CAT_MAP[txn.cat] || CAT_MAP['misc'];
  const isOut = txn.type === 'expense';
  const isInv = txn.type === 'invest';
  const amtColor = isInv ? 'var(--blue)' : (isOut ? 'var(--ink)' : 'var(--green)');
  const prefix = isInv ? '↑' : (isOut ? '−' : '+');
  const metaText = (txn.note ? txn.note : c.name) + ' · ' + dateLabel(txn.date);

  return (
    <div>
      <div className="txn">
        <CatBadge cat={txn.cat} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div className="txn-name" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {txn.name}
          </div>
          <div className="txn-meta">{metaText}</div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div className="txn-amt t-num" style={{ color: amtColor }}>
            {prefix}{money(txn.amt, { cents: true })}
          </div>
          {onDelete && (
            <button onClick={() => onDelete(txn.id)} style={{
              width: 30, height: 30, borderRadius: 8, background: 'var(--bg-2)',
              display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--warm)',
              flexShrink: 0,
            }}>
              <Icon name="trash" size={15} sw={2} />
            </button>
          )}
        </div>
      </div>
      {showSep && <div className="txn-sep" />}
    </div>
  );
}

/* ---- SectionHeader ---- */
export function SectionHeader({ title, action, onAction }: {
  title: string; action?: string; onAction?: () => void;
}) {
  return (
    <div className="row between section-header">
      <div className="t-sec">{title}</div>
      {action && (
        <button className="press" onClick={onAction}
          style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--green)' }}>
          {action}
        </button>
      )}
    </div>
  );
}

/* ---- EmptyState ---- */
export function EmptyState({ icon = 'note', title, sub, cta, onCta }: {
  icon?: string; title: string; sub?: string; cta?: string; onCta?: () => void;
}) {
  return (
    <div className="empty">
      <div className="empty-ico" style={{ color: 'var(--ink-3)' }}>
        <Icon name={icon} size={28} sw={1.8} />
      </div>
      <div className="empty-title">{title}</div>
      {sub && <div className="empty-sub">{sub}</div>}
      {cta && (
        <button className="press" onClick={onCta}
          style={{ marginTop: 4, color: 'var(--green)', fontWeight: 700, fontSize: 14 }}>
          {cta}
        </button>
      )}
    </div>
  );
}

/* ---- Toast ---- */
export function Toast({ show, text, icon = 'check' }: {
  show: boolean; text: string; icon?: string;
}) {
  return (
    <div className={'toast' + (show ? ' show' : '')}>
      <Icon name={icon} size={17} sw={2.2} />
      {text}
    </div>
  );
}

/* ---- Toggle ---- */
export function Toggle({ on, onToggle }: { on: boolean; onToggle: () => void }) {
  return (
    <button className={'toggle' + (on ? ' on' : '')} onClick={onToggle}>
      <span className="toggle-knob" />
    </button>
  );
}
