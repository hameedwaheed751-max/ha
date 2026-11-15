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

function setup({ eligible = () => true, withAuth = true } = {}) {
  const db = new MemoryDb(seed());
  let clock = START;
  const portal = createSubscriberPortal({
    db,
    pepper: 'p'.repeat(32),
    now: () => clock,
    isAgentEligible: async (uid) => eligible(uid),
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
  return { db, app, advance: (ms) => { clock += ms; } };
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
