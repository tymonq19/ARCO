/// Simulation constants. See SPEC.md §2.2. Sim units: arena radius = 1.0.
library;

const int tickRate = 60;
const double dt = 1.0 / 60.0;

const double arenaRadius = 1.0;
const double ballRadius = 0.035;

/// Radius of the paddle's center line; the paddle is drawn from 0.94 to 0.98.
const double paddleRing = 0.96;
const double paddleThickness = 0.04;
const double paddleHalfWidth = 0.34; // radians
const double paddleSpeed = 4.2; // rad/s

const double baseSpeed = 0.55; // units/s at the first serve
const double maxSpeedSolo = 1.6;
const double maxSpeedDuel = 1.5;
const double hitSpeedFactor = 1.035;
const double maxServeSpeed = 0.95;

/// Units/s added to the one-ball serve speed per second of elapsed game, until
/// [maxServeSpeed]: a rally started three minutes in does not open as slowly as
/// the first one. (Was a literal in the serve; the value is unchanged.)
const double serveRamp = 0.01;

/// Balls in play (SPEC §2.3, `GameConfig.ballCount`): 1 is the classic game,
/// 2 the two-ball option. The simulation is written for any count in this
/// range; the range is what the replay verifier accepts.
const int minBallCount = 1;
const int maxBallCount = 2;

/// Angle between two neighbouring balls of a multi-ball serve (radians). The
/// balls are fanned symmetrically around the one drawn serve direction, so ball
/// `i` of `n` leaves along `angle + (2 * i - (n - 1)) * serveFan / 2`. With
/// `n == 1` the offset is 0 and the serve is exactly the one-ball serve.
///
/// 0.7 rad puts the two balls of a two-ball serve 40 degrees apart: wider than
/// the paddle (2 × 0.34 rad = 39 degrees), so they are never one blob the paddle
/// can take without moving, and narrow enough that the paddle crosses the fan in
/// 0.7 / 4.2 = 0.167 s. What makes the two balls two *decisions* is no longer
/// the fan but [twoBallServeStaggerTicks]: they leave the origin at different
/// times.
const double serveFan = 0.7;

// ------------------------------------------------------------- two-ball pace
//
// Tracking two balls is close to twice the work of tracking one, so the
// two-ball game runs on its own speeds rather than the one-ball ones, and its
// speed stops climbing while a rally is still winnable. The one-ball numbers
// above are untouched: they are pinned by `test/golden_hash_test.dart` and by
// every score already on the leaderboard.
//
// The yardstick used below is the **answer interval**: the mean time between
// two moments the player has to be somewhere. A ball leaving the paddle ring
// (radius `paddleHitRadius` = 0.905) comes back across a chord of
// `2 × 0.905 × cos(theta)`, where `theta` is its angle from the inward radial
// and `cos(theta) >= paddleMinInwardDot`; averaged over the allowed range that
// is 1.33 units, so one ball at speed `v` asks something of the player every
// `1.33 / v` seconds and `n` balls every `1.33 / (n v)`.
//
//   one ball   0.55 → 2.42 s      1.60 (ceiling) → 0.83 s
//   two balls  0.42 → 1.58 s      0.72 (ceiling) → 0.92 s
//
// So the two-ball game opens harder than the one-ball game (1.58 s against
// 2.42 s — two balls should be harder) and its ceiling is never tighter than
// the one-ball ceiling the player already survives.

/// Speed the balls leave a two-ball serve with, units/s (against [baseSpeed]
/// 0.55 for one ball).
///
/// 0.42 makes the combined answer interval at the serve 1.33 / (2 × 0.42) =
/// 1.58 s. It also sets the tempo the stagger is derived from: the flight from
/// the origin to the paddle is 0.905 / 0.42 = 2.15 s.
const double twoBallBaseSpeed = 0.42;

/// Units/s added to the two-ball serve speed per second of elapsed game.
///
/// The one-ball ramp ([serveRamp], 0.01/s) spends 40 s crossing 38% of the
/// distance from `baseSpeed` to `maxSpeedSolo`. The two-ball speed range is
/// compressed — (0.72 − 0.42) / (1.6 − 0.55) = 0.286 of it — so the ramp is
/// compressed with it: 0.01 × 0.286 ≈ 0.003, which reaches
/// [twoBallMaxServeSpeed] after 50 s.
const double twoBallServeRamp = 0.003;

/// Ceiling of the two-ball serve speed, units/s (against [maxServeSpeed] 0.95
/// for one ball).
///
/// Halfway from [twoBallBaseSpeed] to [twoBallMaxSpeed]: a late serve opens
/// brisk but still leaves the rally room to speed up, and at 0.57 the flight
/// from the origin is 1.59 s, comfortably longer than the stagger.
const double twoBallMaxServeSpeed = 0.57;

/// Hard ceiling on a ball's speed in the two-ball game, units/s (against
/// [maxSpeedSolo] 1.6 / [maxSpeedDuel] 1.5 for one ball).
///
/// The point of a ceiling is to be a speed the player can still rally at. Take
/// a rebound at `theta` from the inward radial (`cos(theta) >=
/// paddleMinInwardDot`, so `theta <= 1.318`): it travels `2 × 0.905 ×
/// cos(theta)` units and lands `pi - 2 theta` radians away, which the paddle
/// covers in `(pi - 2 theta) / paddleSpeed`. Give the player 0.25 s of reaction
/// before the paddle starts moving; at 0.72 every rebound is still answerable,
/// with 0.26 s to spare in the worst case (the grazing edge hit: 0.63 s of
/// flight against 0.25 s of reaction plus 0.12 s of travel). At 1.6 the same
/// sum fails for `theta > 1.17` — about a tenth of the rebound range is
/// arithmetically unreachable — which is exactly the "it does not matter what I
/// do" the two-ball ceiling has to avoid.
const double twoBallMaxSpeed = 0.72;

/// Fraction of the *remaining* headroom a paddle hit adds in the two-ball game
/// (against a flat × [hitSpeedFactor] for one ball).
///
/// The one-ball law multiplies by a constant, so the speed runs away until it
/// pins at the ceiling and the rally is then decided by arithmetic rather than
/// play. Here each hit closes 9% of the gap to [twoBallMaxSpeed]: the rally
/// quickens fast while it is young (the first hit adds 0.027 u/s, four times
/// what the flat 3.5% would add to 0.42) and then flattens — half the headroom
/// is gone after 8 hits, 85% after 20, and the last 15% is spread over the
/// rest, so a long rally is a plateau the player can settle into.
const double twoBallHitGain = 0.09;

/// Smallest speed a paddle hit may add in the two-ball game, units/s.
///
/// A pure share-of-the-headroom curve only approaches its ceiling, which makes
/// "the ceiling" unobservable and untestable. This floor makes the tail linear,
/// so the ceiling is reached exactly — after 37 hits — and never exceeded. At
/// 0.0025 u/s (0.35% of the ceiling, a tenth of what the one-ball law adds per
/// hit) the tail is a plateau, not a climb.
const double twoBallHitMinGain = 0.0025;

/// Ticks between the launches of the two balls of a two-ball serve.
///
/// They used to leave the origin together, which one paddle cannot answer: the
/// player arrives at one arrival point while the other ball is already past.
/// The gap is the time the player needs to deal with the first ball, and the
/// binding part of that is the first ball itself: struck at the contact ring it
/// can come back across a chord no shorter than
/// `2 × paddleHitRadius × paddleMinInwardDot` = 0.4525 units, which at
/// [twoBallBaseSpeed] takes 0.4525 / 0.42 = 1.077 s = 64.6 ticks. Round up: 65
/// ticks (1.083 s). Inside it the player has room for everything the gap is
/// for — 0.25 s to read the rebound, 0.7 / 4.2 = 0.167 s to cross the fan to
/// the second arrival point and 0.083 s to settle back between the two — and
/// the second ball still arrives *after* the first rebound could, so the two
/// balls are never one event.
///
/// Because `2 × 0.25 = 1/2`, that shortest return is exactly half the serve
/// flight, so the gap is "half a flight" at whatever speed the serve ramp
/// reached. It is also always shorter than a whole flight (65 ticks against 129
/// at [twoBallBaseSpeed] and 95 at [twoBallMaxServeSpeed]), so the queued ball
/// is always launched before the first one could possibly escape: a stagger
/// never quietly turns a two-ball rally into a one-ball rally.
const int twoBallServeStaggerTicks = 65;

/// Ball center beyond this radius = escaped.
const double escapeRadius = 1.06;
const int serveTicks = 60;

const int startLives = 3;
const int maxLives = 5;

const double wallHalfThickness = 0.02;
const double wallMinLength = 0.25;
const double wallMaxLength = 0.45;
const int wallMinLifetime = 9 * tickRate;
const int wallMaxLifetime = 14 * tickRate;
const int wallFadeTicks = 30;
const double wallSpawnRadius = 0.55;

/// Wall shapes (SPEC §2.3). A wall is a polyline; the shape decides how many
/// vertices it has and where they sit. The shape is drawn per spawn attempt:
/// `rng.nextDouble() < wallStraightChance` → straight, the next
/// `wallBentChance` → bent, the rest → curved.
///
/// Half the walls stay straight because that is the wall the player already
/// reads at a glance, and a board of nothing but curves is noise; a quarter
/// each of bent and curved is often enough that a shaped wall is a normal
/// sight rather than a surprise.
const double wallStraightChance = 0.5;
const double wallBentChance = 0.25;

/// Interior angle of a bent wall's joint, radians (100° – 149°).
///
/// The lower bound keeps the concave side of the joint open enough that a ball
/// entering it always leaves in at most two bounces; the upper bound keeps the
/// bend at least 31° away from straight, so a bent wall never reads as a
/// straight one that failed to line up.
const double wallBentMinAngle = 1.75;
const double wallBentMaxAngle = 2.6;

/// Angle swept by a curved wall, radians (60° – 149°).
///
/// Below 60° an arc of this length is indistinguishable from a straight wall;
/// at 149° it is still well short of a closed pocket, so the mouth of the
/// curve (chord `2 R sin(sweep / 2)` ≈ 1.9 R) stays far wider than the ball
/// and nothing can be trapped inside it.
const double wallCurveMinSweep = 1.05;
const double wallCurveMaxSweep = 2.6;

/// Segments a curved wall is approximated with (so `wallCurveSegments + 1`
/// vertices, an odd count whose middle vertex is the arc's midpoint).
///
/// The straight chords sag below the ideal arc by `R (1 - cos(sweep / 2n))`,
/// at worst 0.0023 units for the longest, most strongly curved wall: about a
/// ninth of the wall's half-thickness, well under one screen pixel on a phone.
/// Four segments would sag 0.009 — a third of the wall's own thickness, which
/// is visible as a chain of straight pieces.
const int wallCurveSegments = 8;

/// Collision passes a shaped wall gets per ball substep (SPEC §2.3).
///
/// One pass is the whole collision for a straight wall: the push-out is exact.
/// On the concave side of a joint the push-out of the nearest segment can move
/// the ball into the neighbouring segment's capsule, so two further
/// position-only passes follow. At most one bounce per wall per substep.
const int wallResolvePasses = 3;

const double pickupRadius = 0.07;
const int pickupLifetime = 8 * tickRate;
const int pickupBlinkTicks = 120;
const int maxPickups = 2;
const double pickupSpawnRadius = 0.6;

/// Hard length of a single game, in ticks: one hour of play at [tickRate].
///
/// Every game ends, whether or not a player runs out of lives. Ball speed is
/// capped (see [twoBallMaxSpeed] and [maxSpeedSolo]), so a good enough player is
/// no longer overwhelmed by speed alone and a rally can in principle go on for
/// ever. A solo run only counts once it is submitted, and a submission carries
/// its whole input log, so an endless run would be an unscoreable one: too long
/// to verify and too large to send. The limit turns that into a finish line —
/// survive the hour and the run ends, keeping the score, with the clock as the
/// last opponent instead of the physics.
///
/// [ReplayVerifier.maxTicks] is this same number: a replay may be exactly this
/// long and no longer.
const int maxGameTicks = 60 * 60 * tickRate;

/// Input quantization (see [PlayerInput]).
const int inputAimSteps = 4096;
const int inputMoveMax = 16;

/// Network.
///
/// 2 → 3: the two-ball game got its own speeds, its own speed curve and a
/// staggered serve, and every game now ends at [maxGameTicks] (SPEC §2.3). The simulation moved, so a build carrying the
/// old physics cannot share a game — or verify a replay — with this one, and has
/// to be told to update rather than have an honest score refused.
const int protocolVersion = 3;
const String roomCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const int roomCodeLength = 4;
const int snapshotInterval = 3; // ticks between snapshots (20 Hz)
const int countdownTicks = 180; // 3 s

/// Player names.
const int nameMinLength = 2;
const int nameMaxLength = 12;

/// Duel halves (SPEC §2.3): player 0 defends the bottom half (y < 0) and its
/// paddle starts at 3π/2; player 1 defends the top half and starts at π/2.
/// Solo uses the bottom start angle.
const double bottomCenterAngle = 4.71238898038469; // 3π/2
const double topCenterAngle = 1.5707963267948966; // π/2

/// Serve direction spread around the receiving half's center (duel), radians.
const double serveSpread = 0.9;

/// Spawn placement rules (SPEC §2.3).
const double wallMinDistFromBall = 0.2;
const double wallMinDistBetweenCenters = 0.15;
const double pickupMinDistFromBall = 0.2;
const double pickupMinDistBetweenPickups = 0.15;
const double pickupMinDistFromWall = 0.12;
const int maxSpawnAttempts = 8;

/// Derived simulation constants (SPEC §2.3).

/// Radius at which the ball touches a paddle's inner face
/// (`paddleRing - paddleThickness / 2 - ballRadius`); the ball is pulled
/// back to this radius after a paddle bounce.
const double paddleHitRadius = paddleRing - paddleThickness / 2 - ballRadius;

/// Angular tolerance of a paddle hit: half width plus the ball radius seen
/// from the paddle ring.
const double paddleAngularSlack = paddleHalfWidth + ballRadius / paddleRing;

/// Radians of "english" applied per unit of normalized paddle offset.
const double paddleEnglish = 0.55;

/// Minimum `dot(direction, inwardNormal)` after a paddle bounce.
const double paddleMinInwardDot = 0.25;

/// Capsule radius of a wall as seen by the ball's center.
const double wallCollisionRadius = wallHalfThickness + ballRadius;

/// Minimum distance between the center lines of two walls that are up at the
/// same time (SPEC §2.3), on top of the older centers rule.
///
/// Two capsules whose center lines are closer than this overlap as the ball's
/// center sees them: the ball cannot fit between the walls, so the pair reads as
/// one unreadable blob with a crack in it that swallows the ball. At exactly
/// `2 × wallCollisionRadius` the corridor between two walls is always at least
/// as wide as the ball, so every gap the player can see is a gap the ball can
/// take. Shaped walls made this worth enforcing: two crossing straight lines
/// still read as two walls, two crossing curves do not.
const double wallMinGap = 2 * wallCollisionRadius;

/// Clearance kept between a spawned wall and the serve point, the origin
/// (SPEC §2.3: every serve places the ball at (0, 0)). A wall segment closer
/// than this would cover the serve point, so the next serve would start inside
/// solid geometry; one ball radius of margin on top of the capsule also keeps
/// the first tick of the serve free of the wall.
const double wallMinDistFromServePoint = wallCollisionRadius + ballRadius;

/// Distance (ball center to pickup center) below which a pickup is collected.
const double pickupCollectRadius = pickupRadius + ballRadius;

/// Ball sub-stepping: at most this distance per substep, at most
/// [maxSubsteps] substeps per tick.
const double substepDistance = 0.02;
const int maxSubsteps = 8;

/// Probability that a spawning pickup is a heart rather than a star, when at
/// least one player is below [maxLives].
const double heartProbability = 0.25;

/// Scoring.
const int paddleHitScore = 10;
const int wallHitScore = 5;
const int starScore = 100;
const int maxMultiplier = 8;
