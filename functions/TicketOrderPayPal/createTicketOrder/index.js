/* eslint-disable */

// ============================================
// functions/TicketOrderPayPal/createTicketOrder/index.js
// ============================================
const { onCall } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

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
// Helper: PayPal Order erstellen
// -------------------------------------------------------------
async function createOrder({ accessToken, partyId, buyerUid, hostUid, price, currency }) {
    // In production: Deep Links deiner App
    const returnUrl =
        "https://example.com/pp-return?partyId=" +
        encodeURIComponent(partyId) +
        "&uid=" +
        encodeURIComponent(buyerUid);

    const cancelUrl =
        "https://example.com/pp-cancel?partyId=" +
        encodeURIComponent(partyId) +
        "&uid=" +
        encodeURIComponent(buyerUid);

    // custom_id kann später im Webhook helfen (partyId/buyerUid/hostUid)
    const custom = {
        type: "ticket",
        partyId,
        buyerUid,
        hostUid,
    };

    const body = {
        intent: "CAPTURE",
        purchase_units: [
            {
                reference_id: partyId,
                amount: {
                    currency_code: currency,
                    value: Number(price).toFixed(2),
                },
                custom_id: JSON.stringify(custom),
                description: `Ticket für Party ${partyId}`,
            },
        ],
        application_context: {
            brand_name: "PartyPin",
            user_action: "PAY_NOW",
            return_url: returnUrl,
            cancel_url: cancelUrl,
        },
    };

    const res = await fetch(PAYPAL_BASE_URL + "/v2/checkout/orders", {
        method: "POST",
        headers: {
            Authorization: "Bearer " + accessToken,
            "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
    });

    const text = await res.text();
    if (!res.ok) throw new Error("PayPal Order Fehler: " + text);

    const json = JSON.parse(text);

    let approvalUrl = null;
    if (json.links) {
        for (const l of json.links) {
            if (l && l.rel === "approve" && l.href) {
                approvalUrl = l.href;
                break;
            }
        }
    }

    if (!json.id) throw new Error("PayPal Order ohne id");
    if (!approvalUrl) throw new Error("Kein approve-link von PayPal");

    return {
        orderId: json.id,
        approvalUrl,
        raw: json,
    };
}

// -------------------------------------------------------------
// createTicketOrder (Callable)
// Erwartet: { partyId }
// - prüft Auth
// - liest Party (price/currency/hostUid)
// - optional: prüft host PayPal connected (paypalAccounts/{hostUid})
// - erstellt PayPal order
// - schreibt Ticket pending
// - gibt approvalUrl zurück
// -------------------------------------------------------------
module.exports = onCall(
    {
        region: "us-central1",
        secrets: [PAYPAL_CLIENT_ID, PAYPAL_SECRET],
    },
    async (request) => {
        const { auth, data } = request;

        if (!auth) throw new Error("unauthenticated");

        const buyerUid = auth.uid;
        const partyId = String(data?.partyId || "").trim();
        if (!partyId) throw new Error("partyId fehlt");

        // Party lesen
        const partyRef = db.collection("Party").doc(partyId);
        const partySnap = await partyRef.get();
        if (!partySnap.exists) throw new Error("Party nicht gefunden");

        const party = partySnap.data() || {};
        const hostUid = String(party.hostUid || party.hostId || "").trim();
        const currency = String(party.currency || "EUR").trim().toUpperCase();

        let price = party.price;
        if (typeof price === "string") price = Number(String(price).replace(",", "."));
        price = Number(price || 0);

        if (!hostUid) throw new Error("hostUid fehlt in Party");
        if (!Number.isFinite(price) || price <= 0) throw new Error("Ungültiger Preis");

        // Optional: Host muss PayPal verbunden haben
        // Falls du das (noch) nicht hast, kannst du diesen Block löschen.
        const hostPayRef = db.collection("paypalAccounts").doc(hostUid);
        const hostPaySnap = await hostPayRef.get();
        if (!hostPaySnap.exists || hostPaySnap.data()?.status !== "connected") {
            throw new Error("Host hat PayPal nicht verbunden");
        }

        // Ticket Ref (1 Ticket pro User pro Party)
        const ticketRef = partyRef.collection("tickets").doc(buyerUid);

        // Schon bezahlt? -> idempotent OK
        const existingSnap = await ticketRef.get();
        if (existingSnap.exists) {
            const ex = existingSnap.data() || {};
            const st = String(ex.status || "").toLowerCase();
            if (st === "paid") {
                return { alreadyPaid: true, status: "paid" };
            }
        }

        // PayPal order erstellen
        const accessToken = await getPayPalAccessToken();

        const { orderId, approvalUrl, raw } = await createOrder({
            accessToken,
            partyId,
            buyerUid,
            hostUid,
            price,
            currency,
        });

        // Ticket pending speichern
        await ticketRef.set(
            {
                uid: buyerUid,
                partyId,
                hostUid,
                status: "pending",
                price,
                currency,
                orderId,
                approvalUrl,
                createdAt: FieldValue.serverTimestamp(),
                updatedAt: FieldValue.serverTimestamp(),
                orderRaw: raw, // optional: kannst du auch weglassen
            },
            { merge: true }
        );

        return {
            orderId,
            approvalUrl,
            status: "pending",
        };
    }
);
