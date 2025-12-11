const functions = require("firebase-functions");

// PayPal Sandbox-API Basis-URL
const PAYPAL_BASE_URL = "https://api-m.sandbox.paypal.com";

// Credentials aus firebase functions:config
const PAYPAL_CLIENT_ID = functions.config().paypal.client_id;
const PAYPAL_SECRET = functions.config().paypal.secret;

// Hilfsfunktion: Access Token von PayPal holen
async function getPayPalAccessToken() {
  const auth = Buffer.from(`${PAYPAL_CLIENT_ID}:${PAYPAL_SECRET}`).toString("base64");

  const res = await fetch(`${PAYPAL_BASE_URL}/v1/oauth2/token`, {
    method: "POST",
    headers: {
      "Authorization": `Basic ${auth}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });

  if (!res.ok) {
    const text = await res.text();
    console.error("PayPal Token Fehler:", text);
    throw new Error("Fehler beim Abrufen des PayPal Access Tokens");
  }

  const data = await res.json();
  return data.access_token;
}

// Cloud Function: Order erstellen
exports.createPayPalOrder = functions.https.onRequest(async (req, res) => {
  // CORS sehr simpel (fürs Testen)
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") {
    return res.status(204).send("");
  }

  if (req.method !== "POST") {
    return res.status(405).json({ error: "Nur POST erlaubt" });
  }

  try {
    const { amount, currency, description } = req.body;

    if (!amount || !currency) {
      return res.status(400).json({ error: "amount und currency sind Pflichtfelder" });
    }

    const accessToken = await getPayPalAccessToken();

    const orderRes = await fetch(`${PAYPAL_BASE_URL}/v2/checkout/orders`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        intent: "CAPTURE",
        purchase_units: [
          {
            amount: {
              currency_code: currency,
              value: amount,
            },
            description: description || "Payment",
          },
        ],
        application_context: {
          brand_name: "PartyPin",
          landing_page: "NO_PREFERENCE",
          user_action: "PAY_NOW",
          return_url: "https://example.com/success", // später anpassen
          cancel_url: "https://example.com/cancel",   // später anpassen
        },
      }),
    });

    if (!orderRes.ok) {
      const text = await orderRes.text();
      console.error("PayPal Order Fehler:", text);
      return res.status(500).json({ error: "Fehler beim Erstellen der PayPal Order" });
    }

    const orderData = await orderRes.json();

    let approveLink = null;

if (Array.isArray(orderData.links)) {
  const approveObj = orderData.links.find((l) => l.rel === "approve");
  if (approveObj && approveObj.href) {
    approveLink = approveObj.href;
  }
}

    return res.status(200).json({
      orderId: orderData.id,
      approveLink,
    });
  } catch (err) {
    console.error("createPayPalOrder Fehler:", err);
    return res.status(500).json({ error: "Interner Serverfehler" });
  }
});
