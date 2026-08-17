/** مكوّنات عرض مشتركة بين الصفحات. */
import { el, emptyState } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { duration, time, pct, PRESENCE_LABEL } from '../utils/format.js';

export function stat(label, value, { sub, iconName, accent, meterPct } = {}) {
  return el('div', { class: `stat ${accent ? 'accent' : ''}` }, [
    el('div', { class: 'stat-label' }, [iconName ? el('span', { html: icon(iconName) }) : null, label]),
    el('div', { class: 'stat-value num', text: value }),
    sub ? el('div', { class: 'stat-sub', text: sub }) : null,
    meterPct !== undefined && meterPct !== null
      ? el('div', { class: `meter mt-4 ${meterPct >= 60 ? 'good' : meterPct >= 30 ? '' : 'low'}` },
          [el('span', { style: `width:${Math.max(0, Math.min(100, meterPct))}%` })])
      : null
  ]);
}

export function presenceBadge(presence, label) {
  return el('span', { class: `badge badge-${presence || 'not_started'}`,
                      text: label || PRESENCE_LABEL[presence] || presence || '—' });
}

export function card(title, body, actions = []) {
  return el('section', { class: 'card' }, [
    title ? el('div', { class: 'card-head' }, [el('h2', { text: title }), el('div', { class: 'row' }, actions)]) : null,
    el('div', { class: 'card-body' + (body && body.tagName === 'TABLE' ? ' tight' : '') }, [body])
  ]);
}

export function table(columns, rows, renderRow, { onRowClick, empty = 'لا توجد بيانات لعرضها.' } = {}) {
  if (!rows || !rows.length) return emptyState(empty, icon('inbox'));
  const tb = el('tbody', {}, rows.map((r, i) => {
    const tr = el('tr', { class: onRowClick ? 'clickable' : '' }, renderRow(r, i).map((c) =>
      c instanceof Node && c.tagName === 'TD' ? c : el('td', {}, [c])));
    if (onRowClick) tr.addEventListener('click', () => onRowClick(r));
    return tr;
  }));
  return el('div', { class: 'table-wrap' }, [
    el('table', { class: 'data' }, [
      el('thead', {}, [el('tr', {}, columns.map((c) => el('th', { text: c })))]),
      tb
    ])
  ]);
}

/** الخط الزمني اليومي. */
export function timeline(items) {
  const shown = (items || []).filter((i) =>
    !['active_period', 'break_period', 'idle_period'].includes(i.kind) || (i.seconds || 0) >= 60);

  if (!shown.length) return emptyState('لا يوجد نشاط مسجَّل في هذا اليوم.', icon('activity'));

  const kindClass = (k) =>
    k === 'active_period' ? 'k-active' :
    k === 'idle_period'   ? 'k-idle'   :
    k === 'break_period'  ? 'k-break'  : 'k-event';

  return el('div', { class: 'timeline' }, shown.map((i) =>
    el('div', { class: `tl-item ${kindClass(i.kind)}` }, [
      el('span', { class: 'tl-time', text: time(i.at) }),
      el('span', { class: 'tl-label', text: i.label }),
      i.seconds ? el('span', { class: 'tl-dur', text: `(${duration(i.seconds)})` }) : null
    ])
  ));
}

/** رسم أعمدة يومي: نشاط / خمول / استراحة. */
export function barChart(days, { max } = {}) {
  if (!days || !days.length) return emptyState('لا توجد بيانات في هذه الفترة.', icon('chart'));
  const peak = max || Math.max(...days.map((d) => Number(d.shift_seconds) || 0), 1);

  return el('div', {}, [
    el('div', { class: 'bars' }, days.map((d) => {
      const shiftS  = Number(d.shift_seconds) || 0;
      const breakS  = Math.min(Number(d.break_seconds) || 0, shiftS);
      const activeS = Math.min(Number(d.active_seconds) || 0, Math.max(shiftS - breakS, 0));
      const idleS   = Math.max(shiftS - breakS - activeS, 0);
      const h = (v) => `${(v / peak) * 100}%`;
      return el('div', {
        class: 'bar',
        title: `${d.work_date}\nعمل: ${duration(shiftS)} · نشاط: ${duration(activeS)} · خمول: ${duration(idleS)} · استراحة: ${duration(breakS)}`
      }, [
        el('i', { class: 'b-idle',   style: `height:${h(idleS)}` }),
        el('i', { class: 'b-break',  style: `height:${h(breakS)}` }),
        el('i', { class: 'b-active', style: `height:${h(activeS)}` })
      ]);
    })),
    el('div', { class: 'row', style: 'gap:4px' }, days.map((d) =>
      el('div', { class: 'bar-label', style: 'flex:1;min-width:8px', text: String(d.work_date).slice(5) }))),
    el('div', { class: 'legend mt-4' }, [
      el('span', {}, [el('i', { style: 'background:var(--c-active)' }), 'نشاط']),
      el('span', {}, [el('i', { style: 'background:var(--c-idle);opacity:.55' }), 'خمول']),
      el('span', {}, [el('i', { style: 'background:var(--c-break);opacity:.5' }), 'استراحة'])
    ])
  ]);
}

/** شرح معادلة نسبة النشاط — لا رقم بلا تفسير. */
export function formulaNote() {
  return el('div', { class: 'alert alert-info' }, [
    el('span', { html: icon('info') }),
    el('div', {}, [
      el('div', { class: 'strong', text: 'كيف تُحسب نسبة النشاط؟' }),
      el('div', { class: 'small', text: 'نسبة النشاط = وقت النشاط ÷ (مدة الشيفت − مدة الاستراحات) × 100' }),
      el('div', { class: 'xsmall dim', text: 'وقت النشاط يُحتسب بالدقيقة من تفاعل حقيقي داخل بيئة العمل. هذا مقياس نشاط داخل المنصة، وليس حكمًا على جودة عمل الموظف.' })
    ])
  ]);
}
