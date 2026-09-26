import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:arco/app/cosmetics.dart';
import 'package:arco/app/game_theme.dart';
import 'package:arco/game/arena_geometry.dart';
import 'package:arco/game/render/ball_art.dart';
import 'package:arco/game/render/fx_state.dart';
import 'package:arco/game/render/game_painter.dart';
import 'package:arco/game/render/paddle_art.dart';
import 'package:arco_core/arco_core.dart';
import 'package:arco/game/render/game_view.dart';
import 'package:flutter/material.dart' hide Simulation;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const Size iPhoneSe = Size(375, 667);

/// A real game, stepped with real inputs, with the wake fed one sample per
/// rendered frame — which is what a live frame does, so the trail curves the way
/// the ball actually flew.
({GameState state, FxState fx}) livePose(
  GameMode mode,
  int seed, {
  int ticks = 400,
  int frames = 60,
  int ballCount = minBallCount,
  GameTheme theme = GameThemes.neon,
}) {
  final state = GameState.initial(
    GameConfig(mode: mode, seed: seed, ballCount: ballCount),
  );
  final inputs = <PlayerInput>[
    for (var i = 0; i < state.config.playerCount; i++) PlayerInput.none,
  ];
  void step() {
    for (var p = 0; p < inputs.length; p++) {
      inputs[p] = ScriptedInput.aimAtBall(state, p);
    }
    Simulation.step(state, inputs);
  }

  for (var t = 0; t < ticks; t++) {
    step();
  }
  final fx = FxState()..theme = theme;
  for (var f = 0; f < frames; f++) {
    step();
    fx.trackBalls(state.balls);
    fx.update(1 / 60);
  }
  return (state: state, fx: fx);
}

void paint(GamePainter painter, Size size) {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  recorder.endRecording().dispose();
}

/// The frame as raw RGBA, for the tests that have to look at what was drawn.
Future<ByteData> render(GamePainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.round(), size.height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  picture.dispose();
  image.dispose();
  return data!;
}

/// How far apart two frames are at one pixel, 0 … 765.
int pixelDelta(ByteData a, ByteData b, Offset at, Size size) {
  final x = at.dx.round().clamp(0, size.width.round() - 1);
  final y = at.dy.round().clamp(0, size.height.round() - 1);
  final i = (y * size.width.round() + x) * 4;
  var sum = 0;
  for (var c = 0; c < 3; c++) {
    sum += (a.getUint8(i + c) - b.getUint8(i + c)).abs();
  }
  return sum;
}

/// A bare board with the ball in flight at ([x], [y]).
GameState _ballAt(double x, double y) {
  final state = GameState.initial(
    const GameConfig(mode: GameMode.solo, seed: 3),
  );
  state.phase = Phase.playing;
  state.serveTimer = 0;
  state.balls[0]
    ..active = true
    ..x = x
    ..y = y
    ..vx = 0.60
    ..vy = 0.45
    ..speed = 0.75
    ..owner = 0;
  return state;
}

/// The wake that goes with [_ballAt]: the ball walked back along its own
/// velocity and fed forwards, and a frame counter far enough in that an ember's
/// whole shower is alight.
FxState _seededWake(GameState state, GameTheme theme) {
  final fx = FxState()
    ..theme = theme
    ..time = 0.62
    ..frames = 600;
  final ball = state.balls[0];
  final x = ball.x;
  final y = ball.y;
  const dt = 1 / 60;
  for (var i = FxState.trailLength - 1; i >= 0; i--) {
    ball
      ..x = x - ball.vx * dt * i
      ..y = y - ball.vy * dt * i;
    fx.trackBall(ball, smooth: false);
  }
  ball
    ..x = x
    ..y = y;
  return fx;
}

void main() {
  const size = Size(400, 400);
  final geometry = ArenaGeometry(
    size: size,
    center: const Offset(200, 200),
    radius: 175,
    rotated: false,
  );

  // Every skin has to survive a full frame in every theme, and the themes take
  // different paths through the art: bloom or no bloom, additive or ordinary
  // compositing, round or butt caps, a specular line or none.
  for (final theme in GameThemes.all) {
    final name = theme.id.name;

    testWidgets('every ball and paddle paints a solo frame ($name)', (
      tester,
    ) async {
      final pose = livePose(GameMode.solo, 1234, theme: theme);
      for (final ball in BallSkin.values) {
        for (final paddle in PaddleSkin.values) {
          final painter = GamePainter(
            stateOf: () => pose.state,
            fx: pose.fx,
            geometry: ArenaGeometry.fit(
              iPhoneSe,
              topInset: 96,
              bottomInset: 24,
            ),
            theme: theme,
            equipped: Equipped(ball: ball, paddle: paddle),
          );
          // Twice: the second frame runs with every cached path, filter and
          // scratch buffer already built, which is the state it spends its life
          // in.
          paint(painter, iPhoneSe);
          paint(painter, iPhoneSe);
        }
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('every ball and paddle paints a rotated duel frame ($name)', (
      tester,
    ) async {
      final pose = livePose(GameMode.duel, 99, theme: theme);
      for (final ball in BallSkin.values) {
        for (final paddle in PaddleSkin.values) {
          paint(
            GamePainter(
              stateOf: () => pose.state,
              fx: pose.fx,
              geometry: ArenaGeometry.fit(
                iPhoneSe,
                topInset: 74,
                bottomInset: 74,
                rotated: true,
              ),
              theme: theme,
              equipped: Equipped(ball: ball, paddle: paddle),
              ownPlayer: 1,
            ),
            iPhoneSe,
          );
        }
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('every skin survives the states that have no ball ($name)', (
      tester,
    ) async {
      final pose = livePose(GameMode.solo, 7, ticks: 60, frames: 0);
      // Between serves: no wake, no ball, the paddle still drawn.
      pose.state.balls[0].active = false;
      // And a ball that is somehow standing still, which is what a zero-length
      // velocity is: the art still needs a direction to point its nose at.
      final still = livePose(GameMode.solo, 7, ticks: 200);
      still.state.balls[0]
        ..vx = 0
        ..vy = 0;
      for (final ball in BallSkin.values) {
        for (final paddle in PaddleSkin.values) {
          final worn = Equipped(ball: ball, paddle: paddle);
          paint(
            GamePainter(
              stateOf: () => pose.state,
              fx: pose.fx,
              geometry: geometry,
              theme: theme,
              equipped: worn,
            ),
            size,
          );
          paint(
            GamePainter(
              stateOf: () => still.state,
              fx: still.fx,
              geometry: geometry,
              theme: theme,
              equipped: worn,
            ),
            size,
          );
          // A preview-sized arena, where every cached shape is rebuilt tiny.
          paint(
            GamePainter(
              stateOf: () => still.state,
              fx: still.fx,
              geometry: ArenaGeometry(
                size: const Size(40, 40),
                center: const Offset(20, 20),
                radius: 12,
                rotated: false,
              ),
              theme: theme,
              equipped: worn,
            ),
            const Size(40, 40),
          );
        }
      }
      expect(tester.takeException(), isNull);
    });

    // What a skin may never do is disagree with the simulation about where the
    // ball is. Whatever else it draws, the body has to cover the radius the ball
    // actually collides with, or a player pays money to be lied to.
    testWidgets('every ball fills its true collision radius ($name)', (
      tester,
    ) async {
      // A bare board — no walls, no pickups, the paddle where it starts — so the
      // only thing that can differ between the two frames is the ball.
      final state = _ballAt(0.15, 0.1);
      final fx = _seededWake(state, theme);
      final blank = _ballAt(0.15, 0.1)..balls[0].active = false;
      final at = geometry.toScreen(fx.ballX, fx.ballY);
      await tester.runAsync(() async {
        final without = await render(
          GamePainter(
            stateOf: () => blank,
            fx: FxState()..theme = theme,
            geometry: geometry,
            theme: theme,
          ),
          size,
        );
        for (final ball in BallSkin.values) {
          final drawn = await render(
            GamePainter(
              stateOf: () => state,
              fx: fx,
              geometry: geometry,
              theme: theme,
              equipped: Equipped(ball: ball),
            ),
            size,
          );
          final r = ballRadius * geometry.radius * 0.8;
          for (var i = 0; i < 8; i++) {
            final a = i * math.pi / 4;
            final p = at.translate(math.cos(a) * r, math.sin(a) * r);
            expect(
              pixelDelta(drawn, without, p, size),
              greaterThan(60),
              reason:
                  '${ball.id} in $name leaves a hole at '
                  '${a.toStringAsFixed(2)} rad',
            );
          }
        }
      });
    });

    // The same promise for the paddle, in the dimension the simulation actually
    // bounces off: the whole angular sweep is covered, and — in the themes with
    // no bloom to bleed — nothing outside it is.
    testWidgets('every paddle covers its whole sweep, and no more ($name)', (
      tester,
    ) async {
      final state = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 5),
      );
      state.balls[0].active = false;
      state.players[0].paddle.angle = bottomCenterAngle;
      final elsewhere = GameState.initial(
        const GameConfig(mode: GameMode.solo, seed: 5),
      );
      elsewhere.balls[0].active = false;
      elsewhere.players[0].paddle.angle = topCenterAngle;
      final fx = FxState()..theme = theme;
      Offset onRing(double angle) => geometry.toScreen(
        paddleRing * math.cos(angle),
        paddleRing * math.sin(angle),
      );
      await tester.runAsync(() async {
        final without = await render(
          GamePainter(
            stateOf: () => elsewhere,
            fx: fx,
            geometry: geometry,
            theme: theme,
          ),
          size,
        );
        for (final paddle in PaddleSkin.values) {
          final with_ = await render(
            GamePainter(
              stateOf: () => state,
              fx: fx,
              geometry: geometry,
              theme: theme,
              equipped: Equipped(paddle: paddle),
            ),
            size,
          );
          for (final k in [-0.94, -0.5, 0.0, 0.5, 0.94]) {
            final p = onRing(bottomCenterAngle + k * paddleHalfWidth);
            expect(
              pixelDelta(with_, without, p, size),
              greaterThan(60),
              reason: '${paddle.id} in $name is missing at $k of its sweep',
            );
          }
          if (theme.hasGlow) continue;
          // A flat theme has nothing that legitimately bleeds, so anything drawn
          // past the tips would be a paddle claiming reach it does not have.
          for (final k in [-1.35, 1.35]) {
            final p = onRing(bottomCenterAngle + k * paddleHalfWidth);
            expect(
              pixelDelta(with_, without, p, size),
              lessThan(24),
              reason: '${paddle.id} in $name reaches past its own end',
            );
          }
        }
      });
    });
  }

  test('the ember shower is bounded by construction', () {
    // It is drawn from the frame counter, not from a pool, so this is the whole
    // cost: ten circles, whatever the frame rate or the ball's speed.
    expect(EmberBallArt.sparkCount, 10);
    expect(
      EmberBallArt.sparkLifeFrames,
      lessThan(FxState.trailLength),
      reason: 'a spark must always find the point of the path it was shed from',
    );
  });

  // The hook the shop equips through: an `Equipped` provided above the arena,
  // exactly like the `GameTheme` is.
  testWidgets('the arena wears what is provided to it', (tester) async {
    const worn = Equipped(ball: BallSkin.prism, paddle: PaddleSkin.halo);
    GamePainter painterOf() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<GamePainter>()
        .first;

    Widget arena() => MaterialApp(
      home: GameView(stateOf: () => null, fx: FxState(), onFrame: (_) {}),
    );

    // Nothing provided: the free ball and the free paddle.
    await tester.pumpWidget(arena());
    expect(painterOf().equipped, Equipped.defaults);

    await tester.pumpWidget(
      Provider<Equipped>.value(value: worn, child: arena()),
    );
    expect(painterOf().equipped, worn);

    // And changing it repaints the arena in the new skins.
    await tester.pumpWidget(
      Provider<Equipped>.value(
        value: worn.copyWith(ball: BallSkin.ember),
        child: arena(),
      ),
    );
    expect(painterOf().equipped.ball, BallSkin.ember);
    expect(painterOf().equipped.paddle, PaddleSkin.halo);
  });

  test('a skin is resolved from its catalogue id, and rebuilt per painter', () {
    for (final skin in BallSkin.values) {
      expect(createBallArt(skin).skin, skin);
    }
    for (final skin in PaddleSkin.values) {
      expect(createPaddleArt(skin).skin, skin);
    }
    expect(
      createBallArt(BallSkin.comet),
      isNot(same(createBallArt(BallSkin.comet))),
    );
  });
}
