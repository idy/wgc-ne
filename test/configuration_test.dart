import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wgc_ne/wgc_ne.dart';

String get key => base64Encode(List.filled(32, 1));

Map<String, Object?> configurationJson() => {
      'version': 1,
      'private_key': key,
      'addresses': ['10.7.0.2/32'],
      'peers': [
        {'id': 'exit', 'public_key': key, 'endpoint': '203.0.113.10:51820'}
      ],
    };

void main() {
  test('version 1 defaults and round trip match the core contract', () {
    final configuration = WgcConfiguration.fromJson(configurationJson());
    expect(configuration.defaultPeer, 'exit');
    expect(configuration.mtu, 1280);
    expect(configuration.transport.type, 'udp');
    expect(configuration.dnsServer, '1.1.1.1:53');
    expect(configuration.network.dnsServers, ['198.18.0.2']);
    expect(configuration.network.includedRoutes, ['0.0.0.0/0']);
    expect(
        WgcConfiguration.fromJsonString(configuration.toJsonString()).toJson(),
        configuration.toJson());
    expect(configuration.toString(), isNot(contains(key)));
  });

  test('keys, numeric endpoints, CIDRs, and peer selection are validated', () {
    for (final endpoint in [
      'vpn.invalid:51820',
      'fe80::1%en0:51820',
      '[fe80::1%en0]:51820',
      '203.0.113.1:0',
      '203.0.113.1:65536'
    ]) {
      expect(() => WgcPeer(id: 'exit', publicKey: key, endpoint: endpoint),
          throwsFormatException);
    }
    expect(
        () =>
            WgcPeer(id: 'exit', publicKey: '$key\n', endpoint: '203.0.113.1:1'),
        throwsFormatException);
    expect(
        () => WgcConfiguration.fromJson({...configurationJson(), 'version': 2}),
        throwsFormatException);
    expect(
        () => WgcConfiguration.fromJson({
              ...configurationJson(),
              'addresses': ['10.7.0.2/33']
            }),
        throwsFormatException);
    expect(
        () => WgcConfiguration.fromJson(
            {...configurationJson(), 'default_peer': 'missing'}),
        throwsFormatException);
    expect(
        () => WgcConfiguration.fromJson({...configurationJson(), 'peers': []}),
        throwsFormatException);
    expect(
        WgcPeer(id: 'v6', publicKey: key, endpoint: '[2001:db8::1]:51820').id,
        'v6');
  });

  test('defaults follow the tunnel address families', () {
    final ipv6Only = {
      ...configurationJson(),
      'addresses': ['fd00:7::2/128'],
    };
    final defaults = WgcConfiguration.fromJson(ipv6Only);
    expect(defaults.dnsServer, '[2606:4700:4700::1111]:53');
    expect(defaults.network.dnsServers, ['2001:2::2']);
    expect(defaults.network.includedRoutes, ['::/0']);

    final partial = WgcConfiguration.fromJson({
      ...ipv6Only,
      'network': {
        'excluded_routes': ['2001:db8::1/128']
      },
    });
    expect(partial.network.dnsServers, ['2001:2::2']);
    expect(partial.network.includedRoutes, ['::/0']);

    final dualStack = WgcConfiguration.fromJson({
      ...configurationJson(),
      'addresses': ['fd00:7::2/128', '10.7.0.2/32'],
    });
    expect(dualStack.dnsServer, '1.1.1.1:53');
    expect(dualStack.network.dnsServers, ['198.18.0.2']);
    expect(dualStack.network.includedRoutes, ['0.0.0.0/0', '::/0']);

    final explicit = WgcConfiguration.fromJson({
      ...ipv6Only,
      'dns_server': '[2001:db8::53]:53',
      'network': {
        'dns_servers': ['fd00:7::53']
      },
    });
    expect(explicit.dnsServer, '[2001:db8::53]:53');
    expect(explicit.network.dnsServers, ['fd00:7::53']);
    expect(explicit.toJson()['dns_server'], '[2001:db8::53]:53');
    expect(
        () => WgcConfiguration.fromJson({
              ...ipv6Only,
              'network': {'dns_servers': <String>[]},
            }),
        throwsFormatException);
  });

  test('limits match the Go schema for addresses, peers, and MTU', () {
    final addresses = List.generate(8, (index) => '10.7.0.${index + 2}/32');
    final peers = List.generate(
        32,
        (index) => {
              'id': 'peer$index',
              'public_key': base64Encode(List.filled(32, index + 1)),
              'endpoint': '203.0.113.10:51820',
            });
    for (final mtu in [1280, 1420]) {
      expect(
          WgcConfiguration.fromJson({
            ...configurationJson(),
            'addresses': addresses,
            'peers': peers,
            'mtu': mtu
          }).mtu,
          mtu);
    }
    for (final mtu in [1279, 1421]) {
      expect(
          () => WgcConfiguration.fromJson({...configurationJson(), 'mtu': mtu}),
          throwsFormatException);
    }
    expect(
        () => WgcConfiguration.fromJson({
              ...configurationJson(),
              'addresses': [...addresses, '10.7.0.10/32']
            }),
        throwsFormatException);
    expect(
        () => WgcConfiguration.fromJson({
              ...configurationJson(),
              'peers': [
                ...peers,
                {...peers.last, 'id': 'overflow'}
              ]
            }),
        throwsFormatException);
  });

  test('unknown schema fields are rejected without echoing their names', () {
    const unknown = 'private-field-must-not-be-disclosed';
    final values = <Map<String, Object?>>[
      {...configurationJson(), unknown: 'secret'},
      {
        ...configurationJson(),
        'peers': [
          {
            ...((configurationJson()['peers'] as List).first
                as Map<String, Object?>),
            unknown: 'secret'
          }
        ]
      },
      {
        ...configurationJson(),
        'transport': {'type': 'udp', unknown: 'secret'}
      },
      {
        ...configurationJson(),
        'network': {unknown: 'secret'}
      },
    ];
    for (final value in values) {
      try {
        WgcConfiguration.fromJson(value);
        fail('Unknown schema fields must fail');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains(unknown)));
      }
    }
    final custom = WgcConfiguration.fromJson({
      ...configurationJson(),
      'transport': {
        'type': 'custom',
        'options': {'registered_option': 'value'}
      },
      'sing_box': {'inbounds': [], 'extension_owned_setting': true},
    });
    expect(custom.transport.options['registered_option'], 'value');
    expect(custom.singBox?['extension_owned_setting'], isTrue);
  });

  test('configuration owns immutable copies of custom options', () {
    final options = <String, Object?>{
      'nested': <Object?>['original']
    };
    final transport = WgcTransport(type: 'custom', options: options);
    (options['nested'] as List)[0] = 'changed';
    expect(transport.options['nested'], ['original']);
    expect(() => (transport.options['nested'] as List).add('more'),
        throwsUnsupportedError);
    final config = WgcConfiguration.fromJson(configurationJson());
    expect(() => config.addresses.add('10.7.0.3/32'), throwsUnsupportedError);
    expect(transport.toString(), isNot(contains('original')));
  });

  test('network settings permit outer peer exclusions from another family', () {
    final config = WgcConfiguration.fromJson({
      ...configurationJson(),
      'network': {
        'excluded_routes': ['2001:db8::1/128']
      },
    });
    expect(config.network.excludedRoutes, ['2001:db8::1/128']);
    expect(
        () => WgcConfiguration.fromJson({
              ...configurationJson(),
              'network': {
                'included_routes': ['::/0']
              },
            }),
        throwsFormatException);
  });

  test('oversized and malformed configuration errors do not echo source', () {
    const secret = 'private-value-never-returned';
    for (final source in [
      '{"private_key":"$secret",',
      jsonEncode({
        ...configurationJson(),
        'sing_box': {'secret': secret * 6000}
      })
    ]) {
      try {
        WgcConfiguration.fromJsonString(source);
        fail('Must reject invalid or oversized JSON');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains(secret)));
      }
    }
  });
}
