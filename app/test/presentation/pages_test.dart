import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trans_app/data/settings/settings_repository.dart';
import 'package:trans_app/domain/call_app.dart';
import 'package:trans_app/presentation/app.dart';
import 'package:trans_app/presentation/cubits/devices_cubit.dart';
import 'package:trans_app/presentation/cubits/settings_cubit.dart';
import 'package:trans_app/presentation/cubits/subtitles_cubit.dart';
import 'package:trans_app/presentation/cubits/translator_cubit.dart';
import 'package:trans_app/presentation/pages/home_page.dart';
import 'package:trans_app/translator/translator_controller.dart';
import 'package:win_audio/win_audio.dart';

import '../fakes.dart';

void main() {
  late FakeAudioService audio;
  late SettingsRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    repo = SettingsRepository(
      await SharedPreferences.getInstance(),
      const FlutterSecureStorage(),
      environment: const {},
    );
    audio =
        FakeAudioService()
          ..captureList = const [
            AudioDeviceInfo(id: 'mic', name: 'Microphone (Headset)', isDefault: true),
          ]
          ..renderList = const [
            AudioDeviceInfo(id: 'head', name: 'Headphones (Headset)', isDefault: true),
          ]
          ..apps = const [CallApp(exe: 'Discord.exe', rootPid: 1, isPlaying: true)];
  });

  Future<void> pumpHome(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = TranslatorController(audio);
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: const AppInfo(logPath: r'C:\logs\app.log'),
        child: MultiBlocProvider(
          providers: [
            BlocProvider(create: (_) => SettingsCubit(repo)..loadKeySource()),
            BlocProvider(create: (_) => DevicesCubit(audio)..refresh()),
            BlocProvider(
              create:
                  (_) => TranslatorCubit(
                    controller: controller,
                    settings: repo,
                    audio: audio,
                  ),
            ),
            BlocProvider(create: (_) => SubtitlesCubit(controller.transcripts)),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in const [Size(1280, 860), Size(800, 900)]) {
    testWidgets('home page renders at ${size.width.toInt()} px wide', (tester) async {
      await pumpHome(tester, size);
      expect(find.text('Bắt đầu dịch'), findsOneWidget);
      expect(find.text('Microphone (Headset)  (mặc định)'), findsOneWidget);
      expect(find.text('Discord.exe  (đang phát)'), findsOneWidget);
      expect(find.textContaining('Chưa thấy VB-Cable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Start without VB-Cable explains what to install', (tester) async {
    await pumpHome(tester, const Size(1280, 860));
    await tester.tap(find.text('Bắt đầu dịch'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Không tìm thấy "CABLE Input"'), findsOneWidget);
    expect(audio.calls, isEmpty); // nothing was opened
  });

  testWidgets('Start without an API key asks for one', (tester) async {
    audio.renderList = [
      ...audio.renderList,
      const AudioDeviceInfo(id: 'cable', name: 'CABLE Input (VB-Audio Virtual Cable)'),
    ];
    await pumpHome(tester, const Size(1280, 860));
    await tester.tap(find.text('Bắt đầu dịch'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Chưa có Gemini API key'), findsOneWidget);
  });

  testWidgets('settings page renders and stores an API key', (tester) async {
    await pumpHome(tester, const Size(1280, 860));
    await tester.tap(find.byTooltip('Cài đặt'));
    await tester.pumpAndSettle();
    expect(find.text('Gemini API key'), findsOneWidget);
    expect(find.textContaining('Chưa có key'), findsOneWidget);
    expect(find.text(r'C:\logs\app.log'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.widgetWithText(TextField, 'Dán API key mới'), 'AIza-test-key');
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đã lưu key'), findsOneWidget);
    expect(await repo.readApiKey(), 'AIza-test-key');

    await tester.tap(find.text('Thu từ thiết bị (phương án dự phòng)'));
    await tester.pumpAndSettle();
    expect(find.text('Thiết bị thu âm thanh cuộc gọi'), findsOneWidget);
  });
}
