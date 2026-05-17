// functions/auth/migrateSecretsCallable.js
//
// SECURITY_HARDENING — Auth-Migration Backfill (Pre-Launch Audit C1).
//
// Admin-only one-shot Migration: kopiert passwordHash + (legacy)
// password aus /users/{docId} nach users_secrets/{docId} und
// aus /bars/{docId} nach bars_secrets/{docId} für alle existierenden
// Accounts. Macht den lazy-migration-Pfad in loginCallable.js redundant
// — danach können wir passwordHash aus public-Docs mit gutem Gewissen
// löschen (separates Cleanup-Skript, NICHT hier).
//
// ─── Wichtig ────────────────────────────────────────────
//
// 1. NICHT automatisch deployen ohne Test.
// 2. NICHT die alten Felder hier löschen — das macht ein SEPARATES
//    Skript NACH Beobachtungs-Zeit, weil alte App-Versionen sie
//    sonst nicht mehr lesen können.
// 3. Nur Admin-Caller (request.auth.token.admin === true).
//
// ─── Deployment ─────────────────────────────────────────
//
//   firebase deploy --only functions:migrateAuthSecrets
//
// ─── Trigger (einmalig) ─────────────────────────────────
//
//   const fn = httpsCallable(getFunctions(), 'migrateAuthSecrets');
//   const res = await fn({ collection: 'users', dryRun: true });
//   console.log(res.data);
//   // resume: const next = await fn({ collection: 'users', dryRun: true, lastDocId: res.data.lastDocId });
//   // wenn done: dryRun=false
//   // dann das gleiche für 'bars'
//
// Bei großen User-Mengen läuft die CF in Batches (max 500 pro Aufruf).

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "europe-west1";
const BATCH_SIZE = 500;

const COLLECTIONS = {
  users: { source: "users", target: "users_secrets" },
  bars: { source: "bars", target: "bars_secrets" },
};

exports.migrateAuthSecrets = onCall(
  {
    region: REGION,
    maxInstances: 1, // single instance — sonst Race auf der Cursor-Logik
    timeoutSeconds: 540,
    memory: "512MiB",
    concurrency: 1,
    enforceAppCheck: false,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Login erforderlich.");
    }
    if (request.auth.token?.admin !== true) {
      throw new HttpsError("permission-denied", "Admin only.");
    }

    const collectionKey = String(request.data?.collection || "users");
    const mapping = COLLECTIONS[collectionKey];
    if (!mapping) {
      throw new HttpsError(
        "invalid-argument",
        "collection must be 'users' or 'bars'"
      );
    }

    const dryRun = request.data?.dryRun !== false; // default true
    const lastDocId = (request.data?.lastDocId || "").toString().trim();

    let query = db
      .collection(mapping.source)
      .orderBy("__name__")
      .limit(BATCH_SIZE);
    if (lastDocId) {
      query = query.startAfter(lastDocId);
    }

    const snap = await query.get();
    let migrated = 0;
    let skippedExisting = 0;
    let skippedNoSecret = 0;
    let lastIdSeen = lastDocId;

    for (const doc of snap.docs) {
      lastIdSeen = doc.id;
      const d = doc.data() || {};
      const passwordHash = (d.passwordHash || "").toString();
      const plain = (d.password || "").toString();

      if (!passwordHash && !plain) {
        skippedNoSecret += 1;
        continue;
      }

      // Idempotenz: prüfe ob already migrated.
      const existing = await db.collection(mapping.target).doc(doc.id).get();
      if (existing.exists) {
        skippedExisting += 1;
        continue;
      }

      if (!dryRun) {
        const payload = {
          migratedAt: FieldValue.serverTimestamp(),
          migratedFrom: passwordHash ? mapping.source : `${mapping.source}_plain`,
        };
        if (passwordHash) payload.passwordHash = passwordHash;
        if (plain) payload.passwordPlain = plain; // wird beim nächsten Login durch loginCallable lazy zu Hash konvertiert
        await db.collection(mapping.target).doc(doc.id).set(payload, { merge: true });
      }
      migrated += 1;
    }

    logger.info("[migrate] batch done", {
      collection: collectionKey,
      dryRun,
      seen: snap.size,
      migrated,
      skippedExisting,
      skippedNoSecret,
      lastIdSeen,
    });

    return {
      ok: true,
      collection: collectionKey,
      dryRun,
      seen: snap.size,
      migrated,
      skippedExisting,
      skippedNoSecret,
      lastDocId: lastIdSeen,
      done: snap.size < BATCH_SIZE,
    };
  }
);
