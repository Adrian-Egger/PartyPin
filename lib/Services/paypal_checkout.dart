import 'package:url_launcher/url_launcher.dart';
import '../Services/paypal.dart';


Future<void> openPayPalCheckout({
  required String username,
  required PayPalPlan plan,
}) async {
  final uri = PayPalCheckout.buildCheckoutUri(
    username: username,
    plan: plan,
  );

  final ok = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  );

  if (!ok) {
    throw 'Konnte PayPal Checkout nicht öffnen';
  }
}
