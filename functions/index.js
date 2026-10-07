const admin = require("firebase-admin");
const { onRequest, onCall, HttpsError } = require("firebase-functions/v2/https");
const crypto = require("node:crypto");

admin.initializeApp();

const ADMIN_ROOT = 'admin';
const ADMIN_PAYMENT_REQUESTS_PATH = `${ADMIN_ROOT}/paymentRequests`;
const ADMIN_PAYMENT_HISTORY_PATH = `${ADMIN_ROOT}/paymentHistory`;
const LEGACY_PAYMENT_REQUESTS_PATH = 'paymentRequests';
const LEGACY_PAYMENT_HISTORY_PATH = 'paymentHistory';
const PAYMENT_REQUEST_PATHS = [ADMIN_PAYMENT_REQUESTS_PATH, LEGACY_PAYMENT_REQUESTS_PATH];
const SUBSCRIPTION_REQUEST_PATHS = [
  'admin/subscription_requests',
  'admin/subscriptionRequests',
  'subscription_requests',
  'subscriptionRequests',
];
const REQUEST_LOCK_MS = 2 * 60 * 1000;
const PENDING_REQUEST_CLAIM = 'pendingPaymentRequestId';
const STATUS_TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000;

function requireAdmin(request) {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Authentication is required.');
  }
  if (request.auth.token.admin !== true) {
    throw new HttpsError('permission-denied', 'An administrator claim is required.');
  }
  return {
    uid: request.auth.uid,
    email: String(request.auth.token.email || ''),
  };
}

function cleanRequestData(requestData) {
  const safe = { ...(requestData || {}) };
  delete safe.password;
  delete safe.approvedBy;
  delete safe.rejectedBy;
  delete safe.processingToken;
  delete safe.processingAt;
  delete safe.processingAction;
  delete safe.processingByUid;
  delete safe.receiptTokenHash;
    delete safe.receiptTokenExpiresAt;
    delete safe.statusTokenHash;
    delete safe.statusTokenExpiresAt;
  return safe;
}

function validateRequestId(requestId) {
  const id = String(requestId || '').trim();
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(id)) {
    throw new HttpsError('invalid-argument', 'A valid requestId is required.');
  }
  return id;
}

async function findRequestRef(requestId, paths) {
  const db = admin.database();
  for (const path of paths) {
    const ref = db.ref(`${path}/${requestId}`);
    const snapshot = await ref.get();
    if (snapshot.exists()) return { ref, data: snapshot.val(), path };
  }
  throw new HttpsError('not-found', 'Request not found.');
}

async function reserveSubmissionRateLimit(request) {
  const db = admin.database();
  const now = Date.now();
  const ip = String(request.rawRequest?.ip || 'unknown');
  const email = String(request.data?.email || '').trim().toLowerCase();
  const limits = [
    { key: `ip_${crypto.createHash('sha256').update(ip).digest('hex')}`, max: 20 },
    { key: `email_${crypto.createHash('sha256').update(email).digest('hex')}`, max: 3 },
  ];

  for (const limit of limits) {
    const ref = db.ref(`admin/_paymentSubmissionLimits/${limit.key}`);
    const result = await ref.transaction((current) => {
      const record = current && typeof current === 'object' ? current : {};
      const windowStart = Number(record.windowStart || 0);
      const count = windowStart > 0 && now - windowStart < 60 * 60 * 1000
        ? Number(record.count || 0)
        : 0;
      if (count >= limit.max) return;
      return {
        windowStart: count === 0 ? now : windowStart,
        count: count + 1,
        expiresAt: now + 24 * 60 * 60 * 1000,
      };
    }, undefined, false);
    if (!result.committed) {
      throw new HttpsError('resource-exhausted', 'Too many requests. Try again later.');
    }
  }
}

async function acquireRequestLock(ref, data, action, adminUid) {
  const token = crypto.randomUUID();
  const now = Date.now();
  const result = await ref.transaction((current) => {
    if (!current || typeof current !== 'object') return;
    const status = String(current.status || '').toLowerCase();
    if (status === 'pending') {
      return {
        ...current,
        status: 'processing',
        processingAction: action,
        processingToken: token,
        processingAt: now,
        processingByUid: adminUid,
      };
    }
    const staleProcessing = status === 'processing' &&
      current.processingAction === action &&
      now - Number(current.processingAt || 0) > REQUEST_LOCK_MS;
    if (staleProcessing) {
      return {
        ...current,
        processingToken: token,
        processingAt: now,
        processingByUid: adminUid,
      };
    }
    return;
  }, undefined, false);

  if (!result.committed) {
    const status = String(result.snapshot.val()?.status || '').toLowerCase();
    if (status === (action === 'approve' ? 'approved' : 'rejected')) {
      return { alreadyProcessed: true, token: null, data: result.snapshot.val() };
    }
    throw new HttpsError('failed-precondition', `Request cannot be ${action}d from status '${status}'.`);
  }
  return { alreadyProcessed: false, token, data: result.snapshot.val() };
}

async function finishRequest(ref, token, updates) {
  const result = await ref.transaction((current) => {
    if (!current || current.status !== 'processing' || current.processingToken !== token) {
      return;
    }
    const next = { ...current, ...updates };
    delete next.processingAction;
    delete next.processingToken;
    delete next.processingAt;
    delete next.processingByUid;
    if (next.status === 'approved' || next.status === 'rejected') delete next.password;
    return next;
  }, undefined, false);
  if (!result.committed) {
    throw new HttpsError('aborted', 'Request processing lock was lost; retry safely.');
  }
  return result.snapshot.val();
}

async function mergeUserClaims(uid, patch, removeKeys = []) {
  const user = await admin.auth().getUser(uid);
  const claims = { ...(user.customClaims || {}), ...patch };
  for (const key of removeKeys) delete claims[key];
  await admin.auth().setCustomUserClaims(uid, claims);
  return claims;
}

async function clearPendingPaymentPointer(uid, requestId) {
  if (!uid || !requestId) return;
  await admin.database().ref(`admin/_pendingPaymentRequestByUid/${uid}`).transaction((current) => {
    if (current?.requestId === requestId) return null;
    return;
  }, undefined, false);
}

async function resolveApprovedUser(requestData, requestId) {
  const db = admin.database();
  const email = String(requestData.email || '').trim().toLowerCase();
  const explicitUid = String(requestData.uid || requestData.renewalForUid || '').trim();
  if (explicitUid) {
    const user = await admin.auth().getUser(explicitUid);
    if (email && user.email?.toLowerCase() !== email) {
      throw new HttpsError('failed-precondition', 'Request email does not match the Firebase Auth account.');
    }
    const isRenewal = requestData.isRenewal === true || Boolean(requestData.renewalForUid);
    if (!isRenewal && user.customClaims?.[PENDING_PAYMENT_CLAIM] !== requestId &&
        user.customClaims?.agent !== true) {
      throw new HttpsError('failed-precondition', 'Account is not linked to this pending request.');
    }
    return user;
  }

  if (!email) throw new HttpsError('failed-precondition', 'Request has no account email.');
  const password = String(requestData.password || '');
  let user;
  try {
    user = await admin.auth().getUserByEmail(email);
  } catch (error) {
    if (error.code !== 'auth/user-not-found' || !password) {
      throw new HttpsError('failed-precondition', 'No linked Firebase Auth account exists.');
    }
    user = await admin.auth().createUser({
      email,
      password,
      emailVerified: false,
      disabled: true,
      displayName: String(requestData.agentName || ''),
    });
    await mergeUserClaims(user.uid, { [PENDING_PAYMENT_CLAIM]: requestId });
    user = await admin.auth().getUser(user.uid);
  }
  const agentProfile = (await db.ref(`agents/${user.uid}/profile`).get()).val() || {};
  if (user.customClaims?.[PENDING_PAYMENT_CLAIM] !== requestId &&
      user.customClaims?.agent !== true &&
      String(agentProfile.email || '').toLowerCase() !== email) {
    throw new HttpsError('failed-precondition', 'Existing account is not safely linked to this request.');
  }
  return user;
}

async function applyApprovedAgent(requestData, requestId, user) {
  const db = admin.database();
  const uid = user.uid;
  const now = new Date();
  const nowIso = now.toISOString();
  const email = user.email || String(requestData.email || '').trim().toLowerCase();
  const name = String(
    requestData.agentName ||
      [requestData.firstName, requestData.lastName].filter(Boolean).join(' ') ||
      user.displayName || '',
  ).trim();
  const nameParts = name.split(/\s+/).filter(Boolean);
  const isRenewal = requestData.isRenewal === true || Boolean(requestData.renewalForUid);
  const profile = {
    email,
    name,
    firstName: nameParts[0] || '',
    lastName: nameParts.slice(1).join(' '),
    phone: String(requestData.phone || ''),
    governorate: String(requestData.governorate || ''),
    region: String(requestData.region || ''),
    address: String(requestData.address || ''),
    role: 'agent',
    status: 'active',
    approvedAt: now.getTime(),
    approvalRequestId: requestId,
  };
  await db.ref(`agents/${uid}/profile`).update(profile);
  const plan = normalizePlan(requestData.selectedPlan);
  const durationDays = planDurationDays(plan);
  const subscriptionRef = db.ref(`agents/${uid}/subscription`);
  const currentSubscription = (await subscriptionRef.get()).val() || {};
  let startDate = now;
  if (isRenewal && currentSubscription.status === 'active') {
    const existingEnd = currentSubscription.endDate ? new Date(currentSubscription.endDate) : null;
    if (existingEnd && !Number.isNaN(existingEnd.getTime()) && existingEnd > now) {
      startDate = existingEnd;
    }
  }
  let endDate = durationDays > 0 ? addDays(startDate.toISOString(), durationDays) : startDate.toISOString();
  let subscription = {
    plan,
    status: durationDays > 0 ? 'active' : 'inactive',
    durationDays,
    startDate: startDate.toISOString(),
    endDate,
    autoExpire: true,
    lastPaymentId: requestId,
    updatedAt: nowIso,
  };

  const transaction = await subscriptionRef.transaction((current) => {
    if (current && current.lastPaymentId === requestId) return current;
    if (isRenewal && current?.status === 'active' && current.endDate) {
      const existingEnd = new Date(current.endDate);
      if (!Number.isNaN(existingEnd.getTime()) && existingEnd > now) {
        startDate = existingEnd;
      }
    }
    endDate = durationDays > 0 ? addDays(startDate.toISOString(), durationDays) : startDate.toISOString();
    subscription = { ...subscription, startDate: startDate.toISOString(), endDate };
    return subscription;
  }, undefined, false);
  if (!transaction.committed && transaction.snapshot.val()?.lastPaymentId !== requestId) {
    throw new HttpsError('aborted', 'Could not safely apply subscription.');
  }
  subscription = transaction.snapshot.val() || subscription;
  return { uid, email, name, plan, durationDays, subscription };
}

async function grantAgentClaimAfterApproval(uid, requestId) {
  const user = await admin.auth().getUser(uid);
  const db = admin.database();
  const [profileSnapshot, subscriptionSnapshot] = await Promise.all([
    db.ref(`agents/${uid}/profile`).get(),
    db.ref(`agents/${uid}/subscription`).get(),
  ]);
  const profile = profileSnapshot.val() || {};
  const subscription = subscriptionSnapshot.val() || {};
  if (profile.approvalRequestId !== requestId || subscription.lastPaymentId !== requestId) {
    throw new HttpsError('failed-precondition', 'Backend approval is incomplete; agent activation was withheld.');
  }
  await mergeUserClaims(uid, { agent: true }, [PENDING_PAYMENT_CLAIM]);
  if (user.disabled) await admin.auth().updateUser(uid, { disabled: false });
}

async function approveRequestCore(requestId, paths, reviewer) {
  const found = await findRequestRef(requestId, paths);
  const currentStatus = String(found.data.status || '').toLowerCase();
  if (currentStatus === 'approved') {
    if (found.data.approvalRequestId !== requestId || !found.data.reviewerUid) {
      throw new HttpsError('failed-precondition', 'This request has no trusted backend approval record.');
    }
    const uid = String(found.data.uid || '').trim();
    await grantAgentClaimAfterApproval(uid, requestId);
    return {
      ok: true,
      alreadyProcessed: true,
      uid,
      plan: found.data.subscription?.plan || found.data.selectedPlan || '',
      startDate: found.data.subscription?.startDate || '',
      endDate: found.data.subscription?.endDate || '',
    };
  }

  const locked = await acquireRequestLock(found.ref, found.data, 'approve', reviewer.uid);
  if (locked.alreadyProcessed) {
    const uid = String(locked.data.uid || '').trim();
    if (locked.data.approvalRequestId !== requestId || !locked.data.reviewerUid) {
      throw new HttpsError('failed-precondition', 'This request has no trusted backend approval record.');
    }
    await grantAgentClaimAfterApproval(uid, requestId);
    return { ok: true, alreadyProcessed: true, uid };
  }

  let approvalCommitted = false;
  try {
    const requestData = locked.data;
    if (String(requestData.status || '').toLowerCase() !== 'processing') {
      throw new HttpsError('failed-precondition', 'Request is not pending.');
    }
    const user = await resolveApprovedUser(requestData, requestId);
    const approved = await applyApprovedAgent(requestData, requestId, user);
    const now = new Date().toISOString();
    const safeRecord = cleanRequestData(requestData);
    const historyEntry = {
      ...safeRecord,
      uid: approved.uid,
      status: 'approved',
      reviewerUid: reviewer.uid,
      reviewerEmail: reviewer.email,
      reviewedAt: now,
      approvalRequestId: requestId,
      subscription: approved.subscription,
    };
    await finishRequest(found.ref, locked.token, historyEntry);
    approvalCommitted = true;

    await admin.database().ref(`${ADMIN_PAYMENT_HISTORY_PATH}/${requestId}`).set(historyEntry);
    await grantAgentClaimAfterApproval(approved.uid, requestId);
    await clearPendingPaymentPointer(approved.uid, requestId);
    return {
      ok: true,
      uid: approved.uid,
      phone: String(requestData.phone || ''),
      plan: approved.plan,
      planLabel: approved.plan,
      startDate: approved.subscription.startDate,
      endDate: approved.subscription.endDate,
      request: historyEntry,
    };
  } catch (error) {
    if (!approvalCommitted && locked.token) {
      await finishRequest(found.ref, locked.token, {
        status: 'pending',
        lastProcessingError: String(error.message || error).slice(0, 300),
      }).catch(() => {});
    }
    throw error;
  }
}

async function rejectRequestCore(requestId, paths, reviewer, rejectReason = '') {
  const found = await findRequestRef(requestId, paths);
  const status = String(found.data.status || '').toLowerCase();
  if (status === 'rejected') {
    if (!found.data.reviewerUid) {
      throw new HttpsError('failed-precondition', 'This request has no trusted backend rejection record.');
    }
    return { ok: true, alreadyProcessed: true };
  }
  const locked = await acquireRequestLock(found.ref, found.data, 'reject', reviewer.uid);
  if (locked.alreadyProcessed) return { ok: true, alreadyProcessed: true };

  try {
    const requestData = locked.data;
    if (String(requestData.status || '').toLowerCase() !== 'processing') {
      throw new HttpsError('failed-precondition', 'Request is not pending.');
    }
    const now = new Date().toISOString();
    const safeRecord = cleanRequestData(requestData);
    const history = {
      ...safeRecord,
      status: 'rejected',
      reviewerUid: reviewer.uid,
      reviewerEmail: reviewer.email,
      reviewedAt: now,
      rejectionReason: String(rejectReason || '').trim().slice(0, 500),
      password: null,
    };
    await finishRequest(found.ref, locked.token, history);
    await admin.database().ref(`${ADMIN_PAYMENT_HISTORY_PATH}/${requestId}`).set(history);
    await clearPendingPaymentPointer(String(requestData.uid || ''), requestId);
    return { ok: true, requestId };
  } catch (error) {
    await finishRequest(found.ref, locked.token, {
      status: 'pending',
      lastProcessingError: String(error.message || error).slice(0, 300),
    }).catch(() => {});
    throw error;
  }
}

exports.sasProxy = onRequest(async (req, res) => {
  res.json({
    ok: true,
    message: "NetAgent SAS Proxy is working",
  });
});

exports.createPaymentRequest = onCall(async (request) => {
  const data = request.data || {};
  await reserveSubmissionRateLimit(request);
  let user = null;
  let uid = '';
  let createdUser = false;
  const isRenewal = data.isRenewal === true;
  const signedInUid = request.auth?.uid || '';
  let email = String(data.email || '').trim().toLowerCase();

  if (isRenewal) {
    const targetUid = String(data.renewalForUid || data.uid || '').trim();
    if (!targetUid) throw new HttpsError('invalid-argument', 'A renewal account UID is required.');
    if (signedInUid && signedInUid !== targetUid) {
      throw new HttpsError('permission-denied', 'A renewal can only target the signed-in account.');
    }
    user = await admin.auth().getUser(targetUid);
    const profile = (await admin.database().ref(`agents/${targetUid}/profile`).get()).val() || {};
    if (user.customClaims?.agent !== true || !user.email || user.disabled || profile.status === 'disabled') {
      throw new HttpsError('permission-denied', 'Only an approved, enabled agent can request renewal.');
    }
    if (email && email !== user.email.toLowerCase()) {
      throw new HttpsError('permission-denied', 'Renewal email does not match the Firebase Auth account.');
    }
    email = user.email.toLowerCase();
    uid = user.uid;
  } else if (signedInUid) {
    user = await admin.auth().getUser(signedInUid);
    if (user.disabled || !user.email || user.email.toLowerCase() !== email) {
      throw new HttpsError('permission-denied', 'Request email must match the signed-in account.');
    }
    if (user.customClaims?.agent === true) {
      throw new HttpsError('already-exists', 'This account is already approved; submit a renewal request.');
    }
    uid = user.uid;
  } else {
    const password = String(data.password || '');
    if (!email || password.length < 6) {
      throw new HttpsError('invalid-argument', 'A valid email and password are required.');
    }
    try {
      user = await admin.auth().getUserByEmail(email);
      const pendingId = String(user.customClaims?.[PENDING_REQUEST_CLAIM] || '');
      if (pendingId) {
        const existing = await findRequestRef(pendingId, PAYMENT_REQUEST_PATHS).catch(() => null);
        if (existing && String(existing.data.status).toLowerCase() === 'pending') {
          throw new HttpsError('already-exists', 'A request for this account is already pending.');
        }
      }
      throw new HttpsError('already-exists', 'An account already exists for this email; sign in instead.');
    } catch (error) {
      if (error instanceof HttpsError) throw error;
      if (error.code !== 'auth/user-not-found') throw error;
    }
    user = await admin.auth().createUser({
      email,
      password,
      emailVerified: false,
      disabled: true,
      displayName: String(data.agentName || '').trim(),
    });
    uid = user.uid;
    createdUser = true;
  }

  if (user.customClaims?.[PENDING_REQUEST_CLAIM]) {
    const pendingId = String(user.customClaims[PENDING_REQUEST_CLAIM]);
    const existing = await findRequestRef(pendingId, PAYMENT_REQUEST_PATHS).catch(() => null);
    if (existing && String(existing.data.status).toLowerCase() === 'pending') {
      throw new HttpsError('already-exists', 'A request for this account is already pending.');
    }
  }
  const requestId = admin.database().ref(ADMIN_PAYMENT_REQUESTS_PATH).push().key;
  if (!requestId) throw new HttpsError('internal', 'Could not allocate a request ID.');
  const receiptToken = crypto.randomBytes(32).toString('hex');
  const receiptTokenHash = crypto.createHash('sha256').update(receiptToken).digest('hex');
  const statusToken = crypto.randomBytes(32).toString('hex');
  const statusTokenHash = crypto.createHash('sha256').update(statusToken).digest('hex');
  const record = {
    requestId,
    uid,
    email,
    agentName: String(data.agentName || user.displayName || '').trim(),
    phone: String(data.phone || '').trim(),
    governorate: String(data.governorate || '').trim(),
    region: String(data.region || '').trim(),
    address: String(data.address || '').trim(),
    selectedPlan: normalizePlan(data.selectedPlan),
    amount: String(data.amount || '').trim(),
    paymentMethod: String(data.paymentMethod || 'Qi Card').trim(),
    transferNumber: String(data.transferNumber || '').trim(),
    receiptImage: '',
    status: 'pending',
    createdAt: Date.now(),
    receiptTokenHash,
    receiptTokenExpiresAt: Date.now() + 30 * 60 * 1000,
    statusTokenHash,
    statusTokenExpiresAt: Date.now() + STATUS_TOKEN_TTL_MS,
    isRenewal,
    renewalForUid: isRenewal ? uid : '',
  };

  const pendingRef = admin.database().ref(`admin/_pendingPaymentRequestByUid/${uid}`);
  const reservation = await pendingRef.transaction((current) => {
    if (current && current.requestId) return;
    return { requestId, createdAt: Date.now() };
  }, undefined, false);
  if (!reservation.committed) {
    throw new HttpsError('already-exists', 'A pending request already exists for this account.');
  }

  try {
    await admin.database().ref(`${ADMIN_PAYMENT_REQUESTS_PATH}/${requestId}`).set(record);
    await mergeUserClaims(uid, { [PENDING_REQUEST_CLAIM]: requestId });
    if (!isRenewal && !user.disabled) await admin.auth().updateUser(uid, { disabled: true });
    return { requestId, receiptToken, statusToken };
  } catch (error) {
    await pendingRef.remove();
    if (createdUser) await admin.auth().deleteUser(uid).catch(() => {});
    throw error;
  }
});

exports.listPaymentRequests = onCall(async (request) => {
  requireAdmin(request);
  const status = String(request.data?.status || 'pending').trim().toLowerCase();
  const db = admin.database();
  const merged = new Map();
  for (const path of PAYMENT_REQUEST_PATHS) {
    const snapshot = await db.ref(path).get();
    const records = snapshot.val();
    if (!records || typeof records !== 'object') continue;
    for (const [id, raw] of Object.entries(records)) {
      if (!raw || typeof raw !== 'object') continue;
      const safe = cleanRequestData(raw);
      safe.requestId ||= id;
      if (!status || String(safe.status || '').toLowerCase() === status) {
        merged.set(id, safe);
      }
    }
  }
  return {
    requests: [...merged.values()].sort((a, b) => Number(b.createdAt || 0) - Number(a.createdAt || 0)),
  };
});

exports.getPaymentRequestStatus = onCall(async (request) => {
  const requestId = validateRequestId(request.data?.requestId);
  const token = String(request.data?.statusToken || '');
  if (!token) throw new HttpsError('invalid-argument', 'A status token is required.');
  const found = await findRequestRef(requestId, PAYMENT_REQUEST_PATHS).catch(() => null);
  if (!found) return { request: null };
  const actualHash = crypto.createHash('sha256').update(token).digest();
  const expectedHash = Buffer.from(String(found.data.statusTokenHash || ''), 'hex');
  if (expectedHash.length !== actualHash.length || !crypto.timingSafeEqual(actualHash, expectedHash) ||
      Number(found.data.statusTokenExpiresAt || 0) < Date.now()) {
    throw new HttpsError('permission-denied', 'Invalid or expired status token.');
  }
  return {
    request: {
      requestId,
      status: String(found.data.status || ''),
      createdAt: Number(found.data.createdAt || 0),
      rejectionReason: String(found.data.rejectionReason || found.data.rejectReason || ''),
      selectedPlan: String(found.data.selectedPlan || ''),
    },
  };
});

exports.getMyRenewalRequest = onCall(async (request) => {
  if (!request.auth || request.auth.token.agent !== true) {
    throw new HttpsError('permission-denied', 'An approved agent sign-in is required.');
  }
  const uid = request.auth.uid;
  const pointer = (await admin.database().ref(`admin/_pendingPaymentRequestByUid/${uid}`).get()).val();
  if (!pointer?.requestId) return { request: null };
  const found = await findRequestRef(String(pointer.requestId), PAYMENT_REQUEST_PATHS).catch(() => null);
  if (!found || String(found.data.uid || '') !== uid || found.data.isRenewal !== true) {
    return { request: null };
  }
  const safe = cleanRequestData(found.data);
  return {
    request: {
      requestId: String(found.data.requestId || pointer.requestId),
      status: String(found.data.status || ''),
      createdAt: Number(found.data.createdAt || 0),
      rejectionReason: String(found.data.rejectionReason || found.data.rejectReason || ''),
      selectedPlan: String(found.data.selectedPlan || ''),
    },
  };
});

exports.uploadPaymentReceipt = onCall(async (request) => {
  const data = request.data || {};
  const requestId = validateRequestId(data.requestId);
  const token = String(data.receiptToken || '');
  const contentType = String(data.contentType || '').toLowerCase();
  const encoded = String(data.base64 || '');
  if (!token || encoded.length === 0 || encoded.length > 4_200_000) {
    throw new HttpsError('invalid-argument', 'A receipt and receipt token are required; maximum size is 3 MB.');
  }
  if (!['image/jpeg', 'image/png', 'image/webp', 'application/pdf'].includes(contentType)) {
    throw new HttpsError('invalid-argument', 'Unsupported receipt content type.');
  }
  const found = await findRequestRef(requestId, [ADMIN_PAYMENT_REQUESTS_PATH]);
  if (String(found.data.status || '').toLowerCase() !== 'pending') {
    throw new HttpsError('failed-precondition', 'Receipt upload is only allowed for pending requests.');
  }
  const actualHash = crypto.createHash('sha256').update(token).digest();
  const expectedHash = Buffer.from(String(found.data.receiptTokenHash || ''), 'hex');
  if (expectedHash.length !== actualHash.length || !crypto.timingSafeEqual(actualHash, expectedHash)) {
    throw new HttpsError('permission-denied', 'Invalid receipt upload token.');
  }
  if (Number(found.data.receiptTokenExpiresAt || 0) < Date.now()) {
    throw new HttpsError('deadline-exceeded', 'Receipt upload token expired.');
  }
  const bytes = Buffer.from(encoded, 'base64');
  if (!bytes.length || bytes.length > 3 * 1024 * 1024) {
    throw new HttpsError('invalid-argument', 'Receipt exceeds the 3 MB limit.');
  }
  const storageToken = crypto.randomUUID();
  const objectPath = `admin/paymentRequests/${requestId}/receipt_${crypto.randomUUID()}`;
  const bucket = admin.storage().bucket();
  const file = bucket.file(objectPath);
  await file.save(bytes, {
    resumable: false,
    metadata: {
      contentType,
      metadata: { firebaseStorageDownloadTokens: storageToken },
    },
  });
  const downloadUrl = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(objectPath)}?alt=media&token=${storageToken}`;
  const result = await found.ref.transaction((current) => {
    if (!current || current.status !== 'pending' || current.receiptTokenHash !== found.data.receiptTokenHash) return;
    return {
      ...current,
      receiptImage: downloadUrl,
      receiptTokenHash: null,
      receiptTokenExpiresAt: null,
    };
  }, undefined, false);
  if (!result.committed) {
    await file.delete().catch(() => {});
    throw new HttpsError('failed-precondition', 'Request changed during receipt upload.');
  }
  return { receiptImage: downloadUrl };
});

exports.approveSubscriptionRequest = onCall(async (request) => {
  const reviewer = requireAdmin(request);
  const requestId = validateRequestId(request.data?.requestId);
  return approveRequestCore(requestId, SUBSCRIPTION_REQUEST_PATHS, reviewer);
});

exports.rejectSubscriptionRequest = onCall(async (request) => {
  const reviewer = requireAdmin(request);
  const requestId = validateRequestId(request.data?.requestId);
  return rejectRequestCore(
    requestId,
    SUBSCRIPTION_REQUEST_PATHS,
    reviewer,
    request.data?.rejectReason,
  );
});

function normalizePlan(plan) {
  switch (String(plan || '').trim()) {
    case 'trial':
      return 'free_15_days';
    case '3m':
      return 'three_months';
    case '6m':
      return 'six_months';
    case '1y':
      return 'one_year';
    default:
      return String(plan || '').trim() || 'free';
  }
}

function planDurationDays(plan) {
  switch (normalizePlan(plan)) {
    case 'free_15_days':
      return 15;
    case 'three_months':
      return 90;
    case 'six_months':
      return 183;
    case 'one_year':
      return 365;
    default:
      return 0;
  }
}

function addDays(iso, days) {
  const base = new Date(iso);
  return new Date(base.getTime() + (days * 24 * 60 * 60 * 1000)).toISOString();
}

exports.approvePaymentRequest = onCall(async (request) => {
  const reviewer = requireAdmin(request);
  const requestId = validateRequestId(request.data?.requestId);
  return approveRequestCore(requestId, PAYMENT_REQUEST_PATHS, reviewer);
});

exports.rejectPaymentRequest = onCall(async (request) => {
  const reviewer = requireAdmin(request);
  const requestId = validateRequestId(request.data?.requestId);
  return rejectRequestCore(
    requestId,
    PAYMENT_REQUEST_PATHS,
    reviewer,
    request.data?.rejectReason,
  );
});