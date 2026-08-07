const admin = require("firebase-admin");
const { onRequest, onCall, HttpsError } = require("firebase-functions/v2/https");

admin.initializeApp();

const ADMIN_ROOT = 'admin';
const ADMIN_PAYMENT_REQUESTS_PATH = `${ADMIN_ROOT}/paymentRequests`;
const ADMIN_PAYMENT_HISTORY_PATH = `${ADMIN_ROOT}/paymentHistory`;
const LEGACY_PAYMENT_REQUESTS_PATH = 'paymentRequests';
const LEGACY_PAYMENT_HISTORY_PATH = 'paymentHistory';

exports.sasProxy = onRequest(async (req, res) => {
  res.json({
    ok: true,
    message: "NetAgent SAS Proxy is working",
  });
});

exports.approveSubscriptionRequest = onCall(async (request) => {
  const data = request.data || {};
  const email = String(data.email || "").trim().toLowerCase();
  const password = String(data.password || "");
  const firstName = String(data.firstName || "").trim();
  const lastName = String(data.lastName || "").trim();
  const phone = String(data.phone || "").trim();
  const selectedPlan = String(data.selectedPlan || "").trim();
  const planLabel = String(data.planLabel || "").trim();
  const amount = String(data.amount || "").trim();
  const paymentMethod = String(data.paymentMethod || "Qi Card").trim();
  const requestId = String(data.requestId || "").trim();

  if (!email || !password) {
    throw new Error("Missing email or password");
  }

  let userRecord;
  try {
    userRecord = await admin.auth().getUserByEmail(email);
  } catch (error) {
    if (error.code === "auth/user-not-found") {
      userRecord = await admin.auth().createUser({
        email,
        password,
        emailVerified: true,
      });
    } else {
      throw error;
    }
  }

  const uid = userRecord.uid;
  const firestore = admin.firestore();
  const agentRef = firestore.collection("agents").doc(uid);
  const profileRef = agentRef.collection("profile").doc("main");
  const now = new Date();
  const startDate = now.toISOString();
  const endDate = new Date(now.getTime() + 1000 * 60 * 60 * 24 * 15).toISOString();

  await agentRef.set({
    uid,
    createdAt: now.toISOString(),
    updatedAt: now.toISOString(),
  }, { merge: true });

  await profileRef.set({
    email,
    firstName,
    lastName,
    name: `${firstName} ${lastName}`.trim(),
    phone,
    subscriptionPlan: selectedPlan,
    subscriptionPlanLabel: planLabel,
    subscriptionPrice: amount,
    paymentMethod,
    subscriptionStartDate: startDate,
    subscriptionEndDate: endDate,
    subscriptionStatus: "active",
    status: "active",
  }, { merge: true });

  if (requestId) {
    await firestore.collection("subscription_requests").doc(requestId).update({
      uid,
      status: "approved",
      reviewedAt: now.toISOString(),
    });
  }

  return { ok: true, uid };
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
  const data = request.data || {};
  const requestId = String(data.requestId || '').trim();
  const approvedBy = String(data.approvedBy || '').trim();

  if (!requestId) {
    throw new HttpsError('invalid-argument', 'Missing requestId');
  }

  const rtdb = admin.database();
  let requestPath = ADMIN_PAYMENT_REQUESTS_PATH;
  let requestRef = rtdb.ref(`${requestPath}/${requestId}`);
  let requestSnap = await requestRef.get();
  if (!requestSnap.exists()) {
    requestPath = LEGACY_PAYMENT_REQUESTS_PATH;
    requestRef = rtdb.ref(`${requestPath}/${requestId}`);
    requestSnap = await requestRef.get();
  }
  if (!requestSnap.exists()) {
    throw new HttpsError('not-found', 'Payment request not found');
  }

  const requestData = requestSnap.val() || {};
  let userRecord;
  try {
    const email = String(requestData.email || '').trim().toLowerCase();
    const password = String(requestData.password || '').trim();
    userRecord = await admin.auth().getUserByEmail(email);
  } catch (error) {
    if (error.code === 'auth/user-not-found') {
      const email = String(requestData.email || '').trim().toLowerCase();
      const password = String(requestData.password || '').trim();
      if (!password) {
        throw new HttpsError('failed-precondition', 'Missing password for account creation');
      }
      userRecord = await admin.auth().createUser({
        email,
        password,
        emailVerified: true,
      });
    } else {
      throw error;
    }
  }

  const uid = userRecord.uid;

  const plan = normalizePlan(requestData.selectedPlan);
  const durationDays = planDurationDays(plan);
  const now = new Date().toISOString();

  const subscriptionRef = rtdb.ref(`agents/${uid}/subscription`);
  const currentSubscriptionSnap = await subscriptionRef.get();
  const currentSubscription = currentSubscriptionSnap.val() || {};
  const currentStatus = String(currentSubscription.status || 'inactive');
  const currentEnd = currentSubscription.endDate ? new Date(currentSubscription.endDate) : null;
  const activeNow = currentStatus === 'active' && currentEnd && !Number.isNaN(currentEnd.getTime()) && currentEnd > new Date();
  const startDate = activeNow ? currentEnd.toISOString() : now;
  const endDate = durationDays > 0 ? addDays(startDate, durationDays) : startDate;

  const subscriptionPatch = {
    plan,
    status: durationDays > 0 ? 'active' : 'inactive',
    durationDays,
    startDate,
    endDate,
    autoExpire: true,
    lastPaymentId: requestId,
    updatedAt: now,
  };

  await subscriptionRef.set(subscriptionPatch);

  const historyEntry = {
    ...requestData,
    uid,
    status: 'approved',
    approvedBy,
    approvedAt: now,
    subscription: subscriptionPatch,
  };

  await rtdb.ref(`${ADMIN_PAYMENT_HISTORY_PATH}/${requestId}`).set(historyEntry);
  await rtdb.ref(`${LEGACY_PAYMENT_HISTORY_PATH}/${requestId}`).remove();
  await requestRef.remove();
  if (requestPath !== LEGACY_PAYMENT_REQUESTS_PATH) {
    await rtdb.ref(`${LEGACY_PAYMENT_REQUESTS_PATH}/${requestId}`).remove();
  }

  return {
    ok: true,
    uid,
    phone: String(requestData.phone || ''),
    plan,
    planLabel: plan,
    startDate,
    endDate,
    request: historyEntry,
  };
});

exports.rejectPaymentRequest = onCall(async (request) => {
  const data = request.data || {};
  const requestId = String(data.requestId || '').trim();
  const rejectedBy = String(data.rejectedBy || '').trim();
  const rejectReason = String(data.rejectReason || '').trim();

  if (!requestId) {
    throw new HttpsError('invalid-argument', 'Missing requestId');
  }

  const rtdb = admin.database();
  let requestPath = ADMIN_PAYMENT_REQUESTS_PATH;
  let requestRef = rtdb.ref(`${requestPath}/${requestId}`);
  let requestSnap = await requestRef.get();
  if (!requestSnap.exists()) {
    requestPath = LEGACY_PAYMENT_REQUESTS_PATH;
    requestRef = rtdb.ref(`${requestPath}/${requestId}`);
    requestSnap = await requestRef.get();
  }
  if (!requestSnap.exists()) {
    throw new HttpsError('not-found', 'Payment request not found');
  }

  const requestData = requestSnap.val() || {};
  const now = new Date().toISOString();
  const historyEntry = {
    ...requestData,
    status: 'rejected',
    rejectedBy,
    rejectedAt: now,
    rejectReason,
  };

  await rtdb.ref(`${ADMIN_PAYMENT_HISTORY_PATH}/${requestId}`).set(historyEntry);
  await rtdb.ref(`${LEGACY_PAYMENT_HISTORY_PATH}/${requestId}`).remove();
  await requestRef.remove();
  if (requestPath !== LEGACY_PAYMENT_REQUESTS_PATH) {
    await rtdb.ref(`${LEGACY_PAYMENT_REQUESTS_PATH}/${requestId}`).remove();
  }

  return {
    ok: true,
    phone: String(requestData.phone || ''),
    request: historyEntry,
  };
});