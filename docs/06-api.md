# واجهة الـ API

كل الدوال في مخطط `public` بسابقة `eo_`، وتُستدعى عبر PostgREST:

```
POST {SUPABASE_URL}/rest/v1/rpc/{function}
Authorization: Bearer {access_token}
apikey: {publishable_key}
```

في الواجهة تُستدعى كلها من `js/services/api.js` — لا يوجد نداء واحد خارج هذا الملف.

## واجهات الموظف (رتبة ١٠+)

| الدالة | البارامترات | تُعيد |
|---|---|---|
| `eo_me()` | — | حالة الموظف الكاملة: هويته، شيفته، استراحته، إجمالياته، الإعدادات، وقت الخادم |
| `eo_start_shift(p_client jsonb)` | `{device_id, user_agent, platform}` | الحالة بعد البدء |
| `eo_end_shift(p_note text)` | ملاحظة اختيارية | الحالة بعد الإنهاء |
| `eo_start_break(p_break_type, p_note)` | نوع الاستراحة | الحالة |
| `eo_end_break()` | — | الحالة |
| `eo_ingest_activity(p_payload jsonb)` | نبضة + دفعة أحداث | الحالة والإجماليات والثواني المُحتسبة |
| `eo_close_device(p_device_id)` | معرّف الجهاز | `true` |
| `eo_my_timeline(p_date)` | تاريخ (افتراضي: اليوم) | صفوف الخط الزمني (فترات الخمول تحمل `meta.reason` و`meta.reason_label`) |
| `eo_my_history(p_from, p_to)` | مدى ≤ ٤٠٠ يوم | صف لكل يوم — يشمل `present_seconds` و`present_pct` |
| `eo_request_correction(date, from, to, minutes, reason)` | يوم + فترة داخل شيفت واحد + دقائق ≤ دقائق الفترة + سبب ≥ ١٠ أحرف | الطلب المعلَّق |
| `eo_my_correction_requests()` | — | طلبات التصحيح الخاصة بالموظف وحالاتها |
| `eo_my_activity(p_date, p_limit)` | — | عمليات الموظف داخل المنصة |
| `eo_report(p_from, p_to, …)` | — | تقرير (يُقصر قسرًا على بيانات الطالب) |
| `eo_lists()` | — | القوائم المرجعية |
| `eo_log_auth(p_event)` | `login` / `logout` | تسجيل في سجل التدقيق |

### حمولة `eo_ingest_activity`

```jsonc
{
  "device_id":   "uuid ثابت في localStorage",   // إلزامي
  "source_app":  "mad3oom" | "emp_ops",
  "interactions": 7,          // عدّاد فقط — لا محتوى
  "visible":      true,
  "tabs":         3,
  "client_time": "…",         // للتدقيق فقط، لا يدخل أي حساب
  "events": [
    { "type": "ticket_reply", "entity_type": "ticket", "entity_id": "T-42", "metadata": {} }
  ]
}
```

الرد:

```jsonc
{
  "status": "ok" | "throttled" | "no_session",
  "server_time": "…",
  "presence": "active", "presence_label": "نشط",
  "credited_seconds": 60,      // ما احتُسب فعلًا في هذا النداء
  "stored_events": 1,
  "on_break": false,
  // جديد في 0019:
  "break_auto_ended": false,   // أُنهيت استراحة مفتوحة بحدث عمل حقيقي
  "backfilled_seconds": 0,     // ما اعتُمد رجعيًا من انخراط الدقائق السابقة
  "present_credited_seconds": 0,// حضور مُحتسب في هذا النداء (ظاهر + Focus)
  "last_interaction_at": "…",
  "idle_seconds": 0,            // ثوانٍ منذ آخر تفاعل حقيقي
  "totals": { "shift_seconds": …, "break_seconds": …, "active_seconds": …, "idle_seconds": …, "active_pct": …,
              "present_seconds": …, "present_pct": … },
  "next_heartbeat_seconds": 60 // الخادم يملي إيقاع النبض
}
```

`throttled` ليست خطأً: العميل يعيد الحمولة إلى طابوره ويعيد المحاولة.
`no_session` تعني لا شيفت مفتوح ⇒ لا يُحتسب أي نشاط.

## واجهات الإدارة (رتبة ٥٠+)

| الدالة | الوظيفة |
|---|---|
| `eo_admin_overview()` | عدّادات اللحظة + إجماليات اليوم (يشمل `present_seconds` و`avg_present_pct`) |
| `eo_admin_employees_live()` | صف لكل موظف بحالته وأرقامه (يشمل `present_seconds` و`present_pct`) |
| `eo_admin_correction_requests(status)` | طلبات التصحيح (افتراضيًا المعلَّقة) |
| `eo_admin_review_correction(id, approve, note)` | اعتماد يكتب الدقائق بمصدر `correction`، أو رفض بسبب إلزامي — المراجع لا يراجع طلب نفسه |
| `eo_admin_employee_detail(id, date)` | تفاصيل يوم موظف: جلسات، استراحات، أجهزة |
| `eo_admin_employee_timeline(id, date)` | الخط الزمني |
| `eo_admin_employee_activity(id, date, limit)` | عملياته داخل المنصة |
| `eo_admin_employee_history(id, from, to)` | أيامه السابقة |
| `eo_admin_multi_device()` | من لديه أكثر من جهاز نشط |
| `eo_admin_list_employees()` | قائمة الموظفين للإدارة |
| `eo_admin_force_end_shift(id, reason)` | إنهاء شيفت إداريًا (السبب إلزامي) |
| `eo_admin_upsert_team / upsert_shift / assign_shift` | الفرق والشيفتات |
| `eo_admin_audit_logs(…)` | سجل التدقيق مع فلاتر |
| `eo_admin_settings()` | قراءة الإعدادات |
| `eo_admin_recompute(id, from, to)` | إعادة بناء الإحصاءات من الخام |
| `eo_log_export(kind, meta)` | توثيق تصدير تقرير |

## واجهات المدير العام (رتبة ١٠٠)

| الدالة | الوظيفة |
|---|---|
| `eo_admin_upsert_employee(payload)` | إنشاء/تعديل موظف (يربطه تلقائيًا بحساب بنفس البريد) |
| `eo_admin_set_role(id, role)` | تغيير الدور — لا يمكن تغيير دور النفس |
| `eo_admin_set_status(id, status, reason)` | نشط / موقوف / مؤرشف — لا يمكن على النفس |
| `eo_admin_adjust_attendance(session, start, end, reason)` | تعديل سجل مغلق — السبب إلزامي، والقديم والجديد يُحفظان |
| `eo_admin_set_setting(key, value)` | تعديل إعداد مع فحص المدى المسموح |

## رموز الأخطاء

الرسائل تصل بالعربية من قاعدة البيانات مباشرةً. الرموز للتصنيف البرمجي:

| الرمز | المعنى |
|---|---|
| `EO001` | شيفت مفتوح بالفعل |
| `EO002` | لا يوجد شيفت مفتوح |
| `EO003` | استراحة بدون شيفت |
| `EO004` | استراحة مفتوحة بالفعل |
| `EO005` | لا توجد استراحة مفتوحة |
| `EO006`–`EO010` | مخالفات تعديل الحضور (شيفت مفتوح، نهاية قبل بداية، وقت مستقبلي، مدة تتجاوز الحد، تداخل إسناد) |
| `EO090` | محاولة تعديل سجل للإلحاق فقط |
| `EO091` | محاولة تعديل سجل مغلق خارج المسار الإداري |
| `EO400` | مدخلات غير صالحة |
| `EO401` | غير مسجَّل دخول |
| `EO403` | لا صلاحية / حساب موقوف / مراجعة ذاتية لطلب تصحيح |
| `EO404` | غير موجود |
| `EO011` | طلب تصحيح معلَّق يتداخل مع الفترة المطلوبة |
