import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/direction.dart';
import '../../domain/subtitle_line.dart';
import '../../translator/direction_pipeline.dart';

class SubtitlesState extends Equatable {
  const SubtitlesState([this.lines = const []]);
  final List<SubtitleLine> lines;

  @override
  List<Object?> get props => [lines];
}

/// Assembles transcript fragments into bilingual lines. Each direction has at
/// most one open line.
///
/// Measured 05/11 (docs/poc-results.md): Gemini Live Translate sends input and
/// output transcripts as *fragments to append* (" call today."), the output
/// fragments ~0.2-0.3 s after the matching input ones, no interim text and no
/// turnComplete. So a line is closed when:
///  - the open line's source ends a sentence (. ? ! ...) and a new source
///    fragment arrives >= [sentenceGap] after the previous one, or
///  - nothing arrived for [gap], or
///  - the engine sends turnComplete (other providers).
class SubtitlesCubit extends Cubit<SubtitlesState> {
  SubtitlesCubit(Stream<TranscriptUpdate> updates, {this.maxLines = 200})
    : super(const SubtitlesState()) {
    _sub = updates.listen(onUpdate);
  }

  static const gap = Duration(seconds: 4);
  static const sentenceGap = Duration(milliseconds: 700);
  static final RegExp _sentenceEnd = RegExp(r'[.?!…。]["”’)]*\s*$');

  final int maxLines;
  late final StreamSubscription<TranscriptUpdate> _sub;
  final Map<Direction, int> _open = {}; // direction -> line id
  final Map<Direction, int> _lastSourceAtUs = {};
  int _nextId = 0;

  void onUpdate(TranscriptUpdate u) {
    final lines = [...state.lines];
    var idx = _indexOfOpen(u.direction, lines);

    if (idx != null &&
        u.kind != TranscriptKind.turnComplete &&
        (u.atUs - lines[idx].updatedAtUs > gap.inMicroseconds ||
            _startsNewSentence(u, lines[idx].source))) {
      lines[idx] = lines[idx].copyWith(isFinal: true, interimSource: '');
      _open.remove(u.direction);
      idx = null;
    }
    if (u.kind == TranscriptKind.source) _lastSourceAtUs[u.direction] = u.atUs;

    if (u.kind == TranscriptKind.turnComplete) {
      if (idx == null) return;
      lines[idx] = lines[idx].copyWith(isFinal: true, interimSource: '');
      _open.remove(u.direction);
      emit(SubtitlesState(lines));
      return;
    }
    if (u.text.isEmpty && idx == null) return;

    if (idx == null) {
      final line = SubtitleLine(
        id: _nextId++,
        direction: u.direction,
        updatedAtUs: u.atUs,
      );
      lines.add(line);
      _open[u.direction] = line.id;
      idx = lines.length - 1;
    }
    final line = lines[idx];
    lines[idx] = switch (u.kind) {
      TranscriptKind.source => line.copyWith(
        source: _append(line.source, line.source.isEmpty ? u.text.trimLeft() : u.text),
        interimSource: '',
        updatedAtUs: u.atUs,
      ),
      TranscriptKind.sourceInterim => line.copyWith(
        interimSource: u.text,
        updatedAtUs: u.atUs,
      ),
      TranscriptKind.translated => line.copyWith(
        translated: _append(
          line.translated,
          line.translated.isEmpty ? u.text.trimLeft() : u.text,
        ),
        updatedAtUs: u.atUs,
      ),
      TranscriptKind.turnComplete => line,
    };

    while (lines.length > maxLines) {
      final removed = lines.removeAt(0);
      _open.removeWhere((_, id) => id == removed.id);
    }
    emit(SubtitlesState(lines));
  }

  void clear() {
    _open.clear();
    _lastSourceAtUs.clear();
    emit(const SubtitlesState());
  }

  int? _indexOfOpen(Direction d, List<SubtitleLine> lines) {
    final id = _open[d];
    if (id == null) return null;
    final i = lines.lastIndexWhere((l) => l.id == id);
    return i < 0 ? null : i;
  }

  bool _startsNewSentence(TranscriptUpdate u, String openSource) {
    if (u.kind != TranscriptKind.source) return false;
    final last = _lastSourceAtUs[u.direction];
    return last != null &&
        u.atUs - last >= sentenceGap.inMicroseconds &&
        _sentenceEnd.hasMatch(openSource);
  }

  static String _append(String text, String fragment) => text + fragment;

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
