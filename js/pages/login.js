/** صفحة تسجيل الدخول. */
import { sb } from '../services/client.js';
import { signIn, sendReset } from '../auth/auth.js';
import { el, $, mount, toast, busy } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { messageOf } from '../services/errors.js';
import * as theme from '../utils/theme.js';
import { CONFIG } from '../config.js';

theme.init();

const params = new URLSearchParams(location.search);
const next = params.get('next');

// جلسة قائمة بالفعل ⇒ ادخل مباشرة
const { data: existing } = await sb.auth.getSession();
if (existing.session) location.replace(safeNext(next));

function safeNext(v) {
  if (!v) return 'dashboard.html';
  // نسمح فقط بمسارات داخلية — لا إعادة توجيه إلى نطاق خارجي
  if (/^[a-z0-9._-]+\.html(\?[^#]*)?$/i.test(v)) return v;
  return 'dashboard.html';
}

const errorBox = el('div', { class: 'alert alert-error hidden', role: 'alert' });
const emailInput = el('input', { type: 'email', id: 'email', required: true, autocomplete: 'username', placeholder: 'name@mad3oom.com' });
const passInput  = el('input', { type: 'password', id: 'password', required: true, autocomplete: 'current-password', placeholder: '••••••••' });
const submitBtn  = el('button', { class: 'btn btn-primary btn-block btn-lg', type: 'submit', text: 'تسجيل الدخول' });

function showError(msg) {
  errorBox.textContent = msg;
  errorBox.classList.remove('hidden');
}

const form = el('form', { novalidate: true, onsubmit: async (e) => {
  e.preventDefault();
  errorBox.classList.add('hidden');

  const email = emailInput.value.trim();
  const password = passInput.value;
  if (!email) { showError('أدخل البريد الإلكتروني.'); emailInput.focus(); return; }
  if (!password) { showError('أدخل كلمة المرور.'); passInput.focus(); return; }

  busy(submitBtn, true);
  try {
    await signIn(email, password);
    location.replace(safeNext(next));
  } catch (err) {
    showError(messageOf(err));
    passInput.value = '';
    passInput.focus();
  } finally {
    busy(submitBtn, false);
  }
}}, [
  errorBox,
  el('div', { class: 'field' }, [el('label', { for: 'email', text: 'البريد الإلكتروني' }), emailInput]),
  el('div', { class: 'field' }, [el('label', { for: 'password', text: 'كلمة المرور' }), passInput]),
  submitBtn
]);

const resetLink = el('button', {
  class: 'btn btn-ghost btn-sm btn-block mt-4', type: 'button', text: 'نسيت كلمة المرور؟',
  onclick: async (e) => {
    const email = emailInput.value.trim();
    if (!email) { showError('اكتب بريدك الإلكتروني أولًا ثم اضغط على الرابط.'); emailInput.focus(); return; }
    busy(e.currentTarget, true);
    try {
      await sendReset(email);
      toast('أُرسل رابط إعادة التعيين إلى بريدك.', 'success');
    } catch (err) {
      showError(messageOf(err));
    } finally { busy(e.currentTarget, false); }
  }
});

mount(document.body, el('div', { class: 'auth-page' }, [
  el('div', { class: 'auth-card' }, [
    el('div', { class: 'auth-brand' }, [
      el('div', { class: 'brand-mark', html: icon('logo') }),
      el('div', {}, [
        el('h2', { text: 'عمليات الموظفين' }),
        el('div', { class: 'small muted', text: 'نظام الحضور والنشاط — منصة مدعوم' })
      ])
    ]),
    form,
    resetLink,
    el('div', { class: 'center xsmall dim mt-6', text: 'الدخول متاح لموظفي مدعوم المسجَّلين فقط.' })
  ])
]), el('div', { id: 'toasts' }));

document.title = `تسجيل الدخول · ${CONFIG.APP_NAME}`;
emailInput.focus();
