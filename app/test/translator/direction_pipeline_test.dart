import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trans_app/domain/direction.dart';
import 'package:trans_app/domain/translation_engine.dart';
import 'package:trans_app/translator/direction_pipeline.dart';
import 'package:win_audio/win_audio.dart';

import '../fakes.dart';

void main() {
  late FakeEngine engine;
  late FakeSink sink;
  late StreamController<AudioFrame> source;
  late DirectionPipeline p;

  const loud = 8000; // about -12 dBFS: "speech"
  const ms = 1000; // us

  Future<void> frame(int value, int atMs) async {
    source.add(AudioFrame(frameOf(value), atMs * ms));
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() async {
    engine = FakeEngine();
    sink = FakeSink();
    source = StreamController(sync: true);
    p = DirectionPipeline(direction: Direction.incoming, engine: engine, sink: sink);
    await p.start(source.stream);
  });

  test('starts the engine with the direction languages', () {
    expect(engine.target, 'vi');
    expect(p.stats.status, EngineStatus.ready);
  });

  test('forwards frames to the engine, applying the input gain', () async {
    await frame(1000, 100);
    p.inputGain = 2.0;
    await frame(1000, 200);
    expect(engine.sent, hasLength(2));
    expect(Int16List.view(Uint8List.fromList(engine.sent[0]).buffer).first, 1000);
    expect(Int16List.view(Uint8List.fromList(engine.sent[1]).buffer).first, 2000);
    expect(p.stats.framesIn, 2);
    expect(p.stats.inputDb, closeTo(-24.3, 0.1));
  });

  test('input gain is capped (R12: Discord volume >= 0.2)', () {
    p.inputGain = 20;
    expect(p.inputGain, 5.0);
  });

  /// 250 ms of 24 kHz output, like one Gemini chunk.
  Uint8List voiced() => frameOf(8000, samples: 6000);
  Uint8List silent() => Uint8List(12000);

  test('plays voiced translated audio and measures onset -> heard latency', () async {
    await frame(0, 100);
    await frame(loud, 200); // onset = 200 - 100 = 100 ms
    await frame(loud, 300);
    sink.buffered = 150;
    engine.emit(TranslatedAudio(1600 * ms, voiced(), 24000));
    expect(sink.written.single.length, 12000);
    // 1600 - 100 + 150 queued
    expect(p.stats.lastLagMs, 1650);

    // More audio of the same reply: no new sample.
    engine.emit(TranslatedAudio(1850 * ms, voiced(), 24000));
    expect(p.stats.lagSamples, 1);

    // Silence long enough to end the segment, then a new sentence.
    for (var t = 400; t <= 1200; t += 100) {
      await frame(0, t);
    }
    await frame(loud, 3000); // onset 2900
    sink.buffered = 0;
    engine.emit(TranslatedAudio(4900 * ms, voiced(), 24000));
    expect(p.stats.lastLagMs, 2000);
    expect(p.stats.lagSamples, 2);
    expect(p.stats.p90LagMs, 2000);
  });

  test('skips the digital silence of the continuous output stream', () async {
    engine
      ..emit(TranslatedAudio(0, silent(), 24000))
      ..emit(TranslatedAudio(250 * ms, voiced(), 24000))
      ..emit(TranslatedAudio(500 * ms, silent(), 24000));
    expect(sink.written, hasLength(1));
    expect(p.stats.skippedSilenceMs, 500);
  });

  test('lag counts where the voice starts inside a chunk', () async {
    await frame(loud, 100); // onset 0
    final chunk = Uint8List(12000)..setAll(4800, frameOf(8000, samples: 3600));
    engine.emit(TranslatedAudio(2000 * ms, chunk, 24000)); // voice at 100 ms
    expect(p.stats.lastLagMs, 2100);
  });

  test('reproduces the latencies measured with gemini_probe on 05/11', () async {
    // Input speech (ms) and arrival of the voiced translation, from
    // poc/gemini_probe out/dialog_vi.json: lags 3078, 2359, 2808 ms.
    const speech = [(150, 2400), (4800, 5950), (8350, 11650)];
    const voicedOut = [(3228, 5978), (7159, 8659), (11158, 14000)];
    final events = <(int, void Function())>[];
    for (var t = 100; t <= 14000; t += 100) {
      final on = speech.any((r) => t - 100 >= r.$1 - 99 && t - 100 < r.$2);
      events.add((t, () => source.add(AudioFrame(frameOf(on ? loud : 0), t * ms))));
    }
    // Voiced chunks start exactly at the measured arrival times; silence on a
    // 250 ms grid in between.
    for (final (a, b) in voicedOut) {
      for (var t = a; t < b; t += 250) {
        events.add((t, () => engine.emit(TranslatedAudio(t * ms, voiced(), 24000))));
      }
    }
    for (var t = 3228; t <= 14000; t += 250) {
      if (voicedOut.any((r) => t >= r.$1 - 250 && t < r.$2)) continue;
      events.add((t, () => engine.emit(TranslatedAudio(t * ms, silent(), 24000))));
    }
    events.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, fire) in events) {
      fire();
    }
    await Future<void>.delayed(Duration.zero);
    expect(p.stats.lagSamples, 3);
    // Frame granularity is 100 ms: onsets snap to the frame start.
    expect(p.stats.p50LagMs, closeTo(2808, 100));
    expect(p.stats.p90LagMs, closeTo(3078, 100));
  });

  test('audio at an unexpected rate is not played', () async {
    engine.emit(TranslatedAudio(0, voiced(), 16000));
    expect(sink.written, isEmpty);
  });

  test('counts translated audio dropped by a full playback buffer', () async {
    final small = FakeSink(capacityBytes: 4800);
    final e2 = FakeEngine();
    final p2 = DirectionPipeline(direction: Direction.outgoing, engine: e2, sink: small);
    await p2.start(const Stream.empty());
    e2.emit(TranslatedAudio(0, frameOf(8000, samples: 4800), 24000));
    expect(p2.stats.droppedOutputMs, 100); // 4800 bytes at 24 kHz
  });

  test('bypass plays the raw voice resampled to 24 kHz and drops the translation', () async {
    p.bypass = true;
    expect(sink.clears, 1);
    await frame(loud, 100);
    expect(sink.written.single.length, closeTo(4800, 4)); // 1600 -> 2400 samples
    expect(engine.sent, hasLength(1)); // still sent to the AI
    engine.emit(TranslatedAudio(0, Uint8List(4800), 24000));
    expect(sink.written, hasLength(1));
    p.bypass = false;
    expect(sink.clears, 2);
  });

  test('maps transcripts', () async {
    final updates = <TranscriptUpdate>[];
    p.transcripts.listen(updates.add);
    engine
      ..emit(const SourceTranscript(1, 'Hel', interim: true))
      ..emit(const SourceTranscript(2, 'Hello'))
      ..emit(const TranslatedTranscript(3, 'Xin chào'))
      ..emit(const TurnComplete(4));
    await Future<void>.delayed(Duration.zero);
    expect(updates.map((u) => (u.kind, u.text)), [
      (TranscriptKind.sourceInterim, 'Hel'),
      (TranscriptKind.source, 'Hello'),
      (TranscriptKind.translated, 'Xin chào'),
      (TranscriptKind.turnComplete, ''),
    ]);
    expect(updates.every((u) => u.direction == Direction.incoming), isTrue);
  });

  test('reports source errors and stops cleanly', () async {
    Object? error;
    p.onSourceError = (e) => error = e;
    source.addError(const WinAudioException('unplugged'));
    await Future<void>.delayed(Duration.zero);
    expect(error, isA<WinAudioException>());
    await p.stop();
    expect(engine.stopped, isTrue);
    expect(sink.clears, 1);
  });
}
