import 'dart:async';
import 'dart:typed_data';

/// The only abstraction in the app (ARCHITECTURE.md 3.1 rule 5): providers
/// will be swapped and compared (free -> paid, Gemini <-> OpenAI).
///
/// One instance = one translation session for one direction. It cannot be
/// restarted after [stop]; create a new one.
abstract interface class TranslationEngine {
  /// Human-readable provider/model, for logs and the UI.
  String get name;

  EngineStatus get status;

  /// Broadcast. Timestamps use the same clock as the capture frames.
  Stream<EngineEvent> get events;

  /// Connects and waits until the session accepts audio.
  /// Throws [EngineException] on failure.
  Future<void> start({
    required String sourceLanguage,
    required String targetLanguage,
  });

  /// PCM16 LE mono 16 kHz, 100 ms frames. Ignored when not started.
  void sendAudio(Uint8List pcm);

  Future<void> stop();
}

typedef TranslationEngineFactory = TranslationEngine Function();

enum EngineStatus {
  idle,
  connecting,
  ready,

  /// The connection dropped; audio is queued (up to a few seconds) while a
  /// new session is opened.
  reconnecting,
  closed,

  /// Gave up; see [EngineStatusChanged.message].
  failed,
}

sealed class EngineEvent {
  const EngineEvent(this.atUs);

  /// When the event arrived (engine clock, microseconds).
  final int atUs;
}

final class EngineStatusChanged extends EngineEvent {
  const EngineStatusChanged(super.atUs, this.status, [this.message]);
  final EngineStatus status;
  final String? message;
}

/// Translated speech, PCM16 LE mono.
final class TranslatedAudio extends EngineEvent {
  const TranslatedAudio(super.atUs, this.pcm, this.sampleRate);
  final Uint8List pcm;
  final int sampleRate;
}

/// Transcript of what was said (source language). [text] is a fragment to be
/// appended, unless [interim] is set: then it is a provisional version of the
/// current fragment that replaces the previous interim text.
final class SourceTranscript extends EngineEvent {
  const SourceTranscript(
    super.atUs,
    this.text, {
    this.languageCode,
    this.interim = false,
  });
  final String text;
  final String? languageCode;
  final bool interim;
}

/// Transcript of the translated speech; a fragment to be appended.
final class TranslatedTranscript extends EngineEvent {
  const TranslatedTranscript(super.atUs, this.text);
  final String text;
}

/// The model finished its current turn (end of a sentence or utterance).
final class TurnComplete extends EngineEvent {
  const TurnComplete(super.atUs);
}

class EngineException implements Exception {
  const EngineException(this.message);
  final String message;

  @override
  String toString() => message;
}
