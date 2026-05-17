// functions/hostStats/recompute.js
//
// Host Reputation & Creator System — Aggregator (v2).
//
// Schreibt nach `users/{username}/hostStats/current`. Username-keyed,
// konsistent mit `Party.hostId` (= username aus prefs) und
// `user_profile_screen`'s `username_lower`-Lookup.
//
// Exports:
//   - recomputeHostStats (onCall)         — refresh on demand
//   - recomputeAllHostStats (scheduled)   — daily sweep + trending update
//
// V2-Änderungen:
//   - "Successful Event" jetzt ab 2 Gästen statt 3 (großzügiger für lokale
//     Jugend-App). Zusätzlich eventScore: graduierte Gewichtung pro Event.
//   - Repeat-Attendees: uniqueAttendees / repeatAttendees / repeatRate.
//     Returning guests sind stark positiv gewichtet (40 pro repeat).
//   - Trending: Growth-Delta zwischen aktueller Woche und Vorwoche +
//     Newcomer-Boost für Hosts mit <5 Parties.
//   - Self-Join Filter: Hosts, die sich selbst als Gast eintragen, werden
//     beim attendeeCount nicht mitgezählt (sybil-mitigation Stufe 1).
//   - auditFlags[]: Placeholder für spätere Sybil/Friend-Farm Detection.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "europe-west1";

// ── Level-Tabelle ──────────────────────────────────────────
// Kalibrierung für Linz (Early-Stage). "successfulEvents" zählt Parties
// mit ≥2 Gästen (siehe aggregateForUsername).
// MUSS in Sync bleiben mit lib/Social/host_level.dart → kHostLevelThresholds.
const LEVELS = [
  { id: "rookie",    minEvents: 0,  minScore: 0,    minRate: 0.0 },
  { id: "local",     minEvents: 1,  minScore: 30,   minRate: 0.0 },
  { id: "rising",    minEvents: 5,  minScore: 150,  minRate: 0.5 },
  { id: "nightlife", minEvents: 12, minScore: 500,  minRate: 0.6 },
  { id: "elite",     minEvents: 30, minScore: 1500, minRate: 0.7 },
];

const LEVEL_INDEX = Object.fromEntries(LEVELS.map((l, i) => [l.id, i]));

function pickLevel({ successfulEvents, reputationScore, ratingPositiveRate }) {
  let chosen = LEVELS[0].id;
  for (const l of LEVELS) {
    if (
      successfulEvents >= l.minEvents &&
      reputationScore >= l.minScore &&
      ratingPositiveRate >= l.minRate
    ) {
      chosen = l.id;
    }
  }
  return chosen;
}

// Graduierter Event-Score: kleines Treffen mit 2 echten Gästen zählt
// teilweise statt gar nicht. Senkt die Hürde für frühe Hosts.
function eventWeightFor(attendees) {
  if (attendees <= 0) return 0;
  if (attendees === 1) return 0.4;
  if (attendees === 2) return 0.8;
  if (attendees <= 4) return 1.0;
  if (attendees <= 7) return 1.2;
  return 1.5;
}

// Same parseStart als in index.js — Konsistenz mit setPartyRating.
function parsePartyStart(party) {
  const st = party.startTime;
  if (st && typeof st.toDate === "function") return st.toDate();
  if (typeof st === "string") {
    const d = new Date(st);
    if (!isNaN(d.getTime())) return d;
  }
  let base = null;
  const date = party.date;
  if (date && typeof date.toDate === "function") base = date.toDate();
  if (typeof date === "string") {
    const d = new Date(date);
    if (!isNaN(d.getTime())) base = d;
  }
  if (!base) return null;
  const timeStr = (party.time || "").toString().trim();
  let hh = 0, mm = 0;
  if (timeStr.includes(":")) {
    const p = timeStr.split(":");
    hh = parseInt(p[0] || "0", 10) || 0;
    mm = parseInt(p[1] || "0", 10) || 0;
  }
  return new Date(base.getFullYear(), base.getMonth(), base.getDate(), hh, mm, 0, 0);
}

/**
 * Aggregiert Host-Stats für einen Username (v2 — mit Repeat-Tracking,
 * Self-Join-Filter, Growth-Delta).
 */
async function aggregateForUsername(username) {
  const nowMs = Date.now();
  const sevenDaysAgo  = nowMs - 7  * 24 * 60 * 60 * 1000;
  const fourteenDaysAgo = nowMs - 14 * 24 * 60 * 60 * 1000;

  const partiesSnap = await db
    .collection("Party")
    .where("hostId", "==", username)
    .get();

  let successfulEvents = 0;
  let attendedEvents = 0;          // ≥1 Gast (für "anything happened")
  let attendeeCount = 0;           // Summe (mit Repeat — gleicher UID zählt pro Party)
  let ghostEventCount = 0;
  let ratingsGood = 0;
  let ratingsBad = 0;
  let eventScore = 0;
  let bestSinglePartyAttendees = 0;

  // 7-Tage- + 14-Tage-Fenster
  let recentEvents7d = 0;
  let recentAttendees7d = 0;
  let recentRatingsGood7d = 0;
  let prevAttendees7d = 0;          // 7-14 Tage zurück
  let prevEvents7d = 0;

  // Repeat-Tracking: für jeden Gast (uid) merken wir uns, in wie vielen
  // Parties er war. ≥2 → Stammgast.
  /** @type {Map<string, number>} */
  const uidOccurrences = new Map();

  for (const partyDoc of partiesSnap.docs) {
    const p = partyDoc.data() || {};
    const hostUid = String(p.hostUid || "").trim();
    ratingsGood += Number(p.ratingsGood || 0);
    ratingsBad  += Number(p.ratingsBad  || 0);

    const rsvpSnap = await partyDoc.ref
      .collection("rsvps")
      .where("status", "==", "going")
      .get();

    // Self-Join Filter: Host darf nicht für sich selbst zählen.
    let attendees = 0;
    for (const rsvpDoc of rsvpSnap.docs) {
      const uid = rsvpDoc.id;
      if (hostUid && uid === hostUid) continue;
      attendees++;
      uidOccurrences.set(uid, (uidOccurrences.get(uid) || 0) + 1);
    }

    attendeeCount += attendees;
    if (attendees > bestSinglePartyAttendees) bestSinglePartyAttendees = attendees;

    const start = parsePartyStart(p);
    const isPast = start && start.getTime() <= nowMs;

    if (isPast) {
      const w = eventWeightFor(attendees);
      eventScore += w;
      if (attendees >= 1) attendedEvents++;
      if (attendees >= 2) successfulEvents++;
      if (attendees === 0) ghostEventCount++;

      const startMs = start.getTime();
      if (startMs >= sevenDaysAgo) {
        recentEvents7d++;
        recentAttendees7d   += attendees;
        recentRatingsGood7d += Number(p.ratingsGood || 0);
      } else if (startMs >= fourteenDaysAgo) {
        prevEvents7d++;
        prevAttendees7d += attendees;
      }
    }
  }

  // Repeats berechnen
  let uniqueAttendees = uidOccurrences.size;
  let repeatAttendees = 0;
  for (const [, count] of uidOccurrences) {
    if (count >= 2) repeatAttendees++;
  }
  const repeatRate = uniqueAttendees > 0 ? repeatAttendees / uniqueAttendees : 0;

  // Reports gegen diesen Host
  const reportsSnap = await db
    .collection("reports")
    .where("reportedUsername", "==", username)
    .get();
  const reportCount = reportsSnap.size;

  // ── Reputation (v2.1) ──────────────────────────────────
  // Repeat-Attendees sind das Herzstück: gute Community-Hosts gewinnen,
  // nicht nur Hosts mit großen Zahlen.
  //
  // eventScore-Gewicht hochgezogen von 20 → 25, damit 1 kleine Mini-Party
  // (3 Gäste, weight 1.0) bereits den Local-Threshold (30) auslöst:
  //   25·1.0 + 2·3 = 31 → Local
  // Ziel: erster Erfolg = sichtbares Level-Up, keine Frust-Phase.
  const reputationScore = Math.round(
    25 * eventScore +
    2  * attendeeCount +
    40 * repeatAttendees +
    25 * ratingsGood -
    15 * ratingsBad -
    50 * reportCount -
    10 * ghostEventCount
  );

  const totalRatings = ratingsGood + ratingsBad;
  const ratingPositiveRate = totalRatings > 0 ? ratingsGood / totalRatings : 0;

  const hostLevel = pickLevel({
    successfulEvents,
    reputationScore,
    ratingPositiveRate,
  });

  // ── Trending (v2) ──────────────────────────────────────
  // Lebendig statt statisch:
  //   - aktuelle Woche stark gewichtet
  //   - Growth-Delta gegenüber Vorwoche
  //   - Newcomer-Boost für Hosts mit <5 lifetime Parties
  //   - Reports ziehen härter
  const growthDelta = Math.max(0, recentAttendees7d - prevAttendees7d);
  const partyCount = partiesSnap.size;
  const newcomerBoost = (partyCount > 0 && partyCount < 5) ? 30 : 0;

  const trendingScore = Math.round(
    4 * recentAttendees7d +
    5 * recentEvents7d +
    6 * recentRatingsGood7d +
    8 * growthDelta +
    newcomerBoost -
    30 * reportCount
  );

  // ── Audit-Flags (Placeholder) ──────────────────────────
  // Stufe 1: Self-Join wird oben schon herausgefiltert.
  // Stufe 2+ (späterer Build): friend-farming, device fingerprint,
  // unrealistic-RSVP-rate. Wir schreiben einen Array, das die spätere
  // Audit-CF füllen kann, ohne dass UI/Service-Layer angepasst werden müssen.
  const auditFlags = [];

  return {
    hostLevel,
    reputationScore,
    successfulEvents,
    attendedEvents,
    eventScore: Number(eventScore.toFixed(2)),
    attendeeCount,
    uniqueAttendees,
    repeatAttendees,
    repeatRate: Number(repeatRate.toFixed(3)),
    bestSinglePartyAttendees,
    ghostEventCount,
    ratingsGood,
    ratingsBad,
    ratingPositiveRate: Number(ratingPositiveRate.toFixed(3)),
    reportCount,
    trendingScore,
    growthDelta,
    newcomerBoost,
    partyCount,
    recentEvents7d,
    recentAttendees7d,
    prevEvents7d,
    prevAttendees7d,
    recentRatingsGood7d,
    auditFlags,
  };
}

async function writeStats(username, stats) {
  const ref = db.collection("users").doc(username).collection("hostStats").doc("current");
  const prevSnap = await ref.get();
  const prev = prevSnap.exists ? prevSnap.data() : null;

  const previousLevel = prev ? String(prev.hostLevel || "rookie") : "rookie";
  const newLevel = stats.hostLevel;

  const levelUp =
    (LEVEL_INDEX[newLevel] ?? 0) > (LEVEL_INDEX[previousLevel] ?? 0);

  const payload = {
    ...stats,
    previousLevel,
    lastComputedAt: FieldValue.serverTimestamp(),
  };
  if (levelUp) {
    payload.lastLevelUpAt = FieldValue.serverTimestamp();
  }

  await ref.set(payload, { merge: true });
  return { levelUp, newLevel, previousLevel };
}

exports.recomputeHostStats = onCall(
  {
    region: REGION,
    maxInstances: 10,
    timeoutSeconds: 60,
    memory: "256MiB",
    concurrency: 20,
    // TODO(appcheck): nach Console-Setup auf `true` setzen
    enforceAppCheck: false,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Not logged in.");
    }

    const username = String(request.data?.username || "").trim();
    if (!username) {
      throw new HttpsError("invalid-argument", "username missing.");
    }

    const stats = await aggregateForUsername(username);
    const result = await writeStats(username, stats);

    logger.info("[hostStats] recomputed", {
      username,
      hostLevel: stats.hostLevel,
      score: stats.reputationScore,
      events: stats.successfulEvents,
      repeats: stats.repeatAttendees,
      levelUp: result.levelUp,
    });

    return { ok: true, ...stats, levelUp: result.levelUp };
  }
);

exports.recomputeAllHostStats = onSchedule(
  {
    region: REGION,
    schedule: "0 4 * * *",
    timeZone: "Europe/Vienna",
    maxInstances: 1,
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async () => {
    const partiesSnap = await db.collection("Party").get();
    const hostSet = new Set();
    for (const doc of partiesSnap.docs) {
      const hostId = String(doc.data()?.hostId || "").trim();
      if (hostId) hostSet.add(hostId);
    }

    const hosts = [...hostSet].slice(0, 500);
    logger.info("[hostStats] sweep start", { totalHosts: hosts.length });

    const allStats = [];
    let processed = 0;
    for (const username of hosts) {
      try {
        const stats = await aggregateForUsername(username);
        await writeStats(username, stats);
        allStats.push({ username, ...stats });
      } catch (e) {
        logger.error("[hostStats] sweep error", { username, msg: e?.message });
      }
      processed++;
      if (processed % 50 === 0) {
        logger.info("[hostStats] sweep progress", {
          processed,
          total: hosts.length,
        });
      }
    }

    // Trending: lebendig — sortiert nach v2-trendingScore, kein Filter
    // auf hostLevel mehr (Newcomer-Boost soll Rookies hochbringen können).
    // Nur Mindestaktivität: muss in letzten 7d ≥1 Event ODER ≥3 Attendees
    // ODER newcomerBoost haben — sonst irrelevant.
    const trending = allStats
      .filter((s) => s.trendingScore > 0)
      .filter((s) =>
        s.recentEvents7d > 0 ||
        s.recentAttendees7d >= 3 ||
        s.newcomerBoost > 0
      )
      .sort((a, b) => b.trendingScore - a.trendingScore)
      .slice(0, 10)
      .map((s) => ({
        username: s.username,
        hostLevel: s.hostLevel,
        trendingScore: s.trendingScore,
        recentEvents7d: s.recentEvents7d,
        recentAttendees7d: s.recentAttendees7d,
        growthDelta: s.growthDelta,
        newcomerBoost: s.newcomerBoost,
      }));

    await db.collection("trendingHosts").doc("global").set({
      entries: trending,
      computedAt: FieldValue.serverTimestamp(),
    });

    logger.info("[hostStats] sweep done", {
      hostsProcessed: allStats.length,
      trendingCount: trending.length,
    });

    return null;
  }
);
