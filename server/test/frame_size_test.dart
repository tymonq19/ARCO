/// The wire-level client-frame size cap: `dart:io` reassembles a whole
/// WebSocket message before the session can look at it, so a message declared
/// larger than [maxClientFrameBytes] must be refused from its header, before
/// any of its payload is buffered (SPEC §3: one JSON message per frame).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arco_server/arco_server.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Close code the WebSocket layer sends for a protocol error; an endpoint may
/// not send it itself, which is why the guard lets that layer do the closing.
const int wsProtocolError = 1002;

/// A client that speaks raw WebSocket frames, so that a test can send a frame
/// *header* without the payload it promises - impossible through any real
/// client library.
class _RawClient {
  _RawClient._(this._socket) {
    _sub = _socket.listen(
      _onBytes,
      onError: (Object _) => _finish(),
      onDone: _finish,
    );
    addTearDown(() async {
      await _sub.cancel();
      _socket.destroy();
    });
  }

  static Future<_RawClient> connect(ArcoServer server) async {
    final socket = await Socket.connect(server.address, server.port);
    final client = _RawClient._(socket);
    final key = base64.encode(List<int>.generate(16, (i) => i * 11 + 3));
    socket.write(
      'GET /ws HTTP/1.1\r\n'
      'Host: ${server.address.address}:${server.port}\r\n'
      'Connection: Upgrade\r\n'
      'Upgrade: websocket\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      '\r\n',
    );
    await socket.flush();
    await client._upgraded.future.timeout(const Duration(seconds: 5));
    return client;
  }

  final Socket _socket;
  late final StreamSubscription<List<int>> _sub;

  final List<int> _buffer = <int>[];
  final Completer<void> _upgraded = Completer<void>();
  final Completer<int?> _gone = Completer<int?>();
  final List<String> _texts = <String>[];
  final List<Completer<String>> _waiting = <Completer<String>>[];
  bool _handshakeDone = false;
  int? _closeCode;

  /// Completes when the connection ends, with the code of the close frame the
  /// server sent first (null when it just went away).
  Future<int?> get gone => _gone.future;

  /// Sends one masked frame (the mask is all zeroes, i.e. the identity) whose
  /// header declares [declaredLength] bytes of payload, followed by [payload].
  ///
  /// [payload] shorter than [declaredLength] is exactly what a client sending a
  /// huge frame looks like on the wire before the rest of it arrives.
  void sendFrame({
    required int declaredLength,
    List<int> payload = const <int>[],
    int opcode = 0x1,
    bool fin = true,
  }) {
    final header = <int>[(fin ? 0x80 : 0x00) | opcode];
    if (declaredLength < 126) {
      header.add(0x80 | declaredLength);
    } else if (declaredLength < 65536) {
      header
        ..add(0x80 | 126)
        ..add((declaredLength >> 8) & 0xff)
        ..add(declaredLength & 0xff);
    } else {
      header.add(0x80 | 127);
      for (var shift = 56; shift >= 0; shift -= 8) {
        header.add((declaredLength >> shift) & 0xff);
      }
    }
    header.addAll(const <int>[0, 0, 0, 0]);
    _socket
      ..add(header)
      ..add(payload);
  }

  /// The next text frame from the server.
  Future<String> nextText({Duration timeout = const Duration(seconds: 5)}) {
    if (_texts.isNotEmpty) return Future<String>.value(_texts.removeAt(0));
    final completer = Completer<String>();
    _waiting.add(completer);
    return completer.future.timeout(timeout);
  }

  void _onBytes(List<int> bytes) {
    _buffer.addAll(bytes);
    if (!_handshakeDone) {
      final end = _endOfHeaders();
      if (end < 0) return;
      expect(
        utf8.decode(_buffer.sublist(0, end)),
        contains('101 Switching Protocols'),
      );
      _buffer.removeRange(0, end);
      _handshakeDone = true;
      _upgraded.complete();
    }
    _readFrames();
  }

  int _endOfHeaders() {
    for (var i = 3; i < _buffer.length; i++) {
      if (_buffer[i] == 10 &&
          _buffer[i - 1] == 13 &&
          _buffer[i - 2] == 10 &&
          _buffer[i - 3] == 13) {
        return i + 1;
      }
    }
    return -1;
  }

  /// Decodes complete server frames out of [_buffer]. Server frames are never
  /// masked and the ones this test sees are far below 64 KiB.
  void _readFrames() {
    while (_buffer.length >= 2) {
      final opcode = _buffer[0] & 0x0f;
      final short = _buffer[1] & 0x7f;
      final start = short < 126 ? 2 : 4;
      final length = short < 126 ? short : (_buffer[2] << 8) | _buffer[3];
      if (_buffer.length < start + length) return;
      final payload = _buffer.sublist(start, start + length);
      _buffer.removeRange(0, start + length);
      if (opcode == 0x1) {
        final text = utf8.decode(payload);
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(text);
        } else {
          _texts.add(text);
        }
      } else if (opcode == 0x8) {
        _closeCode = payload.length >= 2
            ? (payload[0] << 8) | payload[1]
            : null;
      }
    }
  }

  void _finish() {
    if (!_upgraded.isCompleted) {
      _upgraded.completeError(StateError('closed before the upgrade'));
    }
    if (!_gone.isCompleted) _gone.complete(_closeCode);
    for (final w in _waiting) {
      w.completeError(StateError('socket closed'));
    }
    _waiting.clear();
  }
}

void main() {
  test('the byte cap leaves everything the length cap accepts alone', () async {
    final server = await bootServer();
    final client = await _RawClient.connect(server);

    // 4096 UTF-16 code units of a 3-byte character: the largest text frame the
    // `maxClientFrameLength` check accepts is also the largest the byte cap
    // accepts, so this must reach the session and be answered normally.
    final text = '€' * maxClientFrameLength;
    final bytes = utf8.encode(text);
    expect(bytes.length, maxClientFrameBytes);
    client.sendFrame(declaredLength: bytes.length, payload: bytes);

    expect(await client.nextText(), '{"t":"error","code":"bad_message"}');
    expect(server.rooms.sessionCount, 1, reason: 'the session survives');
  });

  test('an oversized frame is refused before its payload arrives', () async {
    final server = await bootServer();
    final client = await _RawClient.connect(server);
    await pumpUntil(() => server.rooms.sessionCount == 1);

    // A header promising one byte more than the cap, and not a single byte of
    // the payload: nothing may be buffered while waiting for the rest.
    client.sendFrame(declaredLength: maxClientFrameBytes + 1);

    expect(
      await client.gone.timeout(const Duration(seconds: 10)),
      wsProtocolError,
      reason: 'the socket must be closed from the frame header alone',
    );
    await pumpUntil(
      () => server.rooms.sessionCount == 0,
      reason: 'the refused session must be reclaimed',
    );
  });

  test('a 64-bit length beyond the cap is refused too', () async {
    final server = await bootServer();
    final client = await _RawClient.connect(server);
    client.sendFrame(declaredLength: 0x7fffffffffff);
    expect(
      await client.gone.timeout(const Duration(seconds: 10)),
      wsProtocolError,
    );
  });

  test('fragments that add up beyond the cap are refused', () async {
    final server = await bootServer();
    final client = await _RawClient.connect(server);

    // Two halves that each fit but together do not: the cap applies to the
    // message, because that is what `dart:io` reassembles into one buffer.
    final half = List<int>.filled(maxClientFrameBytes ~/ 2 + 1, 0x41);
    client.sendFrame(
      declaredLength: half.length,
      payload: half,
      opcode: 0x1,
      fin: false,
    );
    client.sendFrame(declaredLength: half.length, opcode: 0x0);

    expect(
      await client.gone.timeout(const Duration(seconds: 10)),
      wsProtocolError,
      reason: 'the second fragment must be refused from its header',
    );
  });
}
