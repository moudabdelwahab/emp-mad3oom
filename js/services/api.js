/**
 * طبقة الـ API — العقد الوحيد بين الواجهة وقاعدة البيانات.
 *
 * لا يوجد في التطبيق كله أي استعلام مباشر على جدول ولا أي كتابة مباشرة.
 * كل شيء يمرّ من هنا عبر دوال public.eo_* التي تفحص الهوية والصلاحية على الخادم.
 */
import { sb } from './client.js';
import { AppError } from './errors.js';
import { setServerTime } from '../utils/time.js';

async function rpc(fn, args = {}) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new AppError(error);
  if (data && typeof data === 'object' && !Array.isArray(data) && data.server_time) {
    setServerTime(data.server_time);          // مزامنة الساعة مع الخادم
  }
  return data;
}

export const api = {
  /* ── الهوية والحالة ── */
  me:               ()                    => rpc('eo_me'),
  logAuth:          (event)               => rpc('eo_log_auth', { p_event: event }),

  /* ── الحضور ── */
  startShift:       (client)              => rpc('eo_start_shift', { p_client: client || {} }),
  endShift:         (note)                => rpc('eo_end_shift', { p_note: note || null }),
  startBreak:       (type, note)          => rpc('eo_start_break', { p_break_type: type || 'general', p_note: note || null }),
  endBreak:         ()                    => rpc('eo_end_break'),

  /* ── النشاط ── */
  ingest:           (payload)             => rpc('eo_ingest_activity', { p_payload: payload }),
  closeDevice:      (deviceId)            => rpc('eo_close_device', { p_device_id: deviceId }),

  /* ── لوحة الموظف ── */
  myTimeline:       (date)                => rpc('eo_my_timeline', { p_date: date || null }),
  myHistory:        (from, to)            => rpc('eo_my_history', { p_from: from, p_to: to }),
  myActivity:       (date, limit)         => rpc('eo_my_activity', { p_date: date || null, p_limit: limit || 100 }),

  /* ── لوحة الإدارة ── */
  overview:         ()                    => rpc('eo_admin_overview'),
  employeesLive:    ()                    => rpc('eo_admin_employees_live'),
  employeeDetail:   (id, date)            => rpc('eo_admin_employee_detail', { p_employee_id: id, p_date: date || null }),
  employeeTimeline: (id, date)            => rpc('eo_admin_employee_timeline', { p_employee_id: id, p_date: date || null }),
  employeeActivity: (id, date, limit)     => rpc('eo_admin_employee_activity', { p_employee_id: id, p_date: date || null, p_limit: limit || 200 }),
  employeeHistory:  (id, from, to)        => rpc('eo_admin_employee_history', { p_employee_id: id, p_from: from, p_to: to }),
  multiDevice:      ()                    => rpc('eo_admin_multi_device'),

  /* ── التقارير ── */
  report:           (from, to, employeeId, teamId) =>
                       rpc('eo_report', { p_from: from, p_to: to, p_employee_id: employeeId || null, p_team_id: teamId || null }),
  logExport:        (kind, meta)          => rpc('eo_log_export', { p_kind: kind, p_meta: meta || {} }),

  /* ── إدارة الموظفين ── */
  listEmployees:    ()                    => rpc('eo_admin_list_employees'),
  upsertEmployee:   (payload)             => rpc('eo_admin_upsert_employee', { p_payload: payload }),
  setRole:          (id, role)            => rpc('eo_admin_set_role', { p_employee_id: id, p_role: role }),
  setStatus:        (id, status, reason)  => rpc('eo_admin_set_status', { p_employee_id: id, p_status: status, p_reason: reason || null }),

  /* ── تدخلات الحضور ── */
  forceEndShift:    (id, reason)          => rpc('eo_admin_force_end_shift', { p_employee_id: id, p_reason: reason }),
  adjustAttendance: (sessionId, startedAt, endedAt, reason) =>
                       rpc('eo_admin_adjust_attendance', { p_session_id: sessionId, p_started_at: startedAt, p_ended_at: endedAt, p_reason: reason }),

  /* ── الفرق والشيفتات ── */
  upsertTeam:       (payload)             => rpc('eo_admin_upsert_team', { p_payload: payload }),
  upsertShift:      (payload)             => rpc('eo_admin_upsert_shift', { p_payload: payload }),
  assignShift:      (employeeId, shiftId, from, to) =>
                       rpc('eo_admin_assign_shift', { p_employee_id: employeeId, p_shift_id: shiftId, p_from: from, p_to: to || null }),

  /* ── الإعدادات وسجل التدقيق ── */
  settings:         ()                    => rpc('eo_admin_settings'),
  setSetting:       (key, value)          => rpc('eo_admin_set_setting', { p_key: key, p_value: value }),
  auditLogs:        (f = {})              => rpc('eo_admin_audit_logs', {
                        p_from: f.from || null, p_to: f.to || null, p_action: f.action || null,
                        p_employee_id: f.employeeId || null, p_limit: f.limit || 100, p_offset: f.offset || 0 }),
  recompute:        (employeeId, from, to) => rpc('eo_admin_recompute', { p_employee_id: employeeId || null, p_from: from, p_to: to }),

  /* ── القوائم المرجعية (فرق، شيفتات، أدوار، أنواع نشاط) في نداء واحد ── */
  lists:            ()                    => rpc('eo_lists')
};

export { sb };
