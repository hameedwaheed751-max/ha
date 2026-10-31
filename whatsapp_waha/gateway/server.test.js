'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  createApp,
  isAuthorizedAccount,
  isAllowedEventType,
  JsonIdempotencyStore,
  loadConfig,
  sessionNameForUid,
} = require('./server');
const TEST_ADMIN_UID = 'uid-admin';

async function withServer(app, action) {
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const address = server.address();
  try {
    await action(`http://127.0.0.1:${address.port}`);
  } finally {
    await new Promise((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
}

function createTempStore() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'netagent-waha-test-'));
  return {
    filePath: path.join(directory, 'idempotency.json'),
    cleanup: () => fs.rmSync(directory, { recursive: true, force: true }),
  };
}

function testConfig(filePath, extra = {}) {
  return loadConfig({
    PORT: '0',
    WAHA_BASE_URL: 'http://waha:3000',
    WAHA_API_KEY: 'test-only-server-key-not-for-production',
    WAHA_IDEMPOTENCY_FILE: filePath,
    CORS_ALLOWED_ORIGINS: 'http://localhost:60518',
    ...extra,
  });
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function createWahaStub() {
  const sessions = new Map();
  const calls = [];
  const fetchImpl = async (input, options = {}) => {
    const url = new URL(input);
    const method = options.method || 'GET';
    const body = options.body ? JSON.parse(options.body) : null;
    calls.push({ method, url, body });

    const sessionMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)$/);
    if (method === 'GET' && sessionMatch) {
      const session = decodeURIComponent(sessionMatch[1]);
      return sessions.has(session)
        ? jsonResponse(sessions.get(session))
        : jsonResponse({ error: 'not_found' }, 404);
    }

    if (method === 'POST' && url.pathname === '/api/sessions') {
      const { name } = body;
      if (sessions.has(name)) return jsonResponse({ error: 'already_exists' }, 409);
      sessions.set(name, { name, status: 'SCAN_QR_CODE' });
      return jsonResponse({ name, status: 'SCAN_QR_CODE' }, 201);
    }

    const sessionAction = url.pathname.match(
      /^\/api\/sessions\/([^/]+)\/(start|restart|logout)$/,
    );
    if (method === 'POST' && sessionAction) {
      const session = decodeURIComponent(sessionAction[1]);
      const action = sessionAction[2];
      if (!sessions.has(session)) return jsonResponse({ error: 'not_found' }, 404);
      const state = sessions.get(session);
      state.status = action === 'logout' ? 'STOPPED' : 'STARTING';
      return jsonResponse(state);
    }

    if (method === 'GET' && /^\/api\/[^/]+\/auth\/qr$/.test(url.pathname)) {
      return jsonResponse({ mimetype: 'image/png', data: 'cXItcGxhY2Vob2xkZXI=' });
    }

    if (method === 'POST' && url.pathname === '/api/sendText') {
      return jsonResponse({ id: 'waha-message-id' });
    }

    return jsonResponse({ error: 'not_found' }, 404);
  };
  return { calls, fetchImpl, sessions };
}

test('any enabled Firebase account is authorized regardless of role or subscription', () => {
  for (const uid of ['uid-admin', 'uid-agent', 'uid-standard']) {
    assert.equal(isAuthorizedAccount({ disabled: false }, uid), true);
  }
  assert.equal(isAuthorizedAccount({ disabled: false }, 'uid-free-agent', {
    profile: { role: 'agent', status: 'pending' },
    subscription: { plan: 'free', status: 'expired' },
  }), true);
});

test('disabled, missing, or invalid Firebase accounts are rejected', () => {
  assert.equal(isAuthorizedAccount({ disabled: true }, 'uid-disabled'), false);
  assert.equal(isAuthorizedAccount(null, 'uid-missing'), false);
  assert.equal(isAuthorizedAccount({ disabled: false }, ''), false);
  assert.equal(isAuthorizedAccount({ disabled: false }, 'invalid/uid'), false);
});

test('Gateway accepts all event types emitted by the WAHA dispatcher', () => {
  for (const eventType of [
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
  ]) {
    assert.equal(isAllowedEventType(eventType), true, eventType);
  }
  assert.equal(isAllowedEventType('manual_campaign'), false);
});

test('session names are opaque, deterministic, and distinct for every verified UID', () => {
  const first = sessionNameForUid('uid-agent-a');
  assert.equal(first, sessionNameForUid('uid-agent-a'));
  assert.notEqual(first, sessionNameForUid('uid-agent-b'));
  assert.match(first, /^netagent_[a-f0-9]{40}$/);
  assert.equal(first.includes('uid-agent-a'), false);
});

test('agent session creation ignores client UID, agentKey, and session values', async () => {
  const temp = createTempStore();
  const waha = createWahaStub();
  let authorizedUid;
  const app = createApp({
    config: testConfig(temp.filePath),
    verifyIdToken: async () => ({ uid: 'uid-agent-a' }),
    authorizeAccount: async (uid) => {
      authorizedUid = uid;
      return true;
    },
    fetchImpl: waha.fetchImpl,
  });

  try {
    await withServer(app, async (baseUrl) => {
      const response = await fetch(
        `${baseUrl}/api/waha/session/start?uid=uid-agent-b&session=central`,
        {
          method: 'POST',
          headers: {
            Authorization: 'Bearer valid-agent-token',
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            uid: 'uid-agent-b',
            agentKey: 'forged-agent-key',
            session: 'central',
          }),
        },
      );
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), {
        success: true,
        status: 'SCAN_QR_CODE',
      });
    });

    const name = sessionNameForUid('uid-agent-a');
    const creation = waha.calls.find((call) => call.url.pathname === '/api/sessions');
    assert.equal(authorizedUid, 'uid-agent-a');
    assert.deepEqual(creation.body, { name, config: {} });
    assert.equal(waha.sessions.has('central'), false);
  } finally {
    temp.cleanup();
  }
});

test('admin session creation is identity-scoped and does not require an agent profile', async () => {
  const temp = createTempStore();
  const waha = createWahaStub();
  const app = createApp({
    config: testConfig(temp.filePath),
    verifyIdToken: async () => ({ uid: TEST_ADMIN_UID }),
    authorizeAccount: async (uid) =>
      isAuthorizedAccount({ disabled: false }, uid),
    fetchImpl: waha.fetchImpl,
  });

  try {
    await withServer(app, async (baseUrl) => {
      const response = await fetch(`${baseUrl}/api/waha/session/start`, {
        method: 'POST',
        headers: { Authorization: 'Bearer valid-admin-token' },
      });
      assert.equal(response.status, 200);
    });
    assert.equal(waha.sessions.has(sessionNameForUid(TEST_ADMIN_UID)), true);
    assert.equal(waha.sessions.has(sessionNameForUid('uid-agent-a')), false);
  } finally {
    temp.cleanup();
  }
});

test('all session-management routes reject an ineligible agent before calling WAHA', async () => {
  const temp = createTempStore();
  const waha = createWahaStub();
  const app = createApp({
    config: testConfig(temp.filePath),
    verifyIdToken: async () => ({ uid: 'uid-ineligible' }),
    authorizeAccount: async () => false,
    fetchImpl: waha.fetchImpl,
  });
  const requests = [
    { path: '/api/waha/session/start', method: 'POST' },
    { path: '/api/waha/session/status', method: 'GET' },
    { path: '/api/waha/session/qr', method: 'GET' },
    { path: '/api/waha/session/reconnect', method: 'POST' },
    { path: '/api/waha/session/disconnect', method: 'POST' },
    {
      path: '/api/waha/send',
      method: 'POST',
      headers: { 'Idempotency-Key': 'activation:subscriber-a:event-1' },
      body: { to: '07900000000', text: 'test', eventType: 'subscription_activated' },
    },
  ];

  try {
    await withServer(app, async (baseUrl) => {
      for (const request of requests) {
        const response = await fetch(`${baseUrl}${request.path}`, {
          method: request.method,
          headers: {
            Authorization: 'Bearer ineligible-agent-token',
            ...(request.body ? { 'Content-Type': 'application/json' } : {}),
            ...request.headers,
          },
          ...(request.body ? { body: JSON.stringify(request.body) } : {}),
        });
        assert.equal(response.status, 403, request.path);
      }
    });
    assert.equal(waha.calls.length, 0);
  } finally {
    temp.cleanup();
  }
});

test('two users are isolated across status, QR, reconnect, disconnect, and send', async () => {
  const temp = createTempStore();
  const waha = createWahaStub();
  const app = createApp({
    config: testConfig(temp.filePath),
    verifyIdToken: async (token) => ({ uid: token }),
    authorizeAccount: async () => true,
    fetchImpl: waha.fetchImpl,
  });
  const userA = sessionNameForUid('uid-agent-a');
  const userB = sessionNameForUid('uid-agent-b');

  try {
    await withServer(app, async (baseUrl) => {
      for (const uid of ['uid-agent-a', 'uid-agent-b']) {
        const response = await fetch(`${baseUrl}/api/waha/session/start`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${uid}` },
        });
        assert.equal(response.status, 200);
      }

      waha.sessions.get(userA).status = 'SCAN_QR_CODE';
      waha.sessions.get(userA).me = { id: '964700000001@c.us' };
      waha.sessions.get(userB).status = 'WORKING';
      waha.sessions.get(userB).me = { id: '964700000002@c.us' };

      const status = await fetch(
        `${baseUrl}/api/waha/session/status?session=${userA}&uid=uid-agent-a`,
        { headers: { Authorization: 'Bearer uid-agent-b' } },
      );
      assert.deepEqual(await status.json(), {
        success: true,
        status: 'WORKING',
        phoneNumber: '964700000002',
      });

      const qr = await fetch(`${baseUrl}/api/waha/session/qr?session=${userA}`, {
        headers: { Authorization: 'Bearer uid-agent-b' },
      });
      assert.equal(qr.status, 409);
      assert.equal(
        waha.calls.some((call) => call.url.pathname === `/api/${userA}/auth/qr`),
        false,
      );

      const reconnect = await fetch(`${baseUrl}/api/waha/session/reconnect`, {
        method: 'POST',
        headers: { Authorization: 'Bearer uid-agent-b' },
        body: JSON.stringify({ session: userA, uid: 'uid-agent-a' }),
      });
      assert.equal(reconnect.status, 200);

      waha.sessions.get(userB).status = 'WORKING';
      const send = await fetch(`${baseUrl}/api/waha/send`, {
        method: 'POST',
        headers: {
          Authorization: 'Bearer uid-agent-b',
          'Content-Type': 'application/json',
          'Idempotency-Key': 'activation:subscriber-b:event-1',
        },
        body: JSON.stringify({
          to: '07900000000',
          text: 'Test message',
          eventType: 'subscription_activated',
          uid: 'uid-agent-a',
          agentKey: 'forged-agent-key',
          session: userA,
        }),
      });
      assert.equal(send.status, 200);
      const sendCall = waha.calls.find((call) => call.url.pathname === '/api/sendText');
      assert.equal(sendCall.body.session, userB);

      const disconnect = await fetch(`${baseUrl}/api/waha/session/disconnect`, {
        method: 'POST',
        headers: { Authorization: 'Bearer uid-agent-b' },
        body: JSON.stringify({ session: userA }),
      });
      assert.equal(disconnect.status, 200);
    });

    assert.equal(waha.sessions.get(userA).status, 'WORKING');
    assert.equal(waha.sessions.get(userB).status, 'STOPPED');
    const sessionRequestPaths = waha.calls
      .filter((call) => call.url.pathname.startsWith('/api/sessions/'))
      .map((call) => decodeURIComponent(call.url.pathname.split('/')[3]));
    assert.ok(sessionRequestPaths.every((session) => session === userA || session === userB));
    assert.equal(sessionRequestPaths.includes('central'), false);
  } finally {
    temp.cleanup();
  }
});

test('QR is returned only while the authenticated user session awaits scanning', async () => {
  const temp = createTempStore();
  const waha = createWahaStub();
  const session = sessionNameForUid('uid-agent-a');
  waha.sessions.set(session, { name: session, status: 'SCAN_QR_CODE' });
  const app = createApp({
    config: testConfig(temp.filePath),
    verifyIdToken: async () => ({ uid: 'uid-agent-a' }),
    authorizeAccount: async () => true,
    fetchImpl: waha.fetchImpl,
  });

  try {
    await withServer(app, async (baseUrl) => {
      const response = await fetch(`${baseUrl}/api/waha/session/qr`, {
        headers: { Authorization: 'Bearer valid-agent-token' },
      });
      assert.equal(response.status, 200);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.deepEqual(await response.json(), {
        success: true,
        mimetype: 'image/png',
        data: 'cXItcGxhY2Vob2xkZXI=',
      });
    });
    assert.ok(waha.calls.some(
      (call) => call.url.pathname === `/api/${session}/auth/qr`,
    ));
  } finally {
    temp.cleanup();
  }
});

test('missing and invalid Firebase authentication are rejected before authorization', async () => {
  const temp = createTempStore();
  let authorizeCalled = false;
  const app = createApp({
    config: testConfig(temp.filePath),
    verifyIdToken: async (token) => {
      if (token !== 'valid-token') throw new Error('invalid token');
      return { uid: 'uid-agent-a' };
    },
    authorizeAccount: async () => {
      authorizeCalled = true;
      return true;
    },
  });

  try {
    await withServer(app, async (baseUrl) => {
      const missing = await fetch(`${baseUrl}/api/waha/session/status`);
      assert.equal(missing.status, 401);
      const invalid = await fetch(`${baseUrl}/api/waha/session/status`, {
        headers: { Authorization: 'Bearer invalid-token' },
      });
      assert.equal(invalid.status, 401);
    });
    assert.equal(authorizeCalled, false);
  } finally {
    temp.cleanup();
  }
});

test('Firebase authorization lookup failures return 503', async () => {
  const temp = createTempStore();
  const app = createApp({
    config: testConfig(temp.filePath),
    verifyIdToken: async () => ({ uid: 'uid-agent-a' }),
    authorizeAccount: async () => {
      throw new Error('Firebase unavailable');
    },
  });
  try {
    await withServer(app, async (baseUrl) => {
      const response = await fetch(`${baseUrl}/api/waha/session/status`, {
        headers: { Authorization: 'Bearer valid-agent-token' },
      });
      assert.equal(response.status, 503);
    });
  } finally {
    temp.cleanup();
  }
});

test('CORS allows the configured app origin and rejects unconfigured origins', async () => {
  const temp = createTempStore();
  const app = createApp({
    config: testConfig(temp.filePath, {
      CORS_ALLOWED_ORIGINS:
        'http://localhost:60518,https://wakeel-unel.onrender.com',
    }),
    verifyIdToken: async () => ({ uid: 'uid-agent-a' }),
    authorizeAccount: async () => true,
  });
  try {
    await withServer(app, async (baseUrl) => {
      const allowed = await fetch(`${baseUrl}/api/waha/session/start`, {
        method: 'OPTIONS',
        headers: {
          Origin: 'http://localhost:60518',
          'Access-Control-Request-Method': 'POST',
          'Access-Control-Request-Headers': 'authorization,content-type',
        },
      });
      assert.equal(allowed.status, 204);
      assert.equal(
        allowed.headers.get('access-control-allow-origin'),
        'http://localhost:60518',
      );
      assert.match(allowed.headers.get('access-control-allow-headers'), /Authorization/i);

      const renderPreflight = await fetch(`${baseUrl}/api/waha/send`, {
        method: 'OPTIONS',
        headers: {
          Origin: 'https://wakeel-unel.onrender.com',
          'Access-Control-Request-Method': 'POST',
          'Access-Control-Request-Headers':
            'authorization,content-type,idempotency-key',
        },
      });
      assert.equal(renderPreflight.status, 204);
      assert.equal(
        renderPreflight.headers.get('access-control-allow-origin'),
        'https://wakeel-unel.onrender.com',
      );
      assert.match(renderPreflight.headers.get('access-control-allow-methods'), /POST/i);
      for (const header of ['Authorization', 'Content-Type', 'Idempotency-Key']) {
        assert.match(
          renderPreflight.headers.get('access-control-allow-headers'),
          new RegExp(header, 'i'),
        );
      }

      const denied = await fetch(`${baseUrl}/api/waha/session/start`, {
        method: 'OPTIONS',
        headers: {
          Origin: 'https://untrusted.example',
          'Access-Control-Request-Method': 'POST',
        },
      });
      assert.equal(denied.status, 403);
      assert.equal(denied.headers.get('access-control-allow-origin'), null);
    });
  } finally {
    temp.cleanup();
  }
});

test('CORS configuration rejects wildcard origins', () => {
  assert.throws(
    () => testConfig('unused', { CORS_ALLOWED_ORIGINS: '*' }),
    /exact HTTP\(S\) origins/,
  );
});

test('same idempotency key returns stored success without a second WAHA send', async () => {
  const temp = createTempStore();
  const waha = createWahaStub();
  const session = sessionNameForUid('uid-agent-a');
  waha.sessions.set(session, { name: session, status: 'WORKING' });
  let sendCount = 0;
  const fetchImpl = async (input, options = {}) => {
    if (new URL(input).pathname === '/api/sendText') {
      sendCount += 1;
      return jsonResponse({ id: `message-${sendCount}` });
    }
    return waha.fetchImpl(input, options);
  };
  const app = createApp({
    config: testConfig(temp.filePath),
    verifyIdToken: async () => ({ uid: 'uid-agent-a' }),
    authorizeAccount: async () => true,
    fetchImpl,
  });
  const request = {
    method: 'POST',
    headers: {
      Authorization: 'Bearer valid-agent-token',
      'Content-Type': 'application/json',
      'Idempotency-Key': 'debt:subscriber-a:event-1',
    },
    body: JSON.stringify({
      to: '07900000000',
      text: 'Debt reminder',
      eventType: 'debt_reminder',
    }),
  };

  try {
    await withServer(app, async (baseUrl) => {
      const first = await fetch(`${baseUrl}/api/waha/send`, request);
      const second = await fetch(`${baseUrl}/api/waha/send`, request);
      assert.equal(first.status, 200);
      assert.equal(second.status, 200);
      assert.deepEqual(await second.json(), { success: true, messageId: 'message-1' });
    });
    assert.equal(sendCount, 1);
  } finally {
    temp.cleanup();
  }
});

test('unresolved idempotent sends are never automatically retried', async () => {
  const temp = createTempStore();
  const store = new JsonIdempotencyStore(temp.filePath);
  const first = await store.reserve({
    uid: 'uid-agent-a',
    idempotencyKey: 'expiry:subscriber-a:event-1',
    requestDigest: 'digest-a',
  });
  assert.equal(first.state, 'reserved');
  await store.complete(first.storeKey, 'unknown', { success: false });
  const second = await store.reserve({
    uid: 'uid-agent-a',
    idempotencyKey: 'expiry:subscriber-a:event-1',
    requestDigest: 'digest-a',
  });
  assert.equal(second.state, 'unknown');
  temp.cleanup();
});
