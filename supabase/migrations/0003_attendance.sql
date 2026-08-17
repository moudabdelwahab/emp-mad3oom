-- 0003 — الحضور: جلسات الشيفت، الاستراحات، وسجل أحداث الحضور

create table if not exists emp_ops.attendance_sessions (
  id              uuid primary key default gen_random_uuid(),
  employee_id     uuid not null references emp_ops.employees(id) on delete cascade,
  -- كل الأوقات من ساعة الخادم. لا يمكن للعميل تمرير أي منها.
  started_at      timestamptz not null default now(),
  ended_at        timestamptz,
  status          text not null default 'open' check (status in ('open','closed','auto_closed')),
  work_date       date not null,
  shift_id        uuid references emp_ops.shifts(id) on delete set null,
  scheduled_start timestamptz,
  late_seconds    integer not null default 0 check (late_seconds >= 0),
  end_reason      text,
  ended_by_employee_id uuid references emp_ops.employees(id) on delete set null,
  start_device_id text,
  client_meta     jsonb not null default '{}'::jsonb,
  adjusted        boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint attendance_end_after_start check (ended_at is null or ended_at >= started_at),
  constraint attendance_open_has_no_end  check ((status = 'open') = (ended_at is null))
);

-- القيد الأهم: لا يمكن أن يوجد شيفتان مفتوحان لنفس الموظف — تُفرض من قاعدة البيانات، لا من الواجهة.
create unique index if not exists attendance_one_open_per_employee
  on emp_ops.attendance_sessions (employee_id) where status = 'open';

create index if not exists attendance_employee_date_idx on emp_ops.attendance_sessions (employee_id, work_date desc);
create index if not exists attendance_started_idx       on emp_ops.attendance_sessions (started_at desc);
create index if not exists attendance_status_idx        on emp_ops.attendance_sessions (status) where status = 'open';

drop trigger if exists trg_attendance_touch on emp_ops.attendance_sessions;
create trigger trg_attendance_touch before update on emp_ops.attendance_sessions
  for each row execute function emp_ops.touch_updated_at();

-- ─────────────────────────────────────────────────────────────
create table if not exists emp_ops.break_sessions (
  id            uuid primary key default gen_random_uuid(),
  attendance_session_id uuid not null references emp_ops.attendance_sessions(id) on delete cascade,
  employee_id   uuid not null references emp_ops.employees(id) on delete cascade,
  started_at    timestamptz not null default now(),
  ended_at      timestamptz,
  status        text not null default 'open' check (status in ('open','closed','auto_closed')),
  break_type    text not null default 'general',
  note          text,
  created_at    timestamptz not null default now(),

  constraint break_end_after_start check (ended_at is null or ended_at >= started_at),
  constraint break_open_has_no_end check ((status = 'open') = (ended_at is null))
);

-- لا يمكن فتح استراحتين داخل نفس الشيفت
create unique index if not exists break_one_open_per_session
  on emp_ops.break_sessions (attendance_session_id) where status = 'open';
-- ولا استراحتين مفتوحتين لنفس الموظف مهما تعددت الشيفتات
create unique index if not exists break_one_open_per_employee
  on emp_ops.break_sessions (employee_id) where status = 'open';

create index if not exists break_session_idx  on emp_ops.break_sessions (attendance_session_id);
create index if not exists break_employee_idx on emp_ops.break_sessions (employee_id, started_at desc);

-- ─────────────────────────────────────────────────────────────
-- سجل أحداث الحضور — للإلحاق فقط (append-only)
create table if not exists emp_ops.attendance_events (
  id            bigint generated always as identity primary key,
  employee_id   uuid not null references emp_ops.employees(id) on delete cascade,
  attendance_session_id uuid references emp_ops.attendance_sessions(id) on delete cascade,
  break_session_id      uuid references emp_ops.break_sessions(id) on delete cascade,
  event_type    text not null check (event_type in
                  ('shift_start','shift_end','shift_auto_close','break_start','break_end',
                   'break_auto_close','admin_adjust','admin_force_end')),
  occurred_at   timestamptz not null default now(),
  actor_employee_id uuid references emp_ops.employees(id) on delete set null,
  metadata      jsonb not null default '{}'::jsonb
);
create index if not exists attendance_events_employee_idx on emp_ops.attendance_events (employee_id, occurred_at desc);
create index if not exists attendance_events_session_idx  on emp_ops.attendance_events (attendance_session_id);

-- منع أي تعديل أو حذف على سجل الأحداث
create or replace function emp_ops.deny_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'هذا السجل للإلحاق فقط ولا يمكن تعديله أو حذفه.' using errcode = 'EO090';
end $$;

drop trigger if exists trg_attendance_events_immutable on emp_ops.attendance_events;
create trigger trg_attendance_events_immutable
  before update or delete on emp_ops.attendance_events
  for each row execute function emp_ops.deny_mutation();

-- ─────────────────────────────────────────────────────────────
-- حماية السجلات المغلقة: لا يمكن تغيير أوقات شيفت مغلق إلا عبر دالة التعديل الإدارية
-- التي ترفع علم الجلسة emp_ops.allow_adjust قبل الكتابة.
create or replace function emp_ops.guard_closed_attendance()
returns trigger language plpgsql as $$
begin
  if old.status <> 'open'
     and coalesce(current_setting('emp_ops.allow_adjust', true), 'off') <> 'on'
     and (new.started_at is distinct from old.started_at
          or new.ended_at   is distinct from old.ended_at
          or new.status     is distinct from old.status) then
    raise exception 'لا يمكن تعديل سجل حضور مغلق إلا عبر التعديل الإداري المُوثَّق.' using errcode = 'EO091';
  end if;
  return new;
end $$;

drop trigger if exists trg_attendance_guard_closed on emp_ops.attendance_sessions;
create trigger trg_attendance_guard_closed
  before update on emp_ops.attendance_sessions
  for each row execute function emp_ops.guard_closed_attendance();

-- مدة جلسة الحضور بالثواني (تحتسب الجلسة المفتوحة حتى اللحظة)
create or replace function emp_ops.session_seconds(p_started timestamptz, p_ended timestamptz)
returns integer
language sql stable as $$
  select greatest(0, floor(extract(epoch from (coalesce(p_ended, now()) - p_started)))::integer);
$$;
