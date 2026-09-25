import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/cosmetics.dart';
import '../../app/game_theme.dart';
import '../../app/settings.dart';
import '../arena_geometry.dart';
import '../input/input_controller.dart';
import '../input/joystick_input.dart';
import '../input/tilt_input.dart';
import 'fx_state.dart';
import 'game_painter.dart';

/// Hosts the arena: a [Ticker]-driven [GamePainter], the pointer layer that
/// feeds the active control scheme and the joystick overlay.
///
/// The ticker calls [onFrame] with the real elapsed time (the controllers turn
/// that into fixed 60 Hz simulation steps) and then bumps a repaint notifier,
/// so frames never rebuild the widget tree.
class GameView extends StatefulWidget {
  const GameView({
    super.key,
    required this.stateOf,
    required this.fx,
    required this.onFrame,
    this.input,
    this.rotated = false,
    this.topInset = 0,
    this.bottomInset = 0,
    this.ownPlayer = 0,
  });

  /// Latest simulation state; null renders the empty arena.
  final GameState? Function() stateOf;
  final FxState fx;

  /// Wall-clock seconds since the previous frame (clamped to 0.25 s).
  final void Function(double dtSeconds) onFrame;

  /// Active control scheme; pointer events and the overlay are wired to it.
  final InputController? input;

  /// Duel player 1 sees the board rotated by 180°.
  final bool rotated;
  final double topInset;
  final double bottomInset;

  /// Player index drawn in the "own" colour.
  final int ownPlayer;

  @override
  State<GameView> createState() => _GameViewState();
}

class _GameViewState extends State<GameView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frames = ValueNotifier<int>(0);
  Duration _lastElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dtSeconds = _lastElapsed == Duration.zero
        ? 1 / 60
        : (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    widget.onFrame(dtSeconds.clamp(0.0, 0.25));
    _frames.value = _frames.value + 1;
  }

  @override
  void dispose() {
    _ticker.stop();
    _ticker.dispose();
    _frames.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.orientationOf(context);
    final theme = GameTheme.of(context);
    // What the player wears (SPEC §4.8). Provided above the navigator exactly
    // like the theme is, so equipping an item in the shop repaints the arena;
    // with nothing provided — a bare widget test, a build before the shop is
    // wired — this is the free ball and the free paddle.
    final equipped = Equipped.of(context);
    // The effects spawn in the active palette; the arena itself is repainted
    // from the ticker, so a theme switch shows up on the very next frame.
    widget.fx.theme = theme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final geometry = ArenaGeometry.fit(
          size,
          topInset: widget.topInset,
          bottomInset: widget.bottomInset,
          rotated: widget.rotated,
        );
        findInput<TiltInput>(widget.input)?.orientation = orientation;
        final pointer = findInput<PointerInputHandler>(widget.input);
        final joystick = findInput<JoystickInput>(widget.input);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: pointer == null
              ? null
              : (e) => pointer.onPointerDown(e, geometry),
          onPointerMove: pointer == null
              ? null
              : (e) => pointer.onPointerMove(e, geometry),
          onPointerUp: pointer == null
              ? null
              : (e) => pointer.onPointerUp(e.pointer),
          onPointerCancel: pointer == null
              ? null
              : (e) => pointer.onPointerUp(e.pointer),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: GamePainter(
                stateOf: widget.stateOf,
                fx: widget.fx,
                geometry: geometry,
                theme: theme,
                equipped: equipped,
                ownPlayer: widget.ownPlayer,
                repaint: _frames,
              ),
              foregroundPainter: joystick == null
                  ? null
                  : JoystickPainter(
                      joystick: joystick,
                      theme: theme,
                      repaint: _frames,
                    ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}

/// Draws the 1-D joystick: a pill-shaped track with a neon knob. Hidden in
/// floating mode until a finger is down.
class JoystickPainter extends CustomPainter {
  JoystickPainter({
    required this.joystick,
    this.theme = GameThemes.neon,
    super.repaint,
  });

  final JoystickInput joystick;
  final GameTheme theme;

  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Paint _glow = Paint()
    ..style = PaintingStyle.fill
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);

  @override
  void paint(Canvas canvas, Size size) {
    final active = joystick.active;
    if (joystick.side == JoystickSide.float && !active) return;
    final center = joystick.trackCenter(size);
    if (center == null) return;

    final opacity = active ? 1.0 : 0.45;
    final track = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: JoystickInput.trackHalfWidth * 2,
        height: JoystickInput.trackHalfHeight * 2,
      ),
      Radius.circular(JoystickInput.trackHalfHeight),
    );
    _fill
      ..maskFilter = null
      ..color = theme.panelFill.withValues(alpha: 0.55 * opacity);
    canvas.drawRRect(track, _fill);
    _stroke
      ..strokeWidth = 1.5
      ..color = theme.accent.withValues(alpha: 0.35 * opacity);
    canvas.drawRRect(track, _stroke);
    _stroke
      ..strokeWidth = 1
      ..color = theme.accent.withValues(alpha: 0.2 * opacity);
    canvas.drawLine(
      Offset(center.dx, center.dy - JoystickInput.trackHalfHeight * 0.45),
      Offset(center.dx, center.dy + JoystickInput.trackHalfHeight * 0.45),
      _stroke,
    );

    final knob = Offset(center.dx + joystick.knobOffset, center.dy);
    if (theme.hasGlow) {
      _glow.color = theme.accent.withValues(alpha: 0.45 * opacity * theme.glow);
      canvas.drawCircle(knob, JoystickInput.knobRadius * 0.9, _glow);
    }
    _fill.color = theme.accent.withValues(alpha: 0.85 * opacity);
    canvas.drawCircle(knob, JoystickInput.knobRadius * 0.8, _fill);
    _fill.color = theme.highlight.withValues(alpha: 0.85 * opacity);
    canvas.drawCircle(knob, JoystickInput.knobRadius * 0.3, _fill);
  }

  @override
  bool shouldRepaint(JoystickPainter oldDelegate) => true;
}
