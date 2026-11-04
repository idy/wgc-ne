import 'dart:convert';

/// The system's VPN state, independent of optional core statistics.
enum WgcConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  reasserting,
  invalid
}

final class WgcStatus {
  const WgcStatus({required this.state, this.core});

  factory WgcStatus.fromMap(Object? value) {
    if (value is! Map || value['state'] is! String) {
      throw const WgcException(WgcErrorCode.invalidResponse);
    }
    final state = WgcConnectionState.values
        .where((state) => state.name == value['state'])
        .firstOrNull;
    if (state == null) {
      throw const WgcException(WgcErrorCode.invalidResponse);
    }
    return WgcStatus(
        state: state,
        core: value['core'] == null
            ? null
            : WgcCoreStatus.fromMap(value['core']));
  }

  final WgcConnectionState state;
  final WgcCoreStatus? core;
  bool get isConnected =>
      state == WgcConnectionState.connected ||
      state == WgcConnectionState.reasserting;

  @override
  String toString() => 'WgcStatus(${state.name})';
}

final class WgcCoreStatus {
  const WgcCoreStatus({
    required this.state,
    this.publicKey,
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.packetsSent = 0,
    this.packetsReceived = 0,
    this.coreVersion,
  });

  factory WgcCoreStatus.fromMap(Object? value) {
    if (value is! Map || !['running', 'stopped'].contains(value['state'])) {
      throw const WgcException(WgcErrorCode.invalidResponse);
    }
    final key = value['public_key'];
    final version = value['core_version'];
    if ((key != null && (key is! String || key.length > 128)) ||
        (version != null &&
            (version is! String || version.isEmpty || version.length > 64))) {
      throw const WgcException(WgcErrorCode.invalidResponse);
    }
    if (key is String) {
      try {
        final bytes = base64Decode(key);
        if (bytes.length != 32 || base64Encode(bytes) != key) {
          throw const WgcException(WgcErrorCode.invalidResponse);
        }
      } catch (_) {
        throw const WgcException(WgcErrorCode.invalidResponse);
      }
    }
    return WgcCoreStatus(
      state: value['state'] as String,
      publicKey: key as String?,
      coreVersion: version as String?,
      bytesSent: _counter(value['bytes_sent']),
      bytesReceived: _counter(value['bytes_received']),
      packetsSent: _counter(value['packets_sent']),
      packetsReceived: _counter(value['packets_received']),
    );
  }

  final String state;
  final String? publicKey;
  final int bytesSent;
  final int bytesReceived;
  final int packetsSent;
  final int packetsReceived;
  final String? coreVersion;
}

int _counter(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is! int || value < 0) {
    throw const WgcException(WgcErrorCode.invalidResponse);
  }
  return value;
}

enum WgcErrorCode {
  invalidArguments(
      'invalid_arguments', 'The provider or Keychain identifiers are invalid.'),
  invalidConfiguration(
      'invalid_configuration', 'The tunnel configuration is invalid.'),
  invalidProfile(
      'invalid_profile', 'The owned VPN profile has invalid metadata.'),
  profileConflict('profile_conflict',
      'The provider has an ambiguous or differently owned VPN profile.'),
  keychainFailure('keychain_failure',
      'The shared Keychain configuration could not be accessed.'),
  preferencesFailure(
      'preferences_failure', 'VPN preferences could not be updated or loaded.'),
  tunnelStartFailed(
      'tunnel_start_failed', 'The system could not start the VPN tunnel.'),
  providerUnavailable(
      'provider_unavailable', 'The tunnel provider is unavailable.'),
  coreUnavailable('core_unavailable',
      'A compatible tunnel core must be supplied by the extension.'),
  coreFailure(
      'core_failure', 'The tunnel core could not complete the operation.'),
  invalidResponse(
      'invalid_response', 'The tunnel provider returned an invalid response.'),
  tunnelUnavailable('tunnel_unavailable',
      'The tunnel network interface could not be identified.'),
  timeout('timeout', 'The tunnel operation timed out.'),
  cancelled('cancelled', 'The tunnel operation was cancelled.'),
  disposed('disposed', 'This tunnel client has been disposed.'),
  unsupportedPlatform('unsupported_platform',
      'WGC NE requires an Apple host with the native plugin installed.'),
  internalError(
      'internal_error', 'The tunnel operation could not be completed.');

  const WgcErrorCode(this.code, this.message);
  final String code;
  final String message;
}

/// Native exception messages and details are deliberately never retained.
final class WgcException implements Exception {
  const WgcException(this.kind);
  final WgcErrorCode kind;
  String get code => kind.code;
  String get message => kind.message;

  @override
  String toString() => 'WgcException($code): $message';
}
