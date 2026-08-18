-- 0004 — محرك النشاط: جلسات الأجهزة، النبضات، الأحداث، ودقائق النشاط
--
-- الفكرة المحورية: وقت النشاط لا يُجمَع من مدد يرسلها العميل، بل يُبنى من
-- "دقائق نشاط" مفتاحها الأساسي (employee_id, minute_start) — فالدقيقة الواحدة
-- تُحسب مرة واحدة مهما بلّغ عنها عدد التبويبات أو الأجهزة.

-- جلسة نشاط = (شيفت × جهاز). التبويبات المتعددة على نفس الجهاز تتشارك نفس الجلسة.
create table if not exists emp_ops.activity_sessions (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references emp_ops.employees(id) on delete cascade,
  attendance_session_id uuid not null references emp_ops.attendance_sessions(id) on delete cascade,
  device_id     text not null,
  source_app    text not null default 'emp_ops',
  started_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  ended_at      timestamptz,
  user_agent    text,
  platform      text,
  ip            inet,
  constraint activity_session_unique_device unique (attendance_session_id, device_id, source_app)
);
create index if not exists activity_sessions_employee_idx on emp_ops.activity_sessions (employee_id, last_seen_at desc);
create index if not exists activity_sessions_attendance_idx on emp_ops.activity_sessions (attendance_session_id);

comment on table emp_ops.activity_sessions is
  'جلسة نشاط لكل جهاز داخل الشيفت. تعدد الجلسات المفتوحة لموظف واحد = تسجيل دخول من أكثر من جهاز.';

-- ─────────────────────────────────────────────────────────────
-- النبضات — مجمّعة في نوافذ زمنية على الخادم لمنع التكرار وتقليل الحجم
create table if not exists emp_ops.activity_heartbeats (
  id            bigint generated always as identity primary key,
  employee_id   uuid not null references emp_ops.employees(id) on delete cascade,
  attendance_session_id uuid not null references emp_ops.attendance_sessions(id) on delete cascade,
  activity_session_id   uuid not null references emp_ops.activity_sessions(id) on delete cascade,
  -- بداية النافذة الزمنية — تُحسب على الخادم من now()
  bucket_start  timestamptz not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  calls         integer not null default 1,
  interactions  integer not null default 0,
  visible       boolean not null default true,
  tabs          integer not null default 1,
  -- وقت العميل يُخزَّن للتدقيق فقط ولا يدخل في أي حساب
  client_sent_at timestamptz,
  clock_skew_seconds integer,
  constraint heartbeat_unique_bucket unique (activity_session_id, bucket_start)
);
create index if not exists heartbeats_employee_idx on emp_ops.activity_heartbeats (employee_id, bucket_start desc);

comment on column emp_ops.activity_heartbeats.clock_skew_seconds is
  'فرق ساعة العميل عن الخادم — مؤشر تدقيق لكشف العبث بالساعة، ولا يُستخدم في أي حساب.';

-- ─────────────────────────────────────────────────────────────
-- أحداث النشاط الحقيقية داخل منصة مدعوم (للإلحاق فقط)
create table if not exists emp_ops.activity_events (
  id            bigint generated always as identity primary key,
  employee_id   uuid not null references emp_ops.employees(id) on delete cascade,
  attendance_session_id uuid references emp_ops.attendance_sessions(id) on delete cascade,
  activity_session_id   uuid references emp_ops.activity_sessions(id) on delete set null,
  event_type    text not null references emp_ops.activity_types(code) on update cascade,
  occurred_at   timestamptz not null default now(),
  entity_type   text,
  entity_id     text,
  source_app    text not null default 'emp_ops',
  metadata      jsonb not null default '{}'::jsonb,
  -- وقت العميل للتدقيق فقط
  client_reported_at timestamptz,
  is_backfilled boolean not null default false
);
create index if not exists activity_events_employee_idx on emp_ops.activity_events (employee_id, occurred_at desc);
create index if not exists activity_events_session_idx  on emp_ops.activity_events (attendance_session_id, occurred_at desc);
create index if not exists activity_events_type_idx     on emp_ops.activity_events (event_type);

drop trigger if exists trg_activity_events_immutable on emp_ops.activity_events;
create trigger trg_activity_events_immutable
  before update or delete on emp_ops.activity_events
  for each row execute function emp_ops.deny_mutation();

-- ─────────────────────────────────────────────────────────────
-- دفتر أستاذ دقائق النشاط — مصدر الحقيقة الوحيد لوقت النشاط
create table if not exists emp_ops.activity_minutes (
  employee_id   uuid not null references emp_ops.employees(id) on delete cascade,
  minute_start  timestamptz not null,
  attendance_session_id uuid not null references emp_ops.attendance_sessions(id) on delete cascade,
  work_date     date not null,
  seconds       smallint not null default 60 check (seconds between 1 and 60),
  interactions  integer not null default 0,
  sources       text[] not null default '{}',
  updated_at    timestamptz not null default now(),
  primary key (employee_id, minute_start)
);
create index if not exists activity_minutes_date_idx    on emp_ops.activity_minutes (employee_id, work_date);
create index if not exists activity_minutes_session_idx on emp_ops.activity_minutes (attendance_session_id);

comment on table emp_ops.activity_minutes is
  'دقيقة واحدة لكل موظف مهما تعددت التبويبات/الأجهزة. المفتاح الأساسي نفسه هو ما يمنع التكرار.';

-- ─────────────────────────────────────────────────────────────
-- الحالة اللحظية للموظف — تُكتب من الخادم فقط، وتُقفل أثناء الاستيعاب لمنع التسابق
create table if not exists emp_ops.employee_runtime_state (
  employee_id   uuid primary key references emp_ops.employees(id) on delete cascade,
  attendance_session_id uuid references emp_ops.attendance_sessions(id) on delete set null,
  last_interaction_at timestamptz,
  last_heartbeat_at   timestamptz,
  -- آخر لحظة تم احتساب النشاط حتى عندها — يضمن ألا تُحسب أي ثانية مرتين
  marked_until  timestamptz,
  presence      text not null default 'offline',
  last_event_type text,
  updated_at    timestamptz not null default now()
);

comment on column emp_ops.employee_runtime_state.marked_until is
  'العداد التسلسلي لاحتساب النشاط. لأنه على مستوى الموظف (لا التبويب) يستحيل احتساب نفس الثانية مرتين.';
