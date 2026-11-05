import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trans_app/core/logging.dart';
import 'package:trans_app/data/engines/gemini/gemini_protocol.dart';
import 'package:trans_app/data/settings/app_settings.dart';
import 'package:trans_app/data/settings/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings', () {
    test('JSON round trip', () {
      const s = AppSettings(
        micDeviceId: 'm',
        headsetDeviceId: 'h',
        cableDeviceId: 'c',
        callAppExe: 'Zalo.exe',
        callCaptureMode: CallCaptureMode.device,
        callCaptureDeviceId: 'cb',
        vietnameseVolume: 0.5,
        englishVolume: 1.5,
        geminiModel: 'm2',
        transcriptionPlacement: TranscriptionPlacement.generationConfig,
      );
      expect(AppSettings.fromJson(s.toJson()), s);
    });

    test('bad or missing values fall back to defaults', () {
      final s = AppSettings.fromJson({
        'callAppExe': '  ',
        'callCaptureMode': 'nonsense',
        'vietnameseVolume': 9,
        'geminiModel': '',
      });
      expect(s.callAppExe, 'Discord.exe');
      expect(s.callCaptureMode, CallCaptureMode.processLoopback);
      expect(s.vietnameseVolume, 2.0);
      expect(s.geminiModel, defaultGeminiModel);
    });

    test('copyWith can set a device back to the Windows default (null)', () {
      const s = AppSettings(micDeviceId: 'm');
      expect(s.copyWith(micDeviceId: () => null).micDeviceId, isNull);
      expect(s.copyWith(englishVolume: 0.3).micDeviceId, 'm');
    });
  });

  group('SettingsRepository', () {
    Future<SettingsRepository> repo({Map<String, String> env = const {}}) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      return SettingsRepository(
        await SharedPreferences.getInstance(),
        const FlutterSecureStorage(),
        environment: env,
      );
    }

    test('saves and loads settings', () async {
      final r = await repo();
      expect(r.load(), const AppSettings());
      await r.save(const AppSettings(callAppExe: 'Zalo.exe'));
      expect(r.load().callAppExe, 'Zalo.exe');
    });

    test('API key: stored key first, then GEMINI_API_KEY, else none', () async {
      final r = await repo(env: {'GEMINI_API_KEY': ' env-key-123 '});
      expect(await r.apiKeySource(), ApiKeySource.environment);
      expect(await r.readApiKey(), 'env-key-123');

      await r.writeApiKey('  stored-key-456 ');
      expect(await r.apiKeySource(), ApiKeySource.stored);
      expect(await r.readApiKey(), 'stored-key-456');

      await r.deleteApiKey();
      expect(await r.readApiKey(), 'env-key-123');

      final none = await repo();
      expect(await none.readApiKey(), isNull);
      expect(await none.apiKeySource(), ApiKeySource.none);
    });

    test('a key read or written is redacted from logs', () async {
      final r = await repo();
      await r.writeApiKey('AIzaSecretValue');
      expect(redactor.redact('connect key=AIzaSecretValue'), isNot(contains('AIzaSecretValue')));
      expect(redactor.redact('header AIzaSecretValue'), 'header ***');
    });
  });
}
