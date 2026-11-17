'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { MemoryDb } = require('./portal_db');
const { createAgentNotifier } = require('./agent_notifications');

const ADMIN = 'admin-uid';
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
// 2026-11-17 05:00 UTC = 08:00 بتوقيت بغداد.
const START = Date.parse('2026-11-17T05:00:00Z');
const token = (name) => `${name}-token-aaaaaaaaaaaaaaaaaaaa`;

function fakeSender() {
  const pushes = [];
  return {
    pushes,
    async sendPush(tokens, message) {
      pushes.push({ tokens: [...tokens], ...message });
      return { invalidTokens: tokens.filter((t) => t.startsWith('dead')) };
    },
  };
}

function setup({ seed = {}, ends = {}, eligible = () => true } = {}) {
  const db = new MemoryDb(seed);
  const sender = fakeSender();
  let clock = START;
  const notifier = createAgentNotifier({
    db,
    sender,
    adminUid: ADMIN,
    now: () => clock,
    subscriptionEnd: async (uid) => (uid in ends ? ends[uid] : null),
    isEligible: async (uid) => eligible(uid),
  });
  const to = (name) => sender.pushes.filter((p) => p.tokens.includes(token(name)));
  return { db, sender, notifier, to, setClock: (ms) => { clock = ms; } };
}

async function register(notifier, ...uids) {
  for (const uid of uids) await notifier.registerDevice(uid, { token: token(uid), platform: 'android' });
}

test('devices: validated, owned by the last account, removed on unregister, dead tokens dropped', async () => {
  const { notifier, db, sender } = setup();
  await assert.rejects(notifier.registerDevice('a', { token: 'x' }), { code: 'validation_failed' });
  await notifier.registerDevice('b', { token: token('shared') });
  await notifier.registerDevice('a', { token: token('shared') });
  assert.equal(Object.keys((await db.get('agentPush/devices/b')) || {}).length, 0);
  await notifier.registerDevice('a', { token: 'dead-token-bbbbbbbbbbbbbbbbbbbb' });
  await notifier.notify('a', { title: 'T', body: 'B', data: { kind: 'x' } });
  assert.equal(sender.pushes[0].tokens.length, 2);
  assert.deepEqual(Object.values(await db.get('agentPush/devices/a')).map((d) => d.token), [token('shared')]);
  await notifier.unregisterDevice('a', { token: token('shared') });
  await notifier.notify('a', { title: 'T', body: 'B' });
  assert.equal(sender.pushes.length, 1);
});

test('a failing sender never throws', async () => {
  const db = new MemoryDb();
  const notifier = createAgentNotifier({
    db,
    sender: { sendPush: async () => { throw new Error('fcm down'); } },
    adminUid: ADMIN,
  });
  await notifier.registerDevice('a', { token: token('a') });
  await notifier.notify('a', { title: 'T', body: 'B' });
});

test('chat: an admin message reaches every agent but not the admin', async () => {
  const { notifier, to } = setup();
  await register(notifier, ADMIN, 'a', 'b');
  await notifier.onChatMessage('m1', { senderUid: ADMIN, senderName: 'المدير', text: 'تحديث جديد متاح' });
  assert.equal(to('a')[0].title, 'رسالة من الإدارة');
  assert.equal(to('a')[0].body, 'تحديث جديد متاح');
  assert.deepEqual(to('a')[0].data, { kind: 'chat', id: 'm1' });
  assert.equal(to('b').length, 1);
  assert.equal(to(ADMIN).length, 0);
});

test('chat: an agent message reaches the admin, and a reply reaches the replied-to agent only', async () => {
  const { notifier, to } = setup();
  await register(notifier, ADMIN, 'a', 'b', 'c');
  await notifier.onChatMessage('m2', {
    senderUid: 'a',
    senderName: 'مكتب النور',
    text: '',
    imageUrl: 'https://x/y.jpg',
    replyTo: { id: 'm0', senderUid: 'b', senderName: 'ب' },
  });
  assert.equal(to(ADMIN)[0].title, 'رسالة من مكتب النور');
  assert.equal(to(ADMIN)[0].body, 'صورة');
  assert.equal(to('b')[0].title, 'مكتب النور رد على رسالتك');
  assert.equal(to('c').length, 0);
  assert.equal(to('a').length, 0);
});

test('chat: deleted, empty or sender-less messages, and replies to oneself, push nothing extra', async () => {
  const { notifier, sender, to } = setup();
  await register(notifier, ADMIN, 'a');
  await notifier.onChatMessage('m3', { senderUid: 'a', text: 'x', deletedAt: '2026-11-17T08:00:00' });
  await notifier.onChatMessage('m4', { senderUid: 'a', text: '  ' });
  await notifier.onChatMessage('m5', { text: 'no sender' });
  assert.equal(sender.pushes.length, 0);
  await notifier.onChatMessage('m6', { senderUid: 'a', senderName: 'أ', text: 'hi', replyTo: { senderUid: 'a' } });
  assert.equal(to(ADMIN).length, 1);
  assert.equal(to('a').length, 0);
});

test('long chat text is shortened in the notification', async () => {
  const { notifier, to } = setup();
  await register(notifier, ADMIN);
  await notifier.onChatMessage('m7', { senderUid: 'a', senderName: 'أ', text: 'ك'.repeat(300) });
  assert.ok(to(ADMIN)[0].body.length <= 120);
  assert.ok(to(ADMIN)[0].body.endsWith('…'));
});

test('subscription requests: a new one reaches the admin; a decision reaches the agent', async () => {
  const { notifier, to } = setup();
  await register(notifier, ADMIN, 'a');
  const request = {
    uid: 'a',
    firstName: 'حسين',
    lastName: 'علي',
    selectedPlan: 'three_months',
    status: 'pending',
    isRenewal: true,
  };
  await notifier.onRequestAdded('r1', request);
  assert.equal(to(ADMIN)[0].title, 'طلب تجديد اشتراك وكيل');
  assert.match(to(ADMIN)[0].body, /حسين علي/);
  assert.deepEqual(to(ADMIN)[0].data, { kind: 'agent_request', id: 'r1' });
  await notifier.onRequestAdded('r2', { ...request, isRenewal: false });
  assert.equal(to(ADMIN)[1].title, 'طلب اشتراك جديد');
  await notifier.onRequestAdded('r3', { ...request, status: 'approved' });
  assert.equal(to(ADMIN).length, 2);

  await notifier.onRequestChanged('r1', 'pending', { ...request, status: 'reviewing' });
  assert.equal(to('a').length, 0);
  await notifier.onRequestChanged('r1', 'reviewing', { ...request, status: 'approved' });
  assert.equal(to('a')[0].title, 'تم قبول طلب اشتراكك');
  assert.deepEqual(to('a')[0].data, { kind: 'my_subscription', id: 'r1' });
  await notifier.onRequestChanged('r1', 'approved', { ...request, status: 'approved' });
  assert.equal(to('a').length, 1);
  await notifier.onRequestChanged('r2', 'pending', { ...request, status: 'rejected', rejectionReason: 'الإيصال غير واضح' });
  assert.equal(to('a')[1].title, 'رُفض طلب اشتراكك');
  assert.match(to('a')[1].body, /الإيصال غير واضح/);
});

test('agent subscription: one notice three days before and one on expiry day', async () => {
  const end = START + 2.5 * DAY;
  const { notifier, to, setClock } = setup({ ends: { a: end, b: START + 10 * DAY } });
  await register(notifier, ADMIN, 'a', 'b');
  await notifier.runScheduled();
  assert.equal(to('a')[0].title, 'اشتراكك في وكيل نت ينتهي قريباً');
  assert.match(to('a')[0].body, /3 أيام/);
  await notifier.runScheduled();
  setClock(START + DAY);
  await notifier.runScheduled();
  assert.equal(to('a').filter((p) => p.data.kind === 'my_subscription').length, 1);
  setClock(end + HOUR);
  await notifier.runScheduled();
  const subscription = to('a').filter((p) => p.data.kind === 'my_subscription');
  assert.equal(subscription.length, 2);
  assert.equal(subscription[1].title, 'انتهى اشتراكك في وكيل نت');
  setClock(end + 3 * DAY);
  await notifier.runScheduled();
  assert.equal(to('a').filter((p) => p.data.kind === 'my_subscription').length, 2);
  assert.equal(to('b').filter((p) => p.data.kind === 'my_subscription').length, 0);
  assert.equal(to(ADMIN).filter((p) => p.data.kind === 'my_subscription').length, 0);
});

test('morning digest: after 9:00 Baghdad, once a day, only when subscribers expire today', async () => {
  const seed = {
    agents: {
      a: {
        subscribers: [
          { name: '1', endDate: '2026-11-17T00:00:00.000', disabled: false },
          { name: '2', endDate: '2026-11-17T23:00:00.000' },
          { name: '3', endDate: '2026-11-17T10:00:00.000', disabled: true },
          { name: '4', endDate: '2026-11-18T00:00:00.000' },
          null,
        ],
      },
      b: { subscribers: [{ name: '5', endDate: '2026-11-20T00:00:00.000' }] },
      c: { subscribers: [{ name: '6', endDate: '2026-11-17T00:00:00.000' }] },
    },
  };
  const { notifier, to, setClock } = setup({ seed, eligible: (uid) => uid !== 'c' });
  await register(notifier, 'a', 'b', 'c');
  await notifier.runScheduled(); // 08:00 بغداد: مبكر.
  assert.equal(to('a').length, 0);
  setClock(START + HOUR); // 09:00 بغداد.
  await notifier.runScheduled();
  const digest = to('a').filter((p) => p.data.kind === 'digest');
  assert.equal(digest.length, 1);
  assert.equal(digest[0].body, 'اليوم ينتهي اشتراك 2 من مشتركيك.');
  await notifier.runScheduled();
  assert.equal(to('a').filter((p) => p.data.kind === 'digest').length, 1);
  assert.equal(to('b').length, 0);
  assert.equal(to('c').length, 0); // وكيل منتهٍ: لا ملخص.
  setClock(START + DAY + HOUR); // اليوم التالي 09:00.
  await notifier.runScheduled();
  const next = to('a').filter((p) => p.data.kind === 'digest');
  assert.equal(next.length, 2);
  assert.equal(next[1].body, 'اليوم ينتهي اشتراك 1 من مشتركيك.');
});

// قاعدة بيانات مزيّفة بأسلوب Admin SDK: ref/orderByKey/limitToLast/startAfter/once/on/off.
function fakeDatabase(seed) {
  const listeners = [];
  const data = JSON.parse(JSON.stringify(seed));
  const snapshotOf = (key, value) => ({ key, val: () => value });
  const childrenOf = (path) => Object.entries(data[path] || {}).sort(([a], [b]) => (a < b ? -1 : 1));
  const query = (path, opts = {}) => ({
    orderByKey: () => query(path, opts),
    limitToLast: (n) => query(path, { ...opts, last: n }),
    startAfter: (key) => query(path, { ...opts, after: key }),
    async once() {
      let items = childrenOf(path).filter(([k]) => !opts.after || k > opts.after);
      if (opts.last) items = items.slice(-opts.last);
      return { forEach: (fn) => items.some(([k, v]) => fn(snapshotOf(k, v)) === true) };
    },
    on(event, cb) {
      listeners.push({ path, event, cb, opts });
      if (event === 'child_added') {
        for (const [k, v] of childrenOf(path)) if (!opts.after || k > opts.after) cb(snapshotOf(k, v));
      }
    },
    off(event, cb) {
      const i = listeners.findIndex((l) => l.event === event && l.cb === cb);
      if (i >= 0) listeners.splice(i, 1);
    },
  });
  return {
    ref: (path) => query(path),
    listeners,
    emit(path, event, key, value) {
      data[path] = { ...(data[path] || {}), [key]: value };
      for (const l of listeners) if (l.path === path && l.event === event) l.cb(snapshotOf(key, value));
    },
  };
}

test('watchers ignore what existed at start, then forward new chat messages and request changes', async () => {
  const { watchAgentEvents } = require('./agent_notifications');
  const database = fakeDatabase({
    'global_chat/chat': { m1: { senderUid: 'a', text: 'قديمة' } },
    'admin/subscriptionRequests': { r1: { uid: 'a', status: 'pending' } },
  });
  const calls = [];
  const notifier = {
    onChatMessage: async (id) => calls.push(['chat', id]),
    onRequestAdded: async (id) => calls.push(['added', id]),
    onRequestChanged: async (id, previous, request) => calls.push(['changed', id, previous, request.status]),
  };
  const stop = await watchAgentEvents({ database, notifier });
  assert.deepEqual(calls, []);
  database.emit('global_chat/chat', 'child_added', 'm2', { senderUid: 'a', text: 'جديدة' });
  database.emit('admin/subscriptionRequests', 'child_added', 'r2', { uid: 'b', status: 'pending' });
  database.emit('admin/subscriptionRequests', 'child_changed', 'r1', { uid: 'a', status: 'approved' });
  assert.deepEqual(calls, [
    ['chat', 'm2'],
    ['added', 'r2'],
    ['changed', 'r1', 'pending', 'approved'],
  ]);
  stop();
  assert.equal(database.listeners.length, 0);
});
