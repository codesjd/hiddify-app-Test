// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:loggy/loggy.dart';

class ConsolePrinter extends LoggyPrinter {
  const ConsolePrinter({this.showColors = false});

  final bool showColors;

  static final _levelColors = {
    LogLevel.debug: AnsiColor(foregroundColor: AnsiColor.grey(0.5), italic: true),
    LogLevel.info: AnsiColor(foregroundColor: 35),
    LogLevel.warning: AnsiColor(foregroundColor: 214),
    LogLevel.error: AnsiColor(foregroundColor: 196),
  };

  @override
  void onLog(LogRecord record) {
    final colorize = showColors && stdout.supportsAnsiEscapes;
    final time = record.time.toIso8601String().split('T')[1];
    final callerFrame = record.callerFrame == null ? ' ' : ' (${record.callerFrame?.location}) ';

    final String logLevel;
    if (colorize) {
      logLevel = record.level.name.toUpperCase().padRight(8);
    } else {
      logLevel = "[${record.level.name.toUpperCase()}]".padRight(10);
    }

    final color = showColors ? levelColor(record.level) ?? AnsiColor() : AnsiColor();

    print(color('$time $logLevel [${record.loggerName}]$callerFrame${record.message}'));

    if (record.stackTrace != null) {
      print(record.stackTrace);
    }
  }

  AnsiColor? levelColor(LogLevel level) {
    return _levelColors[level];
  }
}

class FileLogPrinter extends LoggyPrinter {
  FileLogPrinter(String filePath, {this.minLevel = LogLevel.debug}) : _logFile = File(filePath);

  // Caps how large app.log is allowed to grow within a single run - previously this sink just
  // appended for the whole process lifetime with no size check at all, which combined with
  // debug-level logging over a real session was reported growing unbounded (into the same
  // double-digit-GB range as the Go core's own box.log; see hiddify-sing-box's
  // log/rotating_writer.go for the matching fix there). Rotation here just truncates the already-
  // open handle back to position 0 rather than close/rename/reopen - simpler, and avoids
  // rename-while-open semantics that are unreliable on Windows.
  static const _maxFileSizeBytes = 20 * 1024 * 1024;

  final File _logFile;
  final LogLevel minLevel;

  late final RandomAccessFile _raf = _logFile.openSync(mode: FileMode.write);

  @override
  void onLog(LogRecord record) {
    final time = record.time.toIso8601String().split('T')[1];
    _write("$time - $record\n");
    if (record.error != null) {
      _write("${record.error}\n");
    }
    if (record.stackTrace != null) {
      _write("${record.stackTrace}\n");
    }
  }

  void _write(String content) {
    final bytes = utf8.encode(content);
    if (_raf.positionSync() + bytes.length > _maxFileSizeBytes) {
      _raf.truncateSync(0);
      _raf.setPositionSync(0);
    }
    _raf.writeFromSync(bytes);
  }

  void dispose() {
    _raf.closeSync();
  }
}
