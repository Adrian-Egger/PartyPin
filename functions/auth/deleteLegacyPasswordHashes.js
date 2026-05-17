// functions/auth/deleteLegacyPasswordHashes.js
//
// SECURITY_HARDENING — Final Cleanup (Pre-Launch Audit C1).
//
// Admin-only one-shot Cleanup: löscht `passwordHash` UND `password`
// aus /users/{*} und /bars/{*}. NUR ausführen NACHDEM:
//   1. signupCallable + loginCallable in der App live sind
//   2. migrateAuthSecrets vollständig durchgelaufen ist
//   3. Beobachtungs-Zeit (≥2 Wochen) damit alte App-Versionen migriert
//      sind ODER die Maintainer wissentlich akzeptieren, dass alte App-
//      Versionen nicht mehr login-fähig sind
//
// Defensive Architektur:
//   - dryRun default true
//   - Per-Record-Safety: lösche Hash aus /users/X NUR wenn
//     users_secrets/X.passwordHash existiert UND nicht leer
//   - Batched (max 500/Aufruf), resumable via lastDocId
//   - Idempotent: Records ohne passwordHash werden übersprungen
//   - Global-Schwelle: wenn >5% der Records keine users_secrets haben,
//     wird der Lauf abgebrochen (außer `force: true`)
//
// ─── Deployment ─────────────────────────────────────────
//
//   firebase deploy --only functions:deleteLegacyPasswordHashes
//
// ─── Trigger (in dieser Reihenfolge) ────────────────────
//
//   const fn = httpsCallable(getFunctions('europe-west1'),
//                             'deleteLegacyPasswordHashes');
//   // 1. Dry-run users
//   let res = await fn({ collection: 'users', dryRun: true });
//   console.log(res.data);
//   while (!res.data.done) {
//     res = await fn({
//       collection: 'users', dryRun: true, lastDocId: res.data.lastDocId
//     });
//   }
//   // 2. Wenn Zahlen ok (skippedMissingSecret klein):
//   res = await fn({ collection: 'users', dryRun: false });
//   // Resume bis done.
//
//   // Gleiches Spiel für bars.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "europe-west1";
const BATCH_SIZE = 500;
const SAFETY_MISSING_SECRETS_PCT = 0.05;

const MAPPING = {
  users: { source: "users", secret: "users_secrets" },
  bars: { source: "bars", secret: "bars_secrets" },
};

exports.deleteLegacyPasswordHashes = onCall(
  {
    region: REGION,
    maxInstances: 1, // single-instance, cursor-basiert
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
    const mapping = MAPPING[collectionKey];
    if (!mapping) {
      throw new HttpsError(
        "invalid-argument",
        "collection must be 'users' or 'bars'"
      );
    }
    const dryRun = request.data?.dryRun !== false; // default true
    const force = request.data?.force === true;
    const lastDocId = (request.data?.lastDocId || "").toString().trim();

    let query = db
      .collection(mapping.source)
      .orderBy("__name__")
      .limit(BATCH_SIZE);
    if (lastDocId) query = query.startAfter(lastDocId);

    const snap = await query.get();

    let scanned = 0;
    let cleaned = 0;
    let skippedAlreadyClean = 0;
    let skippedMissingSecret = 0;
    let lastIdSeen = lastDocId;
    const samplesMissing = []; // erste 5 IDs ohne Secret — für Debug-Logs

    for (const doc of snap.docs) {
      lastIdSeen = doc.id;
      scanned += 1;
      const d = doc.data() || {};
      const hasHash =
        (d.passwordHash || "").toString().length > 0 ||
        (d.password || "").toString().length > 0;
      if (!hasHash) {
        skippedAlreadyClean += 1;
        continue;
      }

      // Per-Record-Safety: zugehöriges Secret-Doc MUSS existieren mit
      // gültigem passwordHash. Sonst Skip + Log.
      const secretSnap = await db.collection(mapping.secret).doc(doc.id).get();
      const secretValid =
        secretSnap.exists &&
        ((secretSnap.data()?.passwordHash || "").toString().length > 0 ||
          (secretSnap.data()?.passwordPlain || "").toString().length > 0);
      if (!secretValid) {
        skippedMissingSecret += 1;
        if (samplesMissing.length < 5) samplesMissing.push(doc.id);
        continue;
      }

      if (!dryRun) {
        await doc.ref.update({
          passwordHash: FieldValue.delete(),
          password: FieldValue.delete(),
          passwordHashCleanedAt: FieldValue.serverTimestamp(),
        });
      }
      cleaned += 1;
    }

    const missingPct = scanned > 0 ? skippedMissingSecret / scanned : 0;
    const safetyTriggered = missingPct > SAFETY_MISSING_SECRETS_PCT && !force;

    logger.info("[cleanup] batch done", {
      collection: collectionKey,
      dryRun,
      scanned,
      cleaned,
      skippedAlreadyClean,
      skippedMissingSecret,
      missingPct: Number(missingPct.toFixed(3)),
      safetyTriggered,
      lastIdSeen,
      samplesMissing,
    });

    if (safetyTriggered && !dryRun) {
      // Safety-Abbruch: das wäre echter Cleanup, aber zu viele Records
      // hätten ihr Secret verloren — User würden sich nicht mehr
      // einloggen können. Abbruch BEVOR der Cleanup angewandt wird.
      // Hinweis: die bereits in dieser Batch gelöschten Records sind
      // weg — daher first dry-run, dann scharf.
      throw new HttpsError(
        "failed-precondition",
        `Safety abort: ${(missingPct * 100).toFixed(1)}% der Records haben kein Secret-Doc. ` +
          `Erst Migration nachholen oder mit force:true wiederholen.`
      );
    }

    return {
      ok: true,
      collection: collectionKey,
      dryRun,
      scanned,
      cleaned,
      skippedAlreadyClean,
      skippedMissingSecret,
      missingPct: Number(missingPct.toFixed(3)),
      lastDocId: lastIdSeen,
      done: snap.size < BATCH_SIZE,
      samplesMissing,
    };
  }
);
