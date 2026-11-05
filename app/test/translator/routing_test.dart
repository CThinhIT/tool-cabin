import 'package:flutter_test/flutter_test.dart';
import 'package:trans_app/data/settings/app_settings.dart';
import 'package:trans_app/translator/routing.dart';
import 'package:win_audio/win_audio.dart';

const headset = AudioDeviceInfo(id: 'r-head', name: 'Headphones (USB)', isDefault: true);
const cable = AudioDeviceInfo(id: 'r-cable', name: 'CABLE Input (VB-Audio Virtual Cable)');
const speakers = AudioDeviceInfo(id: 'r-spk', name: 'Speakers (Realtek)');
const mic = AudioDeviceInfo(id: 'c-mic', name: 'Microphone (USB)', isDefault: true);
const cableOut = AudioDeviceInfo(id: 'c-cable', name: 'CABLE Output (VB-Audio Virtual Cable)');
const cableB = AudioDeviceInfo(id: 'c-cable-b', name: 'CABLE-B Output (VB-Audio Cable B)');

RoutingConfig resolve(
  AppSettings s, {
  List<AudioDeviceInfo> capture = const [mic, cableOut, cableB],
  List<AudioDeviceInfo> render = const [headset, cable, speakers],
}) => resolveRouting(s, captureDevices: capture, renderDevices: render);

Matcher throwsRouting(String fragment) =>
    throwsA(isA<RoutingException>().having((e) => e.message, 'message', contains(fragment)));

void main() {
  test('defaults: Windows default mic and headset, CABLE Input found by name', () {
    final r = resolve(const AppSettings());
    expect(r.micDeviceId, 'c-mic');
    expect(r.headsetDeviceId, 'r-head');
    expect(r.cableDeviceId, 'r-cable');
    expect(r.callAppExe, 'Discord.exe');
    expect(r.callCaptureMode, CallCaptureMode.processLoopback);
  });

  test('explicit choices win over defaults', () {
    final r = resolve(
      const AppSettings(micDeviceId: 'c-mic', headsetDeviceId: 'r-spk', vietnameseVolume: 0.5),
    );
    expect(r.headsetDeviceId, 'r-spk');
    expect(r.vietnameseVolume, 0.5);
  });

  test('VB-Cable missing', () {
    expect(() => resolve(const AppSettings(), render: const [headset]), throwsRouting('VB-Cable'));
  });

  test('a selected CABLE device that disappeared', () {
    expect(
      () => resolve(const AppSettings(cableDeviceId: 'gone')),
      throwsRouting('không còn'),
    );
  });

  test('Vietnamese into CABLE would leak to the other side', () {
    expect(
      () => resolve(const AppSettings(headsetDeviceId: 'r-cable')),
      throwsRouting('cáp ảo'),
    );
    // VB-Cable became the Windows default playback device after install.
    expect(
      () => resolve(
        const AppSettings(),
        render: const [
          AudioDeviceInfo(id: 'r-cable', name: 'CABLE Input (VB-Audio Virtual Cable)', isDefault: true),
          headset,
        ],
      ),
      throwsRouting('cáp ảo'),
    );
  });

  test('a virtual cable as mic would loop', () {
    expect(
      () => resolve(const AppSettings(micDeviceId: 'c-cable')),
      throwsRouting('vòng lặp'),
    );
  });

  test('no mic at all', () {
    expect(() => resolve(const AppSettings(), capture: const []), throwsRouting('mic'));
  });

  test('fallback mode needs a capture device different from the mic', () {
    const fallback = AppSettings(callCaptureMode: CallCaptureMode.device);
    expect(() => resolve(fallback), throwsRouting('CABLE-B'));
    expect(
      () => resolve(fallback.copyWith(callCaptureDeviceId: () => 'c-mic')),
      throwsRouting('trùng'),
    );
    final r = resolve(fallback.copyWith(callCaptureDeviceId: () => 'c-cable-b'));
    expect(r.callCaptureDeviceId, 'c-cable-b');
  });
}
