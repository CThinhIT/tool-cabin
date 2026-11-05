import 'dart:io';

/// The only place the API key may come from.
const apiKeyEnvVar = 'GEMINI_API_KEY';

class MissingApiKeyException implements Exception {
  @override
  String toString() => '''
ERROR: environment variable $apiKeyEnvVar is not set (or is empty).

Set it for the current PowerShell session only, then re-run:
  \$env:$apiKeyEnvVar = "<your Google AI Studio API key>"

The key is read from the environment only. It is never printed or written
to any output file.''';
}

/// Reads the API key from [apiKeyEnvVar] and registers it with the global
/// [Redactor] so it can never be printed by accident.
String readApiKeyFromEnv({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final key = (env[apiKeyEnvVar] ?? '').trim();
  if (key.isEmpty) throw MissingApiKeyException();
  Redactor.global.addSecret(key);
  return key;
}

/// Removes secrets (API key, ephemeral tokens) from any text before it is
/// printed or written to disk.
class Redactor {
  static final Redactor global = Redactor();

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

/// Console logger. Every line goes through [Redactor.global].
class Log {
  Log({this.verbose = false, this.prefix = ''});

  final bool verbose;
  final String prefix;

  Log child(String childPrefix) => Log(verbose: verbose, prefix: childPrefix);

  void info(String message) =>
      stdout.writeln(Redactor.global.redact('$prefix$message'));

  void debug(String message) {
    if (verbose) info(message);
  }

  void warn(String message) =>
      stderr.writeln(Redactor.global.redact('${prefix}WARNING: $message'));

  void error(String message) =>
      stderr.writeln(Redactor.global.redact('${prefix}ERROR: $message'));
}
