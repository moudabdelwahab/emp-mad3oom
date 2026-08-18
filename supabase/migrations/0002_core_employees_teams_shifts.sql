-- 0002 — الجداول الأساسية: الفرق، الموظفون، الشيفتات، إسناد الشيفتات

create extension if not exists btree_gist;

-- دالة مشتركة لتحديث updated_at
create or replace function emp_ops.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ─────────────────────────────────────────────────────────────
create table if not exists emp_ops.teams (
  id           uuid primary key default gen_random_uuid(),
  name_ar      text not null unique,
  description_ar text,
  manager_employee_id uuid,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────
create table if not exists emp_ops.employees (
  id            uuid primary key default gen_random_uuid(),
  -- الربط بهوية Supabase. on delete set null حتى لا يضيع تاريخ الحضور أبدًا إذا حُذف الحساب.
  user_id       uuid unique references auth.users(id) on delete set null,
  employee_code text unique,
  full_name     text not null check (length(btrim(full_name)) > 0),
  email         text not null,
  phone         text,
  role          text not null default 'employee' references emp_ops.roles(code) on update cascade,
  status        text not null default 'active' check (status in ('active','suspended','archived')),
  team_id       uuid references emp_ops.teams(id) on delete set null,
  timezone      text not null default 'Africa/Cairo',
  hired_at      date,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references emp_ops.employees(id) on delete set null
);
create unique index if not exists employees_email_lower_idx on emp_ops.employees (lower(email));
create index if not exists employees_role_idx   on emp_ops.employees (role);
create index if not exists employees_status_idx on emp_ops.employees (status);
create index if not exists employees_team_idx   on emp_ops.employees (team_id);

comment on table emp_ops.employees is 'سجل الموظفين. الربط بمنصة مدعوم يتم عبر auth.users فقط — لا اعتماد على أي جدول في مخطط public.';

alter table emp_ops.teams
  drop constraint if exists teams_manager_fk,
  add constraint teams_manager_fk foreign key (manager_employee_id)
      references emp_ops.employees(id) on delete set null;

drop trigger if exists trg_employees_touch on emp_ops.employees;
create trigger trg_employees_touch before update on emp_ops.employees
  for each row execute function emp_ops.touch_updated_at();

drop trigger if exists trg_teams_touch on emp_ops.teams;
create trigger trg_teams_touch before update on emp_ops.teams
  for each row execute function emp_ops.touch_updated_at();

-- ─────────────────────────────────────────────────────────────
-- قوالب الشيفتات
create table if not exists emp_ops.shifts (
  id            uuid primary key default gen_random_uuid(),
  name_ar       text not null unique,
  start_time    time not null,
  end_time      time not null,
  -- شيفت يعبر منتصف الليل (مثلاً 22:00 → 06:00)
  crosses_midnight boolean generated always as (end_time <= start_time) stored,
  work_days     integer[] not null default '{0,1,2,3,4}',
  grace_minutes integer not null default 10 check (grace_minutes between 0 and 240),
  timezone      text not null default 'Africa/Cairo',
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references emp_ops.employees(id) on delete set null,
  constraint shifts_work_days_valid check (
    work_days <@ '{0,1,2,3,4,5,6}'::integer[] and array_length(work_days, 1) > 0
  )
);

drop trigger if exists trg_shifts_touch on emp_ops.shifts;
create trigger trg_shifts_touch before update on emp_ops.shifts
  for each row execute function emp_ops.touch_updated_at();

-- إسناد الشيفت للموظف — بدون أي تداخل زمني لنفس الموظف
create table if not exists emp_ops.shift_assignments (
  id             uuid primary key default gen_random_uuid(),
  employee_id    uuid not null references emp_ops.employees(id) on delete cascade,
  shift_id       uuid not null references emp_ops.shifts(id) on delete restrict,
  effective_from date not null,
  effective_to   date,
  created_at     timestamptz not null default now(),
  created_by     uuid references emp_ops.employees(id) on delete set null,
  constraint shift_assignment_dates_valid check (effective_to is null or effective_to >= effective_from),
  -- قيد استبعاد يمنع إسنادين متداخلين لنفس الموظف
  constraint shift_assignment_no_overlap exclude using gist (
    employee_id with =,
    daterange(effective_from, effective_to, '[]') with &&
  )
);
create index if not exists shift_assignments_employee_idx on emp_ops.shift_assignments (employee_id, effective_from desc);

-- الشيفت المُسنَد لموظف في تاريخ معيّن
create or replace function emp_ops.shift_for(p_employee_id uuid, p_date date)
returns emp_ops.shifts
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select s.*
  from emp_ops.shift_assignments sa
  join emp_ops.shifts s on s.id = sa.shift_id
  where sa.employee_id = p_employee_id
    and sa.effective_from <= p_date
    and (sa.effective_to is null or sa.effective_to >= p_date)
    and s.is_active
  order by sa.effective_from desc
  limit 1;
$$;

-- المنطقة الزمنية الفعلية للموظف (منطقته، وإلا منطقة النظام)
create or replace function emp_ops.employee_timezone(p_employee_id uuid)
returns text
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select coalesce(nullif(btrim(e.timezone), ''), emp_ops.system_timezone())
  from emp_ops.employees e where e.id = p_employee_id;
$$;

-- تاريخ العمل (work_date) بمنطقة الموظف الزمنية — يُحسب على الخادم دائمًا
create or replace function emp_ops.work_date_of(p_employee_id uuid, p_ts timestamptz)
returns date
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select (p_ts at time zone emp_ops.employee_timezone(p_employee_id))::date;
$$;
