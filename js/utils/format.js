/** الصياغة العربية للأرقام والأوقات. */

let TZ = 'Africa/Cairo';
export function setTimezone(tz) { if (tz) TZ = tz; }
export function timezone() { return TZ; }

/** مدة مقروءة: "٣ س ٢٥ د" — نستخدم أرقامًا لاتينية لوضوح القراءة في الجداول. */
export function duration(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (h === 0 && m === 0) return `${s} ث`;
  if (h === 0) return `${m} د`;
  return `${h} س ${m} د`;
}

/** مدة بصيغة الساعة الرقمية HH:MM:SS — للعدّاد الحي. */
export function clock(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const p = (n) => String(n).padStart(2, '0');
  return `${p(Math.floor(s / 3600))}:${p(Math.floor((s % 3600) / 60))}:${p(s % 60)}`;
}

export function time(iso) {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('ar-EG', {
    timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false, numberingSystem: 'latn'
  }).format(new Date(iso));
}

export function dateTime(iso) {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('ar-EG', {
    timeZone: TZ, year: 'numeric', month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: false, numberingSystem: 'latn'
  }).format(new Date(iso));
}

export function date(value) {
  if (!value) return '—';
  const d = typeof value === 'string' && value.length === 10 ? new Date(value + 'T12:00:00Z') : new Date(value);
  return new Intl.DateTimeFormat('ar-EG', {
    timeZone: typeof value === 'string' && value.length === 10 ? 'UTC' : TZ,
    weekday: 'short', year: 'numeric', month: 'short', day: 'numeric', numberingSystem: 'latn'
  }).format(d);
}

export function pct(value) {
  if (value === null || value === undefined) return '—';
  return `${Number(value).toFixed(1)}%`;
}

export function number(value) {
  return new Intl.NumberFormat('ar-EG', { numberingSystem: 'latn' }).format(Number(value) || 0);
}

export function hours(seconds) {
  return (Math.max(0, Number(seconds) || 0) / 3600).toFixed(1);
}

/** "منذ ٥ دقائق" */
export function relative(iso, nowDate) {
  if (!iso) return 'لا يوجد';
  const diff = Math.floor(((nowDate || new Date()).getTime() - Date.parse(iso)) / 1000);
  if (diff < 10) return 'الآن';
  if (diff < 60) return `منذ ${diff} ثانية`;
  if (diff < 3600) return `منذ ${Math.floor(diff / 60)} دقيقة`;
  if (diff < 86400) return `منذ ${Math.floor(diff / 3600)} ساعة`;
  return `منذ ${Math.floor(diff / 86400)} يوم`;
}

export const PRESENCE_LABEL = {
  active: 'نشط', idle: 'خامل', break: 'في استراحة',
  disconnected: 'غير متصل', ended: 'أنهى العمل',
  not_started: 'لم يبدأ العمل', offline: 'غير متصل'
};

export const ROLE_LABEL = { employee: 'موظف', manager: 'مدير / موارد بشرية', super_admin: 'مدير عام' };
export const STATUS_LABEL = { active: 'نشط', suspended: 'موقوف', archived: 'مؤرشف' };
export const BREAK_LABEL = { general: 'استراحة عامة', lunch: 'استراحة غداء', prayer: 'صلاة', personal: 'شخصية' };

export function initials(name) {
  if (!name) return '؟';
  const parts = String(name).trim().split(/\s+/);
  return (parts[0][0] || '') + (parts.length > 1 ? parts[1][0] : '');
}
