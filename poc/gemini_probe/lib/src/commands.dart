import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/command_runner.dart';

import 'probe_run.dart';
import 'protocol.dart';
import 'secrets.dart';
import 'wav.dart';

const toolVersion = '0.1.0';

/// Exit codes.
const exitOk = 0;
const exitSessionFailed = 2;
const exitAllFailed = 3;
const exitUsage = 64;
const exitInputError = 66;
const exitNoApiKey = 78;

class InputException implements Exception {
  InputException(this.message);
  final String message;
  @override
  String toString() => 'ERROR: $message';
}

abstract class _LiveCommand extends Command<int> {
  /// Called at the end of each subclass constructor so that the
  /// command-specific options are listed first in --help.
  void addCommonOptions() {
    argParser
      ..addSeparator('Session / protocol options:')
      ..addOption(
        'model',
        defaultsTo: defaultModel,
        help: 'Model id (without "models/").',
      )
      ..addFlag(
        'echo',
        negatable: false,
        help:
            'Set translationConfig.echoTargetLanguage=true (default '
            'false: input already in the target language yields silence).',
      )
      ..addOption(
        'auth',
        allowed: ['header', 'query', 'ephemeral'],
        defaultsTo: 'header',
        allowedHelp: {
          'header':
              'API key in the x-goog-api-key handshake header '
              '(python-genai SDK behaviour; key never appears in a URL).',
          'query':
              'API key as ?key= query parameter (as in the WebSocket '
              'docs).',
          'ephemeral':
              'POST /v1beta/auth_tokens first, then connect to '
              'BidiGenerateContentConstrained with "Authorization: Token".',
        },
      )
      ..addOption('api-version', defaultsTo: defaultApiVersion)
      ..addOption(
        'transcription-in',
        allowed: ['setup', 'generation-config'],
        defaultsTo: 'setup',
        allowedHelp: {
          'setup':
              'inputAudioTranscription/outputAudioTranscription at '
              'the top level of setup (API reference + SDK).',
          'generation-config':
              'inside setup.generationConfig (as in the '
              'Live Translate guide\'s raw WebSocket example).',
        },
      )
      ..addFlag(
        'resumption',
        negatable: false,
        help:
            'Add setup.sessionResumption={} and count '
            'sessionResumptionUpdate messages.',
      )
      ..addOption(
        'chunk-ms',
        defaultsTo: '100',
        help: 'Audio per realtimeInput message.',
      )
      ..addOption(
        'tail-silence-ms',
        defaultsTo: '2000',
        help: 'Silence streamed after the file (real-time pace).',
      )
      ..addFlag(
        'stream-end',
        defaultsTo: true,
        help: 'Send realtimeInput.audioStreamEnd after the tail silence.',
      )
      ..addOption(
        'idle-timeout-ms',
        defaultsTo: '5000',
        help:
            'After input ends, stop when no serverContent arrived for '
            'this long.',
      )
      ..addOption(
        'max-wait-ms',
        defaultsTo: '60000',
        help: 'Hard cap on waiting after input ends.',
      )
      ..addOption('setup-timeout-ms', defaultsTo: '15000')
      ..addOption(
        'segment-gap-ms',
        defaultsTo: '800',
        help:
            'Output-audio gap that starts a new segment in the '
            'per-utterance table (heuristic).',
      )
      ..addOption(
        'min-seconds',
        defaultsTo: '0',
        help:
            'Loop the input file (1 s gap) until at least this many '
            'seconds were streamed. 0 = play once.',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help:
            'Log the setup JSON and every server message type '
            '(never audio payloads or credentials).',
      );
  }

  int intOpt(String name, {int min = 0}) {
    final raw = argResults![name] as String;
    final v = int.tryParse(raw);
    if (v == null || v < min) {
      throw UsageException(
        '--$name must be an integer >= $min (got "$raw")',
        usage,
      );
    }
    return v;
  }

  String requiredOpt(String name) {
    final v = argResults![name] as String?;
    if (v == null || v.isEmpty) {
      throw UsageException('missing --$name', usage);
    }
    return v;
  }

  bool get verbose => argResults!['verbose'] as bool;

  AuthMode get authMode =>
      AuthMode.values.byName(argResults!['auth'] as String);

  ProbeOptions probeOptions() {
    final chunkMs = intOpt('chunk-ms', min: 10);
    return ProbeOptions(
      chunkMs: chunkMs,
      tailSilenceMs: intOpt('tail-silence-ms'),
      sendStreamEnd: argResults!['stream-end'] as bool,
      idleTimeoutMs: intOpt('idle-timeout-ms', min: 100),
      maxWaitMs: intOpt('max-wait-ms', min: 100),
      setupTimeoutMs: intOpt('setup-timeout-ms', min: 100),
      segmentGapMs: intOpt('segment-gap-ms', min: 1),
      minStreamMs: intOpt('min-seconds') * 1000,
    );
  }

  TranslateSetup translateSetup(String target) => TranslateSetup(
    model: argResults!['model'] as String,
    targetLanguageCode: target,
    echoTargetLanguage: argResults!['echo'] as bool,
    placement:
        argResults!['transcription-in'] == 'generation-config'
            ? TranscriptionPlacement.generationConfig
            : TranscriptionPlacement.setup,
    sessionResumption: argResults!['resumption'] as bool,
  );

  Future<ProbeInput> loadInput(String path, Log log) async {
    try {
      final input = await ProbeInput.load(path);
      log.info(
        'input: $path (${input.original.describe()}) -> '
        '$inputSampleRate Hz mono PCM16, ${input.durationMs} ms'
        '${input.speechOnsetSample == null ? ', no speech detected above -40 dBFS' : ''}',
      );
      return input;
    } on FileSystemException catch (e) {
      throw InputException('${e.message}: ${e.path}');
    } on WavFormatException catch (e) {
      throw InputException('$path: ${e.message}');
    }
  }

  /// Runs [body] with Ctrl+C mapped to a graceful abort (outputs are still
  /// written). A second Ctrl+C exits immediately.
  Future<T> withSigint<T>(
    AbortFlag abort,
    Log log,
    Future<T> Function() body,
  ) async {
    StreamSubscription<ProcessSignal>? sub;
    try {
      sub = ProcessSignal.sigint.watch().listen((_) {
        if (abort.aborted) exit(130);
        abort.aborted = true;
        log.warn(
          'Ctrl+C: stopping, closing session(s), writing outputs... '
          '(press again to quit immediately)',
        );
      });
    } on Object {
      sub = null; // signal watching not supported; ignore
    }
    try {
      return await body();
    } finally {
      await sub?.cancel();
    }
  }

  Map<String, Object?> header(String command) => {
    'tool': 'gemini_probe',
    'version': toolVersion,
    'command': command,
    'startedAt': DateTime.now().toUtc().toIso8601String(),
  };
}

Future<void> _writeWav(String path, ProbeRun run, Log log) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(
    encodeWavPcm16Bytes(
      run.outputAudio.toBytes(),
      sampleRate: run.outputSampleRate,
    ),
  );
  log.info(
    'wrote $path (${(run.outputAudioMs / 1000).toStringAsFixed(2)} s, '
    '${run.outputSampleRate} Hz mono PCM16)',
  );
}

Future<void> _writeJson(String path, Map<String, Object?> json, Log log) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final text = Redactor.global.redact(
    const JsonEncoder.withIndent('  ').convert(json),
  );
  await file.writeAsString(text, encoding: utf8);
  log.info('wrote $path');
}

// ---------------------------------------------------------------------------

class TranslateCommand extends _LiveCommand {
  TranslateCommand() {
    argParser
      ..addOption(
        'in',
        valueHelp: 'wav',
        help: 'Input WAV (any rate/channels).',
      )
      ..addOption(
        'target',
        allowed: ['en', 'vi'],
        help: 'translationConfig.targetLanguageCode.',
      )
      ..addOption(
        'out',
        valueHelp: 'wav',
        help: 'Where to save received audio.',
      )
      ..addOption(
        'transcript',
        valueHelp: 'json',
        help: 'Optional: save transcripts, events and timing as JSON.',
      )
      ..addOption(
        'save-sent',
        valueHelp: 'wav',
        help: 'Optional: save the 16 kHz mono audio exactly as sent.',
      );
    addCommonOptions();
  }

  @override
  String get name => 'translate';

  @override
  String get description =>
      'Stream one WAV to Gemini Live Translate at real-time pace (100 ms '
      'chunks), save the translated audio + transcripts, print latency.';

  @override
  String get invocation =>
      '${runner!.executableName} translate --in <wav> --target <en|vi> '
      '--out <wav> [--transcript <json>]';

  @override
  Future<int> run() async {
    final log = Log(verbose: verbose);
    final inPath = requiredOpt('in');
    final target = requiredOpt('target');
    final outPath = requiredOpt('out');
    final transcriptPath = argResults!['transcript'] as String?;
    final savePath = argResults!['save-sent'] as String?;
    final options = probeOptions();
    final setup = translateSetup(target);

    final input = await loadInput(inPath, log);
    final apiKey = readApiKeyFromEnv();
    if (savePath != null) {
      await File(savePath).parent.create(recursive: true);
      await File(
        savePath,
      ).writeAsBytes(encodeWavPcm16(input.pcm16k, sampleRate: inputSampleRate));
      log.info('wrote $savePath (audio as sent)');
    }
    log.info(
      'model: ${setup.model}  target=$target  '
      'echoTargetLanguage=${setup.echoTargetLanguage}',
    );

    final abort = AbortFlag();
    final run = ProbeRun(
      label: 'translate',
      input: input,
      setup: setup,
      apiKey: apiKey,
      options: options,
      log: log,
      clock: Stopwatch()..start(),
      abort: abort,
      auth: authMode,
      apiVersion: argResults!['api-version'] as String,
    );
    final header = this.header(name);
    await withSigint(abort, log, run.run);

    run.printSummary(log);
    log.info('');
    await _writeWav(outPath, run, log);
    if (transcriptPath != null) {
      await _writeJson(transcriptPath, {...header, ...run.toJson()}, log);
    }
    return run.stayedUp ? exitOk : exitSessionFailed;
  }
}

// ---------------------------------------------------------------------------

class ConcurrencyCommand extends _LiveCommand {
  ConcurrencyCommand() {
    argParser
      ..addOption(
        'in',
        valueHelp: 'wav',
        help: 'Input WAV used for both sessions.',
      )
      ..addOption(
        'in-a',
        valueHelp: 'wav',
        help: 'Input for session A (overrides --in).',
      )
      ..addOption(
        'in-b',
        valueHelp: 'wav',
        help: 'Input for session B (overrides --in).',
      )
      ..addOption('target-a', allowed: ['en', 'vi'], defaultsTo: 'en')
      ..addOption('target-b', allowed: ['en', 'vi'], defaultsTo: 'vi')
      ..addOption(
        'stagger-ms',
        defaultsTo: '0',
        help: 'Delay before opening session B.',
      )
      ..addOption(
        'out-dir',
        valueHelp: 'dir',
        help:
            'Optional: save session_A/B audio + JSON and '
            'concurrency.json here.',
      );
    addCommonOptions();
  }

  @override
  String get name => 'concurrency';

  @override
  String get description =>
      'Open 2 Live Translate sessions at the same time (A: target en, '
      'B: target vi by default), stream audio into both, and report whether '
      'both stayed up or the exact close code/reason of the rejected one.';

  @override
  String get invocation =>
      '${runner!.executableName} concurrency --in <wav> [--in-b <wav>] '
      '[--min-seconds 60] [--out-dir <dir>]';

  @override
  Future<int> run() async {
    final log = Log(verbose: verbose);
    final common = argResults!['in'] as String?;
    final inA = (argResults!['in-a'] as String?) ?? common;
    final inB = (argResults!['in-b'] as String?) ?? common;
    if (inA == null || inB == null) {
      throw UsageException('give --in, or both --in-a and --in-b', usage);
    }
    final targetA = argResults!['target-a'] as String;
    final targetB = argResults!['target-b'] as String;
    final staggerMs = intOpt('stagger-ms');
    final outDir = argResults!['out-dir'] as String?;
    final options = probeOptions();

    final inputA = await loadInput(inA, log.child('[A] '));
    final inputB =
        inB == inA ? inputA : await loadInput(inB, log.child('[B] '));
    final apiKey = readApiKeyFromEnv();

    final clock = Stopwatch()..start();
    final abort = AbortFlag();
    ProbeRun make(String label, ProbeInput input, String target) => ProbeRun(
      label: label,
      input: input,
      setup: translateSetup(target),
      apiKey: apiKey,
      options: options,
      log: log.child('[$label] '),
      clock: clock,
      abort: abort,
      auth: authMode,
      apiVersion: argResults!['api-version'] as String,
    );
    final a = make('A', inputA, targetA);
    final b = make('B', inputB, targetB);
    final header = this.header(name);

    await withSigint(abort, log, () async {
      await Future.wait([
        a.run(),
        Future<void>.delayed(
          Duration(milliseconds: staggerMs),
        ).then((_) => b.run()),
      ]);
    });

    for (final r in [a, b]) {
      log.info('');
      log.info(
        '######## session ${r.label} (target ${r.setup.targetLanguageCode}) ########',
      );
      r.printSummary(log.child('[${r.label}] '));
    }

    final overlapMs = _overlapMs(a, b);
    log.info('');
    log.info('== concurrency verdict ==');
    for (final r in [a, b]) {
      log.info(
        'session ${r.label} (target ${r.setup.targetLanguageCode}): '
        '${r.stayedUp ? 'STAYED UP' : 'FAILED'}; setupComplete='
        '${r.session.setupOk}; audio ${(r.outputAudioMs / 1000).toStringAsFixed(2)} s; '
        'close ${r.closeSummary()}',
      );
    }
    log.info(
      'both sessions open simultaneously for: '
      '${overlapMs == null ? 'n/a' : '${(overlapMs / 1000).toStringAsFixed(1)} s'}',
    );
    final upCount = [a, b].where((r) => r.stayedUp).length;
    final String verdict;
    final int code;
    if (upCount == 2) {
      verdict = 'BOTH_OK: 2 concurrent sessions were accepted and stayed up.';
      code = exitOk;
    } else if (upCount == 1) {
      final failed = a.stayedUp ? b : a;
      verdict =
          'ONE_REJECTED: session ${failed.label} failed '
          '(${failed.closeSummary()}). The other stayed up.';
      code = exitSessionFailed;
    } else {
      verdict =
          'BOTH_FAILED: neither session stayed up — check the key / '
          'model first with the translate command.';
      code = exitAllFailed;
    }
    log.info('RESULT: $verdict');

    if (outDir != null) {
      log.info('');
      final dir = Directory(outDir);
      for (final r in [a, b]) {
        final base =
            '${dir.path}${Platform.pathSeparator}'
            'session_${r.label}_${r.setup.targetLanguageCode}';
        await _writeWav('$base.wav', r, log);
        await _writeJson('$base.json', {...header, ...r.toJson()}, log);
      }
      await _writeJson('${dir.path}${Platform.pathSeparator}concurrency.json', {
        ...header,
        'verdict': verdict,
        'overlapMs': overlapMs,
        'staggerMs': staggerMs,
        'sessions': [
          for (final r in [a, b])
            {
              'label': r.label,
              'target': r.setup.targetLanguageCode,
              'input': r.input.path,
              'stayedUp': r.stayedUp,
              'setupComplete': r.session.setupOk,
              'outputAudioMs': r.outputAudioMs,
              'timing': r.timing(),
              'close': r.closeSummary(),
              'closeCode': r.session.closeCode,
              'closeReason': r.session.closeReason,
              'httpStatusCode': r.session.httpStatusCode,
              'openError': r.session.openError,
              'goAway': r.goAways,
              'serverErrors': r.serverErrors,
            },
        ],
      }, log);
    }
    return code;
  }

  int? _overlapMs(ProbeRun a, ProbeRun b) {
    final sa = a.session.setupCompleteAtUs, sb = b.session.setupCompleteAtUs;
    final ea = a.session.closedAtUs, eb = b.session.closedAtUs;
    if (sa == null || sb == null || ea == null || eb == null) return null;
    final overlap = math.min(ea, eb) - math.max(sa, sb);
    return overlap <= 0 ? 0 : overlap ~/ 1000;
  }
}

// ---------------------------------------------------------------------------

class PrepareCommand extends Command<int> {
  PrepareCommand() {
    argParser
      ..addOption('in', valueHelp: 'wav', help: 'Input WAV.')
      ..addOption(
        'out',
        valueHelp: 'wav',
        help: 'Optional: write the 16 kHz mono PCM16 result.',
      )
      ..addOption('chunk-ms', defaultsTo: '100');
  }

  @override
  String get name => 'prepare';

  @override
  String get description =>
      'Offline (no API key): decode a WAV, downmix + resample to 16 kHz mono '
      'PCM16 exactly as the translate command would send it, print stats.';

  @override
  Future<int> run() async {
    final log = Log();
    final inPath = argResults!['in'] as String?;
    if (inPath == null) throw UsageException('missing --in', usage);
    final chunkMs = int.tryParse(argResults!['chunk-ms'] as String) ?? 0;
    if (chunkMs < 10) throw UsageException('--chunk-ms must be >= 10', usage);
    final ProbeInput input;
    try {
      input = await ProbeInput.load(inPath);
    } on FileSystemException catch (e) {
      throw InputException('${e.message}: ${e.path}');
    } on WavFormatException catch (e) {
      throw InputException('$inPath: ${e.message}');
    }
    final chunkSamples = inputSampleRate * chunkMs ~/ 1000;
    final chunks = splitIntoChunks(input.pcm16k, chunkSamples);
    String ms(int? samples) =>
        samples == null ? 'none' : '${samples * 1000 ~/ inputSampleRate} ms';
    log.info('input     : $inPath');
    log.info('original  : ${input.original.describe()}');
    log.info(
      'as sent   : $inputSampleRate Hz mono PCM16, ${input.durationMs} ms, '
      '${input.pcm16k.length} samples',
    );
    log.info(
      'chunks    : ${chunks.length} x $chunkMs ms '
      '($chunkSamples samples = ${chunkSamples * 2} bytes, '
      '~${(chunkSamples * 2 * 4 / 3).ceil()} chars base64 each)',
    );
    log.info(
      'speech    : onset ${ms(input.speechOnsetSample)}, '
      'end ${ms(input.speechEndSample)} (energy > -40 dBFS)',
    );
    final outPath = argResults!['out'] as String?;
    if (outPath != null) {
      await File(outPath).parent.create(recursive: true);
      await File(
        outPath,
      ).writeAsBytes(encodeWavPcm16(input.pcm16k, sampleRate: inputSampleRate));
      log.info('wrote $outPath');
    }
    return exitOk;
  }
}
