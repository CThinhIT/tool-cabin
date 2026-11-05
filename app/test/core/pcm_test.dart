import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trans_app/core/latency_stats.dart';
import 'package:trans_app/core/pcm.dart';

Uint8List pcmOf(List<int> samples) =>
    Int16List.fromList(samples).buffer.asUint8List();

Int16List samplesOf(Uint8List pcm) =>
    Int16List.view(Uint8List.fromList(pcm).buffer);

Uint8List sine(double hz, int rate, int count, {double amp = 0.5}) => pcmOf([
  for (var i = 0; i < count; i++)
    (amp * 32767 * math.sin(2 * math.pi * hz * i / rate)).round(),
]);

void main() {
  group('rmsDbfs', () {
    test('silence and empty input are -100', () {
      expect(rmsDbfs(Uint8List(0)), -100);
      expect(rmsDbfs(pcmOf(List.filled(160, 0))), -100);
    });

    test('a full-scale square wave is ~0 dBFS, a 0.5 sine ~-9 dBFS', () {
      expect(rmsDbfs(pcmOf([32767, -32767, 32767, -32767])), closeTo(0, 0.01));
      expect(rmsDbfs(sine(440, 16000, 1600)), closeTo(-9.03, 0.1));
    });

    test('works on an unaligned view', () {
      final big = Uint8List(11)..setAll(1, pcmOf([1000, -1000, 1000, -1000, 1000]));
      final view = Uint8List.sublistView(big, 1, 11);
      expect(rmsDbfs(view), closeTo(20 * math.log(1000 / 32768) / math.ln10, 0.01));
    });
  });

  group('firstVoicedOffsetMs', () {
    test('finds where the voice starts, null for silence', () {
      final pcm = Uint8List(4800)..setAll(1920, pcmOf(List.filled(480, 8000)));
      expect(firstVoicedOffsetMs(pcm, 24000, -45), 40); // sample 960 = 40 ms
      expect(firstVoicedOffsetMs(Uint8List(4800), 24000, -45), isNull);
      expect(firstVoicedOffsetMs(pcmOf(List.filled(2400, 50)), 24000, -45), isNull); // -56 dB
    });
  });

  group('applyGain', () {
    test('returns the same buffer for gain 1', () {
      final p = pcmOf([1, 2, 3]);
      expect(identical(applyGain(p, 1.0), p), isTrue);
    });

    test('multiplies and clips without touching the input', () {
      final p = pcmOf([1000, -1000, 20000, -20000]);
      final out = samplesOf(applyGain(p, 2.0));
      expect(out, [2000, -2000, 32767, -32768]);
      expect(samplesOf(p), [1000, -1000, 20000, -20000]);
    });
  });

  group('LinearResampler 16 kHz -> 24 kHz', () {
    test('produces 1.5x the samples, frame after frame', () {
      final r = LinearResampler(16000, 24000);
      var total = 0;
      for (var i = 0; i < 50; i++) {
        total += r.process(Uint8List(3200)).length ~/ 2; // 100 ms frames
      }
      expect(total, closeTo(50 * 2400, 2));
    });

    test('keeps the frequency and has no jumps at frame boundaries', () {
      final input = sine(440, 16000, 16000);
      final r = LinearResampler(16000, 24000);
      final out = <int>[];
      for (var off = 0; off < input.length; off += 3200) {
        out.addAll(samplesOf(r.process(Uint8List.sublistView(input, off, off + 3200))));
      }
      // Count rising zero crossings over 1 s -> 440.
      var crossings = 0;
      for (var i = 1; i < out.length; i++) {
        if (out[i - 1] < 0 && out[i] >= 0) crossings++;
      }
      expect(crossings, inInclusiveRange(439, 441));
      // Max step between neighbours stays that of a 440 Hz sine at 24 kHz.
      final maxStep = 0.5 * 32767 * 2 * math.pi * 440 / 24000;
      for (var i = 1; i < out.length; i++) {
        expect((out[i] - out[i - 1]).abs(), lessThan(maxStep * 1.2));
      }
    });
  });

  group('LatencyStats', () {
    test('nearest-rank percentiles over a rolling window', () {
      final s = LatencyStats(capacity: 10);
      expect(s.percentile(90), isNull);
      for (var i = 1; i <= 10; i++) {
        s.add(i * 100);
      }
      expect(s.percentile(50), 500);
      expect(s.percentile(90), 900);
      expect(s.last, 1000);
      s.add(5000); // drops 100
      expect(s.count, 10);
      expect(s.percentile(100), 5000);
      expect(s.percentile(0), 200);
    });
  });
}
