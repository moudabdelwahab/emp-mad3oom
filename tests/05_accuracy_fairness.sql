-- ═══════════════════════════════════════════════════════════════
-- اختبارات الدقة والعدالة (ترحيل 0019)
--   ح1–ح3: مقياس الحضور من مستويين (حاضر بلا تفاعل)
--   ح4:    رجوع حدث الشغل (backfill)
--   ح5:    إنهاء الاستراحة المنسية بحدث عمل حقيقي
--   ح6:    سبب الخمول في الخط الزمني
--   ح7:    تدفق التصحيح/الطعن (طلب، تداخل، اعتماد، رفض، مراجعة ذاتية)
--   ح8:    تنبيه الشيفت المنسي
--   ح9:    دقيقة الحضور وحدها لا تُحسب نشاطًا + سقف الحضور بالمقام
--
-- كيف يعمل هذا الملف: مثل ملف 01 — معاملة واحدة تنتهي بـ RAISE
-- EXCEPTION متعمَّد فتُلغى بالكامل ولا يبقى أي أثر. الوقت يُحاكى
-- بتأريخ الحالة المخزَّنة إلى الوراء (now() ثابتة داخل المعاملة).
--
-- التشغيل: نفّذ الملف كاملًا بدور postgres (أو عبر Supabase SQL Editor).
-- ═══════════════════════════════════════════════════════════════
do $$
declare
  r text := ''; p int := 0; f int := 0;
  u1 uuid; u2 uuid; e1 uuid; e2 uuid;
  js jsonb; sid uuid; sid2 uuid; bid uuid; act_id uuid;
  req1 uuid; req3 uuid; req_self uuid;
  n int; secs int; present_s int; wd date; v_n int;
  row1 record;
begin
  -- ── تجهيز: موظفان مرتبطان بحسابات موجودة (لا نُنشئ حسابات جديدة)
  select id into u1 from auth.users
   where id not in (select user_id from emp_ops.employees where user_id is not null)
   order by created_at limit 1;
  select id into u2 from auth.users
   where id not in (select user_id from emp_ops.employees where user_id is not null)
     and id <> u1 order by created_at limit 1;
  if u1 is null or u2 is null then
    raise exception 'التجهيز فشل: لا توجد حسابات كافية غير مرتبطة بموظفين.';
  end if;

  insert into emp_ops.employees (user_id, full_name, email, role, timezone)
  values (u1, 'موظف اختبار عدالة', 'eo-fair-1@test.invalid', 'employee', 'Africa/Cairo') returning id into e1;
  insert into emp_ops.employees (user_id, full_name, email, role, timezone)
  values (u2, 'مدير اختبار عدالة', 'eo-fair-2@test.invalid', 'manager', 'Africa/Cairo') returning id into e2;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u1::text, 'email', 'eo-fair-1@test.invalid', 'role', 'authenticated')::text, true);

  wd := (now() at time zone 'Africa/Cairo')::date;

  -- كل نبضات هذا الملف تقع في نافذة زمنية واحدة (now() ثابتة)،
  -- فارفع حدّ النداءات مؤقتًا كما في ملفي 01 و04.
  update emp_ops.app_settings set value = '1000' where key = 'max_ingest_calls_per_bucket';

  ---------------------------------------------------------------
  -- ح1: الحضور يُحتسب مع النشاط في النبضة المنخرطة نفسها
  begin
    js := public.eo_start_shift('{"device_id":"pc","platform":"test"}'::jsonb);
    sid := (js -> 'session' ->> 'id')::uuid;
    update emp_ops.attendance_sessions set started_at = now() - interval '30 minutes' where id = sid;
    -- النبضة الأولى ترسي المرساة بلا منح (لم يمرّ وقت فعلي)
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":3,"visible":true,"focused":true}'::jsonb);
    if (js ->> 'credited_seconds')::int <> 0 or (js ->> 'present_credited_seconds')::int <> 0
    then f:=f+1; r:=r||E'\n[فشل] ح1 النبضة الأولى منحت وقتًا: نشاط='||coalesce(js->>'credited_seconds','?')||' حضور='||coalesce(js->>'present_credited_seconds','?');
    else
      -- محاكاة دقيقتين من العمل المتصل: آخر انخراط قبل دقيقة (داخل حدّ
      -- التغطية ٩٠ث) وآخر تفاعل والمرساتان قبل دقيقتين
      update emp_ops.employee_runtime_state
         set last_interaction_at = now() - interval '2 minutes',
             marked_until        = now() - interval '2 minutes',
             last_engaged_at     = now() - interval '1 minute',
             marked_present_until = now() - interval '2 minutes'
       where employee_id = e1;
      js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":1,"visible":true,"focused":true}'::jsonb);
      select coalesce(sum(present_seconds),0) into present_s from emp_ops.activity_minutes where employee_id = e1;
      if (js ->> 'credited_seconds')::int between 100 and 120
         and (js ->> 'present_credited_seconds')::int between 100 and 120
         and present_s >= 100
      then p:=p+1; r:=r||E'\n[نجح] ح1 حضور ١٢٠ث مع نشاط ١٢٠ث في النبضة المنخرطة';
      else f:=f+1; r:=r||E'\n[فشل] ح1 نشاط='||coalesce(js->>'credited_seconds','?')||' حضور='||coalesce(js->>'present_credited_seconds','?')||' مخزَّن='||present_s; end if;
    end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح1: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ح2: التبويب المخفي لا يمنح حضورًا (ولا يخرب المرساة القديمة)
  begin
    select coalesce(sum(present_seconds),0) into present_s from emp_ops.activity_minutes where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":0,"visible":false,"focused":false}'::jsonb);
    if (js ->> 'present_credited_seconds')::int = 0
       and js ->> 'activity_reason' = 'tab_hidden'
       and (select coalesce(sum(present_seconds),0) from emp_ops.activity_minutes where employee_id = e1) = present_s
    then p:=p+1; r:=r||E'\n[نجح] ح2 تبويب مخفي ⇒ حضور ٠ والسبب tab_hidden';
    else f:=f+1; r:=r||E'\n[فشل] ح2 حضور='||coalesce(js->>'present_credited_seconds','?')||' سبب='||coalesce(js->>'activity_reason','?'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح2: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ح3: نبضة لوحة العمليات لا تمنح حضورًا إطلاقًا
  begin
    select coalesce(sum(present_seconds),0) into present_s from emp_ops.activity_minutes where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"ops","source_app":"emp_ops","interactions":25,"visible":true,"focused":true}'::jsonb);
    if (js ->> 'present_credited_seconds')::int = 0
       and (js ->> 'credited_seconds')::int = 0
       and js ->> 'activity_reason' = 'not_qualified_app'
       and (select coalesce(sum(present_seconds),0) from emp_ops.activity_minutes where employee_id = e1) = present_s
    then p:=p+1; r:=r||E'\n[نجح] ح3 لوحة العمليات ⇒ حضور ٠ ونشاط ٠';
    else f:=f+1; r:=r||E'\n[فشل] ح3 حضور='||coalesce(js->>'present_credited_seconds','?')||' نشاط='||coalesce(js->>'credited_seconds','?')||' سبب='||coalesce(js->>'activity_reason','?'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح3: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ح4: حدث عمل حقيقي يرجع انخراط الدقائق الثماني السابقة
  begin
    select id into act_id from emp_ops.activity_sessions
     where employee_id = e1 and device_id = 'pc' and source_app = 'mad3oom';
    -- ١٦ نافذة نبضات منخرطة (٣٠ث) خلال آخر ٨ دقائق — إدراج مباشر لأن
    -- now() ثابتة داخل المعاملة ولا يمكن انتظار ٨ دقائق حقيقية
    insert into emp_ops.activity_heartbeats
      (employee_id, attendance_session_id, activity_session_id, bucket_start,
       calls, interactions, visible, tabs, focused, engaged)
    select e1, sid, act_id, now() - make_interval(secs => (17 - gs) * 30),
           1, 5, true, 1, true, true
    from generate_series(1, 16) gs;
    js := public.eo_ingest_activity(
      '{"device_id":"pc","source_app":"mad3oom","interactions":1,"visible":true,"focused":true,"events":[{"type":"ticket_reply","entity_type":"ticket","entity_id":"T-100"}]}'::jsonb);
    if (js ->> 'backfilled_seconds')::int between 480 and 510
       and (select count(*) from emp_ops.activity_events where employee_id = e1 and event_type = 'ticket_reply') = 1
    then p:=p+1; r:=r||E'\n[نجح] ح4 رجوع حدث الشغل منح '||(js ->> 'backfilled_seconds')||'ث (١٦ نافذة + الحالية)';
    else f:=f+1; r:=r||E'\n[فشل] ح4 رجوع='||coalesce(js->>'backfilled_seconds','?')||'ث'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح4: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ح5: حدث عمل ينهي الاستراحة المنسية، والنقرة العابرة لا تنهيها
  begin
    js := public.eo_start_break('general', 'اختبار إنهاء تلقائي');
    bid := (js -> 'break' ->> 'id')::uuid;
    -- (أ) نبضة عادية بتفاعل: الاستراحة تبقى مفتوحة
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":5,"visible":true,"focused":true}'::jsonb);
    if (js ->> 'break_auto_ended')::boolean = false and (js ->> 'on_break')::boolean = true
       and (select count(*) from emp_ops.break_sessions where id = bid and status = 'open') = 1
    then
      -- (ب) حدث عمل حقيقي: الاستراحة تُغلق تلقائيًا
      js := public.eo_ingest_activity(
        '{"device_id":"pc","source_app":"mad3oom","interactions":1,"visible":true,"focused":true,"events":[{"type":"ticket_reply","entity_type":"ticket","entity_id":"T-101"}]}'::jsonb);
      if (js ->> 'break_auto_ended')::boolean = true and (js ->> 'on_break')::boolean = false
         and (select status from emp_ops.break_sessions where id = bid) = 'auto_closed'
         and (select count(*) from emp_ops.attendance_events where break_session_id = bid and event_type = 'break_auto_close') = 1
      then p:=p+1; r:=r||E'\n[نجح] ح5 النقرة لم تنهِ الاستراحة، وحدث العمل أنهاها تلقائيًا';
      else f:=f+1; r:=r||E'\n[فشل] ح5 (ب) auto_ended='||coalesce(js->>'break_auto_ended','?')||' on_break='||coalesce(js->>'on_break','?'); end if;
    else f:=f+1; r:=r||E'\n[فشل] ح5 (أ) auto_ended='||coalesce(js->>'break_auto_ended','?')||' on_break='||coalesce(js->>'on_break','?'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح5: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ح6: الخط الزمني يشرح سبب كل فجوة خمول
  begin
    -- ثلاث فترات نشاط متجاورة بفجوتين، في نافذة نظيفة (قبل نشاط ح1/ح4)
    insert into emp_ops.activity_minutes
      (employee_id, minute_start, attendance_session_id, work_date, seconds, present_seconds, interactions, sources)
    values
      (e1, date_trunc('minute', now() - interval '20 minutes'), sid, wd, 60, 0, 0, array['mad3oom']),
      (e1, date_trunc('minute', now() - interval '17 minutes'), sid, wd, 60, 0, 0, array['mad3oom']),
      (e1, date_trunc('minute', now() - interval '14 minutes'), sid, wd, 60, 0, 0, array['mad3oom']);
    -- فجوة أولى: نبضة بتبويب مخفي — فجوة ثانية: نبضة منخرطة بلا تفاعل
    insert into emp_ops.activity_heartbeats
      (employee_id, attendance_session_id, activity_session_id, bucket_start,
       calls, interactions, visible, tabs, focused, engaged)
    values
      (e1, sid, act_id, date_trunc('minute', now() - interval '19 minutes'), 1, 0, false, 1, false, false),
      (e1, sid, act_id, date_trunc('minute', now() - interval '16 minutes'), 1, 3, true, 1, true, true);
    if (select count(*) from emp_ops.timeline(e1, wd)
         where kind = 'idle_period' and meta ->> 'reason' = 'tab_hidden'
           and meta ->> 'reason_label' = 'تبويب مدعوم مخفي') >= 1
       and (select count(*) from emp_ops.timeline(e1, wd)
         where kind = 'idle_period' and meta ->> 'reason' = 'present_quiet'
           and meta ->> 'reason_label' = 'حاضر داخل مدعوم بلا تفاعل — قراءة أو مكالمة غالبًا') >= 1
    then p:=p+1; r:=r||E'\n[نجح] ح6 الخط الزمني يميّز «تبويب مخفي» عن «حاضر بلا تفاعل»';
    else f:=f+1; r:=r||E'\n[فشل] ح6 أسباب الفجوات غير مطابقة'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح6: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ح7: تدفق التصحيح/الطعن كاملًا
  begin
    -- الفترة المطلوبة يجب أن تقع داخل شيفت واحد: أرجع بداية الشيفت ساعتين
    update emp_ops.attendance_sessions set started_at = now() - interval '2 hours' where id = sid;
    -- (أ) طلب صحيح
    js := public.eo_request_correction(wd, now() - interval '60 minutes', now() - interval '30 minutes',
                                       5, 'مراجعة دقائق العمل المنسية');
    req1 := (js ->> 'id')::uuid;
    if req1 is null or js ->> 'status' <> 'pending'
    then f:=f+1; r:=r||E'\n[فشل] ح7 (أ) لم يُقبل الطلب الصحيح';
    else
      -- (ب) طلب متداخل مع المعلَّق ⇒ EO011
      begin
        js := public.eo_request_correction(wd, now() - interval '50 minutes', now() - interval '40 minutes',
                                           3, 'طلب متداخل مع الأول');
        f:=f+1; r:=r||E'\n[فشل] ح7 (ب) سُمح بطلب متداخل!';
      exception
        when sqlstate 'EO011' then null; -- متوقع
        when others then f:=f+1; r:=r||E'\n[خطأ] ح7 (ب) رمز غير متوقع '||sqlstate; end;
      -- (ج) سبب قصير ⇒ EO400
      begin
        js := public.eo_request_correction(wd, now() - interval '25 minutes', now() - interval '20 minutes',
                                           2, 'قصير');
        f:=f+1; r:=r||E'\n[فشل] ح7 (ج) سُمح بسبب قصير!';
      exception
        when sqlstate 'EO400' then null; -- متوقع
        when others then f:=f+1; r:=r||E'\n[خطأ] ح7 (ج) رمز غير متوقع '||sqlstate; end;
      -- (د) المدير يرى الطلب المعلَّق ويعتمده: ٥ دقائق = ٣٠٠ ثانية
      perform set_config('request.jwt.claims',
        json_build_object('sub', u2::text, 'email', 'eo-fair-2@test.invalid', 'role', 'authenticated')::text, true);
      if (select count(*) from public.eo_admin_correction_requests('pending')) <> 1
      then f:=f+1; r:=r||E'\n[فشل] ح7 (د) قائمة المعلَّق لا تحتوي طلبًا واحدًا';
      else
        js := public.eo_admin_review_correction(req1, true, 'معتمدة بعد المراجعة');
        select coalesce(sum(seconds),0) into secs from emp_ops.activity_minutes
         where employee_id = e1 and minute_start >= date_trunc('minute', now() - interval '60 minutes')
           and minute_start < date_trunc('minute', now() - interval '30 minutes');
        if (js ->> 'approved_seconds')::int = 300 and secs = 300
           and (select count(*) from emp_ops.activity_minutes
                 where employee_id = e1 and minute_start >= date_trunc('minute', now() - interval '60 minutes')
                   and minute_start < date_trunc('minute', now() - interval '30 minutes')
                   and 'correction' = any(sources)) = 5
        then
          -- (هـ) مراجعة ثانية للطلب نفسه ⇒ EO400
          begin
            js := public.eo_admin_review_correction(req1, true, 'مرة أخرى');
            f:=f+1; r:=r||E'\n[فشل] ح7 (هـ) سُمح بمراجعة ثانية!';
          exception
            when sqlstate 'EO400' then null; -- متوقع
            when others then f:=f+1; r:=r||E'\n[خطأ] ح7 (هـ) رمز غير متوقع '||sqlstate; end;
          -- (و) طلب ثانٍ يُرفَض بسبب موثَّق
          perform set_config('request.jwt.claims',
            json_build_object('sub', u1::text, 'email', 'eo-fair-1@test.invalid', 'role', 'authenticated')::text, true);
          js := public.eo_request_correction(wd, now() - interval '25 minutes', now() - interval '20 minutes',
                                             3, 'طلب آخر للرفض');
          req3 := (js ->> 'id')::uuid;
          perform set_config('request.jwt.claims',
            json_build_object('sub', u2::text, 'email', 'eo-fair-2@test.invalid', 'role', 'authenticated')::text, true);
          js := public.eo_admin_review_correction(req3, false, 'لا يكفي الدليل');
          if js ->> 'status' = 'rejected'
             and (select status from emp_ops.activity_correction_requests where id = req3) = 'rejected'
          then
            -- (ز) المراجع لا يراجع طلب نفسه ⇒ EO403
            js := public.eo_start_shift('{"device_id":"pc2","platform":"test"}'::jsonb);
            sid2 := (js -> 'session' ->> 'id')::uuid;
            update emp_ops.attendance_sessions set started_at = now() - interval '2 hours' where id = sid2;
            js := public.eo_request_correction(wd, now() - interval '60 minutes', now() - interval '30 minutes',
                                               5, 'طلب المدير لنفسه');
            req_self := (js ->> 'id')::uuid;
            begin
              js := public.eo_admin_review_correction(req_self, true, 'أعتمد نفسي');
              f:=f+1; r:=r||E'\n[فشل] ح7 (ز) سُمح بالمراجعة الذاتية!';
            exception
              when sqlstate 'EO403' then p:=p+1; r:=r||E'\n[نجح] ح7 التصحيح: اعتماد ٣٠٠ث بمصدر correction + رفض موثَّق + منع المراجعة الذاتية';
              when others then f:=f+1; r:=r||E'\n[خطأ] ح7 (ز) رمز غير متوقع '||sqlstate; end;
          else f:=f+1; r:=r||E'\n[فشل] ح7 (و) الرفض لم يُسجَّل'; end if;
        else f:=f+1; r:=r||E'\n[فشل] ح7 (د) اعتماد='||coalesce(js->>'approved_seconds','?')||' مجموع الفترة='||secs; end if;
      end if;
    end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح7: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ح8: تنبيه الشيفت المنسي يصل مرة واحدة ثم يتوقف حتى التكرار
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', u1::text, 'email', 'eo-fair-1@test.invalid', 'role', 'authenticated')::text, true);
    update emp_ops.employee_runtime_state
       set last_heartbeat_at = now() - interval '2 hours', last_shift_nudge_at = null
     where employee_id = e1;
    v_n := emp_ops.nudge_forgotten_shifts();
    if v_n >= 1
       and (select count(*) from public.notifications
             where user_id = u1 and category = 'attendance' and type = 'warning') >= 1
       and emp_ops.nudge_forgotten_shifts() = 0
    then
      -- نبضة حديثة ⇒ لا تنبيه حتى مع تصفير آخر تنبيه
      update emp_ops.employee_runtime_state
         set last_heartbeat_at = now(), last_shift_nudge_at = null
       where employee_id = e1;
      if emp_ops.nudge_forgotten_shifts() = 0
      then p:=p+1; r:=r||E'\n[نجح] ح8 تنبيه الشيفت المنسي: مرة واحدة، ولا تنبيه مع نبضة حديثة';
      else f:=f+1; r:=r||E'\n[فشل] ح8 نُبّه رغم النبضة الحديثة'; end if;
    else f:=f+1; r:=r||E'\n[فشل] ح8 عدد المنبَّهين='||v_n; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح8: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ح9: دقيقة الحضور وحدها خمول لا نشاط، والحضور مسقوف بالمقام
  begin
    -- دقيقة حضور بلا نشاط (seconds=0, present=60) + نبضة منخرطة في فجوتها
    insert into emp_ops.activity_minutes
      (employee_id, minute_start, attendance_session_id, work_date, seconds, present_seconds, interactions, sources)
    values (e1, date_trunc('minute', now() - interval '25 minutes'), sid, wd, 0, 60, 0, array['mad3oom']);
    insert into emp_ops.activity_heartbeats
      (employee_id, attendance_session_id, activity_session_id, bucket_start,
       calls, interactions, visible, tabs, focused, engaged)
    values (e1, sid, act_id, date_trunc('minute', now() - interval '25 minutes'), 1, 3, true, 1, true, true);
    if (select count(*) from emp_ops.timeline(e1, wd)
         where kind = 'idle_period' and meta ->> 'reason' = 'present_quiet'
           and at <= now() - interval '25 minutes' and until > now() - interval '25 minutes') >= 1
       and (select count(*) from emp_ops.timeline(e1, wd)
         where kind = 'active_period'
           and at <= now() - interval '25 minutes' and until > now() - interval '25 minutes') = 0
    then
      -- سقف الحضور: ٣٠٠ دقيقة حضور (١٨٠٠٠ث) تتجاوز الشيفت (~٧٢٠٠ث)
      insert into emp_ops.activity_minutes
        (employee_id, minute_start, attendance_session_id, work_date, seconds, present_seconds, interactions, sources)
      select e1, date_trunc('minute', now() - make_interval(secs => gs * 60)), sid, wd, 0, 60, 0, array['mad3oom']
      from generate_series(1, 300) gs
      on conflict (employee_id, minute_start) do update
        set present_seconds = 60, updated_at = now();
      select * into row1 from emp_ops.recompute_daily_stats(e1, wd);
      if row1.present_seconds <= row1.shift_seconds - row1.break_seconds
         and row1.present_pct <= 100
         and row1.present_seconds >= row1.shift_seconds - row1.break_seconds - 60
      then p:=p+1; r:=r||E'\n[نجح] ح9 دقيقة الحضور خمول لا نشاط، والحضور مسقوف عند '||row1.present_seconds||'ث';
      else f:=f+1; r:=r||E'\n[فشل] ح9 سقف الحضور: حضور='||row1.present_seconds||' مقام='||(row1.shift_seconds - row1.break_seconds)||' نسبة='||row1.present_pct; end if;
    else f:=f+1; r:=r||E'\n[فشل] ح9 تصنيف دقيقة الحضور في الخط الزمني'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح9: '||sqlerrm; end;

  raise exception E'\n════════ تقرير اختبارات الدقة والعدالة (0019) ════════%s\n\nنجح: %s   فشل: %s\n', r, p, f;
end $$;
