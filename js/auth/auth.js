/** المصادقة عبر Supabase Auth الحقيقي. */
import { sb } from '../services/client.js';
import { api } from '../services/api.js';
import { AppError } from '../services/errors.js';

export async function signIn(email, password) {
  const { data, error } = await sb.auth.signInWithPassword({ email: email.trim(), password });
  if (error) throw new AppError(error);
  try { await api.logAuth('login'); } catch { /* الموظف قد لا يكون مسجَّلًا بعد — تتكفّل الحراسة بذلك */ }
  return data.session;
}

export async function signOut() {
  try { await api.logAuth('logout'); } catch { /* تجاهُل: الخروج أولوية */ }
  await sb.auth.signOut();
  localStorage.removeItem('eo.device');   // الجهاز يبقى، لكن ننهي ارتباطه بالجلسة
  location.replace('login.html');
}

export async function getSession() {
  const { data } = await sb.auth.getSession();
  return data.session || null;
}

export function onAuthChange(handler) {
  return sb.auth.onAuthStateChange((event, session) => handler(event, session));
}

export async function sendReset(email) {
  const { error } = await sb.auth.resetPasswordForEmail(email.trim(), {
    redirectTo: new URL('login.html', location.href).href
  });
  if (error) throw new AppError(error);
}
