-- 0001 — المخطط الأساسي، جداول الكتالوج، والإعدادات
-- كل ما يخص نظام عمليات الموظفين يعيش داخل مخطط emp_ops ولا يمسّ مخطط public الخاص بمنصة مدعوم.

create schema if not exists emp_ops;
comment on schema emp_ops is 'نظام حضور ونشاط موظفي مدعوم — معزول تمامًا عن مخطط public الخاص بالمنصة';

revoke all on schema emp_ops from public;
grant usage on schema emp_ops to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- الأدوار (كتالوج قابل للتوسع بدون تعديل كود)
-- ─────────────────────────────────────────────────────────────
create table if not exists emp_ops.roles (
  code         text primary key,
  name_ar      text not null,
  description_ar text,
  rank         integer not null check (rank between 0 and 1000),
  created_at   timestamptz not null default now()
);
comment on table emp_ops.roles is 'أدوار النظام. الصلاحية تُقاس بالـ rank وليس باسم الدور، ليمكن إضافة أدوار جديدة لاحقًا.';

insert into emp_ops.roles (code, name_ar, description_ar, rank) values
  ('employee',    'موظف',        'يرى بياناته فقط، ويدير شيفته واستراحاته',                10),
  ('manager',     'مدير / موارد بشرية', 'يرى كل الموظفين والتقارير ويدير الشيفتات',        50),
  ('super_admin', 'مدير عام',    'صلاحيات كاملة تشمل الإعدادات والأدوار وتعديل الحضور',   100)
on conflict (code) do nothing;

-- ─────────────────────────────────────────────────────────────
-- أنواع الأحداث (كتالوج) — إضافة نوع نشاط جديد = صف واحد، بلا كود
-- ─────────────────────────────────────────────────────────────
create table if not exists emp_ops.activity_types (
  code           text primary key,
  name_ar        text not null,
  category       text not null default 'general',
  -- هل يُعتبر هذا الحدث "تفاعلًا حقيقيًا" يجدد نافذة النشاط؟
  counts_as_interaction boolean not null default true,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);
comment on column emp_ops.activity_types.counts_as_interaction is
  'الأحداث التي لا تُعتبر تفاعلًا (مثل فتح الصفحة فقط) تُسجَّل للتدقيق لكنها لا تمنح وقت نشاط.';

insert into emp_ops.activity_types (code, name_ar, category, counts_as_interaction) values
  ('ticket_open',        'فتح تذكرة',            'tickets',  true),
  ('ticket_reply',       'إرسال رد على تذكرة',   'tickets',  true),
  ('ticket_status',      'تغيير حالة تذكرة',     'tickets',  true),
  ('ticket_assign',      'إسناد تذكرة',          'tickets',  true),
  ('ticket_note',        'إضافة ملاحظة داخلية',  'tickets',  true),
  ('chat_reply',         'رد على محادثة',        'chat',     true),
  ('search',             'بحث',                  'tools',    true),
  ('navigation',         'تنقّل بين الصفحات',    'ui',       true),
  ('ui_interaction',     'تفاعل داخل الواجهة',   'ui',       true),
  ('tool_use',           'استخدام أداة دعم',     'tools',    true),
  ('page_view',          'عرض صفحة',             'ui',       false),
  ('page_focus',         'العودة إلى التبويب',   'ui',       false),
  ('page_hidden',        'إخفاء التبويب',        'ui',       false)
on conflict (code) do nothing;

-- ─────────────────────────────────────────────────────────────
-- الإعدادات — لا يوجد أي رقم تشغيلي مثبَّت في الكود
-- ─────────────────────────────────────────────────────────────
create table if not exists emp_ops.app_settings (
  key            text primary key,
  value          jsonb not null,
  description_ar text not null,
  value_type     text not null default 'number' check (value_type in ('number','text','boolean','json')),
  min_value      numeric,
  max_value      numeric,
  is_public      boolean not null default true,   -- هل يقرؤه الموظف العادي؟
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);

insert into emp_ops.app_settings (key, value, description_ar, value_type, min_value, max_value, is_public) values
  ('idle_threshold_seconds',      '300',              'المدة بلا تفاعل حقيقي التي يُعتبر بعدها الموظف خاملًا (بالثواني)', 'number', 60,   7200, true),
  ('heartbeat_interval_seconds',  '60',               'الفترة بين كل نبضة وأخرى يرسلها المتصفح (بالثواني)',              'number', 15,   600,  true),
  ('offline_threshold_seconds',   '180',              'المدة بلا نبضات التي يُعتبر بعدها الموظف غير متصل (بالثواني)',    'number', 60,   3600, true),
  ('heartbeat_bucket_seconds',    '30',               'حجم النافذة الزمنية لمنع تكرار النبضات (بالثواني)',               'number', 10,   300,  false),
  ('max_ingest_calls_per_bucket', '6',                'الحد الأقصى لعدد نداءات التتبّع المقبولة داخل النافذة الواحدة',    'number', 1,    60,   false),
  ('max_events_per_call',         '50',               'الحد الأقصى لعدد أحداث النشاط في النداء الواحد',                  'number', 1,    500,  false),
  ('auto_close_after_seconds',    '43200',            'إغلاق الشيفت تلقائيًا بعد انقطاع النبضات هذه المدة (بالثواني)',    'number', 1800, 172800, false),
  ('max_shift_seconds',           '57600',            'الحد الأقصى لمدة الشيفت الواحد (بالثواني)',                       'number', 3600, 172800, false),
  ('default_timezone',            '"Africa/Cairo"',   'المنطقة الزمنية الافتراضية للنظام',                               'text',   null, null, true),
  ('late_grace_minutes',          '10',               'دقائق السماح قبل احتساب التأخير',                                 'number', 0,    240,  true),
  ('max_break_seconds_per_day',   '5400',             'الحد الأقصى لمجموع الاستراحات في اليوم (بالثواني) — للتنبيه فقط',  'number', 0,    43200, true),
  ('offline_recovery_credit_seconds', '0',            'أقصى وقت يُحتسب نشاطًا بعد عودة الاتصال دون إثبات (0 = لا يُحتسب)', 'number', 0,   600,  false),
  ('workweek_days',               '[0,1,2,3,4]',      'أيام العمل الأسبوعية (0=الأحد ... 6=السبت)',                      'json',   null, null, true)
on conflict (key) do nothing;

-- قارئ إعدادات مُخزَّن مؤقتًا داخل الاستعلام الواحد
create or replace function emp_ops.setting_num(p_key text, p_default numeric default null)
returns numeric
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select coalesce((select (value #>> '{}')::numeric from emp_ops.app_settings where key = p_key), p_default);
$$;

create or replace function emp_ops.setting_text(p_key text, p_default text default null)
returns text
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select coalesce((select value #>> '{}' from emp_ops.app_settings where key = p_key), p_default);
$$;

create or replace function emp_ops.system_timezone()
returns text
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select emp_ops.setting_text('default_timezone', 'Africa/Cairo');
$$;
