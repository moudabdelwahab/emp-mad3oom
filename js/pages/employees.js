/** إدارة الموظفين والفرق والشيفتات. */
import { requireAuth, isAdmin } from '../auth/guard.js';
import { renderShell, pageTitle } from '../components/shell.js';
import { api } from '../services/api.js';
import { el, mount, toast, formDialog, confirmDialog } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { card, table } from '../components/widgets.js';
import { ROLE_LABEL, STATUS_LABEL, date as fmtDate } from '../utils/format.js';
import { dateKey } from '../utils/time.js';
import { serverNow } from '../utils/time.js';
import { messageOf } from '../services/errors.js';

const auth = await requireAuth({ minRank: 50 });
if (auth) {
  pageTitle('الموظفون');

  const addBtn = el('button', { class: 'btn btn-primary btn-sm' }, [el('span', { html: icon('plus') }), 'موظف جديد']);
  const { content } = renderShell({ title: 'الموظفون', subtitle: 'الإضافة والأدوار والشيفتات', actions: isAdmin() ? [addBtn] : [] });

  const empBox   = el('div');
  const teamBox  = el('div');
  const shiftBox = el('div');
  let lists = { roles: [], teams: [], shifts: [] };

  mount(content,
    card('قائمة الموظفين', empBox),
    card('الفرق', teamBox, [el('button', { class: 'btn btn-sm btn-outline', text: 'إضافة فريق', onclick: upsertTeam })]),
    card('قوالب الشيفتات', shiftBox, [el('button', { class: 'btn btn-sm btn-outline', text: 'إضافة شيفت', onclick: () => upsertShift() })])
  );

  addBtn.addEventListener('click', () => upsertEmployee());

  await load();

  async function load() {
    try {
      const [rows, l] = await Promise.all([api.listEmployees(), api.lists()]);
      lists = l;

      mount(empBox, table(
        ['الموظف', 'الدور', 'الحالة', 'الفريق', 'الشيفت', 'الحساب', 'التعيين', ''],
        rows,
        (r) => [
          el('div', {}, [
            el('div', { class: 'strong', text: r.full_name }),
            el('div', { class: 'xsmall dim', text: [r.email, r.employee_code].filter(Boolean).join(' · ') })
          ]),
          r.role_label || ROLE_LABEL[r.role] || r.role,
          el('span', { class: `badge plain ${r.status === 'active' ? 'badge-success' : r.status === 'suspended' ? 'badge-warning' : 'badge-ended'}`,
                       text: STATUS_LABEL[r.status] || r.status }),
          r.team || '—',
          r.shift_name || '—',
          r.linked
            ? el('span', { class: 'badge plain badge-success', text: 'مرتبط' })
            : el('span', { class: 'badge plain badge-warning', text: 'بانتظار التسجيل' }),
          r.hired_at ? fmtDate(r.hired_at) : '—',
          el('div', { class: 'row' }, [
            el('a', { class: 'btn btn-sm btn-outline', href: `employee.html?id=${encodeURIComponent(r.id)}`, text: 'الملف' }),
            isAdmin() ? el('button', { class: 'btn btn-sm btn-ghost', text: 'تعديل', onclick: () => upsertEmployee(r) }) : null,
            isAdmin() ? el('button', { class: 'btn btn-sm btn-ghost', text: 'الدور', onclick: () => changeRole(r) }) : null,
            isAdmin() ? el('button', { class: 'btn btn-sm btn-ghost', text: 'الحالة', onclick: () => changeStatus(r) }) : null,
            el('button', { class: 'btn btn-sm btn-ghost', text: 'الشيفت', onclick: () => assignShift(r) })
          ])
        ],
        { empty: 'لا يوجد موظفون بعد. ابدأ بإضافة أول موظف.' }
      ));

      mount(teamBox, table(['الفريق', 'الحالة', ''], lists.teams, (t) => [
        t.name_ar,
        t.is_active ? 'نشط' : 'معطّل',
        el('button', { class: 'btn btn-sm btn-ghost', text: 'تعديل', onclick: () => upsertTeam(t) })
      ], { empty: 'لا توجد فرق بعد.' }));

      mount(shiftBox, table(['الشيفت', 'من', 'إلى', 'أيام العمل', 'سماح التأخير', 'الحالة', ''], lists.shifts, (s) => [
        s.name_ar,
        el('span', { class: 'num', text: String(s.start_time).slice(0, 5) }),
        el('span', { class: 'num', text: String(s.end_time).slice(0, 5) }),
        (s.work_days || []).map((d) => ['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'][d]).join('، '),
        `${s.grace_minutes} دقيقة`,
        s.is_active ? 'نشط' : 'معطّل',
        el('button', { class: 'btn btn-sm btn-ghost', text: 'تعديل', onclick: () => upsertShift(s) })
      ], { empty: 'لا توجد قوالب شيفتات بعد.' }));
    } catch (err) { toast(messageOf(err), 'error'); }
  }

  async function upsertEmployee(row) {
    const out = await formDialog({
      title: row ? `تعديل ${row.full_name}` : 'إضافة موظف',
      submitText: 'حفظ',
      fields: [
        { name: 'full_name', label: 'الاسم الكامل', required: true, value: row?.full_name },
        { name: 'email', label: 'البريد الإلكتروني', type: 'email', required: true, value: row?.email,
          hint: 'يُربط الموظف تلقائيًا بحسابه في مدعوم عند أول تسجيل دخول بهذا البريد.' },
        { name: 'employee_code', label: 'الكود الوظيفي', value: row?.employee_code },
        { name: 'phone', label: 'الهاتف', value: row?.phone },
        { name: 'team_id', label: 'الفريق', type: 'select', value: row?.team_id || '',
          options: [{ value: '', label: 'بدون فريق' }, ...lists.teams.map((t) => ({ value: t.id, label: t.name_ar }))] },
        { name: 'role', label: 'الدور', type: 'select', value: row?.role || 'employee',
          options: lists.roles.map((r) => ({ value: r.code, label: r.name_ar })) },
        { name: 'timezone', label: 'المنطقة الزمنية', value: row?.timezone || 'Africa/Cairo' },
        { name: 'hired_at', label: 'تاريخ التعيين', type: 'date', value: row?.hired_at || '' }
      ]
    });
    if (!out) return;
    try {
      const res = await api.upsertEmployee({ ...out, id: row?.id || '' });
      toast(res.message, 'success');
      // الدور لا يتغيّر من نموذج التعديل — له مسار مُدقَّق منفصل
      if (!row && out.role && out.role !== 'employee') await api.setRole(res.id, out.role);
      await load();
    } catch (err) { toast(messageOf(err), 'error'); }
  }

  async function changeRole(row) {
    const out = await formDialog({
      title: `دور ${row.full_name}`,
      submitText: 'تغيير الدور',
      fields: [{ name: 'role', label: 'الدور الجديد', type: 'select', value: row.role,
                 options: lists.roles.map((r) => ({ value: r.code, label: r.name_ar })),
                 hint: 'تغيير الدور عملية حساسة تُسجَّل في سجل التدقيق.' }]
    });
    if (!out || out.role === row.role) return;
    try { toast((await api.setRole(row.id, out.role)).message, 'success'); await load(); }
    catch (err) { toast(messageOf(err), 'error'); }
  }

  async function changeStatus(row) {
    const out = await formDialog({
      title: `حالة ${row.full_name}`,
      submitText: 'حفظ',
      fields: [
        { name: 'status', label: 'الحالة', type: 'select', value: row.status,
          options: [{ value: 'active', label: 'نشط' }, { value: 'suspended', label: 'موقوف' }, { value: 'archived', label: 'مؤرشف' }] },
        { name: 'reason', label: 'السبب', type: 'textarea',
          hint: 'الموظف الموقوف يُمنع من كل العمليات فورًا على مستوى قاعدة البيانات.' }
      ]
    });
    if (!out) return;
    try { toast((await api.setStatus(row.id, out.status, out.reason)).message, 'success'); await load(); }
    catch (err) { toast(messageOf(err), 'error'); }
  }

  async function assignShift(row) {
    if (!lists.shifts.length) { toast('أضِف قالب شيفت أولًا.', 'error'); return; }
    const out = await formDialog({
      title: `إسناد شيفت لـ ${row.full_name}`,
      submitText: 'إسناد',
      fields: [
        { name: 'shift_id', label: 'الشيفت', type: 'select',
          options: lists.shifts.filter((s) => s.is_active).map((s) => ({ value: s.id, label: s.name_ar })) },
        { name: 'from', label: 'يبدأ من', type: 'date', required: true, value: dateKey(serverNow(), auth.me.settings.timezone) },
        { name: 'to', label: 'ينتهي في (اختياري)', type: 'date' }
      ]
    });
    if (!out) return;
    try { toast((await api.assignShift(row.id, out.shift_id, out.from, out.to || null)).message, 'success'); await load(); }
    catch (err) { toast(messageOf(err), 'error'); }
  }

  async function upsertTeam(row) {
    const out = await formDialog({
      title: row ? 'تعديل فريق' : 'فريق جديد',
      fields: [
        { name: 'name_ar', label: 'اسم الفريق', required: true, value: row?.name_ar },
        { name: 'description_ar', label: 'الوصف', type: 'textarea', value: row?.description_ar }
      ]
    });
    if (!out) return;
    try { toast((await api.upsertTeam({ ...out, id: row?.id || '' })).message, 'success'); await load(); }
    catch (err) { toast(messageOf(err), 'error'); }
  }

  async function upsertShift(row) {
    const out = await formDialog({
      title: row ? 'تعديل شيفت' : 'شيفت جديد',
      fields: [
        { name: 'name_ar', label: 'اسم الشيفت', required: true, value: row?.name_ar },
        { name: 'start_time', label: 'يبدأ', type: 'time', required: true, value: row ? String(row.start_time).slice(0, 5) : '09:00' },
        { name: 'end_time', label: 'ينتهي', type: 'time', required: true, value: row ? String(row.end_time).slice(0, 5) : '17:00' },
        { name: 'work_days', label: 'أيام العمل', value: (row?.work_days || [0, 1, 2, 3, 4]).join(','),
          hint: '0=الأحد، 1=الاثنين … 6=السبت — افصل بينها بفاصلة.' },
        { name: 'grace_minutes', label: 'دقائق السماح', type: 'number', value: row?.grace_minutes ?? 10 }
      ]
    });
    if (!out) return;
    const days = out.work_days.split(',').map((d) => parseInt(d.trim(), 10)).filter((d) => d >= 0 && d <= 6);
    if (!days.length) { toast('حدّد يوم عمل واحدًا على الأقل.', 'error'); return; }
    try {
      toast((await api.upsertShift({
        id: row?.id || '', name_ar: out.name_ar, start_time: out.start_time, end_time: out.end_time,
        work_days: days, grace_minutes: Number(out.grace_minutes) || 0
      })).message, 'success');
      await load();
    } catch (err) { toast(messageOf(err), 'error'); }
  }
}
