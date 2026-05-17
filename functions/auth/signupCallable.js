// functions/auth/signupCallable.js
//
// SECURITY_HARDENING — Auth-Closure (Pre-Launch Audit C2).
//
// Server-seitige Account-Erstellung. Schließt die letzte verbleibende
// Quelle der passwordHash-Leakage: bis hierher schrieb der Client den
// Hash direkt nach /users bzw. /bars beim Signup — sichtbar für jeden
// anonym-authed Client.
//
// Neuer Flow:
//   client → signupCallable({userType, username, password, profile})
//        → server validiert, hasht, schreibt:
//             - users_secrets/{docId}.passwordHash  (server-only)
//             - users/{docId}                       (public profile, KEIN hash)
//           ODER (für bars):
//             - bars_secrets/{docId}.passwordHash   (server-only)
//             - bars/{docId}                        (public profile, KEIN hash, status: pending)
//        → returns:
//             - user: { ok, token, uid, profile } → client signInWithCustomToken
//             - bar:  { ok, uid, profile, requiresApproval: true } → KEIN Auto-Login (status pending)
//
// ─── Validierung ────────────────────────────────────────
//
//   - username: ^[a-z0-9_]{3,32}$ (intern als _lower; case-insensitive)
//   - password: 8-200 chars (HMAC-SHA256 wie bei loginCallable)
//   - cross-collection-Eindeutigkeit (kein user + bar mit gleichem username)
//   - user: vorname, nachname, mindestens 1 char
//   - user: Geburtsdatum 12+ (sonst HttpsError)
//   - bar:  barName, email, phoneNumber, address, city, country
//
// ─── Rate-Limit ─────────────────────────────────────────
//
//   - signupQuota/{bucketKey} mit 10/Stunde, Bucket = caller uid (anonymous)
//     ODER ip (rawRequest), je nach Verfügbarkeit. Schwacher Schutz weil
//     anonymous-Auth-UIDs trivial neu gezogen werden können — der echte
//     Schutz kommt mit App Check.
//
// ─── Cross-Refs ─────────────────────────────────────────
//
//   - loginCallable.js: identische Hash-Funktion + identische Cross-
//     Collection-Suche-Reihenfolge (users vor bars)
//   - migrateSecretsCallable.js: Backfill existierender Accounts
//   - deleteLegacyPasswordHashes.js: räumt passwordHash aus public docs

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");
const crypto = require("crypto");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "europe-west1";
const SIGNUP_QUOTA_LIMIT_PER_HOUR = 10;
const PASSWORD_MIN = 8;
const PASSWORD_MAX = 200;
const USERNAME_REGEX = /^[A-Za-z0-9_]{3,32}$/;

// Identisch mit loginCallable.hashLegacyPassword + Client _hashPassword.
function hashLegacyPassword(username, password) {
  const key = Buffer.from(username.toLowerCase(), "utf8");
  return crypto.createHmac("sha256", key).update(password, "utf8").digest("hex");
}

function bucketKey(request) {
  const uid = request.auth?.uid;
  if (uid) return `uid_${uid}`;
  const ip =
    request.rawRequest?.headers?.["x-forwarded-for"]?.toString().split(",")[0]?.trim() ||
    request.rawRequest?.ip ||
    "";
  if (ip) return `ip_${ip}`;
  return "anon_unknown";
}

async function checkAndIncrementQuota(bucket) {
  const ref = db.collection("signupQuota").doc(bucket);
  const nowMs = Date.now();
  const oneHourMs = 60 * 60 * 1000;
  return await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    let count = 0;
    let windowStart = nowMs;
    if (snap.exists) {
      const d = snap.data() || {};
      const ws = d.windowStartMs || 0;
      if (nowMs - ws < oneHourMs) {
        count = d.count || 0;
        windowStart = ws;
      }
    }
    if (count >= SIGNUP_QUOTA_LIMIT_PER_HOUR) {
      return { allowed: false, count };
    }
    tx.set(ref, {
      windowStartMs: windowStart,
      count: count + 1,
      lastAt: FieldValue.serverTimestamp(),
    });
    return { allowed: true, count: count + 1 };
  });
}

async function usernameTaken(username) {
  const lower = username.toLowerCase();
  // Check beide Collections — Namespace ist geteilt.
  for (const col of ["users", "bars"]) {
    // Variante 1: where username == raw
    try {
      const q = await db.collection(col).where("username", "==", username).limit(1).get();
      if (!q.empty) return `${col}:${q.docs[0].id}`;
    } catch (_) {}
    // Variante 2: where username_lower
    try {
      const q = await db.collection(col).where("username_lower", "==", lower).limit(1).get();
      if (!q.empty) return `${col}:${q.docs[0].id}`;
    } catch (_) {}
  }
  // Bar-DocID direkt prüfen (alte Bars haben docId == username).
  try {
    const direct = await db.collection("bars").doc(username).get();
    if (direct.exists) return `bars:${direct.id}`;
  } catch (_) {}
  return null;
}

function ageFromBirthday(year, month, day) {
  const now = new Date();
  let age = now.getFullYear() - year;
  const beforeBirthdayThisYear =
    now.getMonth() + 1 < month ||
    (now.getMonth() + 1 === month && now.getDate() < day);
  if (beforeBirthdayThisYear) age -= 1;
  return age;
}

async function signupUser(request) {
  const d = request.data || {};
  const username = String(d.username || "").trim();
  const password = String(d.password || "").trim();
  const vorname = String(d.vorname || "").trim();
  const nachname = String(d.nachname || "").trim();
  const tag = parseInt(d.geburtstag?.tag, 10);
  const monat = parseInt(d.geburtstag?.monat, 10);
  const jahr = parseInt(d.geburtstag?.jahr, 10);

  if (!vorname || !nachname) {
    throw new HttpsError("invalid-argument", "Vorname/Nachname fehlen.");
  }
  if (vorname.length > 50 || nachname.length > 50) {
    throw new HttpsError("invalid-argument", "Vorname/Nachname zu lang.");
  }
  if (!Number.isFinite(tag) || !Number.isFinite(monat) || !Number.isFinite(jahr)) {
    throw new HttpsError("invalid-argument", "Geburtsdatum ungültig.");
  }
  const age = ageFromBirthday(jahr, monat, tag);
  if (age < 12) {
    throw new HttpsError("failed-precondition", "Mindestalter 12.");
  }
  if (age > 120) {
    throw new HttpsError("invalid-argument", "Geburtsdatum ungültig.");
  }

  const docId = `${vorname} ${nachname}`.trim();
  if (!docId || docId.length > 100) {
    throw new HttpsError("invalid-argument", "Profilname ungültig.");
  }

  // Transaktionale Existenzprüfung des Ziel-Docs.
  // (Cross-Collection-Check außerhalb der TX, weil tx.get nicht über
  // where-Queries iteriert — Race ist hier sehr klein, da die Anzahl
  // Signups niedrig ist; trotzdem stabil weil docId eindeutig per
  // "Vorname Nachname" ist und beim set überschrieben würde.)
  const userRef = db.collection("users").doc(docId);
  const secretRef = db.collection("users_secrets").doc(docId);

  const existing = await userRef.get();
  if (existing.exists) {
    throw new HttpsError(
      "already-exists",
      "Profil mit diesem Vor- und Nachnamen existiert bereits."
    );
  }

  const passwordHash = hashLegacyPassword(username, password);

  await db.runTransaction(async (tx) => {
    // Re-check innerhalb TX zur Sicherheit.
    const reCheck = await tx.get(userRef);
    if (reCheck.exists) {
      throw new HttpsError("already-exists", "Profil existiert bereits.");
    }
    tx.set(userRef, {
      createdAt: FieldValue.serverTimestamp(),
      vorname,
      nachname,
      fullName: docId,
      username,
      username_lower: username.toLowerCase(),
      age,
      geburtsdatum: { tag, monat, jahr },
      phoneNumber: null,
      phoneVerified: false,
      authVersion: 2,
      // SECURITY_HARDENING: KEIN passwordHash, KEIN password in /users.
      // Hash liegt ausschließlich in users_secrets/{docId}.
    });
    tx.set(secretRef, {
      passwordHash,
      createdAt: FieldValue.serverTimestamp(),
      source: "signupCallable",
    });
  });

  const customToken = await admin.auth().createCustomToken(docId, {
    username,
    userType: "user",
  });

  logger.info("[signup] user created", { username, docId });

  return {
    ok: true,
    token: customToken,
    uid: docId,
    userType: "user",
    profile: {
      username,
      vorname,
      nachname,
      authVersion: 2,
      phoneVerified: false,
    },
  };
}

async function signupBar(request) {
  const d = request.data || {};
  const username = String(d.username || "").trim();
  const password = String(d.password || "").trim();
  const barName = String(d.barName || "").trim();
  const email = String(d.email || "").trim();
  const phoneNumber = String(d.phoneNumber || "").trim();
  const address = String(d.address || "").trim();
  const city = String(d.city || "").trim();
  const country = String(d.country || "").trim();
  const description = String(d.description || "").trim();
  const profileImageUrl = d.profileImageUrl ? String(d.profileImageUrl) : null;

  if (!barName) throw new HttpsError("invalid-argument", "Barname fehlt.");
  if (!email) throw new HttpsError("invalid-argument", "Email fehlt.");
  if (!phoneNumber) throw new HttpsError("invalid-argument", "Telefon fehlt.");
  if (!address) throw new HttpsError("invalid-argument", "Adresse fehlt.");
  if (!city) throw new HttpsError("invalid-argument", "Stadt fehlt.");
  if (!country) throw new HttpsError("invalid-argument", "Land fehlt.");
  if (barName.length > 100) {
    throw new HttpsError("invalid-argument", "Barname zu lang.");
  }
  if (description.length > 2000) {
    throw new HttpsError("invalid-argument", "Beschreibung zu lang.");
  }

  // Bar docId = username (matcht login-Lookup-Pfad).
  const docId = username;
  const barRef = db.collection("bars").doc(docId);
  const secretRef = db.collection("bars_secrets").doc(docId);

  const existing = await barRef.get();
  if (existing.exists) {
    throw new HttpsError(
      "already-exists",
      "Bar mit diesem Username existiert bereits."
    );
  }

  const passwordHash = hashLegacyPassword(username, password);

  await db.runTransaction(async (tx) => {
    const reCheck = await tx.get(barRef);
    if (reCheck.exists) {
      throw new HttpsError("already-exists", "Bar existiert bereits.");
    }
    const payload = {
      barId: username,
      barName,
      barName_lower: barName.toLowerCase(),
      username,
      username_lower: username.toLowerCase(),
      email,
      phoneNumber,
      address,
      city,
      city_lower: city.toLowerCase(),
      country,
      description,
      status: "pending",
      createdViaSelfRegistration: true,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
      // SECURITY_HARDENING: KEIN passwordHash in /bars.
    };
    if (profileImageUrl) payload.profileImageUrl = profileImageUrl;
    tx.set(barRef, payload);
    tx.set(secretRef, {
      passwordHash,
      createdAt: FieldValue.serverTimestamp(),
      source: "signupCallable",
    });
  });

  logger.info("[signup] bar created", { username, docId, status: "pending" });

  // KEIN Custom Token: bars sind pending bis Admin-Freischaltung.
  return {
    ok: true,
    uid: docId,
    userType: "bar",
    requiresApproval: true,
    profile: {
      username,
      barName,
      status: "pending",
    },
  };
}

exports.signupCallable = onCall(
  {
    region: REGION,
    maxInstances: 5,
    timeoutSeconds: 30,
    memory: "256MiB",
    concurrency: 20,
    // TODO(appcheck): nach Console-Setup auf `true` setzen.
    // Wichtig für Anti-Squatting bei username-Reservierung.
    enforceAppCheck: false,
  },
  async (request) => {
    const userType = String(request.data?.userType || "user").trim();
    if (userType !== "user" && userType !== "bar") {
      throw new HttpsError("invalid-argument", "userType must be 'user' or 'bar'.");
    }

    const username = String(request.data?.username || "").trim();
    const password = String(request.data?.password || "").trim();

    if (!USERNAME_REGEX.test(username)) {
      throw new HttpsError(
        "invalid-argument",
        "Username: 3-32 Zeichen, nur a-z, 0-9 und _."
      );
    }
    if (password.length < PASSWORD_MIN || password.length > PASSWORD_MAX) {
      throw new HttpsError(
        "invalid-argument",
        `Passwort muss ${PASSWORD_MIN}-${PASSWORD_MAX} Zeichen lang sein.`
      );
    }

    // Rate-Limit (best-effort, IP+UID-Bucket).
    const bucket = bucketKey(request);
    const quota = await checkAndIncrementQuota(bucket);
    if (!quota.allowed) {
      logger.warn("[signup] quota hit", { bucket, count: quota.count });
      throw new HttpsError(
        "resource-exhausted",
        "Zu viele Signups in kurzer Zeit. Bitte später erneut versuchen."
      );
    }

    // Cross-Collection-Eindeutigkeit (außerhalb der TX, akzeptabler
    // Race in Sub-Sekunden-Window).
    const taken = await usernameTaken(username);
    if (taken) {
      logger.info("[signup] username taken", { username, where: taken });
      throw new HttpsError("already-exists", "Username ist bereits vergeben.");
    }

    if (userType === "user") return await signupUser(request);
    return await signupBar(request);
  }
);
