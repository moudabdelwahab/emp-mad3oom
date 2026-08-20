/**
 * اختبار عرض الواجهات (UI smoke test).
 *
 * الغرض: التأكد أن كل صفحة داخلية تُرسَم بلا أي خطأ JavaScript، وأن الجداول
 * والبطاقات والخط الزمني تتعامل مع البيانات الفارغة والكاملة على السواء.
 *
 * هذا الاختبار يستبدل عميل Supabase بعميل وهمي داخل المتصفح فقط أثناء
 * الاختبار — لا علاقة له بتشغيل النظام، ولا يصل أي منه إلى المستخدم النهائي.
 * البيانات الحقيقية في التطبيق تأتي دائمًا من قاعدة البيانات.
 *
 * التشغيل:  python3 -m http.server 8899   ثم   node tests/ui-smoke.mjs
 */
import { chromium } from 'playwright-core';
import fs from 'fs';

const BASE = process.env.EO_BASE || 'http://127.0.0.1:8899';
const EXE = ['/opt/pw-browsers/chromium/chrome-linux/chrome',
             '/opt/pw-browsers/chromium-1194/chrome-linux/chrome']
            .find((p) => fs.existsSync(p));

const now = new Date();
const iso = (minsAgo) => new Date(now.getTime() - minsAgo * 60000).toISOString();
const today = now.toISOString().slice(0, 10);

const ME = {
  server_time: now.toISOString(), work_date: today,
  employee: { id: 'e1', full_name: 'أحمد محمود', email: 'a@mad3oom.com', employee_code: 'EMP-0002',
              role: 'super_admin', role_label: 'مدير عام', rank: 100, status: 'active',
              timezone: 'Africa/Cairo', team: 'فريق الدعم' },
  session: { id: 's1', started_at: iso(200), late_seconds: 420, device_id: 'd1', active_devices: 2 },
  break: null,
  shift: { id: 'sh1', name_ar: 'الشيفت الصباحي', start_time: '09:00:00', end_time: '17:00:00', grace_minutes: 10, work_days: [0,1,2,3,4] },
  presence: 'active', presence_label: 'نشط',
  last_interaction_at: iso(1), last_heartbeat_at: iso(0),
  totals: { shift_seconds: 12000, break_seconds: 1800, active_seconds: 7200, idle_seconds: 3000, active_pct: 70.6, sessions_count: 1 },
  settings: { idle_threshold_seconds: 300, heartbeat_interval_seconds: 60, offline_threshold_seconds: 180, timezone: 'Africa/Cairo' }
};

const RESPONSES = {
  eo_me: ME,
  // نبضة لم تُحتسب: تبويب مدعوم غير مفتوح ⇒ يجب أن تظهر رسالة توضيحية للموظف
  eo_ingest_activity: { status: 'ok', server_time: now.toISOString(), presence: 'idle', presence_label: 'خامل',
                        credited_seconds: 0, stored_events: 0, on_break: false, totals: ME.totals,
                        qualifies: false, engaged: false, activity_counted: false,
                        activity_reason: 'not_qualified_app', next_heartbeat_seconds: 60 },
  eo_my_timeline: [
    { at: iso(200), until: null, kind: 'shift_start', label: 'بدأ العمل', seconds: null, meta: {} },
    { at: iso(198), until: iso(150), kind: 'active_period', label: 'فترة نشاط', seconds: 2880, meta: {} },
    { at: iso(150), until: iso(120), kind: 'idle_period', label: 'فترة خمول', seconds: 1800, meta: {} },
    { at: iso(120), until: iso(90), kind: 'break_period', label: 'فترة استراحة', seconds: 1800, meta: {} }
  ],
  eo_my_activity: [
    { occurred_at: iso(5), event_type: 'ticket_reply', event_label: 'إرسال رد على تذكرة', entity_type: 'ticket', entity_id: 'T-42', source_app: 'mad3oom', metadata: {} }
  ],
  eo_my_history: [
    { work_date: today, first_start_at: iso(200), last_end_at: null, shift_seconds: 12000, break_seconds: 1800,
      active_seconds: 7200, idle_seconds: 3000, active_pct: 70.6, late_seconds: 420, is_late: true, is_absent: false, sessions_count: 1 }
  ],
  eo_admin_overview: {
    server_time: now.toISOString(), work_date: today, timezone: 'Africa/Cairo',
    live: { total_employees: 12, working: 7, active: 4, idle: 2, on_break: 1, disconnected: 0, ended: 2, not_started: 3 },
    today: { shift_seconds: 90000, sessions_count: 9, break_seconds: 9000, active_seconds: 54000,
             idle_seconds: 27000, avg_active_pct: 66.7, late_count: 2, absent_count: 1, employees_worked: 9 }
  },
  eo_admin_employees_live: [
    { employee_id: 'e1', full_name: 'أحمد محمود', employee_code: 'EMP-0002', email: 'a@mad3oom.com', role: 'employee',
      team: 'فريق الدعم', presence: 'active', presence_label: 'نشط', session_id: 's1', started_at: iso(200),
      shift_seconds: 12000, active_seconds: 7200, idle_seconds: 3000, break_seconds: 1800, active_pct: 70.6,
      late_seconds: 420, last_interaction_at: iso(1), last_heartbeat_at: iso(0), active_devices: 2, status: 'active' },
    { employee_id: 'e2', full_name: 'سارة علي', employee_code: null, email: 's@mad3oom.com', role: 'employee',
      team: null, presence: 'not_started', presence_label: 'لم يبدأ العمل', session_id: null, started_at: null,
      shift_seconds: 0, active_seconds: 0, idle_seconds: 0, break_seconds: 0, active_pct: null,
      late_seconds: 0, last_interaction_at: null, last_heartbeat_at: null, active_devices: 0, status: 'active' }
  ],
  eo_admin_multi_device: [{ employee_id: 'e1', full_name: 'أحمد محمود', devices: 2, session_id: 's1' }],
  eo_admin_employee_detail: { ...ME, requested_date: today,
    day_totals: { shift_seconds: 12000, break_seconds: 1800, active_seconds: 7200, idle_seconds: 3000, active_pct: 70.6, sessions_count: 1 },
    sessions: [{ id: 's1', started_at: iso(200), ended_at: null, status: 'open', late_seconds: 420, duration_seconds: 12000, end_reason: null, adjusted: false }],
    breaks: [{ id: 'b1', started_at: iso(120), ended_at: iso(90), status: 'closed', break_type: 'general', duration_seconds: 1800 }],
    devices: [{ device_id: 'abcdef123456', source_app: 'mad3oom', started_at: iso(200), last_seen_at: iso(0), ended_at: null, platform: 'Linux', ip: '10.0.0.1' }] },
  eo_admin_employee_timeline: [],
  eo_admin_employee_activity: [],
  eo_admin_employee_history: [],
  eo_admin_list_employees: [
    { id: 'e1', user_id: 'u1', linked: true, employee_code: 'EMP-0002', full_name: 'أحمد محمود', email: 'a@mad3oom.com',
      phone: null, role: 'employee', role_label: 'موظف', status: 'active', team_id: null, team: 'فريق الدعم',
      timezone: 'Africa/Cairo', hired_at: '2026-01-01', shift_name: 'الشيفت الصباحي', created_at: iso(9999) },
    { id: 'e2', user_id: null, linked: false, employee_code: null, full_name: 'سارة علي', email: 's@mad3oom.com',
      phone: null, role: 'employee', role_label: 'موظف', status: 'suspended', team_id: null, team: null,
      timezone: 'Africa/Cairo', hired_at: null, shift_name: null, created_at: iso(9999) }
  ],
  eo_lists: {
    roles: [{ code: 'employee', name_ar: 'موظف', rank: 10 }, { code: 'manager', name_ar: 'مدير', rank: 50 }, { code: 'super_admin', name_ar: 'مدير عام', rank: 100 }],
    teams: [{ id: 't1', name_ar: 'فريق الدعم', is_active: true }],
    shifts: [{ id: 'sh1', name_ar: 'الشيفت الصباحي', start_time: '09:00:00', end_time: '17:00:00', work_days: [0,1,2,3,4], grace_minutes: 10, is_active: true }],
    activity_types: [], audit_actions: [{ code: 'shift.start', name_ar: 'بدء شيفت', severity: 'info' }],
    employees: [{ id: 'e1', full_name: 'أحمد محمود', role: 'employee', status: 'active' }]
  },
  eo_report: {
    from: today, to: today, generated_at: now.toISOString(), timezone: 'Africa/Cairo',
    filters: {}, formula: 'x',
    summary: { shift_seconds: 90000, break_seconds: 9000, active_seconds: 54000, idle_seconds: 27000,
               present_days: 9, absent_days: 1, late_days: 2, sessions_count: 9, employees: 2, avg_active_pct: 66.7 },
    employees: [{ employee_id: 'e1', full_name: 'أحمد محمود', employee_code: 'EMP-0002', role: 'employee', team: 'فريق الدعم',
                  shift_seconds: 45000, break_seconds: 4500, active_seconds: 27000, idle_seconds: 13500, active_pct: 66.7,
                  present_days: 5, absent_days: 0, late_days: 1, sessions_count: 5 }],
    daily: [{ work_date: today, shift_seconds: 90000, break_seconds: 9000, active_seconds: 54000, employees: 2 }]
  },
  eo_admin_settings: [
    { key: 'idle_threshold_seconds', value: 300, description_ar: 'المدة بلا تفاعل حقيقي التي يُعتبر بعدها الموظف خاملًا (بالثواني)',
      value_type: 'number', min_value: 60, max_value: 7200, updated_at: now.toISOString() },
    { key: 'default_timezone', value: 'Africa/Cairo', description_ar: 'المنطقة الزمنية الافتراضية للنظام',
      value_type: 'text', min_value: null, max_value: null, updated_at: now.toISOString() }
  ],
  eo_admin_audit_logs: [
    { id: 1, occurred_at: iso(10), actor_name: 'أحمد محمود', actor_role: 'super_admin', action: 'shift.start',
      action_label: 'بدء شيفت', severity: 'info', target_type: 'attendance_session', target_id: 's1',
      target_label: 'أحمد محمود', ip: '10.0.0.1', metadata: { late_seconds: 420 } }
  ],
  eo_log_auth: true, eo_log_export: true
};

const STUB = `window.supabase = {
  createClient: () => ({
    auth: {
      getSession: async () => ({ data: { session: { user: { id: 'u1', email: 'a@mad3oom.com' } } } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
      signOut: async () => ({}),
      signInWithPassword: async () => ({ data: { session: {} } })
    },
    rpc: async (fn) => ({ data: (window.__EO_FIXTURES__ || {})[fn] ?? null, error: null }),
    channel: () => ({ on() { return this; }, subscribe() { return this; } })
  })
};`;

const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
const pages = [
  ['dashboard.html', 'لوحة الموظف'],
  ['my-history.html', 'سجل الموظف'],
  ['admin.html', 'لوحة الإدارة'],
  ['employee.html?id=e1', 'ملف الموظف'],
  ['employees.html', 'إدارة الموظفين'],
  ['reports.html', 'التقارير'],
  ['audit.html', 'سجل التدقيق'],
  ['settings.html', 'الإعدادات']
];

let pass = 0, fail = 0;
for (const [path, label] of pages) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });

  await page.route('**/js/vendor/supabase.js', (r) =>
    r.fulfill({ contentType: 'application/javascript', body: STUB }));
  await page.addInitScript(`window.__EO_FIXTURES__ = ${JSON.stringify(RESPONSES)};`);

  await page.goto(`${BASE}/${path}`, { waitUntil: 'networkidle', timeout: 20000 });
  await page.waitForTimeout(900);

  const real = errors.filter((e) => !/favicon|net::ERR_/.test(e));
  const rendered = await page.evaluate(() => ({
    sidebar: !!document.querySelector('.sidebar'),
    cards: document.querySelectorAll('.card, .stat').length,
    text: document.body.innerText.length,
    latin: /[A-Za-z]{4,}/.test(
      Array.from(document.querySelectorAll('h1,h2,h3,.stat-label,.nav a,.btn,th'))
        .map((n) => n.textContent).join(' ').replace(/EMP-\d+|mad3oom|CSV|IP/gi, ''))
  }));

  // لوحة الموظف: يجب أن تشرح سبب توقّف احتساب وقت النشاط.
  // الرسالة تظهر بعد أول نبضة (بعد ثانيتين من التحميل)، لذا ننتظرها.
  const hintOk = path !== 'dashboard.html' || await page
    .waitForFunction(() => document.body.innerText.includes('وقت النشاط يُحتسب داخل منصة مدعوم فقط'),
                     null, { timeout: 6000 })
    .then(() => true).catch(() => false);

  const ok = real.length === 0 && rendered.sidebar && rendered.cards > 0 && rendered.text > 200
             && !rendered.latin && hintOk;
  ok ? pass++ : fail++;
  console.log(`${ok ? '[نجح]' : '[فشل]'} ${label} (${path}) — بطاقات: ${rendered.cards}${real.length ? ' — أخطاء: ' + real.join(' | ') : ''}${rendered.latin ? ' — نص إنجليزي في الواجهة' : ''}${hintOk ? '' : ' — رسالة سبب عدم الاحتساب لم تظهر'}`);

  if (process.env.EO_SHOTS) await page.screenshot({ path: `${process.env.EO_SHOTS}/${path.split('?')[0].replace('.html', '')}.png`, fullPage: true });
  await ctx.close();
}
console.log(`\nنجح: ${pass}   فشل: ${fail}`);
await browser.close();
process.exit(fail ? 1 : 0);
