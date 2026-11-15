'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const express = require('express');

const ALLOWED_EVENT_TYPES = new Set([
  'subscription_activated',
  'subscription_renewed',
  'debt_reminder',
  'debt_paid',
  'expiry_3days',
  'subscription_expired',
  'general_message',
  'broadcast',
  'payment_approved',
  'payment_rejected',
]);
const SESSION_NAME_PREFIX = 'netagent_';

function isAllowedEventType(eventType) {
  return ALLOWED_EVENT_TYPES.has(eventType);
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function sessionNameForUid(uid) {
  return `${SESSION_NAME_PREFIX}${sha256(uid).slice(0, 40)}`;
}

function normalizePhone(value) {
  let phone = String(value || '').replace(/\D/g, '');
  if (phone.startsWith('00')) phone = phone.slice(2);
  if (phone.startsWith('9640')) phone = `964${phone.slice(4)}`;
  else if (phone.startsWith('0')) phone = `964${phone.slice(1)}`;
  else if (phone.length === 10 && phone.startsWith('7')) phone = `964${phone}`;
  return phone;
}

// Accepted product-image types, keyed by their declared MIME. `sniff` checks
// the leading bytes so a forged Content-Type cannot smuggle a non-image.
const IMAGE_TYPES = {
  'image/jpeg': {
    ext: 'jpg',
    sniff: (b) => b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff,
  },
  'image/png': {
    ext: 'png',
    sniff: (b) =>
      b.length >= 8 &&
      b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
      b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a,
  },
  'image/webp': {
    ext: 'webp',
    sniff: (b) =>
      b.length >= 12 &&
      b.toString('ascii', 0, 4) === 'RIFF' &&
      b.toString('ascii', 8, 12) === 'WEBP',
  },
};

// Returns the detected image MIME from the leading bytes, or null.
function detectImageType(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) return null;
  for (const [type, spec] of Object.entries(IMAGE_TYPES)) {
    if (spec.sniff(buffer)) return type;
  }
  return null;
}

// Simple in-memory sliding-window limiter keyed by uid. Single-instance only,
// which matches the one-container deployment; it resets on restart.
function createRateLimiter({ max, windowMs, key: keyFor }, now = Date.now) {
  const hits = new Map();
  return function rateLimit(req, res, next) {
    const key = keyFor ? keyFor(req) : req.rateKey || req.agentUid || 'anonymous';
    const t = now();
    const recent = (hits.get(key) || []).filter((ts) => t - ts < windowMs);
    if (recent.length >= max) {
      hits.set(key, recent);
      return res.status(429).json({ success: false, error: 'rate_limited' });
    }
    recent.push(t);
    hits.set(key, recent);
    if (hits.size > 5000) {
      for (const [k, v] of hits) {
        if (!v.some((ts) => t - ts < windowMs)) hits.delete(k);
      }
    }
    return next();
  };
}

function isAuthorizedAccount(authUser, uid) {
  if (
    !authUser ||
    authUser.disabled !== false ||
    typeof uid !== 'string' ||
    !uid ||
    uid.includes('/')
  ) {
    return false;
  }
  return true;
}

// مدد الخطط: نسخة من AppStore._subscriptionDurationForPlan في lib/models.dart.
const DAY_MS = 24 * 60 * 60 * 1000;
const PLAN_DAYS = {
  free_15_days: 15,
  trial: 15,
  three_months: 90,
  '3m': 90,
  six_months: 183,
  '6m': 183,
  one_year: 365,
  '1y': 365,
};

function toMillis(value) {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  const asNumber = Number(value);
  if (Number.isFinite(asNumber)) return asNumber;
  const parsed = Date.parse(String(value));
  return Number.isNaN(parsed) ? null : parsed;
}

/** نهاية اشتراك الوكيل بالملّي ثانية، أو null إن لم تُعرف (= غير نشط). */
function subscriptionEndMs(subscription) {
  if (!subscription || typeof subscription !== 'object') return null;
  const end = toMillis(subscription.endDate);
  if (end !== null) return end;
  const start = toMillis(subscription.startDate);
  const days = PLAN_DAYS[String(subscription.plan || '').trim()];
  return start !== null && days ? start + days * DAY_MS : null;
}

/**
 * R1: البوابة تخدم الوكلاء الحقيقيين فقط، بنفس قاعدة التطبيق
 * (AppStore.refreshSubscriptionStatus): المدير دائماً، وغيره يحتاج
 * profile.role=agent وstatus=active وخطة غير free لم تنتهِ.
 */
function isEligibleAgent({ authUser, uid, adminUid, profile, subscription, now = Date.now() }) {
  if (!isAuthorizedAccount(authUser, uid)) return false;
  if (adminUid && uid === adminUid) return true;
  if (!profile || profile.role !== 'agent' || profile.status !== 'active') return false;
  const plan = String(subscription?.plan || '').trim();
  if (!plan || plan === 'free') return false;
  const end = subscriptionEndMs(subscription);
  return end !== null && now < end;
}

/**
 * يبني دالة التحقق المستعملة في requireAgent وفي المجدول. القرار يُحفظ
 * دقيقة واحدة لكل uid حتى لا يقرأ كل طلب من قاعدة البيانات؛ فتجديد اشتراك
 * أو انتهاؤه يظهر أثره خلال دقيقة. أخطاء القراءة تُرمى (البوابة تعيد 503).
 */
function createAgentAuthorizer({
  getUser,
  readAgent,
  adminUid,
  cacheMs = 60000,
  // الرفض يُحفظ ثواني فقط: وكيل جديد سجّل للتو يُخدم فور كتابة حسابه.
  refusalCacheMs = 5000,
  now = Date.now,
}) {
  const cache = new Map();
  return async (uid) => {
    const t = now();
    const hit = cache.get(uid);
    if (hit && t - hit.at < (hit.ok ? cacheMs : refusalCacheMs)) return hit.ok;

    let authUser;
    try {
      authUser = await getUser(uid);
    } catch (error) {
      if (error?.code === 'auth/user-not-found') return false;
      throw error;
    }
    let agent = { profile: null, subscription: null };
    if (isAuthorizedAccount(authUser, uid) && uid !== adminUid) {
      agent = (await readAgent(uid)) || agent;
    }
    const ok = isEligibleAgent({
      authUser,
      uid,
      adminUid,
      profile: agent.profile,
      subscription: agent.subscription,
      now: t,
    });
    cache.set(uid, { ok, at: t });
    if (cache.size > 5000) {
      for (const [key, value] of cache) {
        if (t - value.at >= cacheMs) cache.delete(key);
      }
    }
    return ok;
  };
}

function loadConfig(env = process.env) {
  const wahaBaseUrl = String(env.WAHA_BASE_URL || '').replace(/\/+$/, '');
  let wahaUrl;
  try {
    wahaUrl = new URL(wahaBaseUrl);
  } catch (_) {
    throw new Error('WAHA_BASE_URL must be configured.');
  }
  const localWaha = ['localhost', '127.0.0.1', 'waha'].includes(wahaUrl.hostname);
  if (wahaUrl.protocol !== 'https:' && !(wahaUrl.protocol === 'http:' && localWaha)) {
    throw new Error('WAHA_BASE_URL must use HTTPS except on the private local Docker network.');
  }

  const wahaApiKey = String(env.WAHA_API_KEY || '').trim();
  if (wahaApiKey.length < 32) throw new Error('WAHA_API_KEY must be set as a server secret.');
  const allowedOrigins = String(env.CORS_ALLOWED_ORIGINS || '')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);
  for (const origin of allowedOrigins) {
    let parsedOrigin;
    try {
      parsedOrigin = new URL(origin);
    } catch (_) {
      throw new Error('CORS_ALLOWED_ORIGINS must contain exact HTTP(S) origins.');
    }
    if (
      origin === '*' ||
      !['http:', 'https:'].includes(parsedOrigin.protocol) ||
      parsedOrigin.origin !== origin
    ) {
      throw new Error('CORS_ALLOWED_ORIGINS must contain exact HTTP(S) origins, not wildcards or paths.');
    }
  }

  const idempotencyFile = path.resolve(
    env.WAHA_IDEMPOTENCY_FILE || path.join(__dirname, 'data', 'idempotency.json'),
  );
  // Product images live beside the idempotency store, inside the same durable
  // /app/data mount, so they survive a container replacement unchanged.
  const uploadsDir = path.resolve(
    env.UPLOADS_DIR || path.join(path.dirname(idempotencyFile), 'uploads'),
  );
  let publicBaseUrl = String(
    env.PUBLIC_BASE_URL || 'https://netagentiraq.duckdns.org',
  ).replace(/\/+$/, '');
  try {
    if (new URL(publicBaseUrl).protocol !== 'https:') throw new Error('not https');
  } catch (_) {
    throw new Error('PUBLIC_BASE_URL must be an https URL.');
  }
  const maxImageBytes = Math.min(
    Math.max(Number(env.MAX_IMAGE_BYTES || 4 * 1024 * 1024), 1024),
    20 * 1024 * 1024,
  );
  const imageRateLimit = {
    max: Math.max(Number(env.RATE_LIMIT_MAX || 30), 1),
    windowMs: Math.max(Number(env.RATE_LIMIT_WINDOW_MS || 600000), 1000),
  };
  const adminUid = String(
    env.NETAGENT_ADMIN_UID || 'wE10WciDVudIOJziBurjhBxpDfO2',
  ).trim();

  return {
    port: Number(env.PORT || 3001),
    wahaBaseUrl,
    wahaApiKey,
    timeoutMs: Math.min(Math.max(Number(env.WAHA_TIMEOUT_MS || 15000), 1000), 60000),
    idempotencyFile,
    uploadsDir,
    publicBaseUrl,
    maxImageBytes,
    imageRateLimit,
    adminUid,
    allowedOrigins: new Set(allowedOrigins),
    expiryScheduler: {
      enabled: String(env.EXPIRY_SCHEDULER_ENABLED || '').trim() === 'true',
      intervalMs: Math.max(Number(env.EXPIRY_SCHEDULER_INTERVAL_MS || 300000), 60000),
      // Subscriber dates without a zone are device-local; Iraq is UTC+3.
      utcOffsetMinutes: Number(env.NETAGENT_UTC_OFFSET_MINUTES || 180),
    },
    // «مشترك نت» (D7): مطفأة حتى تُفعَّل صراحة. الملح يحمي رموز الدعوات والهواتف المخزنة كبصمات.
    subscriberPortal: (() => {
      const enabled = String(env.SUBSCRIBER_PORTAL_ENABLED || '').trim() === 'true';
      const pepper = String(env.SUBSCRIBER_PORTAL_PEPPER || '').trim();
      if (enabled && pepper.length < 32) {
        throw new Error('SUBSCRIBER_PORTAL_PEPPER must be set (32+ characters) when the subscriber portal is enabled.');
      }
      return {
        enabled,
        pepper,
        // مشروع Firebase للمشتركين لا يحتاج مفتاحاً للتحقق من التوكن. فارغ = الدخول غير مفعّل بعد.
        firebaseProjectId: String(env.SUBSCRIBER_FIREBASE_PROJECT_ID || '').trim(),
        // مسار ملف مفتاح خدمة mushtarak-net (لا محتواه): استعادة كلمة المرور والإشعار الفوري.
        serviceAccountFile: String(env.SUBSCRIBER_SERVICE_ACCOUNT_FILE || '').trim(),
      };
    })(),
    // Orphan product/store image sweeper. Off until explicitly enabled; deletes
    // only unreferenced uploads older than the grace window (default one day).
    imageCleanup: {
      enabled: String(env.IMAGE_CLEANUP_ENABLED || '').trim() === 'true',
      intervalMs: Math.max(
        Number(env.IMAGE_CLEANUP_INTERVAL_MS || 24 * 60 * 60 * 1000),
        60 * 60 * 1000,
      ),
      graceMs: Math.max(
        Number(env.IMAGE_CLEANUP_GRACE_MS || 24 * 60 * 60 * 1000),
        60 * 60 * 1000,
      ),
    },
  };
}

// Entries only guard against a resent request; the Firebase notice records
// are the lasting duplicate guard for automatic notices (an unknown outcome
// is held there for review), so old entries can be dropped.
const IDEMPOTENCY_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const IDEMPOTENCY_PRUNE_INTERVAL_MS = 24 * 60 * 60 * 1000;

class JsonIdempotencyStore {
  constructor(filePath, { now = Date.now } = {}) {
    this.filePath = filePath;
    this.now = now;
    this.lastPrunedAt = -Infinity;
    this.queue = Promise.resolve();
    fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
    try {
      const contents = fs.readFileSync(filePath, 'utf8');
      this.entries = JSON.parse(contents);
      if (!this.entries || typeof this.entries !== 'object' || Array.isArray(this.entries)) {
        throw new Error('Invalid idempotency store.');
      }
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      this.entries = {};
    }
    if (this._prune()) this._persist();
  }

  // Drops entries older than the retention period, at most once a day.
  // Entries without a readable date are kept. Returns true if any were dropped.
  _prune() {
    const now = this.now();
    if (now - this.lastPrunedAt < IDEMPOTENCY_PRUNE_INTERVAL_MS) return false;
    this.lastPrunedAt = now;
    let removed = false;
    for (const [key, entry] of Object.entries(this.entries)) {
      const at = Date.parse(entry?.updatedAt || entry?.createdAt);
      if (now - at > IDEMPOTENCY_RETENTION_MS) {
        delete this.entries[key];
        removed = true;
      }
    }
    return removed;
  }

  _exclusive(action) {
    const pending = this.queue.then(action, action);
    this.queue = pending.catch(() => {});
    return pending;
  }

  _persist() {
    const temporaryPath = `${this.filePath}.${process.pid}.tmp`;
    fs.writeFileSync(temporaryPath, JSON.stringify(this.entries), { mode: 0o600 });
    fs.chmodSync(temporaryPath, 0o600);
    fs.renameSync(temporaryPath, this.filePath);
  }

  reserve({ uid, idempotencyKey, requestDigest }) {
    return this._exclusive(() => {
      if (this._prune()) this._persist();
      const storeKey = sha256(`${uid}\0${idempotencyKey}`);
      const existing = this.entries[storeKey];
      if (existing) {
        if (existing.requestDigest !== requestDigest) return { state: 'conflict' };
        if (existing.status === 'sent') return { state: 'sent', response: existing.response };
        // WAHA refused the earlier request, so nothing was sent and it may be retried.
        if (existing.status !== 'rejected') return { state: 'unknown' };
      }
      this.entries[storeKey] = {
        requestDigest,
        status: 'processing',
        createdAt: new Date().toISOString(),
      };
      this._persist();
      return { state: 'reserved', storeKey };
    });
  }

  complete(storeKey, status, response) {
    return this._exclusive(() => {
      const entry = this.entries[storeKey];
      if (!entry) throw new Error('Idempotency reservation was lost.');
      entry.status = status;
      entry.response = response;
      entry.updatedAt = new Date().toISOString();
      this._persist();
    });
  }
}

/**
 * Talks to WAHA for one UID-derived session. The HTTP routes and the expiry
 * scheduler share one instance so they also share one idempotency store.
 */
function createWahaSender({ config, fetchImpl = fetch, idempotencyStore }) {
  const store = idempotencyStore || new JsonIdempotencyStore(config.idempotencyFile);

  async function callWaha(method, route, body) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), config.timeoutMs);
    try {
      return await fetchImpl(`${config.wahaBaseUrl}${route}`, {
        method,
        headers: {
          'X-Api-Key': config.wahaApiKey,
          Accept: 'application/json',
          ...(body ? { 'Content-Type': 'application/json' } : {}),
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timeout);
    }
  }

  async function getSession(sessionName) {
    const session = encodeURIComponent(sessionName);
    const upstream = await callWaha('GET', `/api/sessions/${session}`);
    if (upstream.status === 404) return null;
    if (!upstream.ok) throw new Error('WAHA session status request failed.');
    return upstream.json();
  }

  /** Returns the HTTP status and body that `/api/waha/send` responds with. */
  async function sendText({ uid, session, to, text, eventType, idempotencyKey }) {
    const recipient = normalizePhone(to);
    const message = typeof text === 'string' ? text.trim() : '';
    const key = String(idempotencyKey || '').trim();

    if (!isAllowedEventType(eventType)) {
      return { status: 400, body: { success: false, error: 'unsupported_event_type' } };
    }
    if (recipient.length < 8 || recipient.length > 15 || !message || message.length > 4096) {
      return { status: 400, body: { success: false, error: 'invalid_message' } };
    }
    if (!/^[A-Za-z0-9:._-]{8,200}$/.test(key)) {
      return { status: 400, body: { success: false, error: 'invalid_idempotency_key' } };
    }

    let sessionData;
    try {
      sessionData = await getSession(session);
    } catch (_) {
      return { status: 502, body: { success: false, error: 'session_status_unavailable' } };
    }
    if (!sessionData || sessionData.status !== 'WORKING') {
      return { status: 409, body: { success: false, error: 'session_not_connected' } };
    }

    const requestDigest = sha256(JSON.stringify({
      uid,
      eventType,
      recipient,
      message,
    }));
    let reservation;
    try {
      reservation = await store.reserve({
        uid,
        idempotencyKey: key,
        requestDigest,
      });
    } catch (_) {
      return { status: 503, body: { success: false, error: 'idempotency_store_unavailable' } };
    }

    if (reservation.state === 'conflict') {
      return { status: 409, body: { success: false, error: 'idempotency_key_conflict' } };
    }
    if (reservation.state === 'unknown') {
      return { status: 409, body: { success: false, error: 'delivery_outcome_unknown' } };
    }
    if (reservation.state === 'sent') return { status: 200, body: reservation.response };

    try {
      const upstream = await callWaha('POST', '/api/sendText', {
        session,
        chatId: `${recipient}@c.us`,
        text: message,
      });
      let upstreamBody = {};
      try {
        upstreamBody = await upstream.json();
      } catch (_) {
        // Do not persist upstream response bodies that could contain private data.
      }
      if (upstream.ok) {
        const response = {
          success: true,
          messageId: String(upstreamBody.id || upstreamBody.key?.id || ''),
        };
        await store.complete(reservation.storeKey, 'sent', response);
        return { status: 200, body: response };
      }

      const knownRejection = upstream.status >= 400 && upstream.status < 500;
      const response = {
        success: false,
        error: knownRejection ? 'waha_rejected_request' : 'delivery_outcome_unknown',
      };
      await store.complete(
        reservation.storeKey,
        knownRejection ? 'rejected' : 'unknown',
        response,
      );
      return { status: knownRejection ? 502 : 504, body: response };
    } catch (_) {
      try {
        await store.complete(reservation.storeKey, 'unknown', {
          success: false,
          error: 'delivery_outcome_unknown',
        });
      } catch (_) {
        // The pre-send reservation remains durable and blocks an unsafe resend.
      }
      return { status: 504, body: { success: false, error: 'delivery_outcome_unknown' } };
    }
  }

  return { callWaha, getSession, sendText };
}

function createApp({
  config,
  verifyIdToken,
  authorizeAccount,
  fetchImpl = fetch,
  idempotencyStore,
  wahaSender,
  subscriberPortal,
  authenticateSubscriber,
}) {
  const app = express();
  const sender = wahaSender || createWahaSender({ config, fetchImpl, idempotencyStore });
  const sessionOperations = new Map();
  app.disable('x-powered-by');
  app.use((req, res, next) => {
    const origin = req.headers.origin;
    if (req.method === 'OPTIONS' && (!origin || !config.allowedOrigins.has(origin))) {
      return res.status(403).json({ success: false, error: 'origin_not_allowed' });
    }
    if (origin && !config.allowedOrigins.has(origin)) {
      return res.status(403).json({ success: false, error: 'origin_not_allowed' });
    }
    if (origin) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
      res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, Idempotency-Key');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    }
    if (req.method === 'OPTIONS') return res.sendStatus(204);
    next();
  });
  app.use(express.json({ limit: '12kb', strict: true }));

  app.get('/healthz', (_req, res) => res.json({ ok: true }));

  // --- Product image storage on the durable /app/data mount ---
  try {
    fs.mkdirSync(config.uploadsDir, { recursive: true });
  } catch (_) {
    // Only fails if the mount is missing; uploads then error per request.
  }

  // Public, read-only serving of stored images. express.static keeps every
  // served path inside uploadsDir, so traversal above the root is refused.
  app.use(
    '/uploads',
    express.static(config.uploadsDir, {
      index: false,
      dotfiles: 'deny',
      fallthrough: false,
      redirect: false,
      maxAge: '7d',
    }),
  );

  const acceptedImageTypes = Object.keys(IMAGE_TYPES);
  const imageRateLimiter = createRateLimiter(config.imageRateLimit);

  app.post(
    '/api/images',
    requireAgent,
    imageRateLimiter,
    express.raw({ type: acceptedImageTypes, limit: config.maxImageBytes }),
    async (req, res) => {
      const declared = String(req.headers['content-type'] || '')
        .split(';')[0]
        .trim()
        .toLowerCase();
      if (!acceptedImageTypes.includes(declared)) {
        return res.status(415).json({ success: false, error: 'unsupported_type' });
      }
      const bytes = req.body;
      if (!Buffer.isBuffer(bytes) || bytes.length === 0) {
        return res.status(400).json({ success: false, error: 'empty_body' });
      }
      const detected = detectImageType(bytes);
      if (!detected || detected !== declared) {
        return res.status(415).json({ success: false, error: 'content_mismatch' });
      }
      const ext = IMAGE_TYPES[detected].ext;
      // The owner is the verified token uid; any client-supplied uid is ignored.
      const name = `${crypto.randomBytes(16).toString('hex')}.${ext}`;
      const dir = path.join(config.uploadsDir, req.agentUid);
      try {
        await fs.promises.mkdir(dir, { recursive: true });
        await fs.promises.writeFile(path.join(dir, name), bytes, { mode: 0o644 });
      } catch (_) {
        return res.status(500).json({ success: false, error: 'store_failed' });
      }
      return res.status(200).json({
        success: true,
        url: `${config.publicBaseUrl}/uploads/${req.agentUid}/${name}`,
      });
    },
  );

  app.delete(
    '/api/images/:uid/:file',
    requireAgent,
    imageRateLimiter,
    async (req, res) => {
      const { uid, file } = req.params;
      if (
        !/^[A-Za-z0-9_-]{1,128}$/.test(uid) ||
        !/^[A-Za-z0-9._-]{1,120}$/.test(file) ||
        file.includes('..')
      ) {
        return res.status(400).json({ success: false, error: 'invalid_path' });
      }
      // Only the owner (by verified uid) or the admin may delete.
      if (uid !== req.agentUid && req.agentUid !== config.adminUid) {
        return res.status(403).json({ success: false, error: 'forbidden' });
      }
      const root = path.resolve(config.uploadsDir);
      const target = path.resolve(path.join(root, uid, file));
      if (target !== path.join(root, uid, file)) {
        return res.status(400).json({ success: false, error: 'invalid_path' });
      }
      try {
        await fs.promises.unlink(target);
      } catch (_) {
        // Best effort: a missing file still counts as deleted.
      }
      return res.status(200).json({ success: true });
    },
  );

  async function requireAgent(req, res, next) {
    const authorization = String(req.headers.authorization || '');
    const match = /^Bearer\s+(.+)$/i.exec(authorization);
    if (!match) return res.status(401).json({ success: false, error: 'unauthorized' });

    let identity;
    try {
      identity = await verifyIdToken(match[1]);
    } catch (error) {
      const reason = typeof error?.code === 'string' && error.code
        ? error.code
        : error instanceof Error
          ? error.constructor.name
          : typeof error;
      console.error('Firebase ID token verification failed:', reason);
      return res.status(401).json({ success: false, error: 'unauthorized' });
    }
    if (
      !identity ||
      typeof identity.uid !== 'string' ||
      !identity.uid ||
      identity.uid.includes('/')
    ) {
      return res.status(401).json({ success: false, error: 'unauthorized' });
    }

    let authorized;
    try {
      authorized = await authorizeAccount(identity.uid);
    } catch (_) {
      return res.status(503).json({ success: false, error: 'authorization_unavailable' });
    }
    if (!authorized) return res.status(403).json({ success: false, error: 'forbidden' });

    req.agentUid = identity.uid;
    req.wahaIdentity = {
      uid: identity.uid,
      session: sessionNameForUid(identity.uid),
    };
    next();
  }

  app.use('/api/waha', requireAgent);

  const callWaha = (_req, method, route, body) => sender.callWaha(method, route, body);
  const getWahaSession = (req) => sender.getSession(req.wahaIdentity.session);

  async function withSessionOperation(session, operation) {
    const previous = sessionOperations.get(session) || Promise.resolve();
    const current = previous.catch(() => {}).then(operation);
    sessionOperations.set(session, current);
    try {
      return await current;
    } finally {
      if (sessionOperations.get(session) === current) {
        sessionOperations.delete(session);
      }
    }
  }

  function sessionResponse(data) {
    const response = { success: true, status: data?.status || 'UNKNOWN' };
    const linkedId = data?.me?.id;
    if (typeof linkedId === 'string') {
      const phoneNumber = linkedId.split('@')[0].split(':')[0].replace(/\D/g, '');
      if (phoneNumber) response.phoneNumber = phoneNumber;
    }
    return response;
  }

  async function createWahaSession(req) {
    const session = req.wahaIdentity.session;
    const createResponse = await callWaha(req, 'POST', '/api/sessions', {
      name: session,
      config: {},
    });
    if (!createResponse.ok && createResponse.status !== 409) {
      throw new Error('WAHA session creation failed.');
    }
    return (await getWahaSession(req)) || { status: 'STARTING' };
  }

  async function startWahaSession(req) {
    return withSessionOperation(req.wahaIdentity.session, async () => {
      const current = await getWahaSession(req);
      if (!current) return createWahaSession(req);
      if (['STARTING', 'SCAN_QR_CODE', 'WORKING'].includes(current.status)) {
        return current;
      }
      const session = encodeURIComponent(req.wahaIdentity.session);
      const action = current.status === 'FAILED' ? 'restart' : 'start';
      const upstream = await callWaha(req, 'POST', `/api/sessions/${session}/${action}`);
      if (!upstream.ok) throw new Error('WAHA session start failed.');
      return (await getWahaSession(req)) || { status: 'STARTING' };
    });
  }

  app.post('/api/waha/session/start', async (req, res) => {
    try {
      return res.json(sessionResponse(await startWahaSession(req)));
    } catch (_) {
      return res.status(502).json({ success: false, error: 'session_start_failed' });
    }
  });

  app.post('/api/waha/session/reconnect', async (req, res) => {
    try {
      const data = await withSessionOperation(req.wahaIdentity.session, async () => {
        const current = await getWahaSession(req);
        if (!current) return createWahaSession(req);
        const session = encodeURIComponent(req.wahaIdentity.session);
        const upstream = await callWaha(req, 'POST', `/api/sessions/${session}/restart`);
        if (!upstream.ok) throw new Error('WAHA session restart failed.');
        return (await getWahaSession(req)) || { status: 'STARTING' };
      });
      return res.json(sessionResponse(data));
    } catch (_) {
      return res.status(502).json({ success: false, error: 'session_reconnect_failed' });
    }
  });

  app.get('/api/waha/session/status', async (req, res) => {
    try {
      const data = await getWahaSession(req);
      return res.json(data ? sessionResponse(data) : { success: true, status: 'NOT_CREATED' });
    } catch (_) {
      return res.status(502).json({ success: false, error: 'session_status_unavailable' });
    }
  });

  app.post('/api/waha/session/disconnect', async (req, res) => {
    try {
      const data = await withSessionOperation(req.wahaIdentity.session, async () => {
        const current = await getWahaSession(req);
        if (!current) return null;
        const session = encodeURIComponent(req.wahaIdentity.session);
        const upstream = await callWaha(req, 'POST', `/api/sessions/${session}/logout`);
        if (!upstream.ok) throw new Error('WAHA session logout failed.');
        return getWahaSession(req);
      });
      return res.json(data ? sessionResponse(data) : { success: true, status: 'NOT_CREATED' });
    } catch (_) {
      return res.status(502).json({ success: false, error: 'session_disconnect_failed' });
    }
  });

  app.get('/api/waha/session/qr', async (req, res) => {
    try {
      const current = await getWahaSession(req);
      if (!current) return res.status(409).json({ success: false, error: 'session_not_started' });
      if (current.status !== 'SCAN_QR_CODE') {
        return res.status(409).json({ success: false, error: 'qr_not_available' });
      }
      const session = encodeURIComponent(req.wahaIdentity.session);
      const qrResponse = await callWaha(
        req,
        'GET',
        `/api/${session}/auth/qr?format=image`,
      );
      if (!qrResponse.ok) return res.status(502).json({ success: false, error: 'qr_unavailable' });
      const qr = await qrResponse.json();
      if (typeof qr.data !== 'string' || typeof qr.mimetype !== 'string') {
        return res.status(502).json({ success: false, error: 'qr_unavailable' });
      }
      res.setHeader('Cache-Control', 'no-store');
      return res.json({ success: true, mimetype: qr.mimetype, data: qr.data });
    } catch (_) {
      return res.status(502).json({ success: false, error: 'qr_unavailable' });
    }
  });

  app.post('/api/waha/send', async (req, res) => {
    const { to, text, eventType } = req.body || {};
    const result = await sender.sendText({
      uid: req.wahaIdentity.uid,
      session: req.wahaIdentity.session,
      to,
      text,
      eventType,
      idempotencyKey: req.headers['idempotency-key'],
    });
    return res.status(result.status).json(result.body);
  });

  // «مشترك نت»: يُركَّب فقط عند تمرير الخدمة (SUBSCRIBER_PORTAL_ENABLED=true).
  if (subscriberPortal) {
    const { createSubscriberPortalRouter } = require('./subscriber_portal');
    app.use(
      '/api/v1',
      createSubscriberPortalRouter({
        portal: subscriberPortal,
        requireAgent,
        authenticateSubscriber,
        // التحقق من الدعوة بلا حساب: حد واحد مشترك يجعل تخمين الرموز غير عملي.
        publicRateLimit: createRateLimiter({ max: 30, windowMs: 10 * 60 * 1000, key: () => 'invitation-validate' }),
        accountRateLimit: createRateLimiter({ max: 120, windowMs: 60 * 1000 }),
      }),
    );
  }

  // Translate body-parser limit errors (e.g. an oversize image) to JSON.
  app.use((err, req, res, next) => {
    if (res.headersSent) return next(err);
    const status = err && (err.status || err.statusCode);
    if (status === 413 || (err && err.type === 'entity.too.large')) {
      return res.status(413).json({ success: false, error: 'image_too_large' });
    }
    // Let Express's default handler keep the original status (e.g. a static
    // 404/403) rather than masking every error as a 400.
    return next(err);
  });

  return app;
}

// مفتاح خدمة مشروع المشتركين (mushtarak-net) من ملف على قرص البيانات. يُرفض
// أي مفتاح لمشروع آخر حتى لا يوضع مفتاح الوكلاء هنا خطأً.
function readSubscriberServiceAccount(file, expectedProjectId) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    throw new Error('Subscriber service account file is missing or not valid JSON.');
  }
  if (parsed?.type !== 'service_account' || !parsed.private_key || !parsed.client_email) {
    throw new Error('Subscriber service account file is not a Firebase service account key.');
  }
  if (parsed.project_id !== expectedProjectId) {
    throw new Error(`Subscriber service account must belong to ${expectedProjectId}.`);
  }
  return parsed;
}

// استعادة كلمة المرور والإشعار الفوري لمشتركي مشترك نت (Admin SDK للمشروع المستقل).
function createSubscriberAccountAdmin({ auth, messaging }) {
  return {
    async setPassword(phone, password) {
      let user;
      try {
        user = await auth.getUserByEmail(`${phone}@phone.mushtarak.net`);
      } catch (error) {
        if (error?.code === 'auth/user-not-found') return false;
        throw error;
      }
      await auth.updateUser(user.uid, { password });
      return true;
    },
    async sendPush(tokens, { title, body, data = {} }) {
      if (tokens.length === 0) return { invalidTokens: [] };
      const result = await messaging.sendEachForMulticast({
        tokens,
        notification: { title, body },
        data: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v ?? '')])),
        android: { priority: 'high' },
      });
      const dead = new Set([
        'messaging/registration-token-not-registered',
        'messaging/invalid-registration-token',
        'messaging/invalid-argument',
      ]);
      return {
        invalidTokens: result.responses
          .map((r, i) => (!r.success && dead.has(r.error?.code) ? tokens[i] : null))
          .filter(Boolean),
      };
    },
  };
}

function start() {
  const config = loadConfig();
  const { initializeApp, applicationDefault, getApps } = require('firebase-admin/app');
  const { getAuth } = require('firebase-admin/auth');
  const firebaseApp = getApps()[0] || initializeApp({
    credential: applicationDefault(),
    projectId: process.env.FIREBASE_PROJECT_ID,
    databaseURL: process.env.FIREBASE_DATABASE_URL,
  });
  const auth = getAuth(firebaseApp);
  const verifyIdToken = (token) => auth.verifyIdToken(token);
  const { getDatabase } = require('firebase-admin/database');
  const database = getDatabase(firebaseApp);
  // R1: وكيل حقيقي فقط (دور agent، حالة active، اشتراك ساري) أو المدير.
  const authorizeAccount = createAgentAuthorizer({
    adminUid: config.adminUid,
    getUser: (uid) => auth.getUser(uid),
    readAgent: async (uid) => {
      const [profile, subscription] = await Promise.all([
        database.ref(`agents/${uid}/profile`).once('value'),
        database.ref(`agents/${uid}/subscription`).once('value'),
      ]);
      return { profile: profile.val(), subscription: subscription.val() };
    },
  });
  const wahaSender = createWahaSender({ config });
  let subscriberPortal;
  let authenticateSubscriber;
  if (config.subscriberPortal.enabled) {
    const { createSubscriberPortal } = require('./subscriber_portal');
    const { firebaseDb } = require('./portal_db');
    const portalConfig = config.subscriberPortal;
    let subscriberApp = null;
    let accountAdmin = null;
    if (portalConfig.firebaseProjectId) {
      const { cert } = require('firebase-admin/app');
      const key = portalConfig.serviceAccountFile
        ? readSubscriberServiceAccount(portalConfig.serviceAccountFile, portalConfig.firebaseProjectId)
        : null;
      subscriberApp = getApps().find((a) => a.name === 'subscribers') ||
        initializeApp(
          key
            ? { credential: cert(key), projectId: portalConfig.firebaseProjectId }
            : { projectId: portalConfig.firebaseProjectId },
          'subscribers',
        );
      if (key) {
        const { getMessaging } = require('firebase-admin/messaging');
        accountAdmin = createSubscriberAccountAdmin({
          auth: getAuth(subscriberApp),
          messaging: getMessaging(subscriberApp),
        });
      }
    }
    subscriberPortal = createSubscriberPortal({
      db: firebaseDb(database),
      pepper: portalConfig.pepper,
      // الوكيل المنتهي لا يستقبل طلبات تجديد ولا تذكيرات (نفس قاعدة R1).
      isAgentEligible: authorizeAccount,
      accountAdmin,
    });
    if (subscriberApp) {
      const subscriberAuth = getAuth(subscriberApp);
      authenticateSubscriber = async (req) => {
        const match = /^Bearer\s+(.+)$/i.exec(String(req.headers.authorization || ''));
        if (!match) return null;
        const decoded = await subscriberAuth.verifyIdToken(match[1]);
        const { accountPhoneFromToken } = require('./subscriber_portal');
        return { accountId: decoded.uid, phone: accountPhoneFromToken(decoded) };
      };
    }
    console.log(
      `Subscriber portal enabled (sign-in ${authenticateSubscriber ? 'configured' : 'not configured'}, ` +
        `service key ${accountAdmin ? 'loaded' : 'not set'})`,
    );
    // تذكير انتهاء اشتراك المشتركين المربوطين: كل ساعة، وأول مرة بعد دقيقة.
    const runNotices = () =>
      subscriberPortal
        .runExpiryNotices()
        .then((n) => n && console.log(`Subscriber expiry notices sent: ${n}`))
        .catch((e) => console.error('Subscriber expiry notices failed:', e?.message || e));
    setTimeout(runNotices, 60 * 1000).unref();
    setInterval(runNotices, 60 * 60 * 1000).unref();
  }
  const app = createApp({
    config,
    verifyIdToken,
    authorizeAccount,
    wahaSender,
    subscriberPortal,
    authenticateSubscriber,
  });
  // Docker publishes only a loopback-bound host port in the local pilot compose file.
  const server = app.listen(config.port, '0.0.0.0', () => {
    console.log(`WAHA gateway listening on container port ${config.port}`);
  });

  let stopScheduler = () => {};
  if (config.expiryScheduler.enabled) {
    const { ExpiryScheduler, FirebaseNoticeStore, startExpiryScheduler } = require('./expiry_scheduler');
    const listAgentUids = async () => {
      const uids = [];
      let pageToken;
      do {
        const page = await auth.listUsers(1000, pageToken);
        // الوكيل المنتهي لا تُرسل تذكيراته حتى يجدد (قرار المالك 2026-11-14).
        for (const user of page.users) {
          if (isAuthorizedAccount(user, user.uid) && (await authorizeAccount(user.uid))) {
            uids.push(user.uid);
          }
        }
        pageToken = page.pageToken;
      } while (pageToken);
      return uids;
    };
    const scheduler = new ExpiryScheduler({
      store: new FirebaseNoticeStore(database),
      sender: wahaSender,
      listAgentUids,
      sessionNameForUid,
      utcOffsetMinutes: config.expiryScheduler.utcOffsetMinutes,
    });
    stopScheduler = startExpiryScheduler(scheduler, {
      intervalMs: config.expiryScheduler.intervalMs,
    });
    console.log(`Expiry scheduler enabled every ${config.expiryScheduler.intervalMs / 1000}s`);
  }

  let stopImageCleanup = () => {};
  if (config.imageCleanup.enabled) {
    const { getDatabase } = require('firebase-admin/database');
    const db = getDatabase(firebaseApp);
    const { runImageCleanup, startImageCleanup } = require('./image_cleanup');
    stopImageCleanup = startImageCleanup({
      run: () =>
        runImageCleanup({
          db,
          uploadsDir: config.uploadsDir,
          publicBaseUrl: config.publicBaseUrl,
          graceMs: config.imageCleanup.graceMs,
          log: (line) => console.log(line),
        }),
      intervalMs: config.imageCleanup.intervalMs,
    });
    console.log(
      `Image cleanup enabled every ${config.imageCleanup.intervalMs / 1000}s ` +
        `(grace ${config.imageCleanup.graceMs / 1000}s)`,
    );
  }

  const shutdown = () => {
    stopImageCleanup();
    // Let a notice being sent finish and be saved, within Docker's 10 second
    // stop timeout, so it is not left for manual review.
    const timeout = new Promise((resolve) => setTimeout(resolve, 8000).unref());
    Promise.race([stopScheduler(), timeout]).finally(() => {
      server.close(() => process.exit(0));
    });
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

if (require.main === module) {
  try {
    start();
  } catch (error) {
    console.error(`WAHA gateway configuration error: ${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = {
  createApp,
  createWahaSender,
  createRateLimiter,
  detectImageType,
  isAuthorizedAccount,
  isEligibleAgent,
  subscriptionEndMs,
  createAgentAuthorizer,
  readSubscriberServiceAccount,
  createSubscriberAccountAdmin,
  isAllowedEventType,
  loadConfig,
  normalizePhone,
  JsonIdempotencyStore,
  sessionNameForUid,
};
