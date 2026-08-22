/* eslint-disable */

// =======================
// functions/index.js  (DEFAULT codebase)  (KOMPLETT, deploybar)
// - Tickets + Cleanup bleiben hier
// - Partner/Onboarding bleibt hier
// - PayPal Premium wird HIER exportiert, weil bei dir keine zweite codebase deployed wird
// - Party Rating (Host-Score in users/{hostUid}) ist HIER dazugekommen ✅
// =======================

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const { setGlobalOptions, logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");
const crypto = require("crypto");

// ✅ EINMAL init
if (!admin.apps.length) admin.initializeApp();

// ============================================================
// Global Defaults — gilt für JEDE Function, die nichts eigenes
// setzt. Das ist der Kosten-Backstop:
//   - region: alles in europe-west1 (DSGVO + niedrige Latenz für AT)
//   - maxInstances: kein Runaway-Auto-Scale → harte Obergrenze
//   - timeoutSeconds: kurze CFs sollen nicht 9 Min hängen
//   - memory: Standard 256MiB → ~0.50€/Mio Invocations
//   - concurrency: pro Container mehrere parallel — billiger
// ============================================================
setGlobalOptions({
  region: "europe-west1",
  maxInstances: 10,
  timeoutSeconds: 15,
  memory: "256MiB",
  concurrency: 80,
});

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

// ✅ Scheduler (v2)
const eventsCleanup = require("./eventCleanup");
const avatarCleanup = require("./avatarCleanup");
const festllisteSync = require("./festlliste/sync");

// SECURITY_HARDENING (Audit M2): `cleanupExpiredEvents` wurde vorher
// zweimal exportiert (hier UND weiter unten). Die zweite Stelle ist
// entfernt — Single source of truth.
exports.cleanupExpiredEvents = eventsCleanup.cleanupExpiredEvents;
exports.cleanupOrphanAvatars = avatarCleanup.cleanupOrphanAvatars;

// FEATURE_FESTLLISTE_IMPORT: täglicher automatischer Import der
// "Festl-Liste" (linkrex.eu/@festlliste, Oberösterreichs Festl-Übersicht)
// in die `festln`-Collection. Siehe functions/festlliste/sync.js für
// Details (Quelle, Rein/Raus-Logik, Konfiguration des PDF-Links).
exports.syncFestlliste = festllisteSync.syncFestlliste;

// FEATURE_DISABLED_TICKETING — Stripe/Ticket Callables sind archiviert.
// Quelle: archived/ticketing/functions/stripe/{tickets,onboarding,webhook,scan}.js
// see archived/ticketing/README.md

// 📧 E-Mail-Verifikation (Account/Profil) — generisch, nicht ticketing-spezifisch.
// Früher: functions/stripe/emailVerify.js. Heute: functions/email/verify.js.
// Export-Namen sind stabil geblieben.
const emailVerify = require("./email/verify");

// 🛡 Admin-Moderation (Ban / Unban / VerifyEmail / Delete).
// Hinter request.auth.token.admin === true gesichert.
const adminModeration = require("./admin/userModeration");

// 🍻 Admin-Bar-Approval (approve / reject pending bars).
// Operational Readiness Sprint 2026-05-17.
const adminBarApproval = require("./admin/barApproval");

// 🏆 Host Reputation & Creator System.
// Aggregiert Party-/RSVP-/Report-Daten in users/{username}/hostStats/current
// und schreibt täglich Top-10 nach trendingHosts/global.
const hostStats = require("./hostStats/recompute");

// 👥 Friends & Social Activity Layer.
// Trigger auf RSVPs → pflegt goingCount + goingRecent (avatars) auf
// jedem Party-Doc. Map/Discovery rendern Social-Proof aus 1 Doc-Read.
const partyActivity = require("./partyActivity/aggregate");

// 🔐 Auth-Migration (Pre-Launch Audit Hardening, Audit C1+C2).
// - loginCallable:      server-seitiger Login, gibt Custom Token zurück.
// - signupCallable:     server-seitige Account-Creation, schreibt
//                       passwordHash NUR nach users_secrets/bars_secrets.
// - migrateAuthSecrets: Admin-only Backfill von users/bars → *_secrets.
// - deleteLegacyPasswordHashes: Admin-only Cleanup nach Migration.
const authLogin = require("./auth/loginCallable");
const authSignup = require("./auth/signupCallable");
const authChangePw = require("./auth/changePasswordCallable");
const authMigrate = require("./auth/migrateSecretsCallable");
const authCleanup = require("./auth/deleteLegacyPasswordHashes");

// 🔑 Password Reset (Operational Readiness, 2026-05-17).
// requestPasswordReset (callable) + passwordResetPage (HTTPS form).
const passwordReset = require("./passwordReset/reset");

// =======================
// Admin-Moderation Callables
// =======================
exports.adminBanUser     = adminModeration.adminBanUser;
exports.adminUnbanUser   = adminModeration.adminUnbanUser;
exports.adminVerifyEmail = adminModeration.adminVerifyEmail;
exports.adminDeleteUser  = adminModeration.adminDeleteUser;

// =======================
// Admin — Bar Approval
// =======================
exports.adminApproveBar = adminBarApproval.adminApproveBar;
exports.adminRejectBar  = adminBarApproval.adminRejectBar;

// =======================
// Host Reputation & Creator System
// =======================
exports.recomputeHostStats     = hostStats.recomputeHostStats;
exports.recomputeAllHostStats  = hostStats.recomputeAllHostStats;

// =======================
// Friends & Social Activity Layer
// =======================
exports.onRsvpWrite = partyActivity.onRsvpWrite;

// =======================
// Auth (siehe functions/auth/*.js für Deployment-Checkliste).
// =======================
exports.loginCallable = authLogin.loginCallable;
exports.signupCallable = authSignup.signupCallable;
exports.changePasswordCallable = authChangePw.changePasswordCallable;
exports.migrateAuthSecrets = authMigrate.migrateAuthSecrets;
exports.deleteLegacyPasswordHashes = authCleanup.deleteLegacyPasswordHashes;

// =======================
// Password Reset
// =======================
exports.requestPasswordReset = passwordReset.requestPasswordReset;
exports.passwordResetPage = passwordReset.passwordResetPage;

// =======================
// E-Mail Verifikation für QR-Code-Versand
// =======================
exports.requestEmailVerification = emailVerify.requestEmailVerification;
exports.verifyEmailToken = emailVerify.verifyEmailToken;

// =======================
// ✅ PARTY RATING (Callable v2)  - schreibt Host-Score in users/{hostUid}
// =======================

function parsePartyStart(party) {
    // 1) startTime bevorzugt (Timestamp oder ISO String)
    const st = party.startTime;
    if (st && typeof st.toDate === "function") return st.toDate();
    if (typeof st === "string") {
        const d = new Date(st);
        if (!isNaN(d.getTime())) return d;
    }

    // 2) fallback: date (Timestamp/ISO) + time ("HH:mm")
    let base = null;
    const date = party.date;
    if (date && typeof date.toDate === "function") base = date.toDate();
    if (typeof date === "string") {
        const d = new Date(date);
        if (!isNaN(d.getTime())) base = d;
    }
    if (!base) return null;

    const timeStr = (party.time || "").toString().trim();
    let hh = 0;
    let mm = 0;
    if (timeStr.includes(":")) {
        const p = timeStr.split(":");
        hh = parseInt(p[0] || "0", 10) || 0;
        mm = parseInt(p[1] || "0", 10) || 0;
    }
    return new Date(base.getFullYear(), base.getMonth(), base.getDate(), hh, mm, 0, 0);
}

exports.setPartyRating = onCall(
    {
        region: "europe-west1",
        maxInstances: 10,
        timeoutSeconds: 15,
        memory: "256MiB",
        concurrency: 80,
        // App Check verpflichtend: nur Calls aus der echten App.
        // TODO(appcheck): nach Console-Setup auf `true` setzen
        enforceAppCheck: false,
    },
    async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Not logged in.");

    const partyId = String(request.data?.partyId || "").trim();
    const value = String(request.data?.value || "").trim(); // good|bad

    if (!partyId) throw new HttpsError("invalid-argument", "partyId missing.");
    if (value !== "good" && value !== "bad") {
        throw new HttpsError("invalid-argument", "value must be 'good' or 'bad'.");
    }

    const partyRef = db.collection("Party").doc(partyId);
    const ratingRef = partyRef.collection("ratings").doc(uid);

    return await db.runTransaction(async (tx) => {
        // READS
        const partySnap = await tx.get(partyRef);
        if (!partySnap.exists) throw new HttpsError("not-found", "Party not found.");

        const party = partySnap.data() || {};
        const hostUid = String(party.hostUid || party.hostId || "").trim();
        if (!hostUid) throw new HttpsError("failed-precondition", "Party has no hostUid.");
        if (hostUid === uid) throw new HttpsError("permission-denied", "Host cannot rate own party.");

        // Zeitfenster: 24h ab Start
        const start = parsePartyStart(party);
        if (!start) throw new HttpsError("failed-precondition", "Party startTime missing/invalid.");

        const now = new Date();
        const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
        if (now < start || now > end) {
            throw new HttpsError("failed-precondition", "Rating not allowed (outside 24h window).");
        }

        // Berechtigung: Closed -> approved, sonst -> rsvps going/maybe
        const typeStr = String(party.type || (party.isClosed ? "Closed" : "Open"));
        const isClosed = !!party.isClosed || typeStr === "Closed";
        const isFriendsOnly = typeStr === "Only4Friends";

        if (isClosed && !isFriendsOnly) {
            const reqSnap = await tx.get(partyRef.collection("requests").doc(uid));
            const st = reqSnap.exists ? String(reqSnap.data()?.status || "") : "";
            if (st !== "approved") {
                throw new HttpsError("permission-denied", "Not approved - cannot rate.");
            }
        } else {
            const rsvpSnap = await tx.get(partyRef.collection("rsvps").doc(uid));
            const st = rsvpSnap.exists ? String(rsvpSnap.data()?.status || "") : "";
            if (st !== "going" && st !== "maybe") {
                throw new HttpsError("permission-denied", "Only going/maybe can rate.");
            }
        }

        // Vorherige Bewertung
        const prevSnap = await tx.get(ratingRef);
        const prevVal = prevSnap.exists ? (prevSnap.data()?.value || null) : null;

        let deltaGood = 0;
        let deltaBad = 0;
        if (value === "good") deltaGood++;
        if (value === "bad") deltaBad++;
        if (prevVal === "good") deltaGood--;
        if (prevVal === "bad") deltaBad--;

        const changed = deltaGood !== 0 || deltaBad !== 0;

        // Host User Doc lesen
        const hostUserRef = db.collection("users").doc(hostUid);
        const hostSnap = await tx.get(hostUserRef);

        const curGood = hostSnap.exists ? (hostSnap.data()?.partyScoreGood || 0) : 0;
        const curBad = hostSnap.exists ? (hostSnap.data()?.partyScoreBad || 0) : 0;

        const newGood = curGood + deltaGood;
        const newBad = curBad + deltaBad;
        const total = newGood + newBad;
        const pct = total > 0 ? Math.round((newGood / total) * 100) : 0;

        // WRITES
        tx.set(
            ratingRef,
            {
                uid,
                value,
                ts: FieldValue.serverTimestamp()
            },
            { merge: true }
        );

        // optional: Party counter (falls du’s im Party Doc willst)
        if (changed) {
            tx.set(
                partyRef,
                {
                    ratingsGood: FieldValue.increment(deltaGood),
                    ratingsBad: FieldValue.increment(deltaBad)
                },
                { merge: true }
            );
        }

        // ✅ Host Score in users/{hostUid}
        if (changed) {
            tx.set(
                hostUserRef,
                {
                    partyScoreGood: newGood,
                    partyScoreBad: newBad,
                    partyScorePct: pct,
                    partyScoreUpdatedAt: FieldValue.serverTimestamp()
                },
                { merge: true }
            );

            // optional: per-party rating history beim Host
            const perUserRef = hostUserRef
                .collection("partyRatings")
                .doc(partyId)
                .collection("byUser")
                .doc(uid);

            tx.set(
                perUserRef,
                {
                    partyId,
                    fromUid: uid,
                    value,
                    ts: FieldValue.serverTimestamp()
                },
                { merge: true }
            );
        }

        return { ok: true, pct, good: newGood, bad: newBad };
    });
});

// =======================
// Nearby Party Notifications (Scheduled — Thu + Fri 17:00 CET)
// =======================

function _haversineKm(lat1, lng1, lat2, lng2) {
    const R = 6371;
    const dLat = (lat2 - lat1) * Math.PI / 180;
    const dLng = (lng2 - lng1) * Math.PI / 180;
    const a =
        Math.sin(dLat / 2) ** 2 +
        Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
        Math.sin(dLng / 2) ** 2;
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

exports.sendNearbyPartyNotifications = onSchedule(
    {
        region: "europe-west1",
        schedule: "0 17 * * 4,5", // Thu + Fri at 17:00
        timeZone: "Europe/Vienna",
        // Schedule-Functions sollen sich nicht selbst überschneiden.
        maxInstances: 1,
        // Bis zu 9 Min für den weekend-sweep (Party + Bars + Users).
        timeoutSeconds: 540,
        // Mehr Speicher: in-memory join über mehrere Collections.
        memory: "512MiB",
        // Trigger ist nicht user-facing → App Check N/A.
    },
    async () => {
        const now = new Date();
        const nowMs = now.getTime();
        const windowEndMs = nowMs + 3 * 24 * 60 * 60 * 1000;

        // --- Load upcoming parties (next 3 days) ---
        const partySnap = await db.collection("Party").get();
        const upcoming = [];
        for (const doc of partySnap.docs) {
            const p = doc.data() || {};
            const start = parsePartyStart(p);
            if (!start) continue;
            const startMs = start.getTime();
            if (startMs < nowMs || startMs > windowEndMs) continue;
            const lat = parseFloat(p.lat ?? p.latitude ?? "");
            const lng = parseFloat(p.lng ?? p.longitude ?? "");
            if (!isFinite(lat) || !isFinite(lng)) continue;
            upcoming.push({ id: doc.id, name: (p.name || "Party").trim(), lat, lng, start });
        }
        console.log("[weekend] Upcoming parties:", upcoming.length);

        // --- Load approved bars ---
        const barSnap = await db.collection("bars").where("status", "==", "approved").get();
        const approvedBars = [];
        for (const doc of barSnap.docs) {
            const b = doc.data() || {};
            const lat = parseFloat(b.lat ?? b.latitude ?? "");
            const lng = parseFloat(b.lng ?? b.longitude ?? "");
            if (!isFinite(lat) || !isFinite(lng)) continue;
            const name = (b.barName || b.name || "Bar").trim();
            approvedBars.push({ id: doc.id, name, lat, lng });
        }
        console.log("[weekend] Approved bars:", approvedBars.length);

        if (upcoming.length === 0 && approvedBars.length === 0) {
            console.log("[weekend] Nothing to notify — done.");
            return null;
        }

        // --- Merge user queries (notifNearbyParties OR notifNearbyBars) ---
        const [partyUsersSnap, barUsersSnap] = await Promise.all([
            db.collection("users").where("notifNearbyParties", "==", true).get(),
            db.collection("users").where("notifNearbyBars", "==", true).get(),
        ]);
        const userMap = new Map();
        for (const doc of [...partyUsersSnap.docs, ...barUsersSnap.docs]) {
            userMap.set(doc.id, doc);
        }
        console.log("[weekend] Users to process:", userMap.size);

        // --- Process each user ---
        for (const userDoc of userMap.values()) {
            const u = userDoc.data() || {};
            const fcmToken = u.fcmToken;
            if (!fcmToken) continue;

            const userLat = parseFloat(u.selectedLat ?? "");
            const userLng = parseFloat(u.selectedLng ?? "");
            if (!isFinite(userLat) || !isFinite(userLng)) continue;

            let title, body, channelId;
            let notified = false;

            // 1. Party notification (takes priority)
            if (u.notifNearbyParties === true && upcoming.length > 0) {
                const nearby = upcoming.filter(p => _haversineKm(userLat, userLng, p.lat, p.lng) <= 50);
                if (nearby.length > 0) {
                    const count = nearby.length;
                    const soonest = nearby.reduce((a, b) => a.start < b.start ? a : b);
                    const daysUntil = Math.floor((soonest.start.getTime() - nowMs) / (24 * 60 * 60 * 1000));
                    const nameList = nearby.slice(0, 2).map(p => p.name).join(", ");

                    if (daysUntil === 0) {
                        title = count === 1 ? "Party heute in deiner Nähe! 🎉" : `${count} Partys heute in deiner Nähe! 🎉`;
                        body = count === 1 ? `${soonest.name} findet heute statt.` : `${nameList}${count > 2 ? " und mehr" : ""} finden heute statt.`;
                    } else if (daysUntil === 1) {
                        title = count === 1 ? "Party morgen in deiner Nähe! 🎉" : `${count} Partys morgen in deiner Nähe! 🎉`;
                        body = count === 1 ? `${soonest.name} findet morgen statt.` : `${nameList}${count > 2 ? " und mehr" : ""} finden morgen statt.`;
                    } else {
                        title = count === 1 ? `Party in ${daysUntil} Tagen in deiner Nähe! 🎉` : `${count} Partys in deiner Nähe! 🎉`;
                        body = count === 1 ? `${soonest.name} findet in ${daysUntil} Tagen statt.` : `${nameList}${count > 2 ? " und mehr" : ""}.`;
                    }
                    channelId = "nearby_parties";
                    notified = true;
                }
            }

            // 2. Bar suggestion fallback (only if no party notification was sent)
            if (!notified && u.notifNearbyBars === true && approvedBars.length > 0) {
                const nearbyBars = approvedBars.filter(b => _haversineKm(userLat, userLng, b.lat, b.lng) <= 50);
                if (nearbyBars.length > 0) {
                    const bar = nearbyBars[Math.floor(Math.random() * nearbyBars.length)];
                    const count = nearbyBars.length;
                    const nameList = nearbyBars.slice(0, 2).map(b => b.name).join(", ");

                    title = count === 1
                        ? `Heute Abend in ${bar.name}? 🍺`
                        : `${count} Bars heute Abend in deiner Nähe 🍺`;
                    body = count === 1
                        ? `Keine Partys – aber ${bar.name} ist in deiner Nähe.`
                        : `${nameList}${count > 2 ? " und mehr" : ""} – perfekt für heute Abend.`;
                    channelId = "nearby_bars";
                    notified = true;
                }
            }

            if (!notified) continue;

            try {
                await admin.messaging().send({
                    token: fcmToken,
                    notification: { title, body },
                    android: {
                        priority: "high",
                        notification: { channelId, sound: "default" },
                    },
                    apns: {
                        headers: { "apns-priority": "10" },
                        payload: { aps: { sound: "default", badge: 1, "content-available": 1 } },
                    },
                });
                console.log("[weekend] Sent to", userDoc.id, "—", title);
            } catch (e) {
                console.log("[weekend] Failed for", userDoc.id, ":", e?.message || e);
            }
        }

        return null;
    }
);

// =======================
// sendFriendRequest (Callable v2) — idempotent, race-condition-safe
// =======================
exports.sendFriendRequest = onCall(
    {
        region: "europe-west1",
        maxInstances: 10,
        timeoutSeconds: 15,
        memory: "256MiB",
        concurrency: 80,
        // TODO(appcheck): nach Console-Setup auf `true` setzen
        enforceAppCheck: false,
    },
    async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Not logged in.");

    const uid = request.auth.uid;
    const to = (request.data?.to || "").trim();
    if (!to) throw new HttpsError("invalid-argument", "Missing 'to' username.");

    // Caller-Username aus users/{uid} holen
    const mySnap = await db.collection("users").doc(uid).get();
    let from = mySnap.exists ? (mySnap.data()?.username || "").trim() : "";

    // Fallback: query by uid field
    if (!from) {
        const q = await db.collection("users").where("uid", "==", uid).limit(1).get();
        if (!q.empty) from = (q.docs[0].data()?.username || "").trim();
    }
    if (!from) throw new HttpsError("not-found", "Caller has no username.");
    if (from === to) throw new HttpsError("invalid-argument", "Cannot add yourself.");

    // Ziel-User prüfen
    const toQuery = await db.collection("users").where("username", "==", to).limit(1).get();
    if (toQuery.empty) throw new HttpsError("not-found", `User "${to}" not found.`);
    const toDocId = toQuery.docs[0].id;

    const shipId = [from, to].sort().join("__");
    const reqId  = `${from}__${to}`;
    const reqRef  = db.collection("friendRequests").doc(reqId);
    const shipRef = db.collection("friendships").doc(shipId);

    return await db.runTransaction(async (tx) => {
        const [reqSnap, shipSnap] = await Promise.all([tx.get(reqRef), tx.get(shipRef)]);

        // Bereits befreundet
        if (shipSnap.exists) return { status: "already_friends" };

        // Anfrage existiert schon (pending oder anderer Status)
        if (reqSnap.exists) {
            const s = reqSnap.data()?.status;
            if (s === "pending") return { status: "already_sent" };
            // declined / accepted → neu anlegen erlaubt (überschreiben)
        }

        tx.set(reqRef, {
            from,
            fromDocId: uid,
            to,
            toDocId,
            status: "pending",
            ts: FieldValue.serverTimestamp(),
        });

        return { status: "sent" };
    });
});

// =======================
// Friend Request Push Notification
// =======================
const { onDocumentCreated } = require("firebase-functions/v2/firestore");

exports.onFriendRequest = onDocumentCreated(
  {
    document: "friendRequests/{requestId}",
    region: "europe-west1",
    // Trigger ist server-intern, App Check N/A.
    maxInstances: 10,
    timeoutSeconds: 30, // FCM send + 2 collection lookups
    memory: "256MiB",
    concurrency: 20,
  },
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const fromUsername = (data.from || "").trim();
    const toUsername = (data.to || data.toUsername || "").trim();
    if (!toUsername || !fromUsername) return;

    const lower = toUsername.toLowerCase();
    let fcmToken = null;

    // Search users and bars collections by username / username_lower
    for (const col of ["users", "bars"]) {
      if (fcmToken) break;
      for (const [field, val] of [["username", toUsername], ["username_lower", lower]]) {
        if (fcmToken) break;
        try {
          const q = await db.collection(col).where(field, "==", val).limit(1).get();
          if (!q.empty) fcmToken = q.docs[0].data()?.fcmToken || null;
        } catch (_) {}
      }
    }
    if (!fcmToken) return;

    try {
      await admin.messaging().send({
        token: fcmToken,
        notification: {
          title: "Neue Freundschaftsanfrage",
          body: `${fromUsername} möchte dich adden`,
        },
        android: {
          priority: "high",
          notification: { channelId: "party_requests", sound: "default" },
        },
        apns: {
          headers: { "apns-priority": "10" },
          payload: {
            aps: { sound: "default", badge: 1, "content-available": 1 },
          },
        },
      });
    } catch (e) {
      console.log("[onFriendRequest] FCM send failed:", e?.message || e);
    }
  }
);

// =======================
// Party Anfrage Status Notification (Callable v2)
// =======================
//
// SECURITY_HARDENING (Pre-Launch Audit): Vor dieser Hardening konnte
// jeder anonym-authed Client beliebigen Usern Pushes mit beliebigem
// Title/Body schicken (siehe Audit C3). Push-Spam-Vektor.
//
// Jetzt:
//   1. Rate-Limit hart: max 30 Pushes pro Stunde pro Caller-UID,
//      gespeichert in `pushQuota/{uid}` mit serverTimestamp + count.
//   2. Beziehungs-Check (fail-closed): Push nur wenn
//      a) Friendship Caller<->Target existiert, ODER
//      b) Common Party: Caller ist Host und Target hat RSVP/Request/
//         Approved, ODER umgekehrt.
//   3. Reject wird mit warn-log + payload-size geloggt.
//
// Push ist UI-optional — wenn der Check fehlschlägt, ist das kein
// Beinbruch, der zugrundeliegende RSVP/Chat-Write läuft trotzdem
// durch (er passiert client-seitig vor diesem Call).

const PUSH_QUOTA_LIMIT_PER_HOUR = 30;

async function _resolveUsernameForUid(uid) {
  // Strategie: erst Doc per uid lookup, dann fallback per `uid` field.
  try {
    const direct = await db.collection("users").doc(uid).get();
    if (direct.exists) {
      const u = (direct.data()?.username || "").toString().trim();
      if (u) return u;
    }
  } catch (_) {}
  try {
    const q = await db.collection("users").where("uid", "==", uid).limit(1).get();
    if (!q.empty) {
      const u = (q.docs[0].data()?.username || "").toString().trim();
      if (u) return u;
    }
  } catch (_) {}
  return null;
}

async function _checkAndIncrementPushQuota(uid) {
  const ref = db.collection("pushQuota").doc(uid);
  const nowMs = Date.now();
  const oneHourMs = 60 * 60 * 1000;
  return await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    let count = 0;
    let windowStart = nowMs;
    if (snap.exists) {
      const d = snap.data() || {};
      const ws = (d.windowStartMs || 0);
      if (nowMs - ws < oneHourMs) {
        count = d.count || 0;
        windowStart = ws;
      } // else: Fenster abgelaufen, Reset auf 0
    }
    if (count >= PUSH_QUOTA_LIMIT_PER_HOUR) {
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

async function _areFriends(usernameA, usernameB) {
  if (!usernameA || !usernameB) return false;
  const shipId = [usernameA, usernameB].sort().join("__");
  try {
    const snap = await db.collection("friendships").doc(shipId).get();
    return snap.exists;
  } catch (_) {
    return false;
  }
}

async function _haveCommonParty(callerUsername, targetUsername) {
  if (!callerUsername || !targetUsername) return false;
  // Caller ist Host einer Party — Target hat dort RSVP/Request/Approved?
  // ODER Target ist Host — Caller hat dort RSVP/Request/Approved?
  // Wir limitieren auf jeweils 10 Parties, sonst kann ein Spam-Host mit
  // tausenden Parties die CF lange laufen lassen.
  for (const [hostName, guestName] of [
    [callerUsername, targetUsername],
    [targetUsername, callerUsername],
  ]) {
    try {
      const hostedSnap = await db
        .collection("Party")
        .where("hostId", "==", hostName)
        .limit(10)
        .get();
      for (const pdoc of hostedSnap.docs) {
        for (const sub of ["rsvps", "requests", "approved", "coming", "maybe"]) {
          try {
            const r = await pdoc.ref.collection(sub).doc(guestName).get();
            if (r.exists) return true;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
  return false;
}

exports.sendPushNotification = onCall(
  {
    region: "europe-west1",
    maxInstances: 10,
    timeoutSeconds: 30, // mehr als vorher: Relation-Check + FCM
    memory: "256MiB",
    concurrency: 40,
    // TODO(appcheck): nach Console-Setup auf `true` setzen
    enforceAppCheck: false,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Not logged in.");
    }
    const callerUid = request.auth.uid;

    const { toUsername, title, body, data: extraData } = request.data || {};
    if (!toUsername || !title || !body) {
      return { ok: false, reason: "missing fields" };
    }
    if (String(title).length > 120 || String(body).length > 400) {
      throw new HttpsError("invalid-argument", "title/body too long.");
    }
    const targetUsername = String(toUsername).trim();
    if (!targetUsername) {
      return { ok: false, reason: "empty target" };
    }

    // --- 1. Rate-Limit ---
    const quota = await _checkAndIncrementPushQuota(callerUid);
    if (!quota.allowed) {
      logger.warn("[push] rate limited", {
        callerUid,
        target: targetUsername,
        countInWindow: quota.count,
      });
      throw new HttpsError(
        "resource-exhausted",
        "Push rate-limit reached. Try later."
      );
    }

    // --- 2. Beziehungs-Check ---
    const callerUsername = await _resolveUsernameForUid(callerUid);
    // Wenn wir den Caller-Username nicht auflösen können, ist das mit
    // dem aktuellen anonymous-Auth-Modell ein gültiger Zustand (User
    // direkt nach Signup ohne username-Set). Wir verweigern den Push
    // trotzdem, weil wir die Beziehung nicht prüfen können — das
    // führt nur dazu, dass ein noch nicht ge-onboardeter User keine
    // Pushes schicken kann, was OK ist.
    if (!callerUsername) {
      logger.warn("[push] caller username unresolved", { callerUid });
      return { ok: false, reason: "caller username unresolved" };
    }
    if (callerUsername === targetUsername) {
      return { ok: false, reason: "self push" };
    }

    const isFriend = await _areFriends(callerUsername, targetUsername);
    let hasRelation = isFriend;
    if (!hasRelation) {
      hasRelation = await _haveCommonParty(callerUsername, targetUsername);
    }
    if (!hasRelation) {
      logger.warn("[push] no relation — rejected", {
        callerUsername,
        target: targetUsername,
      });
      return { ok: false, reason: "no relation" };
    }

    // --- 3. FCM-Token auflösen ---
    const lower = targetUsername.toLowerCase();
    let fcmToken = null;
    for (const col of ["users", "bars"]) {
      if (fcmToken) break;
      for (const [field, val] of [
        ["username", targetUsername],
        ["username_lower", lower],
      ]) {
        if (fcmToken) break;
        try {
          const q = await db.collection(col).where(field, "==", val).limit(1).get();
          if (!q.empty) fcmToken = q.docs[0].data()?.fcmToken || null;
        } catch (_) {}
      }
    }

    if (!fcmToken) return { ok: false, reason: "no fcm token" };

    await admin.messaging().send({
      token: fcmToken,
      notification: { title, body },
      data: extraData || {},
      android: {
        priority: "high",
        notification: { channelId: "party_requests", sound: "default" },
      },
      apns: {
        headers: { "apns-priority": "10" },
        payload: {
          aps: {
            sound: "default",
            badge: 1,
            "content-available": 1,
          },
        },
      },
    });

    return { ok: true };
  }
);
