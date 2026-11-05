import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:win_audio/win_audio.dart';

import '../../data/audio/audio_service.dart';
import '../../domain/call_app.dart';
import '../../translator/routing.dart';

class DevicesState extends Equatable {
  const DevicesState({
    this.captureDevices = const [],
    this.renderDevices = const [],
    this.callApps = const [],
    this.error,
  });

  final List<AudioDeviceInfo> captureDevices;
  final List<AudioDeviceInfo> renderDevices;
  final List<CallApp> callApps;
  final String? error;

  /// VB-Cable's playback endpoint, if installed.
  AudioDeviceInfo? get cableInput => findCableInput(renderDevices);

  @override
  List<Object?> get props => [captureDevices, renderDevices, callApps, error];
}

/// Device and app lists; refreshed on Windows device changes and on demand.
class DevicesCubit extends Cubit<DevicesState> {
  DevicesCubit(this._audio) : super(const DevicesState()) {
    _sub = _audio.devicesChanged.listen((_) => refresh());
  }

  final AudioService _audio;
  final Logger _log = Logger('devices');
  StreamSubscription<void>? _sub;

  void refresh() {
    try {
      emit(
        DevicesState(
          captureDevices: _audio.captureDevices(),
          renderDevices: _audio.renderDevices(),
          callApps: _audio.callApps(),
        ),
      );
    } catch (e) {
      _log.warning('device list failed: $e');
      emit(
        DevicesState(
          captureDevices: state.captureDevices,
          renderDevices: state.renderDevices,
          callApps: state.callApps,
          error: 'Không đọc được danh sách thiết bị: $e',
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    return super.close();
  }
}
