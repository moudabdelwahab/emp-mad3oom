-- 0007 — محرك الحساب: الحالة اللحظية، احتساب دقائق النشاط، الإحصاءات اليومية
--
-- كل منطق النظام يعيش هنا في ثلاث دوال، ولا يتكرر في أي مكان آخر.

-- ─────────────────────────────────────────────────────────────
-- 1) آلة الحالة — تعريف واحد لا يتكرر
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.compute_presence(
  p_has_open_session boolean,
  p_on_break         boolean,
  p_last_interaction timestamptz,
  p_last_heartbeat   timestamptz,
  p_sessions_today   integer default 0,
  p_now              timestamptz default now()
) returns text
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  select case
    when not coalesce(p_has_open_session, false) then
      case when coalesce(p_sessions_today, 0) > 0 then 'ended' else 'not_started' end
    when coalesce(p_on_break, false) then 'break'
    when p_last_heartbeat is null
      or p_now - p_last_heartbeat > make_interval(secs => emp_ops.setting_num('offline_threshold_seconds', 180))
      then 'disconnected'
    when p_last_interaction is null
      or p_now - p_last_interaction > make_interval(secs => emp_ops.setting_num('idle_threshold_seconds', 300))
      then 'idle'
    else 'active'
  end;
$$;

create or replace function emp_ops.presence_label(p_presence text)
returns text language sql immutable as $$
  select case p_presence
    when 'active'       then 'نشط'
    when 'idle'         then 'خامل'
    when 'break'        then 'في استراحة'
    when 'disconnected' then 'غير متصل'
    when 'ended'        then 'أنهى العمل'
    when 'not_started'  then 'لم يبدأ العمل'
    else 'غير معروف'
  end;
$$;

-- ─────────────────────────────────────────────────────────────
-- 2) احتساب دقائق النشاط
--
-- تُستدعى بمدى زمني [p_from, p_to) محسوب بالكامل على الخادم.
-- تستبعد أوقات الاستراحات، وتقصّ المدى على حدود الشيفت، وتكتب بالثانية
-- داخل دقائق مفتاحها (employee_id, minute_start) ⇒ استحالة الاحتساب المزدوج.
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.mark_active_minutes(
  p_employee_id           uuid,
  p_attendance_session_id uuid,
  p_from                  timestamptz,
  p_to                    timestamptz,
  p_source                text default 'emp_ops',
  p_interactions          integer default 0
) returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_from timestamptz;
  v_to   timestamptz;
  v_tz   text;
  v_credited integer := 0;
  v_session emp_ops.attendance_sessions;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    return 0;
  end if;

  select * into v_session from emp_ops.attendance_sessions where id = p_attendance_session_id;
  if not found then
    return 0;
  end if;

  -- القصّ على حدود الشيفت — لا يمكن أن يُحتسب نشاط خارج شيفت
  v_from := greatest(p_from, v_session.started_at);
  v_to   := least(p_to, coalesce(v_session.ended_at, now()));
  if v_to <= v_from then
    return 0;
  end if;

  v_tz := emp_ops.employee_timezone(p_employee_id);

  with minutes as (
    select generate_series(
             date_trunc('minute', v_from),
             date_trunc('minute', v_to - interval '1 microsecond'),
             interval '1 minute'
           ) as minute_start
  ),
  base as (
    select m.minute_start,
           greatest(m.minute_start, v_from) as seg_start,
           least(m.minute_start + interval '1 minute', v_to) as seg_end
    from minutes m
  ),
  -- استبعاد أي تداخل مع استراحة داخل نفس الشيفت
  net as (
    select b.minute_start,
           floor(extract(epoch from (b.seg_end - b.seg_start)))::integer
             - coalesce((
                 select floor(sum(extract(epoch from (
                          least(b.seg_end, coalesce(bs.ended_at, now()))
                        - greatest(b.seg_start, bs.started_at)
                        ))))::integer
                 from emp_ops.break_sessions bs
                 where bs.attendance_session_id = p_attendance_session_id
                   and bs.started_at < b.seg_end
                   and coalesce(bs.ended_at, now()) > b.seg_start
               ), 0) as secs
    from base b
  ),
  final as (
    select minute_start, least(60, greatest(secs, 0))::smallint as secs from net where secs > 0
  ),
  ins as (
    insert into emp_ops.activity_minutes as am
      (employee_id, minute_start, attendance_session_id, work_date, seconds, interactions, sources)
    select p_employee_id,
           f.minute_start,
           p_attendance_session_id,
           (f.minute_start at time zone v_tz)::date,
           f.secs,
           case when f.minute_start = (select max(minute_start) from final) then greatest(p_interactions, 0) else 0 end,
           array[coalesce(p_source, 'emp_ops')]
    from final f
    on conflict (employee_id, minute_start) do update
      set seconds      = least(60, am.seconds + excluded.seconds),
          interactions = am.interactions + excluded.interactions,
          sources      = (select array(select distinct unnest(am.sources || excluded.sources))),
          updated_at   = now()
    returning 1
  )
  select coalesce(sum(secs), 0) into v_credited from final;

  return v_credited;
end $$;

-- ─────────────────────────────────────────────────────────────
-- 3) إعادة حساب الإحصاءات اليومية من الجداول الخام
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.recompute_daily_stats(p_employee_id uuid, p_work_date date)
returns emp_ops.employee_daily_stats
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_row     emp_ops.employee_daily_stats;
  v_shift   integer := 0;
  v_break   integer := 0;
  v_active  integer := 0;
  v_idle    integer := 0;
  v_first   timestamptz;
  v_last    timestamptz;
  v_count   integer := 0;
  v_breaks  integer := 0;
  v_late    integer := 0;
  v_open    boolean := false;
  v_absent  boolean := false;
  v_denom   integer;
  v_shift_tpl emp_ops.shifts;
begin
  select count(*)::integer,
         coalesce(sum(emp_ops.session_seconds(started_at, ended_at)), 0)::integer,
         min(started_at),
         max(coalesce(ended_at, now())),
         bool_or(status = 'open'),
         coalesce(max(late_seconds), 0)
    into v_count, v_shift, v_first, v_last, v_open, v_late
  from emp_ops.attendance_sessions
  where employee_id = p_employee_id and work_date = p_work_date;

  select count(*)::integer,
         coalesce(sum(emp_ops.session_seconds(bs.started_at, bs.ended_at)), 0)::integer
    into v_breaks, v_break
  from emp_ops.break_sessions bs
  join emp_ops.attendance_sessions a on a.id = bs.attendance_session_id
  where a.employee_id = p_employee_id and a.work_date = p_work_date;

  select coalesce(sum(seconds), 0)::integer into v_active
  from emp_ops.activity_minutes
  where employee_id = p_employee_id and work_date = p_work_date;

  -- وقت الخمول = وقت الشيفت − الاستراحات − وقت النشاط (لا يقلّ عن صفر أبدًا)
  v_denom := greatest(v_shift - v_break, 0);
  v_active := least(v_active, v_denom);
  v_idle   := greatest(v_denom - v_active, 0);

  -- غياب = يوم عمل مجدول بلا أي جلسة حضور
  v_shift_tpl := emp_ops.shift_for(p_employee_id, p_work_date);
  v_absent := v_count = 0
              and v_shift_tpl.id is not null
              and (extract(dow from p_work_date)::integer = any(v_shift_tpl.work_days))
              and p_work_date < (now() at time zone emp_ops.employee_timezone(p_employee_id))::date;

  insert into emp_ops.employee_daily_stats as s (
    employee_id, work_date, first_start_at, last_end_at, sessions_count, breaks_count,
    shift_seconds, break_seconds, active_seconds, idle_seconds, active_pct,
    late_seconds, is_late, is_absent, had_open_session, computed_at
  ) values (
    p_employee_id, p_work_date, v_first, v_last, v_count, v_breaks,
    v_shift, v_break, v_active, v_idle,
    case when v_denom > 0 then round((v_active::numeric / v_denom) * 100, 2) else null end,
    v_late, v_late > 0, v_absent, v_open, now()
  )
  on conflict (employee_id, work_date) do update set
    first_start_at = excluded.first_start_at,
    last_end_at    = excluded.last_end_at,
    sessions_count = excluded.sessions_count,
    breaks_count   = excluded.breaks_count,
    shift_seconds  = excluded.shift_seconds,
    break_seconds  = excluded.break_seconds,
    active_seconds = excluded.active_seconds,
    idle_seconds   = excluded.idle_seconds,
    active_pct     = excluded.active_pct,
    late_seconds   = excluded.late_seconds,
    is_late        = excluded.is_late,
    is_absent      = excluded.is_absent,
    had_open_session = excluded.had_open_session,
    computed_at    = now()
  returning * into v_row;

  return v_row;
end $$;

-- ملخّص لحظي لموظف (لا يعتمد على جدول الإحصاءات — يُحسب من الخام مباشرة)
create or replace function emp_ops.live_totals(p_employee_id uuid, p_work_date date)
returns table (
  shift_seconds integer, break_seconds integer, active_seconds integer,
  idle_seconds integer, active_pct numeric, sessions_count integer
)
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  with s as (
    select coalesce(sum(emp_ops.session_seconds(started_at, ended_at)), 0)::integer as shift_seconds,
           count(*)::integer as sessions_count
    from emp_ops.attendance_sessions
    where employee_id = p_employee_id and work_date = p_work_date
  ),
  b as (
    select coalesce(sum(emp_ops.session_seconds(bs.started_at, bs.ended_at)), 0)::integer as break_seconds
    from emp_ops.break_sessions bs
    join emp_ops.attendance_sessions a on a.id = bs.attendance_session_id
    where a.employee_id = p_employee_id and a.work_date = p_work_date
  ),
  m as (
    select coalesce(sum(seconds), 0)::integer as active_seconds
    from emp_ops.activity_minutes
    where employee_id = p_employee_id and work_date = p_work_date
  )
  select s.shift_seconds,
         b.break_seconds,
         least(m.active_seconds, greatest(s.shift_seconds - b.break_seconds, 0)) as active_seconds,
         greatest(greatest(s.shift_seconds - b.break_seconds, 0)
                  - least(m.active_seconds, greatest(s.shift_seconds - b.break_seconds, 0)), 0) as idle_seconds,
         case when greatest(s.shift_seconds - b.break_seconds, 0) > 0
              then round((least(m.active_seconds, greatest(s.shift_seconds - b.break_seconds, 0))::numeric
                          / greatest(s.shift_seconds - b.break_seconds, 0)) * 100, 2)
              else null end as active_pct,
         s.sessions_count
  from s, b, m;
$$;
