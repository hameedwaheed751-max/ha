'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  ExpiryScheduler,
  FirebaseNoticeStore,
  dueEvents,
  eventFor,
  renderNotice,
} = require('./expiry_scheduler');
const { sessionNameForUid } = require('./server');

const UID = 'uid-agent';
const HOUR = 60 * 60 * 1000;
const START = Date.UTC(2026, 10, 3, 9, 0, 0); // 12:00 in Baghdad.

// Like the Firebase SDK, a transaction first sees null when nothing is cached,
// then the stored value if that guess was wrong.
class FakeDatabase {
  constructor(data = {}) {
    this.data = data;
    this.writes = [];
  }

  _get(path) {
    return path.split('/').reduce((node, key) => (node == null ? undefined : node[key]), this.data);
  }

  _set(path, value) {
    const keys = path.split('/');
    let node = this.data;
    for (const key of keys.slice(0, -1)) {
      if (node[key] == null || typeof node[key] !== 'object') node[key] = {};
      node = node[key];
    }
    if (value === null) delete node[keys.at(-1)];
    else node[keys.at(-1)] = structuredClone(value);
  }

  ref(path) {
    const database = this;
    return {
      child: (child) => database.ref(`${path}/${child}`),
      once: async () => {
        const value = database._get(path);
        return { val: () => (value === undefined ? null : structuredClone(value)) };
      },
      transaction: async (update) => {
        const stored = database._get(path) ?? null;
        let next = update(null);
        if (stored !== null) {
          if (next === undefined) return { committed: false };
          next = update(structuredClone(stored));
        }
        if (next === undefined) return { committed: false };
        database._set(path, next);
        database.writes.push(path);
        return { committed: true };
      },
    };
  }
}

function subscriber(index, endDate, extra = {}) {
  return {
    subscriberId: `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
    name: `مشترك ${index}`,
    user: `user${index}`,
    phone: `0770000${String(index).padStart(4, '0')}`,
    type: 'Fiber 50',
    price: 35000,
    paid: 35000,
    startDate: '2026-10-06T10:00:00.000',
    endDate,
    active: true,
    disabled: false,
    ...extra,
  };
}

// Baghdad-local ISO text for `hours` after START, as the app stores it.
function localEnd(hours) {
  const date = new Date(START + hours * HOUR + 3 * HOUR);
  return date.toISOString().replace('Z', '');
}

function agentData(subscribers, extra = {}) {
  return {
    profile: { name: 'وكيل الاختبار', phone: '07701234567' },
    settings: { subscribersRevision: 1, officeName: 'مكتب', officePhone: '07701234567' },
    subscribers,
    ...extra,
  };
}

function setup({ subscribers, agent = {}, sessionStatus = 'WORKING', sendStatus = () => 200 }) {
  const clock = { now: START };
  const database = new FakeDatabase({ agents: { [UID]: agentData(subscribers, agent) } });
  const sent = [];
  const sender = {
    getSession: async (session) => {
      assert.equal(session, sessionNameForUid(UID));
      return sessionStatus ? { status: sessionStatus } : null;
    },
    // sendStatus returns a status code, or { status, error } for a specific error.
    sendText: async (request) => {
      const result = sendStatus(request, sent.length);
      const { status, error } = typeof result === 'object' ? result : { status: result };
      if (status === 200) sent.push({ ...request, at: clock.now });
      return status === 200
        ? { status, body: { success: true, messageId: `m${sent.length}` } }
        : { status, body: { success: false, error: error || (status === 409 ? 'idempotency_key_conflict' : 'x') } };
    },
  };
  const delays = [];
  const makeScheduler = () => new ExpiryScheduler({
    store: new FirebaseNoticeStore(database),
    sender,
    listAgentUids: async () => [UID],
    sessionNameForUid,
    now: () => clock.now,
    delay: async (ms) => {
      delays.push(ms);
      clock.now += ms;
    },
    log: () => {},
  });
  const items = () => database._get(`agents/${UID}/notificationAutomation/expiry3days/items`) || {};
  return { clock, database, sent, delays, makeScheduler, items };
}

test('a subscription is notified once when it enters the last 72 hours', async () => {
  const env = setup({ subscribers: [subscriber(1, localEnd(73))] });
  const scheduler = env.makeScheduler();

  await scheduler.run();
  assert.equal(env.sent.length, 0, 'not yet inside the window');

  env.clock.now += HOUR + 5 * 60 * 1000;
  await scheduler.run();
  assert.equal(env.sent.length, 1);
  assert.equal(env.sent[0].eventType, 'expiry_3days');
  assert.equal(env.sent[0].to, '07700000001');

  env.clock.now += 5 * 60 * 1000;
  await scheduler.run();
  await env.makeScheduler().run();
  assert.equal(env.sent.length, 1, 'never sent twice');
  const [item] = Object.values(env.items());
  assert.equal(item.status, 'sent');
  assert.equal(item.sentBy, 'server');
});

test('the record key matches the one the app computes', () => {
  // Computed with Dart: DateTime.parse('2026-11-05T14:00:00.000') in UTC+3.
  const event = eventFor('3f2b8c1e-9a4d-4e7f-8b2c-1d5e6f7a8b9c', 'expiry_3days', 1793876400000000);
  assert.equal(event.storageKey, 'b57334cf7baa675ca5c8bb6e66f7131fb48aa4e3c3fafda5af52b61ca606610e');
  const [due] = dueEvents(
    [{ ...subscriber(9, '2026-11-05T14:00:00.000'), subscriberId: '3f2b8c1e-9a4d-4e7f-8b2c-1d5e6f7a8b9c' }],
    Date.UTC(2026, 10, 3, 12) * 1000,
    180,
  );
  assert.equal(due.storageKey, event.storageKey);
});

test('a backlog after downtime is sent gradually, oldest first', async () => {
  const subscribers = Array.from({ length: 25 }, (_, index) => subscriber(index + 1, localEnd(70 - index)));
  const env = setup({ subscribers });

  await env.makeScheduler().run();
  assert.equal(env.sent.length, 10, 'at most 10 per run');
  assert.deepEqual(env.delays, Array(9).fill(15000), '15 seconds between messages');
  assert.equal(env.sent[0].to, '07700000025', 'nearest end date first');

  env.clock.now += 5 * 60 * 1000;
  await env.makeScheduler().run();
  env.clock.now += 5 * 60 * 1000;
  await env.makeScheduler().run();
  assert.equal(env.sent.length, 25);
  assert.equal(new Set(env.sent.map((item) => item.idempotencyKey)).size, 25);
});

test('nothing is sent while the app holds the shared lease', async () => {
  const env = setup({ subscribers: [subscriber(1, localEnd(10))] });
  env.database._set(`agents/${UID}/notificationAutomation/expiry3days/control`, {
    owner: 'app-device',
    leaseUntil: START + 60 * 1000,
  });

  await env.makeScheduler().run();
  assert.equal(env.sent.length, 0);

  env.clock.now += 2 * 60 * 1000;
  await env.makeScheduler().run();
  assert.equal(env.sent.length, 1, 'sent once the lease expires');
});

test('notices the app already sent or is sending are left alone', async () => {
  const sentByApp = subscriber(1, localEnd(30));
  const sendingByApp = subscriber(2, localEnd(31));
  const env = setup({ subscribers: [sentByApp, sendingByApp] });
  const root = `agents/${UID}/notificationAutomation/expiry3days/items`;
  const micros = (raw) => dueEvents([raw], START * 1000, 180)[0];
  const appRecord = { status: 'sent', attempts: 1, endDateMicros: micros(sentByApp).endDateMicros, sentAt: 1 };
  env.database._set(`${root}/${micros(sentByApp).storageKey}`, appRecord);
  env.database._set(`${root}/${micros(sendingByApp).storageKey}`, {
    status: 'sending',
    owner: 'app-device',
    leaseUntil: START + 60 * 1000,
  });

  await env.makeScheduler().run();
  assert.equal(env.sent.length, 0);
  assert.deepEqual(env.items()[micros(sentByApp).storageKey], appRecord, 'earlier record unchanged');
});

test('two servers running together send each notice once', async () => {
  const subscribers = Array.from({ length: 4 }, (_, index) => subscriber(index + 1, localEnd(20 + index)));
  const env = setup({ subscribers });

  await Promise.all([env.makeScheduler().run(), env.makeScheduler().run()]);
  env.clock.now += 5 * 60 * 1000;
  await Promise.all([env.makeScheduler().run(), env.makeScheduler().run()]);
  assert.equal(env.sent.length, 4);
});

test('agents without a connected WhatsApp session are skipped', async () => {
  const env = setup({ subscribers: [subscriber(1, localEnd(10))], sessionStatus: 'SCAN_QR_CODE' });
  await env.makeScheduler().run();
  assert.equal(env.sent.length, 0);
  assert.deepEqual(env.items(), {}, 'nothing claimed');
});

test('a disabled notice type is not sent and a saved message is used', async () => {
  const disabled = setup({
    subscribers: [subscriber(1, localEnd(10))],
    agent: { settings: { subscribersRevision: 1, whatsappNotifications: { expiry_3days: { enabled: false } } } },
  });
  await disabled.makeScheduler().run();
  assert.equal(disabled.sent.length, 0);

  const custom = setup({
    subscribers: [subscriber(1, localEnd(10))],
    agent: {
      settings: {
        subscribersRevision: 1,
        officePhone: '07701234567',
        whatsappNotifications: { expiry_3days: { enabled: true, message: 'تنبيه {{customer_name}} ينتهي {{subscription_end}}' } },
      },
    },
  });
  await custom.makeScheduler().run();
  assert.equal(custom.sent[0].text, 'تنبيه مشترك 1 ينتهي 03/11/2026\n🏢 وكيل الاختبار • 07701234567');
});

test('the default text matches the app template with the agent number', () => {
  const [event] = dueEvents([subscriber(1, '2026-11-05T14:00:00.000')], Date.UTC(2026, 10, 3, 12) * 1000, 180);
  const text = renderNotice(
    event,
    { agentName: 'وكيل الاختبار', officeName: 'مكتب', officePhone: '07701234567', expiredTemplate: '' },
    null,
    Date.UTC(2026, 10, 3, 12) * 1000,
    180,
  );
  assert.equal(
    text,
    'مرحباً مشترك 1،\n⏳ نود إعلامكم بأن اشتراك الإنترنت سينتهي قريباً.\n📦 الباقة: Fiber 50\n📅 تاريخ الانتهاء: 05/11/2026\nلضمان استمرار الخدمة دون انقطاع، يرجى مراجعة:\n🏢 وكيل الاختبار\n📱 9647701234567\n\nشكراً لاختياركم خدمتنا.',
  );

  // Both texts were produced by the app's WhatsAppNotificationDispatcher.
  const expiredAt = Date.UTC(2026, 10, 6, 12) * 1000;
  const [expired] = dueEvents([subscriber(1, '2026-11-05T14:00:00.000')], expiredAt, 180);
  assert.equal(
    renderNotice(
      expired,
      { agentName: 'وكيل الاختبار', officeName: 'مكتب', officePhone: '07701234567', expiredTemplate: '' },
      null,
      expiredAt,
      180,
    ),
    'مرحباً مشترك 1، اشتراكك لدى وكيل الاختبار منتهي. يرجى التجديد لاستمرار الخدمة.\n🏢 وكيل الاختبار • 07701234567',
  );
});

test('failures are retried later, conflicts wait for review, 429 pauses', async () => {
  const subscribers = [subscriber(1, localEnd(10)), subscriber(2, localEnd(11)), subscriber(3, localEnd(12))];
  const statuses = { '07700000001': 504, '07700000002': 409, '07700000003': 429 };
  const env = setup({ subscribers, sendStatus: (request) => statuses[request.to] });
  await env.makeScheduler().run();

  const byStatus = Object.values(env.items()).map((item) => item.status).sort();
  assert.deepEqual(byStatus, ['manual_review', 'retry', 'retry']);
  const control = env.database._get(`agents/${UID}/notificationAutomation/expiry3days/control`);
  assert.ok(control.pauseUntil > env.clock.now, 'queue paused after 429');

  statuses['07700000001'] = 200;
  statuses['07700000003'] = 200;
  env.clock.now += 31 * 60 * 1000;
  await env.makeScheduler().run();
  assert.deepEqual(env.sent.map((item) => item.to).sort(), ['07700000001', '07700000003']);
});

test('an unknown delivery outcome waits for review and is never resent', async () => {
  let calls = 0;
  const env = setup({
    subscribers: [subscriber(1, localEnd(10))],
    sendStatus: () => {
      calls += 1;
      return calls === 1 ? { status: 504, error: 'delivery_outcome_unknown' } : 200;
    },
  });
  await env.makeScheduler().run();
  const [item] = Object.values(env.items());
  assert.equal(item.status, 'manual_review');
  assert.equal(item.retryAt, undefined);

  // The sender would now succeed, but the Firebase record alone blocks a resend.
  env.clock.now += 2 * HOUR;
  await env.makeScheduler().run();
  assert.equal(calls, 1);
  assert.equal(env.sent.length, 0);
});

test('a confirmed failure is retried and sent once', async () => {
  let status = { status: 502, error: 'waha_rejected_request' };
  const env = setup({ subscribers: [subscriber(1, localEnd(10))], sendStatus: () => status });
  await env.makeScheduler().run();
  assert.equal(Object.values(env.items())[0].status, 'retry');

  status = 200;
  env.clock.now += 10 * 60 * 1000;
  await env.makeScheduler().run();
  env.clock.now += 10 * 60 * 1000;
  await env.makeScheduler().run();
  assert.equal(env.sent.length, 1);
  assert.equal(Object.values(env.items())[0].status, 'sent');
});

test('a notice left mid-send is held for review, not resent', async () => {
  // E.g. the message went out but saving "sent" to Firebase failed, and the
  // gateway's local record is gone: Firebase alone must stop a resend.
  const raw = subscriber(1, localEnd(10));
  const env = setup({ subscribers: [raw] });
  const [event] = dueEvents([raw], START * 1000, 180);
  env.database._set(`agents/${UID}/notificationAutomation/expiry3days/items/${event.storageKey}`, {
    status: 'sending',
    owner: 'crashed-server',
    attempts: 1,
    leaseUntil: START - 60 * 1000,
  });

  await env.makeScheduler().run();
  env.clock.now += 2 * HOUR;
  await env.makeScheduler().run();
  assert.equal(env.sent.length, 0);
  const item = env.items()[event.storageKey];
  assert.equal(item.status, 'manual_review');
  assert.equal(item.reason, 'outcome_unknown');
});

test('expired, disabled, and phone-less subscribers are handled like the app', () => {
  const now = START * 1000;
  const events = dueEvents([
    subscriber(1, localEnd(-2)),
    subscriber(2, localEnd(-80)),
    subscriber(3, localEnd(10), { disabled: true }),
    subscriber(4, localEnd(10), { phone: '' }),
    subscriber(5, localEnd(10), { active: false }),
    subscriber(6, localEnd(100)),
    { ...subscriber(7, localEnd(10)), subscriberId: 'not-a-uuid' },
  ], now, 180);
  assert.deepEqual(events.map((event) => [event.subscriberId.slice(-1), event.eventType]), [
    ['1', 'subscription_expired'],
  ]);
});

test('subscribers are re-read only when their revision changes', async () => {
  const env = setup({ subscribers: [subscriber(1, localEnd(100))] });
  const reads = [];
  const store = new FirebaseNoticeStore(env.database);
  const originalRead = store.read.bind(store);
  store.read = (path) => {
    reads.push(path);
    return originalRead(path);
  };
  const scheduler = env.makeScheduler();
  scheduler.store = store;

  await scheduler.run();
  await scheduler.run();
  assert.equal(reads.filter((path) => path.endsWith('/subscribers')).length, 1);

  env.database._set(`agents/${UID}/settings/subscribersRevision`, 2);
  await scheduler.run();
  assert.equal(reads.filter((path) => path.endsWith('/subscribers')).length, 2);
});
