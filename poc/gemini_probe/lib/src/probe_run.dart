import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'live_session.dart';
import 'protocol.dart';
import 'secrets.dart';
import 'wav.dart';

class AbortFlag {
  bool aborted = false;
}

class ProbeOptions {
  const ProbeOptions({
    this.chunkMs = 100,
    this.tailSilenceMs = 2000,
    this.sendStreamEnd = true,
    this.idleTimeoutMs = 5000,
    this.maxWaitMs = 60000,
    this.setupTimeoutMs = 15000,
    this.segmentGapMs = 800,
    this.minStreamMs = 0,
    this.loopGapMs = 1000,
  });

  /// Size of each realtimeInput audio message.
  final int chunkMs;

  /// Silence streamed (at real-time pace) after the file, like a live mic.
  final int tailSilenceMs;

  /// Send `realtimeInput.audioStreamEnd` after the tail silence.
  final bool sendStreamEnd;

  /// Stop once no serverContent arrived for this long after input ended.
  final int idleTimeoutMs;

  /// Hard cap on waiting after input ended.
  final int maxWaitMs;
  final int setupTimeoutMs;

  /// Output-audio gap that starts a new (heuristic) segment.
  final int segmentGapMs;

  /// If > 0, repeat the input file until at least this much audio was sent.
  final int minStreamMs;

  /// Silence between repetitions when looping.
  final int loopGapMs;
}

/// Input file converted to the Live API input format.
class ProbeInput {
  ProbeInput._(this.path, this.original, this.pcm16k)
    : speechOnsetSample = findSpeechOnset(pcm16k, inputSampleRate),
      speechEndSample = findSpeechEnd(pcm16k, inputSampleRate);

  factory ProbeInput.fromDecoded(String label, DecodedWav wav) =>
      ProbeInput._(label, wav, toMonoPcm16(wav));

  final String path;
  final DecodedWav original;

  /// 16 kHz mono PCM16.
  final Int16List pcm16k;
  final int? speechOnsetSample;
  final int? speechEndSample;

  int get durationMs => pcm16k.length * 1000 ~/ inputSampleRate;

  static Future<ProbeInput> load(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('input file not found', path);
    }
    final wav = decodeWav(await file.readAsBytes());
    return ProbeInput._(path, wav, toMonoPcm16(wav));
  }
}

class TimedEvent {
  TimedEvent(
    this.atUs,
    this.type,
    this.segment, {
    this.text,
    this.languageCode,
    this.bytes,
    this.detail,
  });
  final int atUs;
  final String type;
  final int? segment;
  final String? text;
  final String? languageCode;
  final int? bytes;
  final String? detail;
}

/// Heuristic grouping of server output: a new segment starts after a
/// `turnComplete`, or when content arrives >= segmentGapMs after the last
/// audio of the current segment.
class Segment {
  Segment(this.index, this.startUs);
  final int index;
  final int startUs;
  int? firstInputTranscriptUs;
  int? firstOutputTranscriptUs;
  int? firstAudioUs;
  int? lastAudioUs;
  int? generationCompleteUs;
  int? turnCompleteUs;
  bool interrupted = false;
  int audioBytes = 0;
  final StringBuffer input = StringBuffer();
  final StringBuffer output = StringBuffer();
  String? inputLanguage;
  String? outputLanguage;
}

class ProbeRun {
  ProbeRun({
    required this.label,
    required this.input,
    required this.setup,
    required this.apiKey,
    required this.options,
    required this.log,
    required this.clock,
    required this.abort,
    this.auth = AuthMode.header,
    this.apiVersion = defaultApiVersion,
    this.endpointOverride,
  });

  /// Tests only (local mock server).
  final Uri? endpointOverride;
  final String label;
  final ProbeInput input;
  final TranslateSetup setup;
  final String apiKey;
  final ProbeOptions options;
  final Log log;
  final Stopwatch clock;
  final AbortFlag abort;
  final AuthMode auth;
  final String apiVersion;

  late final LiveSession session;

  // All absolute times are microseconds on [clock].
  int runStartUs = 0;

  /// Virtual microphone start: audio sample s is "spoken" at
  /// micStartUs + s / 16 kHz. Chunk i is sent when it would be complete on
  /// a real mic, i.e. at micStartUs + (i + 1) * chunkMs.
  int? micStartUs;
  int? firstChunkSentUs;
  int? inputEndUs;
  int? streamEndSentUs;
  int? firstAudioUs;
  int? lastAudioUs;
  int? firstInputTranscriptUs;
  int? firstOutputTranscriptUs;
  int? lastContentUs;
  int chunksSent = 0;
  int samplesSent = 0;
  int maxSendLatenessUs = 0;
  String endReason = 'not-started';

  /// Speech positions (ms of audio) in the streamed sequence.
  int? speechOnsetAudioMs;
  int? speechEndAudioMs;

  final BytesBuilder outputAudio = BytesBuilder(copy: false);
  final Set<int> outputRates = {};
  final List<TimedEvent> events = [];
  final List<Segment> segments = [];
  Segment? _current;
  final Map<String, int> messageCounts = {};
  final List<Map<String, Object?>> goAways = [];
  final List<String> serverErrors = [];
  int resumptionUpdates = 0;
  final StringBuffer inputText = StringBuffer();
  final StringBuffer outputText = StringBuffer();
  final Set<String> inputLanguages = {};

  int get _now => clock.elapsedMicroseconds;

  int get outputSampleRate =>
      outputRates.isEmpty ? defaultOutputSampleRate : outputRates.first;

  int get outputAudioBytes => outputAudio.length;

  int get outputAudioMs =>
      outputAudioBytes ~/ 2 * 1000 ~/ math.max(1, outputSampleRate);

  String _t(int atUs) {
    final base = micStartUs ?? runStartUs;
    final ms = (atUs - base) / 1000.0;
    return '${micStartUs == null ? 'c' : 't'}=${ms >= 0 ? '+' : ''}'
        '${(ms / 1000).toStringAsFixed(3)}s';
  }

  Future<void> run() async {
    runStartUs = _now;
    session = LiveSession(
      setup: setup,
      apiKey: apiKey,
      clock: clock,
      log: log,
      auth: auth,
      apiVersion: apiVersion,
      endpointOverride: endpointOverride,
    )..onMessage = _onMessage;

    log.info(
      'connecting (target=${setup.targetLanguageCode}, '
      'echoTargetLanguage=${setup.echoTargetLanguage}, auth=${auth.name})',
    );
    final ok = await session.open(
      setupTimeout: Duration(milliseconds: options.setupTimeoutMs),
    );
    if (session.connectedAtUs != null) {
      log.info('${_t(session.connectedAtUs!)} websocket connected');
    }
    if (!ok) {
      endReason = 'setup-failed';
      if (session.isOpen) await session.close(reason: 'setup timeout');
      await session.done;
      log.error('session not ready: ${_failureText()}');
      return;
    }
    log.info('${_t(session.setupCompleteAtUs!)} setupComplete');

    await _stream();

    if (!session.isOpen) endReason = 'server-closed while streaming';
    if (session.isOpen && !abort.aborted) await _drain();
    if (abort.aborted) endReason = 'aborted';
    if (session.isOpen) await session.close();
    await session.done;
    _closeSegment();
  }

  Future<void> _stream() async {
    final sequence = _buildSequence();
    final chunkSamples = inputSampleRate * options.chunkMs ~/ 1000;
    final chunks = splitIntoChunks(sequence, chunkSamples);
    micStartUs = _now;
    log.info(
      '${_t(micStartUs!)} streaming ${chunks.length} chunks x '
      '${options.chunkMs} ms at real-time pace '
      '(${sequence.length * 1000 ~/ inputSampleRate} ms incl. '
      '${options.tailSilenceMs} ms tail silence)',
    );
    endReason = 'streaming';

    var endSample = 0;
    for (final chunk in chunks) {
      if (abort.aborted || !session.isOpen) break;
      endSample += chunk.length;
      final dueUs = micStartUs! + endSample * 1000000 ~/ inputSampleRate;
      final waitUs = dueUs - _now;
      if (waitUs > 0) {
        await Future<void>.delayed(Duration(microseconds: waitUs));
      } else {
        // Yield so incoming frames are processed even when we are late.
        await Future<void>.delayed(Duration.zero);
      }
      if (abort.aborted || !session.isOpen) break;
      final lateness = _now - dueUs;
      if (lateness > maxSendLatenessUs) maxSendLatenessUs = lateness;
      session.sendAudio(pcm16ToBytesLE(chunk));
      firstChunkSentUs ??= _now;
      chunksSent++;
      samplesSent = endSample;
    }
    inputEndUs = _now;
    log.info(
      '${_t(inputEndUs!)} input finished '
      '($chunksSent chunks, ${samplesSent * 1000 ~/ inputSampleRate} ms sent)',
    );

    if (options.sendStreamEnd && session.isOpen && !abort.aborted) {
      session.sendAudioStreamEnd();
      streamEndSentUs = _now;
      log.info('${_t(streamEndSentUs!)} sent realtimeInput.audioStreamEnd');
    }
  }

  /// Builds the virtual-mic sample sequence: file (looped if requested),
  /// then tail silence. Records speech onset/end positions.
  Int16List _buildSequence() {
    final pcm = input.pcm16k;
    final gap = inputSampleRate * options.loopGapMs ~/ 1000;
    final tail = inputSampleRate * options.tailSilenceMs ~/ 1000;
    final minSamples = inputSampleRate * options.minStreamMs ~/ 1000;
    var passes = 1;
    if (minSamples > 0 && pcm.isNotEmpty) {
      while (passes * pcm.length + (passes - 1) * gap < minSamples) {
        passes++;
      }
    }
    final total = passes * pcm.length + (passes - 1) * gap + tail;
    final out = Int16List(total);
    var pos = 0;
    var lastPassStart = 0;
    for (var p = 0; p < passes; p++) {
      if (p > 0) pos += gap;
      lastPassStart = pos;
      out.setRange(pos, pos + pcm.length, pcm);
      pos += pcm.length;
    }
    if (input.speechOnsetSample != null) {
      speechOnsetAudioMs = input.speechOnsetSample! * 1000 ~/ inputSampleRate;
    }
    if (input.speechEndSample != null) {
      speechEndAudioMs =
          (lastPassStart + input.speechEndSample!) * 1000 ~/ inputSampleRate;
    }
    if (passes > 1) log.info('looping input file $passes times');
    return out;
  }

  Future<void> _drain() async {
    endReason = 'draining';
    final idleUs = options.idleTimeoutMs * 1000;
    final maxUs = options.maxWaitMs * 1000;
    final start = inputEndUs ?? _now;
    while (true) {
      if (!session.isOpen) {
        endReason = 'server-closed';
        return;
      }
      if (abort.aborted) return;
      final now = _now;
      final lastActivity = math.max(start, lastContentUs ?? 0);
      if (now - lastActivity >= idleUs) {
        endReason = 'idle ${options.idleTimeoutMs} ms';
        return;
      }
      if (now - start >= maxUs) {
        endReason = 'max-wait ${options.maxWaitMs} ms';
        return;
      }
      await Future.any<void>([
        session.done,
        Future<void>.delayed(const Duration(milliseconds: 100)),
      ]);
    }
  }

  // ---------------------------------------------------------------------
  // Server message handling
  // ---------------------------------------------------------------------

  void _onMessage(ServerMessage m, int at) {
    for (final t in m.typeTokens()) {
      messageCounts[t] = (messageCounts[t] ?? 0) + 1;
    }
    log.debug('${_t(at)} recv ${m.describe()}');

    if (m.error != null) {
      final text = jsonEncode(m.error);
      serverErrors.add(text);
      events.add(TimedEvent(at, 'error', _current?.index, detail: text));
      log.error('server error payload: $text');
    }
    if (m.unknownKeys.isNotEmpty) {
      log.warn('unknown server message keys: ${m.unknownKeys.join(', ')}');
    }
    if (m.hasGoAway) {
      goAways.add({'tMs': _rel(at), 'timeLeft': m.goAwayTimeLeft});
      events.add(
        TimedEvent(at, 'goAway', _current?.index, detail: m.goAwayTimeLeft),
      );
      log.warn('${_t(at)} GoAway received, timeLeft=${m.goAwayTimeLeft}');
    }
    if (m.resumable != null) {
      resumptionUpdates++;
      events.add(
        TimedEvent(
          at,
          'sessionResumptionUpdate',
          _current?.index,
          detail: 'resumable=${m.resumable}',
        ),
      );
    }

    final c = m.serverContent;
    if (c == null) return;
    lastContentUs = at;

    final inT = c.inputTranscription;
    if (inT != null && inT.text.isNotEmpty) {
      final seg = _segmentFor(at);
      seg.firstInputTranscriptUs ??= at;
      seg.input.write(inT.text);
      seg.inputLanguage ??= inT.languageCode;
      firstInputTranscriptUs ??= at;
      inputText.write(inT.text);
      if (inT.languageCode != null) inputLanguages.add(inT.languageCode!);
      events.add(
        TimedEvent(
          at,
          'inputTranscription',
          seg.index,
          text: inT.text,
          languageCode: inT.languageCode,
        ),
      );
      log.info('${_t(at)} IN  (${inT.languageCode ?? '?'}): ${inT.text}');
    }
    final interim = c.interimInputTranscription;
    if (interim != null && interim.text.isNotEmpty) {
      events.add(
        TimedEvent(
          at,
          'interimInputTranscription',
          _current?.index,
          text: interim.text,
          languageCode: interim.languageCode,
        ),
      );
      log.debug(
        '${_t(at)} IN~ (${interim.languageCode ?? '?'}): ${interim.text}',
      );
    }

    for (final a in c.audio) {
      final seg = _segmentFor(at);
      seg.firstAudioUs ??= at;
      seg.lastAudioUs = at;
      seg.audioBytes += a.bytes.length;
      firstAudioUs ??= at;
      lastAudioUs = at;
      outputAudio.add(a.bytes);
      final rate = a.sampleRate;
      if (rate != null && outputRates.add(rate) && outputRates.length > 1) {
        log.warn('output sample rate changed mid-stream: $outputRates');
      }
      events.add(
        TimedEvent(
          at,
          'audio',
          seg.index,
          bytes: a.bytes.length,
          detail: a.mimeType,
        ),
      );
      if (seg.audioBytes == a.bytes.length) {
        log.info(
          '${_t(at)} AUDIO starts (segment ${seg.index}, '
          '${a.bytes.length} B, ${a.mimeType})',
        );
      }
    }

    final outT = c.outputTranscription;
    if (outT != null && outT.text.isNotEmpty) {
      final seg = _segmentFor(at);
      seg.firstOutputTranscriptUs ??= at;
      seg.output.write(outT.text);
      seg.outputLanguage ??= outT.languageCode;
      firstOutputTranscriptUs ??= at;
      outputText.write(outT.text);
      events.add(
        TimedEvent(
          at,
          'outputTranscription',
          seg.index,
          text: outT.text,
          languageCode: outT.languageCode,
        ),
      );
      log.info('${_t(at)} OUT (${outT.languageCode ?? '?'}): ${outT.text}');
    }

    for (final text in c.texts) {
      events.add(TimedEvent(at, 'modelText', _current?.index, text: text));
      log.info('${_t(at)} model text part (unexpected for translate): $text');
    }
    if (c.interrupted) {
      _current?.interrupted = true;
      events.add(TimedEvent(at, 'interrupted', _current?.index));
    }
    if (c.generationComplete) {
      _current?.generationCompleteUs = at;
      events.add(TimedEvent(at, 'generationComplete', _current?.index));
    }
    if (c.turnComplete) {
      _current?.turnCompleteUs = at;
      events.add(
        TimedEvent(
          at,
          'turnComplete',
          _current?.index,
          detail: c.interactionStatus,
        ),
      );
      _closeSegment();
    }
  }

  Segment _segmentFor(int at) {
    final cur = _current;
    if (cur != null &&
        !(cur.lastAudioUs != null &&
            at - cur.lastAudioUs! >= options.segmentGapMs * 1000)) {
      return cur;
    }
    _closeSegment();
    final seg = Segment(segments.length + 1, at);
    segments.add(seg);
    _current = seg;
    return seg;
  }

  void _closeSegment() => _current = null;

  // ---------------------------------------------------------------------
  // Results
  // ---------------------------------------------------------------------

  int? _rel(int? atUs) {
    if (atUs == null) return null;
    final base = micStartUs ?? runStartUs;
    return ((atUs - base) / 1000).round();
  }

  static int? _diffMs(int? laterUs, int? earlierUs) =>
      (laterUs == null || earlierUs == null)
          ? null
          : ((laterUs - earlierUs) / 1000).round();

  int? _audioPosUs(int? audioMs) =>
      (audioMs == null || micStartUs == null)
          ? null
          : micStartUs! + audioMs * 1000;

  String get closedBy => session.closeInitiatedByClient ? 'client' : 'server';

  String get closePhase {
    if (!session.setupOk) return 'setup';
    final closedAt = session.closedAtUs;
    if (closedAt == null) return 'open';
    if (inputEndUs == null || closedAt < inputEndUs!) return 'streaming';
    return 'draining';
  }

  /// Session reached setupComplete and was not cut off by the server.
  bool get stayedUp =>
      session.setupOk &&
      (session.closeInitiatedByClient ||
          (closePhase == 'draining' && session.closeCode == 1000));

  Map<String, Object?> timing() => {
    'connectMs': _diffMs(session.connectedAtUs, session.connectStartUs),
    'setupRoundTripMs': _diffMs(
      session.setupCompleteAtUs,
      session.setupSentAtUs,
    ),
    'connectStartToSetupCompleteMs': _diffMs(
      session.setupCompleteAtUs,
      session.connectStartUs,
    ),
    'firstChunkSentToFirstAudioMs': _diffMs(firstAudioUs, firstChunkSentUs),
    'firstChunkSentToFirstInputTranscriptMs': _diffMs(
      firstInputTranscriptUs,
      firstChunkSentUs,
    ),
    'firstChunkSentToFirstOutputTranscriptMs': _diffMs(
      firstOutputTranscriptUs,
      firstChunkSentUs,
    ),
    'firstInputTranscriptToFirstAudioMs': _diffMs(
      firstAudioUs,
      firstInputTranscriptUs,
    ),
    'speechOnsetAudioMs': speechOnsetAudioMs,
    'speechOnsetToFirstAudioMs': _diffMs(
      firstAudioUs,
      _audioPosUs(speechOnsetAudioMs),
    ),
    'speechEndAudioMs': speechEndAudioMs,
    'speechEndToLastAudioMs': _diffMs(
      lastAudioUs,
      _audioPosUs(speechEndAudioMs),
    ),
    'maxSendLatenessMs': (maxSendLatenessUs / 1000).round(),
  };

  List<Map<String, Object?>> segmentsJson() => [
    for (final s in segments)
      {
        'index': s.index,
        'startMs': _rel(s.startUs),
        'firstInputTranscriptMs': _rel(s.firstInputTranscriptUs),
        'firstOutputTranscriptMs': _rel(s.firstOutputTranscriptUs),
        'firstAudioMs': _rel(s.firstAudioUs),
        'lastAudioMs': _rel(s.lastAudioUs),
        'inputTranscriptToFirstAudioMs': _diffMs(
          s.firstAudioUs,
          s.firstInputTranscriptUs,
        ),
        'audioMs': s.audioBytes ~/ 2 * 1000 ~/ outputSampleRate,
        'generationCompleteMs': _rel(s.generationCompleteUs),
        'turnCompleteMs': _rel(s.turnCompleteUs),
        'interrupted': s.interrupted,
        'inputLanguage': s.inputLanguage,
        'outputLanguage': s.outputLanguage,
        'inputText': s.input.toString(),
        'outputText': s.output.toString(),
      },
  ];

  Map<String, Object?> toJson() => {
    'label': label,
    'timeBase':
        't=0 is the virtual microphone start; input audio '
        'position p ms was spoken at t=p ms; chunk i is sent at '
        '(i+1)*chunkMs',
    'model': setup.model,
    'endpoint': session.endpointForReport,
    'auth': auth.name,
    'setup': setup.toMessage(),
    'input': {
      'file': input.path,
      'original': input.original.describe(),
      'sentSampleRate': inputSampleRate,
      'fileDurationMs': input.durationMs,
      'sentAudioMs': samplesSent * 1000 ~/ inputSampleRate,
      'chunkMs': options.chunkMs,
      'chunksSent': chunksSent,
      'tailSilenceMs': options.tailSilenceMs,
      'audioStreamEndSent': streamEndSentUs != null,
      'audioStreamEndMs': _rel(streamEndSentUs),
      'inputEndMs': _rel(inputEndUs),
    },
    'output': {
      'sampleRate': outputSampleRate,
      'sampleRatesSeen': outputRates.toList(),
      'audioBytes': outputAudioBytes,
      'audioMs': outputAudioMs,
      'firstAudioMs': _rel(firstAudioUs),
      'lastAudioMs': _rel(lastAudioUs),
    },
    'timing': timing(),
    'session': {
      'setupComplete': session.setupOk,
      'stayedUp': stayedUp,
      'endReason': endReason,
      'closeCode': session.closeCode,
      'closeReason': session.closeReason,
      'closeHint': closeCodeHint(session.closeCode),
      'closedBy': closedBy,
      'closePhase': closePhase,
      'closedAtMs': _rel(session.closedAtUs),
      'openError': session.openError,
      'httpStatusCode': session.httpStatusCode,
      'goAway': goAways,
      'serverErrors': serverErrors,
      'clientErrors': session.errors,
      'sessionResumptionUpdates': resumptionUpdates,
    },
    'messageTypeCounts': messageCounts,
    'inputLanguages': inputLanguages.toList(),
    'inputTranscript': inputText.toString(),
    'outputTranscript': outputText.toString(),
    'segments': segmentsJson(),
    'events': [
      for (final e in events)
        {
          'tMs': _rel(e.atUs),
          'type': e.type,
          if (e.segment != null) 'segment': e.segment,
          if (e.text != null) 'text': e.text,
          if (e.languageCode != null) 'languageCode': e.languageCode,
          if (e.bytes != null) 'bytes': e.bytes,
          if (e.detail != null) 'detail': e.detail,
        },
    ],
  };

  String _failureText() {
    final parts = <String>[];
    if (session.openError != null) parts.add(session.openError!);
    if (session.closedAtUs != null && session.connectedAtUs != null) {
      parts.add(
        'server closed: code=${session.closeCode} '
        'reason="${session.closeReason ?? ''}" '
        '(${closeCodeHint(session.closeCode)})',
      );
    }
    parts.addAll(session.errors);
    parts.addAll(serverErrors.map((e) => 'server error: $e'));
    return parts.isEmpty ? 'unknown' : parts.join('; ');
  }

  String closeSummary() {
    if (session.openError != null) return session.openError!;
    return 'code=${session.closeCode} reason="${session.closeReason ?? ''}" '
        '(${closeCodeHint(session.closeCode)}), closed by $closedBy '
        'during $closePhase';
  }

  void printSummary(Log out) {
    String v(Object? x, [String unit = ' ms']) => x == null ? 'n/a' : '$x$unit';
    final t = timing();
    out.info('');
    out.info('== timing ==');
    out.info('connect (DNS+TCP+TLS+WS handshake)      ${v(t['connectMs'])}');
    out.info(
      'setup sent -> setupComplete             ${v(t['setupRoundTripMs'])}',
    );
    out.info(
      'first chunk sent -> first audio byte    '
      '${v(t['firstChunkSentToFirstAudioMs'])}   <== time-to-first-audio',
    );
    out.info(
      'first chunk sent -> first IN transcript '
      '${v(t['firstChunkSentToFirstInputTranscriptMs'])}',
    );
    out.info(
      'first chunk sent -> first OUT transcript '
      '${v(t['firstChunkSentToFirstOutputTranscriptMs'])}',
    );
    out.info(
      'first IN transcript -> first audio      '
      '${v(t['firstInputTranscriptToFirstAudioMs'])}',
    );
    out.info(
      'speech onset (audio ${v(t['speechOnsetAudioMs'])}) -> first audio  '
      '${v(t['speechOnsetToFirstAudioMs'])}',
    );
    out.info(
      'speech end (audio ${v(t['speechEndAudioMs'])}) -> last audio     '
      '${v(t['speechEndToLastAudioMs'])}',
    );
    out.info(
      'pacing: max send lateness               ${v(t['maxSendLatenessMs'])}',
    );

    if (segments.isNotEmpty) {
      out.info('');
      out.info(
        '== segments (heuristic: split on turnComplete or '
        '>= ${options.segmentGapMs} ms output gap) ==',
      );
      out.info('  #  firstIN  firstAUDIO  IN->AUDIO  audio_ms  turnComplete');
      for (final s in segmentsJson()) {
        String c(Object? x, int w) => (x == null ? '-' : '$x').padLeft(w);
        out.info(
          '${c(s['index'], 3)}  ${c(s['firstInputTranscriptMs'], 7)}  '
          '${c(s['firstAudioMs'], 10)}  '
          '${c(s['inputTranscriptToFirstAudioMs'], 9)}  '
          '${c(s['audioMs'], 8)}  ${c(s['turnCompleteMs'], 12)}',
        );
        if ((s['inputText'] as String).isNotEmpty) {
          out.info('       IN : ${s['inputText']}');
        }
        if ((s['outputText'] as String).isNotEmpty) {
          out.info('       OUT: ${s['outputText']}');
        }
      }
    }

    out.info('');
    out.info('== session ==');
    out.info(
      'received audio: ${(outputAudioMs / 1000).toStringAsFixed(2)} s '
      '($outputAudioBytes B @ $outputSampleRate Hz)',
    );
    out.info('end reason: $endReason');
    out.info('close: ${closeSummary()}');
    if (goAways.isNotEmpty) out.info('GoAway: $goAways');
    if (resumptionUpdates > 0) {
      out.info('sessionResumptionUpdate messages: $resumptionUpdates');
    }
    if (serverErrors.isNotEmpty) out.info('server errors: $serverErrors');
    if (session.errors.isNotEmpty) out.info('client errors: ${session.errors}');
    out.info('message types: $messageCounts');

    if (session.setupOk && outputAudioBytes == 0) {
      final target = setup.targetLanguageCode.toLowerCase();
      final sameLang = inputLanguages.any(
        (l) =>
            l.toLowerCase() == target || l.toLowerCase().startsWith('$target-'),
      );
      if (sameLang && !setup.echoTargetLanguage) {
        out.info(
          'note: no audio, but the input was detected as '
          '"${setup.targetLanguageCode}" = target and echoTargetLanguage=false, '
          'so silence is the documented behaviour (use --echo to hear it).',
        );
      } else {
        out.warn('no translated audio received');
      }
    }
    if (streamEndSentUs != null &&
        !session.closeInitiatedByClient &&
        (session.closedAtUs ?? 0) >= streamEndSentUs! &&
        session.closeCode != 1000) {
      out.info(
        'hint: server closed after audioStreamEnd; retry with '
        '--no-stream-end to rule it out.',
      );
    }
  }
}
