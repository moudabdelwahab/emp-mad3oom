/** الهيكل المشترك: الشريط الجانبي والرأس. */
import { el, $, mount } from '../utils/dom.js';
import { icon } from '../utils/icons.js';
import { state } from '../auth/guard.js';
import { signOut } from '../auth/auth.js';
import * as theme from '../utils/theme.js';
import { CONFIG } from '../config.js';
import { initials, ROLE_LABEL } from '../utils/format.js';

const NAV = [
  { group: 'مساحتي', items: [
    { href: 'dashboard.html', label: 'لوحتي',      icon: 'clock',   rank: 0 },
    { href: 'my-history.html', label: 'سجلّي',     icon: 'history', rank: 0 }
  ]},
  { group: 'الإدارة', items: [
    { href: 'admin.html',     label: 'المتابعة اللحظية', icon: 'dashboard', rank: 50 },
    { href: 'employees.html', label: 'الموظفون',         icon: 'users',     rank: 50 },
    { href: 'reports.html',   label: 'التقارير',         icon: 'chart',     rank: 50 },
    { href: 'audit.html',     label: 'سجل التدقيق',      icon: 'shield',    rank: 50 },
    { href: 'settings.html',  label: 'الإعدادات',        icon: 'settings',  rank: 100 }
  ]}
];

export function renderShell({ title, subtitle, actions = [] } = {}) {
  const here = location.pathname.split('/').pop() || 'dashboard.html';
  const rank = state.rank || 0;

  const sidebar = el('aside', { class: 'sidebar', id: 'sidebar' }, [
    el('div', { class: 'brand' }, [
      el('div', { class: 'brand-mark', html: icon('logo') }),
      el('div', { class: 'brand-text' }, [
        el('b', { text: 'عمليات الموظفين' }),
        el('span', { text: CONFIG.APP_SHORT })
      ])
    ]),
    el('nav', { class: 'nav' }, NAV.map((g) => {
      const items = g.items.filter((i) => rank >= i.rank);
      if (!items.length) return null;
      return el('div', { class: 'nav-group' }, [
        el('div', { class: 'nav-title', text: g.group }),
        ...items.map((i) => el('a', {
          href: i.href, class: here === i.href ? 'active' : '',
          'aria-current': here === i.href ? 'page' : null
        }, [el('span', { html: icon(i.icon) }), i.label]))
      ]);
    })),
    el('div', { class: 'nav-foot' }, [
      el('div', { class: 'user-chip' }, [
        el('div', { class: 'avatar', text: initials(state.me?.employee?.full_name) }),
        el('div', { class: 'who' }, [
          el('b', { text: state.me?.employee?.full_name || '—' }),
          el('span', { text: state.me?.employee?.role_label || ROLE_LABEL[state.me?.employee?.role] || '' })
        ])
      ]),
      el('button', { class: 'btn btn-ghost btn-block btn-sm', onclick: () => signOut() },
        [el('span', { html: icon('logout') }), 'تسجيل الخروج'])
    ])
  ]);

  const themeBtn = el('button', {
    class: 'icon-btn', title: `السمة: ${theme.LABEL[theme.current()]}`,
    'aria-label': 'تبديل السمة',
    html: theme.current() === 'dark' ? icon('moon') : icon('sun'),
    onclick: (e) => {
      const mode = theme.cycle();
      const btn = e.currentTarget;
      btn.innerHTML = mode === 'dark' ? icon('moon') : icon('sun');
      btn.title = `السمة: ${theme.LABEL[mode]}`;
    }
  });

  const menuBtn = el('button', {
    class: 'icon-btn menu-toggle', 'aria-label': 'القائمة', html: icon('menu'),
    onclick: () => toggleNav(true)
  });

  const topbar = el('header', { class: 'topbar' }, [
    menuBtn,
    el('div', {}, [
      el('h1', { text: title || '' }),
      subtitle ? el('div', { class: 'sub', text: subtitle }) : null
    ]),
    el('div', { class: 'spacer' }),
    el('span', { class: 'conn', id: 'conn', text: 'متصل' }),
    ...actions,
    themeBtn
  ]);

  const content = el('div', { class: 'content', id: 'content' });
  const main = el('main', { class: 'main' }, [topbar, content]);

  mount(document.body, el('div', { class: 'app' }, [sidebar, main]), el('div', { id: 'toasts' }));
  return { content, topbar, sidebar };
}

function toggleNav(open) {
  const sb = $('#sidebar');
  if (!sb) return;
  sb.classList.toggle('open', open);
  let scrim = $('.nav-scrim');
  if (open && !scrim) {
    scrim = el('div', { class: 'nav-scrim', onclick: () => toggleNav(false) });
    document.body.append(scrim);
  } else if (!open && scrim) scrim.remove();
}

/** مؤشر الاتصال في الرأس. */
export function setConnection(online, note) {
  const c = $('#conn');
  if (!c) return;
  c.classList.toggle('off', !online);
  c.textContent = note || (online ? 'متصل' : 'غير متصل');
}

export function pageTitle(t) {
  document.title = `${t} · ${CONFIG.APP_NAME}`;
}
