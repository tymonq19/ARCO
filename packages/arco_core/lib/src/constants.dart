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

const double pickupRadius = 0.07;
const int pickupLifetime = 8 * tickRate;
const int pickupBlinkTicks = 120;
const int maxPickups = 2;
const double pickupSpawnRadius = 0.6;

/// Input quantization (see [PlayerInput]).
const int inputAimSteps = 4096;
const int inputMoveMax = 16;

/// Network.
const int protocolVersion = 1;
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

/// Spawn constraints.
const double wallMinDistanceFromBall = 0.2;
const double wallMinDistanceBetweenCenters = 0.15;
const double pickupMinDistanceBetween = 0.15;
const double pickupMinDistanceFromBall = 0.2;
const double pickupMinDistanceFromWall = 0.12;
const int spawnAttempts = 8;
const double heartProbability = 0.25;

/// Scoring.
const int paddleHitScore = 10;
const int wallHitScore = 5;
const int starScore = 100;
const int maxMultiplier = 8;
