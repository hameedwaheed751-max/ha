'use strict';

// طبقة تخزين صغيرة بأسلوب Realtime Database (مسارات مفصولة بـ /).
// MemoryDb للاختبارات، و firebaseDb غلاف رقيق فوق Admin SDK بنفس الدلالات.

function clone(value) {
  return value === undefined || value === null ? null : JSON.parse(JSON.stringify(value));
}

function segments(path) {
  return String(path || '').split('/').filter(Boolean);
}

class MemoryDb {
  constructor(seed = {}) {
    this.root = clone(seed) || {};
  }

  _read(path) {
    let node = this.root;
    for (const key of segments(path)) {
      if (node === null || typeof node !== 'object' || !(key in node)) return null;
      node = node[key];
    }
    return node === undefined ? null : node;
  }

  _write(path, value) {
    const keys = segments(path);
    if (keys.length === 0) {
      this.root = clone(value) || {};
      return;
    }
    let node = this.root;
    for (const key of keys.slice(0, -1)) {
      if (node[key] === null || typeof node[key] !== 'object') node[key] = {};
      node = node[key];
    }
    const last = keys[keys.length - 1];
    if (value === null || value === undefined) delete node[last];
    else node[last] = clone(value);
  }

  async get(path) {
    return clone(this._read(path));
  }

  async set(path, value) {
    this._write(path, value);
  }

  // مثل ref(path).update(patch): المفاتيح قد تكون مسارات نسبية متعددة المقاطع.
  async update(path, patch) {
    for (const [key, value] of Object.entries(patch)) {
      this._write(`${path}/${key}`, value);
    }
  }

  // يحاكي Realtime Database كما هي في Admin SDK: أول استدعاء لـ fn يكون بقيمة
  // null (لا نسخة محلية)، ثم يُعاد بالقيمة الحقيقية إن اختلفت. undefined يلغي
  // المعاملة فوراً حتى في الاستدعاء الأول.
  async transaction(path, fn) {
    const actual = clone(this._read(path));
    let next = fn(null);
    if (next === undefined) return { committed: false, value: actual };
    if (JSON.stringify(actual) !== JSON.stringify(null)) {
      next = fn(clone(actual));
      if (next === undefined) return { committed: false, value: actual };
    }
    this._write(path, next);
    return { committed: true, value: clone(next) };
  }
}

function firebaseDb(database) {
  return {
    get: async (path) => (await database.ref(path).once('value')).val(),
    set: (path, value) => database.ref(path).set(value),
    update: (path, patch) => database.ref(path).update(patch),
    transaction: async (path, fn) => {
      const result = await database.ref(path).transaction((current) => fn(current));
      return { committed: result.committed, value: result.snapshot.val() };
    },
  };
}

module.exports = { MemoryDb, firebaseDb };
