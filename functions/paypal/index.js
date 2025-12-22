// functions/paypal/index.js
// LIVE-only PayPal Subscriptions (produktionstauglich):
// - Keine Sandbox-Logik
// - Whitelist für LIVE Plan-IDs
// - Premium wird zuverlässig über PayPal WEBHOOK gesetzt/entzogen
// - Activate-Endpoint verknüpft subscriptionId <-> user und macht eine PayPal-Verify

const admin = require("firebase-admin");
admin.initializeApp();

const { onRequest } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");

const REGION = "us-central1";

// ---------- Secrets (in Firebase/Google Cloud setzen, NICHT .env) ----------
const PAYPAL_CLIENT_ID = defineSecret("Ab9P_0GJy0ZeHXkOLDfcbFmpCF_XYXIdSdSSjhF5yYVmflssYX7w90SGZmZv4ZFalIalWa4W1GScG1jQ"); // LIVE Client ID
const PAYPAL_SECRET = defineSecret("EAsN3_kZFN75S3uFg_B3tXPy35jzoIDbLuSZajZobRmcVHX9_Zq0gojcc1rTZqMjA4BB4z1mUoaSUg2m"); // LIVE Secret
const PAYPAL_WEBHOOK_ID = defineSecret("4CC86758J3461010H"); // Webhook-ID aus PayPal Dashboard (Live)

// ---------- LIVE CONFIG ----------
const PAYPAL_BASE = "https://api-m.paypal.com";

// Deine LIVE Plan IDs (nur diese dürfen Premium aktivieren)
const ALLOWED_PLANS_LIVE = new Set([
  "P-55588718AV729883XNE6MJ5Y", // PartyPin Premium – Monatlich
  "P-0WL99384633096336NE6WUSA", // PartyPin Jährlich
]);

const ALLOWED_ORIGINS = [
  "https://partypin-5dc3f.web.app",
  "https://partypin-5dc3f.firebaseapp.com",
];

// ---------- Helpers ----------
function sendJson(res, code, obj) {
  res.status(code).set("content-type", "application/json").send(JSON.stringify(obj));
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

function normalizeStatus(status) {
  return String(status || "UNKNOWN").trim().toUpperCase();
}

function parseIsoDate(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d;
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

// ---------- PayPal API ----------
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
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      }
  );

  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    throw new Error(`PayPal subscription error: ${resp.status} ${txt}`);
  }

  return resp.json();
}

// PayPal Webhook Signatur verifizieren (wichtig in Produktion)
async function verifyPayPalWebhookSignature({ token, webhookId, headers, rawBody, event }) {
  const payload = {
    auth_algo: headers["paypal-auth-algo"],
    cert_url: headers["paypal-cert-url"],
    transmission_id: headers["paypal-transmission-id"],
    transmission_sig: headers["paypal-transmission-sig"],
    transmission_time: headers["paypal-transmission-time"],
    webhook_id: webhookId,
    webhook_event: event,
  };

  // PayPal will rawBody als string (genau wie empfangen)
  // Wenn rawBody Buffer ist, in utf8 umwandeln:
  const _raw = Buffer.isBuffer(rawBody) ? rawBody.toString("utf8") : String(rawBody || "");
  // Wichtig: webhook_event muss dem JSON entsprechen, nicht dem string. Wir senden event-objekt.
  // rawBody wird hier nicht direkt als field geschickt; PayPal verifiziert mit webhook_event.

  const resp = await fetch(`${PAYPAL_BASE}/v1/notifications/verify-webhook-signature`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    throw new Error(`PayPal webhook verify error: ${resp.status} ${txt} rawBodyLen=${_raw.length}`);
  }

  const json = await resp.json();
  const status = normalizeStatus(json?.verification_status);
  return status === "SUCCESS";
}

// ---------- Firestore update helpers ----------
async function setPremiumBySubscriptionId(subscriptionId, fields) {
  const db = admin.firestore();

  // Du speicherst subscriptionId im Userdoc unter paypalSubscriptionId
  const snap = await db
      .collection("users")
      .where("paypalSubscriptionId", "==", subscriptionId)
      .limit(1)
      .get();

  if (snap.empty) return null;

  const ref = snap.docs[0].ref;
  await ref.set(
      {
        ...fields,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
  );
  return ref.id;
}

function premiumFieldsActive({ planId, status, nextBilling }) {
  const payload = {
    premium: true,
    premiumPlan: planId || null,
    paypalStatus: status || null,
    premiumSince: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (nextBilling) payload.premiumUntil = admin.firestore.Timestamp.fromDate(nextBilling);
  return payload;
}

function premiumFieldsInactive({ status }) {
  return {
    premium: false,
    paypalStatus: status || null,
    premiumRevokedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

// ---------- 1) Activate endpoint (client ruft das nach approve auf) ----------
exports.activatePayPalSubscription = onRequest(
    { region: REGION, secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET] },
    async (req, res) => {
      try {
        corsHeaders(req, res);
        if (req.method === "OPTIONS") return sendJson(res, 204, {});
        if (req.method !== "POST") return sendJson(res, 405, { status: "error", message: "method not allowed" });

        const body = req.body || {};
        const subscriptionId = String(body.subscriptionId || "").trim();
        const username = String(body.username || "").trim();
        const planIdSent = String(body.planId || "").trim();

        if (!subscriptionId || !username || !planIdSent) {
          return sendJson(res, 400, { status: "error", message: "missing data" });
        }

        // Plan-Whitelist (Production-Schutz)
        if (!ALLOWED_PLANS_LIVE.has(planIdSent)) {
          return sendJson(res, 400, { status: "error", message: "plan not allowed", planId: planIdSent });
        }

        const clientId = PAYPAL_CLIENT_ID.value();
        const secret = PAYPAL_SECRET.value();
        if (!clientId || !secret) {
          return sendJson(res, 500, { status: "error", message: "missing paypal secrets" });
        }

        // User finden
        const userRef = await findUserDocRefByUsername(username);
        if (!userRef) return sendJson(res, 404, { status: "error", message: "user not found" });

        // PayPal verify (damit niemand fake subscriptionId/planId posten kann)
        const token = await getPayPalAccessToken(clientId, secret);
        const sub = await getPayPalSubscription(subscriptionId, token);

        const paypalStatus = normalizeStatus(sub.status);
        const paypalPlanId = String(sub.plan_id || "").trim();

        if (!paypalPlanId) return sendJson(res, 400, { status: "error", message: "paypal missing plan_id" });
        if (paypalPlanId !== planIdSent) {
          return sendJson(res, 400, {
            status: "error",
            message: "plan mismatch",
            planIdSent,
            planIdPaypal: paypalPlanId,
          });
        }

        // In der Praxis kann es kurz APPROVED sein; Premium wird final über Webhook gesetzt.
        // Hier: verknüpfen + Status speichern (und Premium nur setzen wenn schon ACTIVE).
        const nextBilling = parseIsoDate(sub?.billing_info?.next_billing_time);
        const isActive = paypalStatus === "ACTIVE";

        await userRef.set(
            {
              paypalSubscriptionId: subscriptionId,
              paypalStatus,
              premiumPlan: paypalPlanId,
              premiumActivationRequestedAt: admin.firestore.FieldValue.serverTimestamp(),
              // Nur wenn wirklich ACTIVE ist, sofort premium=true setzen
              ...(isActive ? premiumFieldsActive({ planId: paypalPlanId, status: paypalStatus, nextBilling }) : {}),
              // Webhook wird es sicher finalisieren
              premiumPendingWebhook: !isActive,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true }
        );

        return sendJson(res, 200, {
          status: "ok",
          paypalStatus,
          premiumSetNow: isActive,
          premiumUntil: nextBilling ? nextBilling.toISOString() : null,
        });
      } catch (e) {
        console.error("[activatePayPalSubscription] error:", e);
        return sendJson(res, 500, { status: "error", message: String(e?.message || e) });
      }
    }
);

// ---------- 2) PayPal Webhook (setzt/entzieht Premium zuverlässig) ----------
exports.paypalWebhook = onRequest(
    { region: REGION, secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET, PAYPAL_WEBHOOK_ID] },
    async (req, res) => {
      try {
        // PayPal sendet POST
        if (req.method === "OPTIONS") return sendJson(res, 204, {});
        if (req.method !== "POST") return sendJson(res, 405, { status: "error", message: "method not allowed" });

        const clientId = PAYPAL_CLIENT_ID.value();
        const secret = PAYPAL_SECRET.value();
        const webhookId = PAYPAL_WEBHOOK_ID.value();
        if (!clientId || !secret || !webhookId) {
          return sendJson(res, 500, { status: "error", message: "missing paypal secrets/webhook id" });
        }

        const event = req.body || {};
        const eventType = String(event?.event_type || "").trim();

        // 1) Signatur verifizieren
        const token = await getPayPalAccessToken(clientId, secret);
        const ok = await verifyPayPalWebhookSignature({
          token,
          webhookId,
          headers: req.headers || {},
          rawBody: req.rawBody, // Firebase liefert rawBody
          event,
        });

        if (!ok) {
          console.error("[paypalWebhook] signature verify failed, eventType=", eventType);
          return sendJson(res, 400, { status: "error", message: "invalid signature" });
        }

        // 2) SubscriptionId extrahieren
        // Bei Billing Subscription Events ist es meist resource.id
        const subscriptionId = String(event?.resource?.id || "").trim();
        const planId = String(event?.resource?.plan_id || "").trim();
        const status = normalizeStatus(event?.resource?.status);

        if (!subscriptionId) {
          // PayPal sendet manchmal Events ohne resource.id, dann ignorieren
          return sendJson(res, 200, { status: "ok", ignored: true, reason: "missing subscriptionId" });
        }

        // 3) Plan-Schutz (nur unsere Plans dürfen Premium togglen)
        if (planId && !ALLOWED_PLANS_LIVE.has(planId)) {
          return sendJson(res, 200, { status: "ok", ignored: true, reason: "plan not allowed", planId });
        }

        // 4) Status-Handling (Praxis)
        // Wichtige Events:
        // - BILLING.SUBSCRIPTION.ACTIVATED => premium true
        // - BILLING.SUBSCRIPTION.CANCELLED / SUSPENDED / EXPIRED => premium false
        // - BILLING.SUBSCRIPTION.UPDATED => je nach status
        const dbUpdate = async (fields) => {
          const userId = await setPremiumBySubscriptionId(subscriptionId, fields);
          return userId;
        };

        let userId = null;

        if (eventType === "BILLING.SUBSCRIPTION.ACTIVATED") {
          // Optional: next billing time aus PayPal holen (sicherer)
          const sub = await getPayPalSubscription(subscriptionId, token).catch(() => null);
          const nextBilling = parseIsoDate(sub?.billing_info?.next_billing_time);

          userId = await dbUpdate({
            ...premiumFieldsActive({ planId: planId || sub?.plan_id, status: "ACTIVE", nextBilling }),
            premiumPendingWebhook: false,
          });
        } else if (
            eventType === "BILLING.SUBSCRIPTION.CANCELLED" ||
            eventType === "BILLING.SUBSCRIPTION.SUSPENDED" ||
            eventType === "BILLING.SUBSCRIPTION.EXPIRED"
        ) {
          userId = await dbUpdate({
            ...premiumFieldsInactive({ status: status || eventType }),
            premiumPendingWebhook: false,
          });
        } else if (eventType === "BILLING.SUBSCRIPTION.UPDATED") {
          // Wenn updated und status ACTIVE => premium true, sonst false
          const isActive = status === "ACTIVE";
          if (isActive) {
            const sub = await getPayPalSubscription(subscriptionId, token).catch(() => null);
            const nextBilling = parseIsoDate(sub?.billing_info?.next_billing_time);

            userId = await dbUpdate({
              ...premiumFieldsActive({ planId: planId || sub?.plan_id, status: "ACTIVE", nextBilling }),
              premiumPendingWebhook: false,
            });
          } else {
            userId = await dbUpdate({
              ...premiumFieldsInactive({ status: status || "UPDATED" }),
              premiumPendingWebhook: false,
            });
          }
        } else {
          // Andere Events akzeptieren aber ignorieren
          return sendJson(res, 200, { status: "ok", ignored: true, eventType });
        }

        return sendJson(res, 200, { status: "ok", eventType, subscriptionId, userId });
      } catch (e) {
        console.error("[paypalWebhook] error:", e);
        // PayPal will oft 200 sehen, aber bei echten Fehlern besser 500:
        return sendJson(res, 500, { status: "error", message: String(e?.message || e) });
      }
    }
);

// ---------- 3) Safety Net: täglicher Sync (falls Webhook mal ausfällt) ----------
exports.syncPayPalPremiumDaily = onSchedule(
    { region: REGION, schedule: "every day 03:00", secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET] },
    async () => {
      const db = admin.firestore();

      const clientId = PAYPAL_CLIENT_ID.value();
      const secret = PAYPAL_SECRET.value();
      if (!clientId || !secret) {
        console.error("[syncPayPalPremiumDaily] missing paypal secrets");
        return;
      }

      const token = await getPayPalAccessToken(clientId, secret);

      // Nutzer mit premium=true und subscriptionId prüfen
      const snap = await db
          .collection("users")
          .where("premium", "==", true)
          .where("paypalSubscriptionId", "!=", null)
          .limit(200)
          .get();

      if (snap.empty) return;

      const batch = db.batch();

      for (const doc of snap.docs) {
        const data = doc.data() || {};
        const subId = String(data.paypalSubscriptionId || "").trim();
        if (!subId) continue;

        try {
          const sub = await getPayPalSubscription(subId, token);
          const status = normalizeStatus(sub.status);
          const planId = String(sub.plan_id || "").trim();
          const nextBilling = parseIsoDate(sub?.billing_info?.next_billing_time);

          // Nur unsere Plans
          if (planId && !ALLOWED_PLANS_LIVE.has(planId)) {
            batch.set(
                doc.ref,
                {
                  ...premiumFieldsInactive({ status: "PLAN_NOT_ALLOWED" }),
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
            );
            continue;
          }

          if (status === "ACTIVE") {
            batch.set(
                doc.ref,
                {
                  ...premiumFieldsActive({ planId, status, nextBilling }),
                  premiumPendingWebhook: false,
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
            );
          } else {
            batch.set(
                doc.ref,
                {
                  ...premiumFieldsInactive({ status }),
                  premiumPendingWebhook: false,
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
            );
          }
        } catch (err) {
          console.error("[syncPayPalPremiumDaily] user", doc.id, "error:", err);
        }
      }

      await batch.commit();
    }
);
