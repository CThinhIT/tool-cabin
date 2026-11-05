/// The two translation directions. The direction is decided by the audio
/// source, never by language detection (the user does not mix languages).
enum Direction {
  /// You speak Vietnamese; the other side hears English.
  /// Mic -> AI (en) -> CABLE Input -> call app microphone.
  outgoing('vi', 'en'),

  /// The other side speaks English; you hear Vietnamese.
  /// Call app (process loopback) -> AI (vi) -> headphones.
  incoming('en', 'vi');

  const Direction(this.sourceLanguage, this.targetLanguage);

  final String sourceLanguage;
  final String targetLanguage;

  String get label => switch (this) {
    Direction.outgoing => 'Bạn nói (Việt → Anh)',
    Direction.incoming => 'Đối phương (Anh → Việt)',
  };

  String get shortLabel => switch (this) {
    Direction.outgoing => 'Vi → En',
    Direction.incoming => 'En → Vi',
  };
}
