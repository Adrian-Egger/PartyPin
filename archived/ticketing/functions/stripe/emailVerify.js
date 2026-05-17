// functions/stripe/emailVerify.js
// E-Mail-Verifikation über Bestätigungslink:
//   1. requestEmailVerification (Callable) — speichert pendingEmail + Token
//      auf dem User-Doc und sendet eine Bestätigungsmail mit Link.
//   2. verifyEmailToken (HTTPS)            — wird vom Klick im Mail-Link
//      aufgerufen, verschiebt pendingEmail → email und löscht den Token.

const { onCall, onRequest, HttpsError } =
    require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const crypto = require("crypto");
const nodemailer = require("nodemailer");
const { SMTP_USER, SMTP_PASSWORD } = require("./client");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const PROJECT_ID = "partypin-5dc3f";
const REGION = "europe-west1";
const VERIFY_BASE_URL =
    `https://${REGION}-${PROJECT_ID}.cloudfunctions.net/verifyEmailToken`;

const TOKEN_TTL_HOURS = 24;
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const ALLOWED_COLLECTIONS = ["users", "bars"];

// ── Rate-Limit Konstanten ──────────────────────────────────
// Stoppt Mail-Bombing: pro User max 1 Mail/Minute UND max 5/Tag.
// Quelle der Wahrheit: Felder direkt am User/Bar-Doc.
//   pendingEmailRequestedAt       → letzter Versand-Zeitpunkt
//   pendingEmailDailyCount        → Anzahl seit `pendingEmailDailyResetAt`
//   pendingEmailDailyResetAt      → Beginn des aktuellen 24h-Fensters
// Werte werden serverseitig gesetzt, der Client kann sie wegen
// Firestore-Rules (lockedUserFields) nicht selbst manipulieren.
const MIN_RESEND_INTERVAL_MS = 60 * 1000;          // 1 Mail / Minute
const DAILY_LIMIT             = 5;
const DAILY_WINDOW_MS         = 24 * 60 * 60 * 1000;

function genToken() {
  return crypto.randomBytes(32).toString("hex");
}

async function sendVerifyEmail({ to, link, displayName }) {
  const user = (SMTP_USER.value() || "").trim();
  const pass = (SMTP_PASSWORD.value() || "").trim();
  if (!user || !pass) {
    // Niemals rohen Error werfen — sonst landet das ungefangen als
    // INTERNAL beim Client. HttpsError wird vom äußeren Catch-Block
    // unverändert durchgereicht (siehe Aufrufer-Pattern).
    throw new HttpsError(
      "failed-precondition",
      "E-Mail-Versand ist serverseitig nicht konfiguriert. Bitte Support kontaktieren."
    );
  }

  const transporter = nodemailer.createTransport({
    service: "gmail",
    auth: { user, pass },
  });

  const html = `
    <div style="font-family:Arial,sans-serif;color:#222;max-width:520px;margin:0 auto">
      <h2 style="color:#e53e3e">Bestätige deine E-Mail 🎉</h2>
      <p>Hi ${displayName || "PartyPin User"}!</p>
      <p>
        Du (oder jemand mit deinem Account) hat diese Adresse als
        Kontakt-Mail für PartyPin angegeben. Klicke den folgenden Button,
        um die Adresse zu bestätigen — erst dann wird sie für den
        QR-Code-Versand bei Ticket-Käufen verwendet.
      </p>
      <p style="text-align:center;margin:32px 0">
        <a href="${link}"
           style="background:#e53e3e;color:#fff;text-decoration:none;
                  padding:14px 28px;border-radius:8px;font-weight:700;
                  display:inline-block">
          E-Mail bestätigen
        </a>
      </p>
      <p style="color:#666;font-size:12px">
        Der Link ist ${TOKEN_TTL_HOURS} Stunden gültig. Falls der Button
        nicht klickbar ist, kopiere diese URL in deinen Browser:<br>
        <span style="word-break:break-all">${link}</span>
      </p>
      <p style="color:#888;font-size:11px;margin-top:32px">
        Hast du das nicht angefordert? Ignoriere diese Mail einfach —
        deine bisherige Adresse bleibt aktiv.
      </p>
      <p style="color:#888;font-size:11px">PartyPin · mypartypin@gmail.com</p>
    </div>
  `;

  await transporter.sendMail({
    from: `"PartyPin" <${user}>`,
    to,
    subject: "Bestätige deine E-Mail für PartyPin",
    html,
  });
}

/**
 * requestEmailVerification (Callable v2)
 * Eingabe: { email, docId, collection? }
 * - Validiert Format, schreibt pendingEmail/Token/Expiry auf das User-Doc,
 *   verschickt Bestätigungsmail. Die bestehende verifizierte E-Mail
 *   (Feld `email`) bleibt unverändert.
 */
exports.requestEmailVerification = onCall(
    {
      region: REGION,
      secrets: [SMTP_USER, SMTP_PASSWORD],
      // Strenges Limit: jeder echte Versand kostet Geld + Reputation.
      maxInstances: 5,
      timeoutSeconds: 30,            // SMTP roundtrip
      memory: "256MiB",
      concurrency: 10,
      // TODO(appcheck): nach Console-Setup auf `true` setzen
      // (Original: blockiert Mail-Bombing aus dem Browser)
      enforceAppCheck: false,
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError("unauthenticated", "Login required.");
      }

      const docId = String(request.data?.docId || "").trim();
      const rawEmail = String(request.data?.email || "").trim();
      const email = rawEmail.toLowerCase();
      const collection = String(request.data?.collection || "users").trim();

      if (!docId) throw new HttpsError("invalid-argument", "docId missing.");
      if (!email || !EMAIL_RE.test(email)) {
        throw new HttpsError("invalid-argument", "invalid_email_format");
      }
      if (!ALLOWED_COLLECTIONS.includes(collection)) {
        throw new HttpsError("invalid-argument", "bad_collection");
      }

      const ref = db.collection(collection).doc(docId);
      const snap = await ref.get();
      if (!snap.exists) {
        throw new HttpsError("not-found", "user_not_found");
      }

      const data = snap.data() || {};

      // Ist die Mail bereits als verifiziert hinterlegt? Dann nichts tun.
      const currentVerified = (data.email || "").toString().toLowerCase();
      if (currentVerified === email) {
        return { ok: true, alreadyVerified: true };
      }

      // ── RATE LIMIT (server-only, Felder server-verwaltet via Rules) ──
      const nowMs = Date.now();

      // 1 Mail / Minute
      const lastReq = data.pendingEmailRequestedAt;
      const lastReqMs = (lastReq && typeof lastReq.toMillis === "function")
          ? lastReq.toMillis()
          : 0;
      if (lastReqMs > 0 && nowMs - lastReqMs < MIN_RESEND_INTERVAL_MS) {
        const wait = Math.ceil(
            (MIN_RESEND_INTERVAL_MS - (nowMs - lastReqMs)) / 1000);
        throw new HttpsError(
            "resource-exhausted",
            `Bitte ${wait} Sekunden warten, bevor du eine weitere Bestätigungs-Mail anforderst.`,
        );
      }

      // Tageslimit: aktuelles 24h-Fenster ermitteln.
      const resetTs = data.pendingEmailDailyResetAt;
      const resetMs = (resetTs && typeof resetTs.toMillis === "function")
          ? resetTs.toMillis()
          : 0;
      const windowActive = resetMs > 0 && (nowMs - resetMs) < DAILY_WINDOW_MS;
      const currentCount = windowActive
          ? Number(data.pendingEmailDailyCount || 0)
          : 0;

      if (windowActive && currentCount >= DAILY_LIMIT) {
        const remainingHours = Math.ceil(
            (DAILY_WINDOW_MS - (nowMs - resetMs)) / 3600000);
        throw new HttpsError(
            "resource-exhausted",
            `Du hast das Tageslimit von ${DAILY_LIMIT} Verifikations-Mails ` +
            `erreicht. Bitte in ${remainingHours}h erneut versuchen.`,
        );
      }

      const newCount = currentCount + 1;
      // Reset-Zeitpunkt: bleibt im aktuellen Fenster, oder startet neu.
      const newResetTs = windowActive
          ? resetTs
          : admin.firestore.Timestamp.fromMillis(nowMs);

      const token = genToken();
      const expiresAt = admin.firestore.Timestamp.fromMillis(
          nowMs + TOKEN_TTL_HOURS * 3600 * 1000,
      );

      await ref.set({
        pendingEmail: email,
        pendingEmailToken: token,
        pendingEmailExpiresAt: expiresAt,
        pendingEmailRequestedAt: FieldValue.serverTimestamp(),
        pendingEmailDailyCount: newCount,
        pendingEmailDailyResetAt: newResetTs,
      }, { merge: true });

      const link = `${VERIFY_BASE_URL}?t=${encodeURIComponent(token)}`;

      try {
        await sendVerifyEmail({
          to: email,
          link,
          displayName: data.username || data.fullName || "",
        });
      } catch (e) {
        // HttpsError aus sendVerifyEmail (z.B. failed-precondition bei
        // fehlenden Secrets) unverändert durchreichen — sonst maskieren
        // wir die lesbare Message hinter "internal/send_failed".
        if (e instanceof HttpsError) throw e;
        console.error("[requestEmailVerification] send failed:", e?.message || e);
        throw new HttpsError(
          "unavailable",
          "Verifizierungs-Mail konnte nicht versendet werden — bitte später erneut versuchen."
        );
      }

      return {
        ok: true,
        alreadyVerified: false,
        expiresAtMillis: expiresAt.toMillis(),
      };
    },
);

function htmlPage(title, message, success) {
  const color = success ? "#16a34a" : "#e53e3e";
  const icon = success ? "✅" : "⚠️";
  return `<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title}</title>
  <style>
    html,body{margin:0;padding:0;background:#0E0F12;color:#fff;
              font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",
                          Roboto,Helvetica,Arial,sans-serif;
              min-height:100vh}
    .wrap{display:flex;align-items:center;justify-content:center;
          min-height:100vh;padding:24px}
    .card{background:#15171C;border:1px solid #2A2D35;border-radius:16px;
          padding:40px 28px;max-width:420px;width:100%;text-align:center}
    .icon{font-size:64px;margin-bottom:8px}
    h1{color:${color};font-size:22px;margin:0 0 12px}
    p{color:#aaa;line-height:1.5;font-size:14px;margin:0 0 18px}
    .hint{color:#666;font-size:12px}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="icon">${icon}</div>
      <h1>${title}</h1>
      <p>${message}</p>
      <p class="hint">Du kannst diesen Tab jetzt schließen und zur PartyPin-App zurückkehren.</p>
    </div>
  </div>
</body>
</html>`;
}

/**
 * verifyEmailToken (HTTPS)
 * GET /verifyEmailToken?t=<token>
 *  - Sucht den Token in users + bars
 *  - Prüft Expiry, verschiebt pendingEmail → email
 *  - Liefert eine HTML-Seite mit Erfolg/Fehler
 */
// verifyEmailToken ist der Link aus der Mail — wird im Browser eines
// Users geöffnet und hat KEINEN App Check Token. Hier nur Limits.
exports.verifyEmailToken = onRequest(
    {
      region: REGION,
      maxInstances: 5,        // Mail-Klick-Volumen ist sehr niedrig
      timeoutSeconds: 15,
      memory: "256MiB",
      concurrency: 80,
      // KEIN enforceAppCheck — wird aus dem Mail-Client geöffnet.
      invoker: "public",
    },
    async (req, res) => {
      const token = (req.query?.t || "").toString().trim();
      if (!token) {
        return res
            .status(400)
            .set("Content-Type", "text/html; charset=utf-8")
            .send(htmlPage(
                "Ungültiger Link",
                "Der Bestätigungslink ist unvollständig.",
                false,
            ));
      }

      let userDoc = null;
      let userRef = null;
      for (const col of ALLOWED_COLLECTIONS) {
        const q = await db.collection(col)
            .where("pendingEmailToken", "==", token)
            .limit(1)
            .get();
        if (!q.empty) {
          userDoc = q.docs[0];
          userRef = userDoc.ref;
          break;
        }
      }

      if (!userDoc) {
        return res
            .status(404)
            .set("Content-Type", "text/html; charset=utf-8")
            .send(htmlPage(
                "Link ungültig",
                "Dieser Link ist nicht (mehr) gültig oder wurde bereits verwendet.",
                false,
            ));
      }

      const data = userDoc.data() || {};
      const expiresAt = data.pendingEmailExpiresAt;
      const isExpired = !expiresAt ||
          (typeof expiresAt.toMillis === "function" &&
              expiresAt.toMillis() < Date.now());

      if (isExpired) {
        await userRef.set({
          pendingEmail: FieldValue.delete(),
          pendingEmailToken: FieldValue.delete(),
          pendingEmailExpiresAt: FieldValue.delete(),
          pendingEmailRequestedAt: FieldValue.delete(),
        }, { merge: true });

        return res
            .status(410)
            .set("Content-Type", "text/html; charset=utf-8")
            .send(htmlPage(
                "Link abgelaufen",
                "Dieser Bestätigungslink ist nicht mehr gültig. " +
                "Bitte fordere in der App eine neue Bestätigungs-E-Mail an.",
                false,
            ));
      }

      const newEmail = (data.pendingEmail || "").toString().trim();
      if (!newEmail) {
        return res
            .status(404)
            .set("Content-Type", "text/html; charset=utf-8")
            .send(htmlPage(
                "Keine ausstehende Anfrage",
                "Es gibt keine ausstehende E-Mail zum Bestätigen.",
                false,
            ));
      }

      await userRef.set({
        email: newEmail,
        emailVerifiedAt: FieldValue.serverTimestamp(),
        pendingEmail: FieldValue.delete(),
        pendingEmailToken: FieldValue.delete(),
        pendingEmailExpiresAt: FieldValue.delete(),
        pendingEmailRequestedAt: FieldValue.delete(),
      }, { merge: true });

      return res
          .status(200)
          .set("Content-Type", "text/html; charset=utf-8")
          .send(htmlPage(
              "E-Mail bestätigt!",
              `Deine Adresse <strong>${newEmail}</strong> ist jetzt aktiv ` +
                  "und wird für QR-Codes bei Ticket-Käufen verwendet.",
              true,
          ));
    },
);
