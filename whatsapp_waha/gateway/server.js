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
  };
}

class JsonIdempotencyStore {
  constructor(filePath) {
    this.filePath = filePath;
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
      const storeKey = sha256(`${uid}\0${idempotencyKey}`);
      const existing = this.entries[storeKey];
      if (existing) {
        if (existing.requestDigest !== requestDigest) return { state: 'conflict' };
        if (existing.status === 'sent') return { state: 'sent', response: existing.response };
        return { state: 'unknown' };
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

function createApp({
  config,
  verifyIdToken,
  authorizeAccount,
  fetchImpl = fetch,
  idempotencyStore,
}) {
  const app = express();
  const store = idempotencyStore || new JsonIdempotencyStore(config.idempotencyFile);
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

  async function callWaha(req, method, route, body) {
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

  async function getWahaSession(req) {
    const session = encodeURIComponent(req.wahaIdentity.session);
    const upstream = await callWaha(req, 'GET', `/api/sessions/${session}`);
    if (upstream.status === 404) return null;
    if (!upstream.ok) throw new Error('WAHA session status request failed.');
    return upstream.json();
  }

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
    const idempotencyKey = String(req.headers['idempotency-key'] || '').trim();
    const recipient = normalizePhone(to);
    const message = typeof text === 'string' ? text.trim() : '';

    if (!isAllowedEventType(eventType)) {
      return res.status(400).json({ success: false, error: 'unsupported_event_type' });
    }
    if (recipient.length < 8 || recipient.length > 15 || !message || message.length > 4096) {
      return res.status(400).json({ success: false, error: 'invalid_message' });
    }
    if (!/^[A-Za-z0-9:._-]{8,200}$/.test(idempotencyKey)) {
      return res.status(400).json({ success: false, error: 'invalid_idempotency_key' });
    }

    let sessionData;
    try {
      sessionData = await getWahaSession(req);
    } catch (_) {
      return res.status(502).json({ success: false, error: 'session_status_unavailable' });
    }
    if (!sessionData || sessionData.status !== 'WORKING') {
      return res.status(409).json({ success: false, error: 'session_not_connected' });
    }

    const requestDigest = sha256(JSON.stringify({
      uid: req.wahaIdentity.uid,
      eventType,
      recipient,
      message,
    }));
    let reservation;
    try {
      reservation = await store.reserve({
        uid: req.wahaIdentity.uid,
        idempotencyKey,
        requestDigest,
      });
    } catch (_) {
      return res.status(503).json({ success: false, error: 'idempotency_store_unavailable' });
    }

    if (reservation.state === 'conflict') {
      return res.status(409).json({ success: false, error: 'idempotency_key_conflict' });
    }
    if (reservation.state === 'unknown') {
      return res.status(409).json({ success: false, error: 'delivery_outcome_unknown' });
    }
    if (reservation.state === 'sent') return res.status(200).json(reservation.response);

    try {
      const upstream = await callWaha(req, 'POST', '/api/sendText', {
        session: req.wahaIdentity.session,
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
        return res.status(200).json(response);
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
      return res.status(knownRejection ? 502 : 504).json(response);
    } catch (_) {
      try {
        await store.complete(reservation.storeKey, 'unknown', {
          success: false,
          error: 'delivery_outcome_unknown',
        });
      } catch (_) {
        // The pre-send reservation remains durable and blocks an unsafe resend.
      }
      return res.status(504).json({ success: false, error: 'delivery_outcome_unknown' });
    }
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
  const app = createApp({ config, verifyIdToken, authorizeAccount });
  // Docker publishes only a loopback-bound host port in the local pilot compose file.
  const server = app.listen(config.port, '0.0.0.0', () => {
    console.log(`WAHA gateway listening on container port ${config.port}`);
  });
  const shutdown = () => server.close(() => process.exit(0));
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
  isAuthorizedAccount,
  isAllowedEventType,
  loadConfig,
  normalizePhone,
  JsonIdempotencyStore,
  sessionNameForUid,
};
