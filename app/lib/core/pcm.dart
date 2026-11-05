import 'dart:math' as math;
import 'dart:typed_data';

/// Helpers for PCM16 little-endian mono buffers.

Int16List _samples(Uint8List pcm) =>
    pcm.buffer.asInt16List(pcm.offsetInBytes, pcm.lengthInBytes ~/ 2);

/// RMS level in dBFS (full scale = 0 dB); -100 for silence or empty input.
double rmsDbfs(Uint8List pcm) {
  if (pcm.lengthInBytes < 2) return -100;
  // Copy when unaligned: asInt16List needs a 2-byte aligned offset.
  final s =
      pcm.offsetInBytes.isEven
          ? _samples(pcm)
          : _samples(Uint8List.fromList(pcm));
  var sum = 0.0;
  for (final v in s) {
    sum += v * v;
  }
  final rms = math.sqrt(sum / s.length) / 32768.0;
  if (rms <= 0) return -100;
  final db = 20 * math.log(rms) / math.ln10;
  return db < -100 ? -100 : db;
}

/// Offset in ms of the first [windowMs] window louder than [thresholdDb], or
/// null if the whole buffer is quieter.
int? firstVoicedOffsetMs(
  Uint8List pcm,
  int sampleRate,
  double thresholdDb, {
  int windowMs = 10,
}) {
  final aligned = pcm.offsetInBytes.isEven ? pcm : Uint8List.fromList(pcm);
  final s = _samples(aligned);
  final win = sampleRate * windowMs ~/ 1000;
  if (win <= 0) return null;
  final threshold = math.pow(10, thresholdDb / 20) * 32768;
  final thresholdSq = threshold * threshold;
  for (var start = 0; start + win <= s.length; start += win) {
    var sum = 0.0;
    for (var i = start; i < start + win; i++) {
      sum += s[i] * s[i];
    }
    if (sum / win > thresholdSq) return start * 1000 ~/ sampleRate;
  }
  return null;
}

/// Returns a new buffer multiplied by [gain] and clipped; [pcm] itself when
/// gain is 1.
Uint8List applyGain(Uint8List pcm, double gain) {
  if (gain == 1.0) return pcm;
  final src = Uint8List.fromList(pcm);
  final s = _samples(src);
  for (var i = 0; i < s.length; i++) {
    final v = (s[i] * gain).round();
    s[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
  }
  return src;
}

/// Streaming linear-interpolation resampler for PCM16 mono, e.g. 16 kHz mic
/// frames to the 24 kHz playback stream (emergency bypass). Keeps the phase
/// and the last sample across calls, so frame boundaries are seamless.
/// Speech quality only; not for music.
class LinearResampler {
  LinearResampler(this.fromRate, this.toRate)
    : assert(fromRate > 0 && toRate > 0),
      _step = fromRate / toRate;

  final int fromRate;
  final int toRate;
  final double _step;

  /// Position of the next output sample, relative to the first sample of the
  /// next input chunk; -1 refers to the last sample of the previous chunk.
  double _pos = 0;
  int _prev = 0;

  void reset() {
    _pos = 0;
    _prev = 0;
  }

  Uint8List process(Uint8List pcm) {
    final aligned =
        pcm.offsetInBytes.isEven ? pcm : Uint8List.fromList(pcm);
    final x = _samples(aligned);
    final n = x.length;
    if (n == 0) return Uint8List(0);
    final out = Int16List((n * toRate / fromRate).ceil() + 2);
    var count = 0;
    var p = _pos;
    while (p < n - 1) {
      final i = p.floor();
      final frac = p - i;
      final a = i < 0 ? _prev : x[i];
      final b = x[i + 1];
      out[count++] = (a + (b - a) * frac).round();
      p += _step;
    }
    _pos = p - n;
    _prev = x[n - 1];
    return out.buffer.asUint8List(0, count * 2);
  }
}
