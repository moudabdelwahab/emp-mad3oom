/** عميل Supabase الوحيد في التطبيق. */
import { CONFIG } from '../config.js';

if (!window.supabase || !window.supabase.createClient) {
  throw new Error('لم يُحمَّل عميل Supabase. تأكد من وسم <script src="js/vendor/supabase.js"> قبل ملفات الوحدات.');
}

export const sb = window.supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,     // تجديد التوكن تلقائيًا قبل انتهائه
    detectSessionInUrl: false,
    storageKey: 'eo.auth'
  },
  global: {
    headers: { 'x-application-name': 'mad3oom-employee-operations' }
  },
  realtime: { params: { eventsPerSecond: 4 } }
});
