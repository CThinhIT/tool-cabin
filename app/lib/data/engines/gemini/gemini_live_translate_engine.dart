import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../../domain/translation_engine.dart';
import 'gemini_protocol.dart';

class GeminiConfig {
  const GeminiConfig({
    required this.apiKey,
    this.model = defaultGeminiModel,
    this.placement = TranscriptionPlacement.setup,
    this.apiVersion = defaultGeminiApiVersion,
    this.endpointOverride,
    this.connectTimeout = const Duration(seconds: 10),
    this.setupTimeout = const Duration(seconds: 15),
    this.maxReconnectAttempts = 5,
    this.reconnectDelay = const Duration(seconds: 1),
  });

  final String apiKey;
  final String model;
  final TranscriptionPlacement placement;
  final String apiVersion;

  /// Tests only: connect here instead of Google.
  final Uri? endpointOverride;
  final Duration connectTimeout;
  final Duration setupTimeout;

  /// Consecutive failed reconnects before giving up ([EngineStatus.failed]).
  final int maxReconnectAttempts;

  /// Base delay; attempt n waits n x this.
  final Duration reconnectDelay;
}

/// Gemini Live Translate over a raw WebSocket (ARCHITECTURE.md 6.4).
///
/// The source language is detected by the model; only the target is set.
/// If the connection drops after the session was ready (network, server
/// GoAway, session time limit), a new session is opened and up to 5 s of
/// audio captured meanwhile is replayed. Seamless resumption before the
/// time limit is Phase 3.
class GeminiLiveTranslateEngine implements TranslationEngine {
  GeminiLiveTranslateEngine(
    this.config, {
    required int Function() clockUs,
    Logger? logger,
  }) : _clockUs = clockUs,
       _log = logger ?? Logger('gemini');

  final GeminiConfig config;
  final int Function() _clockUs;
  final Logger _log;

  static const _maxPendingFrames = 50; // 5 s of 100 ms frames
  static const _stableUptimeUs = 60 * 1000000;

  final StreamController<EngineEvent> _events = StreamController.broadcast();
  final Queue<Uint8List> _pending = Queue();

  EngineStatus _status = EngineStatus.idle;
  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;
  Completer<void>? _setupDone;
  String _target = '';
  bool _stopping = false;
  int _failedReconnects = 0;
  int _readyAtUs = 0;
  bool _warnedRate = false;

  /// Audio frames sent since start (for stats).
  int framesSent = 0;

  @override
  String get name => 'Gemini Live Translate (${config.model})';

  @override
  EngineStatus get status => _status;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Future<void> start({
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    if (_status != EngineStatus.idle) {
      throw StateError('A Gemini session can be started only once');
    }
    _target = targetLanguage;
    _setStatus(EngineStatus.connecting);
    try {
      await _connect();
    } on EngineException catch (e) {
      _setStatus(EngineStatus.failed, e.message);
      rethrow;
    }
  }

  @override
  void sendAudio(Uint8List pcm) {
    if (_stopping) return;
    final ws = _ws;
    if (_status == EngineStatus.ready && ws != null) {
      try {
        ws.add(jsonEncode(realtimeAudioMessage(pcm)));
        framesSent++;
      } catch (e) {
        _log.warning('[$_target] send failed: $e');
      }
    } else if (_status == EngineStatus.reconnecting) {
      _pending.add(pcm);
      while (_pending.length > _maxPendingFrames) {
        _pending.removeFirst();
      }
    }
  }

  @override
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    final setupDone = _setupDone;
    if (setupDone != null && !setupDone.isCompleted) {
      setupDone.completeError(const EngineException('Đã dừng'));
    }
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      try {
        await ws.close(1000, 'stopped').timeout(const Duration(seconds: 3));
      } catch (e) {
        _log.fine('[$_target] close: $e');
      }
    }
    await _sub?.cancel();
    _sub = null;
    _pending.clear();
    _setStatus(EngineStatus.closed);
    await _events.close();
  }

  Future<void> _connect() async {
    final uri =
        config.endpointOverride ??
        geminiLiveEndpoint(apiVersion: config.apiVersion);
    WebSocket ws;
    try {
      ws = await WebSocket.connect(
        uri.toString(),
        headers: {'x-goog-api-key': config.apiKey},
      ).timeout(config.connectTimeout);
    } on WebSocketException catch (e) {
      final http = e.httpStatusCode == null ? '' : ' (HTTP ${e.httpStatusCode})';
      throw EngineException('Không kết nối được Gemini: ${e.message}$http');
    } on TimeoutException {
      throw EngineException(
        'Không kết nối được Gemini trong ${config.connectTimeout.inSeconds} giây',
      );
    } on Object catch (e) {
      throw EngineException('Không kết nối được Gemini: $e');
    }
    if (_stopping) {
      unawaited(ws.close(1000));
      return;
    }

    final setupDone = Completer<void>();
    _setupDone = setupDone;
    _ws = ws;
    await _sub?.cancel();
    _sub = ws.listen(
      _onData,
      onError: (Object e) => _log.warning('[$_target] socket error: $e'),
      onDone: () => _onClosed(ws),
      cancelOnError: false,
    );
    ws.add(
      jsonEncode(
        TranslateSetup(
          model: config.model,
          targetLanguageCode: _target,
          placement: config.placement,
        ).toMessage(),
      ),
    );

    try {
      await setupDone.future.timeout(config.setupTimeout);
    } on TimeoutException {
      _ws = null;
      unawaited(ws.close(1000));
      throw EngineException(
        'Gemini không trả setupComplete trong ${config.setupTimeout.inSeconds} giây',
      );
    }
    _readyAtUs = _clockUs();
    _setStatus(EngineStatus.ready);
    _log.info('[$_target] session ready (${config.model})');

    while (_pending.isNotEmpty && _ws != null) {
      sendAudio(_pending.removeFirst());
    }
  }

  void _onData(dynamic data) {
    final at = _clockUs();
    final String text;
    if (data is String) {
      text = data;
    } else if (data is List<int>) {
      text = utf8.decode(data, allowMalformed: true);
    } else {
      return;
    }
    final GeminiServerMessage msg;
    try {
      msg = GeminiServerMessage.parse(jsonDecode(text));
    } catch (_) {
      _log.warning('[$_target] non-JSON frame (${text.length} chars)');
      return;
    }

    if (msg.setupComplete) {
      final done = _setupDone;
      if (done != null && !done.isCompleted) done.complete();
    }
    if (msg.error != null) _log.warning('[$_target] server error: ${msg.error}');
    if (msg.goAway) {
      _log.info('[$_target] goAway, time left ${msg.goAwayTimeLeft}');
    }
    if (_events.isClosed) return;

    for (final chunk in msg.audio) {
      final rate = chunk.sampleRate ?? geminiOutputRate;
      if (rate != geminiOutputRate && !_warnedRate) {
        _warnedRate = true;
        _log.warning('[$_target] unexpected output rate $rate Hz');
      }
      _events.add(TranslatedAudio(at, chunk.bytes, rate));
    }
    final interim = msg.interimInputTranscription;
    if (interim != null) {
      _events.add(
        SourceTranscript(
          at,
          interim.text,
          languageCode: interim.languageCode,
          interim: true,
        ),
      );
    }
    final input = msg.inputTranscription;
    if (input != null && input.text.isNotEmpty) {
      _events.add(
        SourceTranscript(at, input.text, languageCode: input.languageCode),
      );
    }
    final output = msg.outputTranscription;
    if (output != null && output.text.isNotEmpty) {
      _events.add(TranslatedTranscript(at, output.text));
    }
    if (msg.turnComplete) _events.add(TurnComplete(at));
  }

  void _onClosed(WebSocket ws) {
    if (!identical(ws, _ws)) return; // an old socket, or stop() was called
    _ws = null;
    final why =
        '${ws.closeCode ?? '-'} ${geminiCloseHint(ws.closeCode)}'
        '${(ws.closeReason ?? '').isEmpty ? '' : ': ${ws.closeReason}'}';
    final setupDone = _setupDone;
    if (setupDone != null && !setupDone.isCompleted) {
      setupDone.completeError(EngineException('Gemini đóng kết nối: $why'));
      return; // _connect() reports it
    }
    if (_stopping) return;
    _log.warning('[$_target] connection closed: $why');
    unawaited(_reconnect(why));
  }

  Future<void> _reconnect(String why) async {
    if (_clockUs() - _readyAtUs > _stableUptimeUs) _failedReconnects = 0;
    var reason = why;
    while (!_stopping) {
      if (_failedReconnects >= config.maxReconnectAttempts) {
        _setStatus(EngineStatus.failed, 'Mất kết nối Gemini: $reason');
        return;
      }
      _failedReconnects++;
      _setStatus(EngineStatus.reconnecting, reason);
      await Future<void>.delayed(config.reconnectDelay * _failedReconnects);
      if (_stopping) return;
      try {
        await _connect();
        return;
      } on EngineException catch (e) {
        reason = e.message;
        _log.warning('[$_target] reconnect $_failedReconnects failed: $reason');
      }
    }
  }

  void _setStatus(EngineStatus s, [String? message]) {
    if (_status == s) return;
    _status = s;
    if (!_events.isClosed) {
      _events.add(EngineStatusChanged(_clockUs(), s, message));
    }
  }
}
