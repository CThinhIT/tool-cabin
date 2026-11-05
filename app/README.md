# trans_app: phiên dịch Việt ↔ Anh cho cuộc gọi (Phase 2)

App Flutter Windows (Bloc) theo [ARCHITECTURE.md](../docs/ARCHITECTURE.md). Phần âm thanh dùng plugin [win_audio](../packages/win_audio/README.md), AI dùng Gemini Live Translate.

```
Bạn nói tiếng Việt ─ mic ─► Pipeline A ─► Gemini (en) ─► CABLE Input ─► Discord ─► đối phương
Đối phương nói tiếng Anh ─ Discord ─(process loopback)─► Pipeline B ─► Gemini (vi) ─► tai nghe của bạn
```

## Chạy

Cần Flutter 3.29 (bản đang có trên máy, giữ nguyên theo quyết định ngày 05/11) và Visual Studio 2022 C++.

```powershell
cd E:\Tool\Trans\app
flutter run -d windows                 # chạy debug
flutter build windows                  # ra build\windows\x64\runner\Release\trans_app.exe
```

Trước khi bấm **Bắt đầu dịch**:

1. Cài **VB-Cable**, khởi động lại máy. Trong Discord, chọn Voice & Video → Input Device = **CABLE Output**. Các mục khác cấu hình theo bảng 4.3 trong ARCHITECTURE.
2. Cắm **tai nghe có mic**. Trên màn hình chính, chọn mic thật và tai nghe. App sẽ báo lỗi nếu bạn chọn nhầm cáp ảo, vì như vậy sẽ tạo vòng lặp âm thanh.
3. Nhập **API key** trong Cài đặt. Key được lưu mã hóa bằng `flutter_secure_storage`. Nếu không nhập, app dùng biến môi trường `GEMINI_API_KEY`.
4. Mở Discord trước. App tự tìm `Discord.exe` và thu âm thanh của cả cây tiến trình.

Log nằm ở `%LOCALAPPDATA%\trans_app\logs\app-YYYYMMDD.log`. API key được che trong log.

## Cấu trúc `lib/`

| Thư mục | Nội dung |
|---|---|
| `core/` | Cấu hình định dạng, log (che key), xử lý PCM (mức dB, gain, resample 16→24 kHz), thống kê độ trễ |
| `domain/` | `Direction`, `SubtitleLine`, `CallApp`, interface **`TranslationEngine`** (abstraction duy nhất) |
| `data/audio/` | `AudioService`: bọc win_audio, cố định định dạng |
| `data/engines/gemini/` | Giao thức và `GeminiLiveTranslateEngine` (WebSocket, tự nối lại, giữ 5 s audio trong lúc nối lại) |
| `data/settings/` | `AppSettings` + `SettingsRepository` (shared_preferences + secure storage) |
| `translator/` | `routing.dart` (kiểm tra thiết bị, chặn vòng lặp), `DirectionPipeline` (một chiều dịch), `TranslatorController` (hai chiều, nút khẩn cấp, bù volume R12) |
| `presentation/` | 4 cubit (Translator, Devices, Settings, Subtitles), `HomePage`, `SettingsPage` |

## Đo trễ (Phase 2 mục 6)

Mỗi chiều hiển thị độ trễ của câu cuối cùng, p50 và p90.

**Định nghĩa:** tính từ lúc người nói *bắt đầu* một câu, tới lúc bản dịch của câu đó *bắt đầu được nghe*. Công thức là `thời điểm audio dịch đầu tiên tới + phần đang chờ phát trong bộ đệm − thời điểm bắt đầu nói`.

**Mốc "bắt đầu nói":** khung đầu tiên trên −45 dBFS, sau ít nhất 700 ms im lặng.

**Giới hạn:** chưa tính trễ của VB-Cable và của Discord ở phía đối phương. Đây là ước lượng 100–450 ms, xem mục 4.4.

## Test

```powershell
flutter test     # 70 test
```

Test bao gồm:
- PCM;
- giao thức Gemini;
- engine chạy với một WebSocket server giả cục bộ: setup, audio, transcript, lỗi key 1007, timeout, tự nối lại và phát lại audio, bỏ cuộc sau N lần;
- pipeline: gain, đo trễ, khẩn cấp, bộ đệm đầy;
- routing: các vòng lặp cần chặn;
- controller: dọn dẹp khi lỗi, R12, mất thiết bị;
- phụ đề;
- cài đặt;
- render hai trang.

## Đã kiểm chứng với key thật (B13, 05/11, xem docs/poc-results.md mục 4)

- Transcript đến theo **từng mẩu**. Không có `turnComplete` hay transcript tạm, nên phụ đề tách dòng theo dấu câu.
- Gemini gửi audio **liên tục đúng nhịp thời gian thực**, khoảng lặng là số 0. App bỏ các gói im lặng để không giữ khoảng 570 ms trễ thêm.
- Free tier cho **2 phiên đồng thời**.
- Trễ của model khoảng **2,4–3,1 s/câu**.

## Chưa kiểm chứng (cần thiết bị thật)

- ⚠️ Process loopback có thu được Discord **trong cuộc gọi** không (Phase 1, B7).
- Trễ thật tới tai đối phương, gồm cả VB-Cable và Discord.
- Chế độ dự phòng (thu từ CABLE-B) **chưa phát lại tiếng Anh gốc** ra tai nghe. Phần này chỉ làm nếu B7 thất bại.
