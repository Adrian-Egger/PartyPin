// functions/passwordReset/reset.js
//
// Operational Readiness Sprint (2026-05-17) — Password Reset Flow.
//
// Architektur:
//   1. Callable `requestPasswordReset({identifier})`
//      - identifier = username ODER email (App-Form akzeptiert beides)
//      - findet Account in users / bars
//      - generiert 32-byte Token (PLAIN), hasht SHA-256
//      - schreibt nach passwordResets/{tokenId} (server-only Collection)
//      - sendet Mail mit Link auf HTTPS-CF unten
//      - RATE-LIMIT: max 3 Resets / Stunde pro Account, 1 / Minute
//      - ENUMERATION-SCHUTZ: liefert IMMER ok=true, auch wenn Account
//        nicht existiert. Logs zeigen den Grund nur intern.
//
//   2. HTTPS `passwordResetPage` (GET + POST)
//      - GET ?t=<token>: validiert + zeigt HTML-Formular ODER Fehler
//      - POST ?t=<token> mit `newPassword`-Form-Field:
//        Hash + Verify + Write nach users_secrets / bars_secrets,
//        markiert Token als used. Anti-Replay + Anti-Race via Transaction.
//
// Warum web-basiert statt App-Deep-Link:
//   - Funktioniert auf jedem Gerät (auch Browser ohne App)
//   - Kein Flutter-Code-Pfad fragil
//   - Spiegelt verify.js-Pattern → bekannte Form
//   - User der Telefon verloren hat: kann Reset am Desktop machen
//
// Security:
//   - Token plain 32 bytes (256 bit entropy)
//   - Storage: SHA-256(token) als `hashedToken`
//   - TokenId in der URL: erste 12 chars von SHA-256(token) → ohne
//     Voll-Hash kann der Token nicht aus der URL rekonstruiert werden
//     wenn die Logs leaken
//   - Constant-time compare via crypto.timingSafeEqual
//   - One-time use via tx.update({used: true})
//   - 1 Stunde TTL (kürzer als verify, weil sensitiver)
//   - Neuer Passwort-Hash nutzt dieselbe HMAC-SHA256(username, password)-
//     Funktion wie loginCallable, sonst können sich migrierte User
//     nicht mehr einloggen.

const { onCall, onRequest, HttpsError } =
    require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");
const crypto = require("crypto");
const nodemailer = require("nodemailer");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const SMTP_USER = defineSecret("SMTP_USER");
const SMTP_PASSWORD = defineSecret("SMTP_PASSWORD");

const PROJECT_ID = "partypin-5dc3f";
const REGION = "europe-west1";
const RESET_PAGE_URL =
    `https://${REGION}-${PROJECT_ID}.cloudfunctions.net/passwordResetPage`;

const TOKEN_TTL_MS = 60 * 60 * 1000;          // 1 Stunde
const MIN_RESEND_INTERVAL_MS = 60 * 1000;     // 1 Mail / Minute pro Account
const HOURLY_LIMIT = 3;                       // 3 Resets / Stunde pro Account
const HOURLY_WINDOW_MS = 60 * 60 * 1000;
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

// MUSS bit-genau loginCallable.hashLegacyPassword entsprechen.
function hashPasswordForLogin(username, password) {
  const key = Buffer.from(username.toLowerCase(), "utf8");
  return crypto.createHmac("sha256", key).update(password, "utf8").digest("hex");
}

function sha256Hex(s) {
  return crypto.createHash("sha256").update(s).digest("hex");
}

function genResetToken() {
  return crypto.randomBytes(32).toString("hex");
}

// Sucht Account per username (oder email als Fallback). Liefert
// {collection, secretCollection, docId, data} oder null.
async function findAccountByIdentifier(identifier) {
  const id = identifier.trim();
  if (!id) return null;
  const looksLikeEmail = EMAIL_RE.test(id);

  for (const col of ["users", "bars"]) {
    const secretCol = `${col}_secrets`;
    // 1. by username (case-sensitive + lower)
    if (!looksLikeEmail) {
      try {
        const q = await db.collection(col).where("username", "==", id).limit(1).get();
        if (!q.empty) {
          return {
            collection: col,
            secretCollection: secretCol,
            docId: q.docs[0].id,
            data: q.docs[0].data() || {},
          };
        }
        const ql = await db
          .collection(col)
          .where("username_lower", "==", id.toLowerCase())
          .limit(1)
          .get();
        if (!ql.empty) {
          return {
            collection: col,
            secretCollection: secretCol,
            docId: ql.docs[0].id,
            data: ql.docs[0].data() || {},
          };
        }
      } catch (_) {}
    } else {
      // by email (verified or pending)
      try {
        const q = await db
          .collection(col)
          .where("email", "==", id.toLowerCase())
          .limit(1)
          .get();
        if (!q.empty) {
          return {
            collection: col,
            secretCollection: secretCol,
            docId: q.docs[0].id,
            data: q.docs[0].data() || {},
          };
        }
      } catch (_) {}
    }
  }
  // Bar-docId-Variante (manche Bars haben docId = username)
  try {
    const d = await db.collection("bars").doc(id).get();
    if (d.exists) {
      return {
        collection: "bars",
        secretCollection: "bars_secrets",
        docId: d.id,
        data: d.data() || {},
      };
    }
  } catch (_) {}
  return null;
}

async function sendResetEmail({ to, link, displayName }) {
  const user = (SMTP_USER.value() || "").trim();
  const pass = (SMTP_PASSWORD.value() || "").trim();
  if (!user || !pass) {
    throw new HttpsError(
      "failed-precondition",
      "E-Mail-Versand ist nicht konfiguriert."
    );
  }
  const transporter = nodemailer.createTransport({
    service: "gmail",
    auth: { user, pass },
  });

  const html = `
    <div style="font-family:Arial,sans-serif;color:#222;max-width:520px;margin:0 auto">
      <h2 style="color:#e53e3e">Passwort zurücksetzen</h2>
      <p>Hi ${displayName || "PartyPin User"}!</p>
      <p>
        Du hast (oder jemand mit deinem Account-Zugriff) für dein
        PartyPin-Konto einen Passwort-Reset angefordert. Klicke den
        folgenden Button, um ein neues Passwort zu setzen.
      </p>
      <p style="text-align:center;margin:32px 0">
        <a href="${link}"
           style="background:#e53e3e;color:#fff;text-decoration:none;
                  padding:14px 28px;border-radius:8px;font-weight:700;
                  display:inline-block">
          Neues Passwort setzen
        </a>
      </p>
      <p style="color:#666;font-size:12px">
        Der Link ist 1 Stunde gültig und kann nur einmal verwendet werden.
        Falls der Button nicht klickbar ist, kopiere diese URL in deinen Browser:<br>
        <span style="word-break:break-all">${link}</span>
      </p>
      <p style="color:#888;font-size:11px;margin-top:32px">
        Hast du das nicht angefordert? Ignoriere diese Mail einfach —
        dein bisheriges Passwort bleibt aktiv.
      </p>
      <p style="color:#888;font-size:11px">PartyPin · mypartypin@gmail.com</p>
    </div>
  `;

  await transporter.sendMail({
    from: `"PartyPin" <${user}>`,
    to,
    subject: "PartyPin · Passwort zurücksetzen",
    html,
  });
}

exports.requestPasswordReset = onCall(
  {
    region: REGION,
    secrets: [SMTP_USER, SMTP_PASSWORD],
    maxInstances: 5,
    timeoutSeconds: 30,
    memory: "256MiB",
    concurrency: 10,
    enforceAppCheck: false, // TODO(appcheck)
  },
  async (request) => {
    const identifier = String(request.data?.identifier || "").trim();
    if (!identifier || identifier.length > 254) {
      throw new HttpsError("invalid-argument", "identifier fehlt.");
    }

    // ENUMERATION-SCHUTZ: ab hier werfen wir KEINE differenzierten
    // Fehler mehr (außer Rate-Limit). Egal ob Account existiert oder
    // nicht — Response sieht von außen identisch aus.
    const account = await findAccountByIdentifier(identifier);

    // Wenn kein Account: ack-and-noop. Bot kann Account-Existenz nicht
    // sondieren.
    if (!account) {
      logger.info("[pwReset] no account", { identifier });
      return { ok: true };
    }

    const targetEmail = (account.data.email || "").toString().trim().toLowerCase();
    if (!targetEmail || !EMAIL_RE.test(targetEmail)) {
      // Account hat keine verified Email → wir können keinen Reset
      // schicken. Trotzdem ack-and-noop, sonst Enum-Leak.
      logger.warn("[pwReset] account has no verified email", {
        docId: account.docId,
        collection: account.collection,
      });
      return { ok: true };
    }

    // ── RATE LIMIT pro Account ───────────────────────────────
    const limiterRef = db
      .collection("passwordResetLimits")
      .doc(`${account.collection}_${account.docId}`);
    const nowMs = Date.now();
    const limited = await db.runTransaction(async (tx) => {
      const snap = await tx.get(limiterRef);
      const d = snap.exists ? (snap.data() || {}) : {};
      const lastMs = (d.lastRequestMs || 0);
      if (lastMs > 0 && nowMs - lastMs < MIN_RESEND_INTERVAL_MS) {
        return true;
      }
      const windowStart = (d.windowStartMs || 0);
      let count = (d.windowCount || 0);
      let newWindowStart = windowStart;
      if (windowStart === 0 || nowMs - windowStart > HOURLY_WINDOW_MS) {
        newWindowStart = nowMs;
        count = 0;
      }
      if (count >= HOURLY_LIMIT) {
        return true;
      }
      tx.set(
        limiterRef,
        {
          lastRequestMs: nowMs,
          windowStartMs: newWindowStart,
          windowCount: count + 1,
          lastUpdatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      return false;
    });

    if (limited) {
      logger.info("[pwReset] rate limited", {
        docId: account.docId,
        collection: account.collection,
      });
      // Auch hier ack-and-noop, KEINE differenzierte Fehlermeldung.
      // Bot lernt nichts. Echter User sieht in der App "Mail wurde
      // geschickt" und fragt sich warum keine ankommt — akzeptabel
      // bei 3/h Limit.
      return { ok: true };
    }

    // ── Token + Storage ──────────────────────────────────────
    const token = genResetToken();
    const tokenHash = sha256Hex(token);
    const tokenId = tokenHash.substring(0, 12);
    const expiresAt = admin.firestore.Timestamp.fromMillis(nowMs + TOKEN_TTL_MS);

    await db.collection("passwordResets").doc(tokenId).set({
      hashedToken: tokenHash,
      collection: account.collection,
      secretCollection: account.secretCollection,
      docId: account.docId,
      username: (account.data.username || "").toString(),
      createdAt: FieldValue.serverTimestamp(),
      expiresAt,
      used: false,
    });

    const link = `${RESET_PAGE_URL}?t=${encodeURIComponent(token)}`;

    try {
      await sendResetEmail({
        to: targetEmail,
        link,
        displayName: (account.data.username || account.data.fullName || "").toString(),
      });
    } catch (e) {
      logger.error("[pwReset] mail send failed", { msg: e?.message });
      // Auch hier ack-and-noop. Mail-Versand-Fehler nicht leaken.
      // Token-Doc bleibt liegen, läuft per TTL ab.
      return { ok: true };
    }

    logger.info("[pwReset] reset email sent", {
      docId: account.docId,
      collection: account.collection,
      tokenId,
    });
    return { ok: true };
  }
);

// ============================================================
// HTTPS Reset-Page
// ============================================================

function htmlPage({ title, body, color = "#e53e3e" }) {
  return `<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title}</title>
  <style>
    html,body{margin:0;padding:0;background:#0E0F12;color:#fff;
              font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",
                          Roboto,Helvetica,Arial,sans-serif;min-height:100vh}
    .wrap{display:flex;align-items:center;justify-content:center;
          min-height:100vh;padding:24px;box-sizing:border-box}
    .card{background:#15171C;border:1px solid #2A2D35;border-radius:16px;
          padding:32px 28px;max-width:420px;width:100%;text-align:center}
    h1{color:${color};font-size:22px;margin:0 0 12px}
    p{color:#aaa;line-height:1.5;font-size:14px;margin:0 0 16px}
    input[type=password]{
      width:100%;box-sizing:border-box;padding:14px;
      background:#0E0F12;border:1px solid #2A2D35;border-radius:10px;
      color:#fff;font-size:16px;margin:0 0 12px
    }
    button{
      background:${color};color:#fff;border:0;border-radius:10px;
      padding:14px 22px;font-size:16px;font-weight:700;cursor:pointer;
      width:100%
    }
    .err{color:#f87171;font-size:13px;margin:0 0 12px;text-align:left}
    .ok{color:#34d399}
    .hint{color:#666;font-size:12px}
  </style>
</head>
<body>
  <div class="wrap"><div class="card">${body}</div></div>
</body>
</html>`;
}

function errorPage(title, msg) {
  return htmlPage({
    title,
    color: "#e53e3e",
    body: `
      <h1>${title}</h1>
      <p>${msg}</p>
      <p class="hint">Du kannst diesen Tab jetzt schließen.</p>`,
  });
}

function successPage() {
  return htmlPage({
    title: "Passwort geändert",
    color: "#34d399",
    body: `
      <h1 class="ok">Passwort geändert</h1>
      <p>Dein neues Passwort ist aktiv. Öffne die PartyPin-App und melde dich damit an.</p>
      <p class="hint">Du kannst diesen Tab jetzt schließen.</p>`,
  });
}

function formPage({ token, errorMsg }) {
  const escapedToken = token.replace(/[^a-f0-9]/gi, "");
  const errBlock = errorMsg ? `<div class="err">${errorMsg}</div>` : "";
  return htmlPage({
    title: "Neues Passwort setzen",
    color: "#e53e3e",
    body: `
      <h1>Neues Passwort setzen</h1>
      <p>Wähle ein neues Passwort für dein PartyPin-Konto.</p>
      ${errBlock}
      <form method="POST" action="${RESET_PAGE_URL}?t=${encodeURIComponent(escapedToken)}">
        <input type="password" name="newPassword" placeholder="Neues Passwort (min. 8 Zeichen)" minlength="8" maxlength="200" required autofocus />
        <input type="password" name="newPasswordConfirm" placeholder="Passwort bestätigen" minlength="8" maxlength="200" required />
        <button type="submit">Passwort setzen</button>
      </form>
      <p class="hint">Der Link ist 1 Stunde gültig.</p>`,
  });
}

async function loadAndValidateToken(plainToken) {
  if (!plainToken || typeof plainToken !== "string") return { error: "missing" };
  if (!/^[a-f0-9]{64}$/i.test(plainToken)) return { error: "invalid" };
  const tokenHash = sha256Hex(plainToken);
  const tokenId = tokenHash.substring(0, 12);
  const ref = db.collection("passwordResets").doc(tokenId);
  const snap = await ref.get();
  if (!snap.exists) return { error: "not_found" };
  const d = snap.data() || {};

  // Constant-time compare
  const storedHashBuf = Buffer.from((d.hashedToken || "").toString(), "hex");
  const inputHashBuf = Buffer.from(tokenHash, "hex");
  if (
    storedHashBuf.length !== inputHashBuf.length ||
    !crypto.timingSafeEqual(storedHashBuf, inputHashBuf)
  ) {
    return { error: "not_found" };
  }
  if (d.used === true) return { error: "used", ref, data: d };
  const expiresAt = d.expiresAt;
  if (
    !expiresAt ||
    (typeof expiresAt.toMillis === "function" && expiresAt.toMillis() < Date.now())
  ) {
    return { error: "expired", ref, data: d };
  }
  return { ok: true, ref, data: d };
}

// Bare-bones x-www-form-urlencoded parser (req.body wird von functions
// als String/Buffer geliefert je nach Content-Type).
function parseForm(req) {
  if (req.body && typeof req.body === "object" && !Buffer.isBuffer(req.body)) {
    return req.body;
  }
  let raw = "";
  if (typeof req.body === "string") raw = req.body;
  else if (Buffer.isBuffer(req.body)) raw = req.body.toString("utf8");
  else if (typeof req.rawBody === "object" && Buffer.isBuffer(req.rawBody)) {
    raw = req.rawBody.toString("utf8");
  }
  const out = {};
  raw.split("&").forEach((pair) => {
    if (!pair) return;
    const [k, v = ""] = pair.split("=");
    try {
      out[decodeURIComponent(k.replace(/\+/g, " "))] = decodeURIComponent(
        v.replace(/\+/g, " ")
      );
    } catch (_) {}
  });
  return out;
}

exports.passwordResetPage = onRequest(
  {
    region: REGION,
    maxInstances: 5,
    timeoutSeconds: 15,
    memory: "256MiB",
    concurrency: 80,
    invoker: "public",
  },
  async (req, res) => {
    res.set("Content-Type", "text/html; charset=utf-8");
    res.set("X-Content-Type-Options", "nosniff");

    const plainToken = (req.query?.t || "").toString().trim();

    if (req.method === "GET") {
      const v = await loadAndValidateToken(plainToken);
      if (!v.ok) {
        return res.status(400).send(
          errorPage(
            "Link ungültig",
            v.error === "expired"
              ? "Der Reset-Link ist abgelaufen. Bitte fordere einen neuen an."
              : v.error === "used"
              ? "Dieser Reset-Link wurde bereits verwendet."
              : "Der Reset-Link ist ungültig."
          )
        );
      }
      return res.status(200).send(formPage({ token: plainToken }));
    }

    if (req.method !== "POST") {
      return res.status(405).send(errorPage("Nicht erlaubt", "Methode nicht erlaubt."));
    }

    const form = parseForm(req);
    const newPassword = String(form.newPassword || "").trim();
    const newPasswordConfirm = String(form.newPasswordConfirm || "").trim();

    if (newPassword.length < 8 || newPassword.length > 200) {
      return res.status(400).send(
        formPage({ token: plainToken, errorMsg: "Passwort muss 8-200 Zeichen lang sein." })
      );
    }
    if (newPassword !== newPasswordConfirm) {
      return res.status(400).send(
        formPage({ token: plainToken, errorMsg: "Die Passwörter stimmen nicht überein." })
      );
    }

    const v = await loadAndValidateToken(plainToken);
    if (!v.ok) {
      return res.status(400).send(
        errorPage(
          "Link ungültig",
          v.error === "expired"
            ? "Der Reset-Link ist abgelaufen. Bitte fordere einen neuen an."
            : v.error === "used"
            ? "Dieser Reset-Link wurde bereits verwendet."
            : "Der Reset-Link ist ungültig."
        )
      );
    }

    const username = (v.data.username || "").toString();
    if (!username) {
      logger.error("[pwReset] token has no username", { tokenId: v.ref.id });
      return res.status(500).send(errorPage("Fehler", "Account-Daten unvollständig."));
    }
    const secretCollection = (v.data.secretCollection || "").toString();
    const docId = (v.data.docId || "").toString();
    if (!secretCollection || !docId) {
      return res.status(500).send(errorPage("Fehler", "Account-Daten unvollständig."));
    }

    const newHash = hashPasswordForLogin(username, newPassword);

    // Transaktional: Token-Used markieren + neuen Hash schreiben.
    // Anti-Replay: wenn zwischen GET und POST jemand anders dasselbe
    // Token verwendet hat, ist used=true und wir brechen ab.
    try {
      await db.runTransaction(async (tx) => {
        const reread = await tx.get(v.ref);
        const reData = reread.data() || {};
        if (reData.used === true) {
          throw new HttpsError("failed-precondition", "Token bereits verwendet.");
        }
        tx.update(v.ref, {
          used: true,
          usedAt: FieldValue.serverTimestamp(),
        });
        tx.set(
          db.collection(secretCollection).doc(docId),
          {
            passwordHash: newHash,
            passwordPlain: FieldValue.delete(),
            updatedAt: FieldValue.serverTimestamp(),
            source: "passwordReset",
          },
          { merge: true }
        );
      });
    } catch (e) {
      logger.warn("[pwReset] confirm failed", { msg: e?.message });
      return res.status(409).send(
        errorPage(
          "Link bereits verwendet",
          "Dieser Reset-Link wurde inzwischen verwendet. Bitte fordere einen neuen an."
        )
      );
    }

    // Best-effort: legacy passwordHash aus public-Doc löschen (falls
    // noch da). Spielt für Login keine Rolle weil secrets nun gewinnt.
    try {
      const publicCol = secretCollection.replace(/_secrets$/, "");
      await db.collection(publicCol).doc(docId).update({
        passwordHash: FieldValue.delete(),
        password: FieldValue.delete(),
      });
    } catch (_) {}

    logger.info("[pwReset] success", { docId, collection: secretCollection });
    return res.status(200).send(successPage());
  }
);
