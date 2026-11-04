import 'dart:convert';
import 'dart:io';

import 'wireguard_key.dart';

const int wgcMaximumConfigurationBytes = 128 * 1024;

/// Version 1 configuration. Keys and transport options are never included in toString.
final class WgcConfiguration {
  WgcConfiguration({
    required this.privateKey,
    required List<String> addresses,
    required List<WgcPeer> peers,
    String? defaultPeer,
    WgcTransport? transport,
    this.mtu = 1280,
    String? dnsServer,
    WgcNetworkSettings? network,
    Map<String, Object?>? singBox,
  })  : addresses = List.unmodifiable(addresses),
        peers = List.unmodifiable(peers),
        defaultPeer = defaultPeer ?? (peers.isEmpty ? '' : peers.first.id),
        transport = transport ?? WgcTransport(),
        dnsServer = dnsServer ?? _defaultUpstreamDns(addresses),
        network = (network ?? WgcNetworkSettings())._resolveDefaults(addresses),
        singBox = singBox == null ? null : _freezeObject(singBox) {
    validateWireGuardKey(privateKey);
    if (addresses.isEmpty ||
        addresses.length > 8 ||
        peers.isEmpty ||
        peers.length > 32) {
      throw const FormatException(
          'Configuration needs addresses and peers within supported limits.');
    }
    final families = addresses.map(_cidr).toSet();
    if (addresses.map((value) => value.split('/').first).toSet().length !=
        addresses.length) {
      throw const FormatException('Tunnel addresses must be unique.');
    }
    final ids = peers.map((peer) => peer.id).toSet();
    if (ids.length != peers.length || !ids.contains(this.defaultPeer)) {
      throw const FormatException(
          'Peer identifiers must be unique and include the default peer.');
    }
    if (mtu < 1280 || mtu > 1420) {
      throw const FormatException(
          'The tunnel MTU is outside the supported range.');
    }
    _endpoint(this.dnsServer);
    for (final route in this.network.includedRoutes ?? <String>[]) {
      if (!families.contains(_cidr(route))) {
        throw const FormatException(
            'An included route needs a matching tunnel address family.');
      }
    }
    if (utf8.encode(jsonEncode(toJson())).length >
        wgcMaximumConfigurationBytes) {
      throw const FormatException('Configuration exceeds 128 KiB.');
    }
  }

  factory WgcConfiguration.fromJsonString(String source) {
    if (utf8.encode(source).length > wgcMaximumConfigurationBytes) {
      throw const FormatException('Configuration exceeds 128 KiB.');
    }
    try {
      return WgcConfiguration.fromJson(_object(jsonDecode(source)));
    } on FormatException {
      throw const FormatException('Invalid WGC version 1 configuration.');
    } catch (_) {
      throw const FormatException('Invalid WGC version 1 configuration.');
    }
  }

  factory WgcConfiguration.fromJson(Map<String, Object?> json) {
    _rejectUnknownFields(json, _configurationFields);
    if (json['version'] != 1 || json['version'] is! int) {
      throw const FormatException('Only configuration version 1 is supported.');
    }
    final peerValues = json['peers'];
    if (peerValues is! List) {
      throw const FormatException('Configuration peers must be a list.');
    }
    return WgcConfiguration(
      privateKey: _string(json['private_key']),
      addresses: _strings(json['addresses']),
      peers:
          peerValues.map((value) => WgcPeer.fromJson(_object(value))).toList(),
      defaultPeer: _optionalString(json['default_peer']),
      transport: json['transport'] == null
          ? null
          : WgcTransport.fromJson(_object(json['transport'])),
      mtu: json['mtu'] == null ? 1280 : _integer(json['mtu']),
      dnsServer: _optionalString(json['dns_server']),
      network: json['network'] == null
          ? null
          : WgcNetworkSettings.fromJson(_object(json['network'])),
      singBox: json['sing_box'] == null ? null : _object(json['sing_box']),
    );
  }

  final String privateKey;
  final List<String> addresses;
  final List<WgcPeer> peers;
  final String defaultPeer;
  final WgcTransport transport;
  final int mtu;

  /// The configured upstream resolver, with the core's address-family default.
  final String dnsServer;
  final WgcNetworkSettings network;
  final Map<String, Object?>? singBox;
  int get version => 1;

  Map<String, Object?> toJson() => {
        'version': version,
        'private_key': privateKey,
        'addresses': addresses,
        'peers': peers.map((peer) => peer.toJson()).toList(),
        'default_peer': defaultPeer,
        'transport': transport.toJson(),
        'mtu': mtu,
        'dns_server': dnsServer,
        'network': network.toJson(),
        if (singBox != null) 'sing_box': singBox,
      };

  String toJsonString() => jsonEncode(toJson());

  @override
  String toString() => 'WgcConfiguration(version: 1, peers: ${peers.length})';
}

final class WgcPeer {
  WgcPeer({required this.id, required this.publicKey, required this.endpoint}) {
    if (id.isEmpty || id.length > 128 || id.runes.any((value) => value < 32)) {
      throw const FormatException('Peer identifier is invalid.');
    }
    validateWireGuardKey(publicKey);
    _endpoint(endpoint);
  }

  factory WgcPeer.fromJson(Map<String, Object?> json) {
    _rejectUnknownFields(json, const {'id', 'public_key', 'endpoint'});
    return WgcPeer(
      id: _string(json['id']),
      publicKey: _string(json['public_key']),
      endpoint: _string(json['endpoint']),
    );
  }

  final String id;
  final String publicKey;
  final String endpoint;
  Map<String, Object?> toJson() =>
      {'id': id, 'public_key': publicKey, 'endpoint': endpoint};

  @override
  String toString() => 'WgcPeer()';
}

/// The core decides which transport names are registered; unknown names fail closed.
final class WgcTransport {
  WgcTransport({
    this.type = 'udp',
    Map<String, Object?> options = const {},
    this.base,
  }) : options = _freezeObject(options) {
    if (type.isEmpty ||
        type.length > 128 ||
        type.runes.any((value) => value <= 32)) {
      throw const FormatException('Transport name is invalid.');
    }
    _validateDepth(0);
  }

  factory WgcTransport.fromJson(Map<String, Object?> json) =>
      WgcTransport._fromJson(json, 0);

  factory WgcTransport._fromJson(Map<String, Object?> json, int depth) {
    _checkDepth(depth);
    _rejectUnknownFields(json, const {'type', 'options', 'base'});
    return WgcTransport(
      type: _string(json['type']),
      options: json['options'] == null ? const {} : _object(json['options']),
      base: json['base'] == null
          ? null
          : WgcTransport._fromJson(_object(json['base']), depth + 1),
    );
  }

  final String type;
  final Map<String, Object?> options;
  final WgcTransport? base;
  Map<String, Object?> toJson() => {
        'type': type,
        'options': options,
        if (base != null) 'base': base!.toJson(),
      };

  void _validateDepth(int depth) {
    _checkDepth(depth);
    base?._validateDepth(depth + 1);
  }

  static void _checkDepth(int depth) {
    if (depth > 8) {
      throw const FormatException('Transport nesting exceeds eight wrappers.');
    }
  }

  @override
  String toString() => 'WgcTransport()';
}

final class WgcNetworkSettings {
  WgcNetworkSettings({
    List<String>? dnsServers,
    List<String>? includedRoutes,
    List<String> excludedRoutes = const [],
  })  : dnsServers = dnsServers == null ? null : List.unmodifiable(dnsServers),
        includedRoutes =
            includedRoutes == null ? null : List.unmodifiable(includedRoutes),
        excludedRoutes = List.unmodifiable(excludedRoutes) {
    if ((dnsServers != null && (dnsServers.isEmpty || dnsServers.length > 8)) ||
        (includedRoutes?.length ?? 0) > 1024 ||
        excludedRoutes.length > 1024) {
      throw const FormatException('Network settings exceed supported limits.');
    }
    for (final server in [...?dnsServers]) {
      _ip(server);
    }
    for (final route in [...?includedRoutes, ...excludedRoutes]) {
      _cidr(route);
    }
  }

  factory WgcNetworkSettings.fromJson(Map<String, Object?> json) {
    _rejectUnknownFields(
        json, const {'dns_servers', 'included_routes', 'excluded_routes'});
    return WgcNetworkSettings(
      dnsServers:
          json['dns_servers'] == null ? null : _strings(json['dns_servers']),
      includedRoutes: json['included_routes'] == null
          ? null
          : _strings(json['included_routes']),
      excludedRoutes: json['excluded_routes'] == null
          ? const []
          : _strings(json['excluded_routes']),
    );
  }

  /// Null selects the default for the tunnel's address families.
  /// [WgcConfiguration.network] always holds the resolved list.
  final List<String>? dnsServers;

  /// Null routes every address family in the tunnel addresses.
  /// [WgcConfiguration.network] always holds the resolved list.
  final List<String>? includedRoutes;
  final List<String> excludedRoutes;

  /// Fills unset values with the core's defaults. IPv4 defaults apply when any
  /// tunnel address is IPv4, so an IPv6-only tunnel only receives IPv6 DNS.
  WgcNetworkSettings _resolveDefaults(List<String> addresses) {
    final families = addresses.map(_cidr).toSet();
    final hasIPv4 = families.contains(InternetAddressType.IPv4);
    return WgcNetworkSettings(
      dnsServers: dnsServers ?? [hasIPv4 ? '198.18.0.2' : '2001:2::2'],
      includedRoutes: includedRoutes ??
          [
            if (hasIPv4) '0.0.0.0/0',
            if (families.contains(InternetAddressType.IPv6)) '::/0',
          ],
      excludedRoutes: excludedRoutes,
    );
  }

  Map<String, Object?> toJson() => {
        if (dnsServers != null) 'dns_servers': dnsServers,
        if (includedRoutes != null) 'included_routes': includedRoutes,
        'excluded_routes': excludedRoutes,
      };
}

String _defaultUpstreamDns(List<String> addresses) =>
    addresses.map(_cidr).contains(InternetAddressType.IPv4)
        ? '1.1.1.1:53'
        : '[2606:4700:4700::1111]:53';

const _configurationFields = {
  'version',
  'private_key',
  'addresses',
  'peers',
  'default_peer',
  'transport',
  'mtu',
  'dns_server',
  'network',
  'sing_box',
};

/// Field names come from the caller's JSON, so the message never repeats them.
void _rejectUnknownFields(Map<String, Object?> json, Set<String> allowed) {
  if (!allowed.containsAll(json.keys)) {
    throw const FormatException('Configuration contains an unsupported field.');
  }
}

InternetAddress _ip(String value) {
  if (value.isEmpty || value.contains('%') || value.trim() != value) {
    throw const FormatException(
        'Network addresses must be numeric and unzoned.');
  }
  final address = InternetAddress.tryParse(value);
  if (address == null) {
    throw const FormatException(
        'Network addresses must be numeric and unzoned.');
  }
  return address;
}

InternetAddressType _cidr(String value) {
  final parts = value.split('/');
  if (parts.length != 2 || !RegExp(r'^\d+$').hasMatch(parts[1])) {
    throw const FormatException(
        'Tunnel addresses and routes require CIDR notation.');
  }
  final type = _ip(parts[0]).type;
  final prefix = int.tryParse(parts[1]);
  if (prefix == null ||
      prefix < 0 ||
      prefix > (type == InternetAddressType.IPv4 ? 32 : 128)) {
    throw const FormatException(
        'CIDR prefix is outside the address family range.');
  }
  return type;
}

void _endpoint(String value) {
  String host;
  String port;
  if (value.startsWith('[')) {
    final end = value.indexOf(']:');
    if (end <= 1) {
      throw const FormatException('Endpoint needs a numeric host and port.');
    }
    host = value.substring(1, end);
    port = value.substring(end + 2);
    if (_ip(host).type != InternetAddressType.IPv6) {
      throw const FormatException(
          'Bracketed endpoint must contain an IPv6 address.');
    }
  } else {
    final parts = value.split(':');
    if (parts.length != 2) {
      throw const FormatException('Endpoint needs a numeric host and port.');
    }
    host = parts[0];
    port = parts[1];
    if (_ip(host).type != InternetAddressType.IPv4) {
      throw const FormatException('IPv6 endpoints require brackets.');
    }
  }
  final number = int.tryParse(port);
  if (!RegExp(r'^\d+$').hasMatch(port) ||
      number == null ||
      number < 1 ||
      number > 65535) {
    throw const FormatException('Endpoint port must be between 1 and 65535.');
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Configuration requires a JSON object.');
  }
  return Map<String, Object?>.from(value);
}

String _string(Object? value) {
  if (value is! String) {
    throw const FormatException('Configuration string is missing or invalid.');
  }
  return value;
}

String? _optionalString(Object? value) => value == null ? null : _string(value);

List<String> _strings(Object? value) {
  if (value is! List) {
    throw const FormatException('Configuration requires a string list.');
  }
  return value.map(_string).toList();
}

int _integer(Object? value) {
  if (value is! int) {
    throw const FormatException('Configuration requires an integer.');
  }
  return value;
}

Map<String, Object?> _freezeObject(Map<String, Object?> value) =>
    _freezeJson(value, 0) as Map<String, Object?>;

Object? _freezeJson(Object? value, int depth) {
  if (depth > 32) {
    throw const FormatException('Configuration JSON is too deeply nested.');
  }
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
        value.map((item) => _freezeJson(item, depth + 1)));
  }
  if (value is Map && value.keys.every((key) => key is String)) {
    return Map<String, Object?>.unmodifiable(value.map(
        (key, item) => MapEntry(key as String, _freezeJson(item, depth + 1))));
  }
  throw const FormatException(
      'Configuration options must contain JSON values.');
}
