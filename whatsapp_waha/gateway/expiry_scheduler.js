'use strict';

// Sends the "expires in 3 days" and "just expired" WhatsApp notices from the
// server, so they no longer depend on an agent keeping the app open.
//
// The app and this scheduler share one record per notice under
// agents/{uid}/notificationAutomation/expiry3days, with the same keys and the
// same lease/claim transactions as lib/services/auto_notification_service.dart.
// Whoever claims a notice first sends it; nobody sends a notice marked sent.

const crypto = require('node:crypto');

const NEAR_EXPIRY_EVENT = 'expiry_3days';
const EXPIRED_EVENT = 'subscription_expired';
const NEAR_EXPIRY_WINDOW_MS = 72 * 60 * 60 * 1000;
const EXPIRED_NOTICE_WINDOW_MS = 3 * 24 * 60 * 60 * 1000;
const SUBSCRIBER_ID_PATTERN =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

// Copies of the app's default templates (AppStore in lib/models.dart).
const NEAR_EXPIRY_TEMPLATE =
  'مرحباً {{customer_name}}،\n⏳ نود إعلامكم بأن اشتراك الإنترنت سينتهي قريباً.\n📦 الباقة: {{package_name}}\n📅 تاريخ الانتهاء: {{subscription_end}}\nلضمان استمرار الخدمة دون انقطاع، يرجى مراجعة:\n🏢 {{agent_name}}\n📱 {{whatsapp_number}}\n\nشكراً لاختياركم خدمتنا.';
const EXPIRED_TEMPLATE =
  'مرحباً {name}، اشتراكك لدى {office} منتهي. يرجى التجديد لاستمرار الخدمة.';

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function normalizePhone(value) {
  let phone = String(value || '').replace(/\D/g, '');
  if (phone.startsWith('00')) phone = phone.slice(2);
  if (phone.startsWith('9640')) phone = `964${phone.slice(4)}`;
  if (phone.startsWith('0')) phone = `964${phone.slice(1)}`;
  if (phone.length === 10 && phone.startsWith('7')) phone = `964${phone}`;
  return phone;
}

/**
 * Parses a date the way Dart's DateTime.tryParse does and returns microseconds
 * since the epoch. Dates without a zone are local to the agent's device, which
 * is `utcOffsetMinutes` ahead of UTC.
 */
function parseDartDateMicros(value, utcOffsetMinutes) {
  if (typeof value !== 'string') return null;
  const match =
    /^([+-]?\d{4,6})-?(\d\d)-?(\d\d)(?:[T ](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?\s*(Z|[+-]\d\d(?::?\d\d)?)?)?$/i
      .exec(value.trim());
  if (!match) return null;
  const [, year, month, day, hour = '0', minute = '0', second = '0', fraction = '', zone] = match;
  const digits = fraction.slice(0, 6).padEnd(6, '0');
  const fieldsMs = Date.UTC(
    Number(year),
    Number(month) - 1,
    Number(day),
    Number(hour),
    Number(minute),
    Number(second),
  );
  if (!Number.isFinite(fieldsMs)) return null;
  let offsetMinutes = utcOffsetMinutes;
  if (zone) {
    if (zone.toUpperCase() === 'Z') {
      offsetMinutes = 0;
    } else {
      const sign = zone[0] === '-' ? -1 : 1;
      const zoneDigits = zone.slice(1).replace(':', '');
      offsetMinutes = sign * (Number(zoneDigits.slice(0, 2)) * 60 + Number(zoneDigits.slice(2) || 0));
    }
  }
  return (fieldsMs - offsetMinutes * 60000) * 1000 + Number(digits);
}

function formatLocalDate(micros, utcOffsetMinutes) {
  const date = new Date(Math.floor(micros / 1000) + utcOffsetMinutes * 60000);
  const day = String(date.getUTCDate()).padStart(2, '0');
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  return `${day}/${month}/${date.getUTCFullYear()}`;
}

function eventFor(subscriberId, eventType, endMicros) {
  const digest = sha256(`${subscriberId}|${eventType}|${endMicros}`);
  return {
    subscriberId,
    eventType,
    endDateMicros: endMicros,
    storageKey: digest,
    eventId: `${eventType}:${digest}`,
  };
}

function asList(value) {
  if (Array.isArray(value)) return value.filter(Boolean);
  if (value && typeof value === 'object') return Object.values(value).filter(Boolean);
  return [];
}

/** Notices due now, oldest end date first, as the app orders them. */
function dueEvents(rawSubscribers, nowMicros, utcOffsetMinutes) {
  const seen = new Set();
  const events = [];
  for (const raw of asList(rawSubscribers)) {
    if (typeof raw !== 'object') continue;
    const subscriberId = String(raw.subscriberId || '').trim();
    if (!SUBSCRIBER_ID_PATTERN.test(subscriberId) || seen.has(subscriberId)) continue;
    seen.add(subscriberId);
    if (!normalizePhone(raw.phone)) continue;
    const endMicros = parseDartDateMicros(raw.endDate, utcOffsetMinutes);
    if (endMicros === null) continue;

    const remainingMs = (endMicros - nowMicros) / 1000;
    const active = raw.active !== false;
    const disabled = raw.disabled === true;
    let eventType = null;
    if (active && !disabled && remainingMs > 0 && remainingMs <= NEAR_EXPIRY_WINDOW_MS) {
      eventType = NEAR_EXPIRY_EVENT;
    } else if (!disabled && remainingMs <= 0 && -remainingMs <= EXPIRED_NOTICE_WINDOW_MS) {
      eventType = EXPIRED_EVENT;
    }
    if (eventType) events.push({ ...eventFor(subscriberId, eventType, endMicros), subscriber: raw });
  }
  events.sort((left, right) =>
    left.endDateMicros - right.endDateMicros ||
    (left.subscriberId < right.subscriberId ? -1 : left.subscriberId > right.subscriberId ? 1 : 0));
  return events;
}

function packageDisplay(raw) {
  const keys = ['profile_name', 'profile', 'package_name', 'package', 'plan_name', 'service_name'];
  const find = (node) => {
    if (Array.isArray(node)) {
      for (const item of node) {
        const found = find(item);
        if (typeof found === 'string' && found.trim()) return found;
      }
    } else if (node && typeof node === 'object') {
      for (const key of keys) {
        const value = node[key];
        if (['string', 'number', 'boolean'].includes(typeof value)) {
          const text = String(value).trim();
          if (text) return text;
        } else if (value && typeof value === 'object') {
          const nested = find(value);
          if (typeof nested === 'string' && nested.trim()) return nested;
        }
      }
      for (const value of Object.values(node)) {
        const found = find(value);
        if (typeof found === 'string' && found.trim()) return found;
      }
    }
    return null;
  };
  const found = find(raw.sasData);
  if (typeof found === 'string' && found.trim()) return found.trim();
  const type = String(raw.type || '').trim();
  return type || '—';
}

const PLACEHOLDER_ALIASES = {
  name: ['name', 'customername', 'subscribername', 'الاسم', 'اسم', 'الاسمالمشترك', 'اسمالمشترك', 'اسم_المشترك'],
  package: ['package', 'packagename', 'الباقة', 'اسمالباقة', 'الباقه'],
  startDate: ['startdate', 'subscriptionstart', 'subscriptionstartdate', 'subscriptionstart_', 'subscriptionstartdate_', 'تاريخالبدء', 'بدءالاشتراك', 'تاريخبدايةالاشتراك'],
  endDate: ['enddate', 'expirydate', 'subscriptionend', 'subscriptionenddate', 'subscriptionend_', 'subscriptionenddate_', 'تاريخالانتهاء', 'تاريخالانتهاءالاشتراك', 'تاريخانتهاءالاشتراك', 'انتهاءالاشتراك'],
  price: ['price', 'subscriptionamount', 'مبلغالاشتراك', 'سعرالاشتراك'],
  paid: ['paid', 'paidamount', 'الواصل', 'المبلغالواصل'],
  remaining: ['remaining', 'remainingamount', 'balance', 'المتبقي', 'المتبقى', 'المبلغالمتبقي'],
  amount: ['amount', 'debtamount', 'paymentamount', 'المبلغ', 'مبلغالدين', 'قيمةالدين', 'المبلغالمسدد'],
  date: ['date', 'paymentdate', 'today', 'التاريخ', 'تاريخالتسديد', 'تاريخالدفع'],
  agentName: ['agentname', 'office', 'officename', 'اسمالوكيل', 'اسممكتب', 'اسمالمكتب', 'اسممكتبالاشتراكات'],
  whatsappNumber: ['whatsappnumber', 'phonenumber', 'officephone', 'رقمالواتساب'],
  message: ['message', 'الرسالة', 'النص'],
};

// Mirrors RenderWhatsAppService._valueForPlaceholder.
function valueForPlaceholder(placeholder, variables) {
  const trimmed = placeholder.trim();
  const key = trimmed.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
  const explicit = [...new Set([
    trimmed,
    trimmed.toLowerCase(),
    trimmed.replace(/[^a-zA-Z0-9]+/g, '_').trim().toLowerCase(),
    trimmed.replace(/[^a-zA-Z0-9]+/g, '').trim().toLowerCase(),
  ])].filter(Boolean);
  const filled = (candidate) => {
    const value = variables[candidate];
    return typeof value === 'string' && value.trim() ? value.trim() : null;
  };
  for (const [name, aliases] of Object.entries(PLACEHOLDER_ALIASES)) {
    if (!aliases.includes(key)) continue;
    const candidates = [name, name.replace(/[^a-zA-Z0-9]+/g, '').toLowerCase(), ...explicit];
    for (const candidate of candidates) {
      const value = filled(candidate);
      if (value !== null) return value;
    }
  }
  for (const candidate of explicit) {
    const value = filled(candidate);
    if (value !== null) return value;
  }
  return String(variables[placeholder] || '').trim();
}

// Mirrors RenderWhatsAppService.applyTemplate.
function applyTemplate(template, variables) {
  const explicit = {
    '{{الاسم المشترك}}': variables.name,
    '{{اسم المشترك}}': variables.name,
    '{{الباقة}}': variables.package,
    '{{اسم الباقة}}': variables.package,
    '{{تاريخ بداية الاشتراك}}': variables.startDate,
    '{{تاريخ البدء}}': variables.startDate,
    '{{تاريخ انتهاء الاشتراك}}': variables.endDate,
    '{{تاريخ الانتهاء}}': variables.endDate,
    '{{subscription_start}}': variables.subscription_start || variables.startDate,
    '{{subscription_end}}': variables.subscription_end || variables.endDate,
    '{{مبلغ الاشتراك}}': variables.price,
    '{{المبلغ}}': variables.amount,
    '{{التاريخ}}': variables.date,
    '{{الواصل}}': variables.paid,
    '{{المتبقي}}': variables.remaining,
    '{{اسم الوكيل}}': variables.agentName || variables.office,
  };
  let out = template;
  for (const [placeholder, value] of Object.entries(explicit)) {
    out = out.split(placeholder).join(value || '');
  }
  return out.replace(
    /\{\{\s*([^{}]+?)\s*\}\}|\{\s*([a-zA-Z][^{}]*?)\s*\}/g,
    (_match, double, single) => valueForPlaceholder((double || single || '').trim(), variables),
  );
}

// Mirrors WhatsAppNotificationDispatcher._appendAgentFooter.
function appendAgentFooter(message, agentName, officePhone) {
  const parts = [agentName, officePhone].filter(Boolean);
  if (!parts.length) return message;
  const allDigits = message.replace(/[^0-9]/g, '');
  const officeDigits = officePhone.replace(/[^0-9]/g, '');
  const normalizedOfficePhone = normalizePhone(officePhone);
  const hasPhone =
    (officeDigits && allDigits.includes(officeDigits)) ||
    (normalizedOfficePhone && allDigits.includes(normalizedOfficePhone));
  const hasAgent = agentName && message.includes(agentName);
  if (hasPhone && hasAgent) return message;
  return `${message.trim()}\n🏢 ${parts.join(' • ')}`.trim();
}

function amountText(value) {
  const number = Number(value);
  return (Number.isFinite(number) ? number : 0).toFixed(0);
}

/** Builds the same text the app's dispatcher would send. */
function renderNotice(event, agent, preferenceMessage, nowMicros, utcOffsetMinutes) {
  const raw = event.subscriber;
  const template = preferenceMessage ?? (event.eventType === NEAR_EXPIRY_EVENT
    ? NEAR_EXPIRY_TEMPLATE
    : (agent.expiredTemplate || '').trim() ? agent.expiredTemplate : EXPIRED_TEMPLATE);
  const startMicros = parseDartDateMicros(raw.startDate, utcOffsetMinutes) ?? nowMicros;
  const price = Number(raw.price) || 0;
  const paid = Number(raw.paid) || 0;
  const remaining = (Number(raw.carriedDebt) || 0) + Math.max(price - paid, 0);
  const pkg = packageDisplay(raw);
  const startDate = formatLocalDate(startMicros, utcOffsetMinutes);
  const endDate = formatLocalDate(event.endDateMicros, utcOffsetMinutes);
  const today = formatLocalDate(nowMicros, utcOffsetMinutes);
  const phone = normalizePhone(agent.officePhone);
  const name = String(raw.name || '');
  const variables = {
    name,
    customerName: name,
    customer_name: name,
    user: String(raw.user || ''),
    office: agent.officeName,
    package: pkg,
    package_name: pkg,
    startDate,
    subscription_start: startDate,
    subscription_start_date: startDate,
    endDate,
    subscription_end: endDate,
    subscription_end_date: endDate,
    expiryDate: endDate,
    price: amountText(price),
    subscription_amount: amountText(price),
    paid: amountText(paid),
    paid_amount: amountText(paid),
    remaining: amountText(remaining),
    balance: amountText(remaining),
    remaining_amount: amountText(remaining),
    amount: amountText(remaining),
    debt_amount: amountText(remaining),
    agentName: agent.agentName,
    agent_name: agent.agentName,
    date: today,
    payment_date: today,
    notification_date: today,
    whatsappNumber: phone,
    whatsapp_number: phone,
    message: '',
  };
  return appendAgentFooter(
    applyTemplate(template.trim(), variables).trim(),
    agent.agentName,
    agent.officePhone,
  );
}

function toInt(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.trunc(number) : 0;
}

function asMap(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function retryDelayMs(attempt) {
  const exponent = Math.min(Math.max(attempt - 1, 0), 9);
  return Math.min(360, 2 ** exponent) * 60000;
}

/**
 * The shared notice record, using the same transactions as the app's
 * FirebaseExpiryNotificationStore. `database` is a firebase-admin Database.
 */
class FirebaseNoticeStore {
  constructor(database) {
    this.database = database;
  }

  _queue(uid) {
    return this.database.ref(`agents/${uid}/notificationAutomation/expiry3days`);
  }

  // The SDK may first call `update` with null before it knows the stored value.
  // Aborting then would never reach the server, so a null guess is answered
  // with null: the server retries with the real value, or keeps null unchanged,
  // which is not counted as a commit.
  async _transaction(ref, update) {
    let applied = false;
    const result = await ref.transaction((current) => {
      const next = update(current);
      applied = next !== undefined;
      if (!applied && current === null) return null;
      return next;
    }, undefined, false);
    return result.committed && applied;
  }

  acquireLease(uid, owner, nowMs, leaseMs) {
    return this._transaction(this._queue(uid).child('control'), (current) => {
      const data = asMap(current);
      if (toInt(data.leaseUntil) > nowMs || toInt(data.pauseUntil) > nowMs) return undefined;
      return { ...data, owner, leaseUntil: nowMs + leaseMs };
    });
  }

  renewLease(uid, owner, nowMs, leaseMs) {
    return this._transaction(this._queue(uid).child('control'), (current) => {
      const data = asMap(current);
      if (data.owner !== owner || toInt(data.leaseUntil) <= nowMs) return undefined;
      return { ...data, leaseUntil: nowMs + leaseMs };
    });
  }

  releaseLease(uid, owner) {
    return this._transaction(this._queue(uid).child('control'), (current) => {
      const data = asMap(current);
      if (data.owner !== owner) return undefined;
      return { ...data, owner: null, leaseUntil: 0 };
    });
  }

  pause(uid, owner, untilMs) {
    return this._transaction(this._queue(uid).child('control'), (current) => {
      const data = asMap(current);
      if (data.owner !== owner) return undefined;
      return { ...data, owner: null, leaseUntil: 0, pauseUntil: Math.max(toInt(data.pauseUntil), untilMs) };
    });
  }

  /** Returns the attempt number, or null when the notice is not claimable. */
  async claim(uid, event, owner, nowMs, leaseMs) {
    let attempts = 0;
    let claimed = false;
    const committed = await this._transaction(
      this._queue(uid).child(`items/${event.storageKey}`),
      (current) => {
        const data = asMap(current);
        claimed = false;
        if (
          data.status === 'sent' ||
          data.status === 'manual_review' ||
          toInt(data.retryAt) > nowMs ||
          (data.status === 'sending' && toInt(data.leaseUntil) > nowMs)
        ) {
          return undefined;
        }
        // A sender stopped mid-send, so the message may have gone out.
        if (data.status === 'sending') {
          return {
            status: 'manual_review',
            attempts: toInt(data.attempts),
            endDateMicros: event.endDateMicros,
            reason: 'outcome_unknown',
          };
        }
        claimed = true;
        attempts = toInt(data.attempts) + 1;
        return {
          status: 'sending',
          owner,
          attempts,
          endDateMicros: event.endDateMicros,
          leaseUntil: nowMs + leaseMs,
        };
      },
    );
    return committed && claimed ? attempts : null;
  }

  async finish(uid, event, owner, build) {
    const committed = await this._transaction(
      this._queue(uid).child(`items/${event.storageKey}`),
      (current) => {
        const data = asMap(current);
        if (data.owner !== owner || data.status !== 'sending') return undefined;
        return build(data);
      },
    );
    if (!committed) throw new Error('Could not persist the expiry notice state.');
  }

  async read(path) {
    const snapshot = await this.database.ref(path).once('value');
    return snapshot.val();
  }
}

class ExpiryScheduler {
  constructor({
    store,
    sender,
    listAgentUids,
    sessionNameForUid,
    now = () => Date.now(),
    delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    log = (line) => console.log(line),
    utcOffsetMinutes = 180,
    maxPerAgentPerRun = 10,
    messageDelayMs = 15000,
    leaseMs = 2 * 60 * 1000,
    rateLimitPauseMs = 30 * 60 * 1000,
    agentConcurrency = 4,
  }) {
    Object.assign(this, {
      agentConcurrency,
      store,
      sender,
      listAgentUids,
      sessionNameForUid,
      now,
      delay,
      log,
      utcOffsetMinutes,
      maxPerAgentPerRun,
      messageDelayMs,
      leaseMs,
      rateLimitPauseMs,
    });
    this.subscriberCache = new Map();
    this.activeRun = null;
  }

  run() {
    if (this.activeRun) return this.activeRun;
    this.activeRun = this._runOnce().finally(() => {
      this.activeRun = null;
    });
    return this.activeRun;
  }

  async _runOnce() {
    const totals = { agents: 0, sent: 0, failed: 0 };
    const pending = [...await this.listAgentUids()];
    // Agents send from separate WhatsApp numbers, so a few run side by side.
    const worker = async () => {
      while (pending.length) {
        const uid = pending.shift();
        try {
          const result = await this._processAgent(uid);
          if (result) {
            totals.agents += 1;
            totals.sent += result.sent;
            totals.failed += result.failed;
          }
        } catch (error) {
          totals.failed += 1;
          this.log(`Expiry scheduler: agent run failed (${error?.code || error?.constructor?.name || 'error'})`);
        }
      }
    };
    await Promise.all(Array.from({ length: this.agentConcurrency }, worker));
    if (totals.agents) {
      this.log(`Expiry scheduler: agents=${totals.agents} sent=${totals.sent} failed=${totals.failed}`);
    }
    return totals;
  }

  async _subscribers(uid) {
    const revision = await this.store.read(`agents/${uid}/settings/subscribersRevision`);
    const cached = this.subscriberCache.get(uid);
    if (cached && revision !== null && cached.revision === revision) return cached.subscribers;
    const subscribers = await this.store.read(`agents/${uid}/subscribers`);
    this.subscriberCache.set(uid, { revision, subscribers });
    return subscribers;
  }

  async _preference(uid, eventType) {
    const value = await this.store.read(`agents/${uid}/settings/whatsappNotifications/${eventType}`);
    if (value === null || value === undefined) return { enabled: true, message: null };
    if (typeof value !== 'object') return { enabled: false, message: null };
    const { enabled, message } = value;
    if ((enabled !== undefined && enabled !== null && typeof enabled !== 'boolean') ||
        (message !== undefined && message !== null && typeof message !== 'string')) {
      return { enabled: false, message: null };
    }
    return { enabled: enabled ?? true, message: message ?? null };
  }

  async _agent(uid) {
    const [profile, officeName, officePhone, expiredTemplate] = await Promise.all([
      this.store.read(`agents/${uid}/profile`),
      this.store.read(`agents/${uid}/settings/officeName`),
      this.store.read(`agents/${uid}/settings/officePhone`),
      this.store.read(`agents/${uid}/messageTemplates/expired`),
    ]);
    const data = asMap(profile);
    const text = (value) => (value === null || value === undefined ? '' : String(value).trim());
    const office = text(officeName);
    const fullName = [text(data.firstName), text(data.lastName)].filter(Boolean).join(' ');
    return {
      agentName: text(data.name) || fullName || office,
      officeName: office,
      officePhone: data.phone !== undefined && data.phone !== null ? text(data.phone) : text(officePhone),
      expiredTemplate: typeof expiredTemplate === 'string' ? expiredTemplate : '',
    };
  }

  async _processAgent(uid) {
    const session = this.sessionNameForUid(uid);
    const sessionData = await this.sender.getSession(session);
    if (!sessionData || sessionData.status !== 'WORKING') return null;

    const startMs = this.now();
    let events = dueEvents(await this._subscribers(uid), startMs * 1000, this.utcOffsetMinutes);
    if (!events.length) return null;

    const preferences = {};
    for (const eventType of new Set(events.map((event) => event.eventType))) {
      preferences[eventType] = await this._preference(uid, eventType);
    }
    events = events.filter((event) => preferences[event.eventType].enabled);
    if (!events.length) return null;

    const owner = sha256(`${startMs}:${crypto.randomBytes(16).toString('hex')}`);
    if (!await this.store.acquireLease(uid, owner, startMs, this.leaseMs)) return null;

    const result = { sent: 0, failed: 0 };
    let attempted = 0;
    try {
      const agent = await this._agent(uid);
      for (const event of events) {
        if (attempted >= this.maxPerAgentPerRun) break;
        if (attempted > 0) await this.delay(this.messageDelayMs);
        const nowMs = this.now();
        if (!await this.store.renewLease(uid, owner, nowMs, this.leaseMs)) break;
        const attempt = await this.store.claim(uid, event, owner, nowMs, this.leaseMs);
        if (attempt === null) continue;
        attempted += 1;

        const outcome = await this._send(uid, session, event, agent, preferences, nowMs);
        const finishedAt = this.now();
        if (outcome.status === 200 && outcome.body?.success === true) {
          result.sent += 1;
          const messageId = outcome.body.messageId;
          await this.store.finish(uid, event, owner, (data) => ({
            status: 'sent',
            attempts: toInt(data.attempts),
            endDateMicros: event.endDateMicros,
            sentAt: finishedAt,
            sentBy: 'server',
            ...(messageId ? { messageId } : {}),
          }));
          continue;
        }

        result.failed += 1;
        // A message that may have gone out is never retried automatically.
        const reviewNeeded = outcome.body?.error === 'delivery_outcome_unknown' ||
          (outcome.status === 409 && outcome.body?.error !== 'session_not_connected');
        await this.store.finish(uid, event, owner, (data) => reviewNeeded
          ? {
            status: 'manual_review',
            attempts: toInt(data.attempts),
            endDateMicros: event.endDateMicros,
            statusCode: outcome.status,
          }
          : {
            status: 'retry',
            attempts: toInt(data.attempts),
            endDateMicros: event.endDateMicros,
            retryAt: finishedAt + retryDelayMs(attempt),
            statusCode: outcome.status,
          });
        if (outcome.status === 429) {
          await this.store.pause(uid, owner, finishedAt + this.rateLimitPauseMs);
          break;
        }
        if (outcome.body?.error === 'session_not_connected') break;
      }
    } finally {
      await this.store.releaseLease(uid, owner);
    }
    return result;
  }

  async _send(uid, session, event, agent, preferences, nowMs) {
    const text = renderNotice(
      event,
      agent,
      preferences[event.eventType].message,
      nowMs * 1000,
      this.utcOffsetMinutes,
    );
    try {
      return await this.sender.sendText({
        uid,
        session,
        to: event.subscriber.phone,
        text,
        eventType: event.eventType,
        idempotencyKey: `${event.eventType}:${event.subscriberId}:${event.eventId}`,
      });
    } catch (_) {
      return { status: 500, body: { success: false, error: 'notification_delivery_failed' } };
    }
  }
}

/** Runs the scheduler every `intervalMs`; returns a function that stops it. */
function startExpiryScheduler(scheduler, { intervalMs = 5 * 60 * 1000, firstRunDelayMs = 30000 } = {}) {
  const tick = () => {
    scheduler.run().catch((error) => {
      console.error(`Expiry scheduler run failed (${error?.code || error?.constructor?.name || 'error'})`);
    });
  };
  const first = setTimeout(tick, firstRunDelayMs);
  const interval = setInterval(tick, intervalMs);
  return () => {
    clearTimeout(first);
    clearInterval(interval);
  };
}

module.exports = {
  EXPIRED_EVENT,
  NEAR_EXPIRY_EVENT,
  ExpiryScheduler,
  FirebaseNoticeStore,
  applyTemplate,
  dueEvents,
  eventFor,
  parseDartDateMicros,
  renderNotice,
  startExpiryScheduler,
};
