# Arco — Specification (contract for all contributors)

Mobile game (Flutter, iOS + Android, web as bonus): **circular pong**. The ball bounces inside a circle; the
player moves a paddle (an arc) along the circumference to keep the ball in. Modes: **Solo** (endless survival,
global online leaderboard) and **Duel** (2 players online, joined via a 4-letter room code). Pickups spawn on the
board: **hearts** (+1 life), **stars** (+points) and **walls** (obstacles the ball bounces off, making play harder).
The global leaderboard is protected by **server-side replay verification** (deterministic simulation).

Language conventions: all code, comments and docs in English. UI strings in EN + PL (see §5.6).

---

## 1. Repository layout

```
/                              Flutter app, package name `arco`
  lib/main.dart
  lib/app/                     app shell: theme, strings (i18n), settings model, server config
  lib/game/                    rendering (CustomPainter), input (joystick/tilt/follow), controllers, fx, audio glue
  lib/ui/                      screens: home, solo, duel lobby, duel, leaderboard, settings, overlays
  lib/services/                api_client (http), duel_client (ws), storage (prefs), audio_service
  packages/arco_core/          pure Dart package `arco_core`: DetMath, Prng, sim, replay, protocol
  server/                      pure Dart server package `arco_server` (shelf): rooms, leaderboard, verify
  tool/gen_sfx.dart            generates assets/sfx/*.wav (synthesized, no external assets)
  assets/sfx/
  Dockerfile                   server image
  SPEC.md  README.md
```

Package dependencies: app → core (path: packages/arco_core); server → core (path: ../packages/arco_core).
The core package must stay **pure Dart** (no Flutter, no dart:io, no dart:math except `sqrt`).

---

## 2. Core simulation (`packages/arco_core`)

### 2.1 Determinism rules (hard requirements)

The same `(config, inputs)` must produce a bit-identical `GameState` on iOS (AOT), Android (AOT), the Dart VM
(JIT) and Dart-compiled-to-JS. Therefore inside the sim:

- Fixed timestep. `const int tickRate = 60; const double dt = 1.0 / 60.0;`
- Allowed floating-point ops: `+ - * /`, comparisons, `double.sqrt` (from `dart:math` — correctly rounded by IEEE 754,
  so deterministic), `.floor() .ceil() .round() .abs()`, `.clamp`, `.truncate()`.
- **Forbidden inside the sim**: `dart:math` `sin cos tan atan atan2 exp log pow Random`, `DateTime`, `Stopwatch`,
  `Platform`, iteration over `Map`/`Set` order that affects results, `hashCode` of objects, `identityHashCode`.
- `DetMath` (`lib/src/det_math.dart`): `sin(x)`, `cos(x)`, `atan2(y, x)` implemented with pure arithmetic
  (range reduction to [-π, π] using multiplication by literal `1/tau` and `floor`, then a polynomial approximation;
  atan2 via atan polynomial with octant reduction). Provide `pi`, `tau`, `halfPi` as literals,
  `normAngle(a)` → [0, tau), `angleDiff(target, from)` → (-π, π]. Target accuracy: |err| < 1e-6 vs dart:math.
- `Prng` (`lib/src/prng.dart`): xoshiro128** on 32-bit unsigned ints, every op masked with `& 0xFFFFFFFF`
  (must behave identically on VM and JS, where ints are doubles — never exceed 2^53 in intermediate values; use
  `Prng.mul32(a, b)` helper implemented via 16-bit halves). API: `Prng(int seed)` (seed via splitmix32),
  `int nextUint32()`, `double nextDouble()` → [0,1) using the top 24 bits divided by 16777216.0,
  `int nextInt(int n)`, `double nextRange(double a, double b)`, `Prng clone()`, `Map toJson()/fromJson`.
- `GameState.hash()` → deterministic 32-bit FNV-1a over quantized state (positions/angles × 1e6 rounded to int,
  all ints, list order). Used by tests and by the server to validate replays.

### 2.2 Geometry & constants (`lib/src/constants.dart`)

Math convention: arena is a unit circle centered at (0,0), radius `arenaRadius = 1.0`. Angles in radians,
0 = +x, increasing counter-clockwise **with y pointing up**. The renderer flips y.

| constant | value |
|---|---|
| `ballRadius` | 0.035 |
| `paddleRing` | 0.96 (paddle center radius; drawn from 0.94 to 0.98) |
| `paddleHalfWidth` | 0.34 rad |
| `paddleSpeed` | 4.2 rad/s (max angular speed) |
| `baseSpeed` | 0.55 units/s |
| `maxSpeed` | 1.6 (solo) / 1.5 (duel) |
| `hitSpeedFactor` | 1.035 per paddle hit |
| `escapeRadius` | 1.06 (ball center beyond this = escaped) |
| `serveTicks` | 60 (1 s pause with ball hidden before each serve) |
| `startLives` | 3, `maxLives` 5 |
| `wallThickness` | 0.04 (capsule: half-thickness 0.02 + ballRadius) |
| `wallLength` | 0.25 – 0.45 |
| `wallLifetime` | 9 – 14 s (in ticks) |
| `wallFadeTicks` | 30 (no collision while `age < wallFadeTicks`) |
| `pickupRadius` | 0.07 |
| `pickupLifetime` | 8 s (480 ticks); client blinks it during the last 120 ticks |
| `maxPickups` | 2 |

### 2.3 Rules

**Ball motion.** Sub-stepped: `n = max(1, ceil(speed * dt / 0.02))` (cap 8) substeps per tick. Each substep:
move, then resolve in order: walls (capsule collision → reflect about segment normal, push out of penetration),
paddle(s), pickups, escape.

**Paddle bounce.** When the ball is moving outward (`dot(pos, vel) > 0`) and `|pos| >= paddleRing - 0.02 - ballRadius`
and `|angleDiff(ballAngle, paddle.angle)| <= paddleHalfWidth + ballRadius / paddleRing` (angular slack): reflect the
velocity about the inward radial normal, then apply "english": rotate the new direction by
`-(offset / paddleHalfWidth) * 0.55` rad where `offset = angleDiff(ballAngle, paddle.angle)` (hitting near the paddle
edge deflects the ball sideways; sign chosen so that the ball is deflected *away* from the paddle edge it hit).
Then ensure the direction points inward: if `dot(dir, -pos/|pos|) < 0.25`, rotate it toward the inward normal until it is.
Pull the ball back to `|pos| = paddleRing - 0.02 - ballRadius`. `speed = min(speed * hitSpeedFactor, maxSpeed)`.
Only one paddle bounce per tick. Emit `paddleHit(player)`.

**Serve.** `phase = serving`, `serveTimer = serveTicks`, ball inactive at (0,0). When the timer hits 0: `phase = playing`,
ball active, `speed = min(baseSpeed + 0.01 * (tick / 60), 0.95)`, direction: solo → random angle; duel → toward the
receiving player's half: center angle of that half ± `rng.nextRange(-0.9, 0.9)`. Emit `serve`.

**Escape.** `|pos| > escapeRadius`: solo → `lives -= 1`, `combo = 0`; duel → the player whose half contains the
escape angle loses a life (`sin(angle) < 0` → player 0 (bottom), else player 1 (top)), their combo resets; emit
`lifeLost(player)`. If that player's lives == 0 → `phase = gameOver`, `winner` (duel) = other player; emit `gameOver`.
Else → serve (in duel, toward the player who lost).

**Walls.** Spawned when `nextWallIn` reaches 0, if `walls.length < maxWalls(t)` where maxWalls = 1 for t < 20 s,
2 for t < 60 s, 3 after. Center sampled inside radius 0.55, orientation `rng.nextRange(0, tau)`, length in range,
must be ≥ 0.2 from the ball and ≥ 0.15 from other walls' centers (retry up to 8 times, else skip). `ttl` random in
lifetime range; `age` counts up; wall removed when `age >= ttl`. No collision while `age < wallFadeTicks` and during
the last `wallFadeTicks` (fading out). Next spawn interval: `rng.nextRange(7, 9)` s for t < 30 s, `(4, 6)` s after.
Bounce → emit `wallHit`, score `+5 × mult` to the ball owner (if any).

**Pickups.** Spawned when `nextPickupIn` reaches 0 and `pickups.length < maxPickups`: position inside radius 0.6,
≥ 0.15 from other pickups, ≥ 0.2 from the ball, ≥ 0.12 from any wall segment. Type: heart with probability 0.25 if the
(solo: player / duel: any player) has lives < maxLives, else star. Next interval `rng.nextRange(5, 8)` s.
Collected when `dist(ball, pickup) < pickupRadius + ballRadius` by `ball.owner` (solo: always player 0; duel: last
hitter, `-1` if none — then the pickup is simply removed). Heart → `lives = min(maxLives, lives + 1)`;
star → `score += 100 × mult`. Emit `pickup(player, type)`. Expired pickups emit `pickupExpire`.

**Scoring.** Per player: `score`, `combo` (consecutive own paddle hits, reset on that player's life loss),
`multiplier = min(1 + combo ~/ 5, 8)`. Paddle hit: `combo += 1` then `score += 10 × multiplier`.
Star: `+100 × multiplier`. Wall bounce: `+5 × multiplier` (owner). Solo only: `+1` every 60 ticks while playing.

**Duel halves.** Player 0 defends the **bottom** half (angles in (π, 2π), i.e. y < 0); player 1 the **top** half.
Paddle center clamps: P0 ∈ [π + paddleHalfWidth, tau − paddleHalfWidth]; P1 ∈ [paddleHalfWidth, π − paddleHalfWidth].
Start angles: P0 = 3π/2, P1 = π/2. In solo the single paddle roams the whole circle, start angle 3π/2.
(The client renders player 1's view rotated by 180° so each player sees their own paddle at the bottom.)

**Ball owner.** `ball.owner` = index of the last paddle that hit it; `-1` after a serve. Solo: always 0 after first hit
(pickups in solo are credited to player 0 regardless).

### 2.4 Input

```dart
class PlayerInput {
  final int move;   // -16..16 → angular velocity = move / 16 * paddleSpeed (used when aim < 0)
  final int aim;    // -1 = none; else 0..4095 → target angle = aim * tau / 4096; paddle moves toward it at paddleSpeed
  static const none = PlayerInput(move: 0, aim: -1);
  int encode() => aim < 0 ? move + 16 : 33 + aim;      // 0..4128
  static PlayerInput decode(int v);
}
```
Paddle update per tick: if `aim >= 0`: `d = angleDiff(target, angle)`; move by `sign(d) * min(|d|, paddleSpeed * dt)`
(duel: target first clamped to the player's range, then shortest path). Else `angle += move / 16 * paddleSpeed * dt`.
Then normalize (solo) or clamp (duel).

### 2.5 Public API (`lib/arco_core.dart` exports everything below)

```dart
enum GameMode { solo, duel }
enum Phase { serving, playing, gameOver }
enum PickupType { heart, star }
enum GameEventType { serve, paddleHit, wallHit, pickup, pickupExpire, wallSpawn, wallExpire, lifeLost, gameOver, tick }

class GameConfig { final GameMode mode; final int seed; const GameConfig({required this.mode, required this.seed});
  int get playerCount; Map<String, dynamic> toJson(); factory GameConfig.fromJson(Map<String, dynamic>); }

class GameEvent { final GameEventType type; final int player; /* -1 if none */ final double x, y; final PickupType? pickup; }

class Ball { double x, y, vx, vy, speed; int owner; bool active; }
class Paddle { double angle; }
class Player { int lives, score, combo; Paddle paddle; int get multiplier; }
class Wall { final int id; final double x1, y1, x2, y2; final int ttl; int age; bool get solid; double get alpha; }
class Pickup { final int id; final PickupType type; final double x, y; int ttl; }

class GameState {
  final GameConfig config; int tick; Phase phase; List<Player> players; Ball ball;
  List<Wall> walls; List<Pickup> pickups; int serveTimer, nextWallIn, nextPickupIn, nextId; int winner; /* -1 */
  Prng rng; final List<GameEvent> events; // filled during step(); cleared at the start of each step()
  factory GameState.initial(GameConfig config);
  GameState clone();
  int hash();
  Map<String, dynamic> toJson();            // compact snapshot (see §3.2), events NOT included
  factory GameState.fromJson(Map<String, dynamic> json);
  double get elapsedSeconds;
}

class Simulation { static void step(GameState s, List<PlayerInput> inputs); /* inputs.length == playerCount */ }

class InputLog {  // delta-encoded per-tick inputs for ONE player
  void record(int tick, PlayerInput input);   // stores only when different from the previous value
  PlayerInput inputAt(int tick);               // last recorded value at or before tick (PlayerInput.none before first)
  List<List<int>> toJson();                    // [[tick, encoded], ...]
  factory InputLog.fromJson(List json);
  int get length; int get lastTick;
}

class Replay {
  static const int version = 1;
  final GameConfig config; final List<InputLog> inputs; final int finalTick; final int claimedScore;
  Map<String, dynamic> toJson(); factory Replay.fromJson(Map<String, dynamic>); String encode(); factory Replay.decode(String);
}

class ReplayResult { final bool ok; final String? reason; final int score; final int ticks; final int hash; final int lives; }
class ReplayVerifier {
  static const int maxTicks = 216000; // 1 hour
  static ReplayResult verify(Replay r);   // re-simulates from config.seed applying inputs; ok iff phase==gameOver
                                          // at or before finalTick (solo), finalTick <= maxTicks, and score == claimedScore
}

// Protocol helpers (lib/src/protocol.dart) — JSON message builders + parsers shared by client and server, see §3.
```

Snapshot JSON (`GameState.toJson`) is compact: keys `t` (tick) `ph` (phase index) `st` (serveTimer) `win`
`b` [x,y,vx,vy,speed,owner,active?1:0] `p` [[angle,lives,score,combo],…] `w` [[id,x1,y1,x2,y2,age,ttl],…]
`k` [[id,type,x,y,ttl],…] `nw` `np` `nid` `rng` (prng state), `cfg` {m,s}. Doubles serialized as-is (JSON
round-trips doubles exactly in Dart when using `jsonEncode`/`jsonDecode`; ints that are whole doubles must be
restored with `.toDouble()`).

### 2.6 Tests (`packages/arco_core/test`)

determinism (same seed + inputs → identical hash across two fresh runs and vs a cloned state; 5000 ticks with
scripted inputs), DetMath accuracy vs dart:math on 10k samples (|err| < 1e-6) and atan2 quadrants, Prng (known
xoshiro128** reference values, nextInt range, nextDouble in [0,1)), paddle bounce (ball toward paddle is reflected
inward and speed increases; ball toward a gap escapes and costs a life), wall bounce at maxSpeed never tunnels
(1000 random shots), pickups are collected and credited, scoring & multiplier, duel half attribution and clamps,
input encode/decode round-trip for all values, InputLog delta semantics, Replay JSON round-trip, ReplayVerifier
accepts a real recorded game and rejects a tampered score / missing gameOver / too many ticks, toJson/fromJson
round-trip preserves hash.

---

## 3. Network protocol (WebSocket, JSON text frames, one message per frame)

Endpoint: `ws(s)://HOST/ws`. Room code alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no 0/O/1/I), 4 chars.
`protocolVersion = 1`. All builders/parsers live in core `lib/src/protocol.dart` (`ClientMsg`, `ServerMsg` sealed
classes with `toJson()` / `parse(Map)`), so the client and server never hand-write message shapes.

Client → Server
- `{"t":"hello","v":1,"name":"Tymek"}` — must be first. Name rules as in §4.2.
- `{"t":"create"}` → `room` message. `{"t":"join","code":"KX7Q"}` → `room` or `error`.
- `{"t":"input","tick":123,"i":17}` — `i` = `PlayerInput.encode()`. Sent every tick the input changes, and at
  least every 10 ticks (keep-alive). Server applies the latest received input; ignores `tick` older than last.
- `{"t":"rematch"}` — after `over`; when both players sent it → new `start`.
- `{"t":"leave"}`, `{"t":"ping","c":<client ms>}`.

Server → Client
- `{"t":"welcome","v":1}` after hello.
- `{"t":"room","code":"KX7Q","slot":0|1,"names":["Tymek",null]}` (also re-sent to both when the peer joins).
- `{"t":"start","seed":123456,"countdown":180,"names":["A","B"]}` — sim tick 0 begins `countdown` server ticks
  after this message; clients show 3-2-1.
- `{"t":"snap","tick":N,"s":<GameState.toJson()>,"ev":[[type,player,x,y,pickup?],...]}` every 3 ticks (20 Hz).
  `ev` contains the events accumulated since the previous snapshot.
- `{"t":"over","winner":0|1,"scores":[a,b]}`; `{"t":"peer_left"}`; `{"t":"pong","c":<echo>,"tick":N}`;
  `{"t":"error","code":"bad_code|room_not_found|room_full|not_in_room|bad_message|rate_limited"}`.

Room lifecycle: created on `create`; `waiting` → `countdown` → `playing` → `over` → (rematch) `countdown` …
If a player disconnects: the other receives `peer_left`, the room is destroyed. Rooms idle (waiting) > 10 min are
destroyed. The server steps every playing room at 60 Hz from a single periodic timer (catch-up loop with a cap of
5 ticks per timer callback to avoid spiral of death). Max 500 rooms; max 4 rooms created per IP per minute.

Client prediction: the client keeps a local `GameState` copy. Own paddle is moved locally every tick with the
current input (immediate response). Between snapshots the client advances its copy with `Simulation.step`, using
its own current input and `PlayerInput.none` for the opponent (ball/walls/pickups extrapolation). On each snapshot the
copy is replaced by the snapshot state, except the own paddle angle which is kept unless it differs from the server's
by more than 0.2 rad (then it snaps). Rendering smooths the ball position over ~3 frames to hide corrections.

---

## 4. REST API (server)

- `GET /api/health` → `{"ok":true,"version":"1.0.0","rooms":N,"accounts":["apple","google"],"catalogue":1,
  "purchases":false}`.
  `accounts` lists the sign-ins this deployment accepts (§4.5); `[]` means the feature is switched off, so a
  client shows exactly the buttons that will work instead of guessing. `catalogue` is the cosmetic catalogue
  version this build serves (§4.8), so a client learns from a call it already makes whether the shop holds a
  kind of item its build cannot draw. `purchases` says whether this deployment can take money at all — i.e.
  whether the one-time unlock can be bought or restored (§4.9) — and `ads` whether it credits rewarded ads
  (§4.10), for the same reason: the app offers exactly what will work instead of a button that cannot be pressed.
  Neither says anything about one player; whether *this* player is premium is `GET /api/shop/inventory`.
- `GET /api/leaderboard?period=all|week|day&country=PL&limit=100` → `{"entries":[{"rank":1,"name":"…",
  "score":1234,"seconds":183,"createdAt":"2026-09-22T12:00:00Z","playerId":"…","country":"PL"}]}` (limit ≤ 100;
  ordered by score desc, createdAt asc). `playerId` is present only on runs owned by a player (§4.4); its absence
  means an anonymous run, which is what every row stored before player identity existed is. `country` is present
  only on runs that carried a usable country code (§4.6). The optional `country` parameter restricts the board to
  one country and **composes** with `period`; `rank` is then the position within that board, 1..N. An unusable
  country is `400 {"ok":false,"error":"invalid_country"}` — unlike on a submission, where it is ignored (§4.6).
- `POST /api/scores` body `{"name":"…","replay":<Replay.toJson()>,"country":"PL"}` → `201 {"ok":true,"id":"…",
  "score":1234,"rank":7,"country":"PL","countryRank":2}`
  or `400 {"ok":false,"error":"invalid_json|invalid_name|offensive_name|invalid_replay|replay_mismatch|unsupported_version"}`
  or `413` body > 2 MB or `429` (> 10 submissions / IP / minute).
  `country` is optional and is a **hint** the client derives from the device locale (§4.6): a usable ISO 3166-1
  alpha-2 code is stored and echoed back with the rank it took nationally, and anything else is dropped — both
  keys are then absent and the run is stored and ranked globally exactly as before. `offensive_name` is the
  nickname filter of §4.7.
  The server runs `ReplayVerifier.verify` and stores only verified scores (score taken from the verification, not
  the claim). `VERIFY_REPLAYS=off` env var skips verification (dev only).
  The `Authorization` header of §4.4 is **optional** here: with it the verified score is attached to that player
  and the `201` body carries `"playerId":"…"`; without it the submission is anonymous and behaves exactly as
  before. Credentials that are present but invalid are refused with `401` — never stored anonymously.
  An authenticated submission also earns shop tokens (§4.8) and the `201` body carries `"tokens":N` (what this
  run paid) and `"tokenBalance":N` (the wallet afterwards). Both keys are absent for an anonymous submission,
  which has no wallet to pay into.
- `GET /api/leaderboard/rank?score=N&period=…&country=PL` → `{"rank":K}` (1 + number of scores > N, within the
  period and the country when given) — used to show rank when offline submission is deferred. Optional.
  `400 invalid_country` for an unusable code, as on `GET /api/leaderboard`.
- `POST /api/account/link`, `POST /api/account/unlink`, `DELETE /api/players/me` — Sign in with Apple / Google and
  account deletion (§4.5).
- `GET /api/shop/catalogue`, `GET /api/shop/inventory`, `POST /api/shop/buy`, `POST /api/shop/equip` — the
  cosmetic catalogue, the Spark wallet, ownership and equipping (§4.8). All four require the credentials of §4.4.
  The catalogue also advertises the one-time unlock and both it and the inventory carry `premium` (§4.9).
- `POST /api/purchases/webhook` — RevenueCat's verified purchase / refund events, the **authoritative** signal for
  the one-time unlock (§4.9). No player credentials: authenticated by the shared secret RevenueCat sends in
  `Authorization`. `200 {"ok":true,"granted":true|false,"duplicate":…,"premium":…}` for anything handled,
  `401 invalid_signature` for a wrong or missing secret, `400 invalid_event` / `unknown_product`,
  `404 unknown_player` / `purchases_disabled`, `413` body > 32 KB, `429` (> 600 / IP / minute).
- `POST /api/purchases/sync` — the client's nudge after a purchase, and **Restore purchases** (§4.9). Requires the
  credentials of §4.4 and carries **no purchase data at all**; the server re-verifies with RevenueCat's REST API
  using its own secret key. `200 {"ok":true,"premium":…,"granted":N,"owned":…,"balance":N,"purchases":[…]}`,
  `404 purchases_disabled`, `503 revenuecat_unavailable`, `413` body > 1 KB.
- `GET /api/ads/callback` — AdMob's server-side verification callback, the **only** path that turns a watched
  rewarded ad into Sparks (§4.10). No player credentials: the caller is Google, and what authenticates it is the
  ECDSA signature over the query string, verified against Google's published keys before anything is looked up or
  written. `400 invalid_callback`, `401 invalid_signature` / `invalid_key`, `404 unknown_player` / `ads_disabled`,
  `503 admob_keys_unavailable`, `429` (> 600 / IP / minute). Everything handled — including a reward the daily cap
  or the cooldown bounded to nothing — is `200`, because AdMob retries a non-2xx.
- `GET /api/ads/offer` — what the caller's ad allowance is (§4.10). Requires the credentials of §4.4, is read-only,
  and has **no code path to a balance**; the app calls it to decide whether to offer an ad at all, and again
  afterwards to notice the credit arrive. It answers `available: false` with `premium: true` for a player who holds
  the one-time unlock, whose allowance is untouched (§4.9). `404 ads_disabled`.

CORS allows `GET, POST, DELETE, OPTIONS` on `/api/*`.

### 4.2 Names
2–12 characters after trim; allowed: letters (any Unicode letter), digits, space, `_`, `-`; collapse repeated spaces.
Reject otherwise. Names are not unique. A name that is *valid* by this rule may still be refused as offensive by
the filter of §4.7, which is a separate check with its own error code.

### 4.3 Storage
SQLite via the `sqlite3` pub package (system library). Table `scores(id TEXT PK, name TEXT, score INT, ticks INT,
seed INT, created_at TEXT ISO-8601 UTC, ip_hash TEXT, hash INT, player_id TEXT NULL, country TEXT NULL)`. Indexes
on `(score DESC, created_at)`, `(player_id, score DESC, created_at)` and `(country, score DESC, created_at)` — the
second makes "this player's entries" and "this player's best" a prefix scan of one player's slice, the third makes
a national top 100 (§4.6) a prefix scan of one country's. `player_id` references `players(id)` (§4.4) and is NULL
for an anonymous run; `country` is NULL for a run that carried no usable country code.
Tables `player_secrets`, `player_aliases` and `id_token_uses` belong to identity and accounts; see §4.4 and §4.5.
Tables `player_wallets`, `player_items`, `player_equipped` and `token_awards` belong to cosmetic items; see §4.8.
Table `purchases` is the ledger of store payments and the whole of the premium entitlement; see §4.9. Table
`ad_rewards` is the ledger of Sparks earned from rewarded ads; see §4.10.
Env: `PORT` (8080), `DB_PATH` (`data/arco.db`), `VERIFY_REPLAYS` (`strict`|`off`), `LOG_LEVEL`, plus the account
variables of §4.5, the purchase variables of §4.9 and the ad variables of §4.10.
CORS: allow all origins for `/api/*` (needed by the web build); `Authorization` is an allowed request header.

The schema is versioned in SQLite's `user_version` and upgraded in place on open. A file written by an older
build reads as version 0 and is migrated without losing a row: existing scores keep their values and gain
`player_id = NULL`, so they keep appearing on the leaderboard as anonymous runs. A file from a *newer* build is
refused rather than opened. Current version: **7**.

Version 2 (§4.5) moves player credentials out of `players.secret_hash` into `player_secrets`, so one player can
hold one credential per device, and adds `player_aliases` and `id_token_uses`. It also **drops**
`players.account_email`: §4.5 stores no address, and a schema with nowhere to put one is a claim that can be
checked with `PRAGMA table_info(players)` rather than by auditing every write. Migrating needs SQLite **3.35** or
newer (`ALTER TABLE ... DROP COLUMN`); the server refuses to migrate on an older library instead of failing
halfway.

Version 3 (§4.6) adds `scores.country` and its index. Nullable with no default, so every existing row keeps its
values and counts for no country — which is the truth about it: nobody asked those players where they played. They
stay on the global board unchanged, and a national board is a strictly smaller slice of it, never a re-ranking.

Version 4 (§4.8) adds the four cosmetic tables and changes **nothing** that already exists — not a column added, not
a column dropped. A deployment that upgrades gets a shop in which every player has an empty wallet, the free items
and no stored preference, and there is nothing to backfill: free items are owned implicitly and an unset slot means
the default.

Version 5 (§4.9, as it then was) adds `spark_purchases` and one column, `player_wallets.purchased_total`, with a
default of 0. Nothing else changes shape, and no balance moves: before this version there was no way to buy a Spark,
so `purchased_total = 0` is not a backfill but the truth. Keeping it apart from `earned_total` is what makes "how
much of this wallet was played for" answerable at a glance, and what stops a bought Spark from ever looking like one
that counted towards the daily earning cap.

Version 6 (§4.10) adds `ad_rewards` and one column, `player_wallets.ad_total`, with a default of 0. Nothing else
changes shape and no balance moves: before this version there were no ads. The third column is what keeps the two
daily caps genuinely separate — a Spark from an ad must never look like one that consumed a play allowance, or six
ads would quietly make an evening of good runs pay nothing.

Version 7 (§4.9) renames `spark_purchases` to `purchases`, because what money buys is no longer Sparks but the
one-time unlock. **A rename and nothing else**: every row keeps every column, including the `sparks` and
`clawed_back` numbers of the packs that are gone, so a wallet that bought Sparks under an older build is still
explainable by the rows behind it. Nothing is dropped, nothing is rewritten and **no row is backfilled** — the
entitlement this ledger now answers is *derived* from it, so an upgraded database and one created today answer
identically, and a legacy `arco.sparks.*` row still grants nothing, which is the correct reading of it: it paid in
Sparks, and those Sparks are already in the wallet. The index is dropped and recreated, because
`ALTER TABLE … RENAME TO` leaves an index pointing at the renamed table under its old name.

### 4.4 Anonymous player identity
The game is fully playable with **no account and no sign-in prompt**, ever. A player identity is invisible
plumbing that makes someone's scores survive a reinstall and gives the account layer something to attach to; the
client issues one whenever it decides it wants that (e.g. after a run worth keeping), never as a gate on play.

- `POST /api/players` body optional `{"name":"…"}` → `201 {"ok":true,"id":"<32 hex>","secret":"<43 chars>",
  "name":"…"|null}` or `400 {"ok":false,"error":"invalid_json|invalid_name"}` or `413` body > 4 KB or `429`
  (> 10 issues / IP / minute). `name` follows §4.2 when present. The **secret is returned exactly once**: it is
  generated from a cryptographically secure source (256 bits, base64url without padding) and stored only as a
  salted SHA-256 digest, never in plain text, so the server cannot re-issue it.
- Authentication: `Authorization: Arco <playerId>:<secret>`. The id is 32 lowercase hex characters, the secret is
  base64url (`A–Z a–z 0–9 - _`, 16–128 characters), so `:` never occurs inside either half. The scheme name is
  matched case-insensitively. The secret is compared in constant time.
  Failures are **closed**, never downgraded to anonymous: `401 {"ok":false,"error":"missing_credentials"}` when a
  player-scoped endpoint gets no credentials, `401 {"ok":false,"error":"invalid_credentials"}` when they are
  malformed, name no player, or carry a wrong secret — the three are deliberately indistinguishable.
- `GET /api/players/me` (credentials required) → `200 {"ok":true,"id":"…","name":"…"|null,"bestScore":1234|null,
  "rank":7|null,"games":3,"country":"PL"|null,"countryBestScore":1234|null,"countryRank":7|null,
  "createdAt":"2026-09-22T12:00:00Z"}`. `rank` is the global all-time rank of the player's best score (`1 +` the
  number of strictly better scores, so ties share a rank); `bestScore` and `rank` are null exactly when `games` is
  0. `country`, `countryBestScore` and `countryRank` are the national standing of §4.6 and are null together.
- The display name follows the last name the player actually submitted a score under, so `/api/players/me` agrees
  with the leaderboard.
- A player may hold **several credentials**, one per device: signing in to an account on a second phone issues a
  credential there and leaves the first phone's working (§4.5). Authentication accepts the offered secret if it
  matches any credential the named player holds. At most 10 are kept; over that the one added longest ago is
  evicted, which signs out the device that has not signed in for longest.
- The `<playerId>` half of the header may name a player that was **absorbed by a merge** (§4.5); it resolves to the
  surviving player, so a merge never invalidates a credential a device has already stored. A client should
  therefore read the `id` that comes back from `GET /api/players/me` and store it in place of the one it sent.
- `DELETE /api/players/me` (credentials required) deletes the caller's player, whether or not an account is
  attached, and is never switchable off (§4.5).
- Table `players(id TEXT PK, created_at TEXT, last_seen_at TEXT, name TEXT NULL, account_provider TEXT NULL,
  account_subject TEXT NULL, account_linked_at TEXT NULL)`, with a partial unique index on
  `(account_provider, account_subject)`. The `account_*` columns are NULL for every anonymous player.
  `last_seen_at` is moved forward on a successful authentication, coalesced to at most one write per minute per
  player. Credentials live in `player_secrets(id TEXT PK, player_id TEXT, secret_hash TEXT, created_at TEXT)`.

### 4.5 Sign in with Apple / Google (accounts)
An account is what makes a player's scores survive a lost phone and follow them to a second device. It is offered
**during** play, never as a gate on it: the player plays anonymously (§4.4), and at a well-chosen moment the app
offers "keep your scores and play on any device". The phone performs the native sign-in, receives a signed
identity token, and posts it here.

**Configuration.** `ACCOUNTS_ENABLED` (`on`|`off`, default `off`) switches the whole feature. `APPLE_CLIENT_IDS`
and `GOOGLE_CLIENT_IDS` are comma-separated lists of the `aud` values we accept (≤ 8 each, ≤ 255 chars). A
provider is offered only when it has at least one client id, so an Apple-only build simply leaves the Google list
unset. `ACCOUNTS_ENABLED=on` with **no** client id at all is a startup error (exit 64): without an `aud` to check,
a valid token minted for any other app would be accepted. With the feature off, `/api/account/*` answers
`404 {"ok":false,"error":"accounts_disabled"}` and nothing else about the server changes.

**Token verification, server side.** Nothing the client claims about who it is is ever trusted; the subject comes
only from a token that passed *every* check:
- the signature, against the provider's published JWKS, fetched over **HTTPS only** (no redirects, size-capped)
  and cached — the provider's `max-age` clamped to 5 min … 24 h, one refresh when a token names an unknown `kid`
  (a rotation), at most one fetch attempt per minute, concurrent callers sharing the one in-flight fetch, and
  cached keys kept when a refresh fails so a provider outage cannot sign everyone out;
- `alg`, pinned to **RS256**. `none` and the HMAC algorithms are refused outright rather than treated as
  unsupported, because accepting them *is* the classic JWT forgery;
- `iss`, against the provider's own issuers (Google mints both `https://accounts.google.com` and
  `accounts.google.com`);
- `aud`, against the configured client ids — a string or an array, at least one of which must match;
- `exp`, and `nbf`/`iat` when present, with 60 s of clock skew either way;
- a usable `sub` (≤ 255 chars).

**What is stored: the provider name and its opaque `sub`, and nothing else.** The tokens carry an address (Apple's
is usually a private-relay alias) and often a real name; both are dropped before storage, and `players` has no
column to put them in (§4.3). We do not need them, and not having them keeps the privacy policy short. The token
itself is not stored either — only its SHA-256 digest, in the replay ledger below.

- `POST /api/account/link` body `{"provider":"apple"|"google","idToken":"<jwt>"}`. The `Authorization` header of
  §4.4 is **optional**, and decides which half of the flow this is.
  `200 {"ok":true,"id":"<32 hex>","secret":"<43 chars>","name":"…"|null,"provider":"apple","outcome":"…",
  "linkedAt":"…","createdAt":"…","movedScores":N,"bestScore":1234|null,"rank":7|null,"games":3}`.
  A **new credential is always issued** and no other device's is revoked. `outcome` is one of:
  - `created` — no credentials, and the account was unknown here: a new player was made for it.
  - `linked` — the authenticated anonymous player gained the account.
  - `restored` — the account already existed and was handed back: a second device, or signing in again.
  - `merged` — the authenticated player and the account's player were two rows; they are now one.
  - `retried` — this exact token had been presented before; the recorded outcome was replayed.
  Errors: `400 invalid_json` (malformed body, or `idToken` missing/empty/not a string),
  `400 {"error":"invalid_provider","providers":[…]}`, `401 invalid_credentials` (credentials present but wrong —
  never downgraded to anonymous), `401 {"error":"invalid_token","reason":"<code>"}` where `reason` is one of
  `malformed_token unsupported_algorithm unknown_key bad_signature wrong_issuer wrong_audience expired_token
  token_not_yet_valid missing_subject`, `409 {"error":"already_linked","provider":"…"}`, `413` body > 8 KB,
  `429` (> 10 account calls / IP / minute), `503 keys_unavailable` when the provider's keys cannot be reached at
  all — which is our failure, not a bad token, so the client should retry rather than re-prompt.
- **Merge.** If the provider subject already belongs to another player, the two are merged rather than refused.
  The **account's** player survives, because it is the identity the player's other devices already authenticate
  as. Every score row moves across, so nothing chooses between the two best scores — the surviving best is the
  better of them by construction. `created_at` becomes the earlier of the two, the display name keeps following
  the last name actually played under (§4.4) across the union, and the absorbed player's credentials and ledger
  rows move too, so the calling device's stored credential keeps working. The absorbed id is recorded in
  `player_aliases` and resolves to the survivor from then on. All of it is one transaction.
- **Retry safety.** A phone on a flaky network retries. Each accepted token is recorded in
  `id_token_uses(token_hash PK, provider, subject, player_id, credential_id, used_at, expires_at)`, and a second
  presentation of the same token returns the **same player** with a freshly issued credential, rotating the one
  the previous use issued rather than stacking another. This also bounds a replay: a token captured in transit
  cannot be used to merge somebody *else's* anonymous player into the account, because the outcome is pinned to
  the first call. Rows are pruned 10 minutes **after** `expires_at` — comfortably more than the 60 s clock skew,
  because a token is still accepted for that long past `exp` and dropping its row any earlier would reopen exactly
  the window the ledger exists to close.
- **Two devices.** A restore issues a new credential and never discloses or revokes the other device's, so both
  keep playing as the same player and both their runs land on the one account.
- **One account per player.** A player carries at most one `(provider, subject)`. Presenting a *different*
  provider account for an already-linked player is `409 already_linked` naming the provider it is linked with,
  rather than silently detaching that account; the client offers that sign-in, or unlink first.
- `POST /api/account/unlink` (credentials required) → `200 {"ok":true,"id":"…","unlinked":true|false,
  "provider":"…"}`. Detaches the account; the player, its credentials and every score it owns stay exactly as they
  are, anonymous again. Idempotent (`unlinked:false` when there was nothing to detach). The player's ledger rows
  go too, so a token captured before the unlink cannot walk back in through the retry path.
- `DELETE /api/players/me` (credentials required) → `200 {"ok":true,"deleted":true,"scoresAnonymised":N}`.
  Deletes the player, its account, every credential, its aliases and its ledger rows. Its score rows are
  **anonymised** (`player_id = NULL`), not deleted: a verified run is a fact about the leaderboard, and erasing
  rows would silently restate everyone else's rank. What goes is every link between the person and those runs.
  Apple requires an app that offers account creation to offer account deletion, so this route is **never** gated
  on `ACCOUNTS_ENABLED` and works for an anonymous player too.
- `GET /api/players/me` additionally carries `"provider"` and `"linkedAt"` once an account is attached; both keys
  are absent while the player is anonymous.
- The `POST /api/account/link` body also carries the national standing of §4.6 (`country`, `countryBestScore`,
  `countryRank`), because a merge changes it: the runs of both halves are one player's afterwards.

**Not done deliberately.** No nonce/challenge binding: it needs a server-issued challenge and a client round trip,
and the `exp` check plus the replay ledger already bound what a captured token can do. No refresh tokens and no
provider API calls after sign-in — the identity token is used once to establish who the player is, and the
player's own credential (§4.4) carries every later request.

### 4.6 National leaderboard
A global top 100 is unreachable for an ordinary player, so it stops being a goal after the first look. A national
board is winnable, which is the only reason to show a ranking at all. It is therefore a **filter over the same
rows**, not a second board: nothing is stored twice and nothing is re-ranked.

- `POST /api/scores` may carry `"country":"PL"` — an ISO 3166-1 alpha-2 code the client derives from the **device
  locale**. Case and surrounding whitespace are forgiven (`pl`, ` PL `); a whole locale tag (`pl_PL`, `en-GB`) is
  not, so the client sends the region subtag alone.
- The code is a **hint, never a claim**. It is not checked against the submitter's address — the stored `ip_hash`
  is a one-way digest, and geolocating it would be both unreliable and a privacy step backwards — so it is
  validated for shape only, against the list of currently assigned alpha-2 codes. **Anything else is dropped and
  the run is stored without a country**, never refused: a stale device locale must not cost somebody a verified
  score. A `201` therefore carries `country` and `countryRank` exactly when the hint was accepted, which is also
  how a client notices it was sending the wrong thing.
- `GET /api/leaderboard?country=PL` restricts the board to one country and **composes with `period`**, so
  `?period=week&country=PL` is "this week in Poland". `rank` is the position within the returned board, 1..N: the
  point is that someone who is 4 000th in the world can be 12th at home. `GET /api/leaderboard/rank` takes the
  same parameter. On these two, an unusable code is `400 {"ok":false,"error":"invalid_country"}` rather than
  ignored: answering a request for one country's board with the whole world's would be a wrong answer, not a
  lenient one. An absent or empty parameter is the global board.
- A leaderboard entry carries `"country"` only when its run had one; absent means unknown, which is what every row
  stored before this existed is. Those rows stay on the global board and appear on no national one.
- **A player's country** is the code of their most recent run that carried one — the same rule the display name
  follows (§4.4). A run without a country does not clear it. `countryBestScore` is the player's best run *that
  counts for that country*, not their best run overall: a player who played in one country and then moved would
  otherwise be given a national rank their rows do not support, and the number next to their name would not match
  the board they are on. `countryRank` uses the same tie rule as the global rank (`1 +` strictly better rows).

### 4.7 Nickname filtering
§4.2 decides whether a name is *well-formed*; this decides whether it belongs on a worldwide board that children
see and that Apple and Google review. A submitted name that matches the blocklist is refused with
`400 {"ok":false,"error":"offensive_name"}` and **nothing is stored**. The same check runs on the optional name of
`POST /api/players`, so a name the player could never actually play under is never issued either.

- Coverage: **English and Polish** — profanity, sexual terms, slurs and hate references. Deliberately *not* mild
  insults, which are endless, read as ordinary teasing, and cost false positives.
- A name is reduced to a skeleton before matching, which folds away the evasions people actually use: case,
  diacritics (Polish included), digit substitution (`5h1t`, `ni66er`, `f4g`), separators (`f u c k`, `k_u_r_w_a`)
  and repeated characters (`fuuuuck`).
- **Ordinary names must not be caught.** This is the harder half of the requirement: a filter that refuses
  Cassandra, Essex, Nigeria or Michał is worse than no filter, because the thing being refused is the name someone
  was given. Short or ambiguous entries are therefore matched as **whole words** rather than substrings, an
  allowlist rescues the real collisions (Scunthorpe, Penistone, Shiitake), and the repeat-collapsing step is
  switched off for entries whose collapsed form is a real word (`nigger` → `niger`). The cost is explicit: `Ass69`
  and `niggger` get through. That trade is not close.
- It is **best effort and server-side only**. Homoglyphs from another script (`хуй` in Cyrillic) are not folded,
  because rewriting genuine Russian or Greek names into Latin and matching *those* against a profanity list is a
  false-positive machine; new slang and other languages are not covered until the list is extended. Shipping the
  list in the client would publish it, invite exactly those evasions, and still be bypassable by posting to
  `/api/scores` directly.
- The word lists live in their own file so the list can be extended without touching the matching logic. Which
  entry matched is written to the server log and **never** returned: it is a tuning hint for the next attempt.

### 4.8 The shop: Sparks and cosmetics
The currency is **Sparks** (PL *Iskry*, declined by `Strings.sparks`). It is earned by **playing** and spent on
**cosmetics**, and both halves of that sentence are load-bearing.

- **Earning.** A verified solo submission (§4) pays `score ÷ 100` Sparks, at most **50 per run** and **200 per
  player per UTC day**. The score used is the one **this server computed** by re-simulating the replay; no request
  carries a Spark amount and nothing in `tokens.dart` takes one as input. Every award is a row in `token_awards`
  keyed by a digest of the run, so a recorded game cannot be submitted for Sparks twice and a leaked replay is
  worth nothing to whoever leaked it. A row is written even when the award is 0.
- **The catalogue** (`catalogue.dart`) is a table of ids, kinds and prices in Sparks, served from
  `GET /api/shop/catalogue` so no build of the client hardcodes a price. Three kinds — `theme`, `ball`, `paddle` —
  are slots: exactly one item of each is worn. Free items (`theme.neon`, `theme.classic`, `ball.orb`,
  `paddle.arc`) are owned by everybody without a row anywhere.
- **The wallet and ownership live on the server.** `POST /api/shop/buy` carries an item id and nothing else; the
  price is read from the catalogue *inside* the debiting transaction, which is a conditional
  `UPDATE … WHERE balance >= price`, so a balance can never go negative and a retried buy charges once.
  `POST /api/shop/equip` names slots and is a **preference, not an entitlement**: it may only name items the
  player owns, and it grants nothing.
- **Everything sold is purely cosmetic.** Nothing in the catalogue reaches `packages/arco_core`, and there is no
  field an item could use to touch the simulation. Two reasons, both fatal if ignored: the server re-verifies
  every solo replay, so an item that changed a paddle's width would make *honest* runs fail verification; and a
  leaderboard money can climb is worth nothing.
- The client (`shop_service.dart`) caches the server's last answer so the game opens wearing what the player
  bought with no network, and never so the phone can decide what it owns. A stale cache costs one refused
  request, never a free item.

### 4.9 The one-time unlock — [money]
Optional, off by default, and **one product**: a single **non-consumable** purchase that unlocks every cosmetic that
exists and every cosmetic added later, and turns ads off, forever. There is no second tier, no subscription, no
currency pack and nothing that only makes sense beside a struck-through price.

**Nothing in the game is behind it.** Sparks (§4.8) are the **free path** and are untouched: earned by playing, spent
on individual cosmetics, so a player who never pays can still have everything — slowly, which is the only difference
between the two paths and the honest one. The shop must not nag: the unlock sits below the earning panel, there is no
discount, no countdown, no "best value", and nothing outside the shop points at it. The iron rule of §4.8 holds
unchanged — what money buys is **cosmetics**, so nothing it grants reaches `packages/arco_core`, no honest replay
stops verifying, and no leaderboard position can be bought.

**The architecture.** RevenueCat handles the money step *only*: it talks to StoreKit and Google Play, validates the
receipt and tells us. **This server remains the only source of truth for what a player owns**, because the
entitlement is spent in our shop and read by our game. The client never tells the server what it owns; there is
nothing in any request the server reads that says so.

**The product.** `FullUnlock` in `catalogue.dart` — one identifier and **no price**:

| product id | store kind | what it grants |
|---|---|---|
| `arco.unlock.full` | non-consumable | every cosmetic, present and future; no ads |

The same identifier in App Store Connect, the Play Console and RevenueCat, attached there to the **entitlement**
`premium`. Lowercase letters, digits and dots only — the intersection of what both stores accept, so one id serves
both. The price is the **store's**: set per market in App Store Connect and the Play Console, and shown to the player
from the device's own StoreKit / Billing response, localised and tax-inclusive. A price in our table would be wrong
in most markets, illegal in several, and stale the moment somebody edited a tier. `GET /api/shop/catalogue` grows an
`unlock` object (`{"productId","nameKey"}`) and a `premium` flag; the object is **absent** when the feature is off and
absent once the player is premium, so the client draws no money section when there is nothing to sell.
`GET /api/shop/inventory` grows `premium`.

**Premium is ownership, answered rather than stored.** A player is premium **iff** the purchase ledger holds a live
(un-refunded) row for `arco.unlock.full`; `Db.isPremium` is that one lookup, and the catalogue's `owned` flags, the
inventory's `owned` list, `ownsItem`, the buy path, the equip check and the ad offer all read it. **No row per item is
ever written.** Three things follow, and all three are the reason for it:

- a cosmetic added to the catalogue next year is covered the moment it exists, with **nothing to backfill** for
  anybody who already paid;
- a refund is one stamped column rather than a sweep of rows to unpick, so it *cannot* touch an item the player also
  bought with Sparks — the revoke does not read `player_items` at all;
- exactly one place decides the entitlement, so the shop, the equip check and the ad offer cannot drift apart.

**Granting.** Two paths, and the difference between them is the design:

- `POST /api/purchases/webhook` is **authoritative**. RevenueCat posts a verified event; the request is
  authenticated by the shared secret RevenueCat sends in `Authorization`, compared in constant time **before the
  body is decoded**. `NON_RENEWING_PURCHASE` / `INITIAL_PURCHASE` grant; `CANCELLATION` / `REFUND` revoke;
  everything else is acknowledged with `200` and ignored, because RevenueCat retries any non-2xx and a subscription
  event arriving every hour forever is worse than a log line. A granting event whose `product_id` is not
  `arco.unlock.full` is **refused** with `400 unknown_product` rather than granted at a guess: money changed hands
  for something this build does not sell, which is a misconfiguration a human should find in RevenueCat's dashboard.
  The event's `app_user_id`, `original_app_user_id` and aliases are tried in turn against `canonicalPlayerId`, so an
  unlock bought on a phone whose player was later merged (§4.5) still unlocks for the surviving player.
- `POST /api/purchases/sync` is the client's **nudge** — and **Restore purchases**. It carries **no purchase data at
  all**: the server asks RevenueCat's REST API (`GET /v1/subscribers/{app_user_id}`, secret API key, HTTPS only, no
  redirects, size- and time-capped) and grants from *that* answer. The phone cannot lie because the phone is not
  asked anything. A product RevenueCat reports that we do not sell is **skipped** here rather than refused: a
  subscriber record legitimately lists everything that app user ever bought. RevenueCat's `entitlements` map is read
  but is **never** authority for a grant — an entitlement carries no store transaction id, which is the idempotency
  key — so an entitlement with no transaction behind it grants nothing and is logged as the misconfiguration it is.

**Idempotency.** Granting is keyed on the **store's transaction id** (`purchases.transaction_id`, primary key).
Webhooks are retried, the client nudges the same purchase on every restore, and both can be in flight at once — so
the same payment grants exactly once however many times it arrives, and a transaction id already recorded against
one player unlocks nothing for a second one. Apple reissues a transaction id on a restore, so the **original**
transaction id is preferred wherever both exist: it identifies the payment rather than the delivery of it.

**Refunds and chargebacks revoke.** `refunded_at` is stamped, the row stops being a live unlock, and `isPremium`
answers false from the next call on. Nothing else moves, and that is the decision, not an accident:

- **cosmetics the player also bought with Sparks survive.** Those were paid for separately, with Sparks earned by
  playing or credited from a watched ad, and a refund of the unlock is not a claim on them. It holds by construction
  rather than by care: premium was never rows in `player_items`.
- **the wallet is untouched**, because the unlock credits no Sparks. There is no clawback, no shortfall and no
  floored balance to reason about — the whole class of problem a refunded *currency* pack created is simply absent
  from this design, which is one of the better arguments for it.
- an equipped item the revoke has just un-owned is **not** cleared: the stored preference stays and the slot answers
  its free default, so the choice comes back intact if the player buys that item with Sparks or buys the unlock
  again.
- a player who bought the unlock on **both** stores holds two live rows, and refunding one leaves the other standing.

**Restore is a feature, not an apology.** A non-consumable is a permanent entitlement the stores themselves remember,
so a reinstall, a second device or a new phone genuinely recovers it: `POST /api/purchases/sync` asks RevenueCat what
this app user owns and grants from the same transaction id, which either grants once or finds it already granted. A
refunded purchase a store keeps reporting is **not** restored, because the row it names is already ours and already
stamped.

**The ledger.** Every grant is a row in `purchases(transaction_id PK, player_id, product_id, store, environment,
source, event_id, purchased_at, credited_at, refunded_at)`, indexed on `(player_id, credited_at DESC)`. Nothing in it
is an amount: the unlock grants no quantity of anything, so the row records *that* a product was bought and by whom,
which is exactly what deciding premium needs. Premium is therefore always explainable — "you have everything because
of this payment, on this date, through this store" — and so is its absence. `source` records which path wrote it,
because a ledger that is all `sync` means the webhook is broken. The table also still carries the `sparks` and
`clawed_back` columns of the Spark packs this model replaced, so a wallet that bought Sparks under an older build
keeps every number that explains it; nothing reads them to decide anything.

**A premium player still earns Sparks**, and has nothing left to spend them on. That has to read as harmless rather
than broken: every catalogue item reports `owned`, a buy is answered `200 {"alreadyOwned":true,"charged":0}` rather
than refused, the wallet keeps reporting its balance, its totals and the daily cap, and the shop stops advertising
the unlock because there is nothing left to sell. Earning, the 100-score rate, the 50-per-run and 200-per-day caps
and the ad reward are all unchanged (§4.8, §4.10).

**No ads, as the other half of what was bought.** `GET /api/ads/offer` answers `premium: true` and
`available: false` for a premium player with the allowance **untouched and full** — not fewer ads, none — so a client
shows no ad button rather than one that is technically payable (§4.10).

**The switch.** `PURCHASES_ENABLED=on|off` (default `off`), and the server **refuses to start** enabled without
`REVENUECAT_WEBHOOK_SECRET` and `REVENUECAT_API_KEY` — a granting path with nothing to verify against is a granting
path anybody can drive. `PURCHASES_SANDBOX=on|off` (default `off`) decides whether **sandbox** purchases grant; a
sandbox account can buy all day for nothing, so in production they are acknowledged and ignored, and a staging
deployment turns them on to walk the whole flow — buy, reinstall, restore, refund — before real money exists. With
the feature off, both endpoints answer `404 purchases_disabled`, the catalogue advertises no product, nobody is
premium, and nothing else about the server changes. Keys set while the switch is off start normally and log a
warning.

**Client.** `purchases_flutter`, behind `PurchaseGateway` so every outcome is testable without a device. The
RevenueCat app user id **is** our player id, so the two systems agree with no mapping table. The price the app shows
is whatever the store hands it, printed verbatim. After a purchase the client asks the server and re-reads the
inventory — it never grants locally, and when the server has not granted yet it says exactly that rather than
pretending. Handled outcomes: completed, cancelled (silently), pending (Ask to Buy, bank transfer), already owned,
purchases not allowed on the device, store unavailable, no network, and a purchase that completes while the app is
backgrounded (a customer-info update, plus a re-check on resume).

**Restore purchases** is an ordinary button that does what it says: it re-links the store account to this player and
asks the server to re-verify with RevenueCat, and because the product is a non-consumable that genuinely recovers the
unlock on a reinstall or a second device. Signing in (§4.5) is still what carries a player — and the ledger with
them — between devices.

### 4.10 Rewarded ads that pay Sparks — [money]
Optional, off by default, and a **shortcut only** — the same standing as §4.9, and offered only to players who have
not bought the unlock (§4.9). Every Spark an ad pays is earnable by playing, nothing in the game is behind an ad, and an ad is offered in exactly **two** places, both of which are a
player already asking for something: in the shop, as a way to earn Sparks beside the other way, and on the solo
game-over overlay, as an optional extra on the run just finished. **Never an interstitial, never before a duel,
never on launch.** `test/services/ad_pin_test.dart` reads every file in `lib/` and fails if any ad format but the
rewarded one is named.

**The architecture.** A client that says *"I watched an ad, give me Sparks"* is a Spark printer, and every phone
would have one. So no client is asked. The reward is credited on exactly one signal: AdMob's **server-side
verification (SSV) callback**, a `GET` Google's servers make directly to ours, carrying an ECDSA signature over its
own query string. The server verifies that signature against the keys Google publishes at
`https://www.gstatic.com/admob/reward/verifier-keys.json`, maps the signed `custom_data` to a player, and credits.
**Credit happens only there.** The phone's only power is to read its own balance afterwards.

**The amount is ours.** The callback carries a `reward_amount` — a number a human typed into the AdMob dashboard —
and the server **never reads it**. What an ad pays is `AdRate.sparksPerAd` in `tokens.dart`, applied inside the
crediting transaction, exactly as what a store purchase grants comes from `FullUnlock` (§4.9) and a run's amount
from the score the server computed. `reward_amount` and `reward_item` are recorded in the ledger so a dashboard that has drifted from the code
is visible in a query, and read by nothing.

**The bounds** (`AdRate`, and they are separate from §4.8's on purpose):

| | value | why |
|---|---|---|
| Sparks per ad | **10** | a ~1 000-point run, about a minute of real play — roughly what an ad costs in time |
| Daily cap | **60** per player per UTC day (6 ads) | under a third of the play cap of 200, so playing always dominates |
| Cooldown | **5 minutes** between paying ads | six ads spread across a day is a nudge; without it the shop is an ad farm |

Both are applied in `Db.creditAdReward`, inside a transaction, because only a transaction makes "read the day's
total, decide, write" atomic. The **daily cap clips** to what is left rather than refusing — the player has already
watched the ad — and the **cooldown** is measured as an absolute difference between Google's own *signed*
timestamps, not against our clock and not against arrival order, so a delayed or out-of-order callback gives the
same answer as a prompt one. Either bound is an ordinary `200` that paid 0 or a part, with the reason recorded;
neither is an error, because the ad has been watched and the callback is Google telling us so. Rows that paid
nothing do **not** extend the cooldown, or one bounced ad would lock a player out for a rolling five minutes at a
time. The two caps never interact: ad Sparks are written to `ad_total`, never to `earned_total`, so six ads leave a
good run paying in full and a full play day leaves the ad allowance intact.

**Endpoints.**

- `GET /api/ads/callback` — AdMob's SSV, the **only** crediting path. No player credentials: the caller is Google,
  and what authenticates it is the signature. The checks run cheapest first — the switch, the optional URL key, the
  shape — so an unauthenticated flood costs a string comparison rather than an elliptic-curve verification; the
  signature is checked **before any lookup**, so the endpoint cannot be used to probe which player ids exist; and
  nothing is written until it verifies. The **raw** query string is what is verified (`requestedUri.query`): the
  signed content is everything before the last `&signature=`, which is the layout Google documents, and
  re-encoding it from parsed parameters is how a verifier ends up verifying something the caller never sent.
  Answers: `200` for anything handled, including a reward the cap or cooldown bounded to nothing (AdMob retries a
  non-2xx); `400 invalid_callback`; `401 invalid_signature` / `invalid_key`; `404 unknown_player` / `ads_disabled`;
  `503 admob_keys_unavailable`; `429` over `adCallbacksPerMinute` (600/IP/min).
- `GET /api/ads/offer` — the client's read, requiring the credentials of §4.4. Read-only, with **no code path to a
  balance**. It answers `{available, sparks, earnedToday, dailyCap, remaining, cooldownSeconds, waitSeconds,
  balance, adTotal, placements}` so the app can do the one thing a rewarded ad must never get wrong: **not offer an
  ad that would pay nothing.** It doubles as the poll after an ad — `adTotal` can only move one way and only for
  this reason, so watching it is how the app learns the credit landed. `404 ads_disabled` when the feature is off.

**Idempotency.** Keyed on AdMob's own `transaction_id` (`ad_rewards.transaction_id`, primary key), which is inside
the signed content, so a caller cannot choose it. Same reasoning as §4.9: callbacks are retried, a reward that has
paid one player must never pay a second, and a row is written **even when it paid nothing** — the row *is* the key,
so a callback that hit the cap on its first delivery must not be paid on its retry.

**The ledger.** `ad_rewards(transaction_id PK, player_id, placement, sparks, reward_amount, reward_item, ad_unit,
ad_network, key_id, day, rewarded_at, credited_at, refused)`, indexed on `(player_id, day)` for the cap and
`(player_id, rewarded_at DESC)` for the cooldown. With `token_awards` it completes the identity:
`balance = earned_total + purchased_total + ad_total − spent_total`, with a timestamped, non-duplicable row behind
each of the three positive terms — `purchased_total` being 0 for every wallet since §4.9 stopped selling Sparks. `GET /api/shop/inventory` grows `adTotal`; `GET /api/health` grows
`ads`.

**Merges** (§4.5) move `ad_rewards` and `ad_total` to the survivor and then **re-apply the ad daily cap to the
union**, exactly as the play cap is re-applied: two halves that each watched a day of ads are one person who watched
two days' worth. Money is the deliberate exception — what was paid for stays paid for, and premium follows the
person (§4.9).

**Signature verification.** ECDSA over SHA-256. The public key is Google's DER `SubjectPublicKeyInfo`, read from the
`base64` field of the published document, and the curve is taken from the key's **own named-curve OID** rather than
assumed (`prime256v1` today; an unsupported curve throws by name instead of verifying against the wrong one). The
key document is cached with `JwksCache`'s policy — a TTL, one immediate refetch for an unknown `key_id` because that
is what a rotation looks like, at most one fetch per minute however many unknown ids arrive, and cached keys kept
through a failed refresh so a gstatic hiccup does not lose everyone's rewards.

**The switch.** `ADS_ENABLED=on|off` (default `off`). It needs **no secret to be safe** — that is the whole point of
SSV — so unlike §4.9 there is nothing it refuses to start without. `ADMOB_CALLBACK_KEY` is optional defence in
depth: AdMob appends its parameters to whatever URL is configured, so a key put in that URL arrives inside the
signed content and cannot be stripped or forged; what it buys is a **revocable** URL. `ADMOB_SSV_KEYS_URL`
overrides where the keys come from (tests point it at a fake on loopback; production leaves it unset). With the
feature off both routes answer `404 ads_disabled`, no client offers an ad, nothing is fetched from Google, and
nothing else about the server changes. Settings left with the switch off start normally and log a warning. Neither
`ADMOB_CALLBACK_KEY` nor any other setting appears in `toString` or a log line.

**Consent.** Ads in the EEA, the UK and the regulated US states need a consent choice, and it is gathered with
Google's **UMP** SDK through `google_mobile_ads`. Two rules:

- **Asked at the right moment, not on launch.** Opening the shop only *checks* whether a form is required
  (`requestConsentInfoUpdate`, network-only, shows nothing). The form itself appears when the player taps the ad
  row — the moment they have asked for the thing consent is needed for. The game-over overlay never shows a form:
  its button exists only when an ad is already in hand, because game over is not the moment for a privacy form.
- **Refusing costs nothing.** No ad is ever *requested* unless `canRequestAds()` is true, so a player who declines
  has a fully working game with the ad button simply absent — permanently, silently, and with the row saying so
  before they choose. A player who allows non-personalised ads only is `allowed`: that is a perfectly good ad.

**Client.** `google_mobile_ads` behind `AdsGateway` (mirroring `PurchaseGateway`), so every state is reachable in a
unit test without a device or an AdMob account. `AdsService` never adds a Spark: it shows the ad, polls
`GET /api/ads/offer` until `adTotal` moves, then re-reads the wallet through `ShopService`, and reports
`awaitingServer` — *"your sparks are on their way"* — whenever the server has not confirmed. The ad is **preloaded**,
and the button is drawn only when one is in hand *and* the server says it would pay, so it is instant or absent; the
two bounds get a sentence in the shop (a row that was there five minutes ago and is gone now reads as a bug) and
everything else is silence. The ad's SSV `custom_data` is `<playerId>:<placement>`, which is what joins Google's
callback to a wallet with no mapping table; the format is pinned on both sides by a test, because the two halves
cannot share code.

**Ad unit ids** live in `--dart-define`s (`ADMOB_IOS_REWARDED_UNIT`, `ADMOB_ANDROID_REWARDED_UNIT`), never in
source, and a build given none shows no ad button at all — which is also the web build and every desktop.
`--dart-define=ADMOB_TEST_ADS=on` switches to Google's **published test ad units**, which serve to anybody and
belong to no account: that is what makes the whole loop walkable before a human has signed up for AdMob, and it is a
build-time switch so a release build cannot be talked into test ads. The native manifests are checked in with
Google's test *application* ids for the same reason (SETUP.md §10).

---

## 5. Flutter client

### 5.1 Screens (`lib/ui/`)
- **Home**: title "ARCO", nickname field (persisted; default `Player` + 3 random digits), buttons
  SOLO / DUEL / LEADERBOARD / SETTINGS, personal best.
- **Solo**: full-screen arena (portrait-first). HUD top: score, lives (hearts), multiplier badge, time. Overlay
  "tap to start"; pause button; on game over: score, best, auto-submit to the leaderboard (if online; shows rank or
  "saved locally, will retry" — keep one pending replay in prefs and retry on next app start / leaderboard open),
  RETRY / HOME. On that overlay only, and only when an ad is already loaded and the server says it would pay, an
  optional rewarded ad (§4.10) sits under the result and above RETRY. Never before a game, and never a consent
  form here.
- **Duel lobby**: nickname; CREATE → big room code + "waiting for a friend…" + share button (share_plus optional —
  clipboard copy is enough); JOIN → 4-char code input (auto-uppercase, alphabet-filtered) → connecting → both present
  → countdown 3-2-1 → game. Errors shown inline. Connection status indicator + measured ping.
- **Duel game**: same arena, own paddle at the bottom (player 1 sees the board rotated by 180°), own HUD bottom,
  opponent HUD top (names, lives, scores). Game over overlay: YOU WIN / YOU LOSE, scores, REMATCH / LEAVE.
- **Leaderboard**: tabs All time / This week / Today; top 100; own entries highlighted (by locally stored ids);
  pull-to-refresh; offline/error state with retry.
- **Settings**: language (System/EN/PL), sound, haptics, control mode (Joystick / Tilt / Follow), tilt sensitivity
  slider + CALIBRATE button, joystick side (left/right/float), server URL (advanced, collapsed).
- **Shop** (§4.8): the Spark balance in the app bar; three sections of cards (Looks / Balls / Paddles), each card a
  real arena painting so it cannot lie about what is being bought; an "earned today" panel showing the day's
  allowance; and, **below that panel**, the Spark packs of §4.9 with the **store's** own localised prices and a
  Restore Purchases button whose sentence says plainly that a consumable does not restore. Nothing outside this
  screen points at the packs. Between the panel and the packs sits the rewarded-ad row of §4.10 — the third way to
  get Sparks and the order is the argument: playing, then half a minute of attention, then money. It is absent
  whenever an ad would not work, and it is where the consent form is offered.

### 5.2 Controls (`lib/game/input/`)
Every control mode produces a `PlayerInput` each frame.
- **Joystick (default)**: a floating 1-D joystick. On touch-down anywhere in the lower 60% of the screen a pill-shaped
  track appears centered at the touch point; the knob follows the finger's horizontal offset, clamped to ±64 px;
  `move = round(clamp(dx / 64, -1, 1) * 16)` with a 12% dead zone; released → `move = 0`. Knob left → paddle
  moves left on screen when the paddle is at the bottom (i.e. angle increases in math coords); document this
  mapping in code. Optional fixed position (settings: left/right side) rendered at the bottom corner.
- **Tilt (gyroscope)**: `sensors_plus` accelerometer stream (gravity), low-pass filtered (α = 0.15).
  Roll `= atan2(ax, ay)` (portrait) relative to the calibrated baseline; `move = round(clamp(roll / maxRoll, -1, 1) * 16)`
  with `maxRoll = 0.35 rad / sensitivity`, dead zone 0.04 rad. Calibrate = store the current roll as baseline.
  Handle landscape by using the rotated axes (Orientation from MediaQuery).
- **Follow**: pointer down/drag anywhere → `aim` = quantized angle of the finger relative to the arena center
  (rotated by 180° for player 1). Release → `PlayerInput.none`.
- Keyboard (desktop/web): ← → or A/D → `move = ±16`.

### 5.3 Rendering (`lib/game/render/`)
`GameView` widget: `CustomPainter` driven by a `Ticker`; renders a `GameState` plus a client-only `FxState`
(particles, trail, screen shake, hit flashes, countdown, floating score popups). Look: deep navy background with a
subtle radial gradient, glowing arena ring, paddle as a thick arc with neon glow (own = cyan `#22D3EE`,
opponent = magenta `#F472B6`), ball white with additive trail, hearts pink, stars yellow (spinning), walls as neon
segments (fade in/out by `Wall.alpha`), particles on hits, shake on life loss. Layout: arena diameter =
min(width − 32, height − HUD space); centered. Everything scales from sim units (`scale = arenaPixelRadius`).
Player 1 in duel: the painter and the input mapping apply a 180° rotation. Must render at 60 fps on a mid-range phone:
no allocations in the paint loop hot path beyond what's necessary, reuse `Paint` objects, cap particles at 200.

### 5.4 Controllers (`lib/game/controllers/`)
- `SoloController` (ChangeNotifier): owns `GameState`, `InputLog`, accumulates real time and steps the sim at a
  fixed 60 Hz (max 5 catch-up steps per frame), consumes `state.events` → audio + fx, tracks best score, builds the
  `Replay` at game over.
- `DuelController`: wraps `DuelClient`; runs the prediction described in §3; exposes connection status, ping, names,
  countdown, result.

### 5.5 Services (`lib/services/`)
`ApiClient` (http, `baseUrl`, timeouts 8 s, typed errors), `DuelClient` (web_socket_channel; state machine
`disconnected → connecting → lobby → waiting → countdown → playing → over`; auto-ping every 2 s; reconnect not
required in v1), `Storage` (shared_preferences: name, best score, settings, pending replay, own score ids),
`AudioService` (audioplayers, low-latency mode, preloaded from `assets/sfx`, mute flag), `Haptics`
(HapticFeedback.lightImpact on paddle hit, mediumImpact on pickup, heavyImpact on life loss),
`PlayerIdentity` (§4.4), `AccountService` over `NativeSignIn` (§4.5), `ShopService` (§4.8) and
`PurchaseService` over `PurchaseGateway` (§4.9 — `purchases_flutter` behind an interface, so every purchase outcome
is testable without a store), and `AdsService` over `AdsGateway` (§4.10 — `google_mobile_ads` and Google's UMP
consent SDK behind an interface, so every ad and consent state is testable without a device or an AdMob account).

Server URL: `ServerConfig.baseUrl` = `--dart-define=SERVER_URL` (default `http://localhost:8080`), overridable in
Settings; on Android when the host is `localhost` substitute `10.0.2.2`. WS URL derived by replacing the scheme.

### 5.6 i18n
`lib/app/strings.dart`: `class Strings` with `static Strings of(BuildContext)`, backed by two `Map<String,String>`
(`en`, `pl`), keys like `home.solo`, `duel.waiting`. Language = settings override or system locale (pl → PL, else EN).
All user-visible text goes through it. Polish strings must be natural (e.g. "Zagraj solo", "Pojedynek",
"Tablica wyników", "Ustawienia", "Kod pokoju", "Czekam na znajomego…", "Rewanż", "Sterowanie: Joystick / Przechył
telefonu / Podążaj za palcem", "Kalibruj").

### 5.7 SFX
`tool/gen_sfx.dart` writes 16-bit mono 22.05 kHz WAVs: `hit`, `wall`, `star`, `heart`, `lose`, `serve`,
`gameover`, `win`, `click`, `countdown`. Synthesized (sine/square/noise envelopes). Assets listed in pubspec.

---

## 6. Quality bar
- `dart analyze` / `flutter analyze` clean (no infos suppressed globally), `dart test` in core and server green,
  `flutter test` green. `dart format` applied.
- Every rule in §2.3 has a unit test. The multiplayer path has an end-to-end test that boots the server on a
  random port, connects two WebSocket clients, plays until `over` (using scripted inputs that let the ball escape),
  and asserts the message sequence. The leaderboard path has a test that records a solo game via the core,
  submits it and gets `201`, then tampers the score and gets `400 replay_mismatch`.
- No TODOs left for required behavior. No placeholder screens.
