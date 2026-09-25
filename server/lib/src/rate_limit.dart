/// Rate limiting: a sliding window keyed by an arbitrary string (usually an
/// IP) and a token bucket for a single event stream (one WebSocket session).
library;

int _wallClock() => DateTime.now().millisecondsSinceEpoch;

/// Allows at most [limit] events per key inside [window].
///
/// Rejected events are not recorded, so a hammering client cannot keep
/// extending its own ban. Memory is bounded by calling [sweep] periodically.
class RateLimiter {
  RateLimiter({
    required this.limit,
    required this.window,
    int Function()? clock,
  }) : _clock = clock ?? _wallClock;

  /// Maximum number of events allowed per key inside [window].
  final int limit;
  final Duration window;
  final int Function() _clock;

  final Map<String, List<int>> _events = <String, List<int>>{};

  /// Number of keys currently tracked (diagnostics / tests).
  int get keyCount => _events.length;

  /// Records an event for [key] and returns whether it is within the limit.
  bool allow(String key) {
    final now = _clock();
    final list = _events.putIfAbsent(key, () => <int>[]);
    _prune(list, now);
    if (list.length >= limit) return false;
    list.add(now);
    return true;
  }

  /// Events currently counted for [key].
  int count(String key) {
    final list = _events[key];
    if (list == null) return 0;
    _prune(list, _clock());
    return list.length;
  }

  /// Forgets [key] entirely.
  void reset(String key) => _events.remove(key);

  /// Drops keys with no events left inside the window.
  void sweep() {
    final now = _clock();
    _events.removeWhere((_, list) {
      _prune(list, now);
      return list.isEmpty;
    });
  }

  void _prune(List<int> list, int now) {
    final cutoff = now - window.inMilliseconds;
    var drop = 0;
    while (drop < list.length && list[drop] <= cutoff) {
      drop++;
    }
    if (drop > 0) list.removeRange(0, drop);
  }
}

/// Token bucket for a single stream of events (typically one WebSocket).
///
/// [burst] tokens are available at once and refill at [ratePerSecond]. Unlike
/// [RateLimiter] it keeps two integers instead of a timestamp per event, which
/// is what makes it affordable when every client frame takes a token.
class TokenBucket {
  TokenBucket({
    required this.ratePerSecond,
    required this.burst,
    int Function()? clock,
  }) : assert(ratePerSecond > 0),
       assert(burst > 0),
       _clock = clock ?? _wallClock {
    _milliTokens = burst * 1000;
    _last = _clock();
  }

  /// Tokens added per second once the bucket has been drained.
  final int ratePerSecond;

  /// Maximum tokens the bucket holds, i.e. the largest allowed burst.
  final int burst;

  final int Function() _clock;

  /// Thousandths of a token, so the refill needs no floating point.
  late int _milliTokens;
  late int _last;

  /// Whole tokens currently available (diagnostics / tests).
  int get available {
    _refill();
    return _milliTokens ~/ 1000;
  }

  /// Spends one token; false when the bucket is empty.
  bool take() {
    _refill();
    if (_milliTokens < 1000) return false;
    _milliTokens -= 1000;
    return true;
  }

  void _refill() {
    final now = _clock();
    final elapsedMs = now - _last;
    // A clock that did not move (or jumped backwards) credits nothing.
    if (elapsedMs <= 0) {
      _last = now;
      return;
    }
    _last = now;
    final cap = burst * 1000;
    // ratePerSecond tokens per 1000 ms == ratePerSecond milli-tokens per ms.
    final gained = elapsedMs * ratePerSecond;
    _milliTokens = (cap - _milliTokens) <= gained ? cap : _milliTokens + gained;
  }
}
