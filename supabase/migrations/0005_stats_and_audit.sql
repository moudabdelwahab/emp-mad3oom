-- 0005 — الإحصاءات اليومية وسجل التدقيق

create table if not exists emp_ops.employee_daily_stats (
  employee_id     uuid not null references emp_ops.employees(id) on delete cascade,
  work_date       date not null,
  first_start_at  timestamptz,
  last_end_at     timestamptz,
  sessions_count  integer not null default 0,
  breaks_count    integer not null default 0,
  shift_seconds   integer not null default 0 check (shift_seconds  >= 0),
  break_seconds   integer not null default 0 check (break_seconds  >= 0),
  active_seconds  integer not null default 0 check (active_seconds >= 0),
  idle_seconds    integer not null default 0 check (idle_seconds   >= 0),
  active_pct      numeric(5,2),
  late_seconds    integer not null default 0 check (late_seconds >= 0),
  is_late         boolean not null default false,
  is_absent       boolean not null default false,
  had_open_session boolean not null default false,
  computed_at     timestamptz not null default now(),
  primary key (employee_id, work_date)
);
create index if not exists daily_stats_date_idx on emp_ops.employee_daily_stats (work_date desc);

comment on table emp_ops.employee_daily_stats is
  'لقطة محسوبة من الجداول الخام. يمكن إعادة بنائها بالكامل في أي وقت — ليست مصدر حقيقة مستقلًا.';

-- ─────────────────────────────────────────────────────────────
-- سجل التدقيق — للإلحاق فقط، لا يملك أي مستخدم صلاحية تعديله أو حذفه
create table if not exists emp_ops.audit_logs (
  id            bigint generated always as identity primary key,
  occurred_at   timestamptz not null default now(),
  actor_employee_id uuid references emp_ops.employees(id) on delete set null,
  actor_user_id uuid,
  actor_name    text,
  actor_role    text,
  action        text not null,
  target_type   text,
  target_id     text,
  target_label  text,
  ip            inet,
  user_agent    text,
  metadata      jsonb not null default '{}'::jsonb
);
create index if not exists audit_logs_time_idx   on emp_ops.audit_logs (occurred_at desc);
create index if not exists audit_logs_actor_idx  on emp_ops.audit_logs (actor_employee_id, occurred_at desc);
create index if not exists audit_logs_action_idx on emp_ops.audit_logs (action, occurred_at desc);
create index if not exists audit_logs_target_idx on emp_ops.audit_logs (target_type, target_id);

drop trigger if exists trg_audit_logs_immutable on emp_ops.audit_logs;
create trigger trg_audit_logs_immutable
  before update or delete on emp_ops.audit_logs
  for each row execute function emp_ops.deny_mutation();

comment on table emp_ops.audit_logs is
  'سجل تدقيق غير قابل للتعديل أو الحذف — يفرضه trigger على مستوى قاعدة البيانات، لا على مستوى الواجهة.';

-- أسماء عربية للعمليات المُدقَّقة (كتالوج قابل للتوسع)
create table if not exists emp_ops.audit_actions (
  code     text primary key,
  name_ar  text not null,
  severity text not null default 'info' check (severity in ('info','notice','warning','critical'))
);

insert into emp_ops.audit_actions (code, name_ar, severity) values
  ('auth.login',            'تسجيل دخول',                 'info'),
  ('auth.logout',           'تسجيل خروج',                 'info'),
  ('auth.denied',           'محاولة وصول مرفوضة',         'warning'),
  ('shift.start',           'بدء شيفت',                   'info'),
  ('shift.end',             'إنهاء شيفت',                 'info'),
  ('shift.auto_close',      'إغلاق تلقائي لشيفت',         'notice'),
  ('shift.force_end',       'إنهاء شيفت بواسطة الإدارة',  'warning'),
  ('break.start',           'بدء استراحة',                'info'),
  ('break.end',             'إنهاء استراحة',              'info'),
  ('break.auto_close',      'إغلاق تلقائي لاستراحة',      'notice'),
  ('attendance.adjust',     'تعديل سجل حضور',             'critical'),
  ('employee.create',       'إنشاء موظف',                 'notice'),
  ('employee.update',       'تعديل بيانات موظف',          'notice'),
  ('employee.role_change',  'تغيير دور موظف',             'critical'),
  ('employee.status_change','تغيير حالة موظف',            'critical'),
  ('team.create',           'إنشاء فريق',                 'notice'),
  ('team.update',           'تعديل فريق',                 'notice'),
  ('shift_template.create', 'إنشاء قالب شيفت',            'notice'),
  ('shift_template.update', 'تعديل قالب شيفت',            'notice'),
  ('shift_assignment.set',  'إسناد شيفت لموظف',           'notice'),
  ('settings.update',       'تعديل إعدادات النظام',       'critical'),
  ('report.export',         'تصدير تقرير',                'notice')
on conflict (code) do nothing;

-- ─────────────────────────────────────────────────────────────
-- دالة التدقيق الداخلية — تُستدعى من كل دالة تُغيّر حالة
create or replace function emp_ops.audit(
  p_actor        emp_ops.employees,
  p_action       text,
  p_target_type  text default null,
  p_target_id    text default null,
  p_target_label text default null,
  p_metadata     jsonb default '{}'::jsonb
) returns bigint
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare v_id bigint;
begin
  insert into emp_ops.audit_logs (
    actor_employee_id, actor_user_id, actor_name, actor_role,
    action, target_type, target_id, target_label, metadata,
    ip, user_agent
  ) values (
    p_actor.id, p_actor.user_id, p_actor.full_name, p_actor.role,
    p_action, p_target_type, p_target_id, p_target_label, coalesce(p_metadata, '{}'::jsonb),
    nullif(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), '')::inet,
    nullif(current_setting('request.headers', true)::json ->> 'user-agent', '')
  ) returning id into v_id;
  return v_id;
exception
  when others then
    -- لا يجوز أن يُسقط فشلُ التدقيق العمليةَ نفسها، لكن لا يجوز أن يمرّ صامتًا أيضًا
    insert into emp_ops.audit_logs (action, metadata)
    values ('audit.failure', jsonb_build_object('original_action', p_action, 'error', sqlerrm))
    returning id into v_id;
    return v_id;
end $$;
