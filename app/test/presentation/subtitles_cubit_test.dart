import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trans_app/domain/direction.dart';
import 'package:trans_app/presentation/cubits/subtitles_cubit.dart';
import 'package:trans_app/translator/direction_pipeline.dart';

void main() {
  late StreamController<TranscriptUpdate> updates;
  late SubtitlesCubit cubit;

  const s = 1000000; // 1 s in us
  TranscriptUpdate u(Direction d, TranscriptKind k, String text, int atUs) =>
      TranscriptUpdate(d, k, text, atUs);

  setUp(() {
    updates = StreamController();
    cubit = SubtitlesCubit(updates.stream, maxLines: 3);
  });

  tearDown(() => cubit.close());

  test('appends fragments into one line until turnComplete', () {
    const d = Direction.incoming;
    cubit
      ..onUpdate(u(d, TranscriptKind.sourceInterim, 'Hel', 0))
      ..onUpdate(u(d, TranscriptKind.source, 'Hello', 1))
      ..onUpdate(u(d, TranscriptKind.source, ' world', 2))
      ..onUpdate(u(d, TranscriptKind.translated, 'Xin chào', 3))
      ..onUpdate(u(d, TranscriptKind.translated, ' thế giới', 4));
    var line = cubit.state.lines.single;
    expect(line.source, 'Hello world');
    expect(line.interimSource, '');
    expect(line.translated, 'Xin chào thế giới');
    expect(line.isFinal, isFalse);

    cubit.onUpdate(u(d, TranscriptKind.turnComplete, '', 5));
    line = cubit.state.lines.single;
    expect(line.isFinal, isTrue);

    cubit.onUpdate(u(d, TranscriptKind.source, 'Next', 6));
    expect(cubit.state.lines, hasLength(2));
    expect(cubit.state.lines.last.source, 'Next');
  });

  test('interim text is shown until confirmed text arrives', () {
    const d = Direction.outgoing;
    cubit.onUpdate(u(d, TranscriptKind.sourceInterim, 'Xin', 0));
    expect(cubit.state.lines.single.interimSource, 'Xin');
    cubit.onUpdate(u(d, TranscriptKind.sourceInterim, 'Xin chà', 1));
    expect(cubit.state.lines.single.interimSource, 'Xin chà');
    cubit.onUpdate(u(d, TranscriptKind.source, 'Xin chào', 2));
    expect(cubit.state.lines.single.source, 'Xin chào');
    expect(cubit.state.lines.single.interimSource, '');
  });

  test('directions get separate lines', () {
    cubit
      ..onUpdate(u(Direction.outgoing, TranscriptKind.source, 'Chào', 0))
      ..onUpdate(u(Direction.incoming, TranscriptKind.source, 'Hi', 1))
      ..onUpdate(u(Direction.outgoing, TranscriptKind.translated, 'Hello', 2))
      ..onUpdate(u(Direction.incoming, TranscriptKind.translated, 'Chào', 3));
    expect(cubit.state.lines.map((l) => (l.direction, l.source, l.translated)), [
      (Direction.outgoing, 'Chào', 'Hello'),
      (Direction.incoming, 'Hi', 'Chào'),
    ]);
  });

  test('a long pause starts a new line even without turnComplete', () {
    const d = Direction.incoming;
    cubit
      ..onUpdate(u(d, TranscriptKind.source, 'One', 0))
      ..onUpdate(u(d, TranscriptKind.source, 'Two', 5 * s));
    expect(cubit.state.lines, hasLength(2));
    expect(cubit.state.lines.first.isFinal, isTrue);
  });

  test('keeps at most maxLines; ignores empty text and stray turnComplete', () {
    const d = Direction.incoming;
    cubit.onUpdate(u(d, TranscriptKind.turnComplete, '', 0));
    cubit.onUpdate(u(d, TranscriptKind.sourceInterim, '', 0));
    expect(cubit.state.lines, isEmpty);
    for (var i = 0; i < 5; i++) {
      cubit
        ..onUpdate(u(d, TranscriptKind.source, 'L$i', i))
        ..onUpdate(u(d, TranscriptKind.turnComplete, '', i));
    }
    expect(cubit.state.lines.map((l) => l.source), ['L2', 'L3', 'L4']);
    cubit.clear();
    expect(cubit.state.lines, isEmpty);
  });

  test('splits the real Gemini fragment sequence of 05/11 into sentences', () {
    // From poc/gemini_probe out/dialog_vi.json (no turnComplete, no interim).
    const d = Direction.incoming;
    const seq = [
      (3033, TranscriptKind.source, 'Hi. Thanks for joining the'),
      (3220, TranscriptKind.translated, 'Xin chào. Cảm'),
      (3747, TranscriptKind.source, ' call today.'),
      (3919, TranscriptKind.translated, ' ơn bạn đã tham gia cuộc'),
      (4674, TranscriptKind.translated, ' gọi hôm nay.'),
      (5578, TranscriptKind.source, ' Can'),
      (5925, TranscriptKind.translated, ' Bạn'),
      (6650, TranscriptKind.source, ' you hear me clearly?'),
      (6919, TranscriptKind.translated, ' có nghe rõ tôi không?'),
      (10762, TranscriptKind.source, ' Let us review the project'),
      (10912, TranscriptKind.translated, ' Chúng ta hãy xem xét'),
      (11709, TranscriptKind.source, ' timeline and the budget'),
      (11914, TranscriptKind.translated, ' tiến độ dự án và'),
      (12599, TranscriptKind.source, ' for next month.'),
      (12919, TranscriptKind.translated, ' ngân sách cho tháng tới.'),
    ];
    for (final (ms, kind, text) in seq) {
      cubit.onUpdate(u(d, kind, text, ms * 1000));
    }
    // maxLines is 3 in this group.
    expect(cubit.state.lines.map((l) => (l.source, l.translated)), [
      ('Hi. Thanks for joining the call today.', 'Xin chào. Cảm ơn bạn đã tham gia cuộc gọi hôm nay.'),
      ('Can you hear me clearly?', 'Bạn có nghe rõ tôi không?'),
      (
        'Let us review the project timeline and the budget for next month.',
        'Chúng ta hãy xem xét tiến độ dự án và ngân sách cho tháng tới.',
      ),
    ]);
    expect(cubit.state.lines.take(2).every((l) => l.isFinal), isTrue);
  });

  test('a sentence end followed quickly by more speech stays on one line', () {
    const d = Direction.outgoing;
    cubit
      ..onUpdate(u(d, TranscriptKind.source, 'Okay.', 0))
      ..onUpdate(u(d, TranscriptKind.source, ' So the thing is', 300000));
    expect(cubit.state.lines.single.source, 'Okay. So the thing is');
  });

  test('listens to the stream it was given', () async {
    updates.add(u(Direction.incoming, TranscriptKind.source, 'Hi', 0));
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.lines.single.source, 'Hi');
  });
}
