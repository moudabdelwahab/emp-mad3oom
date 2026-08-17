/** أيقونات SVG خطية (بلا إيموجي، بلا مكتبات خارجية). كلها currentColor. */
const w = (d, extra = '') =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}${extra}</svg>`;

export const icons = {
  logo:      w('<path d="M12 2 3 6.5v5c0 5 3.8 9.2 9 10.5 5.2-1.3 9-5.5 9-10.5v-5L12 2Z"/><path d="M12 8v4l2.5 1.6"/>'),
  dashboard: w('<rect x="3" y="3" width="7" height="8" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="11" width="7" height="10" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/>'),
  users:     w('<path d="M16 20v-1.5a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4V20"/><circle cx="9" cy="7" r="3.2"/><path d="M22 20v-1.5a4 4 0 0 0-3-3.87"/><path d="M16.5 3.7a4 4 0 0 1 0 7.1"/>'),
  chart:     w('<path d="M4 20V10"/><path d="M10 20V4"/><path d="M16 20v-7"/><path d="M22 20H2"/>'),
  clock:     w('<circle cx="12" cy="12" r="9"/><path d="M12 7v5.2l3.2 2"/>'),
  play:      w('<path d="M6.5 4.8v14.4a1 1 0 0 0 1.53.85l11.2-7.2a1 1 0 0 0 0-1.7L8.03 3.95a1 1 0 0 0-1.53.85Z"/>'),
  stop:      w('<rect x="5.5" y="5.5" width="13" height="13" rx="2.5"/>'),
  pause:     w('<rect x="7" y="5" width="3.6" height="14" rx="1.3"/><rect x="13.4" y="5" width="3.6" height="14" rx="1.3"/>'),
  coffee:    w('<path d="M4 8h13v6a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5V8Z"/><path d="M17 9h1.6a2.4 2.4 0 0 1 0 4.8H17"/><path d="M7 2.5v2M11 2.5v2"/>'),
  settings:  w('<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .32 1.77l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.6 1.6 0 0 0-2.72 1.13V21a2 2 0 1 1-4 0v-.1A1.6 1.6 0 0 0 7.5 19.4a1.6 1.6 0 0 0-1.77.32l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.6 1.6 0 0 0 3.03 14 1.6 1.6 0 0 0 1.5 12.9H1.4a2 2 0 1 1 0-4h.1A1.6 1.6 0 0 0 3.03 7.5a1.6 1.6 0 0 0-.32-1.77l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.6 1.6 0 0 0 7.5 3.03H7.6A2 2 0 1 1 11.6 3v.1a1.6 1.6 0 0 0 2.72 1.13 1.6 1.6 0 0 0 1.77-.32l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.6 1.6 0 0 0-.32 1.77v.08A1.6 1.6 0 0 0 22.5 10.4h.1a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.47 1Z"/>'),
  shield:    w('<path d="M12 21s8-3.5 8-9.5V5.5L12 2.8 4 5.5V11.5C4 17.5 12 21 12 21Z"/><path d="M9.2 12.2 11 14l4-4"/>'),
  logout:    w('<path d="M9.5 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4.5"/><path d="M16 16l5-4-5-4"/><path d="M21 12H9"/>'),
  sun:       w('<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>'),
  moon:      w('<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/>'),
  menu:      w('<path d="M4 7h16M4 12h16M4 17h16"/>'),
  refresh:   w('<path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 4v5h-5"/>'),
  download:  w('<path d="M12 3v12"/><path d="m7.5 11 4.5 4.5 4.5-4.5"/><path d="M4 20h16"/>'),
  file:      w('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8l-5-5Z"/><path d="M14 3v5h5"/>'),
  history:   w('<path d="M3 12a9 9 0 1 0 2.6-6.4"/><path d="M3 4v5h5"/><path d="M12 8v4.5l3 1.8"/>'),
  warning:   w('<path d="M10.3 3.9 2.6 17.1A2 2 0 0 0 4.3 20h15.4a2 2 0 0 0 1.7-2.9L13.7 3.9a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4"/><path d="M12 16.5h.01"/>'),
  check:     w('<path d="M20 6 9 17l-5-5"/>'),
  info:      w('<circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 8h.01"/>'),
  device:    w('<rect x="2" y="4" width="14" height="11" rx="2"/><path d="M2 19h20"/><rect x="18" y="9" width="4" height="8" rx="1.2"/>'),
  activity:  w('<path d="M3 12h4l2.5-7 5 14 2.5-7h4"/>'),
  calendar:  w('<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>'),
  search:    w('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>'),
  plus:      w('<path d="M12 5v14M5 12h14"/>'),
  close:     w('<path d="M18 6 6 18M6 6l12 12"/>'),
  eye:       w('<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>'),
  inbox:     w('<path d="M3 12h5l1.5 3h5L16 12h5"/><path d="M4.4 5.6 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-2.4-6.4A2 2 0 0 0 17.7 4H6.3a2 2 0 0 0-1.9 1.6Z"/>')
};

export function icon(name) { return icons[name] || ''; }
