import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../core/app_controller.dart';
import '../../core/models/connection_profile.dart';
import '../settings/message_display_controller.dart';
import 'endpoint_selection.dart';
import 'pairing_controller.dart';
import 'pairing_payload.dart';

/// QR pairing: scan the server's pairing code, preview it, then save + test.
class QrPairingScreen extends StatefulWidget {
  const QrPairingScreen({super.key});

  @override
  State<QrPairingScreen> createState() => _QrPairingScreenState();
}

class _QrPairingScreenState extends State<QrPairingScreen> {
  late final PairingController _pairing;
  final MobileScannerController _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  @override
  void initState() {
    super.initState();
    _pairing = PairingController(context.read<AppController>());
  }

  @override
  void dispose() {
    _scanner.dispose();
    _pairing.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_pairing.stage != PairingStage.scanning) return;
    String? raw;
    for (final b in capture.barcodes) {
      if ((b.rawValue ?? '').isNotEmpty) {
        raw = b.rawValue;
        break;
      }
    }
    if (raw == null) return;

    _pairing.onScan(raw);
    if (_pairing.stage == PairingStage.preview) {
      _scanner.stop();
    } else if (_pairing.message != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_pairing.message!)),
      );
    }
  }

  Future<void> _useScanned() async {
    final perChat = context.read<MessageDisplayController>().prefs.messagesPerChat;
    final ok = await _pairing.useScanned(messagesPerChat: perChat);
    if (ok && mounted) {
      context.go(Routes.home);
    }
  }

  void _scanAgain() {
    _pairing.scanAgain();
    _scanner.start();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan pairing code'),
        actions: [
          IconButton(
            tooltip: 'Toggle torch',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _scanner.toggleTorch(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _pairing,
        builder: (context, _) {
          switch (_pairing.stage) {
            case PairingStage.scanning:
              return _scannerView();
            case PairingStage.preview:
              return _PreviewPane(
                payload: _pairing.payload!,
                pairing: _pairing,
                onUse: _useScanned,
                onScanAgain: _scanAgain,
              );
            case PairingStage.testing:
              return const _CenteredStatus(
                icon: null,
                text: 'Connecting to the server…',
                showSpinner: true,
              );
            case PairingStage.failure:
              return _FailurePane(
                message: _pairing.message ?? 'Pairing failed.',
                onScanAgain: _scanAgain,
                onRetry: _useScanned,
              );
            case PairingStage.success:
              return const _CenteredStatus(
                icon: Icons.check_circle_outline,
                text: 'Paired!',
                showSpinner: false,
              );
          }
        },
      ),
    );
  }

  Widget _scannerView() {
    return Stack(
      alignment: Alignment.center,
      children: [
        MobileScanner(
          controller: _scanner,
          onDetect: _onDetect,
          errorBuilder: (context, error) => _CameraError(error: error),
        ),
        // Simple framing + hint overlay.
        IgnorePointer(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        Positioned(
          bottom: 32,
          left: 24,
          right: 24,
          child: Text(
            'Point the camera at the MicaGo pairing QR code\n'
            '(Mac app → Connections → Client Setup → Pairing QR code).',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }
}

class _CameraError extends StatelessWidget {
  final MobileScannerException error;
  const _CameraError({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48),
            const SizedBox(height: 12),
            const Text(
              'Camera unavailable',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'MicaGo needs camera access to scan the pairing code. '
              'Grant the Camera permission in Android Settings, then come back. '
              'You can also pair manually instead.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewPane extends StatelessWidget {
  final PairingPayload payload;
  final PairingController pairing;
  final VoidCallback onUse;
  final VoidCallback onScanAgain;

  const _PreviewPane({
    required this.payload,
    required this.pairing,
    required this.onUse,
    required this.onScanAgain,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.qr_code_2),
                      const SizedBox(width: 8),
                      Text('Pairing code found',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _kv(context, 'Server URL', payload.baseUrl),
                  const SizedBox(height: 6),
                  _kv(context, 'WebSocket', payload.effectiveWsUrl),
                  const SizedBox(height: 6),
                  _kv(context, 'Token', _maskedToken(payload.token)),
                  if (payload.serverName != null) ...[
                    const SizedBox(height: 6),
                    _kv(context, 'Server', payload.serverName!),
                  ],
                ],
              ),
            ),
          ),
          if (pairing.availableModes.length > 1) ...[
            const SizedBox(height: 16),
            Text('Connection mode',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final mode in pairing.availableModes)
                  ChoiceChip(
                    label: Text(connectionModeLabel(mode)),
                    selected: pairing.effectiveMode == mode,
                    onSelected: (_) => pairing.chooseMode(mode),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              pairing.effectiveMode == ConnectionMode.lanOnly
                  ? 'Connects only on your local network. Never uses the public address.'
                  : 'Tries your local network first, then the public address if LAN is unreachable.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onUse,
            icon: const Icon(Icons.check),
            label: const Text('Use this server'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onScanAgain,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan again'),
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(k,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
        ),
        Expanded(
          child: SelectableText(v,
              style: const TextStyle(fontFamily: 'monospace')),
        ),
      ],
    );
  }

  /// Masks the token (shown only as a short prefix). Never reveals it fully.
  String _maskedToken(String token) {
    if (token.isEmpty) return '—';
    final head = token.length <= 4 ? token : token.substring(0, 4);
    return '$head••••••••';
  }
}

class _FailurePane extends StatelessWidget {
  final String message;
  final VoidCallback onScanAgain;
  final VoidCallback onRetry;

  const _FailurePane({
    required this.message,
    required this.onScanAgain,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
            const SizedBox(height: 8),
            TextButton(onPressed: onScanAgain, child: const Text('Scan a different code')),
          ],
        ),
      ),
    );
  }
}

class _CenteredStatus extends StatelessWidget {
  final IconData? icon;
  final String text;
  final bool showSpinner;

  const _CenteredStatus({
    required this.icon,
    required this.text,
    required this.showSpinner,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSpinner) const CircularProgressIndicator(),
          if (icon != null) Icon(icon, size: 48),
          const SizedBox(height: 16),
          Text(text),
        ],
      ),
    );
  }
}
