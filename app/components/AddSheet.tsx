'use client';

import { useEffect, useState } from 'react';
import Icon from './Icon';
import { useStore } from './StoreProvider';
import { CATEGORIES, INCOME_CATS, INVEST_CATS, CAT_MAP } from '../lib/data';

function Keypad({ onKey }: { onKey: (key: string) => void }) {
  const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', 'del'];

  return (
    <div className="keypad">
      {keys.map(k => (
        <button
          key={k}
          type="button"
          className="key"
          onClick={() => onKey(k)}
          aria-label={k === 'del' ? 'Delete last digit' : undefined}
        >
          {k === 'del'
            ? <Icon name="back" size={22} sw={2.2} />
            : k}
        </button>
      ))}
    </div>
  );
}

interface AddSheetProps {
  open: boolean;
  onClose: () => void;
  onSaved?: (type: string, amt: number, cur: string) => void;
}

export default function AddSheet({ open, onClose, onSaved }: AddSheetProps) {
  const { addTxn, currency } = useStore();
  const [type, setType] = useState<'expense' | 'income' | 'invest'>('expense');
  const [cat, setCat] = useState('food');
  const [amount, setAmount] = useState('');
  const [note, setNote] = useState('');
  const [noteOpen, setNoteOpen] = useState(false);

  const catList = type === 'expense' ? CATEGORIES : type === 'income' ? INCOME_CATS : INVEST_CATS;

  useEffect(() => {
    if (!open) return;
    const timer = window.setTimeout(() => {
      setType('expense');
      setCat('food');
      setAmount('');
      setNote('');
      setNoteOpen(false);
    }, 0);
    return () => window.clearTimeout(timer);
  }, [open]);

  const changeType = (t: typeof type) => {
    setType(t);
    const list = t === 'expense' ? CATEGORIES : t === 'income' ? INCOME_CATS : INVEST_CATS;
    setCat(list[0].id);
  };

  const onKey = (k: string) => {
    setAmount(prev => {
      if (k === 'del') return prev.slice(0, -1);
      if (k === '.') {
        if (prev.includes('.')) return prev;
        return (prev || '0') + '.';
      }
      if (prev.includes('.')) { const dec = prev.split('.')[1]; if (dec.length >= 2) return prev; }
      if (prev.replace('.', '').length >= 7) return prev;
      if (prev === '0' && k !== '.') return k;
      return prev + k;
    });
  };

  const numAmount = parseFloat(amount || '0') || 0;
  const valid = numAmount > 0;
  const typeColor = type === 'expense' ? 'var(--warm)' : type === 'income' ? 'var(--green)' : 'var(--blue)';

  const handleSave = () => {
    if (!valid) return;
    const c = CAT_MAP[cat];
    const name = note.trim() ? note.trim() : c.name;
    addTxn({ type, cat, amt: Math.round(numAmount * 100) / 100, name, note: '' });
    onSaved?.(type, numAmount, currency);
    onClose();
  };

  const display = amount === '' ? '0' : amount;
  const formattedAmount = numAmount.toLocaleString('en-MY', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  const saveType = type === 'invest' ? 'investment' : type;

  return (
    <>
      <div className={'scrim' + (open ? ' show' : '')} onClick={onClose} />
      <section
        className={'sheet add-sheet' + (open ? ' show' : '')}
        role="dialog"
        aria-modal="true"
        aria-label="Add transaction"
      >
        <div className="sheet-handle" aria-hidden="true">
          <span className="sheet-grab" />
        </div>

        <div className="add-sheet-header row between">
          <div className="t-h2">Add transaction</div>
          <button type="button" className="press add-sheet-close" onClick={onClose} aria-label="Close">
            <Icon name="close" size={18} sw={2.2} />
          </button>
        </div>

        <div className="sheet-body add-sheet-body">
          <div className="seg">
            {([
              { k: 'expense', l: 'Expense', c: 'exp' },
              { k: 'income',  l: 'Income',  c: 'inc' },
              { k: 'invest',  l: 'Invest',  c: 'inv' },
            ] as const).map(o => (
              <button type="button" key={o.k} className={'seg-btn ' + o.c + (type === o.k ? ' active' : '')}
                onClick={() => changeType(o.k)}>{o.l}</button>
            ))}
          </div>

          <div className="amount-display">
            <div className="amount-value">
              <span className="amount-cur" style={{ color: valid ? typeColor : 'var(--ink-3)' }}>{currency}</span>
              <span className="amount-big" style={{ color: valid ? 'var(--ink)' : 'var(--ink-3)' }}>{display}</span>
            </div>
          </div>

          <div className="category-section">
            <div className="field-lbl">Category</div>
            <div className="category-grid">
              {catList.map(c => {
                const sel = cat === c.id;
                return (
                  <button
                    type="button"
                    key={c.id}
                    className={'category-tile' + (sel ? ' selected' : '')}
                    onClick={() => setCat(c.id)}
                    aria-pressed={sel}
                    style={{ '--category-bg': c.bg, '--category-ink': c.ink } as React.CSSProperties}
                  >
                    <span className="category-icon">
                      <Icon name={c.icon} size={21} sw={2} />
                    </span>
                    <span className="category-label">{c.name}</span>
                  </button>
                );
              })}
            </div>
          </div>

          {noteOpen ? (
            <label className="add-note-field">
              <span className="field-lbl">Note <span className="optional-label">(optional)</span></span>
              <input className="input" placeholder="e.g. Grab, lunch with team..."
                value={note} onChange={e => setNote(e.target.value)} maxLength={40} autoFocus />
            </label>
          ) : (
            <button type="button" className="compact-note" onClick={() => setNoteOpen(true)}>
              <span className="note-plus">+</span>
              <span>Add note</span>
              <span className="optional-label">Optional</span>
            </button>
          )}

          <Keypad onKey={onKey} />

          <button
            type="button"
            className="btn-primary add-sheet-save"
            disabled={!valid}
            onClick={handleSave}
            style={{ background: valid ? typeColor : undefined }}
          >
            Save {saveType} · {currency} {formattedAmount}
          </button>
        </div>
      </section>
    </>
  );
}
