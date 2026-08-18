-- 0009 — استيعاب النشاط: نقطة دخول واحدة للنبضات والأحداث معًا
--
-- نداء واحد كل فترة نبض يحمل: عدّاد التفاعلات + دفعة الأحداث.
-- هذا يقلّل عدد الطلبات إلى أدنى حد ويمنع انفجار عدد الـ requests.

create or replace function emp_ops.try_ts(p_text text)
returns timestamptz language plpgsql immutable as $$
begin
  return nullif(btrim(p_text), '')::timestamptz;
exception when others then
  return null;
end $$;

create or replace function public.eo_ingest_activity(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_emp        emp_ops.employees;
  v_session    emp_ops.attendance_sessions;
  v_break      emp_ops.break_sessions;
  v_act        emp_ops.activity_sessions;
  v_state      emp_ops.employee_runtime_state;
  v_device     text;
  v_source     text;
  v_bucket_sec numeric;
  v_bucket     timestamptz;
  v_calls      integer;
  v_max_calls  integer;
  v_max_events integer;
  v_interactions integer;
  v_visible    boolean;
  v_tabs       integer;
  v_client_ts  timestamptz;
  v_skew       integer;
  v_events     jsonb;
  v_stored_events integer := 0;
  v_interactive boolean;
  v_credited   integer := 0;
  v_presence   text;
  v_totals     record;
  v_date       date;
  v_sessions_today integer;
begin
  v_emp := emp_ops.require_employee();

  v_device := nullif(btrim(coalesce(p_payload ->> 'device_id', '')), '');
  if v_device is null then
    raise exception 'معرّف الجهاز مطلوب.' using errcode = 'EO400';
  end if;
  v_device := left(v_device, 100);
  v_source := left(coalesce(nullif(btrim(p_payload ->> 'source_app'), ''), 'emp_ops'), 40);

  -- لا يُحتسب أي نشاط خارج شيفت مفتوح
  select * into v_session from emp_ops.attendance_sessions
   where employee_id = v_emp.id and status = 'open' limit 1;
  if not found then
    return jsonb_build_object(
      'status', 'no_session',
      'message', 'لا يوجد شيفت مفتوح — لن يُحتسب أي نشاط.',
      'server_time', now(),
      'presence', 'not_started'
    );
  end if;

  v_interactions := greatest(0, least(coalesce((p_payload ->> 'interactions')::integer, 0), 10000));
  v_visible      := coalesce((p_payload ->> 'visible')::boolean, true);
  v_tabs         := greatest(1, least(coalesce((p_payload ->> 'tabs')::integer, 1), 100));
  v_client_ts    := emp_ops.try_ts(p_payload ->> 'client_time');
  v_skew         := case when v_client_ts is null then null
                         else floor(extract(epoch from (v_client_ts - now())))::integer end;

  -- جلسة النشاط لهذا الجهاز داخل هذا الشيفت (التبويبات تتشارك الجلسة نفسها)
  insert into emp_ops.activity_sessions
    (employee_id, attendance_session_id, device_id, source_app, user_agent, platform, ip)
  values (v_emp.id, v_session.id, v_device, v_source,
          left(coalesce(p_payload ->> 'user_agent', ''), 400),
          left(coalesce(p_payload ->> 'platform', ''), 100),
          nullif(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), '')::inet)
  on conflict (attendance_session_id, device_id, source_app) do update
    set last_seen_at = now(), ended_at = null
  returning * into v_act;

  -- ── تحديد الطلبات: نافذة زمنية على الخادم + مفتاح فريد يمنع التكرار
  v_bucket_sec := emp_ops.setting_num('heartbeat_bucket_seconds', 30);
  v_max_calls  := emp_ops.setting_num('max_ingest_calls_per_bucket', 6)::integer;
  v_max_events := emp_ops.setting_num('max_events_per_call', 50)::integer;
  v_bucket     := to_timestamp(floor(extract(epoch from now()) / v_bucket_sec) * v_bucket_sec);

  insert into emp_ops.activity_heartbeats as hb
    (employee_id, attendance_session_id, activity_session_id, bucket_start,
     calls, interactions, visible, tabs, client_sent_at, clock_skew_seconds)
  values (v_emp.id, v_session.id, v_act.id, v_bucket,
          1, v_interactions, v_visible, v_tabs, v_client_ts, v_skew)
  on conflict (activity_session_id, bucket_start) do update
    set calls        = hb.calls + 1,
        interactions = hb.interactions + excluded.interactions,
        last_seen_at = now(),
        visible      = excluded.visible,
        tabs         = greatest(hb.tabs, excluded.tabs),
        clock_skew_seconds = excluded.clock_skew_seconds
  returning calls into v_calls;

  if v_calls > v_max_calls then
    return jsonb_build_object(
      'status', 'throttled',
      'message', 'عدد النداءات تجاوز الحد المسموح في هذه النافذة الزمنية.',
      'server_time', now(),
      'retry_after_seconds', v_bucket_sec
    );
  end if;

  -- ── تخزين أحداث النشاط (الأنواع المعروفة فقط)
  v_events := case when jsonb_typeof(p_payload -> 'events') = 'array'
                   then p_payload -> 'events' else '[]'::jsonb end;
  if jsonb_array_length(v_events) > 0 then
    with incoming as (
      select value as e from jsonb_array_elements(v_events) limit v_max_events
    ), ins as (
      insert into emp_ops.activity_events
        (employee_id, attendance_session_id, activity_session_id, event_type,
         entity_type, entity_id, source_app, metadata, client_reported_at, is_backfilled)
      select v_emp.id, v_session.id, v_act.id, i.e ->> 'type',
             left(nullif(i.e ->> 'entity_type', ''), 60),
             left(nullif(i.e ->> 'entity_id', ''), 200),
             v_source,
             case when length(coalesce(i.e ->> 'metadata', '')) > 4000
                  then jsonb_build_object('truncated', true)
                  else coalesce(i.e -> 'metadata', '{}'::jsonb) end,
             emp_ops.try_ts(i.e ->> 'client_time'),
             coalesce((i.e ->> 'backfilled')::boolean, false)
      from incoming i
      where exists (select 1 from emp_ops.activity_types t
                     where t.code = i.e ->> 'type' and t.is_active)
      returning 1
    )
    select count(*)::integer into v_stored_events from ins;
  end if;

  -- ── هل حدث تفاعل حقيقي؟ (عدّاد التفاعلات أو حدث مصنَّف كتفاعل)
  v_interactive := v_interactions > 0
    or exists (
      select 1 from jsonb_array_elements(v_events) x
      join emp_ops.activity_types t on t.code = x.value ->> 'type'
      where t.counts_as_interaction and t.is_active
    );
  -- التبويب المخفي لا يمنح نشاطًا إلا إذا حمل حدث عمل حقيقي
  if not v_visible and v_interactions > 0 and v_stored_events = 0 then
    v_interactive := false;
  end if;

  select * into v_break from emp_ops.break_sessions
   where attendance_session_id = v_session.id and status = 'open' limit 1;

  -- ── تحديث الحالة اللحظية (مع قفل الصف لمنع تسابق التبويبات/الأجهزة)
  select * into v_state from emp_ops.employee_runtime_state
   where employee_id = v_emp.id for update;

  if not found then
    insert into emp_ops.employee_runtime_state
      (employee_id, attendance_session_id, last_heartbeat_at, last_interaction_at, marked_until)
    values (v_emp.id, v_session.id, now(),
            case when v_interactive then now() else null end,
            case when v_interactive then now() else null end)
    returning * into v_state;
  else
    update emp_ops.employee_runtime_state
       set attendance_session_id = v_session.id,
           last_heartbeat_at   = now(),
           last_interaction_at = case when v_interactive then now() else last_interaction_at end,
           marked_until        = coalesce(marked_until, case when v_interactive then now() else null end),
           updated_at          = now()
     where employee_id = v_emp.id
    returning * into v_state;
  end if;

  -- ── احتساب دقائق النشاط (لا يجري أثناء الاستراحة)
  if v_break.id is null then
    v_credited := emp_ops.flush_activity(v_emp.id, v_session.id, v_source, v_interactions);
  end if;

  v_date := v_session.work_date;
  select count(*)::integer into v_sessions_today from emp_ops.attendance_sessions
   where employee_id = v_emp.id and work_date = v_date;

  select * into v_state from emp_ops.employee_runtime_state where employee_id = v_emp.id;
  v_presence := emp_ops.compute_presence(true, v_break.id is not null,
                  v_state.last_interaction_at, v_state.last_heartbeat_at, v_sessions_today, now());

  update emp_ops.employee_runtime_state
     set presence = v_presence, updated_at = now() where employee_id = v_emp.id;

  select * into v_totals from emp_ops.live_totals(v_emp.id, v_date);

  return jsonb_build_object(
    'status', 'ok',
    'server_time', now(),
    'session_id', v_session.id,
    'activity_session_id', v_act.id,
    'presence', v_presence,
    'presence_label', emp_ops.presence_label(v_presence),
    'credited_seconds', v_credited,
    'stored_events', v_stored_events,
    'on_break', v_break.id is not null,
    'totals', jsonb_build_object(
      'shift_seconds',  coalesce(v_totals.shift_seconds, 0),
      'break_seconds',  coalesce(v_totals.break_seconds, 0),
      'active_seconds', coalesce(v_totals.active_seconds, 0),
      'idle_seconds',   coalesce(v_totals.idle_seconds, 0),
      'active_pct',     v_totals.active_pct
    ),
    'next_heartbeat_seconds', emp_ops.setting_num('heartbeat_interval_seconds', 60)
  );
end $$;

-- إغلاق جلسة جهاز عند إغلاق المتصفح (لا يؤثر على الشيفت نفسه)
create or replace function public.eo_close_device(p_device_id text)
returns boolean
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_emp emp_ops.employees;
begin
  v_emp := emp_ops.require_employee();
  update emp_ops.activity_sessions
     set ended_at = now()
   where employee_id = v_emp.id and device_id = left(coalesce(p_device_id, ''), 100) and ended_at is null;
  return true;
end $$;

revoke all on function public.eo_ingest_activity(jsonb) from public, anon;
revoke all on function public.eo_close_device(text)     from public, anon;
grant execute on function public.eo_ingest_activity(jsonb) to authenticated;
grant execute on function public.eo_close_device(text)     to authenticated;
