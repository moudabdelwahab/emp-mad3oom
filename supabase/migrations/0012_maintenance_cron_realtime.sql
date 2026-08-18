-- 0012 — الصيانة الدورية، مهام pg_cron، والبث اللحظي

-- ─────────────────────────────────────────────────────────────
-- إغلاق الشيفتات المهجورة (متصفح مغلق / جهاز نائم / انقطاع طويل)
-- وقت الإغلاق = آخر نبضة موثوقة، وليس "الآن" — حتى لا يُحتسب وقت لم يعمله أحد.
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.close_stale_sessions()
returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_after numeric := emp_ops.setting_num('auto_close_after_seconds', 43200);
  v_max   numeric := emp_ops.setting_num('max_shift_seconds', 57600);
  v_rec   record;
  v_end   timestamptz;
  v_n     integer := 0;
begin
  for v_rec in
    select a.*, st.last_heartbeat_at
    from emp_ops.attendance_sessions a
    left join emp_ops.employee_runtime_state st on st.employee_id = a.employee_id
    where a.status = 'open'
      and (
        coalesce(st.last_heartbeat_at, a.started_at) < now() - make_interval(secs => v_after)
        or a.started_at < now() - make_interval(secs => v_max)
      )
  loop
    v_end := greatest(v_rec.started_at,
                      least(coalesce(v_rec.last_heartbeat_at, v_rec.started_at),
                            v_rec.started_at + make_interval(secs => v_max)));

    update emp_ops.break_sessions
       set ended_at = greatest(started_at, v_end), status = 'auto_closed'
     where attendance_session_id = v_rec.id and status = 'open';

    perform emp_ops.flush_activity(v_rec.employee_id, v_rec.id, 'system', 0);

    update emp_ops.attendance_sessions
       set ended_at = v_end, status = 'auto_closed',
           end_reason = 'إغلاق تلقائي بعد انقطاع النبضات'
     where id = v_rec.id;

    insert into emp_ops.attendance_events (employee_id, attendance_session_id, event_type, metadata)
    values (v_rec.employee_id, v_rec.id, 'shift_auto_close',
            jsonb_build_object('last_heartbeat_at', v_rec.last_heartbeat_at, 'closed_at', v_end));

    insert into emp_ops.audit_logs (actor_employee_id, action, target_type, target_id, target_label, metadata)
    values (null, 'shift.auto_close', 'attendance_session', v_rec.id::text,
            (select full_name from emp_ops.employees where id = v_rec.employee_id),
            jsonb_build_object('closed_at', v_end, 'reason', 'انقطاع النبضات'));

    update emp_ops.activity_sessions set ended_at = v_end
     where attendance_session_id = v_rec.id and ended_at is null;
    update emp_ops.employee_runtime_state
       set attendance_session_id = null, presence = 'offline', updated_at = now()
     where employee_id = v_rec.employee_id;

    perform emp_ops.recompute_daily_stats(v_rec.employee_id, v_rec.work_date);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- تحديث الحالة اللحظية المخزَّنة (يجعل الانتقال إلى "خامل/غير متصل" يصل للوحة الإدارة فورًا عبر Realtime)
create or replace function emp_ops.refresh_presence()
returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare v_n integer;
begin
  with calc as (
    select st.employee_id,
           emp_ops.compute_presence(
             a.id is not null,
             exists (select 1 from emp_ops.break_sessions bs
                      where bs.attendance_session_id = a.id and bs.status = 'open'),
             st.last_interaction_at, st.last_heartbeat_at,
             (select count(*)::integer from emp_ops.attendance_sessions x
               where x.employee_id = st.employee_id
                 and x.work_date = emp_ops.work_date_of(st.employee_id, now())),
             now()) as presence
    from emp_ops.employee_runtime_state st
    left join emp_ops.attendance_sessions a
      on a.employee_id = st.employee_id and a.status = 'open'
  )
  update emp_ops.employee_runtime_state st
     set presence = c.presence, updated_at = now()
    from calc c
   where c.employee_id = st.employee_id and st.presence is distinct from c.presence;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- إعادة حساب إحصاءات اليوم والأمس لكل الموظفين
create or replace function emp_ops.daily_rollup()
returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare v_n integer := 0; v_e record;
begin
  for v_e in select id from emp_ops.employees where status <> 'archived' loop
    perform emp_ops.recompute_daily_stats(v_e.id, emp_ops.work_date_of(v_e.id, now()));
    perform emp_ops.recompute_daily_stats(v_e.id, emp_ops.work_date_of(v_e.id, now()) - 1);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function emp_ops.maintenance_tick()
returns jsonb
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare v_closed integer; v_presence integer;
begin
  v_closed   := emp_ops.close_stale_sessions();
  v_presence := emp_ops.refresh_presence();
  return jsonb_build_object('closed_sessions', v_closed, 'presence_updates', v_presence, 'at', now());
end $$;

-- ─────────────────────────────────────────────────────────────
-- جدولة المهام
-- ─────────────────────────────────────────────────────────────
do $$
begin
  perform cron.unschedule('emp_ops_maintenance_tick');
exception when others then null;
end $$;

do $$
begin
  perform cron.unschedule('emp_ops_daily_rollup');
exception when others then null;
end $$;

select cron.schedule('emp_ops_maintenance_tick', '* * * * *', $cron$select emp_ops.maintenance_tick()$cron$);
select cron.schedule('emp_ops_daily_rollup',     '*/15 * * * *', $cron$select emp_ops.daily_rollup()$cron$);

-- ─────────────────────────────────────────────────────────────
-- البث اللحظي: لوحة الإدارة تتابع تغيّر الحالة والحضور دون تحديث الصفحة.
-- قاعدة البيانات تبقى مصدر الحقيقة؛ Realtime مجرد إشعار بالتغيير.
-- ─────────────────────────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table emp_ops.employee_runtime_state;
    exception when duplicate_object then null;
    end;
    begin
      alter publication supabase_realtime add table emp_ops.attendance_sessions;
    exception when duplicate_object then null;
    end;
    begin
      alter publication supabase_realtime add table emp_ops.break_sessions;
    exception when duplicate_object then null;
    end;
  end if;
end $$;
