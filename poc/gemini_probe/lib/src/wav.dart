import 'dart:math' as math;
import 'dart:typed_data';

/// WAV read / downmix / resample / write helpers for the probe.
///
/// Supported input: RIFF/WAVE, integer PCM 8/16/24/32-bit and IEEE float
/// 32/64-bit (plain or WAVE_FORMAT_EXTENSIBLE), any sample rate, any channel
/// count. Output is always 16-bit PCM little-endian.

const int wavFormatPcm = 1;
const int wavFormatIeeeFloat = 3;
const int wavFormatExtensible = 0xFFFE;

class WavFormatException implements Exception {
  WavFormatException(this.message);
  final String message;
  @override
  String toString() => 'WavFormatException: $message';
}

class DecodedWav {
  DecodedWav({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.formatTag,
    required this.samples,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// Effective format: [wavFormatPcm] or [wavFormatIeeeFloat]
  /// (EXTENSIBLE is resolved to its sub-format).
  final int formatTag;

  /// Interleaved samples normalised to [-1, 1].
  final Float32List samples;

  int get frameCount => samples.length ~/ channels;
  double get durationSeconds => frameCount / sampleRate;

  String describe() {
    final kind = formatTag == wavFormatIeeeFloat ? 'float' : 'PCM';
    return '$sampleRate Hz, $channels ch, $bitsPerSample-bit $kind, '
        '${durationSeconds.toStringAsFixed(2)} s';
  }
}

String _fourCc(Uint8List b, int offset) =>
    String.fromCharCodes(b.sublist(offset, offset + 4));

DecodedWav decodeWav(Uint8List bytes) {
  if (bytes.length < 12 ||
      _fourCc(bytes, 0) != 'RIFF' ||
      _fourCc(bytes, 8) != 'WAVE') {
    throw WavFormatException('not a RIFF/WAVE file');
  }
  final bd = ByteData.sublistView(bytes);

  int? formatTag;
  int? channels;
  int? sampleRate;
  int? blockAlign;
  int? bits;
  int? dataStart;
  int? dataLength;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = _fourCc(bytes, offset);
    var size = bd.getUint32(offset + 4, Endian.little);
    final bodyStart = offset + 8;
    final available = bytes.length - bodyStart;
    // Streaming writers may leave 0 / 0xFFFFFFFF sizes; clamp to the file.
    if (size > available) size = available;

    if (id == 'fmt ') {
      if (size < 16) throw WavFormatException('fmt chunk too small ($size)');
      formatTag = bd.getUint16(bodyStart, Endian.little);
      channels = bd.getUint16(bodyStart + 2, Endian.little);
      sampleRate = bd.getUint32(bodyStart + 4, Endian.little);
      blockAlign = bd.getUint16(bodyStart + 12, Endian.little);
      bits = bd.getUint16(bodyStart + 14, Endian.little);
      if (formatTag == wavFormatExtensible) {
        if (size < 40) {
          throw WavFormatException(
            'WAVE_FORMAT_EXTENSIBLE fmt chunk too small',
          );
        }
        // First two bytes of the SubFormat GUID hold the actual format tag.
        formatTag = bd.getUint16(bodyStart + 24, Endian.little);
      }
    } else if (id == 'data') {
      dataStart = bodyStart;
      dataLength = size;
      if (formatTag != null) break; // fmt already seen; ignore trailing chunks
    }
    offset = bodyStart + size + (size.isOdd ? 1 : 0);
  }

  if (formatTag == null) throw WavFormatException('missing fmt chunk');
  if (dataStart == null || dataLength == null) {
    throw WavFormatException('missing data chunk');
  }
  if (channels == null || channels < 1) {
    throw WavFormatException('invalid channel count $channels');
  }
  if (sampleRate == null || sampleRate < 1) {
    throw WavFormatException('invalid sample rate $sampleRate');
  }
  final isPcm =
      formatTag == wavFormatPcm &&
      (bits == 8 || bits == 16 || bits == 24 || bits == 32);
  final isFloat = formatTag == wavFormatIeeeFloat && (bits == 32 || bits == 64);
  if (!isPcm && !isFloat) {
    throw WavFormatException(
      'unsupported format tag $formatTag with $bits bits per sample',
    );
  }
  final bytesPerSample = bits! ~/ 8;
  final frameSize = bytesPerSample * channels;
  if (blockAlign != frameSize) {
    throw WavFormatException(
      'unsupported block align $blockAlign (expected $frameSize)',
    );
  }

  final frames = dataLength ~/ frameSize;
  final out = Float32List(frames * channels);
  var p = dataStart;
  for (var i = 0; i < out.length; i++, p += bytesPerSample) {
    double v;
    if (isFloat) {
      v =
          bits == 32
              ? bd.getFloat32(p, Endian.little)
              : bd.getFloat64(p, Endian.little);
    } else {
      switch (bits) {
        case 8:
          v = (bytes[p] - 128) / 128.0;
        case 16:
          v = bd.getInt16(p, Endian.little) / 32768.0;
        case 24:
          var s = bytes[p] | (bytes[p + 1] << 8) | (bytes[p + 2] << 16);
          if (s & 0x800000 != 0) s -= 0x1000000;
          v = s / 8388608.0;
        default:
          v = bd.getInt32(p, Endian.little) / 2147483648.0;
      }
    }
    out[i] = v;
  }

  return DecodedWav(
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bits,
    formatTag: formatTag,
    samples: out,
  );
}

/// Averages all channels into one.
Float32List downmixToMono(Float32List interleaved, int channels) {
  if (channels == 1) return Float32List.fromList(interleaved);
  final frames = interleaved.length ~/ channels;
  final out = Float32List(frames);
  for (var f = 0; f < frames; f++) {
    var sum = 0.0;
    final base = f * channels;
    for (var c = 0; c < channels; c++) {
      sum += interleaved[base + c];
    }
    out[f] = sum / channels;
  }
  return out;
}

/// Plain linear-interpolation resampler (no anti-alias filter; good enough
/// for a probe, speech energy above 8 kHz is small).
Float32List resampleLinear(Float32List mono, int fromRate, int toRate) {
  if (fromRate <= 0 || toRate <= 0) {
    throw ArgumentError('sample rates must be positive');
  }
  if (fromRate == toRate || mono.isEmpty) return Float32List.fromList(mono);
  final outLength = (mono.length * toRate) ~/ fromRate;
  final out = Float32List(outLength);
  final step = fromRate / toRate;
  final last = mono.length - 1;
  for (var i = 0; i < outLength; i++) {
    final pos = i * step;
    final i0 = pos.floor();
    if (i0 >= last) {
      out[i] = mono[last];
      continue;
    }
    final frac = pos - i0;
    out[i] = mono[i0] * (1 - frac) + mono[i0 + 1] * frac;
  }
  return out;
}

Int16List floatToPcm16(Float32List x) {
  final out = Int16List(x.length);
  for (var i = 0; i < x.length; i++) {
    out[i] = (x[i] * 32768.0).round().clamp(-32768, 32767);
  }
  return out;
}

Float32List pcm16ToFloat(Int16List x) {
  final out = Float32List(x.length);
  for (var i = 0; i < x.length; i++) {
    out[i] = x[i] / 32768.0;
  }
  return out;
}

/// Converts any decoded WAV into the Live API input format:
/// 16-bit PCM, mono, [targetRate] Hz.
Int16List toMonoPcm16(DecodedWav wav, {int targetRate = 16000}) {
  final mono = downmixToMono(wav.samples, wav.channels);
  return floatToPcm16(resampleLinear(mono, wav.sampleRate, targetRate));
}

Uint8List pcm16ToBytesLE(Int16List samples) {
  final out = Uint8List(samples.length * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(i * 2, samples[i], Endian.little);
  }
  return out;
}

Int16List bytesLEToPcm16(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final out = Int16List(n);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little);
  }
  return out;
}

/// Builds a canonical 44-byte-header PCM16 WAV file from little-endian
/// interleaved PCM16 bytes.
Uint8List encodeWavPcm16Bytes(
  Uint8List pcmBytesLE, {
  required int sampleRate,
  int channels = 1,
}) {
  final dataLength = pcmBytesLE.length - (pcmBytesLE.length % (2 * channels));
  final out = Uint8List(44 + dataLength);
  final bd = ByteData.sublistView(out);
  void fourCc(int o, String s) {
    for (var i = 0; i < 4; i++) {
      out[o + i] = s.codeUnitAt(i);
    }
  }

  fourCc(0, 'RIFF');
  bd.setUint32(4, 36 + dataLength, Endian.little);
  fourCc(8, 'WAVE');
  fourCc(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, wavFormatPcm, Endian.little);
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * channels * 2, Endian.little);
  bd.setUint16(32, channels * 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  fourCc(36, 'data');
  bd.setUint32(40, dataLength, Endian.little);
  out.setRange(44, 44 + dataLength, pcmBytesLE);
  return out;
}

Uint8List encodeWavPcm16(
  Int16List samples, {
  required int sampleRate,
  int channels = 1,
}) => encodeWavPcm16Bytes(
  pcm16ToBytesLE(samples),
  sampleRate: sampleRate,
  channels: channels,
);

/// Splits mono samples into chunks of [chunkSamples]; the last chunk may be
/// shorter.
List<Int16List> splitIntoChunks(Int16List samples, int chunkSamples) {
  if (chunkSamples <= 0) throw ArgumentError('chunkSamples must be > 0');
  final chunks = <Int16List>[];
  for (var start = 0; start < samples.length; start += chunkSamples) {
    final end = math.min(start + chunkSamples, samples.length);
    chunks.add(Int16List.sublistView(samples, start, end));
  }
  return chunks;
}

/// Very simple energy detector: returns the sample index of the first
/// window (and [minWindows] consecutive windows) whose RMS exceeds
/// [thresholdDbfs], or null if the signal never does.
int? findSpeechOnset(
  Int16List samples,
  int sampleRate, {
  int windowMs = 10,
  double thresholdDbfs = -40,
  int minWindows = 3,
}) {
  final w = math.max(1, sampleRate * windowMs ~/ 1000);
  var run = 0;
  for (var start = 0; start + w <= samples.length; start += w) {
    if (_rmsDbfs(samples, start, w) > thresholdDbfs) {
      run++;
      if (run >= minWindows) return start - (minWindows - 1) * w;
    } else {
      run = 0;
    }
  }
  return null;
}

/// Sample index just after the last window whose RMS exceeds
/// [thresholdDbfs], or null.
int? findSpeechEnd(
  Int16List samples,
  int sampleRate, {
  int windowMs = 10,
  double thresholdDbfs = -40,
}) {
  final w = math.max(1, sampleRate * windowMs ~/ 1000);
  int? end;
  for (var start = 0; start + w <= samples.length; start += w) {
    if (_rmsDbfs(samples, start, w) > thresholdDbfs) end = start + w;
  }
  return end;
}

double _rmsDbfs(Int16List s, int start, int length) {
  var sum = 0.0;
  for (var i = start; i < start + length; i++) {
    final v = s[i] / 32768.0;
    sum += v * v;
  }
  final rms = math.sqrt(sum / length);
  return rms <= 0 ? -200.0 : 20 * math.log(rms) / math.ln10;
}
