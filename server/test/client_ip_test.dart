/// `clientIp()` trust rules: which peers may set `X-Forwarded-For` and which
/// hop of it identifies the client for the per-IP limits of SPEC §3/§4.
library;

import 'dart:io';

import 'package:arco_server/arco_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Stands in for the socket peer that `shelf_io` puts in the request context.
class _FakeConnectionInfo implements HttpConnectionInfo {
  _FakeConnectionInfo(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 54321;

  @override
  int get localPort => 8080;
}

Request requestFrom(String peer, {String? forwarded}) => Request(
  'POST',
  Uri.parse('http://localhost:8080/api/scores'),
  headers: {'x-forwarded-for': ?forwarded},
  context: {
    'shelf.io.connection_info': _FakeConnectionInfo(
      InternetAddress(
        peer,
        type: peer.contains(':')
            ? InternetAddressType.IPv6
            : InternetAddressType.IPv4,
      ),
    ),
  },
);

void main() {
  group('clientIp', () {
    test('uses the socket peer when there is no X-Forwarded-For', () {
      expect(clientIp(requestFrom('203.0.113.7')), '203.0.113.7');
    });

    test('ignores X-Forwarded-For from a public peer', () {
      // Directly exposed server: the header is attacker-controlled, so a
      // client cannot pick its own rate-limit key.
      expect(
        clientIp(requestFrom('203.0.113.7', forwarded: '1.2.3.4')),
        '203.0.113.7',
      );
    });

    test('takes the rightmost hop behind a private-network proxy', () {
      // The proxy appends the address it saw; hops to its left came from the
      // client and are forgeable.
      for (final peer in [
        '127.0.0.1',
        '10.0.0.3',
        '172.16.4.5',
        '192.168.1.2',
        'fdaa::3',
      ]) {
        expect(
          clientIp(requestFrom(peer, forwarded: '9.9.9.9, 203.0.113.8')),
          '203.0.113.8',
          reason: 'peer $peer',
        );
      }
    });

    test('a spoofed prefix cannot change the key', () {
      const real = '203.0.113.8';
      final keys = <String>{
        for (final spoof in ['9.9.9.9', '8.8.8.8, 7.7.7.7', 'unknown', ''])
          clientIp(requestFrom('10.0.0.3', forwarded: '$spoof, $real')),
      };
      expect(keys, {real});
    });

    test('falls back to the peer when every hop is unusable', () {
      expect(
        clientIp(requestFrom('10.0.0.3', forwarded: 'unknown, _hidden')),
        '10.0.0.3',
      );
    });

    test('does not scan left when the rightmost hop is unusable', () {
      // The leftmost hops of a chain are written by the client, so an
      // unparseable rightmost hop must send us to the socket peer rather than
      // promote a value the client chose to the key and the stored IP hash.
      expect(
        clientIp(requestFrom('10.0.0.3', forwarded: '203.0.113.5, unknown')),
        '10.0.0.3',
      );
      expect(
        clientIp(requestFrom('10.0.0.3', forwarded: 'unknown')),
        '10.0.0.3',
      );
      // A well-formed chain is untouched: the rightmost hop still wins.
      expect(
        clientIp(
          requestFrom('10.0.0.3', forwarded: '203.0.113.5, 198.51.100.9'),
        ),
        '198.51.100.9',
      );
    });

    test('normalises a hop that carries a port or brackets', () {
      expect(
        clientIp(
          requestFrom('10.0.0.3', forwarded: '9.9.9.9, 203.0.113.8:1234'),
        ),
        '203.0.113.8',
      );
      expect(
        clientIp(requestFrom('10.0.0.3', forwarded: '[2001:db8::5]:443')),
        '2001:db8::5',
      );
    });

    test('is "unknown" without connection info', () {
      final request = Request(
        'POST',
        Uri.parse('http://localhost:8080/api/scores'),
        headers: {'x-forwarded-for': '1.2.3.4'},
      );
      expect(clientIp(request), 'unknown');
    });
  });
}
