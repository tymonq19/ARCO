/// HTTP plumbing shared by the REST handlers: JSON responses, client IP
/// extraction, bounded body reading, CORS and the error boundary.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'logging.dart';

const Map<String, String> jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};

Response jsonResponse(int status, Map<String, dynamic> body) =>
    Response(status, body: jsonEncode(body), headers: jsonHeaders);

/// `{"ok":false,"error":code[,"detail":detail]}` with [status], plus any
/// [extra] fields the caller wants the client to be able to act on.
Response errorResponse(
  int status,
  String code, {
  String? detail,
  Map<String, dynamic>? extra,
}) => jsonResponse(status, {
  'ok': false,
  'error': code,
  'detail': ?detail,
  ...?extra,
});

/// Client address used for the per-IP limits (SPEC §3, §4) and the stored IP
/// hash (SPEC §4.3).
///
/// `X-Forwarded-For` is honoured only when the request reached us from a
/// loopback or private-network peer, i.e. through the platform's reverse proxy
/// (Fly.io, Railway, Render — see README.server.md). A directly exposed server
/// sees public peers and ignores the header, because anyone can send it.
///
/// Inside a trusted chain the *rightmost* hop is used: a proxy appends the
/// address it actually saw, so every hop further left is client-supplied and
/// therefore forgeable. Keying on the leftmost hop would let a single host
/// rotate the header and escape every per-IP limit.
///
/// Only that one hop is consulted. When it is not an address (`unknown`, an
/// obfuscated identifier, empty) the chain is abandoned for the socket peer
/// rather than scanned leftwards, so a client that appends junk cannot promote
/// a hop it wrote itself to the rate-limit key and the stored IP hash.
String clientIp(Request request) {
  final peer = _peerAddress(request);
  if (peer == null) return 'unknown';
  if (!_isPrivatePeer(peer)) return peer.address;
  final forwarded = request.headers['x-forwarded-for'];
  if (forwarded != null) {
    final ip = _parseHop(forwarded.split(',').last);
    if (ip != null) return ip;
  }
  return peer.address;
}

InternetAddress? _peerAddress(Request request) {
  final info = request.context['shelf.io.connection_info'];
  return info is HttpConnectionInfo ? info.remoteAddress : null;
}

/// Whether [addr] can be a reverse proxy on the deployment's own network
/// (loopback, link-local, RFC 1918 / RFC 6598, or an IPv6 unique-local
/// address such as Fly.io's `fdaa::/16`).
bool _isPrivatePeer(InternetAddress addr) {
  if (addr.isLoopback || addr.isLinkLocal) return true;
  final raw = addr.rawAddress;
  if (raw.length == 4) return _isPrivateV4(raw);
  if (raw.length == 16) {
    if ((raw[0] & 0xfe) == 0xfc) return true;
    // IPv4-mapped / IPv4-compatible peer (`::ffff:10.0.0.1`).
    final embedsV4 =
        raw.take(10).every((b) => b == 0) &&
        ((raw[10] == 0xff && raw[11] == 0xff) || (raw[10] | raw[11]) == 0);
    if (embedsV4) return _isPrivateV4(raw.sublist(12));
  }
  return false;
}

bool _isPrivateV4(List<int> b) =>
    b[0] == 10 ||
    (b[0] == 172 && (b[1] & 0xf0) == 16) ||
    (b[0] == 192 && b[1] == 168) ||
    (b[0] == 100 && (b[1] & 0xc0) == 64);

/// One `X-Forwarded-For` hop as a canonical address, or null when it is not an
/// address at all (empty, `unknown`, an obfuscated identifier), so that a junk
/// header cannot become a rate-limit key.
String? _parseHop(String raw) {
  var hop = raw.trim();
  if (hop.startsWith('[')) {
    final end = hop.indexOf(']');
    if (end < 0) return null;
    hop = hop.substring(1, end);
  } else if (hop.contains(':') && hop.indexOf(':') == hop.lastIndexOf(':')) {
    hop = hop.substring(0, hop.indexOf(':')); // `1.2.3.4:5678`
  }
  return InternetAddress.tryParse(hop)?.address;
}

/// Reads the request body, returning null once it is known to exceed
/// [maxBytes] (declared content length or bytes actually received).
///
/// An oversized body is drained (up to [drainLimit], four times the cap by
/// default) instead of being abandoned, so the client reliably receives the
/// 413 response rather than a reset connection. Nothing beyond [maxBytes] is
/// ever buffered.
Future<Uint8List?> readBodyCapped(
  Request request,
  int maxBytes, {
  int? drainLimit,
}) async {
  final limit = drainLimit ?? maxBytes * 4;
  final builder = BytesBuilder(copy: false);
  var received = 0;
  var tooLarge = (request.contentLength ?? 0) > maxBytes;
  await for (final chunk in request.read()) {
    received += chunk.length;
    if (!tooLarge && received > maxBytes) tooLarge = true;
    if (tooLarge) {
      builder.clear();
      if (received > limit) break;
      continue;
    }
    builder.add(chunk);
  }
  return tooLarge ? null : builder.takeBytes();
}

/// Allows any origin on `/api/*` (needed by the web build) and answers
/// preflight requests directly. SPEC §4.3.
Middleware corsMiddleware() {
  const headers = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
    'access-control-allow-headers':
        'Authorization, Content-Type, X-Requested-With',
    'access-control-max-age': '86400',
  };
  return (Handler inner) {
    return (Request request) async {
      if (!request.url.path.startsWith('api/')) return inner(request);
      if (request.method == 'OPTIONS') return Response(204, headers: headers);
      final response = await inner(request);
      return response.change(headers: headers);
    };
  };
}

/// Turns uncaught exceptions into a JSON 500. WebSocket upgrades hijack the
/// socket by throwing [HijackException], which must pass through untouched.
Middleware errorMiddleware(Logger log) {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on HijackException {
        rethrow;
      } catch (e, st) {
        log.error(
          'unhandled error for ${request.method} /${request.url.path}',
          e,
          st,
        );
        return errorResponse(500, 'internal');
      }
    };
  };
}
