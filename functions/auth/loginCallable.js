// functions/auth/loginCallable.js
//
// SECURITY_HARDENING — Auth-Migration (Pre-Launch Audit C1+C2).
//
// Server-seitiger Login-Endpoint. Ersetzt die client-seitige
// Hash-Vergleichs-Logik in lib/Screens/auth/login_screen.dart, die
// jedem anonym-authed Client erlaubte, alle passwordHashes der
// /users-Collection zu lesen (siehe Audit-Finding C1).
//
// Nach erfolgreicher Verifikation wird ein Firebase Custom Token
// ausgestellt, mit dem der Client per `signInWithCustomToken` eine
// stabile UID bekommt. Diese UID = docId des User-Docs ("Vorname
// Nachname") für users / barId für bars.
//
// ─── Account-Typen ──────────────────────────────────────
//
// Diese CF deckt BEIDE Login-Typen ab — der Client muss nicht
// vorher wissen ob es ein user- oder bar-Account ist. Reihenfolge:
//   1. /users where username == input    → userType "user"
//   2. /bars/{input}                      → userType "bar"
//   3. /bars where username == input      → userType "bar"
//
// Bei bar-Accounts wird `status` (pending/approved/rejected) im
// Response mitgegeben, damit der Client passende Fehler zeigen kann
// — die CF blockiert pending/rejected NICHT auf Token-Ebene, sondern
// liefert nur den Status. Begründung: ein pending-Bar darf z.B.
// noch sein eigenes Profil sehen, nur nicht die App komplett nutzen.
//
// ─── Daten-Modell ────────────────────────────────────────
//
// Phase 0 (heute):  users/{docId}.passwordHash       ← Hash leakt
// Phase 1 (Hotfix): users_secrets/{docId}.passwordHash ← server-only
//                   bars_secrets/{docId}.passwordHash  ← server-only
//
// loginCallable liest aus *_secrets WENN da, sonst Fallback auf
// users/bars (für noch-nicht-migrierte Accounts). Nach erfolgreichem
// Login mit Legacy-Hash: lazy migration in *_secrets.
//
// ─── Deployment-Checkliste ──────────────────────────────
//
// 1. Diese CF deployen: firebase deploy --only functions:loginCallable
// 2. Test mit existierendem User-Account: CF Aufruf, Custom Token zurück
// 3. Test mit existierendem Bar-Account: ebenfalls
// 4. App-Version mit CF-basiertem Login bauen + ausrollen
// 5. migrateAuthSecrets laufen lassen (siehe migrateSecretsCallable.js)
// 6. Nach Wochen Beobachtung: passwordHash aus users / bars entfernen
//    (DEFERRED — breaks alte App-Versionen)

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");
const crypto = require("crypto");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "europe-west1";

// MUSS identisch sein mit lib/Screens/auth/login_screen.dart::_hashPassword.
// HMAC-SHA256(username_lower, password) ohne Salt — schwach, aber als
// Brücke akzeptabel. Eine echte Lösung bricht die Brücke und nutzt
// scrypt/argon2 (separate Iteration).
function hashLegacyPassword(username, password) {
  const key = Buffer.from(username.toLowerCase(), "utf8");
  return crypto.createHmac("sha256", key).update(password, "utf8").digest("hex");
}

/**
 * Findet den Account-Doc für einen username (users ODER bars).
 * Reihenfolge spiegelt das alte client-seitige Verhalten.
 *
 * @returns {{
 *   collection: 'users'|'bars',
 *   secretCollection: 'users_secrets'|'bars_secrets',
 *   docId: string,
 *   data: object,
 *   userType: 'user'|'bar'
 * } | null}
 */
async function findAccountByUsername(username) {
  // 1. /users where username == input
  try {
    const userQ = await db
      .collection("users")
      .where("username", "==", username)
      .limit(1)
      .get();
    if (!userQ.empty) {
      const d = userQ.docs[0];
      return {
        collection: "users",
        secretCollection: "users_secrets",
        docId: d.id,
        data: d.data() || {},
        userType: "user",
      };
    }
  } catch (_) {}

  // 2. /bars/{input} (docId == username)
  try {
    const barDoc = await db.collection("bars").doc(username).get();
    if (barDoc.exists) {
      return {
        collection: "bars",
        secretCollection: "bars_secrets",
        docId: barDoc.id,
        data: barDoc.data() || {},
        userType: "bar",
      };
    }
  } catch (_) {}

  // 3. /bars where username == input
  try {
    const barQ = await db
      .collection("bars")
      .where("username", "==", username)
      .limit(1)
      .get();
    if (!barQ.empty) {
      const d = barQ.docs[0];
      return {
        collection: "bars",
        secretCollection: "bars_secrets",
        docId: d.id,
        data: d.data() || {},
        userType: "bar",
      };
    }
  } catch (_) {}

  return null;
}

/**
 * Liest den stored Hash. Bevorzugt *_secrets (Phase-1),
 * Fallback auf /users.passwordHash (Phase-0).
 */
async function getStoredHash(account) {
  try {
    const secretSnap = await db
      .collection(account.secretCollection)
      .doc(account.docId)
      .get();
    if (secretSnap.exists) {
      const sd = secretSnap.data() || {};
      const h = (sd.passwordHash || "").toString();
      if (h) return { hash: h, source: account.secretCollection };
      const p = (sd.passwordPlain || "").toString();
      if (p) return { hash: null, plain: p, source: `${account.secretCollection}_plain` };
    }
  } catch (_) {}

  const legacyHash = (account.data.passwordHash || "").toString();
  if (legacyHash) return { hash: legacyHash, source: account.collection };

  // Allerletzter Fallback: legacy plaintext password.
  const legacyPlain = (account.data.password || "").toString();
  if (legacyPlain) return { hash: null, plain: legacyPlain, source: `${account.collection}_plain` };

  return null;
}

exports.loginCallable = onCall(
  {
    region: REGION,
    maxInstances: 5,
    timeoutSeconds: 15,
    memory: "256MiB",
    concurrency: 40,
    // TODO(appcheck): nach Console-Setup auf `true` setzen
    enforceAppCheck: false,
  },
  async (request) => {
    const username = String(request.data?.username || "").trim();
    const password = String(request.data?.password || "").trim();
    if (!username || !password) {
      throw new HttpsError("invalid-argument", "username/password required.");
    }
    if (password.length > 200 || username.length > 64) {
      throw new HttpsError("invalid-argument", "input too long.");
    }

    const account = await findAccountByUsername(username);
    if (!account) {
      // Identischer Error für „nicht gefunden" und „falsches Passwort"
      // damit Brute-Force-Bots keinen Username-Enumeration-Vorteil haben.
      logger.info("[login] account not found", { username });
      throw new HttpsError("unauthenticated", "Login fehlgeschlagen.");
    }

    const stored = await getStoredHash(account);
    if (!stored) {
      logger.warn("[login] no stored credential", {
        collection: account.collection,
        docId: account.docId,
      });
      throw new HttpsError("unauthenticated", "Login fehlgeschlagen.");
    }

    const inputHash = hashLegacyPassword(username, password);
    let valid = false;
    if (stored.hash) {
      valid = stored.hash === inputHash;
    } else if (stored.plain) {
      valid = stored.plain === password;
    }
    if (!valid) {
      logger.info("[login] bad credentials", {
        username,
        source: stored.source,
      });
      throw new HttpsError("unauthenticated", "Login fehlgeschlagen.");
    }

    // Ban-Check: User/Bar mit banned=true wird abgewiesen.
    // Wichtig: nach Hash-Verifikation, damit ein Angreifer den
    // banned-Status nicht ohne richtiges Passwort sondieren kann.
    if (account.data.banned === true) {
      logger.warn("[login] banned account login attempt", {
        collection: account.collection,
        docId: account.docId,
      });
      throw new HttpsError(
        "permission-denied",
        "Account ist gesperrt. Bitte Support kontaktieren."
      );
    }

    // Lazy migration: wenn der gültige Hash noch im public-Doc liegt,
    // kopiere ihn nach *_secrets. Die alte Stelle bleibt (vorerst) —
    // Cut-Over später durch Migration-CF + Cleanup-Skript.
    const isLegacySource =
      stored.source === account.collection ||
      stored.source === `${account.collection}_plain`;
    if (isLegacySource) {
      try {
        await db.collection(account.secretCollection).doc(account.docId).set(
          {
            passwordHash: inputHash,
            migratedAt: FieldValue.serverTimestamp(),
            migratedFrom: stored.source,
          },
          { merge: true }
        );
      } catch (e) {
        logger.warn("[login] lazy migration failed", {
          docId: account.docId,
          msg: e?.message,
        });
        // Nicht-fatal — Login fortsetzen.
      }
    }

    // ── Admin-Claim (server-seitig, nicht client-spoofbar) ──────────────
    // Der `admin`-Custom-Claim ist die EINZIGE Quelle für Admin-Rechte in
    // Firestore-Rules (isAdmin()) und Admin-Cloud-Functions (assertAdmin).
    // Er wird HIER beim Login server-verifiziert vergeben:
    //   • primär über das Feld users/{uid}.isAdmin === true. Dieses Feld ist
    //     in den Rules server-only (lockedUserFields) → ein Client kann es
    //     NICHT selbst setzen.
    //   • Bootstrap für den bekannten Stamm-Admin (ADMIN_USERNAMES): beim
    //     ersten Login wird isAdmin=true persistiert, damit er den Claim
    //     bekommt, ohne dass jemand manuell in der Console rumsetzen muss.
    //     Usernames sind eindeutig → niemand sonst kann "admin_pp" belegen.
    const ADMIN_USERNAMES = ["admin_pp"];
    const uname = (account.data.username || "").toString();
    let isAdmin = account.data.isAdmin === true;
    if (
      !isAdmin &&
      account.collection === "users" &&
      ADMIN_USERNAMES.includes(uname)
    ) {
      isAdmin = true;
      // isAdmin-Feld für Konsistenz persistieren (server-only Feld).
      try {
        await db
          .collection(account.collection)
          .doc(account.docId)
          .set({ isAdmin: true }, { merge: true });
      } catch (e) {
        logger.warn("[login] isAdmin bootstrap write failed", {
          docId: account.docId,
          msg: e?.message,
        });
        // Nicht-fatal — der Claim wird trotzdem ins Token geschrieben.
      }
    }

    // Custom Token: UID = docId. Custom Claims enthalten userType +
    // username, damit die App das aus dem ID-Token lesen kann (kein
    // extra Firestore-Read nach Login). Bei Admins zusätzlich `admin: true`.
    const uid = account.docId;
    const claims = {
      username: uname,
      userType: account.userType,
    };
    if (isAdmin) claims.admin = true;

    let customToken;
    try {
      customToken = await admin.auth().createCustomToken(uid, claims);
    } catch (e) {
      logger.error("[login] custom token failed", { uid, msg: e?.message });
      throw new HttpsError("internal", "Token konnte nicht erstellt werden.");
    }

    if (isAdmin) {
      logger.info("[login] admin token issued", { uid, username: uname });
    }

    // Telemetrie: lastActive + login-Quelle. Best-effort, nicht-fatal.
    try {
      await db.collection(account.collection).doc(account.docId).set(
        {
          lastActive: FieldValue.serverTimestamp(),
          lastLoginVia: "cf",
        },
        { merge: true }
      );
    } catch (_) {}

    // Public-Profil-Daten zurückgeben, damit der Client sie direkt in
    // prefs spiegeln kann ohne weiteren /users-Read.
    // KEIN passwordHash, KEIN password, KEINE locked fields.
    const d = account.data;
    const publicProfile = {
      username: (d.username || "").toString(),
      vorname: (d.vorname || "").toString(),
      nachname: (d.nachname || "").toString(),
      phoneNumber: (d.phoneNumber || "").toString(),
      phoneVerified: d.phoneVerified === true,
      authVersion: typeof d.authVersion === "number" ? d.authVersion : 1,
      termsAccepted: d.termsAccepted === true,
      language: (d.language || "").toString(),
      country: (d.country || "").toString(),
      city: (d.city || "").toString(),
      selectedLat: typeof d.selectedLat === "number" ? d.selectedLat : null,
      selectedLng: typeof d.selectedLng === "number" ? d.selectedLng : null,
    };
    if (account.userType === "bar") {
      publicProfile.barName = (d.barName || "").toString();
      publicProfile.status = (d.status || "").toString();
    }

    return {
      ok: true,
      token: customToken,
      uid,
      userType: account.userType,
      profile: publicProfile,
    };
  }
);
