-- 0010 — لوحات القراءة: الخط الزمني، لوحة الموظف، لوحة الإدارة
-- كل رقم هنا محسوب من الجداول الخام لحظة الطلب.

-- ─────────────────────────────────────────────────────────────
-- الخط الزمني اليومي: أحداث الحضور + فترات النشاط + فترات الخمول + الاستراحات
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.timeline(p_employee_id uuid, p_date date)
returns table (at timestamptz, until timestamptz, kind text, label text, seconds integer, meta jsonb)
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  with sessions as (
    select id, started_at, coalesce(ended_at, now()) as ended_at, status, late_seconds
    from emp_ops.attendance_sessions
    where employee_id = p_employee_id and work_date = p_date
  ),
  mins as (
    select minute_start, seconds,
           minute_start - (row_number() over (order by minute_start)) * interval '1 minute' as grp
    from emp_ops.activity_minutes
    where employee_id = p_employee_id and work_date = p_date
  ),
  active_seg as (
    select min(minute_start) as from_ts,
           max(minute_start) + interval '1 minute' as to_ts,
           sum(seconds)::integer as secs
    from mins group by grp
  ),
  breaks as (
    select b.id, b.started_at as from_ts, coalesce(b.ended_at, now()) as to_ts, b.break_type,
           b.attendance_session_id
    from emp_ops.break_sessions b
    join sessions s on s.id = b.attendance_session_id
  ),
  -- كل الفترات المشغولة (نشاط أو استراحة) منسوبة لجلستها
  busy as (
    select s.id as session_id, greatest(a.from_ts, s.started_at) as from_ts,
           least(a.to_ts, s.ended_at) as to_ts, 'active' as kind
    from active_seg a join sessions s
      on a.from_ts < s.ended_at and a.to_ts > s.started_at
    union all
    select b.attendance_session_id, b.from_ts, b.to_ts, 'break' from breaks b
  ),
  ordered as (
    select session_id, from_ts, to_ts, kind,
           lag(to_ts) over (partition by session_id order by from_ts) as prev_end,
           row_number() over (partition by session_id order by from_ts) as rn,
           count(*) over (partition by session_id) as total
    from busy
  ),
  idle_gaps as (
    -- فجوة بين فترتين مشغولتين
    select o.session_id, o.prev_end as from_ts, o.from_ts as to_ts
    from ordered o where o.prev_end is not null and o.from_ts > o.prev_end
    union all
    -- فجوة من بداية الشيفت حتى أول نشاط
    select s.id, s.started_at, o.from_ts
    from sessions s join ordered o on o.session_id = s.id and o.rn = 1
    where o.from_ts > s.started_at
    union all
    -- فجوة من آخر نشاط حتى نهاية الشيفت
    select s.id, o.to_ts, s.ended_at
    from sessions s join ordered o on o.session_id = s.id and o.rn = o.total
    where s.ended_at > o.to_ts
    union all
    -- شيفت بلا أي نشاط على الإطلاق
    select s.id, s.started_at, s.ended_at
    from sessions s where not exists (select 1 from busy b where b.session_id = s.id)
  )
  select * from (
    select ae.occurred_at as at, null::timestamptz as until, ae.event_type as kind,
           case ae.event_type
             when 'shift_start'      then 'بدأ العمل'
             when 'shift_end'        then 'أنهى العمل'
             when 'shift_auto_close' then 'أُغلق الشيفت تلقائيًا'
             when 'shift_force_end'  then 'أنهت الإدارة الشيفت'
             when 'admin_force_end'  then 'أنهت الإدارة الشيفت'
             when 'break_start'      then 'بدأ استراحة'
             when 'break_end'        then 'أنهى الاستراحة'
             when 'break_auto_close' then 'أُغلقت الاستراحة تلقائيًا'
             when 'admin_adjust'     then 'تعديل إداري على السجل'
             else ae.event_type end as label,
           null::integer as seconds, ae.metadata as meta
    from emp_ops.attendance_events ae
    join sessions s on s.id = ae.attendance_session_id
    union all
    select b.from_ts, b.to_ts, 'active_period', 'فترة نشاط',
           greatest(0, floor(extract(epoch from (b.to_ts - b.from_ts))))::integer, '{}'::jsonb
    from busy b where b.kind = 'active' and b.to_ts > b.from_ts
    union all
    select b.from_ts, b.to_ts, 'break_period', 'فترة استراحة',
           greatest(0, floor(extract(epoch from (b.to_ts - b.from_ts))))::integer, '{}'::jsonb
    from busy b where b.kind = 'break' and b.to_ts > b.from_ts
    union all
    select g.from_ts, g.to_ts, 'idle_period', 'فترة خمول',
           greatest(0, floor(extract(epoch from (g.to_ts - g.from_ts))))::integer, '{}'::jsonb
    from idle_gaps g where g.to_ts > g.from_ts
  ) t
  order by at, kind;
$$;

-- ─────────────────────────────────────────────────────────────
-- واجهات الموظف
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_my_timeline(p_date date default null)
returns table (at timestamptz, until timestamptz, kind text, label text, seconds integer, meta jsonb)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v emp_ops.employees; v_date date;
begin
  v := emp_ops.require_employee();
  v_date := coalesce(p_date, emp_ops.work_date_of(v.id, now()));
  return query select * from emp_ops.timeline(v.id, v_date);
end $$;

create or replace function public.eo_my_history(p_from date, p_to date)
returns table (
  work_date date, first_start_at timestamptz, last_end_at timestamptz,
  shift_seconds integer, break_seconds integer, active_seconds integer,
  idle_seconds integer, active_pct numeric, late_seconds integer,
  is_late boolean, is_absent boolean, sessions_count integer
)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v emp_ops.employees;
begin
  v := emp_ops.require_employee();
  if p_to < p_from or (p_to - p_from) > 400 then
    raise exception 'نطاق التاريخ غير صالح (الحد الأقصى 400 يوم).' using errcode = 'EO400';
  end if;
  return query
    select s.work_date, s.first_start_at, s.last_end_at, s.shift_seconds, s.break_seconds,
           s.active_seconds, s.idle_seconds, s.active_pct, s.late_seconds,
           s.is_late, s.is_absent, s.sessions_count
    from emp_ops.employee_daily_stats s
    where s.employee_id = v.id and s.work_date between p_from and p_to
    order by s.work_date desc;
end $$;

create or replace function public.eo_my_activity(p_date date default null, p_limit integer default 100)
returns table (occurred_at timestamptz, event_type text, event_label text,
               entity_type text, entity_id text, source_app text, metadata jsonb)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v emp_ops.employees; v_date date;
begin
  v := emp_ops.require_employee();
  v_date := coalesce(p_date, emp_ops.work_date_of(v.id, now()));
  return query
    select ae.occurred_at, ae.event_type, t.name_ar, ae.entity_type, ae.entity_id, ae.source_app, ae.metadata
    from emp_ops.activity_events ae
    join emp_ops.activity_types t on t.code = ae.event_type
    join emp_ops.attendance_sessions s on s.id = ae.attendance_session_id
    where ae.employee_id = v.id and s.work_date = v_date
    order by ae.occurred_at desc
    limit greatest(1, least(coalesce(p_limit, 100), 500));
end $$;

-- ─────────────────────────────────────────────────────────────
-- واجهات الإدارة (القراءة)
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_admin_overview()
returns jsonb
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_actor emp_ops.employees;
  v_today date;
  v_now   timestamptz := now();
  v_live  jsonb;
  v_totals jsonb;
begin
  v_actor := emp_ops.require_rank(50);
  v_today := (v_now at time zone emp_ops.system_timezone())::date;

  with base as (
    select e.id,
           (select a.id from emp_ops.attendance_sessions a
             where a.employee_id = e.id and a.status = 'open' limit 1) as open_session,
           (select count(*)::integer from emp_ops.attendance_sessions a
             where a.employee_id = e.id and a.work_date = v_today) as sessions_today,
           st.last_interaction_at, st.last_heartbeat_at
    from emp_ops.employees e
    left join emp_ops.employee_runtime_state st on st.employee_id = e.id
    where e.status = 'active'
  ),
  p as (
    select b.id,
           emp_ops.compute_presence(
             b.open_session is not null,
             exists (select 1 from emp_ops.break_sessions bs
                      where bs.attendance_session_id = b.open_session and bs.status = 'open'),
             b.last_interaction_at, b.last_heartbeat_at, b.sessions_today, v_now) as presence
    from base b
  )
  select jsonb_build_object(
    'total_employees',  (select count(*) from base),
    'working',          count(*) filter (where presence in ('active','idle','break','disconnected')),
    'active',           count(*) filter (where presence = 'active'),
    'idle',             count(*) filter (where presence = 'idle'),
    'on_break',         count(*) filter (where presence = 'break'),
    'disconnected',     count(*) filter (where presence = 'disconnected'),
    'ended',            count(*) filter (where presence = 'ended'),
    'not_started',      count(*) filter (where presence = 'not_started')
  ) into v_live from p;

  with t as (
    select a.employee_id,
           coalesce(sum(emp_ops.session_seconds(a.started_at, a.ended_at)), 0)::bigint as shift_seconds,
           count(*)::integer as sessions
    from emp_ops.attendance_sessions a
    where a.work_date = v_today group by a.employee_id
  ),
  b as (
    select coalesce(sum(emp_ops.session_seconds(bs.started_at, bs.ended_at)), 0)::bigint as break_seconds
    from emp_ops.break_sessions bs
    join emp_ops.attendance_sessions a on a.id = bs.attendance_session_id
    where a.work_date = v_today
  ),
  m as (
    select coalesce(sum(seconds), 0)::bigint as active_seconds
    from emp_ops.activity_minutes where work_date = v_today
  ),
  l as (
    select count(*)::integer as late_count, coalesce(sum(late_seconds), 0)::bigint as late_seconds
    from emp_ops.attendance_sessions where work_date = v_today and late_seconds > 0
  ),
  ab as (
    select count(*)::integer as absent_count from emp_ops.employee_daily_stats
    where work_date = v_today and is_absent
  )
  select jsonb_build_object(
    'shift_seconds',  coalesce((select sum(shift_seconds) from t), 0),
    'sessions_count', coalesce((select sum(sessions) from t), 0),
    'break_seconds',  (select break_seconds from b),
    'active_seconds', (select active_seconds from m),
    'idle_seconds',   greatest(coalesce((select sum(shift_seconds) from t), 0)
                               - (select break_seconds from b) - (select active_seconds from m), 0),
    'avg_active_pct', case
        when coalesce((select sum(shift_seconds) from t), 0) - (select break_seconds from b) > 0
        then round(((select active_seconds from m)::numeric
                    / (coalesce((select sum(shift_seconds) from t), 0) - (select break_seconds from b))) * 100, 2)
        else null end,
    'late_count',     (select late_count from l),
    'absent_count',   (select absent_count from ab),
    'employees_worked', (select count(*) from t)
  ) into v_totals;

  return jsonb_build_object(
    'server_time', v_now, 'work_date', v_today,
    'timezone', emp_ops.system_timezone(),
    'live', v_live, 'today', v_totals
  );
end $$;

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
           (select count(*)::integer from emp_ops.activity_sessions acs
             where acs.attendance_session_id = b.open_session and acs.ended_at is null
               and acs.last_seen_at > v_now - make_interval(secs => emp_ops.setting_num('offline_threshold_seconds', 180))),
           b.status
    from withp b
    cross join lateral emp_ops.live_totals(b.id, b.work_date) lt
    order by
      case b.presence
        when 'active' then 1 when 'idle' then 2 when 'break' then 3
        when 'disconnected' then 4 when 'ended' then 5 else 6 end,
      b.full_name;
end $$;

create or replace function public.eo_admin_employee_detail(p_employee_id uuid, p_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_actor emp_ops.employees;
  v_date  date;
  v_status jsonb;
  v_sessions jsonb;
  v_breaks jsonb;
  v_devices jsonb;
begin
  v_actor := emp_ops.require_rank(50);
  if not exists (select 1 from emp_ops.employees where id = p_employee_id) then
    raise exception 'الموظف غير موجود.' using errcode = 'EO404';
  end if;
  v_date := coalesce(p_date, emp_ops.work_date_of(p_employee_id, now()));

  v_status := emp_ops.employee_status_json(p_employee_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'started_at', a.started_at, 'ended_at', a.ended_at,
           'status', a.status, 'late_seconds', a.late_seconds,
           'duration_seconds', emp_ops.session_seconds(a.started_at, a.ended_at),
           'end_reason', a.end_reason, 'adjusted', a.adjusted
         ) order by a.started_at), '[]'::jsonb) into v_sessions
  from emp_ops.attendance_sessions a
  where a.employee_id = p_employee_id and a.work_date = v_date;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'started_at', b.started_at, 'ended_at', b.ended_at,
           'status', b.status, 'break_type', b.break_type,
           'duration_seconds', emp_ops.session_seconds(b.started_at, b.ended_at)
         ) order by b.started_at), '[]'::jsonb) into v_breaks
  from emp_ops.break_sessions b
  join emp_ops.attendance_sessions a on a.id = b.attendance_session_id
  where a.employee_id = p_employee_id and a.work_date = v_date;

  select coalesce(jsonb_agg(jsonb_build_object(
           'device_id', d.device_id, 'source_app', d.source_app,
           'started_at', d.started_at, 'last_seen_at', d.last_seen_at,
           'ended_at', d.ended_at, 'platform', d.platform, 'ip', d.ip
         ) order by d.last_seen_at desc), '[]'::jsonb) into v_devices
  from emp_ops.activity_sessions d
  join emp_ops.attendance_sessions a on a.id = d.attendance_session_id
  where a.employee_id = p_employee_id and a.work_date = v_date;

  return v_status
    || jsonb_build_object(
        'requested_date', v_date,
        'day_totals', (select to_jsonb(t) from emp_ops.live_totals(p_employee_id, v_date) t),
        'sessions', v_sessions, 'breaks', v_breaks, 'devices', v_devices);
end $$;

create or replace function public.eo_admin_employee_timeline(p_employee_id uuid, p_date date default null)
returns table (at timestamptz, until timestamptz, kind text, label text, seconds integer, meta jsonb)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_date date;
begin
  v_actor := emp_ops.require_rank(50);
  v_date := coalesce(p_date, emp_ops.work_date_of(p_employee_id, now()));
  return query select * from emp_ops.timeline(p_employee_id, v_date);
end $$;

create or replace function public.eo_admin_employee_activity(
  p_employee_id uuid, p_date date default null, p_limit integer default 200)
returns table (occurred_at timestamptz, event_type text, event_label text,
               entity_type text, entity_id text, source_app text, metadata jsonb)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_date date;
begin
  v_actor := emp_ops.require_rank(50);
  v_date := coalesce(p_date, emp_ops.work_date_of(p_employee_id, now()));
  return query
    select ae.occurred_at, ae.event_type, t.name_ar, ae.entity_type, ae.entity_id, ae.source_app, ae.metadata
    from emp_ops.activity_events ae
    join emp_ops.activity_types t on t.code = ae.event_type
    join emp_ops.attendance_sessions s on s.id = ae.attendance_session_id
    where ae.employee_id = p_employee_id and s.work_date = v_date
    order by ae.occurred_at desc
    limit greatest(1, least(coalesce(p_limit, 200), 1000));
end $$;

create or replace function public.eo_admin_employee_history(p_employee_id uuid, p_from date, p_to date)
returns table (
  work_date date, first_start_at timestamptz, last_end_at timestamptz,
  shift_seconds integer, break_seconds integer, active_seconds integer,
  idle_seconds integer, active_pct numeric, late_seconds integer,
  is_late boolean, is_absent boolean, sessions_count integer
)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees;
begin
  v_actor := emp_ops.require_rank(50);
  if p_to < p_from or (p_to - p_from) > 400 then
    raise exception 'نطاق التاريخ غير صالح (الحد الأقصى 400 يوم).' using errcode = 'EO400';
  end if;
  return query
    select s.work_date, s.first_start_at, s.last_end_at, s.shift_seconds, s.break_seconds,
           s.active_seconds, s.idle_seconds, s.active_pct, s.late_seconds,
           s.is_late, s.is_absent, s.sessions_count
    from emp_ops.employee_daily_stats s
    where s.employee_id = p_employee_id and s.work_date between p_from and p_to
    order by s.work_date desc;
end $$;

-- الموظفون الذين لديهم أكثر من جهاز نشط في نفس الوقت
create or replace function public.eo_admin_multi_device()
returns table (employee_id uuid, full_name text, devices integer, session_id uuid)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees;
begin
  v_actor := emp_ops.require_rank(50);
  return query
    select e.id, e.full_name, count(*)::integer, a.id
    from emp_ops.attendance_sessions a
    join emp_ops.employees e on e.id = a.employee_id
    join emp_ops.activity_sessions d on d.attendance_session_id = a.id
    where a.status = 'open' and d.ended_at is null
      and d.last_seen_at > now() - make_interval(secs => emp_ops.setting_num('offline_threshold_seconds', 180))
    group by e.id, e.full_name, a.id
    having count(*) > 1;
end $$;

revoke all on function public.eo_my_timeline(date)                       from public, anon;
revoke all on function public.eo_my_history(date, date)                  from public, anon;
revoke all on function public.eo_my_activity(date, integer)              from public, anon;
revoke all on function public.eo_admin_overview()                        from public, anon;
revoke all on function public.eo_admin_employees_live()                  from public, anon;
revoke all on function public.eo_admin_employee_detail(uuid, date)       from public, anon;
revoke all on function public.eo_admin_employee_timeline(uuid, date)     from public, anon;
revoke all on function public.eo_admin_employee_activity(uuid, date, integer) from public, anon;
revoke all on function public.eo_admin_employee_history(uuid, date, date) from public, anon;
revoke all on function public.eo_admin_multi_device()                    from public, anon;

grant execute on function public.eo_my_timeline(date)                       to authenticated;
grant execute on function public.eo_my_history(date, date)                  to authenticated;
grant execute on function public.eo_my_activity(date, integer)              to authenticated;
grant execute on function public.eo_admin_overview()                        to authenticated;
grant execute on function public.eo_admin_employees_live()                  to authenticated;
grant execute on function public.eo_admin_employee_detail(uuid, date)       to authenticated;
grant execute on function public.eo_admin_employee_timeline(uuid, date)     to authenticated;
grant execute on function public.eo_admin_employee_activity(uuid, date, integer) to authenticated;
grant execute on function public.eo_admin_employee_history(uuid, date, date) to authenticated;
grant execute on function public.eo_admin_multi_device()                    to authenticated;
