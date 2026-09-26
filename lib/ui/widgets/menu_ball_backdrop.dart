/// The living background of the title screen: the ball the player has equipped,
/// drifting behind the menu and rolling downhill as the phone is tilted.
///
/// **It is decoration, and it is built like decoration.** The motion is
/// [MenuBallMotion] — a dozen lines of Euler integration in screen pixels that
/// share no code, no constant and no state with `packages/arco_core`. The server
/// re-simulates every submitted replay to keep the leaderboard honest, so the
/// simulation is not something a background animation gets to touch, or import.
/// What *is* reused is the drawing: the real [BallArt] for the equipped skin, so
/// a bought ball is visible where the player looks most, and the app's one
/// accelerometer path ([TiltInput]) rather than a second one.
///
/// **It sleeps.** A ticker and an accelerometer are the two easiest ways to
/// flatten a battery behind a menu nobody is playing, so both stop when the app
/// leaves the foreground and when the player pushes a screen over the menu, and
/// both come back when they come back. When the setting is off — or the system
/// asks for reduced motion — [MenuBallLayer] is never built at all, so there is
/// nothing to stop and no sensor to open.
///
/// **It is quiet.** The whole ball, wake and bloom included, is composited
/// through one layer at [backdropOpacity]: dimming the art from the outside is
/// the only way to be certain that nothing inside it comes out brighter than the
/// text in front of it.
library;

import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../app/cosmetics.dart';
import '../../app/game_theme.dart';
import '../../app/settings.dart';
import '../../game/arena_geometry.dart';
import '../../game/input/tilt_input.dart';
import '../../game/render/ball_art.dart';
import '../../game/render/cosmetic_art.dart';
import '../../game/render/fx_state.dart';

/// Drops the drifting ball behind a menu, or nothing at all.
///
/// Nothing at all in two cases, and in both of them [MenuBallLayer] is never
/// constructed, so no ticker runs and no sensor is opened:
///
/// * [Settings.menuMotion] is off — movement behind text is unpleasant for some
///   people, so it is one switch away;
/// * the platform asks for reduced motion (`MediaQuery.disableAnimationsOf`),
///   which is the same request made by somebody who should not have to find the
///   switch. Motion sensitivity can mean nausea, not just annoyance.
class MenuBallBackdrop extends StatelessWidget {
  const MenuBallBackdrop({super.key, this.accelerometer});

  /// Sensor stream to read; null means the real `sensors_plus` one. A test hands
  /// over a fake, exactly as the duel lobby takes a connector.
  final Stream<AccelerometerEvent>? accelerometer;

  @override
  Widget build(BuildContext context) {
    final wanted = context.select<Settings, bool>((s) => s.menuMotion);
    if (!wanted || MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox.shrink();
    }
    // Behind the wordmark, the nickname field and four buttons: it must never be
    // in the way of a tap meant for any of them.
    return IgnorePointer(child: MenuBallLayer(accelerometer: accelerometer));
  }
}

/// The part that actually runs. Use [MenuBallBackdrop], which decides whether
/// this should exist at all.
class MenuBallLayer extends StatefulWidget {
  const MenuBallLayer({super.key, this.accelerometer});

  /// Sensor stream to read; null means the real one.
  final Stream<AccelerometerEvent>? accelerometer;

  @override
  MenuBallLayerState createState() => MenuBallLayerState();
}

class MenuBallLayerState extends State<MenuBallLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// One motion step and one repaint per 33 ms, i.e. 30 Hz — half the rate the
  /// arena paints at.
  ///
  /// Nobody can see the difference on a ball that drifts a pixel and a half per
  /// step, and it halves the painting. It does not halve the *frames*: a running
  /// [Ticker] asks for a vsync every time, so while this is on the title screen
  /// produces frames at the display's full rate — where with it off the screen
  /// is idle and produces none — and half of those frames re-rasterize a picture
  /// that has not changed. What this buys is the paint, not the wake-up.
  ///
  /// That the ticker fires every frame is also why the step is accumulated
  /// rather than taken per tick: the motion then runs at the same rate on a
  /// 60 Hz and on a 120 Hz display.
  static const Duration stepPeriod = Duration(milliseconds: 33);

  /// The decorative arena's radius, as a fraction of the shorter side of the box.
  ///
  /// This is the one number that sizes everything the skin draws: the ball comes
  /// out at [BallArt.bodyRadius] of it — about 15 pt across on the narrowest
  /// phone, half again the 10 pt it is in play — and every wake scales with it.
  /// Half again, because in play the eye is hunting it and here it is behind
  /// four buttons at a fifth of the brightness.
  static const double arenaScale = 0.66;

  late final Ticker _ticker;
  late final TiltInput _tilt;
  final FxState _fx = FxState();
  final MenuBallMotion _motion = MenuBallMotion();
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  BallArt? _art;
  BallSkin? _skin;
  Size _box = Size.zero;
  double _scale = 0;
  Duration _last = Duration.zero;
  double _pending = 0;
  bool _foreground = true;
  bool _visible = true;

  /// Whether the animation is running at all. The two things that stop it are
  /// the app leaving the foreground and a screen being pushed over the menu.
  @visibleForTesting
  bool get running => _ticker.isActive;

  /// The decorative ball's position and velocity, for tests.
  @visibleForTesting
  MenuBallMotion get motion => _motion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    // The app's one accelerometer path (SPEC §5.2), asked for a sample at 15 Hz
    // instead of the paddle's 50: a lava lamp does not care, and the sampling
    // rate is most of what an open sensor costs.
    _tilt = TiltInput(
      settings: context.read<Settings>(),
      source: widget.accelerometer,
      samplingPeriod: SensorInterval.uiInterval,
    );
    _ticker = createTicker(_onTick);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Whether this screen is visible at all, which `TickerMode` already knows:
    // the [Overlay] entry of a route that a pushed opaque one has covered mutes
    // its subtree's tickers. Muting alone stops the drawing, but a muted ticker
    // still holds the accelerometer open, which is the part that costs a
    // battery — so the same flag stops both. Reading it rather than the
    // navigator also covers everything else that mutes a subtree, not only a
    // pushed route.
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  /// Starts or stops the ticker *and* the sensor together. Idempotent: both
  /// reasons to stop arrive independently and either may repeat.
  void _sync() {
    final run = _foreground && _visible;
    if (run == _ticker.isActive) return;
    if (run) {
      // A stopped [Ticker] restarts its clock from zero, so the next delta has
      // to be measured from scratch rather than from a stale elapsed time.
      _last = Duration.zero;
      _pending = 0;
      _tilt.resume();
      _ticker.start();
    } else {
      _ticker.stop();
      _tilt.pause();
    }
  }

  void _onTick(Duration elapsed) {
    final step = stepPeriod.inMicroseconds / 1000000.0;
    final dt = _last == Duration.zero
        ? step
        : (elapsed - _last).inMicroseconds / 1000000.0;
    _last = elapsed;
    _pending += dt.clamp(0.0, 0.25);
    if (_pending < step) return;
    final advance = _pending;
    _pending = 0;
    if (_box.isEmpty || _scale <= 0) return;
    _motion.step(_box, advance, _tilt.screenGravity);
    // Exactly one trail sample per rendered step, which is the invariant every
    // wake in `ball_art.dart` is written against (see [FxState.frames]).
    _fx.update(advance);
    _fx.trackPoint(_motion.position.dx / _scale, -_motion.position.dy / _scale);
    _repaint.value++;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker
      ..stop()
      ..dispose();
    // Releases the accelerometer subscription for good.
    _tilt.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = GameTheme.of(context);
    // The skin the player bought and equipped (SPEC §4.8), drawn by the very
    // same code the arena uses — not a second, plainer ball. It is a thing they
    // paid for, on the screen they see most.
    final skin = Equipped.of(context).ball;
    if (_skin != skin) {
      _skin = skin;
      _art = createBallArt(skin);
    }
    _tilt.orientation = MediaQuery.orientationOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.hasBoundedWidth && constraints.hasBoundedHeight
            ? Size(constraints.maxWidth, constraints.maxHeight)
            : Size.zero;
        final scale = box.shortestSide * arenaScale;
        if (scale != _scale) {
          _scale = scale;
          // The trail is kept in simulation units, so a path recorded at the old
          // scale would project to a wake that no longer follows the ball.
          _fx.ball(0).clearTrail();
        }
        _box = box;
        final art = _art!;
        // A guarded no-op once the size and the palette have settled, and what
        // tells the motion how big the ball it is carrying actually is.
        art.prepare(theme, scale);
        _motion.radius = art.bodyRadius;
        return RepaintBoundary(
          child: CustomPaint(
            painter: MenuBallPainter(
              art: art,
              fx: _fx,
              motion: _motion,
              theme: theme,
              scale: scale,
              opacity: backdropOpacity(theme),
              repaint: _repaint,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

/// How faint the drifting ball is drawn, in [theme].
///
/// Three figures rather than one, because the four palettes give the same art
/// wildly different contrast and the rule is about what the eye lands on: open
/// the screen and the buttons have to be what you see first.
///
/// * A blooming theme (Neon, Glass) spends most of a skin's alpha on glow, so it
///   needs the most to read as anything at all.
/// * Classic is pure white on pure black — the flattest, hardest mark of the
///   three dark looks, and it needs less.
/// * Modernist is near-black ink on paper: the strongest of the four, and the one
///   where a mark that is too dark competes with the type directly.
double backdropOpacity(GameTheme theme) {
  if (!theme.isDark) return 0.14;
  return theme.hasGlow ? 0.30 : 0.20;
}

/// Draws one decorative ball, wake and all, through a dimming layer.
class MenuBallPainter extends CustomPainter {
  MenuBallPainter({
    required this.art,
    required this.fx,
    required this.motion,
    required this.theme,
    required this.scale,
    required this.opacity,
    super.repaint,
  });

  final BallArt art;
  final FxState fx;
  final MenuBallMotion motion;
  final GameTheme theme;

  /// Pixels per simulation unit — the decorative arena's radius.
  final double scale;

  /// Alpha the whole thing is composited at.
  final double opacity;

  /// How far out from the ball the layer has to reach, in multiples of [scale]:
  /// enough for the longest wake, the widest spark drift and three sigma of the
  /// widest bloom.
  static const double bleed = 0.5;

  final Paint _dim = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    // Nothing until the first step has placed the ball: the alternative is one
    // frame of a ball in the top left corner.
    if (size.isEmpty || scale <= 0 || !fx.ball(0).live) return;
    art.prepare(theme, scale);
    final speed = motion.velocity.distance;
    final dir = speed < 1e-6 ? const Offset(0, -1) : motion.velocity / speed;
    // Body, wake, bloom and hot spots all go into one layer composited at
    // [opacity]: an additive glow or a white-hot highlight dimmed from the
    // outside cannot come out brighter than the text in front of it, whatever
    // the skin does inside.
    _dim.color = const Color(0xFFFFFFFF).withValues(alpha: opacity);
    canvas.saveLayer(
      Rect.fromCircle(center: motion.position, radius: scale * bleed),
      _dim,
    );
    // The projection the art draws through: the origin at the top left of the
    // box and one simulation unit to [scale] pixels, which is all `paintWake`
    // needs to turn the trail back into pixels.
    final geometry = ArenaGeometry(
      size: size,
      center: Offset.zero,
      radius: scale,
      rotated: false,
    );
    art.paintWake(canvas, geometry, fx, 0);
    art.paintBody(
      canvas,
      motion.position,
      art.bodyRadius,
      dir.dx,
      dir.dy,
      fx,
      0,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(MenuBallPainter oldDelegate) => true;
}

/// The decorative ball's own physics — all of it.
///
/// **This is not the game, and it must never become the game.** Everything here
/// is in screen pixels; there is no [GameState], no `Ball`, no tick rate and no
/// shared constant. `packages/arco_core` is what the server re-simulates to
/// verify a leaderboard run, and the price of letting a background animation
/// anywhere near it is a leaderboard nobody can trust.
///
/// Two pulls, a speed band and four walls:
///
/// * **gravity**, read from the accelerometer, so the ball rolls the way the
///   phone is leaned — the mapping the owner asked for, and the player's first
///   hint that this phone answers to being tilted at all (tilt is one of the
///   three control schemes);
/// * **a swirl**, a second pull that turns slowly all by itself (see [swirl]);
/// * **the speed band**, which is what keeps the whole thing unhurried: the two
///   pulls get to aim the ball and never get to race it or stall it;
/// * **the edges of the box**, which the ball bounces off.
class MenuBallMotion {
  /// The middle of the speed band, as a fraction of the box's shorter side per
  /// second.
  ///
  /// Not the speed the ball is actually seen to travel at. The two pulls below
  /// are strong enough to hold it against [fastest] nearly all the time, so in
  /// practice it moves at about 1.6 x this — some 45 px/s on a 375 pt phone, a
  /// crossing in eight seconds rather than the thirteen this figure alone
  /// suggests. [slowest] is reached only while a pull is turning the ball round.
  static const double cruise = 0.075;

  /// Acceleration under full gravity, as a fraction of the shorter side per
  /// second squared. Low enough that leaning the phone bends the path over a
  /// second or two instead of dropping the ball: a lava lamp, not a game.
  static const double pull = 0.055;

  /// The swirl, as a multiple of [pull]: a second pull that turns slowly and
  /// steadily on its own, with no sensor behind it.
  ///
  /// It is what keeps the ball travelling sideways instead of wedging in the low
  /// corner doing tiny bounces the way a real ball would, and it is the *only*
  /// thing moving it on a desktop or in the web build, where there is no
  /// accelerometer to read.
  ///
  /// What it does not do is lift the ball off the floor. A pull that turns at
  /// [swirlRate] bends the path into an orbit of radius `speed / swirlRate`, and
  /// gravity's steady share drags that orbit down onto the bottom wall: with
  /// the phone held upright the ball stays in the lowest third of the screen,
  /// sweeping from side to side behind the panels rather than touring the whole
  /// of it. Raising this figure does not change that — the size of the orbit is
  /// set by [swirlRate], not by how hard the pull is. Slowing [swirlRate] does.
  static const double swirl = 1.5;

  /// Radians per second the swirl turns — one full turn every twenty seconds.
  ///
  /// This, rather than [swirl], is what decides how much of the screen the ball
  /// covers: a pull that comes back round every `2 pi / swirlRate` closes the
  /// path into an orbit of radius roughly `speed / swirlRate`, which at this
  /// rate is about 150 pt — a third of the height of a phone, not the whole of
  /// it. Halving this doubles the orbit.
  static const double swirlRate = 0.31;

  /// The speed band, in multiples of [cruise].
  static const double slowest = 0.55;
  static const double fastest = 1.6;

  /// What gravity is taken to be when the device cannot say: half of it, down
  /// the screen. Enough that the ball still behaves like a ball on a desktop,
  /// little enough that the swirl keeps it touring rather than resting.
  static const Offset noSensor = Offset(0, 0.5);

  /// Where the ball starts, as a fraction of the box: low and to the left, well
  /// away from the wordmark, which is the one thing on the screen that should
  /// have the first frame to itself. Within a second or two the tilt has moved
  /// it anyway.
  static const Offset origin = Offset(0.28, 0.66);

  /// Which way it is first aimed, in radians of screen space (y down): up and to
  /// the right. Fixed rather than random, so a screenshot is reproducible.
  static const double heading = -0.9;

  /// Ball radius in pixels: the walls are met by the ball's edge, not its
  /// middle. Set from [BallArt.bodyRadius] by the layer.
  double radius = 8;

  /// Centre of the ball, in pixels from the top left of the box.
  Offset position = Offset.zero;

  /// Pixels per second.
  Offset velocity = Offset.zero;

  double _swirlPhase = 0;
  bool _placed = false;

  /// Advances by [dt] seconds inside [box].
  ///
  /// [gravity] is which way down is, in screen space (x right, y down), its
  /// length the share of gravity that lies in the screen plane: 1 for a phone
  /// held upright, 0 for one lying flat on a table. Null when there is no sensor
  /// to ask, which is every desktop and the web build — then [noSensor] stands
  /// in and the swirl does the work.
  void step(Size box, double dt, Offset? gravity) {
    if (box.isEmpty || dt <= 0) return;
    final unit = box.shortestSide;
    final speedUnit = cruise * unit;
    if (!_placed) {
      position = Offset(box.width * origin.dx, box.height * origin.dy);
      velocity = Offset(math.cos(heading), math.sin(heading)) * speedUnit;
      _placed = true;
    }
    _swirlPhase += dt * swirlRate;
    final swirlPull =
        Offset(math.cos(_swirlPhase), math.sin(_swirlPhase)) * swirl;
    var v = velocity + ((gravity ?? noSensor) + swirlPull) * (pull * unit * dt);
    // The speed band, direction untouched. This, rather than drag or a bouncier
    // wall, is what makes the motion unhurried at every tilt.
    final speed = v.distance;
    final wanted = (speed / speedUnit).clamp(slowest, fastest) * speedUnit;
    v = speed < 1e-3 ? swirlPull / swirl * wanted : v * (wanted / speed);
    var p = position + v * dt;
    // The edges of the screen are the walls, and they are all there is to bounce
    // off: the menu draws no arena ring, and a ball turning around at an
    // invisible circle in the middle of a menu would read as a bug, not a wall.
    //
    // Put *on* the wall and sent away from it, rather than mirrored through it,
    // so that no size of box and no length of frame can leave the ball outside
    // or shivering against the glass.
    final r = math.min(radius, unit / 2);
    final right = math.max(r, box.width - r);
    final bottom = math.max(r, box.height - r);
    if (p.dx < r) {
      p = Offset(r, p.dy);
      v = Offset(v.dx.abs(), v.dy);
    } else if (p.dx > right) {
      p = Offset(right, p.dy);
      v = Offset(-v.dx.abs(), v.dy);
    }
    if (p.dy < r) {
      p = Offset(p.dx, r);
      v = Offset(v.dx, v.dy.abs());
    } else if (p.dy > bottom) {
      p = Offset(p.dx, bottom);
      v = Offset(v.dx, -v.dy.abs());
    }
    position = p;
    velocity = v;
  }
}
