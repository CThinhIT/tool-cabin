import 'dart:convert';
import 'dart:typed_data';

/// Gemini Live API (WebSocket, BidiGenerateContent) messages used by the app.
/// Ported from poc/gemini_probe/lib/src/protocol.dart; field names follow the
/// official docs (checked 2026-11-04):
///  - https://aistudio.google.com/docs/live-api/live-translate
///  - https://aistudio.google.com/api-reference/live/bidi-generate-content

const defaultGeminiModel = 'gemini-3.5-live-translate-preview';
const defaultGeminiApiVersion = 'v1beta';
const geminiLiveHost = 'generativelanguage.googleapis.com';

/// Input: PCM16 LE mono 16 kHz. Output: PCM16 LE mono 24 kHz.
const geminiInputRate = 16000;
const geminiOutputRate = 24000;

/// Where to put `inputAudioTranscription` / `outputAudioTranscription`.
/// The two Google pages disagree (ARCHITECTURE.md 3.2); to be settled by
/// `gemini_probe` with a real key.
enum TranscriptionPlacement {
  /// Top level of `setup` (API reference, python-genai SDK). Default.
  setup,

  /// Inside `setup.generationConfig` (Live Translate guide example).
  generationConfig,
}

Uri geminiLiveEndpoint({String apiVersion = defaultGeminiApiVersion}) => Uri(
  scheme: 'wss',
  host: geminiLiveHost,
  path:
      '/ws/google.ai.generativelanguage.$apiVersion'
      '.GenerativeService.BidiGenerateContent',
);

class TranslateSetup {
  const TranslateSetup({
    this.model = defaultGeminiModel,
    required this.targetLanguageCode,
    this.placement = TranscriptionPlacement.setup,
  });

  final String model;
  final String targetLanguageCode;
  final TranscriptionPlacement placement;

  /// The first client message: `{"setup": BidiGenerateContentSetup}`.
  Map<String, Object?> toMessage() {
    final generationConfig = <String, Object?>{
      'responseModalities': ['AUDIO'],
      'translationConfig': {
        'targetLanguageCode': targetLanguageCode,
        'echoTargetLanguage': false,
      },
    };
    final setup = <String, Object?>{
      'model': model.startsWith('models/') ? model : 'models/$model',
      'generationConfig': generationConfig,
    };
    final host =
        placement == TranscriptionPlacement.setup ? setup : generationConfig;
    host['inputAudioTranscription'] = <String, Object?>{};
    host['outputAudioTranscription'] = <String, Object?>{};
    return {'setup': setup};
  }
}

/// `{"realtimeInput": {"audio": {"data": <b64>, "mimeType": "audio/pcm;rate=16000"}}}`
Map<String, Object?> realtimeAudioMessage(
  Uint8List pcm16le, {
  int sampleRate = geminiInputRate,
}) => {
  'realtimeInput': {
    'audio': {
      'data': base64Encode(pcm16le),
      'mimeType': 'audio/pcm;rate=$sampleRate',
    },
  },
};

class GeminiTranscription {
  const GeminiTranscription(this.text, this.languageCode);
  final String text;
  final String? languageCode;

  static GeminiTranscription? parse(Object? o) {
    if (o is! Map) return null;
    return GeminiTranscription(
      (o['text'] as String?) ?? '',
      o['languageCode'] as String?,
    );
  }
}

class GeminiAudioChunk {
  const GeminiAudioChunk(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;

  /// `rate=NNNN` of e.g. `audio/pcm;rate=24000`.
  int? get sampleRate {
    final m = RegExp(r'rate=(\d+)').firstMatch(mimeType);
    return m == null ? null : int.parse(m.group(1)!);
  }
}

/// One `BidiGenerateContentServerMessage`, reduced to what the app uses.
class GeminiServerMessage {
  bool setupComplete = false;
  final List<GeminiAudioChunk> audio = [];
  GeminiTranscription? inputTranscription;
  GeminiTranscription? interimInputTranscription;
  GeminiTranscription? outputTranscription;
  bool turnComplete = false;
  bool interrupted = false;
  bool goAway = false;
  String? goAwayTimeLeft;
  Object? error;

  static GeminiServerMessage parse(Object? json) {
    final msg = GeminiServerMessage();
    if (json is! Map) return msg;
    msg.setupComplete = json.containsKey('setupComplete');
    msg.error = json['error'];
    if (json.containsKey('goAway')) {
      msg.goAway = true;
      final g = json['goAway'];
      if (g is Map) msg.goAwayTimeLeft = g['timeLeft']?.toString();
    }
    final sc = json['serverContent'];
    if (sc is Map) {
      final modelTurn = sc['modelTurn'];
      if (modelTurn is Map && modelTurn['parts'] is List) {
        for (final part in modelTurn['parts'] as List) {
          if (part is! Map) continue;
          final inline = part['inlineData'];
          if (inline is Map && inline['data'] is String) {
            msg.audio.add(
              GeminiAudioChunk(
                base64Decode(inline['data'] as String),
                (inline['mimeType'] as String?) ?? '',
              ),
            );
          }
        }
      }
      msg.inputTranscription = GeminiTranscription.parse(
        sc['inputTranscription'],
      );
      msg.interimInputTranscription = GeminiTranscription.parse(
        sc['interimInputTranscription'],
      );
      msg.outputTranscription = GeminiTranscription.parse(
        sc['outputTranscription'],
      );
      msg.turnComplete = sc['turnComplete'] == true;
      msg.interrupted = sc['interrupted'] == true;
    }
    return msg;
  }
}

/// Hints for WebSocket close codes seen from the Live API. The mapping to
/// causes is community knowledge, not documented.
String geminiCloseHint(int? code) => switch (code) {
  null => 'mất kết nối (không có close frame)',
  1000 => 'đóng bình thường',
  1001 => 'server đóng (going away)',
  1006 => 'mất kết nối bất thường',
  1007 => 'tham số không hợp lệ, ví dụ API key sai',
  1008 => 'vi phạm chính sách, ví dụ API key sai hoặc model không được phép',
  1011 => 'lỗi server, thường do hết quota (RESOURCE_EXHAUSTED)',
  1013 => 'server bận, thử lại sau',
  _ => 'xem lý do',
};
