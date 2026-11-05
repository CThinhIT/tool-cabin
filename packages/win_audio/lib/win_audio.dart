/// Windows audio I/O for the translator (docs/ARCHITECTURE.md section 3.3).
///
/// C++ does I/O only; formats are fixed by the caller:
/// capture = PCM16 LE mono 16 kHz in 100 ms frames, render = PCM16 LE mono 24 kHz.
library;

export 'src/models.dart';
export 'src/win_audio_api.dart';
