# Arco

A circular paddle game for phones. Keep the ball inside the ring with a paddle that slides around the
circumference, grab hearts and stars, dodge the walls that pop up mid-game, and climb a global leaderboard. Play
solo or duel a friend online by sharing a 4-letter room code.

- **Flutter app** (iOS, Android, web) — `lib/`
- **Shared deterministic simulation** — `packages/arco_core/` (pure Dart, used by the app *and* the server)
- **Dart server** — `server/` (duel rooms over WebSocket + the leaderboard REST API)

The leaderboard is cheat-resistant: a solo game is recorded as a seed + input log, and the server re-simulates the
recording before accepting a score. Both sides run the exact same code, and the simulation uses only bit-exact
arithmetic, so the replay is bit-identical on phones, on the server and even when compiled to JavaScript.

See `SPEC.md` for the complete game design, rules, protocol and architecture.

## Gameplay

| | Solo | Duel |
|---|---|---|
| Paddle | roams the whole circle | each player defends one half (you always see yours at the bottom) |
| Lives | 3 (max 5) | 3 each (max 5) |
| Goal | survive as long as possible, score points | make your friend miss first |
| Leaderboard | global (all time / week / today) | — |

Scoring: paddle hit **+10 × multiplier**, star **+100 × multiplier**, wall bounce **+5 × multiplier**, **+1 per
second** survived (solo). The multiplier grows by one for every 5 consecutive hits (max ×8) and resets when you lose a
life. Hearts restore a life. Walls appear more often the longer you survive and the ball speeds up with every hit.

Controls (Settings): **Joystick** (floating one-axis stick under your thumb, default), **Tilt** (phone gyroscope,
with calibration and sensitivity), or **Follow** (the paddle chases your finger around the ring). Keyboard arrows
work on desktop/web.

## Run it

Requirements: Flutter ≥ 3.41 (Dart ≥ 3.11). Server: Dart SDK + SQLite (`libsqlite3`, present on macOS; on Debian
`apt install libsqlite3-0`).

```bash
# 1. server (defaults: PORT=8080, DB_PATH=data/arco.db, VERIFY_REPLAYS=strict)
cd server && dart pub get && dart run bin/server.dart

# 2. app — point it at the server
flutter pub get
flutter run --dart-define=SERVER_URL=http://localhost:8080          # iOS simulator / desktop / web
flutter run --dart-define=SERVER_URL=http://192.168.1.20:8080       # real phone on the same Wi-Fi (your Mac's IP)
```

The server URL can also be changed at runtime in **Settings → Advanced**. On the Android emulator `localhost` is
mapped to `10.0.2.2` automatically.

Deploying the server (Docker image in `Dockerfile`, details in `README.server.md`):

```bash
docker build -t arco-server .
docker run -p 8080:8080 -v arco_data:/app/data arco-server
```

Then build the app with `--dart-define=SERVER_URL=https://your-host`.

## Sound

Every effect is synthesised — no recordings, no third-party assets, nothing to license.
`dart run tool/gen_sfx.dart` writes `assets/sfx/` (18 files, 840 KB, 44.1 kHz 16-bit) and prints what it
measured:

```
name          ch     ms      KB  peak dB    LUFS
hit            1     86     7.5    -2.70  -11.57
...
18 files, 839.6 KB total, 44100 Hz / 16-bit, target -11.5 LUFS.
```

Ten logical effects — `hit`, `wall`, `star`, `heart`, `lose`, `serve`, `gameover`, `win`, `click`,
`countdown` — plus two families `AudioService` picks between on its own: `hit2`…`hit8`, one per score
multiplier, so a rally climbs a major pentatonic from C5 to E6 and a long rally audibly builds; and
`countdown_go`, the GO that ends a duel countdown. Call sites play *events* (`audio.play(Sfx.hit)`) and never
name a file.

Mastering: each file is loudness-matched to **-11.5 LUFS** over its loudest 100 ms (K-weighted, ITU-R
BS.1770), peak-capped at **-1 dBFS** and faded at both ends. The relative mix therefore lives entirely in
`AudioService.levelOf` and never in the assets, and every level is scaled by `AudioService.headroom` (0.7,
-3.1 dB) because one simulation tick can land a wall bounce, a paddle hit *and* a pickup at once and
`audioplayers` gives us no bus to put a limiter across.

**One set serves all four themes.** Neon, Classic, Modernist and Glass are palette and stroke systems: the
ball and the paddle are the same simulated objects in each, so there is nothing for a timbre to follow. These
effects are also information before they are decoration — `wall` sits an octave and a fifth below `hit` so
the ear separates them without looking, `star` and `heart` are opposites in register and attack, and the
eight `hit` tiers *are* the combo read-out. A cosmetic that can be equipped between two rallies must not
retune that. (Four full sets would also mean 32 hit files and ~3.4 MB shipped to every player, four times the
player pool, and four times the surface to keep matched inside 0.6 dB.)

### Dropping in a recording

Any synthesised file can be replaced with a bought or recorded one, per file, without touching the code:

1. **Convert** to uncompressed 16-bit PCM WAV at 44.1 kHz, named exactly like the file it replaces
   (`assets/sfx/hit.wav`). Mono for the impacts, stereo is fine for the long moments.
   `ffmpeg -i source.aiff -ar 44100 -ac 1 -c:a pcm_s16le assets/sfx/wall.wav`
2. **Normalise** to -11.5 LUFS momentary with the peak at or below -1 dBFS, and fade the last ~6 ms so a
   truncated tail cannot click. Measure first, then apply a flat gain — `loudnorm` needs three seconds of
   audio and is useless on an 86 ms impact:

   ```bash
   dart run tool/gen_sfx.dart            # prints the measured LUFS of a listed file
   ffmpeg -i in.wav -af "volume=<target - measured>dB,afade=t=out:st=<length-0.006>:d=0.006" \
     -ar 44100 -c:a pcm_s16le assets/sfx/wall.wav
   ```

   Do not compensate for how loud the event should *feel* — that is `AudioService.levelOf`'s job. Match the
   set and leave the mix alone.
3. **Keep it short.** A paddle hit must stay under 115 ms (the ball can cross the arena that fast), the UI
   click under 80 ms, and nothing over 1.5 s.
4. **List it** in `assets/sfx/RECORDED` (one name per line, `#` for comments; create the file if it does not
   exist) so `gen_sfx.dart` stops overwriting it. The tool then measures your file in place and marks it `*`:

   ```
   $ dart run tool/gen_sfx.dart
   click          1    272    23.5   -28.52  -29.00 *
   1 marked * kept from RECORDED and measured in place; target -11.5 LUFS, peak -1.0 dBFS.
   warning: click: 48000 Hz, not 44100 Hz
   ```
5. **Verify**: `flutter test test/services/sfx_assets_test.dart`. It measures every file on disk, recorded or
   not — format, duration, peak, loudness against the rest of the set, clipping, a truncated tail, and
   whether the mix still leaves room for a busy frame.

No `pubspec.yaml` change is needed: the whole directory is bundled.

**Other formats.** `audioplayers` will also decode MP3, AAC and OGG on device, but `AudioService.assetPathOf`
builds `sfx/<clip>.wav`, so another container means changing that one line — and accepting that a compressed
one-shot starts a few milliseconds late. That latency is why the whole set is uncompressed; at 840 KB there
is nothing to save.

### One recording for the eight pitched hits

`hit` is eight files, not one. If you drop in a single paddle recording as `hit.wav` and leave the rest
synthesised, the rally changes timbre at the 5th hit of every rally — the generator warns about exactly this.
Render all eight from your source instead, at the pentatonic steps the synth uses (0, 2, 4, 7, 9, 12, 14, 16
semitones). Tape-style resampling is the right tool here: it shortens and brightens together, which is what
the synthesised ladder does.

```bash
steps=(0 2 4 7 9 12 14 16)
for i in "${!steps[@]}"; do
  n=$((i + 1)); out=$([ "$n" = 1 ] && echo hit || echo "hit$n")
  rate=$(python3 -c "print(round(44100 * 2 ** (${steps[$i]} / 12)))")
  ffmpeg -y -i hit_source.wav -af "asetrate=$rate,aresample=44100" \
    -ac 1 -c:a pcm_s16le "assets/sfx/$out.wav"
  echo "$out" >> assets/sfx/RECORDED
done
```

If you genuinely want one flat recording and no ladder, copy the same file to all eight names and list them
all. The combo then stops being audible, which is a real loss: the climb is the only way the player hears the
multiplier without looking at the HUD.

## Tests

```bash
(cd packages/arco_core && dart test)   # simulation, determinism, replay verification
(cd server && dart test)               # rooms end-to-end over WebSocket, leaderboard API
flutter test                           # controllers, painter, screens
```

`packages/arco_core/tool/det_check.dart` prints the state hash after 20 000 ticks; run it with `dart run`,
as a compiled executable and compiled to JavaScript (`node`) — all three must match.

## Layout

```
lib/app             theme, i18n (EN/PL), settings, server config
lib/game            renderer (CustomPainter), input modes, solo/duel controllers, effects
lib/ui              screens: home, solo, duel lobby, duel, leaderboard, settings
lib/services        REST client, WebSocket duel client, storage, audio, haptics
packages/arco_core  DetMath, Prng, GameState, Simulation.step, Replay, protocol messages
server/             shelf app: /ws rooms, /api/leaderboard, /api/scores (replay verification in an isolate)
tool/gen_sfx.dart   synthesizes the sound effects in assets/sfx
```
