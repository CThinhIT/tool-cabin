import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:gemini_probe/src/probe_run.dart';
import 'package:gemini_probe/src/protocol.dart';
import 'package:gemini_probe/src/secrets.dart';
import 'package:gemini_probe/src/wav.dart';
import 'package:test/test.dart';

/// Local stand-in for the Live API: no network, no API key. It checks what
/// the client sends and replays server messages in the documented shapes.
class MockLiveServer {
  MockLiveServer(this.onConnection);

  final void Function(WebSocket ws, int index, HttpRequest request)
  onConnection;
  late HttpServer _server;
  int connections = 0;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}/ws/mock');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final index = connections++;
      final ws = await WebSocketTransformer.upgrade(req);
      onConnection(ws, index, req);
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// Google sends JSON in binary frames; mimic that.
void sendBinaryJson(WebSocket ws, Object json) =>
    ws.add(utf8.encode(jsonEncode(json)));

ProbeInput toneInput({int ms = 1000}) {
  final n = 16000 * ms ~/ 1000;
  final s = Int16List.fromList(
    List.generate(
      n,
      (i) => (0.3 * 32767 * math.sin(2 * math.pi * 300 * i / 16000)).round(),
    ),
  );
  return ProbeInput.fromDecoded(
    'tone.wav',
    decodeWav(encodeWavPcm16(s, sampleRate: 16000)),
  );
}

ProbeRun makeRun(
  Uri endpoint, {
  String label = 'T',
  String target = 'vi',
  AuthMode auth = AuthMode.header,
  Stopwatch? clock,
  ProbeInput? input,
  ProbeOptions options = const ProbeOptions(
    tailSilenceMs: 200,
    idleTimeoutMs: 500,
    maxWaitMs: 5000,
    setupTimeoutMs: 3000,
  ),
}) => ProbeRun(
  label: label,
  input: input ?? toneInput(),
  setup: TranslateSetup(targetLanguageCode: target),
  apiKey: 'test-key-123',
  options: options,
  log: Log(prefix: '[$label] '),
  clock: clock ?? (Stopwatch()..start()),
  abort: AbortFlag(),
  auth: auth,
  endpointOverride: endpoint,
);

void main() {
  test('happy path: setup shape, real-time 100 ms chunks, audio + transcripts, '
      'audioStreamEnd, GoAway, client close', () async {
    final received = <Map<String, dynamic>>[];
    String? keyHeader;
    var streamEnd = false;
    int? serverSeenCloseCode;
    final outAudio = Uint8List.fromList(List.generate(4800, (i) => i % 251));

    final server = MockLiveServer((ws, index, req) {
      keyHeader = req.headers.value('x-goog-api-key');
      var audioCount = 0;
      ws.listen((data) {
        final m = jsonDecode(data as String) as Map<String, dynamic>;
        received.add(m);
        if (m.containsKey('setup')) {
          sendBinaryJson(ws, {'setupComplete': {}});
          return;
        }
        final ri = m['realtimeInput'] as Map<String, dynamic>;
        if (ri['audioStreamEnd'] == true) {
          streamEnd = true;
          return;
        }
        audioCount++;
        if (audioCount == 3) {
          sendBinaryJson(ws, {
            'serverContent': {
              'inputTranscription': {'text': 'Hello', 'languageCode': 'en'},
            },
          });
        } else if (audioCount == 4) {
          sendBinaryJson(ws, {
            'serverContent': {
              'modelTurn': {
                'parts': [
                  {
                    'inlineData': {
                      'mimeType': 'audio/pcm;rate=24000',
                      'data': base64Encode(outAudio),
                    },
                  },
                ],
              },
            },
          });
          ws.add(
            jsonEncode({
              'serverContent': {
                'outputTranscription': {
                  'text': 'Xin chào',
                  'languageCode': 'vi',
                },
              },
            }),
          );
        } else if (audioCount == 6) {
          sendBinaryJson(ws, {
            'serverContent': {'generationComplete': true},
          });
          sendBinaryJson(ws, {
            'serverContent': {
              'turnComplete': true,
              'interactionStatus': 'IDLE',
            },
          });
          sendBinaryJson(ws, {
            'goAway': {'timeLeft': '5s'},
          });
        }
      }, onDone: () => serverSeenCloseCode = ws.closeCode);
    });
    await server.start();
    addTearDown(server.stop);

    final run = makeRun(server.uri);
    await run.run();

    // Setup message
    expect(keyHeader, 'test-key-123');
    final setup = received.first['setup'] as Map<String, dynamic>;
    expect(setup['model'], 'models/gemini-3.5-live-translate-preview');
    expect(setup['generationConfig']['translationConfig'], {
      'targetLanguageCode': 'vi',
      'echoTargetLanguage': false,
    });
    expect(setup['inputAudioTranscription'], isEmpty);

    // Audio: 1000 ms file + 200 ms tail = 12 chunks of 3200 bytes.
    final audioMsgs =
        received
            .where((m) => (m['realtimeInput'] as Map?)?['audio'] != null)
            .map((m) => m['realtimeInput']['audio'] as Map)
            .toList();
    expect(audioMsgs.length, 12);
    expect(
      audioMsgs.every((a) => a['mimeType'] == 'audio/pcm;rate=16000'),
      isTrue,
    );
    expect(
      audioMsgs.every((a) => base64Decode(a['data'] as String).length == 3200),
      isTrue,
    );
    expect(
      base64Decode(audioMsgs.first['data'] as String),
      orderedEquals(
        pcm16ToBytesLE(Int16List.sublistView(run.input.pcm16k, 0, 1600)),
      ),
    );
    // Tail chunk is silence.
    expect(
      base64Decode(audioMsgs.last['data'] as String).every((b) => b == 0),
      isTrue,
    );
    expect(streamEnd, isTrue);

    // Real-time pacing: the 12th chunk cannot leave before 1.2 s of mic time.
    expect(
      (run.inputEndUs! - run.micStartUs!) / 1000,
      greaterThanOrEqualTo(1190),
    );

    // Output
    expect(run.outputAudio.toBytes(), orderedEquals(outAudio));
    expect(run.outputSampleRate, 24000);
    expect(run.outputAudioMs, 100);
    expect(run.inputText.toString(), 'Hello');
    expect(run.outputText.toString(), 'Xin chào');
    expect(run.goAways.single['timeLeft'], '5s');

    final t = run.timing();
    // First audio was triggered by chunk 4, i.e. ~300 ms after chunk 1.
    expect(
      t['firstChunkSentToFirstAudioMs'] as int,
      inInclusiveRange(250, 1000),
    );
    expect(
      t['firstInputTranscriptToFirstAudioMs'] as int,
      greaterThanOrEqualTo(50),
    );
    expect(t['speechOnsetToFirstAudioMs'], isNotNull);

    expect(run.segments.length, 1);
    final seg = run.segmentsJson().single;
    expect(seg['inputText'], 'Hello');
    expect(seg['outputText'], 'Xin chào');
    expect(seg['turnCompleteMs'], isNotNull);

    // Session
    expect(run.session.setupOk, isTrue);
    expect(run.stayedUp, isTrue);
    expect(run.closedBy, 'client');
    expect(run.session.closeCode, 1000);
    expect(serverSeenCloseCode, 1000);
    expect(run.endReason, startsWith('idle'));
    expect(run.messageCounts['serverContent.modelTurn'], 1);

    final json = jsonEncode(run.toJson());
    expect(json, isNot(contains('test-key-123')));
  });

  test(
    'server rejects at setup (e.g. quota) -> exact close code and reason',
    () async {
      final server = MockLiveServer((ws, index, req) {
        ws.listen((data) {
          ws.close(1011, 'Resource has been exhausted (e.g. check quota).');
        });
      });
      await server.start();
      addTearDown(server.stop);

      final run = makeRun(server.uri);
      await run.run();
      expect(run.session.setupOk, isFalse);
      expect(run.stayedUp, isFalse);
      expect(run.session.closeCode, 1011);
      expect(
        run.session.closeReason,
        'Resource has been exhausted (e.g. check quota).',
      );
      expect(run.closePhase, 'setup');
      expect(run.closedBy, 'server');
      expect(run.endReason, 'setup-failed');
      expect(run.chunksSent, 0);
    },
  );

  test('server closes mid-stream -> streaming phase, not stayed up', () async {
    final server = MockLiveServer((ws, index, req) {
      var n = 0;
      ws.listen((data) {
        final m = jsonDecode(data as String) as Map;
        if (m.containsKey('setup')) {
          sendBinaryJson(ws, {'setupComplete': {}});
        } else if (++n == 3) {
          ws.close(
            1008,
            'Operation is not implemented, or supported, or enabled.',
          );
        }
      });
    });
    await server.start();
    addTearDown(server.stop);

    final run = makeRun(server.uri);
    await run.run();
    expect(run.session.setupOk, isTrue);
    expect(run.stayedUp, isFalse);
    expect(run.closePhase, 'streaming');
    expect(run.session.closeCode, 1008);
    expect(run.endReason, 'server-closed while streaming');
    expect(run.chunksSent, lessThan(12));
  });

  test(
    'two concurrent sessions, second rejected (concurrency command shape)',
    () async {
      final server = MockLiveServer((ws, index, req) {
        ws.listen((data) {
          final m = jsonDecode(data as String) as Map;
          if (!m.containsKey('setup')) return;
          if (index == 0) {
            sendBinaryJson(ws, {'setupComplete': {}});
          } else {
            ws.close(1011, 'Too many concurrent sessions');
          }
        });
      });
      await server.start();
      addTearDown(server.stop);

      final clock = Stopwatch()..start();
      final a = makeRun(server.uri, label: 'A', target: 'en', clock: clock);
      final b = makeRun(server.uri, label: 'B', target: 'vi', clock: clock);
      await Future.wait([
        a.run(),
        Future<void>.delayed(
          const Duration(milliseconds: 50),
        ).then((_) => b.run()),
      ]);
      expect(a.stayedUp, isTrue);
      expect(b.stayedUp, isFalse);
      expect(b.session.closeCode, 1011);
      expect(b.session.closeReason, 'Too many concurrent sessions');
    },
  );

  test(
    'handshake rejected with HTTP 403 (query auth) -> status kept, key redacted',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? keyParam;
      server.listen((req) {
        keyParam = req.uri.queryParameters['key'];
        req.response.statusCode = HttpStatus.forbidden;
        req.response.close();
      });
      final run = makeRun(
        Uri.parse('ws://127.0.0.1:${server.port}/ws/mock'),
        auth: AuthMode.query,
      );
      await run.run();
      expect(keyParam, 'test-key-123');
      expect(run.session.setupOk, isFalse);
      expect(run.session.httpStatusCode, 403);
      expect(run.session.openError, isNotNull);
      final redacted = Redactor.global.redact(jsonEncode(run.toJson()));
      expect(redacted, isNot(contains('test-key-123')));
    },
  );
}
