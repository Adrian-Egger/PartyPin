// lib/Services/email_verify_service.dart
//
// Generische E-Mail-Verifikation für PartyPin (Account / Profil).
//
// Verlauf: Diese Logik lebte früher in `lib/Services/stripe_service.dart`
// (`StripeService.requestEmailVerification`), weil sie damals Teil des
// Ticket-Kauf-Flows war. Nach dem Ticketing-Removal ist sie hier
// entkoppelt — siehe archived/ticketing/README.md.
//
// Die zugehörige Cloud Function (`requestEmailVerification`) wurde von
// `functions/stripe/emailVerify.js` nach `functions/email/verify.js`
// umgezogen; der Export-Name bleibt stabil.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Wandelt eine [FirebaseFunctionsException] in eine `Exception` mit
/// lesbarer Backend-Message + Code um.
Exception _readable(FirebaseFunctionsException e, String fallback) {
  if (kDebugMode) {
    debugPrint('[FirebaseFunctionsException] code=${e.code}');
    debugPrint('[FirebaseFunctionsException] message=${e.message}');
    debugPrint('[FirebaseFunctionsException] details=${e.details}');
  }
  final msg = (e.message ?? '').trim();
  if (msg.isEmpty) {
    return Exception('$fallback (${e.code})');
  }
  return Exception('$msg (${e.code})');
}

class EmailVerifyService {
  /// Fordert eine Bestätigungs-E-Mail an. Setzt `pendingEmail` + Token
  /// auf dem User-/Bar-Doc; die alte verifizierte E-Mail bleibt aktiv,
  /// bis der Klick auf den Link in der Mail eingeht.
  ///
  /// Antwort: `{ ok, alreadyVerified, expiresAtMillis? }`.
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
    try {
      final res = await fn.call(<String, dynamic>{
        'docId': docId,
        'email': email,
        'collection': collection,
      });
      return Map<String, dynamic>.from(res.data as Map);
    } on FirebaseFunctionsException catch (e) {
      throw _readable(e, 'Verifizierungs-Mail konnte nicht angefordert werden.');
    }
  }
}
