/* eslint-disable */
/**
 * ==================================================
 * functions/TicketOrderPayPal/captureTicketOrder/index.js
 * LIVE-ready, ownership checks (expectedCustomId), idempotent, robust
 *
 * Du musst NUR noch:
 * 1) Secret PAYPAL_CLIENT_ID setzen (LIVE)
 * 2) Secret PAYPAL_SECRET setzen (LIVE)
 * ==================================================
 */

const admin = require("firebase-admin");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret, defineString } = require("firebase-functions/params");

const PAYPAL_CLIENT_ID = defineSecret("PAYPAL_CLIENT_ID");
const PAYPAL_SECRET = defineSecret("PAYPAL_SECRET");

// live | sandbox (Default LIVE) – muss zum createTicketOrder passen
const PAYPAL_ENV = defineString("PAYPAL_ENV", { default: "live" });

function ensureAdmin() {
    if (!admin.apps.length) admin.initializeApp();
}

function paypalBaseUrl() {
    return PAYPAL_ENV.value() === "sandbox"
        ? "https://api-m.sandbox.paypal.com"
        : "https://api-m.paypal.com";
}

async function paypalFetch(path, { method = "GET", headers = {}, body } = {}) {
    const res = await fetch(`${paypalBaseUrl()}${path}`, { method, headers, body });
    const text = await res.text().catch(() => "");
    let json = null;
    try {
        json = text ? JSON.parse(text) : null;
    } catch (_) {}
    return { ok: res.ok, status: res.status, text, json };
}

async function getPayPalAccessToken() {
    const clientId = String(PAYPAL_CLIENT_ID.value() || "").trim();
    const secret = String(PAYPAL_SECRET.value() || "").trim();
    if (!clientId || !secret) throw new HttpsError("failed-precondition", "PAYPAL_CLIENT_ID/PAYPAL_SECRET fehlen.");

    const auth = Buffer.from(`${clientId}:${secret}`).toString("base64");

    const { ok, status, text, json } = await paypalFetch("/v1/oauth2/token", {
        method: "POST",
        headers: {
            Authorization: `Basic ${auth}`,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        body: "grant_type=client_credentials",
    });

    if (!ok) throw new HttpsError("internal", `PayPal OAuth Fehler (${status}): ${String(text || "").slice(0, 900)}`);

    const token = String(json?.access_token || "").trim();
    if (!token) throw new HttpsError("internal", "Kein access_token erhalten.");
    return token;
}

function extractOrderInfo(json) {
    const status = String(json?.status || "").toUpperCase();
    const pu0 = (json?.purchase_units || [])[0] || null;

    const captureId =
        pu0?.payments?.captures?.[0]?.id ||
        pu0?.payments?.authorizations?.[0]?.id ||
        null;

    const customId = pu0?.custom_id || null;

    return {
        raw: json,
        status,
        isCompleted: status === "COMPLETED",
        captureId,
        payerEmail: json?.payer?.email_address || null,
        payerId: json?.payer?.payer_id || null,
        customId,
    };
}

async function getOrder(orderId, accessToken) {
    const { ok, status, text, json } = await paypalFetch(`/v2/checkout/orders/${encodeURIComponent(orderId)}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    });

    if (!ok) {
        throw new HttpsError("failed-precondition", `PayPal GET order Fehler (${status}): ${String(text || "").slice(0, 900)}`);
    }
    return extractOrderInfo(json);
}

async function captureOrder(orderId, accessToken) {
    const { ok, status, text, json } = await paypalFetch(`/v2/checkout/orders/${encodeURIComponent(orderId)}/capture`, {
        method: "POST",
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    });

    if (!ok) {
        const msg = String(text || "");
        const maybeAlreadyCaptured =
            status === 422 &&
            (msg.includes("ORDER_ALREADY_CAPTURED") ||
                msg.includes("ORDER_ALREADY_COMPLETED") ||
                msg.toLowerCase().includes("already been captured"));

        if (maybeAlreadyCaptured) return { alreadyCaptured: true };
        throw new HttpsError("failed-precondition", `PayPal Capture Fehler (${status}): ${String(text || "").slice(0, 900)}`);
    }

    return { alreadyCaptured: false, cap: extractOrderInfo(json) };
}

exports.captureTicketOrder = onCall(
    { region: "europe-west1", secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET] },
    async (request) => {
        ensureAdmin();
        const db = admin.firestore();

        const uid = request.auth?.uid;
        if (!uid) throw new HttpsError("unauthenticated", "Login required.");

        const partyId = String(request.data?.partyId || "").trim();
        const orderId = String(request.data?.orderId || "").trim();
        if (!partyId) throw new HttpsError("invalid-argument", "partyId fehlt.");
        if (!orderId) throw new HttpsError("invalid-argument", "orderId fehlt.");

        const ticketRef = db.doc(`Party/${partyId}/tickets/${uid}`);
        const paypalOrderRef = db.doc(`paypalTicketOrders/${orderId}`);

        const ticketSnap = await ticketRef.get();
        if (!ticketSnap.exists) throw new HttpsError("failed-precondition", "Ticket nicht gefunden.");

        const ticket = ticketSnap.data() || {};
        const savedOrderId = String(ticket.orderId || "").trim();
        if (!savedOrderId) throw new HttpsError("failed-precondition", "Ticket hat keine orderId.");
        if (savedOrderId !== orderId) throw new HttpsError("permission-denied", "orderId passt nicht zum Ticket.");

        // ✅ expectedCustomId kommt aus createTicketOrder (oder fallback)
        const expectedCustomId = String(ticket.expectedCustomId || `${partyId}:${uid}`).trim();

        // Optionaler extra Ownership Check über paypalTicketOrders
        const poSnap = await paypalOrderRef.get();
        if (poSnap.exists) {
            const po = poSnap.data() || {};
            if (String(po.buyerUid || "") !== uid) throw new HttpsError("permission-denied", "Order gehört nicht dir.");
            if (String(po.partyId || "") !== partyId) throw new HttpsError("permission-denied", "Order gehört nicht zur Party.");
            if (po.expectedCustomId && String(po.expectedCustomId) !== expectedCustomId) {
                throw new HttpsError("permission-denied", "Order expectedCustomId mismatch.");
            }
        }

        const st = String(ticket.status || "").toLowerCase();
        if (st === "paid") {
            return { ok: true, status: "paid", alreadyPaid: true, captureId: ticket.captureId || null };
        }
        if (st !== "pending") {
            throw new HttpsError("failed-precondition", `Ticket Status '${st}', erwartet 'pending'.`);
        }

        const accessToken = await getPayPalAccessToken();

        // 1) Capture versuchen (idempotent)
        let cap;
        try {
            const result = await captureOrder(orderId, accessToken);
            cap = result.alreadyCaptured ? await getOrder(orderId, accessToken) : result.cap;
        } catch (e) {
            await ticketRef.set(
                {
                    status: "failed",
                    failedAt: admin.firestore.FieldValue.serverTimestamp(),
                    lastError: String(e?.message || e).slice(0, 900),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
            );
            throw e;
        }

        // ✅ Ownership: PayPal custom_id muss passen
        if (cap.customId && String(cap.customId) !== expectedCustomId) {
            await ticketRef.set(
                {
                    status: "failed",
                    failedAt: admin.firestore.FieldValue.serverTimestamp(),
                    lastError: `custom_id mismatch (${cap.customId} != ${expectedCustomId})`,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
            );
            throw new HttpsError("permission-denied", "PayPal Order gehört nicht zu diesem User/Party.");
        }

        // Wenn nicht COMPLETED → pending/failed
        if (!cap.isCompleted) {
            const nextStatus = cap.status === "PAYER_ACTION_REQUIRED" ? "pending" : "failed";

            await ticketRef.set(
                {
                    status: nextStatus,
                    paypalStatus: cap.status,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
            );

            await paypalOrderRef.set(
                {
                    partyId,
                    buyerUid: uid,
                    status: nextStatus,
                    env: PAYPAL_ENV.value(),
                    paypalStatus: cap.status,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    captureId: cap.captureId || null,
                    payerEmail: cap.payerEmail || null,
                    payerId: cap.payerId || null,
                    captureRaw: cap.raw,
                },
                { merge: true }
            );

            return { ok: false, status: nextStatus, paypalStatus: cap.status };
        }

        // COMPLETED → atomar als paid markieren
        await db.runTransaction(async (tx) => {
            const fresh = await tx.get(ticketRef);
            if (!fresh.exists) throw new HttpsError("failed-precondition", "Ticket fehlt.");

            const t = fresh.data() || {};
            if (String(t.status || "").toLowerCase() === "paid") return;
            if (String(t.orderId || "").trim() !== orderId) throw new HttpsError("permission-denied", "Order mismatch.");

            const now = admin.firestore.FieldValue.serverTimestamp();

            tx.set(
                ticketRef,
                {
                    status: "paid",
                    paidAt: now,
                    updatedAt: now,
                    captureId: cap.captureId || null,
                    payerEmail: cap.payerEmail || null,
                    payerId: cap.payerId || null,
                    paypalStatus: cap.status,
                },
                { merge: true }
            );

            tx.set(
                paypalOrderRef,
                {
                    partyId,
                    buyerUid: uid,
                    status: "captured",
                    env: PAYPAL_ENV.value(),
                    capturedAt: now,
                    updatedAt: now,
                    captureId: cap.captureId || null,
                    payerEmail: cap.payerEmail || null,
                    payerId: cap.payerId || null,
                    paypalStatus: cap.status,
                    captureRaw: cap.raw,
                },
                { merge: true }
            );
        });

        return { ok: true, status: "paid", captureId: cap.captureId || null };
    }
);
