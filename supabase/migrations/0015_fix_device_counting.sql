-- 0015 — تصحيح عدّ الأجهزة
--
-- جلسة النشاط مفتاحها (شيفت، جهاز، تطبيق مصدر) — وهذا مقصود: نريد أن نعرف
-- أن الموظف نشط داخل مدعوم وداخل لوحة العمليات في آنٍ واحد.
-- لكن "عدد الأجهزة" يجب أن يُحسب بعدد المعرّفات المميزة للأجهزة لا بعدد الصفوف،
-- وإلا ظهر جهاز واحد يعمل على تطبيقين وكأنه جهازان.
-- (اكتشفه الاختبار ت10 في tests/01_attendance_activity_engine.sql)

create or replace function emp_ops.active_device_count(p_session_id uuid)
returns integer
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select count(distinct device_id)::integer
  from emp_ops.activity_sessions
  where attendance_session_id = p_session_id
    and ended_at is null
    and last_seen_at > now() - make_interval(secs => emp_ops.setting_num('offline_threshold_seconds', 180));
$$;

create or replace function public.eo_admin_multi_device()
returns table (employee_id uuid, full_name text, devices integer, session_id uuid)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees;
begin
  v_actor := emp_ops.require_rank(50);
  return query
    select e.id, e.full_name, count(distinct d.device_id)::integer, a.id
    from emp_ops.attendance_sessions a
    join emp_ops.employees e on e.id = a.employee_id
    join emp_ops.activity_sessions d on d.attendance_session_id = a.id
    where a.status = 'open' and d.ended_at is null
      and d.last_seen_at > now() - make_interval(secs => emp_ops.setting_num('offline_threshold_seconds', 180))
    group by e.id, e.full_name, a.id
    having count(distinct d.device_id) > 1;
end $$;

-- تحديث المستهلكين ليستخدموا العدّاد الصحيح
-- (employee_status_full و eo_admin_employees_live يُعاد تعريفهما بالكامل أدناه)

create or replace function emp_ops.employee_status_json(p_employee_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = emp_ops, pg_temp as $$
declare
  v_emp      emp_ops.employees;
  v_session  emp_ops.attendance_sessions;
  v_break    emp_ops.break_sessions;
  v_state    emp_ops.employee_runtime_state;
  v_shift    emp_ops.shifts;
  v_date     date;
  v_totals   record;
  v_presence text;
  v_sessions_today integer;
  v_devices  integer;
begin
  select * into v_emp from emp_ops.employees where id = p_employee_id;
  if not found then
    return jsonb_build_object('error', 'الموظف غير موجود');
  end if;

  v_date := emp_ops.work_date_of(p_employee_id, now());

  select * into v_session from emp_ops.attendance_sessions
   where employee_id = p_employee_id and status = 'open' limit 1;

  if v_session.id is not null then
    select * into v_break from emp_ops.break_sessions
     where attendance_session_id = v_session.id and status = 'open' limit 1;
    v_devices := emp_ops.active_device_count(v_session.id);
  else
    v_devices := 0;
  end if;

  select * into v_state from emp_ops.employee_runtime_state where employee_id = p_employee_id;

  select count(*)::integer into v_sessions_today from emp_ops.attendance_sessions
   where employee_id = p_employee_id and work_date = v_date;

  select * into v_totals from emp_ops.live_totals(p_employee_id, v_date);

  v_presence := emp_ops.compute_presence(
    v_session.id is not null, v_break.id is not null,
    v_state.last_interaction_at, v_state.last_heartbeat_at, v_sessions_today, now()
  );

  v_shift := emp_ops.shift_for(p_employee_id, v_date);

  return jsonb_build_object(
    'server_time', now(),
    'work_date',   v_date,
    'employee', jsonb_build_object(
      'id', v_emp.id, 'full_name', v_emp.full_name, 'email', v_emp.email,
      'employee_code', v_emp.employee_code, 'role', v_emp.role,
      'role_label', (select name_ar from emp_ops.roles where code = v_emp.role),
      'rank', (select rank from emp_ops.roles where code = v_emp.role),
      'status', v_emp.status, 'timezone', emp_ops.employee_timezone(p_employee_id),
      'team', (select name_ar from emp_ops.teams where id = v_emp.team_id)
    ),
    'session', case when v_session.id is null then null else jsonb_build_object(
      'id', v_session.id, 'started_at', v_session.started_at,
      'late_seconds', v_session.late_seconds, 'device_id', v_session.start_device_id,
      'active_devices', v_devices
    ) end,
    'break', case when v_break.id is null then null else jsonb_build_object(
      'id', v_break.id, 'started_at', v_break.started_at, 'break_type', v_break.break_type
    ) end,
    'shift', case when v_shift.id is null then null else jsonb_build_object(
      'id', v_shift.id, 'name_ar', v_shift.name_ar,
      'start_time', v_shift.start_time, 'end_time', v_shift.end_time,
      'grace_minutes', v_shift.grace_minutes, 'work_days', v_shift.work_days
    ) end,
    'presence', v_presence,
    'presence_label', emp_ops.presence_label(v_presence),
    'last_interaction_at', v_state.last_interaction_at,
    'last_heartbeat_at',   v_state.last_heartbeat_at,
    'totals', jsonb_build_object(
      'shift_seconds',  coalesce(v_totals.shift_seconds, 0),
      'break_seconds',  coalesce(v_totals.break_seconds, 0),
      'active_seconds', coalesce(v_totals.active_seconds, 0),
      'idle_seconds',   coalesce(v_totals.idle_seconds, 0),
      'active_pct',     v_totals.active_pct,
      'sessions_count', coalesce(v_totals.sessions_count, 0)
    ),
    'settings', jsonb_build_object(
      'idle_threshold_seconds',     emp_ops.setting_num('idle_threshold_seconds', 300),
      'heartbeat_interval_seconds', emp_ops.setting_num('heartbeat_interval_seconds', 60),
      'offline_threshold_seconds',  emp_ops.setting_num('offline_threshold_seconds', 180),
      'timezone',                   emp_ops.system_timezone()
    )
  );
end $$;

-- ─────────────────────────────────────────────────────────────
-- الواجهة العامة (RPC)
-- ─────────────────────────────────────────────────────────────

create or replace function public.eo_admin_employees_live()
returns table (
  employee_id uuid, full_name text, employee_code text, email text, role text, team text,
  presence text, presence_label text, session_id uuid, started_at timestamptz,
  shift_seconds integer, active_seconds integer, idle_seconds integer, break_seconds integer,
  active_pct numeric, late_seconds integer, last_interaction_at timestamptz,
  last_heartbeat_at timestamptz, active_devices integer, status text
)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_now timestamptz := now();
begin
  v_actor := emp_ops.require_rank(50);
  return query
    with base as (
      select e.id, e.full_name, e.employee_code, e.email, e.role, e.status,
             (select tm.name_ar from emp_ops.teams tm where tm.id = e.team_id) as team,
             emp_ops.work_date_of(e.id, v_now) as work_date,
             (select a.id from emp_ops.attendance_sessions a
               where a.employee_id = e.id and a.status = 'open' limit 1) as open_session,
             (select a.started_at from emp_ops.attendance_sessions a
               where a.employee_id = e.id and a.status = 'open' limit 1) as open_started_at,
             st.last_interaction_at, st.last_heartbeat_at
      from emp_ops.employees e
      left join emp_ops.employee_runtime_state st on st.employee_id = e.id
      where e.status <> 'archived'
    ),
    withp as (
      select b.*,
             emp_ops.compute_presence(
               b.open_session is not null,
               exists (select 1 from emp_ops.break_sessions bs
                        where bs.attendance_session_id = b.open_session and bs.status = 'open'),
               b.last_interaction_at, b.last_heartbeat_at,
               (select count(*)::integer from emp_ops.attendance_sessions a
                 where a.employee_id = b.id and a.work_date = b.work_date),
               v_now) as presence
      from base b
    )
    select b.id, b.full_name, b.employee_code, b.email, b.role, b.team,
           b.presence, emp_ops.presence_label(b.presence),
           b.open_session, b.open_started_at,
           lt.shift_seconds, lt.active_seconds, lt.idle_seconds, lt.break_seconds, lt.active_pct,
           coalesce((select max(a.late_seconds) from emp_ops.attendance_sessions a
                      where a.employee_id = b.id and a.work_date = b.work_date), 0),
           b.last_interaction_at, b.last_heartbeat_at,
           coalesce(emp_ops.active_device_count(b.open_session), 0),
           b.status
    from withp b
    cross join lateral emp_ops.live_totals(b.id, b.work_date) lt
    order by
      case b.presence
        when 'active' then 1 when 'idle' then 2 when 'break' then 3
        when 'disconnected' then 4 when 'ended' then 5 else 6 end,
      b.full_name;
end $$;
