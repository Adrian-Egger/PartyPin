// archived/ticketing/scripts/ticket-audit.js
//
// READ-ONLY Audit-Report über den aktuellen Ticketing-Zustand in Firestore.
// Schreibt NIRGENDS. Berührt KEINE Doks. Macht nur Aggregat-Counts und
// druckt sie auf stdout.
//
// Verwendung (aus dem Projekt-Root):
//   cd functions
//   node ../archived/ticketing/scripts/ticket-audit.js
//
// Authentifizierung läuft über Application Default Credentials. Wenn du
// das Skript noch nie ausgeführt hast, einmalig:
//   gcloud auth application-default login
// (alternativ: firebase login + GOOGLE_APPLICATION_CREDENTIALS auf einen
// service-account JSON setzen)

const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "partypin-5dc3f" });
}
const db = admin.firestore();

// Same logic as functions/index.js parsePartyStart — keep behaviour consistent.
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
  let hh = 0;
  let mm = 0;
  if (timeStr.includes(":")) {
    const p = timeStr.split(":");
    hh = parseInt(p[0] || "0", 10) || 0;
    mm = parseInt(p[1] || "0", 10) || 0;
  }
  return new Date(base.getFullYear(), base.getMonth(), base.getDate(), hh, mm, 0, 0);
}

function fmt(n) {
  return String(n).padStart(5, " ");
}

async function main() {
  const now = new Date();
  console.log("");
  console.log("=== PartyPin Ticketing Audit ===");
  console.log("Stichzeit:", now.toISOString());
  console.log("Projekt:  partypin-5dc3f");
  console.log("");

  // ── Tickets-Collection ─────────────────────────────────────
  const ticketsSnap = await db.collection("tickets").get();
  const totalTickets = ticketsSnap.size;

  const byStatus = { paid: 0, pending: 0, failed: 0, other: 0 };
  let paidAndUnused = 0;
  let paidAndUsed = 0;
  let totalPaidQuantity = 0;
  let totalUnusedQuantity = 0;
  const partyIdsWithPaidUnusedTickets = new Set();

  for (const doc of ticketsSnap.docs) {
    const t = doc.data() || {};
    const status = String(t.status || "other");
    if (byStatus[status] !== undefined) byStatus[status]++;
    else byStatus.other++;

    if (status === "paid") {
      const qty = Number(t.quantity || 1);
      totalPaidQuantity += qty;
      if (t.usedAt) {
        paidAndUsed++;
      } else {
        paidAndUnused++;
        totalUnusedQuantity += qty;
        if (t.partyId) partyIdsWithPaidUnusedTickets.add(String(t.partyId));
      }
    }
  }

  console.log("Tickets-Collection (tickets/)");
  console.log("  Gesamt-Doks:                 ", fmt(totalTickets));
  console.log("  davon status=paid:           ", fmt(byStatus.paid));
  console.log("  davon status=pending:        ", fmt(byStatus.pending));
  console.log("  davon status=failed:         ", fmt(byStatus.failed));
  if (byStatus.other > 0) {
    console.log("  davon status=other/unknown:  ", fmt(byStatus.other));
  }
  console.log("  paid + bereits genutzt:      ", fmt(paidAndUsed));
  console.log("  paid + noch NICHT genutzt:   ", fmt(paidAndUnused),
              `  (Quantity-Summe: ${totalUnusedQuantity})`);
  console.log("");

  // ── Party-Collection: ticketsEnabled + zukünftig ───────────
  const partySnap = await db.collection("Party").get();
  let partiesWithTicketingEnabled = 0;
  let futurePartiesWithTicketing = 0;
  let pastPartiesWithTicketing = 0;
  const futurePartyDetails = [];

  for (const doc of partySnap.docs) {
    const p = doc.data() || {};
    if (p.ticketsEnabled !== true) continue;
    partiesWithTicketingEnabled++;

    const start = parsePartyStart(p);
    if (!start) {
      pastPartiesWithTicketing++;
      continue;
    }
    if (start.getTime() >= now.getTime()) {
      futurePartiesWithTicketing++;
      futurePartyDetails.push({
        id: doc.id,
        name: p.name || "(unbenannt)",
        start: start.toISOString(),
        sold: p.ticketsSold || 0,
        available: p.ticketsAvailable || 0,
        priceCents: p.ticketPriceCents || 0,
        hasPaidUnusedTickets: partyIdsWithPaidUnusedTickets.has(doc.id),
      });
    } else {
      pastPartiesWithTicketing++;
    }
  }

  console.log("Party-Collection (Party/, ticketsEnabled==true)");
  console.log("  Gesamt:                      ", fmt(partiesWithTicketingEnabled));
  console.log("  davon zukünftig (start>=jetzt):", fmt(futurePartiesWithTicketing));
  console.log("  davon vergangen:             ", fmt(pastPartiesWithTicketing));
  console.log("");

  if (futurePartyDetails.length > 0) {
    console.log("Zukünftige Partys mit Ticket-Verkauf (kritisch beim Tear-Down):");
    futurePartyDetails
      .sort((a, b) => (a.start < b.start ? -1 : 1))
      .forEach((p) => {
        const eur = (p.priceCents / 100).toFixed(2);
        const flag = p.hasPaidUnusedTickets ? " ⚠ unused-paid-tickets" : "";
        console.log(
          `  - ${p.start}  ${p.name}  (id=${p.id})  ` +
            `verkauft=${p.sold}/${p.available || "∞"}  preis=${eur}€${flag}`
        );
      });
    console.log("");
  }

  // ── Zusammenfassung ────────────────────────────────────────
  console.log("Zusammenfassung");
  console.log("  Offene Tickets (paid, ungenutzt): " + paidAndUnused);
  console.log("  Zukünftige Partys mit Ticketing:  " + futurePartiesWithTicketing);
  console.log("  Davon mit offenen Tickets:        " +
              futurePartyDetails.filter((p) => p.hasPaidUnusedTickets).length);
  console.log("");
  console.log("Hinweis: Dieses Skript schreibt NIRGENDS. Keine Doks angefasst.");
  console.log("");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error("Audit failed:", e);
    process.exit(1);
  });
