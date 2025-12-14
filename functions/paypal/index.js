// functions/paypal/index.js
// PartyPin – PayPal Subscriptions (secure-ish, v2 / Node 24 / 2nd gen)
// - Aktiviert Premium nur nach PayPal-Verify
// - Schreibt ins RICHTIGE User-Dokument (query über username_lower / username)
// - premium läuft automatisch aus via Scheduler (premiumUntil)
// - Sync Job aktualisiert PayPal-Status (CANCELLED läuft bis premiumUntil weiter)

const admin = require("firebase-admin");
admin.initializeApp();

const { onRequest } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");

// ---------- Secrets (Secret Manager) ----------
const PAYPAL_CLIENT_ID = defineSecret("PAYPAL_CLIENT_ID");
const PAYPAL_SECRET = defineSecret("PAYPAL_SECRET");

// ---------- CONFIG ----------
const REGION = "us-central1";

// LIVE:
const PAYPAL_BASE = "https://api-m.paypal.com";
// SANDBOX (wenn du testest):
// const PAYPAL_BASE = "https://api-m.sandbox.paypal.com";

// Erlaubte Plan-IDs (deine echten IDs hier eintragen)
const ALLOWED_PLANS = new Set([
  "P-55588718AV729883XNE6MJ5Y", // monthly
  "P-0WL99384633096336NE6WUSA", // yearly (dein neues aktiviertes)
]);

// Nur deine Hosting-Domains dürfen die HTTPS Function aus dem Browser aufrufen
const ALLOWED_ORIGINS = [
  "https://partypin-5dc3f.web.app",
  "https://partypin-5dc3f.firebaseapp.com",
];

function sendJson(res, code, obj) {
  res.status(code).set("content-type", "application/json").send(JSON.stringify(obj));
}

function normalizeStatus(status) {
  return String(status || "UNKNOWN").toUpperCase();
}

// PayPal Status, der bedeutet: “Premium soll aktiv sein”
function isPremiumActiveStatus(status) {
  const s = normalizeStatus(status);
  return s === "ACTIVE";
}

// PayPal Status, der bedeutet: “Premium sofort aus”
function isHardDisabledStatus(status) {
  const s = normalizeStatus(status);
  return s === "EXPIRED" || s === "SUSPENDED" || s === "INACTIVE";
}

// CANCELLED: NICHT sofort aus (läuft bis premiumUntil), aber keine Verlängerung mehr.
function isCancelled(status) {
  return normalizeStatus(status) === "CANCELLED";
}

function parseIsoDate(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d;
}

function isSafeUsername(u) {
  // du übergibst username aus der App; begrenzen damit niemand wild queryt
  if (!u) return false;
  if (u.length < 2 || u.length > 40) return false;
  // erlaubt: buchstaben, zahlen, underscore, dash, punkt
  return /^[a-zA-Z0-9_.-]+$/.test(u);
}

async function findUserDocRefByUsername(username) {
  const db = admin.firestore();
  const u = String(username || "").trim();
  const ul = u.toLowerCase();

  // 1) username_lower
  let snap = await db.collection("users").where("username_lower", "==", ul).limit(1).get();
  if (!snap.empty) return snap.docs[0].ref;

  // 2) username (fallback)
  snap = await db.collection("users").where("username", "==", u).limit(1).get();
  if (!snap.empty) return snap.docs[0].ref;

  return null;
}

async function getPayPalAccessToken(clientId, secret) {
  const basicAuth = Buffer.from(`${clientId}:${secret}`).toString("base64");

  const resp = await fetch(`${PAYPAL_BASE}/v1/oauth2/token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${basicAuth}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });

  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    throw new Error(`PayPal token error: ${resp.status} ${txt}`);
  }

  const json = await resp.json();
  const token = String(json.access_token || "");
  if (!token) throw new Error("PayPal token missing");
  return token;
}

async function getPayPalSubscription(subscriptionId, token) {
  const resp = await fetch(
    `${PAYPAL_BASE}/v1/billing/subscriptions/${encodeURIComponent(subscriptionId)}`,
    {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
    },
  );

  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    throw new Error(`PayPal subscription error: ${resp.status} ${txt}`);
  }

  return resp.json();
}

function corsHeaders(req, res) {
  const origin = req.headers.origin;
  if (origin && ALLOWED_ORIGINS.includes(origin)) {
    res.set("access-control-allow-origin", origin);
    res.set("vary", "Origin");
  }
  res.set("access-control-allow-methods", "POST, OPTIONS");
  res.set("access-control-allow-headers", "content-type");
}

// ---------- 1) Activate: verify subscription + set premiumUntil ----------
exports.activatePayPalSubscription = onRequest(
  {
    region: REGION,
    secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET],
  },
  async (req, res) => {
    try {
      corsHeaders(req, res);

      if (req.method === "OPTIONS") return sendJson(res, 204, {});
      if (req.method !== "POST") return sendJson(res, 405, { status: "error", message: "method not allowed" });

      const body = req.body || {};
      const subscriptionId = String(body.subscriptionId || "").trim();
      const username = String(body.username || "").trim();
      const planId = String(body.planId || "").trim();

      if (!subscriptionId || !username || !planId) {
        return sendJson(res, 400, { status: "error", message: "missing data" });
      }
      if (!isSafeUsername(username)) {
        return sendJson(res, 400, { status: "error", message: "invalid username" });
      }
      if (!ALLOWED_PLANS.has(planId)) {
        return sendJson(res, 400, { status: "error", message: "plan not allowed" });
      }

      const clientId = PAYPAL_CLIENT_ID.value();
      const secret = PAYPAL_SECRET.value();
      if (!clientId || !secret) {
        return sendJson(res, 500, { status: "error", message: "missing paypal secrets" });
      }

      // 1) PayPal verify
      const token = await getPayPalAccessToken(clientId, secret);
      const sub = await getPayPalSubscription(subscriptionId, token);

      const paypalStatus = normalizeStatus(sub.status);

      // Plan-ID gegen PayPal prüfen (wichtig, damit niemand beliebiges planId mitschickt)
      const paypalPlanId = String(sub.plan_id || "").trim();
      if (!paypalPlanId) {
        return sendJson(res, 400, { status: "error", message: "paypal missing plan_id" });
      }
      if (paypalPlanId !== planId) {
        return sendJson(res, 400, {
          status: "error",
          message: "plan mismatch",
          paypalPlanId,
        });
      }

      // Premium nur wenn ACTIVE
      if (!isPremiumActiveStatus(paypalStatus)) {
        return sendJson(res, 400, {
          status: "error",
          message: `subscription not active: ${paypalStatus}`,
        });
      }

      // next billing time => premiumUntil
      const nextBillingIso = sub?.billing_info?.next_billing_time;
      const nextBilling = parseIsoDate(nextBillingIso);
      if (!nextBilling) {
        return sendJson(res, 400, { status: "error", message: "no next_billing_time" });
      }

      // 2) User-Doc finden
      const userRef = await findUserDocRefByUsername(username);
      if (!userRef) {
        return sendJson(res, 404, { status: "error", message: "user not found" });
      }

      // 3) Firestore schreiben
      await userRef.set(
        {
          premium: true,
          premiumPlan: planId,
          premiumSince: admin.firestore.FieldValue.serverTimestamp(),
          premiumUntil: admin.firestore.Timestamp.fromDate(nextBilling),
          paypalSubscriptionId: subscriptionId,
          paypalStatus: paypalStatus,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      return sendJson(res, 200, {
        status: "ok",
        paypalStatus,
        premiumUntil: nextBilling.toISOString(),
      });
    } catch (e) {
      return sendJson(res, 500, { status: "error", message: String(e) });
    }
  },
);

// ---------- 2) Scheduled: expire premium when premiumUntil passed ----------
exports.expirePremiumUsers = onSchedule(
  {
    region: REGION,
    schedule: "every 60 minutes",
    timeZone: "Europe/Vienna",
  },
  async () => {
    const db = admin.firestore();
    const now = admin.firestore.Timestamp.now();

    const snap = await db
      .collection("users")
      .where("premium", "==", true)
      .where("premiumUntil", "<=", now)
      .get();

    if (snap.empty) return;

    const batch = db.batch();
    for (const doc of snap.docs) {
      batch.set(
        doc.ref,
        {
          premium: false,
          paypalStatus: "EXPIRED_BY_SERVER",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }
    await batch.commit();
  },
);

// ---------- 3) Scheduled: sync PayPal status (cancelled/expired/etc.) ----------
exports.syncPayPalSubscriptions = onSchedule(
  {
    region: REGION,
    schedule: "every 6 hours",
    timeZone: "Europe/Vienna",
    secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET],
  },
  async () => {
    const db = admin.firestore();
    const clientId = PAYPAL_CLIENT_ID.value();
    const secret = PAYPAL_SECRET.value();
    if (!clientId || !secret) return;

    const token = await getPayPalAccessToken(clientId, secret);
    const now = admin.firestore.Timestamp.now();

    // robustere Query als "!= null"
    // (setzt voraus: paypalSubscriptionId ist string; wenn nicht vorhanden => fehlt Feld)
    const snap = await db
      .collection("users")
      .orderBy("paypalSubscriptionId")
      .where("paypalSubscriptionId", ">", "")
      .limit(200)
      .get();

    if (snap.empty) return;

    const batch = db.batch();

    for (const doc of snap.docs) {
      const u = doc.data() || {};
      const subId = String(u.paypalSubscriptionId || "").trim();
      if (!subId) continue;

      try {
        const sub = await getPayPalSubscription(subId, token);
        const paypalStatus = normalizeStatus(sub.status);

        const nextBillingIso = sub?.billing_info?.next_billing_time;
        const nextBilling = parseIsoDate(nextBillingIso);

        const patch = {
          paypalStatus,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };

        // Hard disabled => premium sofort aus
        if (isHardDisabledStatus(paypalStatus)) {
          patch.premium = false;
        }

        // CANCELLED => NICHT sofort aus; läuft bis premiumUntil (expirePremiumUsers)
        if (isCancelled(paypalStatus)) {
          // optional: wenn premiumUntil fehlt, dann wenigstens jetzt setzen -> 0 Tage
          if (!u.premiumUntil && nextBilling) {
            patch.premiumUntil = admin.firestore.Timestamp.fromDate(nextBilling);
          }
          // premium bleibt wie es ist
        }

        // ACTIVE => premium true, premiumUntil nachziehen
        if (isPremiumActiveStatus(paypalStatus)) {
          patch.premium = true;
          if (nextBilling) {
            patch.premiumUntil = admin.firestore.Timestamp.fromDate(nextBilling);
          }
        }

        // Extra safety: wenn premiumUntil existiert und schon vorbei ist, setze premium false
        if (u.premiumUntil && u.premiumUntil.toMillis && u.premiumUntil.toMillis() <= now.toMillis()) {
          patch.premium = false;
        }

        batch.set(doc.ref, patch, { merge: true });
      } catch (e) {
        batch.set(
          doc.ref,
          {
            paypalStatus: "SYNC_ERROR",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
    }

    await batch.commit();
  },
);
