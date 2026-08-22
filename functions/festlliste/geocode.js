// =======================
// functions/festlliste/geocode.js
// =======================
/* eslint-disable */
//
// Geocoding für die Festlliste-Synchronisierung. Es gibt in diesem
// Projekt keinen serverseitigen Google-Maps-Key (die Flutter-App nutzt
// das `geocoding`-Plugin, das die NATIVEN Geocoder von iOS/Android nutzt
// -- ohne API-Key, aber nur clientseitig verfügbar). Für den Cloud-
// Function-Import verwenden wir daher den kostenlosen OpenStreetMap-
// Nominatim-Dienst.
//
// WICHTIG (Nominatim Nutzungsrichtlinie, siehe
// https://operations.osmfoundation.org/policies/nominatim/):
// - Max. 1 Request/Sekunde
// - Aussagekräftiger User-Agent Header (Identifikation der App)
// - Ergebnisse cachen, nicht bei jedem Lauf neu abfragen
//
// Wir cachen deshalb jede erfolgreiche Antwort dauerhaft in Firestore
// (`_geocodeCache/{key}`), sodass wiederkehrende Orte (die absolute
// Mehrheit -- dieselbe Gemeinde taucht über das Jahr x-mal auf) nur EIN
// einziges Mal jemals bei Nominatim angefragt werden.

const NOMINATIM_URL = "https://nominatim.openstreetmap.org/search";
// Nominatim verlangt einen Kontakt/Identifikator im User-Agent, kein
// Generic-Browser-UA. Wir verweisen auf das öffentliche Repo der App.
const USER_AGENT = "PartyPinFestllisteSync/1.0 (+https://github.com/Adrian-Egger/PartyPin)";
const MIN_REQUEST_GAP_MS = 1100; // > 1 req/s Limit, mit Sicherheitsmarge

function slugKey(query) {
  return query
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[̀-ͯ]/g, "")
      .replace(/[^a-z0-9]+/g, "_")
      .replace(/^_+|_+$/g, "")
      .slice(0, 200) || "unknown";
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Erstellt einen Geocoder mit eingebautem Firestore-Cache und
 * Rate-Limiting. `db` = firestore admin instance.
 */
function createGeocoder(db) {
  let lastRequestAt = 0;
  const cacheCollection = db.collection("_geocodeCache");
  // In-Memory-Cache zusätzlich zum Firestore-Cache, damit innerhalb
  // EINES Laufs identische Orte nicht mehrfach sogar Firestore treffen.
  const memCache = new Map();

  async function geocode(query) {
    const key = slugKey(query);
    if (memCache.has(key)) return memCache.get(key);

    const cachedDoc = await cacheCollection.doc(key).get();
    if (cachedDoc.exists) {
      const data = cachedDoc.data();
      const result = data.lat != null && data.lng != null ?
        {lat: data.lat, lng: data.lng} :
        null;
      memCache.set(key, result);
      return result;
    }

    // Rate-Limit einhalten.
    const wait = MIN_REQUEST_GAP_MS - (Date.now() - lastRequestAt);
    if (wait > 0) await sleep(wait);
    lastRequestAt = Date.now();

    let result = null;
    try {
      const url = `${NOMINATIM_URL}?format=json&limit=1&countrycodes=at&q=${encodeURIComponent(query)}`;
      const resp = await fetch(url, {headers: {"User-Agent": USER_AGENT, "Accept-Language": "de"}});
      if (resp.ok) {
        const json = await resp.json();
        if (Array.isArray(json) && json.length > 0) {
          result = {lat: parseFloat(json[0].lat), lng: parseFloat(json[0].lon)};
        }
      } else {
        console.log("[geocode] Nominatim non-OK response", resp.status, query);
      }
    } catch (e) {
      console.log("[geocode] Fehler bei Anfrage:", query, e?.message || e);
    }

    // Auch NEGATIVE Treffer cachen (result=null), sonst würden künftig
    // unauffindbare Orte bei jedem Lauf erneut angefragt.
    await cacheCollection.doc(key).set({
      query,
      lat: result ? result.lat : null,
      lng: result ? result.lng : null,
      updatedAt: new Date(),
    });
    memCache.set(key, result);
    return result;
  }

  return {geocode};
}

module.exports = {createGeocoder, slugKey};
