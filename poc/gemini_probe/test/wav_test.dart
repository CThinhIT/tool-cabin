import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:gemini_probe/src/wav.dart';
import 'package:test/test.dart';

/// Builds a WAV file by hand so the reader is tested against bytes it did
/// not write itself.
Uint8List buildWav({
  required int formatTag,
  required int channels,
  required int sampleRate,
  required int bits,
  required Uint8List data,
  bool extensible = false,
  bool extraChunks = false,
  int? dataSizeOverride,
}) {
  final b = BytesBuilder();
  void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void tag(String s) => b.add(s.codeUnits);

  final blockAlign = channels * bits ~/ 8;
  tag('RIFF');
  u32(0); // RIFF size is not validated by the reader
  tag('WAVE');
  if (extraChunks) {
    tag('LIST');
    u32(3); // odd size -> 1 pad byte
    b.add([1, 2, 3, 0]);
  }
  tag('fmt ');
  u32(extensible ? 40 : 16);
  u16(extensible ? wavFormatExtensible : formatTag);
  u16(channels);
  u32(sampleRate);
  u32(sampleRate * blockAlign);
  u16(blockAlign);
  u16(bits);
  if (extensible) {
    u16(22); // cbSize
    u16(bits); // valid bits
    u32(channels == 2 ? 3 : 4); // channel mask
    u16(formatTag); // SubFormat GUID data1 (low word)
    b.add([
      0x00,
      0x00,
      0x00,
      0x00,
      0x10,
      0x00,
      0x80,
      0x00,
      0x00,
      0xAA,
      0x00,
      0x38,
      0x9B,
      0x71,
    ]);
  }
  if (extraChunks) {
    tag('fact');
    u32(4);
    u32(data.length ~/ blockAlign);
  }
  tag('data');
  u32(dataSizeOverride ?? data.length);
  b.add(data);
  return b.toBytes();
}

Int16List sine(int sampleRate, double freq, int samples, {double amp = 0.5}) =>
    Int16List.fromList(
      List.generate(
        samples,
        (i) =>
            (amp * 32767 * math.sin(2 * math.pi * freq * i / sampleRate))
                .round(),
      ),
    );

void main() {
  group('PCM16 write/read', () {
    test('mono 16 kHz round-trips exactly, canonical 44-byte header', () {
      final s = sine(16000, 440, 1600);
      final bytes = encodeWavPcm16(s, sampleRate: 16000);
      expect(bytes.length, 44 + 3200);
      final bd = ByteData.sublistView(bytes);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(bd.getUint32(4, Endian.little), 36 + 3200);
      expect(bd.getUint16(20, Endian.little), 1); // PCM
      expect(bd.getUint16(22, Endian.little), 1); // mono
      expect(bd.getUint32(24, Endian.little), 16000);
      expect(bd.getUint32(28, Endian.little), 32000); // byte rate
      expect(bd.getUint16(34, Endian.little), 16);
      expect(bd.getUint32(40, Endian.little), 3200);

      final wav = decodeWav(bytes);
      expect(wav.sampleRate, 16000);
      expect(wav.channels, 1);
      expect(wav.frameCount, 1600);
      // 16 kHz mono in -> identical samples out (no resample, no rounding).
      expect(toMonoPcm16(wav), orderedEquals(s));
    });

    test('PCM bytes are little-endian', () {
      expect(
        pcm16ToBytesLE(Int16List.fromList([0x1234, -2])),
        orderedEquals([0x34, 0x12, 0xFE, 0xFF]),
      );
      expect(
        bytesLEToPcm16(Uint8List.fromList([0x34, 0x12, 0xFE, 0xFF])),
        orderedEquals([0x1234, -2]),
      );
    });

    test('24 kHz output WAV from raw server bytes', () {
      final raw = pcm16ToBytesLE(sine(24000, 300, 2400));
      final wav = decodeWav(encodeWavPcm16Bytes(raw, sampleRate: 24000));
      expect(wav.sampleRate, 24000);
      expect(wav.durationSeconds, closeTo(0.1, 1e-9));
    });
  });

  group('downmix + resample', () {
    test('stereo 48 kHz -> mono 16 kHz: channels averaged, 1/3 length', () {
      const frames = 4800; // 100 ms
      final inter = Int16List(frames * 2);
      for (var i = 0; i < frames; i++) {
        inter[2 * i] = 1000;
        inter[2 * i + 1] = 3000;
      }
      final bytes = buildWav(
        formatTag: wavFormatPcm,
        channels: 2,
        sampleRate: 48000,
        bits: 16,
        data: pcm16ToBytesLE(inter),
      );
      final out = toMonoPcm16(decodeWav(bytes));
      expect(out.length, 1600);
      expect(out.every((v) => v == 2000), isTrue);
    });

    test(
      '44.1 kHz sine -> 16 kHz keeps the waveform (linear interp error small)',
      () {
        const freq = 440.0;
        final src = sine(44100, freq, 44100); // 1 s
        final out = toMonoPcm16(
          decodeWav(encodeWavPcm16(src, sampleRate: 44100)),
        );
        expect(out.length, 16000);
        var maxErr = 0.0;
        for (var i = 0; i < out.length; i++) {
          final expected =
              0.5 * 32767 * math.sin(2 * math.pi * freq * i / 16000);
          maxErr = math.max(maxErr, (out[i] - expected).abs() / 32768);
        }
        expect(maxErr, lessThan(0.002));
      },
    );

    test('22050 Hz (Windows TTS default) -> 16 kHz length', () {
      final src = sine(22050, 200, 22050 * 2);
      final out = toMonoPcm16(
        decodeWav(encodeWavPcm16(src, sampleRate: 22050)),
      );
      expect(out.length, 32000);
    });

    test('resampleLinear edge cases', () {
      expect(resampleLinear(Float32List(0), 48000, 16000), isEmpty);
      final one = resampleLinear(Float32List.fromList([0.5]), 8000, 16000);
      expect(one.length, 2);
      expect(one.every((v) => v == 0.5), isTrue);
      expect(
        () => resampleLinear(Float32List(1), 0, 16000),
        throwsArgumentError,
      );
    });
  });

  group('reader formats', () {
    test(
      'WAVE_FORMAT_EXTENSIBLE 24-bit with LIST/fact chunks and odd padding',
      () {
        // Two frames, stereo: (+0.5, -0.5), (max, min)
        final data = Uint8List.fromList([
          0x00, 0x00, 0x40, 0x00, 0x00, 0xC0, // 0x400000, -0x400000
          0xFF, 0xFF, 0x7F, 0x00, 0x00, 0x80, // 0x7FFFFF, -0x800000
        ]);
        final wav = decodeWav(
          buildWav(
            formatTag: wavFormatPcm,
            channels: 2,
            sampleRate: 48000,
            bits: 24,
            data: data,
            extensible: true,
            extraChunks: true,
          ),
        );
        expect(wav.channels, 2);
        expect(wav.bitsPerSample, 24);
        expect(wav.formatTag, wavFormatPcm);
        expect(wav.samples[0], closeTo(0.5, 1e-6));
        expect(wav.samples[1], closeTo(-0.5, 1e-6));
        expect(wav.samples[2], closeTo(1.0, 1e-6));
        expect(wav.samples[3], -1.0);
      },
    );

    test('32-bit float', () {
      final f = Float32List.fromList([0.25, -1.0, 2.0]);
      final wav = decodeWav(
        buildWav(
          formatTag: wavFormatIeeeFloat,
          channels: 1,
          sampleRate: 16000,
          bits: 32,
          data: f.buffer.asUint8List(),
        ),
      );
      expect(wav.samples, orderedEquals([0.25, -1.0, 2.0]));
      // Out-of-range float is clipped on conversion.
      expect(toMonoPcm16(wav), orderedEquals([8192, -32768, 32767]));
    });

    test('data size 0xFFFFFFFF (streaming writer) is clamped to the file', () {
      final s = Int16List.fromList([1, 2, 3, 4]);
      final wav = decodeWav(
        buildWav(
          formatTag: wavFormatPcm,
          channels: 1,
          sampleRate: 16000,
          bits: 16,
          data: pcm16ToBytesLE(s),
          dataSizeOverride: 0xFFFFFFFF,
        ),
      );
      expect(toMonoPcm16(wav), orderedEquals(s));
    });

    test('rejects non-WAV and unsupported formats', () {
      expect(
        () => decodeWav(Uint8List.fromList('hello world!'.codeUnits)),
        throwsA(isA<WavFormatException>()),
      );
      expect(
        () => decodeWav(
          buildWav(
            formatTag: 2, // ADPCM
            channels: 1,
            sampleRate: 16000,
            bits: 4,
            data: Uint8List(4),
          ),
        ),
        throwsA(isA<WavFormatException>()),
      );
      final noData = buildWav(
        formatTag: wavFormatPcm,
        channels: 1,
        sampleRate: 16000,
        bits: 16,
        data: Uint8List(0),
      );
      // Chop off the 'data' chunk header entirely.
      expect(
        () => decodeWav(Uint8List.sublistView(noData, 0, noData.length - 8)),
        throwsA(isA<WavFormatException>()),
      );
    });
  });

  group('chunking + speech detection', () {
    test(
      '100 ms chunks at 16 kHz = 1600 samples = 3200 bytes, last partial',
      () {
        final chunks = splitIntoChunks(Int16List(16000 + 800), 1600);
        expect(chunks.length, 11);
        expect(chunks.first.length, 1600);
        expect(pcm16ToBytesLE(chunks.first).length, 3200);
        expect(chunks.last.length, 800);
      },
    );

    test('speech onset/end on silence + tone + silence', () {
      final s = Int16List(16000 * 2);
      final tone = sine(16000, 300, 8000, amp: 0.3);
      s.setRange(4000, 12000, tone); // 250 ms .. 750 ms
      final onset = findSpeechOnset(s, 16000)!;
      final end = findSpeechEnd(s, 16000)!;
      expect(onset, inInclusiveRange(4000, 4160));
      expect(end, inInclusiveRange(11840, 12000));
      expect(findSpeechOnset(Int16List(16000), 16000), isNull);
    });
  });

  group('sample files', () {
    test('samples/en_short.wav (Windows TTS) decodes and converts', () {
      final f = File('samples/en_short.wav');
      if (!f.existsSync()) return markTestSkipped('sample not present');
      final wav = decodeWav(f.readAsBytesSync());
      expect(wav.channels, 1);
      expect(wav.bitsPerSample, 16);
      final pcm = toMonoPcm16(wav);
      expect(pcm.length, wav.frameCount * 16000 ~/ wav.sampleRate);
      expect(findSpeechOnset(pcm, 16000), isNotNull);
    });

    test('samples/en_dialog_48k_stereo.wav decodes and converts', () {
      final f = File('samples/en_dialog_48k_stereo.wav');
      if (!f.existsSync()) return markTestSkipped('sample not present');
      final wav = decodeWav(f.readAsBytesSync());
      expect(wav.sampleRate, 48000);
      expect(wav.channels, 2);
      final pcm = toMonoPcm16(wav);
      expect(pcm.length, wav.frameCount ~/ 3);
    });
  });
}
