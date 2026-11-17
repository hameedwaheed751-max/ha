'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const express = require('express');
const { MemoryDb } = require('./portal_db');
const {
  createSubscriberPortal,
  createSubscriberPortalRouter,
  normalizeCode,
} = require('./subscriber_portal');

const START = Date.parse('2026-11-15T10:00:00Z');
const HOUR = 60 * 60 * 1000;

function seed() {
  return {
    agents: {
      'agent-a': {
        settings: { officeName: 'مكتب النور', officePhone: '07700000001', officeAddress: 'بغداد' },
        subscribers: [
          {
            subscriberId: 'sub-1',
            name: 'علي حسن',
            phone: '0770 123 4567',
            type: 'Fiber 50',
            price: 35000,
            startDate: '2026-11-01T00:00:00.000',
            endDate: '2026-12-01T00:00:00.000',
            disabled: false,
            notes: 'ملاحظة داخلية',
            user: 'ali.sas',
            sasData: { password: 'x' },
          },
          { subscriberId: 'sub-2', name: 'بلا هاتف', phone: '' },
        ],
      },
      'agent-b': {
        settings: { officeName: 'مكتب آخر' },
        subscribers: [{ subscriberId: 'sub-9', name: 'غريب', phone: '07800000000', type: 'X', price: 1 }],
      },
    },
  };
}

function setup({ eligible = () => true, withAuth = true, accountAdmin, notifyAgent } = {}) {
  const db = new MemoryDb(seed());
  let clock = START;
  const portal = createSubscriberPortal({
    db,
    pepper: 'p'.repeat(32),
    now: () => clock,
    isAgentEligible: async (uid) => eligible(uid),
    accountAdmin,
    notifyAgent,
  });
  const app = express();
  app.use(express.json());
  const requireAgent = (req, res, next) => {
    const uid = req.headers['x-agent'];
    if (!uid) return res.status(401).json({ success: false, error: 'unauthorized' });
    req.agentUid = uid;
    return next();
  };
  const authenticateSubscriber = withAuth
    ? async (req) =>
        req.headers['x-account']
          ? { accountId: req.headers['x-account'], phone: req.headers['x-phone'] || '' }
          : null
    : null;
  app.use('/api/v1', createSubscriberPortalRouter({ portal, requireAgent, authenticateSubscriber }));
  return { db, app, portal, advance: (ms) => { clock += ms; } };
}

async function withServer(app, action) {
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, path, { agent, account, phone, body, key } = {}) => {
    const headers = { 'content-type': 'application/json' };
    if (agent) headers['x-agent'] = agent;
    if (account) headers['x-account'] = account;
    if (phone) headers['x-phone'] = phone;
    if (key) headers['idempotency-key'] = key;
    const res = await fetch(`${base}/api/v1${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: res.status, json: await res.json().catch(() => null) };
  };
  try {
    await action(call);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function invite(call, subscriberId = 'sub-1', agent = 'agent-a') {
  const res = await call('POST', '/agent/subscriber-invitations', {
    agent,
    body: { subscriber_id: subscriberId },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  return res.json.data;
}

async function linkAccount(call, account = 'acc-1') {
  const inv = await invite(call);
  const res = await call('POST', '/subscriber/account/link-existing', {
    account,
    body: { code: inv.code },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  const me = await call('GET', '/me', { account });
  return me.json.data.subscriptions[0];
}

test('codes normalise case, spaces and dashes', () => {
  assert.equal(normalizeCode(' ab-cd 2345 '), 'ABCD2345');
});

test('an invitation is returned once and only its hashes are stored', async () => {
  const { app, db } = setup();
  await withServer(app, async (call) => {
    const inv = await invite(call);
    assert.match(inv.code, /^[A-Z2-9]{8}$/);
    assert.ok(inv.link_token.length >= 22);
    assert.equal(inv.masked_phone.endsWith('67'), true);
    assert.equal(inv.masked_phone.includes('123'), false);
    const stored = JSON.stringify(await db.get('subscriberPortal'));
    assert.equal(stored.includes(inv.code), false);
    assert.equal(stored.includes(inv.link_token), false);
    assert.equal(stored.includes('7701234567'), false);
  });
});

test('agents can only invite their own subscribers, and only ones with a phone', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const other = await call('POST', '/agent/subscriber-invitations', {
      agent: 'agent-a',
      body: { subscriber_id: 'sub-9' },
    });
    assert.equal(other.status, 404);
    assert.equal(other.json.error, 'subscription_not_found');
    const noPhone = await call('POST', '/agent/subscriber-invitations', {
      agent: 'agent-a',
      body: { subscriber_id: 'sub-2' },
    });
    assert.equal(noPhone.json.error, 'phone_missing');
    const bad = await call('POST', '/agent/subscriber-invitations', {
      agent: 'agent-a',
      body: { subscriber_id: '../x' },
    });
    assert.equal(bad.json.error, 'validation_failed');
  });
});

test('validation reveals only the office name and masked phone', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const inv = await invite(call);
    const typed = inv.code.toLowerCase().replace(/(.{4})/, '$1 ');
    for (const code of [typed, inv.link_token]) {
      const res = await call('POST', '/subscriber/invitations/validate', { body: { code } });
      assert.equal(res.status, 200, JSON.stringify(res.json));
      assert.deepEqual(Object.keys(res.json.data).sort(), ['code', 'expires_at', 'masked_phone', 'office_name']);
      assert.equal(res.json.data.office_name, 'مكتب النور');
    }
    const wrong = await call('POST', '/subscriber/invitations/validate', { body: { code: 'ZZZZZZZZ' } });
    assert.equal(wrong.status, 404);
    assert.equal(wrong.json.error, 'invalid_code');
  });
});

test('a new invitation cancels the previous one, and invitations expire after 48 hours', async () => {
  const { app, advance } = setup();
  await withServer(app, async (call) => {
    const first = await invite(call);
    const second = await invite(call);
    const old = await call('POST', '/subscriber/invitations/validate', { body: { code: first.code } });
    assert.equal(old.json.error, 'invitation_cancelled');
    advance(48 * HOUR + 1);
    const late = await call('POST', '/subscriber/invitations/validate', { body: { code: second.code } });
    assert.equal(late.json.error, 'invitation_expired');
  });
});

test('the agent can cancel an invitation and list its invitations without secrets', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const inv = await invite(call);
    const list = await call('GET', '/agent/subscriber-invitations', { agent: 'agent-a' });
    assert.equal(list.json.data.length, 1);
    assert.equal(JSON.stringify(list.json.data).includes('Hash'), false);
    const foreign = await call('POST', `/agent/subscriber-invitations/${inv.id}/cancel`, { agent: 'agent-b' });
    assert.equal(foreign.status, 404);
    const cancel = await call('POST', `/agent/subscriber-invitations/${inv.id}/cancel`, { agent: 'agent-a' });
    assert.equal(cancel.json.data.status, 'cancelled');
    const used = await call('POST', '/subscriber/invitations/validate', { body: { code: inv.code } });
    assert.equal(used.json.error, 'invitation_cancelled');
  });
});

test('linking is one-time, one account per record, and checks a known phone', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const inv = await invite(call);
    const mismatch = await call('POST', '/subscriber/account/link-existing', {
      account: 'acc-x',
      phone: '07809999999',
      body: { code: inv.code },
    });
    assert.equal(mismatch.json.error, 'phone_mismatch');
    const ok = await call('POST', '/subscriber/account/link-existing', {
      account: 'acc-1',
      phone: '+964 770 123 4567',
      body: { code: inv.code },
    });
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
    const again = await call('POST', '/subscriber/account/link-existing', {
      account: 'acc-2',
      body: { code: inv.code },
    });
    assert.equal(again.json.error, 'invitation_used');
    const reinvite = await call('POST', '/agent/subscriber-invitations', {
      agent: 'agent-a',
      body: { subscriber_id: 'sub-1' },
    });
    assert.equal(reinvite.json.error, 'record_already_linked');
  });
});

test('subscriber routes refuse until a sign-in method is configured', async () => {
  const { app } = setup({ withAuth: false });
  await withServer(app, async (call) => {
    const res = await call('GET', '/me', { account: 'acc-1' });
    assert.equal(res.status, 503);
    assert.equal(res.json.error, 'auth_not_configured');
  });
  const configured = setup();
  await withServer(configured.app, async (call) => {
    const res = await call('GET', '/me');
    assert.equal(res.status, 401);
    assert.equal(res.json.error, 'unauthorized');
  });
});

test('a linked subscription shows record basics without internal fields', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    assert.equal(sub.subscriber_name, 'علي حسن');
    assert.equal(sub.package_name, 'Fiber 50');
    assert.equal(sub.price, 35000);
    assert.equal(sub.agent.office_name, 'مكتب النور');
    assert.equal(sub.agent.show_debt, false);
    const text = JSON.stringify(sub);
    for (const secret of ['ali.sas', 'ملاحظة داخلية', 'password', 'agent-a', 'sub-1']) {
      assert.equal(text.includes(secret), false, secret);
    }
    const finance = await call('GET', `/subscriber/finance/summary?subscription_id=${sub.id}`, { account: 'acc-1' });
    assert.equal(finance.json.data.visible, false);
    const stranger = await call('GET', `/subscriber/subscription?subscription_id=${sub.id}`, { account: 'acc-2' });
    assert.equal(stranger.json.error, 'subscription_not_found');
  });
});

test('the agent publishes a sanitised summary only for linked records', async () => {
  const { app, db } = setup();
  await withServer(app, async (call) => {
    const summary = {
      subscriber_name: 'علي',
      package_name: 'Fiber 75',
      speed_label: '75 ميغابت',
      price: 40000,
      start_date: '2026-11-10T00:00:00.000',
      end_date: '2026-12-10T00:00:00.000',
      disabled: false,
      connection: 'online',
      notes: 'يجب ألا يُخزَّن',
      finance: {
        balance_due: 25000,
        total_charges: 75000,
        total_paid: 50000,
        entries: [
          { id: 'e1', date: '2026-11-02T00:00:00.000', type: 'payment', amount: -20000, description: 'دفعة' },
          { id: 'e2', date: '2026-11-10T00:00:00.000', type: 'renewal', amount: 40000, description: 'تجديد', sasData: 1 },
        ],
      },
    };
    const early = await call('PUT', '/agent/subscriber-summaries/sub-1', { agent: 'agent-a', body: summary });
    assert.equal(early.json.error, 'not_linked');
    const sub = await linkAccount(call);
    const put = await call('PUT', '/agent/subscriber-summaries/sub-1', { agent: 'agent-a', body: summary });
    assert.equal(put.status, 200, JSON.stringify(put.json));
    const stored = JSON.stringify(await db.get('subscriberPortal/summaries'));
    assert.equal(stored.includes('يجب ألا'), false);
    assert.equal(stored.includes('sasData'), false);

    const shown = await call('GET', `/subscriber/subscription?subscription_id=${sub.id}`, { account: 'acc-1' });
    assert.equal(shown.json.data.package_name, 'Fiber 75');
    assert.equal(shown.json.data.connection, 'online');
    const hidden = await call('GET', `/subscriber/finance/summary?subscription_id=${sub.id}`, { account: 'acc-1' });
    assert.equal(hidden.json.data.visible, false);
    assert.equal(hidden.json.data.balance_due, 0);

    await call('PUT', '/agent/portal-settings', { agent: 'agent-a', body: { show_debt: true } });
    const visible = await call('GET', `/subscriber/finance/summary?subscription_id=${sub.id}`, { account: 'acc-1' });
    assert.equal(visible.json.data.visible, true);
    assert.equal(visible.json.data.balance_due, 25000);
    assert.equal(visible.json.data.last_payment.id, 'e1');
    const page = await call(
      'GET',
      `/subscriber/finance/transactions?subscription_id=${sub.id}&limit=1`,
      { account: 'acc-1' },
    );
    assert.equal(page.json.data.items[0].id, 'e2');
    assert.ok(page.json.data.next_cursor);
    const next = await call(
      'GET',
      `/subscriber/finance/transactions?subscription_id=${sub.id}&limit=1&cursor=${page.json.data.next_cursor}`,
      { account: 'acc-1' },
    );
    assert.equal(next.json.data.items[0].id, 'e1');
    assert.equal(next.json.data.next_cursor, null);
    const payments = await call(
      'GET',
      `/subscriber/finance/transactions?subscription_id=${sub.id}&type=payment`,
      { account: 'acc-1' },
    );
    assert.deepEqual(payments.json.data.items.map((e) => e.id), ['e1']);
    const links = await call('GET', '/agent/subscriber-links', { agent: 'agent-a' });
    assert.deepEqual(links.json.data.map((l) => l.subscriber_id), ['sub-1']);
  });
});

test('renewals use the server price, need an idempotency key, and allow one open request', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const body = { subscription_id: sub.id, package_id: sub.package_id, price: 1 };
    const noKey = await call('POST', '/subscriber/renewals', { account: 'acc-1', body });
    assert.equal(noKey.json.error, 'validation_failed');
    const other = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-00000000',
      body: { ...body, package_id: 'other' },
    });
    assert.equal(other.json.error, 'validation_failed');
    const first = await call('POST', '/subscriber/renewals', { account: 'acc-1', key: 'key-11111111', body });
    assert.equal(first.status, 200, JSON.stringify(first.json));
    assert.equal(first.json.data.quoted_price, 35000);
    assert.equal(first.json.data.status, 'pending');
    assert.match(first.json.data.number, /^R-\d+$/);
    const repeat = await call('POST', '/subscriber/renewals', { account: 'acc-1', key: 'key-11111111', body });
    assert.equal(repeat.json.data.id, first.json.data.id);
    const second = await call('POST', '/subscriber/renewals', { account: 'acc-1', key: 'key-22222222', body });
    assert.equal(second.json.error, 'renewal_in_progress');
    const list = await call('GET', `/subscriber/renewals?subscription_id=${sub.id}`, { account: 'acc-1' });
    assert.equal(list.json.data.length, 1);
    const home = await call('GET', `/subscriber/home?subscription_id=${sub.id}`, { account: 'acc-1' });
    assert.equal(home.json.data.open_renewal.id, first.json.data.id);
    assert.equal(home.json.data.notifications[0].kind, 'renewalReceived');
  });
});

test('an expired or ineligible agent cannot receive renewal requests', async () => {
  const { app } = setup({ eligible: () => false });
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const res = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-11111111',
      body: { subscription_id: sub.id, package_id: sub.package_id },
    });
    assert.equal(res.json.error, 'agent_unavailable');
  });
});

test('only the owning agent approves, and completed comes only from the agent after activation', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const created = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-11111111',
      body: { subscription_id: sub.id, package_id: sub.package_id },
    });
    const id = created.json.data.id;
    const inbox = await call('GET', '/agent/renewal-requests', { agent: 'agent-a' });
    assert.equal(inbox.json.data[0].subscriber_id, 'sub-1');
    assert.equal(inbox.json.data[0].quoted_price, 35000);
    const foreign = await call('POST', `/agent/renewal-requests/${id}/decision`, {
      agent: 'agent-b',
      body: { decision: 'approve' },
    });
    assert.equal(foreign.status, 404);
    const early = await call('POST', `/agent/renewal-requests/${id}/result`, {
      agent: 'agent-a',
      body: { result: 'completed' },
    });
    assert.equal(early.json.error, 'validation_failed');
    const approve = await call('POST', `/agent/renewal-requests/${id}/decision`, {
      agent: 'agent-a',
      body: { decision: 'approve' },
    });
    assert.equal(approve.json.data.status, 'approved');
    const cancel = await call('POST', `/subscriber/renewals/${id}/cancel`, { account: 'acc-1' });
    assert.equal(cancel.json.error, 'invalid_state');
    const done = await call('POST', `/agent/renewal-requests/${id}/result`, {
      agent: 'agent-a',
      body: { result: 'completed', new_end_date: '2027-01-01T00:00:00.000' },
    });
    assert.equal(done.json.data.status, 'completed');
    const seen = await call('GET', `/subscriber/renewals/${id}`, { account: 'acc-1' });
    assert.equal(seen.json.data.status, 'completed');
    assert.equal(seen.json.data.new_end_date, '2027-01-01T00:00:00.000');
    assert.deepEqual(seen.json.data.history.map((h) => h.status), ['pending', 'approved', 'completed']);
    const again = await call('POST', `/agent/renewal-requests/${id}/result`, {
      agent: 'agent-a',
      body: { result: 'failed' },
    });
    assert.equal(again.json.error, 'invalid_state');
    const next = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-33333333',
      body: { subscription_id: sub.id, package_id: sub.package_id },
    });
    assert.equal(next.status, 200);
    const kinds = (await call('GET', '/subscriber/notifications', { account: 'acc-1' })).json.data.map((n) => n.kind);
    assert.deepEqual(kinds.slice(0, 4), ['renewalReceived', 'renewalCompleted', 'renewalApproved', 'renewalReceived']);
  });
});

test('rejection needs a reason, and a pending request can be cancelled by the subscriber', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const body = { subscription_id: sub.id, package_id: sub.package_id };
    const a = await call('POST', '/subscriber/renewals', { account: 'acc-1', key: 'key-aaaaaaaa', body });
    const noReason = await call('POST', `/agent/renewal-requests/${a.json.data.id}/decision`, {
      agent: 'agent-a',
      body: { decision: 'reject' },
    });
    assert.equal(noReason.json.error, 'validation_failed');
    const rejected = await call('POST', `/agent/renewal-requests/${a.json.data.id}/decision`, {
      agent: 'agent-a',
      body: { decision: 'reject', reason: 'الدفع غير مستلم' },
    });
    assert.equal(rejected.json.data.reject_reason, 'الدفع غير مستلم');
    const b = await call('POST', '/subscriber/renewals', { account: 'acc-1', key: 'key-bbbbbbbb', body });
    assert.equal(b.status, 200);
    const cancelled = await call('POST', `/subscriber/renewals/${b.json.data.id}/cancel`, { account: 'acc-1' });
    assert.equal(cancelled.json.data.status, 'cancelled');
    const stranger = await call('POST', `/subscriber/renewals/${b.json.data.id}/cancel`, { account: 'acc-2' });
    assert.equal(stranger.status, 404);
    const c = await call('POST', '/subscriber/renewals', { account: 'acc-1', key: 'key-cccccccc', body });
    assert.equal(c.status, 200);
  });
});

test('notifications can be counted and marked read', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const body = { subscription_id: sub.id, package_id: sub.package_id };
    const r = await call('POST', '/subscriber/renewals', { account: 'acc-1', key: 'key-aaaaaaaa', body });
    await call('POST', `/subscriber/renewals/${r.json.data.id}/cancel`, { account: 'acc-1' });
    await call('POST', '/subscriber/renewals', { account: 'acc-1', key: 'key-bbbbbbbb', body });
    const count = await call('GET', '/subscriber/notifications/unread-count', { account: 'acc-1' });
    assert.equal(count.json.data.count, 2);
    const list = await call('GET', '/subscriber/notifications', { account: 'acc-1' });
    await call('POST', `/subscriber/notifications/${list.json.data[0].id}/read`, { account: 'acc-1' });
    assert.equal((await call('GET', '/subscriber/notifications/unread-count', { account: 'acc-1' })).json.data.count, 1);
    await call('POST', '/subscriber/notifications/read-all', { account: 'acc-1' });
    assert.equal((await call('GET', '/subscriber/notifications/unread-count', { account: 'acc-1' })).json.data.count, 0);
    const other = await call('GET', '/subscriber/notifications/unread-count', { account: 'acc-2' });
    assert.equal(other.json.data.count, 0);
  });
});

test('the agent can unlink a record, removing the subscriber\'s access', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const res = await call('DELETE', '/agent/subscriber-links/sub-1', { agent: 'agent-a' });
    assert.equal(res.status, 200);
    const me = await call('GET', '/me', { account: 'acc-1' });
    assert.equal(me.json.data.subscriptions.length, 0);
    const gone = await call('GET', `/subscriber/subscription?subscription_id=${sub.id}`, { account: 'acc-1' });
    assert.equal(gone.json.error, 'subscription_not_found');
    const reinvite = await call('POST', '/agent/subscriber-invitations', {
      agent: 'agent-a',
      body: { subscriber_id: 'sub-1' },
    });
    assert.equal(reinvite.status, 200);
  });
});

test('required dates are always ISO strings, because the app cannot parse null', async () => {
  const { app, db } = setup();
  await db.set('agents/agent-a/subscribers/0/startDate', null);
  await db.set('agents/agent-a/subscribers/0/endDate', '');
  await withServer(app, async (call) => {
    await linkAccount(call);
    const me = await call('GET', '/me', { account: 'acc-1' });
    const { account, subscriptions } = me.json.data;
    for (const value of [account.created_at, subscriptions[0].start_date, subscriptions[0].end_date, subscriptions[0].last_synced_at]) {
      assert.equal(typeof value, 'string');
      assert.ok(!Number.isNaN(Date.parse(value)), String(value));
    }
  });
});

test('the agent inbox carries the end date at request time, to detect the real activation', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-11111111',
      body: { subscription_id: sub.id, package_id: sub.package_id },
    });
    const inbox = await call('GET', '/agent/renewal-requests', { agent: 'agent-a' });
    assert.equal(inbox.json.data[0].previous_end_date, '2026-12-01T00:00:00.000');
    const mine = await call('GET', `/subscriber/renewals?subscription_id=${sub.id}`, { account: 'acc-1' });
    assert.equal('previous_end_date' in mine.json.data[0], false);
  });
});

test('the account phone comes from the phone-number sign-in id, never from other emails', () => {
  const { accountPhoneFromToken } = require('./subscriber_portal');
  assert.equal(accountPhoneFromToken({ email: '9647701234567@phone.mushtarak.net' }), '9647701234567');
  assert.equal(accountPhoneFromToken({ email: '9647701234567@PHONE.mushtarak.net' }), '9647701234567');
  assert.equal(accountPhoneFromToken({ phone_number: '+9647701234567' }), '9647701234567');
  assert.equal(accountPhoneFromToken({ email: '9647701234567@gmail.com' }), '');
  assert.equal(accountPhoneFromToken({ email: 'x9647701234567@phone.mushtarak.net' }), '');
  assert.equal(accountPhoneFromToken({}), '');
});

// --- مفتاح خدمة mushtarak-net: استعادة كلمة المرور والإشعار الفوري وتذكير الانتهاء ---

function fakeAccountAdmin({ accounts = { '9647701234567': 'old-pass' } } = {}) {
  const pushes = [];
  return {
    accounts,
    pushes,
    async setPassword(phone, password) {
      if (!(phone in accounts)) return false;
      accounts[phone] = password;
      return true;
    },
    async sendPush(tokens, message) {
      pushes.push({ tokens: [...tokens], ...message });
      return { invalidTokens: tokens.filter((t) => t.startsWith('dead')) };
    },
  };
}

test('a valid invitation and the matching phone reset the password', async () => {
  const accountAdmin = fakeAccountAdmin();
  const { app } = setup({ accountAdmin });
  await withServer(app, async (call) => {
    const inv = await invite(call);
    const wrongPhone = await call('POST', '/subscriber/account/reset-password', {
      body: { code: inv.code, phone: '07809999999', new_password: 'new-pass' },
    });
    assert.equal(wrongPhone.json.error, 'phone_mismatch');
    const short = await call('POST', '/subscriber/account/reset-password', {
      body: { code: inv.code, phone: '07701234567', new_password: '123' },
    });
    assert.equal(short.json.error, 'validation_failed');
    const badCode = await call('POST', '/subscriber/account/reset-password', {
      body: { code: 'ZZZZZZZZ', phone: '07701234567', new_password: 'new-pass' },
    });
    assert.equal(badCode.json.error, 'invalid_code');
    const ok = await call('POST', '/subscriber/account/reset-password', {
      body: { code: inv.code, phone: '0770 123 4567', new_password: 'new-pass' },
    });
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
    assert.equal(accountAdmin.accounts['9647701234567'], 'new-pass');
    // الدعوة نفسها تبقى صالحة للربط بعد الاستعادة.
    const still = await call('POST', '/subscriber/invitations/validate', { body: { code: inv.code } });
    assert.equal(still.status, 200);
  });
});

test('reset refuses phones without an account, and is unavailable without the service key', async () => {
  const accountAdmin = fakeAccountAdmin({ accounts: {} });
  const { app } = setup({ accountAdmin });
  await withServer(app, async (call) => {
    const inv = await invite(call);
    const res = await call('POST', '/subscriber/account/reset-password', {
      body: { code: inv.code, phone: '07701234567', new_password: 'new-pass' },
    });
    assert.equal(res.json.error, 'account_not_found');
  });
  const bare = setup();
  await withServer(bare.app, async (call) => {
    const inv = await invite(call);
    const res = await call('POST', '/subscriber/account/reset-password', {
      body: { code: inv.code, phone: '07701234567', new_password: 'new-pass' },
    });
    assert.equal(res.status, 503);
    assert.equal(res.json.error, 'reset_unavailable');
  });
});

test('devices register per account and every notification is also pushed to them', async () => {
  const accountAdmin = fakeAccountAdmin();
  const { app, db } = setup({ accountAdmin });
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const bad = await call('POST', '/subscriber/devices', { account: 'acc-1', body: { token: 'x' } });
    assert.equal(bad.json.error, 'validation_failed');
    for (const token of ['token-aaaaaaaaaaaaaaaaaaaaaaaa', 'dead-bbbbbbbbbbbbbbbbbbbbbbbb']) {
      const ok = await call('POST', '/subscriber/devices', {
        account: 'acc-1',
        body: { token, platform: 'android' },
      });
      assert.equal(ok.status, 200);
    }
    await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-11111111',
      body: { subscription_id: sub.id, package_id: sub.package_id },
    });
    const push = accountAdmin.pushes.at(-1);
    assert.equal(push.title, 'وصل طلب التجديد');
    assert.equal(push.data.kind, 'renewalReceived');
    assert.equal(push.tokens.length, 2);
    // الرمز الميت يُحذف بعد أول فشل.
    const devices = await db.get('subscriberPortal/devices/acc-1');
    assert.equal(Object.values(devices).some((d) => d.token.startsWith('dead')), false);
    const stored = JSON.stringify(await db.get('subscriberPortal/devices'));
    assert.equal(stored.includes('acc-2'), false);
  });
});

test('expiry reminders go out once at three days and once at expiry, never for an expired agent', async () => {
  const accountAdmin = fakeAccountAdmin();
  let eligible = true;
  const { app, portal, advance } = setup({ accountAdmin, eligible: () => eligible });
  await withServer(app, async (call) => {
    await linkAccount(call);
    await call('POST', '/subscriber/devices', {
      account: 'acc-1',
      body: { token: 'token-aaaaaaaaaaaaaaaaaaaaaaaa' },
    });
    // ينتهي 2026-12-01؛ الآن 2026-11-15: لا تذكير.
    assert.equal(await portal.runExpiryNotices(), 0);
    advance(14 * 24 * HOUR); // 2026-11-29: يومان متبقيان
    assert.equal(await portal.runExpiryNotices(), 1);
    assert.equal(await portal.runExpiryNotices(), 0, 'not twice');
    advance(2 * 24 * HOUR); // 2026-12-01 ظهراً: انتهى قبل ساعات (نافذة يوم، والفحص كل ساعة)
    eligible = false;
    assert.equal(await portal.runExpiryNotices(), 0, 'agent expired: reminders stop');
    eligible = true;
    assert.equal(await portal.runExpiryNotices(), 1);
    const kinds = (await call('GET', '/subscriber/notifications', { account: 'acc-1' })).json.data.map((n) => n.kind);
    assert.deepEqual(kinds, ['expired', 'expirySoon']);
    assert.deepEqual(accountAdmin.pushes.map((p) => p.data.kind), ['expirySoon', 'expired']);
  });
});

// --- فك الارتباط: يغلق الطلب المفتوح، ويُشعر المشترك، ويحدث تلقائياً عند حذف المشترك ---

test('unlinking cancels the open request, releases it for a later link, and tells the subscriber', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const created = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-11111111',
      body: { subscription_id: sub.id, package_id: sub.package_id },
    });
    await call('DELETE', '/agent/subscriber-links/sub-1', { agent: 'agent-a' });
    const inbox = await call('GET', '/agent/renewal-requests', { agent: 'agent-a' });
    assert.equal(inbox.json.data.find((r) => r.id === created.json.data.id).status, 'cancelled');
    const notes = (await call('GET', '/subscriber/notifications', { account: 'acc-1' })).json.data;
    assert.equal(notes[0].kind, 'system');
    assert.equal(notes[0].title, 'انتهى ربط اشتراكك');
    // ربط جديد لنفس السجل يستطيع طلب التجديد (لا قفل معلّق).
    const again = await linkAccount(call, 'acc-1');
    const renew = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-22222222',
      body: { subscription_id: again.id, package_id: again.package_id },
    });
    assert.equal(renew.status, 200, JSON.stringify(renew.json));
  });
});

test('a subscriber removed by the agent loses access and is told, even with a published summary', async () => {
  const { app, db } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    await call('PUT', '/agent/subscriber-summaries/sub-1', {
      agent: 'agent-a',
      body: { subscriber_name: 'علي', package_name: 'Fiber 50', price: 35000, end_date: '2026-12-01T00:00:00.000' },
    });
    // الوكيل حذف المشترك؛ بقي مشترك آخر في القائمة.
    await db.set('agents/agent-a/subscribers', [{ subscriberId: 'sub-2', name: 'بلا هاتف', phone: '' }]);
    const me = await call('GET', '/me', { account: 'acc-1' });
    assert.equal(me.json.data.subscriptions.length, 0);
    const gone = await call('GET', `/subscriber/subscription?subscription_id=${sub.id}`, { account: 'acc-1' });
    assert.equal(gone.json.error, 'subscription_not_found');
    const notes = (await call('GET', '/subscriber/notifications', { account: 'acc-1' })).json.data;
    assert.equal(notes[0].title, 'انتهى ربط اشتراكك');
    assert.equal(notes.filter((n) => n.title === 'انتهى ربط اشتراكك').length, 1, 'told once');
    const links = await call('GET', '/agent/subscriber-links', { agent: 'agent-a' });
    assert.deepEqual(links.json.data, []);
  });
});

test('an empty subscriber list never unlinks anyone (could be a bad save, not deletions)', async () => {
  const { app, db } = setup();
  await withServer(app, async (call) => {
    await linkAccount(call);
    await call('PUT', '/agent/subscriber-summaries/sub-1', {
      agent: 'agent-a',
      body: { subscriber_name: 'علي', package_name: 'Fiber 50', price: 35000, end_date: '2026-12-01T00:00:00.000' },
    });
    await db.set('agents/agent-a/subscribers', null);
    const me = await call('GET', '/me', { account: 'acc-1' });
    assert.equal(me.json.data.subscriptions.length, 1);
    const links = await call('GET', '/agent/subscriber-links', { agent: 'agent-a' });
    assert.equal(links.json.data.length, 1);
  });
});

// --- الدعم الفني: تذاكر بين المشترك المربوط ووكيله فقط ---

async function openTicket(call, sub, account = 'acc-1', description = 'الإنترنت ينقطع مساءً') {
  return call('POST', '/subscriber/support/tickets', {
    account,
    body: { subscription_id: sub.id, category: 'connection', description },
  });
}

test('a linked subscriber opens a ticket that reaches only their agent', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const bad = await call('POST', '/subscriber/support/tickets', {
      account: 'acc-1',
      body: { subscription_id: sub.id, category: 'connection', description: '' },
    });
    assert.equal(bad.json.error, 'validation_failed');
    const created = await openTicket(call, sub);
    assert.equal(created.status, 200, JSON.stringify(created.json));
    const t = created.json.data;
    assert.match(t.number, /^T-\d+$/);
    assert.equal(t.status, 'open');
    assert.equal(t.category, 'connection');
    assert.equal(t.messages[0].from_subscriber, true);
    assert.equal(t.messages[0].text, 'الإنترنت ينقطع مساءً');
    const mine = await call('GET', '/subscriber/support/tickets', { account: 'acc-1' });
    assert.equal(mine.json.data.length, 1);
    const stranger = await call('GET', `/subscriber/support/tickets/${t.id}`, { account: 'acc-2' });
    assert.equal(stranger.status, 404);
    const inbox = await call('GET', '/agent/support-tickets', { agent: 'agent-a' });
    assert.equal(inbox.json.data[0].subscriber_name, 'علي حسن');
    assert.equal(inbox.json.data[0].subscriber_id, 'sub-1');
    const other = await call('GET', '/agent/support-tickets', { agent: 'agent-b' });
    assert.deepEqual(other.json.data, []);
  });
});

test('the agent replies and the subscriber is notified; a reply from the subscriber reopens it', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const t = (await openTicket(call, sub)).json.data;
    const foreign = await call('POST', `/agent/support-tickets/${t.id}/messages`, {
      agent: 'agent-b',
      body: { text: 'رد' },
    });
    assert.equal(foreign.status, 404);
    const reply = await call('POST', `/agent/support-tickets/${t.id}/messages`, {
      agent: 'agent-a',
      body: { text: 'سنفحص الخط اليوم' },
    });
    assert.equal(reply.json.data.status, 'answered');
    const seen = (await call('GET', `/subscriber/support/tickets/${t.id}`, { account: 'acc-1' })).json.data;
    assert.equal(seen.messages[1].from_subscriber, false);
    assert.equal(seen.messages[1].author, 'مكتب النور');
    const note = (await call('GET', '/subscriber/notifications', { account: 'acc-1' })).json.data[0];
    assert.equal(note.kind, 'supportReply');
    assert.deepEqual(note.target, { kind: 'ticket', id: t.id });
    const back = await call('POST', `/subscriber/support/tickets/${t.id}/messages`, {
      account: 'acc-1',
      body: { text: 'شكراً، ما زال ينقطع' },
    });
    assert.equal(back.json.data.status, 'open');
    assert.equal(back.json.data.messages.length, 3);
  });
});

test('closed tickets accept no more messages, and open tickets per subscriber are limited', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const t = (await openTicket(call, sub)).json.data;
    const closed = await call('POST', `/agent/support-tickets/${t.id}/close`, { agent: 'agent-a' });
    assert.equal(closed.json.data.status, 'closed');
    const late = await call('POST', `/subscriber/support/tickets/${t.id}/messages`, {
      account: 'acc-1',
      body: { text: 'مرحباً' },
    });
    assert.equal(late.json.error, 'invalid_state');
    for (let i = 0; i < 5; i += 1) assert.equal((await openTicket(call, sub)).status, 200);
    const sixth = await openTicket(call, sub);
    assert.equal(sixth.json.error, 'too_many_tickets');
    const open = await call('GET', '/agent/support-tickets?status=open', { agent: 'agent-a' });
    assert.equal(open.json.data.length, 5);
  });
});

test('the agent master account from office settings reaches the subscriber', async () => {
  const { app, db } = setup();
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    assert.equal(sub.agent.master_account, '');
    await db.set('agents/agent-a/settings/masterAccount', ' 7012 3456 7890 1234 ');
    const me = await call('GET', '/me', { account: 'acc-1' });
    assert.equal(me.json.data.subscriptions[0].agent.master_account, '7012 3456 7890 1234');
  });
});

// --- حذف الحساب (شرط Google Play): الحساب وروابطه وأجهزته وإشعاراته ---

test('deleting the account removes links, devices and notifications, cancels open requests, and deletes the sign-in', async () => {
  const deleted = [];
  const accountAdmin = { ...fakeAccountAdmin(), deleteUser: async (uid) => deleted.push(uid) };
  const { app, db } = setup({ accountAdmin });
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    await call('POST', '/subscriber/devices', { account: 'acc-1', body: { token: 'token-aaaaaaaaaaaaaaaaaaaaaaaa' } });
    const r = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-11111111',
      body: { subscription_id: sub.id, package_id: sub.package_id },
    });
    const res = await call('DELETE', '/subscriber/account', { account: 'acc-1' });
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.deepEqual(deleted, ['acc-1']);
    assert.deepEqual((await call('GET', '/agent/subscriber-links', { agent: 'agent-a' })).json.data, []);
    const inbox = (await call('GET', '/agent/renewal-requests', { agent: 'agent-a' })).json.data;
    assert.equal(inbox.find((x) => x.id === r.json.data.id).status, 'cancelled');
    for (const node of ['links', 'devices', 'notifications', 'renewalKeys', 'renewalsByAccount', 'ticketsByAccount']) {
      assert.equal(await db.get(`subscriberPortal/${node}/acc-1`), null, node);
    }
    // الوكيل يستطيع دعوة المشترك من جديد لاحقاً.
    const again = await call('POST', '/agent/subscriber-invitations', { agent: 'agent-a', body: { subscriber_id: 'sub-1' } });
    assert.equal(again.status, 200);
  });
});

test('deleting an account with no links still deletes the sign-in, and needs a signed-in subscriber', async () => {
  const deleted = [];
  const { app } = setup({ accountAdmin: { ...fakeAccountAdmin(), deleteUser: async (uid) => deleted.push(uid) } });
  await withServer(app, async (call) => {
    assert.equal((await call('DELETE', '/subscriber/account')).status, 401);
    const res = await call('DELETE', '/subscriber/account', { account: 'acc-9' });
    assert.equal(res.status, 200);
    assert.deepEqual(deleted, ['acc-9']);
  });
});

// --- إشعار الوكيل الفوري (عبر agent_notifications) ---

function recordAgentPushes({ fail = false } = {}) {
  const pushes = [];
  return {
    pushes,
    notifyAgent: async (uid, message) => {
      if (fail) throw new Error('should never be called with a throwing notifier');
      pushes.push({ uid, ...message });
    },
  };
}

test('the agent is notified of a new renewal, a new ticket and a subscriber reply', async () => {
  const recorder = recordAgentPushes();
  const { app } = setup({ notifyAgent: recorder.notifyAgent });
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const renewal = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-11111111',
      body: { subscription_id: sub.id, package_id: sub.package_id },
    });
    assert.equal(renewal.status, 200);
    const [first] = recorder.pushes;
    assert.equal(first.uid, 'agent-a');
    assert.equal(first.title, 'طلب تجديد جديد');
    assert.match(first.body, /علي حسن/);
    assert.deepEqual(first.data, { kind: 'renewal', id: renewal.json.data.id });

    const ticket = await openTicket(call, sub);
    assert.equal(recorder.pushes[1].title, 'تذكرة دعم جديدة');
    assert.match(recorder.pushes[1].body, /الإنترنت ينقطع مساءً/);
    assert.deepEqual(recorder.pushes[1].data, { kind: 'ticket', id: ticket.json.data.id });

    await call('POST', `/subscriber/support/tickets/${ticket.json.data.id}/messages`, {
      account: 'acc-1',
      body: { text: 'ما زال ينقطع' },
    });
    assert.equal(recorder.pushes[2].title, 'رد جديد من مشترك');
    assert.equal(recorder.pushes.length, 3);
    assert.ok(recorder.pushes.every((p) => p.uid === 'agent-a'));
  });
});

// --- إعلان الوكيل لمشتركيه ---

test('an agent announcement reaches every linked subscriber, with limits', async () => {
  const accountAdmin = fakeAccountAdmin();
  const { app, advance } = setup({ accountAdmin });
  await withServer(app, async (call) => {
    const none = await call('POST', '/agent/announcements', { agent: 'agent-a', body: { text: 'صيانة الليلة' } });
    assert.equal(none.status, 200);
    assert.equal(none.json.data.recipients, 0);
    await linkAccount(call);
    await call('POST', '/subscriber/devices', {
      account: 'acc-1',
      body: { token: 'token-aaaaaaaaaaaaaaaaaaaaaaaa', platform: 'android' },
    });
    const empty = await call('POST', '/agent/announcements', { agent: 'agent-a', body: { text: '  ' } });
    assert.equal(empty.json.error, 'validation_failed');
    const long = await call('POST', '/agent/announcements', { agent: 'agent-a', body: { text: 'x'.repeat(501) } });
    assert.equal(long.json.error, 'validation_failed');
    const sent = await call('POST', '/agent/announcements', {
      agent: 'agent-a',
      body: { text: 'انقطاع للصيانة من 2 إلى 4 فجراً' },
    });
    assert.equal(sent.status, 200, JSON.stringify(sent.json));
    assert.equal(sent.json.data.recipients, 1);
    const list = await call('GET', '/subscriber/notifications', { account: 'acc-1' });
    const message = list.json.data.find((n) => n.kind === 'agentMessage');
    assert.equal(message.title, 'مكتب النور');
    assert.equal(message.body, 'انقطاع للصيانة من 2 إلى 4 فجراً');
    assert.equal(message.important, true);
    assert.equal(accountAdmin.pushes.at(-1).title, 'مكتب النور');
    // مشتركو الوكيل الآخر لا يصلهم شيء.
    const other = await call('POST', '/agent/announcements', { agent: 'agent-b', body: { text: 'عرض' } });
    assert.equal(other.json.data.recipients, 0);
    // ثلاثة إعلانات في اليوم كحد أقصى.
    await call('POST', '/agent/announcements', { agent: 'agent-a', body: { text: 'ثانٍ' } });
    const limited = await call('POST', '/agent/announcements', { agent: 'agent-a', body: { text: 'رابع' } });
    assert.equal(limited.status, 429);
    assert.equal(limited.json.error, 'too_many_announcements');
    advance(25 * HOUR);
    const tomorrow = await call('POST', '/agent/announcements', { agent: 'agent-a', body: { text: 'غداً' } });
    assert.equal(tomorrow.status, 200);
    const history = await call('GET', '/agent/announcements', { agent: 'agent-a' });
    assert.equal(history.json.data[0].text, 'غداً');
    assert.equal(history.json.data.length, 4);
  });
});

// --- تغيير الباقة ---

test('subscribers see the agent catalog and may request another package only when allowed', async () => {
  const recorder = recordAgentPushes();
  const { app } = setup({ notifyAgent: recorder.notifyAgent });
  await withServer(app, async (call) => {
    const sub = await linkAccount(call);
    const badCatalog = await call('PUT', '/agent/portal-packages', { agent: 'agent-a', body: { packages: 'x' } });
    assert.equal(badCatalog.json.error, 'validation_failed');
    const catalog = await call('PUT', '/agent/portal-packages', {
      agent: 'agent-a',
      body: {
        packages: [
          { name: 'Fiber 50', price: 35000 },
          { name: 'Fiber 100', price: 50000 },
          { name: '  ', price: 1 },
        ],
      },
    });
    assert.equal(catalog.status, 200, JSON.stringify(catalog.json));

    let packages = (await call('GET', `/subscriber/packages?subscription_id=${sub.id}`, { account: 'acc-1' })).json.data;
    assert.deepEqual(packages.map((p) => [p.name, p.is_current, p.requestable]), [
      ['Fiber 50', true, true],
      ['Fiber 100', false, false],
    ]);
    const other = packages.find((p) => p.name === 'Fiber 100');
    const refused = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-11111111',
      body: { subscription_id: sub.id, package_id: other.id },
    });
    assert.equal(refused.json.error, 'validation_failed');

    const settings = await call('PUT', '/agent/portal-settings', { agent: 'agent-a', body: { allow_package_change: true } });
    assert.deepEqual(settings.json.data, { show_debt: false, allow_package_change: true });
    const me = await call('GET', '/me', { account: 'acc-1' });
    assert.equal(me.json.data.subscriptions[0].agent.allow_package_change, true);
    packages = (await call('GET', `/subscriber/packages?subscription_id=${sub.id}`, { account: 'acc-1' })).json.data;
    assert.equal(packages.find((p) => p.name === 'Fiber 100').requestable, true);

    const changed = await call('POST', '/subscriber/renewals', {
      account: 'acc-1',
      key: 'key-22222222',
      body: { subscription_id: sub.id, package_id: other.id },
    });
    assert.equal(changed.status, 200, JSON.stringify(changed.json));
    assert.equal(changed.json.data.package_name, 'Fiber 100');
    assert.equal(changed.json.data.quoted_price, 50000);
    const inbox = await call('GET', '/agent/renewal-requests', { agent: 'agent-a' });
    assert.equal(inbox.json.data[0].current_package_name, 'Fiber 50');
    assert.equal(inbox.json.data[0].package_change, true);
    assert.equal(recorder.pushes.at(-1).title, 'طلب تغيير باقة');
    assert.match(recorder.pushes.at(-1).body, /Fiber 50.*Fiber 100/);
  });
});

test('the old settings call with only show_debt still works', async () => {
  const { app } = setup();
  await withServer(app, async (call) => {
    const res = await call('PUT', '/agent/portal-settings', { agent: 'agent-a', body: { show_debt: true } });
    assert.deepEqual(res.json.data, { show_debt: true, allow_package_change: false });
    const bad = await call('PUT', '/agent/portal-settings', { agent: 'agent-a', body: {} });
    assert.equal(bad.json.error, 'validation_failed');
  });
});
