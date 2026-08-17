/**
 * إعدادات الاتصال.
 *
 * مفتاح anon مفتاح عام بطبيعته ومصمَّم للظهور في المتصفح — الحماية كلها
 * مبنية على RLS ودوال SECURITY DEFINER في قاعدة البيانات، لا على إخفاء المفتاح.
 *
 * ممنوع منعًا باتًا وضع SUPABASE_SERVICE_ROLE_KEY هنا أو في أي ملف داخل js/.
 * لا يوجد في هذا المشروع أي كود يحتاجه أصلًا.
 *
 * للتشغيل على بيئة أخرى: عرّف window.__EO_CONFIG__ قبل تحميل هذا الملف،
 * أو عدّل القيم أدناه.
 */
const injected = (typeof window !== 'undefined' && window.__EO_CONFIG__) || {};

export const CONFIG = Object.freeze({
  SUPABASE_URL:      injected.SUPABASE_URL      || 'https://srnelrdpqkcntbgudyto.supabase.co',
  SUPABASE_ANON_KEY: injected.SUPABASE_ANON_KEY || 'sb_publishable_0pvB8_xD0txjdJBkYqXMyg__jKMw71W',

  APP_NAME: 'عمليات الموظفين — مدعوم',
  APP_SHORT: 'مدعوم',

  /* المصدر الذي يُوسم به كل نشاط قادم من هذه الواجهة */
  SOURCE_APP: 'emp_ops',

  /* قيم احتياطية تُستخدم فقط قبل وصول الإعدادات الحقيقية من قاعدة البيانات.
     الإعدادات الفعلية تأتي دائمًا من جدول emp_ops.app_settings. */
  FALLBACK: Object.freeze({
    heartbeat_interval_seconds: 60,
    idle_threshold_seconds: 300,
    offline_threshold_seconds: 180,
    timezone: 'Africa/Cairo'
  }),

  /* كل كم ثانية تُحدَّث لوحة الإدارة عند تعذّر البث اللحظي */
  ADMIN_REFRESH_SECONDS: 30
});

if (/SUPABASE_SERVICE_ROLE|service_role/i.test(CONFIG.SUPABASE_ANON_KEY)) {
  throw new Error('خطأ أمني: تم وضع مفتاح خدمة في الواجهة. أوقف التشغيل فورًا.');
}
