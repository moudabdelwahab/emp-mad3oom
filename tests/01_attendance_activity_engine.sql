-- ═══════════════════════════════════════════════════════════════
-- اختبارات محرك الحضور والنشاط
--
-- كيف يعمل هذا الملف:
--   كل الاختبارات تجري داخل معاملة واحدة تنتهي بـ RAISE EXCEPTION متعمَّد،
--   فتُلغى المعاملة بالكامل ولا يبقى في قاعدة البيانات أي أثر — ولا حتى في
--   سجل التدقيق. التقرير يصل عبر نص الاستثناء نفسه.
--
--   الوقت لا يمكن تسريعه داخل معاملة واحدة (now() ثابتة)، لذلك تُحاكى المدد
--   بتأريخ الحالة المخزَّنة إلى الوراء مباشرةً — وهو ما يكافئ مرور الوقت
--   تمامًا من وجهة نظر المحرك، ويجعل النتائج قطعية لا تعتمد على sleep.
--
-- التشغيل: نفّذ الملف كاملًا بدور postgres (أو عبر Supabase SQL Editor).
-- ═══════════════════════════════════════════════════════════════
do $$
declare
  r text := ''; p int := 0; f int := 0;
  u1 uuid; u2 uuid; e1 uuid; e2 uuid;
  js jsonb; sid uuid; bid uuid; n int; secs int; idle_s int := 300;
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
  values (u1, 'موظف اختبار', 'eo-test-1@test.invalid', 'employee', 'Africa/Cairo') returning id into e1;
  insert into emp_ops.employees (user_id, full_name, email, role, timezone)
  values (u2, 'مدير اختبار', 'eo-test-2@test.invalid', 'manager', 'Africa/Cairo') returning id into e2;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u1::text, 'email', 'eo-test-1@test.invalid', 'role', 'authenticated')::text, true);

  ---------------------------------------------------------------
  -- ت١: الحالة الابتدائية = لم يبدأ العمل
  begin
    js := public.eo_me();
    if js -> 'session' = 'null'::jsonb and js ->> 'presence' = 'not_started'
    then p:=p+1; r:=r||E'\n[نجح] ت١ الحالة الابتدائية "لم يبدأ العمل"';
    else f:=f+1; r:=r||E'\n[فشل] ت١ الحالة الابتدائية: '||coalesce(js->>'presence','?'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت١: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٢: بدء الشيفت يُنشئ جلسة حقيقية بوقت الخادم
  begin
    js := public.eo_start_shift('{"device_id":"dev-A","platform":"test"}'::jsonb);
    sid := (js -> 'session' ->> 'id')::uuid;
    if sid is not null and js ->> 'presence' = 'active'
       and (select count(*) from emp_ops.attendance_sessions where employee_id=e1 and status='open')=1
    then p:=p+1; r:=r||E'\n[نجح] ت٢ بدء الشيفت أنشأ جلسة مفتوحة واحدة';
    else f:=f+1; r:=r||E'\n[فشل] ت٢ بدء الشيفت'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٢: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٣: منع شيفتين مفتوحين (يُفرض من قاعدة البيانات)
  begin
    js := public.eo_start_shift('{"device_id":"dev-A"}'::jsonb);
    f:=f+1; r:=r||E'\n[فشل] ت٣ سُمح ببدء شيفت ثانٍ!';
  exception
    when sqlstate 'EO001' then p:=p+1; r:=r||E'\n[نجح] ت٣ رُفض الشيفت الثاني (EO001)';
    when others then f:=f+1; r:=r||E'\n[خطأ] ت٣ رمز غير متوقع '||sqlstate||': '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٤: النبضة الأولى لا تمنح وقتًا (لم يمرّ وقت فعلي)
  begin
    js := public.eo_ingest_activity('{"device_id":"dev-A","interactions":3,"visible":true}'::jsonb);
    if js ->> 'status' = 'ok' and (js ->> 'credited_seconds')::int = 0
    then p:=p+1; r:=r||E'\n[نجح] ت٤ النبضة الأولى لم تمنح وقتًا وهميًا';
    else f:=f+1; r:=r||E'\n[فشل] ت٤ credited='||coalesce(js->>'credited_seconds','?'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٤: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٥: حدث نشاط داخل مدعوم يُسجَّل ويُصنَّف
  begin
    js := public.eo_ingest_activity(
      '{"device_id":"dev-A","interactions":0,"source_app":"mad3oom","events":[
         {"type":"ticket_reply","entity_type":"ticket","entity_id":"T-100"},
         {"type":"نوع_غير_موجود","entity_id":"x"}]}'::jsonb);
    if (js ->> 'stored_events')::int = 1
       and (select count(*) from emp_ops.activity_events where employee_id=e1 and event_type='ticket_reply')=1
    then p:=p+1; r:=r||E'\n[نجح] ت٥ حُفظ الحدث المعروف ورُفض النوع المجهول';
    else f:=f+1; r:=r||E'\n[فشل] ت٥ stored='||coalesce(js->>'stored_events','?'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٥: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٦: محاكاة مرور ٣٠ دقيقة — الاحتساب يتوقف عند عتبة الخمول (٥ دقائق)
  begin
    update emp_ops.attendance_sessions set started_at = now() - interval '30 minutes' where id = sid;
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '30 minutes',
           marked_until        = now() - interval '30 minutes',
           last_heartbeat_at   = now() - interval '30 minutes'
     where employee_id = e1;

    js := public.eo_ingest_activity('{"device_id":"dev-A","interactions":0}'::jsonb);
    secs := (js ->> 'credited_seconds')::int;
    if secs between idle_s - 60 and idle_s
    then p:=p+1; r:=r||E'\n[نجح] ت٦ احتُسبت عتبة الخمول فقط ('||secs||' ثانية من ١٨٠٠)';
    else f:=f+1; r:=r||E'\n[فشل] ت٦ احتُسب '||secs||' ثانية بدل ~'||idle_s; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٦: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٧: الحالة الآن "خامل" لأن آخر تفاعل تجاوز العتبة
  begin
    js := public.eo_me();
    if js ->> 'presence' = 'idle'
    then p:=p+1; r:=r||E'\n[نجح] ت٧ اكتُشف الخمول تلقائيًا';
    else f:=f+1; r:=r||E'\n[فشل] ت٧ الحالة='||coalesce(js->>'presence','?'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٧: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٨: العودة بتفاعل جديد لا تمنح الفجوة الخاملة بأثر رجعي
  begin
    select coalesce(sum(seconds),0) into n from emp_ops.activity_minutes where employee_id=e1;
    js := public.eo_ingest_activity('{"device_id":"dev-A","interactions":7}'::jsonb);
    secs := (js ->> 'credited_seconds')::int;
    if secs = 0
    then p:=p+1; r:=r||E'\n[نجح] ت٨ التفاعل بعد ٢٥ دقيقة خمول لم يمنح أي وقت رجعي';
    else f:=f+1; r:=r||E'\n[فشل] ت٨ مُنح '||secs||' ثانية بأثر رجعي!'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٨: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٩: تعدد التبويبات/الأجهزة لا يضاعف وقت النشاط
  begin
    select coalesce(sum(seconds),0) into n from emp_ops.activity_minutes where employee_id=e1;
    -- محاكاة مرور دقيقتين ثم نبضتان من جهازين مختلفين
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '2 minutes',
           marked_until        = now() - interval '2 minutes'
     where employee_id = e1;
    js := public.eo_ingest_activity('{"device_id":"dev-A","interactions":1}'::jsonb);
    secs := (js ->> 'credited_seconds')::int;
    js := public.eo_ingest_activity('{"device_id":"dev-B","interactions":1}'::jsonb);
    if secs between 110 and 130 and (js ->> 'credited_seconds')::int = 0
    then p:=p+1; r:=r||E'\n[نجح] ت٩ الجهاز الأول احتُسب ('||secs||'ث) والثاني لم يضاعف (٠ث)';
    else f:=f+1; r:=r||E'\n[فشل] ت٩ الأول='||secs||' الثاني='||(js->>'credited_seconds'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٩: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١٠: جهازان مميزان على شيفت واحد، وثلاث جلسات نشاط
  -- (dev-A من لوحة العمليات + dev-A من مدعوم + dev-B) — العدّاد يحسب الأجهزة لا الصفوف
  begin
    select count(*) into n from emp_ops.activity_sessions where attendance_session_id = sid;
    select emp_ops.active_device_count(sid) into secs;
    if n = 3 and secs = 2
    then p:=p+1; r:=r||E'\n[نجح] ت١٠ ٣ جلسات نشاط لكن جهازان مميزان فقط';
    else f:=f+1; r:=r||E'\n[فشل] ت١٠ صفوف='||n||' أجهزة='||secs; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت١٠: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١١: تحديد معدل النداءات داخل النافذة الواحدة
  begin
    update emp_ops.app_settings set value='2' where key='max_ingest_calls_per_bucket';
    js := public.eo_ingest_activity('{"device_id":"dev-C","interactions":1}'::jsonb);
    js := public.eo_ingest_activity('{"device_id":"dev-C","interactions":1}'::jsonb);
    js := public.eo_ingest_activity('{"device_id":"dev-C","interactions":1}'::jsonb);
    if js ->> 'status' = 'throttled'
    then p:=p+1; r:=r||E'\n[نجح] ت١١ رُفض النداء الزائد (throttled)';
    else f:=f+1; r:=r||E'\n[فشل] ت١١ الحالة='||coalesce(js->>'status','?'); end if;
    update emp_ops.app_settings set value='6' where key='max_ingest_calls_per_bucket';
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت١١: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١٢: بدء استراحة
  begin
    js := public.eo_start_break('lunch', 'اختبار');
    bid := (js -> 'break' ->> 'id')::uuid;
    if bid is not null and js ->> 'presence' = 'break'
    then p:=p+1; r:=r||E'\n[نجح] ت١٢ بدأت الاستراحة والحالة "في استراحة"';
    else f:=f+1; r:=r||E'\n[فشل] ت١٢'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت١٢: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١٣: منع استراحتين مفتوحتين
  begin
    js := public.eo_start_break();
    f:=f+1; r:=r||E'\n[فشل] ت١٣ سُمح باستراحة ثانية!';
  exception
    when sqlstate 'EO004' then p:=p+1; r:=r||E'\n[نجح] ت١٣ رُفضت الاستراحة الثانية (EO004)';
    when others then f:=f+1; r:=r||E'\n[خطأ] ت١٣ '||sqlstate||': '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١٤: لا يُحتسب نشاط أثناء الاستراحة
  begin
    update emp_ops.employee_runtime_state
       set last_interaction_at = now() - interval '2 minutes',
           marked_until        = now() - interval '2 minutes'
     where employee_id = e1;
    update emp_ops.break_sessions set started_at = now() - interval '3 minutes' where id = bid;
    js := public.eo_ingest_activity('{"device_id":"dev-A","interactions":5}'::jsonb);
    if (js ->> 'on_break')::boolean and (js ->> 'credited_seconds')::int = 0
    then p:=p+1; r:=r||E'\n[نجح] ت١٤ الاستراحة لا تُحتسب نشاطًا';
    else f:=f+1; r:=r||E'\n[فشل] ت١٤ credited='||coalesce(js->>'credited_seconds','?'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت١٤: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١٥: إنهاء الاستراحة
  begin
    js := public.eo_end_break();
    if js -> 'break' = 'null'::jsonb and js ->> 'presence' = 'active'
       and (select status from emp_ops.break_sessions where id=bid) = 'closed'
    then p:=p+1; r:=r||E'\n[نجح] ت١٥ أُغلقت الاستراحة وعاد النشاط';
    else f:=f+1; r:=r||E'\n[فشل] ت١٥'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت١٥: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١٦: إنهاء استراحة غير موجودة
  begin
    js := public.eo_end_break();
    f:=f+1; r:=r||E'\n[فشل] ت١٦ سُمح بإنهاء استراحة غير موجودة!';
  exception
    when sqlstate 'EO005' then p:=p+1; r:=r||E'\n[نجح] ت١٦ رُفض إنهاء استراحة غير قائمة (EO005)';
    when others then f:=f+1; r:=r||E'\n[خطأ] ت١٦ '||sqlstate||': '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١٧: مدة الاستراحة مطروحة من مقام نسبة النشاط
  begin
    js := public.eo_me();
    if (js -> 'totals' ->> 'break_seconds')::int > 0
       and (js -> 'totals' ->> 'shift_seconds')::int > (js -> 'totals' ->> 'break_seconds')::int
       and (js -> 'totals' ->> 'active_seconds')::int + (js -> 'totals' ->> 'idle_seconds')::int
           = (js -> 'totals' ->> 'shift_seconds')::int - (js -> 'totals' ->> 'break_seconds')::int
    then p:=p+1; r:=r||E'\n[نجح] ت١٧ المعادلة متسقة: نشاط + خمول = شيفت − استراحة';
    else f:=f+1; r:=r||E'\n[فشل] ت١٧ '||(js->'totals')::text; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت١٧: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١٨: الخط الزمني يحتوي فترات نشاط وخمول واستراحة
  begin
    select count(*) into n from emp_ops.timeline(e1, emp_ops.work_date_of(e1, now()))
     where kind in ('active_period','idle_period','break_period');
    if n >= 3
    then p:=p+1; r:=r||E'\n[نجح] ت١٨ الخط الزمني يحتوي '||n||' فترة محسوبة';
    else f:=f+1; r:=r||E'\n[فشل] ت١٨ عدد الفترات='||n; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت١٨: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت١٩: إنهاء الشيفت
  begin
    js := public.eo_end_shift('نهاية اختبار');
    if js -> 'session' = 'null'::jsonb
       and (select status from emp_ops.attendance_sessions where id=sid)='closed'
       and (select count(*) from emp_ops.attendance_sessions where employee_id=e1 and status='open')=0
    then p:=p+1; r:=r||E'\n[نجح] ت١٩ أُغلق الشيفت بنجاح';
    else f:=f+1; r:=r||E'\n[فشل] ت١٩'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت١٩: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٢٠: إنهاء شيفت غير مفتوح
  begin
    js := public.eo_end_shift();
    f:=f+1; r:=r||E'\n[فشل] ت٢٠ سُمح بإنهاء شيفت غير مفتوح!';
  exception
    when sqlstate 'EO002' then p:=p+1; r:=r||E'\n[نجح] ت٢٠ رُفض إنهاء شيفت غير قائم (EO002)';
    when others then f:=f+1; r:=r||E'\n[خطأ] ت٢٠ '||sqlstate||': '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٢١: لا يُحتسب نشاط بعد إغلاق الشيفت
  begin
    js := public.eo_ingest_activity('{"device_id":"dev-A","interactions":9}'::jsonb);
    if js ->> 'status' = 'no_session'
    then p:=p+1; r:=r||E'\n[نجح] ت٢١ رُفض النشاط خارج الشيفت';
    else f:=f+1; r:=r||E'\n[فشل] ت٢١ الحالة='||coalesce(js->>'status','?'); end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٢١: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٢٢: الإحصاءات اليومية تطابق الجداول الخام
  begin
    perform emp_ops.recompute_daily_stats(e1, emp_ops.work_date_of(e1, now()));
    select active_seconds into n from emp_ops.employee_daily_stats
     where employee_id=e1 and work_date=emp_ops.work_date_of(e1, now());
    select coalesce(sum(seconds),0) into secs from emp_ops.activity_minutes where employee_id=e1;
    if n = secs and n > 0
    then p:=p+1; r:=r||E'\n[نجح] ت٢٢ الإحصاءة اليومية = مجموع دقائق النشاط ('||n||'ث)';
    else f:=f+1; r:=r||E'\n[فشل] ت٢٢ إحصاءة='||n||' خام='||secs; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٢٢: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٢٣: سجل التدقيق سجّل كل العمليات الحساسة
  begin
    select count(*) into n from emp_ops.audit_logs
     where actor_employee_id = e1
       and action in ('shift.start','shift.end','break.start','break.end');
    if n = 4
    then p:=p+1; r:=r||E'\n[نجح] ت٢٣ سُجّلت ٤ عمليات في سجل التدقيق';
    else f:=f+1; r:=r||E'\n[فشل] ت٢٣ عدد السجلات='||n; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٢٣: '||sqlerrm; end;

  ---------------------------------------------------------------
  -- ت٢٤: الإغلاق التلقائي يستخدم آخر نبضة موثوقة لا "الآن"
  begin
    js := public.eo_start_shift('{"device_id":"dev-Z"}'::jsonb);
    sid := (js -> 'session' ->> 'id')::uuid;
    update emp_ops.attendance_sessions set started_at = now() - interval '20 hours' where id = sid;
    update emp_ops.employee_runtime_state
       set last_heartbeat_at = now() - interval '15 hours',
           last_interaction_at = now() - interval '15 hours',
           marked_until = now() - interval '15 hours'
     where employee_id = e1;
    n := emp_ops.close_stale_sessions();
    select emp_ops.session_seconds(started_at, ended_at) into secs
      from emp_ops.attendance_sessions where id = sid;
    if (select status from emp_ops.attendance_sessions where id=sid) = 'auto_closed'
       and secs between 17000 and 19000
    then p:=p+1; r:=r||E'\n[نجح] ت٢٤ الإغلاق التلقائي أنهى الشيفت عند آخر نبضة ('||secs||'ث ≈ ٥ ساعات)';
    else f:=f+1; r:=r||E'\n[فشل] ت٢٤ الحالة='||(select status from emp_ops.attendance_sessions where id=sid)||' المدة='||secs; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ت٢٤: '||sqlerrm; end;

  raise exception E'\n════════ تقرير اختبار محرك الحضور والنشاط ════════%\n\nنجح: %   فشل: %\n', r, p, f;
end $$;
