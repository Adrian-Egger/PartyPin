// functions/migrations/migrateStripeToSubcollection.js
//
// Einmalige Migration: Stripe-Felder vom User-Doc nach
//   users/{uid}/stripe/account
// verschieben und danach aus dem User-Doc löschen.
//
// Aufruf (als HTTPS-Function, Token-geschützt):
//
//   1) Token einmalig setzen:
//        firebase functions:secrets:set MIGRATION_TOKEN
//      (z.B. einen langen Random-String einfügen)
//
//   2) Functions deployen:
//        firebase deploy --only functions:migrateStripeToSubcollection
//
//   3) Dry-Run (zeigt was migriert würde, schreibt nichts):
//        curl "https://europe-west1-<project>.cloudfunctions.net/migrateStripeToSubcollection" \
//          -H "X-Migration-Token: <DEIN_TOKEN>"
//
//   4) Echte Migration:
//        curl "https://europe-west1-<project>.cloudfunctions.net/migrateStripeToSubcollection?apply=1" \
//          -H "X-Migration-Token: <DEIN_TOKEN>"
//
//   5) Function nach erfolgreichem Lauf löschen (siehe README/Anleitung).
//
// Idempotent: erneutes Ausführen ist safe — verschobene Felder sind dann
// nicht mehr im User-Doc, das Script überspringt sie.

const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");

const MIGRATION_TOKEN = defineSecret("MIGRATION_TOKEN");

const STRIPE_FIELDS = [
  "stripeAccountId",
  "stripeAccountCreatedAt",
  "stripeChargesEnabled",
  "stripeDetailsSubmitted",
  "stripeIsDevBypass",
  "stripeOnboardingStatus",
  "stripePayoutsEnabled",
  "stripeStatusUpdatedAt",
];

exports.migrateStripeToSubcollection = onRequest(
  {
    region: "europe-west1",
    secrets: [MIGRATION_TOKEN],
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async (req, res) => {
    // --- Auth: shared-secret im Header ---
    const expected = (MIGRATION_TOKEN.value() || "").trim();
    const provided = (req.headers["x-migration-token"] || "").toString().trim();
    if (!expected) {
      res.status(500).json({ error: "MIGRATION_TOKEN secret nicht gesetzt." });
      return;
    }
    if (provided !== expected) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }

    const apply = req.query.apply === "1" || req.query.apply === "true";
    const db = admin.firestore();
    const FieldValue = admin.firestore.FieldValue;

    const usersSnap = await db.collection("users").get();

    let migrated = 0;
    let skipped = 0;
    let failed = 0;
    const details = [];

    for (const doc of usersSnap.docs) {
      const data = doc.data() || {};
      const stripeData = {};
      const deletes = {};

      for (const f of STRIPE_FIELDS) {
        if (Object.prototype.hasOwnProperty.call(data, f)) {
          stripeData[f] = data[f];
          deletes[f] = FieldValue.delete();
        }
      }

      const fields = Object.keys(stripeData);
      if (fields.length === 0) {
        skipped++;
        continue;
      }

      if (!apply) {
        details.push({ uid: doc.id, fields });
        migrated++;
        continue;
      }

      try {
        const stripeRef = doc.ref.collection("stripe").doc("account");
        await stripeRef.set(stripeData, { merge: true });
        await doc.ref.update(deletes);
        migrated++;
        details.push({ uid: doc.id, fields });
      } catch (e) {
        failed++;
        details.push({ uid: doc.id, error: e.message });
      }
    }

    res.status(200).json({
      mode: apply ? "apply" : "dry-run",
      totalUsers: usersSnap.size,
      migrated,
      skipped,
      failed,
      details,
    });
  }
);
