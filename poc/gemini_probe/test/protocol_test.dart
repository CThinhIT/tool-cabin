import 'dart:convert';
import 'dart:typed_data';

import 'package:gemini_probe/src/protocol.dart';
import 'package:gemini_probe/src/secrets.dart';
import 'package:test/test.dart';

void main() {
  group('endpoint', () {
    test('matches the documented v1beta BidiGenerateContent URL', () {
      expect(
        liveEndpoint().toString(),
        'wss://generativelanguage.googleapis.com/ws/'
        'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent',
      );
      expect(
        liveEndpoint(constrained: true).path,
        endsWith('GenerativeService.BidiGenerateContentConstrained'),
      );
      expect(
        authTokensEndpoint().toString(),
        'https://generativelanguage.googleapis.com/v1beta/auth_tokens',
      );
    });
  });

  group('setup message', () {
    test(
      'default: translationConfig in generationConfig, transcription at setup level',
      () {
        final m = const TranslateSetup(targetLanguageCode: 'en').toMessage();
        final setup = m['setup'] as Map;
        expect(m.keys, ['setup']);
        expect(setup['model'], 'models/gemini-3.5-live-translate-preview');
        final gc = setup['generationConfig'] as Map;
        expect(gc['responseModalities'], ['AUDIO']);
        expect(gc['translationConfig'], {
          'targetLanguageCode': 'en',
          'echoTargetLanguage': false,
        });
        expect(setup['inputAudioTranscription'], isEmpty);
        expect(setup['outputAudioTranscription'], isEmpty);
        expect(gc.containsKey('inputAudioTranscription'), isFalse);
        expect(setup.containsKey('sessionResumption'), isFalse);
      },
    );

    test('guide variant: transcription inside generationConfig', () {
      final m =
          const TranslateSetup(
            targetLanguageCode: 'vi',
            echoTargetLanguage: true,
            placement: TranscriptionPlacement.generationConfig,
            sessionResumption: true,
          ).toMessage();
      final setup = m['setup'] as Map;
      final gc = setup['generationConfig'] as Map;
      expect(gc['inputAudioTranscription'], isEmpty);
      expect(gc['outputAudioTranscription'], isEmpty);
      expect(setup.containsKey('inputAudioTranscription'), isFalse);
      expect((gc['translationConfig'] as Map)['echoTargetLanguage'], isTrue);
      expect(setup['sessionResumption'], isEmpty);
      // Exactly the JSON in the Live Translate guide (apart from values).
      expect(
        jsonEncode(m),
        '{"setup":{"model":"models/gemini-3.5-live-translate-preview",'
        '"generationConfig":{"responseModalities":["AUDIO"],'
        '"translationConfig":{"targetLanguageCode":"vi","echoTargetLanguage":true},'
        '"inputAudioTranscription":{},"outputAudioTranscription":{}},'
        '"sessionResumption":{}}}',
      );
    });

    test('model given with models/ prefix is not doubled', () {
      final m =
          const TranslateSetup(
            model: 'models/x',
            targetLanguageCode: 'en',
          ).toMessage();
      expect((m['setup'] as Map)['model'], 'models/x');
    });
  });

  group('client messages', () {
    test('realtimeInput.audio carries base64 PCM and the 16 kHz mime type', () {
      final pcm = Uint8List.fromList([1, 2, 3, 4]);
      final m = realtimeAudioMessage(pcm);
      final audio = (m['realtimeInput'] as Map)['audio'] as Map;
      expect(audio['mimeType'], 'audio/pcm;rate=16000');
      expect(base64Decode(audio['data'] as String), orderedEquals(pcm));
    });

    test('audioStreamEnd', () {
      expect(
        jsonEncode(audioStreamEndMessage()),
        '{"realtimeInput":{"audioStreamEnd":true}}',
      );
    });

    test('ephemeral token request', () {
      final now = DateTime.utc(2026, 11, 4, 10);
      final body = ephemeralTokenRequest(now);
      expect(body['uses'], 1);
      expect(body['expireTime'], '2026-11-04T10:30:00.000Z');
      expect(body['newSessionExpireTime'], '2026-11-04T10:01:00.000Z');
    });
  });

  group('server message parsing', () {
    test('setupComplete', () {
      final m = ServerMessage.parse(jsonDecode('{"setupComplete":{}}'));
      expect(m.setupComplete, isTrue);
      expect(m.describe(), 'setupComplete');
    });

    test('serverContent with audio + transcriptions (docs shape)', () {
      final pcm = Uint8List.fromList(List.generate(4800, (i) => i % 256));
      final m = ServerMessage.parse({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {
                  'mimeType': 'audio/pcm;rate=24000',
                  'data': base64Encode(pcm),
                },
              },
            ],
          },
          'inputTranscription': {'text': 'Hello', 'languageCode': 'en'},
          'outputTranscription': {'text': 'Xin chào', 'languageCode': 'vi'},
          'turnComplete': true,
          'interactionStatus': 'IDLE',
        },
        'usageMetadata': {'totalTokenCount': 10},
      });
      final c = m.serverContent!;
      expect(c.audio.single.bytes, orderedEquals(pcm));
      expect(c.audio.single.sampleRate, 24000);
      expect(c.inputTranscription!.text, 'Hello');
      expect(c.inputTranscription!.languageCode, 'en');
      expect(c.outputTranscription!.text, 'Xin chào');
      expect(c.turnComplete, isTrue);
      expect(c.interactionStatus, 'IDLE');
      expect(m.usageMetadata, {'totalTokenCount': 10});
      final d = m.describe();
      expect(d, contains('modelTurn(audio 4800B audio/pcm;rate=24000)'));
      expect(d, contains('inputTranscription'));
      expect(d, isNot(contains(base64Encode(pcm).substring(0, 20))));
      expect(
        m.typeTokens(),
        containsAll([
          'serverContent.modelTurn',
          'serverContent.turnComplete',
          'usageMetadata',
        ]),
      );
    });

    test('goAway, sessionResumptionUpdate, error and unknown keys', () {
      final g = ServerMessage.parse({
        'goAway': {'timeLeft': '10s'},
      });
      expect(g.hasGoAway, isTrue);
      expect(g.goAwayTimeLeft, '10s');

      final r = ServerMessage.parse({
        'sessionResumptionUpdate': {'newHandle': 'abcdef', 'resumable': true},
      });
      expect(r.resumable, isTrue);
      expect(r.resumptionHandleLength, 6);
      expect(r.describe(), isNot(contains('abcdef')));

      final e = ServerMessage.parse({
        'error': {'code': 429},
        'somethingNew': 1,
      });
      expect(e.error, {'code': 429});
      expect(e.unknownKeys, ['somethingNew']);

      expect(ServerMessage.parse([1, 2]).unknownKeys, isNotEmpty);
    });
  });

  group('secrets', () {
    test('missing / blank key throws; key is trimmed and registered', () {
      expect(
        () => readApiKeyFromEnv(environment: {}),
        throwsA(isA<MissingApiKeyException>()),
      );
      expect(
        () => readApiKeyFromEnv(environment: {apiKeyEnvVar: '   '}),
        throwsA(isA<MissingApiKeyException>()),
      );
      final k = readApiKeyFromEnv(
        environment: {apiKeyEnvVar: ' AIzaTESTKEY123 \n'},
      );
      expect(k, 'AIzaTESTKEY123');
      expect(Redactor.global.redact('x AIzaTESTKEY123 y'), 'x *** y');
    });

    test('credential query params are redacted even if unregistered', () {
      final r = Redactor();
      expect(
        r.redact("Connection to 'https://h/ws/x?key=SECRET123&a=1' failed"),
        "Connection to 'https://h/ws/x?key=***&a=1' failed",
      );
      expect(
        r.redact('wss://h/p?access_token=auth_tokens/abc'),
        'wss://h/p?access_token=***',
      );
    });
  });
}
