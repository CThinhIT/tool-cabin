import 'dart:async';
import 'dart:typed_data';

import 'package:trans_app/data/audio/audio_service.dart';
import 'package:trans_app/domain/call_app.dart';
import 'package:trans_app/domain/translation_engine.dart';
import 'package:win_audio/win_audio.dart';

class FakeEngine implements TranslationEngine {
  FakeEngine({this.startError});

  final Object? startError;
  final StreamController<EngineEvent> _events = StreamController.broadcast(sync: true);
  final List<Uint8List> sent = [];
  String? target;
  bool stopped = false;
  EngineStatus _status = EngineStatus.idle;

  @override
  String get name => 'fake';

  @override
  EngineStatus get status => _status;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Future<void> start({required String sourceLanguage, required String targetLanguage}) async {
    target = targetLanguage;
    if (startError != null) {
      _status = EngineStatus.failed;
      throw startError!;
    }
    _status = EngineStatus.ready;
  }

  @override
  void sendAudio(Uint8List pcm) => sent.add(pcm);

  @override
  Future<void> stop() async {
    stopped = true;
    _status = EngineStatus.closed;
    await _events.close();
  }

  void emit(EngineEvent e) => _events.add(e);
}

class FakeSink implements AudioSink {
  FakeSink({this.capacityBytes = 1 << 30});

  final int capacityBytes;
  final List<Uint8List> written = [];
  int clears = 0;
  double gainValue = 1.0;
  int buffered = 0;

  int get queuedBytes => written.fold(0, (s, b) => s + b.length);

  @override
  int write(Uint8List pcm) {
    final room = capacityBytes - queuedBytes;
    final n = pcm.length < room ? pcm.length : room;
    if (n > 0) written.add(Uint8List.sublistView(pcm, 0, n));
    return n;
  }

  @override
  void clear() {
    clears++;
    written.clear();
  }

  @override
  set gain(double value) => gainValue = value;

  @override
  int get bufferedMs => buffered;
}

/// Implements the plugin's CaptureStream interface (its private members are
/// only called on real instances by the plugin itself).
class FakeCapture implements CaptureStream {
  FakeCapture(this.id);

  final StreamController<AudioFrame> controller = StreamController();
  bool stopped = false;

  @override
  final int id;

  @override
  int get sampleRate => 16000;

  @override
  int discontinuities = 0;

  @override
  Stream<AudioFrame> get frames => controller.stream;

  @override
  bool get isClosed => stopped;

  @override
  void stop() {
    stopped = true;
    unawaited(controller.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRender extends FakeSink implements RenderStream {
  FakeRender(this.id, this.deviceId);

  @override
  final int id;
  final String? deviceId;
  bool stopped = false;
  final StreamController<WinAudioException> errorsController = StreamController.broadcast();

  @override
  int get sampleRate => 24000;

  @override
  double get gain => gainValue;

  @override
  Stream<WinAudioException> get errors => errorsController.stream;

  @override
  bool get isClosed => stopped;

  @override
  void stop() => stopped = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAudioService implements AudioService {
  final List<FakeCapture> captures = [];
  final List<FakeRender> renders = [];
  final Map<String, int> runningApps = {'discord.exe': 4242};
  double? volume = 1.0;
  int _ids = 0;
  final List<String> calls = [];

  @override
  int nowUs() => 0;

  @override
  Stream<void> get devicesChanged => const Stream.empty();

  List<AudioDeviceInfo> captureList = const [];
  List<AudioDeviceInfo> renderList = const [];
  List<CallApp> apps = const [];

  @override
  List<AudioDeviceInfo> captureDevices() => captureList;

  @override
  List<AudioDeviceInfo> renderDevices() => renderList;

  @override
  List<CallApp> callApps() => apps;

  @override
  int? findRootPid(String exe) => runningApps[exe.toLowerCase()];

  FakeCapture _capture(String what) {
    calls.add(what);
    final c = FakeCapture(++_ids);
    captures.add(c);
    return c;
  }

  @override
  CaptureStream captureMic(String? deviceId) => _capture('mic:$deviceId');

  @override
  CaptureStream captureApp(int rootPid) => _capture('app:$rootPid');

  @override
  CaptureStream captureDevice(String deviceId) => _capture('device:$deviceId');

  @override
  RenderStream openOutput(String? deviceId) {
    calls.add('out:$deviceId');
    final r = FakeRender(++_ids, deviceId);
    renders.add(r);
    return r;
  }

  @override
  double? appVolume(int rootPid) => volume;

  @override
  int restoreAppVolumes() => 0;
}

/// 100 ms of PCM16 at 16 kHz with a constant sample value.
Uint8List frameOf(int value, {int samples = 1600}) =>
    Int16List.fromList(List.filled(samples, value)).buffer.asUint8List();
