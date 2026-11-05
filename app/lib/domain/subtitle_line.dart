import 'package:equatable/equatable.dart';

import 'direction.dart';

/// One bilingual subtitle line: what was said and its translation.
class SubtitleLine extends Equatable {
  const SubtitleLine({
    required this.id,
    required this.direction,
    this.source = '',
    this.interimSource = '',
    this.translated = '',
    this.isFinal = false,
    required this.updatedAtUs,
  });

  final int id;
  final Direction direction;

  /// Confirmed source text.
  final String source;

  /// Provisional tail of the source text (shown greyed).
  final String interimSource;
  final String translated;
  final bool isFinal;
  final int updatedAtUs;

  SubtitleLine copyWith({
    String? source,
    String? interimSource,
    String? translated,
    bool? isFinal,
    int? updatedAtUs,
  }) => SubtitleLine(
    id: id,
    direction: direction,
    source: source ?? this.source,
    interimSource: interimSource ?? this.interimSource,
    translated: translated ?? this.translated,
    isFinal: isFinal ?? this.isFinal,
    updatedAtUs: updatedAtUs ?? this.updatedAtUs,
  );

  @override
  List<Object?> get props => [
    id,
    direction,
    source,
    interimSource,
    translated,
    isFinal,
    updatedAtUs,
  ];
}
