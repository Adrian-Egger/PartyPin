// functions/stripe/webhook.js
// Stripe Webhook — wird von Stripe aufgerufen, sobald die Zahlung erfolgreich war.
// Hier generieren wir den QR-Code, schreiben ihn ins Ticket-Doc und senden die E-Mail.

const { onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const QRCode = require("qrcode");
const nodemailer = require("nodemailer");
const {
  STRIPE_SECRET_KEY,
  STRIPE_WEBHOOK_SECRET,
  SMTP_USER,
  SMTP_PASSWORD,
  getStripe,
} = require("./client");

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

async function generateQrPngBase64(payload) {
  return await QRCode.toDataURL(payload, {
    errorCorrectionLevel: "H",
    margin: 2,
    width: 512,
  });
}

async function sendTicketEmail({ to, ticket, qrDataUrl }) {
  const user = (SMTP_USER.value() || "").trim();
  const pass = (SMTP_PASSWORD.value() || "").trim();
  if (!user || !pass) {
    console.warn("[stripe webhook] SMTP secrets fehlen — keine Mail gesendet.");
    return;
  }

  const transporter = nodemailer.createTransport({
    service: "gmail",
    auth: { user, pass },
  });

  const base64 = qrDataUrl.split(",")[1];
  const totalEur = (ticket.totalAmountCents / 100).toFixed(2);

  const html = `
    <div style="font-family:Arial,sans-serif;color:#222">
      <h2 style="color:#e53e3e">Dein PartyPin Ticket 🎉</h2>
      <p>Hi! Hier ist dein Ticket für <strong>${ticket.partyName}</strong>.</p>
      <p>
        <strong>Anzahl:</strong> ${ticket.quantity}<br>
        <strong>Gesamt:</strong> ${totalEur} €<br>
        <strong>Ticket-ID:</strong> ${ticket.ticketId}
      </p>
      <p>Zeig diesen QR-Code beim Einlass — oder öffne ihn in der App unter „Meine Tickets".</p>
      <img src="cid:ticketqr" alt="QR-Code" style="width:240px;height:240px;border:1px solid #ddd;border-radius:8px"/>
      <p style="color:#888;font-size:12px;margin-top:24px">PartyPin · mypartypin@gmail.com</p>
    </div>
  `;

  await transporter.sendMail({
    from: `"PartyPin" <${user}>`,
    to,
    subject: `Dein Ticket für ${ticket.partyName}`,
    html,
    attachments: [
      {
        filename: "ticket-qr.png",
        content: base64,
        encoding: "base64",
        cid: "ticketqr",
      },
    ],
  });
}

/**
 * stripeWebhook (HTTPS, RAW body!) — registriere diese URL im Stripe-Dashboard.
 *   https://europe-west1-<project>.cloudfunctions.net/stripeWebhook
 * Events: payment_intent.succeeded, payment_intent.payment_failed
 */
exports.stripeWebhook = onRequest(
  {
    region: "europe-west1",
    secrets: [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, SMTP_USER, SMTP_PASSWORD],
  },
  async (req, res) => {
    const stripe = getStripe();
    const sig = req.headers["stripe-signature"];
    const whSecret = (STRIPE_WEBHOOK_SECRET.value() || "").trim();

    let event;
    try {
      // Firebase Functions liefert raw body in req.rawBody
      event = stripe.webhooks.constructEvent(req.rawBody, sig, whSecret);
    } catch (err) {
      console.error("Webhook signature failed:", err.message);
      return res.status(400).send(`Webhook Error: ${err.message}`);
    }

    try {
      switch (event.type) {
        case "payment_intent.succeeded": {
          const pi = event.data.object;
          const ticketId = pi.metadata?.ticketId;
          if (!ticketId) {
            console.warn("payment_intent.succeeded ohne ticketId metadata", pi.id);
            break;
          }

          const ticketRef = db.collection("tickets").doc(ticketId);
          const snap = await ticketRef.get();
          if (!snap.exists) {
            console.warn("Ticket nicht gefunden:", ticketId);
            break;
          }
          const ticket = snap.data();
          if (ticket.status === "paid") break; // idempotent

          // QR-Code-Inhalt: ticketId (am Einlass scant der Host das, prüft Status in Firestore)
          const qrDataUrl = await generateQrPngBase64(ticketId);

          await ticketRef.set(
            {
              status: "paid",
              paidAt: FieldValue.serverTimestamp(),
              qrCodeDataUrl: qrDataUrl,
            },
            { merge: true }
          );

          // ticketsSold counter erhöhen
          const partyRef = db.collection("Party").doc(ticket.partyId);
          await partyRef.set(
            { ticketsSold: FieldValue.increment(ticket.quantity) },
            { merge: true }
          );

          // Mail senden (Best-Effort, blockt nicht den 200er)
          try {
            await sendTicketEmail({
              to: ticket.buyerEmail,
              ticket: { ...ticket, ticketId },
              qrDataUrl,
            });
          } catch (e) {
            console.error("Ticket-Mail fehlgeschlagen:", e.message);
          }
          break;
        }

        case "payment_intent.payment_failed": {
          const pi = event.data.object;
          const ticketId = pi.metadata?.ticketId;
          if (ticketId) {
            await db.collection("tickets").doc(ticketId).set(
              {
                status: "failed",
                failedAt: FieldValue.serverTimestamp(),
                failureReason: pi.last_payment_error?.message || "unknown",
              },
              { merge: true }
            );
          }
          break;
        }

        default:
          // andere Events ignorieren
          break;
      }
    } catch (e) {
      console.error("Webhook handler error:", e);
      // 200 trotzdem zurück, damit Stripe nicht endlos retried
    }

    return res.status(200).send("ok");
  }
);
