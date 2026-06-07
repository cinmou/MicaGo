import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../core/app_controller.dart';
import '../../core/models/connection_profile.dart';
import '../../core/network/endpoint_utils.dart';
import 'connection_controller.dart';

/// Manual connection setup: server URL, bearer token, optional WebSocket URL.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  final _wsCtrl = TextEditingController();
  bool _obscureToken = true;

  late final ConnectionController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ConnectionController(context.read<AppController>());
    // Pre-fill from an existing profile when editing.
    final existing = _controller.app.profile;
    if (existing != null) {
      _baseUrlCtrl.text = existing.baseUrl;
      _tokenCtrl.text = existing.token;
      _wsCtrl.text = existing.wsUrlOverride ?? '';
    }
    _baseUrlCtrl.addListener(() => setState(() {}));
    _wsCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _baseUrlCtrl.dispose();
    _tokenCtrl.dispose();
    _wsCtrl.dispose();
    super.dispose();
  }

  ConnectionProfile _buildProfile() {
    return ConnectionProfile(
      baseUrl: normalizeBaseUrl(_baseUrlCtrl.text),
      token: _tokenCtrl.text.trim(),
      wsUrlOverride: _wsCtrl.text.trim().isEmpty ? null : _wsCtrl.text.trim(),
    );
  }

  String get _derivedWs {
    final base = _baseUrlCtrl.text.trim();
    if (base.isEmpty) return '';
    return deriveWebSocketUrl(base);
  }

  Future<void> _onTest() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    await _controller.test(_buildProfile());
  }

  Future<void> _onSave() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await _controller.save(_buildProfile());
    if (!mounted) return;
    context.go(Routes.home);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to MicaGo')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _BrandHeader(),
                    const SizedBox(height: 24),
                    // QR is the recommended pairing path.
                    FilledButton.icon(
                      onPressed: () => context.push(Routes.pair),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan QR code'),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text('or enter manually',
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _baseUrlCtrl,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Server URL',
                        hintText: 'https://mica.example.com',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      validator: (v) => isValidHttpUrl(v ?? '')
                          ? null
                          : 'Enter a valid http(s) URL',
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _tokenCtrl,
                      obscureText: _obscureToken,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Bearer token',
                        prefixIcon: const Icon(Icons.key_outlined),
                        suffixIcon: IconButton(
                          tooltip: _obscureToken ? 'Show' : 'Hide',
                          icon: Icon(_obscureToken
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () =>
                              setState(() => _obscureToken = !_obscureToken),
                        ),
                      ),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'Token is required'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _wsCtrl,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'WebSocket URL (optional)',
                        helperMaxLines: 2,
                        helperText: _wsCtrl.text.trim().isEmpty
                            ? (_derivedWs.isEmpty
                                ? 'Auto-derived from the server URL.'
                                : 'Auto: $_derivedWs')
                            : null,
                        prefixIcon: const Icon(Icons.cable_outlined),
                      ),
                    ),
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      onPressed: _controller.state == TestState.testing
                          ? null
                          : _onTest,
                      icon: _controller.state == TestState.testing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering),
                      label: const Text('Test connection'),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _onSave,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save & continue'),
                    ),
                    const SizedBox(height: 16),
                    _TestResult(controller: _controller),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.bolt, color: scheme.onPrimaryContainer),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MicaGo', style: Theme.of(context).textTheme.headlineSmall),
            Text(
              'Connect to your relay server',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TestResult extends StatelessWidget {
  final ConnectionController controller;
  const _TestResult({required this.controller});

  @override
  Widget build(BuildContext context) {
    if (controller.state == TestState.idle ||
        controller.state == TestState.testing) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final ok = controller.state == TestState.success;
    final color = ok ? scheme.primary : scheme.error;
    return Card(
      color: (ok ? scheme.primaryContainer : scheme.errorContainer)
          .withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
                color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(controller.message ?? ''),
                  if (controller.urlsPreview?.public?.enabled == true) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Public endpoint: '
                      '${controller.urlsPreview!.public!.baseUrl}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
