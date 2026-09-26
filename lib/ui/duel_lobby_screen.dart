import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/game_theme.dart';
import '../app/settings.dart';
import '../app/strings.dart';
import '../game/controllers/duel_controller.dart';
import '../game/input/input_controller.dart';
import '../game/input/input_factory.dart';
import '../game/input/keyboard_input.dart';
import '../services/audio_service.dart';
import '../services/duel_client.dart';
import '../services/haptics.dart';
import 'duel_screen.dart';
import 'widgets/ball_count_selector.dart';
import 'widgets/code_display.dart';
import 'widgets/neon_button.dart';
import 'widgets/neon_panel.dart';

enum _LobbyMode { menu, create, join }

/// Duel lobby: create a room (shows the 4-letter code) or join one.
class DuelLobbyScreen extends StatefulWidget {
  const DuelLobbyScreen({super.key, this.connector});

  static const String route = '/duel';

  /// Overrides how the WebSocket is opened; the default connects for real.
  /// Tests inject an in-memory transport here.
  final WsConnector? connector;

  @override
  State<DuelLobbyScreen> createState() => _DuelLobbyScreenState();
}

class _DuelLobbyScreenState extends State<DuelLobbyScreen> {
  final TextEditingController _code = TextEditingController();
  DuelController? _controller;
  _LobbyMode _mode = _LobbyMode.menu;
  bool _busy = false;
  bool _inGame = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    super.dispose();
  }

  DuelController _ensureController() {
    final existing = _controller;
    if (existing != null) return existing;
    final settings = context.read<Settings>();
    final created = DuelController(
      client: DuelClient(
        wsUri: () => settings.wsUrl,
        connector: widget.connector,
      ),
      settings: settings,
      audio: context.read<AudioService>(),
      haptics: context.read<Haptics>(),
      input: CompositeInput(<InputController>[
        KeyboardInput(),
        createInputController(settings),
      ]),
    )..addListener(_onControllerChanged);
    _controller = created;
    return created;
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final controller = _controller;
    if (controller != null && controller.hasMatch && !_inGame) {
      _inGame = true;
      _openGame(controller);
    }
    setState(() {});
  }

  Future<void> _openGame(DuelController controller) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DuelScreen(controller: controller),
      ),
    );
    _inGame = false;
    if (!mounted) return;
    setState(() => _mode = _LobbyMode.menu);
  }

  String? _validName(Strings s) {
    final name = normalizeName(context.read<Settings>().playerName);
    if (name == null) setState(() => _error = s.t('error.bad_name'));
    return name;
  }

  Future<void> _create() async {
    final s = Strings.read(context);
    final name = _validName(s);
    if (name == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _mode = _LobbyMode.create;
    });
    try {
      // The creator's choice of game travels with the room (SPEC §2.3): the
      // server puts it in `room` and `start`, so the joiner is told before the
      // first serve and both clients predict the same simulation.
      await _ensureController().createRoom(
        name,
        ballCount: context.read<Settings>().ballCount,
      );
    } on DuelClientException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = s.error(e.code);
        _mode = _LobbyMode.menu;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    final s = Strings.read(context);
    final code = normalizeRoomCode(_code.text);
    if (code == null) {
      setState(() => _error = s.t('error.bad_code'));
      return;
    }
    final name = _validName(s);
    if (name == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _ensureController().joinRoom(name, code);
    } on DuelClientException catch (e) {
      if (!mounted) return;
      setState(() => _error = s.error(e.code));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _backToMenu() {
    final controller = _controller;
    if (controller != null) {
      controller.leaveRoom();
      controller.disconnect();
    }
    setState(() {
      _mode = _LobbyMode.menu;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final controller = _controller;
    final code = controller?.roomCode;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('duel.title'))),
      body: NeonBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _statusBar(s, controller),
                const SizedBox(height: 20),
                if (_mode == _LobbyMode.create && code != null)
                  _waitingRoom(s, controller!, code)
                else if (_mode == _LobbyMode.join)
                  _joinPanel(s)
                else
                  _menuPanel(s),
                if (_error != null) ...[
                  const SizedBox(height: 18),
                  NeonPanel(
                    color: theme.danger,
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: theme.danger),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusBar(Strings s, DuelController? controller) {
    final theme = GameTheme.of(context);
    final state = controller?.status ?? DuelClientState.disconnected;
    final connected =
        state != DuelClientState.disconnected &&
        state != DuelClientState.connecting;
    final label = switch (state) {
      DuelClientState.disconnected => s.t('duel.disconnected'),
      DuelClientState.connecting => s.t('duel.connecting'),
      _ => s.t('duel.connected'),
    };
    final ping = controller?.ping;
    final dot = connected ? theme.success : theme.textDim;
    return NeonPanel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      glow: false,
      color: dot,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dot,
              boxShadow: theme.hasGlow
                  ? [
                      BoxShadow(
                        color: dot.withValues(alpha: 0.6 * theme.glow),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: theme.textDim),
            ),
          ),
          if (ping != null)
            Text(
              '${s.t('duel.ping')} $ping ms',
              style: TextStyle(fontSize: 12, color: theme.textDim),
            ),
        ],
      ),
    );
  }

  Widget _menuPanel(Strings s) {
    final theme = GameTheme.of(context);
    final settings = context.watch<Settings>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Directly above CREATE ROOM, because in a duel the count is a property
        // of the room being created and not of this phone: the creator picks the
        // game, both players play it, and the joiner is told. Joining uses
        // whatever the room already is, which is why this sits with the create
        // button rather than at the top of the screen.
        NeonPanel(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          glow: false,
          child: BallCountSelector(
            value: settings.ballCount,
            onChanged: _busy
                ? null
                : (n) => setState(() => settings.ballCount = n),
            footnote: s.t('duel.ballsHost'),
          ),
        ),
        const SizedBox(height: 14),
        NeonButton(
          label: s.t('duel.create'),
          icon: Icons.add_circle_outline,
          color: theme.accentDuel,
          onPressed: _busy ? null : _create,
        ),
        const SizedBox(height: 12),
        NeonButton(
          label: s.t('duel.join'),
          icon: Icons.login,
          filled: false,
          onPressed: _busy
              ? null
              : () => setState(() {
                  _mode = _LobbyMode.join;
                  _error = null;
                }),
        ),
      ],
    );
  }

  Widget _joinPanel(Strings s) {
    final theme = GameTheme.of(context);
    return NeonPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.t('duel.joinTitle'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            textAlign: TextAlign.center,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            maxLength: roomCodeLength,
            inputFormatters: [RoomCodeFormatter()],
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _join(),
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              letterSpacing: 10,
            ),
            decoration: InputDecoration(
              labelText: s.t('duel.roomCode'),
              hintText: s.t('duel.enterCode'),
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          NeonButton(
            label: s.t('duel.join'),
            onPressed: _busy || _code.text.length != roomCodeLength
                ? null
                : _join,
          ),
          const SizedBox(height: 10),
          NeonButton(
            label: s.t('common.cancel'),
            filled: false,
            color: theme.textDim,
            height: 48,
            fontSize: 13,
            onPressed: _backToMenu,
          ),
        ],
      ),
    );
  }

  Widget _waitingRoom(Strings s, DuelController controller, String code) {
    final theme = GameTheme.of(context);
    final opponent = controller.opponentName;
    return NeonPanel(
      color: theme.accentDuel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.t('duel.roomCode'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.textDim,
              fontSize: 12,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 14),
          CodeDisplay(code: code, color: theme.accentDuel),
          const SizedBox(height: 14),
          // What this room is, stated in the waiting room: the creator sees the
          // game they asked for while they wait, and it is the same sentence the
          // joiner is shown before the first serve.
          Text(
            s.f('duel.ballsRoom', {'balls': s.balls(controller.ballCount)}),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.textDim, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  opponent.isEmpty
                      ? s.t('duel.waiting')
                      : s.f('duel.opponentJoined', {'name': opponent}),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: NeonButton(
                  label: s.t('duel.copy'),
                  height: 48,
                  fontSize: 12,
                  onPressed: () => _copy(code, s.t('duel.copied')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: NeonButton(
                  label: s.t('duel.share'),
                  height: 48,
                  fontSize: 12,
                  filled: false,
                  onPressed: () => _copy(
                    s.f('duel.shareText', {'code': code}),
                    s.t('duel.shared'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          NeonButton(
            label: s.t('duel.leave'),
            filled: false,
            color: theme.textDim,
            height: 46,
            fontSize: 12,
            onPressed: _backToMenu,
          ),
        ],
      ),
    );
  }
}

/// Keeps a room-code field uppercase, inside the code alphabet and at most
/// [roomCodeLength] characters long.
class RoomCodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final buffer = StringBuffer();
    for (final rune in newValue.text.toUpperCase().runes) {
      final c = String.fromCharCode(rune);
      if (roomCodeAlphabet.contains(c)) buffer.write(c);
      if (buffer.length == roomCodeLength) break;
    }
    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
