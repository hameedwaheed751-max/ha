'use strict';

// Tests for the VPS product-image endpoints: POST /api/images (upload),
// DELETE /api/images/:uid/:file, and the public GET /uploads static serve.
// Auth/authorization is injected exactly like the WAHA route tests.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { createApp, loadConfig, detectImageType } = require('./server');

const ADMIN_UID = 'wE10WciDVudIOJziBurjhBxpDfO2';

// Minimal but valid magic-byte headers.
const JPEG = Buffer.concat([
  Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]),
  Buffer.from('JFIF\0', 'ascii'),
  Buffer.alloc(16, 0x20),
]);
const PNG = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  Buffer.alloc(16, 0x00),
]);
const WEBP = Buffer.concat([
  Buffer.from('RIFF', 'ascii'),
  Buffer.from([0x1a, 0x00, 0x00, 0x00]),
  Buffer.from('WEBP', 'ascii'),
  Buffer.alloc(10, 0x00),
]);

async function withServer(app, action) {
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const { port } = server.address();
  try {
    await action(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
}

function tempDirs() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'netagent-img-test-'));
  return {
    idempotency: path.join(root, 'idempotency.json'),
    uploads: path.join(root, 'uploads'),
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }),
  };
}

function imageConfig(dirs, extra = {}) {
  return loadConfig({
    PORT: '0',
    WAHA_BASE_URL: 'http://waha:3000',
    WAHA_API_KEY: 'test-only-server-key-not-for-production',
    WAHA_IDEMPOTENCY_FILE: dirs.idempotency,
    UPLOADS_DIR: dirs.uploads,
    CORS_ALLOWED_ORIGINS: 'http://localhost:60518',
    ...extra,
  });
}

// Builds an app whose token always resolves to `uid`, every account authorized.
function appForUid(dirs, uid, extra = {}) {
  return createApp({
    config: imageConfig(dirs, extra),
    verifyIdToken: async () => ({ uid }),
    authorizeAccount: async () => true,
    fetchImpl: async () => new Response('{}', { status: 200 }),
  });
}

async function upload(baseUrl, bytes, contentType, token = 'valid') {
  return fetch(`${baseUrl}/api/images`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': contentType },
    body: bytes,
  });
}

test('detectImageType sniffs jpeg/png/webp and rejects others', () => {
  assert.equal(detectImageType(JPEG), 'image/jpeg');
  assert.equal(detectImageType(PNG), 'image/png');
  assert.equal(detectImageType(WEBP), 'image/webp');
  assert.equal(detectImageType(Buffer.from('not an image')), null);
  assert.equal(detectImageType(Buffer.alloc(0)), null);
});

test('POST /api/images stores a valid jpeg and returns its public url', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const res = await upload(baseUrl, JPEG, 'image/jpeg');
      assert.equal(res.status, 200);
      const body = await res.json();
      assert.equal(body.success, true);
      assert.match(
        body.url,
        /^https:\/\/netagentiraq\.duckdns\.org\/uploads\/uid-agent-a\/[a-f0-9]{32}\.jpg$/,
      );
      const file = body.url.split('/uploads/')[1];
      const onDisk = path.join(dirs.uploads, file);
      assert.ok(fs.existsSync(onDisk));
      assert.deepEqual(fs.readFileSync(onDisk), JPEG);
    });
  } finally {
    dirs.cleanup();
  }
});

test('POST rejects a content-type that does not match the bytes (415)', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      // PNG bytes declared as jpeg.
      const res = await upload(baseUrl, PNG, 'image/jpeg');
      assert.equal(res.status, 415);
      assert.equal(fs.existsSync(path.join(dirs.uploads, 'uid-agent-a')), false);
    });
  } finally {
    dirs.cleanup();
  }
});

test('POST rejects an unsupported content-type (415)', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const res = await upload(baseUrl, JPEG, 'application/pdf');
      assert.equal(res.status, 415);
    });
  } finally {
    dirs.cleanup();
  }
});

test('POST rejects an oversize image (413)', async () => {
  const dirs = tempDirs();
  try {
    const app = appForUid(dirs, 'uid-agent-a', { MAX_IMAGE_BYTES: '1024' });
    await withServer(app, async (baseUrl) => {
      const big = Buffer.concat([JPEG, Buffer.alloc(2048, 0x20)]);
      const res = await upload(baseUrl, big, 'image/jpeg');
      assert.equal(res.status, 413);
    });
  } finally {
    dirs.cleanup();
  }
});

test('POST rejects an empty body (400)', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const res = await upload(baseUrl, Buffer.alloc(0), 'image/jpeg');
      assert.equal(res.status, 400);
    });
  } finally {
    dirs.cleanup();
  }
});

test('POST without a bearer token is unauthorized (401)', async () => {
  const dirs = tempDirs();
  try {
    const app = createApp({
      config: imageConfig(dirs),
      verifyIdToken: async () => {
        throw new Error('should not be called');
      },
      authorizeAccount: async () => true,
      fetchImpl: async () => new Response('{}'),
    });
    await withServer(app, async (baseUrl) => {
      const res = await fetch(`${baseUrl}/api/images`, {
        method: 'POST',
        headers: { 'Content-Type': 'image/jpeg' },
        body: JPEG,
      });
      assert.equal(res.status, 401);
    });
  } finally {
    dirs.cleanup();
  }
});

test('POST by a non-agent account is forbidden (403)', async () => {
  const dirs = tempDirs();
  try {
    const app = createApp({
      config: imageConfig(dirs),
      verifyIdToken: async () => ({ uid: 'uid-stranger' }),
      authorizeAccount: async () => false,
      fetchImpl: async () => new Response('{}'),
    });
    await withServer(app, async (baseUrl) => {
      const res = await upload(baseUrl, JPEG, 'image/jpeg');
      assert.equal(res.status, 403);
    });
  } finally {
    dirs.cleanup();
  }
});

test('POST ignores a client-supplied uid and stores under the token uid', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const res = await fetch(
        `${baseUrl}/api/images?uid=uid-agent-b&dir=../uid-agent-b`,
        {
          method: 'POST',
          headers: { Authorization: 'Bearer valid', 'Content-Type': 'image/jpeg' },
          body: JPEG,
        },
      );
      assert.equal(res.status, 200);
      const { url } = await res.json();
      assert.ok(url.includes('/uploads/uid-agent-a/'));
      assert.equal(url.includes('uid-agent-b'), false);
      assert.equal(fs.existsSync(path.join(dirs.uploads, 'uid-agent-b')), false);
    });
  } finally {
    dirs.cleanup();
  }
});

test('POST beyond the rate limit is throttled (429)', async () => {
  const dirs = tempDirs();
  try {
    const app = appForUid(dirs, 'uid-agent-a', {
      RATE_LIMIT_MAX: '2',
      RATE_LIMIT_WINDOW_MS: '600000',
    });
    await withServer(app, async (baseUrl) => {
      assert.equal((await upload(baseUrl, JPEG, 'image/jpeg')).status, 200);
      assert.equal((await upload(baseUrl, JPEG, 'image/jpeg')).status, 200);
      const third = await upload(baseUrl, JPEG, 'image/jpeg');
      assert.equal(third.status, 429);
    });
  } finally {
    dirs.cleanup();
  }
});

test('GET /uploads serves a stored image and 404s a missing one', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const up = await upload(baseUrl, PNG, 'image/png');
      const { url } = await up.json();
      const relative = url.split('/uploads/')[1];
      const got = await fetch(`${baseUrl}/uploads/${relative}`);
      assert.equal(got.status, 200);
      assert.equal(got.headers.get('content-type'), 'image/png');
      assert.deepEqual(Buffer.from(await got.arrayBuffer()), PNG);

      const missing = await fetch(`${baseUrl}/uploads/uid-agent-a/nope.png`);
      assert.equal(missing.status, 404);
    });
  } finally {
    dirs.cleanup();
  }
});

test('GET /uploads refuses path traversal to files outside the uploads root', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const res = await fetch(`${baseUrl}/uploads/%2e%2e%2f%2e%2e%2fserver.js`);
      assert.ok(res.status === 403 || res.status === 404, `status ${res.status}`);
    });
  } finally {
    dirs.cleanup();
  }
});

test('DELETE removes the owner own image', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const { url } = await (await upload(baseUrl, JPEG, 'image/jpeg')).json();
      const [uid, file] = url.split('/uploads/')[1].split('/');
      const onDisk = path.join(dirs.uploads, uid, file);
      assert.ok(fs.existsSync(onDisk));
      const del = await fetch(`${baseUrl}/api/images/${uid}/${file}`, {
        method: 'DELETE',
        headers: { Authorization: 'Bearer valid' },
      });
      assert.equal(del.status, 200);
      assert.equal(fs.existsSync(onDisk), false);
    });
  } finally {
    dirs.cleanup();
  }
});

test('DELETE of another agent image is forbidden and keeps the file', async () => {
  const dirs = tempDirs();
  try {
    // Agent A uploads.
    let stored;
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const { url } = await (await upload(baseUrl, JPEG, 'image/jpeg')).json();
      stored = url.split('/uploads/')[1];
    });
    const [uid, file] = stored.split('/');
    const onDisk = path.join(dirs.uploads, uid, file);
    assert.ok(fs.existsSync(onDisk));
    // Agent B tries to delete A's file.
    await withServer(appForUid(dirs, 'uid-agent-b'), async (baseUrl) => {
      const del = await fetch(`${baseUrl}/api/images/${uid}/${file}`, {
        method: 'DELETE',
        headers: { Authorization: 'Bearer valid' },
      });
      assert.equal(del.status, 403);
    });
    assert.ok(fs.existsSync(onDisk), 'file must survive a forbidden delete');
  } finally {
    dirs.cleanup();
  }
});

test('DELETE with a traversal filename is rejected (400)', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const del = await fetch(
        `${baseUrl}/api/images/uid-agent-a/${encodeURIComponent('../x.js')}`,
        { method: 'DELETE', headers: { Authorization: 'Bearer valid' } },
      );
      assert.equal(del.status, 400);
    });
  } finally {
    dirs.cleanup();
  }
});

test('admin may delete any agent image', async () => {
  const dirs = tempDirs();
  try {
    let stored;
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const { url } = await (await upload(baseUrl, JPEG, 'image/jpeg')).json();
      stored = url.split('/uploads/')[1];
    });
    const [uid, file] = stored.split('/');
    await withServer(appForUid(dirs, ADMIN_UID), async (baseUrl) => {
      const del = await fetch(`${baseUrl}/api/images/${uid}/${file}`, {
        method: 'DELETE',
        headers: { Authorization: 'Bearer valid' },
      });
      assert.equal(del.status, 200);
    });
    assert.equal(fs.existsSync(path.join(dirs.uploads, uid, file)), false);
  } finally {
    dirs.cleanup();
  }
});

test('DELETE preflight advertises the DELETE method in CORS', async () => {
  const dirs = tempDirs();
  try {
    await withServer(appForUid(dirs, 'uid-agent-a'), async (baseUrl) => {
      const res = await fetch(`${baseUrl}/api/images/uid-agent-a/x.jpg`, {
        method: 'OPTIONS',
        headers: {
          Origin: 'http://localhost:60518',
          'Access-Control-Request-Method': 'DELETE',
        },
      });
      assert.equal(res.status, 204);
      assert.match(res.headers.get('access-control-allow-methods') || '', /DELETE/);
    });
  } finally {
    dirs.cleanup();
  }
});
