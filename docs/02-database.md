# قاعدة البيانات

مخطط واحد: `emp_ops` داخل مشروع Supabase الخاص بمدعوم. لم يُمسّ أي جدول في `public`.

## الجداول (١٨)

### الكتالوجات والإعدادات

| الجدول | الوصف |
|---|---|
| `roles` | أدوار النظام: `code`, `name_ar`, `rank`. الصلاحية تُقاس بالـ **rank** لا بالاسم، ليمكن إضافة أدوار جديدة بصف واحد. |
| `activity_types` | أنواع أحداث النشاط. العمود `counts_as_interaction` يحدد إن كان الحدث يجدد نافذة النشاط أم يُسجَّل للتدقيق فقط. |
| `audit_actions` | أسماء عربية ودرجات خطورة لعمليات سجل التدقيق. |
| `app_settings` | كل رقم تشغيلي في النظام: عتبة الخمول، فترة النبض، الإغلاق التلقائي، **التطبيقات المؤهَّلة لاحتساب النشاط**، **اشتراط الـFocus**، **حد تغطية النبضات**… مع `min_value`/`max_value` تُفحص على الخادم، و`is_public` لتحديد ما يراه الموظف العادي. |

### التنظيم

| الجدول | الوصف |
|---|---|
| `teams` | الفرق. |
| `employees` | الموظف. `user_id → auth.users(id)` هو **نقطة التماس الوحيدة** مع منصة مدعوم، و`on delete set null` حتى لا يضيع تاريخ الحضور لو حُذف الحساب. |
| `shifts` | قوالب الشيفتات: وقت البدء والانتهاء، أيام العمل، دقائق السماح. `crosses_midnight` عمود محسوب للشيفتات الليلية. |
| `shift_assignments` | إسناد شيفت لموظف في مدى تواريخ، بقيد **exclusion** يمنع أي تداخل زمني لنفس الموظف. |

### الحضور

| الجدول | الوصف |
|---|---|
| `attendance_sessions` | جلسة الشيفت. `started_at`/`ended_at` من `now()` على الخادم حصرًا. |
| `break_sessions` | الاستراحات داخل الشيفت. |
| `attendance_events` | سجل انتقالات الحالة — **للإلحاق فقط**، أي UPDATE/DELETE يرفعه trigger. |

### النشاط

| الجدول | الوصف |
|---|---|
| `activity_sessions` | جلسة نشاط لكل (شيفت × جهاز × تطبيق مصدر). تعدد الأجهزة يُكتشف من هنا. |
| `activity_heartbeats` | النبضات مجمَّعة في نوافذ زمنية على الخادم. يخزّن `clock_skew_seconds` كمؤشر تدقيق على العبث بساعة الجهاز، و`visible`/`focused`/`engaged` لتفسير سبب احتساب النبضة أو تجاهلها. |
| `activity_events` | العمليات الحقيقية داخل مدعوم — **للإلحاق فقط**. |
| `activity_minutes` | **دفتر أستاذ وقت النشاط.** المفتاح الأساسي `(employee_id, minute_start)`. |
| `employee_runtime_state` | الحالة اللحظية لكل موظف + مؤشر `marked_until` الذي يمنع الاحتساب المزدوج. |

### النتائج والتدقيق

| الجدول | الوصف |
|---|---|
| `employee_daily_stats` | لقطة يومية محسوبة. **ليست مصدر حقيقة** — يمكن إعادة بنائها بالكامل من الخام في أي وقت عبر `eo_admin_recompute`. |
| `audit_logs` | سجل التدقيق. غير قابل للتعديل أو الحذف من أي دور، بما فيهم مالك الجدول. |

## القيود التي تفرض سلامة البيانات

هذه ليست فحوصات في الكود — هي قيود في المحرك نفسه، تعمل حتى لو استُدعيت قاعدة البيانات من أي مسار آخر:

```sql
-- شيفت مفتوح واحد لكل موظف
create unique index attendance_one_open_per_employee
  on emp_ops.attendance_sessions (employee_id) where status = 'open';

-- استراحة مفتوحة واحدة لكل موظف ولكل شيفت
create unique index break_one_open_per_employee
  on emp_ops.break_sessions (employee_id) where status = 'open';

-- استحالة المدة السالبة
constraint attendance_end_after_start check (ended_at is null or ended_at >= started_at)

-- الحالة والنهاية متسقتان دائمًا
constraint attendance_open_has_no_end check ((status = 'open') = (ended_at is null))

-- استحالة تداخل إسنادات الشيفتات
constraint shift_assignment_no_overlap exclude using gist (
  employee_id with =, daterange(effective_from, effective_to, '[]') with &&)

-- استحالة تكرار النبضة في نفس النافذة
constraint heartbeat_unique_bucket unique (activity_session_id, bucket_start)

-- استحالة احتساب الدقيقة مرتين
primary key (employee_id, minute_start)   -- activity_minutes
```

بالإضافة إلى triggers:
- `deny_mutation` على `audit_logs` و`attendance_events` و`activity_events`.
- `guard_closed_attendance` يمنع تعديل أي جلسة مغلقة إلا داخل دالة التعديل الإداري
  التي ترفع علم الجلسة `emp_ops.allow_adjust` — وهو علم لا يستطيع أي عميل ضبطه.

## المهام الدورية (pg_cron)

| المهمة | التكرار | الوظيفة |
|---|---|---|
| `emp_ops_maintenance_tick` | كل دقيقة | إغلاق الشيفتات المهجورة + تحديث الحالة اللحظية (يغذّي البث اللحظي) |
| `emp_ops_daily_rollup` | كل ١٥ دقيقة | إعادة حساب إحصاءات اليوم والأمس لكل الموظفين |

الإغلاق التلقائي يستخدم **آخر نبضة موثوقة** كوقت انتهاء، لا `now()` — حتى لا يُحتسب
للموظف وقت لم يعمله لأن متصفحه أُغلق فجأة.
