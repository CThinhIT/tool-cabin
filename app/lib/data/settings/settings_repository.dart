import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logging.dart';
import 'app_settings.dart';

enum ApiKeySource {
  none,

  /// Entered in Settings, stored encrypted (flutter_secure_storage).
  stored,

  /// The GEMINI_API_KEY environment variable (developer convenience, same
  /// variable as poc/gemini_probe).
  environment,
}

/// Settings in shared_preferences, the API key in secure storage.
class SettingsRepository {
  SettingsRepository(
    this._prefs,
    this._secure, {
    Map<String, String>? environment,
  }) : _env = environment ?? Platform.environment;

  static Future<SettingsRepository> create() async => SettingsRepository(
    await SharedPreferences.getInstance(),
    const FlutterSecureStorage(),
  );

  static const _settingsKey = 'settings_v1';
  static const _apiKeyKey = 'gemini_api_key';
  static const apiKeyEnvVar = 'GEMINI_API_KEY';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  final Map<String, String> _env;
  final Logger _log = Logger('settings');

  AppSettings load() {
    final raw = _prefs.getString(_settingsKey);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (e) {
      _log.warning('Unreadable settings, using defaults: $e');
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    await _prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  /// The stored key, else the environment variable. Registers the key with
  /// the log redactor.
  Future<String?> readApiKey() async {
    final (key, _) = await _readKey();
    if (key != null) redactor.addSecret(key);
    return key;
  }

  Future<ApiKeySource> apiKeySource() async => (await _readKey()).$2;

  Future<void> writeApiKey(String key) async {
    final k = key.trim();
    if (k.isEmpty) throw ArgumentError('API key is empty');
    redactor.addSecret(k);
    await _secure.write(key: _apiKeyKey, value: k);
  }

  Future<void> deleteApiKey() => _secure.delete(key: _apiKeyKey);

  Future<(String?, ApiKeySource)> _readKey() async {
    String? stored;
    try {
      stored = (await _secure.read(key: _apiKeyKey))?.trim();
    } catch (e) {
      _log.warning('Cannot read the secure storage: $e');
    }
    if (stored != null && stored.isNotEmpty) {
      return (stored, ApiKeySource.stored);
    }
    final env = _env[apiKeyEnvVar]?.trim();
    if (env != null && env.isNotEmpty) return (env, ApiKeySource.environment);
    return (null, ApiKeySource.none);
  }
}
