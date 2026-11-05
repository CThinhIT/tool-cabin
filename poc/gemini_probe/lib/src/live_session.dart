import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';
import 'secrets.dart';

/// One raw WebSocket connection to the Live API (BidiGenerateContent).
///
/// All timestamps are microseconds on the shared [clock].
class LiveSession {
  LiveSession({
    required this.setup,
    required this.apiKey,
    required this.clock,
    required this.log,
    this.auth = AuthMode.header,
    this.apiVersion = defaultApiVersion,
    this.endpointOverride,
  });

  /// Tests only: connect here instead of the Google endpoint.
  final Uri? endpointOverride;

  final TranslateSetup setup;
  final String apiKey;
  final Stopwatch clock;
  final Log log;
  final AuthMode auth;
  final String apiVersion;

  /// Called for every parsed server message, with its arrival time.
  void Function(ServerMessage message, int atUs)? onMessage;

  WebSocket? _ws;
  final Completer<void> _setupComplete = Completer<void>();
  final Completer<void> _done = Completer<void>();

  int? connectStartUs;
  int? connectedAtUs;
  int? setupSentAtUs;
  int? setupCompleteAtUs;
  int? closedAtUs;
  int? closeCode;
  String? closeReason;
  bool closeInitiatedByClient = false;

  /// Failure before/while opening (handshake rejected, DNS, TLS, token...).
  String? openError;
  int? httpStatusCode;

  /// Errors on an open socket (stream errors, unparsable frames).
  final List<String> errors = [];

  /// The endpoint actually used, without credentials.
  String? endpointForReport;

  bool get isOpen => _ws != null && closedAtUs == null;
  bool get setupOk => setupCompleteAtUs != null;
  Future<void> get done => _done.future;

  int get _now => clock.elapsedMicroseconds;

  /// Connects, sends the setup message and waits for `setupComplete`.
  /// Returns true if setup completed.
  Future<bool> open({
    Duration setupTimeout = const Duration(seconds: 15),
  }) async {
    connectStartUs = _now;
    final headers = <String, Object>{};
    Uri uri;
    final base = endpointOverride;
    try {
      switch (auth) {
        case AuthMode.header:
          uri = base ?? liveEndpoint(apiVersion: apiVersion);
          headers['x-goog-api-key'] = apiKey;
        case AuthMode.query:
          uri =
              base?.replace(queryParameters: {'key': apiKey}) ??
              liveEndpoint(
                apiVersion: apiVersion,
                queryParameters: {'key': apiKey},
              );
        case AuthMode.ephemeral:
          final token = await _createEphemeralToken();
          uri = liveEndpoint(apiVersion: apiVersion, constrained: true);
          headers['Authorization'] = 'Token $token';
      }
    } catch (e) {
      openError = 'ephemeral token creation failed: $e';
      _finish();
      return false;
    }
    endpointForReport =
        Uri(scheme: uri.scheme, host: uri.host, path: uri.path).toString();
    log.debug('connecting to $endpointForReport (auth=${auth.name})');

    try {
      _ws = await WebSocket.connect(uri.toString(), headers: headers);
    } on WebSocketException catch (e) {
      httpStatusCode = e.httpStatusCode;
      openError =
          'WebSocket handshake failed: ${e.message}'
          '${e.httpStatusCode != null ? ' (HTTP ${e.httpStatusCode})' : ''}';
      _finish();
      return false;
    } on Object catch (e) {
      openError = 'connect failed: $e';
      _finish();
      return false;
    }
    connectedAtUs = _now;

    _ws!.listen(
      _onData,
      onError: (Object e) => errors.add('socket error: $e'),
      onDone: () {
        closeCode = _ws!.closeCode;
        closeReason = _ws!.closeReason;
        _finish();
      },
      cancelOnError: false,
    );

    final setupMessage = setup.toMessage();
    log.debug('send setup ${jsonEncode(setupMessage)}');
    _sendJson(setupMessage);
    setupSentAtUs = _now;

    await Future.any<void>([
      _setupComplete.future,
      _done.future,
      Future<void>.delayed(setupTimeout),
    ]);
    if (!setupOk && isOpen) {
      errors.add('no setupComplete within ${setupTimeout.inSeconds}s');
    }
    return setupOk;
  }

  void sendAudio(Uint8List pcm16le) {
    if (!isOpen) return;
    _sendJson(realtimeAudioMessage(pcm16le));
  }

  void sendAudioStreamEnd() {
    if (!isOpen) return;
    log.debug('send realtimeInput.audioStreamEnd');
    _sendJson(audioStreamEndMessage());
  }

  Future<void> close({int code = 1000, String reason = 'probe done'}) async {
    final ws = _ws;
    if (ws == null) {
      _finish();
      return;
    }
    if (closedAtUs == null) {
      closeInitiatedByClient = true;
      try {
        await ws.close(code, reason).timeout(const Duration(seconds: 5));
      } catch (e) {
        errors.add('close failed: $e');
      }
    }
    await done.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        closeCode ??= ws.closeCode;
        closeReason ??= ws.closeReason;
        _finish();
      },
    );
  }

  void _sendJson(Map<String, Object?> message) {
    try {
      _ws!.add(jsonEncode(message));
    } catch (e) {
      errors.add('send failed: $e');
    }
  }

  void _onData(dynamic data) {
    final at = _now;
    String text;
    if (data is String) {
      text = data;
    } else if (data is List<int>) {
      text = utf8.decode(data, allowMalformed: true);
    } else {
      errors.add('unexpected frame type ${data.runtimeType}');
      return;
    }
    Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      final preview = text.length > 200 ? '${text.substring(0, 200)}...' : text;
      errors.add('non-JSON frame: $preview');
      log.warn('non-JSON frame from server: $preview');
      return;
    }
    final msg = ServerMessage.parse(json);
    if (msg.setupComplete && !_setupComplete.isCompleted) {
      setupCompleteAtUs = at;
      _setupComplete.complete();
    }
    onMessage?.call(msg, at);
  }

  void _finish() {
    closedAtUs ??= _now;
    if (!_done.isCompleted) _done.complete();
  }

  Future<String> _createEphemeralToken() async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        authTokensEndpoint(apiVersion: apiVersion),
      );
      req.headers.set('x-goog-api-key', apiKey);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(ephemeralTokenRequest(DateTime.now().toUtc())));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        var detail = body.trim();
        try {
          final err = (jsonDecode(body) as Map)['error'] as Map;
          detail = '${err['status']}: ${err['message']}';
        } catch (_) {
          if (detail.length > 300) detail = '${detail.substring(0, 300)}...';
        }
        throw HttpException(
          'POST auth_tokens -> HTTP ${resp.statusCode} $detail',
        );
      }
      final name = (jsonDecode(body) as Map)['name'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('auth_tokens response has no "name"');
      }
      Redactor.global.addSecret(name);
      log.debug('ephemeral token created (length ${name.length})');
      return name;
    } finally {
      client.close(force: true);
    }
  }
}
