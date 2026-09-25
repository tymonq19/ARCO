/// Arco server: duel rooms over WebSocket and the verified leaderboard.
///
/// See SPEC.md §3 (WebSocket protocol), §4 (REST API, storage), §4.4
/// (anonymous player identity), §4.5 (Sign in with Apple / Google), §4.6
/// (national leaderboard), §4.7 (nickname filtering), §4.8 (cosmetic items),
/// §4.9 (the one-time unlock) and §4.10 (rewarded ads that pay Sparks).
library;

export 'src/accounts.dart';
export 'src/ads.dart';
export 'src/api.dart';
export 'src/catalogue.dart';
export 'src/config.dart';
export 'src/country.dart';
export 'src/db.dart';
export 'src/http_util.dart';
export 'src/id_token.dart';
export 'src/leaderboard.dart';
export 'src/logging.dart';
export 'src/name_blocklist.dart';
export 'src/name_filter.dart';
export 'src/players.dart';
export 'src/purchases.dart';
export 'src/rate_limit.dart';
export 'src/room.dart';
export 'src/rooms.dart';
export 'src/score_store.dart';
export 'src/server.dart';
export 'src/session.dart';
export 'src/shop.dart';
export 'src/tokens.dart';
export 'src/version.dart';
export 'src/ws_frame_guard.dart';
