'use client';

interface IconProps {
  name: string;
  size?: number;
  sw?: number;
  style?: React.CSSProperties;
}

export default function Icon({ name, size = 22, sw = 1.9, style }: IconProps) {
  const p = {
    fill: 'none' as const,
    stroke: 'currentColor' as const,
    strokeWidth: sw,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
  };

  const paths: Record<string, React.ReactNode> = {
    home: <><path d="M3 10.5 12 3l9 7.5" {...p}/><path d="M5.5 9.5V20h13V9.5" {...p}/><path d="M9.5 20v-5.5h5V20" {...p}/></>,
    stats: <><path d="M4 20V10" {...p}/><path d="M10 20V4" {...p}/><path d="M16 20v-7" {...p}/><path d="M3 20h18" {...p}/></>,
    settings: <><path d="M4 7h10" {...p}/><path d="M18 7h2" {...p}/><circle cx="16" cy="7" r="2.3" {...p}/><path d="M4 17h6" {...p}/><path d="M14 17h6" {...p}/><circle cx="12" cy="17" r="2.3" {...p}/></>,
    plus: <><path d="M12 5v14M5 12h14" {...p} strokeWidth={2.4}/></>,
    minus: <><path d="M5 12h14" {...p} strokeWidth={2.4}/></>,
    food: <><path d="M6 3v7a2.5 2.5 0 0 0 5 0V3" {...p}/><path d="M8.5 10v11" {...p}/><path d="M17 3c-1.5 0-2.5 2-2.5 5s1 4 2.5 4 2.5-1 2.5-4-1-5-2.5-5Z" {...p}/><path d="M17 12v9" {...p}/></>,
    groc: <><path d="M4 6h2l2 11h9l2-8H7" {...p}/><circle cx="9.5" cy="20" r="1.2" {...p}/><circle cx="16.5" cy="20" r="1.2" {...p}/></>,
    tpt: <><rect x="4" y="5" width="16" height="11" rx="3" {...p}/><path d="M4 11h16" {...p}/><path d="M8 16v2.5M16 16v2.5" {...p}/><path d="M8 8h2M14 8h2" {...p}/></>,
    shop: <><path d="M5 8h14l-1 11.5a1.5 1.5 0 0 1-1.5 1.4h-9A1.5 1.5 0 0 1 6 19.5L5 8Z" {...p}/><path d="M8.5 8V6.5a3.5 3.5 0 0 1 7 0V8" {...p}/></>,
    bill: <><path d="M6 3h9l3 3v15l-2.2-1.3L13.6 21l-2.1-1.3L9.4 21l-2.1-1.3L5 21V3Z" {...p}/><path d="M8.5 8h7M8.5 12h7M8.5 16h4" {...p}/></>,
    ent: <><circle cx="12" cy="12" r="8.5" {...p}/><path d="M10 9l5 3-5 3V9Z" {...p}/></>,
    hlth: <><path d="M12 20s-7-4.3-7-9.4A4.1 4.1 0 0 1 12 8a4.1 4.1 0 0 1 7 2.6C19 15.7 12 20 12 20Z" {...p}/></>,
    edu: <><path d="M12 4 2.5 8.5 12 13l9.5-4.5L12 4Z" {...p}/><path d="M6 11v5c0 1.4 2.7 2.5 6 2.5s6-1.1 6-2.5v-5" {...p}/></>,
    misc: <><circle cx="6" cy="12" r="1.6" {...p} fill="currentColor"/><circle cx="12" cy="12" r="1.6" {...p} fill="currentColor"/><circle cx="18" cy="12" r="1.6" {...p} fill="currentColor"/></>,
    inc: <><path d="M12 4v13" {...p}/><path d="M7 12l5 5 5-5" {...p}/><path d="M5 20h14" {...p}/></>,
    inv: <><path d="M4 16l5-5 4 3 7-8" {...p}/><path d="M20 11V6h-5" {...p}/></>,
    bank: <><path d="M12 3 3.5 7.5h17L12 3Z" {...p}/><path d="M5 10v7M9.5 10v7M14.5 10v7M19 10v7" {...p}/><path d="M3.5 20h17" {...p}/></>,
    coin: <><ellipse cx="12" cy="6.5" rx="7" ry="3" {...p}/><path d="M5 6.5v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6" {...p}/><path d="M5 12.5c0 1.7 3.1 3 7 3s7-1.3 7-3" {...p}/></>,
    gift: <><rect x="4" y="9" width="16" height="11" rx="1.5" {...p}/><path d="M3 9h18v3H3z" {...p}/><path d="M12 9v11" {...p}/><path d="M12 9C9 9 7.5 4 10 4s2 5 2 5Zm0 0c3 0 4.5-5 2-5s-2 5-2 5Z" {...p}/></>,
    fire: <><path d="M12 3c.5 3-2 4-2 7a3 3 0 0 0 6 0c0-1-.5-2-1-2.5C16 9 17 11 17 14a5 5 0 0 1-10 0c0-4 3-5.5 3-8 0-1.5 1-2.5 2-3Z" {...p}/></>,
    alert: <><path d="M12 4 2.8 20h18.4L12 4Z" {...p}/><path d="M12 10v4.5" {...p}/><circle cx="12" cy="17.5" r="0.4" {...p} fill="currentColor" strokeWidth={1.6}/></>,
    wallet: <><rect x="3.5" y="6" width="17" height="13" rx="3" {...p}/><path d="M3.5 10h17" {...p}/><circle cx="16.5" cy="14.5" r="1.1" {...p} fill="currentColor"/></>,
    invest: <><path d="M4 16l5-5 4 3 7-8" {...p}/><path d="M20 11V6h-5" {...p}/></>,
    repeat: <><path d="M4 9a5 5 0 0 1 5-5h7" {...p}/><path d="M13 1.5 16.5 4 13 6.5" {...p}/><path d="M20 15a5 5 0 0 1-5 5H8" {...p}/><path d="M11 22.5 7.5 20 11 17.5" {...p}/></>,
    check: <><circle cx="12" cy="12" r="8.5" {...p}/><path d="M8.5 12.5l2.5 2.5 4.5-5" {...p}/></>,
    chevron: <><path d="M9 5l7 7-7 7" {...p}/></>,
    back: <><path d="M15 5l-7 7 7 7" {...p}/></>,
    close: <><path d="M6 6l12 12M18 6 6 18" {...p}/></>,
    trash: <><path d="M5 7h14" {...p}/><path d="M9 7V5.5A1.5 1.5 0 0 1 10.5 4h3A1.5 1.5 0 0 1 15 5.5V7" {...p}/><path d="M6.5 7l.8 12a1.5 1.5 0 0 0 1.5 1.4h6.4a1.5 1.5 0 0 0 1.5-1.4L18.5 7" {...p}/></>,
    target: <><circle cx="12" cy="12" r="8.5" {...p}/><circle cx="12" cy="12" r="4.5" {...p}/><circle cx="12" cy="12" r="0.6" {...p} fill="currentColor" strokeWidth={1.6}/></>,
    save: <><path d="M19 8c1 0 1.5 1 1.5 2s-.5 2-1.5 2c0 3.5-3 6-7 6s-7-2.5-7-6 3-6.5 7-6.5c1.4 0 2.7.3 3.8.9" {...p}/><path d="M15 5l1.5 2.5" {...p}/><circle cx="9" cy="11" r="0.5" {...p} fill="currentColor" strokeWidth={1.4}/></>,
    bell: <><path d="M6.5 10a5.5 5.5 0 0 1 11 0c0 5 2 6 2 6H4.5s2-1 2-6Z" {...p}/><path d="M10 19a2 2 0 0 0 4 0" {...p}/></>,
    moon: <><path d="M19 13.5A7.5 7.5 0 0 1 10.5 5a6 6 0 1 0 8.5 8.5Z" {...p}/></>,
    sun: <><circle cx="12" cy="12" r="4" {...p}/><path d="M12 2.5v2M12 19.5v2M4.5 4.5l1.5 1.5M18 18l1.5 1.5M2.5 12h2M19.5 12h2M4.5 19.5 6 18M18 6l1.5-1.5" {...p}/></>,
    auto: <><circle cx="12" cy="12" r="8.5" {...p}/><path d="M12 3.5v17a8.5 8.5 0 0 0 0-17Z" fill="currentColor" stroke="none"/></>,
    currency: <><circle cx="12" cy="12" r="8.5" {...p}/><path d="M9 9h4.5a2 2 0 0 1 0 4H9m0 0h5M9 7v10" {...p}/></>,
    palette: <><path d="M12 3a9 9 0 1 0 0 18c1.4 0 2-1 2-2 0-1.5 1-2 2.2-2H18a3 3 0 0 0 3-3c0-5-4-9-9-9Z" {...p}/><circle cx="7.5" cy="11" r="1" {...p} fill="currentColor"/><circle cx="9.5" cy="7" r="1" {...p} fill="currentColor"/><circle cx="14.5" cy="7" r="1" {...p} fill="currentColor"/><circle cx="16.5" cy="11" r="1" {...p} fill="currentColor"/></>,
    sparkle: <><path d="M12 4l1.6 4.4L18 10l-4.4 1.6L12 16l-1.6-4.4L6 10l4.4-1.6L12 4Z" {...p}/><path d="M18 15l.7 1.8L20.5 17.5l-1.8.7L18 20l-.7-1.8L15.5 17.5l1.8-.7L18 15Z" {...p}/></>,
    calendar: <><rect x="4" y="5.5" width="16" height="15" rx="3" {...p}/><path d="M4 10h16M8 3.5v4M16 3.5v4" {...p}/></>,
    note: <><path d="M5 4h10l4 4v12H5V4Z" {...p}/><path d="M14 4v5h5" {...p}/><path d="M8 13h7M8 16.5h4" {...p}/></>,
    wallet2: <><rect x="3.5" y="6" width="17" height="13" rx="3" {...p}/><path d="M3.5 10h17" {...p}/></>,
    leaf: <><path d="M5 19c0-8 6-13 14-13 0 8-6 13-14 13Z" {...p}/><path d="M5 19c2-5 5-8 9-10" {...p}/></>,
    tag: <><path d="M3.5 11.5 11 4h7v7l-7.5 7.5a2 2 0 0 1-2.8 0l-4.2-4.2a2 2 0 0 1 0-2.8Z" {...p}/><circle cx="14.5" cy="7.5" r="1.1" {...p} fill="currentColor"/></>,
    edit: <><path d="M14.5 5.5 18.5 9.5M4 20l1-4L16 5a2 2 0 0 1 3 3L8 19l-4 1Z" {...p}/></>,
  };

  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={style} aria-hidden="true">
      {paths[name] ?? null}
    </svg>
  );
}
