/// ===============================
/// PayPal Konfiguration – PartyPin
/// ===============================

/// Erlaubte PayPal-Pläne (LIVE)
enum PayPalPlan {
  monthly,
  yearly,
}

class PayPalPlans {
  /// LIVE Plan IDs (PayPal Dashboard → LIVE)
  static const String monthly = 'P-55588718AV729883XNE6MJ5Y';
  static const String yearly  = 'P-0WL99384633096336NE6WUSA';

  /// Gibt die richtige Plan-ID zurück
  static String idFor(PayPalPlan plan) {
    switch (plan) {
      case PayPalPlan.yearly:
        return yearly;
      case PayPalPlan.monthly:
      default:
        return monthly;
    }
  }
}

class PayPalCheckout {
  /// ✅ Firebase Hosting URL zu deiner Checkout-Seite
  /// MUSS https sein
  static const String checkoutBaseUrl =
      'https://partypin-5dc3f.web.app/subscribe.html';

  /// Baut die finale Checkout-URL
  /// Beispiel:
  /// https://partypin-5dc3f.web.app/subscribe.html?u=Adrian&plan=monthly&v=123
  static Uri buildCheckoutUri({
    required String username,
    required PayPalPlan plan,
  }) {
    if (username.trim().isEmpty) {
      throw ArgumentError('username darf nicht leer sein');
    }

    return Uri.parse(checkoutBaseUrl).replace(
      queryParameters: {
        'u': username.trim(),        // EXAKT wie Firestore username
        'plan': plan.name,           // "monthly" | "yearly"
        'v': DateTime.now()
            .millisecondsSinceEpoch
            .toString(),              // Cache-Buster
      },
    );
  }
}
