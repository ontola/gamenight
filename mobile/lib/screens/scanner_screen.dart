import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../link.dart';
import '../theme.dart';

/// Full-screen camera that returns the first GameNight QR it sees.
/// Frames are decoded on the device; nothing is uploaded.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  String? _hint;
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final text = code.rawValue;
      if (text == null) continue;
      try {
        parseHostLink(text);
      } on LinkError catch (e) {
        setState(() => _hint = e.message);
        continue;
      }
      _done = true;
      Navigator.of(context).pop(text);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan lobby QR'), backgroundColor: GnColors.card),
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: GnColors.accent, width: 3),
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: GnColors.card.withValues(alpha: .9),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _hint ?? 'Point your camera at the QR code in the GameNight lobby.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ]),
    );
  }
}
