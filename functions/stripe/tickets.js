// functions/stripe/tickets.js
// Erzeugt einen PaymentIntent für einen Ticket-Kauf.
// 97 % gehen an den Host (transfer_data.destination), 3 % bleiben als
// application_fee_amount auf der Plattform.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const {
  STRIPE_SECRET_KEY,
  PLATFORM_FEE_PERCENT,
  CURRENCY,
  getStripe,
} = require("./client");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

/**
 * createTicketPaymentIntent
 * Eingabe: { partyId, quantity, buyerEmail }
 * Ausgabe: { clientSecret, ephemeralKey, customerId, ticketId, amount }
 *
 * Der Client nutzt clientSecret + ephemeralKey + customerId, um das
 * native Stripe-Payment-Sheet zu öffnen (Apple Pay / Google Pay / Karte).
 */
exports.createTicketPaymentIntent = onCall(
  { region: "europe-west1", secrets: [STRIPE_SECRET_KEY] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Not logged in.");
    const uid = request.auth.uid;

    const partyId = String(request.data?.partyId || "").trim();
    const qty = Math.max(1, Math.min(20, parseInt(request.data?.quantity || "1", 10) || 1));
    const buyerEmail = String(request.data?.buyerEmail || "").trim();

    if (!partyId) throw new HttpsError("invalid-argument", "partyId missing.");
    if (!buyerEmail) throw new HttpsError("invalid-argument", "buyerEmail missing.");

    const stripe = getStripe();

    // Party laden + Validierung
    const partyRef = db.collection("Party").doc(partyId);
    const partySnap = await partyRef.get();
    if (!partySnap.exists) throw new HttpsError("not-found", "Party not found.");
    const party = partySnap.data() || {};

    const ticketsEnabled = party.ticketsEnabled === true;
    const priceCents = parseInt(party.ticketPriceCents || 0, 10);
    if (!ticketsEnabled || priceCents <= 0) {
      throw new HttpsError("failed-precondition", "Tickets sind für diese Party nicht aktiv.");
    }

    const hostUid = String(party.hostUid || party.hostId || "").trim();
    if (!hostUid) throw new HttpsError("failed-precondition", "Party hat keinen Host.");
    if (hostUid === uid) throw new HttpsError("permission-denied", "Host kann eigene Tickets nicht kaufen.");

    // Host-Stripe-Account prüfen (Subcollection users/{uid}/stripe/account)
    const hostStripeSnap = await db
      .collection("users")
      .doc(hostUid)
      .collection("stripe")
      .doc("account")
      .get();
    const hostStripe = hostStripeSnap.data() || {};
    const hostAccountId = hostStripe.stripeAccountId;
    const hostChargesOk = hostStripe.stripeChargesEnabled === true;
    if (!hostAccountId || !hostChargesOk) {
      throw new HttpsError("failed-precondition", "Host hat Auszahlungen nicht aktiviert.");
    }

    // Sold-Out-Check (optional)
    const soldSoFar = parseInt(party.ticketsSold || 0, 10);
    const max = parseInt(party.ticketsAvailable || 0, 10);
    if (max > 0 && soldSoFar + qty > max) {
      throw new HttpsError("resource-exhausted", "Nicht genug Tickets verfügbar.");
    }

    const totalAmount = priceCents * qty;
    const platformFee = Math.round((totalAmount * PLATFORM_FEE_PERCENT) / 100);

    // Ticket-Doc anlegen (status pending — wird von webhook auf paid gesetzt)
    const ticketRef = db.collection("tickets").doc();

    // Stripe-Customer (für Saved-Cards in Payment Sheet)
    const customer = await stripe.customers.create({
      email: buyerEmail,
      metadata: { uid, ticketId: ticketRef.id },
    });

    const ephemeralKey = await stripe.ephemeralKeys.create(
      { customer: customer.id },
      { apiVersion: "2024-11-20.acacia" }
    );

    const paymentIntent = await stripe.paymentIntents.create({
      amount: totalAmount,
      currency: CURRENCY,
      customer: customer.id,
      receipt_email: buyerEmail,
      automatic_payment_methods: { enabled: true },
      application_fee_amount: platformFee,
      transfer_data: { destination: hostAccountId },
      metadata: {
        ticketId: ticketRef.id,
        partyId,
        hostUid,
        buyerUid: uid,
        quantity: String(qty),
      },
    });

    await ticketRef.set({
      ticketId: ticketRef.id,
      partyId,
      partyName: party.name || "",
      partyDate: party.date || null,
      partyTime: party.time || "",
      hostUid,
      buyerUid: uid,
      buyerEmail,
      quantity: qty,
      pricePerTicketCents: priceCents,
      totalAmountCents: totalAmount,
      platformFeeCents: platformFee,
      currency: CURRENCY,
      status: "pending",
      paymentIntentId: paymentIntent.id,
      stripeCustomerId: customer.id,
      createdAt: FieldValue.serverTimestamp(),
    });

    return {
      clientSecret: paymentIntent.client_secret,
      ephemeralKey: ephemeralKey.secret,
      customerId: customer.id,
      ticketId: ticketRef.id,
      amount: totalAmount,
      currency: CURRENCY,
    };
  }
);
