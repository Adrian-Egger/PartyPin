// functions/stripe/scan.js
// Validiert ein Ticket beim Einlass und markiert es atomar als "verwendet".
// Nur der Host der jeweiligen Party darf scannen.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

/**
 * validateAndUseTicket
 * Eingabe: { ticketId, partyId }
 * Ausgabe (gültig):
 *   { valid: true, quantity, partyName, buyerEmail }
 * Ausgabe (ungültig):
 *   { valid: false, reason: "not_found" | "wrong_party" | "not_paid" |
 *                   "already_used" | "party_not_found",
 *     usedAt?: number, partyName?: string, status?: string }
 */
exports.validateAndUseTicket = onCall(
  { region: "europe-west1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Not logged in.");
    }
    const uid = request.auth.uid;

    const ticketId = String(request.data?.ticketId || "").trim();
    const partyId = String(request.data?.partyId || "").trim();

    if (!ticketId) throw new HttpsError("invalid-argument", "ticketId missing.");
    if (!partyId) throw new HttpsError("invalid-argument", "partyId missing.");

    return await db.runTransaction(async (tx) => {
      const ticketRef = db.collection("tickets").doc(ticketId);
      const partyRef = db.collection("Party").doc(partyId);

      // READS zuerst
      const partySnap = await tx.get(partyRef);
      if (!partySnap.exists) {
        return { valid: false, reason: "party_not_found" };
      }

      const party = partySnap.data() || {};
      const hostUid = String(party.hostUid || party.hostId || "").trim();
      if (hostUid !== uid) {
        throw new HttpsError(
          "permission-denied",
          "Only the host can scan tickets."
        );
      }

      const ticketSnap = await tx.get(ticketRef);
      if (!ticketSnap.exists) {
        return { valid: false, reason: "not_found" };
      }

      const ticket = ticketSnap.data() || {};

      if (ticket.partyId !== partyId) {
        return {
          valid: false,
          reason: "wrong_party",
          partyName: ticket.partyName || "",
        };
      }

      if (ticket.status !== "paid") {
        return {
          valid: false,
          reason: "not_paid",
          status: ticket.status || "unknown",
        };
      }

      if (ticket.usedAt) {
        const ts = ticket.usedAt;
        return {
          valid: false,
          reason: "already_used",
          usedAt: typeof ts.toMillis === "function" ? ts.toMillis() : null,
        };
      }

      // WRITE: als verwendet markieren
      tx.set(
        ticketRef,
        {
          usedAt: FieldValue.serverTimestamp(),
          usedBy: uid,
        },
        { merge: true }
      );

      return {
        valid: true,
        quantity: ticket.quantity || 1,
        partyName: ticket.partyName || "",
        buyerEmail: ticket.buyerEmail || "",
      };
    });
  }
);
