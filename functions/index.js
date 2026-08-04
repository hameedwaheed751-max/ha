const admin = require("firebase-admin");
const { onRequest, onCall } = require("firebase-functions/v2/https");

admin.initializeApp();

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