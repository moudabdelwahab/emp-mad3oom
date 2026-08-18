/**
 * ترجمة أخطاء قاعدة البيانات إلى رسائل عربية واضحة.
 *
 * الرسائل العربية تأتي أصلًا من دوال قاعدة البيانات (RAISE EXCEPTION بالعربية)،
 * وهذه الطبقة تتعامل مع الأخطاء التقنية التي لا يُفترض أن يراها المستخدم كما هي.
 */

const BY_CODE = {
  EO001: 'لديك شيفت مفتوح بالفعل.',
  EO002: 'لا يوجد شيفت مفتوح.',
  EO003: 'لا يمكن بدء استراحة بدون شيفت مفتوح.',
  EO004: 'لديك استراحة مفتوحة بالفعل.',
  EO005: 'لا توجد استراحة مفتوحة.',
  EO401: 'انتهت جلستك. سجّل الدخول مرة أخرى.',
  EO403: 'ليست لديك صلاحية تنفيذ هذه العملية.',
  EO404: 'العنصر المطلوب غير موجود.',
  EO400: 'البيانات المُرسلة غير صالحة.',
  EO090: 'هذا السجل محمي ولا يمكن تعديله أو حذفه.',
  EO091: 'لا يمكن تعديل سجل مغلق إلا عبر التعديل الإداري الموثَّق.',
  '42501': 'ليست لديك صلاحية على هذه البيانات.',
  '23505': 'يوجد سجل مطابق بالفعل.',
  '23514': 'القيمة المُدخلة تخالف قواعد سلامة البيانات.',
  PGRST301: 'انتهت صلاحية الجلسة. سجّل الدخول مرة أخرى.'
};

const AUTH_MESSAGES = {
  'Invalid login credentials': 'البريد الإلكتروني أو كلمة المرور غير صحيحة.',
  'Email not confirmed': 'لم يُفعَّل هذا البريد بعد. راجع بريدك الإلكتروني.',
  'User not found': 'لا يوجد حساب بهذا البريد.',
  'Invalid Refresh Token: Refresh Token Not Found': 'انتهت جلستك. سجّل الدخول مرة أخرى.'
};

/** هل يعني هذا الخطأ أن الجلسة انتهت ويجب إخراج المستخدم؟ */
export function isAuthError(error) {
  if (!error) return false;
  const code = error.code || '';
  const msg = error.message || '';
  return code === 'EO401' || code === 'PGRST301' ||
         /jwt|token|session/i.test(msg) && /expire|invalid|missing/i.test(msg);
}

export function messageOf(error) {
  if (!error) return 'حدث خطأ غير متوقع.';
  if (typeof error === 'string') return error;

  // رسائل دوال قاعدة البيانات عربية بالفعل — تُعرض كما هي
  const raw = error.message || error.msg || '';
  if (/[؀-ۿ]/.test(raw)) return raw;

  if (AUTH_MESSAGES[raw]) return AUTH_MESSAGES[raw];
  if (BY_CODE[error.code]) return BY_CODE[error.code];

  if (/Failed to fetch|NetworkError|network/i.test(raw)) {
    return 'تعذّر الاتصال بالخادم. تحقّق من اتصالك بالإنترنت.';
  }
  if (/rate limit|too many/i.test(raw)) {
    return 'عدد المحاولات كبير. انتظر قليلًا ثم أعد المحاولة.';
  }
  return raw || 'حدث خطأ غير متوقع.';
}

export class AppError extends Error {
  constructor(error) {
    super(messageOf(error));
    this.original = error;
    this.code = error && error.code;
    this.isAuth = isAuthError(error);
  }
}
