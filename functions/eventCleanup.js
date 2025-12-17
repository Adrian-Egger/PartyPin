// =======================
// functions/eventsCleanup.js
// =======================
const functions = require('firebase-functions');
const admin = require('firebase-admin');

// Erwartet: admin.initializeApp() wird in functions/index.js genau 1x aufgerufen.

function computeEventKeyFromDate(eventDate) {
    // eventDate kann Timestamp, Date, Zahl, String sein
    if (!eventDate) return null;

    if (eventDate.toDate && typeof eventDate.toDate === 'function') {
        return String(eventDate.toDate().getTime());
    }
    if (eventDate instanceof Date) {
        return String(eventDate.getTime());
    }
    if (typeof eventDate === 'number') {
        return String(eventDate);
    }
    if (typeof eventDate === 'string') {
        const dt = new Date(eventDate);
        if (!isNaN(dt.getTime())) return String(dt.getTime());
    }
    return null;
}

// Extrahiert Storage-Pfade aus gs:// oder downloadURL
function storagePathFromUrl(url) {
    if (!url || typeof url !== 'string') return null;

    // gs://bucket/path/to/file
    if (url.startsWith('gs://')) {
        const without = url.replace('gs://', '');
        const slash = without.indexOf('/');
        if (slash === -1) return null;
        return without.substring(slash + 1);
    }

    // https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<encodedPath>?alt=media...
    const marker = '/o/';
    const i = url.indexOf(marker);
    if (i !== -1) {
        const rest = url.substring(i + marker.length);
        const q = rest.indexOf('?');
        const encoded = q === -1 ? rest : rest.substring(0, q);
        try {
            return decodeURIComponent(encoded);
        } catch (_) {
            return encoded;
        }
    }

    return null;
}

// Sammelt alle *Url Strings rekursiv aus einem Objekt/Array
function collectImageUrlsDeep(value, out) {
    if (!value) return;

    if (typeof value === 'string') {
        // nur Strings, die wie URLs/gs:// aussehen
        if (value.startsWith('http') || value.startsWith('gs://')) out.push(value);
        return;
    }

    if (Array.isArray(value)) {
        for (const v of value) collectImageUrlsDeep(v, out);
        return;
    }

    if (typeof value === 'object') {
        for (const [k, v] of Object.entries(value)) {
            // typische Felder
            if (typeof v === 'string' && (k.toLowerCase().includes('url') || v.startsWith('http') || v.startsWith('gs://'))) {
                collectImageUrlsDeep(v, out);
            } else {
                collectImageUrlsDeep(v, out);
            }
        }
    }
}

async function deleteStorageFiles(urls) {
    const bucket = admin.storage().bucket();
    const uniquePaths = new Set();

    for (const u of urls) {
        const p = storagePathFromUrl(u);
        if (p) uniquePaths.add(p);
    }

    for (const path of uniquePaths) {
        try {
            await bucket.file(path).delete({ ignoreNotFound: true });
            console.log('[cleanup] deleted storage file:', path);
        } catch (e) {
            console.log('[cleanup] failed delete storage file:', path, e?.message || e);
        }
    }
}

// löscht docs in batches
async function deleteQueryInBatches(query, batchSize = 300) {
    while (true) {
        const snap = await query.limit(batchSize).get();
        if (snap.empty) break;

        const batch = admin.firestore().batch();
        for (const doc of snap.docs) batch.delete(doc.ref);
        await batch.commit();
    }
}

// löscht doc + alle Subcollections rekursiv (ohne firebase-tools)
async function deleteDocRecursively(docRef) {
    const collections = await docRef.listCollections();
    for (const col of collections) {
        // alles in Subcollection löschen
        const q = col.orderBy(admin.firestore.FieldPath.documentId());
        await deleteQueryInBatches(q);
    }
    await docRef.delete();
}

function computeEventEnd(eventDate) {
    // Deine UI-Logik: start = eventDate - 1h; endet nach +12h
    // => end = (eventDate - 1h) + 12h = eventDate + 11h
    const dt = eventDate.toDate ? eventDate.toDate() : (eventDate instanceof Date ? eventDate : null);
    if (!dt) return null;
    return new Date(dt.getTime() + 11 * 60 * 60 * 1000);
}

/**
 * Scheduled Cleanup:
 * - findet Events unter bars/{barId}/events/{eventId}
 * - wenn Event "vorbei" (endTime < now) -> löscht:
 *   - Event-Dokument
 *   - (optional) eventFeedback docs unter bars/{barId}/eventFeedback mit passendem eventKey
 *   - alle Bilder (Storage) die im Event-Dokument verlinkt sind
 *
 * Läuft jede Stunde.
 */
exports.cleanupExpiredEvents = functions.pubsub
    .schedule('every 60 minutes')
    .timeZone('Europe/Vienna')
    .onRun(async () => {
        const db = admin.firestore();
        const now = new Date();

        // collectionGroup: alle events unter allen bars
        const eventsSnap = await db.collectionGroup('events').where('eventActive', '==', true).get();

        console.log('[cleanup] events scanned:', eventsSnap.size);

        for (const eventDoc of eventsSnap.docs) {
            const eventData = eventDoc.data() || {};

            const rawDate = eventData.eventDate;
            if (!rawDate) continue;

            const end = computeEventEnd(rawDate);
            if (!end) continue;

            // noch nicht vorbei
            if (end.getTime() > now.getTime()) continue;

            // barId aus Pfad holen: bars/{barId}/events/{eventId}
            const parts = eventDoc.ref.path.split('/');
            // ["bars", "{barId}", "events", "{eventId}"]
            const barId = parts.length >= 2 ? parts[1] : null;
            if (!barId) continue;

            const eventKey = computeEventKeyFromDate(rawDate);

            console.log('[cleanup] deleting expired event:', {
                barId,
                eventId: eventDoc.id,
                end: end.toISOString(),
                eventKey,
            });

            // 1) Bilder sammeln + löschen
            const urls = [];
            collectImageUrlsDeep(eventData, urls);
            await deleteStorageFiles(urls);

            // 2) Optional: eventFeedback zu diesem Event löschen
            if (eventKey) {
                const feedbackCol = db.collection('bars').doc(barId).collection('eventFeedback');
                const q = feedbackCol.where('eventKey', '==', eventKey);
                await deleteQueryInBatches(q);
            }

            // 3) Event Doc + Subcollections löschen
            try {
                await deleteDocRecursively(eventDoc.ref);
            } catch (e) {
                console.log('[cleanup] failed deleting event doc:', eventDoc.ref.path, e?.message || e);
            }

            // 4) Optional: eventActive im Event selbst ist eh weg, aber falls du in bars doc Flags gesetzt hast -> hier anpassen
            // (nur wenn du solche Felder noch verwendest)
            // await db.collection('bars').doc(barId).set({ eventActive: false }, { merge: true });
        }

        return null;
    });
