/** لوحة الإدارة — المتابعة اللحظية. */
import { requireAuth } from '../auth/guard.js';
import { renderShell, setConnection, pageTitle } from '../components/shell.js';
import { api, sb } from '../services/api.js';
import { el, mount, toast, confirmDialog } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { stat, card, table, presenceBadge, formulaNote } from '../components/widgets.js';
import { duration, pct, time, hours, relative, number } from '../utils/format.js';
import { serverNow } from '../utils/time.js';
import { messageOf } from '../services/errors.js';
import { CONFIG } from '../config.js';

const auth = await requireAuth({ minRank: 50 });
if (auth) {
  pageTitle('المتابعة اللحظية');

  const refreshBtn = el('button', { class: 'icon-btn', title: 'تحديث الآن', html: icon('refresh'),
                                    onclick: () => load(true) });
  const { content } = renderShell({ title: 'المتابعة اللحظية', subtitle: 'كل رقم هنا محسوب من قاعدة البيانات لحظة الطلب', actions: [refreshBtn] });

  const liveBox   = el('div', { class: 'stat-grid' });
  const todayBox  = el('div', { class: 'stat-grid' });
  const tableBox  = el('div');
  const alertsBox = el('div');
  const updatedAt = el('span', { class: 'xsmall dim' });

  mount(content,
    el('div', {}, [el('h2', { text: 'الآن' }), el('div', { class: 'xsmall dim mb-4', text: 'حالة الموظفين في هذه اللحظة' }), liveBox]),
    alertsBox,
    el('div', {}, [el('h2', { text: 'اليوم' }), el('div', { class: 'xsmall dim mb-4', text: 'إجماليات اليوم حتى الآن' }), todayBox]),
    card('الموظفون', tableBox, [updatedAt]),
    formulaNote()
  );

  let busyLoading = false;

  async function load(manual) {
    if (busyLoading) return;
    busyLoading = true;
    if (manual) refreshBtn.classList.add('is-loading');
    try {
      const [ov, rows, multi] = await Promise.all([api.overview(), api.employeesLive(), api.multiDevice()]);
      paintOverview(ov);
      paintTable(rows);
      paintAlerts(multi);
      updatedAt.textContent = `آخر تحديث ${time(ov.server_time)}`;
      setConnection(true);
    } catch (err) {
      setConnection(false, 'تعذّر التحديث');
      toast(messageOf(err), 'error');
      if (err.isAuth) location.replace('login.html');
    } finally {
      busyLoading = false;
      refreshBtn.classList.remove('is-loading');
    }
  }

  function paintOverview(ov) {
    const l = ov.live, t = ov.today;
    mount(liveBox,
      stat('يعملون الآن', number(l.working), { iconName: 'users', accent: true, sub: `من ${number(l.total_employees)} موظفًا` }),
      stat('نشط', number(l.active), { iconName: 'activity' }),
      stat('خامل', number(l.idle), { iconName: 'pause' }),
      stat('في استراحة', number(l.on_break), { iconName: 'coffee' }),
      stat('غير متصل', number(l.disconnected), { iconName: 'warning' }),
      stat('لم يبدأ', number(l.not_started), { iconName: 'clock' })
    );
    mount(todayBox,
      stat('إجمالي ساعات العمل', hours(t.shift_seconds), { sub: 'ساعة', iconName: 'clock' }),
      stat('إجمالي وقت النشاط', hours(t.active_seconds), { sub: 'ساعة', iconName: 'activity',
           meterPct: t.avg_active_pct, accent: true }),
      stat('إجمالي الخمول', hours(t.idle_seconds), { sub: 'ساعة', iconName: 'pause' }),
      stat('متوسط النشاط', t.avg_active_pct === null ? '—' : pct(t.avg_active_pct), { iconName: 'chart' }),
      stat('عدد الشيفتات', number(t.sessions_count), { iconName: 'calendar' }),
      stat('حالات التأخير', number(t.late_count), { iconName: 'warning' }),
      stat('الغياب', number(t.absent_count), { sub: 'أيام عمل مجدولة بلا حضور', iconName: 'warning' })
    );
  }

  function paintAlerts(multi) {
    if (!multi || !multi.length) { mount(alertsBox); return; }
    mount(alertsBox, el('div', { class: 'alert alert-warning' }, [
      el('span', { html: icon('device') }),
      el('div', {}, [
        el('div', { class: 'strong', text: 'جلسات نشطة من أكثر من جهاز' }),
        el('div', { class: 'small', text: multi.map((m) => `${m.full_name} (${m.devices} أجهزة)`).join(' · ') }),
        el('div', { class: 'xsmall dim', text: 'وقت النشاط لا يتضاعف بتعدد الأجهزة — هذا تنبيه أمني للمراجعة فقط.' })
      ])
    ]));
  }

  function paintTable(rows) {
    mount(tableBox, table(
      ['الموظف', 'الحالة', 'بداية الشيفت', 'مدة الشيفت', 'وقت النشاط', 'الخمول', 'الاستراحة', 'النشاط %', 'آخر نشاط', ''],
      rows,
      (r) => [
        el('div', {}, [
          el('div', { class: 'strong', text: r.full_name }),
          el('div', { class: 'xsmall dim', text: [r.employee_code, r.team].filter(Boolean).join(' · ') || r.email })
        ]),
        presenceBadge(r.presence, r.presence_label),
        el('span', { class: 'num', text: r.started_at ? time(r.started_at) : '—' }),
        duration(r.shift_seconds),
        duration(r.active_seconds),
        duration(r.idle_seconds),
        duration(r.break_seconds),
        r.active_pct === null ? '—' : pct(r.active_pct),
        el('span', { class: 'xsmall dim', text: relative(r.last_interaction_at, serverNow()) }),
        el('div', { class: 'row' }, [
          el('a', { class: 'btn btn-sm btn-outline', href: `employee.html?id=${encodeURIComponent(r.employee_id)}`, text: 'التفاصيل' }),
          r.session_id ? el('button', {
            class: 'btn btn-sm btn-ghost', title: 'إنهاء الشيفت إداريًا', html: icon('stop'),
            onclick: async (e) => {
              e.stopPropagation();
              const reason = await confirmDialog({
                title: `إنهاء شيفت ${r.full_name}`,
                message: 'ستُنهى جلسة العمل المفتوحة، وتُسجَّل العملية في سجل التدقيق باسمك.',
                confirmText: 'إنهاء الشيفت', danger: true, requireReason: true
              });
              if (!reason) return;
              try {
                const res = await api.forceEndShift(r.employee_id, reason);
                toast(res.message, 'success');
                load(true);
              } catch (err) { toast(messageOf(err), 'error'); }
            }
          }) : null
        ])
      ],
      { empty: 'لا يوجد موظفون مسجَّلون بعد. أضِف أول موظف من صفحة "الموظفون".' }
    ));
  }

  await load();

  /* ── التحديث اللحظي: بث من قاعدة البيانات + تحديث دوري كشبكة أمان ── */
  let debounce = null;
  const bump = () => { clearTimeout(debounce); debounce = setTimeout(() => load(), 1200); };

  try {
    sb.channel('eo-live')
      .on('postgres_changes', { event: '*', schema: 'emp_ops', table: 'employee_runtime_state' }, bump)
      .on('postgres_changes', { event: '*', schema: 'emp_ops', table: 'attendance_sessions' }, bump)
      .on('postgres_changes', { event: '*', schema: 'emp_ops', table: 'break_sessions' }, bump)
      .subscribe();
  } catch { /* البث اختياري — التحديث الدوري يغطّي الحالة */ }

  setInterval(() => { if (document.visibilityState === 'visible') load(); }, CONFIG.ADMIN_REFRESH_SECONDS * 1000);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') load(); });
}
