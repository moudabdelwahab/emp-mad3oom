-- 0016 — القوائم المرجعية في نداء واحد
--
-- جداول emp_ops غير مكشوفة عبر PostgREST عمدًا (طبقة حماية إضافية)،
-- لذلك حتى قراءة القوائم المرجعية تمرّ عبر دالة في مخطط public.

create or replace function public.eo_lists()
returns jsonb
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v emp_ops.employees; v_manage boolean;
begin
  v := emp_ops.require_employee();
  v_manage := emp_ops.can_manage();

  return jsonb_build_object(
    'roles', (select coalesce(jsonb_agg(jsonb_build_object(
                'code', code, 'name_ar', name_ar, 'rank', rank) order by rank), '[]'::jsonb)
              from emp_ops.roles),
    'teams', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', id, 'name_ar', name_ar, 'is_active', is_active) order by name_ar), '[]'::jsonb)
              from emp_ops.teams where is_active or v_manage),
    'shifts', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', id, 'name_ar', name_ar, 'start_time', start_time, 'end_time', end_time,
                'work_days', work_days, 'grace_minutes', grace_minutes, 'is_active', is_active)
                order by name_ar), '[]'::jsonb)
               from emp_ops.shifts),
    'activity_types', (select coalesce(jsonb_agg(jsonb_build_object(
                'code', code, 'name_ar', name_ar, 'category', category,
                'counts_as_interaction', counts_as_interaction) order by category, name_ar), '[]'::jsonb)
               from emp_ops.activity_types where is_active),
    'audit_actions', case when v_manage then
               (select coalesce(jsonb_agg(jsonb_build_object(
                'code', code, 'name_ar', name_ar, 'severity', severity) order by name_ar), '[]'::jsonb)
                from emp_ops.audit_actions) else '[]'::jsonb end,
    'employees', case when v_manage then
               (select coalesce(jsonb_agg(jsonb_build_object(
                'id', id, 'full_name', full_name, 'role', role, 'status', status) order by full_name), '[]'::jsonb)
                from emp_ops.employees where status <> 'archived') else '[]'::jsonb end
  );
end $$;

revoke all on function public.eo_lists() from public, anon;
grant execute on function public.eo_lists() to authenticated;
