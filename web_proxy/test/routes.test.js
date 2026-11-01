const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');
const test = require('node:test');

const TOKEN = crypto.randomBytes(16).toString('hex');
const WRONG = crypto.randomBytes(16).toString('hex');
const APP_SECRET = crypto.randomBytes(16).toString('hex');
const PROXY_PORT = 4651;
const SAS_PORT = 4652;
const FULL_PHONE = '9647701234567';
const SAS_TARGET = `http://127.0.0.1:${SAS_PORT}`;

const base = `http://127.0.0.1:${PROXY_PORT}`;
const sasCalls = [];
let dropNextPost = false;
let proxy;
let proxyLogs = '';

const sas = http.createServer((req, res) => {
  sasCalls.push({ method: req.method, url: req.url, headers: { ...req.headers } });
  if (req.method === 'POST' && dropNextPost) {
    req.socket.destroy();
    return;
  }
  res.setHeader('content-type', 'application/json');
  res.end('{"status":200,"token":"sas-session"}');
});

async function waitForProxy() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      await fetch(`${base}/health`);
      return;
    } catch (_) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error('Proxy did not start');
}

test.before(async () => {
  await new Promise((resolve) => sas.listen(SAS_PORT, '127.0.0.1', resolve));
  proxy = spawn(
    process.execPath,
    ['--require', path.join(__dirname, 'fake-meta.js'), 'server.js'],
    {
      cwd: path.join(__dirname, '..'),
      env: {
        ...process.env,
        PORT: String(PROXY_PORT),
        NODE_ENV: 'production',
        SAS_PROXY_TOKEN: TOKEN,
        WHATSAPP_APP_SECRET: APP_SECRET,
        WHATSAPP_VERIFY_TOKEN: 'verify-value',
        WHATSAPP_ACCESS_TOKEN: 'test-access-token',
        WHATSAPP_PHONE_NUMBER_ID: '123456',
        WHATSAPP_BUSINESS_ACCOUNT_ID: '654321',
        ALLOW_INSECURE_TLS: '1',
        ALLOW_HTTP_TARGETS: '1',
        ALLOW_PRIVATE_TARGETS: '1',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  proxy.stdout.on('data', (chunk) => { proxyLogs += chunk; });
  proxy.stderr.on('data', (chunk) => { proxyLogs += chunk; });
  await waitForProxy();
});

test.after(async () => {
  proxy.kill();
  await new Promise((resolve) => sas.close(resolve));
});

const withToken = (headers = {}) => ({ 'x-proxy-token': TOKEN, ...headers });
const json = (headers = {}) => ({ 'content-type': 'application/json', ...headers });

const text = {
  to: FULL_PHONE,
  message: 'رسالة اختبار',
  clientBuild: 'whatsapp-template-v3',
};
const template = {
  to: FULL_PHONE,
  templateName: 'debt_paid',
  language: 'ar',
  clientBuild: 'whatsapp-template-v3',
  parameters: [{ parameterName: 'customer_name', text: 'علي' }],
};
const post = (body, headers) => ({
  method: 'POST',
  headers: json(headers),
  body: JSON.stringify(body),
});

const protectedRoutes = [
  ['POST', '/send-message', post(text)],
  ['POST', '/whatsapp/send', post(text)],
  ['GET', '/whatsapp/message-status?id=x', {}],
  ['GET', '/whatsapp/template-contract?name=debt_paid', {}],
  ['GET', `/ping-target?target=${SAS_TARGET}`, {}],
  ['GET', `/sas/admin/api/index.php/api/index/online?target=${SAS_TARGET}`, {}],
  ['GET', `/admin/api/index.php/api/index/online?target=${SAS_TARGET}`, {}],
];

for (const [method, route, options] of protectedRoutes) {
  test(`${method} ${route.split('?')[0]} rejects a missing or wrong token`, async () => {
    const before = sasCalls.length;
    const missing = await fetch(`${base}${route}`, { method, ...options });
    assert.equal(missing.status, 401);
    const wrong = await fetch(`${base}${route}`, {
      method,
      ...options,
      headers: { ...(options.headers || {}), 'x-proxy-token': WRONG },
    });
    assert.equal(wrong.status, 401);
    assert.equal(sasCalls.length, before);
  });
}

test('health stays public and shows the current TLS setting', async () => {
  const health = await (await fetch(`${base}/health`)).json();
  assert.equal(health.ok, true);
  assert.equal(health.hasTokenAuth, true);
  assert.equal(health.proxyAuthBypassed, false);
  assert.equal(health.allowInsecureTls, true);
  assert.equal(JSON.stringify(health).includes(TOKEN), false);
});

for (const route of ['/login', '/sas/login']) {
  test(`SAS sign-in through ${route} keeps working without a token`, async () => {
    const before = sasCalls.length;
    const response = await fetch(`${base}${route}`, {
      method: 'POST',
      headers: json({ 'x-sas-target': SAS_TARGET }),
      body: '{"payload":"encrypted"}',
    });
    assert.equal(response.status, 200);
    assert.equal(sasCalls.length, before + 1);
    assert.equal(sasCalls.at(-1).url, '/admin/api/index.php/api/login');
  });
}

test('SAS requests work with the token and do not expose it to SAS', async () => {
  const before = sasCalls.length;
  const response = await fetch(`${base}/sas/admin/api/index.php/api/index/online`, {
    headers: withToken({
      'x-sas-target': SAS_TARGET,
      authorization: 'Bearer sas-session',
    }),
  });
  assert.equal(response.status, 200);
  assert.equal(sasCalls.length, before + 1);
  const seen = sasCalls.at(-1).headers;
  assert.equal(seen.authorization, 'Bearer sas-session');
  assert.equal(JSON.stringify(seen).includes(TOKEN), false);
});

test('a host name target still connects when private targets are allowed', async () => {
  const before = sasCalls.length;
  const response = await fetch(`${base}/sas/admin/api/index.php/api/index/online`, {
    headers: withToken({ 'x-sas-target': `http://localhost.:${SAS_PORT}` }),
  });
  assert.equal(response.status, 200);
  assert.equal(sasCalls.length, before + 1);
});

test('a dropped POST is not repeated, so activation cannot run twice', async () => {
  const before = sasCalls.length;
  dropNextPost = true;
  const response = await fetch(`${base}/sas/admin/api/index.php/api/user/activate`, {
    method: 'POST',
    headers: json(withToken({ 'x-sas-target': SAS_TARGET })),
    body: '{"payload":"encrypted"}',
  });
  dropNextPost = false;
  assert.equal(response.status, 502);
  assert.equal(sasCalls.length, before + 1);
});

test('Meta text and template sending work with the token', async () => {
  const sent = await fetch(`${base}/send-message`, post(text, withToken()));
  assert.equal(sent.status, 200);
  assert.equal((await sent.json()).messageId, 'wamid.test-message');

  const templated = await fetch(`${base}/send-message`, post(template, withToken()));
  assert.equal(templated.status, 200);

  const direct = await fetch(`${base}/whatsapp/send`, post(text, withToken()));
  assert.equal(direct.status, 200);

  const contract = await fetch(`${base}/whatsapp/template-contract?name=debt_paid`, {
    headers: withToken(),
  });
  assert.equal(contract.status, 200);
  assert.deepEqual((await contract.json()).parameterNames, ['customer_name']);
});

test('WhatsApp sending works with each token header the client uses', async () => {
  for (const headers of [
    { 'x-api-key': TOKEN },
    { 'x-sas-proxy-token': TOKEN },
    { 'x-proxy-token': WRONG, 'x-api-key': TOKEN },
  ]) {
    const response = await fetch(`${base}/send-message`, post(text, headers));
    assert.equal(response.status, 200);
  }
});

test('webhook verification and signed delivery updates work', async () => {
  const challenge = await fetch(
    `${base}/webhook?hub.mode=subscribe&hub.verify_token=verify-value&hub.challenge=abc`,
  );
  assert.equal(challenge.status, 200);
  assert.equal(await challenge.text(), 'abc');

  const badChallenge = await fetch(
    `${base}/webhook?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=abc`,
  );
  assert.equal(badChallenge.status, 403);

  const body = JSON.stringify({
    entry: [{
      changes: [{
        value: {
          statuses: [{ id: 'wamid.test-message', status: 'delivered', recipient_id: 'x' }],
        },
      }],
    }],
  });
  const forged = await fetch(`${base}/webhook`, {
    method: 'POST',
    body,
    headers: { 'x-hub-signature-256': 'sha256=forged' },
  });
  assert.equal(forged.status, 401);

  const signature = crypto.createHmac('sha256', APP_SECRET).update(body).digest('hex');
  const signed = await fetch(`${base}/webhook`, {
    method: 'POST',
    body,
    headers: { 'x-hub-signature-256': `sha256=${signature}` },
  });
  assert.equal(signed.status, 200);

  await new Promise((resolve) => setTimeout(resolve, 100));
  const status = await fetch(`${base}/whatsapp/message-status?id=wamid.test-message`, {
    headers: withToken(),
  });
  assert.equal((await status.json()).delivery.status, 'delivered');
});

test('logs hide full phone numbers and message text', () => {
  assert.equal(proxyLogs.includes('[whatsapp] outbound'), true);
  assert.equal(proxyLogs.includes(FULL_PHONE), false);
  assert.equal(proxyLogs.includes('رسالة اختبار'), false);
  assert.equal(proxyLogs.includes(TOKEN), false);
});
