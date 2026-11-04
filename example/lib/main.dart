import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wgc_ne/wgc_ne.dart';

void main() => runApp(const WgcExample());

class WgcExample extends StatelessWidget {
  const WgcExample({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'WGC NE',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff2463b4), brightness: Brightness.light),
          scaffoldBackgroundColor: const Color(0xfff6f8fb),
          inputDecorationTheme:
              const InputDecorationTheme(border: OutlineInputBorder()),
          useMaterial3: true,
        ),
        home: const TunnelPage(),
      );
}

class TunnelPage extends StatefulWidget {
  const TunnelPage({super.key});
  @override
  State<TunnelPage> createState() => _TunnelPageState();
}

class _TunnelPageState extends State<TunnelPage> {
  final _provider = TextEditingController();
  final _group = TextEditingController();
  final _configuration = TextEditingController();
  WgcNe? _client;
  StreamSubscription<WgcStatus>? _subscription;
  WgcStatus? _status;
  String? _error;
  bool _busy = false;

  bool get _active =>
      _status != null &&
      ![
        WgcConnectionState.disconnected,
        WgcConnectionState.invalid,
      ].contains(_status!.state);

  Future<WgcNe> _ensureClient() async {
    final provider = _provider.text.trim();
    final group = _group.text.trim();
    final old = _client;
    if (old != null &&
        old.providerBundleIdentifier == provider &&
        old.keychainAccessGroup == group) {
      return old;
    }
    final client = Platform.isAndroid
        ? WgcNe.android(localizedDescription: 'WGC NE example')
        : WgcNe(
            providerBundleIdentifier: provider,
            keychainAccessGroup: group,
            localizedDescription: 'WGC NE example');
    await _subscription?.cancel();
    await old?.dispose();
    _client = client;
    _subscription = client.statuses.listen((status) {
      if (mounted) {
        setState(() => _status = status);
      }
    }, onError: (Object error) {
      if (mounted) {
        setState(() => _error = error is WgcException
            ? error.message
            : 'Could not read tunnel status.');
      }
    });
    return client;
  }

  Future<void> _perform(Future<WgcStatus> Function(WgcNe) operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = await _ensureClient();
      final result = await operation(client);
      if (mounted) {
        setState(() => _status = result);
      }
    } on WgcException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } on FormatException {
      if (mounted) {
        setState(
            () => _error = 'Enter a valid WGC version 1 JSON configuration.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'The tunnel operation could not be completed.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_client?.dispose());
    _provider.dispose();
    _group.dispose();
    _configuration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final core = _status?.core;
    return Scaffold(
      appBar: AppBar(title: const Text('WGC NE')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Connect your tunnel',
                        style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 12),
                    Text(Platform.isAndroid
                        ? 'Android will request VPN permission and show a notification while connected.'
                        : 'Use the identifiers of your embedded PacketTunnel extension and shared Keychain group. Both targets need the corresponding entitlements.'),
                    const SizedBox(height: 24),
                    if (!Platform.isAndroid) ...[
                      TextField(
                        controller: _provider,
                        enabled: !_busy && !_active,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                            labelText: 'Provider bundle identifier',
                            hintText: 'com.yourcompany.app.tunnel'),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _group,
                        enabled: !_busy && !_active,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                            labelText: 'Shared Keychain access group',
                            hintText: 'TEAMID.com.yourcompany.shared'),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: _configuration,
                      enabled: !_busy && !_active,
                      minLines: 8,
                      maxLines: 18,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                          labelText: 'Configuration JSON',
                          alignLabelWithHint: true,
                          helperText: Platform.isAndroid
                              ? 'Contains your private key. Kept in app/service memory, not saved to disk.'
                              : 'Contains your private key. It is stored in the shared device-only Keychain.'),
                    ),
                    const SizedBox(height: 24),
                    Semantics(
                        liveRegion: true,
                        child: Text(
                          _status == null
                              ? 'Status has not been checked'
                              : 'Tunnel: ${_status!.state.name}',
                          style: Theme.of(context).textTheme.titleLarge,
                        )),
                    if (core != null) ...[
                      const SizedBox(height: 8),
                      Text(
                          'Sent ${core.bytesSent} bytes · Received ${core.bytesReceived} bytes'),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                          liveRegion: true,
                          child: Text(_error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                    ],
                    const SizedBox(height: 20),
                    Wrap(spacing: 12, runSpacing: 12, children: [
                      FilledButton(
                        onPressed: _busy || _active
                            ? null
                            : () => _perform((client) => client.start(
                                WgcConfiguration.fromJsonString(
                                    _configuration.text))),
                        child: const Text('Connect'),
                      ),
                      OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _perform((client) => client.stop()),
                          child: const Text('Disconnect')),
                      TextButton(
                          onPressed: _busy
                              ? null
                              : () => _perform((client) => client.status()),
                          child: const Text('Check status')),
                      TextButton(
                          onPressed: _busy
                              ? null
                              : () =>
                                  _perform((client) => client.removeProfile()),
                          child: const Text('Remove VPN profile')),
                    ]),
                    if (_busy) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator()
                    ],
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}
