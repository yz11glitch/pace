// PACE — data model, sample data, money + signal logic

const TODAY = new Date(2026, 5, 11); // 11 June 2026
const DAYS_IN_MONTH = 30;
const DAY = TODAY.getDate();
const DAYS_LEFT = DAYS_IN_MONTH - DAY;

export const MONTH_LABEL = 'June 2026';

export interface Category {
  id: string;
  name: string;
  icon: string;
  ink: string;
  bg: string;
  budget?: number;
}

export interface Transaction {
  id: string;
  type: 'expense' | 'income' | 'invest';
  cat: string;
  name: string;
  note: string;
  amt: number;
  date: string;
}

export interface Settings {
  income: number;
  savingTarget: number;
  investTarget: number;
  currency: string;
  budgets: Record<string, number>;
  notifications: boolean;
  roundUps: boolean;
}

export const CATEGORIES: Category[] = [
  { id: 'food',  name: 'Food & Drinks', icon: 'food',  ink: 'var(--c-food)', bg: 'var(--c-food-bg)', budget: 800 },
  { id: 'groc',  name: 'Groceries',     icon: 'groc',  ink: 'var(--c-groc)', bg: 'var(--c-groc-bg)', budget: 600 },
  { id: 'tpt',   name: 'Transport',     icon: 'tpt',   ink: 'var(--c-tpt)',  bg: 'var(--c-tpt-bg)',  budget: 400 },
  { id: 'shop',  name: 'Shopping',      icon: 'shop',  ink: 'var(--c-shop)', bg: 'var(--c-shop-bg)', budget: 300 },
  { id: 'bill',  name: 'Bills',         icon: 'bill',  ink: 'var(--c-bill)', bg: 'var(--c-bill-bg)', budget: 500 },
  { id: 'ent',   name: 'Entertainment', icon: 'ent',   ink: 'var(--c-ent)',  bg: 'var(--c-ent-bg)',  budget: 200 },
  { id: 'hlth',  name: 'Health',        icon: 'hlth',  ink: 'var(--c-hlth)', bg: 'var(--c-hlth-bg)', budget: 150 },
  { id: 'edu',   name: 'Education',     icon: 'edu',   ink: 'var(--c-edu)',  bg: 'var(--c-edu-bg)',  budget: 100 },
  { id: 'misc',  name: 'Others',        icon: 'misc',  ink: 'var(--c-misc)', bg: 'var(--c-misc-bg)', budget: 150 },
];

export const INCOME_CATS: Category[] = [
  { id: 'salary',    name: 'Salary',    icon: 'inc',  ink: 'var(--c-inc)', bg: 'var(--c-inc-bg)' },
  { id: 'freelance', name: 'Freelance', icon: 'inc',  ink: 'var(--c-inc)', bg: 'var(--c-inc-bg)' },
  { id: 'gift',      name: 'Gift',      icon: 'gift', ink: 'var(--c-inc)', bg: 'var(--c-inc-bg)' },
  { id: 'other-inc', name: 'Other',     icon: 'inc',  ink: 'var(--c-inc)', bg: 'var(--c-inc-bg)' },
];

export const INVEST_CATS: Category[] = [
  { id: 'stocks', name: 'Stocks',          icon: 'inv',  ink: 'var(--c-inv)', bg: 'var(--c-inv-bg)' },
  { id: 'asb',    name: 'ASB / Unit Trust',icon: 'bank', ink: 'var(--c-inv)', bg: 'var(--c-inv-bg)' },
  { id: 'robo',   name: 'Robo-advisor',    icon: 'inv',  ink: 'var(--c-inv)', bg: 'var(--c-inv-bg)' },
  { id: 'crypto', name: 'Crypto',          icon: 'coin', ink: 'var(--c-inv)', bg: 'var(--c-inv-bg)' },
];

export const CAT_MAP: Record<string, Category> = {};
[...CATEGORIES, ...INCOME_CATS, ...INVEST_CATS].forEach(c => { CAT_MAP[c.id] = c; });

const d = (day: number) => new Date(2026, 5, day).toISOString();
let _id = 0;
const nid = () => 't' + (++_id);

export const INITIAL_TXNS: Transaction[] = [
  // Income
  { id: nid(), type: 'income', cat: 'salary',    name: 'Monthly Salary', note: 'Acme Sdn Bhd',   amt: 6500,  date: d(1) },
  { id: nid(), type: 'income', cat: 'freelance',  name: 'Design gig',    note: 'Logo project',   amt: 850,   date: d(7) },
  // Invest
  { id: nid(), type: 'invest', cat: 'robo',  name: 'StashAway', note: 'Auto top-up', amt: 200, date: d(2) },
  { id: nid(), type: 'invest', cat: 'asb',   name: 'ASB',       note: 'Monthly',     amt: 100, date: d(2) },
  // Transport — Grab x9 = RM214
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Grab', note: 'Ride to office',  amt: 18.50, date: d(2) },
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Grab', note: 'Ride home',       amt: 22.00, date: d(2) },
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Grab', note: 'Lunch run',       amt: 15.40, date: d(3) },
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Grab', note: 'To KLCC',         amt: 31.00, date: d(4) },
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Grab', note: 'Late night',      amt: 19.90, date: d(5) },
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Grab', note: 'To airport',      amt: 24.60, date: d(6) },
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Grab', note: 'Meeting',         amt: 28.00, date: d(8) },
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Grab', note: 'Groceries run',   amt: 17.10, date: d(9) },
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Grab', note: 'Weekend out',     amt: 37.50, date: d(10) },
  { id: nid(), type: 'expense', cat: 'tpt', name: "Touch 'n Go", note: 'eWallet reload', amt: 50.00, date: d(3) },
  { id: nid(), type: 'expense', cat: 'tpt', name: 'Petronas',    note: 'Fuel',          amt: 70.00, date: d(7) },
  // Food
  { id: nid(), type: 'expense', cat: 'food', name: 'Mamak',    note: 'Roti + teh tarik',  amt: 12.50, date: d(1) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Tealive',  note: 'Brown sugar',       amt: 9.90,  date: d(1) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Starbucks',note: 'Latte',             amt: 18.00, date: d(2) },
  { id: nid(), type: 'expense', cat: 'food', name: 'GrabFood', note: 'Nasi lemak',        amt: 24.30, date: d(3) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Sushi King',note:'Dinner',            amt: 56.80, date: d(4) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Kopitiam', note: 'Breakfast',         amt: 14.00, date: d(5) },
  { id: nid(), type: 'expense', cat: 'food', name: 'GrabFood', note: 'Team lunch',        amt: 68.50, date: d(6) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Zus Coffee',note:'Americano',         amt: 10.60, date: d(7) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Nando’s', note: 'Dinner w/ friends', amt: 78.40, date: d(8) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Mamak',    note: 'Supper',            amt: 21.00, date: d(9) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Family Mart',note:'Snacks',           amt: 16.20, date: d(9) },
  { id: nid(), type: 'expense', cat: 'food', name: 'GrabFood', note: 'Lunch',             amt: 27.90, date: d(10) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Tealive',  note: 'Afternoon',         amt: 11.40, date: d(11) },
  { id: nid(), type: 'expense', cat: 'food', name: 'Kopitiam', note: 'Breakfast',         amt: 13.50, date: d(11) },
  // Shopping — over budget (RM420, budget 300)
  { id: nid(), type: 'expense', cat: 'shop', name: 'Shopee', note: 'Phone case + cable', amt: 89.00,  date: d(2) },
  { id: nid(), type: 'expense', cat: 'shop', name: 'Uniqlo', note: 'T-shirts',           amt: 139.00, date: d(5) },
  { id: nid(), type: 'expense', cat: 'shop', name: 'Lazada', note: 'Desk lamp',          amt: 72.00,  date: d(7) },
  { id: nid(), type: 'expense', cat: 'shop', name: 'AEON',   note: 'Homeware',           amt: 120.00, date: d(9) },
  // Groceries
  { id: nid(), type: 'expense', cat: 'groc', name: '99 Speedmart', note: 'Essentials',    amt: 43.20,  date: d(2) },
  { id: nid(), type: 'expense', cat: 'groc', name: 'Jaya Grocer',  note: 'Weekly shop',   amt: 156.70, date: d(6) },
  { id: nid(), type: 'expense', cat: 'groc', name: 'AEON',         note: 'Fresh produce', amt: 88.40,  date: d(10) },
  // Bills
  { id: nid(), type: 'expense', cat: 'bill', name: 'TNB',   note: 'Electricity',  amt: 142.00, date: d(3) },
  { id: nid(), type: 'expense', cat: 'bill', name: 'Maxis', note: 'Phone plan',   amt: 98.00,  date: d(4) },
  { id: nid(), type: 'expense', cat: 'bill', name: 'Unifi', note: 'Home internet',amt: 129.00, date: d(4) },
  // Entertainment
  { id: nid(), type: 'expense', cat: 'ent', name: 'Netflix', note: 'Subscription', amt: 55.00, date: d(1) },
  { id: nid(), type: 'expense', cat: 'ent', name: 'Spotify', note: 'Premium',      amt: 17.90, date: d(1) },
  { id: nid(), type: 'expense', cat: 'ent', name: 'GSC',     note: 'Movie night',  amt: 42.00, date: d(8) },
  // Health
  { id: nid(), type: 'expense', cat: 'hlth', name: 'Guardian', note: 'Vitamins', amt: 64.90, date: d(6) },
];

export const DEFAULT_SETTINGS: Settings = {
  income: 6500,
  savingTarget: 1500,
  investTarget: 800,
  currency: 'RM',
  budgets: CATEGORIES.reduce((m, c) => { m[c.id] = c.budget!; return m; }, {} as Record<string, number>),
  notifications: true,
  roundUps: false,
};

export function money(n: number, opts: { cents?: boolean; sign?: boolean; cur?: string } = {}): string {
  const { cents = false, sign = false, cur = 'RM' } = opts;
  const neg = n < 0;
  const abs = Math.abs(n);
  const s = abs.toLocaleString('en-MY', {
    minimumFractionDigits: cents ? 2 : 0,
    maximumFractionDigits: cents ? 2 : 0,
  });
  const prefix = sign ? (neg ? '−' : '+') : (neg ? '−' : '');
  return prefix + cur + s;
}

export function dateLabel(iso: string): string {
  const dt = new Date(iso);
  const day = dt.getDate();
  if (day === DAY) return 'Today';
  if (day === DAY - 1) return 'Yesterday';
  return dt.toLocaleDateString('en-MY', { day: 'numeric', month: 'short' });
}

export function categoryTotals(txns: Transaction[]): Record<string, number> {
  const m: Record<string, number> = {};
  CATEGORIES.forEach(c => { m[c.id] = 0; });
  txns.filter(t => t.type === 'expense').forEach(t => { m[t.cat] = (m[t.cat] || 0) + t.amt; });
  return m;
}

export function summary(txns: Transaction[], settings: Settings) {
  const totalSpent = txns.filter(t => t.type === 'expense').reduce((s, t) => s + t.amt, 0);
  const totalInvest = txns.filter(t => t.type === 'invest').reduce((s, t) => s + t.amt, 0);
  const totalIncome = txns.filter(t => t.type === 'income').reduce((s, t) => s + t.amt, 0);
  const totalBudget = CATEGORIES.reduce((s, c) => s + (settings.budgets[c.id] || 0), 0);
  const expectedByNow = totalBudget * (DAY / DAYS_IN_MONTH);
  const remaining = totalBudget - totalSpent;
  const dailyLeft = DAYS_LEFT > 0 ? remaining / DAYS_LEFT : remaining;
  const pacePct = totalBudget > 0 ? totalSpent / totalBudget : 0;
  const investRate = settings.income > 0 ? totalInvest / settings.income : 0;
  const saved = settings.income - totalSpent - totalInvest;
  return {
    totalSpent, totalInvest, totalIncome, totalBudget,
    expectedByNow, remaining, dailyLeft, pacePct, investRate, saved,
    day: DAY, daysInMonth: DAYS_IN_MONTH, daysLeft: DAYS_LEFT,
    onTrack: totalSpent <= expectedByNow,
  };
}

export function dailyTrend(txns: Transaction[]) {
  const arr = [];
  for (let i = 1; i <= DAY; i++) {
    const tot = txns
      .filter(t => t.type === 'expense' && new Date(t.date).getDate() === i)
      .reduce((s, t) => s + t.amt, 0);
    arr.push({ day: i, total: tot });
  }
  return arr;
}

export function weeklyTrend(txns: Transaction[]) {
  const weeks = [0, 0, 0, 0, 0];
  txns.filter(t => t.type === 'expense').forEach(t => {
    const wk = Math.min(4, Math.floor((new Date(t.date).getDate() - 1) / 7));
    weeks[wk] += t.amt;
  });
  return weeks.slice(0, Math.ceil(DAY / 7)).map((v, i) => ({ label: 'W' + (i + 1), total: v }));
}

export interface Signal {
  id: string;
  tone: 'warm' | 'green' | 'blue';
  icon: string;
  cat?: Category;
  title: string;
  sub: string;
}

export function computeSignals(txns: Transaction[], settings: Settings): Signal[] {
  const out: Signal[] = [];
  const sum = summary(txns, settings);
  const totals = categoryTotals(txns);
  const expectedFrac = DAY / DAYS_IN_MONTH;

  // 1. category moving fast
  let fastest: { cat: Category; spent: number; bud: number; frac: number; speed: number } | null = null;
  CATEGORIES.forEach(c => {
    const spent = totals[c.id]; const bud = settings.budgets[c.id] || 0;
    if (bud <= 0 || spent <= 0) return;
    const frac = spent / bud;
    const speed = frac / expectedFrac;
    if (speed > 1.15 && frac < 1 && (!fastest || speed > fastest.speed)) {
      fastest = { cat: c, spent, bud, frac, speed };
    }
  });
  if (fastest) {
    const f = fastest as { cat: Category; spent: number; bud: number; frac: number; speed: number };
    out.push({
      id: 'fast', tone: 'warm', icon: 'fire', cat: f.cat,
      title: `${f.cat.name} is moving fast this month`,
      sub: `${money(f.spent)} of ${money(f.bud)} · ${Math.round(f.frac * 100)}% used, ${Math.round(expectedFrac * 100)}% of the month gone`,
    });
  }

  // 2. over budget
  let over: { cat: Category; amt: number; spent: number; bud: number } | null = null;
  CATEGORIES.forEach(c => {
    const spent = totals[c.id]; const bud = settings.budgets[c.id] || 0;
    if (bud > 0 && spent > bud) {
      const amt = spent - bud;
      if (!over || amt > over.amt) over = { cat: c, amt, spent, bud };
    }
  });
  if (over) {
    const o = over as { cat: Category; amt: number; spent: number; bud: number };
    out.push({
      id: 'over', tone: 'warm', icon: 'alert', cat: o.cat,
      title: `${o.cat.name} is ${money(o.amt)} over budget`,
      sub: `Spent ${money(o.spent)} against a ${money(o.bud)} budget`,
    });
  }

  // 3. daily left
  if (sum.remaining > 0 && sum.daysLeft > 0) {
    out.push({
      id: 'daily', tone: 'blue', icon: 'wallet',
      title: `You have ${money(sum.dailyLeft)}/day left before your limit`,
      sub: `${money(sum.remaining)} across ${sum.daysLeft} days keeps you on budget`,
    });
  } else if (sum.remaining <= 0) {
    out.push({
      id: 'daily', tone: 'warm', icon: 'wallet',
      title: `You’ve reached your monthly budget`,
      sub: `${money(-sum.remaining)} over your total limit so far`,
    });
  }

  // 4. invested so far
  if (sum.totalInvest > 0) {
    const pctTarget = settings.investTarget > 0
      ? Math.round(sum.totalInvest / settings.investTarget * 100) : 0;
    out.push({
      id: 'invest', tone: 'green', icon: 'invest',
      title: `You’ve invested ${money(sum.totalInvest)} so far`,
      sub: `${pctTarget}% of your ${money(settings.investTarget)} monthly target`,
    });
  }

  // 5. recurring merchant
  const counts: Record<string, { n: number; total: number }> = {};
  txns.filter(t => t.type === 'expense').forEach(t => {
    if (!counts[t.name]) counts[t.name] = { n: 0, total: 0 };
    counts[t.name].n++;
    counts[t.name].total += t.amt;
  });
  let topMerchant: { name: string; n: number; total: number } | null = null;
  Object.entries(counts).forEach(([name, v]) => {
    if (v.n >= 4 && (!topMerchant || v.n > topMerchant.n)) topMerchant = { name, ...v };
  });
  if (topMerchant) {
    const m = topMerchant as { name: string; n: number; total: number };
    out.push({
      id: 'merchant', tone: 'blue', icon: 'repeat',
      title: `${m.name} appeared ${m.n} times this month`,
      sub: `Totalling ${money(m.total, { cents: true })} — your most frequent spend`,
    });
  }

  // 6. on-track
  if (sum.onTrack && !over) {
    out.push({
      id: 'ontrack', tone: 'green', icon: 'check',
      title: `Nice — you’re pacing under budget`,
      sub: `${money(sum.expectedByNow - sum.totalSpent)} below where you'd expect by day ${DAY}`,
    });
  }

  return out;
}

export function recentTxns(txns: Transaction[], limit?: number): Transaction[] {
  const sorted = [...txns].sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime() || (b.id > a.id ? 1 : -1));
  return limit ? sorted.slice(0, limit) : sorted;
}
