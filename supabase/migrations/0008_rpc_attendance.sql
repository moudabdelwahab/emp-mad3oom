-- 0008 — واجهة الحضور (RPC). كل الأوقات من ساعة الخادم، وكل عملية مُدقَّقة.

-- ترحيل احتساب النشاط حتى اللحظة الحالية (يُستدعى قبل أي تغيير حالة)
create or replace function emp_ops.flush_activity(
  p_employee_id  uuid,
  p_session_id   uuid,
  p_source       text default 'emp_ops',
  p_interactions integer default 0
) returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_state emp_ops.employee_runtime_state;
  v_idle  numeric;
  v_from  timestamptz;
  v_to    timestamptz;
begin
  select * into v_state from emp_ops.employee_runtime_state
   where employee_id = p_employee_id for update;
  if not found or v_state.last_interaction_at is null then
    return 0;
  end if;

  v_idle := emp_ops.setting_num('idle_threshold_seconds', 300);
  -- النشاط يُحتسب من آخر لحظة محسوبة وحتى الآن، بشرط ألا يتجاوز نافذة الخمول
  -- الممتدة من آخر تفاعل حقيقي. لا يوجد أي مدخل من العميل في هذه المعادلة.
  v_from := coalesce(v_state.marked_until, v_state.last_interaction_at);
  v_to   := least(now(), v_state.last_interaction_at + make_interval(secs => v_idle));

  if v_to <= v_from then
    return 0;
  end if;

  update emp_ops.employee_runtime_state
     set marked_until = greatest(coalesce(marked_until, v_to), v_to), updated_at = now()
   where employee_id = p_employee_id;

  return emp_ops.mark_active_minutes(p_employee_id, p_session_id, v_from, v_to, p_source, p_interactions);
end $$;

-- ─────────────────────────────────────────────────────────────
-- الحالة الكاملة للموظف — المصدر الوحيد لكل رقم يظهر في لوحة الموظف
-- ─────────────────────────────────────────────────────────────
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
    select count(*)::integer into v_devices from emp_ops.activity_sessions
     where attendance_session_id = v_session.id and ended_at is null
       and last_seen_at > now() - make_interval(secs => emp_ops.setting_num('offline_threshold_seconds', 180));
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

create or replace function public.eo_me()
returns jsonb
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v emp_ops.employees;
begin
  v := emp_ops.require_employee();
  return emp_ops.employee_status_json(v.id);
end $$;

create or replace function public.eo_start_shift(p_client jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_emp     emp_ops.employees;
  v_session emp_ops.attendance_sessions;
  v_shift   emp_ops.shifts;
  v_date    date;
  v_sched   timestamptz;
  v_late    integer := 0;
  v_device  text;
begin
  v_emp  := emp_ops.require_employee();
  v_date := emp_ops.work_date_of(v_emp.id, now());
  v_device := nullif(btrim(coalesce(p_client ->> 'device_id', '')), '');

  v_shift := emp_ops.shift_for(v_emp.id, v_date);
  if v_shift.id is not null then
    v_sched := (v_date + v_shift.start_time) at time zone emp_ops.employee_timezone(v_emp.id);
    v_late  := greatest(0, floor(extract(epoch from
                 (now() - (v_sched + make_interval(mins => v_shift.grace_minutes)))))::integer);
  end if;

  begin
    insert into emp_ops.attendance_sessions
      (employee_id, work_date, shift_id, scheduled_start, late_seconds, start_device_id, client_meta)
    values
      (v_emp.id, v_date, v_shift.id, v_sched, v_late, v_device,
       jsonb_strip_nulls(jsonb_build_object(
         'user_agent', p_client ->> 'user_agent',
         'platform',   p_client ->> 'platform',
         'device_id',  v_device,
         'client_time', p_client ->> 'client_time'
       )))
    returning * into v_session;
  exception when unique_violation then
    raise exception 'لديك شيفت مفتوح بالفعل. أنهِ الشيفت الحالي قبل بدء شيفت جديد.' using errcode = 'EO001';
  end;

  insert into emp_ops.employee_runtime_state
    (employee_id, attendance_session_id, last_interaction_at, last_heartbeat_at, marked_until, presence, last_event_type)
  values (v_emp.id, v_session.id, now(), now(), now(), 'active', 'shift_start')
  on conflict (employee_id) do update set
    attendance_session_id = excluded.attendance_session_id,
    last_interaction_at   = excluded.last_interaction_at,
    last_heartbeat_at     = excluded.last_heartbeat_at,
    marked_until          = excluded.marked_until,
    presence              = 'active',
    last_event_type       = 'shift_start',
    updated_at            = now();

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, event_type, actor_employee_id, metadata)
  values (v_emp.id, v_session.id, 'shift_start', v_emp.id,
          jsonb_build_object('late_seconds', v_late, 'device_id', v_device));

  perform emp_ops.audit(v_emp, 'shift.start', 'attendance_session', v_session.id::text, v_emp.full_name,
                        jsonb_build_object('late_seconds', v_late, 'work_date', v_date));
  perform emp_ops.recompute_daily_stats(v_emp.id, v_date);

  return emp_ops.employee_status_json(v_emp.id);
end $$;

create or replace function public.eo_end_shift(p_note text default null)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_emp     emp_ops.employees;
  v_session emp_ops.attendance_sessions;
  v_break   emp_ops.break_sessions;
begin
  v_emp := emp_ops.require_employee();

  select * into v_session from emp_ops.attendance_sessions
   where employee_id = v_emp.id and status = 'open' for update;
  if not found then
    raise exception 'لا يوجد شيفت مفتوح لإنهائه.' using errcode = 'EO002';
  end if;

  -- إغلاق أي استراحة مفتوحة تلقائيًا قبل إنهاء الشيفت
  update emp_ops.break_sessions
     set ended_at = now(), status = 'auto_closed'
   where attendance_session_id = v_session.id and status = 'open'
  returning * into v_break;

  if v_break.id is not null then
    insert into emp_ops.attendance_events (employee_id, attendance_session_id, break_session_id, event_type, actor_employee_id)
    values (v_emp.id, v_session.id, v_break.id, 'break_auto_close', v_emp.id);
  end if;

  -- ترحيل آخر دقائق النشاط قبل الإغلاق
  perform emp_ops.flush_activity(v_emp.id, v_session.id, 'emp_ops', 0);

  update emp_ops.attendance_sessions
     set ended_at = now(), status = 'closed',
         end_reason = coalesce(nullif(btrim(p_note), ''), 'إنهاء بواسطة الموظف'),
         ended_by_employee_id = v_emp.id
   where id = v_session.id
  returning * into v_session;

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, event_type, actor_employee_id, metadata)
  values (v_emp.id, v_session.id, 'shift_end', v_emp.id,
          jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_session.started_at, v_session.ended_at)));

  update emp_ops.activity_sessions
     set ended_at = now() where attendance_session_id = v_session.id and ended_at is null;

  update emp_ops.employee_runtime_state
     set attendance_session_id = null, presence = 'offline', last_event_type = 'shift_end', updated_at = now()
   where employee_id = v_emp.id;

  perform emp_ops.audit(v_emp, 'shift.end', 'attendance_session', v_session.id::text, v_emp.full_name,
    jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_session.started_at, v_session.ended_at)));
  perform emp_ops.recompute_daily_stats(v_emp.id, v_session.work_date);

  return emp_ops.employee_status_json(v_emp.id);
end $$;

create or replace function public.eo_start_break(p_break_type text default 'general', p_note text default null)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_emp     emp_ops.employees;
  v_session emp_ops.attendance_sessions;
  v_break   emp_ops.break_sessions;
begin
  v_emp := emp_ops.require_employee();

  select * into v_session from emp_ops.attendance_sessions
   where employee_id = v_emp.id and status = 'open' for update;
  if not found then
    raise exception 'لا يمكن بدء استراحة بدون شيفت مفتوح.' using errcode = 'EO003';
  end if;

  -- ترحيل النشاط حتى لحظة بدء الاستراحة، ثم إيقاف الاحتساب
  perform emp_ops.flush_activity(v_emp.id, v_session.id, 'emp_ops', 0);

  begin
    insert into emp_ops.break_sessions (attendance_session_id, employee_id, break_type, note)
    values (v_session.id, v_emp.id, coalesce(nullif(btrim(p_break_type), ''), 'general'), nullif(btrim(p_note), ''))
    returning * into v_break;
  exception when unique_violation then
    raise exception 'لديك استراحة مفتوحة بالفعل.' using errcode = 'EO004';
  end;

  update emp_ops.employee_runtime_state
     set marked_until = greatest(coalesce(marked_until, now()), now()),
         presence = 'break', last_event_type = 'break_start', updated_at = now()
   where employee_id = v_emp.id;

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, break_session_id, event_type, actor_employee_id, metadata)
  values (v_emp.id, v_session.id, v_break.id, 'break_start', v_emp.id, jsonb_build_object('break_type', v_break.break_type));

  perform emp_ops.audit(v_emp, 'break.start', 'break_session', v_break.id::text, v_emp.full_name,
                        jsonb_build_object('break_type', v_break.break_type));

  return emp_ops.employee_status_json(v_emp.id);
end $$;

create or replace function public.eo_end_break()
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_emp   emp_ops.employees;
  v_break emp_ops.break_sessions;
begin
  v_emp := emp_ops.require_employee();

  select * into v_break from emp_ops.break_sessions
   where employee_id = v_emp.id and status = 'open' for update;
  if not found then
    raise exception 'لا توجد استراحة مفتوحة لإنهائها.' using errcode = 'EO005';
  end if;

  update emp_ops.break_sessions
     set ended_at = now(), status = 'closed'
   where id = v_break.id
  returning * into v_break;

  -- إنهاء الاستراحة تفاعل حقيقي: تُستأنف نافذة النشاط من الآن
  update emp_ops.employee_runtime_state
     set last_interaction_at = now(),
         marked_until = greatest(coalesce(marked_until, now()), now()),
         presence = 'active', last_event_type = 'break_end', updated_at = now()
   where employee_id = v_emp.id;

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, break_session_id, event_type, actor_employee_id, metadata)
  values (v_emp.id, v_break.attendance_session_id, v_break.id, 'break_end', v_emp.id,
          jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_break.started_at, v_break.ended_at)));

  perform emp_ops.audit(v_emp, 'break.end', 'break_session', v_break.id::text, v_emp.full_name,
    jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_break.started_at, v_break.ended_at)));

  return emp_ops.employee_status_json(v_emp.id);
end $$;

-- تسجيل أحداث المصادقة في سجل التدقيق
create or replace function public.eo_log_auth(p_event text)
returns boolean
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_emp emp_ops.employees;
begin
  if p_event not in ('login', 'logout') then
    raise exception 'حدث غير معروف.' using errcode = 'EO400';
  end if;
  v_emp := emp_ops.require_employee();
  perform emp_ops.audit(v_emp, 'auth.' || p_event, 'employee', v_emp.id::text, v_emp.full_name, '{}'::jsonb);
  return true;
end $$;

-- منح التنفيذ للموظفين المسجَّلين فقط
revoke all on function public.eo_me()                          from public, anon;
revoke all on function public.eo_start_shift(jsonb)            from public, anon;
revoke all on function public.eo_end_shift(text)               from public, anon;
revoke all on function public.eo_start_break(text, text)       from public, anon;
revoke all on function public.eo_end_break()                   from public, anon;
revoke all on function public.eo_log_auth(text)                from public, anon;

grant execute on function public.eo_me()                       to authenticated;
grant execute on function public.eo_start_shift(jsonb)         to authenticated;
grant execute on function public.eo_end_shift(text)            to authenticated;
grant execute on function public.eo_start_break(text, text)    to authenticated;
grant execute on function public.eo_end_break()                to authenticated;
grant execute on function public.eo_log_auth(text)             to authenticated;
