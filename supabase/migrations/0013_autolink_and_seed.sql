-- 0013 — الربط التلقائي بالحساب + البذرة الأولى (مدير عام + شيفت افتراضي)

-- ─────────────────────────────────────────────────────────────
-- الربط التلقائي: تُنشئ الإدارة سجل الموظف ببريده قبل أن يكون له حساب،
-- وعند أول دخول له يُربط السجل بحسابه تلقائيًا اعتمادًا على البريد الموجود
-- داخل الـ JWT الموقَّع من Supabase (وليس على أي مدخل من العميل).
-- ملاحظة: لا يوجد أي trigger على auth.users — منصة مدعوم لا تُمسّ إطلاقًا.
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.try_link_current_user()
returns emp_ops.employees
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_row   emp_ops.employees;
begin
  if v_uid is null then
    return null;
  end if;

  select * into v_row from emp_ops.employees where user_id = v_uid limit 1;
  if found then
    return v_row;
  end if;

  -- البريد من داخل الـ JWT، ثم من auth.users كاحتياطي
  v_email := lower(btrim(coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email',
    (select email from auth.users where id = v_uid)
  )));

  if v_email is null or v_email = '' then
    return null;
  end if;

  update emp_ops.employees
     set user_id = v_uid
   where user_id is null and lower(email) = v_email
  returning * into v_row;

  if found then
    insert into emp_ops.audit_logs (actor_employee_id, actor_user_id, actor_name, actor_role,
                                    action, target_type, target_id, target_label, metadata)
    values (v_row.id, v_uid, v_row.full_name, v_row.role,
            'employee.update', 'employee', v_row.id::text, v_row.full_name,
            jsonb_build_object('auto_linked', true, 'email', v_email));
  end if;

  return v_row;
end $$;

-- eo_me تصبح غير ثابتة لأنها قد تنفّذ الربط التلقائي عند أول دخول
create or replace function public.eo_me()
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v emp_ops.employees;
begin
  perform emp_ops.try_link_current_user();
  v := emp_ops.require_employee();
  return emp_ops.employee_status_json(v.id);
end $$;

revoke all on function public.eo_me() from public, anon;
grant execute on function public.eo_me() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- البذرة: مدير عام أول (بدونه لا يستطيع أحد إدارة النظام)
-- ─────────────────────────────────────────────────────────────
insert into emp_ops.employees (user_id, full_name, email, role, status, timezone, employee_code)
select u.id, coalesce(nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''), 'المدير العام'),
       lower(u.email), 'super_admin', 'active', 'Africa/Cairo', 'EMP-0001'
from auth.users u
where lower(u.email) = 'mahmoudabdelwahabsa@gmail.com'
on conflict (user_id) do nothing;

-- شيفت افتراضي (الأحد–الخميس ٩ص–٥م بتوقيت القاهرة)
insert into emp_ops.shifts (name_ar, start_time, end_time, work_days, grace_minutes, timezone)
values ('الشيفت الصباحي', '09:00', '17:00', '{0,1,2,3,4}', 10, 'Africa/Cairo')
on conflict (name_ar) do nothing;
