/// One duel room: two player slots, lifecycle and the per-tick simulation.
library;

import 'package:arco_core/arco_core.dart';

import 'session.dart';

/// How far ahead of the room's own sim tick a client input tick may be before
/// the server stops believing it (1 s). Clients predict a few ticks ahead and
/// may finish the countdown slightly before the server does, so the window is
/// generous; anything beyond it is a bug, a duplicated frame or a forged one.
const int maxInputTickLead = tickRate;

/// `waiting → countdown → playing → over → (rematch) countdown …`
enum RoomState { waiting, countdown, playing, over }

class Room {
  Room(this.code, {required DateTime now})
    : createdAt = now,
      lastActivity = now;

  final String code;
  final DateTime createdAt;

  /// Last time a player did something that changed the room (join, game start,
  /// rematch vote, input while a game runs); drives the idle timeout for rooms
  /// that are not playing. Input received while `waiting` or `over` does not
  /// count, so a client cannot hold a room slot with a keep-alive (SPEC §3).
  DateTime lastActivity;

  RoomState state = RoomState.waiting;

  /// Player slots: 0 = creator (bottom half), 1 = joiner (top half).
  final List<ClientSession?> slots = <ClientSession?>[null, null];

  /// Seed of the current (or upcoming) game.
  int seed = 0;

  /// Server ticks left before sim tick 0 while in [RoomState.countdown].
  int countdownLeft = 0;

  GameState? game;

  /// Latest input received per slot; applied every tick.
  final List<PlayerInput> inputs = <PlayerInput>[
    PlayerInput.none,
    PlayerInput.none,
  ];

  /// Client tick of the latest accepted input per slot (older ticks are ignored).
  final List<int> lastInputTick = <int>[-1, -1];

  final List<bool> rematchVotes = <bool>[false, false];

  /// Events accumulated since the previous snapshot.
  final List<GameEvent> _pendingEvents = <GameEvent>[];

  /// Snapshots sent in the current game (statistics / tests).
  int snapshotsSent = 0;

  int get playerCount => slots.where((s) => s != null).length;
  bool get isFull => slots[0] != null && slots[1] != null;
  bool get isEmpty => playerCount == 0;

  /// Rooms in these states are advanced by the tick driver.
  bool get isRunning =>
      state == RoomState.countdown || state == RoomState.playing;

  List<String?> get names => [for (final s in slots) s?.name];

  /// Current sim tick, -1 when no game is in progress.
  int get currentTick => game?.tick ?? -1;

  ClientSession? peerOf(ClientSession s) =>
      slots[0] == s ? slots[1] : (slots[1] == s ? slots[0] : null);

  void touch(DateTime now) => lastActivity = now;

  /// Seats [session] in the first free slot and returns it (0 or 1); -1 when full.
  int addPlayer(ClientSession session, DateTime now) {
    for (var i = 0; i < slots.length; i++) {
      if (slots[i] == null) {
        slots[i] = session;
        session.room = this;
        session.slot = i;
        touch(now);
        return i;
      }
    }
    return -1;
  }

  void removePlayer(ClientSession session) {
    for (var i = 0; i < slots.length; i++) {
      if (slots[i] == session) {
        slots[i] = null;
        session.room = null;
        session.slot = -1;
      }
    }
  }

  /// Sends the current `room` message to every seated player.
  void broadcastRoomInfo() {
    for (var i = 0; i < slots.length; i++) {
      slots[i]?.send(RoomMsg(code: code, slot: i, names: names));
    }
  }

  /// Starts a new game (first game or rematch): announces `start` and enters
  /// the countdown. Sim tick 0 exists [countdownTicks] server ticks later.
  void begin(int newSeed, DateTime now) {
    seed = newSeed;
    game = null;
    state = RoomState.countdown;
    countdownLeft = countdownTicks;
    snapshotsSent = 0;
    _pendingEvents.clear();
    for (var i = 0; i < 2; i++) {
      inputs[i] = PlayerInput.none;
      lastInputTick[i] = -1;
      rematchVotes[i] = false;
    }
    touch(now);
    broadcast(
      StartMsg(
        seed: seed,
        countdown: countdownTicks,
        names: [for (final n in names) n ?? ''],
      ),
    );
  }

  /// Applies an input message from [slot]; inputs older than the last
  /// accepted tick are ignored (SPEC §3).
  ///
  /// A tick further than [maxInputTickLead] ahead of the room's own sim tick is
  /// ignored too: the tick is only ever compared against itself, so accepting a
  /// wild one would make it the ordering watermark and drop every later (honest)
  /// input from that slot until the next `begin()`. Dropping the frame instead
  /// leaves the watermark near the live tick, so input recovers by itself.
  ///
  /// Only input that feeds a running game counts as activity: a room that is
  /// `waiting` for a friend (or sitting in `over`) stays idle no matter how
  /// much input arrives, so the idle sweep can reclaim it (SPEC §3).
  void applyInput(int slot, InputMsg msg, DateTime now) {
    if (slot < 0 || slot > 1) return;
    if (msg.tick < lastInputTick[slot]) return;
    if (msg.tick > currentTick + maxInputTickLead) return;
    lastInputTick[slot] = msg.tick;
    inputs[slot] = PlayerInput.decode(msg.input);
    if (isRunning) touch(now);
  }

  /// Records a rematch vote; returns true when both players voted.
  bool voteRematch(int slot, DateTime now) {
    if (state != RoomState.over || slot < 0 || slot > 1) return false;
    rematchVotes[slot] = true;
    touch(now);
    return rematchVotes[0] && rematchVotes[1];
  }

  /// Advances the room by one server tick (60 Hz). Countdown → creates the
  /// state and performs the first step when it expires; playing → one
  /// `Simulation.step`, a snapshot every [snapshotInterval] ticks and on game
  /// over, then `over`.
  void tick() {
    switch (state) {
      case RoomState.waiting:
      case RoomState.over:
        return;
      case RoomState.countdown:
        countdownLeft--;
        if (countdownLeft > 0) return;
        game = GameState.initial(GameConfig(mode: GameMode.duel, seed: seed));
        state = RoomState.playing;
        _step();
      case RoomState.playing:
        _step();
    }
  }

  void _step() {
    final g = game!;
    Simulation.step(g, inputs);
    _pendingEvents.addAll(g.events);
    final over = g.phase == Phase.gameOver;
    if (over || g.tick % snapshotInterval == 0) {
      _flushSnapshot(g);
    }
    if (over) {
      state = RoomState.over;
      broadcast(
        OverMsg(winner: g.winner, scores: [for (final p in g.players) p.score]),
      );
    }
  }

  void _flushSnapshot(GameState g) {
    final snap = SnapMsg(
      tick: g.tick,
      state: g.toJson(),
      events: List<GameEvent>.of(_pendingEvents),
    );
    _pendingEvents.clear();
    snapshotsSent++;
    broadcast(snap);
  }

  /// Encodes [msg] once and sends it to every seated player.
  void broadcast(ServerMsg msg) {
    final frame = encodeMsg(msg);
    for (final s in slots) {
      s?.sendFrame(frame);
    }
  }
}
