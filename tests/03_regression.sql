-- ═══════════════════════════════════════════════════════════════
-- اختبار الانحدار — يُشغَّل بعد أي تعديل على دوال القراءة أو المحرك
--
-- يتأكد أن المسار الكامل ما زال يعمل من طرف إلى طرف: بدء شيفت، نبضات من
-- جهازين وتطبيقين، ثم كل واجهات القراءة الإدارية والتقارير والصيانة.
--
-- كالمعتاد: معاملة واحدة تنتهي بـ RAISE EXCEPTION متعمَّد ⇒ لا أثر باقٍ.
-- ═══════════════════════════════════════════════════════════════
do $$
declare
  r text := ''; p int := 0; f int := 0;
  u1 uuid; u2 uuid; e1 uuid; e2 uuid; js jsonb; sid uuid; n int;
begin
  select id into u1 from auth.users where id not in (select user_id from emp_ops.employees where user_id is not null) order by created_at limit 1;
  select id into u2 from auth.users where id not in (select user_id from emp_ops.employees where user_id is not null) and id <> u1 order by created_at limit 1;
  insert into emp_ops.employees (user_id, full_name, email, role) values (u1,'موظف','reg1@test.invalid','employee') returning id into e1;
  insert into emp_ops.employees (user_id, full_name, email, role) values (u2,'مدير','reg2@test.invalid','manager') returning id into e2;
  perform set_config('request.jwt.claims', json_build_object('sub',u1::text,'email','reg1@test.invalid','role','authenticated')::text, true);

  -- ر1: جهازان مميزان رغم ثلاث جلسات نشاط (جهاز A من تطبيقين + جهاز B)
  begin
    js := public.eo_start_shift('{"device_id":"A"}'::jsonb);
    sid := (js->'session'->>'id')::uuid;
    perform public.eo_ingest_activity('{"device_id":"A","interactions":2}'::jsonb);
    perform public.eo_ingest_activity('{"device_id":"A","source_app":"mad3oom","interactions":1,"events":[{"type":"ticket_open","entity_id":"1"}]}'::jsonb);
    perform public.eo_ingest_activity('{"device_id":"B","interactions":1}'::jsonb);
    js := public.eo_me();
    select count(*) into n from emp_ops.activity_sessions where attendance_session_id = sid;
    if (js->'session'->>'active_devices')::int = 2 and n = 3
    then p:=p+1; r:=r||E'\n[نجح] ر1 عدّاد الأجهزة = 2 رغم 3 جلسات نشاط';
    else f:=f+1; r:=r||E'\n[فشل] ر1 أجهزة='||(js->'session'->>'active_devices')||' صفوف='||n; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر1: '||sqlerrm; end;

  -- ر2: eo_me يُعيد الحالة كاملة
  begin
    if js->>'presence'='active' and (js->'totals'->>'shift_seconds') is not null
       and js->'employee'->>'role_label' = 'موظف' and js->'settings'->>'timezone' = 'Africa/Cairo'
    then p:=p+1; r:=r||E'\n[نجح] ر2 eo_me يُعيد الحالة والإجماليات والإعدادات كاملة';
    else f:=f+1; r:=r||E'\n[فشل] ر2 '||js::text; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر2: '||sqlerrm; end;

  -- ر3: لوحة الإدارة
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',u2::text,'email','reg2@test.invalid','role','authenticated')::text, true);
    select count(*) into n from public.eo_admin_employees_live() where active_devices = 2;
    if n = 1 then p:=p+1; r:=r||E'\n[نجح] ر3 لوحة الإدارة تعرض عدّاد الأجهزة الصحيح';
    else f:=f+1; r:=r||E'\n[فشل] ر3 صفوف بجهازين='||n; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر3: '||sqlerrm; end;

  -- ر4: كشف تعدد الأجهزة
  begin
    select count(*) into n from public.eo_admin_multi_device();
    if n = 1 then p:=p+1; r:=r||E'\n[نجح] ر4 كشف تعدد الأجهزة يعمل';
    else f:=f+1; r:=r||E'\n[فشل] ر4 n='||n; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر4: '||sqlerrm; end;

  -- ر5: نظرة عامة
  begin
    js := public.eo_admin_overview();
    if (js->'live'->>'working')::int >= 1 and (js->'today'->>'sessions_count')::int >= 1
    then p:=p+1; r:=r||E'\n[نجح] ر5 eo_admin_overview يعمل';
    else f:=f+1; r:=r||E'\n[فشل] ر5 '||js::text; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر5: '||sqlerrm; end;

  -- ر6: تفاصيل الموظف
  begin
    js := public.eo_admin_employee_detail(e1, null);
    if jsonb_array_length(js->'sessions')=1 and jsonb_array_length(js->'devices')=3
    then p:=p+1; r:=r||E'\n[نجح] ر6 تفاصيل الموظف تعمل';
    else f:=f+1; r:=r||E'\n[فشل] ر6'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر6: '||sqlerrm; end;

  -- ر7: القوائم المرجعية
  begin
    js := public.eo_lists();
    if jsonb_array_length(js->'roles')=3 and jsonb_array_length(js->'shifts')>=1
    then p:=p+1; r:=r||E'\n[نجح] ر7 القوائم المرجعية تعمل';
    else f:=f+1; r:=r||E'\n[فشل] ر7'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر7: '||sqlerrm; end;

  -- ر8: التقرير
  begin
    js := public.eo_report(current_date - 7, current_date, null, null);
    if jsonb_array_length(js->'employees') >= 1 and (js->'summary'->>'shift_seconds') is not null
    then p:=p+1; r:=r||E'\n[نجح] ر8 التقرير يعمل ('||jsonb_array_length(js->'employees')||' موظفًا)';
    else f:=f+1; r:=r||E'\n[فشل] ر8 '||js::text; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر8: '||sqlerrm; end;

  -- ر9: سجل التدقيق
  begin
    select count(*) into n from public.eo_admin_audit_logs(null,null,null,null,50,0);
    if n >= 1 then p:=p+1; r:=r||E'\n[نجح] ر9 سجل التدقيق يُقرأ ('||n||' سجلًا)';
    else f:=f+1; r:=r||E'\n[فشل] ر9'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر9: '||sqlerrm; end;

  -- ر10: الخط الزمني
  begin
    select count(*) into n from emp_ops.timeline(e1, emp_ops.work_date_of(e1, now()));
    if n >= 1 then p:=p+1; r:=r||E'\n[نجح] ر10 الخط الزمني يعمل ('||n||' عنصرًا)';
    else f:=f+1; r:=r||E'\n[فشل] ر10'; end if;
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر10: '||sqlerrm; end;

  -- ر11: مهام الصيانة الدورية
  begin
    n := emp_ops.refresh_presence();
    js := emp_ops.maintenance_tick();
    p:=p+1; r:=r||E'\n[نجح] ر11 مهام الصيانة تعمل ('||js::text||')';
  exception when others then f:=f+1; r:=r||E'\n[خطأ] ر11: '||sqlerrm; end;

  raise exception E'\n======== تقرير الانحدار ========%\n\nنجح: %   فشل: %\n', r, p, f;
end $$;
