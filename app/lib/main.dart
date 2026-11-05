import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:win_audio/win_audio.dart';

import 'core/logging.dart';
import 'data/settings/settings_repository.dart';
import 'presentation/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final logPath = await setupLogging();
  final log = Logger('main');
  log.info('starting, log file: $logPath');

  final settings = await SettingsRepository.create();

  final WinAudio winAudio;
  try {
    winAudio = WinAudio.open();
  } catch (e, st) {
    log.severe('cannot load win_audio', e, st);
    runApp(StartupErrorApp(message: '$e'));
    return;
  }

  // A previous run may have lowered the call app's volume and crashed.
  try {
    final restored = winAudio.restoreSessionVolumes();
    if (restored > 0) log.info('restored the volume of $restored session(s)');
  } catch (e) {
    log.warning('volume restore: $e');
  }

  runApp(
    TransApp(
      winAudio: winAudio,
      settings: settings,
      info: AppInfo(logPath: logPath),
    ),
  );
}
