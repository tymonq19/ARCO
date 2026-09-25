import 'dart:async';

import 'package:arco_core/arco_core.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Connection state machine of [DuelClient] (SPEC §5.5).
enum DuelClientState {
  disconnected,
  connecting,
  lobby,
  waiting,
  countdown,
  playing,
  over,
}

/// Raised by [DuelClient.connect] when the handshake fails. [code] is one of
/// the `duel.error.*` keys (`connection`, `timeout`, `closed`, `bad_version`…).
class DuelClientException implements Exception {
  const DuelClientException(this.code, [this.detail]);
  final String code;
  final String? detail;

  @override
  String toString() =>
      'DuelClientException($code${detail == null ? '' : ': $detail'})';
}

/// Minimal transport abstraction so tests can drive the client without a
/// socket.
abstract class WsTransport {
  Stream<dynamic> get stream;
  void send(String data);
  Future<void> close();
}

typedef WsConnector = Future<WsTransport> Function(Uri uri);

class WebSocketChannelTransport implements WsTransport {
  WebSocketChannelTransport(this._channel);

  final WebSocketChannel _channel;

  static Future<WsTransport> connect(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;
    return WebSocketChannelTransport(channel);
  }

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close(ws_status.normalClosure);
}

/// WebSocket client for duel rooms. Sends `hello` on connect, pings every
/// two seconds and exposes typed message streams for the controller.
class DuelClient extends ChangeNotifier {
  DuelClient({
    required Uri Function() wsUri,
    WsConnector? connector,
    this.handshakeTimeout = const Duration(seconds: 8),
    this.pingInterval = const Duration(seconds: 2),
  }) : _wsUri = wsUri,
       _connector = connector ?? WebSocketChannelTransport.connect;

  final Uri Function() _wsUri;
  final WsConnector _connector;
  final Duration handshakeTimeout;
  final Duration pingInterval;

  final StreamController<ServerMsg> _messages =
      StreamController<ServerMsg>.broadcast();

  WsTransport? _transport;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Completer<void>? _welcome;
  bool _disposed = false;

  DuelClientState _state = DuelClientState.disconnected;
  int? _pingMs;
  int _serverTick = -1;
  String? _roomCode;
  int _slot = -1;
  List<String?> _names = const [null, null];
  String? _lastError;
  String _playerName = '';

  DuelClientState get state => _state;
  bool get isConnected =>
      _state != DuelClientState.disconnected &&
      _state != DuelClientState.connecting;

  /// Last measured round trip in milliseconds, null before the first pong.
  int? get pingMs => _pingMs;

  /// Server sim tick reported by the latest pong (-1 when not playing).
  int get serverTick => _serverTick;
  String? get roomCode => _roomCode;

  /// Own player index in the room (0 = creator / bottom, 1 = joiner / top).
  int get slot => _slot;
  List<String?> get names => _names;

  /// Last error code received (`duel.error.*` key), cleared on success.
  String? get lastError => _lastError;
  String get playerName => _playerName;

  Stream<ServerMsg> get messages => _messages.stream;
  Stream<RoomMsg> get roomMessages => _typed<RoomMsg>();
  Stream<StartMsg> get startMessages => _typed<StartMsg>();
  Stream<SnapMsg> get snapMessages => _typed<SnapMsg>();
  Stream<OverMsg> get overMessages => _typed<OverMsg>();
  Stream<PeerLeftMsg> get peerLeftMessages => _typed<PeerLeftMsg>();
  Stream<ErrorMsg> get errorMessages => _typed<ErrorMsg>();
  Stream<PongMsg> get pongMessages => _typed<PongMsg>();

  Stream<T> _typed<T extends ServerMsg>() =>
      _messages.stream.where((m) => m is T).cast<T>();

  /// Opens the socket, sends `hello` and waits for `welcome`.
  /// Throws [DuelClientException] on failure and returns to `disconnected`.
  Future<void> connect(String name) async {
    if (_disposed) throw const DuelClientException('closed', 'disposed');
    if (_state == DuelClientState.connecting) {
      await _welcome?.future;
      return;
    }
    if (isConnected) return;
    _playerName = name;
    _lastError = null;
    _setState(DuelClientState.connecting);
    final welcome = _welcome = Completer<void>();
    try {
      final uri = _wsUri();
      final transport = await _connector(uri).timeout(handshakeTimeout);
      _transport = transport;
      _sub = transport.stream.listen(
        _onFrame,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: false,
      );
      _send(HelloMsg(version: protocolVersion, name: name));
      await welcome.future.timeout(handshakeTimeout);
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(pingInterval, (_) => _ping());
      _ping();
    } on DuelClientException catch (e) {
      _lastError = e.code;
      await _teardown();
      rethrow;
    } on TimeoutException {
      _lastError = 'timeout';
      await _teardown();
      throw const DuelClientException('timeout');
    } on Object catch (e) {
      _lastError = 'connection';
      await _teardown();
      throw DuelClientException('connection', '$e');
    } finally {
      if (identical(_welcome, welcome)) _welcome = null;
    }
  }

  void createRoom() {
    _lastError = null;
    _send(const CreateRoomMsg());
  }

  void joinRoom(String code) {
    _lastError = null;
    _send(JoinRoomMsg(code: code));
  }

  void sendInput(int tick, PlayerInput input) {
    _send(InputMsg(tick: tick, input: input.encode()));
  }

  void rematch() => _send(const RematchMsg());

  /// Leaves the current room but keeps the socket open (back to lobby).
  void leave() {
    if (!isConnected) return;
    _send(const LeaveMsg());
    _roomCode = null;
    _slot = -1;
    _names = const [null, null];
    _serverTick = -1;
    _setState(DuelClientState.lobby);
  }

  /// Closes the socket cleanly.
  Future<void> disconnect() async {
    if (_state == DuelClientState.disconnected && _transport == null) return;
    await _teardown();
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    _messages.close();
    super.dispose();
  }

  // ----------------------------------------------------------------- internals

  void _send(ClientMsg msg) {
    final t = _transport;
    if (t == null) return;
    try {
      t.send(encodeMsg(msg));
    } on Object catch (e) {
      debugPrint('DuelClient: send failed: $e');
    }
  }

  void _ping() {
    if (!isConnected) return;
    _send(PingMsg(clientMs: DateTime.now().millisecondsSinceEpoch));
  }

  void _onFrame(dynamic frame) {
    final msg = ServerMsg.decode(frame);
    if (msg == null) {
      debugPrint('DuelClient: unparseable frame');
      return;
    }
    switch (msg) {
      case WelcomeMsg():
        if (_state == DuelClientState.connecting) {
          _setState(DuelClientState.lobby);
        }
        _welcome?.complete();
      case RoomMsg():
        _roomCode = msg.code;
        _slot = msg.slot;
        _names = msg.names;
        _lastError = null;
        _setState(DuelClientState.waiting);
      case StartMsg():
        _names = msg.names;
        _lastError = null;
        _setState(DuelClientState.countdown);
      case SnapMsg():
        if (_state != DuelClientState.playing) {
          _setState(DuelClientState.playing);
        }
      case OverMsg():
        _setState(DuelClientState.over);
      case PeerLeftMsg():
        // The room is gone (SPEC §3), but the duel screen is still on top and
        // keeps rendering the finished match, so the own slot and both names
        // must survive: they decide which half of the arena is "ours" and
        // which HUD strip is ours. `leave()` / `_teardown()` clear them once
        // the player actually goes back.
        _roomCode = null;
        _setState(DuelClientState.lobby);
      case PongMsg():
        final now = DateTime.now().millisecondsSinceEpoch;
        _pingMs = (now - msg.clientMs).clamp(0, 99999);
        _serverTick = msg.tick;
        notifyListeners();
      case ErrorMsg():
        _lastError = msg.code;
        final w = _welcome;
        if (w != null && !w.isCompleted) {
          w.completeError(DuelClientException(msg.code));
        } else {
          notifyListeners();
        }
    }
    if (!_messages.isClosed) _messages.add(msg);
  }

  void _onSocketError(Object error) {
    debugPrint('DuelClient: socket error: $error');
    _lastError = 'closed';
    final w = _welcome;
    if (w != null && !w.isCompleted) {
      w.completeError(DuelClientException('connection', '$error'));
      return;
    }
    _teardown();
  }

  void _onSocketDone() {
    final w = _welcome;
    if (w != null && !w.isCompleted) {
      w.completeError(const DuelClientException('closed'));
      return;
    }
    if (_state != DuelClientState.disconnected) {
      _lastError ??= 'closed';
      _teardown();
    }
  }

  Future<void> _teardown() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    final sub = _sub;
    _sub = null;
    final t = _transport;
    _transport = null;
    _roomCode = null;
    _slot = -1;
    _names = const [null, null];
    _pingMs = null;
    _serverTick = -1;
    _setState(DuelClientState.disconnected);
    await sub?.cancel();
    try {
      await t?.close();
    } on Object {
      // Already closed by the peer.
    }
  }

  void _setState(DuelClientState s) {
    if (_state == s) return;
    _state = s;
    if (!_disposed) notifyListeners();
  }
}
