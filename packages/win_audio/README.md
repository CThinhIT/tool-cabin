# win_audio

Flutter FFI plugin (Windows) lo phần I/O âm thanh của app phiên dịch, theo [ARCHITECTURE.md mục 3.3](../../docs/ARCHITECTURE.md). C++ **chỉ** làm I/O, mọi logic nằm ở Dart. Code được chuyển từ `poc/audio_probe`.

| Chức năng | Hàm C (`src/win_audio.h`) | Dart (`lib/src/win_audio_api.dart`) |
|---|---|---|
| Khởi tạo, nhận sự kiện | `wa_init`, `wa_shutdown` | `WinAudio.open()`, `dispose()` |
| Liệt kê thiết bị, session, tìm PID gốc của app | `wa_list_devices`, `wa_list_sessions`, `wa_find_root_pid` | `listDevices`, `listSessions`, `findRootPid` |
| Thu: mic, process loopback (cả cây tiến trình), thiết bị (phương án dự phòng) | `wa_capture_start` | `startCapture` → `CaptureStream.frames` |
| Phát vào một thiết bị, bộ đệm vòng | `wa_render_*` | `startRender` → `RenderStream` (`AudioSink`) |
| Volume theo app, lưu và khôi phục bản gốc | `wa_session_*` | `sessionVolume`, `setSessionVolume`, `restoreSessionVolumes` |
| Thiết bị thay đổi | sự kiện `WA_EVENT_DEVICES_CHANGED` | `devicesChanged` (debounce 300 ms) |

Định dạng do bên gọi chọn. App dùng: **thu PCM16 mono 16 kHz, khung 100 ms** và **phát PCM16 mono 24 kHz**. WASAPI tự chuyển đổi bằng `AUTOCONVERTPCM`.

## Thiết kế

- **Luồng:** mỗi stream có một thread MTA riêng, ưu tiên MMCSS "Audio". Các lệnh điều khiển (liệt kê, volume, đăng ký sự kiện thiết bị) chạy trên **một thread MTA cố định** (`ComWorker`). Lý do: thread UI của Flutter là STA.
- **Sự kiện sang Dart:** một callback `NativeCallable.listener`. Dữ liệu là bản sao trên heap, phía Dart giải phóng bằng `wa_free`.
- **Process loopback** không có gói nào khi app đích im lặng. Vì vậy luồng này được **đệm im lặng theo đồng hồ thật**, để AI không thấy thời gian bị nhảy.
- **Phát:** bộ đệm WASAPI 40 ms; bộ đệm vòng do bên gọi chọn (app dùng 60 s). Khi bộ đệm vòng rỗng thì phát im lặng, để CABLE luôn nhận luồng liên tục. Stream phát tự loại khỏi cơ chế ducking của Windows.
- **Volume theo app:** trước lần đổi đầu tiên, volume gốc được lưu vào `%LOCALAPPDATA%\trans_app\volume_backup.txt`. App gọi khôi phục mỗi lần khởi động (phòng trường hợp crash).
- **Binding FFI viết tay** (`lib/src/bindings.dart`), không dùng ffigen vì máy dev chưa có LLVM. Khi sửa `win_audio.h` thì phải sửa file này theo.

## Smoke test native (không cần Flutter)

```powershell
cd packages\win_audio\native_test
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
build\Release\win_audio_smoke.exe --pid <PID Discord>     # thêm --tone để nghe tiếng bíp nhỏ
```

Kết quả ngày 05/11/2026 trên máy dev: **ALL PASSED** cho 20 kiểm tra. Cụ thể:
- mic DeskIn và process loopback Discord (ngoài cuộc gọi) đều ra đúng 10 khung/giây, mỗi khung 3200 byte;
- bộ đệm phát chạy đúng thời gian thực; `clear` và giới hạn dung lượng hoạt động đúng;
- đọc được volume session của cả cây tiến trình Discord.

## Test Dart

```powershell
flutter test   # parse JSON của danh sách thiết bị/session, mã lỗi mất thiết bị
```
