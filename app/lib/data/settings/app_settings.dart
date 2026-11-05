import 'package:equatable/equatable.dart';

import '../../core/app_config.dart';
import '../engines/gemini/gemini_protocol.dart';

/// How the other side's voice is captured (ARCHITECTURE.md 4.1 / 4.2).
enum CallCaptureMode {
  /// Process loopback of the call app's process tree. Main plan.
  processLoopback,

  /// A capture device, e.g. "CABLE-B Output" when the call app plays into a
  /// second virtual cable. Fallback plan if process loopback is silent.
  device,
}

/// Non-secret settings, persisted as JSON. Device ids are WASAPI endpoint
/// ids; null means "the Windows default device".
class AppSettings extends Equatable {
  const AppSettings({
    this.micDeviceId,
    this.headsetDeviceId,
    this.cableDeviceId,
    this.callAppExe = AppConfig.defaultCallAppExe,
    this.callCaptureMode = CallCaptureMode.processLoopback,
    this.callCaptureDeviceId,
    this.vietnameseVolume = 1.0,
    this.englishVolume = 1.0,
    this.geminiModel = defaultGeminiModel,
    this.transcriptionPlacement = TranscriptionPlacement.setup,
  });

  factory AppSettings.fromJson(Map<String, Object?> j) {
    T byName<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    double vol(Object? v) => ((v as num?)?.toDouble() ?? 1.0).clamp(0.0, 2.0);
    return AppSettings(
      micDeviceId: j['micDeviceId'] as String?,
      headsetDeviceId: j['headsetDeviceId'] as String?,
      cableDeviceId: j['cableDeviceId'] as String?,
      callAppExe:
          (j['callAppExe'] as String?)?.trim().isNotEmpty == true
              ? j['callAppExe'] as String
              : AppConfig.defaultCallAppExe,
      callCaptureMode: byName(
        CallCaptureMode.values,
        j['callCaptureMode'],
        CallCaptureMode.processLoopback,
      ),
      callCaptureDeviceId: j['callCaptureDeviceId'] as String?,
      vietnameseVolume: vol(j['vietnameseVolume']),
      englishVolume: vol(j['englishVolume']),
      geminiModel:
          (j['geminiModel'] as String?)?.trim().isNotEmpty == true
              ? j['geminiModel'] as String
              : defaultGeminiModel,
      transcriptionPlacement: byName(
        TranscriptionPlacement.values,
        j['transcriptionPlacement'],
        TranscriptionPlacement.setup,
      ),
    );
  }

  /// Your real microphone.
  final String? micDeviceId;

  /// Where you hear the Vietnamese translation (your headphones).
  final String? headsetDeviceId;

  /// "CABLE Input"; null = detect by name.
  final String? cableDeviceId;

  /// The call app whose audio is translated, e.g. "Discord.exe".
  final String callAppExe;
  final CallCaptureMode callCaptureMode;

  /// Only for [CallCaptureMode.device].
  final String? callCaptureDeviceId;

  /// Playback gain of the Vietnamese translation (headphones).
  final double vietnameseVolume;

  /// Playback gain of the English translation (into CABLE).
  final double englishVolume;
  final String geminiModel;
  final TranscriptionPlacement transcriptionPlacement;

  Map<String, Object?> toJson() => {
    'micDeviceId': micDeviceId,
    'headsetDeviceId': headsetDeviceId,
    'cableDeviceId': cableDeviceId,
    'callAppExe': callAppExe,
    'callCaptureMode': callCaptureMode.name,
    'callCaptureDeviceId': callCaptureDeviceId,
    'vietnameseVolume': vietnameseVolume,
    'englishVolume': englishVolume,
    'geminiModel': geminiModel,
    'transcriptionPlacement': transcriptionPlacement.name,
  };

  /// Nullable fields are set through the `Function()?` wrappers so that null
  /// ("use default") can be assigned explicitly.
  AppSettings copyWith({
    String? Function()? micDeviceId,
    String? Function()? headsetDeviceId,
    String? Function()? cableDeviceId,
    String? callAppExe,
    CallCaptureMode? callCaptureMode,
    String? Function()? callCaptureDeviceId,
    double? vietnameseVolume,
    double? englishVolume,
    String? geminiModel,
    TranscriptionPlacement? transcriptionPlacement,
  }) => AppSettings(
    micDeviceId: micDeviceId != null ? micDeviceId() : this.micDeviceId,
    headsetDeviceId:
        headsetDeviceId != null ? headsetDeviceId() : this.headsetDeviceId,
    cableDeviceId: cableDeviceId != null ? cableDeviceId() : this.cableDeviceId,
    callAppExe: callAppExe ?? this.callAppExe,
    callCaptureMode: callCaptureMode ?? this.callCaptureMode,
    callCaptureDeviceId:
        callCaptureDeviceId != null
            ? callCaptureDeviceId()
            : this.callCaptureDeviceId,
    vietnameseVolume: vietnameseVolume ?? this.vietnameseVolume,
    englishVolume: englishVolume ?? this.englishVolume,
    geminiModel: geminiModel ?? this.geminiModel,
    transcriptionPlacement:
        transcriptionPlacement ?? this.transcriptionPlacement,
  );

  @override
  List<Object?> get props => [
    micDeviceId,
    headsetDeviceId,
    cableDeviceId,
    callAppExe,
    callCaptureMode,
    callCaptureDeviceId,
    vietnameseVolume,
    englishVolume,
    geminiModel,
    transcriptionPlacement,
  ];
}
