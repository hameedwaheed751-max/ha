const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');
const test = require('node:test');

const TOKEN = 'test-only-proxy-token';
const APP_SECRET = 'test-only-app-secret';

function startProxy(port, env) {
  return spawn(process.execPath, ['server.js'], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, PORT: String(port), NODE_ENV: 'production', ...env },
    stdio: 'ignore',
  });
}

async function waitForProxy(port) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      await fetch(`http://127.0.0.1:${port}/health`);
      return;
    } catch (_) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error('Proxy did not start');
}

const send = (port, pathname, options) =>
  fetch(`http://127.0.0.1:${port}${pathname}`, options);

const signature = (body) =>
  `sha256=${crypto.createHmac('sha256', APP_SECRET).update(body).digest('hex')}`;

test('proxy security', async (t) => {
  const port = 4631;
  const internal = http.createServer((_, res) => res.end('internal'));
  await new Promise((resolve) => internal.listen(4632, '127.0.0.1', resolve));
  const proxy = startProxy(port, {
    PROXY_TOKEN: TOKEN,
    WHATSAPP_APP_SECRET: APP_SECRET,
    ALLOW_HTTP_TARGETS: '1',
  });
  t.after(() => {
    proxy.kill();
    internal.close();
  });
  await waitForProxy(port);

  const message = {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ to: '9647000000000', message: 'x', clientBuild: 'v3' }),
  };

  await t.test('sending needs the proxy token', async () => {
    assert.equal((await send(port, '/send-message', message)).status, 401);
    const allowed = await send(port, '/send-message', {
      ...message,
      headers: { ...message.headers, 'x-proxy-token': TOKEN },
    });
    assert.notEqual(allowed.status, 401);
  });

  await t.test('ping needs the token and rejects private targets', async () => {
    const target = '/ping-target?target=http://127.0.0.1:4632';
    assert.equal((await send(port, target)).status, 401);
    const withToken = await send(port, target, {
      headers: { 'x-proxy-token': TOKEN },
    });
    assert.equal(withToken.status, 403);
  });

  await t.test('login rejects private addresses in every form', async () => {
    for (const target of [
      'http://127.0.0.1:4632',
      'http://[::1]:4632',
      'http://[::ffff:127.0.0.1]:4632',
    ]) {
      const response = await send(port, '/login', {
        method: 'POST',
        headers: { 'x-sas-target': target },
      });
      assert.equal(response.status, 403, target);
    }
  });

  await t.test('a host name cannot resolve to a private address', async () => {
    const response = await send(port, '/login', {
      method: 'POST',
      headers: { 'x-sas-target': 'http://localhost.:4632' },
    });
    const body = await response.json();
    assert.equal(response.status, 502);
    assert.equal(body.message, 'Private address blocked');
  });

  await t.test('the webhook accepts only signed events', async () => {
    const body = JSON.stringify({ entry: [{ id: 'attacker-account' }] });
    assert.equal(
      (await send(port, '/webhook', { method: 'POST', body })).status,
      401,
    );
    const signed = await send(port, '/webhook', {
      method: 'POST',
      body,
      headers: { 'x-hub-signature-256': signature(body) },
    });
    assert.equal(signed.status, 200);
  });
});

test('old and new tokens both work during rotation', async (t) => {
  const port = 4634;
  const current = crypto.randomBytes(16).toString('hex');
  const previous = crypto.randomBytes(16).toString('hex');
  const proxy = startProxy(port, {
    SAS_PROXY_TOKEN: current,
    SAS_PROXY_TOKENS: `${current},${previous}`,
  });
  t.after(() => proxy.kill());
  await waitForProxy(port);

  const statusWith = async (token) =>
    (await send(port, '/whatsapp/message-status?id=x', {
      headers: { 'x-api-key': token },
    })).status;

  assert.equal(await statusWith(current), 200);
  assert.equal(await statusWith(previous), 200);
  assert.equal(await statusWith('not-a-valid-token'), 401);
});

test('production rejects requests when no token is configured', async (t) => {
  const port = 4633;
  const proxy = startProxy(port, { PROXY_TOKEN: '', SAS_PROXY_TOKEN: '', SAS_PROXY_TOKENS: '' });
  t.after(() => proxy.kill());
  await waitForProxy(port);

  const response = await send(port, '/send-message', {
    method: 'POST',
    body: JSON.stringify({ to: '9647000000000', message: 'x', clientBuild: 'v3' }),
  });
  assert.equal(response.status, 401);

  const webhook = await send(port, '/webhook', { method: 'POST', body: '{}' });
  assert.equal(webhook.status, 503);
});
