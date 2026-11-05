import 'dart:convert';
import 'dart:typed_data';

/// Gemini Live API (WebSocket, BidiGenerateContent) protocol pieces used by
/// the probe. Field names follow the official docs (verified 2026-11-04):
///  - https://aistudio.google.com/docs/live-api/live-translate
///  - https://aistudio.google.com/api-reference/live
///  - https://aistudio.google.com/api-reference/live/bidi-generate-content

const defaultModel = 'gemini-3.5-live-translate-preview';
const defaultApiVersion = 'v1beta';
const liveHost = 'generativelanguage.googleapis.com';

/// Input: raw 16-bit PCM, 16 kHz, mono, little-endian.
const inputSampleRate = 16000;

/// Output: raw 16-bit PCM, 24 kHz, mono, little-endian.
const defaultOutputSampleRate = 24000;

enum AuthMode {
  /// API key in the `x-goog-api-key` handshake header (what the official
  /// python-genai SDK does). Keeps the key out of URLs.
  header,

  /// API key in the `?key=` query parameter (what the WebSocket docs show).
  query,

  /// Create an ephemeral token via `POST /v1beta/auth_tokens`, then connect
  /// to `BidiGenerateContentConstrained` with `Authorization: Token <t>`.
  ephemeral,
}

/// Where to put `inputAudioTranscription` / `outputAudioTranscription`.
enum TranscriptionPlacement {
  /// Top level of `setup` — API reference (BidiGenerateContentSetup) and the
  /// python-genai SDK converter. Default.
  setup,

  /// Inside `setup.generationConfig` — as shown in the Live Translate guide's
  /// raw WebSocket example.
  generationConfig,
}

Uri liveEndpoint({
  String apiVersion = defaultApiVersion,
  bool constrained = false,
  Map<String, String>? queryParameters,
}) {
  final method =
      constrained ? 'BidiGenerateContentConstrained' : 'BidiGenerateContent';
  return Uri(
    scheme: 'wss',
    host: liveHost,
    path:
        '/ws/google.ai.generativelanguage.$apiVersion'
        '.GenerativeService.$method',
    queryParameters:
        (queryParameters == null || queryParameters.isEmpty)
            ? null
            : queryParameters,
  );
}

Uri authTokensEndpoint({String apiVersion = defaultApiVersion}) =>
    Uri.https(liveHost, '/$apiVersion/auth_tokens');

class TranslateSetup {
  const TranslateSetup({
    this.model = defaultModel,
    required this.targetLanguageCode,
    this.echoTargetLanguage = false,
    this.inputTranscription = true,
    this.outputTranscription = true,
    this.placement = TranscriptionPlacement.setup,
    this.sessionResumption = false,
  });

  final String model;
  final String targetLanguageCode;
  final bool echoTargetLanguage;
  final bool inputTranscription;
  final bool outputTranscription;
  final TranscriptionPlacement placement;
  final bool sessionResumption;

  /// The first client message: `{"setup": BidiGenerateContentSetup}`.
  Map<String, Object?> toMessage() {
    final generationConfig = <String, Object?>{
      'responseModalities': ['AUDIO'],
      'translationConfig': {
        'targetLanguageCode': targetLanguageCode,
        'echoTargetLanguage': echoTargetLanguage,
      },
    };
    final setup = <String, Object?>{
      'model': model.startsWith('models/') ? model : 'models/$model',
      'generationConfig': generationConfig,
    };
    final transcriptionHost =
        placement == TranscriptionPlacement.setup ? setup : generationConfig;
    if (inputTranscription) {
      transcriptionHost['inputAudioTranscription'] = <String, Object?>{};
    }
    if (outputTranscription) {
      transcriptionHost['outputAudioTranscription'] = <String, Object?>{};
    }
    if (sessionResumption) {
      setup['sessionResumption'] = <String, Object?>{};
    }
    return {'setup': setup};
  }
}

/// `{"realtimeInput": {"audio": {"data": <b64>, "mimeType": "audio/pcm;rate=16000"}}}`
Map<String, Object?> realtimeAudioMessage(
  Uint8List pcm16le, {
  int sampleRate = inputSampleRate,
}) => {
  'realtimeInput': {
    'audio': {
      'data': base64Encode(pcm16le),
      'mimeType': 'audio/pcm;rate=$sampleRate',
    },
  },
};

/// `{"realtimeInput": {"audioStreamEnd": true}}` — documented as the way to
/// flush cached audio when the stream pauses for more than ~1 s.
Map<String, Object?> audioStreamEndMessage() => {
  'realtimeInput': {'audioStreamEnd': true},
};

/// Body for `POST /v1beta/auth_tokens` (unconstrained token: the setup sent
/// over the WebSocket is used as-is).
Map<String, Object?> ephemeralTokenRequest(DateTime nowUtc) => {
  'uses': 1,
  'expireTime':
      nowUtc.add(const Duration(minutes: 30)).toUtc().toIso8601String(),
  'newSessionExpireTime':
      nowUtc.add(const Duration(minutes: 1)).toUtc().toIso8601String(),
};

// ---------------------------------------------------------------------------
// Server messages
// ---------------------------------------------------------------------------

class Transcription {
  Transcription({required this.text, this.languageCode});
  final String text;
  final String? languageCode;

  static Transcription? parse(Object? o) {
    if (o is! Map) return null;
    return Transcription(
      text: (o['text'] as String?) ?? '',
      languageCode: o['languageCode'] as String?,
    );
  }
}

class AudioChunk {
  AudioChunk(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;

  /// Parses `rate=NNNN` out of e.g. `audio/pcm;rate=24000`.
  int? get sampleRate {
    final m = RegExp(r'rate=(\d+)').firstMatch(mimeType);
    return m == null ? null : int.parse(m.group(1)!);
  }
}

class ServerContent {
  final List<AudioChunk> audio = [];
  final List<String> texts = [];
  Transcription? inputTranscription;
  Transcription? interimInputTranscription;
  Transcription? outputTranscription;
  bool generationComplete = false;
  bool turnComplete = false;
  bool interrupted = false;
  bool waitingForInput = false;
  String? interactionStatus;
  final List<String> keys = [];
}

/// One `BidiGenerateContentServerMessage`. The `messageType` union appears as
/// a top-level key (setupComplete, serverContent, toolCall,
/// toolCallCancellation, goAway, sessionResumptionUpdate), optionally next to
/// usageMetadata / voiceActivity.
class ServerMessage {
  ServerMessage._(this.keys);

  final List<String> keys;
  bool setupComplete = false;
  ServerContent? serverContent;
  String? goAwayTimeLeft;
  bool hasGoAway = false;
  bool? resumable;
  int? resumptionHandleLength;
  Map<String, Object?>? usageMetadata;
  Object? voiceActivity;
  Object? error;
  final List<String> unknownKeys = [];

  static const _known = {
    'setupComplete',
    'serverContent',
    'toolCall',
    'toolCallCancellation',
    'goAway',
    'sessionResumptionUpdate',
    'usageMetadata',
    'voiceActivity',
    'error',
  };

  static ServerMessage parse(Object? json) {
    if (json is! Map) {
      final m = ServerMessage._(const []);
      m.unknownKeys.add('<non-object ${json.runtimeType}>');
      return m;
    }
    final msg = ServerMessage._(json.keys.map((k) => '$k').toList());
    for (final k in msg.keys) {
      if (!_known.contains(k)) msg.unknownKeys.add(k);
    }
    if (json.containsKey('setupComplete')) msg.setupComplete = true;
    if (json.containsKey('error')) msg.error = json['error'];
    final usage = json['usageMetadata'];
    if (usage is Map) msg.usageMetadata = usage.cast<String, Object?>();
    if (json.containsKey('voiceActivity')) {
      msg.voiceActivity = json['voiceActivity'];
    }

    final goAway = json['goAway'];
    if (json.containsKey('goAway')) {
      msg.hasGoAway = true;
      if (goAway is Map) msg.goAwayTimeLeft = goAway['timeLeft']?.toString();
    }

    final sru = json['sessionResumptionUpdate'];
    if (sru is Map) {
      msg.resumable = sru['resumable'] as bool?;
      final h = sru['newHandle'];
      msg.resumptionHandleLength = h is String ? h.length : null;
    }

    final sc = json['serverContent'];
    if (sc is Map) {
      final content = ServerContent();
      content.keys.addAll(sc.keys.map((k) => '$k'));
      final modelTurn = sc['modelTurn'];
      if (modelTurn is Map && modelTurn['parts'] is List) {
        for (final part in modelTurn['parts'] as List) {
          if (part is! Map) continue;
          final inline = part['inlineData'];
          if (inline is Map && inline['data'] is String) {
            content.audio.add(
              AudioChunk(
                base64Decode(inline['data'] as String),
                (inline['mimeType'] as String?) ?? '',
              ),
            );
          }
          if (part['text'] is String) content.texts.add(part['text'] as String);
        }
      }
      content.inputTranscription = Transcription.parse(
        sc['inputTranscription'],
      );
      content.interimInputTranscription = Transcription.parse(
        sc['interimInputTranscription'],
      );
      content.outputTranscription = Transcription.parse(
        sc['outputTranscription'],
      );
      content.generationComplete = sc['generationComplete'] == true;
      content.turnComplete = sc['turnComplete'] == true;
      content.interrupted = sc['interrupted'] == true;
      content.waitingForInput = sc['waitingForInput'] == true;
      content.interactionStatus = sc['interactionStatus']?.toString();
      msg.serverContent = content;
    }
    return msg;
  }

  /// Message type summary without any payload (safe for --verbose logs).
  String describe() {
    final parts = <String>[];
    for (final k in keys) {
      if (k == 'serverContent' && serverContent != null) {
        final c = serverContent!;
        final sub = <String>[];
        for (final ck in c.keys) {
          if (ck == 'modelTurn') {
            final audioBytes = c.audio.fold<int>(
              0,
              (s, a) => s + a.bytes.length,
            );
            final mimes = c.audio.map((a) => a.mimeType).toSet().join('|');
            sub.add(
              c.audio.isEmpty
                  ? 'modelTurn(${c.texts.length} text parts)'
                  : 'modelTurn(audio ${audioBytes}B $mimes)',
            );
          } else if (ck == 'interactionStatus') {
            sub.add('interactionStatus=${c.interactionStatus}');
          } else {
            sub.add(ck);
          }
        }
        parts.add('serverContent{${sub.join(',')}}');
      } else if (k == 'goAway') {
        parts.add('goAway(timeLeft=$goAwayTimeLeft)');
      } else if (k == 'sessionResumptionUpdate') {
        parts.add(
          'sessionResumptionUpdate(resumable=$resumable, '
          'handleLen=$resumptionHandleLength)',
        );
      } else {
        parts.add(k);
      }
    }
    return parts.isEmpty ? '<empty>' : parts.join(' + ');
  }

  /// Flat type tokens for counting, e.g. `serverContent.outputTranscription`.
  List<String> typeTokens() {
    final out = <String>[];
    for (final k in keys) {
      if (k == 'serverContent' && serverContent != null) {
        for (final ck in serverContent!.keys) {
          out.add('serverContent.$ck');
        }
      } else {
        out.add(k);
      }
    }
    return out;
  }
}

/// Human hints for WebSocket close codes seen from the Live API.
/// (Codes are standard RFC 6455; the mapping to Gemini causes is
/// community knowledge, not documented — treat as hints only.)
String closeCodeHint(int? code) {
  switch (code) {
    case null:
      return 'no close frame (connection dropped)';
    case 1000:
      return 'normal closure';
    case 1001:
      return 'going away';
    case 1006:
      return 'abnormal closure (no close frame)';
    case 1007:
      return 'invalid argument — e.g. invalid API key (seen live) or a bad '
          'setup field';
    case 1008:
      return 'policy violation — e.g. bad API key, model not allowed, unsupported operation';
    case 1011:
      return 'server error — often quota / RESOURCE_EXHAUSTED or internal error';
    case 1013:
      return 'try again later';
    default:
      return 'see reason text';
  }
}
