/// Entry point. Environment: PORT (8080), DB_PATH (data/arco.db),
/// VERIFY_REPLAYS (strict|off), LOG_LEVEL (debug|info|warn|error), HOST, and
/// for Sign in with Apple / Google (SPEC §4.5) ACCOUNTS_ENABLED (on|off, default
/// off), APPLE_CLIENT_IDS, GOOGLE_CLIENT_IDS.
library;

import 'dart:async';
import 'dart:io';

import 'package:arco_server/arco_server.dart';

Future<void> main(List<String> args) async {
  final ServerConfig config;
  try {
    config = ServerConfig.fromEnvironment(Platform.environment);
  } on FormatException catch (e) {
    stderr.writeln('configuration error: ${e.message}');
    exit(64);
  }

  final log = Logger(config.logLevel);
  final server = ArcoServer(config: config, log: log);
  try {
    await server.start();
  } catch (e, st) {
    log.error('failed to start', e, st);
    exit(1);
  }
  log.info(
    'arco_server $serverVersion listening on http://${server.address.address}:${server.port} '
    '(ws: /ws, api: /api/*) verify=${config.verifyReplays ? 'strict' : 'off'}',
  );

  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    log.info('received $signal, shutting down');
    try {
      await server.stop().timeout(const Duration(seconds: 5));
    } catch (e) {
      log.warn('shutdown did not complete cleanly: $e');
    }
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
