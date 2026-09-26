# Arco server

Pure-Dart backend for [Arco](README.md): duel rooms over WebSocket and the
verified global leaderboard. The contract is [SPEC.md](SPEC.md) §3 (protocol) and
§4 (REST API, storage).

* package: `server/` (`arco_server`), depends on `packages/arco_core`
* stack: `shelf` + `shelf_router` + `shelf_web_socket`, `sqlite3` (system library)
* entry point: `server/bin/server.dart`

## Run it locally

```bash
cd server
dart pub get
dart run bin/server.dart                       # http://localhost:8080
PORT=18080 DB_PATH=/tmp/cp_dev.db dart run bin/server.dart
```

Smoke test:

```bash
curl localhost:8080/api/health                 # {"ok":true,"version":"1.0.0","rooms":0,"accounts":[]}
curl 'localhost:8080/api/leaderboard?period=week&limit=10'     # the one-ball board
curl 'localhost:8080/api/leaderboard?balls=2&period=week'      # the two-ball board
curl 'localhost:8080/api/leaderboard?country=PL&period=week'   # national board
curl 'localhost:8080/api/leaderboard/rank?score=1000&country=PL&balls=2'
```

Tests (boot a real server on an ephemeral port, play a full duel over two
WebSocket clients, submit a recorded replay):

```bash
cd server
dart analyze
dart test
dart format .
```

`tool/e2e_smoke.dart` is the cross-process check: it talks to a server that is
already running, over real sockets, exactly as the app does. Six steps — health,
a solo replay submitted and listed, a tampered score refused, a two-ball replay
filed on its own board, a duel over two WebSockets, and a two-ball duel room:

```bash
PORT=18100 DB_PATH=/tmp/cp_smoke.db dart run bin/server.dart &
dart run tool/e2e_smoke.dart http://localhost:18100
```

The end-to-end duel test uses the one test-only knob the server exposes:
`ArcoServer(tickMultiplier: n)` runs the room tick driver at `n x 60` sim
ticks per real second (default `1`), so a duel that takes ~40 s of play finishes
in about two seconds. Production never sets it.

Ahead-of-time build (what the Docker image does):

```bash
cd server
dart build cli --output ../build/server        # -> ../build/server/bundle/bin/server
```

`dart compile exe` does **not** work for this package: `package:sqlite3` 3.x ships
a native-assets build hook and `dart compile` rejects build hooks. `dart build cli`
produces the same AOT executable inside a bundle directory.

## Environment variables

| variable | default | meaning |
|---|---|---|
| `PORT` | `8080` | TCP port; `0` picks a free one |
| `DB_PATH` | `data/arco.db` | SQLite file; parent directories are created, `:memory:` works |
| `VERIFY_REPLAYS` | `strict` | `strict` re-simulates every submitted replay, `off` trusts the claimed score (**development only**) |
| `LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `HOST` | all interfaces | bind address, e.g. `127.0.0.1` |
| `ACCOUNTS_ENABLED` | `off` | `on` turns on Sign in with Apple / Google (SPEC §4.5) |
| `APPLE_CLIENT_IDS` | — | comma-separated `aud` values accepted from Apple: the app's bundle id, plus the Services ID if sign-in goes through the web flow |
| `GOOGLE_CLIENT_IDS` | — | comma-separated `aud` values accepted from Google: the iOS / Android / web OAuth client ids the app asks tokens for |
| `PURCHASES_ENABLED` | `off` | `on` turns on the one-time unlock through RevenueCat (SPEC §4.9) |
| `REVENUECAT_WEBHOOK_SECRET` | — | the exact `Authorization` header value RevenueCat is configured to send with every webhook. **Secret.** |
| `REVENUECAT_API_KEY` | — | a RevenueCat **secret** API key (`sk_…`), used by the server to re-verify a purchase for itself |
| `PURCHASES_SANDBOX` | `off` | `on` also grants premium from **sandbox** purchases; for a staging deployment only |
| `ADS_ENABLED` | `off` | `on` turns on rewarded ads that pay Sparks through AdMob (SPEC §4.10) |
| `ADMOB_CALLBACK_KEY` | — | optional: a value that must appear as `?arco_key=…` on the SSV callback URL. **Secret**, and never the authentication — see below |
| `ADMOB_SSV_KEYS_URL` | Google's | where AdMob's published verifier keys are fetched from; override for staging or a test fake |

`ACCOUNTS_ENABLED=on` with **neither** client id list set is a startup error: with
no `aud` to check against, a valid token minted for any other app would be
accepted. Setting client ids while `ACCOUNTS_ENABLED` is not `on` starts normally
and logs a warning, because that combination is nearly always a mistake. At most
8 ids per provider, 255 characters each.

`PURCHASES_ENABLED=on` without **both** RevenueCat secrets is a startup error:
without the webhook secret any caller could claim a purchase and unlock the whole
catalogue, and without the API key the server cannot re-verify one for itself —
which is also what makes Restore purchases work. Setting either key while
`PURCHASES_ENABLED` is not `on` starts normally and logs a warning. Neither key is
ever logged, and neither is the *public* SDK key the app is built with — that one
is not a secret and is not configured here (see SETUP.md §9.5).

`ADS_ENABLED=on` needs **nothing else**, and that is deliberate: what
authenticates an AdMob reward callback is Google's own signature over the query
string, so there is no shared secret to configure and none to leak.
`ADMOB_CALLBACK_KEY` is optional hardening (see below); `ADMOB_SSV_KEYS_URL` must
be an absolute `http(s)` URL or startup fails. Settings left in place while
`ADS_ENABLED` is not `on` start normally and log a warning, and the callback key
never appears in a log line or in any `toString`.

Invalid values abort startup with exit code 64. `SIGINT`/`SIGTERM` trigger a
graceful shutdown (tick driver stopped, sockets closed, database closed).

## What it serves

| route | purpose |
|---|---|
| `GET /api/health` | `{"ok":true,"version":"1.0.0","rooms":N,"accounts":["apple",…],"catalogue":N,"purchases":false,"ads":false}`; `accounts` is empty when the feature is off, and the two money flags say whether this deployment can take money at all (the one-time unlock, SPEC §4.9) and whether it credits ads. Neither says anything about one player |
| `GET /api/leaderboard?period=all\|week\|day&country=PL&balls=1\|2&limit=100` | top scores of one **board**, `limit` clamped to 100; `balls` names the board (absent → the one-ball board) and composes with `period` and `country`; the answer carries `balls` in the envelope; an entry carries `playerId` when the run is owned and `country` when it had one; `400` `invalid_country` / `invalid_balls` |
| `GET /api/leaderboard/rank?score=N&period=…&country=PL&balls=1\|2` | `{"rank":K,"balls":N}`, `1 +` the number of better scores in that scope |
| `POST /api/scores` | `{"name":…,"replay":…[,"country":"PL"]}` → `201` with `{id,score,rank,balls[,playerId][,country,countryRank]}`; `balls` is taken from the replay, never from the request; `400` `invalid_json` / `invalid_name` / `offensive_name` / `invalid_replay` / `unsupported_version` / `replay_mismatch`, `401` bad credentials, `413` over 2 MB, `429` over 10 submissions per IP per minute |
| `POST /api/players` | issues an anonymous player → `201` with `{id,secret,name}`; `400` `invalid_json` / `invalid_name` / `offensive_name`, `413` over 4 KB, `429` over 10 issues per IP per minute |
| `GET /api/players/me` | the caller's `{name,bestScore,rank,games,country,countryBestScore,countryRank,boards,createdAt}`, plus `{provider,linkedAt}` once an account is linked; `boards` is one entry per board actually played and the top-level standing is the one-ball board; `401` `missing_credentials` / `invalid_credentials` |
| `POST /api/account/link` | sign in with Apple / Google → `200` with `{id,secret,outcome,boards,…}` — the same standing `GET /api/players/me` reports, because a merge changes it; `400` `invalid_json` / `invalid_provider`, `401` `invalid_credentials` / `invalid_token`, `409` `already_linked`, `413` over 8 KB, `429`, `503` `keys_unavailable`, `404` `accounts_disabled` |
| `POST /api/account/unlink` | detaches the account, keeps the player and its runs → `200 {unlinked}` |
| `DELETE /api/players/me` | deletes the caller's player, anonymises its runs → `200 {deleted,scoresAnonymised}` |
| `GET /api/shop/catalogue?v=N` | what can be owned, what it costs in Sparks, what the caller owns and wears, plus `premium` and the one-time unlock of SPEC §4.9 (`unlock: {productId,nameKey}` — absent when `PURCHASES_ENABLED` is off, and absent once the caller is premium) |
| `GET /api/shop/inventory?v=N` | the caller's `{balance,earnedTotal,spentTotal,purchasedTotal,premium,adTotal,owned,equipped,earnedToday,dailyCap}`; `premium` is the one-time unlock (SPEC §4.9), and `owned` is then the whole catalogue |
| `POST /api/shop/buy` | `{"itemId":"ball.comet"}` → `200` with `{priceTokens,charged,alreadyOwned,balance,premium,owned}`; a premium player is answered `alreadyOwned` with `charged: 0` rather than refused; `402` `insufficient_tokens`, `404` `unknown_item` |
| `POST /api/shop/equip` | `{"theme":"theme.glass","ball":null}` → `200 {equipped}`; `403` `item_not_owned`, `404` `unknown_item`, `400` `unknown_kind` / `wrong_kind` |
| `POST /api/purchases/webhook` | RevenueCat's verified purchase / refund events (SPEC §4.9). Authenticated by `REVENUECAT_WEBHOOK_SECRET` in `Authorization` → `200 {granted,duplicate,playerId,productId,premium}` on a grant, `200 {revoked,duplicate,playerId,premium}` on a refund; `401` `invalid_signature`, `400` `invalid_event` / `unknown_product`, `404` `unknown_player` / `purchases_disabled`, `413` over 32 KB, `429` over 600 per IP per minute |
| `POST /api/purchases/sync` | the client's nudge after a purchase, and **Restore purchases**; carries **no purchase data** and the server re-verifies with RevenueCat → `200 {premium,granted,owned,balance,purchases}`; `404` `purchases_disabled`, `503` `revenuecat_unavailable` |
| `GET /api/ads/callback` | AdMob's server-side verification callback (SPEC §4.10), the **only** path that credits a watched ad. No player credentials: authenticated by Google's ECDSA signature over the query string; `400` `invalid_callback`, `401` `invalid_signature` / `invalid_key`, `404` `unknown_player` / `ads_disabled`, `503` `admob_keys_unavailable`, `429` over 600 per IP per minute |
| `GET /api/ads/offer` | the caller's ad allowance → `200 {available,sparks,earnedToday,dailyCap,remaining,cooldownSeconds,waitSeconds,premium,balance,adTotal,placements}`. Read-only, with no code path to a balance; `available` is false with `premium: true` for a player who bought the unlock (SPEC §4.9); `404` `ads_disabled` |
| `GET /ws` | duel WebSocket, `hello` first, JSON text frames (SPEC §3); `429` when one IP opens sockets faster than the upgrade limit below |

CORS allows every origin on `/api/*` (needed by the Flutter web build), the
methods `GET, POST, DELETE, OPTIONS`, and the `Authorization` request header.
Replay verification runs on a helper isolate, so a long re-simulation never
stalls the 60 Hz room tick. Submitter IPs are stored as a SHA-256 hash only.

## Anonymous player identity

The game is fully playable with no account and no sign-in prompt. Identity is
plumbing that makes a player's scores survive a reinstall — and the hook the
account layer will hang a real account on — so the client issues one whenever it
decides it wants that (after a run worth keeping, say), never as a gate on play.

```
POST /api/players            {"name":"Ada"}        # body optional
201  {"ok":true,"id":"<32 hex>","secret":"<43 chars>","name":"Ada"}

Authorization: Arco <id>:<secret>                  # on every later call
```

* The secret is 256 bits from `Random.secure`, base64url without padding. It is
  returned **once**: the database keeps only a salted SHA-256 digest
  (`v1$<salt>$<digest>`), compared in constant time, so a lost secret cannot be
  recovered and a stolen table cannot be replayed. It is a server-generated
  credential, not a password anyone typed, which is why a fast digest is enough
  — and why it stays cheap on the isolate that also drives the 60 Hz room tick.
* `POST /api/scores` takes the header **optionally**. With it, the verified
  score is attached to the player and comes back with `playerId`; without it the
  submission is anonymous exactly as before. Credentials that are present but
  wrong are refused with `401` rather than quietly stored under nobody.
* Leaderboard entries carry `playerId` when owned, so a client highlights its own
  runs by comparing ids instead of remembering which submissions were its own.
  Rows stored before identity existed have no `playerId` and stay on the board.
* `GET /api/players/me` reports the display name, best score, global rank
  (ties share a rank) and the number of games submitted. The display name follows
  the last name the player actually submitted under.
* `last_seen_at` moves forward on a successful authentication, coalesced to at
  most one write per minute per player, so polling an authenticated endpoint
  cannot turn every read into a database write.
* A player may hold **several credentials, one per device**: signing in to an
  account on a second phone issues one there and leaves the first phone's alone,
  which is the only way both can keep playing as the same person. The offered
  secret is checked against every credential the named player holds; at most 10
  are kept, and over that the one added longest ago is evicted.

The schema carries `user_version` and upgrades in place on open: a database file
written before players existed keeps every row, gains the `players` table and a
NULL `scores.player_id`, and keeps serving those rows as anonymous runs. A file
from a newer build is refused rather than half-read. Version 2 moves credentials
into `player_secrets` (carrying each existing one across unchanged, so a client
that stored its secret still authenticates) and adds `player_aliases` and
`id_token_uses`. Version 3 adds `scores.country` and its index. Versions 4 to 6
add the shop, purchase and ad tables described further down, each of them without
moving a balance; version 7 renames the purchase ledger `spark_purchases` to
`purchases` (SPEC §4.9) and changes not a single row. Migrating uses
`ALTER TABLE ... DROP COLUMN`, so it needs **SQLite 3.35 or newer** — Debian
bookworm, which the image is built on, ships 3.40; an older library is refused
with that sentence rather than failing halfway.

## Sign in with Apple and Google

Off unless `ACCOUNTS_ENABLED=on`. An account is what makes a player's scores
survive a lost phone and follow them to a second device — offered *during* play,
never as a gate on it. `GET /api/health` lists the providers this deployment
accepts, so the client shows exactly the buttons that will work.

```
POST /api/account/link      {"provider":"apple","idToken":"<jwt>"}
Authorization: Arco <id>:<secret>            # OPTIONAL — see below

200  {"ok":true,"id":"<32 hex>","secret":"<43 chars>","name":"Ada"|null,
      "provider":"apple","outcome":"linked","linkedAt":"…","createdAt":"…",
      "movedScores":0,"bestScore":18,"rank":1,"games":1}
```

With credentials the authenticated anonymous player gains the account; without
them the account is restored onto a device that holds none yet. `outcome` says
which happened: `created`, `linked`, `restored`, `merged` or `retried`. A new
credential is always issued and **no other device's is revoked**.

### What the server checks

Everything that decides whose account a token is comes from the token, verified
here — never from anything the client claims:

* the signature, against the provider's published JWKS over **HTTPS only** (no
  redirects, size-capped), cached with the provider's `max-age` clamped to
  5 min … 24 h, one refresh when a token names an unknown `kid`, at most one
  fetch attempt per minute, concurrent callers sharing the one in-flight fetch,
  and cached keys kept when a refresh fails so a provider outage cannot sign
  everyone out;
* `alg` pinned to **RS256** — `none` and the HMAC algorithms are refused
  outright, because accepting them *is* the classic JWT forgery;
* `iss`, `aud` against the configured client ids, and `exp`/`nbf`/`iat` with 60 s
  of clock skew.

A failure is `401 {"error":"invalid_token","reason":"<code>"}`. The reason is
coarse on purpose but actionable: `expired_token` means run the native sign-in
again, `wrong_audience` means the build is misconfigured. Keys we cannot reach at
all are `503 keys_unavailable` — our failure, so the client retries rather than
re-prompting. Verification is ~0.2 ms (measured, 2048-bit RS256 in
pointycastle), so it stays on the request isolate; the per-IP budget below is
what bounds it.

### What is stored

**The provider name and its opaque `sub`. Nothing else.** The tokens carry an
address — Apple's is usually a private-relay alias — and often a real name; both
are dropped before storage, and `players` has no column to put them in (schema v2
dropped the one that was reserved, so `PRAGMA table_info(players)` is the proof
rather than a code audit). We do not need them, and not having them keeps the
privacy policy short. The token itself is not kept either, only its SHA-256
digest.

### Merge, retry, deletion

* **Merge.** If the provider subject already belongs to another player, the two
  become one rather than the call failing. The *account's* player survives — it
  is the identity the player's other devices already authenticate as. Every score
  row moves across, so nothing chooses between the two best scores: the surviving
  best is the better of them by construction. The absorbed player's credentials
  move too and its id is recorded in `player_aliases`, so the calling device's
  stored `<playerId>:<secret>` keeps working; `GET /api/players/me` then returns
  the surviving id, which the client should store in place of the old one. One
  transaction.
* **Retry.** A phone on a flaky network retries. Each accepted token is recorded
  by digest in `id_token_uses`, so presenting it again returns the same player
  with a freshly issued credential instead of merging anything twice. That also
  bounds a replay: a captured token cannot drag somebody *else's* anonymous
  player into the account, because the outcome is pinned to the first call. Rows
  are pruned 10 minutes *after* the token's `exp`, which is comfortably longer
  than the 60 s clock skew the verifier allows — a token is still accepted for
  that long past `exp`, so dropping its row sooner would reopen the very window
  the ledger closes.
* **One account per player.** Presenting a different provider account for an
  already-linked player is `409 {"error":"already_linked","provider":"apple"}`
  rather than silently detaching the first. Unlink, or use that sign-in.
* **Deletion.** `DELETE /api/players/me` removes the player, its account, every
  credential, its aliases and its ledger rows, and **anonymises** its score rows
  (`player_id = NULL`) rather than deleting them: a verified run is a fact about
  the leaderboard, and erasing rows would silently restate everyone else's rank.
  What goes is every link between the person and those runs. Apple requires an
  app offering account creation to offer account deletion, so this route is never
  gated on `ACCOUNTS_ENABLED` and works for an anonymous player too.
* **Unlink** detaches the account and keeps the player, its credentials and its
  runs; it is idempotent.

Tests sign their own tokens with a fixture key and serve them from a loopback
fake JWKS server, so `dart test` never touches Apple or Google.

## The one-time unlock — [money]

Off by default. With `PURCHASES_ENABLED=off` — which is every deployment until a
human does the store paperwork in SETUP.md §9 — both purchase endpoints answer
`404 purchases_disabled`, `GET /api/shop/catalogue` carries no `unlock` object,
the app draws no money section at all, and nothing else about the server changes.
Nothing in the game is behind a payment: every cosmetic the unlock covers is
earnable with Sparks by playing (SPEC §4.8), so a deployment that never turns this
on is not missing a feature, it is missing a shortcut.

### The shape of it

**One product, bought once.** `arco.unlock.full` is a **non-consumable** that
unlocks every cosmetic that exists and every cosmetic added later, and turns ads
off, forever. There is no second tier, no subscription and no Spark pack. Sparks
are the free path and are untouched beside it — earned by playing, spent on
individual cosmetics — so a player who never pays can still have everything,
slowly, which is the only difference between the two paths.

RevenueCat handles the **money step only**: it talks to StoreKit and Google Play,
validates the receipt, and tells us. **This server stays the only source of truth
for what a player owns**, because the entitlement is spent in our shop and read by
our game.

The client never says what it owns. There is nothing in any request this server
reads that says so: the product identifier comes from a source we verified, and
what it grants comes from `FullUnlock` in `catalogue.dart` inside the granting
transaction.

```
  phone ──buy──► App Store / Play ──receipt──► RevenueCat
                                                   │
                        ┌──── webhook (authoritative, signed) ────┘
                        ▼
                   arco_server ──grant──► purchases (one row = premium)
                        ▲
   phone ──"look again"─┘   (POST /api/purchases/sync — carries no purchase data;
                             the server asks RevenueCat's REST API itself.
                             This is also what "Restore purchases" calls.)
```

### The product

One identifier, the same string in App Store Connect, in the Play Console and in
RevenueCat:

| product id | store kind | RevenueCat entitlement | what it grants |
|---|---|---|---|
| `arco.unlock.full` | non-consumable | `premium` | every cosmetic, present and future; no ads |

There is **no price on the server**, and there must never be one. The price is set
per market in the stores and shown to the player from the device's own StoreKit /
Billing response — localised, tax-inclusive, and correct in markets nobody on the
team has thought about. Changing what the unlock *grants* is a server deploy;
changing what it *costs* is a change in App Store Connect and nothing else.

A webhook naming any other product is **refused**, never granted at a guess —
including one of the `arco.sparks.*` packs this model replaced, which grant
nothing because they paid in Sparks and those Sparks are already in the wallet.

### Premium is ownership, answered rather than stored

A player is premium **iff** the ledger holds a live (un-refunded) row for
`arco.unlock.full`. `Db.isPremium` is that one lookup, and the catalogue's `owned`
flags, the inventory's `owned` list, `ownsItem`, the buy path, the equip check and
the ad offer all read it. **No row per item is ever written.** Three things follow,
and all three are why it is built this way:

* a cosmetic added to the catalogue next year is covered the moment it exists,
  with **nothing to backfill** for anybody who already paid;
* a refund is one stamped column, not a sweep of rows to unpick — so it cannot
  possibly take away an item the player *also* bought with Sparks, because the
  revoke never reads `player_items`;
* exactly one place decides the entitlement, so the shop, the equip check and the
  ad offer cannot drift apart.

What a premium player sees: every item `owned: true`, no `unlock` object in the
catalogue (there is nothing left to sell them), `premium: true` in the inventory,
and `available: false` with `premium: true` from `GET /api/ads/offer` — with the
ad allowance untouched, because it is the entitlement and not the cap that makes
the answer false.

### The two granting paths

**`POST /api/purchases/webhook` is authoritative.** RevenueCat posts a verified
event and we grant from it. The endpoint takes no player credentials, so what
authenticates it is the shared secret RevenueCat sends in `Authorization`,
compared in constant time **before the body is decoded** — an unauthenticated
caller does not even buy a JSON parse. Both the bare secret and
`Bearer <secret>` are accepted, because RevenueCat sends verbatim whatever is
typed into its dashboard and people type both.

Event handling:

| event type | what happens |
|---|---|
| `NON_RENEWING_PURCHASE`, `INITIAL_PURCHASE` | grants premium |
| `CANCELLATION`, `REFUND` | revokes (see below) |
| anything else (`TEST`, `RENEWAL`, `TRANSFER`, `EXPIRATION`, …) | `200`, logged, ignored |

A non-consumable arrives as `NON_RENEWING_PURCHASE`: RevenueCat uses that type for
every purchase that will not auto-renew. `INITIAL_PURCHASE` is accepted too, in
case somebody configures the product as a subscription by mistake — what makes
that safe is not the type but the product, since an event naming anything other
than `arco.unlock.full` grants nothing whatever it is called.

Everything that is not an error is answered `200`, on purpose: RevenueCat retries
any non-2xx, so acknowledging "seen, nothing to do" is the difference between a
log line and the same subscription event arriving every hour forever. The
exceptions are an unknown `product_id` (`400`) and an app user id that is not a
player (`404`) — both are misconfigurations that have already taken somebody's
money, so they are surfaced as failed events in RevenueCat's dashboard rather
than swallowed, and the retry lands once the fix is deployed.

**`POST /api/purchases/sync` is the client's nudge, and Restore purchases.** The
webhook usually arrives within a second or two, but "usually" is no good to a
player who has just paid and is watching the screen. So the phone can ask us to
look again — and the request carries **nothing**: no product id, no transaction
id, no entitlement. The server calls RevenueCat's
`GET /v1/subscribers/{app_user_id}` with its own secret key (HTTPS only bar
loopback, no redirects, size- and time-capped, exactly like the provider key fetch
in `id_token.dart`) and grants from that answer. The phone cannot lie because the
phone is not asked anything.

A product RevenueCat reports that we do not sell is **skipped** here rather than
refused: a subscriber record legitimately lists everything that app user ever
bought. RevenueCat's own `entitlements` map is read but is **never** authority for
a grant — an entitlement carries no store transaction id, and the transaction id
is the idempotency key that stops a refunded payment unlocking again. So an
entitlement with nothing behind it grants nothing and is logged loudly, because
that is what a product attached to the wrong entitlement looks like from here.

A healthy deployment answers almost every sync with `granted: 0`, meaning the
webhook got there first — or that there was nothing to restore.

### Restore actually restores

This is the part a consumable could never do. A non-consumable is a permanent
entitlement the stores themselves remember, so after a reinstall, on a second
device or on a new phone, RevenueCat still reports the purchase and
`POST /api/purchases/sync` grants from the same store transaction id — which
either grants once or finds it already granted. The answer carries `owned`, which
is the difference between "restored" and "there was nothing to restore": the one
sentence a Restore button has to be able to say truthfully.

A refunded purchase a store keeps reporting is **not** restored, because the row
it names is already ours and already stamped `refunded_at`.

### Idempotency

Granting is keyed on the **store's transaction id**, which is the primary key of
`purchases`. Webhooks are retried, the client nudges the same purchase on every
restore, and both can be in flight at once, so:

* the same payment grants **exactly once**, however many times it arrives;
* a transaction id already recorded against one player unlocks nothing for a
  second one, so a leaked receipt is worth nothing to whoever leaked it;
* a repeat is answered `200` with `granted: false` and `duplicate: true`, and
  `premium` reports the **asking** player's state rather than the row's.

Apple reissues a transaction id on a restore, which a non-consumable makes an
everyday event, so the **original** transaction id is preferred wherever both
exist: it identifies the payment rather than the delivery of it.

### Refunds and chargebacks

A refund or chargeback arrives as a webhook and **revokes**: `refunded_at` is
stamped, the row stops being a live unlock, and `isPremium` answers false from the
next call on. Nothing else moves, and that is the decision:

* **cosmetics the player also bought with Sparks survive.** Those were paid for
  separately, with Sparks earned by playing or credited from a watched ad, and a
  refund of the unlock is not a claim on them. It holds by construction rather
  than by care: premium was never rows in `player_items`, and the revoke does not
  read that table. A player who paid, bought two extra looks with earned Sparks
  and then refunded keeps exactly those two looks and loses the rest.
* **the wallet is untouched**, because the unlock credited no Sparks. There is no
  clawback, no shortfall and no floored balance to reason about — the whole class
  of problem a refunded *currency* pack created is simply absent from this design,
  which is one of the better arguments for it.
* an equipped item the revoke has just un-owned is **not** cleared. The stored
  preference stays and the slot answers its free default, so the choice comes back
  intact if the player buys that item with Sparks or buys the unlock again.
* a player who bought the unlock on **both** stores holds two live rows, and
  refunding one leaves the other standing (`premium: true` in the reply).

A refund for a transaction we never recorded — a subscription cancelling, a
product from another feature — finds no ledger row and is acknowledged with
nothing done.

### A premium player still earns Sparks

They do, and they have nothing left to spend them on. That reads as harmless
rather than broken, deliberately: every item reports `owned`, a buy from a stale
screen or an older build is answered `200 {"alreadyOwned":true,"charged":0}`
instead of a `402`, the wallet keeps reporting its balance, its totals and the
daily cap, and the shop stops advertising the unlock. Earning, the 100-score rate,
the 50-per-run and 200-per-day caps and the ad reward are all unchanged.

### The ledger

```sql
purchases(
  transaction_id TEXT PRIMARY KEY,   -- the STORE's id: the idempotency key
  player_id TEXT NOT NULL,
  product_id TEXT NOT NULL,          -- arco.unlock.full grants premium
  store TEXT NOT NULL,               -- app_store | play_store | …
  environment TEXT NOT NULL,         -- PRODUCTION | SANDBOX
  source TEXT NOT NULL,              -- webhook | sync
  event_id TEXT,                     -- RevenueCat's event id
  purchased_at TEXT NOT NULL,
  credited_at TEXT NOT NULL,
  refunded_at TEXT                   -- this one column IS the entitlement
)
```

Nothing in it is an amount: the unlock grants no quantity of anything, so a row
records *that* a product was bought and by whom, which is exactly what deciding
premium needs. (The table still carries the `sparks` and `clawed_back` columns of
the Spark packs this model replaced — schema version 7 is a rename and nothing
else — so a wallet that bought Sparks under an older build keeps every number that
explains it. Nothing reads them to decide anything.)

Premium is therefore **always explainable**, and so is its absence:

```sql
SELECT * FROM purchases WHERE transaction_id = '1000000123456789';
SELECT product_id, store, credited_at, refunded_at
  FROM purchases WHERE player_id = '…' ORDER BY credited_at DESC;
```

And the Spark balance is still explained by `token_awards` and `ad_rewards`:

```
balance = earned_total + purchased_total + ad_total − spent_total
```

with `purchased_total` at 0 for every wallet from now on, because money no longer
buys Sparks.

`source` is worth watching: a ledger that is entirely `sync` means the webhook is
not arriving, and a broken webhook is a refund with nowhere to land.

### Sandbox

A sandbox purchase costs nothing and a StoreKit sandbox account can make them all
day, so with `PURCHASES_SANDBOX=off` (the default, and the only correct value in
production) sandbox events are **acknowledged and not granted** — acknowledged, so
RevenueCat stops retrying them. A staging deployment sets it to `on` to walk the
whole flow on TestFlight before any real money exists — buy, reinstall, restore,
refund — and the row records `environment = 'SANDBOX'` either way, so it always
says which money it was.

### Merges and deleting a player

A sign-in that merges two players (SPEC §4.5) moves the ledger to the survivor, so
premium follows the person with nothing to migrate: it is answered from the rows
that moved. It also *has* to move, or a refund would later arrive for a row whose
player no longer exists.

`DELETE /api/players/me` removes the ledger with everything else: it is a record
of what that person bought, and a deletion request is a request to remove it. The
store keeps its own receipt, so a refund still works through Apple or Google, and
a refund webhook that arrives afterwards finds no row and is acknowledged with
nothing to do. A player who deletes and then restores gets premium granted to the
new player, which is the honest answer when the previous one is gone.

## Rewarded ads that pay Sparks — [money]

Off by default. With `ADS_ENABLED=off` — which is every deployment until a human
does the AdMob paperwork in SETUP.md §10 — both ad endpoints answer
`404 ads_disabled`, no client offers an ad button, nothing is fetched from Google,
and nothing else about the server changes. Nothing in the game is behind an ad:
every Spark an ad pays is earnable by playing (SPEC §4.8), so a deployment that
never turns this on is missing a shortcut, not a feature.

### The shape of it

A client that says *"I watched an ad, give me Sparks"* is a Spark printer, and
every phone would have one. So **no client is asked**. The reward is credited on
exactly one signal: AdMob's **server-side verification (SSV) callback**, a `GET`
Google's servers make directly to this one, carrying an ECDSA signature over its
own query string. This server verifies that signature against the keys Google
publishes, maps the signed `custom_data` to a player, and credits. There is no
other path, and no endpoint a phone could call to claim a reward — the phone's
only power is to read its own balance afterwards.

The division of labour is the same as for purchases: an outside system attests
that something happened, **this server stays the only source of truth for the
balance**, and the amount comes from our own table rather than from the message.

### The amount is ours, not the dashboard's

The callback carries a `reward_amount`, which is a number a human typed into the
AdMob dashboard. **This server never reads it.** What an ad pays is
`AdRate.sparksPerAd` in `lib/src/tokens.dart`, applied inside the crediting
transaction — exactly as what a store purchase grants comes from `FullUnlock` and a
run's amount from the score this server computed by re-simulating the replay. `reward_amount` and
`reward_item` are written to the ledger and read by nothing, so a dashboard that
has drifted from the code shows up in a query instead of in a balance.

### The two bounds

| | value | why |
|---|---|---|
| Sparks per ad | **10** | about a 1 000-point run, i.e. a minute of real play — roughly what an ad costs in time |
| Daily cap | **60** per player per UTC day (six ads) | under a third of the play cap of 200, so playing always dominates |
| Cooldown | **5 minutes** between paying ads | six ads spread over a day is a nudge; without it the shop is a place you sit and farm |

Both live in `AdRate` and are applied in `Db.creditAdReward`, inside a
transaction, because only a transaction makes "read the day's total, decide,
write" atomic.

The **daily cap clips** to what is left rather than refusing: the player has
already watched the ad, so the cap bounds the day, it does not punish the ad that
reaches it. The **cooldown** is measured as an absolute difference between
Google's own *signed* timestamps — not against this server's clock and not against
arrival order — so a delayed or out-of-order callback gives the same answer as a
prompt one. Either bound is an ordinary `200` that paid 0 or a part, with the
reason in `ad_rewards.refused`; neither is an error, because the ad has been
watched and the callback is Google telling us so. Rows that paid nothing do **not**
extend the cooldown, or one bounced ad would lock a player out for a rolling five
minutes at a time.

**The two caps never interact.** Ad Sparks go to `player_wallets.ad_total`, never
to `earned_total`, so six ads leave a good run paying in full and a full play day
leaves the ad allowance intact. A player who has watched their six ads must not
then find their runs paying nothing.

### Verifying the callback

The order of the checks is the design, cheapest first:

1. the switch (`404 ads_disabled`);
2. the optional `ADMOB_CALLBACK_KEY`, compared in constant time (`401 invalid_key`)
   — so an unauthenticated flood costs a string comparison, not an elliptic-curve
   verification;
3. the shape of the query (`400 invalid_callback`);
4. the signature (`401 invalid_signature`) — **before any database lookup**, so the
   endpoint cannot be used to probe which player ids exist;
5. only then the player, and only then a write.

The **raw** query string is what is verified (`request.requestedUri.query`, not the
parsed parameters): the signed content is everything before the last
`&signature=`, which is the layout Google documents — the last two parameters are
always `signature` then `key_id`. Re-encoding the content from a parsed map is how
a verifier ends up verifying something the caller never sent.

The signature is ECDSA over SHA-256. The public key is Google's DER
`SubjectPublicKeyInfo`, read from the `base64` field of
`https://www.gstatic.com/admob/reward/verifier-keys.json`, and the curve is taken
from the key's **own** named-curve OID rather than assumed (`prime256v1` today; an
unsupported curve throws with the OID in the message instead of verifying against
the wrong curve). The document is cached with the same policy the Apple / Google
sign-in keys use: a TTL, one immediate refetch when a callback names a `key_id` we
have never seen — because that is what a rotation looks like — at most one fetch
per minute however many unknown ids arrive, and cached keys kept through a failed
refresh, so a gstatic hiccup does not lose everybody's rewards. Keys we genuinely
cannot get are `503 admob_keys_unavailable`, which makes AdMob retry: the callback
may be perfectly good and we cannot tell.

Everything the server has handled is answered `200`, **including** a reward the cap
or the cooldown bounded to nothing, because AdMob retries a non-2xx and there is
nothing to retry. `unknown_player` is deliberately a `404`: it means the app and
this deployment disagree about who is playing, and that should surface as a failed
callback in AdMob's dashboard rather than be swallowed.

### Idempotency

Keyed on AdMob's own `transaction_id` (`ad_rewards.transaction_id`, primary key),
which is inside the signed content, so a caller cannot choose it. Callbacks are
retried, so the same watched ad credits exactly once however many times it
arrives, and a transaction id that has already paid one player never pays a
second.

A row is written **even when it paid nothing**. That is not bookkeeping pedantry:
the row *is* the key, so a callback that hit the daily cap on its first delivery
must not be paid on its retry after midnight.

### The ledger

```
ad_rewards(transaction_id PK, player_id, placement, sparks, reward_amount,
           reward_item, ad_unit, ad_network, key_id, day, rewarded_at,
           credited_at, refused)
```

indexed on `(player_id, day)` for the cap and `(player_id, rewarded_at DESC)` for
the cooldown. With `token_awards` it completes the identity

```
balance = earned_total + purchased_total + ad_total − spent_total
```

with a timestamped, non-duplicable row behind each of the three positive terms. So
"where did these Sparks come from" is a query, not a guess.

`GET /api/shop/inventory` reports `adTotal`; `GET /api/health` reports `ads`.

### Merges and deletion

A sign-in merge (SPEC §4.5) moves `ad_rewards` and `ad_total` to the survivor and
then **re-applies the ad daily cap to the union**, exactly as it re-applies the
play cap: two halves that each watched a day of ads are one person who watched two
days' worth, and the allowance is per person. Money is the deliberate exception —
what was paid for stays paid for, and premium follows the person. Without this, farming ads on throwaway
players and signing them all into one account would multiply the cap by however
many players somebody could be bothered to make.

`DELETE /api/players/me` removes the ad ledger with everything else. A callback
that arrives afterwards finds no player and is refused, which is the right answer:
there is no wallet left to credit.

### The optional URL key

`ADS_ENABLED=on` needs **no secret to be safe** — that is the whole point of SSV,
and it is the one place this server differs from the purchase feature, which
refuses to start without its two secrets.

`ADMOB_CALLBACK_KEY` is therefore optional defence in depth rather than the
authentication. AdMob appends its own parameters to whatever URL is typed into its
dashboard, so a key put in that URL (`?arco_key=…`) arrives **inside the signed
content** and cannot be stripped or forged. What it buys is a *revocable* URL: if
the SSV URL leaks, a caller still cannot forge a reward, but it can make this
server verify signatures — and changing one environment variable makes every such
call a `401` before any cryptography runs. Set it, and the same value must be in
the SSV URL in the AdMob console; forget one side and every reward is a `401` with
a log line naming the variable.

## Boards: one leaderboard per game

A two-ball game is a different game — two balls to keep alive, two paddle hits
per rally, a run that scores faster per second and ends sooner. Ranking the two
together would make the one-ball board, the classic one and the only one that
existed until now, read as if it had been overtaken by runs that were not
playing the same game. So every stored run carries the ball count it was played
with and **every query names a board**. There is no combined board, and no way
to ask for one.

```
POST /api/scores    {"name":"Ada","replay":<one-ball replay>}
201  {"ok":true,"id":"…","score":2113,"rank":1,"balls":1}

POST /api/scores    {"name":"Duo","replay":<two-ball replay>}
201  {"ok":true,"id":"…","score":3606,"rank":1,"balls":2}   # rank 1 of its own board

GET  /api/leaderboard                      # a client that never heard of boards
200  {"balls":1,"entries":[{"rank":1,"name":"Ada",…}]}      # the classic board, whole

GET  /api/leaderboard?balls=2&period=week&country=PL
200  {"balls":2,"entries":[…]}                              # all three filters compose

GET  /api/leaderboard?balls=3
400  {"ok":false,"error":"invalid_balls","detail":"balls must be between 1 and 2"}
```

* **The board comes from the replay, never from the request.** There is no
  `balls` field on a submission: it is `replay.cfg.n`, the config the server
  re-simulated, so a run cannot be filed on a board it was not played on. The
  `201` echoes it so a client can confirm which board its rank is measured
  against.
* **A request naming no board gets the one-ball board.** Not the two mixed —
  that board does not exist. One is the default of `GameConfig.ballCount`, so a
  request that says nothing gets the board matching the game a client that says
  nothing plays; and since every row stored before this change is a one-ball run,
  an old client asking the old question gets exactly the board it always got, all
  of it. `?balls=` (empty) is the same as absent. A value outside 1..2 is
  `400 invalid_balls` rather than quietly substituted, the same treatment
  `country` and `period` have always had.
* **Rows written before this change are one-ball rows.** `scores.balls` is
  `NOT NULL DEFAULT 1`, so the upgrade reads every existing row as what it was:
  two balls could not be played, so there is nothing to guess. This is why the
  migration cannot hide anything — see *Operating notes* below.
* `GET /api/players/me` reports `boards`, one entry per board the player has
  actually played, each with its own `games`, `bestScore`, `rank`,
  `countryBestScore` and `countryRank`. A player who has submitted nothing gets
  `[]`. The **top-level** `bestScore`, `rank` and national numbers stay the
  one-ball board — what they always described — so a client that knows nothing
  about boards keeps reading a true number; `games` is every run on either board.
* **Boards are a leaderboard concept and nothing else.** One wallet, one daily
  Spark allowance, one submission rate limit and one replay ledger cover both, so
  a second board is not a second allowance to earn or to flood from.
* **The Spark rate did not change, and that is a decision.** Measured against the
  real simulation with a paddle that chases the ball it has to meet: a *surviving*
  two-ball run scores about **1.4×** the one-ball rate per second, and a typical
  two-ball run ends far sooner and pays **less** than a one-ball one, because the
  paddle cannot cover two balls. So "a two-ball game scores faster" is true per
  second and false per run. What bounds earning anyway is not the rate but
  `maxTokensPerRun = 50` and `dailyCap = 200`, which are per run and per
  player-day: four capped runs a day is four capped runs whatever the ball count,
  and those caps are shared across the boards. A per-mode rate would have to be
  explained in the UI as "two-ball runs pay less", which a player experiences as a
  con — and it would make the catalogue's prices mean different things in
  different games. The run digest *does* now include the ball count, so the two
  games are two runs in the ledger; it is written so a one-ball digest is
  byte-identical to the previous build's, because `token_awards` is keyed by it
  and re-deriving it differently would let every run ever submitted be paid a
  second time.
* `idx_scores_balls (balls, score DESC, created_at)` and
  `idx_scores_balls_country (balls, country, score DESC, created_at)` make a
  board's top 100 a prefix scan, so the filter costs no sort.

**Duel rooms** carry the count too (SPEC §3): the creator sends
`{"t":"create","n":2}`, both players get it back on `room` — which is how the
joining player learns what they joined, before the countdown — and on `start`,
and it is fixed for the room's life including rematches. A count outside 1..2 is
`{"t":"error","code":"bad_balls"}` and no room is created. A `create` without
`n` is a one-ball room.

## National leaderboard

A global top 100 is unreachable for an ordinary player, so it stops being a goal
after the first look. A national board is winnable, which is the only reason to
show a ranking at all. It is a **filter over the same rows** — nothing is stored
twice, nothing is re-ranked, and the pre-existing rows simply belong to no
country.

```
POST /api/scores    {"name":"Ada","replay":…,"country":"pl"}
201  {"ok":true,"id":"…","score":18,"rank":1,"playerId":"…","country":"PL","countryRank":1}

POST /api/scores    {"name":"Nobody","replay":…,"country":"pl_PL"}
201  {"ok":true,"id":"…","score":6,"rank":2}          # hint dropped, run stored

GET  /api/leaderboard?country=PL&period=week
200  {"entries":[{"rank":1,"name":"Ada","score":18,"seconds":10,
                  "createdAt":"…","playerId":"…","country":"PL"}]}

GET  /api/leaderboard?country=XX
400  {"ok":false,"error":"invalid_country","detail":"country must be an ISO 3166-1 alpha-2 code"}
```

* The code is an ISO 3166-1 alpha-2 code the **client derives from the device
  locale**. Case and padding are forgiven; a whole locale tag (`pl_PL`, `en-GB`)
  is not, so send the region subtag alone.
* It is a **hint, not a claim.** It is never checked against the submitter's
  address — the stored `ip_hash` is a one-way digest, and geolocating it would be
  unreliable and a privacy step backwards — so only its shape is validated,
  against the 249 currently assigned codes. Anything else is **dropped and the
  run is stored anyway**: a stale device locale must not cost somebody a verified
  score. `country` and `countryRank` come back exactly when the hint was
  accepted, which is also the cheapest way for a client to notice it is sending
  the wrong thing.
* On `GET /api/leaderboard` and `/rank` an unusable code is `400 invalid_country`
  instead, because answering a request for one country's board with the whole
  world's is a wrong answer rather than a lenient one — the same treatment
  `period` has always had.
* `country` composes with `period` and `balls`, and `rank` is the position inside
  the returned board (1..N). Someone who is 4 000th in the world can be 12th at
  home.
* `GET /api/players/me` reports `country`, `countryBestScore` and `countryRank`.
  The country is the one the player's **newest run carried**, the same rule the
  display name follows, and a run with no country does not clear it — it is one
  fact about the person, not one per board, because somebody who plays both games
  plays them in the same place. The national *standing* is per board, so each
  `boards` entry carries its own `countryBestScore` and `countryRank`.
  `countryBestScore` is their best run *that counts for that country*, not their
  best run overall: a player who moved would otherwise be given a national rank
  their rows do not support, and the number beside their name would not match the
  board they are on. All three are null together.
* `idx_scores_country (country, score DESC, created_at)` makes a national top 100
  a prefix scan of one country's slice, so the filter costs no sort.

## Nickname filtering

SPEC §4.2 only ever asked whether a name was 2–12 characters of letters, digits,
space, `_` and `-`. That is a validity rule, not a moderation rule: `Kurwa` and
every English four-letter word passed it. A worldwide board that children see —
and that Apple and Google review — needs the second rule.

```
POST /api/scores    {"name":"Kurwa","replay":…}
400  {"ok":false,"error":"offensive_name"}

POST /api/players   {"name":"FuCk You"}
400  {"ok":false,"error":"offensive_name"}
```

Nothing is stored on a refusal, and the offending run is simply not submitted.
The same check guards the optional name of `POST /api/players`, so a name the
player could never play under is never issued either.

* Covers **English and Polish**: profanity, sexual terms, slurs and hate
  references — deliberately not mild insults, which are endless, read as ordinary
  teasing, and cost false positives.
* Folds away the evasions people actually use: case, diacritics (`PEDAŁ`,
  `kurwą`), digit substitution (`5h1t`, `ni66er`, `f4g`, `s1ut`), separators
  (`f u c k`, `k_u_r_w_a`) and repeated characters (`fuuuuck`).
* **Ordinary names are the harder half.** A filter that refuses Cassandra, Essex,
  Nigeria or Michał is worse than none, because what it refuses is the name
  someone was given. Short or ambiguous entries are matched as **whole words**
  (`ass`, `sex`, `cum`, `dick`, `nazi`, `porn`), an allowlist rescues the real
  collisions (Scunthorpe, Penistone, Shiitake), and repeat-collapsing is switched
  off where the collapsed form is a real word (`nigger` → `niger`). The cost is
  explicit: `Ass69` and `niggger` get through. A test asserts a list of ~110
  innocent names — Polish diacritics, Thai `-porn` names, Slutsky, Fukuda,
  Hancock — is untouched.
* **Best effort, and server-side only.** Homoglyphs from another script (`хуй` in
  Cyrillic) are not folded: rewriting genuine Russian or Greek names into Latin
  and matching *those* against a profanity list is a false-positive machine. New
  slang and other languages need the list extended. Shipping the list in the
  client would publish it, invite those evasions, and still be bypassable by
  posting to `/api/scores` directly.
* The word lists are a file of their own (`lib/src/name_blocklist.dart`), with the
  match mode and the real name that forced it commented on each entry; the
  matching logic (`name_filter.dart`) is the smaller half. Which entry matched
  goes to the log and is **never** returned — that is a tuning hint for whoever
  wrote the name.

## Limits

| limit | value | guards against |
|---|---|---|
| live rooms | 500 (SPEC §3) | room-table memory |
| rooms created per IP | 4 per minute (SPEC §3) | room-table flooding |
| concurrent sockets | 2000 total, 64 per IP | session memory |
| `/ws` upgrades per IP | 128 per minute | socket churn |
| WebSocket frame | 4 KB | buffering (checked on the wire) |
| client frames per socket | 120 per second, burst 240 | event loop / tick driver |
| protocol violations per socket | 5 | junk traffic |
| `join`s naming no live room | 10 per socket, **20 per IP per 10 min** | room-code enumeration |
| score submissions per IP | 10 per minute (SPEC §4) | verifier CPU |
| player issues per IP | 10 per minute (SPEC §4.4) | junk rows in `players` |
| account calls per IP | 10 per minute (SPEC §4.5) | RSA verification CPU |
| shop calls per IP | 30 per minute (SPEC §4.8) | wallet probing |
| purchase webhooks per IP | 600 per minute (SPEC §4.9) | unauthenticated POST floods |
| credentials per player | 10, oldest evicted (SPEC §4.5) | unbounded `player_secrets` growth |
| identity token | 4 KB; account body 8 KB | base64-decoding junk |
| idle non-playing room | destroyed after 10 minutes | abandoned rooms |

Every per-IP limit is keyed by the same address (see `X-Forwarded-For` handling
below) and its expired keys are swept periodically, so the tables stay bounded
by the number of clients currently connected.

### Room-code guessing

There are only 32^4 = 1 048 576 room codes and `join` truthfully answers
`room_not_found`, so this budget is the only thing keeping a stranger out of
other people's waiting rooms. A per-socket budget is not enough on its own: it
dies with the socket, and a reconnect loop from a single IP measured ~4900
codes/s (640 codes over 64 sockets in 131 ms), which walks the whole code space
in under four minutes. The 64-sockets-per-IP cap bounds concurrency, not
reconnect rate.

Misses are therefore counted **per client IP as well: 20 per 10 minutes**, a
count that outlives the socket. The same loop now gets 20 codes per 10 minutes
and needs about a year for the whole space. Once an IP is out of budget, every
further `join` from it is answered `rate_limited` and the socket is closed with
code 4008 `room_code_guessing` *before the code is looked up*, so a guess reveals
nothing even when it happens to be right.

Honest play stays far inside the budget:

* only codes that name no live room count, so retrying a code that does exist
  (`room_full`) is free, and one mistyped code costs exactly one miss;
* two players behind the same NAT share the budget and still have ~10 fumbles
  each, and a joiner who mistypes a few times gets in normally;
* `create` is never refused by this budget, so an IP that has spent it can still
  host a room and pass the code on;
* the window slides, so the budget is back 10 minutes later.

The `/ws` upgrade cap (128 per IP per minute) is the second half of the fix: it
stops the churn rather than the guessing, so a reconnect loop cannot spend
handshakes, file descriptors and log lines either. It is deliberately twice the
64 concurrent sessions one IP may hold, so a whole NAT'd group can connect and
then reconnect once more inside the same minute. Over the cap the upgrade gets
`429` with `retry-after: 60` before any WebSocket handshake happens.

## Docker

The image is built from the repository root (it needs both `server/` and
`packages/arco_core/`):

```bash
docker build -t arco-server .
docker run --rm -p 8080:8080 -v arco_data:/app/data arco-server
```

Multi-stage: `dart:stable` compiles the server ahead of time, the runtime layer
is `debian:bookworm-slim` with `libsqlite3-0` and `ca-certificates`, running as
the non-root user `arco` (uid 10001). The database lives in the `/app/data`
volume — mount it, or the leaderboard is lost on redeploy.

## Deploying

### Fly.io

```bash
fly launch --no-deploy --name arco            # detects the Dockerfile
fly volumes create arco_data --size 1 --region fra
fly deploy
```

`fly.toml`:

```toml
app = "arco"
primary_region = "fra"

[build]

[env]
  PORT = "8080"
  DB_PATH = "/app/data/arco.db"
  VERIFY_REPLAYS = "strict"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "suspend"
  auto_start_machines = true
  min_machines_running = 1

  [[http_service.checks]]
    interval = "30s"
    timeout = "5s"
    method = "GET"
    path = "/api/health"

[mounts]
  source = "arco_data"
  destination = "/app/data"
```

Use a single machine (`min_machines_running = 1`, no autoscaling): rooms live in
memory, so two machines cannot share a duel, and the SQLite file lives on one
volume. Fly terminates TLS, so the app connects to `https://…` / `wss://…`.

### Railway

New project → *Deploy from GitHub repo*; Railway builds the root `Dockerfile`.
Add a volume mounted at `/app/data` and set `DB_PATH=/app/data/arco.db`.
Railway injects `PORT`, which the server already honours. Keep the replica count
at 1.

### Render

New *Web Service* → runtime **Docker**, root directory `.`, health check path
`/api/health`. Add a persistent disk mounted at `/app/data` and set
`DB_PATH=/app/data/arco.db`. Instance count must stay at 1.

### Anywhere else

Any host that can run a container works; only two things matter: one instance
(in-memory rooms) and a persistent `/app/data`. Behind a reverse proxy, forward
`X-Forwarded-For` — the server uses the hop the proxy appended (the rightmost
one) for rate limiting and for the stored IP hash, and ignores the header
altogether when the request did not arrive from a private-network peer, so a
client cannot forge its own rate-limit key — and allow WebSocket upgrades on
`/ws`.

## Pointing the app at the server

The Flutter client reads the base URL from a compile-time define (SPEC §5.5) and
derives the WebSocket URL from it:

```bash
flutter run  --dart-define=SERVER_URL=https://arco.fly.dev
flutter build apk --release --dart-define=SERVER_URL=https://arco.fly.dev
flutter build ipa --release --dart-define=SERVER_URL=https://arco.fly.dev
flutter build web --release --dart-define=SERVER_URL=https://arco.fly.dev
```

Default is `http://localhost:8080`; on the Android emulator `localhost` is
rewritten to `10.0.2.2` automatically. The URL can also be overridden at runtime
in *Settings → server URL*, which is handy for testing against a laptop on the
same Wi-Fi (`http://192.168.x.y:8080`).

## Operating notes

* Back up the leaderboard by copying `arco.db` (WAL mode: copy
  `-wal`/`-shm` too, or run `sqlite3 arco.db ".backup backup.db"`).
* `VERIFY_REPLAYS=off` is for local development only; with it, any client can
  claim any score.
* Logs go to stderr, one line per event, prefixed with an ISO-8601 UTC
  timestamp — `LOG_LEVEL=debug` adds every HTTP request and room event.
* Startup logs whether accounts are enabled and which providers are live, so a
  deployment that silently lost `ACCOUNTS_ENABLED` is visible in the first few
  lines. A repeated `refused <provider> identity token ... wrong_audience` in the
  log is the shape of a stale or missing client id, not an attack.
* Player secrets and identity tokens are never logged, and no identity token is
  stored — only its SHA-256 digest, until the token expires.
* Startup also logs whether purchases are enabled, which product and entitlement
  are served (`purchases enabled: arco.unlock.full (entitlement "premium")`) and
  whether sandbox purchases are granted. `RevenueCat keys are configured but
  PURCHASES_ENABLED is not "on"` in the first few lines is a deployment that
  silently lost the switch and is quietly refusing money.
* `RevenueCat reports the "premium" entitlement for player=… but no
  arco.unlock.full transaction` means the product is attached to the wrong
  entitlement in RevenueCat (or to none), and somebody has paid for nothing. It is
  the one purchase warning that needs a human in the dashboard.
* Neither RevenueCat secret is ever logged.
* A refused nickname logs `name rejected (matched "<entry>") name="…"`, which is
  how the blocklist gets tuned: a legitimate name in that line is a false
  positive to fix in `name_blocklist.dart` (add it to `innocentSubstrings`, or
  make the entry `whole: true`), and a run of them from one IP is somebody
  probing the filter. The matched entry is never in the response.
* A run stored with `country=-` in the score line carried no usable country code
  — normal for an older client, and worth a look if *every* line says it while
  the app is meant to be sending one.
* The score line carries `balls=N`, so which board a run went to is in the log
  without a query. `room <code> created by <name> with N ball(s)` does the same
  for duel rooms.
* **Upgrading to the board schema (`user_version` 8).** The database upgrades in
  place on open, as always, and this one adds a single column,
  `scores.balls NOT NULL DEFAULT 1`, plus two indexes. Every existing row reads
  `balls = 1`, which is the truth about it rather than a backfill: until this
  version the simulation had exactly one ball. Nothing is dropped, nothing is
  rewritten, no row is moved. After the upgrade `GET /api/leaderboard` with no
  `balls` parameter returns exactly the board it returned before, in the same
  order — so a deployed app that has not been updated sees no change at all on
  that route. `dart test test/migration_test.dart` covers this upgrade from a
  file written by the current (version 7) schema, including over HTTP.
* **After this release, the deployed app can no longer submit scores.** The
  simulation changed (wall shapes and ball counts), so a replay recorded by the
  old build cannot be re-simulated: `POST /api/scores` answers
  `400 unsupported_version`, checked before anything is simulated and before
  `VERIFY_REPLAYS` is consulted. That code means *the app is too old*, not *this
  score is bad*, and the app renders it as "update the app". Duel sockets from an
  old build are already refused at `hello` with `bad_version`, because
  `protocolVersion` went from 1 to 2. Scores already stored are untouched, and an
  old client can still read the leaderboard.
