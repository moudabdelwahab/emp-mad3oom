-- 0017 — تثبيت search_path على الدوال المتبقية
--
-- ستّ دوال مساعدة (اثنتان منها triggers) كانت بلا search_path مثبَّت.
-- رغم أنها SECURITY INVOKER وخطرها محدود، فإن ترك المسار قابلًا للتغيير يفتح
-- بابًا نظريًا لاختطاف أسماء الدوال عبر مخطط يسبق في المسار.
-- رصدها مدقّق Supabase الأمني (function_search_path_mutable).

alter function emp_ops.deny_mutation()            set search_path = emp_ops, pg_temp;
alter function emp_ops.guard_closed_attendance()  set search_path = emp_ops, pg_temp;
alter function emp_ops.touch_updated_at()         set search_path = emp_ops, pg_temp;
alter function emp_ops.presence_label(text)       set search_path = emp_ops, pg_temp;
alter function emp_ops.session_seconds(timestamptz, timestamptz) set search_path = emp_ops, pg_temp;
alter function emp_ops.try_ts(text)               set search_path = emp_ops, pg_temp;

-- ملاحظة على التحذير الآخر (authenticated_security_definer_function_executable):
-- المدقّق يشير إلى أن ٣٤ دالة SECURITY DEFINER قابلة للتنفيذ من دور authenticated.
-- هذا هو تصميم النظام بعينه وليس ثغرة: الجداول لا تملك أي صلاحية كتابة لأي دور
-- عميل، فكل تغيير يجب أن يمرّ عبر دالة تفحص الهوية والرتبة على الخادم.
-- كل دالة من الـ٣٤ تبدأ بـ require_employee() أو require_rank(n)، وهو ما تتحقق
-- منه اختبارات tests/02_security_and_integrity.sql (ح10 · ح11 · ح12 · ح15 · ح17).
