/**
 * محرك تتبّع النشاط.
 *
 * ما يجمعه هذا الملف بالضبط:
 *   • عدّاد رقمي لعدد التفاعلات منذ آخر نبضة (رقم واحد، بلا أي محتوى).
 *   • هل التبويب ظاهر أم مخفي.
 *   • عدد التبويبات المفتوحة على هذا الجهاز.
 *   • أحداث عمل معرَّفة مسبقًا يرسلها التطبيق صراحةً (فتح تذكرة، إرسال رد…).
 *
 * ما لا يجمعه إطلاقًا:
 *   • أي حرف أو كلمة يكتبها المستخدم — تُعدّ ضغطات المفاتيح عدًّا فقط ولا
 *     يُقرأ أي مفتاح ولا يُخزَّن.
 *   • إحداثيات الفأرة، لقطات الشاشة، عناوين المواقع الأخرى، أي نشاط خارج
 *     هذه الصفحات.
 *
 * تعدد التبويبات:
 *   يُنتخب تبويب واحد "قائدًا" عبر Web Locks، وهو وحده من يرسل النبضات.
 *   بقية التبويبات ترسل عدّاداتها إليه عبر BroadcastChannel. النتيجة: طلب
 *   واحد كل فترة نبض مهما بلغ عدد التبويبات — والخادم يضمن عدم الازدواج
 *   مرة أخرى بمفتاح دقائق النشاط.
 */
import { api } from '../services/api.js';
import { CONFIG } from '../config.js';

const DEVICE_KEY = 'eo.device';
const CHANNEL = 'eo.tracker';

function deviceId() {
  let id = localStorage.getItem(DEVICE_KEY);
  if (!id) {
    id = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2));
    localStorage.setItem(DEVICE_KEY, id);
  }
  return id;
}

export class ActivityTracker {
  constructor({ sourceApp = CONFIG.SOURCE_APP, onStatus = () => {}, onError = () => {} } = {}) {
    this.sourceApp = sourceApp;
    this.onStatus = onStatus;
    this.onError = onError;

    this.device = deviceId();
    this.tabId = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random())).slice(0, 8);
    this.interactions = 0;
    this.queue = [];                 // أحداث لم تُرسل بعد
    this.tabs = new Map([[this.tabId, Date.now()]]);
    this.isLeader = false;
    this.running = false;
    this.failures = 0;
    this.intervalSec = CONFIG.FALLBACK.heartbeat_interval_seconds;
    this._timer = null;
    this._bc = null;
    this._bound = [];
  }

  /* ── دورة الحياة ───────────────────────────────────── */

  start() {
    if (this.running) return;
    this.running = true;
    this._listen();
    this._openChannel();
    this._electLeader();
    this._schedule(2);               // نبضة أولى سريعة لتثبيت الحالة
  }

  stop() {
    this.running = false;
    clearTimeout(this._timer);
    this._bound.forEach(([t, e, h, o]) => t.removeEventListener(e, h, o));
    this._bound = [];
    if (this._bc) { try { this._bc.close(); } catch {} this._bc = null; }
  }

  /** تسجيل حدث عمل حقيقي (يُستدعى من التطبيق). */
  track(type, { entityType, entityId, metadata } = {}) {
    if (!type) return;
    this.queue.push({
      type,
      entity_type: entityType || null,
      entity_id: entityId != null ? String(entityId) : null,
      metadata: metadata || {},
      client_time: new Date().toISOString()
    });
    if (this.queue.length > 200) this.queue.splice(0, this.queue.length - 200);
    this.bump();
    if (this.queue.length >= 10) this._schedule(1);   // دفعة كبيرة ⇒ أرسل الآن
  }

  /** زيادة عدّاد التفاعلات (رقم فقط). */
  bump() {
    this.interactions++;
    if (!this.isLeader && this._bc) {
      this._bc.postMessage({ t: 'delta', tab: this.tabId, n: 1 });
      this.interactions = 0;
    }
  }

  /* ── الاستماع للتفاعل ──────────────────────────────── */

  _on(target, event, handler, opts) {
    target.addEventListener(event, handler, opts);
    this._bound.push([target, event, handler, opts]);
  }

  _listen() {
    const bump = () => this.bump();

    // نقر ولمس — تفاعل صريح
    this._on(document, 'pointerdown', bump, { passive: true });
    // كتابة — يُعدّ عدًّا فقط؛ لا يُقرأ أي مفتاح ولا يُخزَّن
    this._on(document, 'keydown', bump, { passive: true });

    // تمرير — مخنوق حتى لا يضخّم العدّاد
    let lastScroll = 0;
    this._on(window, 'scroll', () => {
      const now = Date.now();
      if (now - lastScroll > 4000) { lastScroll = now; this.bump(); }
    }, { passive: true });

    this._on(document, 'visibilitychange', () => {
      if (document.visibilityState === 'visible') { this.bump(); this._schedule(1); }
    });

    this._on(window, 'online',  () => { this._schedule(1); });
    this._on(window, 'offline', () => { this.onStatus({ status: 'offline_client' }); });

    // إغلاق التبويب: أبلغ الآخرين، وأغلق جلسة الجهاز إن كان آخر تبويب
    this._on(window, 'pagehide', () => {
      if (this._bc) this._bc.postMessage({ t: 'bye', tab: this.tabId });
      this.tabs.delete(this.tabId);
      if (this.isLeader && this.tabs.size === 0) {
        try { api.closeDevice(this.device); } catch { /* أفضل جهد */ }
      }
    });
  }

  /* ── التنسيق بين التبويبات ─────────────────────────── */

  _openChannel() {
    if (typeof BroadcastChannel === 'undefined') return;
    this._bc = new BroadcastChannel(CHANNEL);
    this._bc.onmessage = (ev) => {
      const m = ev.data || {};
      if (m.tab && m.tab !== this.tabId) this.tabs.set(m.tab, Date.now());
      if (m.t === 'delta' && this.isLeader) this.interactions += m.n || 0;
      if (m.t === 'bye') this.tabs.delete(m.tab);
      if (m.t === 'status' && !this.isLeader) this.onStatus(m.payload);   // شارك النتيجة مع بقية التبويبات
      if (m.t === 'ping' && this._bc) this._bc.postMessage({ t: 'pong', tab: this.tabId });
    };
    setInterval(() => {
      if (!this.running || !this._bc) return;
      this._bc.postMessage({ t: 'ping', tab: this.tabId });
      const cutoff = Date.now() - 15000;
      for (const [id, seen] of this.tabs) if (id !== this.tabId && seen < cutoff) this.tabs.delete(id);
    }, 5000);
  }

  /** قائد واحد لكل جهاز — Web Locks تُحرَّر تلقائيًا عند إغلاق التبويب. */
  _electLeader() {
    if (!navigator.locks) { this.isLeader = true; return; }
    navigator.locks.request('eo-activity-leader', { mode: 'exclusive' }, () =>
      new Promise((release) => {
        this.isLeader = true;
        this._releaseLock = release;
        if (!this.running) release();
      })
    ).catch(() => { this.isLeader = true; });
  }

  /* ── النبض ─────────────────────────────────────────── */

  _schedule(seconds) {
    clearTimeout(this._timer);
    if (!this.running) return;
    this._timer = setTimeout(() => this._beat(), Math.max(1, seconds) * 1000);
  }

  async _beat() {
    if (!this.running) return;

    // التبويب التابع لا يرسل شيئًا — القائد يتكفّل
    if (!this.isLeader) { this._schedule(this.intervalSec); return; }

    if (!navigator.onLine) {
      this.onStatus({ status: 'offline_client' });
      this._schedule(Math.min(this.intervalSec, 20));
      return;
    }

    const sending = this.queue;
    const count = this.interactions;
    this.queue = [];
    this.interactions = 0;

    const payload = {
      device_id: this.device,
      source_app: this.sourceApp,
      interactions: count,
      visible: document.visibilityState === 'visible',
      tabs: Math.max(1, this.tabs.size),
      client_time: new Date().toISOString(),
      user_agent: navigator.userAgent,
      platform: navigator.platform || '',
      events: sending.slice(0, 50)
    };

    try {
      const res = await api.ingest(payload);
      this.failures = 0;

      if (res.next_heartbeat_seconds) this.intervalSec = Number(res.next_heartbeat_seconds) || this.intervalSec;

      if (res.status === 'throttled') {
        // أعِد ما لم يُرسل إلى الطابور ولا تحتسبه ضائعًا
        this.queue = sending.concat(this.queue);
        this.interactions += count;
        this._schedule(Number(res.retry_after_seconds) || 30);
        return;
      }

      this.onStatus(res);
      if (this._bc) this._bc.postMessage({ t: 'status', tab: this.tabId, payload: res });

      if (res.status === 'no_session') { this._schedule(this.intervalSec * 2); return; }
      this._schedule(this.intervalSec);
    } catch (err) {
      // فشل الشبكة: لا نفقد شيئًا — نُعيد الحمولة إلى الطابور ونتراجع تدريجيًا
      this.queue = sending.concat(this.queue).slice(-200);
      this.interactions += count;
      this.failures++;
      this.onError(err);
      if (err.isAuth) { this.stop(); return; }
      const backoff = Math.min(this.intervalSec * Math.pow(2, this.failures), 300);
      this.onStatus({ status: 'retrying', in_seconds: backoff });
      this._schedule(backoff);
    }
  }
}
