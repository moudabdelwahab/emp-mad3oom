-- 0019 — عدالة قياس النشاط: حضور من مستويين، رجوع حدث الشغل،
--        إنهاء استراحة منسية، سبب الخمول في الخط الزمني،
--        طلبات تصحيح، تنبيه الشيفت المنسي
--
-- السياق: بعد التدقيق الحي (2026-11-26) تبيّن أن النظام دقيق فيما يدّعي
-- قياسه — "ثوانٍ داخل مدعوم والتبويب ظاهر وعليه تركيز، مربوطة بتفاعل
-- خلال آخر ٥ دقائق" — لكنه يظلم العمل الحقيقي الهادئ: قراءة تذكرة طويلة،
-- مكالمة هاتفية، تفكير. هذا الترحيل لا يرخي أي حارس موجود (كل قواعد
-- مكافحة التضخيم تبقى كما هي)، بل يضيف عدسة ثانية للقياس ويصلح ثلاثة
-- أخطاء بشرية متوقعة: الاستراحة المنسية، والشيفت المنسي، والحساب غير المربوط.
--
-- ما يتغيّر:
--   ١) مقياس "الحضور" (present): ثوانٍ كان فيها تبويب مدعوم ظاهرًا وعليه
--      تركيز، سواء تفاعل الموظف أم لا. يُحسب في دفتر أستاذ موازٍ
--      (activity_minutes.present_seconds) بنفس ضمانات دفتر النشاط:
--      قصّ على حدود الشيفت، طرح الاستراحات، سقف ٦٠ ثانية/دقيقة،
--      ولا يُمنح عن فجوة انخراط أكبر من حدّ التغطية.
--      الحضور لا يحلّ محلّ النشاط: نسبة النشاط تبقى كما هي، والحضور
--      يُعرض بجانبها كسياق. خطأ الحضور الوحيد المعروف: فجوة ≤ ٩٠ ثانية
--      في لوحة العمليات قد تُحتسب حضورًا عند العودة إلى مدعوم — حدّ
--      أقصى ٩٠ ثانية لكل مرة، موثّق هنا عمدًا.
--   ٢) رجوع حدث الشغل (backfill): حدث عمل حقيقي (ردّ، تغيير حالة، تعيين…)
--      يثبت أن الدقائق السابقة كانت شغلًا، فيُعتمَد الانخراط المسجَّل
--      في النبضات خلال آخر ١٠ دقائق — لا أكثر، ولا بلا دليل نبضات.
--   ٣) الاستراحة المنسية: حدث عمل حقيقي أثناء استراحة مفتوحة ينهيها
--      تلقائيًا (حالة auto_closed + حدث break_auto_close + تدقيق)
--      لأن نقرة عابرة لا تنهي استراحة، لكن تنفيذ شغل حقيقي يعني أن
--      الاستراحة انتهت فعلًا. النقرات العادية وحدها لا تنهيها.
--   ٤) سبب الخمول في الخط الزمني: كل فترة خمول تحمل سببها المشتق من
--      النبضات (بلا نبضات / حاضر بلا تفاعل / تبويب مخفي / بلا تركيز /
--      في لوحة العمليات) حتى يرى المدير السياق لا الرقم وحده.
--   ٥) طلبات تصحيح: الموظف يطلب اعتماد دقائق من فترة محددة، والإدارة
--      تعتمد أو ترفض — والاعتماد يكتب الدقائق في الدفتر بمصدر
--      'correction' (ظاهر في sources) مع سقف ٦٠ ثانية/دقيقة، لا بتعديل
--      الأوقات يدويًا.
--   ٦) تنبيه الشيفت المنسي: مهمة الصيانة الدورية ترسل إشعارًا إلى جرس
--      مدعوم (public.notifications) إذا بقي الشيفت مفتوحًا بلا نبضات
--      أكثر من ساعة، ويُعاد كل ٦ ساعات حتى يُغلق.
--
-- ما لا يتغيّر: معادلة نسبة النشاط، عتبة الخمول، حدّ التغطية،
-- قاعدة "لا وقت رجعي"، سقف الدقيقة، فصل وقت الشيفت عن وقت النشاط.

-- ─────────────────────────────────────────────────────────────
-- ١) إعدادات جديدة
-- ─────────────────────────────────────────────────────────────
insert into emp_ops.app_settings (key, value, description_ar, value_type, min_value, max_value, is_public) values
  ('work_event_backfill_minutes', '10',
   'عدد الدقائق السابقة لحدث عمل حقيقي التي يُعتمَد انخراطها رجعيًا (0 = معطّل)', 'number', 0, 30, true),
  ('present_coverage_tolerance_seconds', '90',
   'أقصى فجوة بين نبضتين منخرطتين يُسمح باحتساب الحضور عبرها (بالثواني)', 'number', 30, 300, true),
  ('shift_nudge_after_seconds', '3600',
   'مدة الصمت (بلا نبضات) قبل تنبيه الموظف بأن شيفتًا مفتوحًا لديه (بالثواني)', 'number', 600, 86400, true),
  ('shift_nudge_repeat_seconds', '21600',
   'المدة بين تنبيهين متتاليين عن الشيفت نفسه (بالثواني)', 'number', 3600, 86400, true)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────
-- ٢) أفعال تدقيق جديدة
-- ─────────────────────────────────────────────────────────────
insert into emp_ops.audit_actions (code, name_ar, severity) values
  ('correction.request', 'طلب تصحيح نشاط', 'notice'),
  ('correction.approve', 'اعتماد تصحيح نشاط', 'warning'),
  ('correction.reject',  'رفض تصحيح نشاط', 'notice'),
  ('break.auto_end',     'إنهاء استراحة تلقائيًا عند استئناف العمل', 'notice')
on conflict (code) do nothing;

-- ─────────────────────────────────────────────────────────────
-- ٣) المخطط: عمود الحضور في دفتر الدقائق والإحصاءات والحالة
-- ─────────────────────────────────────────────────────────────
alter table emp_ops.activity_minutes
  add column if not exists present_seconds smallint not null default 0
    check (present_seconds between 0 and 60);

-- ثواني النشاط نفسها يجوز أن تكون صفرًا الآن (دقيقة حضور بلا نشاط)،
-- لكن لا يجوز أن تكون الدقيقة فارغة من المقياسين معًا.
alter table emp_ops.activity_minutes drop constraint if exists activity_minutes_seconds_check;
alter table emp_ops.activity_minutes
  add constraint activity_minutes_seconds_check check (seconds between 0 and 60),
  add constraint activity_minutes_not_empty check (seconds > 0 or present_seconds > 0);

comment on column emp_ops.activity_minutes.present_seconds is
  'ثوانٍ كان فيها تبويب مدعوم ظاهرًا وعليه تركيز داخل هذه الدقيقة، سواء تفاعل الموظف أم لا.';

alter table emp_ops.employee_daily_stats
  add column if not exists present_seconds integer not null default 0,
  add column if not exists present_pct numeric;

comment on column emp_ops.employee_daily_stats.present_seconds is
  'مجموع ثواني الحضور في اليوم — عدسة ثانية بجانب وقت النشاط، لا بديل عنه.';

alter table emp_ops.employee_runtime_state
  add column if not exists marked_present_until timestamptz,
  add column if not exists last_engaged_at timestamptz,
  add column if not exists last_shift_nudge_at timestamptz;

comment on column emp_ops.employee_runtime_state.marked_present_until is
  'آخر لحظة تم احتساب الحضور حتى عندها. NULL = لا نافذة حضور متصلة (بعد إغلاق أو استراحة) — النبضة المنخرطة التالية ترسي مرساة جديدة بلا منح رجعي.';
comment on column emp_ops.employee_runtime_state.last_engaged_at is
  'آخر لحظة وصلت فيها نبضة منخرطة (تبويب مدعوم ظاهر وعليه تركيز).';

-- ─────────────────────────────────────────────────────────────
-- ٤) طلبات تصحيح النشاط
-- ─────────────────────────────────────────────────────────────
create table if not exists emp_ops.activity_correction_requests (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references emp_ops.employees(id) on delete cascade,
  attendance_session_id uuid not null references emp_ops.attendance_sessions(id) on delete cascade,
  work_date     date not null,
  period_start  timestamptz not null,
  period_end    timestamptz not null,
  requested_minutes integer not null check (requested_minutes > 0 and requested_minutes <= 480),
  reason        text not null check (char_length(btrim(reason)) >= 10),
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  approved_seconds integer,
  reviewed_by   uuid references emp_ops.employees(id) on delete set null,
  review_note   text,
  created_at    timestamptz not null default now(),
  reviewed_at   timestamptz,
  constraint correction_period_valid check (period_end > period_start)
);
create index if not exists correction_requests_employee_idx on emp_ops.activity_correction_requests (employee_id, work_date desc);
create index if not exists correction_requests_status_idx  on emp_ops.activity_correction_requests (status, created_at desc);

comment on table emp_ops.activity_correction_requests is
  'طلب موظف اعتماد دقائق نشاط من فترة محددة داخل شيفت واحد مغلق أو مفتوح. الاعتماد يكتب الدقائق في الدفتر بمصدر correction — لا يعدّل الأوقات يدويًا.';

-- RLS مفعّل بلا أي سياسة: الوصول المباشر من العميل ممنوع، والواجهات
-- (SECURITY DEFINER) وحدها تقرأ وتكتب — نفس نمط بقية جداول emp_ops.
alter table emp_ops.activity_correction_requests enable row level security;

-- ─────────────────────────────────────────────────────────────
-- ٥) محرك الحضور — مرآة محرك النشاط مع اختلافين فقط:
--     • النافذة تُقاس بالانخراط (ظاهر + Focus) لا بالتفاعل
--     • لا تُمنح ثانية بعد إغلاق النافذة (NULL) إلا بمرساة جديدة
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.mark_present_minutes(
  p_employee_id           uuid,
  p_attendance_session_id uuid,
  p_from                  timestamptz,
  p_to                    timestamptz,
  p_source                text default 'emp_ops'
) returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_from timestamptz;
  v_to   timestamptz;
  v_tz   text;
  v_credited integer := 0;
  v_session emp_ops.attendance_sessions;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    return 0;
  end if;

  select * into v_session from emp_ops.attendance_sessions where id = p_attendance_session_id;
  if not found then
    return 0;
  end if;

  -- القصّ على حدود الشيفت — لا حضور خارج شيفت
  v_from := greatest(p_from, v_session.started_at);
  v_to   := least(p_to, coalesce(v_session.ended_at, now()));
  if v_to <= v_from then
    return 0;
  end if;

  v_tz := emp_ops.employee_timezone(p_employee_id);

  with minutes as (
    select generate_series(
             date_trunc('minute', v_from),
             date_trunc('minute', v_to - interval '1 microsecond'),
             interval '1 minute'
           ) as minute_start
  ),
  base as (
    select m.minute_start,
           greatest(m.minute_start, v_from) as seg_start,
           least(m.minute_start + interval '1 minute', v_to) as seg_end
    from minutes m
  ),
  -- استبعاد أي تداخل مع استراحة داخل نفس الشيفت
  net as (
    select b.minute_start,
           floor(extract(epoch from (b.seg_end - b.seg_start)))::integer
             - coalesce((
                 select floor(sum(extract(epoch from (
                          least(b.seg_end, coalesce(bs.ended_at, now()))
                        - greatest(b.seg_start, bs.started_at)
                        ))))::integer
                 from emp_ops.break_sessions bs
                 where bs.attendance_session_id = p_attendance_session_id
                   and bs.started_at < b.seg_end
                   and coalesce(bs.ended_at, now()) > b.seg_start
               ), 0) as secs
    from base b
  ),
  final as (
    select minute_start, least(60, greatest(secs, 0))::smallint as secs from net where secs > 0
  ),
  ins as (
    insert into emp_ops.activity_minutes as am
      (employee_id, minute_start, attendance_session_id, work_date, seconds, present_seconds, interactions, sources)
    select p_employee_id,
           f.minute_start,
           p_attendance_session_id,
           (f.minute_start at time zone v_tz)::date,
           0,
           f.secs,
           0,
           array[coalesce(p_source, 'emp_ops')]
    from final f
    on conflict (employee_id, minute_start) do update
      set present_seconds = least(60, am.present_seconds + excluded.present_seconds),
          sources         = (select array(select distinct unnest(am.sources || excluded.sources))),
          updated_at      = now()
    returning 1
  )
  select coalesce(sum(secs), 0) into v_credited from final;

  return v_credited;
end $$;

-- ترحيل نافذة الحضور: يُستدعى من نبضة منخرطة فقط.
-- لا يُحتسب شيء إن لم تكن هناك مرساة (بعد إغلاق/استراحة) أو إن كانت
-- آخر لحظة انخراط أقدم من حدّ التغطية — يبدأ الاحتساب من الآن.
create or replace function emp_ops.flush_presence(
  p_employee_id  uuid,
  p_session_id   uuid,
  p_source       text default 'emp_ops'
) returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_state emp_ops.employee_runtime_state;
  v_tol   numeric;
  v_from  timestamptz;
  v_to    timestamptz;
begin
  select * into v_state from emp_ops.employee_runtime_state
   where employee_id = p_employee_id for update;
  if not found then
    return 0;
  end if;

  v_tol := emp_ops.setting_num('present_coverage_tolerance_seconds', 90);

  -- بلا مرساة أو بلا انخراط سابق: رسّ مرساة جديدة بلا منح
  if v_state.marked_present_until is null or v_state.last_engaged_at is null then
    update emp_ops.employee_runtime_state
       set marked_present_until = now(), updated_at = now()
     where employee_id = p_employee_id;
    return 0;
  end if;

  v_from := v_state.marked_present_until;
  v_to   := now();

  -- فجوة انخراط غير مغطّاة ⇒ لا تُحتسب، ويُستأنف الاحتساب من الآن
  if now() - v_state.last_engaged_at > make_interval(secs => v_tol) then
    v_from := now();
  end if;

  if v_to <= v_from then
    update emp_ops.employee_runtime_state
       set marked_present_until = greatest(coalesce(marked_present_until, v_from), v_from), updated_at = now()
     where employee_id = p_employee_id;
    return 0;
  end if;

  update emp_ops.employee_runtime_state
     set marked_present_until = greatest(coalesce(marked_present_until, v_to), v_to), updated_at = now()
   where employee_id = p_employee_id;

  return emp_ops.mark_present_minutes(p_employee_id, p_session_id, v_from, v_to, p_source);
end $$;

-- إغلاق نافذة النشاط يغلق نافذة الحضور أيضًا: المرساة تصبح NULL
-- فلا تُمنح ثانية بعد الخروج حتى ترسي نبضة منخرطة جديدة مرساة.
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
         marked_present_until = null,
         updated_at = now()
   where employee_id = p_employee_id;
end $$;

comment on function emp_ops.seal_activity_window(uuid) is
  'تُستدعى عند خروج الموظف من تبويب مدعوم: تدفع مؤشر النشاط إلى ما بعد نافذة التفاعل الحالية، وتُلغي مرساة الحضور فلا يُمنح وقت الغياب عند العودة.';

-- ─────────────────────────────────────────────────────────────
-- ٦) رجوع حدث الشغل: حدث عمل حقيقي يثبت أن الدقائق السابقة كانت
--     شغلًا، فيُعتمَد الانخراط المسجَّل في النبضات خلال آخر N دقيقة.
--     سقف الدقيقة (٦٠ث) يمنع أي ازدواج مع الترحيل العادي.
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.backfill_work_event(
  p_employee_id uuid,
  p_session_id  uuid,
  p_source      text default 'emp_ops',
  p_minutes     integer default null
) returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_limit   numeric;
  v_from    timestamptz;
  v_total   integer := 0;
  v_bucket  timestamptz;
begin
  v_limit := coalesce(p_minutes, emp_ops.setting_num('work_event_backfill_minutes', 10));
  if v_limit <= 0 then
    return 0;
  end if;

  v_from := now() - make_interval(secs => v_limit * 60);

  for v_bucket in
    select distinct h.bucket_start
    from emp_ops.activity_heartbeats h
    where h.employee_id = p_employee_id
      and h.attendance_session_id = p_session_id
      and coalesce(h.engaged, false)
      and h.bucket_start >= v_from
      and h.bucket_start < now()
    order by h.bucket_start
  loop
    v_total := v_total + emp_ops.mark_active_minutes(
      p_employee_id, p_session_id,
      v_bucket, v_bucket + interval '30 seconds',
      p_source, 0);
  end loop;

  return v_total;
end $$;

-- تعبئة حضور الدقائق الموجودة من النبضات المنخرطة (مرة واحدة عند التطبيق،
-- وقابلة لإعادة التشغيل للتدقيق): كل نافذة ٣٠ ثانية منخرطة = ٣٠ ثانية حضور
-- في دقيقتها، مطروحًا منها تداخل الاستراحات، وبسقف ٦٠ ثانية/دقيقة.
create or replace function emp_ops.backfill_present_seconds()
returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare v_n integer := 0;
begin
  with hb as (
    select h.employee_id, h.attendance_session_id,
           date_trunc('minute', h.bucket_start) as minute_start,
           count(distinct h.bucket_start) as buckets
    from emp_ops.activity_heartbeats h
    where coalesce(h.engaged, false)
    group by h.employee_id, h.attendance_session_id, date_trunc('minute', h.bucket_start)
  ),
  calc as (
    select hb.employee_id, hb.attendance_session_id, hb.minute_start,
           least(60, greatest(hb.buckets * 30
             - coalesce((
                 select floor(sum(extract(epoch from (
                          least(hb.minute_start + interval '1 minute', coalesce(bs.ended_at, now()))
                        - greatest(hb.minute_start, bs.started_at)
                        ))))::integer
                 from emp_ops.break_sessions bs
                 where bs.attendance_session_id = hb.attendance_session_id
                   and bs.started_at < hb.minute_start + interval '1 minute'
                   and coalesce(bs.ended_at, now()) > hb.minute_start
               ), 0), 0))::smallint as present_secs
    from hb
  )
  update emp_ops.activity_minutes am
     set present_seconds = least(60, greatest(am.present_seconds, c.present_secs)),
         updated_at = now()
    from calc c
   where am.employee_id = c.employee_id
     and am.minute_start = c.minute_start
     and c.present_secs > 0;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ─────────────────────────────────────────────────────────────
-- ٧) تنبيه الشيفت المنسي: شيفت مفتوح بلا نبضات أكثر من حدّ التنبيه
--     ⇒ إشعار في جرس مدعوم، ويُعاد كل فترة التكرار حتى يُغلق الشيفت.
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.nudge_forgotten_shifts()
returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_after  numeric := emp_ops.setting_num('shift_nudge_after_seconds', 3600);
  v_repeat numeric := emp_ops.setting_num('shift_nudge_repeat_seconds', 21600);
  v_rec    record;
  v_n      integer := 0;
begin
  for v_rec in
    select a.id as session_id, a.employee_id, a.started_at, e.user_id, e.full_name,
           emp_ops.employee_timezone(a.employee_id) as tz
    from emp_ops.attendance_sessions a
    join emp_ops.employees e on e.id = a.employee_id
    left join emp_ops.employee_runtime_state st on st.employee_id = a.employee_id
    where a.status = 'open'
      and e.status = 'active'
      and e.user_id is not null
      and coalesce(st.last_heartbeat_at, a.started_at) < now() - make_interval(secs => v_after)
      and (st.last_shift_nudge_at is null
           or st.last_shift_nudge_at < now() - make_interval(secs => v_repeat))
  loop
    insert into public.notifications (user_id, title, message, type, category)
    values (v_rec.user_id,
            'شيفتك ما زال مفتوحًا',
            'بدأت شيفتك في ' || to_char(v_rec.started_at at time zone v_rec.tz, 'HH24:MI')
              || ' ولم تصل أي نبضات منذ أكثر من ساعة — هل نسيت إنهاء الشيفت؟',
            'warning', 'attendance');

    update emp_ops.employee_runtime_state
       set last_shift_nudge_at = now(), updated_at = now()
     where employee_id = v_rec.employee_id;

    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ─────────────────────────────────────────────────────────────
-- ٨) بوّابة الاحتساب داخل eo_ingest_activity
--    (نفس الدالة السابقة حرفيًا عدا مواضع التغيير المُعلَّمة أدناه)
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
  -- جديد في 0019:
  v_break_auto_ended boolean := false;
  v_backfilled integer := 0;
  v_present_credited integer := 0;
  v_idle_seconds integer;
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

  -- جديد في 0019 — الاستراحة المنسية: حدث عمل حقيقي أثناء استراحة مفتوحة
  -- ينهيها تلقائيًا. نقرة عابرة لا تنهي استراحة، لكن تنفيذ شغل حقيقي
  -- (ردّ على تذكرة، تغيير حالة…) يعني أن الاستراحة انتهت فعلًا، فلا
  -- يُعاقَب الموظف على نسيان زر الإنهاء بضياع شغله وتضخّم استراحته.
  if v_break.id is not null and v_work_event and v_qualifies then
    update emp_ops.break_sessions
       set ended_at = now(), status = 'auto_closed'
     where id = v_break.id;
    insert into emp_ops.attendance_events (employee_id, attendance_session_id, break_session_id, event_type, actor_employee_id, metadata)
    values (v_emp.id, v_session.id, v_break.id, 'break_auto_close', v_emp.id,
            jsonb_build_object('auto', 'activity',
                               'duration_seconds', emp_ops.session_seconds(v_break.started_at, now())));
    perform emp_ops.audit(v_emp, 'break.auto_end', 'break_session', v_break.id::text, v_emp.full_name,
                          jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_break.started_at, now()),
                                             'trigger', 'work_event'));
    v_break := null;
    v_break_auto_ended := true;
  end if;

  -- قفل صف الحالة: يُسلسل كل التبويبات والأجهزة لنفس الموظف
  select * into v_state from emp_ops.employee_runtime_state
   where employee_id = v_emp.id for update;

  if not found then
    insert into emp_ops.employee_runtime_state
      (employee_id, attendance_session_id, last_heartbeat_at, last_interaction_at, marked_until,
       last_engaged_at, marked_present_until)
    values (v_emp.id, v_session.id, now(),
            case when v_interactive then now() else null end,
            case when v_interactive then now() else null end,
            case when v_engaged then now() else null end,
            case when v_engaged then now() else null end);
  else
    -- جديد في 0019 — رجوع حدث الشغل قبل الترحيل العادي.
    if v_work_event and v_qualifies and v_break.id is null then
      v_backfilled := emp_ops.backfill_work_event(v_emp.id, v_session.id, v_source);
    end if;

    -- (١) الترحيل أولًا بالحالة القديمة — يقف عند نهاية نافذة التفاعل السابق.
    --     التطبيق غير المؤهَّل (لوحة العمليات) لا يحتسب ولا يُغلق النافذة:
    -- يكتفي بتحديث آخر نبضة حتى تبقى حالة الاتصال معروفة.
    if v_qualifies then
      if v_break.id is null and v_engaged then
        v_credited := emp_ops.flush_activity(v_emp.id, v_session.id, v_source, v_interactions);
        -- جديد في 0019 — ترحيل الحضور مع النشاط في النبضة المنخرطة نفسها.
        v_present_credited := emp_ops.flush_presence(v_emp.id, v_session.id, v_source);
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
           -- جديد في 0019 — آخر لحظة انخراط: مرساة نافذة الحضور.
           last_engaged_at     = case when v_engaged then now() else last_engaged_at end,
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

  v_idle_seconds := case when v_state.last_interaction_at is null then null
                         else greatest(0, floor(extract(epoch from (now() - v_state.last_interaction_at))))::integer end;

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
    -- جديد في 0019:
    'break_auto_ended', v_break_auto_ended,
    'backfilled_seconds', v_backfilled,
    'present_credited_seconds', v_present_credited,
    'last_interaction_at', v_state.last_interaction_at,
    'idle_seconds', v_idle_seconds,
    'totals', jsonb_build_object(
      'shift_seconds',  coalesce(v_totals.shift_seconds, 0),
      'break_seconds',  coalesce(v_totals.break_seconds, 0),
      'active_seconds', coalesce(v_totals.active_seconds, 0),
      'idle_seconds',   coalesce(v_totals.idle_seconds, 0),
      'active_pct',     v_totals.active_pct,
      'present_seconds', coalesce(v_totals.present_seconds, 0),
      'present_pct',    v_totals.present_pct),
    'next_heartbeat_seconds', emp_ops.setting_num('heartbeat_interval_seconds', 60));
end $$;

-- ─────────────────────────────────────────────────────────────
-- ٩) الملخّص اللحظي والإحصاءات اليومية: الحضور بجانب النشاط
-- ─────────────────────────────────────────────────────────────
-- تغيير نوع الإرجاع (عمودان جديدان) يتطلب DROP أولًا — فـ CREATE OR
-- REPLACE وحدها ترفض تغيير صف الإرجاع.
drop function if exists emp_ops.live_totals(uuid, date);
create or replace function emp_ops.live_totals(p_employee_id uuid, p_work_date date)
returns table (
  shift_seconds integer, break_seconds integer, active_seconds integer,
  idle_seconds integer, active_pct numeric, sessions_count integer,
  present_seconds integer, present_pct numeric
)
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  with s as (
    select coalesce(sum(emp_ops.session_seconds(started_at, ended_at)), 0)::integer as shift_seconds,
           count(*)::integer as sessions_count
    from emp_ops.attendance_sessions
    where employee_id = p_employee_id and work_date = p_work_date
  ),
  b as (
    select coalesce(sum(emp_ops.session_seconds(bs.started_at, bs.ended_at)), 0)::integer as break_seconds
    from emp_ops.break_sessions bs
    join emp_ops.attendance_sessions a on a.id = bs.attendance_session_id
    where a.employee_id = p_employee_id and a.work_date = p_work_date
  ),
  m as (
    select coalesce(sum(seconds), 0)::integer as active_seconds,
           coalesce(sum(present_seconds), 0)::integer as present_seconds
    from emp_ops.activity_minutes
    where employee_id = p_employee_id and work_date = p_work_date
  )
  select s.shift_seconds,
         b.break_seconds,
         least(m.active_seconds, greatest(s.shift_seconds - b.break_seconds, 0)) as active_seconds,
         greatest(greatest(s.shift_seconds - b.break_seconds, 0)
                  - least(m.active_seconds, greatest(s.shift_seconds - b.break_seconds, 0)), 0) as idle_seconds,
         case when greatest(s.shift_seconds - b.break_seconds, 0) > 0
              then round((least(m.active_seconds, greatest(s.shift_seconds - b.break_seconds, 0))::numeric
                          / greatest(s.shift_seconds - b.break_seconds, 0)) * 100, 2)
              else null end as active_pct,
         s.sessions_count,
         least(m.present_seconds, greatest(s.shift_seconds - b.break_seconds, 0)) as present_seconds,
         case when greatest(s.shift_seconds - b.break_seconds, 0) > 0
              then round((least(m.present_seconds, greatest(s.shift_seconds - b.break_seconds, 0))::numeric
                          / greatest(s.shift_seconds - b.break_seconds, 0)) * 100, 2)
              else null end as present_pct
  from s, b, m;
$$;

create or replace function emp_ops.recompute_daily_stats(p_employee_id uuid, p_work_date date)
returns emp_ops.employee_daily_stats
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_row     emp_ops.employee_daily_stats;
  v_shift   integer := 0;
  v_break   integer := 0;
  v_active  integer := 0;
  v_present integer := 0;
  v_idle    integer := 0;
  v_first   timestamptz;
  v_last    timestamptz;
  v_count   integer := 0;
  v_breaks  integer := 0;
  v_late    integer := 0;
  v_open    boolean := false;
  v_absent  boolean := false;
  v_denom   integer;
  v_shift_tpl emp_ops.shifts;
begin
  select count(*)::integer,
         coalesce(sum(emp_ops.session_seconds(started_at, ended_at)), 0)::integer,
         min(started_at),
         max(coalesce(ended_at, now())),
         bool_or(status = 'open'),
         coalesce(max(late_seconds), 0)
    into v_count, v_shift, v_first, v_last, v_open, v_late
  from emp_ops.attendance_sessions
  where employee_id = p_employee_id and work_date = p_work_date;

  select count(*)::integer,
         coalesce(sum(emp_ops.session_seconds(bs.started_at, bs.ended_at)), 0)::integer
    into v_breaks, v_break
  from emp_ops.break_sessions bs
  join emp_ops.attendance_sessions a on a.id = bs.attendance_session_id
  where a.employee_id = p_employee_id and a.work_date = p_work_date;

  select coalesce(sum(seconds), 0)::integer,
         coalesce(sum(present_seconds), 0)::integer
    into v_active, v_present
  from emp_ops.activity_minutes
  where employee_id = p_employee_id and work_date = p_work_date;

  -- وقت الخمول = وقت الشيفت − الاستراحات − وقت النشاط (لا يقلّ عن صفر أبدًا)
  v_denom := greatest(v_shift - v_break, 0);
  v_active := least(v_active, v_denom);
  v_present := least(v_present, v_denom);
  v_idle   := greatest(v_denom - v_active, 0);

  -- غياب = يوم عمل مجدول بلا أي جلسة حضور
  v_shift_tpl := emp_ops.shift_for(p_employee_id, p_work_date);
  v_absent := v_count = 0
              and v_shift_tpl.id is not null
              and (extract(dow from p_work_date)::integer = any(v_shift_tpl.work_days))
              and p_work_date < (now() at time zone emp_ops.employee_timezone(p_employee_id))::date;

  insert into emp_ops.employee_daily_stats as s (
    employee_id, work_date, first_start_at, last_end_at, sessions_count, breaks_count,
    shift_seconds, break_seconds, active_seconds, idle_seconds, active_pct,
    present_seconds, present_pct,
    late_seconds, is_late, is_absent, had_open_session, computed_at
  ) values (
    p_employee_id, p_work_date, v_first, v_last, v_count, v_breaks,
    v_shift, v_break, v_active, v_idle,
    case when v_denom > 0 then round((v_active::numeric / v_denom) * 100, 2) else null end,
    v_present,
    case when v_denom > 0 then round((v_present::numeric / v_denom) * 100, 2) else null end,
    v_late, v_late > 0, v_absent, v_open, now()
  )
  on conflict (employee_id, work_date) do update set
    first_start_at = excluded.first_start_at,
    last_end_at    = excluded.last_end_at,
    sessions_count = excluded.sessions_count,
    breaks_count   = excluded.breaks_count,
    shift_seconds  = excluded.shift_seconds,
    break_seconds  = excluded.break_seconds,
    active_seconds = excluded.active_seconds,
    idle_seconds   = excluded.idle_seconds,
    active_pct     = excluded.active_pct,
    present_seconds = excluded.present_seconds,
    present_pct    = excluded.present_pct,
    late_seconds   = excluded.late_seconds,
    is_late        = excluded.is_late,
    is_absent      = excluded.is_absent,
    had_open_session = excluded.had_open_session,
    computed_at    = now()
  returning * into v_row;

  return v_row;
end $$;

-- حالة الموظف الكاملة: الحضور في كائن الإجماليات
create or replace function emp_ops.employee_status_json(p_employee_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = emp_ops, pg_temp as $$
declare
  v_emp      emp_ops.employees;
  v_session  emp_ops.attendance_sessions;
  v_break    emp_ops.break_sessions;
  v_state    emp_ops.employee_runtime_state;
  v_shift    emp_ops.shifts;
  v_date     date;
  v_totals   record;
  v_presence text;
  v_sessions_today integer;
  v_devices  integer;
begin
  select * into v_emp from emp_ops.employees where id = p_employee_id;
  if not found then
    return jsonb_build_object('error', 'الموظف غير موجود');
  end if;

  v_date := emp_ops.work_date_of(p_employee_id, now());

  select * into v_session from emp_ops.attendance_sessions
   where employee_id = p_employee_id and status = 'open' limit 1;

  if v_session.id is not null then
    select * into v_break from emp_ops.break_sessions
     where attendance_session_id = v_session.id and status = 'open' limit 1;
    v_devices := emp_ops.active_device_count(v_session.id);
  else
    v_devices := 0;
  end if;

  select * into v_state from emp_ops.employee_runtime_state where employee_id = p_employee_id;

  select count(*)::integer into v_sessions_today from emp_ops.attendance_sessions
   where employee_id = p_employee_id and work_date = v_date;

  select * into v_totals from emp_ops.live_totals(p_employee_id, v_date);

  v_presence := emp_ops.compute_presence(
    v_session.id is not null, v_break.id is not null,
    v_state.last_interaction_at, v_state.last_heartbeat_at, v_sessions_today, now()
  );

  v_shift := emp_ops.shift_for(p_employee_id, v_date);

  return jsonb_build_object(
    'server_time', now(),
    'work_date',   v_date,
    'employee', jsonb_build_object(
      'id', v_emp.id, 'full_name', v_emp.full_name, 'email', v_emp.email,
      'employee_code', v_emp.employee_code, 'role', v_emp.role,
      'role_label', (select name_ar from emp_ops.roles where code = v_emp.role),
      'rank', (select rank from emp_ops.roles where code = v_emp.role),
      'status', v_emp.status, 'timezone', emp_ops.employee_timezone(p_employee_id),
      'team', (select name_ar from emp_ops.teams where id = v_emp.team_id)
    ),
    'session', case when v_session.id is null then null else jsonb_build_object(
      'id', v_session.id, 'started_at', v_session.started_at,
      'late_seconds', v_session.late_seconds, 'device_id', v_session.start_device_id,
      'active_devices', v_devices
    ) end,
    'break', case when v_break.id is null then null else jsonb_build_object(
      'id', v_break.id, 'started_at', v_break.started_at, 'break_type', v_break.break_type
    ) end,
    'shift', case when v_shift.id is null then null else jsonb_build_object(
      'id', v_shift.id, 'name_ar', v_shift.name_ar,
      'start_time', v_shift.start_time, 'end_time', v_shift.end_time,
      'grace_minutes', v_shift.grace_minutes, 'work_days', v_shift.work_days
    ) end,
    'presence', v_presence,
    'presence_label', emp_ops.presence_label(v_presence),
    'last_interaction_at', v_state.last_interaction_at,
    'last_heartbeat_at',   v_state.last_heartbeat_at,
    'totals', jsonb_build_object(
      'shift_seconds',  coalesce(v_totals.shift_seconds, 0),
      'break_seconds',  coalesce(v_totals.break_seconds, 0),
      'active_seconds', coalesce(v_totals.active_seconds, 0),
      'idle_seconds',   coalesce(v_totals.idle_seconds, 0),
      'active_pct',     v_totals.active_pct,
      'sessions_count', coalesce(v_totals.sessions_count, 0),
      'present_seconds', coalesce(v_totals.present_seconds, 0),
      'present_pct',    v_totals.present_pct
    ),
    'settings', jsonb_build_object(
      'idle_threshold_seconds',     emp_ops.setting_num('idle_threshold_seconds', 300),
      'heartbeat_interval_seconds', emp_ops.setting_num('heartbeat_interval_seconds', 60),
      'offline_threshold_seconds',  emp_ops.setting_num('offline_threshold_seconds', 180),
      'timezone',                   emp_ops.system_timezone()
    )
  );
end $$;

-- ─────────────────────────────────────────────────────────────
-- ١٠) الخط الزمني: سبب كل فترة خمول + تجاهل دقائق الحضور الصافية
--      عند رسم فترات النشاط (ثواني النشاط = 0 لا تصنع فترة نشاط)
-- ─────────────────────────────────────────────────────────────
create or replace function emp_ops.timeline(p_employee_id uuid, p_date date)
returns table (at timestamptz, until timestamptz, kind text, label text, seconds integer, meta jsonb)
language sql stable security definer set search_path = emp_ops, pg_temp as $$
  with sessions as (
    select id, started_at, coalesce(ended_at, now()) as ended_at, status, late_seconds
    from emp_ops.attendance_sessions
    where employee_id = p_employee_id and work_date = p_date
  ),
  mins as (
    select minute_start, seconds,
           minute_start - (row_number() over (order by minute_start)) * interval '1 minute' as grp
    from emp_ops.activity_minutes
    where employee_id = p_employee_id and work_date = p_date and seconds > 0
  ),
  active_seg as (
    select min(minute_start) as from_ts,
           max(minute_start) + interval '1 minute' as to_ts,
           sum(seconds)::integer as secs
    from mins group by grp
  ),
  breaks as (
    select b.id, b.started_at as from_ts, coalesce(b.ended_at, now()) as to_ts, b.break_type,
           b.attendance_session_id
    from emp_ops.break_sessions b
    join sessions s on s.id = b.attendance_session_id
  ),
  -- كل الفترات المشغولة (نشاط أو استراحة) منسوبة لجلستها
  busy as (
    select s.id as session_id, greatest(a.from_ts, s.started_at) as from_ts,
           least(a.to_ts, s.ended_at) as to_ts, 'active' as kind
    from active_seg a join sessions s
      on a.from_ts < s.ended_at and a.to_ts > s.started_at
    union all
    select b.attendance_session_id, b.from_ts, b.to_ts, 'break' from breaks b
  ),
  ordered as (
    select session_id, from_ts, to_ts, kind,
           lag(to_ts) over (partition by session_id order by from_ts) as prev_end,
           row_number() over (partition by session_id order by from_ts) as rn,
           count(*) over (partition by session_id) as total
    from busy
  ),
  gaps as (
    -- فجوة بين فترتين مشغولتين
    select o.session_id, o.prev_end as from_ts, o.from_ts as to_ts
    from ordered o where o.prev_end is not null and o.from_ts > o.prev_end
    union all
    -- فجوة من بداية الشيفت حتى أول نشاط
    select s.id, s.started_at, o.from_ts
    from sessions s join ordered o on o.session_id = s.id and o.rn = 1
    where o.from_ts > s.started_at
    union all
    -- فجوة من آخر نشاط حتى نهاية الشيفت
    select s.id, o.to_ts, s.ended_at
    from sessions s join ordered o on o.session_id = s.id and o.rn = o.total
    where s.ended_at > o.to_ts
    union all
    -- شيفت بلا أي نشاط على الإطلاق
    select s.id, s.started_at, s.ended_at
    from sessions s where not exists (select 1 from busy b where b.session_id = s.id)
  ),
  idle_gaps as (
    select g.session_id, g.from_ts, g.to_ts,
      case
        when not exists (
          select 1 from emp_ops.activity_heartbeats h
          where h.attendance_session_id = g.session_id
            and h.bucket_start >= g.from_ts and h.bucket_start < g.to_ts)
          then 'no_heartbeat'
        when exists (
          select 1 from emp_ops.activity_heartbeats h
          where h.attendance_session_id = g.session_id
            and h.bucket_start >= g.from_ts and h.bucket_start < g.to_ts
            and coalesce(h.engaged, false))
          then 'present_quiet'
        when not exists (
          select 1 from emp_ops.activity_heartbeats h
          join emp_ops.activity_sessions s on s.id = h.activity_session_id
          where h.attendance_session_id = g.session_id
            and h.bucket_start >= g.from_ts and h.bucket_start < g.to_ts
            and s.source_app = 'mad3oom')
          and exists (
          select 1 from emp_ops.activity_heartbeats h
          where h.attendance_session_id = g.session_id
            and h.bucket_start >= g.from_ts and h.bucket_start < g.to_ts)
          then 'in_ops'
        when exists (
          select 1 from emp_ops.activity_heartbeats h
          where h.attendance_session_id = g.session_id
            and h.bucket_start >= g.from_ts and h.bucket_start < g.to_ts
            and not coalesce(h.visible, true))
          then 'tab_hidden'
        else 'tab_unfocused'
      end as reason
    from gaps g
  ),
  idle_labeled as (
    select g.session_id, g.from_ts, g.to_ts, g.reason,
      case g.reason
        when 'no_heartbeat'  then 'لا نبضات — التبويب مغلق أو الجهاز غير متصل'
        when 'present_quiet' then 'حاضر داخل مدعوم بلا تفاعل — قراءة أو مكالمة غالبًا'
        when 'in_ops'        then 'يعمل داخل لوحة العمليات (لا يُحتسب نشاطًا)'
        when 'tab_hidden'    then 'تبويب مدعوم مخفي'
        else 'تبويب مدعوم بلا تركيز'
      end as reason_label
    from idle_gaps g
  )
  select * from (
    select ae.occurred_at as at, null::timestamptz as until, ae.event_type as kind,
           case ae.event_type
             when 'shift_start'      then 'بدأ العمل'
             when 'shift_end'        then 'أنهى العمل'
             when 'shift_auto_close' then 'أُغلق الشيفت تلقائيًا'
             when 'shift_force_end'  then 'أنهت الإدارة الشيفت'
             when 'admin_force_end'  then 'أنهت الإدارة الشيفت'
             when 'break_start'      then 'بدأ استراحة'
             when 'break_end'        then 'أنهى الاستراحة'
             when 'break_auto_close' then 'أُغلقت الاستراحة تلقائيًا'
             when 'admin_adjust'     then 'تعديل إداري على السجل'
             else ae.event_type end as label,
           null::integer as seconds, ae.metadata as meta
    from emp_ops.attendance_events ae
    join sessions s on s.id = ae.attendance_session_id
    union all
    select b.from_ts, b.to_ts, 'active_period', 'فترة نشاط',
           greatest(0, floor(extract(epoch from (b.to_ts - b.from_ts))))::integer, '{}'::jsonb
    from busy b where b.kind = 'active' and b.to_ts > b.from_ts
    union all
    select b.from_ts, b.to_ts, 'break_period', 'فترة استراحة',
           greatest(0, floor(extract(epoch from (b.to_ts - b.from_ts))))::integer, '{}'::jsonb
    from busy b where b.kind = 'break' and b.to_ts > b.from_ts
    union all
    select g.from_ts, g.to_ts, 'idle_period', 'فترة خمول',
           greatest(0, floor(extract(epoch from (g.to_ts - g.from_ts))))::integer,
           jsonb_build_object('reason', g.reason, 'reason_label', g.reason_label)
    from idle_labeled g where g.to_ts > g.from_ts
  ) t
  order by at, kind;
$$;

-- ─────────────────────────────────────────────────────────────
-- ١١) التقارير والسجلات: الحضور في كل إجمالي
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_report(
  p_from date, p_to date,
  p_employee_id uuid default null,
  p_team_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_actor emp_ops.employees;
  v_rows  jsonb;
  v_sum   jsonb;
  v_daily jsonb;
begin
  v_actor := emp_ops.require_employee();
  -- الموظف العادي لا يرى إلا تقريره هو
  if not emp_ops.can_manage() then
    if p_employee_id is null or p_employee_id <> v_actor.id then
      p_employee_id := v_actor.id;
    end if;
    p_team_id := null;
  end if;

  if p_to < p_from or (p_to - p_from) > 400 then
    raise exception 'نطاق التاريخ غير صالح (الحد الأقصى 400 يوم).' using errcode = 'EO400';
  end if;

  with scope as (
    select e.* from emp_ops.employees e
    where e.status <> 'archived'
      and (p_employee_id is null or e.id = p_employee_id)
      and (p_team_id is null or e.team_id = p_team_id)
  ),
  dates as (select d::date as work_date from generate_series(p_from, p_to, interval '1 day') d),
  sess as (
    select a.employee_id, a.work_date,
           count(*)::integer as sessions,
           sum(emp_ops.session_seconds(a.started_at, a.ended_at))::bigint as shift_seconds,
           max(a.late_seconds)::integer as late_seconds
    from emp_ops.attendance_sessions a
    join scope s on s.id = a.employee_id
    where a.work_date between p_from and p_to
    group by a.employee_id, a.work_date
  ),
  brk as (
    select a.employee_id, a.work_date,
           sum(emp_ops.session_seconds(b.started_at, b.ended_at))::bigint as break_seconds,
           count(*)::integer as breaks
    from emp_ops.break_sessions b
    join emp_ops.attendance_sessions a on a.id = b.attendance_session_id
    join scope s on s.id = a.employee_id
    where a.work_date between p_from and p_to
    group by a.employee_id, a.work_date
  ),
  act as (
    select m.employee_id, m.work_date, sum(m.seconds)::bigint as active_seconds,
           sum(m.present_seconds)::bigint as present_seconds
    from emp_ops.activity_minutes m
    join scope s on s.id = m.employee_id
    where m.work_date between p_from and p_to
    group by m.employee_id, m.work_date
  ),
  absent as (
    select s.id as employee_id, count(*)::integer as absent_days
    from scope s
    cross join dates d
    where d.work_date < (now() at time zone emp_ops.employee_timezone(s.id))::date
      and (emp_ops.shift_for(s.id, d.work_date)).id is not null
      and extract(dow from d.work_date)::integer = any((emp_ops.shift_for(s.id, d.work_date)).work_days)
      and not exists (select 1 from emp_ops.attendance_sessions a
                       where a.employee_id = s.id and a.work_date = d.work_date)
    group by s.id
  ),
  per_emp as (
    select s.id as employee_id, s.full_name, s.employee_code, s.role,
           (select tm.name_ar from emp_ops.teams tm where tm.id = s.team_id) as team,
           coalesce(sum(se.shift_seconds), 0)::bigint as shift_seconds,
           coalesce(sum(b.break_seconds), 0)::bigint as break_seconds,
           coalesce(sum(a.active_seconds), 0)::bigint as active_seconds,
           coalesce(sum(a.present_seconds), 0)::bigint as present_seconds,
           coalesce(count(distinct se.work_date), 0)::integer as present_days,
           coalesce(sum(se.sessions), 0)::integer as sessions_count,
           coalesce(count(*) filter (where se.late_seconds > 0), 0)::integer as late_days,
           coalesce(max(ab.absent_days), 0)::integer as absent_days
    from scope s
    left join sess se on se.employee_id = s.id
    left join brk  b  on b.employee_id = s.id and b.work_date = se.work_date
    left join act  a  on a.employee_id = s.id and a.work_date = se.work_date
    left join absent ab on ab.employee_id = s.id
    group by s.id, s.full_name, s.employee_code, s.role, s.team_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'employee_id', employee_id, 'full_name', full_name, 'employee_code', employee_code,
      'role', role, 'team', team,
      'shift_seconds', shift_seconds, 'break_seconds', break_seconds,
      'active_seconds', least(active_seconds, greatest(shift_seconds - break_seconds, 0)),
      'idle_seconds', greatest(greatest(shift_seconds - break_seconds, 0)
                               - least(active_seconds, greatest(shift_seconds - break_seconds, 0)), 0),
      'active_pct', case when greatest(shift_seconds - break_seconds, 0) > 0
                         then round((least(active_seconds, greatest(shift_seconds - break_seconds, 0))::numeric
                                     / greatest(shift_seconds - break_seconds, 0)) * 100, 2) else null end,
      'present_seconds', least(present_seconds, greatest(shift_seconds - break_seconds, 0)),
      'present_pct', case when greatest(shift_seconds - break_seconds, 0) > 0
                         then round((least(present_seconds, greatest(shift_seconds - break_seconds, 0))::numeric
                                     / greatest(shift_seconds - break_seconds, 0)) * 100, 2) else null end,
      'present_days', present_days, 'absent_days', absent_days,
      'late_days', late_days, 'sessions_count', sessions_count
    ) order by full_name), '[]'::jsonb),
    jsonb_build_object(
      'shift_seconds',  coalesce(sum(shift_seconds), 0),
      'break_seconds',  coalesce(sum(break_seconds), 0),
      'active_seconds', coalesce(sum(least(active_seconds, greatest(shift_seconds - break_seconds, 0))), 0),
      'idle_seconds',   coalesce(sum(greatest(greatest(shift_seconds - break_seconds, 0)
                          - least(active_seconds, greatest(shift_seconds - break_seconds, 0)), 0)), 0),
      'present_seconds', coalesce(sum(least(present_seconds, greatest(shift_seconds - break_seconds, 0))), 0),
      'present_days',   coalesce(sum(present_days), 0),
      'absent_days',    coalesce(sum(absent_days), 0),
      'late_days',      coalesce(sum(late_days), 0),
      'sessions_count', coalesce(sum(sessions_count), 0),
      'employees',      count(*),
      'avg_active_pct', case when coalesce(sum(greatest(shift_seconds - break_seconds, 0)), 0) > 0
        then round((coalesce(sum(least(active_seconds, greatest(shift_seconds - break_seconds, 0))), 0)::numeric
                    / sum(greatest(shift_seconds - break_seconds, 0))) * 100, 2) else null end,
      'avg_present_pct', case when coalesce(sum(greatest(shift_seconds - break_seconds, 0)), 0) > 0
        then round((coalesce(sum(least(present_seconds, greatest(shift_seconds - break_seconds, 0))), 0)::numeric
                    / sum(greatest(shift_seconds - break_seconds, 0))) * 100, 2) else null end
    )
  into v_rows, v_sum
  from per_emp;

  -- تفصيل يومي للرسم البياني
  with scope as (
    select e.id from emp_ops.employees e
    where e.status <> 'archived'
      and (p_employee_id is null or e.id = p_employee_id)
      and (p_team_id is null or e.team_id = p_team_id)
  ),
  d as (
    select a.work_date,
           sum(emp_ops.session_seconds(a.started_at, a.ended_at))::bigint as shift_seconds,
           count(distinct a.employee_id)::integer as employees
    from emp_ops.attendance_sessions a join scope s on s.id = a.employee_id
    where a.work_date between p_from and p_to group by a.work_date
  ),
  db as (
    select a.work_date, sum(emp_ops.session_seconds(b.started_at, b.ended_at))::bigint as break_seconds
    from emp_ops.break_sessions b
    join emp_ops.attendance_sessions a on a.id = b.attendance_session_id
    join scope s on s.id = a.employee_id
    where a.work_date between p_from and p_to group by a.work_date
  ),
  da as (
    select m.work_date, sum(m.seconds)::bigint as active_seconds,
           sum(m.present_seconds)::bigint as present_seconds
    from emp_ops.activity_minutes m join scope s on s.id = m.employee_id
    where m.work_date between p_from and p_to group by m.work_date
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'work_date', d.work_date,
           'shift_seconds', d.shift_seconds,
           'break_seconds', coalesce(db.break_seconds, 0),
           'active_seconds', coalesce(da.active_seconds, 0),
           'present_seconds', coalesce(da.present_seconds, 0),
           'employees', d.employees
         ) order by d.work_date), '[]'::jsonb) into v_daily
  from d left join db on db.work_date = d.work_date left join da on da.work_date = d.work_date;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'generated_at', now(),
    'timezone', emp_ops.system_timezone(),
    'filters', jsonb_build_object('employee_id', p_employee_id, 'team_id', p_team_id),
    'summary', v_sum, 'employees', v_rows, 'daily', v_daily,
    'formula', 'نسبة النشاط = وقت النشاط ÷ (مدة الشيفت − مدة الاستراحات) × 100 · وقت الحضور = الوقت الذي كان فيه تبويب مدعوم ظاهرًا وعليه تركيز، سواء تفاعل الموظف أم لا.'
  );
end $$;

drop function if exists public.eo_my_history(date, date);
create or replace function public.eo_my_history(p_from date, p_to date)
returns table (
  work_date date, first_start_at timestamptz, last_end_at timestamptz,
  shift_seconds integer, break_seconds integer, active_seconds integer,
  idle_seconds integer, active_pct numeric, late_seconds integer,
  is_late boolean, is_absent boolean, sessions_count integer,
  present_seconds integer, present_pct numeric
)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v emp_ops.employees;
begin
  v := emp_ops.require_employee();
  if p_to < p_from or (p_to - p_from) > 400 then
    raise exception 'نطاق التاريخ غير صالح (الحد الأقصى 400 يوم).' using errcode = 'EO400';
  end if;
  return query
    select s.work_date, s.first_start_at, s.last_end_at, s.shift_seconds, s.break_seconds,
           s.active_seconds, s.idle_seconds, s.active_pct, s.late_seconds,
           s.is_late, s.is_absent, s.sessions_count, s.present_seconds, s.present_pct
    from emp_ops.employee_daily_stats s
    where s.employee_id = v.id and s.work_date between p_from and p_to
    order by s.work_date desc;
end $$;

drop function if exists public.eo_admin_employee_history(uuid, date, date);
create or replace function public.eo_admin_employee_history(p_employee_id uuid, p_from date, p_to date)
returns table (
  work_date date, first_start_at timestamptz, last_end_at timestamptz,
  shift_seconds integer, break_seconds integer, active_seconds integer,
  idle_seconds integer, active_pct numeric, late_seconds integer,
  is_late boolean, is_absent boolean, sessions_count integer,
  present_seconds integer, present_pct numeric
)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees;
begin
  v_actor := emp_ops.require_rank(50);
  if p_to < p_from or (p_to - p_from) > 400 then
    raise exception 'نطاق التاريخ غير صالح (الحد الأقصى 400 يوم).' using errcode = 'EO400';
  end if;
  return query
    select s.work_date, s.first_start_at, s.last_end_at, s.shift_seconds, s.break_seconds,
           s.active_seconds, s.idle_seconds, s.active_pct, s.late_seconds,
           s.is_late, s.is_absent, s.sessions_count, s.present_seconds, s.present_pct
    from emp_ops.employee_daily_stats s
    where s.employee_id = p_employee_id and s.work_date between p_from and p_to
    order by s.work_date desc;
end $$;

create or replace function public.eo_admin_overview()
returns jsonb
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_actor emp_ops.employees;
  v_today date;
  v_now   timestamptz := now();
  v_live  jsonb;
  v_totals jsonb;
begin
  v_actor := emp_ops.require_rank(50);
  v_today := (v_now at time zone emp_ops.system_timezone())::date;

  with base as (
    select e.id,
           (select a.id from emp_ops.attendance_sessions a
             where a.employee_id = e.id and a.status = 'open' limit 1) as open_session,
           (select count(*)::integer from emp_ops.attendance_sessions a
             where a.employee_id = e.id and a.work_date = v_today) as sessions_today,
           st.last_interaction_at, st.last_heartbeat_at
    from emp_ops.employees e
    left join emp_ops.employee_runtime_state st on st.employee_id = e.id
    where e.status = 'active'
  ),
  p as (
    select b.id,
           emp_ops.compute_presence(
             b.open_session is not null,
             exists (select 1 from emp_ops.break_sessions bs
                      where bs.attendance_session_id = b.open_session and bs.status = 'open'),
             b.last_interaction_at, b.last_heartbeat_at, b.sessions_today, v_now) as presence
    from base b
  )
  select jsonb_build_object(
    'total_employees',  (select count(*) from base),
    'working',          count(*) filter (where presence in ('active','idle','break','disconnected')),
    'active',           count(*) filter (where presence = 'active'),
    'idle',             count(*) filter (where presence = 'idle'),
    'on_break',         count(*) filter (where presence = 'break'),
    'disconnected',     count(*) filter (where presence = 'disconnected'),
    'ended',            count(*) filter (where presence = 'ended'),
    'not_started',      count(*) filter (where presence = 'not_started')
  ) into v_live from p;

  with t as (
    select a.employee_id,
           coalesce(sum(emp_ops.session_seconds(a.started_at, a.ended_at)), 0)::bigint as shift_seconds,
           count(*)::integer as sessions
    from emp_ops.attendance_sessions a
    where a.work_date = v_today group by a.employee_id
  ),
  b as (
    select coalesce(sum(emp_ops.session_seconds(bs.started_at, bs.ended_at)), 0)::bigint as break_seconds
    from emp_ops.break_sessions bs
    join emp_ops.attendance_sessions a on a.id = bs.attendance_session_id
    where a.work_date = v_today
  ),
  m as (
    select coalesce(sum(seconds), 0)::bigint as active_seconds,
           coalesce(sum(present_seconds), 0)::bigint as present_seconds
    from emp_ops.activity_minutes where work_date = v_today
  ),
  l as (
    select count(*)::integer as late_count, coalesce(sum(late_seconds), 0)::bigint as late_seconds
    from emp_ops.attendance_sessions where work_date = v_today and late_seconds > 0
  ),
  ab as (
    select count(*)::integer as absent_count from emp_ops.employee_daily_stats
    where work_date = v_today and is_absent
  )
  select jsonb_build_object(
    'shift_seconds',  coalesce((select sum(shift_seconds) from t), 0),
    'sessions_count', coalesce((select sum(sessions) from t), 0),
    'break_seconds',  (select break_seconds from b),
    'active_seconds', (select active_seconds from m),
    'idle_seconds',   greatest(coalesce((select sum(shift_seconds) from t), 0)
                               - (select break_seconds from b) - (select active_seconds from m), 0),
    'avg_active_pct', case
        when coalesce((select sum(shift_seconds) from t), 0) - (select break_seconds from b) > 0
        then round(((select active_seconds from m)::numeric
                    / (coalesce((select sum(shift_seconds) from t), 0) - (select break_seconds from b))) * 100, 2)
        else null end,
    'present_seconds', (select present_seconds from m),
    'avg_present_pct', case
        when coalesce((select sum(shift_seconds) from t), 0) - (select break_seconds from b) > 0
        then round(((select present_seconds from m)::numeric
                    / (coalesce((select sum(shift_seconds) from t), 0) - (select break_seconds from b))) * 100, 2)
        else null end,
    'late_count',     (select late_count from l),
    'absent_count',   (select absent_count from ab),
    'employees_worked', (select count(*) from t)
  ) into v_totals;

  return jsonb_build_object(
    'server_time', v_now, 'work_date', v_today,
    'timezone', emp_ops.system_timezone(),
    'live', v_live, 'today', v_totals
  );
end $$;

drop function if exists public.eo_admin_employees_live();
create or replace function public.eo_admin_employees_live()
returns table (
  employee_id uuid, full_name text, employee_code text, email text, role text, team text,
  presence text, presence_label text, session_id uuid, started_at timestamptz,
  shift_seconds integer, active_seconds integer, idle_seconds integer, break_seconds integer,
  active_pct numeric, late_seconds integer, last_interaction_at timestamptz,
  last_heartbeat_at timestamptz, active_devices integer, status text,
  present_seconds integer, present_pct numeric
)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_now timestamptz := now();
begin
  v_actor := emp_ops.require_rank(50);
  return query
    with base as (
      select e.id, e.full_name, e.employee_code, e.email, e.role, e.status,
             (select tm.name_ar from emp_ops.teams tm where tm.id = e.team_id) as team,
             emp_ops.work_date_of(e.id, v_now) as work_date,
             (select a.id from emp_ops.attendance_sessions a
               where a.employee_id = e.id and a.status = 'open' limit 1) as open_session,
             (select a.started_at from emp_ops.attendance_sessions a
               where a.employee_id = e.id and a.status = 'open' limit 1) as open_started_at,
             st.last_interaction_at, st.last_heartbeat_at
      from emp_ops.employees e
      left join emp_ops.employee_runtime_state st on st.employee_id = e.id
      where e.status <> 'archived'
    ),
    withp as (
      select b.*,
             emp_ops.compute_presence(
               b.open_session is not null,
               exists (select 1 from emp_ops.break_sessions bs
                        where bs.attendance_session_id = b.open_session and bs.status = 'open'),
               b.last_interaction_at, b.last_heartbeat_at,
               (select count(*)::integer from emp_ops.attendance_sessions a
                 where a.employee_id = b.id and a.work_date = b.work_date),
               v_now) as presence
      from base b
    )
    select b.id, b.full_name, b.employee_code, b.email, b.role, b.team,
           b.presence, emp_ops.presence_label(b.presence),
           b.open_session, b.open_started_at,
           lt.shift_seconds, lt.active_seconds, lt.idle_seconds, lt.break_seconds, lt.active_pct,
           coalesce((select max(a.late_seconds) from emp_ops.attendance_sessions a
                      where a.employee_id = b.id and a.work_date = b.work_date), 0),
           b.last_interaction_at, b.last_heartbeat_at,
           coalesce(emp_ops.active_device_count(b.open_session), 0),
           b.status,
           lt.present_seconds, lt.present_pct
    from withp b
    cross join lateral emp_ops.live_totals(b.id, b.work_date) lt
    order by
      case b.presence
        when 'active' then 1 when 'idle' then 2 when 'break' then 3
        when 'disconnected' then 4 when 'ended' then 5 else 6 end,
      b.full_name;
end $$;

-- الـ DROP أعلاه أسقط منح التنفيذ القديمة، فأُعيد منحها هنا (كما في 0010).
grant execute on function public.eo_my_history(date, date)                  to authenticated;
grant execute on function public.eo_admin_employee_history(uuid, date, date) to authenticated;
grant execute on function public.eo_admin_employees_live()                  to authenticated;

-- ─────────────────────────────────────────────────────────────
-- ١٢) ترحيل الحضور عند إغلاق الشيفت/الاستراحة وإنهائها إداريًا،
--      وتنبيه الشيفت المنسي في مهمة الصيانة الدورية
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_end_shift(p_note text default null)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_emp     emp_ops.employees;
  v_session emp_ops.attendance_sessions;
  v_break   emp_ops.break_sessions;
begin
  v_emp := emp_ops.require_employee();

  select * into v_session from emp_ops.attendance_sessions
   where employee_id = v_emp.id and status = 'open' for update;
  if not found then
    raise exception 'لا يوجد شيفت مفتوح لإنهائه.' using errcode = 'EO002';
  end if;

  -- إغلاق أي استراحة مفتوحة تلقائيًا قبل إنهاء الشيفت
  update emp_ops.break_sessions
     set ended_at = now(), status = 'auto_closed'
   where attendance_session_id = v_session.id and status = 'open'
  returning * into v_break;

  if v_break.id is not null then
    insert into emp_ops.attendance_events (employee_id, attendance_session_id, break_session_id, event_type, actor_employee_id)
    values (v_emp.id, v_session.id, v_break.id, 'break_auto_close', v_emp.id);
  end if;

  -- ترحيل آخر دقائق النشاط والحضور قبل الإغلاق
  perform emp_ops.flush_activity(v_emp.id, v_session.id, 'emp_ops', 0);
  perform emp_ops.flush_presence(v_emp.id, v_session.id, 'emp_ops');

  update emp_ops.attendance_sessions
     set ended_at = now(), status = 'closed',
         end_reason = coalesce(nullif(btrim(p_note), ''), 'إنهاء بواسطة الموظف'),
         ended_by_employee_id = v_emp.id
   where id = v_session.id
  returning * into v_session;

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, event_type, actor_employee_id, metadata)
  values (v_emp.id, v_session.id, 'shift_end', v_emp.id,
          jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_session.started_at, v_session.ended_at)));

  update emp_ops.activity_sessions
     set ended_at = now() where attendance_session_id = v_session.id and ended_at is null;

  update emp_ops.employee_runtime_state
     set attendance_session_id = null, presence = 'offline', last_event_type = 'shift_end', updated_at = now()
   where employee_id = v_emp.id;

  perform emp_ops.audit(v_emp, 'shift.end', 'attendance_session', v_session.id::text, v_emp.full_name,
    jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_session.started_at, v_session.ended_at)));
  perform emp_ops.recompute_daily_stats(v_emp.id, v_session.work_date);

  return emp_ops.employee_status_json(v_emp.id);
end $$;

create or replace function public.eo_start_break(p_break_type text default 'general', p_note text default null)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_emp     emp_ops.employees;
  v_session emp_ops.attendance_sessions;
  v_break   emp_ops.break_sessions;
begin
  v_emp := emp_ops.require_employee();

  select * into v_session from emp_ops.attendance_sessions
   where employee_id = v_emp.id and status = 'open' for update;
  if not found then
    raise exception 'لا يمكن بدء استراحة بدون شيفت مفتوح.' using errcode = 'EO003';
  end if;

  -- ترحيل النشاط والحضور حتى لحظة بدء الاستراحة، ثم إيقاف الاحتساب
  perform emp_ops.flush_activity(v_emp.id, v_session.id, 'emp_ops', 0);
  perform emp_ops.flush_presence(v_emp.id, v_session.id, 'emp_ops');

  begin
    insert into emp_ops.break_sessions (attendance_session_id, employee_id, break_type, note)
    values (v_session.id, v_emp.id, coalesce(nullif(btrim(p_break_type), ''), 'general'), nullif(btrim(p_note), ''))
    returning * into v_break;
  exception when unique_violation then
    raise exception 'لديك استراحة مفتوحة بالفعل.' using errcode = 'EO004';
  end;

  update emp_ops.employee_runtime_state
     set marked_until = greatest(coalesce(marked_until, now()), now()),
         marked_present_until = null,
         presence = 'break', last_event_type = 'break_start', updated_at = now()
   where employee_id = v_emp.id;

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, break_session_id, event_type, actor_employee_id, metadata)
  values (v_emp.id, v_session.id, v_break.id, 'break_start', v_emp.id, jsonb_build_object('break_type', v_break.break_type));

  perform emp_ops.audit(v_emp, 'break.start', 'break_session', v_break.id::text, v_emp.full_name,
                        jsonb_build_object('break_type', v_break.break_type));

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
  -- ومرساة الحضور تُلغى لتُرسي نبضة منخرطة جديدة مرساة نظيفة.
  update emp_ops.employee_runtime_state
     set marked_until = greatest(coalesce(marked_until, now()), now()),
         marked_present_until = null,
         presence = 'idle', last_event_type = 'break_end', updated_at = now()
   where employee_id = v_emp.id;

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, break_session_id, event_type, actor_employee_id, metadata)
  values (v_emp.id, v_break.attendance_session_id, v_break.id, 'break_end', v_emp.id,
          jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_break.started_at, v_break.ended_at)));

  perform emp_ops.audit(v_emp, 'break.end', 'break_session', v_break.id::text, v_emp.full_name,
    jsonb_build_object('duration_seconds', emp_ops.session_seconds(v_break.started_at, v_break.ended_at)));

  return emp_ops.employee_status_json(v_emp.id);
end $$;

create or replace function public.eo_admin_force_end_shift(p_employee_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees; v_session emp_ops.attendance_sessions;
begin
  v_actor := emp_ops.require_rank(50);
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'يجب ذكر سبب إنهاء الشيفت.' using errcode = 'EO400';
  end if;

  select * into v_session from emp_ops.attendance_sessions
   where employee_id = p_employee_id and status = 'open' for update;
  if not found then raise exception 'لا يوجد شيفت مفتوح لهذا الموظف.' using errcode = 'EO002'; end if;

  update emp_ops.break_sessions set ended_at = now(), status = 'auto_closed'
   where attendance_session_id = v_session.id and status = 'open';

  perform emp_ops.flush_activity(p_employee_id, v_session.id, 'admin', 0);
  perform emp_ops.flush_presence(p_employee_id, v_session.id, 'admin');

  update emp_ops.attendance_sessions
     set ended_at = now(), status = 'closed',
         end_reason = btrim(p_reason), ended_by_employee_id = v_actor.id
   where id = v_session.id returning * into v_session;

  insert into emp_ops.attendance_events (employee_id, attendance_session_id, event_type, actor_employee_id, metadata)
  values (p_employee_id, v_session.id, 'admin_force_end', v_actor.id, jsonb_build_object('reason', btrim(p_reason)));

  update emp_ops.activity_sessions set ended_at = now()
   where attendance_session_id = v_session.id and ended_at is null;
  update emp_ops.employee_runtime_state
     set attendance_session_id = null, presence = 'offline', updated_at = now()
   where employee_id = p_employee_id;

  perform emp_ops.audit(v_actor, 'shift.force_end', 'attendance_session', v_session.id::text,
                        (select full_name from emp_ops.employees where id = p_employee_id),
                        jsonb_build_object('reason', btrim(p_reason)));
  perform emp_ops.recompute_daily_stats(p_employee_id, v_session.work_date);
  return jsonb_build_object('session_id', v_session.id, 'message', 'تم إنهاء الشيفت وتسجيل العملية في سجل التدقيق.');
end $$;

create or replace function emp_ops.close_stale_sessions()
returns integer
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare
  v_after numeric := emp_ops.setting_num('auto_close_after_seconds', 43200);
  v_max   numeric := emp_ops.setting_num('max_shift_seconds', 57600);
  v_rec   record;
  v_end   timestamptz;
  v_n     integer := 0;
begin
  for v_rec in
    select a.*, st.last_heartbeat_at
    from emp_ops.attendance_sessions a
    left join emp_ops.employee_runtime_state st on st.employee_id = a.employee_id
    where a.status = 'open'
      and (
        coalesce(st.last_heartbeat_at, a.started_at) < now() - make_interval(secs => v_after)
        or a.started_at < now() - make_interval(secs => v_max)
      )
  loop
    v_end := greatest(v_rec.started_at,
                      least(coalesce(v_rec.last_heartbeat_at, v_rec.started_at),
                            v_rec.started_at + make_interval(secs => v_max)));

    update emp_ops.break_sessions
       set ended_at = greatest(started_at, v_end), status = 'auto_closed'
     where attendance_session_id = v_rec.id and status = 'open';

    perform emp_ops.flush_activity(v_rec.employee_id, v_rec.id, 'system', 0);
    perform emp_ops.flush_presence(v_rec.employee_id, v_rec.id, 'system');

    update emp_ops.attendance_sessions
       set ended_at = v_end, status = 'auto_closed',
           end_reason = 'إغلاق تلقائي بعد انقطاع النبضات'
     where id = v_rec.id;

    insert into emp_ops.attendance_events (employee_id, attendance_session_id, event_type, metadata)
    values (v_rec.employee_id, v_rec.id, 'shift_auto_close',
            jsonb_build_object('last_heartbeat_at', v_rec.last_heartbeat_at, 'closed_at', v_end));

    insert into emp_ops.audit_logs (actor_employee_id, action, target_type, target_id, target_label, metadata)
    values (null, 'shift.auto_close', 'attendance_session', v_rec.id::text,
            (select full_name from emp_ops.employees where id = v_rec.employee_id),
            jsonb_build_object('closed_at', v_end, 'reason', 'انقطاع النبضات'));

    update emp_ops.activity_sessions set ended_at = v_end
     where attendance_session_id = v_rec.id and ended_at is null;
    update emp_ops.employee_runtime_state
       set attendance_session_id = null, presence = 'offline', updated_at = now()
     where employee_id = v_rec.employee_id;

    perform emp_ops.recompute_daily_stats(v_rec.employee_id, v_rec.work_date);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function emp_ops.maintenance_tick()
returns jsonb
language plpgsql security definer set search_path = emp_ops, pg_temp as $$
declare v_closed integer; v_presence integer; v_nudged integer;
begin
  v_closed   := emp_ops.close_stale_sessions();
  v_presence := emp_ops.refresh_presence();
  v_nudged   := emp_ops.nudge_forgotten_shifts();
  return jsonb_build_object('closed_sessions', v_closed, 'presence_updates', v_presence,
                            'shift_nudges', v_nudged, 'at', now());
end $$;

-- ─────────────────────────────────────────────────────────────
-- ١٣) طلبات تصحيح النشاط: طلب الموظف، ومراجعة الإدارة
-- ─────────────────────────────────────────────────────────────
create or replace function public.eo_request_correction(
  p_work_date date, p_from timestamptz, p_to timestamptz,
  p_requested_minutes integer, p_reason text)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_emp emp_ops.employees;
  v_session emp_ops.attendance_sessions;
  v_id uuid;
  v_span integer;
begin
  v_emp := emp_ops.require_employee();

  if coalesce(btrim(p_reason), '') = '' or char_length(btrim(p_reason)) < 10 then
    raise exception 'اذكر سبب التصحيح بوضوح (١٠ أحرف على الأقل).' using errcode = 'EO400';
  end if;
  if p_to is null or p_from is null or p_to <= p_from then
    raise exception 'فترة غير صالحة.' using errcode = 'EO400';
  end if;
  v_span := floor(extract(epoch from (p_to - p_from)) / 60)::integer;
  if v_span > 480 then
    raise exception 'الفترة تتجاوز ٨ ساعات.' using errcode = 'EO400';
  end if;
  if p_requested_minutes is null or p_requested_minutes < 1 or p_requested_minutes > v_span then
    raise exception 'عدد الدقائق المطلوبة غير صالح.' using errcode = 'EO400';
  end if;
  if p_work_date > (now() at time zone emp_ops.employee_timezone(v_emp.id))::date then
    raise exception 'لا يمكن طلب تصحيح ليوم في المستقبل.' using errcode = 'EO400';
  end if;

  -- الفترة يجب أن تقع داخل شيفت واحد في ذلك اليوم
  select * into v_session from emp_ops.attendance_sessions
   where employee_id = v_emp.id and work_date = p_work_date
     and started_at <= p_from
     and coalesce(ended_at, now()) >= p_to
   limit 1;
  if not found then
    raise exception 'لا يوجد شيفت يغطي هذه الفترة بالكامل.' using errcode = 'EO404';
  end if;

  if exists (select 1 from emp_ops.activity_correction_requests
              where employee_id = v_emp.id and status = 'pending'
                and period_start < p_to and period_end > p_from) then
    raise exception 'لديك طلب معلَّق يتداخل مع هذه الفترة.' using errcode = 'EO011';
  end if;

  insert into emp_ops.activity_correction_requests
    (employee_id, attendance_session_id, work_date, period_start, period_end,
     requested_minutes, reason)
  values (v_emp.id, v_session.id, p_work_date, p_from, p_to, p_requested_minutes, btrim(p_reason))
  returning id into v_id;

  perform emp_ops.audit(v_emp, 'correction.request', 'correction_request', v_id::text, v_emp.full_name,
                        jsonb_build_object('work_date', p_work_date,
                                           'requested_minutes', p_requested_minutes));

  return jsonb_build_object('id', v_id, 'status', 'pending',
                            'message', 'تم إرسال طلب التصحيح للإدارة. ستظهر النتيجة هنا بعد المراجعة.');
end $$;

create or replace function public.eo_my_correction_requests()
returns table (
  id uuid, work_date date, period_start timestamptz, period_end timestamptz,
  requested_minutes integer, reason text, status text, approved_seconds integer,
  review_note text, reviewed_at timestamptz, reviewer_name text
)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v emp_ops.employees;
begin
  v := emp_ops.require_employee();
  return query
    select r.id, r.work_date, r.period_start, r.period_end, r.requested_minutes,
           r.reason, r.status, r.approved_seconds, r.review_note, r.reviewed_at,
           rv.full_name
    from emp_ops.activity_correction_requests r
    left join emp_ops.employees rv on rv.id = r.reviewed_by
    where r.employee_id = v.id
    order by r.created_at desc
    limit 100;
end $$;

create or replace function public.eo_admin_correction_requests(p_status text default 'pending')
returns table (
  id uuid, employee_id uuid, employee_name text, employee_code text,
  work_date date, period_start timestamptz, period_end timestamptz,
  requested_minutes integer, reason text, status text, approved_seconds integer,
  review_note text, reviewed_at timestamptz, created_at timestamptz
)
language plpgsql stable security definer set search_path = emp_ops, public, pg_temp as $$
declare v_actor emp_ops.employees;
begin
  v_actor := emp_ops.require_rank(50);
  return query
    select r.id, r.employee_id, e.full_name, e.employee_code,
           r.work_date, r.period_start, r.period_end, r.requested_minutes,
           r.reason, r.status, r.approved_seconds, r.review_note, r.reviewed_at, r.created_at
    from emp_ops.activity_correction_requests r
    join emp_ops.employees e on e.id = r.employee_id
    where p_status is null or p_status = 'all' or r.status = p_status
    order by r.created_at desc
    limit 200;
end $$;

create or replace function public.eo_admin_review_correction(
  p_request_id uuid, p_approve boolean, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = emp_ops, public, pg_temp as $$
declare
  v_actor   emp_ops.employees;
  v_req     emp_ops.activity_correction_requests;
  v_min     timestamptz;
  v_existing integer;
  v_add     integer;
  v_remaining integer;
  v_applied integer := 0;
begin
  v_actor := emp_ops.require_rank(50);

  select * into v_req from emp_ops.activity_correction_requests
   where id = p_request_id for update;
  if not found then
    raise exception 'الطلب غير موجود.' using errcode = 'EO404';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'تمت مراجعة هذا الطلب من قبل.' using errcode = 'EO400';
  end if;
  -- لا يراجع المراجع طلب نفسه — حتى لو كان مديرًا: الفصل بين الطالب والمراجع.
  if v_req.employee_id = v_actor.id then
    raise exception 'لا يمكنك مراجعة طلبك بنفسك.' using errcode = 'EO403';
  end if;

  if p_approve then
    -- كتابة الدقائق المعتمَدة في الدفتر بمصدر correction، دقيقة بدقيقة،
    -- وبسقف ٦٠ ثانية/دقيقة — لا تتجاوز المطلوب ولا ما يتسع له الدفتر.
    v_remaining := v_req.requested_minutes * 60;
    v_min := date_trunc('minute', v_req.period_start);
    while v_min < v_req.period_end and v_remaining > 0 loop
      select seconds into v_existing from emp_ops.activity_minutes
       where employee_id = v_req.employee_id and minute_start = v_min;
      if not found then
        v_existing := 0;
      end if;
      v_add := least(60 - v_existing, v_remaining);
      if v_add > 0 then
        insert into emp_ops.activity_minutes as am
          (employee_id, minute_start, attendance_session_id, work_date,
           seconds, present_seconds, interactions, sources)
        values (v_req.employee_id, v_min, v_req.attendance_session_id, v_req.work_date,
                v_add, 0, 0, array['correction'])
        on conflict (employee_id, minute_start) do update
          set seconds    = least(60, am.seconds + excluded.seconds),
              sources    = (select array(select distinct unnest(am.sources || excluded.sources))),
              updated_at = now();
        v_remaining := v_remaining - v_add;
        v_applied := v_applied + v_add;
      end if;
      v_min := v_min + interval '1 minute';
    end loop;

    perform emp_ops.recompute_daily_stats(v_req.employee_id, v_req.work_date);

    insert into emp_ops.attendance_events (employee_id, attendance_session_id, event_type, actor_employee_id, metadata)
    values (v_req.employee_id, v_req.attendance_session_id, 'admin_adjust', v_actor.id,
            jsonb_build_object('correction_request_id', v_req.id,
                               'approved_seconds', v_applied,
                               'reason', btrim(coalesce(p_note, ''))));

    perform emp_ops.audit(v_actor, 'correction.approve', 'correction_request', v_req.id::text,
                          (select full_name from emp_ops.employees where id = v_req.employee_id),
                          jsonb_build_object('approved_seconds', v_applied,
                                             'requested_minutes', v_req.requested_minutes,
                                             'note', btrim(coalesce(p_note, ''))));

    update emp_ops.activity_correction_requests
       set status = 'approved', approved_seconds = v_applied,
           reviewed_by = v_actor.id, review_note = nullif(btrim(coalesce(p_note, '')), ''),
           reviewed_at = now()
     where id = v_req.id;

    return jsonb_build_object('id', v_req.id, 'status', 'approved',
                              'approved_seconds', v_applied,
                              'message', 'تم اعتماد التصحيح وكتابة الدقائق في السجل.');
  else
    if coalesce(btrim(p_note), '') = '' then
      raise exception 'اذكر سبب الرفض.' using errcode = 'EO400';
    end if;

    perform emp_ops.audit(v_actor, 'correction.reject', 'correction_request', v_req.id::text,
                          (select full_name from emp_ops.employees where id = v_req.employee_id),
                          jsonb_build_object('note', btrim(p_note)));

    update emp_ops.activity_correction_requests
       set status = 'rejected', approved_seconds = 0,
           reviewed_by = v_actor.id, review_note = btrim(p_note),
           reviewed_at = now()
     where id = v_req.id;

    return jsonb_build_object('id', v_req.id, 'status', 'rejected',
                              'message', 'تم رفض طلب التصحيح مع تسجيل السبب.');
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────
-- ١٤) الصلاحيات على الواجهات الجديدة
-- ─────────────────────────────────────────────────────────────
revoke all on function public.eo_request_correction(date, timestamptz, timestamptz, integer, text) from public, anon;
revoke all on function public.eo_my_correction_requests() from public, anon;
revoke all on function public.eo_admin_correction_requests(text) from public, anon;
revoke all on function public.eo_admin_review_correction(uuid, boolean, text) from public, anon;

grant execute on function public.eo_request_correction(date, timestamptz, timestamptz, integer, text) to authenticated;
grant execute on function public.eo_my_correction_requests() to authenticated;
grant execute on function public.eo_admin_correction_requests(text) to authenticated;
grant execute on function public.eo_admin_review_correction(uuid, boolean, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- ١٥) تعبئة حضور الدقائق الموجودة من النبضات، ثم إعادة حساب
--      إحصاءات الأيام المتأثرة (اليومان الموجودان في البيانات)
-- ─────────────────────────────────────────────────────────────
select emp_ops.backfill_present_seconds();

do $$
declare r record;
begin
  for r in select distinct employee_id, work_date from emp_ops.activity_minutes loop
    perform emp_ops.recompute_daily_stats(r.employee_id, r.work_date);
  end loop;
end $$;





