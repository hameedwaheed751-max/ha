'use strict';

// الإشعارات الفورية لوكلاء «وكيل نت» وللمدير، عبر Firebase Cloud Messaging
// لمشروع وكيل نت نفسه. كل إرسال هنا «تحسين»: لا يُفشل أي عملية أبداً.
//
// المسارات (يكتبها الخادم فقط):
//   agentPush/devices/{uid}/{key}  رموز أجهزة الحساب (5 كحد أقصى)
//   agentPush/owners/{key}         آخر حساب سجّل هذا الجهاز
//   agentPush/sent/{uid}/{key}     تذكيرات اشتراك الوكيل المرسلة (لا تكرار)
//   agentPush/digest/{uid}         آخر يوم أُرسل فيه الملخص الصباحي

const crypto = require('node:crypto');
const express = require('express');

const ROOT = 'agentPush';
const DAY_MS = 24 * 60 * 60 * 1000;
const BAGHDAD_OFFSET_MS = 3 * 60 * 60 * 1000; // العراق بلا توقيت صيفي.
const DIGEST_HOUR = 9;
const MAX_DEVICES = 5;
const SOON_DAYS = 3;

class NotifyError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

const entriesOf = (value) =>
  value && typeof value === 'object' ? Object.entries(value).filter(([, v]) => v) : [];
const listOf = (value) => (Array.isArray(value) ? value : value && typeof value === 'object' ? Object.values(value) : []);
const str = (value) => (typeof value === 'string' ? value.trim() : '');

function preview(value, max = 120) {
  const t = String(value || '').replace(/\s+/g, ' ').trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

function daysWord(n) {
  if (n <= 1) return 'يوم واحد';
  if (n === 2) return 'يومين';
  return `${n} أيام`;
}

/** يوم بغداد (YYYY-MM-DD) وساعته لوقت بالملّي ثانية. */
function baghdadClock(ms) {
  const shifted = new Date(ms + BAGHDAD_OFFSET_MS);
  return { day: shifted.toISOString().slice(0, 10), hour: shifted.getUTCHours() };
}

function createAgentNotifier({
  db,
  sender = null,
  adminUid = '',
  now = Date.now,
  subscriptionEnd = async () => null,
  isEligible = async () => true,
}) {
  const keyOf = (token) => crypto.createHash('sha256').update(`agent-device/${token}`).digest('hex').slice(0, 24);
  const devicesPath = (uid) => `${ROOT}/devices/${uid}`;

  function deviceToken(token) {
    const value = typeof token === 'string' ? token.trim() : '';
    if (value.length < 20 || value.length > 4096) throw new NotifyError(400, 'validation_failed');
    return value;
  }

  // الجهاز لآخر حساب سجّله: إن دخل وكيل آخر على نفس الهاتف لا تصله إشعارات الأول.
  async function registerDevice(uid, { token, platform } = {}) {
    const value = deviceToken(token);
    const key = keyOf(value);
    const owner = await db.get(`${ROOT}/owners/${key}`);
    if (owner && owner !== uid) await db.set(`${devicesPath(owner)}/${key}`, null);
    const others = entriesOf(await db.get(devicesPath(uid)))
      .filter(([k]) => k !== key)
      .sort((a, b) => (a[1].updatedAt < b[1].updatedAt ? 1 : -1));
    const patch = {
      [`devices/${uid}/${key}`]: {
        token: value,
        platform: str(platform).slice(0, 20) || 'android',
        updatedAt: new Date(now()).toISOString(),
      },
      [`owners/${key}`]: uid,
    };
    for (const [k] of others.slice(MAX_DEVICES - 1)) patch[`devices/${uid}/${k}`] = null;
    await db.update(ROOT, patch);
    return null;
  }

  async function unregisterDevice(uid, { token } = {}) {
    const key = keyOf(deviceToken(token));
    const patch = { [`devices/${uid}/${key}`]: null };
    if ((await db.get(`${ROOT}/owners/${key}`)) === uid) patch[`owners/${key}`] = null;
    await db.update(ROOT, patch);
    return null;
  }

  async function notify(uid, message) {
    if (!sender?.sendPush || !uid) return;
    try {
      const devices = entriesOf(await db.get(devicesPath(uid)));
      if (devices.length === 0) return;
      const { invalidTokens = [] } = await sender.sendPush(devices.map(([, d]) => d.token), message);
      const dead = new Set(invalidTokens);
      const patch = {};
      for (const [key, d] of devices) if (dead.has(d.token)) patch[key] = null;
      if (Object.keys(patch).length) await db.update(devicesPath(uid), patch);
    } catch (error) {
      console.error('agent push failed:', error?.message || error);
    }
  }

  async function owners() {
    return entriesOf(await db.get(`${ROOT}/devices`)).map(([uid]) => uid);
  }

  // --- الدردشة العامة ---

  async function onChatMessage(id, message) {
    try {
      if (!message || typeof message !== 'object' || message.deletedAt) return;
      const senderUid = str(message.senderUid);
      const body = preview(message.text) || (str(message.imageUrl) ? 'صورة' : '');
      if (!senderUid || !body) return;
      const name = str(message.senderName) || 'وكيل';
      const data = { kind: 'chat', id: String(id) };
      if (adminUid && senderUid === adminUid) {
        const all = (await owners()).filter((uid) => uid !== adminUid);
        await Promise.all(all.map((uid) => notify(uid, { title: 'رسالة من الإدارة', body, data })));
        return;
      }
      const tasks = [notify(adminUid, { title: `رسالة من ${name}`, body, data })];
      const repliedTo = str(message.replyTo?.senderUid);
      if (repliedTo && repliedTo !== senderUid && repliedTo !== adminUid) {
        tasks.push(notify(repliedTo, { title: `${name} رد على رسالتك`, body, data }));
      }
      await Promise.all(tasks);
    } catch (error) {
      console.error('chat push failed:', error?.message || error);
    }
  }

  // --- طلبات اشتراك الوكلاء ---

  const fullName = (r) => `${str(r.firstName)} ${str(r.lastName)}`.trim() || str(r.email) || 'وكيل';

  async function onRequestAdded(id, request) {
    if (!request || str(request.status || 'pending') !== 'pending') return;
    const plan = str(request.selectedPlan);
    await notify(adminUid, {
      title: request.isRenewal === true ? 'طلب تجديد اشتراك وكيل' : 'طلب اشتراك جديد',
      body: plan ? `${fullName(request)} — ${plan}` : fullName(request),
      data: { kind: 'agent_request', id: String(id) },
    });
  }

  async function onRequestChanged(id, previousStatus, request) {
    const status = str(request?.status);
    const uid = str(request?.uid);
    if (!uid || status === str(previousStatus)) return;
    const data = { kind: 'my_subscription', id: String(id) };
    if (status === 'approved') {
      await notify(uid, { title: 'تم قبول طلب اشتراكك', body: 'اشتراكك في وكيل نت مفعّل الآن.', data });
    } else if (status === 'rejected') {
      const reason = preview(request.rejectionReason, 100);
      await notify(uid, {
        title: 'رُفض طلب اشتراكك',
        body: reason ? `السبب: ${reason}` : 'افتح وكيل نت لمعرفة التفاصيل.',
        data,
      });
    }
  }

  // --- المجدول (كل ساعة): تذكير اشتراك الوكيل، والملخص الصباحي ---

  async function subscriptionNotice(uid, at) {
    const end = await subscriptionEnd(uid);
    if (!Number.isFinite(end)) return;
    let key;
    let message;
    if (end > at && end - at <= SOON_DAYS * DAY_MS) {
      key = `${end}-soon`;
      message = {
        title: 'اشتراكك في وكيل نت ينتهي قريباً',
        body: `ينتهي خلال ${daysWord(Math.ceil((end - at) / DAY_MS))}. جدّد لتستمر الخدمة دون انقطاع.`,
      };
    } else if (at >= end && at - end < 2 * DAY_MS) {
      key = `${end}-ended`;
      message = { title: 'انتهى اشتراكك في وكيل نت', body: 'جدّد اشتراكك من التطبيق لاستعادة كل الميزات.' };
    } else {
      return;
    }
    const sentPath = `${ROOT}/sent/${uid}/${key}`;
    if (await db.get(sentPath)) return;
    await db.set(sentPath, new Date(at).toISOString());
    await notify(uid, { ...message, data: { kind: 'my_subscription', id: '' } });
  }

  async function morningDigest(uid, at) {
    const { day, hour } = baghdadClock(at);
    if (hour < DIGEST_HOUR) return;
    const digestPath = `${ROOT}/digest/${uid}`;
    if ((await db.get(digestPath)) === day) return;
    await db.set(digestPath, day);
    if (!(await isEligible(uid))) return;
    const count = listOf(await db.get(`agents/${uid}/subscribers`)).filter(
      (s) => s && s.disabled !== true && String(s.endDate || '').slice(0, 10) === day,
    ).length;
    if (count === 0) return;
    await notify(uid, {
      title: 'ملخص اليوم',
      body: `اليوم ينتهي اشتراك ${count} من مشتركيك.`,
      data: { kind: 'digest', id: day },
    });
  }

  async function runScheduled() {
    const at = now();
    for (const uid of await owners()) {
      try {
        if (uid !== adminUid) await subscriptionNotice(uid, at);
        await morningDigest(uid, at);
      } catch (error) {
        console.error(`agent schedule failed for ${uid}:`, error?.message || error);
      }
    }
  }

  return {
    registerDevice,
    unregisterDevice,
    notify,
    onChatMessage,
    onRequestAdded,
    onRequestChanged,
    runScheduled,
  };
}

/**
 * يراقب الدردشة العامة وطلبات اشتراك الوكلاء في قاعدة وكيل نت (Admin SDK).
 * ما كان موجوداً عند البدء لا يُرسل عنه شيء، فإعادة تشغيل البوابة لا تكرر إشعاراً.
 * يعيد دالة إيقاف المراقبة.
 */
async function watchAgentEvents({
  database,
  notifier,
  chatPath = 'global_chat/chat',
  requestsPath = 'admin/subscriptionRequests',
}) {
  const stops = [];

  // مفاتيح push مرتّبة زمنياً: نبدأ بعد آخر رسالة موجودة.
  let lastKey = null;
  (await database.ref(chatPath).orderByKey().limitToLast(1).once('value')).forEach((child) => {
    lastKey = child.key;
  });
  const chat = lastKey
    ? database.ref(chatPath).orderByKey().startAfter(lastKey)
    : database.ref(chatPath).orderByKey();
  const onChat = (snap) => {
    notifier.onChatMessage(snap.key, snap.val());
  };
  chat.on('child_added', onChat);
  stops.push(() => chat.off('child_added', onChat));

  const requests = database.ref(requestsPath);
  const statuses = new Map();
  (await requests.once('value')).forEach((child) => {
    statuses.set(child.key, str(child.val()?.status));
  });
  const onAdded = (snap) => {
    if (statuses.has(snap.key)) return;
    statuses.set(snap.key, str(snap.val()?.status));
    notifier.onRequestAdded(snap.key, snap.val());
  };
  const onChanged = (snap) => {
    const previous = statuses.get(snap.key) || '';
    statuses.set(snap.key, str(snap.val()?.status));
    notifier.onRequestChanged(snap.key, previous, snap.val());
  };
  requests.on('child_added', onAdded);
  requests.on('child_changed', onChanged);
  stops.push(() => requests.off('child_added', onAdded));
  stops.push(() => requests.off('child_changed', onChanged));

  return () => stops.forEach((stop) => stop());
}

function createAgentNotificationsRouter({ notifier, requireAgent }) {
  const router = express.Router();
  const handle = (fn) => async (req, res) => {
    try {
      await fn(req);
      res.status(200).json({ success: true, data: null });
    } catch (error) {
      if (error instanceof NotifyError) {
        return res.status(error.status).json({ success: false, error: error.code });
      }
      console.error('agent devices error:', error?.message || error);
      return res.status(500).json({ success: false, error: 'server_error' });
    }
  };
  router.post('/agent/devices', requireAgent, handle((req) =>
    notifier.registerDevice(req.agentUid, { token: req.body?.token, platform: req.body?.platform })));
  router.post('/agent/devices/unregister', requireAgent, handle((req) =>
    notifier.unregisterDevice(req.agentUid, { token: req.body?.token })));
  return router;
}

module.exports = { createAgentNotifier, createAgentNotificationsRouter, watchAgentEvents, baghdadClock };
