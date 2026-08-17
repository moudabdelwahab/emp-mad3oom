/** التقارير. */
import { requireAuth } from '../auth/guard.js';
import { renderShell, pageTitle } from '../components/shell.js';
import { api } from '../services/api.js';
import { el, mount, toast, busy } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { stat, card, table, barChart, formulaNote } from '../components/widgets.js';
import { duration, pct, hours, number, date as fmtDate } from '../utils/format.js';
import { serverNow, dateKey, addDays, startOfWeek, startOfMonth } from '../utils/time.js';
import { messageOf } from '../services/errors.js';

const auth = await requireAuth({ minRank: 50 });
if (auth) {
  pageTitle('التقارير');

  const tz = auth.me.settings.timezone;
  const today = dateKey(serverNow(), tz);

  let from = startOfWeek(today), to = today, employeeId = '', teamId = '';
  let lists = { employees: [], teams: [] };
  let lastReport = null;

  const fromInput = el('input', { type: 'date', value: from, onchange: (e) => { from = e.target.value; setChip(null); } });
  const toInput   = el('input', { type: 'date', value: to,   onchange: (e) => { to = e.target.value; setChip(null); } });
  const empSelect = el('select', { onchange: (e) => { employeeId = e.target.value; } });
  const teamSelect= el('select', { onchange: (e) => { teamId = e.target.value; } });
  const runBtn    = el('button', { class: 'btn btn-primary', text: 'عرض التقرير' });
  const csvBtn    = el('button', { class: 'btn btn-outline' }, [el('span', { html: icon('download') }), 'تصدير CSV']);

  const chips = [
    { id: 'today', label: 'اليوم',       range: () => [today, today] },
    { id: 'yday',  label: 'أمس',         range: () => [addDays(today, -1), addDays(today, -1)] },
    { id: 'week',  label: 'هذا الأسبوع', range: () => [startOfWeek(today), today] },
    { id: 'month', label: 'هذا الشهر',   range: () => [startOfMonth(today), today] },
    { id: 'd30',   label: 'آخر ٣٠ يومًا', range: () => [addDays(today, -29), today] }
  ];
  const chipEls = chips.map((c) => el('button', { class: 'chip', text: c.label, dataset: { id: c.id },
    onclick: () => { const [f, t] = c.range(); from = f; to = t; fromInput.value = f; toInput.value = t; setChip(c.id); run(); } }));
  function setChip(id) { chipEls.forEach((e) => e.classList.toggle('active', e.dataset.id === id)); }

  const { content } = renderShell({ title: 'التقارير', subtitle: 'محسوبة من الجداول الخام مباشرة' });

  const summaryBox = el('div', { class: 'stat-grid' });
  const chartBox   = el('div');
  const tableBox   = el('div');
  const metaBox    = el('div', { class: 'xsmall dim' });

  mount(content,
    el('div', { class: 'filters' }, [
      el('div', { class: 'chips', style: 'flex-basis:100%' }, chipEls),
      el('div', { class: 'field' }, [el('label', { text: 'من' }), fromInput]),
      el('div', { class: 'field' }, [el('label', { text: 'إلى' }), toInput]),
      el('div', { class: 'field' }, [el('label', { text: 'الموظف' }), empSelect]),
      el('div', { class: 'field' }, [el('label', { text: 'الفريق' }), teamSelect]),
      el('div', { class: 'row' }, [runBtn, csvBtn])
    ]),
    summaryBox,
    card('التوزيع اليومي', chartBox),
    card('التفصيل حسب الموظف', tableBox, [metaBox]),
    formulaNote()
  );

  runBtn.addEventListener('click', () => run());
  csvBtn.addEventListener('click', exportCsv);

  try {
    lists = await api.lists();
    mount(empSelect, el('option', { value: '', text: 'كل الموظفين' }),
      ...lists.employees.map((e) => el('option', { value: e.id, text: e.full_name })));
    mount(teamSelect, el('option', { value: '', text: 'كل الفرق' }),
      ...lists.teams.map((t) => el('option', { value: t.id, text: t.name_ar })));
  } catch (err) { toast(messageOf(err), 'error'); }

  setChip('week');
  await run();

  async function run() {
    if (to < from) { toast('تاريخ النهاية يسبق تاريخ البداية.', 'error'); return; }
    busy(runBtn, true);
    try {
      const rep = await api.report(from, to, employeeId || null, teamId || null);
      lastReport = rep;
      const s = rep.summary;

      mount(summaryBox,
        stat('إجمالي ساعات العمل', hours(s.shift_seconds), { sub: 'ساعة', iconName: 'clock' }),
        stat('إجمالي وقت النشاط', hours(s.active_seconds), { sub: 'ساعة', iconName: 'activity', accent: true, meterPct: s.avg_active_pct }),
        stat('إجمالي الخمول', hours(s.idle_seconds), { sub: 'ساعة', iconName: 'pause' }),
        stat('إجمالي الاستراحات', hours(s.break_seconds), { sub: 'ساعة', iconName: 'coffee' }),
        stat('متوسط النشاط', s.avg_active_pct === null ? '—' : pct(s.avg_active_pct), { iconName: 'chart' }),
        stat('أيام الحضور', number(s.present_days), { iconName: 'calendar' }),
        stat('أيام الغياب', number(s.absent_days), { iconName: 'warning' }),
        stat('مرات التأخير', number(s.late_days), { iconName: 'warning' })
      );

      mount(chartBox, barChart(rep.daily));

      mount(tableBox, table(
        ['الموظف', 'الفريق', 'ساعات العمل', 'النشاط', 'الخمول', 'الاستراحة', 'النشاط %', 'حضور', 'غياب', 'تأخير'],
        rep.employees,
        (r) => [
          el('div', {}, [
            el('div', { class: 'strong', text: r.full_name }),
            r.employee_code ? el('div', { class: 'xsmall dim', text: r.employee_code }) : null
          ]),
          r.team || '—',
          duration(r.shift_seconds),
          duration(r.active_seconds),
          duration(r.idle_seconds),
          duration(r.break_seconds),
          r.active_pct === null ? '—' : pct(r.active_pct),
          number(r.present_days),
          number(r.absent_days),
          number(r.late_days)
        ],
        { empty: 'لا توجد بيانات في هذه الفترة.' }
      ));

      metaBox.textContent = `${fmtDate(rep.from)} – ${fmtDate(rep.to)} · ${number(s.employees)} موظفًا · بتوقيت ${rep.timezone}`;
    } catch (err) {
      toast(messageOf(err), 'error');
    } finally { busy(runBtn, false); }
  }

  async function exportCsv() {
    if (!lastReport || !lastReport.employees.length) { toast('لا توجد بيانات للتصدير.', 'error'); return; }
    const head = ['الموظف', 'الكود', 'الفريق', 'ساعات العمل', 'ساعات النشاط', 'ساعات الخمول', 'ساعات الاستراحة',
                  'نسبة النشاط', 'أيام الحضور', 'أيام الغياب', 'مرات التأخير'];
    const rows = lastReport.employees.map((r) => [
      r.full_name, r.employee_code || '', r.team || '',
      hours(r.shift_seconds), hours(r.active_seconds), hours(r.idle_seconds), hours(r.break_seconds),
      r.active_pct === null ? '' : Number(r.active_pct).toFixed(1),
      r.present_days, r.absent_days, r.late_days
    ]);
    const esc = (v) => `"${String(v).replace(/"/g, '""')}"`;
    const csv = '﻿' + [head, ...rows].map((r) => r.map(esc).join(',')).join('\r\n');

    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = el('a', { href: url, download: `تقرير-${lastReport.from}_${lastReport.to}.csv` });
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);

    try { await api.logExport('report_csv', { from: lastReport.from, to: lastReport.to, rows: rows.length }); }
    catch { /* التصدير تم؛ فشل التدقيق لا يمنع المستخدم */ }
    toast('تم تصدير التقرير وتسجيل العملية في سجل التدقيق.', 'success');
  }
}
