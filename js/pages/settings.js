/** إعدادات النظام — كلها مخزَّنة في قاعدة البيانات، لا شيء مثبَّت في الكود. */
import { requireAuth } from '../auth/guard.js';
import { renderShell, pageTitle } from '../components/shell.js';
import { api } from '../services/api.js';
import { el, mount, toast, busy } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { card } from '../components/widgets.js';
import { messageOf } from '../services/errors.js';

const auth = await requireAuth({ minRank: 100 });
if (auth) {
  pageTitle('الإعدادات');
  const { content } = renderShell({ title: 'إعدادات النظام', subtitle: 'تُطبَّق فورًا على كل الموظفين' });

  const box = el('div');
  mount(content,
    el('div', { class: 'alert alert-warning' }, [
      el('span', { html: icon('warning') }),
      el('div', {}, [
        el('div', { class: 'strong', text: 'تغيير هذه القيم يؤثر على احتساب النشاط لكل الموظفين' }),
        el('div', { class: 'small', text: 'كل تعديل يُسجَّل في سجل التدقيق باسمك مع القيمة القديمة والجديدة.' })
      ])
    ]),
    card('الإعدادات', box)
  );

  await load();

  async function load() {
    try {
      const rows = await api.settings();
      mount(box, el('div', {}, rows.map(renderSetting)));
    } catch (err) { toast(messageOf(err), 'error'); }
  }

  function renderSetting(s) {
    const isNum  = s.value_type === 'number';
    const isJson = s.value_type === 'json';
    const raw    = isJson ? JSON.stringify(s.value) : String(s.value).replace(/^"|"$/g, '');

    const input = el('input', {
      type: isNum ? 'number' : 'text', value: raw,
      min: s.min_value ?? undefined, max: s.max_value ?? undefined
    });

    const saveBtn = el('button', { class: 'btn btn-sm btn-primary', text: 'حفظ', onclick: async () => {
      busy(saveBtn, true);
      try {
        let value;
        if (isNum) value = JSON.parse(String(Number(input.value)));
        else if (isJson) value = JSON.parse(input.value);
        else value = input.value;
        const res = await api.setSetting(s.key, isNum || isJson ? value : String(value));
        toast(res.message, 'success');
        await load();
      } catch (err) {
        toast(err instanceof SyntaxError ? 'صيغة القيمة غير صحيحة.' : messageOf(err), 'error');
      } finally { busy(saveBtn, false); }
    }});

    const range = (s.min_value !== null && s.min_value !== undefined)
      ? `المدى المسموح: ${s.min_value} – ${s.max_value}` : '';

    return el('div', { class: 'field' }, [
      el('label', { text: s.description_ar }),
      el('div', { class: 'row' }, [input, saveBtn]),
      el('div', { class: 'hint' }, [
        el('span', { class: 'mono xsmall', text: s.key }),
        range ? el('span', { text: ` · ${range}` }) : null
      ])
    ]);
  }
}
