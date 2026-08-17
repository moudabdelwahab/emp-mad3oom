/** سجل التدقيق. */
import { requireAuth } from '../auth/guard.js';
import { renderShell, pageTitle } from '../components/shell.js';
import { api } from '../services/api.js';
import { el, mount, toast, busy } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { card, table } from '../components/widgets.js';
import { dateTime } from '../utils/format.js';
import { serverNow, dateKey, addDays } from '../utils/time.js';
import { messageOf } from '../services/errors.js';

const auth = await requireAuth({ minRank: 50 });
if (auth) {
  pageTitle('سجل التدقيق');

  const tz = auth.me.settings.timezone;
  const today = dateKey(serverNow(), tz);
  let filters = { from: addDays(today, -6), to: today, action: '', employeeId: '', offset: 0, limit: 100 };
  let lists = { audit_actions: [], employees: [] };

  const fromInput   = el('input', { type: 'date', value: filters.from, onchange: (e) => filters.from = e.target.value });
  const toInput     = el('input', { type: 'date', value: filters.to,   onchange: (e) => filters.to = e.target.value });
  const actSelect   = el('select', { onchange: (e) => filters.action = e.target.value });
  const empSelect   = el('select', { onchange: (e) => filters.employeeId = e.target.value });
  const runBtn      = el('button', { class: 'btn btn-primary', text: 'عرض' });
  const moreBtn     = el('button', { class: 'btn btn-outline btn-block mt-4', text: 'تحميل المزيد' });

  const { content } = renderShell({ title: 'سجل التدقيق', subtitle: 'سجل غير قابل للتعديل أو الحذف' });
  const box = el('div');

  mount(content,
    el('div', { class: 'alert alert-info' }, [
      el('span', { html: icon('shield') }),
      el('div', {}, [
        el('div', { class: 'strong', text: 'هذا السجل محمي على مستوى قاعدة البيانات' }),
        el('div', { class: 'small', text: 'لا يملك أي مستخدم — بما في ذلك المدير العام — صلاحية تعديل أو حذف أي سطر منه. المحاولة تُرفض من الخادم.' })
      ])
    ]),
    el('div', { class: 'filters' }, [
      el('div', { class: 'field' }, [el('label', { text: 'من' }), fromInput]),
      el('div', { class: 'field' }, [el('label', { text: 'إلى' }), toInput]),
      el('div', { class: 'field' }, [el('label', { text: 'نوع العملية' }), actSelect]),
      el('div', { class: 'field' }, [el('label', { text: 'المنفِّذ' }), empSelect]),
      el('div', { class: 'row' }, [runBtn])
    ]),
    card('العمليات', el('div', {}, [box, moreBtn]))
  );

  runBtn.addEventListener('click', () => { filters.offset = 0; load(false); });
  moreBtn.addEventListener('click', () => { filters.offset += filters.limit; load(true); });

  try {
    lists = await api.lists();
    mount(actSelect, el('option', { value: '', text: 'كل العمليات' }),
      ...lists.audit_actions.map((a) => el('option', { value: a.code, text: a.name_ar })));
    mount(empSelect, el('option', { value: '', text: 'الجميع' }),
      ...lists.employees.map((e) => el('option', { value: e.id, text: e.full_name })));
  } catch (err) { toast(messageOf(err), 'error'); }

  let rows = [];
  await load(false);

  async function load(append) {
    busy(runBtn, true);
    try {
      const page = await api.auditLogs({
        from: filters.from + 'T00:00:00Z',
        to: filters.to + 'T23:59:59Z',
        action: filters.action || null,
        employeeId: filters.employeeId || null,
        limit: filters.limit, offset: filters.offset
      });
      rows = append ? rows.concat(page) : page;
      moreBtn.classList.toggle('hidden', page.length < filters.limit);

      mount(box, table(
        ['الوقت', 'المنفِّذ', 'العملية', 'الهدف', 'التفاصيل'],
        rows,
        (r) => [
          el('span', { class: 'num xsmall', text: dateTime(r.occurred_at) }),
          el('div', {}, [
            el('div', { text: r.actor_name || 'النظام' }),
            el('div', { class: 'xsmall dim', text: r.actor_role || 'مهمة تلقائية' })
          ]),
          el('span', { class: `badge plain ${severityClass(r.severity)}`, text: r.action_label }),
          el('div', {}, [
            el('div', { class: 'small', text: r.target_label || '—' }),
            el('div', { class: 'xsmall dim mono', text: r.target_type || '' })
          ]),
          el('span', { class: 'xsmall dim', text: describe(r.metadata) })
        ],
        { empty: 'لا توجد عمليات في هذه الفترة.' }
      ));
    } catch (err) { toast(messageOf(err), 'error'); }
    finally { busy(runBtn, false); }
  }

  function severityClass(s) {
    return s === 'critical' ? 'badge-danger' : s === 'warning' ? 'badge-warning'
         : s === 'notice' ? 'badge-info' : 'badge-ended';
  }

  function describe(meta) {
    if (!meta || typeof meta !== 'object') return '';
    const bits = [];
    if (meta.reason) bits.push(`السبب: ${meta.reason}`);
    if (meta.from && meta.to) bits.push(`${JSON.stringify(meta.from)} ← ${JSON.stringify(meta.to)}`);
    if (meta.duration_seconds) bits.push(`المدة: ${Math.round(meta.duration_seconds / 60)} دقيقة`);
    if (meta.late_seconds) bits.push(`تأخير: ${Math.round(meta.late_seconds / 60)} دقيقة`);
    if (meta.auto_linked) bits.push('ربط تلقائي بالحساب');
    if (!bits.length) {
      const keys = Object.keys(meta).slice(0, 3);
      return keys.map((k) => `${k}: ${JSON.stringify(meta[k])}`).join(' · ');
    }
    return bits.join(' · ');
  }
}
