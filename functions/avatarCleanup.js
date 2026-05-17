// functions/avatarCleanup.js
//
// Verwaiste Avatare im Storage entfernen.
//
// Hintergrund:
//   Der Avatar-Upload in der App schreibt unter `avatars/{docId}-{ts}.jpg`
//   und löscht beim Wechsel zwar die VORIGE Datei — wenn aber ein Upload
//   abbricht, der Client crasht, ein Account gelöscht wird, oder die App
//   einen alten Cache-Eintrag behält, bleiben Dateien als "Müll" im
//   Storage liegen. Das kostet auf Dauer Geld.
//
// Strategie:
//   Wöchentlich (Sonntag 03:00 Europe/Vienna) den `avatars/`-Prefix
//   durchgehen. Für jede Datei prüfen, ob die zugehörige `avatarUrl`
//   irgendwo in `users/` oder `bars/` als aktive URL referenziert wird.
//   Falls nicht UND die Datei älter als 7 Tage ist → löschen.
//
// Warum 7 Tage Schonfrist?
//   Schutz vor Race Conditions: Upload abgeschlossen aber Firestore-
//   Update noch nicht durch. Vorlauf von einer Woche ist großzügig genug.
//
// Skalierungsschutz:
//   - maxInstances: 1  (kein paralleler Müll-Sweep)
//   - timeoutSeconds: 540 (9 Min — listFiles + batches deletes)
//   - memory: 512MiB (für Set-basierte In-Memory-Diff bei vielen Usern)

/* eslint-disable */
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { logger } = require("firebase-functions/v2");

if (!admin.apps.length) admin.initializeApp();

const PREFIX = "avatars/";
const GRACE_PERIOD_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Extrahiert den Storage-Pfad aus einer Firebase-Storage-Download-URL
 * bzw. einem `gs://`-Pfad. Gibt `null` zurück, wenn das nichts mit dem
 * Bucket dieser App zu tun hat.
 */
function storagePathFromUrl(url) {
  if (!url || typeof url !== "string") return null;

  if (url.startsWith("gs://")) {
    const without = url.replace("gs://", "");
    const slash = without.indexOf("/");
    if (slash === -1) return null;
    return without.substring(slash + 1);
  }

  const marker = "/o/";
  const i = url.indexOf(marker);
  if (i === -1) return null;

  const rest = url.substring(i + marker.length);
  const q = rest.indexOf("?");
  const encoded = q === -1 ? rest : rest.substring(0, q);

  try {
    return decodeURIComponent(encoded);
  } catch (_) {
    return encoded;
  }
}

/**
 * Lädt alle aktiven `avatarUrl`-Werte aus `users` + `bars`.
 * Liefert ein Set der referenzierten Storage-Pfade unter `avatars/`.
 */
async function loadReferencedAvatarPaths(db) {
  const referenced = new Set();

  for (const col of ["users", "bars"]) {
    const snap = await db.collection(col).get();
    for (const doc of snap.docs) {
      const data = doc.data() || {};
      const url = (data.avatarUrl || "").toString().trim();
      if (!url) continue;
      const path = storagePathFromUrl(url);
      if (path && path.startsWith(PREFIX)) {
        referenced.add(path);
      }
    }
  }

  return referenced;
}

exports.cleanupOrphanAvatars = onSchedule(
  {
    region: "europe-west1",
    // Sonntag 03:00 — niedriges Traffic-Fenster.
    schedule: "0 3 * * 0",
    timeZone: "Europe/Vienna",
    maxInstances: 1,
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async () => {
    const db = admin.firestore();

    let bucket;
    try {
      bucket = admin.storage().bucket();
    } catch (e) {
      logger.error("[avatarCleanup] admin.storage() not configured", { msg: e?.message });
      return null;
    }

    const referenced = await loadReferencedAvatarPaths(db);
    logger.info("[avatarCleanup] referenced avatar paths", {
      count: referenced.size,
    });

    const [files] = await bucket.getFiles({ prefix: PREFIX });
    logger.info("[avatarCleanup] storage objects under prefix", {
      prefix: PREFIX,
      count: files.length,
    });

    const now = Date.now();
    let deleted = 0;
    let skipped = 0;
    let young = 0;

    for (const file of files) {
      // referenced? → behalten
      if (referenced.has(file.name)) {
        skipped++;
        continue;
      }

      // Schonfrist: jünger als GRACE_PERIOD_MS → behalten.
      // Wir nehmen `updated` aus den Metadaten (Default für GCS-Listing).
      const updatedStr = file.metadata?.updated || file.metadata?.timeCreated;
      const updatedMs = updatedStr ? Date.parse(updatedStr) : 0;
      if (!updatedMs || (now - updatedMs) < GRACE_PERIOD_MS) {
        young++;
        continue;
      }

      try {
        await file.delete({ ignoreNotFound: true });
        deleted++;
      } catch (e) {
        logger.warn("[avatarCleanup] delete failed", {
          path: file.name,
          msg: e?.message,
        });
      }
    }

    logger.info("[avatarCleanup] done", {
      deleted,
      skippedReferenced: skipped,
      skippedYoung: young,
    });
    return null;
  }
);
