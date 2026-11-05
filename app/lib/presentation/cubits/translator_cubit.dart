import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:win_audio/win_audio.dart';

import '../../data/audio/audio_service.dart';
import '../../data/engines/gemini/gemini_live_translate_engine.dart';
import '../../data/settings/app_settings.dart';
import '../../data/settings/settings_repository.dart';
import '../../domain/translation_engine.dart';
import '../../translator/routing.dart';
import '../../translator/translator_controller.dart';

enum TranslatorPhase { idle, starting, running, stopping }

class TranslatorState extends Equatable {
  const TranslatorState({
    this.phase = TranslatorPhase.idle,
    this.snapshot,
    this.error,
  });

  final TranslatorPhase phase;
  final TranslatorSnapshot? snapshot;

  /// Why the last start failed or why the run stopped by itself.
  final String? error;

  bool get isRunning => phase == TranslatorPhase.running;
  bool get isBusy =>
      phase == TranslatorPhase.starting || phase == TranslatorPhase.stopping;

  @override
  List<Object?> get props => [phase, snapshot, error];
}

class TranslatorCubit extends Cubit<TranslatorState> {
  TranslatorCubit({
    required TranslatorController controller,
    required SettingsRepository settings,
    required AudioService audio,
  }) : _controller = controller,
       _settings = settings,
       _audio = audio,
       super(const TranslatorState()) {
    _failureSub = _controller.failures.listen(_onFailure);
  }

  final TranslatorController _controller;
  final SettingsRepository _settings;
  final AudioService _audio;
  final Logger _log = Logger('translator.ui');
  StreamSubscription<String>? _failureSub;
  Timer? _ticker;

  Future<void> start(AppSettings s) async {
    if (state.phase != TranslatorPhase.idle) return;
    emit(const TranslatorState(phase: TranslatorPhase.starting));
    try {
      final routing = resolveRouting(
        s,
        captureDevices: _audio.captureDevices(),
        renderDevices: _audio.renderDevices(),
      );
      final key = await _settings.readApiKey();
      if (key == null) {
        throw const RoutingException(
          'Chưa có Gemini API key. Vào Cài đặt để nhập key.',
        );
      }
      final config = GeminiConfig(
        apiKey: key,
        model: s.geminiModel,
        placement: s.transcriptionPlacement,
      );
      await _controller.start(
        routing,
        () => GeminiLiveTranslateEngine(config, clockUs: _audio.nowUs),
      );
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        final snap = _controller.snapshot();
        if (snap != null && !isClosed) {
          emit(TranslatorState(phase: TranslatorPhase.running, snapshot: snap));
        }
      });
      emit(
        TranslatorState(
          phase: TranslatorPhase.running,
          snapshot: _controller.snapshot(),
        ),
      );
    } catch (e) {
      _log.warning('start failed: $e');
      emit(TranslatorState(error: _message(e)));
    }
  }

  Future<void> stop() async {
    if (state.phase != TranslatorPhase.running) return;
    _ticker?.cancel();
    emit(
      TranslatorState(phase: TranslatorPhase.stopping, snapshot: state.snapshot),
    );
    await _controller.stop();
    emit(TranslatorState(snapshot: state.snapshot));
  }

  void setBypass(bool on) => _controller.setBypass(on);

  void setVolumes({double? vietnamese, double? english}) =>
      _controller.setVolumes(vietnamese: vietnamese, english: english);

  void _onFailure(String message) {
    _ticker?.cancel();
    if (!isClosed) {
      emit(TranslatorState(snapshot: state.snapshot, error: message));
    }
  }

  static String _message(Object e) => switch (e) {
    RoutingException(:final message) => message,
    EngineException(:final message) => message,
    WinAudioException(:final message) => 'Lỗi âm thanh: $message',
    _ => '$e',
  };

  @override
  Future<void> close() async {
    _ticker?.cancel();
    await _failureSub?.cancel();
    await _controller.stop();
    return super.close();
  }
}
