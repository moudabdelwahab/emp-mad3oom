/**
 * حراسة الصفحات.
 *
 * ملاحظة مهمة: هذه الحراسة راحة للمستخدم فقط. الحماية الحقيقية في قاعدة
 * البيانات — لو تجاوز أحدهم هذه الشاشة برمجيًا فلن يحصل على أي بيانات،
 * لأن كل دالة تفحص الرتبة على الخادم و RLS تحجب الصفوف.
 */
import { sb } from '../services/client.js';
import { api } from '../services/api.js';
import { setTimezone } from '../utils/format.js';
import { setServerTime } from '../utils/time.js';

/** حالة المستخدم الحالية، متاحة لكل الصفحات بعد الحراسة. */
export const state = { session: null, me: null, rank: 0 };

export async function requireAuth({ minRank = 0 } = {}) {
  const { data } = await sb.auth.getSession();
  if (!data.session) { redirectToLogin(); return null; }
  state.session = data.session;

  let me;
  try {
    me = await api.me();
  } catch (err) {
    if (err.code === 'EO403') { showNotEnrolled(err.message); return null; }
    if (err.isAuth) { redirectToLogin(); return null; }
    throw err;
  }

  state.me = me;
  state.rank = me?.employee?.rank || 0;
  setTimezone(me?.settings?.timezone);
  setServerTime(me.server_time);

  if (state.rank < minRank) {
    location.replace('dashboard.html');
    return null;
  }

  // انتهاء الجلسة أو الخروج من تبويب آخر
  sb.auth.onAuthStateChange((event, session) => {
    if (event === 'SIGNED_OUT' || (!session && event !== 'INITIAL_SESSION')) redirectToLogin();
    if (session) state.session = session;
  });

  return state;
}

function redirectToLogin() {
  const here = location.pathname.split('/').pop() || 'dashboard.html';
  if (here === 'login.html') return;
  location.replace(`login.html?next=${encodeURIComponent(here + location.search)}`);
}

function showNotEnrolled(message) {
  document.body.innerHTML = '';
  const wrap = document.createElement('div');
  wrap.className = 'auth-page';
  wrap.innerHTML = `
    <div class="auth-card">
      <h2 style="margin-bottom:12px">لا يمكن الدخول</h2>
      <p class="muted"></p>
      <button class="btn btn-outline btn-block" id="_out">تسجيل الخروج</button>
    </div>`;
  wrap.querySelector('p').textContent = message || 'حسابك غير مسجَّل كموظف في النظام.';
  document.body.append(wrap);
  wrap.querySelector('#_out').addEventListener('click', async () => {
    await sb.auth.signOut();
    location.replace('login.html');
  });
}

export const isManager = () => state.rank >= 50;
export const isAdmin   = () => state.rank >= 100;
