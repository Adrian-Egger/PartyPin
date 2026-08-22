// =======================
// functions/festlliste/extractRecords.js
// =======================
/* eslint-disable */
//
// Liest die "Festl-Liste - Gesamtübersicht" PDF (Quelle: linkrex.eu/@
// festlliste -> Dropbox-Link) und extrahiert strukturierte Event-Records.
//
// WARUM KOORDINATEN-BASIERT STATT REINEM TEXT-PARSING:
// Die PDF ist eine Tabelle mit 6 Spalten (Datum, Veranstaltungsname,
// Veranstaltungsort, Kategorie, Bezirk, Link). JEDE dieser Spalten kann
// über mehrere Zeilen umbrechen (lange Namen, lange Ortsnamen, lange
// Kategorien wie "Oktoberfest / Volksfest", lange Bezirksnamen, lange
// URLs). Reiner linearer Text böte keine zuverlässige Grenze zwischen
// z.B. einem umgebrochenen Namen und dem folgenden Ort.
//
// Lösung: `pdfjs-dist` liefert pro Textfragment die exakte x/y-Position
// auf der Seite. Wir lesen EINMALIG die Kopfzeile ("Datum",
// "Veranstaltungsname", ...) auf Seite 1 und merken uns deren
// x-Positionen als Spaltengrenzen. Jedes weitere Textfragment (auf allen
// Seiten) wird anhand seiner x-Position der nächstgelegenen Spalte
// zugeordnet — unabhängig davon, ob es in derselben visuellen Zeile wie
// der Datums-Wert steht oder eine Umbruch-Fortsetzungszeile ist. Eine
// neue Zeile OHNE Datum wird als Fortsetzung der vorherigen Spalten
// gewertet und an die jeweilige Spalte angehängt.
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
    // Mindestens 5 der 6 Spalten müssen erkannt sein (Link fehlt manchmal
    // in älteren Layouts) -> als Kopfzeile akzeptieren.
    if (Object.keys(found).length >= 5) {
      return {headerY: row.y, columns: found};
    }
  }
  return null;
}

function assignColumn(x, columnBounds) {
  let best = columnBounds[0].key;
  for (const c of columnBounds) {
    if (x + 1 >= c.x) best = c.key;
    else break;
  }
  return best;
}

function buildRowCells(row, columnBounds) {
  // WICHTIG: Items werden OHNE künstlich eingefügte Leerzeichen
  // aneinandergehängt (nur sortiert nach x). PDF-Text-Extraktion liefert
  // echte Leerzeichen meist als eigene Text-Fragmente ("text": " ") --
  // die sind in `row.items` bereits enthalten. Würden wir stattdessen
  // pauschal mit " " joinen, bekämen in mehrere Glyph-Runs aufgeteilte
  // Wörter (z.B. durch Kerning/Umlaute) fälschlich ein Leerzeichen
  // mitten im Wort.
  const cells = {datum: [], name: [], ort: [], kategorie: [], bezirk: [], link: []};
  for (const it of row.items) {
    const col = assignColumn(it.x, columnBounds);
    if (cells[col]) cells[col].push(it.text);
  }
  const out = {};
  for (const k of Object.keys(cells)) {
    out[k] = cells[k].join("").replace(/\s+/g, " ").trim();
  }
  return out;
}

// Hängt `addition` an `base` an. Wenn `base` mit "-" endet (typischer
// PDF-Silbentrennungs-Umbruch, z.B. "Wels-" + "Stadt"), OHNE Leerzeichen
// verbinden, sonst mit Leerzeichen. Für `link` (URLs) NIE ein Leerzeichen
// einfügen.
function appendContinuation(base, addition, {noSpace = false} = {}) {
  if (!addition) return base;
  if (!base) return addition;
  // Silbentrennungs-Umbruch mitten im Wort (z.B. "Wels-" + "Stadt")
  // erkennen wir daran, dass UNMITTELBAR vor dem "-" ein Buchstabe ohne
  // Leerzeichen steht. "OÖ -" (Bezirks-Trennzeichen mit Leerzeichen davor)
  // bekommt dagegen ganz normal ein Leerzeichen vor der Fortsetzung.
  const midWordHyphen = /\S-$/.test(base) && !/\s-$/.test(base);
  if (noSpace || midWordHyphen) return base + addition;
  return base + " " + addition;
}

function parsePageIntoRecords(items, columnBounds, headerY) {
  const rows = groupIntoRows(items).filter((r) => r.y < headerY - 1);
  const cellRows = rows.map((r) => buildRowCells(r, columnBounds));

  const records = [];
  let current = null;
  for (const cell of cellRows) {
    const isNewRecord = WEEKDAY_DATE_RE.test(cell.datum);
    if (isNewRecord) {
      if (current) records.push(current);
      const m = cell.datum.match(WEEKDAY_DATE_RE);
      current = {
        day: parseInt(m[1], 10),
        month: parseInt(m[2], 10),
        name: cell.name,
        ort: cell.ort,
        kategorie: cell.kategorie,
        bezirk: cell.bezirk,
        link: cell.link,
      };
    } else if (current) {
      current.name = appendContinuation(current.name, cell.name);
      current.ort = appendContinuation(current.ort, cell.ort);
      current.kategorie = appendContinuation(current.kategorie, cell.kategorie);
      current.bezirk = appendContinuation(current.bezirk, cell.bezirk);
      current.link = appendContinuation(current.link, cell.link, {noSpace: true});
    }
    // Zeilen ohne aktiven Record (z.B. Fußzeilentext vor dem ersten
    // Datensatz) werden stillschweigend ignoriert.
  }
  if (current) records.push(current);
  return records;
}

// Manche Zeilen sind Sonderfälle: statt eines Links steht "❌" +
// Ausfalltext (Event abgesagt) in einer der Spalten (meist Bezirk oder
// Link, je nach genauer PDF-Position des Emojis). Wir suchen deshalb in
// ALLEN Textfeldern danach, statt uns auf eine feste Spalte zu verlassen.
function extractCancellation(record) {
  const fields = ["kategorie", "bezirk", "link"];
  for (const f of fields) {
    const val = record[f] || "";
    const idx = val.indexOf("❌");
    if (idx !== -1) {
      const reason = val.slice(idx + 1).replace(/^❌\s*/, "").trim();
      record[f] = val.slice(0, idx).trim();
      return {cancelled: true, cancelReason: reason || "Abgesagt/Ausfall laut Quelle."};
    }
  }
  return {cancelled: false, cancelReason: ""};
}

/**
 * Extrahiert alle Records aus einem PDF-Buffer.
 * Gibt {records, warnings} zurück. `records` = rohe, noch nicht
 * geocodete/normalisierte Datensätze mit {day, month, name, ort,
 * kategorie, bezirk, link, cancelled, cancelReason}.
 */
async function extractAllRecords(pdfBuffer) {
  const pdfjsLib = await import("pdfjs-dist/legacy/build/pdf.mjs");
  const loadingTask = pdfjsLib.getDocument({
    data: new Uint8Array(pdfBuffer),
    // Keine externen Standard-Fonts nötig, wir lesen nur Text-Layout.
    useSystemFonts: true,
  });
  const doc = await loadingTask.promise;

  let columnBounds = null;
  let headerY = null;
  const records = [];
  const warnings = [];

  for (let p = 1; p <= doc.numPages; p++) {
    const page = await doc.getPage(p);
    const content = await page.getTextContent();
    // Nur wirklich leere ("") Fragmente verwerfen -- Fragmente, die NUR
    // aus einem Leerzeichen bestehen, werden bewusst behalten (siehe
    // buildRowCells).
    const items = content.items
        .map((it) => ({text: it.str, x: it.transform[4], y: it.transform[5]}))
        .filter((it) => it.text.length > 0);

    if (!columnBounds) {
      const header = findHeaderColumns(items);
      if (!header) {
        warnings.push({page: p, reason: "kein-header-gefunden"});
        continue;
      }
      columnBounds = Object.entries(header.columns)
          .map(([key, x]) => ({key, x}))
          .sort((a, b) => a.x - b.x);
      headerY = header.headerY;
    }

    const pageRecords = parsePageIntoRecords(items, columnBounds, headerY);
    for (const rec of pageRecords) {
      if (!rec.name || !rec.kategorie) {
        warnings.push({page: p, reason: "unvollstaendiger-record", raw: rec});
        continue;
      }
      const cancel = extractCancellation(rec);
      records.push({...rec, ...cancel});
    }
  }

  if (!columnBounds) {
    throw new Error(
        "Tabellen-Header (Datum/Veranstaltungsname/.../Bezirk) wurde auf " +
        "keiner Seite gefunden. Layout der Quelle hat sich vermutlich " +
        "geändert.",
    );
  }

  return {records, warnings};
}

module.exports = {extractAllRecords, groupIntoRows, findHeaderColumns};
