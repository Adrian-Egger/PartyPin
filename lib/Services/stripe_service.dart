// lib/Services/stripe_service.dart
// Stripe Init + Hilfsfunktionen für Payment Sheet & Onboarding.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as fs;

/// PUBLISHABLE KEY (kein Geheimnis — darf im Client stehen).
/// Test:  pk_test_…   Live: pk_live_…
const String kStripePublishableKey =
    'pk_test_51T07iICi3bYIGTkS0l5sCVxtfQgneLLpgVWKKLbvzMc89njxAaHLJxtJGOc67Qy3gMXwamApD1udI4iDAJ4fw99W00fNDJYnYz';

/// Merchant-Identifier für Apple Pay (im Apple Developer Portal anlegen).
const String kStripeMerchantIdentifier = 'merchant.com.partypin';

class StripeService {
  static bool _initialized = false;

  /// Einmalig im main() vor runApp() aufrufen.
  static Future<void> init() async {
    if (_initialized) return;
    fs.Stripe.publishableKey = kStripePublishableKey;
    fs.Stripe.merchantIdentifier = kStripeMerchantIdentifier;
    fs.Stripe.urlScheme = 'partypin';
    try {
      await fs.Stripe.instance.applySettings();
      _initialized = true;
    } catch (e) {
      debugPrint('Stripe init failed: $e');
    }
  }

  /// Erzeugt einen PaymentIntent via Cloud Function und öffnet das
  /// native Payment Sheet. Wirft bei Cancel/Fehler.
  /// Gibt die ticketId zurück.
  static Future<String> purchaseTickets({
    required String partyId,
    required int quantity,
    required String buyerEmail,
  }) async {
    final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable(
      'createTicketPaymentIntent',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );

    final result = await fn.call(<String, dynamic>{
      'partyId': partyId,
      'quantity': quantity,
      'buyerEmail': buyerEmail,
    });

    final data = Map<String, dynamic>.from(result.data as Map);
    final clientSecret = data['clientSecret'] as String;
    final ephemeralKey = data['ephemeralKey'] as String;
    final customerId = data['customerId'] as String;
    final ticketId = data['ticketId'] as String;

    await fs.Stripe.instance.initPaymentSheet(
      paymentSheetParameters: fs.SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        customerEphemeralKeySecret: ephemeralKey,
        customerId: customerId,
        merchantDisplayName: 'PartyPin',
        style: ThemeMode.dark,
        applePay: const fs.PaymentSheetApplePay(merchantCountryCode: 'AT'),
        googlePay: const fs.PaymentSheetGooglePay(
          merchantCountryCode: 'AT',
          currencyCode: 'EUR',
          testEnv: true,
        ),
      ),
    );

    await fs.Stripe.instance.presentPaymentSheet();
    return ticketId;
  }

  /// Onboarding-Flow für Hosts: erzeugt einen Stripe-Express-Account und
  /// gibt eine URL zurück, die du im Browser öffnest.
  static Future<String> createHostOnboardingUrl() async {
    final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('createStripeOnboardingLink');
    final res = await fn.call();
    return (res.data as Map)['url'] as String;
  }

  /// Aktualisiert in Firestore, ob der Host charges/payouts aktiviert hat.
  static Future<Map<String, dynamic>> refreshHostStatus() async {
    final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('refreshStripeAccountStatus');
    final res = await fn.call();
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Validiert ein gescanntes Ticket atomar und markiert es als verwendet.
  /// Wirft, wenn der Aufrufer nicht der Host der Party ist.
  /// Liefert { valid, reason?, quantity?, partyName?, ... }.
  static Future<Map<String, dynamic>> validateTicket({
    required String ticketId,
    required String partyId,
  }) async {
    final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable(
      'validateAndUseTicket',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
    );
    final res = await fn.call(<String, dynamic>{
      'ticketId': ticketId,
      'partyId': partyId,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Fordert eine Bestätigungs-E-Mail an. Setzt `pendingEmail` + Token
  /// auf dem User-Doc; die alte verifizierte E-Mail bleibt aktiv, bis
  /// der Klick auf den Link in der Mail eingeht.
  static Future<Map<String, dynamic>> requestEmailVerification({
    required String docId,
    required String email,
    String collection = 'users',
  }) async {
    final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable(
      'requestEmailVerification',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final res = await fn.call(<String, dynamic>{
      'docId': docId,
      'email': email,
      'collection': collection,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }
}
