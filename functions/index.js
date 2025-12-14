/* eslint-disable */

const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");

if (!admin.apps.length) admin.initializeApp();

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

// PayPal Sandbox (Production wäre: https://api-m.paypal.com)
const PAYPAL_BASE_URL = "https://api-m.sandbox.paypal.com";

// Secrets
const PAYPAL_CLIENT_ID = defineSecret("PAYPAL_CLIENT_ID");
const PAYPAL_SECRET = defineSecret("PAYPAL_SECRET");
const PAYPAL_WEBHOOK_ID = defineSecret("PAYPAL_WEBHOOK_ID");


// ====== CORS (stell hier DEINE Domains ein) ======
const ALLOWED_ORIGINS = [
  "http://localhost:5173",
  "http://localhost:3000",
  // "https://deine-domain.at",
];

function setCors(req, res) {
  const origin = req.headers.origin;
  if (origin && ALLOWED_ORIGINS.indexOf(origin) !== -1) {
    res.set("Access-Control-Allow-Origin", origin);
  } else {
    res.set("Access-Control-Allow-Origin", "null");
  }
  res.set("Vary", "Origin");
  res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
}

// ====== Subscription Plan IDs (HIER DEINE P-... EINTRAGEN) ======
const PLAN_IDS = {
  monthly: "P-55588718AV729883XNE6MJ5Y",
  yearly: "P-0WL99384633096336NE6WUSA",
};

// -------------------------------------------------------------
// Firebase Auth: ID Token prüfen (Authorization: Bearer <token>)
// -------------------------------------------------------------
async function requireAuth(req) {
  const authHeader = req.headers.authorization || "";
  if (!authHeader.startsWith("Bearer ")) {
    const err = new Error("Missing Authorization Bearer token");
    err.code = "auth_missing";
    throw err;
  }
  const idToken = authHeader.substring("Bearer ".length).trim();
  return await admin.auth().verifyIdToken(idToken); // { uid, ... }
}

// -------------------------------------------------------------
// PayPal Access Token holen
// -------------------------------------------------------------
async function getPayPalAccessToken() {
  const clientId = (PAYPAL_CLIENT_ID.value() || "").trim();
  const secret = (PAYPAL_SECRET.value() || "").trim();
  if (!clientId || !secret) throw new Error("PayPal-Credentials nicht gesetzt");

  const auth = Buffer.from(clientId + ":" + secret).toString("base64");

  const res = await fetch(PAYPAL_BASE_URL + "/v1/oauth2/token", {
    method: "POST",
    headers: {
      Authorization: "Basic " + auth,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });

  const text = await res.text();
  if (!res.ok) throw new Error("PayPal OAuth-Fehler: " + text);

  return JSON.parse(text).access_token;
}

// -------------------------------------------------------------
// createPayPalSubscription
// - Client sendet nur { plan: "monthly"|"yearly" }
// - User wird aus Firebase Auth UID genommen
// - PayPal subscription bekommt custom_id = uid
// - Firestore: paypalSubscriptions/{subscriptionId} + users/{uid} updaten
// -------------------------------------------------------------
exports.createPayPalSubscription = onRequest(
    { region: "us-central1", secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET, PAYPAL_WEBHOOK_ID] },
    async (req, res) => {
      setCors(req, res);
      if (req.method === "OPTIONS") return res.status(204).send("");
      if (req.method !== "POST") return res.status(405).json({ error: "Nur POST erlaubt" });

      try {
        const decoded = await requireAuth(req);
        const uid = decoded.uid;

        const planKey = String((req.body || {}).plan || "").trim();
        const planId = PLAN_IDS[planKey];
        if (!planId) return res.status(400).json({ error: "Ungültiger plan" });

        const accessToken = await getPayPalAccessToken();

        const subRes = await fetch(PAYPAL_BASE_URL + "/v1/billing/subscriptions", {
          method: "POST",
          headers: {
            Authorization: "Bearer " + accessToken,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            plan_id: planId,
            custom_id: uid, // Bindung an User
            application_context: {
              brand_name: "PartyPin",
              user_action: "SUBSCRIBE_NOW",
              return_url: "https://example.com/success",
              cancel_url: "https://example.com/cancel",
            },
          }),
        });

        const subText = await subRes.text();
        if (!subRes.ok) throw new Error("PayPal Subscription Fehler: " + subText);

        const subData = JSON.parse(subText);
        const subscriptionId = subData.id;

        // approve link
        let approveLink = null;
        if (subData.links && subData.links.length) {
          for (let i = 0; i < subData.links.length; i++) {
            const l = subData.links[i];
            if (l && l.rel === "approve" && l.href) {
              approveLink = l.href;
              break;
            }
          }
        }

        // Mapping subscription -> uid speichern
        await db.collection("paypalSubscriptions").doc(subscriptionId).set(
            {
              uid,
              planKey,
              planId,
              status: subData.status || "APPROVAL_PENDING",
              createdAt: FieldValue.serverTimestamp(),
            },
            { merge: true }
        );

        // User markieren (pending)
        await db.collection("users").doc(uid).set(
            {
              paypalSubscriptionId: subscriptionId,
              premiumPlan: planKey,
              paypalSubscriptionStatus: subData.status || "APPROVAL_PENDING",
            },
            { merge: true }
        );

        return res.status(200).json({
          subscriptionId,
          approveLink,
          status: subData.status || null,
        });
      } catch (err) {
        console.error("createPayPalSubscription Fehler:", err);
        return res.status(401).json({ error: err.message || "Fehler" });
      }
    }
);

// -------------------------------------------------------------
// cancelPayPalSubscription
// - Client sendet { subscriptionId }
// - Auth required, subscription muss dem uid gehören
// -------------------------------------------------------------
exports.cancelPayPalSubscription = onRequest(
    { region: "us-central1", secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET, PAYPAL_WEBHOOK_ID] },
    async (req, res) => {
      setCors(req, res);
      if (req.method === "OPTIONS") return res.status(204).send("");
      if (req.method !== "POST") return res.status(405).json({ error: "Nur POST erlaubt" });

      try {
        const decoded = await requireAuth(req);
        const uid = decoded.uid;

        const subscriptionId = String((req.body || {}).subscriptionId || "").trim();
        if (!subscriptionId) return res.status(400).json({ error: "subscriptionId fehlt" });

        const subRef = db.collection("paypalSubscriptions").doc(subscriptionId);
        const subSnap = await subRef.get();
        if (!subSnap.exists) return res.status(404).json({ error: "Unbekannte Subscription" });

        const sub = subSnap.data() || {};
        if (sub.uid !== uid) return res.status(403).json({ error: "Subscription gehört nicht dir" });

        const accessToken = await getPayPalAccessToken();

        const cancelRes = await fetch(
            PAYPAL_BASE_URL + "/v1/billing/subscriptions/" + subscriptionId + "/cancel",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer " + accessToken,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({ reason: "User requested cancellation" }),
            }
        );

        const cancelText = await cancelRes.text();
        if (!cancelRes.ok && cancelRes.status !== 204) {
          throw new Error("PayPal cancel Fehler: " + cancelText);
        }

        await subRef.set({ status: "CANCELLED", updatedAt: FieldValue.serverTimestamp() }, { merge: true });

        // Premium wird endgültig durch Webhook gesteuert;
        // du kannst hier optional schon UI-mäßig downgraden:
        await db.collection("users").doc(uid).set(
            { premium: false, paypalSubscriptionStatus: "CANCELLED" },
            { merge: true }
        );

        return res.status(200).json({ status: "ok" });
      } catch (err) {
        console.error("cancelPayPalSubscription Fehler:", err);
        return res.status(401).json({ error: err.message || "Fehler" });
      }
    }
);

// -------------------------------------------------------------
// paypalWebhook (Pflicht für Subscriptions)
// - Verifiziert Signatur via verify-webhook-signature
// - Setzt premium true/false anhand Events
// -------------------------------------------------------------
exports.paypalWebhook = onRequest(
    { region: "us-central1", secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET, PAYPAL_WEBHOOK_ID] },
    async (req, res) => {
      if (req.method !== "POST") return res.status(405).send("Only POST");

      try {
        const webhookId = (PAYPAL_WEBHOOK_ID.value() || "").trim();
        if (!webhookId) throw new Error("PAYPAL_WEBHOOK_ID fehlt");

        const event = req.body || {};
        const eventType = event.event_type || null;

        // PayPal headers
        const transmissionId = req.header("PAYPAL-TRANSMISSION-ID");
        const transmissionTime = req.header("PAYPAL-TRANSMISSION-TIME");
        const certUrl = req.header("PAYPAL-CERT-URL");
        const authAlgo = req.header("PAYPAL-AUTH-ALGO");
        const transmissionSig = req.header("PAYPAL-TRANSMISSION-SIG");

        if (!transmissionId || !transmissionTime || !certUrl || !authAlgo || !transmissionSig) {
          console.error("Webhook Header fehlen");
          return res.status(400).send("Missing PayPal headers");
        }

        // 1) Signatur verifizieren
        const accessToken = await getPayPalAccessToken();

        const verifyRes = await fetch(PAYPAL_BASE_URL + "/v1/notifications/verify-webhook-signature", {
          method: "POST",
          headers: {
            Authorization: "Bearer " + accessToken,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            auth_algo: authAlgo,
            cert_url: certUrl,
            transmission_id: transmissionId,
            transmission_sig: transmissionSig,
            transmission_time: transmissionTime,
            webhook_id: webhookId,
            webhook_event: event,
          }),
        });

        const verifyText = await verifyRes.text();
        if (!verifyRes.ok) {
          console.error("Webhook verify HTTP Fehler:", verifyText);
          return res.status(400).send("Verify failed");
        }

        const verifyData = JSON.parse(verifyText);
        if (verifyData.verification_status !== "SUCCESS") {
          console.error("Webhook verify != SUCCESS:", verifyData);
          return res.status(400).send("Invalid signature");
        }

        // 2) Idempotenz: Event-ID nur einmal verarbeiten
        const eventId = String(event.id || "");
        if (eventId) {
          const already = await db.collection("paypalWebhookEvents").doc(eventId).get();
          if (already.exists) return res.status(200).send("ok_already_processed");
          await db.collection("paypalWebhookEvents").doc(eventId).set({
            eventType,
            receivedAt: FieldValue.serverTimestamp(),
          });
        }

        // 3) SubscriptionId & UID zuordnen
        let subscriptionId = null;
        let uid = null;

        // subscription events
        if (event.resource && event.resource.id && String(event.resource.id).startsWith("I-")) {
          subscriptionId = event.resource.id;
        }
        // payment sale events (oft billing_agreement_id)
        if (!subscriptionId && event.resource && event.resource.billing_agreement_id) {
          subscriptionId = event.resource.billing_agreement_id;
        }

        // uid bevorzugt aus custom_id, sonst aus DB mapping
        if (event.resource && event.resource.custom_id) uid = event.resource.custom_id;

        if (subscriptionId) {
          const subSnap = await db.collection("paypalSubscriptions").doc(subscriptionId).get();
          if (subSnap.exists) {
            const sub = subSnap.data() || {};
            if (!uid) uid = sub.uid;
          }
        }

        if (!uid) {
          console.error("Kein uid zuordenbar", { eventType, subscriptionId });
          return res.status(200).send("ok_no_uid");
        }

        const userRef = db.collection("users").doc(uid);

        // 4) Event handling
        if (eventType === "BILLING.SUBSCRIPTION.ACTIVATED") {
          if (subscriptionId) {
            await db.collection("paypalSubscriptions").doc(subscriptionId).set(
                { status: "ACTIVE", updatedAt: FieldValue.serverTimestamp() },
                { merge: true }
            );
          }
          await userRef.set(
              { premium: true, paypalSubscriptionStatus: "ACTIVE", paypalSubscriptionId: subscriptionId || null },
              { merge: true }
          );
        }

        if (
            eventType === "BILLING.SUBSCRIPTION.CANCELLED" ||
            eventType === "BILLING.SUBSCRIPTION.SUSPENDED" ||
            eventType === "BILLING.SUBSCRIPTION.EXPIRED"
        ) {
          if (subscriptionId) {
            await db.collection("paypalSubscriptions").doc(subscriptionId).set(
                { status: "INACTIVE", updatedAt: FieldValue.serverTimestamp() },
                { merge: true }
            );
          }
          await userRef.set(
              { premium: false, paypalSubscriptionStatus: "INACTIVE" },
              { merge: true }
          );
        }

        if (eventType === "PAYMENT.SALE.COMPLETED") {
          // Zahlung ok -> Premium bleibt an
          await userRef.set(
              { premium: true, lastPaymentAt: FieldValue.serverTimestamp() },
              { merge: true }
          );
        }

        if (eventType === "PAYMENT.SALE.DENIED") {
          // hart: sofort aus (optional: grace period einbauen)
          await userRef.set(
              { premium: false, paypalSubscriptionStatus: "PAYMENT_FAILED" },
              { merge: true }
          );
        }

        return res.status(200).send("ok");
      } catch (err) {
        console.error("paypalWebhook Fehler:", err);
        return res.status(500).send("error");
      }
    }
);
