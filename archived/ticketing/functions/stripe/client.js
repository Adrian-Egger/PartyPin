// functions/stripe/client.js
// Gemeinsamer Stripe-Client + Secret-Definitionen.

const { defineSecret } = require("firebase-functions/params");
const { HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const Stripe = require("stripe");

// Secrets — werden via `firebase functions:secrets:set <NAME>` gesetzt.
const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");          // sk_live_… oder sk_test_…
const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");  // whsec_…

// SMTP für Ticket-Mails (Gmail-App-Passwort empfohlen)
const SMTP_USER = defineSecret("SMTP_USER");        // z.B. mypartypin@gmail.com
const SMTP_PASSWORD = defineSecret("SMTP_PASSWORD"); // App-Password aus Google-Account

// Plattform-Konfiguration
const PLATFORM_FEE_PERCENT = 3; // du bekommst 3 %, Host 97 %
const CURRENCY = "eur";

function getStripe() {
  const key = (STRIPE_SECRET_KEY.value() || "").trim();
  if (!key) {
    // Defense-in-depth: auch wenn der Aufrufer das nicht in einem try
    // hat, bekommt der Client einen lesbaren HttpsError statt INTERNAL.
    logger.error("[stripe] STRIPE_SECRET_KEY secret ist leer/nicht gesetzt.");
    throw new HttpsError(
      "failed-precondition",
      "Stripe ist nicht konfiguriert. Bitte STRIPE_SECRET_KEY setzen und Functions neu deployen."
    );
  }
  if (!key.startsWith("sk_live_") && !key.startsWith("sk_test_")) {
    logger.error("[stripe] STRIPE_SECRET_KEY hat ein ungültiges Format.");
    throw new HttpsError(
      "failed-precondition",
      "Stripe-Schlüssel ist ungültig. Bitte STRIPE_SECRET_KEY prüfen."
    );
  }
  return new Stripe(key, { apiVersion: "2024-11-20.acacia" });
}

module.exports = {
  STRIPE_SECRET_KEY,
  STRIPE_WEBHOOK_SECRET,
  SMTP_USER,
  SMTP_PASSWORD,
  PLATFORM_FEE_PERCENT,
  CURRENCY,
  getStripe,
};
