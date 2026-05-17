// functions/partyActivity/aggregate.js
//
// Friends & Social Activity Layer — Aggregator.
//
// Hält pro Party einen kompakten Social-Proof-Snapshot, damit die Map
// und Discovery jeden Marker / jede Card mit "X going · 3 Köpfe"
// rendern können — ohne pro Marker eine eigene RSVP-Query.
//
// Trigger: onDocumentWritten(`Party/{partyId}/rsvps/{rsvpDocId}`)
//
// Schreibt nach Party/{partyId}:
//   - goingCount        : int (Anzahl rsvps mit status=going, self-join entfernt)
//   - goingRecent       : [{username, avatarUrl?, joinedAt: Timestamp}]  (max 20, neueste zuerst)
//   - goingDelta60m     : int (neue going-RSVPs in den letzten 60min, für Momentum-Detection)
//   - goingUpdatedAt    : Timestamp
//
// Self-join-Filter: Host (hostUid) wird nicht mitgezählt — konsistent
// mit functions/hostStats/recompute.js. Vermeidet, dass ein Host sich
// selbst zu Social-Proof macht.
//
// Aggregat-Strategie: voll-recomputed pro Trigger. Für Linz-Größe
// (≤20 RSVPs/Party) ist das akzeptabel — wir lesen alle rsvps + max 20
// User-Docs. Bei viel größeren Parties später inkrementell umbauen.
//
// Momentum-Hinweis: `goingDelta60m` wird nur beim Trigger neu berechnet.
// Wenn 2h keine neuen RSVPs reinkommen, bleibt der Wert eingefroren —
// Client behandelt das via TTL (`goingUpdatedAt` älter als 90min →
// Momentum=none). Kein Scheduler nötig.

const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "europe-west1";
const RECENT_LIMIT = 20;

// User-Cache pro Function-Invocation (kalter Start = leer, warm wird
// recycled). Spart bei Bursts dieselbe users-Lookup.
const userInfoCache = new Map();

async function loadUserInfo(uid) {
  if (!uid) return null;
  if (userInfoCache.has(uid)) return userInfoCache.get(uid);

  // Strategie: erst nach docId (= uid) versuchen, dann fallback per
  // where('uid', ==). Manche User-Docs haben docId !== uid (Legacy).
  let username = null;
  let avatarUrl = null;

  try {
    const direct = await db.collection("users").doc(uid).get();
    if (direct.exists) {
      const d = direct.data() || {};
      username = (d.username || "").toString().trim() || null;
      avatarUrl = (d.avatarUrl || "").toString().trim() || null;
    }
  } catch (_) {}

  if (!username) {
    try {
      const q = await db.collection("users").where("uid", "==", uid).limit(1).get();
      if (!q.empty) {
        const d = q.docs[0].data() || {};
        username = (d.username || "").toString().trim() || null;
        avatarUrl = (d.avatarUrl || "").toString().trim() || null;
      }
    } catch (_) {}
  }

  const info = username ? { username, avatarUrl } : null;
  userInfoCache.set(uid, info);
  return info;
}

async function aggregateForParty(partyId) {
  const partyRef = db.collection("Party").doc(partyId);
  const partySnap = await partyRef.get();
  if (!partySnap.exists) {
    logger.info("[partyActivity] party gone", { partyId });
    return;
  }
  const partyData = partySnap.data() || {};
  const hostUid = String(partyData.hostUid || "").trim();

  const rsvpsSnap = await partyRef
    .collection("rsvps")
    .where("status", "==", "going")
    .get();

  const nowMs = Date.now();
  const sixtyMinAgoMs = nowMs - 60 * 60 * 1000;

  // Reihenfolge: neueste zuerst, soweit feststellbar. RSVPs haben
  // teilweise `updatedAt`/`ts`, fallback auf createTime der Docs.
  const docs = rsvpsSnap.docs
    .filter((d) => {
      const uid = d.id;
      // Self-join Filter: Host wird nicht als "going" mitgezählt.
      return !hostUid || uid !== hostUid;
    })
    .map((d) => {
      const data = d.data() || {};
      const ts =
        (data.updatedAt && typeof data.updatedAt.toMillis === "function"
          ? data.updatedAt.toMillis()
          : null) ??
        (data.ts && typeof data.ts.toMillis === "function"
          ? data.ts.toMillis()
          : null) ??
        (d.createTime?.toMillis ? d.createTime.toMillis() : 0);
      return { uid: d.id, ts };
    })
    .sort((a, b) => b.ts - a.ts);

  const goingCount = docs.length;

  // Momentum-Aggregat: wie viele neue going-RSVPs in den letzten 60min.
  // Wenn ts == 0 (legacy: kein Timestamp ermittelbar), wird nicht
  // mitgezählt — kein false positive.
  const goingDelta60m = docs.filter((x) => x.ts > 0 && x.ts >= sixtyMinAgoMs).length;

  // Recent-Auflösung: max RECENT_LIMIT User. Wir wollen nicht alle
  // User-Docs bei 100+ RSVPs lesen.
  const slice = docs.slice(0, RECENT_LIMIT);
  const recent = [];
  for (const { uid, ts } of slice) {
    const info = await loadUserInfo(uid);
    if (!info) continue;
    recent.push({
      username: info.username,
      avatarUrl: info.avatarUrl || null,
      // joinedAt für Client-side Momentum-Recomputation (TTL-Check).
      // null wenn ts unbekannt — Client behandelt das tolerant.
      joinedAt: ts > 0 ? admin.firestore.Timestamp.fromMillis(ts) : null,
    });
  }

  await partyRef.set(
    {
      goingCount,
      goingRecent: recent,
      goingDelta60m,
      goingUpdatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  logger.info("[partyActivity] aggregated", {
    partyId,
    goingCount,
    delta60m: goingDelta60m,
    recent: recent.length,
  });
}

exports.onRsvpWrite = onDocumentWritten(
  {
    region: REGION,
    document: "Party/{partyId}/rsvps/{rsvpId}",
    maxInstances: 5,
    timeoutSeconds: 30,
    memory: "256MiB",
    concurrency: 10,
  },
  async (event) => {
    const partyId = event.params?.partyId;
    if (!partyId) return null;
    try {
      await aggregateForParty(partyId);
    } catch (e) {
      logger.error("[partyActivity] aggregate failed", {
        partyId,
        msg: e?.message,
      });
    }
    return null;
  }
);
