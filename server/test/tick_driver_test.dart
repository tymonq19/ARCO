/// The 60 Hz tick driver: the catch-up cap of SPEC §3 drops backlog instead of
/// snowballing, and says so in the log.
library;

import 'package:arco_server/arco_server.dart';
import 'package:test/test.dart';

void main() {
  group('tick driver catch-up cap', () {
    late List<String> lines;
    late DateTime now;
    late RoomRegistry registry;

    setUp(() {
      lines = <String>[];
      now = DateTime.utc(2026, 9, 23, 12);
      registry = RoomRegistry(
        log: Logger(LogLevel.warn, sink: lines.add),
        clock: () => now,
      );
      addTearDown(registry.close);
    });

    test('a backlog within the cap is caught up silently', () {
      registry.catchUpTo(registry.maxCatchUpTicks);
      expect(registry.ticksDone, registry.maxCatchUpTicks);
      expect(registry.droppedTicks, 0);
      expect(lines, isEmpty);
    });

    test('dropped ticks are warned about, not only counted', () {
      // 12 ticks due, 5 processed: the remaining 7 are lost real time for
      // every room, so the driver must leave a trace in the log.
      registry.catchUpTo(12);

      expect(registry.droppedTicks, 12 - registry.maxCatchUpTicks);
      expect(registry.ticksDone, 12);
      expect(lines, hasLength(1));
      expect(lines.single, contains('WARN'));
      expect(lines.single, contains('tick driver starved'));
      expect(lines.single, contains('dropped 7 ticks'));
      expect(lines.single, contains('7 total'));
      expect(lines.single, contains('0/0 rooms running'));
      expect(lines.single, contains('0 sessions'));
    });

    test(
      'the warning is throttled and reports the ticks since the last one',
      () {
        registry.catchUpTo(12);
        expect(lines, hasLength(1));

        // A starved event loop drops on every callback; one line per callback
        // would drown the log, so further drops inside the interval are folded
        // into the next line.
        now = now.add(
          droppedTickReportInterval - const Duration(milliseconds: 1),
        );
        registry.catchUpTo(30);
        registry.catchUpTo(48);
        expect(lines, hasLength(1));

        now = now.add(droppedTickReportInterval);
        registry.catchUpTo(60);
        expect(lines, hasLength(2));
        // 13 + 13 + 7 ticks lost since the first line, 40 in total.
        expect(lines[1], contains('dropped 33 ticks'));
        expect(lines[1], contains('40 total'));
        expect(registry.droppedTicks, 40);
      },
    );

    test('a burst that ends inside the throttle window is still reported', () {
      registry.catchUpTo(12);
      expect(lines, hasLength(1));

      now = now.add(const Duration(milliseconds: 1));
      registry.catchUpTo(30);
      expect(lines, hasLength(1), reason: 'throttled');

      // The event loop recovers: the next healthy callback past the interval
      // flushes the 13 ticks that the throttle swallowed.
      now = now.add(droppedTickReportInterval);
      registry.catchUpTo(registry.ticksDone + registry.maxCatchUpTicks);
      expect(registry.droppedTicks, 20);
      expect(lines, hasLength(2));
      expect(lines[1], contains('dropped 13 ticks'));
      expect(lines[1], contains('20 total'));

      // Nothing left to report: healthy callbacks stay silent.
      now = now.add(droppedTickReportInterval);
      registry.catchUpTo(registry.ticksDone + registry.maxCatchUpTicks);
      expect(lines, hasLength(2));
    });
  });
}
