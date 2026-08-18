-- ═══════════════════════════════════════════════════════════════
-- اختبارات فصل Active Time عن Shift Time
--
-- تغطي السيناريوهات الاثني عشر المطلوبة: من بدء شيفت بلا فتح مدعوم، إلى
-- الانتقال بين التبويبات وفقد الـFocus والخمول والاستراحة وتعدد التبويبات
-- والأجهزة وإغلاق التبويب.
--
-- كالعادة: معاملة واحدة تنتهي بـ RAISE EXCEPTION متعمَّد ⇒ لا أثر باقٍ.
-- المدد تُحاكى بتأريخ الحالة المخزَّنة، فالنتائج قطعية بلا انتظار حقيقي.
-- ═══════════════════════════════════════════════════════════════
do $$
declare
  r text := ''; p int := 0; f int := 0;
  u1 uuid; e1 uuid; js jsonb; sid uuid; n int; secs int; mu timestamptz;

  -- نبضة من منصة مدعوم
begin
  select id into u1 from auth.users
   where id not in (select user_id from emp_ops.employees where user_id is not null)
   order by created_at limit 1;
  insert into emp_ops.employees (user_id, full_name, email, role, timezone)
  values (u1, 'موظف اختبار الانخراط', 'eng@test.invalid', 'employee', 'Africa/Cairo') returning id into e1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', u1::text, 'email', 'eng@test.invalid', 'role', 'authenticated')::text, true);

  js := public.eo_start_shift('{"device_id":"ops"}'::jsonb);
  sid := (js -> 'session' ->> 'id')::uuid;

  -- تجهيزان لازمان لأن now() ثابتة داخل المعاملة الواحدة:
  --  (١) نُرجِع بداية الشيفت للوراء، وإلا قصّت mark_active_minutes كل مدى
  --      مُحاكى على حدود الجلسة (بدايتها = الآن) فخرج الاحتساب صفرًا دائمًا.
  --  (٢) نرفع حد النداءات: الاختبار يرسل عشرات النبضات داخل نافذة زمنية واحدة
  --      فيتدخّل تحديد المعدل ويُعيد throttled بدل نتيجة الاحتساب.
  update emp_ops.attendance_sessions set started_at = now() - interval '8 hours' where id = sid;
  update emp_ops.app_settings set value = '1000' where key = 'max_ingest_calls_per_bucket';

  ---------------------------------------------------------------
  -- ب1: بدء الشيفت بلا فتح مدعوم ⇒ لا وقت نشاط إطلاقًا
  begin
    -- نبضات لوحة العمليات مع تفاعل حقيقي فيها
    perform public.eo_ingest_activity('{"device_id":"ops","source_app":"emp_ops","interactions":25,"visible":true,"focused":true}'::jsonb);
    -- مرور دقيقتين ثم نبضة أخرى من لوحة العمليات
    update emp_ops.employee_runtime_state set last_heartbeat_at = now() - interval '2 minutes' where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"ops","source_app":"emp_ops","interactions":30,"visible":true,"focused":true}'::jsonb);
    select coalesce(sum(seconds),0) into secs from emp_ops.activity_minutes where employee_id = e1;
    if secs = 0 and js ->> 'activity_reason' = 'not_qualified_app' and (js ->> 'qualifies')::boolean = false
    then p:=p+1; r:=concat(r, E'\n[نجح] ب1 شيفت مفتوح + لوحة العمليات فقط ⇒ وقت نشاط = 0');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب1 نشاط=', secs, ' سبب=', coalesce(js->>'activity_reason','?'); end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب1: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب2: فتح مدعوم والتفاعل داخله ⇒ يبدأ احتساب النشاط
  begin
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":4,"visible":true,"focused":true}'::jsonb);
    -- محاكاة مرور دقيقتين من العمل المتصل داخل مدعوم
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '2 minutes', marked_until = now() - interval '2 minutes'
     where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":3,"visible":true,"focused":true}'::jsonb);
    secs := (js ->> 'credited_seconds')::int;
    if secs between 110 and 130 and (js ->> 'engaged')::boolean and js ->> 'activity_reason' = 'counted'
    then p:=p+1; r:=concat(r, E'\n[نجح] ب2 العمل داخل مدعوم احتُسب (', secs, 'ث)');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب2 احتُسب ', secs, ' سبب=', coalesce(js->>'activity_reason','?'); end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب2: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب3: الانتقال إلى تبويب آخر ⇒ يتوقف النشاط وتُغلق النافذة
  begin
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":0,"visible":false,"focused":false}'::jsonb);
    select marked_until into mu from emp_ops.employee_runtime_state where employee_id = e1;
    if js ->> 'activity_reason' = 'tab_hidden' and (js ->> 'engaged')::boolean = false and mu > now()
    then p:=p+1; r:=concat(r, E'\n[نجح] ب3 تبويب مخفي ⇒ توقّف الاحتساب وأُغلقت النافذة');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب3 سبب=', coalesce(js->>'activity_reason','?'), ' نافذة مغلقة=', (mu > now())::text; end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب3: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب4: العودة إلى مدعوم بلا تفاعل ⇒ لا يُمنح وقت الغياب رجعيًا
  begin
    select coalesce(sum(seconds),0) into n from emp_ops.activity_minutes where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":0,"visible":true,"focused":true}'::jsonb);
    select coalesce(sum(seconds),0) into secs from emp_ops.activity_minutes where employee_id = e1;
    if (js ->> 'credited_seconds')::int = 0 and secs = n
    then p:=p+1; r:=concat(r, E'\n[نجح] ب4 العودة وحدها لا تمنح وقتًا (يلزم تفاعل)');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب4 مُنح ', ((js->>'credited_seconds')::int), 'ث'; end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب4: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب4/ب: العودة مع تفاعل حقيقي ⇒ يستأنف الاحتساب من لحظة التفاعل
  begin
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":5,"visible":true,"focused":true}'::jsonb);
    select marked_until into mu from emp_ops.employee_runtime_state where employee_id = e1;
    -- محاكاة دقيقة عمل بعد العودة
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '60 seconds', marked_until = now() - interval '60 seconds'
     where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":2,"visible":true,"focused":true}'::jsonb);
    secs := (js ->> 'credited_seconds')::int;
    if mu <= now() and secs between 50 and 70
    then p:=p+1; r:=concat(r, E'\n[نجح] ب4/ب التفاعل بعد العودة استأنف الاحتساب (', secs, 'ث)');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب4/ب استئناف=', secs, 'ث'; end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب4/ب: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب5: مدعوم ظاهر لكن بلا Focus ⇒ لا احتساب مستمر
  --
  -- النبضة الأولى بعد فقد الـFocus تُرحّل ما استُحق قبله فقط (ذيل مقيَّد بحد
  -- التغطية، وفي التشغيل الحقيقي يكون أجزاء من الثانية لأن العميل يرسل نبضة
  -- فورية عند blur). ثم تُغلق النافذة فلا يتراكم شيء بعدها مهما تكرّرت النبضات.
  begin
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '60 seconds', marked_until = now() - interval '60 seconds'
     where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":9,"visible":true,"focused":false}'::jsonb);
    n := (js ->> 'credited_seconds')::int;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":15,"visible":true,"focused":false}'::jsonb);
    secs := (js ->> 'credited_seconds')::int;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":40,"visible":true,"focused":false}'::jsonb);
    if n <= 180 and secs = 0 and (js ->> 'credited_seconds')::int = 0
       and js ->> 'activity_reason' = 'tab_unfocused'
    then p:=p+1; r:=concat(r, E'\n[نجح] ب5 بلا Focus: ذيل واحد (', n, 'ث) ثم توقّف الاحتساب نهائيًا');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب5 ذيل=', n, ' ثم=', secs, '/', js->>'credited_seconds', ' سبب=', js->>'activity_reason'); end if;
  exception when others then f:=f+1; r:=concat(r, E'\n[خطأ] ب5: ', sqlerrm); end;

  -- ب6: الخمول داخل مدعوم ⇒ الاحتساب يقف عند عتبة الخمول لا عند الآن
  begin
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '400 seconds',   -- تجاوز عتبة 300
           marked_until        = now() - interval '120 seconds',   -- ضمن حد التغطية
           last_heartbeat_at   = now()
     where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":0,"visible":true,"focused":true}'::jsonb);
    secs := (js ->> 'credited_seconds')::int;
    if secs between 10 and 30 and js ->> 'presence' = 'idle'
    then p:=p+1; r:=concat(r, E'\n[نجح] ب6 الخمول أوقف الاحتساب عند العتبة (', secs, 'ث من 120) والحالة خامل');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب6 احتُسب ', secs, ' الحالة=', coalesce(js->>'presence','?'); end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب6: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب7: العودة بعد خمول طويل ⇒ لا وقت رجعي
  begin
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '40 minutes',
           marked_until        = now() - interval '40 minutes'
     where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":6,"visible":true,"focused":true}'::jsonb);
    if (js ->> 'credited_seconds')::int = 0
    then p:=p+1; r:=concat(r, E'\n[نجح] ب7 العودة بعد 40 دقيقة لم تمنح أي وقت رجعي');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب7 مُنح ', (js->>'credited_seconds'), 'ث رجعيًا!'; end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب7: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب8: الاستراحة ⇒ لا احتساب نشاط
  begin
    perform public.eo_start_break('lunch');
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '60 seconds', marked_until = now() - interval '60 seconds'
     where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":10,"visible":true,"focused":true}'::jsonb);
    if (js ->> 'credited_seconds')::int = 0 and (js ->> 'on_break')::boolean and js ->> 'activity_reason' = 'on_break'
    then p:=p+1; r:=concat(r, E'\n[نجح] ب8 الاستراحة لا تُحتسب نشاطًا');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب8 مُنح ', (js->>'credited_seconds'), ' سبب=', coalesce(js->>'activity_reason','?'); end if);
    perform public.eo_end_break();
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب8: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب8/ب: إنهاء الاستراحة وحده لا يفتح نافذة نشاط
  begin
    update emp_ops.employee_runtime_state set last_heartbeat_at = now() - interval '60 seconds' where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":0,"visible":true,"focused":true}'::jsonb);
    if (js ->> 'credited_seconds')::int = 0
    then p:=p+1; r:=concat(r, E'\n[نجح] ب8/ب إنهاء الاستراحة لا يمنح نشاطًا بلا تفاعل داخل مدعوم');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب8/ب مُنح ', (js->>'credited_seconds'), 'ث'; end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب8/ب: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب10: تبويبان لمدعوم على نفس الجهاز ⇒ لا تتضاعف الدقائق
  begin
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '90 seconds', marked_until = now() - interval '90 seconds'
     where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":2,"visible":true,"focused":true,"tabs":3}'::jsonb);
    secs := (js ->> 'credited_seconds')::int;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":2,"visible":true,"focused":true,"tabs":3}'::jsonb);
    if secs between 80 and 100 and (js ->> 'credited_seconds')::int = 0
    then p:=p+1; r:=concat(r, E'\n[نجح] ب10 ثلاثة تبويبات على جهاز واحد ⇒ احتساب مرة واحدة (', secs, 'ث)');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب10 الأول=', secs, ' الثاني=', (js->>'credited_seconds'); end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب10: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب11: جهاز ثانٍ لمدعوم ⇒ لا تتضاعف الدقائق
  begin
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '90 seconds', marked_until = now() - interval '90 seconds'
     where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"laptop","source_app":"mad3oom","interactions":2,"visible":true,"focused":true}'::jsonb);
    secs := (js ->> 'credited_seconds')::int;
    js := public.eo_ingest_activity('{"device_id":"phone","source_app":"mad3oom","interactions":2,"visible":true,"focused":true}'::jsonb);
    if secs between 80 and 100 and (js ->> 'credited_seconds')::int = 0
    then p:=p+1; r:=concat(r, E'\n[نجح] ب11 جهازان ⇒ احتساب مرة واحدة (', secs, 'ث)');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب11 الأول=', secs, ' الثاني=', (js->>'credited_seconds'); end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب11: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب12: إغلاق تبويب مدعوم ⇒ لا يستمر النشاط بلا دليل
  begin
    -- آخر نبضة مؤهَّلة قديمة جدًا (التبويب أُغلق)، ثم يُعاد فتحه دون تفاعل
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '55 minutes',
           marked_until        = now() - interval '55 minutes'
     where employee_id = e1;
    select coalesce(sum(seconds),0) into n from emp_ops.activity_minutes where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":0,"visible":true,"focused":true}'::jsonb);
    select coalesce(sum(seconds),0) into secs from emp_ops.activity_minutes where employee_id = e1;
    if (js ->> 'credited_seconds')::int = 0 and secs = n
    then p:=p+1; r:=concat(r, E'\n[نجح] ب12 إعادة فتح التبويب بعد ساعة لم تمنح شيئًا');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب12 مُنح ', ((js->>'credited_seconds')::int), 'ث'; end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب12: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب9: إنهاء الشيفت ⇒ يتوقف كل احتساب
  begin
    perform public.eo_end_shift('اختبار');
    js := public.eo_ingest_activity('{"device_id":"pc","source_app":"mad3oom","interactions":20,"visible":true,"focused":true}'::jsonb);
    if js ->> 'status' = 'no_session'
    then p:=p+1; r:=concat(r, E'\n[نجح] ب9 بعد إنهاء الشيفت لا يُقبل أي نشاط');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب9 الحالة=', coalesce(js->>'status','?'); end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب9: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ب13: وقت الشيفت لم يتأثر بأي مما سبق (الفصل المطلوب)
  begin
    select emp_ops.session_seconds(started_at, ended_at) into n
      from emp_ops.attendance_sessions where id = sid;
    select coalesce(sum(seconds),0) into secs from emp_ops.activity_minutes where employee_id = e1;
    if n >= 0 and secs > 0 and secs < greatest(n, 1) + 600
    then p:=p+1; r:=concat(r, E'\n[نجح] ب13 الشيفت مستقل عن النشاط (شيفت=', n, 'ث · نشاط=', secs, 'ث)');
    else f:=f+1; r:=concat(r, E'\n[فشل] ب13 شيفت=', n, ' نشاط=', secs; end if);
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ب13: '||sqlerrm; end;

  raise exception E'\n======== تقرير فصل وقت النشاط عن وقت الشيفت ========%\n\nنجح: %   فشل: %\n', r, p, f;
end $$;
