import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:win_audio/win_audio.dart';

import '../data/audio/audio_service.dart';
import '../data/settings/settings_repository.dart';
import '../translator/translator_controller.dart';
import 'cubits/devices_cubit.dart';
import 'cubits/settings_cubit.dart';
import 'cubits/subtitles_cubit.dart';
import 'cubits/translator_cubit.dart';
import 'pages/home_page.dart';

/// Read-only facts for the UI.
class AppInfo {
  const AppInfo({this.logPath});
  final String? logPath;
}

ThemeData _theme(Brightness b) => ThemeData(
  colorSchemeSeed: const Color(0xFF00796B),
  brightness: b,
  useMaterial3: true,
  visualDensity: VisualDensity.compact,
);

class TransApp extends StatefulWidget {
  const TransApp({
    super.key,
    required this.winAudio,
    required this.settings,
    required this.info,
  });

  final WinAudio winAudio;
  final SettingsRepository settings;
  final AppInfo info;

  @override
  State<TransApp> createState() => _TransAppState();
}

class _TransAppState extends State<TransApp> {
  final Logger _log = Logger('app');
  late final AudioService _audio = AudioService(widget.winAudio);
  late final TranslatorController _controller = TranslatorController(_audio);
  late final SettingsCubit _settingsCubit = SettingsCubit(widget.settings)
    ..loadKeySource();
  late final DevicesCubit _devicesCubit = DevicesCubit(_audio)..refresh();
  late final TranslatorCubit _translatorCubit = TranslatorCubit(
    controller: _controller,
    settings: widget.settings,
    audio: _audio,
  );
  late final SubtitlesCubit _subtitlesCubit = SubtitlesCubit(
    _controller.transcripts,
  );
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  /// Close the AI sessions and audio streams before the window closes.
  Future<AppExitResponse> _onExitRequested() async {
    try {
      await _translatorCubit.stop().timeout(const Duration(seconds: 3));
    } catch (e) {
      _log.warning('stop on exit: $e');
    }
    widget.winAudio.dispose();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_subtitlesCubit.close());
    unawaited(_translatorCubit.close());
    unawaited(_devicesCubit.close());
    unawaited(_settingsCubit.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepositoryProvider.value(
      value: widget.info,
      child: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: _settingsCubit),
          BlocProvider.value(value: _devicesCubit),
          BlocProvider.value(value: _translatorCubit),
          BlocProvider.value(value: _subtitlesCubit),
        ],
        child: MaterialApp(
          title: 'Phiên dịch Việt ↔ Anh',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: const HomePage(),
        ),
      ),
    );
  }
}

/// Shown when win_audio.dll cannot be loaded: nothing else can work.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                const Text('Không khởi tạo được phần âm thanh (win_audio).'),
                const SizedBox(height: 8),
                SelectableText(message),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
