/** أدوات DOM صغيرة — بدون أي مكتبة خارجية. */

export const $  = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

/** إنشاء عنصر. النصوص تُمرَّر كـ textContent دائمًا ⇒ لا مجال لـ XSS. */
export function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k === 'html') node.innerHTML = v;              // للأيقونات SVG الداخلية فقط
    else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
    else if (k === 'dataset') Object.assign(node.dataset, v);
    else node.setAttribute(k, v === true ? '' : v);
  }
  for (const c of [].concat(children)) {
    if (c === null || c === undefined || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}

export function clear(node) { while (node && node.firstChild) node.removeChild(node.firstChild); }

export function mount(target, ...nodes) {
  const t = typeof target === 'string' ? $(target) : target;
  if (!t) return null;
  clear(t);
  t.append(...nodes.filter(Boolean));
  return t;
}

/** إشعار عابر. */
export function toast(message, kind = '') {
  let box = $('#toasts');
  if (!box) { box = el('div', { id: 'toasts' }); document.body.append(box); }
  const t = el('div', { class: `toast ${kind}`, text: message, role: 'status' });
  box.append(t);
  setTimeout(() => { t.style.opacity = '0'; setTimeout(() => t.remove(), 250); }, kind === 'error' ? 6000 : 3500);
}

/** نافذة تأكيد عربية (تعوّض confirm الافتراضي غير القابل للتنسيق). */
export function confirmDialog({ title, message, confirmText = 'تأكيد', cancelText = 'إلغاء', danger = false, requireReason = false }) {
  return new Promise((resolve) => {
    const input = requireReason
      ? el('div', { class: 'field' }, [el('label', { text: 'السبب (إلزامي)' }), el('input', { type: 'text', id: '_reason' })])
      : null;
    const backdrop = el('div', { class: 'modal-backdrop' });
    const close = (v) => { backdrop.remove(); document.removeEventListener('keydown', onKey); resolve(v); };
    const onKey = (e) => { if (e.key === 'Escape') close(null); };

    const okBtn = el('button', {
      class: `btn ${danger ? 'btn-danger' : 'btn-primary'}`, text: confirmText,
      onclick: () => {
        if (requireReason) {
          const val = input.querySelector('#_reason').value.trim();
          if (!val) { toast('السبب مطلوب.', 'error'); return; }
          close(val);
        } else close(true);
      }
    });

    backdrop.append(el('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true' }, [
      el('div', { class: 'modal-head' }, [el('h3', { text: title })]),
      el('div', { class: 'modal-body' }, [el('p', { text: message, class: 'muted' }), input]),
      el('div', { class: 'modal-foot' }, [okBtn, el('button', { class: 'btn btn-outline', text: cancelText, onclick: () => close(null) })])
    ]));
    backdrop.addEventListener('click', (e) => { if (e.target === backdrop) close(null); });
    document.addEventListener('keydown', onKey);
    document.body.append(backdrop);
    (input ? input.querySelector('#_reason') : okBtn).focus();
  });
}

/** نافذة نموذج عامة. تُعيد قيم الحقول أو null. */
export function formDialog({ title, fields, submitText = 'حفظ' }) {
  return new Promise((resolve) => {
    const backdrop = el('div', { class: 'modal-backdrop' });
    const close = (v) => { backdrop.remove(); document.removeEventListener('keydown', onKey); resolve(v); };
    const onKey = (e) => { if (e.key === 'Escape') close(null); };
    const inputs = {};

    const body = el('div', { class: 'modal-body' }, fields.map((f) => {
      let control;
      if (f.type === 'select') {
        control = el('select', { id: `f_${f.name}` },
          (f.options || []).map((o) => el('option', { value: o.value, text: o.label, selected: String(o.value) === String(f.value ?? '') })));
      } else if (f.type === 'textarea') {
        control = el('textarea', { id: `f_${f.name}`, placeholder: f.placeholder || '' });
        control.value = f.value ?? '';
      } else {
        control = el('input', { type: f.type || 'text', id: `f_${f.name}`, placeholder: f.placeholder || '', step: f.step, min: f.min, max: f.max });
        control.value = f.value ?? '';
      }
      inputs[f.name] = control;
      return el('div', { class: 'field' }, [
        el('label', { for: `f_${f.name}`, text: f.label + (f.required ? ' *' : '') }),
        control,
        f.hint ? el('div', { class: 'hint', text: f.hint }) : null
      ]);
    }));

    const submit = () => {
      const out = {};
      for (const f of fields) {
        const v = inputs[f.name].value.trim();
        if (f.required && !v) { toast(`الحقل "${f.label}" مطلوب.`, 'error'); inputs[f.name].focus(); return; }
        out[f.name] = v;
      }
      close(out);
    };

    backdrop.append(el('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true' }, [
      el('div', { class: 'modal-head' }, [el('h3', { text: title })]),
      body,
      el('div', { class: 'modal-foot' }, [
        el('button', { class: 'btn btn-primary', text: submitText, onclick: submit }),
        el('button', { class: 'btn btn-outline', text: 'إلغاء', onclick: () => close(null) })
      ])
    ]));
    backdrop.addEventListener('click', (e) => { if (e.target === backdrop) close(null); });
    document.addEventListener('keydown', onKey);
    document.body.append(backdrop);
    Object.values(inputs)[0]?.focus();
  });
}

/** حالة تحميل على زر. */
export function busy(button, on = true) {
  if (!button) return;
  button.classList.toggle('is-loading', on);
  button.disabled = on;
}

export function emptyState(message, icon) {
  return el('div', { class: 'empty' }, [
    icon ? el('div', { html: icon }) : null,
    el('div', { text: message })
  ]);
}
