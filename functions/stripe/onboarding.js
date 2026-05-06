// functions/stripe/onboarding.js
// Stripe Connect Express — Host-Onboarding.
// Hosts brauchen einen Stripe-Connect-Account, damit Auszahlungen funktionieren.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { STRIPE_SECRET_KEY, getStripe } = require("./client");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

// Stripe verlangt HTTPS-URLs (keine custom schemes). Jede der beiden
// Seiten liegt in einem eigenen Netlify-Projekt als index.html und
// triggert per JS den Deep-Link "partypin://stripe-return" bzw.
// "partypin://stripe-refresh".
const ONBOARD_RETURN_URL =
  "https://startling-hummingbird-1696da.netlify.app";
const ONBOARD_REFRESH_URL =
  "https://eloquent-griffin-e5aad2.netlify.app";
const HOST_BUSINESS_URL = "https://eloquent-griffin-e5aad2.netlify.app";

/**
 * createStripeOnboardingLink
 * Legt (falls nötig) einen Stripe-Connect-Express-Account für den Host an
 * und gibt eine Onboarding-URL zurück.
 */
exports.createStripeOnboardingLink = onCall(
  { region: "europe-west1", secrets: [STRIPE_SECRET_KEY] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Not logged in.");
    const uid = request.auth.uid;

    const stripe = getStripe();

    const userRef = db.collection("users").doc(uid);
    const stripeRef = userRef.collection("stripe").doc("account");

    const [userSnap, stripeSnap] = await Promise.all([
      userRef.get(),
      stripeRef.get(),
    ]);
    const userData = userSnap.data() || {};
    const stripeData = stripeSnap.data() || {};

    let accountId = stripeData.stripeAccountId;

    if (!accountId) {
      const account = await stripe.accounts.create({
        type: "express",
        country: "AT",
        email: userData.email || request.auth.token?.email || undefined,
        capabilities: {
          card_payments: { requested: true },
          transfers: { requested: true },
        },
        business_type: "individual",
        business_profile: { url: HOST_BUSINESS_URL },
        metadata: { uid },
      });
      accountId = account.id;
      await stripeRef.set(
        {
          stripeAccountId: accountId,
          stripeOnboardingStatus: "pending",
          stripeAccountCreatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    } else {
      await stripe.accounts.update(accountId, {
        business_profile: { url: HOST_BUSINESS_URL },
      });
    }

    const link = await stripe.accountLinks.create({
      account: accountId,
      refresh_url: ONBOARD_REFRESH_URL,
      return_url: ONBOARD_RETURN_URL,
      type: "account_onboarding",
    });

    return { url: link.url, accountId };
  }
);

/**
 * refreshStripeAccountStatus
 * Holt aktuellen Status vom Stripe-Account und schreibt ihn in users/{uid}.
 * Wird aufgerufen, sobald der User aus dem Onboarding zurückkommt.
 */
exports.refreshStripeAccountStatus = onCall(
  { region: "europe-west1", secrets: [STRIPE_SECRET_KEY] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Not logged in.");
    const uid = request.auth.uid;

    const stripe = getStripe();

    const stripeRef = db.collection("users").doc(uid).collection("stripe").doc("account");
    const stripeSnap = await stripeRef.get();
    const accountId = stripeSnap.data()?.stripeAccountId;

    if (!accountId) {
      throw new HttpsError("failed-precondition", "Kein Stripe-Account vorhanden.");
    }

    const account = await stripe.accounts.retrieve(accountId);

    const charges = !!account.charges_enabled;
    const payouts = !!account.payouts_enabled;
    const detailsSubmitted = !!account.details_submitted;
    const status = charges && payouts ? "active" : detailsSubmitted ? "pending_review" : "incomplete";

    await stripeRef.set(
      {
        stripeChargesEnabled: charges,
        stripePayoutsEnabled: payouts,
        stripeDetailsSubmitted: detailsSubmitted,
        stripeOnboardingStatus: status,
        stripeStatusUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    return { status, chargesEnabled: charges, payoutsEnabled: payouts };
  }
);
