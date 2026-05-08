// functions/stripe/utils.js
//
// Gemeinsame Helfer für alle Stripe-Functions.
// WICHTIG: hängt an NICHTS aus diesem Modul-Subtree (kein require auf
// onboarding.js / tickets.js), damit kein Zirkel-Import entsteht.
// onboarding.js und tickets.js importieren NUR von hier.

const { HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

const FieldValue = admin.firestore.FieldValue;

// ---------- Konstanten ----------

// Legacy-Schutz: der entfernte DevBypass-Toggle hat in der Vergangenheit
// "acct_DEV_BYPASS" in users/{uid}/stripe/account.stripeAccountId
// geschrieben. Falls solche Werte in alten Firestore-Docs noch
// existieren, fängt isRealStripeAccountId() sie hier ab — bevor sie
// jemals an die Stripe-API gehen. Self-Heal greift dann.
const PLACEHOLDER_ACCOUNT_IDS = new Set(["acct_DEV_BYPASS"]);

const ONBOARD_RETURN_URL  = "https://startling-hummingbird-1696da.netlify.app";
const ONBOARD_REFRESH_URL = "https://eloquent-griffin-e5aad2.netlify.app";
const HOST_BUSINESS_URL   = "https://eloquent-griffin-e5aad2.netlify.app";

// ---------- Stripe-ID-Validierung ----------

/**
 * Strikte Validierung. Verhindert, dass irgendeine Platzhalter- oder
 * kaputte ID an die Stripe-API gehen kann (sonst INTERNAL).
 */
function isRealStripeAccountId(id) {
  if (typeof id !== "string") return false;
  if (!id.startsWith("acct_")) return false;
  if (PLACEHOLDER_ACCOUNT_IDS.has(id)) return false;
  if (id.length < 12) return false;
  return /^acct_[A-Za-z0-9]+$/.test(id);
}

// ---------- Fehler-Mapping ----------

/**
 * Übersetzt jeden Fehler — egal ob Stripe, HttpsError oder unbekannt — in
 * einen HttpsError mit lesbarer Message. Verhindert, dass der Client je
 * eine generische "INTERNAL"-Antwort bekommt.
 */
function toHttpsError(e, fallbackMsg) {
  if (e instanceof HttpsError) return e;

  const type = e?.type || "";
  const msg  = (e?.message || "").trim();

  switch (type) {
    case "StripeInvalidRequestError":
      return new HttpsError("failed-precondition", `Stripe: ${msg || "Ungültige Anfrage."}`);
    case "StripeAuthenticationError":
      logger.error("[stripe] auth error — falscher API-Key?", e);
      return new HttpsError("internal", "Stripe-Konfiguration fehlerhaft. Bitte Support kontaktieren.");
    case "StripePermissionError":
      return new HttpsError("permission-denied", "Stripe-Berechtigung fehlt.");
    case "StripeRateLimitError":
      return new HttpsError("resource-exhausted", "Zu viele Anfragen — bitte gleich nochmal versuchen.");
    case "StripeConnectionError":
    case "StripeAPIError":
      return new HttpsError("unavailable", "Stripe ist gerade nicht erreichbar. Bitte später erneut versuchen.");
    default:
      logger.error(`[stripe] unhandled error (${type}):`, e);
      return new HttpsError("unknown", msg || fallbackMsg || "Stripe-Fehler.");
  }
}

// ---------- Path-Helfer ----------

/** Subcollection-Doc-Ref für die Stripe-Daten EINES Users. */
function userStripeAccountRef(db, uid) {
  return db.collection("users").doc(uid).collection("stripe").doc("account");
}

// ---------- Stripe-State-Cleanup ----------

/**
 * Räumt eine ungültige / nicht-existente Stripe-ID + abgeleiteten Status
 * aus der User-Subcollection. Onboarding kann dann sauber neu starten.
 */
async function clearInvalidStripeAccount(stripeRef) {
  await stripeRef.set({
    stripeAccountId: FieldValue.delete(),
    stripeChargesEnabled: false,
    stripePayoutsEnabled: false,
    stripeDetailsSubmitted: false,
    // Legacy-Feld aus der entfernten DevBypass-Logik aktiv löschen,
    // damit alte Test-States in Firestore verschwinden.
    stripeIsDevBypass: FieldValue.delete(),
    stripeOnboardingStatus: "incomplete",
    stripeStatusUpdatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
}

module.exports = {
  // Konstanten
  PLACEHOLDER_ACCOUNT_IDS,
  ONBOARD_RETURN_URL,
  ONBOARD_REFRESH_URL,
  HOST_BUSINESS_URL,

  // Helfer
  isRealStripeAccountId,
  toHttpsError,
  userStripeAccountRef,
  clearInvalidStripeAccount,
};
