import 'dart:convert';
import 'dart:typed_data';

enum DeviceFlow { render, capture }

enum CaptureSource {
  /// A capture endpoint: the real microphone, or "CABLE-B Output" in the
  /// fallback plan (ARCHITECTURE.md 4.2).
  device,

  /// Process loopback of one app's process tree (ARCHITECTURE.md 4.1).
  processLoopback,

  /// Everything a render endpoint plays.
  deviceLoopback,
}

class WinAudioException implements Exception {
  const WinAudioException(this.message, {this.hresult});

  final String message;
  final int? hresult;

  /// The device behind the stream disappeared (unplugged or disabled).
  bool get isDeviceLost =>
      hresult != null &&
      (hresult!.toUnsigned(32) == 0x88890004 || // AUDCLNT_E_DEVICE_INVALIDATED
          hresult!.toUnsigned(32) == 0x80070490); // E_NOTFOUND

  @override
  String toString() => 'WinAudioException: $message';
}

class AudioDeviceInfo {
  const AudioDeviceInfo({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.isDefaultComm = false,
  });

  factory AudioDeviceInfo.fromJson(Map<String, Object?> j) => AudioDeviceInfo(
    id: j['id'] as String,
    name: j['name'] as String,
    isDefault: j['isDefault'] == true,
    isDefaultComm: j['isDefaultComm'] == true,
  );

  final String id;
  final String name;
  final bool isDefault;
  final bool isDefaultComm;

  /// VB-Audio Virtual Cable endpoints: "CABLE Input" (render) and
  /// "CABLE Output" (capture).
  bool get isVirtualCable => name.toLowerCase().contains('cable');

  static List<AudioDeviceInfo> listFromJson(String json) => [
    for (final e in jsonDecode(json) as List)
      AudioDeviceInfo.fromJson((e as Map).cast<String, Object?>()),
  ];

  @override
  bool operator ==(Object other) =>
      other is AudioDeviceInfo &&
      other.id == id &&
      other.name == name &&
      other.isDefault == isDefault &&
      other.isDefaultComm == isDefaultComm;

  @override
  int get hashCode => Object.hash(id, name, isDefault, isDefaultComm);

  @override
  String toString() => 'AudioDeviceInfo($name)';
}

class AudioSessionInfo {
  const AudioSessionInfo({
    required this.pid,
    required this.exe,
    required this.rootPid,
    required this.isSystem,
    required this.state,
    required this.volume,
    required this.muted,
    required this.deviceId,
    required this.deviceName,
  });

  factory AudioSessionInfo.fromJson(Map<String, Object?> j) => AudioSessionInfo(
    pid: (j['pid'] as num).toInt(),
    exe: j['exe'] as String,
    rootPid: (j['rootPid'] as num).toInt(),
    isSystem: j['system'] == true,
    state: j['state'] as String,
    volume: (j['volume'] as num).toDouble(),
    muted: j['muted'] == true,
    deviceId: j['deviceId'] as String,
    deviceName: j['deviceName'] as String,
  );

  final int pid;
  final String exe;

  /// Top process of the same exe; pass it to process loopback.
  final int rootPid;
  final bool isSystem;

  /// "active" | "inactive".
  final String state;
  final double volume;
  final bool muted;
  final String deviceId;
  final String deviceName;

  bool get isActive => state == 'active';

  static List<AudioSessionInfo> listFromJson(String json) => [
    for (final e in jsonDecode(json) as List)
      AudioSessionInfo.fromJson((e as Map).cast<String, Object?>()),
  ];
}

/// One capture frame: PCM16 LE mono.
class AudioFrame {
  const AudioFrame(this.pcm, this.capturedAtUs);

  final Uint8List pcm;

  /// [WinAudio.nowUs] clock, when the frame was completed.
  final int capturedAtUs;
}

/// Where translated audio is played. Implemented by [RenderStream]; tests use
/// fakes.
abstract interface class AudioSink {
  /// Appends PCM16 LE mono at the stream's sample rate. Returns the number of
  /// bytes accepted (less when the buffer is full).
  int write(Uint8List pcm);

  /// Drops everything not yet played.
  void clear();

  /// Linear gain applied while playing (0..8).
  set gain(double value);

  /// Audio queued but not yet heard, in ms.
  int get bufferedMs;
}
