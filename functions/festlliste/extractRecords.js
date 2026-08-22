// =======================
// functions/festlliste/extractRecords.js
// =======================
/* eslint-disable */
//
// Liest die "Festl-Liste - Gesamtübersicht" PDF (Quelle: linkrex.eu/@
// festlliste -> Dropbox-Link) und extrahiert strukturierte Event-Records.
//
// VERSION 2 -- nach Diagnose gegen die ECHTE PDF (siehe Diagnose-Lauf
// vom 22.08.2026) komplett überarbeitet. Zwei Annahmen aus Version 1
// haben sich als falsch herausgestellt:
//
// 1) "Spalten-Header stehen über den Werten": FALSCH. In der echten PDF
//    sitzen die Header-Labels ("Bezirk", "Link") teils deutlich RECHTS
//    von den tatsächlichen Werten (z.B. Header "Bezirk" bei x=349.95,
//    echte Werte ab x≈329). Reine x-Schwellenwerte relativ zum Header
//    haben Link- und Bezirk-Werte in die falsche Nachbarspalte gemappt.
// 2) "Umbruch-Fortsetzungszeilen stehen UNTER der Hauptzeile": FALSCH.
//    Zellen sind vertikal zentriert -- eine umgebrochene Bezirks-Zelle
//    kann mit ihrer ersten Zeile ÜBER der Datums-Hauptzeile stehen. Rein
//    sequentielles "alles nach dem Datum gehört zum current Record" hat
//    solche Fragmente dem VORHERIGEN Datensatz zugeschlagen.
//
// NEUER ANSATZ:
// a) Felder werden primär am INHALT erkannt, nicht an der Spalten-
//    Position: Datum hat ein festes Muster ("Sa,22.08."), Bezirk beginnt
//    immer mit einem 2-3-stelligen Bundesland-Kürzel + " - " ("OÖ - ",
//    "NÖ - "), Link beginnt immer mit "http", Kategorie kommt aus einer
//    bekannten, kurzen Liste. NUR für Name/Ort (beides freier Text ohne
//    erkennbares Muster) und für Fortsetzungs-Fragmente (die ihr
//    Muster durch den Umbruch verloren haben, z.B. nur noch "Inn" statt
//    "OÖ - Braunau am Inn") wird die x-Position als Fallback benutzt --
//    mit Zonen-Grenzen, die aus der echten PDF kalibriert sind (siehe
//    ZONE_BOUNDS unten).
// b) Zeilen werden nicht mehr "der vorherigen Zeile" zugeschlagen,
//    sondern JEDEM Datensatz wird die Zeile zugeordnet, deren
//    Datums-Anker (Wochentag,TT.MM.) ihr am NÄCHSTEN ist (egal ob
//    darüber oder darunter) -- das bildet die vertikale Zentrierung der
//    Zellen korrekt ab.
//
// Diese Datei ist reine Parsing-Logik ohne Netzwerk-/Firestore-Zugriffe.

const HEADER_LABELS = {
  datum: ["datum"],
  name: ["veranstaltungsname"],
  ort: ["veranstaltungsort"],
  kategorie: ["kategorie"],
  bezirk: ["bezirk"],
  link: ["link"],
};

// Toleranz in PDF-Punkten: Textfragmente mit |y1-y2| <= diesem Wert
// gelten als selbe visuelle Zeile.
const ROW_Y_TOLERANCE = 2.5;

const WEEKDAY_DATE_RE = /^[A-ZÄÖÜ][a-zäöüß]{1,2},(\d{2})\.(\d{2})\.$/;
const BEZIRK_START_RE = /^[A-ZÄÖÜ]{2,3}\s*-\s*/;
const LINK_START_RE = /^https?:\/\//i;
const CANCEL_START_RE = /^❌/;

// Bekannte Kategorie-Werte, GENAU wie sie als EIGENSTÄNDIGES Textfragment
// vorkommen (Vergleich nach trim(), exakte Gleichheit -- kein "enthält",
// damit z.B. der Name "Dämmerschoppen Feuerwehr Jeging" nicht
// fälschlich als Kategorie erkannt wird). Fortsetzungszeilen einer
// umgebrochenen Kategorie (z.B. "Volksfest" als 2. Zeile von
// "Oktoberfest / Volksfest") brauchen HIER keinen Eintrag -- die fallen
// automatisch über die x-Zone in "kategorie", weil sie in derselben
// Spalte stehen.
const KATEGORIE_EXACT = new Set([
  "Festl", "FFestl", "Festival", "Maturaball", "Ballveranstaltung",
  "Frühschoppen", "Dämmerschoppen", "Nachtclubevent", "Kirtag",
  "Oktoberfest /", "Weinfest /", "-",
]);

// KALIBRIERTE x-ZONEN (aus dem echten Diagnose-Dump vom 22.08.2026,
// Seite 1+2 der "FL 2026 - Gesamtübersicht.pdf"):
//   Beobachtete Werte -- name: 62.7-103.2 | ort: 176.8-201.2 |
//   kategorie: 258.3-281.3 | bezirk: 329.4-353.6 | link: ~395-455
// Grenzen bewusst mit Sicherheitsabstand in die jeweilige Lücke gelegt.
// NUR als Fallback benutzt, wenn Inhalts-Erkennung nicht greift (siehe
// classifyItem). Falls die Quelle ihr Layout grundlegend ändert, fällt
// das über die Warnings auf ("kein-name-oder-ort" etc.) -- dann muss
// hier neu kalibriert werden (Diagnose-Skript erneut laufen lassen).
const ZONE_NAME_ORT = 145;
const ZONE_ORT_KATEGORIE = 230;
const ZONE_KATEGORIE_BEZIRK = 310;
const ZONE_BEZIRK_LINK = 380;

// Layout-Rauschen (Fußzeile/Kopfzeile/Cookie-Banner etc.), das NICHT zu
// irgendeinem Datensatz gehört. Muss VOR der Anker-Zuordnung entfernt
// werden, sonst wird es dem jeweils letzten Datensatz einer Seite
// zugeschlagen (der einzige Anker, der noch "darunter" liegt).
const NOISE_LINE_PATTERNS = [
  /^ÜS - Gesamtübersicht/i,
  /^Festl-Liste$/i,
  /^Seite \d+ von \d+$/i,
  /^Page \d+ of \d+$/i,
  /^Für weitere Infos/i,
  /^Letzte Aktualisierung/i,
  /^last Update$/i,
  /^:$/,
  /^We use cookies/i,
  /^Customize cookies$/i,
  /^Decline$/i,
  /^Accept All$/i,
];

function isNoiseText(text) {
  const t = text.trim();
  if (!t) return false;
  return NOISE_LINE_PATTERNS.some((re) => re.test(t));
}

function groupIntoRows(items) {
  const sorted = [...items].sort((a, b) => b.y - a.y || a.x - b.x);
  const rows = [];
  for (const it of sorted) {
    let row = rows.find((r) => Math.abs(r.y - it.y) <= ROW_Y_TOLERANCE);
    if (!row) {
      row = {y: it.y, items: []};
      rows.push(row);
    }
    row.items.push(it);
  }
  rows.sort((a, b) => b.y - a.y);
  for (const r of rows) r.items.sort((a, b) => a.x - b.x);
  return rows;
}

function findHeaderColumns(items) {
  const rows = groupIntoRows(items);
  for (const row of rows) {
    const found = {};
    for (const it of row.items) {
      const norm = it.text.trim().toLowerCase();
      for (const [key, labels] of Object.entries(HEADER_LABELS)) {
        if (labels.includes(norm)) found[key] = it.x;
      }
    }
    if (Object.keys(found).length >= 5) {
      return {headerY: row.y, columns: found};
    }
  }
  return null;
}

// Ordnet ein x < ZONE_NAME_ORT usw. der jeweiligen "Zwischenspalte" zu.
// Wird NUR als Fallback benutzt (siehe classifyItem).
function zoneForX(x) {
  if (x < ZONE_NAME_ORT) return "name";
  if (x < ZONE_ORT_KATEGORIE) return "ort";
  if (x < ZONE_KATEGORIE_BEZIRK) return "kategorie";
  if (x < ZONE_BEZIRK_LINK) return "bezirk";
  return "link";
}

// Klassifiziert EIN Textfragment anhand seines INHALTS (primär) bzw.
// seiner x-Position (Fallback für Fortsetzungszeilen und freien Text).
// Gibt eines von "datum" | "cancel" | "link" | "bezirk" | "kategorie" |
// "name" | "ort" zurück.
function classifyItem(text, x) {
  const t = text.trim();
  if (WEEKDAY_DATE_RE.test(t)) return "datum";
  if (CANCEL_START_RE.test(t)) return "cancel";
  if (LINK_START_RE.test(t)) return "link";
  if (BEZIRK_START_RE.test(t)) return "bezirk";
  if (KATEGORIE_EXACT.has(t)) return "kategorie";
  return zoneForX(x);
}

// appendContinuation: hängt `addition` an `base` an. Silbentrennung
// mitten im Wort (z.B. "Wels-" + "Stadt", KEIN Leerzeichen davor) wird
// ohne Leerzeichen verbunden, alles andere MIT Leerzeichen. Für Link
// (URLs) nie ein Leerzeichen einfügen.
function appendContinuation(base, addition, {noSpace = false} = {}) {
  if (!addition) return base;
  if (!base) return addition;
  const midWordHyphen = /\S-$/.test(base) && !/\s-$/.test(base);
  if (noSpace || midWordHyphen) return base + addition;
  return base + " " + addition;
}

const FIELD_KEYS = ["name", "ort", "kategorie", "bezirk", "link", "cancelReason"];

/**
 * Baut aus einer geordneten Liste von {text,x,y}-Items (alle Items, die
 * zu EINEM Datensatz gehören, bereits in Lesereihenfolge: y absteigend,
 * innerhalb einer Zeile x aufsteigend) die Felder des Datensatzes.
 */
function buildRecordFromItems(items) {
  const rec = {name: "", ort: "", kategorie: "", bezirk: "", link: "", cancelled: false, cancelReason: ""};
  let lastField = null;
  let lastY = null;

  for (const it of items) {
    if (WEEKDAY_DATE_RE.test(it.text.trim())) continue; // Datum selbst kein Feldinhalt

    let field = classifyItem(it.text, it.x);
    if (field === "cancel") {
      rec.cancelled = true;
      lastField = "cancelReason";
      lastY = it.y;
      continue;
    }
    // Nach einer Absage-Markierung gehört ALLES Weitere in diesem
    // Datensatz zum Ausfalltext, nicht mehr zu Link/Bezirk/etc.
    if (rec.cancelled && lastField === "cancelReason" && field !== "datum") {
      field = "cancelReason";
    }

    const opts = field === "link" ? {noSpace: true} : {};
    const sameRowContinuation = lastField === field && lastY === it.y;
    if (sameRowContinuation) {
      rec[field] = rec[field] + it.text; // selbe Zeile: rohe Konkatenation (Leerzeichen ggf. schon als eigenes Fragment enthalten)
    } else {
      rec[field] = appendContinuation(rec[field], it.text, opts);
    }
    lastField = field;
    lastY = it.y;
  }

  for (const k of FIELD_KEYS) {
    if (typeof rec[k] === "string") rec[k] = rec[k].replace(/\s+/g, " ").trim();
  }
  // URLs enthalten nie echte Leerzeichen -- ein hier verbliebenes
  // Leerzeichen stammt von einem Zeilenumbruch mitten in der URL (die
  // PDF enthält manchmal ein Trenn-Leerzeichen als eigenes Fragment am
  // Zeilenende, bevor die URL in der nächsten Zeile weitergeht).
  rec.link = rec.link.replace(/\s+/g, "");

  // Bei einzelnen Records taucht das Kategorie-Wort in der PDF als ZWEI
  // separate Textfragmente an (fast) derselben Stelle auf (z.B.
  // "Frühschoppen Frühschoppen") -- vermutlich eine Artefakt-Ebene der
  // Quelle. Exakte Verdopplung des kompletten Werts wird deshalb
  // zusammengefasst; echte Zwei-Wort-Kategorien wie "Weinfest / Weinkost"
  // sind davon nicht betroffen, weil sie keine Wiederholung DESSELBEN
  // Teilstrings sind.
  const dup = rec.kategorie.match(/^(.+?)\s+\1$/);
  if (dup) rec.kategorie = dup[1];
  if (rec.cancelled && !rec.cancelReason) rec.cancelReason = "Abgesagt/Ausfall laut Quelle.";
  return rec;
}

/**
 * Gruppiert alle Zeilen einer Seite zu Datensätzen: jede Zeile wird dem
 * Datums-Anker (Zeile mit einem WEEKDAY_DATE_RE-Treffer) zugeordnet, der
 * ihr in y am NÄCHSTEN liegt -- unabhängig davon, ob sie optisch darüber
 * oder darunter liegt (vertikal zentrierte Zellen-Umbrüche).
 */
function parsePageIntoRecords(items, headerY) {
  const rows = groupIntoRows(items).filter((r) => r.y < headerY - 1);
  if (rows.length === 0) return [];

  const anchors = []; // {y, day, month}
  for (const row of rows) {
    for (const it of row.items) {
      const m = it.text.trim().match(WEEKDAY_DATE_RE);
      if (m) {
        anchors.push({y: row.y, day: parseInt(m[1], 10), month: parseInt(m[2], 10)});
        break;
      }
    }
  }
  if (anchors.length === 0) return [];

  function nearestAnchorIndex(y) {
    let best = 0;
    let bestDist = Infinity;
    for (let i = 0; i < anchors.length; i++) {
      const d = Math.abs(anchors[i].y - y);
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  // Items je Anker sammeln (Reihenfolge bleibt y-absteigend erhalten,
  // weil `rows` bereits so sortiert ist und wir sie in dieser
  // Reihenfolge durchgehen).
  const itemsPerAnchor = anchors.map(() => []);
  for (const row of rows) {
    const idx = nearestAnchorIndex(row.y);
    for (const it of row.items) itemsPerAnchor[idx].push(it);
  }

  const records = [];
  for (let i = 0; i < anchors.length; i++) {
    const rec = buildRecordFromItems(itemsPerAnchor[i]);
    records.push({day: anchors[i].day, month: anchors[i].month, ...rec});
  }
  return records;
}

/**
 * Extrahiert alle Records aus einem PDF-Buffer.
 * Gibt {records, warnings} zurück.
 */
async function extractAllRecords(pdfBuffer) {
  const pdfjsLib = await import("pdfjs-dist/legacy/build/pdf.mjs");
  const loadingTask = pdfjsLib.getDocument({
    data: new Uint8Array(pdfBuffer),
    useSystemFonts: true,
  });
  const doc = await loadingTask.promise;

  let headerY = null;
  const records = [];
  const warnings = [];

  for (let p = 1; p <= doc.numPages; p++) {
    const page = await doc.getPage(p);
    const content = await page.getTextContent();
    const items = content.items
        .map((it) => ({text: it.str, x: it.transform[4], y: it.transform[5]}))
        .filter((it) => it.text.length > 0)
        .filter((it) => !isNoiseText(it.text));

    if (headerY === null) {
      const header = findHeaderColumns(items);
      if (!header) {
        warnings.push({page: p, reason: "kein-header-gefunden"});
        continue;
      }
      headerY = header.headerY;
      console.log("[festlliste-parser] Header gefunden auf Seite", p, "bei y=", headerY, "Spalten (nur Info, nicht mehr für Zuordnung genutzt):", JSON.stringify(header.columns));
    }

    const pageRecords = parsePageIntoRecords(items, headerY);
    for (const rec of pageRecords) {
      if (!rec.name || !rec.kategorie) {
        warnings.push({page: p, reason: "unvollstaendiger-record", raw: rec});
        continue;
      }
      records.push(rec);
    }
  }

  if (headerY === null) {
    throw new Error(
        "Tabellen-Header (Datum/Veranstaltungsname/.../Bezirk) wurde auf " +
        "keiner Seite gefunden. Layout der Quelle hat sich vermutlich " +
        "geändert.",
    );
  }

  return {records, warnings};
}

module.exports = {extractAllRecords, groupIntoRows, findHeaderColumns, classifyItem};
