# Danh sách công việc (theo thứ tự làm)

> Nguồn: [ARCHITECTURE.md](ARCHITECTURE.md) mục 8 và 11. Kết quả đo: [poc-results.md](poc-results.md).
> Ký hiệu: 🤖 Claude làm · 👤 bạn làm (cần thao tác tay hoặc thiết bị) · ✅ xong · 🔄 đang làm · ⏳ chưa làm

**Nguyên tắc sắp xếp:** làm xong và nghiệm thu từng phase mới sang phase sau. Ưu tiên số một là chứng minh thu được âm thanh cuộc gọi.

---

## ▶ Việc bạn cần làm tiếp theo

1. 👤 Cài **VB-Cable** (https://vb-audio.com/Cable/): chạy setup bằng quyền Administrator rồi **khởi động lại máy**.
2. 👤 Cắm **tai nghe có mic thật**. Hiện máy chỉ có mic ảo DeskIn đang hoạt động; mic Realtek và webcam C270 đang tắt.
3. ✅ API key đã có (lưu mã hóa DPAPI ở `%LOCALAPPDATA%\trans_app\gemini_key.dpapi`, dùng qua `poc/gemini_probe/with_key.ps1`). B13 đã chạy xong ngày 05/11. Với app: nhập key ở trang Cài đặt.
4. 👤 Chạy các lệnh trong mục 1C và dán kết quả vào chat. 🤖 Mình sẽ phân tích và chốt Phase 1.
5. 👤 Làm xong 1–3 thì có thể chạy thử app Phase 2 luôn (xem [app/README.md](../app/README.md)): gọi Discord với điện thoại, bấm **Bắt đầu dịch**, rồi gửi mình file log.

---

## Phase 1: Research & PoC (đang làm)

### 1A. Công cụ đo (🤖)

| # | Việc | Trạng thái |
|---|---|---|
| 1 | `poc/audio_probe` (C++/WASAPI): `list`, `rec-mic`, `rec-app` (process loopback), `rec-both`, `play`, `volume` | ✅ build sạch ở /W4, tự test T1–T8 đạt |
| 2 | `poc/gemini_probe` (Dart CLI): gửi WAV tới Gemini Live Translate với tốc độ thời gian thực, đo trễ, thử 2 phiên đồng thời | ✅ `dart analyze` sạch, 32 test đạt. Đã gọi thử endpoint thật bằng key giả và nhận đúng lỗi 1007. **Chưa chạy với key thật** |

### 1B. Chuẩn bị máy (👤, khoảng nửa ngày)

| # | Việc | Kiểm tra |
|---|---|---|
| 1 | Cài VB-Cable, khởi động lại | Dòng cuối của `audio_probe list` báo `installed`. Thiết bị mặc định vẫn là tai nghe và mic thật (VB-Cable hay tự chiếm mặc định) |
| 2 | Cắm tai nghe có mic | `audio_probe list` thấy mic đó trong danh sách Capture |
| 3 | Windows → Sound → Communications → **"Do nothing"** | |
| 4 | Điện thoại cài Discord bằng tài khoản thứ 2 | Gọi được giữa máy tính và điện thoại |
| 5 | Cấu hình Discord theo bảng 4.3 ARCHITECTURE. Lúc đầu giữ Input = mic thật | |
| 6 | API key Google AI Studio, đặt vào biến môi trường `GEMINI_API_KEY` | |

### 1C. Chạy test (👤 chạy lệnh, 🤖 đọc kết quả)

Lệnh cụ thể nằm trong [poc/audio_probe/README.md](../poc/audio_probe/README.md).

| Bước | Test | Tiêu chí | Trạng thái |
|---|---|---|---|
| B5 | `list` trong lúc gọi: thấy Discord.exe có session | | ⏳ |
| B7 | **`rec-app --name Discord.exe`**, điện thoại phát podcast. Thử cả audio subsystem Standard và Legacy | ① | ⏳ **quyết định cả dự án** |
| B8 | `rec-both` 30 phút | ② | ⏳ |
| B9 | Discord Input = CABLE Output, `play` vào CABLE Input, điện thoại nghe rõ | ③ | ⏳ cần VB-Cable |
| B10 | Phát tiếng ra tai nghe trong lúc `rec-app`; file Discord không chứa tiếng đó | ④ | ✅ ngoài cuộc gọi (T5), cần test lại trong cuộc gọi |
| B11 | Giảm volume Discord ảnh hưởng mức thu thế nào (R12) | | ✅ đã đo: giảm đúng tỉ lệ (T8) |
| B13 | `gemini_probe`: dịch file vi→en và en→vi, đo trễ, **2 phiên đồng thời**. Lệnh: xem [poc/gemini_probe/README.md](../poc/gemini_probe/README.md) | ⑤ | ✅ 05/11: 2 phiên song song OK. Trễ của model 2,4–3,1 s/câu, cao hơn ước lượng (poc-results mục 4) |

### 1D. Chốt Phase 1 (🤖)

- Ghi kết quả vào `poc-results.md`. **Chốt phương án thu âm cuộc gọi**: chính (process loopback) hay dự phòng (cáp ảo thứ 2).
- **Nếu B7 thất bại:**
  - 👤 cài cáp ảo thứ 2 (kiểm tra license VB-CABLE A+B hoặc Voicemeeter);
  - 🤖 thêm lệnh `monitor` vào `audio_probe` (thu CABLE-B rồi phát lại ra tai nghe) và đo trễ.
- Cập nhật ARCHITECTURE.md nếu giả thuyết nào bị bác bỏ.

---

## Phase 2: AI Translation Engine (code viết song song với Phase 1, từ 05/11)

Ngày 05/11 bạn chốt: viết code ngay, không chờ Phase 1. Phần lớn code không phụ thuộc kết quả B7; nếu B7 thất bại thì chỉ đổi nguồn thu, và chế độ thu từ thiết bị đã có sẵn.

| # | Việc | Ai | Trạng thái |
|---|---|---|---|
| 1 | Nâng Flutter | 🤖 | ⛔ Bỏ. Giữ **Flutter 3.29 / Dart 3.7** theo quyết định của bạn; bản này đủ cho `NativeCallable.listener` |
| 2 | `packages/win_audio`: FFI plugin chuyển từ `audio_probe`. C API 18 hàm, `NativeCallable.listener`, bộ đệm vòng cho phát, volume theo app có lưu/khôi phục | 🤖 | ✅ Smoke test native đạt 20/20 trên máy. **Binding viết tay**, không dùng ffigen vì máy chưa có LLVM |
| 3 | Khung app Flutter + Bloc theo cấu trúc mục 7 (`app/`) | 🤖 | ✅ Build Windows chạy được; đã xem giao diện trên máy |
| 4 | `TranslationEngine` + `GeminiLiveTranslateEngine` (chuyển từ `gemini_probe`, thêm tự nối lại) | 🤖 | ✅ Đã test với WebSocket server giả. ⏳ **Chưa chạy với key thật** |
| 5 | `DirectionPipeline` A và B chạy song song; **bù gain R12** theo volume Discord | 🤖 | ✅ Đã test với fake. ⏳ Chưa chạy với thiết bị thật |
| 6 | Đo trễ (từ lúc bắt đầu nói tới lúc bắt đầu nghe bản dịch, p50/p90); nút khẩn cấp đưa mic thẳng vào CABLE | 🤖 | ✅ |
| 7 | Hội thoại thử 10 phút. Nghiệm thu: không crash, trễ p90 ≤ 3 giây, không có vòng lặp phản hồi | 👤 + 🤖 | ⏳ Cần VB-Cable, mic thật, API key |

Đã kiểm chứng bằng key thật (B13, 05/11):
- transcript đến theo từng mẩu;
- đặt transcript ở cấp `setup` là đúng;
- free tier cho 2 phiên đồng thời.

Đã sửa app theo số đo:
- bỏ các gói im lặng Gemini gửi liên tục;
- đo trễ chỉ theo gói có tiếng;
- tách dòng phụ đề theo dấu câu, vì Gemini không gửi `turnComplete`.

⚠️ Trễ của model 2,4–3,1 s/câu làm tiêu chí ở mục 7 (p90 ≤ 3 giây) có nguy cơ không đạt.

Test: `app` 70 test, `win_audio` 3 test và smoke test native.

## Phase 3: Tự động hóa

1. 🤖 Tự tìm PID app gọi và theo dõi khi app khởi động lại.
2. 🤖 Nối lại phiên Gemini liền mạch: xử lý GoAway, nối lại lúc im lặng trước mốc khoảng 10 phút.
3. 🤖 Tự phục hồi khi rút hoặc cắm tai nghe.
4. 🤖 (Tùy chọn) Tự giảm âm tiếng Việt khi bạn đang nói.
5. 👤 Nghiệm thu: cuộc gọi 30 phút không phải động tay.

## Phase 4: Tích hợp app

1. 👤 + 🤖 Discord: gọi 1-1, gọi nhóm, video, chia sẻ màn hình.
2. 👤 + 🤖 Zalo PC.
3. 👤 + 🤖 Messenger trên trình duyệt (dùng một trình duyệt riêng chỉ để gọi).
4. 🤖 Viết `docs/setup-<app>.md` và bảng tương thích đã test thực tế.

## Phase 5: Giao diện (làm song song được với Phase 3–4)

1. 🤖 Màn hình chính: trạng thái và VU meter; chọn thiết bị và app gọi; bật/tắt dịch và phụ đề; âm lượng.
2. 🤖 Cửa sổ phụ đề nổi song ngữ (`window_manager`, luôn nằm trên).
3. 🤖 Trang cài đặt (API key trong secure storage); trình kiểm tra cấu hình (VB-Cable, Discord, Communications); phím tắt cho nút khẩn cấp.

## Phase 6: Tối ưu

1. 🤖 So sánh A/B Gemini paid và OpenAI `gpt-realtime-translate`; chốt nhà cung cấp trả phí.
2. 🤖 Tinh chỉnh kích thước khung và bộ đệm; cắt im lặng trước khi gửi; đo CPU và RAM.
3. 🤖 Giảm âm Discord kèm khôi phục an toàn khi crash: cơ chế lưu và khôi phục đã có sẵn trong `audio_probe volume`.
