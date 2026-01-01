/* eslint-disable */

// =======================
// functions/index.js  (DEFAULT codebase)  (KOMPLETT, deploybar)
// - Tickets + Cleanup bleiben hier
// - Partner/Onboarding bleibt hier
// - PayPal Premium wird HIER exportiert, weil bei dir keine zweite codebase deployed wird
// =======================

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const crypto = require("crypto");

// ✅ EINMAL init
if (!admin.apps.length) admin.initializeApp();

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

// ✅ Scheduler (v2)
const eventsCleanup = require("./eventCleanup");

// ✅ Ticket PayPal Callables (v2)
const ticketCreate = require("./TicketOrderPayPal/createTicketOrder");
const ticketCapture = require("./TicketOrderPayPal/captureTicketOrder");

// =======================
// Partner/Onboarding Secrets
// =======================
const PAYPAL_PARTNER_CLIENT_ID = defineSecret("PAYPAL_PARTNER_CLIENT_ID");
const PAYPAL_PARTNER_SECRET = defineSecret("PAYPAL_PARTNER_SECRET");

// LIVE Base (für Partner-Referrals)
const PAYPAL_BASE_URL = "https://api-m.paypal.com";

// Diese URLs ersetzt du später durch deine echten Hosting URLs
const PAYPAL_ONBOARD_RETURN_URL = "https://example.com/paypal-merchant-return";
const PAYPAL_ONBOARD_CANCEL_URL = "https://example.com/paypal-merchant-cancel";

// -------------------------------------------------------------
// PayPal Partner Access Token holen (LIVE)
// -------------------------------------------------------------
async function getPayPalPartnerAccessToken() {
    const clientId = (PAYPAL_PARTNER_CLIENT_ID.value() || "").trim();
    const secret = (PAYPAL_PARTNER_SECRET.value() || "").trim();
    if (!clientId || !secret) throw new Error("PayPal Partner Credentials nicht gesetzt");

    const auth = Buffer.from(`${clientId}:${secret}`).toString("base64");

    const res = await fetch(PAYPAL_BASE_URL + "/v1/oauth2/token", {
        method: "POST",
        headers: {
            Authorization: "Basic " + auth,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        body: "grant_type=client_credentials",
    });

    const text = await res.text();
    if (!res.ok) throw new Error("PayPal Partner OAuth-Fehler: " + text);

    const json = JSON.parse(text);
    if (!json.access_token) throw new Error("Kein Partner access_token von PayPal erhalten");
    return json.access_token;
}

// -------------------------------------------------------------
// createHostOnboardingLink (Callable v2) ✅ europe-west1
// -------------------------------------------------------------
exports.createHostOnboardingLink = onCall(
    {
        region: "europe-west1",
        secrets: [PAYPAL_PARTNER_CLIENT_ID, PAYPAL_PARTNER_SECRET],
    },
    async (request) => {
        if (!request.auth) throw new HttpsError("unauthenticated", "Not logged in.");

        const uid = request.auth.uid;
        const trackingId = `${uid}_${crypto.randomBytes(6).toString("hex")}`;

        await db.collection("paypalHostOnboarding").doc(uid).set(
            {
                trackingId,
                status: "pending",
                createdAt: FieldValue.serverTimestamp(),
            },
            { merge: true }
        );

        let accessToken;
        try {
            accessToken = await getPayPalPartnerAccessToken();
        } catch (e) {
            throw new HttpsError("failed-precondition", String(e.message || e));
        }

        const body = {
            tracking_id: trackingId,
            operations: [
                {
                    operation: "API_INTEGRATION",
                    api_integration_preference: {
                        rest_api_integration: {
                            integration_method: "PAYPAL",
                            integration_type: "THIRD_PARTY",
                            third_party_details: { features: ["PAYMENT", "REFUND"] },
                        },
                    },
                },
            ],
            products: ["EXPRESS_CHECKOUT"],
            legal_consents: [{ type: "SHARE_DATA_CONSENT", granted: true }],
            partner_config_override: {
                return_url: PAYPAL_ONBOARD_RETURN_URL,
                cancel_url: PAYPAL_ONBOARD_CANCEL_URL,
            },
        };

        const resp = await fetch(PAYPAL_BASE_URL + "/v2/customer/partner-referrals", {
            method: "POST",
            headers: {
                Authorization: "Bearer " + accessToken,
                "Content-Type": "application/json",
            },
            body: JSON.stringify(body),
        });

        const text = await resp.text();
        if (!resp.ok) {
            console.error("partner-referrals error:", text);
            throw new HttpsError("failed-precondition", text);
        }

        const json = JSON.parse(text);

        let actionUrl = null;
        for (const l of json.links || []) {
            if (l?.rel === "action_url" && l.href) {
                actionUrl = l.href;
                break;
            }
        }

        if (!actionUrl) {
            console.error("partner-referrals no action_url:", json);
            throw new HttpsError("internal", "No action_url from PayPal.");
        }

        return { actionUrl };
    }
);

// -------------------------------------------------------------
// finalizeHostOnboarding (Callable v2) ✅ europe-west1
// -------------------------------------------------------------
exports.finalizeHostOnboarding = onCall({ region: "europe-west1" }, async (request) => {
    if (!request.auth) {
        throw new HttpsError("unauthenticated", "Not logged in.");
    }

    const uid = request.auth.uid;
    const data = request.data || {};
    const merchantIdInPayPal = String(data.merchantIdInPayPal || "").trim();

    if (!merchantIdInPayPal) {
        throw new HttpsError("invalid-argument", "merchantIdInPayPal missing.");
    }

    await db.collection("users").doc(uid).set(
        {
            paypalMerchantId: merchantIdInPayPal,
            paypalConnectedAt: FieldValue.serverTimestamp(),
            paypalOnboardingStatus: "connected",
        },
        { merge: true }
    );

    return { ok: true };
});

// =======================
// Ticket PayPal Exports (Callable)
// =======================
exports.createTicketOrder = ticketCreate.createTicketOrder;
exports.captureTicketOrder = ticketCapture.captureTicketOrder;

// =======================
// Scheduler Export
// =======================
exports.cleanupExpiredEvents = eventsCleanup.cleanupExpiredEvents;

// =======================
// PayPal Premium Exports (HTTP + Scheduler)  ✅ HIER MUSS ES REIN
// =======================
const paypalPremium = require("./paypal/index");

exports.paypalWebhook = paypalPremium.paypalWebhook;
exports.createPayPalCheckout = paypalPremium.createPayPalCheckout;
exports.syncPayPalPremiumDaily = paypalPremium.syncPayPalPremiumDaily;
