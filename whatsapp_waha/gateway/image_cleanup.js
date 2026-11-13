'use strict';

// Reclaims disk by deleting product/store images on the VPS that no Firebase
// record references any more. Orphans build up when a delete fails, the app
// stops mid-edit, or a record is removed outside the normal flow.
//
// Safety:
//  - A freshly uploaded image is written to disk a moment before its record is
//    saved, so files younger than the grace period are never touched.
//  - The referenced set is read from Firebase FIRST; a failed read throws and
//    aborts before any file is listed or deleted, so a transient DB outage can
//    never be mistaken for "nothing is referenced" and wipe the uploads.
//  - Only files under uploadsDir/<uid>/<name> are considered; dotfiles skipped.

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_GRACE_MS = 24 * 60 * 60 * 1000;
const DEFAULT_INTERVAL_MS = 24 * 60 * 60 * 1000;

function addUrls(set, value) {
  if (Array.isArray(value)) {
    for (const item of value) if (typeof item === 'string' && item) set.add(item);
  } else if (value && typeof value === 'object') {
    for (const item of Object.values(value)) {
      if (typeof item === 'string' && item) set.add(item);
    }
  } else if (typeof value === 'string' && value) {
    set.add(value);
  }
}

function asMap(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

/** Every image URL referenced by a product (`images`) or store (`logoUrl`). Pure. */
function collectReferencedUrls({ products, stores } = {}) {
  const set = new Set();
  for (const product of Object.values(asMap(products))) {
    if (product && typeof product === 'object') addUrls(set, product.images);
  }
  for (const store of Object.values(asMap(stores))) {
    if (store && typeof store === 'object') addUrls(set, store.logoUrl);
  }
  return set;
}

/**
 * Files on disk whose URL no record references and that are older than the
 * grace period. Pure.
 * `files`: [{ path, uid, name, url, mtimeMs }]
 */
function selectOrphans({ files, referenced, nowMs, graceMs = DEFAULT_GRACE_MS }) {
  return files.filter(
    (file) => !referenced.has(file.url) && nowMs - file.mtimeMs >= graceMs,
  );
}

/** Lists every upload file as { path, uid, name, url, mtimeMs }. */
async function listUploadFiles(uploadsDir, publicBaseUrl) {
  const base = String(publicBaseUrl).replace(/\/+$/, '');
  let uidEntries;
  try {
    uidEntries = await fs.promises.readdir(uploadsDir, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
  const files = [];
  for (const uidEntry of uidEntries) {
    if (!uidEntry.isDirectory() || uidEntry.name.startsWith('.')) continue;
    const uid = uidEntry.name;
    const dir = path.join(uploadsDir, uid);
    let names;
    try {
      names = await fs.promises.readdir(dir, { withFileTypes: true });
    } catch (_) {
      continue;
    }
    for (const nameEntry of names) {
      if (!nameEntry.isFile() || nameEntry.name.startsWith('.')) continue;
      const full = path.join(dir, nameEntry.name);
      let stat;
      try {
        stat = await fs.promises.stat(full);
      } catch (_) {
        continue;
      }
      files.push({
        path: full,
        uid,
        name: nameEntry.name,
        url: `${base}/uploads/${uid}/${nameEntry.name}`,
        mtimeMs: stat.mtimeMs,
      });
    }
  }
  return files;
}

/** Reads `products` and `stores` from a firebase-admin Database. */
async function readReferencedUrls(db) {
  const [products, stores] = await Promise.all([
    db.ref('products').once('value').then((snapshot) => snapshot.val()),
    db.ref('stores').once('value').then((snapshot) => snapshot.val()),
  ]);
  return collectReferencedUrls({ products, stores });
}

/**
 * One cleanup pass. Reads the referenced set first (throws on DB failure,
 * before touching any file), then deletes unreferenced files past the grace
 * period. `apply:false` reports without deleting.
 */
async function runImageCleanup({
  db,
  uploadsDir,
  publicBaseUrl,
  nowMs = Date.now(),
  graceMs = DEFAULT_GRACE_MS,
  apply = true,
  log = () => {},
}) {
  const referenced = await readReferencedUrls(db);
  const files = await listUploadFiles(uploadsDir, publicBaseUrl);
  const orphans = selectOrphans({ files, referenced, nowMs, graceMs });
  let deleted = 0;
  if (apply) {
    for (const orphan of orphans) {
      try {
        await fs.promises.unlink(orphan.path);
        deleted += 1;
      } catch (_) {
        // Best effort: a file already gone still counts as cleaned up.
      }
    }
  }
  const summary = {
    scanned: files.length,
    referenced: referenced.size,
    orphans: orphans.length,
    deleted,
  };
  log(
    `Image cleanup: scanned=${summary.scanned} referenced=${summary.referenced} ` +
      `orphans=${summary.orphans} deleted=${summary.deleted}`,
  );
  return summary;
}

/**
 * Runs `run` every `intervalMs` (and once after `firstRunDelayMs`), skipping a
 * tick while the previous run is still in flight. Returns a stop function.
 */
function startImageCleanup({ run, intervalMs = DEFAULT_INTERVAL_MS, firstRunDelayMs = 60000 }) {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      await run();
    } catch (error) {
      console.error(
        `Image cleanup run failed (${error?.code || error?.constructor?.name || 'error'})`,
      );
    } finally {
      running = false;
    }
  };
  const first = setTimeout(tick, firstRunDelayMs);
  const interval = setInterval(tick, intervalMs);
  return () => {
    clearTimeout(first);
    clearInterval(interval);
  };
}

module.exports = {
  DEFAULT_GRACE_MS,
  DEFAULT_INTERVAL_MS,
  collectReferencedUrls,
  selectOrphans,
  listUploadFiles,
  readReferencedUrls,
  runImageCleanup,
  startImageCleanup,
};
