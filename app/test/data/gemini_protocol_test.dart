import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trans_app/data/engines/gemini/gemini_protocol.dart';

void main() {
  test('setup: translationConfig in generationConfig, transcription at setup level', () {
    final m = const TranslateSetup(targetLanguageCode: 'vi').toMessage();
    final setup = m['setup']! as Map;
    expect(setup['model'], 'models/$defaultGeminiModel');
    final gc = setup['generationConfig'] as Map;
    expect(gc['responseModalities'], ['AUDIO']);
    expect(gc['translationConfig'], {
      'targetLanguageCode': 'vi',
      'echoTargetLanguage': false,
    });
    expect(setup.containsKey('inputAudioTranscription'), isTrue);
    expect(setup.containsKey('outputAudioTranscription'), isTrue);
    expect(gc.containsKey('inputAudioTranscription'), isFalse);
  });

  test('setup: transcription inside generationConfig when asked', () {
    final m =
        const TranslateSetup(
          targetLanguageCode: 'en',
          model: 'models/x',
          placement: TranscriptionPlacement.generationConfig,
        ).toMessage();
    final setup = m['setup']! as Map;
    expect(setup['model'], 'models/x');
    final gc = setup['generationConfig'] as Map;
    expect(gc.containsKey('inputAudioTranscription'), isTrue);
    expect(setup.containsKey('inputAudioTranscription'), isFalse);
  });

  test('realtime audio message', () {
    final pcm = Uint8List.fromList([1, 2, 3, 4]);
    expect(jsonEncode(realtimeAudioMessage(pcm)), jsonEncode({
      'realtimeInput': {
        'audio': {'data': base64Encode(pcm), 'mimeType': 'audio/pcm;rate=16000'},
      },
    }));
  });

  test('endpoint', () {
    expect(
      geminiLiveEndpoint().toString(),
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent',
    );
  });

  test('parses audio, transcriptions and turnComplete', () {
    final audio = Uint8List.fromList(List.generate(8, (i) => i));
    final m = GeminiServerMessage.parse({
      'serverContent': {
        'modelTurn': {
          'parts': [
            {
              'inlineData': {
                'data': base64Encode(audio),
                'mimeType': 'audio/pcm;rate=24000',
              },
            },
          ],
        },
        'inputTranscription': {'text': 'Hello', 'languageCode': 'en'},
        'interimInputTranscription': {'text': ' wor'},
        'outputTranscription': {'text': 'Xin chào'},
        'turnComplete': true,
      },
      'usageMetadata': {'totalTokenCount': 3},
    });
    expect(m.setupComplete, isFalse);
    expect(m.audio.single.bytes, audio);
    expect(m.audio.single.sampleRate, 24000);
    expect(m.inputTranscription!.text, 'Hello');
    expect(m.inputTranscription!.languageCode, 'en');
    expect(m.interimInputTranscription!.text, ' wor');
    expect(m.outputTranscription!.text, 'Xin chào');
    expect(m.turnComplete, isTrue);
  });

  test('parses setupComplete and goAway; tolerates junk', () {
    expect(GeminiServerMessage.parse({'setupComplete': {}}).setupComplete, isTrue);
    final g = GeminiServerMessage.parse({
      'goAway': {'timeLeft': '10s'},
    });
    expect(g.goAway, isTrue);
    expect(g.goAwayTimeLeft, '10s');
    final junk = GeminiServerMessage.parse([1, 2]);
    expect(junk.audio, isEmpty);
    expect(junk.setupComplete, isFalse);
  });

  test('close code hints', () {
    expect(geminiCloseHint(1007), contains('API key'));
    expect(geminiCloseHint(1011), contains('quota'));
    expect(geminiCloseHint(null), isNotEmpty);
  });
}
