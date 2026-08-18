/** سجل الموظف الشخصي: أيامه السابقة وتقريره. */
import { requireAuth, state } from '../auth/guard.js';
import { renderShell, pageTitle } from '../components/shell.js';
import { api } from '../services/api.js';
import { el, mount, toast, busy } from '../utils/dom.js';
import { stat, card, table, barChart, timeline, formulaNote } from '../components/widgets.js';
import { duration, pct, time, hours, number, date as fmtDate } from '../utils/format.js';
import { serverNow, dateKey, addDays, startOfMonth } from '../utils/time.js';
import { messageOf } from '../services/errors.js';

const auth = await requireAuth();
if (auth) {
  pageTitle('سجلّي');

  const tz = auth.me.settings.timezone;
  const today = dateKey(serverNow(), tz);
  let from = startOfMonth(today), to = today;

  const fromInput = el('input', { type: 'date', value: from, onchange: (e) => from = e.target.value });
  const toInput   = el('input', { type: 'date', value: to,   onchange: (e) => to = e.target.value });
  const runBtn    = el('button', { class: 'btn btn-primary', text: 'عرض' });

  const { content } = renderShell({ title: 'سجلّي', subtitle: 'حضورك ونشاطك في الفترات السابقة' });

  const sumBox   = el('div', { class: 'stat-grid' });
  const chartBox = el('div');
  const tableBox = el('div');
  const dayBox   = el('div');

  mount(content,
    el('div', { class: 'filters' }, [
      el('div', { class: 'field' }, [el('label', { text: 'من' }), fromInput]),
      el('div', { class: 'field' }, [el('label', { text: 'إلى' }), toInput]),
      el('div', { class: 'row' }, [runBtn])
    ]),
    sumBox,
    card('التوزيع اليومي', chartBox),
    card('الأيام', tableBox),
    card('تفاصيل اليوم المحدَّد', dayBox),
    formulaNote()
  );

  runBtn.addEventListener('click', load);
  await load();

  async function load() {
    if (to < from) { toast('تاريخ النهاية يسبق تاريخ البداية.', 'error'); return; }
    busy(runBtn, true);
    try {
      const [rows, rep] = await Promise.all([api.myHistory(from, to), api.report(from, to, null, null)]);
      const s = rep.summary;

      mount(sumBox,
        stat('ساعات العمل', hours(s.shift_seconds), { sub: 'ساعة', iconName: 'clock' }),
        stat('وقت النشاط', hours(s.active_seconds), { sub: 'ساعة', iconName: 'activity', accent: true, meterPct: s.avg_active_pct }),
        stat('الخمول', hours(s.idle_seconds), { sub: 'ساعة', iconName: 'pause' }),
        stat('الاستراحات', hours(s.break_seconds), { sub: 'ساعة', iconName: 'coffee' }),
        stat('متوسط النشاط', s.avg_active_pct === null ? '—' : pct(s.avg_active_pct), { iconName: 'chart' }),
        stat('أيام الحضور', number(s.present_days), { iconName: 'calendar' }),
        stat('أيام الغياب', number(s.absent_days), { iconName: 'warning' }),
        stat('مرات التأخير', number(s.late_days), { iconName: 'warning' })
      );

      mount(chartBox, barChart([...rows].reverse()));

      mount(tableBox, table(
        ['اليوم', 'البداية', 'النهاية', 'العمل', 'النشاط', 'الخمول', 'الاستراحة', 'النشاط %', 'الحالة'],
        rows,
        (r) => [
          fmtDate(r.work_date),
          el('span', { class: 'num', text: r.first_start_at ? time(r.first_start_at) : '—' }),
          el('span', { class: 'num', text: r.last_end_at ? time(r.last_end_at) : '—' }),
          duration(r.shift_seconds), duration(r.active_seconds),
          duration(r.idle_seconds), duration(r.break_seconds),
          r.active_pct === null ? '—' : pct(r.active_pct),
          r.is_absent ? el('span', { class: 'badge badge-danger plain', text: 'غياب' })
            : r.is_late ? el('span', { class: 'badge badge-warning plain', text: 'تأخير' })
            : el('span', { class: 'badge badge-success plain', text: 'حضور' })
        ],
        { empty: 'لا توجد أيام مسجَّلة في هذه الفترة.',
          onRowClick: (r) => showDay(r.work_date) }
      ));
    } catch (err) { toast(messageOf(err), 'error'); }
    finally { busy(runBtn, false); }
  }

  async function showDay(workDate) {
    try {
      const tl = await api.myTimeline(workDate);
      mount(dayBox, el('div', {}, [
        el('div', { class: 'strong mb-4', text: fmtDate(workDate) }),
        timeline(tl)
      ]));
      dayBox.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    } catch (err) { toast(messageOf(err), 'error'); }
  }
}
