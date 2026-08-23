// =======================
// functions/festlliste/sync.js
// =======================
/* eslint-disable */
//
// Täglicher Scheduled-Job: lädt die "Festl-Liste - Gesamtübersicht" PDF
// (Quelle: linkrex.eu/@festlliste -> Dropbox), extrahiert alle
// bevorstehenden (nicht abgesagten) Feste und synchronisiert sie 1:1 in
// die Firestore-Collection `festln` (dieselbe Collection, die auch der
// Admin-Editor in der App befüllt -- siehe
// lib/Screens/festl/admin_create_festl_screen.dart).
//
// "Rein und raus" (siehe Anforderung):
//  - NEU auftauchende / weiterhin bevorstehende Feste werden angelegt
//    bzw. aktualisiert (upsert, docId = deterministischer sourceKey).
//  - Feste, die nicht mehr in der Quelle auftauchen, deren Termin schon
//    vorbei ist, oder die als abgesagt markiert wurden, werden wieder
//    gelöscht -- ABER NUR Dokumente, die von diesem Import stammen
//    (`source == "festlliste_import"`). Manuell im Admin-Bereich
//    angelegte Festln werden nie angefasst.
//
// Läuft mit dem Firebase Admin SDK (voller Zugriff, umgeht die
// Firestore-Rules komplett -- die Rules gelten nur für Client-Zugriffe).

const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineString} = require("firebase-functions/params");
const admin = require("firebase-admin");

const {extractAllRecords} = require("./extractRecords");
const {createGeocoder} = require("./geocode");

const FESTLN_COLLECTION = "festln";
const SOURCE_TAG = "festlliste_import";

// Als Firebase-Functions-Parameter konfigurierbar (Firebase Console ->
// Functions -> Parameter, oder `firebase functions:config` bzw. .env),
// damit der Link ohne Code-Änderung/Redeploy aktualisiert werden kann
// (z.B. wenn linkrex.eu/@festlliste im Jänner auf die "FL 2027"-PDF
// umstellt). Default = aktuell (August 2026) aktiver Link von
// "Gesamtübersicht 2026" auf linkrex.eu/@festlliste.
const FESTLLISTE_PDF_URL = defineString("FESTLLISTE_PDF_URL", {
  default: "https://www.dropbox.com/scl/fi/4c8l7bl9yhuhkmlhv1f4q/FL-2026-Gesamt-bersicht.pdf?rlkey=9bp4chnudoc59lpbgguooh8sv&dl=1",
});

// Bundesland-Kürzel -> voller Name, wie sie in der Bezirk-Spalte der PDF
// vorkommen (z.B. "OÖ - Braunau am Inn", "NÖ - St. Pölten").
const BUNDESLAND_NAMES = {
  "oö": "Oberösterreich",
  "nö": "Niederösterreich",
  "stmk": "Steiermark",
  "sbg": "Salzburg",
  "ktn": "Kärnten",
  "tirol": "Tirol",
  "vlbg": "Vorarlberg",
  "wien": "Wien",
  "bgld": "Burgenland",
};

// Grobe, aus der Kategorie abgeleitete Startzeit -- die PDF liefert
// keine Uhrzeiten, nur Datum + Kategorie. Dient nur als sinnvoller
// Startwert; Details verweisen wir im Beschreibungstext auf den Link.
const CATEGORY_START_HOUR = {
  "Frühschoppen": 10,
  "Kirtag": 10,
  "Weinfest/Weinkost": 16,
  "Weinfest / Weinkost": 16,
  "Dämmerschoppen": 18,
  "Oktoberfest/Volksfest": 18,
  "Oktoberfest / Volksfest": 18,
  "Maturaball": 20,
  "Ballveranstaltung": 20,
  "Nachtclub-Event": 22,
  "Nachtclubevent": 22,
};
const DEFAULT_START_HOUR = 14;
// Konsistent mit functions/eventCleanup.js (dort: eventDate + 11h).
const EVENT_DURATION_HOURS = 11;

function slugify(text) {
  return (text || "")
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[̀-ͯ]/g, "")
      .replace(/ä/g, "ae").replace(/ö/g, "oe").replace(/ü/g, "ue").replace(/ß/g, "ss")
      .replace(/[^a-z0-9]+/g, "_")
      .replace(/^_+|_+$/g, "")
      .slice(0, 80);
}

function toDropboxDirectUrl(url) {
  try {
    const u = new URL(url);
    u.searchParams.set("dl", "1");
    return u.toString();
  } catch (e) {
    return url;
  }
}

function parseBezirk(bezirkRaw) {
  const raw = (bezirkRaw || "").trim();
  const m = raw.match(/^([A-Za-zÄÖÜäöü]{2,5})\s*-\s*(.+)$/);
  if (!m) return {bundesland: "Österreich", bezirkName: raw};
  const code = m[1].trim().toLowerCase();
  const bundesland = BUNDESLAND_NAMES[code] || m[1].trim();
  return {bundesland, bezirkName: m[2].trim()};
}

// Bestimmt das Jahr für ein "TT.MM."-Datum ohne Jahresangabe: nimmt das
// aktuelle Server-Jahr an, außer der Monat liegt deutlich VOR dem
// aktuellen Monat (> 1 Monat zurück) -- dann handelt es sich vermutlich
// um einen Jahreswechsel-Fall (z.B. Lauf im Dezember, Eintrag im
// Jänner) und wir nehmen das Folgejahr an.
function resolveYear(month, now) {
  const currentYear = now.getFullYear();
  const currentMonth = now.getMonth() + 1;
  if (month < currentMonth - 1) return currentYear + 1;
  return currentYear;
}

// Grobe, DST-taugliche (Sommer-/Winterzeit) UTC-Umrechnung für
// Europe/Vienna ohne externe Zeitzonen-Bibliothek: CEST (+2) von April
// bis Oktober, CET (+1) sonst. Für den Zweck hier (ungefähre, aus der
// Kategorie abgeleitete Startzeit) ausreichend genau -- an den exakten
// DST-Umstelltagen im März/Oktober im schlimmsten Fall 1h Abweichung.
function viennaLocalToUtc(year, month, day, hour) {
  const isSummer = month >= 4 && month <= 10;
  const offsetHours = isSummer ? 2 : 1;
  return new Date(Date.UTC(year, month - 1, day, hour - offsetHours, 0, 0));
}

// Die Quelle liefert KEINEN Beschreibungstext (nur Datum/Name/Ort/
// Kategorie/Bezirk/Link). `description` ist in der Detailansicht
// (FestlBottomSheet) aber der einzige Inhaltsblock, muss also generiert
// werden. Bewusst kurz und ohne Meta-Gerede: kein "automatisch
// importiert", keine Quellenangabe -- die Herkunft steht ohnehin
// intern in `sourceUrl`/`source`.
function categoryLabel(kategorie) {
  const k = (kategorie || "").trim();
  // "Oktoberfest / Volksfest" und "Weinfest / Weinkost" sind
  // Doppelbezeichnungen der Quelle -- im Fliesstext reicht die erste.
  const first = k.split("/")[0].trim();
  if (!first || first === "-") return "";
  return first;
}

function buildDescription(rec, bezirkName) {
  const kat = categoryLabel(rec.kategorie);
  const ort = (rec.ort || "").trim();

  let opener;
  if (kat && ort) {
    opener = `🎉 ${kat} in ${ort}`;
  } else if (kat) {
    opener = `🎉 ${kat}`;
  } else if (ort) {
    opener = `🎉 Fest in ${ort}`;
  } else {
    opener = "🎉 Fest";
  }
  // Bezirksname weglassen, wenn er dem Ort entspricht ("Maturaball in
  // Braunau am Inn, Bezirk Braunau am Inn" liest sich doppelt).
  const bez = (bezirkName || "").trim();
  if (bez && bez.toLowerCase() !== ort.toLowerCase()) {
    opener += `, Bezirk ${bez}`;
  }
  opener += ".";

  // Nur ~10 % der Eintraege haben einen Link (die Quelle pflegt ihn
  // erst, wenn der Termin naeher rueckt) -- ohne Link darf der Text
  // nicht auf einen verweisen, den es nicht gibt.
  const tail = rec.link ?
    "Alle Infos zum Programm gibt's über den Link." :
    "Programm und genaue Uhrzeit gibt der Veranstalter noch bekannt.";

  return `${opener} ${tail}`;
}

async function fetchPdfBuffer(url) {
  const resp = await fetch(url, {
    headers: {"User-Agent": "Mozilla/5.0 (compatible; PartyPinFestllisteSync/1.0)"},
    redirect: "follow",
  });
  if (!resp.ok) {
    throw new Error(`PDF-Download fehlgeschlagen: HTTP ${resp.status} (${url})`);
  }
  const arrayBuffer = await resp.arrayBuffer();
  return Buffer.from(arrayBuffer);
}

async function deleteFestlDocRecursively(docRef) {
  const collections = await docRef.listCollections();
  for (const col of collections) {
    const snap = await col.get();
    if (snap.empty) continue;
    const batch = admin.firestore().batch();
    for (const d of snap.docs) batch.delete(d.ref);
    await batch.commit();
  }
  await docRef.delete();
}

async function runFestllisteSync() {
  const db = admin.firestore();
  const geocoder = createGeocoder(db);
  const now = new Date();

  const pdfUrl = toDropboxDirectUrl(FESTLLISTE_PDF_URL.value());
  console.log("[festlliste-sync] Lade PDF von", pdfUrl);
  const pdfBuffer = await fetchPdfBuffer(pdfUrl);

  const {records, warnings} = await extractAllRecords(pdfBuffer);
  console.log(`[festlliste-sync] ${records.length} Records extrahiert, ${warnings.length} Warnungen.`);
  if (warnings.length) {
    console.log("[festlliste-sync] Warnungen (erste 20):", JSON.stringify(warnings.slice(0, 20)));
  }

  const currentKeys = new Set();
  let created = 0;
  let updated = 0;
  let geocodeFailed = 0;
  let skippedCancelled = 0;
  let skippedPast = 0;

  for (const rec of records) {
    if (rec.cancelled) {
      skippedCancelled++;
      continue;
    }

    const year = resolveYear(rec.month, now);
    const {bundesland, bezirkName} = parseBezirk(rec.bezirk);
    const startHour = CATEGORY_START_HOUR[rec.kategorie] ?? DEFAULT_START_HOUR;
    const startTime = viennaLocalToUtc(year, rec.month, rec.day, startHour);
    const endTime = new Date(startTime.getTime() + EVENT_DURATION_HOURS * 60 * 60 * 1000);

    // Bereits vergangene Termine gar nicht erst importieren (werden,
    // falls vorher importiert, unten automatisch aufgeräumt, weil sie
    // nicht mehr in `currentKeys` landen).
    if (endTime.getTime() < now.getTime()) {
      skippedPast++;
      continue;
    }

    const sourceKey = `fl_${year}${String(rec.month).padStart(2, "0")}${String(rec.day).padStart(2, "0")}_${slugify(rec.name)}_${slugify(rec.ort)}`;
    currentKeys.add(sourceKey);

    // Mehrere Anfrage-Varianten probieren, von spezifisch zu grob --
    // analog zu AdminCreateFestlScreen._geocode() in der App. Bezirke
    // wie "Braunau am Inn" oder "Ried im Innkreis" enthalten Zusätze
    // ("am Inn", "im Innkreis"), die Nominatim bei manchen Gemeinden aus
    // dem Konzept bringen -- ohne den Bezirksnamen klappt die Anfrage
    // dann meistens.
    const geoAttempts = [
      `${rec.ort}, ${bezirkName}, ${bundesland}, Österreich`,
      `${rec.ort}, ${bundesland}, Österreich`,
      `${rec.ort}, Österreich`,
    ];
    let geo = null;
    for (const q of geoAttempts) {
      geo = await geocoder.geocode(q);
      if (geo) break;
    }
    if (!geo) {
      geocodeFailed++;
      console.log("[festlliste-sync] Geocoding fehlgeschlagen für:", rec.ort, bezirkName);
    }

    const docRef = db.collection(FESTLN_COLLECTION).doc(sourceKey);
    const existing = await docRef.get();

    const description = buildDescription(rec, bezirkName);

    const data = {
      festlName: rec.name,
      festlId: sourceKey,
      organizer: "",
      link: rec.link || "",
      description,
      address: rec.ort,
      city: rec.ort,
      country: "Austria",
      status: "approved",
      createdByAdmin: false,
      startTime: admin.firestore.Timestamp.fromDate(startTime),
      endTime: admin.firestore.Timestamp.fromDate(endTime),
      minAge: null,
      festlHighlights: [],
      city_lower: rec.ort.toLowerCase(),
      festlName_lower: rec.name.toLowerCase(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      source: SOURCE_TAG,
      sourceCategory: rec.kategorie,
      sourceBundesland: bundesland,
      sourceBezirk: bezirkName,
      sourceUrl: pdfUrl,
      importedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (geo) {
      data.location = new admin.firestore.GeoPoint(geo.lat, geo.lng);
      data.lat = geo.lat;
      data.lng = geo.lng;
    }
    if (!existing.exists) data.createdAt = admin.firestore.FieldValue.serverTimestamp();

    await docRef.set(data, {merge: true});
    if (existing.exists) updated++; else created++;
  }

  // "Raus": alle zuvor importierten Festln löschen, die in DIESEM Lauf
  // nicht mehr als aktuell/bevorstehend erkannt wurden (abgesagt,
  // vorbei, oder aus der Quelle verschwunden). Manuell angelegte Festln
  // (kein `source`-Feld) bleiben unangetastet.
  const importedSnap = await db.collection(FESTLN_COLLECTION).where("source", "==", SOURCE_TAG).get();
  let deleted = 0;
  for (const doc of importedSnap.docs) {
    if (!currentKeys.has(doc.id)) {
      await deleteFestlDocRecursively(doc.ref);
      deleted++;
    }
  }

  const summary = {
    recordsExtracted: records.length,
    parseWarnings: warnings.length,
    created,
    updated,
    deleted,
    skippedCancelled,
    skippedPast,
    geocodeFailed,
  };
  console.log("[festlliste-sync] Zusammenfassung:", JSON.stringify(summary));
  return summary;
}

exports.syncFestlliste = onSchedule(
    {
      region: "europe-west1",
      // Täglich um 06:00 Europe/Vienna -- nach dem täglichen Update der
      // Quelle (linkrex.eu zeigt jeweils ein "Update" für den Folgetag
      // an, siehe Landingpage).
      schedule: "0 6 * * *",
      timeZone: "Europe/Vienna",
      maxInstances: 1,
      timeoutSeconds: 540,
      memory: "512MiB",
    },
    async () => {
      await runFestllisteSync();
      return null;
    },
);

// Für manuelles Testen/Debuggen exportiert (z.B. via
// `firebase functions:shell` -> `runFestllisteSyncForTest()`), OHNE
// einen zweiten Scheduler zu registrieren.
exports.runFestllisteSyncForTest = runFestllisteSync;
