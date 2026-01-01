/* eslint-disable */
/**
 * ==================================================
 * functions/TicketOrderPayPal/createTicketOrder/index.js
 * LIVE-ready, idempotent, robust, production-safe
 *
 * Du musst NUR noch:
 * 1) Secret PAYPAL_CLIENT_ID setzen (LIVE)
 * 2) Secret PAYPAL_SECRET setzen (LIVE)
 * 3) (Optional) Return/Cancel URLs anpassen, wenn du andere willst
 * ==================================================
 */

const admin = require("firebase-admin");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret, defineString } = require("firebase-functions/params");

const PAYPAL_CLIENT_ID = defineSecret("PAYPAL_CLIENT_ID");
const PAYPAL_SECRET = defineSecret("PAYPAL_SECRET");

// live | sandbox (Default LIVE)
const PAYPAL_ENV = defineString("PAYPAL_ENV", { default: "live" });

// Return/Cancel URLs (Default: deine Hosting Domain)
const TICKET_RETURN_URL = defineString("TICKET_RETURN_URL", {
    default: "https://partypin-5dc3f.web.app/paypal-return",
});
const TICKET_CANCEL_URL = defineString("TICKET_CANCEL_URL", {
    default: "https://partypin-5dc3f.web.app/paypal-cancel",
});

const MAX_PRICE = 10000; // Schutz

function ensureAdmin() {
    if (!admin.apps.length) admin.initializeApp();
}

function paypalBaseUrl() {
    return PAYPAL_ENV.value() === "sandbox"
        ? "https://api-m.sandbox.paypal.com"
        : "https://api-m.paypal.com";
}

function requireHttpsUrl(val, name) {
    const v = String(val || "").trim();
    if (!/^https:\/\/.+/i.test(v)) throw new HttpsError("failed-precondition", `${name} muss eine https URL sein.`);
    return v;
}

function toMoneyString(value) {
    const n = Number(value);
    if (!Number.isFinite(n) || n <= 0) throw new HttpsError("failed-precondition", "Party.price muss > 0 sein.");
    if (n > MAX_PRICE) throw new HttpsError("failed-precondition", "Party.price ist unplausibel hoch.");
    return n.toFixed(2);
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

async function createPayPalOrder({ accessToken, partyId, buyerUid, price }) {
    const returnUrl = requireHttpsUrl(TICKET_RETURN_URL.value(), "TICKET_RETURN_URL");
    const cancelUrl = requireHttpsUrl(TICKET_CANCEL_URL.value(), "TICKET_CANCEL_URL");

    const expectedCustomId = `${partyId}:${buyerUid}`;

    const body = {
        intent: "CAPTURE",
        purchase_units: [
            {
                reference_id: String(partyId),
                custom_id: expectedCustomId,
                amount: {
                    currency_code: "EUR", // fix: immer EUR
                    value: toMoneyString(price),
                },
            },
        ],
        application_context: {
            user_action: "PAY_NOW",
            return_url: returnUrl,
            cancel_url: cancelUrl,
        },
    };

    const { ok, status, text, json } = await paypalFetch("/v2/checkout/orders", {
        method: "POST",
        headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
    });

    if (!ok) throw new HttpsError("internal", `PayPal create order Fehler (${status}): ${String(text || "").slice(0, 900)}`);

    const orderId = String(json?.id || "").trim();
    if (!orderId) throw new HttpsError("internal", "PayPal Order ID fehlt.");

    let approvalUrl = null;
    for (const l of json?.links || []) {
        if (l?.rel === "approve" && l?.href) {
            approvalUrl = l.href;
            break;
        }
    }
    if (!approvalUrl) throw new HttpsError("internal", "PayPal approval link fehlt.");

    return { orderId, approvalUrl, raw: json, expectedCustomId };
}

exports.createTicketOrder = onCall(
    { region: "europe-west1", secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET] },
    async (request) => {
        ensureAdmin();
        const db = admin.firestore();

        const uid = request.auth?.uid;
        if (!uid) throw new HttpsError("unauthenticated", "Login required.");

        const partyId = String(request.data?.partyId || "").trim();
        if (!partyId) throw new HttpsError("invalid-argument", "partyId fehlt.");

        const partyRef = db.doc(`Party/${partyId}`);
        const ticketRef = db.doc(`Party/${partyId}/tickets/${uid}`);

        const partySnap = await partyRef.get();
        if (!partySnap.exists) throw new HttpsError("not-found", "Party nicht gefunden.");

        const party = partySnap.data() || {};
        const price = party.price;
        const hostUid = String(party.hostId || "").trim(); // fix: hostId -> hostUid

        if (price === undefined || price === null) throw new HttpsError("failed-precondition", "Party.price fehlt.");
        if (!hostUid) throw new HttpsError("failed-precondition", "Party.hostId fehlt.");

        // Idempotenz: pending schon vorhanden => zurückgeben
        const existingSnap = await ticketRef.get();
        if (existingSnap.exists) {
            const t = existingSnap.data() || {};
            const st = String(t.status || "").toLowerCase();
            if (st === "paid") return { ok: true, status: "paid", alreadyPaid: true };
            if (st === "pending" && t.orderId && t.approvalUrl) {
                return { ok: true, status: "pending", alreadyPending: true, orderId: t.orderId, approvalUrl: t.approvalUrl };
            }
        }

        const accessToken = await getPayPalAccessToken();
        const { orderId, approvalUrl, raw, expectedCustomId } = await createPayPalOrder({
            accessToken,
            partyId,
            buyerUid: uid,
            price,
        });

        const now = admin.firestore.FieldValue.serverTimestamp();
        const paypalOrderRef = db.doc(`paypalTicketOrders/${orderId}`);

        // Transaction: verhindert paralleles Überschreiben
        await db.runTransaction(async (tx) => {
            const fresh = await tx.get(ticketRef);
            if (fresh.exists) {
                const ft = fresh.data() || {};
                const st = String(ft.status || "").toLowerCase();
                if (st === "paid") return;
                if (st === "pending" && ft.orderId && ft.approvalUrl) return;
            }

            const baseTicket = {
                status: "pending",
                orderId,
                approvalUrl,
                price: Number(price),
                currency: "EUR",
                hostUid,
                paypalEnv: PAYPAL_ENV.value(),
                expectedCustomId,
                updatedAt: now,
            };
            if (!fresh.exists) baseTicket.createdAt = now;

            tx.set(ticketRef, baseTicket, { merge: true });

            tx.set(
                paypalOrderRef,
                {
                    partyId,
                    buyerUid: uid,
                    status: "created",
                    env: PAYPAL_ENV.value(),
                    expectedCustomId,
                    createdAt: now,
                    updatedAt: now,
                    createRaw: raw,
                },
                { merge: true }
            );
        });

        return { ok: true, status: "pending", orderId, approvalUrl };
    }
);
