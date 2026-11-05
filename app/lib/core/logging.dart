import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'app_config.dart';

/// Removes secrets (API key) from every log line before it is printed or
/// written to disk.
class Redactor {
  final Set<String> _secrets = {};

  static final RegExp _credentialQueryParam = RegExp(
    r'''((?:[?&]|\b)(?:key|access_token)=)[^&\s"']+''',
    caseSensitive: false,
  );

  void addSecret(String secret) {
    if (secret.length >= 4) _secrets.add(secret);
  }

  String redact(String input) {
    var out = input;
    for (final s in _secrets) {
      out = out.replaceAll(s, '***');
    }
    return out.replaceAllMapped(_credentialQueryParam, (m) => '${m[1]}***');
  }
}

final Redactor redactor = Redactor();

/// %LOCALAPPDATA%\trans_app
String appDataDir() {
  final base =
      Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
  return '$base${Platform.pathSeparator}${AppConfig.dataFolderName}';
}

/// Sends every log record to the debug console and to
/// %LOCALAPPDATA%\trans_app\logs\app-YYYYMMDD.log. Returns the log file path.
Future<String?> setupLogging() async {
  Logger.root.level = Level.ALL;
  IOSink? sink;
  String? path;
  try {
    final dir = Directory(
      '${appDataDir()}${Platform.pathSeparator}logs',
    );
    await dir.create(recursive: true);
    final now = DateTime.now();
    final day =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    path = '${dir.path}${Platform.pathSeparator}app-$day.log';
    sink = File(path).openWrite(mode: FileMode.append);
  } catch (e) {
    debugPrint('Cannot open the log file: $e');
  }
  Logger.root.onRecord.listen((r) {
    final buf = StringBuffer()
      ..write(r.time.toIso8601String())
      ..write(' ')
      ..write(r.level.name.padRight(7))
      ..write(' ')
      ..write(r.loggerName)
      ..write(': ')
      ..write(r.message);
    if (r.error != null) buf.write(' | ${r.error}');
    if (r.stackTrace != null && r.level >= Level.SEVERE) {
      buf.write('\n${r.stackTrace}');
    }
    final line = redactor.redact(buf.toString());
    debugPrint(line);
    sink?.writeln(line);
  });
  return path;
}
