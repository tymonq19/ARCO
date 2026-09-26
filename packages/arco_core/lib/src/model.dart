/// Game model: config, entities, events and the full [GameState].
/// See SPEC.md §2.3 and §2.5.
library;

import 'constants.dart';
import 'det_math.dart';
import 'prng.dart';

enum GameMode { solo, duel }

enum Phase { serving, playing, gameOver }

enum PickupType { heart, star }

/// Shape of a [Wall] (SPEC §2.3). Every shape is collided as a polyline; the
/// shape only says how that polyline was built, which is what a renderer needs
/// to draw a curve as a curve instead of a chain of chords.
enum WallShape {
  /// Two vertices, one segment — the only wall the game had before shapes.
  straight,

  /// Three vertices: two equal arms meeting at a joint on the wall's center.
  bent,

  /// `wallCurveSegments + 1` vertices on a circular arc.
  curved,
}

enum GameEventType {
  serve,
  paddleHit,
  wallHit,
  pickup,
  pickupExpire,
  wallSpawn,
  wallExpire,
  lifeLost,
  gameOver,

  /// Reserved for clients that want a per-tick marker (never emitted by the
  /// simulation itself); kept last so the indices above stay stable.
  tick,
}

class GameConfig {
  const GameConfig({
    required this.mode,
    required this.seed,
    this.ballCount = minBallCount,
  }) : assert(ballCount >= minBallCount && ballCount <= maxBallCount);

  final GameMode mode;

  /// 32-bit unsigned seed.
  final int seed;

  /// Balls in play, [minBallCount]..[maxBallCount]. 1 is the classic game and
  /// the default; 2 is the two-ball option the player can switch on. It is part
  /// of the config — and therefore of the replay — because the server has to
  /// simulate the same game the player played (SPEC §2.3, §2.5).
  final int ballCount;

  int get playerCount => mode == GameMode.duel ? 2 : 1;
  double get maxSpeed => mode == GameMode.duel ? maxSpeedDuel : maxSpeedSolo;

  Map<String, dynamic> toJson() => {'m': mode.index, 's': seed, 'n': ballCount};

  /// Decodes a config, rejecting values the simulation cannot run. A missing
  /// `n` means one ball (a snapshot written before ball counts existed).
  ///
  /// Throws [FormatException] on an unknown mode or an out-of-range ball count,
  /// so a hostile or stale replay is refused where it is decoded instead of
  /// silently simulating a different game than the one that was played.
  factory GameConfig.fromJson(Map<String, dynamic> j) {
    final mode = j['m'] as int;
    if (mode < 0 || mode >= GameMode.values.length) {
      throw FormatException('unknown game mode $mode');
    }
    final balls = j['n'] == null ? minBallCount : j['n'] as int;
    if (balls < minBallCount || balls > maxBallCount) {
      throw FormatException(
        'ballCount $balls outside $minBallCount..$maxBallCount',
      );
    }
    return GameConfig(
      mode: GameMode.values[mode],
      seed: j['s'] as int,
      ballCount: balls,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GameConfig &&
      other.mode == mode &&
      other.seed == seed &&
      other.ballCount == ballCount;

  @override
  int get hashCode => Object.hash(mode, seed, ballCount);
}

/// Something that happened during a tick; consumed by rendering/audio and
/// forwarded to duel clients inside snapshots.
class GameEvent {
  const GameEvent(
    this.type, {
    this.player = -1,
    this.x = 0,
    this.y = 0,
    this.pickup,
    this.ball = -1,
  });

  final GameEventType type;

  /// Player index the event concerns, or -1.
  final int player;
  final double x;
  final double y;
  final PickupType? pickup;

  /// Index into [GameState.balls] of the ball the event came from, or -1 for an
  /// event that belongs to no single ball (`serve` launches every ball;
  /// `wallSpawn`, `wallExpire`, `pickupExpire` and `gameOver` belong to none).
  /// With two balls one tick can carry two `paddleHit` events, and this is what
  /// tells them apart.
  final int ball;

  List<dynamic> toJson() => [type.index, player, x, y, pickup?.index, ball];

  /// Accepts a five-element event (no ball index) as `ball == -1`.
  factory GameEvent.fromJson(List<dynamic> j) => GameEvent(
    GameEventType.values[j[0] as int],
    player: j[1] as int,
    x: (j[2] as num).toDouble(),
    y: (j[3] as num).toDouble(),
    pickup: j[4] == null ? null : PickupType.values[j[4] as int],
    ball: j.length > 5 ? j[5] as int : -1,
  );

  @override
  String toString() =>
      'GameEvent($type, p=$player, ($x,$y), $pickup, ball=$ball)';
}

class Ball {
  Ball({
    this.x = 0,
    this.y = 0,
    this.vx = 0,
    this.vy = 0,
    this.speed = baseSpeed,
    this.owner = -1,
    this.active = false,
  });

  double x, y;

  /// Unit direction × speed — kept consistent with [speed] while the ball is
  /// active. While the ball is inactive (during [Phase.serving] and after
  /// [Phase.gameOver]) both components are 0; the serve direction is drawn
  /// only when the serve timer reaches 0 (SPEC §2.3).
  double vx, vy;
  double speed;

  /// Index of the last paddle that hit the ball, -1 after a serve.
  ///
  /// While the game is [Phase.serving] in a duel this field carries the
  /// receiving player instead (the one who lost the previous point, or the
  /// player drawn at game start), because the serve aims at that player's
  /// half. It is reset to -1 by the serve itself.
  int owner;
  bool active;

  Ball clone() => Ball(
    x: x,
    y: y,
    vx: vx,
    vy: vy,
    speed: speed,
    owner: owner,
    active: active,
  );

  List<dynamic> toJson() => [x, y, vx, vy, speed, owner, active ? 1 : 0];

  factory Ball.fromJson(List<dynamic> j) => Ball(
    x: (j[0] as num).toDouble(),
    y: (j[1] as num).toDouble(),
    vx: (j[2] as num).toDouble(),
    vy: (j[3] as num).toDouble(),
    speed: (j[4] as num).toDouble(),
    owner: j[5] as int,
    active: (j[6] as int) == 1,
  );
}

class Paddle {
  Paddle(this.angle);

  /// Center angle in radians (math convention, y up).
  double angle;

  Paddle clone() => Paddle(angle);
}

class Player {
  Player({
    required this.paddle,
    this.lives = startLives,
    this.score = 0,
    this.combo = 0,
  });

  final Paddle paddle;
  int lives;
  int score;

  /// Consecutive own paddle hits; reset when this player loses a life.
  int combo;

  int get multiplier {
    final m = 1 + combo ~/ 5;
    return m > maxMultiplier ? maxMultiplier : m;
  }

  Player clone() =>
      Player(paddle: paddle.clone(), lives: lives, score: score, combo: combo);

  List<dynamic> toJson() => [paddle.angle, lives, score, combo];

  factory Player.fromJson(List<dynamic> j) => Player(
    paddle: Paddle((j[0] as num).toDouble()),
    lives: j[1] as int,
    score: j[2] as int,
    combo: j[3] as int,
  );
}

/// An obstacle: an open polyline of at least two vertices, collided as one
/// capsule per consecutive pair of vertices (SPEC §2.3).
///
/// [shape] says how the polyline was built — [WallShape.straight] has two
/// vertices, [WallShape.bent] three and [WallShape.curved]
/// `wallCurveSegments + 1` — so a renderer can draw a curve as a curve. The
/// collision never looks at it: every shape is the same chain of capsules,
/// which is why the no-tunnelling guarantee of a single segment carries over
/// unchanged.
class Wall {
  Wall({
    required this.id,
    required this.shape,
    required this.points,
    required this.ttl,
    this.age = 0,
  }) : assert(points.length >= 4, 'a wall needs at least two vertices'),
       assert(points.length.isEven, 'points is a flat list of x, y pairs');

  /// A straight, single-segment wall from (x1, y1) to (x2, y2).
  Wall.segment({
    required int id,
    required double x1,
    required double y1,
    required double x2,
    required double y2,
    required int ttl,
    int age = 0,
  }) : this(
         id: id,
         shape: WallShape.straight,
         points: <double>[x1, y1, x2, y2],
         ttl: ttl,
         age: age,
       );

  final int id;
  final WallShape shape;

  /// Vertices as a flat `[x0, y0, x1, y1, …]` list, in order along the wall.
  /// Never mutated after construction (a wall's geometry is fixed for its life).
  final List<double> points;

  /// Lifetime in ticks; the wall is removed when `age >= ttl`.
  final int ttl;
  int age;

  /// Number of vertices (2 for a straight wall).
  int get pointCount => points.length >> 1;

  /// Number of capsule segments (`pointCount - 1`).
  int get segmentCount => pointCount - 1;

  double pointX(int i) => points[i << 1];
  double pointY(int i) => points[(i << 1) + 1];

  /// Collides only when fully faded in and not yet fading out.
  bool get solid => age >= wallFadeTicks && age < ttl - wallFadeTicks;

  /// 0..1 visual opacity (fade in / out).
  ///
  /// Exactly 1 while — and only while — the wall is [solid], so a wall the
  /// player can see through is always a wall the ball can pass through and a
  /// wall that looks solid always is. The two ramps mirror each other: the
  /// first tick of a wall's life and the last are both invisible, and the
  /// 29 ticks in between each window's ends step by 1 / [wallFadeTicks].
  double get alpha {
    if (age < wallFadeTicks) return age / wallFadeTicks;
    final left = ttl - 1 - age;
    if (left < wallFadeTicks) return left <= 0 ? 0 : left / wallFadeTicks;
    return 1;
  }

  /// The point the wall was built around: the middle vertex when there is an
  /// odd number of them (the joint of a bent wall, the midpoint of a curve) and
  /// the midpoint of the two middle vertices otherwise (the midpoint of a
  /// straight segment). Every vertex lies within `length / 2` of it, so a
  /// shaped wall takes up no more room than the straight wall it replaced.
  double get centerX {
    final n = pointCount;
    if (n.isOdd) return pointX(n >> 1);
    final i = (n >> 1) - 1;
    return (pointX(i) + pointX(i + 1)) * 0.5;
  }

  double get centerY {
    final n = pointCount;
    if (n.isOdd) return pointY(n >> 1);
    final i = (n >> 1) - 1;
    return (pointY(i) + pointY(i + 1)) * 0.5;
  }

  Wall clone() => Wall(
    id: id,
    shape: shape,
    points: List<double>.of(points),
    ttl: ttl,
    age: age,
  );

  List<dynamic> toJson() => [id, shape.index, age, ttl, ...points];

  factory Wall.fromJson(List<dynamic> j) => Wall(
    id: j[0] as int,
    shape: WallShape.values[j[1] as int],
    age: j[2] as int,
    ttl: j[3] as int,
    points: <double>[
      for (var i = 4; i < j.length; i++) (j[i] as num).toDouble(),
    ],
  );
}

class Pickup {
  Pickup({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    this.ttl = pickupLifetime,
  });

  final int id;
  final PickupType type;
  final double x, y;

  /// Remaining ticks; removed when it reaches 0.
  int ttl;

  Pickup clone() => Pickup(id: id, type: type, x: x, y: y, ttl: ttl);

  List<dynamic> toJson() => [id, type.index, x, y, ttl];

  factory Pickup.fromJson(List<dynamic> j) => Pickup(
    id: j[0] as int,
    type: PickupType.values[j[1] as int],
    x: (j[2] as num).toDouble(),
    y: (j[3] as num).toDouble(),
    ttl: j[4] as int,
  );
}

/// Complete, serializable state of one game. Mutated in place by [Simulation.step].
class GameState {
  GameState({
    required this.config,
    required this.players,
    required this.balls,
    required this.rng,
    this.tick = 0,
    this.phase = Phase.serving,
    List<Wall>? walls,
    List<Pickup>? pickups,
    this.serveTimer = serveTicks,
    this.nextWallIn = 0,
    this.nextPickupIn = 0,
    this.nextId = 1,
    this.winner = -1,
  }) : walls = walls ?? <Wall>[],
       pickups = pickups ?? <Pickup>[];

  final GameConfig config;
  int tick;
  Phase phase;
  final List<Player> players;

  /// `config.ballCount` balls, resolved in this order within a tick: ball 0
  /// moves and collides first, so it takes a contested pickup, and the first
  /// ball to escape ends the rally before the others move (SPEC §2.3).
  final List<Ball> balls;
  final List<Wall> walls;
  final List<Pickup> pickups;

  /// Ticks left in [Phase.serving] before the ball is launched.
  int serveTimer;
  int nextWallIn;
  int nextPickupIn;

  /// Next entity id (walls and pickups share the sequence).
  int nextId;

  /// Winning player in duel once [phase] == gameOver, else -1.
  int winner;
  Prng rng;

  /// Events produced by the most recent [Simulation.step] (cleared at its start).
  final List<GameEvent> events = <GameEvent>[];

  double get elapsedSeconds => tick / tickRate;

  /// Fresh state for [config]: paddles at their start angles (solo 3π/2; duel
  /// P0 3π/2, P1 π/2), serving phase with the full serve timer, first wall in
  /// 7–9 s and first pickup in 3–5 s (drawn from the seeded rng) and
  /// `config.ballCount` balls inactive at the origin. In a duel the player who receives the first serve
  /// is drawn here; the serve direction itself is only drawn when the serve
  /// timer reaches 0 (SPEC §2.3).
  factory GameState.initial(GameConfig config) {
    final rng = Prng(config.seed);
    final players = <Player>[Player(paddle: Paddle(DetMath.threeHalfPi))];
    if (config.mode == GameMode.duel) {
      players.add(Player(paddle: Paddle(DetMath.halfPi)));
    }
    final s = GameState(
      config: config,
      players: players,
      balls: <Ball>[for (var i = 0; i < config.ballCount; i++) Ball()],
      rng: rng,
    );
    s.nextWallIn = (rng.nextRange(7, 9) * tickRate).round();
    s.nextPickupIn = (rng.nextRange(3, 5) * tickRate).round();
    final receiver = config.mode == GameMode.duel ? rng.nextInt(2) : 0;
    s.prepareServe(receiver);
    return s;
  }

  /// Puts the game into [Phase.serving]: serve timer armed and the ball hidden
  /// at the origin with zero velocity. [receiver] is the player the next serve
  /// will aim at (duel only; it is stored in `ball.owner` until the serve
  /// consumes it). Consumes no randomness — the serve direction is drawn by
  /// the simulation when the timer reaches 0. Called by [GameState.initial]
  /// and by the simulation after a life loss.
  void prepareServe(int receiver) {
    phase = Phase.serving;
    serveTimer = serveTicks;
    final owner = config.mode == GameMode.duel ? receiver : -1;
    for (var i = 0; i < balls.length; i++) {
      final ball = balls[i];
      ball.x = 0;
      ball.y = 0;
      ball.vx = 0;
      ball.vy = 0;
      ball.speed = baseSpeed;
      ball.owner = owner;
      ball.active = false;
    }
  }

  /// Deep copy (including rng and events).
  GameState clone() {
    final c = GameState(
      config: config,
      players: [for (final p in players) p.clone()],
      balls: [for (final b in balls) b.clone()],
      rng: rng.clone(),
      tick: tick,
      phase: phase,
      walls: [for (final w in walls) w.clone()],
      pickups: [for (final k in pickups) k.clone()],
      serveTimer: serveTimer,
      nextWallIn: nextWallIn,
      nextPickupIn: nextPickupIn,
      nextId: nextId,
      winner: winner,
    );
    c.events.addAll(events);
    return c;
  }

  /// Deterministic 32-bit FNV-1a hash of the quantized state.
  ///
  /// Mixes, in order: tick, phase, serveTimer, nextWallIn, nextPickupIn,
  /// nextId, winner, the four rng words, per player (angle, lives, score,
  /// combo), per ball (x, y, vx, vy, speed, owner, active), per wall (id,
  /// shape, age, ttl, then every vertex coordinate) and per pickup (id, type,
  /// x, y, ttl). Doubles are quantized with `(v * 1e6).round()`; every value is
  /// mixed as four little-endian bytes of its 32-bit two's complement.
  ///
  /// A one-ball game therefore hashes exactly the values it hashed before ball
  /// counts existed: `config` is not part of the hash, and a single ball mixes
  /// the same seven values in the same place as the single ball did.
  int hash() {
    var h = 0x811C9DC5;
    h = _fnv(h, tick);
    h = _fnv(h, phase.index);
    h = _fnv(h, serveTimer);
    h = _fnv(h, nextWallIn);
    h = _fnv(h, nextPickupIn);
    h = _fnv(h, nextId);
    h = _fnv(h, winner);
    h = _fnv(h, rng.s0);
    h = _fnv(h, rng.s1);
    h = _fnv(h, rng.s2);
    h = _fnv(h, rng.s3);
    for (final p in players) {
      h = _fnv(h, _q(p.paddle.angle));
      h = _fnv(h, p.lives);
      h = _fnv(h, p.score);
      h = _fnv(h, p.combo);
    }
    for (final b in balls) {
      h = _fnv(h, _q(b.x));
      h = _fnv(h, _q(b.y));
      h = _fnv(h, _q(b.vx));
      h = _fnv(h, _q(b.vy));
      h = _fnv(h, _q(b.speed));
      h = _fnv(h, b.owner);
      h = _fnv(h, b.active ? 1 : 0);
    }
    for (final w in walls) {
      h = _fnv(h, w.id);
      h = _fnv(h, w.shape.index);
      h = _fnv(h, w.age);
      h = _fnv(h, w.ttl);
      for (final v in w.points) {
        h = _fnv(h, _q(v));
      }
    }
    for (final k in pickups) {
      h = _fnv(h, k.id);
      h = _fnv(h, k.type.index);
      h = _fnv(h, _q(k.x));
      h = _fnv(h, _q(k.y));
      h = _fnv(h, k.ttl);
    }
    return h;
  }

  static int _q(double v) => (v * 1000000).round();

  /// Mixes the four little-endian bytes of [v] (as 32-bit two's complement)
  /// into the FNV-1a state [h].
  static int _fnv(int h, int v) {
    var x = v & 0xFFFFFFFF;
    for (var i = 0; i < 4; i++) {
      h ^= x & 0xFF;
      h = Prng.mul32(h, 0x01000193);
      x >>= 8;
    }
    return h;
  }

  /// Compact snapshot (SPEC §2.5); events are not included.
  Map<String, dynamic> toJson() => {
    't': tick,
    'ph': phase.index,
    'st': serveTimer,
    'win': winner,
    'b': [for (final b in balls) b.toJson()],
    'p': [for (final p in players) p.toJson()],
    'w': [for (final w in walls) w.toJson()],
    'k': [for (final k in pickups) k.toJson()],
    'nw': nextWallIn,
    'np': nextPickupIn,
    'nid': nextId,
    'rng': rng.toJson(),
    'cfg': config.toJson(),
  };

  /// Rebuilds a state from a snapshot. Throws [FormatException] when the ball
  /// list does not match `cfg.n`, because a state whose ball count disagrees
  /// with its config would step differently on the two sides of the wire.
  factory GameState.fromJson(Map<String, dynamic> json) {
    final config = GameConfig.fromJson(json['cfg'] as Map<String, dynamic>);
    final balls = [
      for (final b in json['b'] as List<dynamic>)
        Ball.fromJson(b as List<dynamic>),
    ];
    if (balls.length != config.ballCount) {
      throw FormatException(
        'snapshot carries ${balls.length} balls, config says ${config.ballCount}',
      );
    }
    return GameState(
      config: config,
      balls: balls,
      players: [
        for (final p in json['p'] as List<dynamic>)
          Player.fromJson(p as List<dynamic>),
      ],
      rng: Prng.fromJson(json['rng'] as List<dynamic>),
      tick: json['t'] as int,
      phase: Phase.values[json['ph'] as int],
      walls: [
        for (final w in json['w'] as List<dynamic>)
          Wall.fromJson(w as List<dynamic>),
      ],
      pickups: [
        for (final k in json['k'] as List<dynamic>)
          Pickup.fromJson(k as List<dynamic>),
      ],
      serveTimer: json['st'] as int,
      nextWallIn: json['nw'] as int,
      nextPickupIn: json['np'] as int,
      nextId: json['nid'] as int,
      winner: json['win'] as int,
    );
  }
}
