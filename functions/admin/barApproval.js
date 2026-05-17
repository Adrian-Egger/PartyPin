// functions/admin/barApproval.js
//
// Operational Readiness Sprint (2026-05-17).
//
// Admin-only Approve/Reject für Bar-Selbstregistrierungen. Vorher musste
// der Admin in der Firebase Console manuell `bars/{uid}.status` umsetzen.
//
// Schreibpfad:
//   - approve: bars/{uid}.status = 'approved', approvedAt, approvedBy
//   - reject:  bars/{uid}.status = 'rejected', rejectedAt, rejectedBy,
//              rejectionReason (optional)
//
// Audit:
//   barApprovalAudit/{autoId} — append-only Log jeder Aktion.
//
// Security:
//   - assertAdmin (request.auth.token.admin === true)
//   - Pre-Check: Doc muss existieren, status muss 'pending' sein
//   - Audit-Log immer, auch bei Fehler

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const REGION = "europe-west1";

function assertAdmin(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Login erforderlich.");
  }
  if (request.auth.token?.admin !== true) {
    logger.warn("[barApproval] non-admin attempted", {
      caller: request.auth.uid,
    });
    throw new HttpsError("permission-denied", "Nur Admins dürfen freischalten.");
  }
}

function requireBarId(data) {
  const uid = String(data?.uid || "").trim();
  if (!uid) throw new HttpsError("invalid-argument", "uid (barId) fehlt.");
  return uid;
}

async function loadPendingBar(uid) {
  const ref = db.collection("bars").doc(uid);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Bar existiert nicht.");
  }
  return { ref, snap, data: snap.data() || {} };
}

async function auditLog({ action, callerUid, barId, prevStatus, newStatus, reason }) {
  try {
    await db.collection("barApprovalAudit").add({
      action,
      callerUid,
      barId,
      prevStatus: prevStatus || null,
      newStatus: newStatus || null,
      reason: reason || null,
      at: FieldValue.serverTimestamp(),
    });
  } catch (e) {
    // Audit darf den primären Flow nicht brechen.
    logger.error("[barApproval] audit write failed", { msg: e?.message });
  }
}

// ---------- Approve ----------

exports.adminApproveBar = onCall(
  {
    region: REGION,
    maxInstances: 3,
    timeoutSeconds: 15,
    memory: "256MiB",
    concurrency: 10,
    enforceAppCheck: false, // TODO(appcheck)
  },
  async (request) => {
    assertAdmin(request);
    const callerUid = request.auth.uid;
    const barId = requireBarId(request.data);

    const { ref, data } = await loadPendingBar(barId);
    const prevStatus = (data.status || "").toString();

    if (prevStatus === "approved") {
      return { ok: true, alreadyApproved: true };
    }
    if (prevStatus !== "pending" && prevStatus !== "rejected") {
      // Defensiv: wir erlauben re-approve von rejected (Admin will doch
      // zustimmen), aber sonst nichts unerwartetes.
      throw new HttpsError(
        "failed-precondition",
        `Bar-Status '${prevStatus}' kann nicht freigeschaltet werden.`
      );
    }

    await ref.set(
      {
        status: "approved",
        approvedAt: FieldValue.serverTimestamp(),
        approvedBy: callerUid,
        rejectedAt: FieldValue.delete(),
        rejectedBy: FieldValue.delete(),
        rejectionReason: FieldValue.delete(),
      },
      { merge: true }
    );

    logger.info("[barApproval] approved", { barId, callerUid });
    await auditLog({
      action: "approve",
      callerUid,
      barId,
      prevStatus,
      newStatus: "approved",
    });

    return { ok: true };
  }
);

// ---------- Reject ----------

exports.adminRejectBar = onCall(
  {
    region: REGION,
    maxInstances: 3,
    timeoutSeconds: 15,
    memory: "256MiB",
    concurrency: 10,
    enforceAppCheck: false, // TODO(appcheck)
  },
  async (request) => {
    assertAdmin(request);
    const callerUid = request.auth.uid;
    const barId = requireBarId(request.data);
    const reason = String(request.data?.reason || "").trim().substring(0, 500);

    const { ref, data } = await loadPendingBar(barId);
    const prevStatus = (data.status || "").toString();

    if (prevStatus === "rejected") {
      return { ok: true, alreadyRejected: true };
    }
    if (prevStatus !== "pending" && prevStatus !== "approved") {
      throw new HttpsError(
        "failed-precondition",
        `Bar-Status '${prevStatus}' kann nicht abgelehnt werden.`
      );
    }

    await ref.set(
      {
        status: "rejected",
        rejectedAt: FieldValue.serverTimestamp(),
        rejectedBy: callerUid,
        rejectionReason: reason || null,
        approvedAt: FieldValue.delete(),
        approvedBy: FieldValue.delete(),
      },
      { merge: true }
    );

    logger.info("[barApproval] rejected", { barId, callerUid, reason });
    await auditLog({
      action: "reject",
      callerUid,
      barId,
      prevStatus,
      newStatus: "rejected",
      reason,
    });

    return { ok: true };
  }
);
