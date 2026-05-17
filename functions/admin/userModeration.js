// functions/admin/userModeration.js
//
// Admin-Moderation-Callables. Jede Function ist hinter
// `request.auth.token.admin === true` gesichert. Operationen wirken
// IMMER auf zwei Systeme — Firestore (App-Daten) UND Firebase Auth
// (Identität). Cloud Functions nutzen Admin-SDK, das Firestore-Rules
// bypassed; deshalb ist der Admin-Claim-Check hier die einzige
// Berechtigungsschicht und MUSS solid sein.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "europe-west1";

// ---------- Helfer ----------

function assertAdmin(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Login erforderlich.");
  }
  if (request.auth.token?.admin !== true) {
    logger.warn("[admin] non-admin attempted moderation", {
      caller: request.auth.uid,
    });
    throw new HttpsError("permission-denied", "Nur Admins dürfen moderieren.");
  }
}

function requireUid(data) {
  const uid = String(data?.uid || "").trim();
  if (!uid) throw new HttpsError("invalid-argument", "uid fehlt.");
  return uid;
}

function mapAuthError(e) {
  if (e?.code === "auth/user-not-found") {
    return new HttpsError("not-found", "User existiert nicht in Firebase Auth.");
  }
  if (e?.code === "auth/invalid-uid") {
    return new HttpsError("invalid-argument", "Ungültige uid.");
  }
  return null;
}

// ---------- Ban ----------

exports.adminBanUser = onCall(
  {
    region: REGION,
    // Admin-Calls sollen niemals in großer Menge laufen — pro Klick
    // in der Admin-UI 1 Aufruf. Hartes Limit gegen Bug-Loops.
    maxInstances: 3,
    timeoutSeconds: 30, // updateUser + Firestore-set
    memory: "256MiB",
    concurrency: 10,
    // App Check: Admin-UI muss App Check Token mitschicken.
    // TODO(appcheck): nach Console-Setup auf `true` setzen
    enforceAppCheck: false,
  },
  async (request) => {
    assertAdmin(request);
    const uid = requireUid(request.data);
    const reason = String(request.data?.reason || "").trim();
    const callerUid = request.auth.uid;

    if (uid === callerUid) {
      throw new HttpsError("failed-precondition", "Du kannst dich nicht selbst bannen.");
    }

    try {
      // Auth: Account deaktivieren + Refresh-Tokens widerrufen.
      // Ohne revokeRefreshTokens kann der User mit gecachtem
      // Token weiter API-Calls machen, bis das Token abläuft (1h).
      await admin.auth().updateUser(uid, { disabled: true });
      await admin.auth().revokeRefreshTokens(uid);

      // Firestore-Spiegel — die App liest `banned` für UI-Gating.
      await db.collection("users").doc(uid).set({
        banned: true,
        bannedAt: FieldValue.serverTimestamp(),
        bannedBy: callerUid,
        banReason: reason || null,
      }, { merge: true });

      logger.info("[admin] user banned", { uid, by: callerUid, reason });
      return { ok: true };
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      const mapped = mapAuthError(e);
      if (mapped) throw mapped;
      logger.error("[admin] ban failed", { uid, msg: e?.message });
      throw new HttpsError("internal", e?.message || "Ban fehlgeschlagen.");
    }
  }
);

// ---------- Unban ----------

exports.adminUnbanUser = onCall(
  {
    region: REGION,
    // Admin-Calls sollen niemals in großer Menge laufen — pro Klick
    // in der Admin-UI 1 Aufruf. Hartes Limit gegen Bug-Loops.
    maxInstances: 3,
    timeoutSeconds: 30, // updateUser + Firestore-set
    memory: "256MiB",
    concurrency: 10,
    // App Check: Admin-UI muss App Check Token mitschicken.
    // TODO(appcheck): nach Console-Setup auf `true` setzen
    enforceAppCheck: false,
  },
  async (request) => {
    assertAdmin(request);
    const uid = requireUid(request.data);
    const callerUid = request.auth.uid;

    try {
      await admin.auth().updateUser(uid, { disabled: false });

      await db.collection("users").doc(uid).set({
        banned: false,
        unbannedAt: FieldValue.serverTimestamp(),
        unbannedBy: callerUid,
        bannedAt: FieldValue.delete(),
        bannedBy: FieldValue.delete(),
        banReason: FieldValue.delete(),
      }, { merge: true });

      logger.info("[admin] user unbanned", { uid, by: callerUid });
      return { ok: true };
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      const mapped = mapAuthError(e);
      if (mapped) throw mapped;
      logger.error("[admin] unban failed", { uid, msg: e?.message });
      throw new HttpsError("internal", e?.message || "Unban fehlgeschlagen.");
    }
  }
);

// ---------- Email verifizieren ----------

exports.adminVerifyEmail = onCall(
  {
    region: REGION,
    // Admin-Calls sollen niemals in großer Menge laufen — pro Klick
    // in der Admin-UI 1 Aufruf. Hartes Limit gegen Bug-Loops.
    maxInstances: 3,
    timeoutSeconds: 30, // updateUser + Firestore-set
    memory: "256MiB",
    concurrency: 10,
    // App Check: Admin-UI muss App Check Token mitschicken.
    // TODO(appcheck): nach Console-Setup auf `true` setzen
    enforceAppCheck: false,
  },
  async (request) => {
    assertAdmin(request);
    const uid = requireUid(request.data);
    const callerUid = request.auth.uid;

    try {
      // Setzt das Auth-Flag (was z.B. password-reset / change-email
      // beeinflusst) UND spiegelt es nach Firestore für UI-Gating.
      await admin.auth().updateUser(uid, { emailVerified: true });

      await db.collection("users").doc(uid).set({
        emailVerified: true,
        emailVerifiedAt: FieldValue.serverTimestamp(),
        emailVerifiedBy: callerUid,
      }, { merge: true });

      logger.info("[admin] email verified", { uid, by: callerUid });
      return { ok: true };
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      const mapped = mapAuthError(e);
      if (mapped) throw mapped;
      logger.error("[admin] verify-email failed", { uid, msg: e?.message });
      throw new HttpsError("internal", e?.message || "Email-Verifizierung fehlgeschlagen.");
    }
  }
);

// ---------- Delete ----------

exports.adminDeleteUser = onCall(
  {
    region: REGION,
    // Admin-Calls sollen niemals in großer Menge laufen — pro Klick
    // in der Admin-UI 1 Aufruf. Hartes Limit gegen Bug-Loops.
    maxInstances: 3,
    timeoutSeconds: 30, // updateUser + Firestore-set
    memory: "256MiB",
    concurrency: 10,
    // App Check: Admin-UI muss App Check Token mitschicken.
    // TODO(appcheck): nach Console-Setup auf `true` setzen
    enforceAppCheck: false,
  },
  async (request) => {
    assertAdmin(request);
    const uid = requireUid(request.data);
    const callerUid = request.auth.uid;

    if (uid === callerUid) {
      throw new HttpsError("failed-precondition", "Du kannst dich nicht selbst löschen.");
    }

    try {
      // 1) Firestore: User-Doc.
      // FEATURE_DISABLED_TICKETING — frühere Stripe-Subcoll-Bereinigung
      // (users/{uid}/stripe/*) wurde mit dem Ticketing-Removal entfernt;
      // keine Stripe-SDK-Abhängigkeit mehr im Admin-Pfad.
      // see archived/ticketing/README.md
      //
      // Andere Querverweise (Parties, friendRequests, ratings, reports,
      // tickets) bleiben bewusst stehen — sweep ist hier zu groß für eine
      // synchrone Function. Falls gewünscht: später per onUserDeleted-
      // Trigger nachziehen.
      const userRef = db.collection("users").doc(uid);
      await userRef.delete();

      // 2) Firebase Auth: Identity entfernen, sodass der User
      // sich nicht erneut einloggen kann. Falls Auth-User
      // bereits weg ist (z.B. von Hand gelöscht), ignorieren.
      try {
        await admin.auth().deleteUser(uid);
      } catch (e) {
        if (e?.code !== "auth/user-not-found") throw e;
        logger.warn("[admin] firestore deleted, auth user already gone", { uid });
      }

      logger.info("[admin] user deleted", { uid, by: callerUid });
      return { ok: true };
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      const mapped = mapAuthError(e);
      if (mapped) throw mapped;
      logger.error("[admin] delete failed", { uid, msg: e?.message });
      throw new HttpsError("internal", e?.message || "Löschen fehlgeschlagen.");
    }
  }
);
