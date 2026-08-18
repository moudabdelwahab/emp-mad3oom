/**
 * السمة: فاتح / داكن / حسب النظام.
 * الوضع الافتراضي هو تفضيل النظام، والفاتح هو الأساس في التصميم.
 */
const KEY = 'eo.theme';
const ORDER = ['system', 'light', 'dark'];
export const LABEL = { system: 'حسب النظام', light: 'فاتح', dark: 'داكن' };

export function current() {
  const v = localStorage.getItem(KEY);
  return ORDER.includes(v) ? v : 'system';
}

export function apply(mode = current()) {
  const root = document.documentElement;
  if (mode === 'system') root.removeAttribute('data-theme');
  else root.setAttribute('data-theme', mode);
  localStorage.setItem(KEY, mode);
  return mode;
}

export function cycle() {
  const next = ORDER[(ORDER.indexOf(current()) + 1) % ORDER.length];
  return apply(next);
}

/** يُستدعى مبكرًا جدًا لتفادي وميض الألوان. */
export function init() { apply(); }
