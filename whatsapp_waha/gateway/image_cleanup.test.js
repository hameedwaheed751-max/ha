'use strict';

// Tests for the orphan product/store image cleanup. The pure selectors run with
// plain objects; the IO is exercised against a temp dir and a fake Database.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  collectReferencedUrls,
  selectOrphans,
  listUploadFiles,
  readReferencedUrls,
  runImageCleanup,
} = require('./image_cleanup');

const GW = 'https://netagentiraq.duckdns.org';

function tmpUploads() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'uploads-'));
}

function writeFile(root, uid, name, { ageMs = 0 } = {}) {
  const dir = path.join(root, uid);
  fs.mkdirSync(dir, { recursive: true });
  const full = path.join(dir, name);
  fs.writeFileSync(full, 'x');
  if (ageMs > 0) {
    const when = new Date(Date.now() - ageMs);
    fs.utimesSync(full, when, when);
  }
  return full;
}

/** A fake firebase-admin Database serving fixed products/stores snapshots. */
function fakeDb({ products = null, stores = null, fail = null }) {
  return {
    ref(node) {
      return {
        once() {
          if (fail) return Promise.reject(fail);
          const val = node === 'products' ? products : node === 'stores' ? stores : null;
          return Promise.resolve({ val: () => val });
        },
      };
    },
  };
}

test('collectReferencedUrls gathers product images (list + map) and store logos', () => {
  const set = collectReferencedUrls({
    products: {
      a: { images: [`${GW}/uploads/u1/a.jpg`, `${GW}/uploads/u1/b.jpg`] },
      b: { images: { 0: `${GW}/uploads/u2/c.jpg` } },
      c: { title: 'no images' },
    },
    stores: {
      s1: { logoUrl: `${GW}/uploads/u3/logo.png` },
      s2: { name: 'no logo' },
    },
  });
  assert.deepEqual(
    [...set].sort(),
    [
      `${GW}/uploads/u1/a.jpg`,
      `${GW}/uploads/u1/b.jpg`,
      `${GW}/uploads/u2/c.jpg`,
      `${GW}/uploads/u3/logo.png`,
    ].sort(),
  );
});

test('collectReferencedUrls tolerates null/empty trees', () => {
  assert.equal(collectReferencedUrls({}).size, 0);
  assert.equal(collectReferencedUrls({ products: null, stores: null }).size, 0);
});

test('selectOrphans keeps referenced files and files inside the grace window', () => {
  const nowMs = 1_000_000_000;
  const graceMs = 24 * 60 * 60 * 1000;
  const files = [
    { url: `${GW}/uploads/u/ref.jpg`, mtimeMs: nowMs - 2 * graceMs }, // referenced → keep
    { url: `${GW}/uploads/u/old.jpg`, mtimeMs: nowMs - 2 * graceMs }, // orphan, old → delete
    { url: `${GW}/uploads/u/new.jpg`, mtimeMs: nowMs - 1000 }, // orphan, fresh → keep
  ];
  const referenced = new Set([`${GW}/uploads/u/ref.jpg`]);
  const orphans = selectOrphans({ files, referenced, nowMs, graceMs });
  assert.deepEqual(orphans.map((f) => f.url), [`${GW}/uploads/u/old.jpg`]);
});

test('listUploadFiles returns files with their public URLs, skipping dotfiles', async () => {
  const root = tmpUploads();
  try {
    writeFile(root, 'uidA', 'a.jpg');
    writeFile(root, 'uidA', '.hidden');
    writeFile(root, 'uidB', 'b.png');
    const files = await listUploadFiles(root, `${GW}/`);
    const urls = files.map((f) => f.url).sort();
    assert.deepEqual(urls, [
      `${GW}/uploads/uidA/a.jpg`,
      `${GW}/uploads/uidB/b.png`,
    ]);
    assert.ok(files.every((f) => typeof f.mtimeMs === 'number'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('listUploadFiles returns [] when the uploads dir does not exist', async () => {
  const files = await listUploadFiles(path.join(os.tmpdir(), 'no-such-dir-xyz'), GW);
  assert.deepEqual(files, []);
});

test('readReferencedUrls reads products and stores from the database', async () => {
  const db = fakeDb({
    products: { a: { images: [`${GW}/uploads/u/a.jpg`] } },
    stores: { s: { logoUrl: `${GW}/uploads/u/logo.png` } },
  });
  const set = await readReferencedUrls(db);
  assert.deepEqual([...set].sort(), [
    `${GW}/uploads/u/a.jpg`,
    `${GW}/uploads/u/logo.png`,
  ]);
});

test('runImageCleanup deletes old orphans, keeps referenced and fresh files', async () => {
  const root = tmpUploads();
  try {
    const day = 24 * 60 * 60 * 1000;
    const referencedPath = writeFile(root, 'u', 'ref.jpg', { ageMs: 5 * day });
    const orphanOld = writeFile(root, 'u', 'old.jpg', { ageMs: 5 * day });
    const orphanNew = writeFile(root, 'u', 'new.jpg', { ageMs: 0 });
    const db = fakeDb({ products: { p: { images: [`${GW}/uploads/u/ref.jpg`] } } });

    const summary = await runImageCleanup({
      db,
      uploadsDir: root,
      publicBaseUrl: GW,
      graceMs: day,
    });

    assert.equal(summary.scanned, 3);
    assert.equal(summary.referenced, 1);
    assert.equal(summary.orphans, 1);
    assert.equal(summary.deleted, 1);
    assert.ok(fs.existsSync(referencedPath));
    assert.ok(!fs.existsSync(orphanOld));
    assert.ok(fs.existsSync(orphanNew));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('runImageCleanup with apply:false deletes nothing', async () => {
  const root = tmpUploads();
  try {
    const orphan = writeFile(root, 'u', 'old.jpg', { ageMs: 10 * 24 * 60 * 60 * 1000 });
    const db = fakeDb({ products: null, stores: null });
    const summary = await runImageCleanup({
      db,
      uploadsDir: root,
      publicBaseUrl: GW,
      apply: false,
    });
    assert.equal(summary.orphans, 1);
    assert.equal(summary.deleted, 0);
    assert.ok(fs.existsSync(orphan));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('runImageCleanup aborts without deleting if the database read fails', async () => {
  const root = tmpUploads();
  try {
    const orphan = writeFile(root, 'u', 'old.jpg', { ageMs: 10 * 24 * 60 * 60 * 1000 });
    const db = fakeDb({ fail: new Error('db down') });
    await assert.rejects(
      runImageCleanup({ db, uploadsDir: root, publicBaseUrl: GW }),
      /db down/,
    );
    assert.ok(fs.existsSync(orphan), 'no file may be deleted when the DB read fails');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
