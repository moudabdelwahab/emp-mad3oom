-- ═══════════════════════════════════════════════════════════════
-- اختبارات الأمان وسلامة البيانات
--
-- تفحص هذه المجموعة الادعاء الأهم في النظام: أن الحماية مفروضة من قاعدة
-- البيانات لا من الواجهة. لذلك تنتحل هوية موظف حقيقي (set local role
-- authenticated + request.jwt.claims) وتحاول فعليًا:
--   القراءة عبر الحدود · الكتابة المباشرة · تزوير الأوقات · رفع الرتبة
--   · العبث بسجل التدقيق · تجاوز قيود سلامة البيانات
--
-- كل شيء داخل معاملة واحدة تنتهي بـ RAISE EXCEPTION متعمَّد ⇒ لا أثر باقٍ.
-- ═══════════════════════════════════════════════════════════════
do $$
declare
  r text := ''; p int := 0; f int := 0;
  u1 uuid; u2 uuid; u3 uuid; e1 uuid; e2 uuid; e3 uuid;
  js jsonb; sid uuid; n int;
begin
  select id into u1 from auth.users where id not in (select user_id from emp_ops.employees where user_id is not null) order by created_at limit 1;
  select id into u2 from auth.users where id not in (select user_id from emp_ops.employees where user_id is not null) and id <> u1 order by created_at limit 1;
  select id into u3 from auth.users where id not in (select user_id from emp_ops.employees where user_id is not null) and id <> u1 and id <> u2 order by created_at limit 1;

  insert into emp_ops.employees (user_id, full_name, email, role) values (u1,'موظف أ','sec-a@test.invalid','employee') returning id into e1;
  insert into emp_ops.employees (user_id, full_name, email, role) values (u2,'موظف ب','sec-b@test.invalid','employee') returning id into e2;
  insert into emp_ops.employees (user_id, full_name, email, role) values (u3,'مدير ج','sec-c@test.invalid','manager') returning id into e3;

  perform set_config('request.jwt.claims', json_build_object('sub',u1::text,'email','sec-a@test.invalid','role','authenticated')::text, true);
  js := public.eo_start_shift('{"device_id":"d1"}'::jsonb);
  sid := (js->'session'->>'id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub',u2::text,'email','sec-b@test.invalid','role','authenticated')::text, true);
  perform public.eo_start_shift('{"device_id":"d2"}'::jsonb);
  perform set_config('request.jwt.claims', json_build_object('sub',u1::text,'email','sec-a@test.invalid','role','authenticated')::text, true);

  -- ح1: الموظف يرى نفسه فقط في جدول الموظفين
  begin
    execute 'set local role authenticated';
    select count(*) into n from emp_ops.employees;
    execute 'reset role';
    if n = 1 then p:=p+1; r:=r||E'\n[نجح] ح1 الموظف يرى سجله فقط في employees (RLS)';
    else f:=f+1; r:=r||E'\n[فشل] ح1 رأى '||n||' سجلًا'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح1: '||sqlerrm; end;

  -- ح2: الموظف لا يرى حضور موظف آخر
  begin
    execute 'set local role authenticated';
    select count(*) into n from emp_ops.attendance_sessions where employee_id = e2;
    execute 'reset role';
    if n = 0 then p:=p+1; r:=r||E'\n[نجح] ح2 لا يرى حضور زميله (RLS)';
    else f:=f+1; r:=r||E'\n[فشل] ح2 رأى '||n||' جلسة'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح2: '||sqlerrm; end;

  -- ح3: الموظف لا يرى دقائق نشاط زميله
  begin
    execute 'set local role authenticated';
    select count(*) into n from emp_ops.activity_minutes where employee_id = e2;
    execute 'reset role';
    if n = 0 then p:=p+1; r:=r||E'\n[نجح] ح3 لا يرى دقائق نشاط زميله';
    else f:=f+1; r:=r||E'\n[فشل] ح3'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح3: '||sqlerrm; end;

  -- ح4: لا إدراج مباشر لجلسة حضور
  begin
    execute 'set local role authenticated';
    execute format('insert into emp_ops.attendance_sessions (employee_id, work_date) values (%L, current_date)', e1);
    execute 'reset role';
    f:=f+1; r:=r||E'\n[فشل] ح4 نجح الإدراج المباشر!';
  exception when insufficient_privilege then p:=p+1; r:=r||E'\n[نجح] ح4 مُنع الإدراج المباشر (42501)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح4 '||sqlstate||': '||sqlerrm; end;

  -- ح5: لا تزوير لوقت بداية الشيفت
  begin
    execute 'set local role authenticated';
    execute format('update emp_ops.attendance_sessions set started_at = now() - interval ''8 hours'' where id = %L', sid);
    execute 'reset role';
    f:=f+1; r:=r||E'\n[فشل] ح5 نجح تعديل وقت البداية!';
  exception when insufficient_privilege then p:=p+1; r:=r||E'\n[نجح] ح5 مُنع تزوير وقت بداية الشيفت (42501)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح5 '||sqlstate||': '||sqlerrm; end;

  -- ح6: لا حذف لسجل حضور
  begin
    execute 'set local role authenticated';
    execute format('delete from emp_ops.attendance_sessions where id = %L', sid);
    execute 'reset role';
    f:=f+1; r:=r||E'\n[فشل] ح6 نجح حذف سجل الحضور!';
  exception when insufficient_privilege then p:=p+1; r:=r||E'\n[نجح] ح6 مُنع حذف سجل الحضور (42501)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح6 '||sqlstate||': '||sqlerrm; end;

  -- ح7: لا تضخيم لدقائق النشاط
  begin
    execute 'set local role authenticated';
    execute format('update emp_ops.activity_minutes set seconds = 60 where employee_id = %L', e1);
    execute 'reset role';
    f:=f+1; r:=r||E'\n[فشل] ح7 نجح تضخيم دقائق النشاط!';
  exception when insufficient_privilege then p:=p+1; r:=r||E'\n[نجح] ح7 مُنع تضخيم وقت النشاط (42501)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح7 '||sqlstate||': '||sqlerrm; end;

  -- ح8: لا حذف لسجل التدقيق
  begin
    execute 'set local role authenticated';
    execute 'delete from emp_ops.audit_logs';
    execute 'reset role';
    f:=f+1; r:=r||E'\n[فشل] ح8 نجح حذف سجل التدقيق!';
  exception when insufficient_privilege then p:=p+1; r:=r||E'\n[نجح] ح8 مُنع حذف سجل التدقيق (42501)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح8 '||sqlstate||': '||sqlerrm; end;

  -- ح9: لا رفع للرتبة ذاتيًا
  begin
    execute 'set local role authenticated';
    execute format('update emp_ops.employees set role = ''super_admin'' where id = %L', e1);
    execute 'reset role';
    f:=f+1; r:=r||E'\n[فشل] ح9 نجح رفع الرتبة ذاتيًا!';
  exception when insufficient_privilege then p:=p+1; r:=r||E'\n[نجح] ح9 مُنع رفع الرتبة ذاتيًا (42501)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح9 '||sqlstate||': '||sqlerrm; end;

  -- ح10: الموظف لا ينادي واجهات الإدارة
  begin
    perform public.eo_admin_employees_live();
    f:=f+1; r:=r||E'\n[فشل] ح10 الموظف وصل إلى لوحة الإدارة!';
  exception when sqlstate 'EO403' then p:=p+1; r:=r||E'\n[نجح] ح10 رُفض وصول الموظف للوحة الإدارة (EO403)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح10 '||sqlstate||': '||sqlerrm; end;

  -- ح11: الموظف لا يرى تفاصيل زميله
  begin
    perform public.eo_admin_employee_detail(e2);
    f:=f+1; r:=r||E'\n[فشل] ح11 الموظف رأى تفاصيل زميله!';
  exception when sqlstate 'EO403' then p:=p+1; r:=r||E'\n[نجح] ح11 رُفضت محاولة رؤية تفاصيل زميل (EO403)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح11 '||sqlstate||': '||sqlerrm; end;

  -- ح12: الموظف لا يغيّر الإعدادات
  begin
    perform public.eo_admin_set_setting('idle_threshold_seconds', '60'::jsonb);
    f:=f+1; r:=r||E'\n[فشل] ح12 الموظف غيّر إعدادات النظام!';
  exception when sqlstate 'EO403' then p:=p+1; r:=r||E'\n[نجح] ح12 رُفض تغيير الإعدادات (EO403)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح12 '||sqlstate||': '||sqlerrm; end;

  -- ح13: تقرير الموظف يُقصر قسرًا على بياناته حتى لو طلب زميله
  begin
    js := public.eo_report(current_date - 1, current_date, e2, null);
    if jsonb_array_length(js->'employees') <= 1
       and coalesce(js->'employees'->0->>'employee_id', e1::text) = e1::text
    then p:=p+1; r:=r||E'\n[نجح] ح13 التقرير أُعيد توجيهه إلى بيانات الطالب نفسه';
    else f:=f+1; r:=r||E'\n[فشل] ح13 '||(js->'employees')::text; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح13: '||sqlerrm; end;

  -- ح14: المدير يرى كل الموظفين
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',u3::text,'email','sec-c@test.invalid','role','authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into n from emp_ops.employees;
    execute 'reset role';
    if n >= 3 then p:=p+1; r:=r||E'\n[نجح] ح14 المدير يرى كل الموظفين ('||n||')';
    else f:=f+1; r:=r||E'\n[فشل] ح14 رأى '||n; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح14: '||sqlerrm; end;

  -- ح15: المدير لا يغيّر الأدوار (تحتاج مديرًا عامًا)
  begin
    perform public.eo_admin_set_role(e1, 'super_admin');
    f:=f+1; r:=r||E'\n[فشل] ح15 المدير غيّر دورًا!';
  exception when sqlstate 'EO403' then p:=p+1; r:=r||E'\n[نجح] ح15 رُفض تغيير الأدوار من المدير (EO403)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح15 '||sqlstate||': '||sqlerrm; end;

  -- ح16: المدير يفتح لوحة الإدارة
  begin
    select count(*) into n from public.eo_admin_employees_live();
    if n >= 3 then p:=p+1; r:=r||E'\n[نجح] ح16 المدير فتح لوحة الإدارة ('||n||' صفًا)';
    else f:=f+1; r:=r||E'\n[فشل] ح16 صفوف='||n; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح16: '||sqlerrm; end;

  -- ح17: الموظف الموقوف يُمنع من كل شيء
  begin
    update emp_ops.employees set status='suspended' where id = e1;
    perform set_config('request.jwt.claims', json_build_object('sub',u1::text,'email','sec-a@test.invalid','role','authenticated')::text, true);
    perform public.eo_end_shift();
    f:=f+1; r:=r||E'\n[فشل] ح17 الموظف الموقوف نفّذ عملية!';
  exception when sqlstate 'EO403' then p:=p+1; r:=r||E'\n[نجح] ح17 الموظف الموقوف مُنع تمامًا (EO403)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح17 '||sqlstate||': '||sqlerrm; end;

  -- ح18: الزائر غير المسجَّل لا يملك أي وصول
  begin
    update emp_ops.employees set status='active' where id = e1;
    execute 'set local role anon';
    select count(*) into n from emp_ops.employees;
    execute 'reset role';
    f:=f+1; r:=r||E'\n[فشل] ح18 anon قرأ جدول الموظفين!';
  exception when insufficient_privilege then p:=p+1; r:=r||E'\n[نجح] ح18 مُنع anon من الوصول للمخطط (42501)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح18 '||sqlstate||': '||sqlerrm; end;

  -- ح19: الإعدادات الداخلية محجوبة عن الموظف
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',u1::text,'email','sec-a@test.invalid','role','authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into n from emp_ops.app_settings where not is_public;
    execute 'reset role';
    if n = 0 then p:=p+1; r:=r||E'\n[نجح] ح19 الإعدادات الداخلية محجوبة عن الموظف';
    else f:=f+1; r:=r||E'\n[فشل] ح19 رأى '||n||' إعدادًا داخليًا'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ح19: '||sqlerrm; end;

  -- ح20: سجل التدقيق غير قابل للتعديل حتى من مالك الجدول
  begin
    update emp_ops.audit_logs set action = 'tampered' where id = (select min(id) from emp_ops.audit_logs);
    f:=f+1; r:=r||E'\n[فشل] ح20 عُدِّل سجل التدقيق من postgres!';
  exception when sqlstate 'EO090' then p:=p+1; r:=r||E'\n[نجح] ح20 trigger منع تعديل سجل التدقيق حتى من المالك';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح20 '||sqlstate||': '||sqlerrm; end;

  -- ح21: سجل أحداث الحضور غير قابل للحذف
  begin
    delete from emp_ops.attendance_events where attendance_session_id = sid;
    f:=f+1; r:=r||E'\n[فشل] ح21 حُذفت أحداث الحضور!';
  exception when sqlstate 'EO090' then p:=p+1; r:=r||E'\n[نجح] ح21 مُنع حذف أحداث الحضور';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح21 '||sqlstate||': '||sqlerrm; end;

  -- ح22: السجل المغلق محمي من التعديل خارج المسار الإداري الموثَّق
  begin
    perform public.eo_end_shift();
    update emp_ops.attendance_sessions set ended_at = now() + interval '5 hours' where id = sid;
    f:=f+1; r:=r||E'\n[فشل] ح22 عُدِّل سجل مغلق مباشرة!';
  exception when sqlstate 'EO091' then p:=p+1; r:=r||E'\n[نجح] ح22 مُنع تعديل السجل المغلق (EO091)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح22 '||sqlstate||': '||sqlerrm; end;

  -- ح23: قيد المدة السالبة
  begin
    insert into emp_ops.attendance_sessions (employee_id, work_date, started_at, ended_at, status)
    values (e2, current_date, now(), now() - interval '1 hour', 'closed');
    f:=f+1; r:=r||E'\n[فشل] ح23 قُبلت مدة سالبة!';
  exception when check_violation then p:=p+1; r:=r||E'\n[نجح] ح23 رُفضت المدة السالبة (check constraint)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح23 '||sqlstate||': '||sqlerrm; end;

  -- ح24: قيد الشيفت المفتوح الواحد
  begin
    insert into emp_ops.attendance_sessions (employee_id, work_date) values (e2, current_date);
    f:=f+1; r:=r||E'\n[فشل] ح24 قُبل شيفت مفتوح ثانٍ!';
  exception when unique_violation then p:=p+1; r:=r||E'\n[نجح] ح24 رُفض الشيفت المفتوح الثاني (unique index)';
       when others then f:=f+1; r:=r||E'\n[خطأ] ح24 '||sqlstate||': '||sqlerrm; end;

  raise exception E'\n======== تقرير اختبارات الأمان وسلامة البيانات ========%\n\nنجح: %   فشل: %\n', r, p, f;
end $$;
