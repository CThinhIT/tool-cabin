import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gemini_probe/src/commands.dart';
import 'package:gemini_probe/src/secrets.dart';

Future<void> main(List<String> arguments) async {
  final runner =
      CommandRunner<int>(
          'gemini_probe',
          'Phase 1 smoke test for Gemini Live Translate (vi <-> en) over a raw '
              'WebSocket.\nAPI key: environment variable $apiKeyEnvVar only.',
        )
        ..addCommand(TranslateCommand())
        ..addCommand(ConcurrencyCommand())
        ..addCommand(PrepareCommand());

  try {
    exitCode = await runner.run(arguments) ?? exitOk;
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = exitUsage;
  } on MissingApiKeyException catch (e) {
    stderr.writeln(e);
    exitCode = exitNoApiKey;
  } on InputException catch (e) {
    stderr.writeln(e);
    exitCode = exitInputError;
  } catch (e, st) {
    stderr.writeln(
      Redactor.global.redact('ERROR: unexpected failure: $e\n$st'),
    );
    exitCode = 1;
  }
}
