'use strict';

// خدمة «مشترك نت» داخل البوابة (قرار D7). مطفأة افتراضياً، ولا تلمس أي مسار قائم.
// كل ما تكتبه تحت العقدة الجديدة subscriberPortal/، وتقرأ من agents/** فقط.
// العقد الكامل في C:\Mushtaraknet\docs\SUBSCRIBER_API.md.

const crypto = require('node:crypto');
const express = require('express');

const PORTAL = 'subscriberPortal';
const INVITATION_TTL_MS = 48 * 60 * 60 * 1000;
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 8;
const ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const IDEMPOTENCY_PATTERN = /^[A-Za-z0-9_-]{8,128}$/;
const OPEN_RENEWAL = new Set(['pending', 'approved', 'processing']);
const LEDGER_TYPES = new Set(['subscription', 'renewal', 'payment', 'debt', 'settlement', 'discount', 'addition']);
const CONNECTIONS = new Set(['online', 'offline', 'unknown']);
const MAX_LEDGER_ENTRIES = 40;

class PortalError extends Error {
  constructor(status, code, message = '') {
    super(message || code);
    this.status = status;
    this.code = code;
  }
}

const fail = (status, code, message) => {
  throw new PortalError(status, code, message);
};

function normalizePhone(value) {
  let phone = String(value || '').replace(/\D/g, '');
  if (phone.startsWith('00')) phone = phone.slice(2);
  if (phone.startsWith('9640')) phone = `964${phone.slice(4)}`;
  else if (phone.startsWith('0')) phone = `964${phone.slice(1)}`;
  else if (phone.length === 10 && phone.startsWith('7')) phone = `964${phone}`;
  return phone;
}

function normalizeCode(value) {
  return String(value || '').toUpperCase().replace(/[\s-]/g, '');
}

function text(value, max = 120) {
  return typeof value === 'string' ? value.trim().slice(0, max) : '';
}

function amount(value) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n) : 0;
}

function isoOrNull(value) {
  if (typeof value !== 'string' || !value.trim()) return null;
  return Number.isNaN(Date.parse(value)) ? null : value.trim().slice(0, 40);
}

function listOf(value) {
  if (!value) return [];
  return Array.isArray(value) ? value.filter(Boolean) : Object.values(value).filter(Boolean);
}

function entriesOf(value) {
  return value && typeof value === 'object' ? Object.entries(value) : [];
}

function requireId(value) {
  const id = String(value || '');
  if (!ID_PATTERN.test(id)) fail(400, 'validation_failed');
  return id;
}

function sanitizeLedgerEntry(entry) {
  if (!entry || typeof entry !== 'object') return null;
  const id = String(entry.id || '');
  const date = isoOrNull(entry.date);
  if (!ID_PATTERN.test(id) || !date) return null;
  return {
    id,
    date,
    type: LEDGER_TYPES.has(entry.type) ? entry.type : 'addition',
    amount: amount(entry.amount),
    description: text(entry.description),
    balance_after: entry.balance_after === null || entry.balance_after === undefined
      ? null
      : amount(entry.balance_after),
    pending: entry.pending === true,
  };
}

// الملخص يحسبه تطبيق الوكيل بكود Dart نفسه (D5-ب)؛ الخادم يقبل الحقول المعروفة فقط.
function sanitizeSummary(body, nowIso) {
  if (!body || typeof body !== 'object') fail(400, 'validation_failed');
  const finance = body.finance && typeof body.finance === 'object' ? body.finance : null;
  return {
    subscriber_name: text(body.subscriber_name),
    package_name: text(body.package_name),
    speed_label: text(body.speed_label, 40),
    price: amount(body.price),
    start_date: isoOrNull(body.start_date),
    end_date: isoOrNull(body.end_date),
    disabled: body.disabled === true,
    connection: CONNECTIONS.has(body.connection) ? body.connection : 'unknown',
    last_synced_at: isoOrNull(body.last_synced_at) || nowIso,
    finance: finance
      ? {
          balance_due: amount(finance.balance_due),
          total_charges: amount(finance.total_charges),
          total_paid: amount(finance.total_paid),
          entries: listOf(finance.entries)
            .slice(0, MAX_LEDGER_ENTRIES)
            .map(sanitizeLedgerEntry)
            .filter(Boolean),
        }
      : null,
    updated_at: nowIso,
  };
}

function createSubscriberPortal({
  db,
  pepper,
  now = Date.now,
  randomBytes = crypto.randomBytes,
  isAgentEligible = async () => true,
}) {
  if (typeof pepper !== 'string' || pepper.length < 32) {
    throw new Error('SUBSCRIBER_PORTAL_PEPPER must be at least 32 characters.');
  }
  let sequence = 0;

  const iso = () => new Date(now()).toISOString();
  const hash = (value) => crypto.createHash('sha256').update(`${pepper}:${value}`).digest('hex');
  const shortHash = (value) => hash(value).slice(0, 24);
  // مرتّبة زمنياً: الوقت + عدّاد + عشوائي، فالترتيب بالمعرّف ترتيب بالإنشاء.
  const newId = () => {
    sequence = (sequence + 1) % 1679616;
    return `${now().toString(36).padStart(9, '0')}${sequence.toString(36).padStart(4, '0')}${randomBytes(6).toString('hex')}`;
  };
  const newCode = () => {
    let code = '';
    while (code.length < CODE_LENGTH) {
      for (const byte of randomBytes(CODE_LENGTH * 2)) {
        // رفض القيم خارج المضاعف الكامل حتى يبقى التوزيع منتظماً.
        if (byte < CODE_ALPHABET.length * 8 && code.length < CODE_LENGTH) {
          code += CODE_ALPHABET[byte % CODE_ALPHABET.length];
        }
      }
    }
    return code;
  };
  const maskPhone = (phone) => `${'•'.repeat(Math.max(phone.length - 2, 4))}${phone.slice(-2)}`;
  const linkIdFor = (agentUid, subscriberId) => shortHash(`link/${agentUid}/${subscriberId}`);
  const packageIdFor = (name) => shortHash(`package/${name}`).slice(0, 16);

  const paths = {
    agentInvitations: (agentUid) => `${PORTAL}/agents/${agentUid}/invitations`,
    invitation: (agentUid, id) => `${PORTAL}/agents/${agentUid}/invitations/${id}`,
    invitationIndex: (codeHash) => `${PORTAL}/invitationIndex/${codeHash}`,
    record: (agentUid, subscriberId) => `${PORTAL}/recordIndex/${agentUid}/${subscriberId}`,
    agentRecords: (agentUid) => `${PORTAL}/recordIndex/${agentUid}`,
    links: (accountId) => `${PORTAL}/links/${accountId}`,
    link: (accountId, linkId) => `${PORTAL}/links/${accountId}/${linkId}`,
    summary: (agentUid, subscriberId) => `${PORTAL}/summaries/${agentUid}/${subscriberId}`,
    settings: (agentUid) => `${PORTAL}/agents/${agentUid}/settings`,
    renewal: (agentUid, id) => `${PORTAL}/agents/${agentUid}/renewalRequests/${id}`,
    agentRenewals: (agentUid) => `${PORTAL}/agents/${agentUid}/renewalRequests`,
    openRenewal: (agentUid, subscriberId) => `${PORTAL}/agents/${agentUid}/openRenewals/${subscriberId}`,
    renewalCounter: (agentUid) => `${PORTAL}/agents/${agentUid}/renewalCounter`,
    renewalKey: (accountId, keyHash) => `${PORTAL}/renewalKeys/${accountId}/${keyHash}`,
    accountRenewals: (accountId) => `${PORTAL}/renewalsByAccount/${accountId}`,
    notifications: (accountId) => `${PORTAL}/notifications/${accountId}`,
    notification: (accountId, id) => `${PORTAL}/notifications/${accountId}/${id}`,
  };

  async function findRecord(agentUid, subscriberId) {
    const subscribers = listOf(await db.get(`agents/${agentUid}/subscribers`));
    return subscribers.find((s) => s && s.subscriberId === subscriberId) || null;
  }

  async function officeOf(agentUid) {
    const [settings, portalSettings] = await Promise.all([
      db.get(`agents/${agentUid}/settings`),
      db.get(paths.settings(agentUid)),
    ]);
    return {
      id: shortHash(`agent/${agentUid}`).slice(0, 16),
      office_name: text(settings?.officeName) || 'مكتب الوكيل',
      phone: text(settings?.officePhone, 30),
      address: text(settings?.officeAddress),
      show_debt: portalSettings?.showDebt === true,
      allow_package_change: false,
      lastSasSync: isoOrNull(settings?.lastSasSync),
    };
  }

  // --- الدعوات ---

  async function createInvitation(agentUid, subscriberIdInput) {
    const subscriberId = requireId(subscriberIdInput);
    const record = await findRecord(agentUid, subscriberId);
    if (!record) fail(404, 'subscription_not_found');
    const phone = normalizePhone(record.phone);
    if (phone.length < 10) fail(422, 'phone_missing');
    if (await db.get(paths.record(agentUid, subscriberId))) fail(409, 'record_already_linked');

    const patch = {};
    for (const [id, invitation] of entriesOf(await db.get(paths.agentInvitations(agentUid)))) {
      if (invitation.subscriberId === subscriberId && invitation.status === 'pending') {
        patch[`agents/${agentUid}/invitations/${id}/status`] = 'cancelled';
      }
    }
    const id = newId();
    const code = newCode();
    const token = randomBytes(18).toString('base64url');
    const createdAt = now();
    const invitation = {
      subscriberId,
      phoneHash: hash(`phone/${phone}`),
      codeHash: hash(`code/${code}`),
      tokenHash: hash(`token/${token}`),
      status: 'pending',
      createdAt: new Date(createdAt).toISOString(),
      expiresAt: new Date(createdAt + INVITATION_TTL_MS).toISOString(),
    };
    patch[`agents/${agentUid}/invitations/${id}`] = invitation;
    patch[`invitationIndex/${invitation.codeHash}`] = { agentUid, id };
    patch[`invitationIndex/${invitation.tokenHash}`] = { agentUid, id };
    await db.update(PORTAL, patch);
    return {
      id,
      subscriber_id: subscriberId,
      subscriber_name: text(record.name),
      code,
      link_token: token,
      masked_phone: maskPhone(phone),
      status: 'pending',
      expires_at: invitation.expiresAt,
    };
  }

  function invitationView(id, invitation) {
    const expired = invitation.status === 'pending' && Date.parse(invitation.expiresAt) <= now();
    return {
      id,
      subscriber_id: invitation.subscriberId,
      status: expired ? 'expired' : invitation.status,
      created_at: invitation.createdAt,
      expires_at: invitation.expiresAt,
      redeemed_at: invitation.redeemedAt || null,
    };
  }

  async function listInvitations(agentUid) {
    return entriesOf(await db.get(paths.agentInvitations(agentUid)))
      .map(([id, invitation]) => invitationView(id, invitation))
      .sort((a, b) => (a.id < b.id ? 1 : -1));
  }

  async function cancelInvitation(agentUid, idInput) {
    const id = requireId(idInput);
    let state = null;
    const result = await db.transaction(paths.invitation(agentUid, id), (current) => {
      state = current ? current.status : null;
      // null في أول استدعاء يعني «لا نسخة محلية» لا «غير موجود»: كتابة فارغة
      // يعيدها Firebase بالقيمة الحقيقية. undefined تُلغي المعاملة نهائياً.
      if (!current) return null;
      if (current.status !== 'pending') return undefined;
      return { ...current, status: 'cancelled' };
    });
    if (!state) fail(404, 'not_found');
    if (!result.committed) fail(409, 'invalid_state');
    return invitationView(id, result.value);
  }

  function checkInvitationUsable(invitation, accountId = null) {
    if (invitation.status === 'cancelled') fail(410, 'invitation_cancelled');
    if (invitation.status === 'redeemed') {
      if (accountId && invitation.redeemedBy === accountId) return;
      fail(409, 'invitation_used');
    }
    if (invitation.status !== 'pending') fail(404, 'invalid_code');
    if (Date.parse(invitation.expiresAt) <= now()) fail(410, 'invitation_expired');
  }

  async function resolveInvitation(input) {
    const raw = String(input || '').trim();
    if (!raw || raw.length > 64) fail(404, 'invalid_code');
    const candidates = [hash(`code/${normalizeCode(raw)}`), hash(`token/${raw}`)];
    for (const codeHash of candidates) {
      const pointer = await db.get(paths.invitationIndex(codeHash));
      if (!pointer) continue;
      const invitation = await db.get(paths.invitation(pointer.agentUid, pointer.id));
      if (invitation) return { agentUid: pointer.agentUid, id: pointer.id, invitation };
    }
    return fail(404, 'invalid_code');
  }

  async function validateInvitation(code) {
    const { agentUid, invitation } = await resolveInvitation(code);
    checkInvitationUsable(invitation);
    const record = await findRecord(agentUid, invitation.subscriberId);
    if (!record) fail(404, 'invalid_code');
    const office = await officeOf(agentUid);
    return {
      code: normalizeCode(code).length === CODE_LENGTH ? normalizeCode(code) : '',
      office_name: office.office_name,
      masked_phone: maskPhone(normalizePhone(record.phone)),
      expires_at: invitation.expiresAt,
    };
  }

  // يربط حساباً قائماً بالسجل الذي تحدده الدعوة؛ المعرّفات لا تأتي من العميل أبداً.
  async function linkExisting(identity, code) {
    const { agentUid, id, invitation } = await resolveInvitation(code);
    checkInvitationUsable(invitation, identity.accountId);
    const phone = normalizePhone(identity.phone);
    if (phone && hash(`phone/${phone}`) !== invitation.phoneHash) fail(403, 'phone_mismatch');
    const { subscriberId } = invitation;
    const linkedAt = iso();

    let claimedNow = false;
    const claim = await db.transaction(paths.record(agentUid, subscriberId), (current) => {
      if (current && current.accountId !== identity.accountId) return undefined;
      claimedNow = !current;
      return current || { accountId: identity.accountId, linkedAt };
    });
    if (!claim.committed) fail(409, 'record_already_linked');

    let redeemState = null;
    const redeem = await db.transaction(paths.invitation(agentUid, id), (current) => {
      redeemState = current ? current.status : null;
      if (!current) return null; // انظر cancelInvitation: ليست «غير موجودة».
      if (current.status === 'redeemed' && current.redeemedBy === identity.accountId) {
        return current;
      }
      if (current.status !== 'pending' || Date.parse(current.expiresAt) <= now()) {
        return undefined;
      }
      return { ...current, status: 'redeemed', redeemedAt: linkedAt, redeemedBy: identity.accountId };
    });
    if (!redeem.committed || !redeem.value) {
      if (claimedNow) await db.set(paths.record(agentUid, subscriberId), null);
      if (redeemState === 'redeemed') fail(409, 'invitation_used');
      if (redeemState === 'cancelled') fail(410, 'invitation_cancelled');
      fail(410, 'invitation_expired');
    }

    const linkId = linkIdFor(agentUid, subscriberId);
    await db.set(paths.link(identity.accountId, linkId), {
      agentUid,
      subscriberId,
      linkedAt: claim.value.linkedAt,
    });
    return { subscription_id: linkId };
  }

  // --- الاشتراك والمالية ---

  async function linksOf(accountId) {
    return entriesOf(await db.get(paths.links(accountId)));
  }

  async function getLink(accountId, subscriptionId) {
    const links = await linksOf(accountId);
    if (links.length === 0) fail(404, 'subscription_not_found');
    if (!subscriptionId) return { linkId: links[0][0], ...links[0][1] };
    const found = links.find(([linkId]) => linkId === subscriptionId);
    if (!found) fail(404, 'subscription_not_found');
    return { linkId: found[0], ...found[1] };
  }

  async function loadSubscription(link) {
    const [summary, office] = await Promise.all([
      db.get(paths.summary(link.agentUid, link.subscriberId)),
      officeOf(link.agentUid),
    ]);
    const { lastSasSync, ...agent } = office;
    let fields;
    if (summary) {
      fields = {
        subscriber_name: summary.subscriber_name,
        package_name: summary.package_name,
        speed_label: summary.speed_label || null,
        price: summary.price,
        start_date: summary.start_date,
        end_date: summary.end_date,
        disabled: summary.disabled === true,
        connection: summary.connection || 'unknown',
        last_synced_at: summary.last_synced_at,
      };
    } else {
      // قبل أول ملخص من تطبيق الوكيل: الحقول الأساسية من السجل فقط، بلا مالية.
      const record = await findRecord(link.agentUid, link.subscriberId);
      if (!record) return null;
      fields = {
        subscriber_name: text(record.name),
        package_name: text(record.type),
        speed_label: null,
        price: amount(record.price),
        start_date: isoOrNull(record.startDate),
        end_date: isoOrNull(record.endDate),
        disabled: record.disabled === true,
        connection: 'unknown',
        last_synced_at: lastSasSync || link.linkedAt,
      };
    }
    // التطبيق لا يقبل تاريخاً فارغاً؛ السجل بلا تواريخ يظهر بتاريخ الربط.
    fields.start_date = fields.start_date || link.linkedAt;
    fields.end_date = fields.end_date || fields.start_date;
    fields.last_synced_at = fields.last_synced_at || link.linkedAt;
    return {
      subscription: {
        id: link.linkId,
        agent,
        line_label: '',
        package_id: packageIdFor(fields.package_name),
        note: '',
        ...fields,
      },
      summary,
      showDebt: agent.show_debt,
    };
  }

  async function subscriptionFor(accountId, subscriptionId) {
    const link = await getLink(accountId, subscriptionId);
    const loaded = await loadSubscription(link);
    if (!loaded) fail(404, 'subscription_not_found');
    return { link, ...loaded };
  }

  async function me(identity) {
    const subscriptions = [];
    let firstLinkedAt = iso();
    for (const [linkId, link] of await linksOf(identity.accountId)) {
      if (link.linkedAt && link.linkedAt < firstLinkedAt) firstLinkedAt = link.linkedAt;
      const loaded = await loadSubscription({ linkId, ...link });
      if (loaded) subscriptions.push(loaded.subscription);
    }
    return {
      account: { id: identity.accountId, name: '', phone: identity.phone || '', created_at: firstLinkedAt },
      subscriptions,
    };
  }

  function sortedEntries(summary) {
    return [...(summary?.finance?.entries || [])].sort((a, b) =>
      a.date === b.date ? (a.id < b.id ? 1 : -1) : a.date < b.date ? 1 : -1,
    );
  }

  function financeOf({ summary, showDebt }) {
    if (!showDebt || !summary?.finance) {
      return {
        visible: false,
        balance_due: 0,
        total_charges: 0,
        total_paid: 0,
        last_payment: null,
        updated_at: summary?.updated_at || iso(),
      };
    }
    return {
      visible: true,
      balance_due: summary.finance.balance_due,
      total_charges: summary.finance.total_charges,
      total_paid: summary.finance.total_paid,
      last_payment: sortedEntries(summary).find((e) => e.type === 'payment') || null,
      updated_at: summary.updated_at,
    };
  }

  async function financeSummary(accountId, subscriptionId) {
    return financeOf(await subscriptionFor(accountId, subscriptionId));
  }

  async function transactions(accountId, { subscriptionId, limit, cursor, type }) {
    const loaded = await subscriptionFor(accountId, subscriptionId);
    if (!financeOf(loaded).visible) return { items: [], next_cursor: null };
    let items = sortedEntries(loaded.summary);
    if (type) items = items.filter((e) => e.type === type);
    const size = Math.min(Math.max(Number(limit) || 20, 1), 50);
    const start = Math.max(Number(cursor) || 0, 0);
    const page = items.slice(start, start + size);
    return { items: page, next_cursor: start + size < items.length ? String(start + size) : null };
  }

  async function packages(accountId, subscriptionId) {
    const { subscription } = await subscriptionFor(accountId, subscriptionId);
    // D6-أ: نفس الباقة فقط في الإصدار الأول.
    return [
      {
        id: subscription.package_id,
        name: subscription.package_name,
        speed_label: subscription.speed_label,
        duration_days: 30,
        price: subscription.price,
        description: '',
        is_current: true,
        requestable: true,
      },
    ];
  }

  // --- الإشعارات ---

  async function notify(accountId, { kind, title, body, important = false, subscriptionId = '', target = null }) {
    const id = newId();
    await db.set(paths.notification(accountId, id), {
      kind,
      title,
      body,
      created_at: iso(),
      read: false,
      important,
      subscription_id: subscriptionId,
      target,
    });
  }

  async function notifications(accountId, limit = 50) {
    return entriesOf(await db.get(paths.notifications(accountId)))
      .sort((a, b) => (a[0] < b[0] ? 1 : -1))
      .slice(0, limit)
      .map(([id, n]) => ({ id, ...n }));
  }

  async function unreadCount(accountId) {
    return { count: entriesOf(await db.get(paths.notifications(accountId))).filter(([, n]) => !n.read).length };
  }

  async function markRead(accountId, idInput) {
    const id = requireId(idInput);
    if (!(await db.get(paths.notification(accountId, id)))) fail(404, 'not_found');
    await db.set(`${paths.notification(accountId, id)}/read`, true);
    return null;
  }

  async function markAllRead(accountId) {
    const patch = {};
    for (const [id, n] of entriesOf(await db.get(paths.notifications(accountId)))) {
      if (!n.read) patch[`${id}/read`] = true;
    }
    if (Object.keys(patch).length) await db.update(paths.notifications(accountId), patch);
    return null;
  }

  // --- التجديد ---

  function renewalView(id, r) {
    return {
      id,
      number: r.number,
      subscription_id: r.linkId,
      package_id: r.packageId,
      package_name: r.packageName,
      quoted_price: r.quotedPrice,
      status: r.status,
      created_at: r.createdAt,
      updated_at: r.updatedAt,
      history: listOf(r.history),
      reject_reason: r.rejectReason || '',
      new_end_date: r.newEndDate || null,
    };
  }

  function agentRenewalView(id, r) {
    return {
      ...renewalView(id, r),
      subscriber_id: r.subscriberId,
      subscriber_name: r.subscriberName,
      // تطبيق الوكيل يعتبر التجديد منفّذاً حين يتقدّم تاريخ الانتهاء عن هذا.
      previous_end_date: r.previousEndDate || null,
    };
  }

  async function renewalByKey(accountId, keyHash) {
    const pointer = await db.get(paths.renewalKey(accountId, keyHash));
    if (!pointer) return null;
    const request = await db.get(paths.renewal(pointer.agentUid, pointer.id));
    return request ? renewalView(pointer.id, request) : null;
  }

  async function createRenewal(identity, { subscriptionId, packageId, idempotencyKey }) {
    const { accountId } = identity;
    if (!IDEMPOTENCY_PATTERN.test(String(idempotencyKey || ''))) fail(400, 'validation_failed');
    const keyHash = hash(`renewal-key/${idempotencyKey}`).slice(0, 32);
    const existing = await renewalByKey(accountId, keyHash);
    if (existing) return existing;

    const { link, subscription } = await subscriptionFor(accountId, requireId(subscriptionId));
    if (String(packageId || '') !== subscription.package_id) fail(400, 'validation_failed');
    if (!(await isAgentEligible(link.agentUid))) fail(409, 'agent_unavailable');

    const id = newId();
    const lock = await db.transaction(paths.openRenewal(link.agentUid, link.subscriberId), (current) =>
      current ? undefined : id,
    );
    if (!lock.committed) {
      const raced = await renewalByKey(accountId, keyHash);
      if (raced) return raced;
      fail(409, 'renewal_in_progress');
    }
    const counter = await db.transaction(paths.renewalCounter(link.agentUid), (n) => (Number(n) || 0) + 1);
    const at = iso();
    const request = {
      number: `R-${1000 + counter.value}`,
      accountId,
      linkId: link.linkId,
      subscriberId: link.subscriberId,
      subscriberName: subscription.subscriber_name,
      packageId: subscription.package_id,
      packageName: subscription.package_name,
      // السعر من بيانات الوكيل، وأي سعر يرسله التطبيق يُتجاهل.
      quotedPrice: subscription.price,
      previousEndDate: subscription.end_date,
      status: 'pending',
      createdAt: at,
      updatedAt: at,
      history: [{ status: 'pending', at, note: '' }],
      rejectReason: '',
      newEndDate: null,
    };
    await db.update(PORTAL, {
      [`agents/${link.agentUid}/renewalRequests/${id}`]: request,
      [`renewalKeys/${accountId}/${keyHash}`]: { agentUid: link.agentUid, id },
      [`renewalsByAccount/${accountId}/${id}`]: { agentUid: link.agentUid },
    });
    await notify(accountId, {
      kind: 'renewalReceived',
      title: 'وصل طلب التجديد',
      body: `طلبك ${request.number} لباقة ${request.packageName} وصل إلى ${subscription.agent.office_name}.`,
      subscriptionId: link.linkId,
      target: { kind: 'renewal', id },
    });
    return renewalView(id, request);
  }

  async function accountRenewal(accountId, idInput) {
    const id = requireId(idInput);
    const pointer = await db.get(`${paths.accountRenewals(accountId)}/${id}`);
    if (!pointer) fail(404, 'not_found');
    const request = await db.get(paths.renewal(pointer.agentUid, id));
    if (!request || request.accountId !== accountId) fail(404, 'not_found');
    return { id, agentUid: pointer.agentUid, request };
  }

  async function listRenewals(accountId, subscriptionId) {
    const items = [];
    for (const [id, pointer] of entriesOf(await db.get(paths.accountRenewals(accountId)))) {
      const request = await db.get(paths.renewal(pointer.agentUid, id));
      if (request && (!subscriptionId || request.linkId === subscriptionId)) {
        items.push(renewalView(id, request));
      }
    }
    return items.sort((a, b) => (a.id < b.id ? 1 : -1));
  }

  async function getRenewal(accountId, id) {
    const found = await accountRenewal(accountId, id);
    return renewalView(found.id, found.request);
  }

  async function openRenewalFor(accountId, link) {
    const id = await db.get(paths.openRenewal(link.agentUid, link.subscriberId));
    if (!id) return null;
    const request = await db.get(paths.renewal(link.agentUid, id));
    return request && request.accountId === accountId ? renewalView(id, request) : null;
  }

  // انتقال حالة ذري. allowed: الحالات التي يُسمح بالانتقال منها.
  async function transition(agentUid, id, allowed, status, extra = {}, note = '') {
    let previous = null;
    const result = await db.transaction(paths.renewal(agentUid, id), (current) => {
      previous = current ? current.status : null;
      if (!current) return null; // انظر cancelInvitation: ليست «غير موجودة».
      if (!allowed.includes(current.status)) return undefined;
      const at = iso();
      return {
        ...current,
        ...extra,
        status,
        updatedAt: at,
        history: [...listOf(current.history), { status, at, note }],
      };
    });
    if (!previous) fail(404, 'not_found');
    if (!result.committed) fail(409, 'invalid_state');
    const request = result.value;
    if (!OPEN_RENEWAL.has(status)) {
      await db.transaction(paths.openRenewal(agentUid, request.subscriberId), (current) =>
        current === null || current === id ? null : undefined,
      );
    }
    return request;
  }

  async function cancelRenewal(accountId, idInput) {
    const { id, agentUid } = await accountRenewal(accountId, idInput);
    const request = await transition(agentUid, id, ['pending'], 'cancelled');
    return renewalView(id, request);
  }

  async function listAgentRenewals(agentUid, status) {
    return entriesOf(await db.get(paths.agentRenewals(agentUid)))
      .filter(([, r]) => !status || r.status === status)
      .map(([id, r]) => agentRenewalView(id, r))
      .sort((a, b) => (a.id < b.id ? 1 : -1));
  }

  async function decideRenewal(agentUid, idInput, { decision, reason }) {
    const id = requireId(idInput);
    if (decision === 'approve') {
      const request = await transition(agentUid, id, ['pending'], 'approved');
      await notify(request.accountId, {
        kind: 'renewalApproved',
        title: 'وافق الوكيل على طلبك',
        body: `طلب ${request.number} مقبول، وسيُفعَّل اشتراكك قريباً.`,
        subscriptionId: request.linkId,
        target: { kind: 'renewal', id },
      });
      return agentRenewalView(id, request);
    }
    if (decision === 'reject') {
      const why = text(reason, 200);
      if (!why) fail(400, 'validation_failed');
      const request = await transition(agentUid, id, ['pending', 'approved'], 'rejected', { rejectReason: why }, why);
      await notify(request.accountId, {
        kind: 'renewalRejected',
        title: 'رُفض طلب التجديد',
        body: why,
        important: true,
        subscriptionId: request.linkId,
        target: { kind: 'renewal', id },
      });
      return agentRenewalView(id, request);
    }
    return fail(400, 'validation_failed');
  }

  // يُستدعى من تطبيق الوكيل بعد التفعيل الفعلي فقط؛ لا يوجد «مكتمل» بلا تفعيل.
  async function renewalResult(agentUid, idInput, { result, newEndDate, note }) {
    const id = requireId(idInput);
    if (result === 'completed') {
      const end = isoOrNull(newEndDate);
      if (!end) fail(400, 'validation_failed');
      const request = await transition(agentUid, id, ['pending', 'approved', 'processing'], 'completed', { newEndDate: end }, text(note, 200));
      await notify(request.accountId, {
        kind: 'renewalCompleted',
        title: 'تم تجديد اشتراكك',
        body: `اشتراكك الجديد ساري حتى ${end.slice(0, 10)}.`,
        important: true,
        subscriptionId: request.linkId,
        target: { kind: 'renewal', id },
      });
      return agentRenewalView(id, request);
    }
    if (result === 'failed') {
      const request = await transition(agentUid, id, ['pending', 'approved', 'processing'], 'failed', {}, text(note, 200));
      await notify(request.accountId, {
        kind: 'system',
        title: 'تعذّر تنفيذ التجديد',
        body: `لم يكتمل طلب ${request.number}. تواصل مع وكيلك.`,
        important: true,
        subscriptionId: request.linkId,
        target: { kind: 'renewal', id },
      });
      return agentRenewalView(id, request);
    }
    return fail(400, 'validation_failed');
  }

  // --- ملخصات وروابط الوكيل ---

  async function putSummary(agentUid, subscriberIdInput, body) {
    const subscriberId = requireId(subscriberIdInput);
    if (!(await db.get(paths.record(agentUid, subscriberId)))) fail(409, 'not_linked');
    const summary = sanitizeSummary(body, iso());
    await db.set(paths.summary(agentUid, subscriberId), summary);
    return { updated_at: summary.updated_at };
  }

  async function listAgentLinks(agentUid) {
    return entriesOf(await db.get(paths.agentRecords(agentUid))).map(([subscriberId, r]) => ({
      subscriber_id: subscriberId,
      linked_at: r.linkedAt,
    }));
  }

  async function unlink(agentUid, subscriberIdInput) {
    const subscriberId = requireId(subscriberIdInput);
    const record = await db.get(paths.record(agentUid, subscriberId));
    if (!record) fail(404, 'not_linked');
    const linkId = linkIdFor(agentUid, subscriberId);
    await db.update(PORTAL, {
      [`recordIndex/${agentUid}/${subscriberId}`]: null,
      [`links/${record.accountId}/${linkId}`]: null,
      [`summaries/${agentUid}/${subscriberId}`]: null,
    });
    return null;
  }

  async function getSettings(agentUid) {
    const settings = await db.get(paths.settings(agentUid));
    return { show_debt: settings?.showDebt === true };
  }

  async function putSettings(agentUid, body) {
    if (!body || typeof body.show_debt !== 'boolean') fail(400, 'validation_failed');
    await db.update(paths.settings(agentUid), { showDebt: body.show_debt });
    return getSettings(agentUid);
  }

  async function home(accountId, subscriptionId) {
    const loaded = await subscriptionFor(accountId, subscriptionId);
    return {
      subscription: loaded.subscription,
      finance: financeOf(loaded),
      notifications: await notifications(accountId, 5),
      open_renewal: await openRenewalFor(accountId, loaded.link),
    };
  }

  return {
    createInvitation,
    listInvitations,
    cancelInvitation,
    validateInvitation,
    linkExisting,
    me,
    home,
    subscription: async (accountId, id) => (await subscriptionFor(accountId, id)).subscription,
    packages,
    financeSummary,
    transactions,
    notifications,
    unreadCount,
    markRead,
    markAllRead,
    createRenewal,
    listRenewals,
    getRenewal,
    cancelRenewal,
    listAgentRenewals,
    decideRenewal,
    renewalResult,
    putSummary,
    listAgentLinks,
    unlink,
    getSettings,
    putSettings,
  };
}

function createSubscriberPortalRouter({
  portal,
  requireAgent,
  authenticateSubscriber,
  publicRateLimit = (_req, _res, next) => next(),
  accountRateLimit = (_req, _res, next) => next(),
}) {
  const router = express.Router();

  const handle = (fn) => async (req, res) => {
    try {
      const data = await fn(req);
      res.status(200).json({ success: true, data: data === undefined ? null : data });
    } catch (error) {
      if (error instanceof PortalError) {
        return res.status(error.status).json({ success: false, error: error.code });
      }
      const requestId = crypto.randomBytes(6).toString('hex');
      console.error(`subscriber portal error ${requestId}:`, error?.message || error);
      return res.status(500).json({ success: false, error: 'server_error', request_id: requestId });
    }
  };

  async function requireSubscriber(req, res, next) {
    if (typeof authenticateSubscriber !== 'function') {
      return res.status(503).json({ success: false, error: 'auth_not_configured' });
    }
    let identity;
    try {
      identity = await authenticateSubscriber(req);
    } catch (_) {
      identity = null;
    }
    if (!identity || !ID_PATTERN.test(String(identity.accountId || ''))) {
      return res.status(401).json({ success: false, error: 'unauthorized' });
    }
    req.subscriber = { accountId: identity.accountId, phone: identity.phone || '' };
    req.agentUid = undefined;
    req.rateKey = `subscriber:${identity.accountId}`;
    return next();
  }

  const account = (req) => req.subscriber.accountId;
  const sub = [requireSubscriber, accountRateLimit];

  // --- مسارات الوكيل (توكن وكيل نت + فحص R1 الحالي) ---
  router.post('/agent/subscriber-invitations', requireAgent, handle((req) =>
    portal.createInvitation(req.agentUid, req.body?.subscriber_id)));
  router.get('/agent/subscriber-invitations', requireAgent, handle((req) =>
    portal.listInvitations(req.agentUid)));
  router.post('/agent/subscriber-invitations/:id/cancel', requireAgent, handle((req) =>
    portal.cancelInvitation(req.agentUid, req.params.id)));
  router.get('/agent/subscriber-links', requireAgent, handle((req) =>
    portal.listAgentLinks(req.agentUid)));
  router.delete('/agent/subscriber-links/:subscriberId', requireAgent, handle((req) =>
    portal.unlink(req.agentUid, req.params.subscriberId)));
  router.put('/agent/subscriber-summaries/:subscriberId', requireAgent, handle((req) =>
    portal.putSummary(req.agentUid, req.params.subscriberId, req.body)));
  router.get('/agent/portal-settings', requireAgent, handle((req) =>
    portal.getSettings(req.agentUid)));
  router.put('/agent/portal-settings', requireAgent, handle((req) =>
    portal.putSettings(req.agentUid, req.body)));
  router.get('/agent/renewal-requests', requireAgent, handle((req) =>
    portal.listAgentRenewals(req.agentUid, typeof req.query.status === 'string' ? req.query.status : '')));
  router.post('/agent/renewal-requests/:id/decision', requireAgent, handle((req) =>
    portal.decideRenewal(req.agentUid, req.params.id, req.body || {})));
  router.post('/agent/renewal-requests/:id/result', requireAgent, handle((req) =>
    portal.renewalResult(req.agentUid, req.params.id, {
      result: req.body?.result,
      newEndDate: req.body?.new_end_date,
      note: req.body?.note,
    })));

  // --- مسارات المشترك ---
  router.post('/subscriber/invitations/validate', publicRateLimit, handle((req) =>
    portal.validateInvitation(req.body?.code)));
  router.post('/subscriber/account/link-existing', ...sub, handle((req) =>
    portal.linkExisting(req.subscriber, req.body?.code)));
  router.get('/me', ...sub, handle((req) => portal.me(req.subscriber)));

  const subscriptionId = (req) =>
    typeof req.query.subscription_id === 'string' ? req.query.subscription_id : '';
  router.get('/subscriber/home', ...sub, handle((req) => portal.home(account(req), subscriptionId(req))));
  router.get('/subscriber/subscription', ...sub, handle((req) =>
    portal.subscription(account(req), subscriptionId(req))));
  router.get('/subscriber/packages', ...sub, handle((req) => portal.packages(account(req), subscriptionId(req))));
  router.get('/subscriber/finance/summary', ...sub, handle((req) =>
    portal.financeSummary(account(req), subscriptionId(req))));
  router.get('/subscriber/finance/transactions', ...sub, handle((req) =>
    portal.transactions(account(req), {
      subscriptionId: subscriptionId(req),
      limit: req.query.limit,
      cursor: req.query.cursor,
      type: typeof req.query.type === 'string' ? req.query.type : '',
    })));
  router.post('/subscriber/renewals', ...sub, handle((req) =>
    portal.createRenewal(req.subscriber, {
      subscriptionId: req.body?.subscription_id,
      packageId: req.body?.package_id,
      idempotencyKey: req.headers['idempotency-key'],
    })));
  router.get('/subscriber/renewals', ...sub, handle((req) =>
    portal.listRenewals(account(req), subscriptionId(req))));
  router.get('/subscriber/renewals/:id', ...sub, handle((req) => portal.getRenewal(account(req), req.params.id)));
  router.post('/subscriber/renewals/:id/cancel', ...sub, handle((req) =>
    portal.cancelRenewal(account(req), req.params.id)));
  router.get('/subscriber/notifications', ...sub, handle((req) => portal.notifications(account(req))));
  router.get('/subscriber/notifications/unread-count', ...sub, handle((req) => portal.unreadCount(account(req))));
  router.post('/subscriber/notifications/read-all', ...sub, handle((req) => portal.markAllRead(account(req))));
  router.post('/subscriber/notifications/:id/read', ...sub, handle((req) =>
    portal.markRead(account(req), req.params.id)));

  return router;
}

module.exports = {
  createSubscriberPortal,
  createSubscriberPortalRouter,
  normalizeCode,
  sanitizeSummary,
  PortalError,
};
