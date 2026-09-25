import 'dart:ui' as ui;

import 'package:arco/app/game_theme.dart';
import 'package:arco/game/arena_geometry.dart';
import 'package:arco/game/input/joystick_input.dart';
import 'package:arco/game/render/fx_state.dart';
import 'package:arco/game/render/game_painter.dart';
import 'package:arco/game/render/game_view.dart';
import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart' hide Simulation;
import 'package:flutter_test/flutter_test.dart';

const Size iPhoneSe = Size(375, 667);

/// Runs [ticks] of a real game so the painter gets a lifelike state.
GameState simulate(GameMode mode, int seed, int ticks) {
  final state = GameState.initial(GameConfig(mode: mode, seed: seed));
  final inputs = <PlayerInput>[
    for (var i = 0; i < state.config.playerCount; i++) PlayerInput.none,
  ];
  for (var t = 0; t < ticks; t++) {
    for (var p = 0; p < inputs.length; p++) {
      inputs[p] = ScriptedInput.aimAtBall(state, p);
    }
    Simulation.step(state, inputs);
  }
  return state;
}

/// Adds a wall and two pickups (one of them about to expire, i.e. blinking).
void decorate(GameState state) {
  state.walls.add(
    Wall(id: 90, x1: -0.25, y1: 0.1, x2: 0.2, y2: 0.35, ttl: 600, age: 40),
  );
  state.walls.add(
    Wall(id: 91, x1: 0.1, y1: -0.3, x2: 0.4, y2: -0.1, ttl: 600, age: 5),
  );
  state.pickups.add(
    Pickup(id: 92, type: PickupType.heart, x: -0.3, y: -0.2, ttl: 400),
  );
  state.pickups.add(
    Pickup(id: 93, type: PickupType.star, x: 0.35, y: 0.25, ttl: 60),
  );
}

FxState busyFx(
  GameState state, {
  int ownPlayer = 0,
  GameTheme theme = GameThemes.neon,
}) {
  final fx = FxState()
    ..ballSmoothing = 0.4
    ..theme = theme;
  for (var i = 0; i < 40; i++) {
    fx.trackBall(state.ball);
    fx.update(1 / 60);
  }
  fx.applyEvent(
    const GameEvent(GameEventType.paddleHit, player: 0, x: 0.1, y: -0.9),
    state,
    ownPlayer: ownPlayer,
  );
  fx.applyEvent(
    const GameEvent(
      GameEventType.pickup,
      player: 1,
      x: 0.2,
      y: 0.3,
      pickup: PickupType.star,
    ),
    state,
    ownPlayer: ownPlayer,
  );
  fx.applyEvent(
    const GameEvent(GameEventType.lifeLost, player: 0, x: 0, y: -1.05),
    state,
    ownPlayer: ownPlayer,
  );
  fx.setCountdown('3');
  return fx;
}

void paint(GamePainter painter, Size size) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, size);
  final picture = recorder.endRecording();
  expect(picture, isNotNull);
  picture.dispose();
}

void main() {
  // Every theme must survive a full frame: each one takes a different path
  // through the painter (glow on or off, comet / dots / no trail, round or
  // butt caps, scanlines, vignette).
  for (final theme in GameThemes.all) {
    final name = theme.id.name;

    testWidgets('paints a solo game with every effect ($name)', (tester) async {
      final state = simulate(GameMode.solo, 1234, 400);
      decorate(state);
      final fx = busyFx(state, theme: theme);
      final geometry = ArenaGeometry.fit(
        iPhoneSe,
        topInset: 96,
        bottomInset: 24,
      );
      expect(geometry.radius, greaterThan(100));
      paint(
        GamePainter(
          stateOf: () => state,
          fx: fx,
          geometry: geometry,
          theme: theme,
        ),
        iPhoneSe,
      );
    });

    testWidgets('paints a duel game rotated for player 1 ($name)', (
      tester,
    ) async {
      final state = simulate(GameMode.duel, 99, 400);
      decorate(state);
      final fx = busyFx(state, ownPlayer: 1, theme: theme);
      final geometry = ArenaGeometry.fit(
        iPhoneSe,
        topInset: 74,
        bottomInset: 74,
        rotated: true,
      );
      paint(
        GamePainter(
          stateOf: () => state,
          fx: fx,
          geometry: geometry,
          theme: theme,
          ownPlayer: 1,
        ),
        iPhoneSe,
      );
      // Player 1's own paddle (start angle pi/2) must be drawn at the bottom.
      final own = geometry.toScreen(0, 1);
      expect(own.dy, greaterThan(geometry.center.dy));
    });

    testWidgets('paints an empty arena and an empty canvas safely ($name)', (
      tester,
    ) async {
      final geometry = ArenaGeometry.fit(iPhoneSe);
      paint(
        GamePainter(
          stateOf: () => null,
          fx: FxState(),
          geometry: geometry,
          theme: theme,
        ),
        iPhoneSe,
      );
      paint(
        GamePainter(
          stateOf: () => null,
          fx: FxState(),
          geometry: geometry,
          theme: theme,
        ),
        Size.zero,
      );
    });
  }

  testWidgets('paints the joystick overlay while a finger is down', (
    tester,
  ) async {
    final joystick = JoystickInput();
    final geometry = ArenaGeometry.fit(iPhoneSe);
    joystick.onPointerDown(
      const PointerDownEvent(pointer: 1, position: Offset(180, 560)),
      geometry,
    );
    joystick.onPointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(140, 560)),
      geometry,
    );
    for (final theme in GameThemes.all) {
      paint2(JoystickPainter(joystick: joystick, theme: theme), iPhoneSe);
    }
    joystick.onPointerUp(1);
    // Floating mode hides the pill again once released.
    paint2(JoystickPainter(joystick: joystick), iPhoneSe);
    joystick.dispose();
  });

  test('the particle pool is capped', () {
    final state = GameState.initial(
      const GameConfig(mode: GameMode.solo, seed: 1),
    );
    final fx = FxState();
    for (var i = 0; i < 60; i++) {
      fx.emitBurst(0, 0, color: GameThemes.neon.accent, count: 20);
    }
    expect(fx.particles, hasLength(FxState.maxParticles));
    expect(
      fx.particles.where((p) => p.alive).length,
      lessThanOrEqualTo(FxState.maxParticles),
    );
    fx.applyEvent(const GameEvent(GameEventType.gameOver), state);
    expect(fx.shake, 1);
  });
}

void paint2(CustomPainter painter, Size size) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, size);
  recorder.endRecording().dispose();
}
