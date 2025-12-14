class PayPalPlans {
  // ✅ Deine Plan-IDs
  static const String monthly = 'P-55588718AV729883XNE6MJ5Y';

  // ✅ Dein neuer Jahres-Plan (den du genannt hast)
  static const String yearly = 'P-0WL99384633096336NE6WUSA';
}

class PayPalCheckout {
  // ✅ Deine Firebase Hosting URL zur Checkout-Seite
  static const String checkoutBaseUrl =
      'https://partypin-5dc3f.web.app/subscribe.html';

  /// Baut die URL mit Username + Plan + Cache-Buster
  static Uri buildCheckoutUri({
    required String username,
    required String plan, // "monthly" oder "yearly"
  }) {
    return Uri.parse(checkoutBaseUrl).replace(queryParameters: {
      'u': username,
      'plan': plan,
      // verhindert, dass Android/Chrome eine alte HTML cached
      'v': DateTime.now().millisecondsSinceEpoch.toString(),
    });
  }
}
