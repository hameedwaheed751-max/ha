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

  return {
    port: Number(env.PORT || 3001),
    wahaBaseUrl,
    wahaApiKey,
    timeoutMs: Math.min(Math.max(Number(env.WAHA_TIMEOUT_MS || 15000), 1000), 60000),
    idempotencyFile: path.resolve(
      env.WAHA_IDEMPOTENCY_FILE || path.join(__dirname, 'data', 'idempotency.json'),
    ),
    allowedOrigins: new Set(allowedOrigins),
    expiryScheduler: {
      enabled: String(env.EXPIRY_SCHEDULER_ENABLED || '').trim() === 'true',
      intervalMs: Math.max(Number(env.EXPIRY_SCHEDULER_INTERVAL_MS || 300000), 60000),
      // Subscriber dates without a zone are device-local; Iraq is UTC+3.
      utcOffsetMinutes: Number(env.NETAGENT_UTC_OFFSET_MINUTES || 180),
    },
  };
}

// Resolved entries only guard against a resent request; the Firebase notice
// records are the lasting duplicate guard, so old resolved entries can be
// dropped. Entries whose outcome is unresolved are kept forever.
const IDEMPOTENCY_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const IDEMPOTENCY_RESOLVED_STATUSES = new Set(['sent', 'rejected']);
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

  // Drops resolved entries older than the retention period, at most once a
  // day. Unresolved or undated entries are kept. Returns true if any were dropped.
  _prune() {
    const now = this.now();
    if (now - this.lastPrunedAt < IDEMPOTENCY_PRUNE_INTERVAL_MS) return false;
    this.lastPrunedAt = now;
    let removed = false;
    for (const [key, entry] of Object.entries(this.entries)) {
      if (!IDEMPOTENCY_RESOLVED_STATUSES.has(entry?.status)) continue;
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
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    }
    if (req.method === 'OPTIONS') return res.sendStatus(204);
    next();
  });
  app.use(express.json({ limit: '12kb', strict: true }));

  app.get('/healthz', (_req, res) => res.json({ ok: true }));

  app.use('/api/waha', async (req, res, next) => {
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

    req.wahaIdentity = {
      uid: identity.uid,
      session: sessionNameForUid(identity.uid),
    };
    next();
  });

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

  return app;
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
  const authorizeAccount = async (uid) => {
    let authUser;
    try {
      authUser = await auth.getUser(uid);
    } catch (error) {
      if (error.code === 'auth/user-not-found') return false;
      throw error;
    }
    return isAuthorizedAccount(authUser, uid);
  };
  const wahaSender = createWahaSender({ config });
  const app = createApp({ config, verifyIdToken, authorizeAccount, wahaSender });
  // Docker publishes only a loopback-bound host port in the local pilot compose file.
  const server = app.listen(config.port, '0.0.0.0', () => {
    console.log(`WAHA gateway listening on container port ${config.port}`);
  });

  let stopScheduler = () => {};
  if (config.expiryScheduler.enabled) {
    const { getDatabase } = require('firebase-admin/database');
    const { ExpiryScheduler, FirebaseNoticeStore, startExpiryScheduler } = require('./expiry_scheduler');
    const listAgentUids = async () => {
      const uids = [];
      let pageToken;
      do {
        const page = await auth.listUsers(1000, pageToken);
        for (const user of page.users) {
          if (isAuthorizedAccount(user, user.uid)) uids.push(user.uid);
        }
        pageToken = page.pageToken;
      } while (pageToken);
      return uids;
    };
    const scheduler = new ExpiryScheduler({
      store: new FirebaseNoticeStore(getDatabase(firebaseApp)),
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
  const shutdown = () => {
    stopScheduler();
    server.close(() => process.exit(0));
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
  isAuthorizedAccount,
  isAllowedEventType,
  loadConfig,
  normalizePhone,
  JsonIdempotencyStore,
  sessionNameForUid,
};
