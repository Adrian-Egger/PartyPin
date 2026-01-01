// =======================
// functions/eventCleanup.js   (V2 Scheduler kompatibel, deploybar)
// =======================
/* eslint-disable */
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

// Erwartet: admin.initializeApp() wird in functions/index.js genau 1x aufgerufen.

function computeEventKeyFromDate(eventDate) {
    if (!eventDate) return null;

    if (eventDate.toDate && typeof eventDate.toDate === "function") {
        return String(eventDate.toDate().getTime());
    }
    if (eventDate instanceof Date) {
        return String(eventDate.getTime());
    }
    if (typeof eventDate === "number") {
        return String(eventDate);
    }
    if (typeof eventDate === "string") {
        const dt = new Date(eventDate);
        if (!Number.isNaN(dt.getTime())) return String(dt.getTime());
    }
    return null;
}

// Extrahiert Storage-Pfade aus gs:// oder downloadURL
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
    if (i !== -1) {
        const rest = url.substring(i + marker.length);
        const q = rest.indexOf("?");
        const encoded = q === -1 ? rest : rest.substring(0, q);
        try {
            return decodeURIComponent(encoded);
        } catch (_) {
            return encoded;
        }
    }

    return null;
}

// Sammelt alle URL-Strings rekursiv aus Objekt/Array
function collectImageUrlsDeep(value, out) {
    if (value === null || value === undefined) return;

    if (typeof value === "string") {
        if (value.startsWith("http") || value.startsWith("gs://")) out.push(value);
        return;
    }

    if (Array.isArray(value)) {
        for (const v of value) collectImageUrlsDeep(v, out);
        return;
    }

    if (typeof value === "object") {
        for (const v of Object.values(value)) collectImageUrlsDeep(v, out);
    }
}

async function deleteStorageFiles(urls) {
    // Storage nur wenn Admin SDK Storage aktiviert ist
    let bucket;
    try {
        bucket = admin.storage().bucket();
    } catch (e) {
        console.log("[cleanup] admin.storage() not configured, skip storage deletes");
        return;
    }

    const uniquePaths = new Set();
    for (const u of urls) {
        const p = storagePathFromUrl(u);
        if (p) uniquePaths.add(p);
    }

    for (const path of uniquePaths) {
        try {
            await bucket.file(path).delete({ ignoreNotFound: true });
            console.log("[cleanup] deleted storage file:", path);
        } catch (e) {
            console.log("[cleanup] failed delete storage file:", path, e?.message || e);
        }
    }
}

// Löscht docs in batches
async function deleteQueryInBatches(query, batchSize = 300) {
    while (true) {
        const snap = await query.limit(batchSize).get();
        if (snap.empty) break;

        const batch = admin.firestore().batch();
        for (const doc of snap.docs) batch.delete(doc.ref);
        await batch.commit();
    }
}

// Löscht doc + alle Subcollections (1 Level) + doc
async function deleteDocRecursively(docRef) {
    const collections = await docRef.listCollections();
    for (const col of collections) {
        const q = col.orderBy(admin.firestore.FieldPath.documentId());
        await deleteQueryInBatches(q);
    }
    await docRef.delete();
}

function computeEventEnd(eventDate) {
    const dt =
        eventDate?.toDate && typeof eventDate.toDate === "function"
            ? eventDate.toDate()
            : eventDate instanceof Date
                ? eventDate
                : null;

    if (!dt) return null;

    // Ende = eventDate + 11h (deine Logik)
    return new Date(dt.getTime() + 11 * 60 * 60 * 1000);
}

/**
 * Scheduled Cleanup:
 * - findet Events unter bars/{barId}/events/{eventId} (collectionGroup("events"))
 * - wenn Event vorbei -> löscht:
 *   - Event-Dokument (+ Subcollections)
 *   - eventFeedback (bars/{barId}/eventFeedback) per eventKey
 *   - Bilder in Storage (URLs im Event-Dokument)
 */
exports.cleanupExpiredEvents = onSchedule(
    {
        region: "us-central1",
        schedule: "every 60 minutes",
        timeZone: "Europe/Vienna",
    },
    async () => {
        const db = admin.firestore();
        const now = new Date();

        const eventsSnap = await db.collectionGroup("events").where("eventActive", "==", true).get();
        console.log("[cleanup] events scanned:", eventsSnap.size);

        for (const eventDoc of eventsSnap.docs) {
            const eventData = eventDoc.data() || {};
            const rawDate = eventData.eventDate;
            if (!rawDate) continue;

            const end = computeEventEnd(rawDate);
            if (!end) continue;
            if (end.getTime() > now.getTime()) continue;

            // bars/{barId}/events/{eventId}
            const parts = eventDoc.ref.path.split("/");
            const barId = parts.length >= 2 ? parts[1] : null;
            if (!barId) continue;

            const eventKey = computeEventKeyFromDate(rawDate);

            console.log("[cleanup] deleting expired event:", {
                barId,
                eventId: eventDoc.id,
                end: end.toISOString(),
                eventKey,
            });

            // 1) Storage Bilder löschen
            const urls = [];
            collectImageUrlsDeep(eventData, urls);
            await deleteStorageFiles(urls);

            // 2) Feedback löschen
            if (eventKey) {
                const feedbackCol = db.collection("bars").doc(barId).collection("eventFeedback");
                const q = feedbackCol.where("eventKey", "==", eventKey);
                await deleteQueryInBatches(q);
            }

            // 3) Event Doc + Subcollections löschen
            try {
                await deleteDocRecursively(eventDoc.ref);
            } catch (e) {
                console.log("[cleanup] failed deleting event doc:", eventDoc.ref.path, e?.message || e);
            }
        }

        return null;
    }
);
