import 'package:flutter_test/flutter_test.dart';
import 'package:trans_app/data/settings/app_settings.dart';
import 'package:trans_app/domain/translation_engine.dart';
import 'package:trans_app/translator/routing.dart';
import 'package:trans_app/translator/translator_controller.dart';
import 'package:win_audio/win_audio.dart';

import '../fakes.dart';

const routing = RoutingConfig(
  micDeviceId: 'mic',
  headsetDeviceId: 'head',
  cableDeviceId: 'cable',
  callAppExe: 'Discord.exe',
  callCaptureMode: CallCaptureMode.processLoopback,
  vietnameseVolume: 0.8,
  englishVolume: 1.2,
);

void main() {
  late FakeAudioService audio;
  late TranslatorController c;
  late List<FakeEngine> engines;

  TranslationEngineFactory factory({Object? failSecond}) => () {
    final e = FakeEngine(startError: engines.length == 1 ? failSecond : null);
    engines.add(e);
    return e;
  };

  setUp(() {
    audio = FakeAudioService();
    engines = [];
    c = TranslatorController(audio, volumePollInterval: const Duration(milliseconds: 10));
  });

  tearDown(() => c.stop());

  test('opens outputs, captures and two sessions with the right languages', () async {
    await c.start(routing, factory());
    expect(c.isRunning, isTrue);
    expect(audio.calls, ['out:cable', 'out:head', 'mic:mic', 'app:4242']);
    expect(engines.map((e) => e.target), ['en', 'vi']);
    expect(audio.renders[0].gainValue, 1.2); // English into CABLE
    expect(audio.renders[1].gainValue, 0.8); // Vietnamese into the headset

    // Mic frames go to the outgoing engine, call frames to the incoming one.
    audio.captures[0].controller.add(AudioFrame(frameOf(10), 0));
    audio.captures[1].controller.add(AudioFrame(frameOf(20), 0));
    audio.captures[1].controller.add(AudioFrame(frameOf(20), 0));
    await Future<void>.delayed(Duration.zero);
    expect(engines[0].sent, hasLength(1));
    expect(engines[1].sent, hasLength(2));

    await c.stop();
    expect(c.isRunning, isFalse);
    expect(audio.captures.every((x) => x.stopped), isTrue);
    expect(audio.renders.every((x) => x.stopped), isTrue);
    expect(engines.every((e) => e.stopped), isTrue);
  });

  test('call app not running: nothing is left open', () async {
    audio.runningApps.clear();
    await expectLater(c.start(routing, factory()), throwsA(isA<RoutingException>()));
    expect(c.isRunning, isFalse);
    expect(audio.captures.every((x) => x.stopped), isTrue);
    expect(audio.renders.every((x) => x.stopped), isTrue);
  });

  test('one session failing to start closes everything', () async {
    await expectLater(
      c.start(routing, factory(failSecond: const EngineException('quota'))),
      throwsA(isA<EngineException>()),
    );
    expect(c.isRunning, isFalse);
    expect(engines.every((e) => e.stopped), isTrue);
    expect(audio.captures.every((x) => x.stopped), isTrue);
    expect(audio.renders.every((x) => x.stopped), isTrue);
  });

  test('R12: compensates the call app volume on the incoming input', () async {
    audio.volume = 0.25;
    await c.start(routing, factory());
    expect(c.snapshot()!.incoming.inputGain, 4.0);
    expect(c.snapshot()!.callAppVolume, 0.25);
    audio.volume = 0.05; // below the 0.2 floor -> capped at x5
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(c.snapshot()!.incoming.inputGain, 5.0);
    expect(c.snapshot()!.outgoing.inputGain, 1.0);
  });

  test('fallback capture device mode does not poll the app volume', () async {
    await c.start(
      const RoutingConfig(
        micDeviceId: 'mic',
        headsetDeviceId: 'head',
        cableDeviceId: 'cable',
        callAppExe: 'Discord.exe',
        callCaptureMode: CallCaptureMode.device,
        callCaptureDeviceId: 'cable-b',
      ),
      factory(),
    );
    expect(audio.calls, contains('device:cable-b'));
    expect(c.snapshot()!.callAppVolume, isNull);
  });

  test('bypass and volumes reach the streams', () async {
    await c.start(routing, factory());
    c.setBypass(true);
    expect(c.snapshot()!.bypass, isTrue);
    c.setVolumes(vietnamese: 0.3, english: 0.6);
    expect(audio.renders[1].gainValue, 0.3);
    expect(audio.renders[0].gainValue, 0.6);
  });

  test('a lost device stops the run and reports why', () async {
    await c.start(routing, factory());
    final failure = c.failures.first;
    audio.renders[1].errorsController.add(const WinAudioException('device invalidated'));
    expect(await failure, contains('tai nghe'));
    expect(c.isRunning, isFalse);
    expect(audio.captures.every((x) => x.stopped), isTrue);
  });

  test('an unplugged mic stops the run', () async {
    await c.start(routing, factory());
    final failure = c.failures.first;
    audio.captures[0].controller.addError(const WinAudioException('unplugged'));
    expect(await failure, contains('unplugged'));
    expect(c.isRunning, isFalse);
  });
}
