// Hand-written bindings for src/win_audio.h (ffigen needs LLVM, which is not
// installed on the dev machine; the C API is ~18 functions).
//
// Keep in sync with src/win_audio.h.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

const waEventAudio = 1;
const waEventError = 2;
const waEventStopped = 3;
const waEventDiscontinuity = 4;
const waEventDevicesChanged = 5;

const waSourceDevice = 0;
const waSourceProcess = 1;
const waSourceDeviceLoopback = 2;

const waFlowRender = 0;
const waFlowCapture = 1;

typedef WaEventCallbackNative =
    Void Function(
      Int32 stream,
      Int32 kind,
      Int64 value,
      Pointer<Uint8> data,
      Int32 size,
    );

class WinAudioBindings {
  WinAudioBindings(DynamicLibrary lib)
    : init = lib.lookupFunction<
        Int32 Function(Pointer<NativeFunction<WaEventCallbackNative>>),
        int Function(Pointer<NativeFunction<WaEventCallbackNative>>)
      >('wa_init'),
      shutdown = lib.lookupFunction<Void Function(), void Function()>(
        'wa_shutdown',
      ),
      lastError = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'wa_last_error',
          ),
      free = lib.lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('wa_free'),
      nowUs = lib.lookupFunction<Int64 Function(), int Function()>(
        'wa_now_us',
        isLeaf: true,
      ),
      listDevices = lib.lookupFunction<
        Pointer<Utf8> Function(Int32),
        Pointer<Utf8> Function(int)
      >('wa_list_devices'),
      listSessions = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'wa_list_sessions',
          ),
      findRootPid = lib.lookupFunction<
        Uint32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('wa_find_root_pid'),
      captureStart = lib.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Uint32, Int32, Int32),
        int Function(int, Pointer<Utf8>, int, int, int)
      >('wa_capture_start'),
      renderStart = lib.lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, Int32),
        int Function(Pointer<Utf8>, int, int)
      >('wa_render_start'),
      renderWrite = lib.lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Uint8>, int)
      >('wa_render_write'),
      renderClear = lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'wa_render_clear',
      ),
      renderSetGain = lib.lookupFunction<
        Void Function(Int32, Float),
        void Function(int, double)
      >('wa_render_set_gain'),
      renderBufferedMs = lib
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'wa_render_buffered_ms',
          ),
      streamStop = lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'wa_stream_stop',
      ),
      sessionVolume = lib
          .lookupFunction<Float Function(Uint32), double Function(int)>(
            'wa_session_volume',
          ),
      sessionSetVolume = lib.lookupFunction<
        Int32 Function(Uint32, Float),
        int Function(int, double)
      >('wa_session_set_volume'),
      sessionRestore = lib.lookupFunction<Int32 Function(), int Function()>(
        'wa_session_restore',
      );

  final int Function(Pointer<NativeFunction<WaEventCallbackNative>>) init;
  final void Function() shutdown;
  final Pointer<Utf8> Function() lastError;
  final void Function(Pointer<Void>) free;
  final int Function() nowUs;
  final Pointer<Utf8> Function(int flow) listDevices;
  final Pointer<Utf8> Function() listSessions;
  final int Function(Pointer<Utf8> exe) findRootPid;
  final int Function(
    int source,
    Pointer<Utf8> deviceId,
    int pid,
    int sampleRate,
    int frameMs,
  )
  captureStart;
  final int Function(Pointer<Utf8> deviceId, int sampleRate, int capacityMs)
  renderStart;
  final int Function(int stream, Pointer<Uint8> pcm, int bytes) renderWrite;
  final void Function(int stream) renderClear;
  final void Function(int stream, double gain) renderSetGain;
  final int Function(int stream) renderBufferedMs;
  final void Function(int stream) streamStop;
  final double Function(int rootPid) sessionVolume;
  final int Function(int rootPid, double volume) sessionSetVolume;
  final int Function() sessionRestore;

  String lastErrorText() {
    final p = lastError();
    final s = p == nullptr ? '' : p.toDartString();
    return s.isEmpty ? 'unknown error' : s;
  }

  /// Decodes a heap string returned by the DLL and frees it.
  /// Returns null for NULL (failure).
  String? takeString(Pointer<Utf8> p) {
    if (p == nullptr) return null;
    try {
      return p.toDartString();
    } finally {
      free(p.cast());
    }
  }
}
