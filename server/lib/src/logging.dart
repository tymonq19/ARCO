/// Minimal leveled logger writing one line per event to stderr.
library;

import 'dart:io';

enum LogLevel { debug, info, warn, error }

/// Parses `LOG_LEVEL` values (case-insensitive); returns null when unknown.
LogLevel? parseLogLevel(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'debug':
      return LogLevel.debug;
    case 'info':
      return LogLevel.info;
    case 'warn':
    case 'warning':
      return LogLevel.warn;
    case 'error':
      return LogLevel.error;
  }
  return null;
}

/// Writes one line per event, prefixed with an ISO-8601 UTC timestamp and the
/// level. Events below [level] are dropped.
///
/// The logger is deliberately tiny: the server has no structured-logging
/// requirement and stderr is what container runtimes collect.
class Logger {
  Logger(this.level, {void Function(String line)? sink})
    : sink = sink ?? _writeStderr;

  static void _writeStderr(String line) => stderr.writeln(line);

  /// Threshold; mutable so a running server can be turned verbose.
  LogLevel level;

  /// Where lines go. Tests pass a collector instead of stderr.
  final void Function(String line) sink;

  bool isEnabled(LogLevel l) => l.index >= level.index;

  void log(LogLevel l, String message, [Object? error, StackTrace? stack]) {
    if (!isEnabled(l)) return;
    final ts = DateTime.now().toUtc().toIso8601String();
    final buf = StringBuffer(
      '$ts ${l.name.toUpperCase().padRight(5)} $message',
    );
    if (error != null) buf.write(' | $error');
    if (stack != null) buf.write('\n$stack');
    sink(buf.toString());
  }

  void debug(String message) => log(LogLevel.debug, message);

  void info(String message) => log(LogLevel.info, message);

  void warn(String message, [Object? error]) =>
      log(LogLevel.warn, message, error);

  void error(String message, [Object? error, StackTrace? stack]) =>
      log(LogLevel.error, message, error, stack);
}
