# التشغيل والنشر

## المتطلبات

- مشروع Supabase (تم استخدام مشروع مدعوم الحالي بمخطط `emp_ops` معزول).
- أي استضافة ملفات ثابتة: Vercel أو Netlify أو Cloudflare Pages أو Nginx.
  **لا يوجد build step ولا اعتماديات npm للتشغيل** — الملفات تُرفع كما هي.

## ١) قاعدة البيانات

الملفات في `supabase/migrations/` مرقّمة ويجب تنفيذها بالترتيب:

```bash
# عبر Supabase CLI
supabase link --project-ref <ref>
supabase db push
```

أو نسخ محتوى كل ملف بالترتيب في **SQL Editor** داخل لوحة Supabase.

| الملف | المحتوى |
|---|---|
| `0001` | المخطط، الأدوار، أنواع النشاط، الإعدادات |
| `0002` | الموظفون، الفرق، الشيفتات، الإسنادات |
| `0003` | الحضور والاستراحات وأحداثها |
| `0004` | جلسات النشاط، النبضات، الأحداث، دقائق النشاط |
| `0005` | الإحصاءات اليومية وسجل التدقيق |
| `0006` | الهوية و RLS والصلاحيات |
| `0007` | محرك الحالة والدقائق والإحصاءات |
| `0008` | واجهات الحضور |
| `0009` | استيعاب النشاط |
| `0010` | لوحات القراءة |
| `0011` | التقارير وعمليات الإدارة |
| `0012` | الصيانة، pg_cron، البث اللحظي |
| `0013` | الربط التلقائي بالحساب + البذرة |
| `0014` | تصحيح ترتيب احتساب النشاط |
| `0015` | تصحيح عدّ الأجهزة |
| `0016` | القوائم المرجعية |

بعد التنفيذ تحقق:

```sql
select count(*) from information_schema.tables where table_schema = 'emp_ops';         -- 18
select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname like 'eo\_%';                                  -- 34
select count(*) from pg_tables where schemaname='emp_ops' and not rowsecurity;         -- 0
select count(*) from cron.job where jobname like 'emp_ops%';                           -- 2
```

## ٢) المدير العام الأول

الترحيل `0013` ينشئ مديرًا عامًا للبريد `mahmoudabdelwahabsa@gmail.com` إن وُجد
حساب به. لإضافة مدير عام آخر:

```sql
insert into emp_ops.employees (user_id, full_name, email, role, status)
select id, 'الاسم الكامل', lower(email), 'super_admin', 'active'
from auth.users where lower(email) = 'admin@mad3oom.com'
on conflict (user_id) do update set role = 'super_admin';
```

بعدها تتم كل إضافة موظف من الواجهة. الموظف الذي يُضاف ببريد ليس له حساب بعد
يظهر بحالة "بانتظار التسجيل"، ويُربط تلقائيًا عند أول دخول له بنفس البريد
(اعتمادًا على البريد داخل الـ JWT الموقَّع، لا على أي مدخل من العميل).

## ٣) متغيرات البيئة

المشروع ثابت بالكامل، فلا توجد متغيرات بيئة على الخادم. الإعدادات في
`js/config.js`:

| المفتاح | القيمة |
|---|---|
| `SUPABASE_URL` | رابط مشروع Supabase |
| `SUPABASE_ANON_KEY` | مفتاح `publishable` أو `anon` — **عام بطبيعته** |

للنشر على أكثر من بيئة دون تعديل الملف، عرّف قبل تحميل الوحدات:

```html
<script>
  window.__EO_CONFIG__ = { SUPABASE_URL: '…', SUPABASE_ANON_KEY: '…' };
</script>
```

> `SUPABASE_SERVICE_ROLE_KEY` لا يُوضع هنا ولا في أي ملف داخل `js/`.
> النظام لا يحتاجه أصلًا، و`config.js` يوقف التطبيق إن اكتُشف.

## ٤) النشر

### Vercel

```bash
npm i -g vercel && vercel --prod
```

الملف `vercel.json` الموجود في المستودع يضبط ترويسات الأمان ويمنع فهرسة النظام.

### أي خادم ثابت

```bash
rsync -av --exclude node_modules ./ user@server:/var/www/emp-ops/
```

المتطلب الوحيد: **HTTPS** (Web Locks و`crypto.randomUUID` وSupabase Auth تحتاجه).

## ٥) الإعدادات بعد التشغيل

من صفحة **الإعدادات** (مدير عام):

| الإعداد | الافتراضي | ملاحظة |
|---|---|---|
| عتبة الخمول | ٣٠٠ ث | ابدأ بـ٥ دقائق وراقب أسبوعًا قبل التغيير |
| فترة النبض | ٦٠ ث | تقليلها يزيد الطلبات؛ زيادتها تؤخر كشف الانقطاع |
| عتبة عدم الاتصال | ١٨٠ ث | يجب أن تكون ≥ ضعف فترة النبض |
| الإغلاق التلقائي | ١٢ ساعة | إغلاق الشيفتات المنسية |
| المنطقة الزمنية | Africa/Cairo | تُغيَّر من هنا دون لمس الكود |

## ٦) المتابعة التشغيلية

```sql
-- المهام الدورية
select jobname, schedule, active from cron.job where jobname like 'emp_ops%';
select status, return_message, start_time from cron.job_run_details
 order by start_time desc limit 10;

-- حجم البيانات
select relname, n_live_tup from pg_stat_user_tables
 where schemaname = 'emp_ops' order by n_live_tup desc;
```

**النمو المتوقع:** ١٠٠ موظف × ٨ ساعات ⇒ ≈ ٤٨ ألف صف/يوم في `activity_minutes`
و≈ ٩٦ ألف نبضة/يوم. أرشفة النبضات الأقدم من ٩٠ يومًا كافية؛ `activity_minutes`
تبقى لأنها سند التدقيق للأرقام.
