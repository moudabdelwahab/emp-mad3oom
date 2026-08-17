-- 0011 — التقارير وعمليات الإدارة
-- كل عملية تغيير هنا مُقيَّدة برتبة، ومُدقَّقة في audit_logs، ومحسوبة بأوقات الخادم.

-- ─────────────────────────────────────────────────────────────
-- التقارير — محسوبة من الجداول الخام مباشرة (لا من لقطة قد تكون قديمة)
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_report(
  p_from date, p_to date,
  p_employee_id uuid default null,
  p_team_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_actor emp_ops.employees;
  v_rows  jsonb;
  v_sum   jsonb;
  v_daily jsonb;
begin
  v_actor := emp_ops.require_employee();
  -- الموظف العادي لا يرى إلا تقريره هو
  if not emp_ops.can_manage() then
    if p_employee_id is null or p_employee_id <> v_actor.id then
      p_employee_id := v_actor.id;
    end if;
    p_team_id := null;
  end if;

  if p_to < p_from or (p_to - p_from) > 400 then
    raise exception 'نطاق التاريخ غير صالح (الحد الأقصى 400 يوم).' using errcode = 'EO400';
  end if;

  with scope as (
    select e.* from emp_ops.employees e
    where e.status <> 'archived'
      and (p_employee_id is null or e.id = p_employee_id)
      and (p_team_id is null or e.team_id = p_team_id)
  ),
  dates as (select d::date as work_date from generate_series(p_from, p_to, interval '1 day') d),
  sess as (
    select a.employee_id, a.work_date,
           count(*)::integer as sessions,
           sum(emp_ops.session_seconds(a.started_at, a.ended_at))::bigint as shift_seconds,
           max(a.late_seconds)::integer as late_seconds
    from emp_ops.attendance_sessions a
    join scope s on s.id = a.employee_id
    where a.work_date between p_from and p_to
    group by a.employee_id, a.work_date
  ),
  brk as (
    select a.employee_id, a.work_date,
           sum(emp_ops.session_seconds(b.started_at, b.ended_at))::bigint as break_seconds,
           count(*)::integer as breaks
    from emp_ops.break_sessions b
    join emp_ops.attendance_sessions a on a.id = b.attendance_session_id
    join scope s on s.id = a.employee_id
    where a.work_date between p_from and p_to
    group by a.employee_id, a.work_date
  ),
  act as (
    select m.employee_id, m.work_date, sum(m.seconds)::bigint as active_seconds
    from emp_ops.activity_minutes m
    join scope s on s.id = m.employee_id
    where m.work_date between p_from and p_to
    group by m.employee_id, m.work_date
  ),
  absent as (
    select s.id as employee_id, count(*)::integer as absent_days
    from scope s
    cross join dates d
    where d.work_date < (now() at time zone emp_ops.employee_timezone(s.id))::date
      and (emp_ops.shift_for(s.id, d.work_date)).id is not null
      and extract(dow from d.work_date)::integer = any((emp_ops.shift_for(s.id, d.work_date)).work_days)
      and not exists (select 1 from emp_ops.attendance_sessions a
                       where a.employee_id = s.id and a.work_date = d.work_date)
    group by s.id
  ),
  per_emp as (
    select s.id as employee_id, s.full_name, s.employee_code, s.role,
           (select tm.name_ar from emp_ops.teams tm where tm.id = s.team_id) as team,
           coalesce(sum(se.shift_seconds), 0)::bigint as shift_seconds,
           coalesce(sum(b.break_seconds), 0)::bigint as break_seconds,
           coalesce(sum(a.active_seconds), 0)::bigint as active_seconds,
           coalesce(count(distinct se.work_date), 0)::integer as present_days,
           coalesce(sum(se.sessions), 0)::integer as sessions_count,
           coalesce(count(*) filter (where se.late_seconds > 0), 0)::integer as late_days,
           coalesce(max(ab.absent_days), 0)::integer as absent_days
    from scope s
    left join sess se on se.employee_id = s.id
    left join brk  b  on b.employee_id = s.id and b.work_date = se.work_date
    left join act  a  on a.employee_id = s.id and a.work_date = se.work_date
    left join absent ab on ab.employee_id = s.id
    group by s.id, s.full_name, s.employee_code, s.role, s.team_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'employee_id', employee_id, 'full_name', full_name, 'employee_code', employee_code,
      'role', role, 'team', team,
      'shift_seconds', shift_seconds, 'break_seconds', break_seconds,
      'active_seconds', least(active_seconds, greatest(shift_seconds - break_seconds, 0)),
      'idle_seconds', greatest(greatest(shift_seconds - break_seconds, 0)
                               - least(active_seconds, greatest(shift_seconds - break_seconds, 0)), 0),
      'active_pct', case when greatest(shift_seconds - break_seconds, 0) > 0
                         then round((least(active_seconds, greatest(shift_seconds - break_seconds, 0))::numeric
                                     / greatest(shift_seconds - break_seconds, 0)) * 100, 2) else null end,
      'present_days', present_days, 'absent_days', absent_days,
      'late_days', late_days, 'sessions_count', sessions_count
    ) order by full_name), '[]'::jsonb),
    jsonb_build_object(
      'shift_seconds',  coalesce(sum(shift_seconds), 0),
      'break_seconds',  coalesce(sum(break_seconds), 0),
      'active_seconds', coalesce(sum(least(active_seconds, greatest(shift_seconds - break_seconds, 0))), 0),
      'idle_seconds',   coalesce(sum(greatest(greatest(shift_seconds - break_seconds, 0)
                          - least(active_seconds, greatest(shift_seconds - break_seconds, 0)), 0)), 0),
      'present_days',   coalesce(sum(present_days), 0),
      'absent_days',    coalesce(sum(absent_days), 0),
      'late_days',      coalesce(sum(late_days), 0),
      'sessions_count', coalesce(sum(sessions_count), 0),
      'employees',      count(*),
      'avg_active_pct', case when coalesce(sum(greatest(shift_seconds - break_seconds, 0)), 0) > 0
        then round((coalesce(sum(least(active_seconds, greatest(shift_seconds - break_seconds, 0))), 0)::numeric
                    / sum(greatest(shift_seconds - break_seconds, 0))) * 100, 2) else null end
    )
  into v_rows, v_sum
  from per_emp;

  -- تفصيل يومي للرسم البياني
  with scope as (
    select e.id from emp_ops.employees e
    where e.status <> 'archived'
      and (p_employee_id is null or e.id = p_employee_id)
      and (p_team_id is null or e.team_id = p_team_id)
  ),
  d as (
    select a.work_date,
           sum(emp_ops.session_seconds(a.started_at, a.ended_at))::bigint as shift_seconds,
           count(distinct a.employee_id)::integer as employees
    from emp_ops.attendance_sessions a join scope s on s.id = a.employee_id
    where a.work_date between p_from and p_to group by a.work_date
  ),
  db as (
    select a.work_date, sum(emp_ops.session_seconds(b.started_at, b.ended_at))::bigint as break_seconds
    from emp_ops.break_sessions b
    join emp_ops.attendance_sessions a on a.id = b.attendance_session_id
    join scope s on s.id = a.employee_id
    where a.work_date between p_from and p_to group by a.work_date
  ),
  da as (
    select m.work_date, sum(m.seconds)::bigint as active_seconds
    from emp_ops.activity_minutes m join scope s on s.id = m.employee_id
    where m.work_date between p_from and p_to group by m.work_date
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'work_date', d.work_date,
           'shift_seconds', d.shift_seconds,
           'break_seconds', coalesce(db.break_seconds, 0),
           'active_seconds', coalesce(da.active_seconds, 0),
           'employees', d.employees
         ) order by d.work_date), '[]'::jsonb) into v_daily
  from d left join db on db.work_date = d.work_date left join da on da.work_date = d.work_date;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'generated_at', now(),
    'timezone', emp_ops.system_timezone(),
    'filters', jsonb_build_object('employee_id', p_employee_id, 'team_id', p_team_id),
    'summary', v_sum, 'employees', v_rows, 'daily', v_daily,
    'formula', 'نسبة النشاط = وقت النشاط ÷ (مدة الشيفت − مدة الاستراحات) × 100'
  );
end $$;

create or replace function public.eo_log_export(p_kind text, p_meta jsonb default '{}'::jsonb)
returns boolean
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v emp_ops.employees;
begin
  v := emp_ops.require_employee();
  perform emp_ops.audit(v, 'report.export', 'report', left(coalesce(p_kind, 'report'), 60), null, coalesce(p_meta, '{}'::jsonb));
  return true;
end $$;

-- ─────────────────────────────────────────────────────────────
-- إدارة الموظفين
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_admin_list_employees()
returns table (
  id uuid, user_id uuid, linked boolean, employee_code text, full_name text, email text,
  phone text, role text, role_label text, status text, team_id uuid, team text,
  timezone text, hired_at date, shift_name text, created_at timestamptz
)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees;
begin
  v_actor := emp_ops.require_rank(50);
  return query
    select e.id, e.user_id, e.user_id is not null, e.employee_code, e.full_name, e.email,
           e.phone, e.role, r.name_ar, e.status, e.team_id,
           (select tm.name_ar from emp_ops.teams tm where tm.id = e.team_id),
           e.timezone, e.hired_at,
           (emp_ops.shift_for(e.id, (now() at time zone emp_ops.system_timezone())::date)).name_ar,
           e.created_at
    from emp_ops.employees e
    join emp_ops.roles r on r.code = e.role
    order by e.status, e.full_name;
end $$;

create or replace function public.eo_admin_upsert_employee(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_actor emp_ops.employees;
  v_id    uuid;
  v_row   emp_ops.employees;
  v_email text;
  v_user  uuid;
  v_role  text;
  v_new   boolean;
begin
  v_actor := emp_ops.require_rank(100);

  v_id    := nullif(p_payload ->> 'id', '')::uuid;
  v_email := lower(btrim(coalesce(p_payload ->> 'email', '')));
  v_role  := coalesce(nullif(btrim(p_payload ->> 'role'), ''), 'employee');

  if v_email = '' then
    raise exception 'البريد الإلكتروني مطلوب.' using errcode = 'EO400';
  end if;
  if not exists (select 1 from emp_ops.roles where code = v_role) then
    raise exception 'الدور المحدَّد غير موجود.' using errcode = 'EO400';
  end if;
  if coalesce(nullif(btrim(p_payload ->> 'full_name'), ''), '') = '' then
    raise exception 'اسم الموظف مطلوب.' using errcode = 'EO400';
  end if;

  -- الربط بحساب Supabase الموجود بنفس البريد (إن وُجد)
  select id into v_user from auth.users where lower(email) = v_email limit 1;

  if v_id is null then
    v_new := true;
    insert into emp_ops.employees
      (user_id, employee_code, full_name, email, phone, role, status, team_id, timezone, hired_at, notes, created_by)
    values (
      v_user,
      nullif(btrim(p_payload ->> 'employee_code'), ''),
      btrim(p_payload ->> 'full_name'),
      v_email,
      nullif(btrim(p_payload ->> 'phone'), ''),
      v_role,
      coalesce(nullif(p_payload ->> 'status', ''), 'active'),
      nullif(p_payload ->> 'team_id', '')::uuid,
      coalesce(nullif(btrim(p_payload ->> 'timezone'), ''), emp_ops.system_timezone()),
      nullif(p_payload ->> 'hired_at', '')::date,
      nullif(btrim(p_payload ->> 'notes'), ''),
      v_actor.id)
    returning * into v_row;
    perform emp_ops.audit(v_actor, 'employee.create', 'employee', v_row.id::text, v_row.full_name,
                          jsonb_build_object('role', v_role, 'linked', v_user is not null));
  else
    v_new := false;
    select * into v_row from emp_ops.employees where id = v_id;
    if not found then
      raise exception 'الموظف غير موجود.' using errcode = 'EO404';
    end if;
    update emp_ops.employees set
      employee_code = nullif(btrim(p_payload ->> 'employee_code'), ''),
      full_name     = btrim(p_payload ->> 'full_name'),
      email         = v_email,
      phone         = nullif(btrim(p_payload ->> 'phone'), ''),
      team_id       = nullif(p_payload ->> 'team_id', '')::uuid,
      timezone      = coalesce(nullif(btrim(p_payload ->> 'timezone'), ''), timezone),
      hired_at      = nullif(p_payload ->> 'hired_at', '')::date,
      notes         = nullif(btrim(p_payload ->> 'notes'), ''),
      user_id       = coalesce(user_id, v_user)
    where id = v_id returning * into v_row;
    perform emp_ops.audit(v_actor, 'employee.update', 'employee', v_row.id::text, v_row.full_name,
                          jsonb_build_object('changed', p_payload - 'id'));
  end if;

  return jsonb_build_object(
    'id', v_row.id, 'created', v_new, 'linked', v_row.user_id is not null,
    'message', case when v_row.user_id is null
      then 'تم الحفظ. لم يُعثر على حساب بهذا البريد بعد — سيُربط الموظف تلقائيًا عند إنشاء حسابه.'
      else 'تم الحفظ وربط الموظف بحسابه بنجاح.' end);
end $$;

create or replace function public.eo_admin_set_role(p_employee_id uuid, p_role text)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_row emp_ops.employees; v_old text;
begin
  v_actor := emp_ops.require_rank(100);
  select * into v_row from emp_ops.employees where id = p_employee_id;
  if not found then raise exception 'الموظف غير موجود.' using errcode = 'EO404'; end if;
  if not exists (select 1 from emp_ops.roles where code = p_role) then
    raise exception 'الدور المحدَّد غير موجود.' using errcode = 'EO400';
  end if;
  if v_row.id = v_actor.id and p_role <> v_actor.role then
    raise exception 'لا يمكنك تغيير دورك بنفسك.' using errcode = 'EO403';
  end if;
  v_old := v_row.role;
  update emp_ops.employees set role = p_role where id = p_employee_id returning * into v_row;
  perform emp_ops.audit(v_actor, 'employee.role_change', 'employee', v_row.id::text, v_row.full_name,
                        jsonb_build_object('from', v_old, 'to', p_role));
  return jsonb_build_object('id', v_row.id, 'role', v_row.role, 'message', 'تم تغيير الدور بنجاح.');
end $$;

create or replace function public.eo_admin_set_status(p_employee_id uuid, p_status text, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_row emp_ops.employees; v_old text;
begin
  v_actor := emp_ops.require_rank(100);
  if p_status not in ('active','suspended','archived') then
    raise exception 'حالة غير صالحة.' using errcode = 'EO400';
  end if;
  select * into v_row from emp_ops.employees where id = p_employee_id;
  if not found then raise exception 'الموظف غير موجود.' using errcode = 'EO404'; end if;
  if v_row.id = v_actor.id then
    raise exception 'لا يمكنك تغيير حالة حسابك بنفسك.' using errcode = 'EO403';
  end if;
  v_old := v_row.status;
  update emp_ops.employees set status = p_status where id = p_employee_id returning * into v_row;
  perform emp_ops.audit(v_actor, 'employee.status_change', 'employee', v_row.id::text, v_row.full_name,
                        jsonb_build_object('from', v_old, 'to', p_status, 'reason', p_reason));
  return jsonb_build_object('id', v_row.id, 'status', v_row.status, 'message', 'تم تحديث حالة الموظف.');
end $$;

-- ─────────────────────────────────────────────────────────────
-- تدخلات الإدارة على الحضور
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_admin_force_end_shift(p_employee_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_session emp_ops.attendance_sessions;
begin
  v_actor := emp_ops.require_rank(50);
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'يجب ذكر سبب إنهاء الشيفت.' using errcode = 'EO400';
  end if;

  select * into v_session from emp_ops.attendance_sessions
   where employee_id = p_employee_id and status = 'open' for update;
  if not found then raise exception 'لا يوجد شيفت مفتوح لهذا الموظف.' using errcode = 'EO002'; end if;

  update emp_ops.break_sessions set ended_at = now(), status = 'auto_closed'
   where attendance_session_id = v_session.id and status = 'open';

  perform emp_ops.flush_activity(p_employee_id, v_session.id, 'admin', 0);

  update emp_ops.attendance_sessions
     set ended_at = now(), status = 'closed',
         end_reason = btrim(p_reason), ended_by_employee_id = v_actor.id
   where id = v_session.id returning * into v_session;

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, event_type, actor_employee_id, metadata)
  values (p_employee_id, v_session.id, 'admin_force_end', v_actor.id, jsonb_build_object('reason', btrim(p_reason)));

  update emp_ops.activity_sessions set ended_at = now()
   where attendance_session_id = v_session.id and ended_at is null;
  update emp_ops.employee_runtime_state
     set attendance_session_id = null, presence = 'offline', updated_at = now()
   where employee_id = p_employee_id;

  perform emp_ops.audit(v_actor, 'shift.force_end', 'attendance_session', v_session.id::text,
                        (select full_name from emp_ops.employees where id = p_employee_id),
                        jsonb_build_object('reason', btrim(p_reason)));
  perform emp_ops.recompute_daily_stats(p_employee_id, v_session.work_date);
  return jsonb_build_object('session_id', v_session.id, 'message', 'تم إنهاء الشيفت وتسجيل العملية في سجل التدقيق.');
end $$;

create or replace function public.eo_admin_adjust_attendance(
  p_session_id uuid, p_started_at timestamptz, p_ended_at timestamptz, p_reason text)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_actor emp_ops.employees; v_old emp_ops.attendance_sessions; v_new emp_ops.attendance_sessions;
  v_max numeric;
begin
  v_actor := emp_ops.require_rank(100);
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'يجب ذكر سبب التعديل.' using errcode = 'EO400';
  end if;

  select * into v_old from emp_ops.attendance_sessions where id = p_session_id for update;
  if not found then raise exception 'سجل الحضور غير موجود.' using errcode = 'EO404'; end if;
  if v_old.status = 'open' then
    raise exception 'لا يمكن تعديل شيفت مفتوح. أنهِ الشيفت أولًا.' using errcode = 'EO006';
  end if;
  if p_started_at is null or p_ended_at is null then
    raise exception 'يجب تحديد وقت البداية والنهاية.' using errcode = 'EO400';
  end if;
  if p_ended_at < p_started_at then
    raise exception 'وقت النهاية لا يمكن أن يسبق وقت البداية.' using errcode = 'EO007';
  end if;
  if p_started_at > now() or p_ended_at > now() then
    raise exception 'لا يمكن تسجيل أوقات في المستقبل.' using errcode = 'EO008';
  end if;
  v_max := emp_ops.setting_num('max_shift_seconds', 57600);
  if extract(epoch from (p_ended_at - p_started_at)) > v_max then
    raise exception 'المدة تتجاوز الحد الأقصى المسموح للشيفت.' using errcode = 'EO009';
  end if;

  perform set_config('emp_ops.allow_adjust', 'on', true);
  update emp_ops.attendance_sessions
     set started_at = p_started_at, ended_at = p_ended_at, adjusted = true,
         end_reason = coalesce(end_reason, '') || ' | تعديل إداري: ' || btrim(p_reason),
         work_date = emp_ops.work_date_of(v_old.employee_id, p_started_at)
   where id = p_session_id returning * into v_new;
  perform set_config('emp_ops.allow_adjust', 'off', true);

  -- قصّ دقائق النشاط خارج الحدود الجديدة حتى تبقى الأرقام متسقة
  delete from emp_ops.activity_minutes
   where attendance_session_id = p_session_id
     and (minute_start < date_trunc('minute', p_started_at) or minute_start >= p_ended_at);

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, event_type, actor_employee_id, metadata)
  values (v_new.employee_id, v_new.id, 'admin_adjust', v_actor.id,
          jsonb_build_object('reason', btrim(p_reason),
                             'old_started_at', v_old.started_at, 'old_ended_at', v_old.ended_at,
                             'new_started_at', p_started_at, 'new_ended_at', p_ended_at));

  perform emp_ops.audit(v_actor, 'attendance.adjust', 'attendance_session', v_new.id::text,
                        (select full_name from emp_ops.employees where id = v_new.employee_id),
                        jsonb_build_object('reason', btrim(p_reason),
                                           'old', jsonb_build_object('started_at', v_old.started_at, 'ended_at', v_old.ended_at),
                                           'new', jsonb_build_object('started_at', p_started_at, 'ended_at', p_ended_at)));

  perform emp_ops.recompute_daily_stats(v_new.employee_id, v_old.work_date);
  if v_new.work_date <> v_old.work_date then
    perform emp_ops.recompute_daily_stats(v_new.employee_id, v_new.work_date);
  end if;

  return jsonb_build_object('session_id', v_new.id, 'message', 'تم تعديل سجل الحضور وتوثيق العملية.');
end $$;

-- ─────────────────────────────────────────────────────────────
-- الفرق والشيفتات
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_admin_upsert_team(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_id uuid; v_row emp_ops.teams;
begin
  v_actor := emp_ops.require_rank(50);
  v_id := nullif(p_payload ->> 'id', '')::uuid;
  if coalesce(btrim(p_payload ->> 'name_ar'), '') = '' then
    raise exception 'اسم الفريق مطلوب.' using errcode = 'EO400';
  end if;
  if v_id is null then
    insert into emp_ops.teams (name_ar, description_ar, manager_employee_id)
    values (btrim(p_payload ->> 'name_ar'), nullif(btrim(p_payload ->> 'description_ar'), ''),
            nullif(p_payload ->> 'manager_employee_id', '')::uuid)
    returning * into v_row;
    perform emp_ops.audit(v_actor, 'team.create', 'team', v_row.id::text, v_row.name_ar, '{}'::jsonb);
  else
    update emp_ops.teams set name_ar = btrim(p_payload ->> 'name_ar'),
           description_ar = nullif(btrim(p_payload ->> 'description_ar'), ''),
           manager_employee_id = nullif(p_payload ->> 'manager_employee_id', '')::uuid,
           is_active = coalesce((p_payload ->> 'is_active')::boolean, is_active)
     where id = v_id returning * into v_row;
    if not found then raise exception 'الفريق غير موجود.' using errcode = 'EO404'; end if;
    perform emp_ops.audit(v_actor, 'team.update', 'team', v_row.id::text, v_row.name_ar, '{}'::jsonb);
  end if;
  return jsonb_build_object('id', v_row.id, 'message', 'تم حفظ الفريق.');
end $$;

create or replace function public.eo_admin_upsert_shift(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_id uuid; v_row emp_ops.shifts; v_days integer[];
begin
  v_actor := emp_ops.require_rank(50);
  v_id := nullif(p_payload ->> 'id', '')::uuid;
  if coalesce(btrim(p_payload ->> 'name_ar'), '') = '' then
    raise exception 'اسم الشيفت مطلوب.' using errcode = 'EO400';
  end if;
  select coalesce(array_agg((x)::integer), '{}') into v_days
    from jsonb_array_elements_text(coalesce(p_payload -> 'work_days', '[0,1,2,3,4]'::jsonb)) x;

  if v_id is null then
    insert into emp_ops.shifts (name_ar, start_time, end_time, work_days, grace_minutes, timezone, created_by)
    values (btrim(p_payload ->> 'name_ar'),
            (p_payload ->> 'start_time')::time, (p_payload ->> 'end_time')::time,
            v_days, coalesce((p_payload ->> 'grace_minutes')::integer, 10),
            coalesce(nullif(btrim(p_payload ->> 'timezone'), ''), emp_ops.system_timezone()), v_actor.id)
    returning * into v_row;
    perform emp_ops.audit(v_actor, 'shift_template.create', 'shift', v_row.id::text, v_row.name_ar, '{}'::jsonb);
  else
    update emp_ops.shifts set name_ar = btrim(p_payload ->> 'name_ar'),
           start_time = (p_payload ->> 'start_time')::time,
           end_time   = (p_payload ->> 'end_time')::time,
           work_days  = v_days,
           grace_minutes = coalesce((p_payload ->> 'grace_minutes')::integer, grace_minutes),
           is_active  = coalesce((p_payload ->> 'is_active')::boolean, is_active)
     where id = v_id returning * into v_row;
    if not found then raise exception 'الشيفت غير موجود.' using errcode = 'EO404'; end if;
    perform emp_ops.audit(v_actor, 'shift_template.update', 'shift', v_row.id::text, v_row.name_ar, '{}'::jsonb);
  end if;
  return jsonb_build_object('id', v_row.id, 'message', 'تم حفظ الشيفت.');
end $$;

create or replace function public.eo_admin_assign_shift(
  p_employee_id uuid, p_shift_id uuid, p_from date, p_to date default null)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_row emp_ops.shift_assignments;
begin
  v_actor := emp_ops.require_rank(50);
  if p_from is null then raise exception 'تاريخ بدء الإسناد مطلوب.' using errcode = 'EO400'; end if;
  -- إنهاء الإسناد المفتوح السابق قبل بدء الجديد (منعًا للتداخل)
  update emp_ops.shift_assignments
     set effective_to = p_from - 1
   where employee_id = p_employee_id and effective_to is null and effective_from < p_from;
  begin
    insert into emp_ops.shift_assignments (employee_id, shift_id, effective_from, effective_to, created_by)
    values (p_employee_id, p_shift_id, p_from, p_to, v_actor.id) returning * into v_row;
  exception when exclusion_violation then
    raise exception 'يوجد إسناد شيفت متداخل زمنيًا لهذا الموظف.' using errcode = 'EO010';
  end;
  perform emp_ops.audit(v_actor, 'shift_assignment.set', 'employee', p_employee_id::text,
                        (select full_name from emp_ops.employees where id = p_employee_id),
                        jsonb_build_object('shift_id', p_shift_id, 'from', p_from, 'to', p_to));
  return jsonb_build_object('id', v_row.id, 'message', 'تم إسناد الشيفت.');
end $$;

-- ─────────────────────────────────────────────────────────────
-- الإعدادات وسجل التدقيق
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_admin_settings()
returns table (key text, value jsonb, description_ar text, value_type text,
               min_value numeric, max_value numeric, updated_at timestamptz)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees;
begin
  v_actor := emp_ops.require_rank(50);
  return query select s.key, s.value, s.description_ar, s.value_type, s.min_value, s.max_value, s.updated_at
               from emp_ops.app_settings s order by s.key;
end $$;

create or replace function public.eo_admin_set_setting(p_key text, p_value jsonb)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_row emp_ops.app_settings; v_old jsonb; v_num numeric;
begin
  v_actor := emp_ops.require_rank(100);
  select * into v_row from emp_ops.app_settings where key = p_key;
  if not found then raise exception 'الإعداد غير موجود.' using errcode = 'EO404'; end if;
  v_old := v_row.value;

  if v_row.value_type = 'number' then
    begin
      v_num := (p_value #>> '{}')::numeric;
    exception when others then
      raise exception 'القيمة يجب أن تكون رقمًا.' using errcode = 'EO400';
    end;
    if v_row.min_value is not null and v_num < v_row.min_value then
      raise exception 'القيمة أقل من الحد الأدنى المسموح (%).', v_row.min_value using errcode = 'EO400';
    end if;
    if v_row.max_value is not null and v_num > v_row.max_value then
      raise exception 'القيمة أكبر من الحد الأقصى المسموح (%).', v_row.max_value using errcode = 'EO400';
    end if;
  end if;

  if p_key = 'default_timezone' then
    begin
      perform now() at time zone (p_value #>> '{}');
    exception when others then
      raise exception 'المنطقة الزمنية غير صالحة.' using errcode = 'EO400';
    end;
  end if;

  update emp_ops.app_settings set value = p_value, updated_at = now(), updated_by = v_actor.user_id
   where key = p_key returning * into v_row;

  perform emp_ops.audit(v_actor, 'settings.update', 'setting', p_key, v_row.description_ar,
                        jsonb_build_object('from', v_old, 'to', p_value));
  return jsonb_build_object('key', v_row.key, 'value', v_row.value, 'message', 'تم حفظ الإعداد.');
end $$;

create or replace function public.eo_admin_audit_logs(
  p_from timestamptz default null, p_to timestamptz default null,
  p_action text default null, p_employee_id uuid default null,
  p_limit integer default 100, p_offset integer default 0)
returns table (id bigint, occurred_at timestamptz, actor_name text, actor_role text,
               action text, action_label text, severity text, target_type text,
               target_id text, target_label text, ip inet, metadata jsonb)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees;
begin
  v_actor := emp_ops.require_rank(50);
  return query
    select l.id, l.occurred_at, l.actor_name, l.actor_role, l.action,
           coalesce(a.name_ar, l.action), coalesce(a.severity, 'info'),
           l.target_type, l.target_id, l.target_label, l.ip, l.metadata
    from emp_ops.audit_logs l
    left join emp_ops.audit_actions a on a.code = l.action
    where (p_from is null or l.occurred_at >= p_from)
      and (p_to   is null or l.occurred_at <= p_to)
      and (p_action is null or l.action = p_action)
      and (p_employee_id is null or l.actor_employee_id = p_employee_id)
    order by l.occurred_at desc
    limit greatest(1, least(coalesce(p_limit, 100), 500))
    offset greatest(0, coalesce(p_offset, 0));
end $$;

create or replace function public.eo_admin_recompute(p_employee_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_d date; v_n integer := 0;
begin
  v_actor := emp_ops.require_rank(50);
  if p_to < p_from or (p_to - p_from) > 400 then
    raise exception 'نطاق التاريخ غير صالح.' using errcode = 'EO400';
  end if;
  v_d := p_from;
  while v_d <= p_to loop
    if p_employee_id is null then
      perform emp_ops.recompute_daily_stats(e.id, v_d) from emp_ops.employees e where e.status <> 'archived';
    else
      perform emp_ops.recompute_daily_stats(p_employee_id, v_d);
    end if;
    v_n := v_n + 1;
    v_d := v_d + 1;
  end loop;
  return jsonb_build_object('days', v_n, 'message', 'تمت إعادة حساب الإحصاءات.');
end $$;

revoke all on function public.eo_report(date, date, uuid, uuid)                  from public, anon;
revoke all on function public.eo_log_export(text, jsonb)                          from public, anon;
revoke all on function public.eo_admin_list_employees()                           from public, anon;
revoke all on function public.eo_admin_upsert_employee(jsonb)                     from public, anon;
revoke all on function public.eo_admin_set_role(uuid, text)                       from public, anon;
revoke all on function public.eo_admin_set_status(uuid, text, text)               from public, anon;
revoke all on function public.eo_admin_force_end_shift(uuid, text)                from public, anon;
revoke all on function public.eo_admin_adjust_attendance(uuid, timestamptz, timestamptz, text) from public, anon;
revoke all on function public.eo_admin_upsert_team(jsonb)                         from public, anon;
revoke all on function public.eo_admin_upsert_shift(jsonb)                        from public, anon;
revoke all on function public.eo_admin_assign_shift(uuid, uuid, date, date)       from public, anon;
revoke all on function public.eo_admin_settings()                                 from public, anon;
revoke all on function public.eo_admin_set_setting(text, jsonb)                   from public, anon;
revoke all on function public.eo_admin_audit_logs(timestamptz, timestamptz, text, uuid, integer, integer) from public, anon;
revoke all on function public.eo_admin_recompute(uuid, date, date)                from public, anon;

grant execute on function public.eo_report(date, date, uuid, uuid)                  to authenticated;
grant execute on function public.eo_log_export(text, jsonb)                          to authenticated;
grant execute on function public.eo_admin_list_employees()                           to authenticated;
grant execute on function public.eo_admin_upsert_employee(jsonb)                     to authenticated;
grant execute on function public.eo_admin_set_role(uuid, text)                       to authenticated;
grant execute on function public.eo_admin_set_status(uuid, text, text)               to authenticated;
grant execute on function public.eo_admin_force_end_shift(uuid, text)                to authenticated;
grant execute on function public.eo_admin_adjust_attendance(uuid, timestamptz, timestamptz, text) to authenticated;
grant execute on function public.eo_admin_upsert_team(jsonb)                         to authenticated;
grant execute on function public.eo_admin_upsert_shift(jsonb)                        to authenticated;
grant execute on function public.eo_admin_assign_shift(uuid, uuid, date, date)       to authenticated;
grant execute on function public.eo_admin_settings()                                 to authenticated;
grant execute on function public.eo_admin_set_setting(text, jsonb)                   to authenticated;
grant execute on function public.eo_admin_audit_logs(timestamptz, timestamptz, text, uuid, integer, integer) to authenticated;
grant execute on function public.eo_admin_recompute(uuid, date, date)                to authenticated;
