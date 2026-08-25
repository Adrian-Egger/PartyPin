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

// ZWEITE QUELLE: Die Hauptliste ist ausdrücklich "Oberösterreichs
// Festl-Übersicht" -- alle 15 Bezirkslisten dort sind OÖ-Bezirke. Auf
// derselben Seite gibt es eine separate, viel kleinere PDF "Andere
// Bundesländer (Nur Festl und Festivals)". Die ist Stand August 2026
// winzig (3 Einträge, alle NÖ) und waechst laut Hinweis in der PDF ab
// 25.10.2026 nur um an OÖ angrenzende Gemeinden in NÖ/Stmk/Sbg. Auch
// mit beiden Quellen deckt der Import also NICHT ganz Österreich ab --
// das ist eine Eigenschaft der Quelle, keine des Codes.
//
// Spaltenstruktur ist identisch, nur enthält die Bezirk-Spalte hier
// Bundesland- statt OÖ-Bezirks-Kürzel ("NÖ - St. Pölten"). Das passt
// bereits zu parseBezirk()/BUNDESLAND_NAMES -- am Parser war nur die
// Fusszeilen-Erkennung anzupassen (siehe extractRecords.js, "ÜS - ").
const FESTLLISTE_OTHER_PDF_URL = defineString("FESTLLISTE_OTHER_PDF_URL", {
  default: "https://www.dropbox.com/scl/fi/oh0h3cnb1b8q7t8mc2kge/FL-Bezirk-Andere-Bundesl-nder.pdf?rlkey=65i6sq8tmkppiojx16fj0u4ne&st=4bg5ptof&e=1&dl=1",
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

// GESCHAETZTES MINDESTALTER. Die Quelle liefert KEIN Alter -- diese
// Werte sind aus der Kategorie abgeleitet, nicht aus der Realitaet.
// Deshalb wird jeder so gesetzte Wert mit `minAgeEstimated: true`
// markiert und in der App als Schaetzung ausgewiesen ("ca. 16+"), damit
// niemand vor verschlossener Tuer steht, weil die App ihm eine
// Sicherheit vorgegaukelt hat, die es nicht gibt.
//
// Bewusst KEIN Wert fuer Frühschoppen/Kirtag/Festl/Weinfest: das sind
// Familienveranstaltungen ohne Altersgrenze -- dort waere jede Zahl
// schlechter als gar keine Angabe.
const CATEGORY_MIN_AGE = {
  "Maturaball": 16,
  "Ballveranstaltung": 16,
  "Nachtclub-Event": 18,
  "Nachtclubevent": 18,
};

// Kategorien ohne Einlassgrenze. Bei Kirtag, Fruehschoppen, Zeltfest &
// Co. gibt es praktisch nie eine Altersbeschraenkung am Eingang -- der
// Jugendschutz regelt dort den Alkoholausschank, nicht den Eintritt.
// Diese Festln bekommen `ageOpen: true` und werden in der App als
// "Alle Altersgruppen" ausgewiesen, damit der Alters-Reiter nicht bei
// vier von fuenf Festln fehlt.
//
// Bewusst NICHT enthalten: "Festival" (grosse Festivals haben sehr wohl
// oft ein Mindestalter) und "-" (unbekannte Kategorie). Dort bleibt der
// Reiter lieber leer, als etwas Falsches zu behaupten.
const CATEGORY_AGE_OPEN = new Set([
  "Frühschoppen",
  "Dämmerschoppen",
  "Kirtag",
  "Festl",
  "FFestl",
  "Oktoberfest / Volksfest",
  "Oktoberfest/Volksfest",
  // Kommen vor, wenn die Doppelbezeichnung in der PDF umbricht und nur
  // eine Haelfte als eigenstaendige Kategorie ankommt.
  "Oktoberfest",
  "Volksfest",
  "Weinfest / Weinkost",
  "Weinfest/Weinkost",
  "Weinfest",
  "Weinkost",
]);

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

// ---------------------------------------------------------------------------
// Vorschaubild aus dem Event-Link (og:image)
// ---------------------------------------------------------------------------
// Die Quelle liefert keine Bilder. Das Einzige, woran ein Bild haengt, ist
// der verlinkte Beitrag -- wir lesen daher dessen Link-Vorschaubild aus,
// wie es Messenger und Chat-Apps beim Teilen eines Links auch tun.
//
// Erwartungshaltung: nur ~10 % der Eintraege haben ueberhaupt einen Link,
// und Instagram/Facebook liefern Bots meist eine Login-Wand statt der
// Seite. Realistisch bleiben ein paar Gemeinde-Seiten uebrig. Der Job
// darf daran nie haengenbleiben, deshalb hartes Timeout + jeder Fehler
// ist nicht-fatal.
const OG_FETCH_TIMEOUT_MS = 8000;
// Kurz genug, dass signierte Instagram-/Facebook-URLs frisch bleiben,
// lang genug, dass ein zweiter Lauf am selben Tag nichts neu holt.
const OG_CACHE_TTL_MS = 12 * 60 * 60 * 1000;
const OG_MAX_BYTES = 512 * 1024; // og:image steht im <head>, mehr braucht es nicht

const OG_PATTERNS = [
  /<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i,
  /<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i,
  /<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']/i,
];

function extractOgImage(html, pageUrl) {
  for (const re of OG_PATTERNS) {
    const m = html.match(re);
    if (!m || !m[1]) continue;
    const raw = m[1].trim()
        .replace(/&amp;/g, "&")
        .replace(/&#x2F;/gi, "/");
    if (!raw) continue;
    try {
      // Relative Pfade gegen die Seite aufloesen (kommt bei
      // Gemeinde-Seiten vor: content="/images/fest.jpg").
      return new URL(raw, pageUrl).toString();
    } catch (e) {
      continue;
    }
  }
  return null;
}

/// Liefert die og:image-URL zu [link] oder null. Ergebnisse (auch
/// negative) werden dauerhaft in `_ogImageCache` abgelegt, damit der
/// taegliche Lauf nicht jedes Mal dieselben Seiten abklappert.
function createOgImageFetcher(db) {
  const cacheCollection = db.collection("_ogImageCache");
  const memCache = new Map();

  async function fetchFor(link) {
    if (!link) return null;
    const key = slugify(link) || "unknown";
    if (memCache.has(key)) return memCache.get(key);

    const cached = await cacheCollection.doc(key).get();
    if (cached.exists) {
      const d = cached.data() || {};
      const at = d.updatedAt instanceof Date ?
        d.updatedAt : (d.updatedAt?.toDate?.() || null);
      const ageMs = at ? (Date.now() - at.getTime()) : Infinity;
      // KEIN dauerhafter Cache: Instagram und Facebook liefern signierte
      // CDN-URLs (scontent.cdninstagram.com / lookaside.fbsbx.com), die
      // nach wenigen Tagen ablaufen. Einmal gespeichert und nie wieder
      // geholt hiesse: das Bild ist ab dann dauerhaft kaputt. Deshalb
      // nur kurz cachen, damit ein manueller Zweitlauf am selben Tag
      // schnell ist, und danach frisch holen.
      if (ageMs < OG_CACHE_TTL_MS) {
        const v = d.imageUrl || null;
        memCache.set(key, v);
        return v;
      }
    }

    let imageUrl = null;
    let note = "";
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), OG_FETCH_TIMEOUT_MS);
      try {
        const resp = await fetch(link, {
          redirect: "follow",
          signal: ctrl.signal,
          headers: {
            // Ohne realistischen UA liefern viele Seiten gar nichts.
            "User-Agent": "Mozilla/5.0 (compatible; PartyPinBot/1.0; +https://partypin-5dc3f.web.app)",
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "de-AT,de;q=0.9",
          },
        });
        if (!resp.ok) {
          note = `HTTP ${resp.status}`;
        } else {
          const ct = (resp.headers.get("content-type") || "").toLowerCase();
          if (!ct.includes("html")) {
            note = `kein HTML (${ct})`;
          } else {
            const html = (await resp.text()).slice(0, OG_MAX_BYTES);
            imageUrl = extractOgImage(html, resp.url || link);
            if (!imageUrl) note = "kein og:image";
          }
        }
      } finally {
        clearTimeout(timer);
      }
    } catch (e) {
      note = (e && e.name === "AbortError") ? "Timeout" : `Fehler: ${e?.message || e}`;
    }

    await cacheCollection.doc(key).set({
      link,
      imageUrl,
      note,
      updatedAt: new Date(),
    });
    memCache.set(key, imageUrl);
    return imageUrl;
  }

  return {fetchFor};
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
  const ogImages = createOgImageFetcher(db);
  const now = new Date();

  // Beide Quellen laden. `sourceUrl` muss PRO Record mitgeführt werden --
  // vorher war das eine globale Variable, mit zwei PDFs stünde sonst bei
  // der Hälfte der Dokumente die falsche Herkunft.
  const sources = [
    {label: "Gesamtübersicht (OÖ)", url: toDropboxDirectUrl(FESTLLISTE_PDF_URL.value())},
    {label: "Andere Bundesländer", url: toDropboxDirectUrl(FESTLLISTE_OTHER_PDF_URL.value())},
  ];

  const records = [];
  let parseWarnings = 0;

  for (const src of sources) {
    console.log(`[festlliste-sync] Lade PDF (${src.label}) von`, src.url);
    const buffer = await fetchPdfBuffer(src.url);
    const res = await extractAllRecords(buffer);
    console.log(
        `[festlliste-sync] ${src.label}: ${res.records.length} Records, ` +
        `${res.warnings.length} Warnungen.`);
    if (res.warnings.length) {
      console.log(`[festlliste-sync] Warnungen ${src.label} (erste 20):`,
          JSON.stringify(res.warnings.slice(0, 20)));
    }
    parseWarnings += res.warnings.length;
    for (const r of res.records) records.push({...r, sourceUrl: src.url});
  }

  console.log(`[festlliste-sync] ${records.length} Records aus ${sources.length} Quellen, ${parseWarnings} Warnungen gesamt.`);

  const currentKeys = new Set();
  let created = 0;
  let updated = 0;
  let geocodeFailed = 0;
  let imagesFound = 0;
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
    const prev = existing.exists ? (existing.data() || {}) : {};

    // Mindestalter aus der Kategorie schaetzen -- aber NIE einen Wert
    // ueberschreiben, den jemand von Hand gesetzt hat. Ohne diesen Schutz
    // wuerde der naechtliche Sync (merge: true) jede manuelle Korrektur
    // wieder platt machen. Manuell = Wert vorhanden und NICHT als
    // Schaetzung markiert.
    const manualMinAge = prev.minAge != null && prev.minAgeEstimated !== true;
    const estimatedMinAge = CATEGORY_MIN_AGE[rec.kategorie] ?? null;

    // Vorschaubild: nur wenn es einen Link gibt und noch kein Bild
    // gesetzt ist. Ein manuell hochgeladenes Titelbild hat immer Vorrang.
    const manualImage = (prev.profileImageUrl || "").trim().length > 0 &&
      prev.profileImageEstimated !== true;
    let ogImage = null;
    if (rec.link && !manualImage) {
      ogImage = await ogImages.fetchFor(rec.link);
      if (ogImage) imagesFound++;
    }

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
      festlHighlights: [],
      city_lower: rec.ort.toLowerCase(),
      festlName_lower: rec.name.toLowerCase(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      source: SOURCE_TAG,
      sourceCategory: rec.kategorie,
      sourceBundesland: bundesland,
      sourceBezirk: bezirkName,
      sourceUrl: rec.sourceUrl,
      importedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (geo) {
      data.location = new admin.firestore.GeoPoint(geo.lat, geo.lng);
      data.lat = geo.lat;
      data.lng = geo.lng;
    }
    if (!manualMinAge) {
      data.minAge = estimatedMinAge;
      data.minAgeEstimated = estimatedMinAge != null;
      // Nur setzen, wenn es KEINE geschaetzte Grenze gibt -- sonst
      // widersprechen sich die beiden Felder.
      data.ageOpen = estimatedMinAge == null &&
        CATEGORY_AGE_OPEN.has(rec.kategorie);
    }
    if (ogImage && !manualImage) {
      data.profileImageUrl = ogImage;
      // Markiert das Bild als automatisch geholt, damit ein spaeter
      // manuell hochgeladenes Titelbild erkennbar bleibt und nicht vom
      // naechsten Lauf ueberschrieben wird.
      data.profileImageEstimated = true;
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
    parseWarnings,
    created,
    updated,
    deleted,
    skippedCancelled,
    skippedPast,
    geocodeFailed,
    imagesFound,
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
