/** ملف الموظف: يومه، خطه الزمني، عملياته، وتاريخه. */
import { requireAuth, isAdmin } from '../auth/guard.js';
import { renderShell, pageTitle } from '../components/shell.js';
import { api } from '../services/api.js';
import { el, mount, toast, confirmDialog, formDialog } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { stat, card, table, timeline, presenceBadge, barChart, formulaNote } from '../components/widgets.js';
import { duration, pct, time, dateTime, date as fmtDate, relative, hours } from '../utils/format.js';
import { serverNow, dateKey, addDays } from '../utils/time.js';
import { messageOf } from '../services/errors.js';

const auth = await requireAuth({ minRank: 50 });
if (auth) {
  const employeeId = new URLSearchParams(location.search).get('id');
  if (!employeeId) location.replace('admin.html');

  pageTitle('ملف الموظف');

  let day = dateKey(serverNow(), auth.me.settings.timezone);

  const dayInput = el('input', { type: 'date', value: day, style: 'width:auto',
    onchange: (e) => { day = e.target.value; loadDay(); } });
  const { content } = renderShell({ title: 'ملف الموظف', actions: [dayInput] });

  const headBox     = el('div');
  const statsBox    = el('div', { class: 'stat-grid' });
  const timelineBox = el('div');
  const sessionsBox = el('div');
  const activityBox = el('div');
  const devicesBox  = el('div');
  const historyBox  = el('div');
  const chartBox    = el('div');

  mount(content,
    headBox,
    statsBox,
    card('الخط الزمني', timelineBox),
    card('جلسات الحضور والاستراحات', sessionsBox),
    card('العمليات داخل المنصة', activityBox),
    card('الأجهزة والجلسات', devicesBox),
    card('آخر ٣٠ يومًا', el('div', {}, [chartBox, historyBox])),
    formulaNote()
  );

  await loadDay();
  await loadHistory();

  async function loadDay() {
    try {
      const [detail, tl, acts] = await Promise.all([
        api.employeeDetail(employeeId, day),
        api.employeeTimeline(employeeId, day),
        api.employeeActivity(employeeId, day, 100)
      ]);

      const e = detail.employee;
      const t = detail.day_totals || {};
      const denom = Math.max((t.shift_seconds || 0) - (t.break_seconds || 0), 0);
      const p = denom > 0 ? ((t.active_seconds || 0) / denom) * 100 : null;

      mount(headBox, el('section', { class: 'card' }, [
        el('div', { class: 'card-body row wrap' }, [
          el('div', {}, [
            el('h2', { text: e.full_name }),
            el('div', { class: 'small muted', text: [e.email, e.employee_code, e.team, e.role_label].filter(Boolean).join(' · ') })
          ]),
          el('div', { class: 'spacer' }),
          presenceBadge(detail.presence, detail.presence_label),
          detail.session ? el('span', { class: 'small muted', text: `منذ ${time(detail.session.started_at)}` }) : null
        ])
      ]));

      mount(statsBox,
        stat('مدة العمل', duration(t.shift_seconds), { iconName: 'clock' }),
        stat('وقت النشاط', duration(t.active_seconds), { iconName: 'activity', accent: true, meterPct: p }),
        stat('وقت الخمول', duration(t.idle_seconds), { iconName: 'pause' }),
        stat('الاستراحات', duration(t.break_seconds), { iconName: 'coffee' }),
        stat('نسبة النشاط', p === null ? '—' : pct(p), { iconName: 'chart' }),
        stat('آخر تفاعل', relative(detail.last_interaction_at, serverNow()), { iconName: 'clock' })
      );

      mount(timelineBox, timeline(tl));

      const sessions = detail.sessions || [];
      const breaks = detail.breaks || [];
      mount(sessionsBox, el('div', {}, [
        table(['البداية', 'النهاية', 'المدة', 'الحالة', 'التأخير', 'ملاحظة', ''], sessions, (s) => [
          el('span', { class: 'num', text: time(s.started_at) }),
          el('span', { class: 'num', text: s.ended_at ? time(s.ended_at) : '—' }),
          duration(s.duration_seconds),
          el('span', { class: `badge plain ${s.status === 'open' ? 'badge-active' : s.status === 'auto_closed' ? 'badge-warning' : 'badge-ended'}`,
                       text: s.status === 'open' ? 'مفتوح' : s.status === 'auto_closed' ? 'إغلاق تلقائي' : 'مغلق' }),
          s.late_seconds > 0 ? duration(s.late_seconds) : '—',
          el('span', { class: 'xsmall dim', text: (s.adjusted ? 'مُعدَّل إداريًا · ' : '') + (s.end_reason || '') }),
          isAdmin() && s.status !== 'open'
            ? el('button', { class: 'btn btn-sm btn-ghost', text: 'تعديل', onclick: () => adjust(s) })
            : null
        ], { empty: 'لا توجد جلسات حضور في هذا اليوم.' }),
        breaks.length ? el('div', { class: 'mt-6' }, [
          el('div', { class: 'strong small mb-4', text: 'الاستراحات' }),
          table(['البداية', 'النهاية', 'المدة', 'النوع'], breaks, (b) => [
            el('span', { class: 'num', text: time(b.started_at) }),
            el('span', { class: 'num', text: b.ended_at ? time(b.ended_at) : '—' }),
            duration(b.duration_seconds),
            b.break_type
          ])
        ]) : null
      ]));

      mount(activityBox, table(['الوقت', 'العملية', 'العنصر', 'المصدر'], acts, (a) => [
        el('span', { class: 'num', text: time(a.occurred_at) }),
        a.event_label,
        [a.entity_type, a.entity_id].filter(Boolean).join(' · ') || '—',
        a.source_app === 'mad3oom' ? 'منصة مدعوم' : 'لوحة العمليات'
      ], { empty: 'لا توجد عمليات مسجَّلة في هذا اليوم.' }));

      mount(devicesBox, table(['الجهاز', 'التطبيق', 'أول ظهور', 'آخر ظهور', 'النظام', 'IP'], detail.devices || [], (d) => [
        el('span', { class: 'mono xsmall', text: String(d.device_id).slice(0, 8) }),
        d.source_app === 'mad3oom' ? 'منصة مدعوم' : 'لوحة العمليات',
        el('span', { class: 'num', text: time(d.started_at) }),
        el('span', { class: 'num', text: time(d.last_seen_at) }),
        d.platform || '—',
        el('span', { class: 'mono xsmall', text: d.ip || '—' })
      ], { empty: 'لا توجد أجهزة مسجَّلة في هذا اليوم.' }));
    } catch (err) {
      toast(messageOf(err), 'error');
    }
  }

  async function loadHistory() {
    try {
      const to = dateKey(serverNow(), auth.me.settings.timezone);
      const from = addDays(to, -29);
      const rows = await api.employeeHistory(employeeId, from, to);

      mount(chartBox, barChart([...rows].reverse()));
      mount(historyBox, el('div', { class: 'mt-6' }, [table(
        ['اليوم', 'البداية', 'النهاية', 'العمل', 'النشاط', 'الخمول', 'الاستراحة', 'النشاط %', 'الحالة'],
        rows,
        (r) => [
          fmtDate(r.work_date),
          el('span', { class: 'num', text: r.first_start_at ? time(r.first_start_at) : '—' }),
          el('span', { class: 'num', text: r.last_end_at ? time(r.last_end_at) : '—' }),
          duration(r.shift_seconds),
          duration(r.active_seconds),
          duration(r.idle_seconds),
          duration(r.break_seconds),
          r.active_pct === null ? '—' : pct(r.active_pct),
          r.is_absent ? el('span', { class: 'badge badge-danger plain', text: 'غياب' })
            : r.is_late ? el('span', { class: 'badge badge-warning plain', text: `تأخير ${duration(r.late_seconds)}` })
            : el('span', { class: 'badge badge-success plain', text: 'حضور' })
        ],
        { empty: 'لا توجد أيام مسجَّلة بعد.' }
      )]));
    } catch (err) { toast(messageOf(err), 'error'); }
  }

  async function adjust(session) {
    const toLocal = (iso) => {
      if (!iso) return '';
      const d = new Date(iso);
      const p = (n) => String(n).padStart(2, '0');
      return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
    };
    const out = await formDialog({
      title: 'تعديل سجل الحضور',
      submitText: 'حفظ التعديل',
      fields: [
        { name: 'started_at', label: 'وقت البداية', type: 'datetime-local', value: toLocal(session.started_at), required: true },
        { name: 'ended_at', label: 'وقت النهاية', type: 'datetime-local', value: toLocal(session.ended_at), required: true },
        { name: 'reason', label: 'سبب التعديل', type: 'textarea', required: true,
          hint: 'يُحفظ السبب في سجل التدقيق باسمك ولا يمكن حذفه.' }
      ]
    });
    if (!out) return;
    try {
      const res = await api.adjustAttendance(
        session.id, new Date(out.started_at).toISOString(), new Date(out.ended_at).toISOString(), out.reason);
      toast(res.message, 'success');
      await loadDay(); await loadHistory();
    } catch (err) { toast(messageOf(err), 'error'); }
  }
}
