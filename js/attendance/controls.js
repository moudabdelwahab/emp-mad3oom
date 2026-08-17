/** لوحة الشيفت: الحالة اللحظية وأزرار العمل والاستراحة. */
import { el, busy, toast, confirmDialog } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { api } from '../services/api.js';
import { messageOf } from '../services/errors.js';
import { clock, duration, time, PRESENCE_LABEL, BREAK_LABEL } from '../utils/format.js';
import { secondsSince } from '../utils/time.js';

export function createShiftPanel({ onChange }) {
  const badge      = el('span', { class: 'badge', text: '—' });
  const clockEl    = el('div', { class: 'clock num', text: '00:00:00' });
  const clockLabel = el('div', { class: 'small muted', text: 'مدة الشيفت' });
  const meta       = el('div', { class: 'small muted' });
  const note       = el('div', { class: 'xsmall dim' });

  const startBtn = el('button', { class: 'btn btn-primary btn-lg' }, [el('span', { html: icon('play') }), 'بدء العمل']);
  const endBtn   = el('button', { class: 'btn btn-danger btn-lg' },  [el('span', { html: icon('stop') }), 'إنهاء العمل']);
  const brkBtn   = el('button', { class: 'btn btn-outline btn-lg' }, [el('span', { html: icon('coffee') }), 'بدء استراحة']);
  const brkEnd   = el('button', { class: 'btn btn-primary btn-lg' }, [el('span', { html: icon('play') }), 'إنهاء الاستراحة']);

  const actions = el('div', { class: 'shift-actions' }, [startBtn, endBtn, brkBtn, brkEnd]);

  const root = el('div', { class: 'shift-status' }, [
    el('div', { class: 'state-line' }, [badge, el('div', { class: 'spacer' }), meta]),
    el('div', {}, [clockEl, clockLabel]),
    actions,
    note
  ]);

  let current = null;      // آخر حالة من الخادم
  let ticking = null;

  async function run(button, fn, confirmOpts) {
    if (confirmOpts) {
      const ok = await confirmDialog(confirmOpts);
      if (!ok) return;
    }
    busy(button, true);
    try {
      const res = await fn();
      update(res);
      onChange?.(res);
    } catch (err) {
      toast(messageOf(err), 'error');
      // أعِد المزامنة مع الخادم: الخادم هو الحقيقة، لا حالة الأزرار
      try { update(await api.me()); } catch { /* تجاهُل */ }
    } finally {
      busy(button, false);
    }
  }

  startBtn.addEventListener('click', () => run(startBtn, () => api.startShift(clientMeta())));
  endBtn.addEventListener('click', () => run(endBtn, () => api.endShift(), {
    title: 'إنهاء العمل', message: 'سيُغلق الشيفت الحالي ويتوقف احتساب النشاط. هل تريد المتابعة؟',
    confirmText: 'إنهاء العمل', danger: true
  }));
  brkBtn.addEventListener('click', () => run(brkBtn, () => api.startBreak('general')));
  brkEnd.addEventListener('click', () => run(brkEnd, () => api.endBreak()));

  function clientMeta() {
    return {
      device_id: localStorage.getItem('eo.device') || '',
      user_agent: navigator.userAgent,
      platform: navigator.platform || '',
      client_time: new Date().toISOString()
    };
  }

  function update(status) {
    if (!status || !status.employee) return;
    current = status;

    const presence = status.presence || 'not_started';
    badge.className = `badge badge-${presence}`;
    badge.textContent = status.presence_label || PRESENCE_LABEL[presence] || presence;

    const hasSession = !!status.session;
    const onBreak = !!status.break;

    startBtn.classList.toggle('hidden', hasSession);
    endBtn.classList.toggle('hidden', !hasSession);
    brkBtn.classList.toggle('hidden', !hasSession || onBreak);
    brkEnd.classList.toggle('hidden', !onBreak);

    if (onBreak) {
      clockLabel.textContent = `مدة الاستراحة — ${BREAK_LABEL[status.break.break_type] || 'استراحة'}`;
      meta.textContent = `بدأت الاستراحة ${time(status.break.started_at)}`;
    } else if (hasSession) {
      clockLabel.textContent = 'مدة الشيفت';
      meta.textContent = `بدأ العمل ${time(status.session.started_at)}`;
    } else {
      clockLabel.textContent = 'مدة الشيفت';
      meta.textContent = status.totals?.sessions_count ? 'أنهيت شيفتك اليوم' : 'لم تبدأ العمل بعد';
    }

    const parts = [];
    if (hasSession && status.session.late_seconds > 0) parts.push(`تأخير: ${duration(status.session.late_seconds)}`);
    if (hasSession && status.session.active_devices > 1) parts.push(`${status.session.active_devices} أجهزة نشطة`);
    if (status.shift) parts.push(`شيفتك: ${status.shift.name_ar} (${String(status.shift.start_time).slice(0,5)} – ${String(status.shift.end_time).slice(0,5)})`);
    note.textContent = parts.join(' · ');

    tick();
    if (!ticking) ticking = setInterval(tick, 1000);
  }

  function tick() {
    if (!current) return;
    if (current.break) clockEl.textContent = clock(secondsSince(current.break.started_at));
    else if (current.session) clockEl.textContent = clock(secondsSince(current.session.started_at));
    else clockEl.textContent = clock(current.totals?.shift_seconds || 0);
  }

  return { root, update, get status() { return current; } };
}
