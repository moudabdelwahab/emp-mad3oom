/** لوحة الموظف الشخصية. */
import { requireAuth, state } from '../auth/guard.js';
import { renderShell, setConnection, pageTitle } from '../components/shell.js';
import { createShiftPanel } from '../attendance/controls.js';
import { ActivityTracker } from '../activity/tracker.js';
import { api } from '../services/api.js';
import { el, mount, toast } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { stat, card, timeline, table, formulaNote } from '../components/widgets.js';
import { duration, pct, time, relative, dateTime } from '../utils/format.js';
import { serverNow, dateKey } from '../utils/time.js';
import { messageOf } from '../services/errors.js';

const auth = await requireAuth();
if (auth) {
  pageTitle('لوحتي');
  const { content } = renderShell({
    title: `أهلًا، ${state.me.employee.full_name.split(' ')[0]}`,
    subtitle: `اليوم ${new Date(state.me.work_date + 'T12:00:00Z').toLocaleDateString('ar-EG', { weekday: 'long', day: 'numeric', month: 'long' })}`
  });

  const statsBox    = el('div', { class: 'stat-grid' });
  const timelineBox = el('div');
  const activityBox = el('div');

  const panel = createShiftPanel({ onChange: (status) => { paint(status); refreshDetails(); } });

  mount(content,
    el('div', { class: 'shift-panel' }, [panel.root, el('div', {}, [statsBox])]),
    card('الخط الزمني لليوم', timelineBox, [
      el('button', { class: 'icon-btn', title: 'تحديث', html: icon('refresh'), onclick: () => refreshDetails() })
    ]),
    card('آخر العمليات داخل المنصة', activityBox),
    formulaNote()
  );

  panel.update(state.me);
  paint(state.me);
  await refreshDetails();

  /* ── محرك التتبّع: هو مصدر التحديث اللحظي للأرقام ── */
  const tracker = new ActivityTracker({
    onStatus: (res) => {
      if (res.status === 'ok') {
        setConnection(true, `آخر مزامنة ${time(res.server_time)}`);
        paintTotals(res.totals, res.presence);
      } else if (res.status === 'offline_client') {
        setConnection(false, 'لا يوجد اتصال — سيُستأنف تلقائيًا');
      } else if (res.status === 'retrying') {
        setConnection(false, `تعذّرت المزامنة، إعادة المحاولة خلال ${Math.round(res.in_seconds)} ثانية`);
      } else if (res.status === 'no_session') {
        setConnection(true, 'لا يوجد شيفت مفتوح');
      }
    },
    onError: (err) => { if (err.isAuth) toast(messageOf(err), 'error'); }
  });
  tracker.start();
  window.eoTracker = tracker;   // متاح للتطبيق لتسجيل أحداث عمل صريحة

  // مزامنة كاملة دورية مع الخادم (الخادم هو الحقيقة، لا العدّاد المحلي)
  setInterval(async () => {
    try {
      const me = await api.me();
      panel.update(me);
      paint(me);
    } catch (err) { if (err.isAuth) location.replace('login.html'); }
  }, 120000);

  function paint(status) {
    paintTotals(status.totals, status.presence);
  }

  function paintTotals(t, presence) {
    if (!t) return;
    const denom = Math.max((t.shift_seconds || 0) - (t.break_seconds || 0), 0);
    const p = denom > 0 ? ((t.active_seconds || 0) / denom) * 100 : null;
    mount(statsBox,
      stat('مدة العمل اليوم', duration(t.shift_seconds), { iconName: 'clock' }),
      stat('وقت النشاط', duration(t.active_seconds), { iconName: 'activity', accent: true, meterPct: p }),
      stat('وقت الخمول', duration(t.idle_seconds), { iconName: 'pause' }),
      stat('الاستراحات', duration(t.break_seconds), { iconName: 'coffee' }),
      stat('نسبة النشاط', p === null ? '—' : pct(p), { sub: 'من وقت العمل بعد خصم الاستراحات', iconName: 'chart' })
    );
  }

  async function refreshDetails() {
    try {
      const [tl, acts] = await Promise.all([
        api.myTimeline(null),
        api.myActivity(null, 40)
      ]);

      mount(timelineBox, timeline(tl));

      mount(activityBox, table(
        ['الوقت', 'العملية', 'العنصر', 'المصدر'],
        acts,
        (a) => [
          el('span', { class: 'num', text: time(a.occurred_at) }),
          a.event_label,
          [a.entity_type, a.entity_id].filter(Boolean).join(' · ') || '—',
          a.source_app === 'mad3oom' ? 'منصة مدعوم' : 'لوحة العمليات'
        ],
        { empty: 'لم تُسجَّل عمليات بعد اليوم. ستظهر هنا فور تنفيذك لأي عملية داخل المنصة.' }
      ));
    } catch (err) {
      toast(messageOf(err), 'error');
    }
  }
}
