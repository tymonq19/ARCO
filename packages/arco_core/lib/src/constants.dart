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

/// Balls in play (SPEC §2.3, `GameConfig.ballCount`): 1 is the classic game,
/// 2 the two-ball option. The simulation is written for any count in this
/// range; the range is what the replay verifier accepts.
const int minBallCount = 1;
const int maxBallCount = 2;

/// Angle between two neighbouring balls of a multi-ball serve (radians). All
/// balls leave the origin on the same tick, fanned symmetrically around the
/// one drawn serve direction, so ball `i` of `n` leaves at
/// `angle + (2 * i - (n - 1)) * serveFan / 2`. With `n == 1` the offset is 0
/// and the serve is exactly the one-ball serve.
///
/// 0.7 rad puts the two balls of a two-ball serve 40 degrees apart: wider than
/// the paddle (2 × 0.34 rad = 39 degrees) so saving both is a real decision,
/// narrow enough that one paddle can still reach both while the serve is slow.
const double serveFan = 0.7;

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

/// Input quantization (see [PlayerInput]).
const int inputAimSteps = 4096;
const int inputMoveMax = 16;

/// Network.
const int protocolVersion = 2;
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
