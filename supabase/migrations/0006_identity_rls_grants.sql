-- 0006 — الهوية، الصلاحيات، RLS، ومنح الصلاحيات على مستوى Postgres
--
-- القاعدة الحاكمة: لا يملك أي دور عميل (anon / authenticated) صلاحية
-- INSERT أو UPDATE أو DELETE على أي جدول في emp_ops — إطلاقًا.
-- كل كتابة تمرّ عبر دالة SECURITY DEFINER تفحص الهوية والصلاحية والقواعد.

-- ─────────────────────────────────────────────────────────────
-- 1) الهوية والصلاحية
-- ─────────────────────────────────────────────────────────────

-- SECURITY DEFINER حتى لا تدخل هذه الدالة في حلقة RLS لا نهائية عند استخدامها داخل السياسات
create or replace function emp_ops.current_employee()
returns emp_ops.employees
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select e.* from emp_ops.employees e where e.user_id = auth.uid() limit 1;
$$;

create or replace function emp_ops.current_employee_id()
returns uuid
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select e.id from emp_ops.employees e where e.user_id = auth.uid() limit 1;
$$;

-- رتبة المستخدم الحالي. الموظف المعطَّل أو المؤرشف رتبته صفر ⇒ لا يستطيع فعل شيء.
create or replace function emp_ops.current_rank()
returns integer
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select coalesce((
    select r.rank
    from emp_ops.employees e
    join emp_ops.roles r on r.code = e.role
    where e.user_id = auth.uid() and e.status = 'active'
    limit 1
  ), 0);
$$;

create or replace function emp_ops.can_manage() returns boolean
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select emp_ops.current_rank() >= 50;
$$;

create or replace function emp_ops.is_admin() returns boolean
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select emp_ops.current_rank() >= 100;
$$;

-- تُستدعى في بداية كل دالة كتابة: تُرجع الموظف أو ترفض العملية برسالة عربية
create or replace function emp_ops.require_employee()
returns emp_ops.employees
language plpgsql stable security definer set search_path = emp_ops, pg_temp as $$
declare v emp_ops.employees;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولًا.' using errcode = 'EO401';
  end if;
  select * into v from emp_ops.employees where user_id = auth.uid() limit 1;
  if not found then
    raise exception 'حسابك غير مسجَّل كموظف في النظام. تواصل مع الإدارة.' using errcode = 'EO403';
  end if;
  if v.status = 'suspended' then
    raise exception 'حسابك موقوف حاليًا. تواصل مع الإدارة.' using errcode = 'EO403';
  end if;
  if v.status = 'archived' then
    raise exception 'حسابك مؤرشف ولا يمكنه استخدام النظام.' using errcode = 'EO403';
  end if;
  return v;
end $$;

create or replace function emp_ops.require_rank(p_min_rank integer)
returns emp_ops.employees
language plpgsql stable security definer set search_path = emp_ops, pg_temp as $$
declare v emp_ops.employees; v_rank integer;
begin
  v := emp_ops.require_employee();
  select r.rank into v_rank from emp_ops.roles r where r.code = v.role;
  if coalesce(v_rank, 0) < p_min_rank then
    raise exception 'ليست لديك صلاحية تنفيذ هذه العملية.' using errcode = 'EO403';
  end if;
  return v;
end $$;

-- هل يحق للمستخدم الحالي رؤية بيانات هذا الموظف؟
create or replace function emp_ops.can_view_employee(p_employee_id uuid)
returns boolean
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select emp_ops.can_manage() or p_employee_id = emp_ops.current_employee_id();
$$;

-- ─────────────────────────────────────────────────────────────
-- 2) تفعيل RLS على كل جدول
-- ─────────────────────────────────────────────────────────────
alter table emp_ops.roles                  enable row level security;
alter table emp_ops.activity_types         enable row level security;
alter table emp_ops.audit_actions          enable row level security;
alter table emp_ops.app_settings           enable row level security;
alter table emp_ops.teams                  enable row level security;
alter table emp_ops.employees              enable row level security;
alter table emp_ops.shifts                 enable row level security;
alter table emp_ops.shift_assignments      enable row level security;
alter table emp_ops.attendance_sessions    enable row level security;
alter table emp_ops.break_sessions         enable row level security;
alter table emp_ops.attendance_events      enable row level security;
alter table emp_ops.activity_sessions      enable row level security;
alter table emp_ops.activity_heartbeats    enable row level security;
alter table emp_ops.activity_events        enable row level security;
alter table emp_ops.activity_minutes       enable row level security;
alter table emp_ops.employee_runtime_state enable row level security;
alter table emp_ops.employee_daily_stats   enable row level security;
alter table emp_ops.audit_logs             enable row level security;

-- ─────────────────────────────────────────────────────────────
-- 3) سياسات القراءة فقط — لا توجد أي سياسة كتابة في النظام كله
-- ─────────────────────────────────────────────────────────────

-- كتالوجات عامة لكل موظف مسجَّل
drop policy if exists p_roles_read on emp_ops.roles;
create policy p_roles_read on emp_ops.roles for select to authenticated using (true);

drop policy if exists p_activity_types_read on emp_ops.activity_types;
create policy p_activity_types_read on emp_ops.activity_types for select to authenticated using (true);

drop policy if exists p_audit_actions_read on emp_ops.audit_actions;
create policy p_audit_actions_read on emp_ops.audit_actions for select to authenticated using (true);

drop policy if exists p_teams_read on emp_ops.teams;
create policy p_teams_read on emp_ops.teams for select to authenticated using (true);

drop policy if exists p_shifts_read on emp_ops.shifts;
create policy p_shifts_read on emp_ops.shifts for select to authenticated using (true);

-- الإعدادات: العامة للجميع، والداخلية للإدارة فقط
drop policy if exists p_settings_read on emp_ops.app_settings;
create policy p_settings_read on emp_ops.app_settings for select to authenticated
  using (is_public or emp_ops.can_manage());

-- الموظفون: كلٌّ يرى نفسه، والإدارة ترى الجميع
drop policy if exists p_employees_read on emp_ops.employees;
create policy p_employees_read on emp_ops.employees for select to authenticated
  using (id = emp_ops.current_employee_id() or emp_ops.can_manage());

drop policy if exists p_shift_assignments_read on emp_ops.shift_assignments;
create policy p_shift_assignments_read on emp_ops.shift_assignments for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

drop policy if exists p_attendance_read on emp_ops.attendance_sessions;
create policy p_attendance_read on emp_ops.attendance_sessions for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

drop policy if exists p_breaks_read on emp_ops.break_sessions;
create policy p_breaks_read on emp_ops.break_sessions for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

drop policy if exists p_attendance_events_read on emp_ops.attendance_events;
create policy p_attendance_events_read on emp_ops.attendance_events for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

drop policy if exists p_activity_sessions_read on emp_ops.activity_sessions;
create policy p_activity_sessions_read on emp_ops.activity_sessions for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

drop policy if exists p_heartbeats_read on emp_ops.activity_heartbeats;
create policy p_heartbeats_read on emp_ops.activity_heartbeats for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

drop policy if exists p_activity_events_read on emp_ops.activity_events;
create policy p_activity_events_read on emp_ops.activity_events for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

drop policy if exists p_activity_minutes_read on emp_ops.activity_minutes;
create policy p_activity_minutes_read on emp_ops.activity_minutes for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

drop policy if exists p_runtime_state_read on emp_ops.employee_runtime_state;
create policy p_runtime_state_read on emp_ops.employee_runtime_state for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

drop policy if exists p_daily_stats_read on emp_ops.employee_daily_stats;
create policy p_daily_stats_read on emp_ops.employee_daily_stats for select to authenticated
  using (emp_ops.can_view_employee(employee_id));

-- سجل التدقيق: الموظف يرى ما فعله هو فقط، والإدارة ترى كل شيء. لا أحد يعدّل أو يحذف.
drop policy if exists p_audit_read on emp_ops.audit_logs;
create policy p_audit_read on emp_ops.audit_logs for select to authenticated
  using (emp_ops.can_manage() or actor_employee_id = emp_ops.current_employee_id());

-- ─────────────────────────────────────────────────────────────
-- 4) منح الصلاحيات على مستوى Postgres — القراءة فقط
-- ─────────────────────────────────────────────────────────────
revoke all on all tables    in schema emp_ops from anon, authenticated;
revoke all on all sequences in schema emp_ops from anon, authenticated;
revoke all on all functions in schema emp_ops from anon, authenticated;

grant select on
  emp_ops.roles, emp_ops.activity_types, emp_ops.audit_actions, emp_ops.app_settings,
  emp_ops.teams, emp_ops.employees, emp_ops.shifts, emp_ops.shift_assignments,
  emp_ops.attendance_sessions, emp_ops.break_sessions, emp_ops.attendance_events,
  emp_ops.activity_sessions, emp_ops.activity_heartbeats, emp_ops.activity_events,
  emp_ops.activity_minutes, emp_ops.employee_runtime_state, emp_ops.employee_daily_stats,
  emp_ops.audit_logs
to authenticated;

-- الافتراضي لأي جدول يُنشأ لاحقًا: لا صلاحية لأي دور عميل
alter default privileges in schema emp_ops revoke all on tables from anon, authenticated;

-- anon لا يملك أي شيء على الإطلاق
revoke usage on schema emp_ops from anon;
