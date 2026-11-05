import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/settings/app_settings.dart';
import '../../data/settings/settings_repository.dart';

class SettingsState extends Equatable {
  const SettingsState({
    required this.settings,
    this.keySource = ApiKeySource.none,
  });

  final AppSettings settings;
  final ApiKeySource keySource;

  SettingsState copyWith({AppSettings? settings, ApiKeySource? keySource}) =>
      SettingsState(
        settings: settings ?? this.settings,
        keySource: keySource ?? this.keySource,
      );

  @override
  List<Object?> get props => [settings, keySource];
}

class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this._repo) : super(SettingsState(settings: _repo.load()));

  final SettingsRepository _repo;

  Future<void> loadKeySource() async =>
      emit(state.copyWith(keySource: await _repo.apiKeySource()));

  /// Applies a change and persists it.
  Future<void> update(AppSettings Function(AppSettings s) change) async {
    final next = change(state.settings);
    if (next == state.settings) return;
    emit(state.copyWith(settings: next));
    await _repo.save(next);
  }

  Future<void> saveApiKey(String key) async {
    await _repo.writeApiKey(key);
    await loadKeySource();
  }

  Future<void> deleteApiKey() async {
    await _repo.deleteApiKey();
    await loadKeySource();
  }
}
