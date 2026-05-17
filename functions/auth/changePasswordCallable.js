// functions/auth/changePasswordCallable.js
//
// SECURITY_HARDENING — Final-Closure-Session (2026-05-17).
//
// Server-seitiger Password-Change. Vorher las profil_settings_screen
// `passwordHash` direkt aus /users für Verifikation und schrieb den
// neuen Hash zurück — beides am Hash-Leak in /users beteiligt. Nach
// dem deleteLegacyPasswordHashes-Cleanup wäre der alte Flow gebrochen
// (kein Hash mehr in /users zum Vergleichen).
//
// Neuer Flow:
//   1. Caller muss eingeloggt sein per Custom Token (uid == docId).
//      Legacy anonymous-Sessions können das NICHT — sie müssen erst
//      via loginCallable einen Custom Token holen.
//   2. CF liest passwordHash aus users_secrets/{uid} (lazy migration
//      aus /users wenn nötig — analog loginCallable).
//   3. Verifiziert currentPassword.
//   4. Schreibt neuen Hash NUR nach users_secrets, NICHT zurück nach
//      /users. Ggf. löscht passwordHash aus /users falls noch da.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");
const crypto = require("crypto");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "europe-west1";

function hashLegacyPassword(username, password) {
  const key = Buffer.from(username.toLowerCase(), "utf8");
  return crypto.createHmac("sha256", key).update(password, "utf8").digest("hex");
}

exports.changePasswordCallable = onCall(
  {
    region: REGION,
    maxInstances: 5,
    timeoutSeconds: 15,
    memory: "256MiB",
    concurrency: 20,
    enforceAppCheck: false, // TODO(appcheck)
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Login erforderlich.");
    }

    // SECURITY: nur Custom-Token-Sessions kommen durch. Anonymous-
    // Sessions haben keine username-Claim und keine stabile uid →
    // wären für password-change ohnehin unsicher.
    const provider = request.auth.token?.firebase?.sign_in_provider;
    if (provider !== "custom") {
      throw new HttpsError(
        "permission-denied",
        "Bitte erst neu einloggen, dann Passwort ändern."
      );
    }

    const callerUid = request.auth.uid;
    const claimUsername = (request.auth.token?.username || "").toString().trim();

    const currentPassword = String(request.data?.currentPassword || "").trim();
    const newPassword = String(request.data?.newPassword || "").trim();
    if (!currentPassword || !newPassword) {
      throw new HttpsError("invalid-argument", "Passwörter fehlen.");
    }
    if (newPassword.length < 8 || newPassword.length > 200) {
      throw new HttpsError(
        "invalid-argument",
        "Neues Passwort muss 8-200 Zeichen lang sein."
      );
    }
    if (currentPassword === newPassword) {
      throw new HttpsError(
        "invalid-argument",
        "Neues Passwort muss sich vom alten unterscheiden."
      );
    }

    // Account-Doc finden (uid == docId in /users oder /bars).
    let collection, secretCollection;
    let userDocSnap = await db.collection("users").doc(callerUid).get();
    if (userDocSnap.exists) {
      collection = "users";
      secretCollection = "users_secrets";
    } else {
      userDocSnap = await db.collection("bars").doc(callerUid).get();
      if (userDocSnap.exists) {
        collection = "bars";
        secretCollection = "bars_secrets";
      } else {
        throw new HttpsError("not-found", "Account nicht gefunden.");
      }
    }

    // Username für Hash-Key: priorisiere Claim, fallback auf doc.username.
    const username = claimUsername || (userDocSnap.data()?.username || "").toString();
    if (!username) {
      throw new HttpsError("failed-precondition", "Account hat keinen Username.");
    }

    // Stored Hash: aus *_secrets bevorzugt, fallback auf legacy /users.
    let storedHash = "";
    let storedPlain = "";
    try {
      const sec = await db.collection(secretCollection).doc(callerUid).get();
      if (sec.exists) {
        storedHash = (sec.data()?.passwordHash || "").toString();
        storedPlain = (sec.data()?.passwordPlain || "").toString();
      }
    } catch (_) {}
    if (!storedHash && !storedPlain) {
      const d = userDocSnap.data() || {};
      storedHash = (d.passwordHash || "").toString();
      storedPlain = (d.password || "").toString();
    }
    if (!storedHash && !storedPlain) {
      logger.warn("[changePw] no stored credential", { uid: callerUid });
      throw new HttpsError("failed-precondition", "Account hat kein Passwort gespeichert.");
    }

    const currentHash = hashLegacyPassword(username, currentPassword);
    const verified =
      (storedHash && storedHash === currentHash) ||
      (storedPlain && storedPlain === currentPassword);
    if (!verified) {
      logger.info("[changePw] bad current password", { uid: callerUid });
      throw new HttpsError("permission-denied", "Aktuelles Passwort ist falsch.");
    }

    const newHash = hashLegacyPassword(username, newPassword);

    // Neuen Hash NUR in *_secrets schreiben. /users / /bars bleiben
    // ohne passwordHash (Audit C1).
    await db.collection(secretCollection).doc(callerUid).set(
      {
        passwordHash: newHash,
        passwordPlain: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
        source: "changePasswordCallable",
      },
      { merge: true }
    );

    // Wenn der alte Hash noch im public Doc lebt: lautlos entfernen.
    // Best-effort — falls fehlschlägt, läuft deleteLegacyPasswordHashes
    // später drüber.
    try {
      await db.collection(collection).doc(callerUid).update({
        passwordHash: FieldValue.delete(),
        password: FieldValue.delete(),
      });
    } catch (_) {}

    logger.info("[changePw] success", { uid: callerUid, collection });
    return { ok: true };
  }
);
