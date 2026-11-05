import 'package:win_audio/win_audio.dart';

import '../../core/app_config.dart';
import '../../domain/call_app.dart';

/// Thin app-facing wrapper of the win_audio plugin: fixes the formats and
/// turns session lists into [CallApp]s. Tests implement this class as an
/// interface with fakes.
class AudioService {
  AudioService(this._wa);

  final WinAudio _wa;

  int nowUs() => _wa.nowUs();

  /// Debounced device add/remove/default changes.
  Stream<void> get devicesChanged => _wa.devicesChanged;

  List<AudioDeviceInfo> captureDevices() =>
      _wa.listDevices(DeviceFlow.capture);

  List<AudioDeviceInfo> renderDevices() => _wa.listDevices(DeviceFlow.render);

  /// Apps with an audio session, one entry per process tree, sorted by name.
  List<CallApp> callApps() {
    final byRoot = <int, List<AudioSessionInfo>>{};
    for (final s in _wa.listSessions()) {
      if (s.isSystem || s.rootPid == 0) continue;
      (byRoot[s.rootPid] ??= []).add(s);
    }
    final apps = [
      for (final MapEntry(key: root, value: sessions) in byRoot.entries)
        CallApp(
          exe: sessions.first.exe,
          rootPid: root,
          isPlaying: sessions.any((s) => s.isActive),
          volume: sessions
              .map((s) => s.volume)
              .reduce((a, b) => a > b ? a : b),
        ),
    ]..sort((a, b) => a.exe.toLowerCase().compareTo(b.exe.toLowerCase()));
    return apps;
  }

  /// Root PID of a running app, also before it has played any sound.
  int? findRootPid(String exe) => _wa.findRootPid(exe);

  CaptureStream captureMic(String? deviceId) => _wa.startCapture(
    source: CaptureSource.device,
    deviceId: deviceId,
    sampleRate: AudioFormat.captureRate,
    frameMs: AudioFormat.frameMs,
  );

  CaptureStream captureApp(int rootPid) => _wa.startCapture(
    source: CaptureSource.processLoopback,
    pid: rootPid,
    sampleRate: AudioFormat.captureRate,
    frameMs: AudioFormat.frameMs,
  );

  /// Fallback plan: the call app plays into a second virtual cable.
  CaptureStream captureDevice(String deviceId) => _wa.startCapture(
    source: CaptureSource.device,
    deviceId: deviceId,
    sampleRate: AudioFormat.captureRate,
    frameMs: AudioFormat.frameMs,
  );

  RenderStream openOutput(String? deviceId) => _wa.startRender(
    deviceId: deviceId,
    sampleRate: AudioFormat.renderRate,
    capacityMs: AudioFormat.renderCapacityMs,
  );

  /// The app's session volume in the Windows mixer (0..1), null if none.
  double? appVolume(int rootPid) => _wa.sessionVolume(rootPid);

  /// Undo a session volume change left behind by a crash. Returns sessions
  /// restored.
  int restoreAppVolumes() => _wa.restoreSessionVolumes();
}
