/// Room-code enumeration: the per-socket guess budget only ends one socket's
/// guessing, so the budget that actually bounds a guesser is the per-IP one
/// ([joinMissesPerIp]) plus the `/ws` upgrade limit
/// ([wsUpgradesPerIpPerMinute]). SPEC §3 (`join` → `room_not_found`).
library;

import 'package:arco_core/arco_core.dart';
import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support.dart';

/// Loopback is what every test client connects from, so it is the rate-limit
/// key the server derives with `clientIp()`.
const String _testIp = '127.0.0.1';

/// An upgrade limiter so loose it can never be what stops a loop, so that a
/// test can show the *join* budget doing the stopping.
RateLimiter _unlimitedUpgrades() =>
    RateLimiter(limit: 1000000, window: const Duration(minutes: 1));

/// Well-formed codes `AAAA`, `AAAB`, … over [roomCodeAlphabet], skipping [skip]
/// so a guess never hits the live room by accident.
Iterable<String> _codeSequence({String? skip}) sync* {
  for (final a in roomCodeAlphabet.split('')) {
    for (final b in roomCodeAlphabet.split('')) {
      for (final c in roomCodeAlphabet.split('')) {
        for (final d in roomCodeAlphabet.split('')) {
          final code = '$a$b$c$d';
          if (code != skip) yield code;
        }
      }
    }
  }
}

/// What one socket of a reconnect loop managed to learn before it was cut off.
class _Burst {
  _Burst({required this.answered, this.lastError, this.closeCode});

  /// Guesses the server actually answered, i.e. codes this socket ruled out.
  final int answered;

  /// `error` code of the last reply received.
  final String? lastError;
  final int? closeCode;
}

/// Opens a fresh socket and guesses codes until the server closes it.
///
/// This is the attack shape the per-socket budget does not cover: short-lived
/// sockets from one IP, each burning its own [maxMissedJoins] and then
/// reconnecting.
Future<_Burst> _guessUntilCutOff(
  ArcoServer server,
  Iterator<String> codes, {
  int maxGuesses = maxMissedJoins * 2,
}) async {
  final client = await TestClient.connect(server, name: 'Guesser');
  var answered = 0;
  String? lastError;
  for (var i = 0; i < maxGuesses && !client.isClosed; i++) {
    codes.moveNext();
    try {
      client.send(JoinRoomMsg(code: codes.current));
      final msg = await client.nextOf<ErrorMsg>(
        timeout: const Duration(seconds: 5),
      );
      lastError = msg.code;
      // A refused attempt is never answered from the room table, so it tells
      // the guesser nothing about the code.
      if (msg.code == 'rate_limited') break;
      answered++;
    } on StateError {
      break; // The socket went away between the send and the reply.
    }
  }
  await client.closed.timeout(const Duration(seconds: 5));
  return _Burst(
    answered: answered,
    lastError: lastError,
    closeCode: client.closeCode,
  );
}

/// Creates a room and returns its code.
Future<String> _openRoom(ArcoServer server, {String name = 'Host'}) async {
  final host = await TestClient.connect(server, name: name);
  host.send(const CreateRoomMsg());
  return (await host.nextOf<RoomMsg>()).code;
}

void main() {
  group('reconnect-loop enumeration', () {
    test('a reconnect loop cannot out-live the per-IP guess budget', () async {
      final server = await bootServer(upgradeLimiter: _unlimitedUpgrades());
      final code = await _openRoom(server);
      final codes = _codeSequence(skip: code).iterator;

      // Enough sockets that the per-socket budget alone would hand out
      // 6 x maxMissedJoins = 60 answered guesses.
      const sockets = 6;
      expect(
        sockets * maxMissedJoins,
        greaterThan(joinMissesPerIp),
        reason: 'the loop must ask for more than the per-IP budget allows',
      );
      var learned = 0;
      final bursts = <_Burst>[];
      for (var i = 0; i < sockets; i++) {
        final burst = await _guessUntilCutOff(server, codes);
        bursts.add(burst);
        learned += burst.answered;
        expect(
          burst.closeCode,
          closeCodePolicyViolation,
          reason: 'socket ${i + 1} must be cut off',
        );
      }

      expect(
        learned,
        joinMissesPerIp,
        reason:
            'the whole loop may only ever rule out joinMissesPerIp codes, '
            'however many sockets it opens',
      );
      expect(server.rooms.joinMissCount(_testIp), joinMissesPerIp);
      // Once the budget is spent the later sockets learn nothing at all: they
      // are refused before the code is looked up.
      expect(bursts.last.answered, 0);
      expect(bursts.last.lastError, 'rate_limited');
      expect(
        server.rooms.roomCount,
        1,
        reason: 'the waiting room must still be there, just not findable',
      );
    });

    test('a spent budget hides a live room from a fresh socket', () async {
      final server = await bootServer(upgradeLimiter: _unlimitedUpgrades());
      final code = await _openRoom(server);
      final codes = _codeSequence(skip: code).iterator;
      while (server.rooms.joinMissCount(_testIp) < joinMissesPerIp) {
        await _guessUntilCutOff(server, codes);
      }

      // The real code now gets the same answer as a wrong one, so the guesser
      // cannot tell a hit from a miss even when it finally guesses right.
      final stranger = await TestClient.connect(server, name: 'Stranger');
      stranger.send(JoinRoomMsg(code: code));
      expect((await stranger.nextOf<ErrorMsg>()).code, 'rate_limited');
      await stranger.closed.timeout(const Duration(seconds: 5));
      expect(stranger.closeCode, closeCodePolicyViolation);
      expect(server.rooms.roomByCode(code)!.isFull, isFalse);
    });

    test('the budget is per IP, not per socket', () async {
      // A budget of 3 is below the per-socket budget, so the only thing that
      // can end the second socket's guessing is the per-IP one.
      final server = await bootServer(
        upgradeLimiter: _unlimitedUpgrades(),
        joinMissLimiter: RateLimiter(limit: 3, window: joinMissWindow),
      );
      final codes = _codeSequence().iterator;
      final first = await _guessUntilCutOff(server, codes);
      expect(first.answered, 3);
      expect(first.lastError, 'room_not_found');
      expect(first.closeCode, closeCodePolicyViolation);
      expect(
        first.answered,
        lessThan(maxMissedJoins),
        reason: 'the per-socket budget must not be what cut this socket off',
      );

      final second = await _guessUntilCutOff(server, codes);
      expect(
        second.answered,
        0,
        reason: 'the budget did not survive the close',
      );
      expect(second.lastError, 'rate_limited');
      expect(second.closeCode, closeCodePolicyViolation);
    });

    test('the budget comes back when its window has passed', () async {
      var now = DateTime.utc(2026, 9, 23, 12).millisecondsSinceEpoch;
      final server = await bootServer(
        upgradeLimiter: _unlimitedUpgrades(),
        joinMissLimiter: RateLimiter(
          limit: 3,
          window: joinMissWindow,
          clock: () => now,
        ),
      );
      final code = await _openRoom(server);
      final codes = _codeSequence(skip: code).iterator;
      await _guessUntilCutOff(server, codes);
      expect(server.rooms.joinMissCount(_testIp), 3);

      now += joinMissWindow.inMilliseconds + 1;
      expect(server.rooms.joinMissCount(_testIp), 0);

      // A player who gave up, waited and came back can join again.
      final guest = await TestClient.connect(server, name: 'Guest');
      guest.send(JoinRoomMsg(code: code));
      expect((await guest.nextOf<RoomMsg>()).code, code);
    });
  });

  group('honest mistypes', () {
    test('a few wrong codes still get the player into the room', () async {
      final server = await bootServer();
      final code = await _openRoom(server);
      final guest = await TestClient.connect(server, name: 'Guest');

      // Five fumbles is more than anyone really needs and well inside both
      // budgets.
      const fumbles = 5;
      expect(fumbles, lessThan(maxMissedJoins));
      expect(fumbles, lessThan(joinMissesPerIp));
      final wrong = _codeSequence(skip: code).take(fumbles);
      for (final guess in wrong) {
        guest.send(JoinRoomMsg(code: guess));
        expect((await guest.nextOf<ErrorMsg>()).code, 'room_not_found');
      }

      guest.send(JoinRoomMsg(code: code));
      expect((await guest.nextOf<RoomMsg>()).code, code);
      expect(guest.isClosed, isFalse);
      expect(server.rooms.roomByCode(code)!.isFull, isTrue);
    });

    test('two players behind one NAT can still play a duel', () async {
      // Both clients come from the same IP, and the guest mistypes on the way
      // in: the per-IP budget must not turn that into a refused duel.
      final server = await bootServer();
      final host = await TestClient.connect(server, name: 'Host');
      host.send(const CreateRoomMsg());
      final code = (await host.nextOf<RoomMsg>()).code;

      final guest = await TestClient.connect(server, name: 'Guest');
      for (final guess in _codeSequence(skip: code).take(3)) {
        guest.send(JoinRoomMsg(code: guess));
        expect((await guest.nextOf<ErrorMsg>()).code, 'room_not_found');
      }
      guest.send(JoinRoomMsg(code: code));
      await guest.nextOf<RoomMsg>();

      // The host is told the peer arrived, then both are started.
      expect((await host.nextOf<RoomMsg>()).names, ['Host', 'Guest']);
      expect((await host.nextOf<StartMsg>()).names, ['Host', 'Guest']);
      expect((await guest.nextOf<StartMsg>()).names, ['Host', 'Guest']);
      expect(server.rooms.joinMissCount(_testIp), 3);
    });

    test('a join that names a live room never costs per-IP budget', () async {
      final server = await bootServer();
      final code = await _openRoom(server);
      final guest = await TestClient.connect(server, name: 'Guest');
      guest.send(JoinRoomMsg(code: code));
      await guest.nextOf<RoomMsg>();

      // room_full is a real answer about a real room, so hammering it is not
      // guessing and must stay free (see protocol_test.dart for the
      // per-socket side of this).
      final late = await TestClient.connect(server, name: 'Late');
      for (var i = 0; i < joinMissesPerIp * 2; i++) {
        late.send(JoinRoomMsg(code: code));
        expect((await late.nextOf<ErrorMsg>()).code, 'room_full');
      }
      expect(late.isClosed, isFalse);
      expect(server.rooms.joinMissCount(_testIp), 0);
    });
  });

  group('/ws upgrade limit', () {
    test('is generous enough for a full NAT group', () {
      expect(
        wsUpgradesPerIpPerMinute,
        greaterThan(maxLiveSessionsPerIp),
        reason: 'every session one IP may hold must be openable in a minute',
      );
    });

    test('refuses socket churn with 429 before the handshake', () async {
      final server = await bootServer(
        upgradeLimiter: RateLimiter(
          limit: 2,
          window: const Duration(minutes: 1),
        ),
      );
      final a = await TestClient.connect(server, name: 'Alice');
      final b = await TestClient.connect(server, name: 'Bob');
      expect(server.rooms.sessionCount, 2);

      final refused = await http.get(Uri.parse('${server.baseUrl}/ws'));
      expect(refused.statusCode, 429);
      expect(refused.headers['retry-after'], '60');

      // A real upgrade attempt fails outright: nothing is upgraded, so no
      // session slot and no handshake is spent on it.
      final channel = WebSocketChannel.connect(
        Uri.parse('ws://${server.address.address}:${server.port}/ws'),
      );
      await expectLater(channel.ready, throwsA(isA<Object>()));
      expect(server.rooms.sessionCount, 2);
      expect(a.isClosed, isFalse);
      expect(b.isClosed, isFalse);
    });
  });
}
