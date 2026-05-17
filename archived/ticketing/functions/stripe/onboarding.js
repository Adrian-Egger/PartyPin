// functions/stripe/onboarding.js
// Stripe Connect Express — Host-Onboarding pro User.
// Hosts sind reguläre App-User (nicht Bars). Genau ein Stripe-Account
// pro User, idempotent über die Firebase-Auth-uid.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

const { STRIPE_SECRET_KEY, getStripe } = require("./client");
const {
  HOST_BUSINESS_URL,
  ONBOARD_RETURN_URL,
  ONBOARD_REFRESH_URL,
  isRealStripeAccountId,
  toHttpsError,
  userStripeAccountRef,
  clearInvalidStripeAccount,
} = require("./utils");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

/**
 * createStripeOnboardingLink
 *  - Auth: jeder eingeloggte User darf für sich selbst onboarden.
 *  - Idempotent pro uid: vorhandene gültige Stripe-Account-ID wird
 *    wiederverwendet.
 *  - Self-healing: Platzhalter / kaputte IDs werden ersetzt.
 *  - Liefert immer einen frischen Onboarding-Link.
 */
exports.createStripeOnboardingLink = onCall(
  {
    region: "europe-west1",
    secrets: [STRIPE_SECRET_KEY],
    maxInstances: 5,           // Onboarding ist 1-pro-User-pro-Session
    timeoutSeconds: 30,        // Stripe API roundtrip
    memory: "256MiB",
    concurrency: 20,
    // TODO(appcheck): nach Console-Setup auf `true` setzen
    enforceAppCheck: false,
  },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Not logged in.");
    const uid = request.auth.uid;

    try {
      // WICHTIG: getStripe() lädt das Secret + konstruiert den Client.
      // Wenn das Secret fehlt, wirft es einen regulären Error — der
      // MUSS innerhalb des try liegen, sonst wird er von Cloud Functions
      // als nacktes INTERNAL ohne Message an den Client zurückgegeben.
      const stripe = getStripe();

      const userRef   = db.collection("users").doc(uid);
      const stripeRef = userStripeAccountRef(db, uid);

      const [userSnap, stripeSnap] = await Promise.all([
        userRef.get(),
        stripeRef.get(),
      ]);
      const userData   = userSnap.data()   || {};
      const stripeData = stripeSnap.data() || {};

      let accountId = stripeData.stripeAccountId;

      logger.info("[onboarding] start", { uid, hadAccount: !!accountId });

      // Self-healing: Platzhalter (acct_DEV_BYPASS) oder kaputte IDs
      // dürfen NIE an die Stripe-API.
      if (accountId && !isRealStripeAccountId(accountId)) {
        logger.warn("[onboarding] invalid accountId — replacing", { uid, accountId });
        accountId = null;
      }

      if (!accountId) {
        const account = await stripe.accounts.create({
          type: "express",
          country: "AT",
          email: userData.email || request.auth.token?.email || undefined,
          capabilities: {
            card_payments: { requested: true },
            transfers:     { requested: true },
          },
          business_type: "individual",
          business_profile: { url: HOST_BUSINESS_URL },
          metadata: { uid },
        });
        accountId = account.id;

        // Komplett überschreiben. Der DevBypass-Pfad ist abgeschafft —
        // das Feld wird nicht mehr geschrieben (Legacy-Werte räumt
        // clearInvalidStripeAccount weg).
        await stripeRef.set({
          stripeAccountId:        accountId,
          stripeOnboardingStatus: "pending",
          stripeAccountCreatedAt: FieldValue.serverTimestamp(),
          stripeChargesEnabled:   false,
          stripePayoutsEnabled:   false,
          stripeDetailsSubmitted: false,
          stripeStatusUpdatedAt:  FieldValue.serverTimestamp(),
        }, { merge: true });

        logger.info("[onboarding] account created", { uid, accountId });
      } else {
        await stripe.accounts.update(accountId, {
          business_profile: { url: HOST_BUSINESS_URL },
        });
        logger.info("[onboarding] account reused/updated", { uid, accountId });
      }

      const link = await stripe.accountLinks.create({
        account:     accountId,
        refresh_url: ONBOARD_REFRESH_URL,
        return_url:  ONBOARD_RETURN_URL,
        type:        "account_onboarding",
      });

      logger.info("[onboarding] link issued", { uid, accountId });
      return { url: link.url, accountId };
    } catch (e) {
      logger.error("[onboarding] failed", {
        uid, type: e?.type, code: e?.code, msg: e?.message,
      });
      throw toHttpsError(e, "Onboarding-Link konnte nicht erstellt werden.");
    }
  }
);

/**
 * refreshStripeAccountStatus
 * Holt den aktuellen Status vom Stripe-Account und schreibt ihn in die
 * User-Subcollection. Bei "No such account" oder ungültiger ID: Doc
 * cleanen + lesbarer Fehler.
 */
exports.refreshStripeAccountStatus = onCall(
  {
    region: "europe-west1",
    secrets: [STRIPE_SECRET_KEY],
    maxInstances: 5,
    timeoutSeconds: 30,
    memory: "256MiB",
    concurrency: 20,
    // TODO(appcheck): nach Console-Setup auf `true` setzen
    enforceAppCheck: false,
  },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Not logged in.");
    const uid = request.auth.uid;

    try {
      // Siehe Hinweis in createStripeOnboardingLink: getStripe() muss
      // innerhalb des try liegen, sonst leakt fehlendes Secret als INTERNAL.
      const stripe = getStripe();

      const stripeRef = userStripeAccountRef(db, uid);
      const stripeSnap = await stripeRef.get();
      const accountId  = stripeSnap.data()?.stripeAccountId;

      if (!accountId) {
        throw new HttpsError("failed-precondition", "Kein Stripe-Account vorhanden.");
      }

      if (!isRealStripeAccountId(accountId)) {
        logger.warn("[refresh] invalid accountId — clearing", { uid, accountId });
        await clearInvalidStripeAccount(stripeRef);
        throw new HttpsError(
          "failed-precondition",
          "Stripe-Account ist ungültig — bitte Onboarding erneut starten."
        );
      }

      let account;
      try {
        account = await stripe.accounts.retrieve(accountId);
      } catch (e) {
        if (
          e?.type === "StripeInvalidRequestError" &&
          /No such account/i.test(e?.message || "")
        ) {
          logger.warn("[refresh] stripe says No such account — clearing", { uid, accountId });
          await clearInvalidStripeAccount(stripeRef);
          throw new HttpsError(
            "failed-precondition",
            "Stripe-Account existiert nicht mehr — bitte Onboarding erneut starten."
          );
        }
        throw e;
      }

      const charges          = !!account.charges_enabled;
      const payouts          = !!account.payouts_enabled;
      const detailsSubmitted = !!account.details_submitted;
      const status = charges && payouts
        ? "active"
        : detailsSubmitted
          ? "pending_review"
          : "incomplete";

      await stripeRef.set({
        stripeChargesEnabled:   charges,
        stripePayoutsEnabled:   payouts,
        stripeDetailsSubmitted: detailsSubmitted,
        stripeOnboardingStatus: status,
        stripeStatusUpdatedAt:  FieldValue.serverTimestamp(),
      }, { merge: true });

      logger.info("[refresh] status updated", {
        uid, status, charges, payouts, detailsSubmitted,
      });
      return { status, chargesEnabled: charges, payoutsEnabled: payouts };
    } catch (e) {
      logger.error("[refresh] failed", {
        uid, type: e?.type, code: e?.code, msg: e?.message,
      });
      throw toHttpsError(e, "Stripe-Status konnte nicht aktualisiert werden.");
    }
  }
);
