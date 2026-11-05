import 'dart:async';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:logging/logging.dart';
import 'package:win_audio/win_audio.dart';

import '../core/app_config.dart';
import '../core/latency_stats.dart';
import '../core/pcm.dart';
import '../domain/direction.dart';
import '../domain/translation_engine.dart';

enum TranscriptKind { source, sourceInterim, translated, turnComplete }

class TranscriptUpdate {
  const TranscriptUpdate(this.direction, this.kind, this.text, this.atUs);
  final Direction direction;
  final TranscriptKind kind;
  final String text;
  final int atUs;
}

/// Live numbers of one direction, for the UI and the Phase 2 acceptance test.
class PipelineStats extends Equatable {
  const PipelineStats({
    required this.status,
    this.statusMessage,
    this.inputDb = -100,
    this.outputDb = -100,
    this.bufferedMs = 0,
    this.lastLagMs,
    this.p50LagMs,
    this.p90LagMs,
    this.lagSamples = 0,
    this.framesIn = 0,
    this.inputGain = 1.0,
    this.droppedOutputMs = 0,
    this.skippedSilenceMs = 0,
  });

  final EngineStatus status;
  final String? statusMessage;

  /// Level of the last captured frame, after [inputGain].
  final double inputDb;

  /// Level of the last translated chunk.
  final double outputDb;

  /// Translated audio queued but not heard yet.
  final int bufferedMs;

  /// Speech onset -> the translation starts to be heard (see
  /// [DirectionPipeline] for the exact definition).
  final int? lastLagMs;
  final int? p50LagMs;
  final int? p90LagMs;
  final int lagSamples;
  final int framesIn;
  final double inputGain;

  /// Translated audio lost because the playback buffer was full.
  final int droppedOutputMs;

  /// Digital silence from the AI that was not played (see [DirectionPipeline]).
  final int skippedSilenceMs;

  @override
  List<Object?> get props => [
    status,
    statusMessage,
    inputDb.round(),
    outputDb.round(),
    bufferedMs ~/ 20,
    lastLagMs,
    p50LagMs,
    p90LagMs,
    lagSamples,
    inputGain,
    droppedOutputMs,
    skippedSilenceMs ~/ 1000,
  ];
}

/// Connects one audio source to one [TranslationEngine] and plays the result
/// into one [AudioSink] (ARCHITECTURE.md 3).
///
/// Gemini Live Translate streams its output continuously at real-time pace
/// (250 ms chunks), padding pauses with digital silence, and keeps ~0.5 s
/// ahead (measured 05/11, docs/poc-results.md). Silent chunks are therefore
/// not played: the renderer plays silence by itself when its buffer is empty,
/// and queuing them would keep that half second of extra delay for the whole
/// call.
///
/// Latency (Phase 2 item 6): a speech onset is the first input frame above
/// [AppConfig.voiceThresholdDb] after >= 700 ms of silence. The next voiced
/// translated chunk that starts a new reply (no voiced output in the previous
/// 600 ms) gives `arrival + offset of the voice in the chunk + audio already
/// queued in the sink - onset`: roughly when the listener starts hearing the
/// translation of that sentence.
class DirectionPipeline {
  DirectionPipeline({
    required this.direction,
    required this.engine,
    required this.sink,
    this.frameMs = AudioFormat.frameMs,
    this.inputRate = AudioFormat.captureRate,
    this.outputRate = AudioFormat.renderRate,
    Logger? logger,
  }) : _log = logger ?? Logger('pipeline.${direction.name}'),
       _bypassResampler = LinearResampler(inputRate, outputRate);

  final Direction direction;
  final TranslationEngine engine;
  final AudioSink sink;
  final int frameMs;
  final int inputRate;
  final int outputRate;
  final Logger _log;
  final LinearResampler _bypassResampler;

  final StreamController<TranscriptUpdate> _transcripts =
      StreamController.broadcast();
  final LatencyStats _lag = LatencyStats();
  StreamSubscription<EngineEvent>? _engineSub;
  StreamSubscription<AudioFrame>? _sourceSub;

  /// Called when the audio source fails (e.g. device unplugged).
  void Function(Object error)? onSourceError;

  double _inputGain = 1.0;
  bool _bypass = false;
  String? _statusMessage;
  double _inputDb = -100;
  double _outputDb = -100;
  int _framesIn = 0;
  int _droppedOutputBytes = 0;

  bool _inVoice = false;
  int _silentFrames = 0;
  int? _onsetUs;
  int _lastVoicedOutputAtUs = -1 << 62;
  int _droppedSilenceBytes = 0;

  Stream<TranscriptUpdate> get transcripts => _transcripts.stream;

  double get inputGain => _inputGain;

  /// Multiplies the captured audio before it is sent (R12 compensation).
  set inputGain(double value) =>
      _inputGain = value.clamp(0.0, AppConfig.maxInputGain);

  bool get bypass => _bypass;

  /// Emergency: play the captured voice straight into the sink (untranslated)
  /// and drop the translation. Audio is still sent to the engine so that
  /// switching back is instant.
  set bypass(bool on) {
    if (on == _bypass) return;
    _bypass = on;
    sink.clear();
    _bypassResampler.reset();
    _log.info('bypass ${on ? 'ON' : 'off'}');
  }

  PipelineStats get stats => PipelineStats(
    status: engine.status,
    statusMessage: _statusMessage,
    inputDb: _inputDb,
    outputDb: _outputDb,
    bufferedMs: sink.bufferedMs,
    lastLagMs: _lag.last,
    p50LagMs: _lag.percentile(50),
    p90LagMs: _lag.percentile(90),
    lagSamples: _lag.count,
    framesIn: _framesIn,
    inputGain: _inputGain,
    droppedOutputMs: _droppedOutputBytes * 1000 ~/ (outputRate * 2),
    skippedSilenceMs: _droppedSilenceBytes * 1000 ~/ (outputRate * 2),
  );

  /// Subscribes to [source] right away (for the level meters) and starts the
  /// engine. Throws [EngineException] if the engine cannot start.
  Future<void> start(Stream<AudioFrame> source) async {
    _engineSub = engine.events.listen(_onEngineEvent);
    _sourceSub = source.listen(
      _onFrame,
      onError: (Object e) {
        _log.severe('audio source failed', e);
        onSourceError?.call(e);
      },
    );
    _log.info('starting ${engine.name}');
    await engine.start(
      sourceLanguage: direction.sourceLanguage,
      targetLanguage: direction.targetLanguage,
    );
  }

  Future<void> stop() async {
    await _sourceSub?.cancel();
    _sourceSub = null;
    await engine.stop();
    await _engineSub?.cancel();
    _engineSub = null;
    sink.clear();
    await _transcripts.close();
  }

  void _onFrame(AudioFrame frame) {
    final pcm = applyGain(frame.pcm, _inputGain);
    _inputDb = rmsDbfs(pcm);
    _framesIn++;
    _trackVoice(_inputDb, frame.capturedAtUs);
    if (_bypass) _write(_bypassResampler.process(pcm));
    engine.sendAudio(pcm);
  }

  void _trackVoice(double db, int atUs) {
    if (db > AppConfig.voiceThresholdDb) {
      if (!_inVoice) {
        _inVoice = true;
        _onsetUs = atUs - frameMs * 1000; // the frame started 100 ms earlier
      }
      _silentFrames = 0;
    } else if (_inVoice && ++_silentFrames >= AppConfig.silenceHangoverFrames) {
      _inVoice = false;
    }
  }

  void _onEngineEvent(EngineEvent e) {
    switch (e) {
      case TranslatedAudio():
        _onTranslatedAudio(e);
      case SourceTranscript(:final text, :final interim):
        _emit(
          interim ? TranscriptKind.sourceInterim : TranscriptKind.source,
          text,
          e.atUs,
        );
      case TranslatedTranscript(:final text):
        _emit(TranscriptKind.translated, text, e.atUs);
      case TurnComplete():
        _emit(TranscriptKind.turnComplete, '', e.atUs);
      case EngineStatusChanged(:final status, :final message):
        _statusMessage = message;
        if (status == EngineStatus.failed) {
          _log.severe('engine failed: $message');
        } else {
          _log.info('engine ${status.name}${message == null ? '' : ': $message'}');
        }
    }
  }

  void _onTranslatedAudio(TranslatedAudio e) {
    _outputDb = rmsDbfs(e.pcm);
    if (e.sampleRate != outputRate) {
      _log.warning('dropping audio at ${e.sampleRate} Hz (expected $outputRate)');
      return;
    }
    final voicedAtMs = firstVoicedOffsetMs(
      e.pcm,
      e.sampleRate,
      AppConfig.voiceThresholdDb,
    );
    if (voicedAtMs != null) {
      _measureLag(e.atUs, voicedAtMs);
      _lastVoicedOutputAtUs = e.atUs;
    }
    if (_bypass) return;
    if (_outputDb <= AppConfig.silentChunkDb) {
      _droppedSilenceBytes += e.pcm.length;
      return;
    }
    _write(e.pcm);
  }

  void _measureLag(int arrivalUs, int voicedAtMs) {
    final onset = _onsetUs;
    if (onset == null) return;
    if (arrivalUs - onset > _maxPlausibleLagUs) {
      _onsetUs = null; // its translation never came (noise, or English only)
      return;
    }
    if (arrivalUs - _lastVoicedOutputAtUs <= 600000) return; // same reply
    final lagMs =
        (arrivalUs - onset) ~/ 1000 + voicedAtMs + (_bypass ? 0 : sink.bufferedMs);
    _lag.add(lagMs);
    _onsetUs = null;
    _log.fine('lag ${lagMs}ms');
  }

  static const _maxPlausibleLagUs = 15 * 1000000;

  void _write(Uint8List pcm) {
    final accepted = sink.write(pcm);
    if (accepted < pcm.length) {
      _droppedOutputBytes += pcm.length - accepted;
      _log.warning('playback buffer full, dropped ${pcm.length - accepted} bytes');
    }
  }

  void _emit(TranscriptKind kind, String text, int atUs) {
    if (!_transcripts.isClosed) {
      _transcripts.add(TranscriptUpdate(direction, kind, text, atUs));
    }
  }
}
