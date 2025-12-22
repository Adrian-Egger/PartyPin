/* eslint-disable */

// ============================================
// functions/TicketOrderPayPal/captureTicketOrder/index.js
// ============================================
const { onCall } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");

const db = admin.firestore();

// PayPal Sandbox (Production: https://api-m.paypal.com)
const PAYPAL_BASE_URL = "https://api-m.sandbox.paypal.com";

// Secrets (müssen in Firebase gesetzt sein)
const PAYPAL_CLIENT_ID = defineSecret("PAYPAL_CLIENT_ID");
const PAYPAL_SECRET = defineSecret("PAYPAL_SECRET");

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

    const json = JSON.parse(text);
    if (!json.access_token) throw new Error("Kein access_token von PayPal erhalten");
    return json.access_token;
}

// -------------------------------------------------------------
// Helper: PayPal Order capturen
// -------------------------------------------------------------
async function captureOrder(orderId, accessToken) {
    const res = await fetch(PAYPAL_BASE_URL + `/v2/checkout/orders/${orderId}/capture`, {
        method: "POST",
        headers: {
            Authorization: "Bearer " + accessToken,
            "Content-Type": "application/json",
        },
    });

    const text = await res.text();
    if (!res.ok) throw new Error("PayPal Capture Fehler: " + text);

    const json = JSON.parse(text);

    // PayPal status checks
    const status = String(json.status || "").toUpperCase(); // e.g. COMPLETED
    const isCompleted = status === "COMPLETED";

    // Try to extract captureId + payer email (optional)
    let captureId = null;
    try {
        const pu0 = (json.purchase_units || [])[0];
        const cap0 = (((pu0 || {}).payments || {}).captures || [])[0];
        captureId = cap0 ? cap0.id : null;
    } catch (_) {}

    const payerEmail = json?.payer?.email_address || null;
    const payerId = json?.payer?.payer_id || null;

    return { raw: json, isCompleted, captureId, payerEmail, payerId, status };
}

// -------------------------------------------------------------
// captureTicketOrder (Callable)
// Erwartet: { partyId, orderId }
// - prüft Auth
// - stellt sicher, dass Ticket zu diesem user gehört
// - capturt Order bei PayPal
// - schreibt Ticket -> paid (oder failed)
// -------------------------------------------------------------
module.exports = onCall(
    {
        region: "us-central1",
        secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET],
    },
    async (request) => {
        const { auth, data } = request;

        if (!auth) {
            // Callable errors (einfach als Error reicht, Flutter bekommt "internal" wenn du nicht catchst)
            throw new Error("unauthenticated");
        }

        const uid = auth.uid;

        const partyId = String(data?.partyId || "").trim();
        const orderId = String(data?.orderId || "").trim();

        if (!partyId) throw new Error("partyId fehlt");
        if (!orderId) throw new Error("orderId fehlt");

        const partyRef = db.collection("Party").doc(partyId);
        const ticketRef = partyRef.collection("tickets").doc(uid);

        // Ticket muss existieren und OrderId muss passen
        const ticketSnap = await ticketRef.get();
        if (!ticketSnap.exists) throw new Error("Ticket nicht gefunden");

        const ticket = ticketSnap.data() || {};
        const savedOrderId = String(ticket.orderId || "").trim();

        if (!savedOrderId) throw new Error("Ticket hat keine orderId gespeichert");
        if (savedOrderId !== orderId) throw new Error("orderId passt nicht zum Ticket");

        // Schon bezahlt? -> idempotent OK
        const currentStatus = String(ticket.status || "").toLowerCase();
        if (currentStatus === "paid") {
            return { ok: true, alreadyPaid: true };
        }

        // PayPal capture
        const accessToken = await getPayPalAccessToken();
        let cap;
        try {
            cap = await captureOrder(orderId, accessToken);
        } catch (e) {
            // Ticket als failed markieren
            await ticketRef.set(
                {
                    status: "failed",
                    failedAt: admin.firestore.FieldValue.serverTimestamp(),
                    lastError: String(e?.message || e),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
            );
            throw e;
        }

        // Update ticket state
        if (cap.isCompleted) {
            await ticketRef.set(
                {
                    status: "paid",
                    paidAt: admin.firestore.FieldValue.serverTimestamp(),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    captureId: cap.captureId || null,
                    payerEmail: cap.payerEmail || null,
                    payerId: cap.payerId || null,
                    paypalStatus: cap.status || null,
                    captureRaw: cap.raw, // optional: kannst du auch weglassen
                },
                { merge: true }
            );

            return {
                ok: true,
                status: "paid",
                captureId: cap.captureId || null,
            };
        } else {
            // Nicht completed -> pending/failed je nach PayPal status
            const nextStatus = String(cap.status || "").toUpperCase() === "PAYER_ACTION_REQUIRED"
                ? "pending"
                : "failed";

            await ticketRef.set(
                {
                    status: nextStatus,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    paypalStatus: cap.status || null,
                    captureRaw: cap.raw,
                },
                { merge: true }
            );

            return {
                ok: false,
                status: nextStatus,
                paypalStatus: cap.status || null,
            };
        }
    }
);
