import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:app_links/app_links.dart';

class PayPalLoginScreen extends StatefulWidget {
  const PayPalLoginScreen({super.key});

  @override
  State<PayPalLoginScreen> createState() => _PayPalLoginScreenState();
}

class _PayPalLoginScreenState extends State<PayPalLoginScreen> {
  bool _loading = false;

  // ✅ MUSS zu den Functions passen (bei dir: europe-west1)
  final FirebaseFunctions _functions =
  FirebaseFunctions.instanceFor(region: 'europe-west1');

  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _appLinks = AppLinks();
    _listenLinks();
    _handleInitialLink();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  void _listenLinks() {
    _linkSub = _appLinks.uriLinkStream.listen((uri) async {
      await _handleUri(uri);
    });
  }

  Future<void> _handleInitialLink() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) await _handleUri(uri);
    } catch (_) {}
  }

  Future<void> _handleUri(Uri uri) async {
    if (uri.scheme != 'partypin') return;

    if (uri.host != 'paypal-return' && uri.host != 'paypal-merchant-return') {
      return;
    }

    final merchantId = uri.queryParameters['merchantIdInPayPal'] ??
        uri.queryParameters['merchantId'] ??
        uri.queryParameters['merchant_id'];

    if (merchantId == null || merchantId.isEmpty) {
      _toast('PayPal Rückgabe ohne Merchant ID.');
      return;
    }

    await _finalizeHostOnboarding(merchantId);
  }

  Future<void> _connectPayPal() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _toast('Bitte einloggen.');
      return;
    }

    setState(() => _loading = true);

    try {
      final res = await _functions
          .httpsCallable('createHostOnboardingLink')
          .call(<String, dynamic>{});

      final actionUrl =
      (res.data is Map) ? res.data['actionUrl']?.toString() : null;

      if (actionUrl == null || actionUrl.isEmpty) {
        _toast('Kein PayPal-Link erhalten.');
        return;
      }

      final ok = await launchUrl(
        Uri.parse(actionUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) _toast('Konnte PayPal nicht öffnen.');
    } catch (e) {
      _toast('PayPal Fehler: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _finalizeHostOnboarding(String merchantIdInPayPal) async {
    setState(() => _loading = true);

    try {
      final res = await _functions
          .httpsCallable('finalizeHostOnboarding')
          .call(<String, dynamic>{
        'merchantIdInPayPal': merchantIdInPayPal,
      });

      final ok = (res.data is Map) ? res.data['ok'] == true : false;

      if (ok) {
        _toast('PayPal verbunden ✅');
        if (mounted) Navigator.pop(context);
      } else {
        _toast('PayPal Verifizierung fehlgeschlagen.');
      }
    } catch (e) {
      _toast('Finalize Fehler: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PayPal verbinden')),
      body: Center(
        child: ElevatedButton(
          onPressed: _loading ? null : _connectPayPal,
          child: Text(_loading ? 'Bitte warten…' : 'Mit PayPal verbinden'),
        ),
      ),
    );
  }
}
