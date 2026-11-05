/// Fixed audio formats (ARCHITECTURE.md 3.1): the AI wants 16 kHz in and
/// produces 24 kHz out; WASAPI converts to and from the devices.
abstract final class AudioFormat {
  static const captureRate = 16000;
  static const renderRate = 24000;

  /// Gemini: "Send audio in chunks of 100ms".
  static const frameMs = 100;

  /// Ring buffer of a playback stream. Translated speech arrives in bursts
  /// faster than real time, so this must hold a long sentence.
  static const renderCapacityMs = 60000;
}

abstract final class AppConfig {
  static const defaultCallAppExe = 'Discord.exe';

  /// Folder under %LOCALAPPDATA% for logs (and the native volume backup).
  static const dataFolderName = 'trans_app';

  /// R12: process loopback is captured after the app's session volume, so the
  /// incoming pipeline multiplies by 1/volume. Capped: keep Discord >= 0.2.
  static const maxInputGain = 5.0;

  /// Energy threshold for "someone is speaking", used only to time latency.
  static const voiceThresholdDb = -45.0;

  /// Frames of silence before a speech segment is considered over (700 ms).
  static const silenceHangoverFrames = 7;

  /// Translated chunks at or below this level are digital silence (measured
  /// 05/11: Gemini pads its continuous output stream with exact zeros).
  static const silentChunkDb = -80.0;
}
