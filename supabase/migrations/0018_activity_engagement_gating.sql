-- 0018 — ربط احتساب Active Time بانخراط الموظف الفعلي في تبويب مدعوم
--
-- المشكلة التي يعالجها هذا الترحيل:
--   كان flush_activity يُستدعى في كل نبضة بلا أي شرط على حالة التبويب ولا على
--   التطبيق المُرسِل، فيمتد الاحتساب إلى (آخر تفاعل + عتبة الخمول) حتى لو كان
--   الموظف قد انتقل إلى تبويب آخر، أو كان النشاط قادمًا من لوحة العمليات نفسها
--   لا من منصة مدعوم.
--
-- المبدأ الجديد (وهو الفصل الذي طُلب):
--   Shift Time  = من بدء الشيفت إلى إنهائه — لم يتغيّر منه شيء إطلاقًا.
--   Active Time = الوقت الذي كان فيه الموظف داخل تبويب مدعوم، ظاهرًا وعليه
--                 Focus، ومتفاعلًا فعلًا خلال نافذة الخمول.
--
-- لم يُضَف أي جدول، ولم تتغيّر RLS ولا الصلاحيات ولا محرك الحضور ولا
-- mark_active_minutes ولا مفتاح دقائق النشاط الذي يحمي من تعدد التبويبات.

-- ─────────────────────────────────────────────────────────────
-- ١) إعدادات جديدة — لا رقم ولا اسم تطبيق مثبَّت في الكود
-- ─────────────────────────────────────────────────────────────
insert into emp_ops.app_settings (key, value, description_ar, value_type, min_value, max_value, is_public) values
  ('activity_source_apps', '["mad3oom"]',
   'التطبيقات التي يُحتسب النشاط داخلها فقط (لوحة العمليات نفسها ليست منها)', 'json', null, null, true),
  ('require_focus_for_activity', 'true',
   'اشتراط أن يكون تبويب مدعوم عليه Focus لاحتساب النشاط', 'boolean', null, null, true),
  ('activity_coverage_tolerance_seconds', '180',
   'أقصى فجوة بين نبضتين مؤهَّلتين يُسمح باحتساب ما بينها (بالثواني)', 'number', 30, 1800, true)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────
-- ٢) أثر تدقيق: نخزّن ما أبلغ عنه العميل حتى يمكن تفسير سبب عدم الاحتساب
-- ─────────────────────────────────────────────────────────────
alter table emp_ops.activity_heartbeats
  add column if not exists focused boolean,
  add column if not exists engaged boolean;

comment on column emp_ops.activity_heartbeats.engaged is
  'هل كانت النبضة مؤهِّلة للاحتساب لحظة وصولها: تطبيق مؤهَّل + تبويب ظاهر + Focus.';

-- ─────────────────────────────────────────────────────────────
-- ٣) قاعدة التغطية داخل flush_activity
--
-- النبضة الواحدة لا يجوز أن تمنح وقتًا لفترة لا تغطّيها نبضات مؤهَّلة متتابعة.
-- إن كانت الفجوة منذ آخر لحظة محسوبة أكبر من حدّ التسامح، فالفجوة بلا دليل
-- ⇒ يبدأ الاحتساب من الآن، ولا يُمنح عنها شيء بأثر رجعي.
-- هذا وحده يُسقط سيناريو "أغلق تبويب مدعوم ساعة ثم عاد" دون أي عمود جديد.
-- ─────────────────────────────────────────────────────────────
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
  v_tol   numeric;
  v_from  timestamptz;
  v_to    timestamptz;
begin
  select * into v_state from emp_ops.employee_runtime_state
   where employee_id = p_employee_id for update;
  if not found or v_state.last_interaction_at is null then
    return 0;
  end if;

  v_idle := emp_ops.setting_num('idle_threshold_seconds', 300);
  v_tol  := emp_ops.setting_num('activity_coverage_tolerance_seconds', 180);

  v_from := coalesce(v_state.marked_until, v_state.last_interaction_at);
  v_to   := least(now(), v_state.last_interaction_at + make_interval(secs => v_idle));

  -- فجوة غير مغطّاة بنبضات ⇒ لا تُحتسب، ويُستأنف الاحتساب من الآن
  if now() - v_from > make_interval(secs => v_tol) then
    v_from := now();
  end if;

  if v_to <= v_from then
    -- لا شيء يُحتسب، لكن نُقدّم مؤشر الاحتساب حتى لا تُمنح الفجوة لاحقًا
    update emp_ops.employee_runtime_state
       set marked_until = greatest(coalesce(marked_until, v_from), v_from), updated_at = now()
     where employee_id = p_employee_id;
    return 0;
  end if;

  update emp_ops.employee_runtime_state
     set marked_until = greatest(coalesce(marked_until, v_to), v_to), updated_at = now()
   where employee_id = p_employee_id;

  return emp_ops.mark_active_minutes(p_employee_id, p_session_id, v_from, v_to, p_source, p_interactions);
end $$;

-- إغلاق نافذة النشاط عند فقدان الانخراط: يمنع منح الفجوة عند العودة
create or replace function emp_ops.seal_activity_window(p_employee_id uuid)
returns void
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare v_idle numeric := emp_ops.setting_num('idle_threshold_seconds', 300);
begin
  update emp_ops.employee_runtime_state
     set marked_until = greatest(
           coalesce(marked_until, now()),
           coalesce(last_interaction_at + make_interval(secs => v_idle), now()),
           now()),
         updated_at = now()
   where employee_id = p_employee_id;
end $$;

comment on function emp_ops.seal_activity_window(uuid) is
  'تُستدعى عند خروج الموظف من تبويب مدعوم: تدفع مؤشر الاحتساب إلى ما بعد نافذة التفاعل الحالية، فلا يُمنح وقت الغياب عند العودة.';

-- ─────────────────────────────────────────────────────────────
-- ٤) بوّابة الاحتساب داخل eo_ingest_activity
--    (نفس الدالة السابقة حرفيًا عدا مواضع البوّابة المُعلَّمة أدناه)
-- ─────────────────────────────────────────────────────────────
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
  v_focused    boolean;
  v_qualifies  boolean;
  v_engaged    boolean;
  v_work_event boolean := false;
  v_reason     text;
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

  select * into v_session from emp_ops.attendance_sessions
   where employee_id = v_emp.id and status = 'open' limit 1;
  if not found then
    return jsonb_build_object(
      'status', 'no_session',
      'message', 'لا يوجد شيفت مفتوح — لن يُحتسب أي نشاط.',
      'server_time', now(), 'presence', 'not_started');
  end if;

  v_interactions := greatest(0, least(coalesce((p_payload ->> 'interactions')::integer, 0), 10000));
  v_visible      := coalesce((p_payload ->> 'visible')::boolean, true);
  -- العملاء الأقدم لا يرسلون focused ⇒ نعود إلى visible للتوافق الخلفي
  v_focused      := coalesce((p_payload ->> 'focused')::boolean, v_visible);

  -- هل هذا التطبيق مؤهَّل أصلًا لاحتساب النشاط؟ (لوحة العمليات ليست منها)
  v_qualifies := exists (
    select 1 from jsonb_array_elements_text(
      coalesce((select value from emp_ops.app_settings where key = 'activity_source_apps'),
               '["mad3oom"]'::jsonb)) a
    where a = v_source);

  -- الانخراط = تطبيق مؤهَّل + تبويب ظاهر + Focus (إن كان مشترطًا)
  v_engaged := v_qualifies and v_visible
               and (v_focused or not coalesce(
                     (select (value #>> '{}')::boolean from emp_ops.app_settings
                       where key = 'require_focus_for_activity'), true));
  v_tabs         := greatest(1, least(coalesce((p_payload ->> 'tabs')::integer, 1), 100));
  v_client_ts    := emp_ops.try_ts(p_payload ->> 'client_time');
  v_skew         := case when v_client_ts is null then null
                         else floor(extract(epoch from (v_client_ts - now())))::integer end;

  insert into emp_ops.activity_sessions
    (employee_id, attendance_session_id, device_id, source_app, user_agent, platform, ip)
  values (v_emp.id, v_session.id, v_device, v_source,
          left(coalesce(p_payload ->> 'user_agent', ''), 400),
          left(coalesce(p_payload ->> 'platform', ''), 100),
          nullif(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), '')::inet)
  on conflict (attendance_session_id, device_id, source_app) do update
    set last_seen_at = now(), ended_at = null
  returning * into v_act;

  v_bucket_sec := emp_ops.setting_num('heartbeat_bucket_seconds', 30);
  v_max_calls  := emp_ops.setting_num('max_ingest_calls_per_bucket', 6)::integer;
  v_max_events := emp_ops.setting_num('max_events_per_call', 50)::integer;
  v_bucket     := to_timestamp(floor(extract(epoch from now()) / v_bucket_sec) * v_bucket_sec);

  insert into emp_ops.activity_heartbeats as hb
    (employee_id, attendance_session_id, activity_session_id, bucket_start,
     calls, interactions, visible, tabs, client_sent_at, clock_skew_seconds, focused, engaged)
  values (v_emp.id, v_session.id, v_act.id, v_bucket,
          1, v_interactions, v_visible, v_tabs, v_client_ts, v_skew, v_focused, v_engaged)
  on conflict (activity_session_id, bucket_start) do update
    set calls        = hb.calls + 1,
        interactions = hb.interactions + excluded.interactions,
        last_seen_at = now(),
        visible      = excluded.visible,
        tabs         = greatest(hb.tabs, excluded.tabs),
        clock_skew_seconds = excluded.clock_skew_seconds,
        focused      = excluded.focused,
        engaged      = hb.engaged or excluded.engaged
  returning calls into v_calls;

  if v_calls > v_max_calls then
    return jsonb_build_object(
      'status', 'throttled',
      'message', 'عدد النداءات تجاوز الحد المسموح في هذه النافذة الزمنية.',
      'server_time', now(), 'retry_after_seconds', v_bucket_sec);
  end if;

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

  -- حدث عمل حقيقي داخل تطبيق مؤهَّل = دليل نشاط بذاته
  v_work_event := exists (
    select 1 from jsonb_array_elements(v_events) x
    join emp_ops.activity_types t on t.code = x.value ->> 'type'
    where t.counts_as_interaction and t.is_active);

  -- عدّاد التفاعل الخام لا يُصدَّق إلا من تبويب مؤهَّل ظاهر وعليه Focus.
  -- هذا ما يمنع "الشيفت مفتوح والصفحة مفتوحة" من أن يُنتج وقت نشاط.
  v_interactive := v_qualifies and ((v_engaged and v_interactions > 0) or v_work_event);

  select * into v_break from emp_ops.break_sessions
   where attendance_session_id = v_session.id and status = 'open' limit 1;

  -- قفل صف الحالة: يُسلسل كل التبويبات والأجهزة لنفس الموظف
  select * into v_state from emp_ops.employee_runtime_state
   where employee_id = v_emp.id for update;

  if not found then
    insert into emp_ops.employee_runtime_state
      (employee_id, attendance_session_id, last_heartbeat_at, last_interaction_at, marked_until)
    values (v_emp.id, v_session.id, now(),
            case when v_interactive then now() else null end,
            case when v_interactive then now() else null end);
  else
    -- (١) الترحيل أولًا بالحالة القديمة — يقف عند نهاية نافذة التفاعل السابق.
    --     التطبيق غير المؤهَّل (لوحة العمليات) لا يحتسب ولا يُغلق النافذة:
    -- يكتفي بتحديث آخر نبضة حتى تبقى حالة الاتصال معروفة.
    if v_qualifies then
      if v_break.id is null and v_engaged then
        v_credited := emp_ops.flush_activity(v_emp.id, v_session.id, v_source, v_interactions);
      else
        -- خرج من التبويب أو دخل استراحة: رحّل المستحق ثم أغلق النافذة
        if v_break.id is null then
          v_credited := emp_ops.flush_activity(v_emp.id, v_session.id, v_source, v_interactions);
        end if;
        perform emp_ops.seal_activity_window(v_emp.id);
      end if;
    end if;

    -- (٢) ثم تسجيل التفاعل الجديد ودفع مؤشر الاحتساب إلى الآن
    update emp_ops.employee_runtime_state
       set attendance_session_id = v_session.id,
           last_heartbeat_at   = now(),
           last_interaction_at = case when v_interactive then now() else last_interaction_at end,
           -- إعادة الضبط إلى الآن بالضبط: الترحيل تمّ قبل قليل، وأي قيمة
           -- مستقبلية وضعها الإغلاق يجب أن تسقط عند وصول تفاعل حقيقي.
           marked_until        = case when v_interactive then now() else marked_until end,
           updated_at          = now()
     where employee_id = v_emp.id;
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

  v_reason := case
    when not v_qualifies      then 'not_qualified_app'
    when v_break.id is not null then 'on_break'
    when not v_visible        then 'tab_hidden'
    when not v_engaged        then 'tab_unfocused'
    when v_credited = 0       then 'no_interaction'
    else 'counted' end;

  return jsonb_build_object(
    'status', 'ok',
    'qualifies', v_qualifies,
    'engaged', v_engaged,
    'activity_counted', v_credited > 0,
    'activity_reason', v_reason,
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
      'active_pct',     v_totals.active_pct),
    'next_heartbeat_seconds', emp_ops.setting_num('heartbeat_interval_seconds', 60));
end $$;

-- ─────────────────────────────────────────────────────────────
-- ٥) إجراءات لوحة العمليات لا تفتح نافذة نشاط
--
--    بدء الشيفت وإنهاء الاستراحة إجراءان إداريان داخل لوحة العمليات، لا
--    نشاطان داخل منصة مدعوم. كانا يبذران last_interaction_at = now()، فتُفتح
--    نافذة خمول تمنح حتى ٥ دقائق نشاط دون أن يفتح الموظف مدعوم أصلًا.
--    سجلّا الحضور والاستراحة نفساهما لم يتغيّرا بحرف واحد.
-- ─────────────────────────────────────────────────────────────
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
  -- last_interaction_at يبقى NULL عمدًا: بدء الشيفت إجراء إداري في لوحة
  -- العمليات وليس نشاطًا داخل منصة مدعوم، فلا يجوز أن يفتح نافذة احتساب.
  values (v_emp.id, v_session.id, null, now(), now(), 'idle', 'shift_start')
  on conflict (employee_id) do update set
    attendance_session_id = excluded.attendance_session_id,
    last_interaction_at   = null,
    last_heartbeat_at     = excluded.last_heartbeat_at,
    marked_until          = excluded.marked_until,
    presence              = 'idle',
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

  -- إنهاء الاستراحة يرفع الحجب فقط؛ استئناف احتساب النشاط يتطلب تفاعلًا
  -- حقيقيًا داخل تبويب مدعوم، لا مجرد الضغط على زر في لوحة العمليات.
  update emp_ops.employee_runtime_state
     set marked_until = greatest(coalesce(marked_until, now()), now()),
         presence = 'idle', last_event_type = 'break_end', updated_at = now()
   where employee_id = v_emp.id;

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, break_session_id, event_type, actor_employee_id, metadata)
  values (v_emp.id, v_break.attendance_session_id, v_break.id, 'break_end', v_emp.id,
          jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_break.started_at, v_break.ended_at)));

  perform emp_ops.audit(v_emp, 'break.end', 'break_session', v_break.id::text, v_emp.full_name,
    jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_break.started_at, v_break.ended_at)));

  return emp_ops.employee_status_json(v_emp.id);
end $$;
