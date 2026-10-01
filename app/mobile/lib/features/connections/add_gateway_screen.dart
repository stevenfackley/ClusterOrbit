import 'package:flutter/material.dart';

import '../../core/cluster_domain/saved_connection.dart';
import '../../core/connectivity/cluster_connection_factory.dart';
import 'connection_builders.dart';

/// Returns a user-facing error for [value], or null when it is a usable
/// Gateway base URL: parseable, http/https, with a non-empty host.
String? validateGatewayUrl(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return 'Required';
  final uri = Uri.tryParse(text);
  if (uri == null) return 'Not a valid URL';
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return 'Must start with http:// or https://';
  }
  if (uri.host.isEmpty) return 'Not a valid URL';
  return null;
}

/// Form screen for adding a Gateway connection.
class AddGatewayScreen extends StatefulWidget {
  const AddGatewayScreen({
    super.key,
    required this.onAddConnection,
    this.gatewayConnectionFactory,
  });

  final Future<void> Function(SavedConnection) onAddConnection;

  /// Test hook: overrides how we build a connection for the "Test connection"
  /// probe. Defaults to a real [GatewayClusterConnection].
  final GatewayClusterConnection Function(String url, String token)?
      gatewayConnectionFactory;

  @override
  State<AddGatewayScreen> createState() => _AddGatewayScreenState();
}

class _TestOutcome {
  const _TestOutcome.success(this.clusterCount)
      : ok = true,
        message = null;
  const _TestOutcome.failure(this.message)
      : ok = false,
        clusterCount = 0;

  final bool ok;
  final int clusterCount;
  final String? message;
}

class _AddGatewayScreenState extends State<AddGatewayScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _submitting = false;
  bool _testing = false;
  _TestOutcome? _testOutcome;

  /// A previous probe result no longer describes the edited URL or token.
  void _clearTestOutcome([String? _]) {
    if (_testOutcome != null) setState(() => _testOutcome = null);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    // URL is required for a probe; skip name/token validation.
    final url = _urlController.text.trim();
    if (validateGatewayUrl(url) != null) {
      setState(() => _testOutcome = const _TestOutcome.failure(
          'Enter a valid Gateway URL before testing.'));
      return;
    }
    setState(() {
      _testing = true;
      _testOutcome = null;
    });

    final token = _tokenController.text.trim();
    final factory = widget.gatewayConnectionFactory ??
        (u, t) => GatewayClusterConnection(gatewayBaseUrl: u, token: t);
    final connection = factory(url, token);
    try {
      final clusters = await connection.listClusters();
      if (!mounted) return;
      setState(() => _testOutcome = _TestOutcome.success(clusters.length));
    } catch (e) {
      if (!mounted) return;
      setState(() => _testOutcome = _TestOutcome.failure(e.toString()));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _submit() async {
    // Keyboard submit bypasses the disabled Save button.
    if (_submitting || _testing) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    final connection = newGatewayConnection(
      displayName: _nameController.text,
      url: _urlController.text,
      token: _tokenController.text,
    );

    try {
      await widget.onAddConnection(connection);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Add Gateway Connection')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                        hintText: 'Prod Gateway',
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: 'Gateway URL',
                        hintText: 'https://gateway.example.com',
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      onChanged: _clearTestOutcome,
                      validator: validateGatewayUrl,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _tokenController,
                      decoration: const InputDecoration(
                        labelText: 'Token (optional)',
                        hintText: 'X-ClusterOrbit-Token value',
                      ),
                      obscureText: true,
                      onChanged: _clearTestOutcome,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Sent as the X-ClusterOrbit-Token request header.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 24),
                    if (_testOutcome != null) ...[
                      _TestResultBanner(outcome: _testOutcome!),
                      const SizedBox(height: 16),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const ValueKey('test-connection'),
                            onPressed: (_testing || _submitting)
                                ? null
                                : _testConnection,
                            icon: _testing
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.wifi_tethering, size: 18),
                            label: Text(
                              _testing ? 'Testing…' : 'Test connection',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed:
                                (_submitting || _testing) ? null : _submit,
                            child: const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TestResultBanner extends StatelessWidget {
  const _TestResultBanner({required this.outcome});

  final _TestOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = outcome.ok ? Colors.green : theme.colorScheme.error;
    final icon = outcome.ok ? Icons.check_circle_outline : Icons.error_outline;
    final label = outcome.ok
        ? 'Connected — ${outcome.clusterCount} cluster(s) visible.'
        : 'Failed: ${outcome.message}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.40)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
