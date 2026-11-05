import 'package:win_audio/win_audio.dart';

import '../data/settings/app_settings.dart';

/// Concrete device ids for one translation run (no "default" placeholders:
/// resolved when Start is pressed).
class RoutingConfig {
  const RoutingConfig({
    required this.micDeviceId,
    required this.headsetDeviceId,
    required this.cableDeviceId,
    required this.callAppExe,
    required this.callCaptureMode,
    this.callCaptureDeviceId,
    this.vietnameseVolume = 1.0,
    this.englishVolume = 1.0,
  });

  final String micDeviceId;
  final String headsetDeviceId;
  final String cableDeviceId;
  final String callAppExe;
  final CallCaptureMode callCaptureMode;
  final String? callCaptureDeviceId;
  final double vietnameseVolume;
  final double englishVolume;
}

class RoutingException implements Exception {
  const RoutingException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Finds "CABLE Input" (VB-Audio Virtual Cable's playback endpoint).
AudioDeviceInfo? findCableInput(List<AudioDeviceInfo> renderDevices) =>
    renderDevices
        .where((d) => d.name.toLowerCase().contains('cable input'))
        .firstOrNull;

/// Checks the settings against the devices present now and returns concrete
/// ids. Throws [RoutingException] with a Vietnamese message for the user.
///
/// Guards against the feedback loops of ARCHITECTURE.md 4.3: the Vietnamese
/// translation must not go into CABLE, and the mic must not be a virtual
/// cable (VB-Cable likes to make itself the Windows default after install).
RoutingConfig resolveRouting(
  AppSettings s, {
  required List<AudioDeviceInfo> captureDevices,
  required List<AudioDeviceInfo> renderDevices,
}) {
  AudioDeviceInfo? byId(List<AudioDeviceInfo> list, String id) =>
      list.where((d) => d.id == id).firstOrNull;
  AudioDeviceInfo? defaultOf(List<AudioDeviceInfo> list) =>
      list.where((d) => d.isDefault).firstOrNull;

  final AudioDeviceInfo cable;
  if (s.cableDeviceId != null) {
    cable =
        byId(renderDevices, s.cableDeviceId!) ??
        (throw const RoutingException(
          'Thiết bị phát tiếng Anh cho đối phương (CABLE Input) đã chọn không còn. '
          'Chọn lại ở mục "Đối phương nghe tiếng Anh qua".',
        ));
  } else {
    cable =
        findCableInput(renderDevices) ??
        (throw const RoutingException(
          'Không tìm thấy "CABLE Input". Cài VB-Cable (chạy setup bằng quyền '
          'Administrator) rồi khởi động lại máy.',
        ));
  }

  final headset =
      s.headsetDeviceId != null
          ? byId(renderDevices, s.headsetDeviceId!)
          : defaultOf(renderDevices);
  if (headset == null) {
    throw const RoutingException(
      'Không tìm thấy thiết bị để bạn nghe tiếng Việt. Cắm tai nghe rồi chọn lại.',
    );
  }
  if (headset.id == cable.id || headset.isVirtualCable) {
    throw RoutingException(
      'Bạn đang nghe tiếng Việt qua "${headset.name}", là cáp ảo. Đối phương sẽ '
      'nghe cả tiếng Việt. Chọn tai nghe thật ở mục "Bạn nghe tiếng Việt qua" '
      '(Windows có thể đã tự đặt VB-Cable làm thiết bị mặc định).',
    );
  }

  final mic =
      s.micDeviceId != null
          ? byId(captureDevices, s.micDeviceId!)
          : defaultOf(captureDevices);
  if (mic == null) {
    throw const RoutingException(
      'Không tìm thấy mic. Cắm tai nghe có mic rồi chọn lại.',
    );
  }
  if (mic.isVirtualCable) {
    throw RoutingException(
      'Mic đang là "${mic.name}", là cáp ảo, sẽ tạo vòng lặp âm thanh. '
      'Chọn mic thật của tai nghe.',
    );
  }

  String? callDeviceId;
  if (s.callCaptureMode == CallCaptureMode.device) {
    final d =
        s.callCaptureDeviceId == null
            ? null
            : byId(captureDevices, s.callCaptureDeviceId!);
    if (d == null) {
      throw const RoutingException(
        'Chế độ dự phòng cần chọn thiết bị thu âm thanh cuộc gọi (ví dụ CABLE-B Output) trong Cài đặt.',
      );
    }
    if (d.id == mic.id) {
      throw const RoutingException(
        'Thiết bị thu âm thanh cuộc gọi trùng với mic của bạn.',
      );
    }
    callDeviceId = d.id;
  } else if (s.callAppExe.trim().isEmpty) {
    throw const RoutingException('Chưa chọn app gọi (ví dụ Discord.exe).');
  }

  return RoutingConfig(
    micDeviceId: mic.id,
    headsetDeviceId: headset.id,
    cableDeviceId: cable.id,
    callAppExe: s.callAppExe.trim(),
    callCaptureMode: s.callCaptureMode,
    callCaptureDeviceId: callDeviceId,
    vietnameseVolume: s.vietnameseVolume,
    englishVolume: s.englishVolume,
  );
}
