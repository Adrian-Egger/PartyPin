// lib/Screens/party/ticket_scanner_screen.dart
// Host-only: scannt QR-Codes von Tickets, validiert sie via Cloud Function
// und zeigt grünes ✅ oder rotes ❌ Overlay.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../Services/stripe_service.dart';
import '../../Theme/app_theme.dart';

class TicketScannerScreen extends StatefulWidget {
  const TicketScannerScreen({
    super.key,
    required this.partyId,
    required this.partyName,
  });

  final String partyId;
  final String partyName;

  @override
  State<TicketScannerScreen> createState() => _TicketScannerScreenState();
}

class _TicketScannerScreenState extends State<TicketScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  bool _processing = false;
  _ScanOutcome? _result;
  String? _lastCode;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing || _result != null) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final code = barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;
    if (code == _lastCode) return;
    _lastCode = code;

    setState(() => _processing = true);
    HapticFeedback.mediumImpact();

    try {
      final res = await StripeService.validateTicket(
        ticketId: code,
        partyId: widget.partyId,
      );
      final outcome = _ScanOutcome.fromResult(res);
      if (!mounted) return;
      setState(() => _result = outcome);
      HapticFeedback.heavyImpact();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _result = _ScanOutcome.error(
            e.code == 'permission-denied'
                ? 'Du bist nicht der Host dieser Party.'
                : (e.message ?? e.code),
          ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _result = _ScanOutcome.error(e.toString()));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _resetForNextScan() {
    setState(() {
      _result = null;
      _lastCode = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('Tickets scannen — ${widget.partyName}'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: ValueListenableBuilder<MobileScannerState>(
              valueListenable: _controller,
              builder: (_, state, __) => Icon(
                state.torchState == TorchState.on
                    ? Icons.flash_on_rounded
                    : Icons.flash_off_rounded,
              ),
            ),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),

          // Halbtransparenter Sucher-Rahmen
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),

          // Hint
          Positioned(
            left: 0,
            right: 0,
            bottom: 60,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'QR-Code des Tickets einscannen',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),

          // Overlay nach Scan
          if (_result != null)
            _ResultOverlay(
              outcome: _result!,
              onNext: _resetForNextScan,
              onClose: () => Navigator.of(context).pop(),
            ),

          // Loading Indicator
          if (_processing)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ResultOverlay extends StatelessWidget {
  const _ResultOverlay({
    required this.outcome,
    required this.onNext,
    required this.onClose,
  });

  final _ScanOutcome outcome;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final color = outcome.valid ? AppColors.success : AppColors.accent;
    return Positioned.fill(
      child: ColoredBox(
        color: color.withOpacity(0.92),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  outcome.valid
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  color: Colors.white,
                  size: 140,
                ),
                const SizedBox(height: 12),
                Text(
                  outcome.valid ? 'GÜLTIG' : 'UNGÜLTIG',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  outcome.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onClose,
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('Schließen'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white70),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: onNext,
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('Nächstes scannen'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: color,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanOutcome {
  _ScanOutcome._({
    required this.valid,
    required this.message,
  });

  factory _ScanOutcome.fromResult(Map<String, dynamic> r) {
    final ok = r['valid'] == true;
    if (ok) {
      final qty = r['quantity'] ?? 1;
      return _ScanOutcome._(
        valid: true,
        message: '$qty Ticket${qty == 1 ? '' : 's'} eingelöst.\n'
            'Person darf rein.',
      );
    }

    final reason = (r['reason'] ?? '').toString();
    String msg;
    switch (reason) {
      case 'already_used':
        msg = 'Dieses Ticket wurde bereits eingelöst.';
        break;
      case 'wrong_party':
        final name = (r['partyName'] ?? '').toString();
        msg = name.isEmpty
            ? 'Ticket gehört zu einer anderen Party.'
            : 'Ticket gehört zu „$name", nicht zu dieser Party.';
        break;
      case 'not_paid':
        msg = 'Ticket ist nicht (vollständig) bezahlt.';
        break;
      case 'not_found':
        msg = 'Kein Ticket mit dieser ID gefunden.';
        break;
      case 'party_not_found':
        msg = 'Party nicht gefunden.';
        break;
      default:
        msg = 'Ticket ungültig.';
    }
    return _ScanOutcome._(valid: false, message: msg);
  }

  factory _ScanOutcome.error(String err) =>
      _ScanOutcome._(valid: false, message: err);

  final bool valid;
  final String message;
}
