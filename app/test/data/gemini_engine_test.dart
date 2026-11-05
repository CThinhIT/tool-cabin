import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trans_app/data/engines/gemini/gemini_live_translate_engine.dart';
import 'package:trans_app/domain/translation_engine.dart';

/// A local stand-in for the Live API endpoint.
class FakeLiveServer {
  late HttpServer _http;
  final List<FakeConnection> connections = [];
  final StreamController<FakeConnection> _connected = StreamController.broadcast();

  /// What a new connection does after receiving `setup`.
  void Function(FakeConnection c) onSetup = (c) => c.send({'setupComplete': {}});

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}/ws');

  Future<FakeConnection> nextConnection() => _connected.stream.first;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen((req) async {
      final key = req.headers.value('x-goog-api-key');
      final ws = await WebSocketTransformer.upgrade(req);
      final c = FakeConnection(ws, key);
      connections.add(c);
      _connected.add(c);
      ws.listen((data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        c.received.add(msg);
        if (msg.containsKey('setup')) onSetup(c);
      });
    });
  }

  Future<void> close() async {
    for (final c in connections) {
      await c.ws.close();
    }
    await _http.close(force: true);
  }
}

class FakeConnection {
  FakeConnection(this.ws, this.apiKeyHeader);
  final WebSocket ws;
  final String? apiKeyHeader;
  final List<Map<String, dynamic>> received = [];

  void send(Object json) => ws.add(jsonEncode(json));

  List<String> get audioPayloads => [
    for (final m in received)
      if (m['realtimeInput'] case {'audio': {'data': final String d}}) d,
  ];
}

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeLiveServer server;
  var clock = 0;

  GeminiLiveTranslateEngine engine({
    Duration setupTimeout = const Duration(seconds: 5),
    int maxReconnects = 3,
  }) => GeminiLiveTranslateEngine(
    GeminiConfig(
      apiKey: 'test-key',
      endpointOverride: server.uri,
      setupTimeout: setupTimeout,
      maxReconnectAttempts: maxReconnects,
      reconnectDelay: const Duration(milliseconds: 20),
    ),
    clockUs: () => clock += 1000,
  );

  setUp(() async {
    server = FakeLiveServer();
    await server.start();
  });

  tearDown(() => server.close());

  test('sends the setup with the API key header and becomes ready', () async {
    final e = engine();
    final statuses = <EngineStatus>[];
    e.events.listen((ev) {
      if (ev is EngineStatusChanged) statuses.add(ev.status);
    });
    await e.start(sourceLanguage: 'en', targetLanguage: 'vi');
    expect(e.status, EngineStatus.ready);
    final c = server.connections.single;
    expect(c.apiKeyHeader, 'test-key');
    final setup = c.received.first['setup'] as Map;
    expect(
      (setup['generationConfig'] as Map)['translationConfig'],
      {'targetLanguageCode': 'vi', 'echoTargetLanguage': false},
    );
    await e.stop();
    expect(statuses, [EngineStatus.connecting, EngineStatus.ready, EngineStatus.closed]);
  });

  test('streams audio and maps server content to events', () async {
    final e = engine();
    final events = <EngineEvent>[];
    e.events.listen(events.add);
    await e.start(sourceLanguage: 'en', targetLanguage: 'vi');
    final c = server.connections.single;

    final frame = Uint8List.fromList(List.generate(3200, (i) => i & 0xff));
    e.sendAudio(frame);
    e.sendAudio(frame);
    await until(() => c.audioPayloads.length == 2);
    expect(base64Decode(c.audioPayloads.first), frame);
    expect(e.framesSent, 2);

    final out = Uint8List.fromList([9, 8, 7, 6]);
    c.send({
      'serverContent': {
        'interimInputTranscription': {'text': 'Hel'},
        'inputTranscription': {'text': 'Hello', 'languageCode': 'en'},
      },
    });
    c.send({
      'serverContent': {
        'modelTurn': {
          'parts': [
            {'inlineData': {'data': base64Encode(out), 'mimeType': 'audio/pcm;rate=24000'}},
          ],
        },
        'outputTranscription': {'text': 'Xin chào'},
      },
    });
    c.send({'serverContent': {'turnComplete': true}});
    await until(() => events.whereType<TurnComplete>().isNotEmpty);

    final content = events.where((ev) => ev is! EngineStatusChanged).toList();
    expect(content[0], isA<SourceTranscript>().having((s) => s.interim, 'interim', isTrue));
    expect(
      content[1],
      isA<SourceTranscript>()
          .having((s) => s.text, 'text', 'Hello')
          .having((s) => s.languageCode, 'lang', 'en'),
    );
    expect(content[2], isA<TranslatedAudio>().having((a) => a.pcm, 'pcm', out));
    expect(content[3], isA<TranslatedTranscript>().having((t) => t.text, 'text', 'Xin chào'));
    expect(content[4], isA<TurnComplete>());
    await e.stop();
  });

  test('a rejected key (close 1007 before setupComplete) fails start with a hint', () async {
    server.onSetup = (c) => c.ws.close(1007, 'API key not valid');
    final e = engine();
    await expectLater(
      e.start(sourceLanguage: 'vi', targetLanguage: 'en'),
      throwsA(
        isA<EngineException>().having((x) => x.message, 'message', allOf(contains('1007'), contains('API key'))),
      ),
    );
    expect(e.status, EngineStatus.failed);
    expect(server.connections, hasLength(1)); // no retry on the first connect
    await e.stop();
  });

  test('no setupComplete within the timeout fails start', () async {
    server.onSetup = (_) {};
    final e = engine(setupTimeout: const Duration(milliseconds: 200));
    await expectLater(
      e.start(sourceLanguage: 'vi', targetLanguage: 'en'),
      throwsA(isA<EngineException>()),
    );
    await e.stop();
  });

  test('reconnects after a drop and replays audio captured meanwhile', () async {
    final e = engine();
    final statuses = <EngineStatus>[];
    e.events.listen((ev) {
      if (ev is EngineStatusChanged) statuses.add(ev.status);
    });
    await e.start(sourceLanguage: 'en', targetLanguage: 'vi');

    // Hold the next setupComplete until we have queued some audio.
    late FakeConnection second;
    final secondArrived = Completer<void>();
    server.onSetup = (c) {
      second = c;
      secondArrived.complete();
    };
    await server.connections.single.ws.close(1011, 'internal');
    await until(() => e.status == EngineStatus.reconnecting);
    e.sendAudio(Uint8List.fromList([1, 1]));
    e.sendAudio(Uint8List.fromList([2, 2]));
    await secondArrived.future;
    second.send({'setupComplete': {}});
    await until(() => second.audioPayloads.length == 2);

    expect(e.status, EngineStatus.ready);
    expect(second.audioPayloads.map(base64Decode), [
      [1, 1],
      [2, 2],
    ]);
    expect(statuses, containsAllInOrder([EngineStatus.ready, EngineStatus.reconnecting, EngineStatus.ready]));
    await e.stop();
  });

  test('gives up after maxReconnectAttempts and reports failed', () async {
    final e = engine(maxReconnects: 2);
    String? failure;
    e.events.listen((ev) {
      if (ev is EngineStatusChanged && ev.status == EngineStatus.failed) failure = ev.message;
    });
    await e.start(sourceLanguage: 'en', targetLanguage: 'vi');
    server.onSetup = (c) => c.ws.close(1011, 'quota');
    await server.connections.single.ws.close(1011, 'quota');
    await until(() => e.status == EngineStatus.failed);
    expect(server.connections, hasLength(3)); // first + 2 attempts
    expect(failure, contains('1011'));
    await e.stop();
  });

  test('stop closes the socket and the event stream', () async {
    final e = engine();
    await e.start(sourceLanguage: 'en', targetLanguage: 'vi');
    final done = e.events.toList();
    await e.stop();
    await done; // completes because the stream closed
    expect(e.status, EngineStatus.closed);
    e.sendAudio(Uint8List(2)); // ignored, no throw
    await expectLater(
      e.start(sourceLanguage: 'en', targetLanguage: 'vi'),
      throwsStateError,
    );
  });
}
