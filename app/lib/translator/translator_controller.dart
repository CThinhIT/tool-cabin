import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:logging/logging.dart';
import 'package:win_audio/win_audio.dart';

import '../core/app_config.dart';
import '../data/audio/audio_service.dart';
import '../data/settings/app_settings.dart';
import '../domain/direction.dart';
import '../domain/translation_engine.dart';
import 'direction_pipeline.dart';
import 'routing.dart';

class TranslatorSnapshot extends Equatable {
  const TranslatorSnapshot({
    required this.outgoing,
    required this.incoming,
    this.bypass = false,
    this.micDiscontinuities = 0,
    this.callDiscontinuities = 0,
    this.callAppVolume,
  });

  final PipelineStats outgoing;
  final PipelineStats incoming;
  final bool bypass;
  final int micDiscontinuities;
  final int callDiscontinuities;

  /// Session volume of the call app (R12), when capturing it by process
  /// loopback.
  final double? callAppVolume;

  PipelineStats of(Direction d) =>
      d == Direction.outgoing ? outgoing : incoming;

  @override
  List<Object?> get props => [
    outgoing,
    incoming,
    bypass,
    micDiscontinuities,
    callDiscontinuities,
    callAppVolume,
  ];
}

/// Owns the audio streams and the two pipelines of one translation run
/// (ARCHITECTURE.md 3):
///   A (outgoing): mic -> AI (en) -> CABLE Input
///   B (incoming): call app (process loopback) -> AI (vi) -> headphones
class TranslatorController {
  TranslatorController(
    this._audio, {
    Duration volumePollInterval = const Duration(seconds: 1),
    Logger? logger,
  }) : _volumePollInterval = volumePollInterval,
       _log = logger ?? Logger('translator');

  final AudioService _audio;
  final Duration _volumePollInterval;
  final Logger _log;

  final StreamController<TranscriptUpdate> _transcripts =
      StreamController.broadcast();
  final StreamController<String> _failures = StreamController.broadcast();

  _Run? _run;

  bool get isRunning => _run != null;

  /// Subtitle fragments of both directions.
  Stream<TranscriptUpdate> get transcripts => _transcripts.stream;

  /// A device disappeared or a stream failed while running. The controller
  /// has already stopped when this fires.
  Stream<String> get failures => _failures.stream;

  TranslatorSnapshot? snapshot() {
    final r = _run;
    if (r == null) return null;
    return TranslatorSnapshot(
      outgoing: r.outgoing.stats,
      incoming: r.incoming.stats,
      bypass: r.outgoing.bypass,
      micDiscontinuities: r.mic.discontinuities,
      callDiscontinuities: r.call.discontinuities,
      callAppVolume: r.callAppVolume,
    );
  }

  /// Opens all streams and both AI sessions. Everything opened is closed
  /// again if any step fails. Throws [RoutingException], [WinAudioException]
  /// or [EngineException].
  Future<void> start(RoutingConfig cfg, TranslationEngineFactory engines) async {
    if (_run != null) throw StateError('Already running');
    final cleanup = <FutureOr<void> Function()>[];
    try {
      final cable = _audio.openOutput(cfg.cableDeviceId)
        ..gain = cfg.englishVolume;
      cleanup.add(cable.stop);
      final headset = _audio.openOutput(cfg.headsetDeviceId)
        ..gain = cfg.vietnameseVolume;
      cleanup.add(headset.stop);

      final mic = _audio.captureMic(cfg.micDeviceId);
      cleanup.add(mic.stop);

      int? callRootPid;
      final CaptureStream call;
      if (cfg.callCaptureMode == CallCaptureMode.processLoopback) {
        callRootPid = _audio.findRootPid(cfg.callAppExe);
        if (callRootPid == null) {
          throw RoutingException(
            'Không thấy ${cfg.callAppExe} đang chạy. Mở app gọi trước rồi bấm Bắt đầu.',
          );
        }
        call = _audio.captureApp(callRootPid);
      } else {
        call = _audio.captureDevice(cfg.callCaptureDeviceId!);
      }
      cleanup.add(call.stop);

      final outgoing = DirectionPipeline(
        direction: Direction.outgoing,
        engine: engines(),
        sink: cable,
      );
      cleanup.add(outgoing.stop);
      final incoming = DirectionPipeline(
        direction: Direction.incoming,
        engine: engines(),
        sink: headset,
      );
      cleanup.add(incoming.stop);

      final run = _Run(
        cable: cable,
        headset: headset,
        mic: mic,
        call: call,
        outgoing: outgoing,
        incoming: incoming,
        callRootPid: callRootPid,
      );
      for (final p in [outgoing, incoming]) {
        run.subs.add(p.transcripts.listen(_transcripts.add));
        p.onSourceError = (e) => _fail('Mất âm thanh đầu vào (${p.direction.shortLabel}): ${_describe(e)}');
      }
      for (final (name, out) in [('CABLE Input', cable), ('tai nghe', headset)]) {
        run.subs.add(out.errors.listen((e) => _fail('Mất thiết bị phát $name: ${e.message}')));
      }

      // Both sessions in parallel; wait for both so nothing is left half open.
      final results = await Future.wait([
        outgoing.start(mic.frames).then<Object?>((_) => null, onError: (Object e) => e),
        incoming.start(call.frames).then<Object?>((_) => null, onError: (Object e) => e),
      ]);
      final error = results.whereType<Object>().firstOrNull;
      if (error != null) throw error;

      if (callRootPid != null) {
        run.volumeTimer = Timer.periodic(
          _volumePollInterval,
          (_) => _compensateCallVolume(run),
        );
        _compensateCallVolume(run);
      }
      _run = run;
      _log.info(
        'started: call=${cfg.callCaptureMode.name} '
        '${cfg.callCaptureMode == CallCaptureMode.processLoopback ? '${cfg.callAppExe} pid $callRootPid' : cfg.callCaptureDeviceId}',
      );
    } catch (e) {
      _log.warning('start failed: $e');
      for (final c in cleanup.reversed) {
        try {
          await c();
        } catch (ce) {
          _log.fine('cleanup: $ce');
        }
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    final r = _run;
    if (r == null) return;
    _run = null;
    r.volumeTimer?.cancel();
    for (final s in r.subs) {
      await s.cancel();
    }
    await Future.wait([r.outgoing.stop(), r.incoming.stop()]);
    r.mic.stop();
    r.call.stop();
    r.cable.stop();
    r.headset.stop();
    _log.info('stopped');
  }

  /// Emergency switch for the outgoing direction: your real voice goes into
  /// CABLE untranslated.
  void setBypass(bool on) => _run?.outgoing.bypass = on;

  void setVolumes({double? vietnamese, double? english}) {
    final r = _run;
    if (r == null) return;
    if (vietnamese != null) r.headset.gain = vietnamese;
    if (english != null) r.cable.gain = english;
  }

  /// R12: process loopback is captured after the call app's session volume.
  /// If you turn Discord down in the mixer, the AI would get a weak signal;
  /// multiply by 1/volume (capped at [AppConfig.maxInputGain]).
  void _compensateCallVolume(_Run r) {
    final pid = r.callRootPid;
    if (pid == null) return;
    try {
      final v = _audio.appVolume(pid);
      r.callAppVolume = v;
      final gain =
          (v == null || v <= 0)
              ? 1.0
              : (1 / v).clamp(1.0, AppConfig.maxInputGain).toDouble();
      if ((gain - r.incoming.inputGain).abs() > 0.01) {
        _log.info('call app volume ${v?.toStringAsFixed(2)} -> input gain ${gain.toStringAsFixed(2)}');
        r.incoming.inputGain = gain;
      }
    } catch (e) {
      _log.fine('volume poll: $e');
    }
  }

  void _fail(String message) {
    if (_run == null) return;
    _log.severe(message);
    unawaited(stop().whenComplete(() => _failures.add(message)));
  }

  static String _describe(Object e) =>
      e is WinAudioException ? e.message : '$e';
}

class _Run {
  _Run({
    required this.cable,
    required this.headset,
    required this.mic,
    required this.call,
    required this.outgoing,
    required this.incoming,
    required this.callRootPid,
  });

  final RenderStream cable;
  final RenderStream headset;
  final CaptureStream mic;
  final CaptureStream call;
  final DirectionPipeline outgoing;
  final DirectionPipeline incoming;
  final int? callRootPid;
  final List<StreamSubscription<Object?>> subs = [];
  Timer? volumeTimer;
  double? callAppVolume;
}
