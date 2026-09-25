/// Byte-level size guard for inbound WebSocket frames.
///
/// `dart:io` reassembles a whole WebSocket message - every fragment of it -
/// into one buffer before handing it to the application, and it has no
/// maximum-message-size knob. The [maxClientFrameLength] check in
/// [ClientSession] therefore runs *after* the frame is already in memory, so a
/// single socket could make the server allocate as much as it cares to send
/// before being told `bad_message`.
///
/// This wraps the hijacked socket of a `/ws` upgrade and reads each frame's
/// *declared* payload length straight out of its header, so a message over
/// [maxClientFrameBytes] is refused while it is still on the wire: nothing
/// beyond the 14-byte header is ever buffered, and the read side is torn down
/// at once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:stream_channel/stream_channel.dart';

import 'logging.dart';
import 'session.dart';

/// Hard cap on the wire size of one inbound WebSocket message.
///
/// A UTF-16 code unit costs at most 3 UTF-8 bytes, so no text frame that the
/// [maxClientFrameLength] check would accept can exceed this. The byte cap
/// therefore only ever rejects what the string cap would reject anyway - it
/// just does so before `dart:io` has buffered it.
const int maxClientFrameBytes = 3 * maxClientFrameLength;

/// Returns [request] with its hijack wrapped, so that a handler upgrading it to
/// a WebSocket reads the socket through the frame-size guard.
///
/// A request that cannot be hijacked (or whose hijacked sink is not a
/// `dart:io` [Socket], which is all `shelf_io` ever provides) is passed
/// through untouched.
Request guardClientFrames(
  Request request, {
  Logger? log,
  int maxBytes = maxClientFrameBytes,
}) {
  if (!request.canHijack) return request;
  return Request(
    request.method,
    request.requestedUri,
    protocolVersion: request.protocolVersion,
    headers: request.headersAll,
    handlerPath: request.handlerPath,
    url: request.url,
    context: request.context,
    onHijack: (onChannel) {
      try {
        request.hijack((channel) {
          final socket = channel.sink;
          if (socket is! Socket) {
            onChannel(channel);
            return;
          }
          // Exactly the channel `shelf_io` builds for a hijacked request, but
          // over the guarded socket: `shelf_web_socket` reads *and* writes
          // through `channel.sink`, which must stay a `dart:io` [Socket].
          final guarded = _GuardedSocket(socket, maxBytes, log);
          onChannel(StreamChannel<List<int>>(guarded, guarded));
        });
      } on HijackException {
        // `hijack` always throws this to tell the adapter not to write a
        // response. The returned request throws its own, and shelf runs this
        // callback from a bare microtask where a throw would escape as an
        // unhandled asynchronous error.
      }
    },
  );
}

/// A [Socket] that behaves exactly like the one it wraps, except that its
/// stream ends with an error as soon as an inbound frame header declares a
/// message larger than `maxBytes`.
///
/// The WebSocket layer reads with `cancelOnError`, so that error stops the
/// reading of the socket entirely and makes it send a 1002 (protocol error)
/// close frame.
class _GuardedSocket extends StreamView<Uint8List> implements Socket {
  factory _GuardedSocket(Socket socket, int maxBytes, Logger? log) {
    final scanner = _FrameScanner(maxBytes);
    var rejected = false;
    return _GuardedSocket._(
      socket,
      socket.transform(
        StreamTransformer<Uint8List, Uint8List>.fromHandlers(
          handleData: (chunk, sink) {
            // Once rejected, every remaining byte is dropped instead of
            // buffered: the teardown below may still be in flight.
            if (rejected) return;
            if (scanner.accepts(chunk)) {
              sink.add(chunk);
              return;
            }
            rejected = true;
            log?.info(
              'client frame refused: message of >= ${scanner.rejectedSize} '
              'bytes exceeds the $maxBytes byte cap',
            );
            sink.addError(
              const WebSocketException('client frame too large'),
              StackTrace.current,
            );
          },
        ),
      ),
    );
  }

  _GuardedSocket._(this._socket, super.stream);

  final Socket _socket;

  // `Socket` declares a private member (`_detachRaw`) that cannot be
  // implemented from outside `dart:io`; this turns it into a forwarder that
  // throws if anything ever calls it. Nothing on the WebSocket path does.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  InternetAddress get address => _socket.address;

  @override
  int get port => _socket.port;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  Future<dynamic> get done => _socket.done;

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) =>
      _socket.addStream(stream);

  @override
  Future<dynamic> close() => _socket.close();

  @override
  Future<dynamic> flush() => _socket.flush();

  @override
  void destroy() => _socket.destroy();

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
}

/// Tracks where the frame headers are in the inbound byte stream and how big
/// the message currently being assembled has been declared to be.
///
/// Only the header is inspected; the payload is counted, never kept. Frame
/// layout (RFC 6455 §5.2): `FIN|RSV|opcode`, `MASK|len7`, then 2 or 8 length
/// bytes when `len7` is 126 or 127, then the 4 mask bytes when `MASK` is set.
class _FrameScanner {
  _FrameScanner(this.maxMessageBytes);

  /// Largest message (sum of its fragments' payloads) still delivered.
  final int maxMessageBytes;

  /// A declared length whose high 32 bits are set is reported as this floor
  /// rather than computed, which also keeps the shifts below in 32 bits.
  static const int _hugeLength = 0x100000000;

  /// The header being read; at most 14 bytes (2 + 8 length + 4 mask).
  final List<int> _header = <int>[];

  /// Payload bytes of the current frame still to be skipped.
  int _payloadLeft = 0;

  /// Payload bytes declared so far for the message being assembled.
  int _messageBytes = 0;

  /// Declared size that tripped the cap; 0 while nothing has.
  int rejectedSize = 0;

  /// Whether [chunk] may be handed on, i.e. no frame in it (or before it)
  /// declared a message over [maxMessageBytes].
  bool accepts(List<int> chunk) {
    var i = 0;
    while (i < chunk.length) {
      if (_payloadLeft > 0) {
        final available = chunk.length - i;
        if (available < _payloadLeft) {
          _payloadLeft -= available;
          return true;
        }
        i += _payloadLeft;
        _payloadLeft = 0;
        continue;
      }
      _header.add(chunk[i++]);
      final size = _headerLength();
      if (size == null || _header.length < size) continue;
      final accepted = _startFrame();
      _header.clear();
      if (!accepted) return false;
    }
    return true;
  }

  /// Total length of the header being read, or null while it is still unknown.
  int? _headerLength() {
    if (_header.length < 2) return null;
    final len7 = _header[1] & 0x7f;
    final extra = len7 == 126
        ? 2
        : len7 == 127
        ? 8
        : 0;
    return 2 + extra + ((_header[1] & 0x80) != 0 ? 4 : 0);
  }

  /// Accounts for the frame whose complete header sits in [_header].
  bool _startFrame() {
    final len7 = _header[1] & 0x7f;
    final int payload;
    if (len7 == 126) {
      payload = (_header[2] << 8) | _header[3];
    } else if (len7 == 127) {
      if ((_header[2] | _header[3] | _header[4] | _header[5]) != 0) {
        return _reject(_hugeLength);
      }
      payload =
          (_header[6] << 24) |
          (_header[7] << 16) |
          (_header[8] << 8) |
          _header[9];
    } else {
      payload = len7;
    }

    final opcode = _header[0] & 0x0f;
    if (opcode >= 0x8) {
      // A control frame (close/ping/pong) is never part of a message and RFC
      // 6455 §5.5 caps its payload at 125 bytes.
      if (payload > 125) return _reject(payload);
      _payloadLeft = payload;
      return true;
    }
    // opcode 0 continues the message in progress; 1 (text) and 2 (binary)
    // start a new one. FIN ends it.
    if (opcode != 0x0) _messageBytes = 0;
    _messageBytes += payload;
    if (_messageBytes > maxMessageBytes) return _reject(_messageBytes);
    if ((_header[0] & 0x80) != 0) _messageBytes = 0;
    _payloadLeft = payload;
    return true;
  }

  bool _reject(int size) {
    rejectedSize = size;
    return false;
  }
}
