import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'models.dart';

/// Entry point. One instance per process: [WinAudio.open] loads
/// `win_audio.dll` (bundled next to the app exe by the Flutter tool) and
/// registers the native event callback.
///
/// All calls are synchronous FFI calls; the slow ones (device and session
/// lists, opening a stream) take a few ms to ~100 ms.
class WinAudio {
  WinAudio._(this._b) {
    _callable = NativeCallable<WaEventCallbackNative>.listener(_onEvent);
    if (_b.init(_callable.nativeFunction) != 0) {
      final message = _b.lastErrorText();
      _callable.close();
      throw WinAudioException('wa_init failed: $message');
    }
  }

  static WinAudio? _instance;

  /// Opens the DLL once; later calls return the same instance until [dispose].
  static WinAudio open({String libraryPath = 'win_audio.dll'}) =>
      _instance ??= WinAudio._(
        WinAudioBindings(DynamicLibrary.open(libraryPath)),
      );

  final WinAudioBindings _b;
  late final NativeCallable<WaEventCallbackNative> _callable;
  final Map<int, _NativeStream> _streams = {};
  final StreamController<void> _devicesChanged = StreamController.broadcast();
  Timer? _devicesDebounce;
  bool _disposed = false;

  /// Monotonic microseconds, same clock as [AudioFrame.capturedAtUs].
  int nowUs() => _b.nowUs();

  /// Fires (debounced by 300 ms) when an endpoint is added, removed, enabled,
  /// disabled or becomes default.
  Stream<void> get devicesChanged => _devicesChanged.stream;

  List<AudioDeviceInfo> listDevices(DeviceFlow flow) {
    final json = _b.takeString(
      _b.listDevices(flow == DeviceFlow.render ? waFlowRender : waFlowCapture),
    );
    if (json == null) throw WinAudioException(_b.lastErrorText());
    return AudioDeviceInfo.listFromJson(json);
  }

  List<AudioSessionInfo> listSessions() {
    final json = _b.takeString(_b.listSessions());
    if (json == null) throw WinAudioException(_b.lastErrorText());
    return AudioSessionInfo.listFromJson(json);
  }

  /// Root PID of a running app's process tree ("Discord.exe"), or null.
  int? findRootPid(String exe) {
    final p = exe.toNativeUtf8();
    try {
      final pid = _b.findRootPid(p);
      return pid == 0 ? null : pid;
    } finally {
      malloc.free(p);
    }
  }

  /// Starts capturing PCM16 mono at [sampleRate] in frames of [frameMs].
  /// [deviceId] null = default device. [pid] is the root PID for
  /// [CaptureSource.processLoopback]. Throws [WinAudioException].
  CaptureStream startCapture({
    required CaptureSource source,
    String? deviceId,
    int pid = 0,
    int sampleRate = 16000,
    int frameMs = 100,
  }) {
    _checkOpen();
    final id = _withUtf8(
      deviceId,
      (p) => _b.captureStart(switch (source) {
        CaptureSource.device => waSourceDevice,
        CaptureSource.processLoopback => waSourceProcess,
        CaptureSource.deviceLoopback => waSourceDeviceLoopback,
      }, p, pid, sampleRate, frameMs),
    );
    if (id == 0) throw WinAudioException(_b.lastErrorText());
    final s = CaptureStream._(this, id, sampleRate);
    _streams[id] = s;
    return s;
  }

  /// Opens a playback stream into [deviceId] (null = default device) that
  /// plays what is written and silence otherwise. Throws [WinAudioException].
  RenderStream startRender({
    String? deviceId,
    int sampleRate = 24000,
    int capacityMs = 60000,
  }) {
    _checkOpen();
    final id = _withUtf8(
      deviceId,
      (p) => _b.renderStart(p, sampleRate, capacityMs),
    );
    if (id == 0) throw WinAudioException(_b.lastErrorText());
    final s = RenderStream._(this, id, sampleRate);
    _streams[id] = s;
    return s;
  }

  /// Volume (0..1) of an app's audio sessions, null if it has none.
  double? sessionVolume(int rootPid) {
    final v = _b.sessionVolume(rootPid);
    return v < 0 ? null : v;
  }

  /// Sets an app's session volume; the original is backed up once so that
  /// [restoreSessionVolumes] (also after a crash) can undo it. Returns the
  /// number of sessions changed.
  int setSessionVolume(int rootPid, double volume) {
    final n = _b.sessionSetVolume(rootPid, volume);
    if (n < 0) throw WinAudioException(_b.lastErrorText());
    return n;
  }

  /// Returns the number of sessions restored (0 = nothing to restore).
  int restoreSessionVolumes() {
    final n = _b.sessionRestore();
    if (n < 0) throw WinAudioException(_b.lastErrorText());
    return n;
  }

  /// Stops every stream and unloads the callback.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.shutdown();
    _callable.close();
    _devicesDebounce?.cancel();
    for (final s in _streams.values) {
      s._closed();
    }
    _streams.clear();
    unawaited(_devicesChanged.close());
    if (identical(_instance, this)) _instance = null;
  }

  void _checkOpen() {
    if (_disposed) throw const WinAudioException('WinAudio is disposed');
  }

  int _withUtf8(String? s, int Function(Pointer<Utf8>) body) {
    if (s == null || s.isEmpty) return body(nullptr);
    final p = s.toNativeUtf8();
    try {
      return body(p);
    } finally {
      malloc.free(p);
    }
  }

  void _stop(_NativeStream s) {
    if (_streams.remove(s.id) == null) return;
    _b.streamStop(s.id);
    s._closed();
  }

  void _onEvent(int stream, int kind, int value, Pointer<Uint8> data, int size) {
    Uint8List? bytes;
    if (data != nullptr) {
      bytes = Uint8List.fromList(data.asTypedList(size));
      _b.free(data.cast());
    }
    if (kind == waEventDevicesChanged) {
      _devicesDebounce?.cancel();
      _devicesDebounce = Timer(const Duration(milliseconds: 300), () {
        if (!_devicesChanged.isClosed) _devicesChanged.add(null);
      });
      return;
    }
    final s = _streams[stream];
    if (s == null) return; // already stopped
    switch (kind) {
      case waEventAudio:
        if (bytes != null && s is CaptureStream) s._frame(bytes, value);
      case waEventError:
        final message =
            bytes == null
                ? 'audio stream failed'
                : utf8.decode(bytes, allowMalformed: true);
        s._error(WinAudioException(message, hresult: value));
      case waEventDiscontinuity:
        if (s is CaptureStream) s.discontinuities += value;
      case waEventStopped:
        break; // _stop() already closed the Dart side
    }
  }
}

sealed class _NativeStream {
  _NativeStream(this._owner, this.id, this.sampleRate);

  final WinAudio _owner;
  final int id;
  final int sampleRate;
  bool _isClosed = false;

  bool get isClosed => _isClosed;

  /// Stops the native stream. Idempotent.
  void stop() => _owner._stop(this);

  void _error(WinAudioException e);
  void _closed();
}

/// A running capture. [frames] is single-subscription; errors (e.g. device
/// unplugged) arrive as [WinAudioException] stream errors, after which the
/// stream produces nothing until [stop] is called.
class CaptureStream extends _NativeStream {
  CaptureStream._(super.owner, super.id, super.sampleRate);

  final StreamController<AudioFrame> _frames = StreamController();

  /// Data discontinuities reported by WASAPI (dropped capture data).
  int discontinuities = 0;

  Stream<AudioFrame> get frames => _frames.stream;

  void _frame(Uint8List pcm, int atUs) {
    if (!_frames.isClosed) _frames.add(AudioFrame(pcm, atUs));
  }

  @override
  void _error(WinAudioException e) {
    if (!_frames.isClosed) _frames.addError(e);
  }

  @override
  void _closed() {
    _isClosed = true;
    unawaited(_frames.close());
  }
}

/// A running playback stream into one device.
class RenderStream extends _NativeStream implements AudioSink {
  RenderStream._(super.owner, super.id, super.sampleRate);

  Pointer<Uint8> _buf = nullptr;
  int _bufSize = 0;
  double _gain = 1.0;
  final StreamController<WinAudioException> _errors =
      StreamController.broadcast();

  /// The stream failed (e.g. device unplugged) and plays nothing any more.
  Stream<WinAudioException> get errors => _errors.stream;

  @override
  int write(Uint8List pcm) {
    if (_isClosed || pcm.isEmpty) return 0;
    if (_bufSize < pcm.length) {
      if (_buf != nullptr) malloc.free(_buf);
      _bufSize = pcm.length < 65536 ? 65536 : pcm.length;
      _buf = malloc<Uint8>(_bufSize);
    }
    _buf.asTypedList(pcm.length).setAll(0, pcm);
    final n = _owner._b.renderWrite(id, _buf, pcm.length);
    return n < 0 ? 0 : n;
  }

  @override
  void clear() {
    if (!_isClosed) _owner._b.renderClear(id);
  }

  double get gain => _gain;

  @override
  set gain(double value) {
    _gain = value;
    if (!_isClosed) _owner._b.renderSetGain(id, value);
  }

  @override
  int get bufferedMs {
    if (_isClosed) return 0;
    final ms = _owner._b.renderBufferedMs(id);
    return ms < 0 ? 0 : ms;
  }

  @override
  void _error(WinAudioException e) {
    if (!_errors.isClosed) _errors.add(e);
  }

  @override
  void _closed() {
    _isClosed = true;
    if (_buf != nullptr) {
      malloc.free(_buf);
      _buf = nullptr;
      _bufSize = 0;
    }
    unawaited(_errors.close());
  }
}
