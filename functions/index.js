/* eslint-disable */

// =======================
// functions/index.js  (DEFAULT codebase)  (KOMPLETT, deploybar)
// - Tickets + Cleanup bleiben hier
// - Partner/Onboarding bleibt hier
// - PayPal Premium wird HIER exportiert, weil bei dir keine zweite codebase deployed wird
// - Party Rating (Host-Score in users/{hostUid}) ist HIER dazugekommen ✅
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
            "Content-Type": "application/x-www-form-urlencoded"
        },
        body: "grant_type=client_credentials"
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
        secrets: [PAYPAL_PARTNER_CLIENT_ID, PAYPAL_PARTNER_SECRET]
    },
    async (request) => {
        if (!request.auth) throw new HttpsError("unauthenticated", "Not logged in.");

        const uid = request.auth.uid;
        const trackingId = `${uid}_${crypto.randomBytes(6).toString("hex")}`;

        await db.collection("paypalHostOnboarding").doc(uid).set(
            {
                trackingId,
                status: "pending",
                createdAt: FieldValue.serverTimestamp()
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
                            third_party_details: { features: ["PAYMENT", "REFUND"] }
                        }
                    }
                }
            ],
            products: ["EXPRESS_CHECKOUT"],
            legal_consents: [{ type: "SHARE_DATA_CONSENT", granted: true }],
            partner_config_override: {
                return_url: PAYPAL_ONBOARD_RETURN_URL,
                cancel_url: PAYPAL_ONBOARD_CANCEL_URL
            }
        };

        const resp = await fetch(PAYPAL_BASE_URL + "/v2/customer/partner-referrals", {
            method: "POST",
            headers: {
                Authorization: "Bearer " + accessToken,
                "Content-Type": "application/json"
            },
            body: JSON.stringify(body)
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
            paypalOnboardingStatus: "connected"
        },
        { merge: true }
    );

    return { ok: true };
});

// =======================
// ✅ PARTY RATING (Callable v2)  - schreibt Host-Score in users/{hostUid}
// =======================

function parsePartyStart(party) {
    // 1) startTime bevorzugt (Timestamp oder ISO String)
    const st = party.startTime;
    if (st && typeof st.toDate === "function") return st.toDate();
    if (typeof st === "string") {
        const d = new Date(st);
        if (!isNaN(d.getTime())) return d;
    }

    // 2) fallback: date (Timestamp/ISO) + time ("HH:mm")
    let base = null;
    const date = party.date;
    if (date && typeof date.toDate === "function") base = date.toDate();
    if (typeof date === "string") {
        const d = new Date(date);
        if (!isNaN(d.getTime())) base = d;
    }
    if (!base) return null;

    const timeStr = (party.time || "").toString().trim();
    let hh = 0;
    let mm = 0;
    if (timeStr.includes(":")) {
        const p = timeStr.split(":");
        hh = parseInt(p[0] || "0", 10) || 0;
        mm = parseInt(p[1] || "0", 10) || 0;
    }
    return new Date(base.getFullYear(), base.getMonth(), base.getDate(), hh, mm, 0, 0);
}

exports.setPartyRating = onCall({ region: "europe-west1" }, async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Not logged in.");

    const partyId = String(request.data?.partyId || "").trim();
    const value = String(request.data?.value || "").trim(); // good|bad

    if (!partyId) throw new HttpsError("invalid-argument", "partyId missing.");
    if (value !== "good" && value !== "bad") {
        throw new HttpsError("invalid-argument", "value must be 'good' or 'bad'.");
    }

    const partyRef = db.collection("Party").doc(partyId);
    const ratingRef = partyRef.collection("ratings").doc(uid);

    return await db.runTransaction(async (tx) => {
        // READS
        const partySnap = await tx.get(partyRef);
        if (!partySnap.exists) throw new HttpsError("not-found", "Party not found.");

        const party = partySnap.data() || {};
        const hostUid = String(party.hostUid || party.hostId || "").trim();
        if (!hostUid) throw new HttpsError("failed-precondition", "Party has no hostUid.");
        if (hostUid === uid) throw new HttpsError("permission-denied", "Host cannot rate own party.");

        // Zeitfenster: 24h ab Start
        const start = parsePartyStart(party);
        if (!start) throw new HttpsError("failed-precondition", "Party startTime missing/invalid.");

        const now = new Date();
        const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
        if (now < start || now > end) {
            throw new HttpsError("failed-precondition", "Rating not allowed (outside 24h window).");
        }

        // Berechtigung: Closed -> approved, sonst -> rsvps going/maybe
        const typeStr = String(party.type || (party.isClosed ? "Closed" : "Open"));
        const isClosed = !!party.isClosed || typeStr === "Closed";
        const isFriendsOnly = typeStr === "Only4Friends";

        if (isClosed && !isFriendsOnly) {
            const reqSnap = await tx.get(partyRef.collection("requests").doc(uid));
            const st = reqSnap.exists ? String(reqSnap.data()?.status || "") : "";
            if (st !== "approved") {
                throw new HttpsError("permission-denied", "Not approved - cannot rate.");
            }
        } else {
            const rsvpSnap = await tx.get(partyRef.collection("rsvps").doc(uid));
            const st = rsvpSnap.exists ? String(rsvpSnap.data()?.status || "") : "";
            if (st !== "going" && st !== "maybe") {
                throw new HttpsError("permission-denied", "Only going/maybe can rate.");
            }
        }

        // Vorherige Bewertung
        const prevSnap = await tx.get(ratingRef);
        const prevVal = prevSnap.exists ? (prevSnap.data()?.value || null) : null;

        let deltaGood = 0;
        let deltaBad = 0;
        if (value === "good") deltaGood++;
        if (value === "bad") deltaBad++;
        if (prevVal === "good") deltaGood--;
        if (prevVal === "bad") deltaBad--;

        const changed = deltaGood !== 0 || deltaBad !== 0;

        // Host User Doc lesen
        const hostUserRef = db.collection("users").doc(hostUid);
        const hostSnap = await tx.get(hostUserRef);

        const curGood = hostSnap.exists ? (hostSnap.data()?.partyScoreGood || 0) : 0;
        const curBad = hostSnap.exists ? (hostSnap.data()?.partyScoreBad || 0) : 0;

        const newGood = curGood + deltaGood;
        const newBad = curBad + deltaBad;
        const total = newGood + newBad;
        const pct = total > 0 ? Math.round((newGood / total) * 100) : 0;

        // WRITES
        tx.set(
            ratingRef,
            {
                uid,
                value,
                ts: FieldValue.serverTimestamp()
            },
            { merge: true }
        );

        // optional: Party counter (falls du’s im Party Doc willst)
        if (changed) {
            tx.set(
                partyRef,
                {
                    ratingsGood: FieldValue.increment(deltaGood),
                    ratingsBad: FieldValue.increment(deltaBad)
                },
                { merge: true }
            );
        }

        // ✅ Host Score in users/{hostUid}
        if (changed) {
            tx.set(
                hostUserRef,
                {
                    partyScoreGood: newGood,
                    partyScoreBad: newBad,
                    partyScorePct: pct,
                    partyScoreUpdatedAt: FieldValue.serverTimestamp()
                },
                { merge: true }
            );

            // optional: per-party rating history beim Host
            const perUserRef = hostUserRef
                .collection("partyRatings")
                .doc(partyId)
                .collection("byUser")
                .doc(uid);

            tx.set(
                perUserRef,
                {
                    partyId,
                    fromUid: uid,
                    value,
                    ts: FieldValue.serverTimestamp()
                },
                { merge: true }
            );
        }

        return { ok: true, pct, good: newGood, bad: newBad };
    });
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

// =======================
// Friend Request Push Notification
// =======================
const { onDocumentCreated } = require("firebase-functions/v2/firestore");

exports.onFriendRequest = onDocumentCreated("friendRequests/{requestId}", async (event) => {
  const data = event.data?.data();
  if (!data) return;

  const fromUsername = (data.from || "").trim();
  const toUsername = (data.to || data.toUsername || "").trim();
  if (!toUsername || !fromUsername) return;

  // Get recipient's FCM token
  const userSnap = await db.collection("users").doc(toUsername).get();
  if (!userSnap.exists) return;

  const fcmToken = userSnap.data()?.fcmToken;
  if (!fcmToken) return;

  await admin.messaging().send({
    token: fcmToken,
    notification: {
      title: "Neue Freundschaftsanfrage",
      body: `${fromUsername} möchte dich adden`,
    },
    android: {
      notification: { channelId: "friend_requests" },
    },
  });
});
