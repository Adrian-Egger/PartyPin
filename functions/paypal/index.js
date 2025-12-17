// PartyPin – PayPal Subscriptions (Sandbox + Live toggle)
// Premium wird NUR nach PayPal Verify gesetzt.

const admin = require("firebase-admin");
admin.initializeApp();

const { onRequest } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret, defineString } = require("firebase-functions/params");

// ---------- Secrets ----------
const PAYPAL_CLIENT_ID = defineSecret("PAYPAL_CLIENT_ID");
const PAYPAL_SECRET = defineSecret("PAYPAL_SECRET");

// ---------- Params ----------
const PAYPAL_ENV = defineString("PAYPAL_ENV", { default: "SANDBOX" }); // "SANDBOX" oder "LIVE"

// ---------- CONFIG ----------
const REGION = "us-central1";

// Plan-IDs: Sandbox und Live getrennt!
const ALLOWED_PLANS_SANDBOX = new Set([
  // HIER deine Sandbox Plan IDs rein:
  // "P-XXXX", "P-YYYY"
]);

const ALLOWED_PLANS_LIVE = new Set([
  "P-55588718AV729883XNE6MJ5Y", // PartyPin Premium – Monatlich
  "P-0WL99384633096336NE6WUSA", // PartyPin Jährlich
]);

const ALLOWED_ORIGINS = [
  "https://partypin-5dc3f.web.app",
  "https://partypin-5dc3f.firebaseapp.com",
];

function paypalBase() {
  const env = String(PAYPAL_ENV.value() || "SANDBOX").toUpperCase();
  return env === "LIVE"
      ? "https://api-m.paypal.com"
      : "https://api-m.sandbox.paypal.com";
}

function allowedPlans() {
  const env = String(PAYPAL_ENV.value() || "SANDBOX").toUpperCase();
  return env === "LIVE" ? ALLOWED_PLANS_LIVE : ALLOWED_PLANS_SANDBOX;
}

function sendJson(res, code, obj) {
  res.status(code).set("content-type", "application/json").send(JSON.stringify(obj));
}

function normalizeStatus(status) {
  return String(status || "UNKNOWN").toUpperCase();
}

function isPremiumActiveStatus(status) {
  return normalizeStatus(status) === "ACTIVE";
}

function parseIsoDate(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d;
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

async function findUserDocRefByUsername(username) {
  const db = admin.firestore();
  const u = String(username || "").trim();
  const ul = u.toLowerCase();

  let snap = await db.collection("users").where("username_lower", "==", ul).limit(1).get();
  if (!snap.empty) return snap.docs[0].ref;

  snap = await db.collection("users").where("username", "==", u).limit(1).get();
  if (!snap.empty) return snap.docs[0].ref;

  return null;
}

async function getPayPalAccessToken(clientId, secret) {
  const basicAuth = Buffer.from(`${clientId}:${secret}`).toString("base64");
  const base = paypalBase();

  const resp = await fetch(`${base}/v1/oauth2/token`, {
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
  const base = paypalBase();

  const resp = await fetch(
      `${base}/v1/billing/subscriptions/${encodeURIComponent(subscriptionId)}`,
      {
        method: "GET",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
      }
  );

  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    throw new Error(`PayPal subscription error: ${resp.status} ${txt}`);
  }

  return resp.json();
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
        if (req.method !== "POST")
          return sendJson(res, 405, { status: "error", message: "method not allowed" });

        const body = req.body || {};
        const subscriptionId = String(body.subscriptionId || "").trim();
        const username = String(body.username || "").trim();
        const planId = String(body.planId || "").trim();

        if (!subscriptionId || !username || !planId) {
          return sendJson(res, 400, { status: "error", message: "missing data" });
        }

        const plans = allowedPlans();
        if (!plans.has(planId)) {
          return sendJson(res, 400, {
            status: "error",
            message: "plan not allowed",
            env: String(PAYPAL_ENV.value() || "SANDBOX"),
            planId,
          });
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

        // Plan-ID gegen PayPal prüfen
        const paypalPlanId = String(sub.plan_id || "").trim();
        if (!paypalPlanId) {
          return sendJson(res, 400, { status: "error", message: "paypal missing plan_id" });
        }
        if (paypalPlanId !== planId) {
          return sendJson(res, 400, {
            status: "error",
            message: "plan mismatch",
            planIdSent: planId,
            planIdPaypal: paypalPlanId,
          });
        }

        if (!isPremiumActiveStatus(paypalStatus)) {
          return sendJson(res, 400, {
            status: "error",
            message: `subscription not active: ${paypalStatus}`,
            paypalStatus,
          });
        }

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
            { merge: true }
        );

        return sendJson(res, 200, {
          status: "ok",
          env: String(PAYPAL_ENV.value() || "SANDBOX"),
          paypalStatus,
          premiumUntil: nextBilling.toISOString(),
        });
      } catch (e) {
        return sendJson(res, 500, { status: "error", message: String(e) });
      }
    }
);
