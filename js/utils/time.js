/**
 * الوقت.
 *
 * قاعدة: ساعة المتصفح غير موثوقة. كل استجابة من الخادم تحمل server_time،
 * ونحسب منها فرق الساعة ونستخدمه في كل عرض زمني. المدد الظاهرة على الشاشة
 * بين كل تحديث وآخر هي استيفاء بصري فقط — الأرقام المعتمدة تأتي من الخادم.
 */

let offsetMs = 0;          // خادم − عميل
let synced = false;

export function setServerTime(iso) {
  const t = Date.parse(iso);
  if (!Number.isNaN(t)) { offsetMs = t - Date.now(); synced = true; }
}

export const isSynced = () => synced;
export const clockSkewSeconds = () => Math.round(-offsetMs / 1000);
export function serverNow() { return new Date(Date.now() + offsetMs); }

/** ثوانٍ منقضية منذ لحظة معيّنة، بحساب ساعة الخادم. */
export function secondsSince(iso) {
  if (!iso) return 0;
  return Math.max(0, Math.floor((serverNow().getTime() - Date.parse(iso)) / 1000));
}

/** التاريخ بصيغة YYYY-MM-DD في منطقة زمنية محددة. */
export function dateKey(d = serverNow(), tz) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz || undefined, year: 'numeric', month: '2-digit', day: '2-digit'
  }).formatToParts(d);
  const get = (t) => parts.find((p) => p.type === t).value;
  return `${get('year')}-${get('month')}-${get('day')}`;
}

export function addDays(dateStr, n) {
  const d = new Date(dateStr + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function startOfWeek(dateStr) {
  const d = new Date(dateStr + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() - d.getUTCDay());   // الأسبوع يبدأ الأحد
  return d.toISOString().slice(0, 10);
}

export function startOfMonth(dateStr) {
  return dateStr.slice(0, 8) + '01';
}
