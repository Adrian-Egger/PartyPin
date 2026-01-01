/* eslint-disable */

/**
 * functions/paypal/index.js
 * LIVE Subscriptions (username-based, NO Firebase Auth)
 * - createPayPalCheckout: erstellt Subscription + approveLink
 * - paypalWebhook: verifiziert Signatur + setzt premium true/false
 * - syncPayPalPremiumDaily: Safety Net
 */

const admin = require("firebase-admin");
if (!admin.apps.length) admin.initializeApp();

const { onRequest } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "us-central1";
const PAYPAL_BASE_URL = "https://api-m.paypal.com";

// Secrets (nur Namen)
const PAYPAL_CLIENT_ID = defineSecret("PAYPAL_CLIENT_ID");
const PAYPAL_SECRET = defineSecret("PAYPAL_SECRET");
const PAYPAL_WEBHOOK_ID = defineSecret("PAYPAL_WEBHOOK_ID");

// LIVE Plan IDs (Whitelist)
const ALLOWED_PLANS_LIVE = new Set([
    "P-55588718AV729883XNE6MJ5Y",
    "P-0WL99384633096336NE6WUSA",
]);

// Deep Links
const RETURN_URL = "partypin://paypal-return";
const CANCEL_URL = "partypin://paypal-cancel";

// CORS
const ALLOWED_ORIGINS = [
    "https://partypin-5dc3f.web.app",
    "https://partypin-5dc3f.firebaseapp.com",
    "http://localhost:5173",
    "http://localhost:3000",
];

function setCors(req, res) {
    const origin = req.headers?.origin;
    if (origin && ALLOWED_ORIGINS.includes(origin)) {
        res.set("Access-Control-Allow-Origin", origin);
        res.set("Vary", "Origin");
    }
    res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
}

function sendJson(res, code, obj) {
    res.status(code).set("content-type", "application/json").send(JSON.stringify(obj));
}

function normalizeStatus(status) {
    return String(status || "UNKNOWN").trim().toUpperCase();
}

function parseIsoDate(iso) {
    if (!iso) return null;
    const d = new Date(iso);
    return Number.isNaN(d.getTime()) ? null : d;
}

function getHeaderCI(headers, name) {
    if (!headers) return undefined;
    const lower = name.toLowerCase();
    return headers[lower] || headers[name];
}

// ---------- PayPal API ----------
async function getPayPalAccessToken() {
    const clientId = (PAYPAL_CLIENT_ID.value() || "").trim();
    const secret = (PAYPAL_SECRET.value() || "").trim();
    if (!clientId || !secret) throw new Error("PayPal-Credentials nicht gesetzt (Secrets)");

    const basicAuth = Buffer.from(`${clientId}:${secret}`).toString("base64");

    const resp = await fetch(`${PAYPAL_BASE_URL}/v1/oauth2/token`, {
        method: "POST",
        headers: {
            Authorization: `Basic ${basicAuth}`,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        body: "grant_type=client_credentials",
    });

    const txt = await resp.text().catch(() => "");
    if (!resp.ok) throw new Error(`PayPal token error: ${resp.status} ${txt}`.slice(0, 900));

    const json = JSON.parse(txt);
    const token = String(json.access_token || "");
    if (!token) throw new Error("PayPal token missing");
    return token;
}

async function createPayPalSubscription({ token, planId, username }) {
    const body = {
        plan_id: planId,
        custom_id: username,
        application_context: {
            brand_name: "PartyPin",
            locale: "de-DE",
            user_action: "SUBSCRIBE_NOW",
            return_url: RETURN_URL,
            cancel_url: CANCEL_URL,
        },
    };

    const resp = await fetch(`${PAYPAL_BASE_URL}/v1/billing/subscriptions`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });

    const txt = await resp.text().catch(() => "");
    if (!resp.ok) throw new Error(`PayPal create subscription error: ${resp.status} ${txt}`.slice(0, 900));
    return JSON.parse(txt);
}

async function getPayPalSubscription(subscriptionId, token) {
    const resp = await fetch(`${PAYPAL_BASE_URL}/v1/billing/subscriptions/${encodeURIComponent(subscriptionId)}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    });

    const txt = await resp.text().catch(() => "");
    if (!resp.ok) throw new Error(`PayPal subscription error: ${resp.status} ${txt}`.slice(0, 900));
    return JSON.parse(txt);
}

// ---------- Webhook Signature Verify ----------
async function verifyPayPalWebhookSignature({ token, webhookId, headers, event }) {
    const payload = {
        auth_algo: getHeaderCI(headers, "paypal-auth-algo"),
        cert_url: getHeaderCI(headers, "paypal-cert-url"),
        transmission_id: getHeaderCI(headers, "paypal-transmission-id"),
        transmission_sig: getHeaderCI(headers, "paypal-transmission-sig"),
        transmission_time: getHeaderCI(headers, "paypal-transmission-time"),
        webhook_id: webhookId,
        webhook_event: event,
    };

    const resp = await fetch(`${PAYPAL_BASE_URL}/v1/notifications/verify-webhook-signature`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify(payload),
    });

    const txt = await resp.text().catch(() => "");
    if (!resp.ok) throw new Error(`PayPal webhook verify error: ${resp.status} ${txt}`.slice(0, 900));

    const json = JSON.parse(txt);
    return normalizeStatus(json?.verification_status) === "SUCCESS";
}

// ---------- Firestore Premium Fields ----------
function premiumFieldsActive({ planId, status, nextBilling }) {
    const payload = {
        premium: true,
        premiumPlan: planId || null,
        paypalStatus: status || null,
        premiumSince: FieldValue.serverTimestamp(),
    };
    if (nextBilling) payload.premiumUntil = admin.firestore.Timestamp.fromDate(nextBilling);
    return payload;
}

function premiumFieldsInactive({ status }) {
    return {
        premium: false,
        paypalStatus: status || null,
        premiumRevokedAt: FieldValue.serverTimestamp(),
        premiumUntil: FieldValue.delete(),
    };
}

// =======================
// 1) createPayPalCheckout
// =======================
exports.createPayPalCheckout = onRequest(
    { region: REGION, invoker: "public", secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET] },
    async (req, res) => {
        setCors(req, res);
        if (req.method === "OPTIONS") return sendJson(res, 204, {});
        if (req.method !== "POST") return sendJson(res, 405, { status: "error", message: "Nur POST erlaubt" });

        try {
            const body = req.body || {};
            const username = String(body.username || "").trim();
            const planId = String(body.planId || "").trim();

            if (!username) return sendJson(res, 400, { status: "error", message: "username fehlt" });
            if (!planId) return sendJson(res, 400, { status: "error", message: "planId fehlt" });
            if (!ALLOWED_PLANS_LIVE.has(planId)) {
                return sendJson(res, 400, { status: "error", message: "plan not allowed", planId });
            }

            const userRef = db.doc(`users/${username}`);

            await userRef.set(
                {
                    premiumPendingWebhook: true,
                    premiumPlan: planId,
                    updatedAt: FieldValue.serverTimestamp(),
                },
                { merge: true }
            );

            const token = await getPayPalAccessToken();
            const sub = await createPayPalSubscription({ token, planId, username });

            const subscriptionId = String(sub?.id || "").trim();
            const approveLink = (sub.links || []).find((l) => l.rel === "approve")?.href || "";

            if (!subscriptionId || !approveLink) {
                return sendJson(res, 500, { status: "error", message: "paypal missing approve link/id" });
            }

            await db.doc(`paypalSubscriptions/${subscriptionId}`).set(
                {
                    username,
                    planId,
                    status: normalizeStatus(sub.status),
                    createdAt: FieldValue.serverTimestamp(),
                },
                { merge: true }
            );

            await userRef.set(
                {
                    paypalSubscriptionId: subscriptionId,
                    paypalStatus: normalizeStatus(sub.status),
                    updatedAt: FieldValue.serverTimestamp(),
                },
                { merge: true }
            );

            return sendJson(res, 200, { status: "ok", approveLink, subscriptionId });
        } catch (e) {
            console.error("[createPayPalCheckout] error:", e);
            return sendJson(res, 500, { status: "error", message: String(e?.message || e) });
        }
    }
);

// =======================
// 2) paypalWebhook
// =======================
exports.paypalWebhook = onRequest(
    { region: REGION, invoker: "public", secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET, PAYPAL_WEBHOOK_ID] },
    async (req, res) => {
        setCors(req, res);
        if (req.method === "OPTIONS") return sendJson(res, 204, {});
        if (req.method !== "POST") return sendJson(res, 405, { status: "error", message: "Only POST" });

        const h = req.headers || {};
        const event = req.body || {};
        const eventType = String(event?.event_type || "").trim();
        const eventId = String(event?.id || "").trim();

        // Debug
        console.log("[paypalWebhook] HIT", { eventType, eventId, headers: h });

        // PayPal signature headers
        const authAlgo = getHeaderCI(h, "paypal-auth-algo");
        const certUrl = getHeaderCI(h, "paypal-cert-url");
        const transmissionId = getHeaderCI(h, "paypal-transmission-id");
        const transmissionSig = getHeaderCI(h, "paypal-transmission-sig");
        const transmissionTime = getHeaderCI(h, "paypal-transmission-time");

        // HARD GUARD: bei manuellen Tests NIE verify callen
        const missing = [];
        if (!authAlgo) missing.push("paypal-auth-algo");
        if (!certUrl) missing.push("paypal-cert-url");
        if (!transmissionId) missing.push("paypal-transmission-id");
        if (!transmissionSig) missing.push("paypal-transmission-sig");
        if (!transmissionTime) missing.push("paypal-transmission-time");

        if (missing.length) {
            console.log("[paypalWebhook] Missing PayPal headers -> ignored", { missing });
            return sendJson(res, 200, { status: "ok", ignored: true, reason: "missing_paypal_headers", missing });
        }

        try {
            const webhookId = (PAYPAL_WEBHOOK_ID.value() || "").trim();
            if (!webhookId) return sendJson(res, 500, { status: "error", message: "PAYPAL_WEBHOOK_ID fehlt" });

            const token = await getPayPalAccessToken();

            // 1) Verify signature
            const verified = await verifyPayPalWebhookSignature({
                token,
                webhookId,
                headers: h,
                event,
            });

            if (!verified) {
                console.log("[paypalWebhook] invalid signature", { eventType, eventId });
                return sendJson(res, 400, { status: "error", message: "invalid signature" });
            }

            // 2) Idempotenz
            if (eventId) {
                const ref = db.doc(`paypalWebhookEvents/${eventId}`);
                try {
                    await ref.create({ eventType, receivedAt: FieldValue.serverTimestamp() });
                } catch (_) {
                    return sendJson(res, 200, { status: "ok", alreadyProcessed: true, eventType });
                }
            }

            const r = event?.resource || {};
            const subscriptionId = String(r.id || r.billing_agreement_id || "").trim();
            const planId = String(r.plan_id || "").trim();
            const status = normalizeStatus(r.status);
            const username = String(r.custom_id || "").trim();

            if (planId && !ALLOWED_PLANS_LIVE.has(planId)) {
                return sendJson(res, 200, { status: "ok", ignored: true, reason: "plan not allowed", planId });
            }
            if (!username) {
                return sendJson(res, 200, { status: "ok", ignored: true, reason: "missing custom_id(username)" });
            }

            const userRef = db.doc(`users/${username}`);

            const applyActive = async () => {
                const sub = subscriptionId ? await getPayPalSubscription(subscriptionId, token).catch(() => null) : null;
                const nextBilling = parseIsoDate(sub?.billing_info?.next_billing_time);
                const realPlan = planId || String(sub?.plan_id || "").trim();

                if (realPlan && !ALLOWED_PLANS_LIVE.has(realPlan)) {
                    await userRef.set(
                        {
                            paypalSubscriptionId: subscriptionId || null,
                            ...premiumFieldsInactive({ status: "PLAN_NOT_ALLOWED" }),
                            premiumPendingWebhook: false,
                            updatedAt: FieldValue.serverTimestamp(),
                        },
                        { merge: true }
                    );
                    return;
                }

                await userRef.set(
                    {
                        paypalSubscriptionId: subscriptionId || null,
                        ...premiumFieldsActive({ planId: realPlan, status: "ACTIVE", nextBilling }),
                        premiumPendingWebhook: false,
                        updatedAt: FieldValue.serverTimestamp(),
                    },
                    { merge: true }
                );

                if (subscriptionId) {
                    await db.doc(`paypalSubscriptions/${subscriptionId}`).set(
                        { username, planId: realPlan || null, status: "ACTIVE", updatedAt: FieldValue.serverTimestamp() },
                        { merge: true }
                    );
                }
            };

            const applyInactive = async (why) => {
                await userRef.set(
                    {
                        paypalSubscriptionId: subscriptionId || null,
                        ...premiumFieldsInactive({ status: why }),
                        premiumPendingWebhook: false,
                        updatedAt: FieldValue.serverTimestamp(),
                    },
                    { merge: true }
                );

                if (subscriptionId) {
                    await db.doc(`paypalSubscriptions/${subscriptionId}`).set(
                        { status: why, updatedAt: FieldValue.serverTimestamp() },
                        { merge: true }
                    );
                }
            };

            if (eventType === "BILLING.SUBSCRIPTION.ACTIVATED" || eventType === "BILLING.SUBSCRIPTION.RE-ACTIVATED") {
                await applyActive();
            } else if (
                eventType === "BILLING.SUBSCRIPTION.CANCELLED" ||
                eventType === "BILLING.SUBSCRIPTION.SUSPENDED" ||
                eventType === "BILLING.SUBSCRIPTION.EXPIRED"
            ) {
                await applyInactive(status || eventType);
            } else if (eventType === "BILLING.SUBSCRIPTION.UPDATED") {
                if (status === "ACTIVE") await applyActive();
                else await applyInactive(status || "UPDATED");
            } else {
                return sendJson(res, 200, { status: "ok", ignored: true, eventType });
            }

            return sendJson(res, 200, { status: "ok", eventType, username, subscriptionId });
        } catch (e) {
            console.error("[paypalWebhook] error:", e);
            return sendJson(res, 500, { status: "error", message: String(e?.message || e) });
        }
    }
);

// =======================
// 3) daily sync
// =======================
exports.syncPayPalPremiumDaily = onSchedule(
    { region: REGION, schedule: "every day 03:00", secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET] },
    async () => {
        const token = await getPayPalAccessToken();

        const snap = await db
            .collection("users")
            .where("premium", "==", true)
            .where("paypalSubscriptionId", "!=", null)
            .limit(300)
            .get();

        if (snap.empty) return;

        const batch = db.batch();

        for (const doc of snap.docs) {
            const data = doc.data() || {};
            const subId = String(data.paypalSubscriptionId || "").trim();
            if (!subId) continue;

            try {
                const sub = await getPayPalSubscription(subId, token);
                const st = normalizeStatus(sub.status);
                const plan = String(sub.plan_id || "").trim();
                const nextBilling = parseIsoDate(sub?.billing_info?.next_billing_time);

                if (plan && !ALLOWED_PLANS_LIVE.has(plan)) {
                    batch.set(
                        doc.ref,
                        { ...premiumFieldsInactive({ status: "PLAN_NOT_ALLOWED" }), premiumPendingWebhook: false, updatedAt: FieldValue.serverTimestamp() },
                        { merge: true }
                    );
                    continue;
                }

                if (st === "ACTIVE") {
                    batch.set(
                        doc.ref,
                        { ...premiumFieldsActive({ planId: plan, status: st, nextBilling }), premiumPendingWebhook: false, updatedAt: FieldValue.serverTimestamp() },
                        { merge: true }
                    );
                } else {
                    batch.set(
                        doc.ref,
                        { ...premiumFieldsInactive({ status: st }), premiumPendingWebhook: false, updatedAt: FieldValue.serverTimestamp() },
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
