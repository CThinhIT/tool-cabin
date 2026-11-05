# Kiến trúc & Kế hoạch: AI phiên dịch giọng nói Việt ↔ Anh thời gian thực trên Windows

> Phiên bản 0.1 — 02/11/2026. Tài liệu chỉ phân tích, thiết kế và lập kế hoạch, **chưa có code**.
> Yêu cầu gốc: [README.md](../README.md).

---

## 0. Bối cảnh và quy ước

### 0.1 Các quyết định đã chốt

| # | Quyết định | Hệ quả thiết kế |
|---|---|---|
| 1 | Luôn dùng tai nghe khi gọi | MVP không cần khử tiếng vọng loa ngoài (AEC) |
| 2 | Chỉ cuộc gọi online, không có chế độ nói chuyện trực tiếp | Luôn tách được 2 nguồn: mic và app gọi |
| 3 | Đối phương **chỉ nghe tiếng Anh**. Bạn nghe **tiếng Anh gốc (giảm âm lượng) + tiếng Việt** | App gọi vẫn phát thẳng vào tai nghe; app mình chỉ "nghe lén" app gọi |
| 4 | Dùng VB-Audio Virtual Cable làm micro ảo | Không phải tự viết driver |
| 5 | Chỉ Việt ↔ Anh, không nói lẫn ngôn ngữ | Chiều dịch **cố định theo nguồn âm thanh**, không cần đoán |
| 6 | Test bằng AI miễn phí trước, chọn gói trả phí sau | MVP dùng Gemini Live Translate (free tier), thiết kế cho phép đổi nhà cung cấp |
| 7 | App gọi ưu tiên: **Discord desktop** | Phase 1 và 4 kiểm thử Discord trước |
| 8 | Không backend trong MVP, chỉ Windows 11 | API key lưu cục bộ, được dùng process loopback |
| 9 | **Flutter (Dart + Bloc)** cho toàn bộ app | C++ chỉ làm I/O âm thanh mà Flutter không làm được |

### 0.2 Ký hiệu độ tin cậy

- ✅ **Đã kiểm chứng (tài liệu)**: có trong tài liệu chính thức (link ở Phụ lục). *Chưa có nghĩa là đã chạy thử trên máy bạn.*
- ⚠️ **Giả thuyết**: suy luận hợp lý hoặc nguồn cộng đồng, **phải kiểm chứng bằng PoC**.
- ❓ **Chưa rõ**: không tìm thấy thông tin.

---

## 1. Đánh giá tính khả thi

**Kết luận: KHẢ THI CÓ ĐIỀU KIỆN.** Mọi khối kỹ thuật cần thiết đều có tài liệu chính thức. Có **một rủi ro có thể chặn phương án chính**: thu âm Discord bằng process loopback có thể ra im lặng. Rủi ro này đã có phương án dự phòng.

| Khối chức năng | Đánh giá | Trạng thái |
|---|---|---|
| Thu micro | WASAPI chuẩn, dễ | ✅ |
| Thu **riêng** âm thanh Discord (process loopback) | API có tài liệu (Windows build ≥ 20348). Có một báo cáo cộng đồng ngày 28/10/2026 trên build 26200 (đúng máy bạn): stream loại *Communications* bị thu ra im lặng, ví dụ Teams. **04/11: đã thu được Opera (Chromium) trên máy bạn, 16 kHz mono qua AUTOCONVERTPCM** ([poc-results.md](poc-results.md) T1) | ✅ API · ✅ chạy trên build 26200 · ⚠️ **Discord trong cuộc gọi có thu được không** |
| Dự phòng: Discord xuất ra một cáp ảo thứ 2 | Về nguyên lý chắc chắn chạy, vì chỉ là thu một thiết bị capture bình thường | ⚠️ cần đo độ trễ |
| Đưa tiếng Anh vào cuộc gọi | VB-Cable làm micro ảo, Discord chọn "CABLE Output" làm input | ✅ VB-Cable · ⚠️ bộ lọc của Discord có làm méo TTS không |
| Tiếng Việt chỉ vào tai bạn | App phát ra tai nghe. Process loopback chỉ lấy âm thanh Discord nên không thu lại tiếng Việt | ✅ nguyên lý · ⚠️ PoC |
| AI dịch giọng nói realtime Vi↔En, miễn phí để test | **Gemini 3.5 Live Translate**: speech-to-speech, có `vi`, free tier "Free of charge" | ✅ tài liệu · ⚠️ chất lượng, độ trễ, 2 phiên đồng thời trên free tier |
| Flutter ↔ C++ | `dart:ffi` + `NativeCallable.listener` (Dart ≥ 3.1) | ✅ |

**Những điều sản phẩm KHÔNG làm được (cần chấp nhận từ đầu):**

1. **Không dịch đồng thời không trễ.** Ước tính trễ **1,5–3 giây** từ lúc nói đến lúc bên kia nghe (⚠️ sẽ đo ở Phase 2).
2. **Hội thoại phải nói lần lượt.** Hai người nói chồng lên nhau thì cả hai đầu đều nghe lẫn lộn.
3. **Bạn phải đổi micro trong Discord/Zalo sang "CABLE Output".** Không có cách hợp lý nào khác để "chèn" âm thanh vào một app gọi của bên thứ ba.
4. **Khi AI mất kết nối, đối phương không nghe gì** (vì đã chọn "chỉ nghe tiếng Anh"). Vì vậy app cần một nút khẩn cấp để chuyển giọng thật thẳng vào cuộc gọi.

---

## 2. Những giới hạn kỹ thuật quan trọng nhất

### 2.1 Danh sách giới hạn

1. **Độ trễ không thể tránh**: AI phải nghe một đoạn mới dịch được. Cộng thêm mạng, VB-Cable và bộ đệm jitter của Discord.
2. **Process loopback có thể không thu được Discord** (⚠️). Microsoft không xác nhận nguyên nhân. → Dự phòng bằng cáp ảo thứ 2 (mục 4.2).
3. **Messenger desktop đã bị Meta khai tử ngày 15/12/2025** (✅). Gọi Messenger chỉ còn qua trình duyệt (messenger.com, facebook.com/messages), nên thu theo process sẽ lấy cả âm thanh các tab khác của trình duyệt.
4. **Gemini Live Translate là bản preview** (✅ model `gemini-3.5-live-translate-preview`):
   - có thể thay đổi hoặc ngừng;
   - *"Only audio input is supported"*: không nhận instruction, **không có glossary** cho tên riêng hay thuật ngữ;
   - *"Voice replication can be inconsistent"*;
   - **chọn giọng đọc: ❓ không thấy tài liệu**, nên có thể không đáp ứng được yêu cầu "Cấu hình giọng nói AI".
5. **Gemini free tier dùng dữ liệu để cải thiện sản phẩm** (✅ bảng giá: "Used to improve our products: Yes" ở Free Tier, "No" ở Paid Tier). Giới hạn số phiên đồng thời của free tier **không được công bố** (❓).
6. **Phiên Live API có giới hạn thời gian** (✅): kết nối khoảng 10 phút; phiên chỉ có audio tối đa 15 phút nếu không nén ngữ cảnh; handle resumption có hiệu lực 2 giờ. App phải tự nối lại liền mạch.
7. **Đổi âm lượng session của app khác được Windows lưu vĩnh viễn**, kể cả sau khi khởi động lại (✅). App crash lúc đang giảm âm Discord thì Discord bị nhỏ mãi.
8. **Có hai cơ chế tự giảm âm có thể làm nhỏ tiếng Việt của app** (✅). Cả hai phải tắt hoặc vô hiệu hóa:
   - Windows tự giảm âm khi có "communications activity" (mặc định giảm 80%);
   - Discord có tính năng "Attenuation".
9. **Chỉ chạy trên Windows 11**, vì process loopback cần build ≥ 20348 (✅).
10. **Bắt buộc dùng tai nghe.**

### 2.2 Trả lời 10 câu hỏi nghiên cứu (README mục 5)

**1. Windows lấy âm thanh cuộc gọi Messenger, Zalo, Discord bằng cách nào?**

Có ba cách, theo thứ tự ưu tiên:

| Cách | Mô tả | Vai trò |
|---|---|---|
| (a) Process loopback | Thu riêng âm thanh một process và các process con phát ra. *"The capture is not tied to a specific audio endpoint"* (✅) | **Phương án chính** |
| (b) Cáp ảo thứ 2 | App gọi xuất ra một cáp ảo riêng; app mình thu từ đó rồi tự phát lại vào tai nghe | **Dự phòng** (⚠️ đo trễ) |
| (c) Loopback cả thiết bị tai nghe | Thu toàn bộ mix trên tai nghe, kể cả tiếng Việt do app phát | Không dùng làm chính |

Theo từng app:
- **Discord** chạy trên Chromium, nhiều process (✅). Discord không công bố process nào phát voice (❓), nên dùng chế độ `INCLUDE_TARGET_PROCESS_TREE` từ process `Discord.exe` gốc. Báo cáo cộng đồng lẫn lộn: có người dùng OBS "Application Audio Capture" không thu được Discord (⚠️).
- **Zalo PC** là Electron (⚠️ bằng chứng từ sandbox năm 2024), process `Zalo.exe`. Kỳ vọng hoạt động giống Discord.
- **Messenger** chỉ còn bản web, nên thu theo process trình duyệt.

**2. WASAPI Loopback có thu được âm thanh các app này không?**
Có, với điều kiện app không dùng exclusive mode. Tài liệu ghi: *"Exclusive-mode streams cannot operate in loopback mode"* (✅). Lớp âm thanh Windows của WebRTC (upstream) chỉ khởi tạo shared mode (✅); bản fork của Discord có giữ nguyên hay không thì chưa rõ (⚠️). Loopback thiết bị thì thu cả mix, nên vẫn cần cách (a) hoặc (b).

**3. Có cần Windows Audio Session API để phân biệt từng app không?**
Có, nhưng để **tìm** app chứ không phải để tách âm thanh:
- Liệt kê các session đang phát (`IAudioSessionManager2`, ✅) để biết PID nào thuộc Discord, Zalo hay Chrome. Việc **tách** âm thanh do process loopback đảm nhận.
- Session API còn dùng để giảm âm Discord qua `ISimpleAudioVolume`. Microsoft khuyên không nên chỉnh volume của app khác nhưng không chặn (✅ khuyến nghị · ⚠️ hoạt động thực tế).

**4. Có thu micro và âm thanh hệ thống đồng thời được không?**
Có. Mỗi luồng dùng một `IAudioClient` riêng; không thấy tài liệu nào cấm (⚠️ PoC chạy 30 phút để xác nhận). Đồng hồ giữa các thiết bị lệch nhau cũng không gây hại, vì hai luồng không bao giờ bị trộn vào nhau.

**5. Làm sao phân biệt giọng tôi và giọng đối phương?**
**Theo nguồn**: mic thật là bạn, âm thanh process Discord là đối phương. Không cần nhận diện người nói. Với tai nghe, mic gần như không thu tiếng đối phương.

**6. Làm sao tránh micro thu lại âm thanh phiên dịch?**
Có ba lớp bảo vệ:
1. Tai nghe (đã chốt).
2. Tiếng Anh **không bao giờ phát ra loa**: nó đi thẳng vào VB-Cable bằng đường số, không qua không khí.
3. Bảo vệ tự nhiên từ AI: phiên A đặt `targetLanguageCode = "en"` và `echoTargetLanguage = false`. Nếu mic lỡ thu tiếng Anh của đối phương thì model không phát lại (✅ theo tài liệu · ⚠️ hành vi thực tế).

**7. Làm sao để tiếng Anh tới tai đối phương còn tiếng Việt chỉ vào tai nghe của tôi?**
- **Tiếng Anh**: app phát vào "CABLE Input". Discord dùng "CABLE Output" làm mic.
- **Tiếng Việt**: app phát vào tai nghe. Process loopback chỉ lấy âm thanh Discord, không lấy âm thanh của app mình, nên tiếng Việt không bị thu lại và không lọt vào cuộc gọi. Discord cũng không phát lại giọng mic của chính bạn.

**8. Làm sao tự động nhận diện chiều dịch khi hai người thay phiên nói?**
Không cần đoán. Hai luồng **chạy song song và độc lập (full-duplex)**, mỗi luồng có chiều cố định. Không có thao tác "chuyển chiều".

**9. Xử lý thế nào khi hai người nói cùng lúc?**
Hai luồng độc lập nên cả hai câu vẫn được dịch, nhưng âm thanh sẽ chồng nhau ở cả hai đầu. MVP chấp nhận điều này, và phụ đề vẫn hiện đủ cả hai. Tùy chọn cho sau MVP: tự giảm âm tiếng Việt khi bạn đang nói.

**10. Có hoạt động với cả cuộc gọi thoại và video không?**
Âm thanh đi cùng một đường nên về nguyên lý là như nhau (⚠️ cần test). Lưu ý: khi đối phương chia sẻ màn hình có tiếng (nhạc, video), âm thanh đó cũng bị thu và gửi đi dịch.

---

## 3. Kiến trúc tổng thể đề xuất

```
┌─────────────────────────────── Flutter app (Dart) ───────────────────────────────┐
│                                                                                  │
│   UI (widgets)  ◄────►  Blocs / Cubits                                           │
│                              │                                                   │
│                     TranslatorController  (bật/tắt, trạng thái, nút khẩn cấp)    │
│                 ┌────────────┴─────────────┐                                     │
│        DirectionPipeline A          DirectionPipeline B                          │
│        mic → (vi→en) → CABLE        Discord → (en→vi) → tai nghe                 │
│                 │  ▲                       │  ▲                                  │
│                 ▼  │                       ▼  │                                  │
│        TranslationEngine (interface)  ──►  GeminiLiveTranslateEngine (WebSocket) │
│                 │  ▲                                                             │
│        AudioService (Dart wrapper của plugin)                                    │
└─────────────────┼──┼─────────────────────────────────────────────────────────────┘
                  │  │   dart:ffi  (C API nhỏ, ~10 hàm)
┌─────────────────▼──┴──────────────── win_audio (C++ DLL) ───────────────────────┐
│  DeviceList │ MicCapture │ AppCapture (process loopback) │ Renderer ×2 │ SessionVolume │
└───────────────────────────── WASAPI / Windows Core Audio ───────────────────────┘
```

### 3.1 Nguyên tắc thiết kế

1. **C++ chỉ làm I/O âm thanh, không có logic nghiệp vụ.** Có ba việc bắt buộc phải là C++, vì Flutter và plugin phổ biến không làm được:
   - process loopback;
   - phát PCM streaming vào một thiết bị cụ thể (CABLE Input) với độ trễ thấp;
   - điều khiển session volume.

   Mic cũng thu trong C++ để mọi luồng âm thanh dùng chung định dạng, cơ chế và thời gian (xem mục 5).
2. **Để WASAPI tự chuyển định dạng**: mở stream ở đúng định dạng AI cần, dùng cờ `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | SRC_DEFAULT_QUALITY`. Như vậy không cần thư viện resample (✅ cờ có tài liệu · ⚠️ chất lượng chuyển đổi cần nghe thử).
   - Thu: 16 kHz, mono, PCM16.
   - Phát: 24 kHz, mono, PCM16.
3. **C++ gom âm thanh thành khung 100 ms**, đúng khuyến nghị của Gemini *"Send audio in chunks of 100ms"* (✅). Mỗi luồng chỉ khoảng 10 callback/giây sang Dart.
4. **Dart làm toàn bộ logic**: WebSocket, nối lại phiên, phụ đề, trạng thái, cài đặt.
5. **Chỉ có một interface trừu tượng: `TranslationEngine`.** Lý do: chắc chắn sẽ phải đổi hoặc so sánh nhà cung cấp (free → paid, Gemini ↔ OpenAI). **Không** tạo UseCase hay Repository cho từng hành động.
6. **Không backend.** API key lưu mã hóa cục bộ.

### 3.2 Hợp đồng `TranslationEngine` (mô tả, chưa phải code)

| Thành phần | Ý nghĩa |
|---|---|
| Mở phiên (ngôn ngữ nguồn, ngôn ngữ đích) | Mỗi chiều dịch là một phiên riêng |
| Gửi khung âm thanh | PCM16 16 kHz mono, khung 100 ms |
| Luồng sự kiện ra | Âm thanh đã dịch (PCM16 24 kHz) · văn bản gốc · văn bản đã dịch · trạng thái (đang kết nối, sẵn sàng, đang nối lại, lỗi) |
| Đóng phiên | Giải phóng tài nguyên |

Gemini Live Translate cung cấp đủ các sự kiện trên (✅). Cập nhật 04/11 sau khi đối chiếu tài liệu chính thức, chi tiết ở [poc/gemini_probe/README.md](../poc/gemini_probe/README.md):
- `inputAudioTranscription` và `outputAudioTranscription` là **cài đặt trong `setup`**. Sự kiện trả về tên là `serverContent.inputTranscription` và `serverContent.outputTranscription`.
- `targetLanguageCode` và `echoTargetLanguage` nằm trong `setup.generationConfig.translationConfig`, không nằm ở cấp đầu của `setup`.
- Hai trang tài liệu của Google mâu thuẫn nhau về vị trí của cài đặt transcription. `gemini_probe` thử được cả hai cách (⚠️ cần key thật).
- Tài liệu đã chuyển sang `aistudio.google.com/docs`. Link `ai.google.dev` cũ vẫn tự chuyển hướng.

### 3.3 C API của `win_audio` (danh sách chức năng)

| Nhóm | Chức năng |
|---|---|
| Khởi tạo | init (đăng ký callback sự kiện) · shutdown |
| Thiết bị | Liệt kê thiết bị thu và phát · liệt kê session đang phát (PID, tên process) · báo khi thiết bị thay đổi |
| Thu | Thu mic theo device id · thu app theo PID (process loopback, include tree) · thu một thiết bị capture (cho phương án dự phòng) · dừng thu |
| Phát | Mở output theo device id · ghi PCM vào bộ đệm vòng · đặt gain · xóa bộ đệm (khi ngắt lời hoặc dừng) |
| Session | Đặt volume session theo PID · khôi phục volume gốc |
| Sự kiện về Dart | Khung âm thanh 100 ms · mức âm lượng (VU) · lỗi · thiết bị thay đổi |

---

## 4. Sơ đồ luồng dữ liệu âm thanh

### 4.1 Phương án chính: process loopback

```
LUỒNG A — Bạn nói tiếng Việt → đối phương nghe tiếng Anh
─────────────────────────────────────────────────────────
 [Mic thật] ─WASAPI capture (16k mono)─► [win_audio] ─FFI, khung 100ms─► [Dart · Pipeline A]
                                                                             │ base64 / JSON
                                                                             ▼
                                                     [Gemini Live Translate · target = "en"]
                                                                             │ PCM 24k + transcript
                                                                             ▼
 Đối phương ◄─ Discord gửi đi ◄─ [Discord mic = "CABLE Output"] ◄─ VB-Cable ◄─ [win_audio render → "CABLE Input"]
                                                                             │
                                                                     phụ đề Vi / En lên UI


LUỒNG B — Đối phương nói tiếng Anh → bạn nghe tiếng Việt
─────────────────────────────────────────────────────────
 Đối phương ─► Discord.exe ─render─► [Tai nghe]   ← bạn nghe tiếng Anh gốc (đã giảm âm lượng)
                    │
                    └─ process loopback (INCLUDE tree của Discord) ─► [win_audio] ─FFI─► [Dart · Pipeline B]
                                                                                            ▼
                                                                  [Gemini Live Translate · target = "vi"]
                                                                                            ▼
 [Tai nghe] ◄─────────────── [win_audio render → tai nghe] ◄──────────────────────── PCM 24k + transcript
```

### 4.2 Phương án dự phòng: dùng khi Phase 1 cho thấy process loopback thu Discord ra im lặng

```
 Đối phương ─► Discord.exe ─render─► ["CABLE-B Input"]   (Discord Output device = cáp ảo thứ 2)
                                            │
                                     ["CABLE-B Output"] ─WASAPI capture─► [win_audio]
                                                                              ├─► phát lại tiếng Anh gốc (âm lượng nhỏ) → [Tai nghe]
                                                                              └─► Pipeline B → Gemini (vi) → [Tai nghe]
```

- Ưu điểm: chắc chắn thu được; giảm âm hoàn toàn do app mình kiểm soát, không phải can thiệp volume của Discord.
- Nhược điểm:
  - cần cài thêm một cáp ảo, phải kiểm tra license của VB-CABLE A+B hoặc Voicemeeter trước khi dùng (❓);
  - thêm một chặng trễ khi phát lại tiếng gốc;
  - **nếu app crash thì bạn không nghe được Discord.**

### 4.3 Bảng cấu hình thiết bị

| Nơi cấu hình | Mục | Giá trị |
|---|---|---|
| Discord → Voice & Video | Input device | **CABLE Output (VB-Audio Virtual Cable)** |
| | Output device | Tai nghe (phương án chính) hoặc CABLE-B (dự phòng) |
| | Input mode | Voice Activity, **tắt** "Automatically determine input sensitivity", đặt ngưỡng thấp. Không dùng Push to Talk |
| | Noise suppression / Echo cancellation / AGC | **Tắt** (TTS đã sạch; Krisp có thể làm méo, ⚠️ thử cả hai) |
| | Attenuation | **0%** (nếu không, Discord làm nhỏ tiếng Việt của app) |
| | Audio subsystem | Standard. Nếu loopback ra im lặng thì thử Legacy |
| Windows → Sound → Communications | Khi có cuộc gọi | **"Do nothing"** |
| Windows → thiết bị mặc định | Playback / Recording | Tai nghe và mic thật. **Không** để VB-Cable làm mặc định: sau khi cài, Windows có thể tự đặt CABLE làm mặc định (✅ manual VB-Cable) |
| App → Thu | Mic | Mic thật |
| | Âm thanh cuộc gọi | App đang phát: Discord (chọn từ danh sách session) |
| App → Phát | Tiếng Anh | CABLE Input |
| | Tiếng Việt | Tai nghe |

App cũng gọi `IAudioSessionControl2::SetDuckingPreference(TRUE)` cho stream phát của mình, để Windows không giảm âm tiếng Việt (✅).

### 4.4 Ngân sách độ trễ (cập nhật 05/11 theo số đo B13 trong [poc-results.md](poc-results.md) mục 4)

| Chặng | Ước lượng ban đầu | Đo được 05/11 |
|---|---|---|
| Bộ đệm thu WASAPI + gom khung 100 ms | 20–120 ms | |
| Mạng tới Gemini (từ Việt Nam) | 50–200 ms mỗi chiều ❓ | Bắt tay WebSocket 0,13–0,21 s |
| Model nghe đủ ngữ cảnh rồi bắt đầu dịch | **800–1.500 ms** ❓ | ❌ **Sai:** từ lúc bắt đầu nói tới lúc audio dịch về máy (đã gồm khung 100 ms và mạng) đo được **2,36–3,08 s** (3 câu). Model dịch "nói đuổi" với độ trễ gần như cố định |
| Bộ đệm phát | 30–80 ms | WASAPI 40 ms. Server gửi trước khoảng 570 ms; app bỏ các gói im lặng nên phần này không thành trễ cố định |
| VB-Cable | ≤ ~150 ms (trần bộ đệm mặc định 7168 mẫu ở 48 kHz; trễ thực thường thấp hơn) | chưa đo |
| Discord: mã hóa, mạng, jitter buffer phía bên kia | 100–300 ms ❓ | chưa đo |
| **Tổng (luồng A, tới tai đối phương)** | ~1,5–3 giây | **ước ~2,6–3,6 giây.** Tiêu chí p90 ≤ 3 s của Phase 2 có nguy cơ không đạt vì model |

---

## 5. Công nghệ cụ thể cho từng thành phần

| Thành phần | Công nghệ | Lý do chọn |
|---|---|---|
| App desktop | **Flutter 3.47 stable, Dart 3.13** (✅ phiên bản hiện hành 10/2026) | Yêu cầu của bạn; Flutter Windows ổn định |
| Quản lý trạng thái | **flutter_bloc 9.x**: Cubit cho phần đơn giản, Bloc khi có nhiều sự kiện | Yêu cầu của bạn. Cubit giảm code thừa |
| Âm thanh native | **C++17 + WASAPI**: `IMMDeviceEnumerator`, `IAudioClient`, `IAudioCaptureClient`, `IAudioRenderClient`, `ActivateAudioInterfaceAsync` (process loopback), `IAudioSessionManager2`, `ISimpleAudioVolume` | API gốc của Windows, có tài liệu, không phụ thuộc thư viện ngoài. Microsoft có sample `ApplicationLoopback` để bám theo |
| Định dạng và resample | Cờ `AUTOCONVERTPCM` của WASAPI | Không thêm thư viện. Nếu chất lượng kém mới thêm resampler (speexdsp, BSD) |
| Cầu nối Flutter ↔ C++ | **`dart:ffi` + `ffigen`**, `NativeCallable.listener` cho callback từ luồng âm thanh | Gọi được từ mọi thread (✅). Đơn giản hơn platform channel, vốn bắt buộc chạy trên main thread (✅) |
| Đóng gói plugin | **Template `plugin_ffi` (CMake)** | Flutter 3.38+ khuyên dùng `package_ffi` với build hooks (✅), nhưng module C++/COM cần link Windows SDK thì CMake vẫn là đường ít rủi ro nhất, và template này vẫn được hỗ trợ dưới tên "legacy". API C chỉ khoảng 10 hàm nên chuyển sang `package_ffi` sau rất rẻ |
| Micro ảo | **VB-Audio Virtual Cable** (donationware, hỗ trợ Windows 11, mặc định 48 kHz stereo) ✅ | Đã chốt. Tự viết driver ảo là kernel driver và cần chữ ký Microsoft |
| AI (MVP) | **Gemini 3.5 Live Translate** qua WebSocket | Miễn phí, speech-to-speech, có tiếng Việt, có transcript. Chi tiết ở mục 6 |
| WebSocket | `dart:io` `WebSocket` | Có sẵn trên desktop, không cần package |
| Lưu API key | `flutter_secure_storage` | Mã hóa cục bộ. Đủ an toàn cho máy cá nhân |
| Cài đặt | `shared_preferences` | Thiết bị đã chọn, âm lượng, ... |
| Cửa sổ phụ đề nổi (Phase 5) | `window_manager` | Cần cửa sổ always-on-top nhỏ khi đang gọi |
| Log | `logging` + ghi file | Debug các sự cố âm thanh xảy ra lúc đang gọi |
| Công cụ kiểm thử | Audacity (xem dạng sóng WAV) · điện thoại cài Discord làm "đối phương" | Đo im lặng, rớt khung, độ trễ |

**Không dùng, kèm lý do:**
- *Plugin `record` cho mic*: có thể thu mic trên Windows, nhưng loopback và render vẫn phải viết bằng C++. Tách mic sang một stack khác chỉ thêm phức tạp, trong khi code thu mic bằng C++ gần như giống hệt code thu loopback.
- *VAD (Silero/ONNX)*: chưa cần cho MVP. Tín hiệu từ VB-Cable và loopback là tín hiệu số sạch, mic qua tai nghe cũng khá sạch. Nếu cần cắt im lặng để tiết kiệm chi phí, bắt đầu bằng ngưỡng năng lượng đơn giản.
- *Node.js backend*: không cần cho công cụ cá nhân (đã chốt).

---

## 6. So sánh các phương án AI

### 6.1 Hai kiểu kiến trúc

| Tiêu chí | **Speech-to-Speech realtime** (một model) | **STT → Dịch → TTS** (ghép 3 dịch vụ) |
|---|---|---|
| Độ trễ | Thấp hơn: dịch trong khi người nói chưa dứt câu | Cao hơn: thường phải chờ hết câu mới dịch, cộng thêm trễ của từng chặng |
| Lượng code | Ít: 1 WebSocket mỗi chiều | Nhiều: 3 kết nối, phải tự chia câu và đồng bộ |
| Kiểm soát | Thấp: không glossary, chọn giọng hạn chế | Cao: glossary, chọn giọng, sửa văn bản trước khi đọc |
| Phụ đề | Có transcript vào và ra | Có sẵn vì văn bản là sản phẩm trung gian |
| Rủi ro khóa nhà cung cấp | Cao hơn | Thấp, thay từng khâu được |

**Đề xuất:** dùng **Speech-to-Speech cho MVP** vì ít code và trễ thấp. Chỉ chuyển sang pipeline khi cần glossary hoặc chọn giọng, hoặc khi chất lượng S2S không đạt.

### 6.2 Các nhà cung cấp (giá và giới hạn theo trang chính thức ngày 02/11/2026; giá tính cho **một** luồng)

| Phương án | Tiếng Việt | Kiểu | Miễn phí | Giá trả phí | Ghi chú quan trọng |
|---|---|---|---|---|---|
| **Gemini 3.5 Live Translate** `gemini-3.5-live-translate-preview` | ✅ vi/en | S2S qua WebSocket. Vào PCM16 16 kHz, ra 24 kHz | ✅ "Free of charge" (dữ liệu được dùng cải thiện sản phẩm) | $0.0053/phút vào + $0.0315/phút ra ✅ | Preview. Không instruction hay glossary. Số phiên đồng thời trên free tier ❓ |
| Gemini 3.8 Live (model hội thoại chung) | ✅ | S2S, dịch bằng prompt | ✅ | $0.005/phút vào + $0.018/phút ra ✅ | Model hội thoại có thể "trả lời" thay vì dịch. Không chọn làm chính |
| **OpenAI `gpt-realtime-translate`** | ✅ vi nằm trong 13 ngôn ngữ đầu ra | S2S qua WebRTC/WSS, 24 kHz | ❌ | $0.034/phút ✅ (đơn vị tính chính xác ❓) | Đối thủ trực tiếp của Gemini. Dùng để A/B khi chọn gói trả phí |
| Azure Speech Translation | ✅ vi-VN, giọng HoaiMy, NamMinh | STT + dịch + giọng đọc, có C++ SDK | ✅ F0: 5 giờ/tháng, nhưng **chỉ 1 phiên đồng thời**, nên không chạy được 2 chiều cùng lúc | $2.50/giờ ✅ | Ổn định, **chọn được giọng**. Phương án trả phí an toàn |
| Deepgram Nova-3 (chỉ STT) | ✅ STT · ❌ không có TTS tiếng Việt | Streaming | ✅ $200 credit, không cần thẻ | $0.0077/phút | Dùng trong pipeline |
| Google Cloud: Chirp 3 + Translation + Chirp 3 HD TTS | ✅ | Pipeline. Stream STT tối đa 5 phút | Translation 500K ký tự/tháng, TTS 1M ký tự/tháng, $300 credit cho khách mới. STT v2 không có phút miễn phí ✅ | STT $0.016/phút | Dùng trong pipeline |
| ElevenLabs Scribe v2 + Flash v2.5 | ✅ | Pipeline. Hãng công bố STT khoảng 150 ms, TTS khoảng 100 ms | ✅ 10.000 credit/tháng | STT $0.39/giờ | TTS chất lượng cao, có tiếng Việt |
| Soniox | ✅ | STT + dịch realtime | ❌ đã ngừng tặng credit | Khoảng $0.12–0.18/giờ (trang giá mâu thuẫn) | TTS giới hạn 2 phút mỗi stream |
| Groq (Whisper + LLM) | ⚠️ | **Không streaming** | ✅ có giới hạn | Rẻ | Chỉ hợp để nghịch thử |
| Chạy local (whisper.cpp + Piper vi) | ⚠️ | Offline | ✅ | Miễn phí | Cần GPU cho 2 luồng; chất lượng và trễ ❓. Không đưa vào MVP |

### 6.3 Ước tính chi phí khi trả phí, cho một giờ gọi cả hai chiều (⚠️ ước lượng)

Giả định: mỗi người nói khoảng 30 phút mỗi giờ, và giọng dịch dài xấp xỉ giọng gốc.

| Phương án | Cách tính | Ước tính mỗi giờ gọi |
|---|---|---|
| Gemini Live Translate | Vào 60–120 phút × $0.0053 + ra khoảng 60 phút × $0.0315 | **khoảng $2.2–2.5** |
| OpenAI translate | $0.034/phút × 60–120 phút (tùy tính theo phút nói hay phút mở phiên ❓) | **khoảng $2.0–4.1** |
| Azure S1 | $2.50/giờ × 1–2 luồng, chưa gồm giọng đọc ❓ | **khoảng $2.5–5+** |

Cắt phần im lặng trước khi gửi lên (Phase 6) giảm được phần chi phí đầu vào.

### 6.4 Khuyến nghị

1. **MVP: Gemini 3.5 Live Translate trên free tier.** Hai phiên WebSocket: phiên A `targetLanguageCode="en"`, phiên B `targetLanguageCode="vi"`, cả hai `echoTargetLanguage=false`.
   - Việc cần kiểm tra ngay ngày đầu: **free tier có cho 2 phiên đồng thời không.**
   - Chỉ test bằng file ghi âm hoặc cuộc gọi thử, vì dữ liệu free tier được dùng để cải thiện sản phẩm.
2. **Chọn gói trả phí sau Phase 2:** so sánh A/B giữa Gemini (paid tier) và OpenAI `gpt-realtime-translate`. Chỉ cần viết thêm một implementation của `TranslationEngine`, và chi phí test chỉ vài đô.
3. **Pipeline (Azure, hoặc Deepgram + Google/ElevenLabs)** chỉ khi:
   - cần chọn giọng hoặc glossary;
   - hoặc chất lượng S2S không đạt.

---

## 7. Cấu trúc project (mức thư mục, chưa có code)

```
E:\Tool\Trans\
├── README.md
├── docs\
│   ├── ARCHITECTURE.md          ← tài liệu này
│   ├── TASKS.md                 ← danh sách công việc theo thứ tự, ai làm gì
│   ├── poc-results.md           ← kết quả đo Phase 1 (tạo ở Phase 1)
│   └── setup-discord.md         ← hướng dẫn cấu hình VB-Cable, Discord, Windows
├── poc\
│   ├── audio_probe\             ← Phase 1: C++ console (CMake), KHÔNG phụ thuộc Flutter
│   │   └── src\                 ← liệt kê thiết bị/session, thu mic, thu app, phát file WAV
│   └── gemini_probe\            ← Phase 1: script Dart CLI gửi WAV tới Gemini, đo trễ
├── packages\
│   └── win_audio\               ← Flutter FFI plugin (Phase 2): mã C++ đã qua PoC
│       ├── src\                 ← C++: devices, capture, app_capture, renderer, session_volume, c_api.h
│       ├── lib\                 ← binding do ffigen sinh + lớp Dart mỏng (Stream khung âm thanh)
│       └── windows\             ← CMakeLists.txt
└── app\                         ← Flutter Windows app (Phase 2+)
    └── lib\
        ├── main.dart
        ├── core\                ← cấu hình, log, kiểu lỗi chung
        ├── domain\              ← entity (Direction, SubtitleLine, AudioDevice, AppSession)
        │                          + interface TranslationEngine
        ├── data\
        │   ├── audio\           ← AudioService (bọc win_audio)
        │   ├── engines\gemini\  ← GeminiLiveTranslateEngine (WebSocket, nối lại phiên)
        │   └── settings\        ← SettingsRepository (shared_preferences + secure storage)
        ├── translator\          ← DirectionPipeline (ghép audio ↔ engine cho 1 chiều)
        │                          + TranslatorController (quản lý 2 chiều, nút khẩn cấp)
        └── presentation\
            ├── cubits\          ← TranslatorCubit, DevicesCubit, SettingsCubit, SubtitlesCubit
            └── pages\           ← HomePage (một màn hình chính), SettingsPage, SubtitleOverlay
```

Lý do tách `poc\` riêng: Phase 1 phải chứng minh phần âm thanh **trước** và **độc lập** với Flutter. Debug COM/WASAPI trong một console app nhanh hơn nhiều so với debug qua FFI. Code đã chạy ổn thì chuyển sang `packages\win_audio`.

---

## 8. Roadmap từng phase

> Phase 3 được **định nghĩa lại** so với README: chiều dịch đã cố định theo nguồn, nên "Automatic Detection" chuyển thành *tự động hóa*: tự tìm app gọi, tự nối lại phiên, tự xử lý im lặng.

### Phase 1: Research & Proof of Concept (ưu tiên số một)

| Mục | Nội dung |
|---|---|
| Mục tiêu | Chứng minh trên máy bạn: **thu được mic và âm thanh Discord đồng thời**, đưa được âm thanh vào cuộc gọi qua VB-Cable, và tiếng Việt phát ra tai nghe không bị thu lại |
| Công việc | Xem mục 11 |
| Công nghệ | C++17, WASAPI, CMake, VB-Cable, Discord (máy tính + điện thoại), Audacity. Thêm script Dart CLI cho smoke test Gemini |
| Đầu ra | `poc/audio_probe`, các file WAV mẫu, `docs/poc-results.md`, **quyết định phương án thu âm cuộc gọi (chính hay dự phòng)** |
| Tiêu chí nghiệm thu | ① WAV thu từ Discord nghe rõ giọng đối phương, không phải im lặng · ② thu mic và Discord đồng thời 30 phút không rớt khung · ③ người nghe trên điện thoại nghe rõ file tiếng Anh phát vào CABLE · ④ WAV thu Discord không lẫn âm thanh app mình phát ra tai nghe · ⑤ biết được free tier Gemini có cho 2 phiên đồng thời không |
| Rủi ro | Process loopback thu Discord ra im lặng (⚠️ cao). Bộ lọc của Discord cắt hoặc méo TTS |
| Phụ thuộc | Cài Visual Studio Build Tools (C++), Windows SDK, VB-Cable. Cần một thiết bị thứ 2 có Discord. Có Google AI Studio API key |

### Phase 2: AI Translation Engine

| Mục | Nội dung |
|---|---|
| Mục tiêu | Dịch hai chiều Vi ↔ En chạy được trong app Flutter, với một UI debug đơn giản |
| Công việc | Chuyển C++ PoC thành plugin `win_audio` (ffigen, `NativeCallable.listener`, bộ đệm vòng phát) · `GeminiLiveTranslateEngine` (setup, gửi khung 100 ms, nhận audio và transcript, xử lý lỗi) · `DirectionPipeline` A rồi B · chạy 2 chiều song song · **đo độ trễ từng chặng** (gắn timestamp) · nút khẩn cấp: chuyển mic thẳng vào CABLE |
| Công nghệ | Flutter, dart:ffi, dart:io WebSocket, flutter_bloc |
| Đầu ra | App chạy được: nói tiếng Việt thì điện thoại nghe tiếng Anh; điện thoại nói tiếng Anh thì tai nghe nghe tiếng Việt; phụ đề thô |
| Tiêu chí nghiệm thu | Hội thoại thử 10 phút không crash · đo được độ trễ trung vị và p90 của mỗi chiều (mục tiêu ≤ 3 giây, ⚠️) · không có vòng lặp phản hồi |
| Rủi ro | Free tier chỉ cho 1 phiên (→ test từng chiều, hoặc nạp paid tier vài đô) · độ trễ hay chất lượng dịch không đạt (→ A/B với OpenAI) · lỗi luồng hoặc bộ nhớ qua FFI |
| Phụ thuộc | Phase 1 đạt tiêu chí ①–④ |

### Phase 3: Tự động hóa

| Mục | Nội dung |
|---|---|
| Mục tiêu | Không phải thao tác tay khi đang gọi |
| Công việc | Tự tìm PID Discord (hoặc Zalo, trình duyệt) từ danh sách session và theo dõi khi app khởi động lại · **nối lại phiên Gemini liền mạch**: xử lý thông báo GoAway, chủ động nối lại vào lúc im lặng trước mốc ~10 phút, thử session resumption (❓ Live Translate có hỗ trợ không) · tự khởi động lại khi thiết bị âm thanh thay đổi (rút hoặc cắm tai nghe) · tùy chọn tự giảm âm tiếng Việt khi bạn đang nói |
| Công nghệ | `IMMNotificationClient`, `IAudioSessionNotification`, logic trong Dart |
| Đầu ra | Gọi 30 phút liên tục không phải động tay |
| Tiêu chí nghiệm thu | Cuộc gọi 30 phút: các lần nối lại phiên không làm mất câu (hoặc mất dưới 1 giây âm thanh) · rút và cắm lại tai nghe thì app tự phục hồi |
| Rủi ro | Mỗi lần nối lại có thể làm mất nửa câu · giới hạn phiên đồng thời làm khó việc mở phiên mới trước khi đóng phiên cũ |
| Phụ thuộc | Phase 2 |

### Phase 4: Application Integration

| Mục | Nội dung |
|---|---|
| Mục tiêu | Xác nhận hoạt động với từng app gọi, gọi thoại lẫn gọi video |
| Công việc | Ma trận test: Discord (gọi 1-1, nhóm, video, chia sẻ màn hình) → Zalo PC → Messenger trên Chrome/Edge. Mỗi app: thu được không, bộ lọc mic của app có làm méo TTS không, thiết lập cần thiết. Viết `docs/setup-<app>.md` |
| Công nghệ | Như Phase 1–3. Có thể cần phương án dự phòng cho từng app |
| Đầu ra | Bảng tương thích có trạng thái **đã test thực tế** cho từng app |
| Tiêu chí nghiệm thu | Discord đạt đầy đủ. Zalo và Messenger: có kết luận rõ ràng (chạy, chạy kèm điều kiện, hoặc không chạy kèm lý do) |
| Rủi ro | Zalo hoặc Messenger dùng cơ chế âm thanh khiến process loopback ra im lặng · Messenger trên trình duyệt thu lẫn âm thanh tab khác (→ dùng một trình duyệt riêng chỉ để gọi) |
| Phụ thuộc | Phase 3 |

### Phase 5: Windows Desktop Application

| Mục | Nội dung |
|---|---|
| Mục tiêu | Giao diện hoàn chỉnh, dễ dùng, theo README mục 7 |
| Công việc | Một màn hình chính: trạng thái AI, mic và thu cuộc gọi (đèn và VU meter); chọn mic, chọn thiết bị phát tiếng Anh và tiếng Việt, chọn app gọi; bật/tắt dịch và phụ đề; thanh âm lượng · cửa sổ phụ đề nổi song ngữ · trang cài đặt (API key, giọng nếu engine hỗ trợ) · trình hướng dẫn kiểm tra cấu hình (VB-Cable đã cài chưa, Discord đã chọn CABLE chưa, chế độ Communications) · phím tắt cho nút khẩn cấp |
| Công nghệ | Flutter, flutter_bloc, window_manager, flutter_secure_storage |
| Đầu ra | Bản MVP dùng hằng ngày |
| Tiêu chí nghiệm thu | Từ lúc mở app tới lúc dịch được ≤ 3 thao tác · mọi cài đặt được nhớ sau khi khởi động lại |
| Rủi ro | Thấp. Yêu cầu "cấu hình giọng nói" có thể không làm được với Live Translate (❓) |
| Phụ thuộc | Phase 2 (có thể làm song song với Phase 3–4) |

### Phase 6: Optimization

| Mục | Nội dung |
|---|---|
| Mục tiêu | Giảm trễ, giảm chi phí, tăng ổn định, chốt nhà cung cấp trả phí |
| Công việc | A/B Gemini paid với OpenAI `gpt-realtime-translate` (và Azure nếu cần chọn giọng) · tinh chỉnh kích thước khung và bộ đệm · cắt im lặng trước khi gửi (đo xem có làm giảm chất lượng không) · tự giảm âm Discord với khôi phục an toàn khi crash (lưu volume gốc ra file, khôi phục khi khởi động lại) · đo CPU và RAM · log và báo lỗi |
| Đầu ra | Báo cáo so sánh nhà cung cấp, cấu hình tối ưu |
| Tiêu chí nghiệm thu | Độ trễ p90 giảm so với Phase 2 · chi phí mỗi giờ gọi được đo thực tế |
| Rủi ro | Model preview thay đổi API · giá thay đổi |
| Phụ thuộc | Phase 4 |

---

## 9. Ước tính độ khó và thời gian

Giả định: một developer Flutter làm toàn thời gian, phần C++ chủ yếu do AI coding assistant viết.

| Phase | Độ khó | Thời gian | Ghi chú |
|---|---|---|---|
| 1. PoC âm thanh | **Cao** | 1–2 tuần | COM/WASAPI khó debug kể cả khi có AI viết hộ. Nếu phải dùng phương án dự phòng thì cộng thêm vài ngày |
| 2. AI engine | Trung bình – Cao | ~2 tuần | Luồng FFI, bộ nhớ, giao thức WebSocket |
| 3. Tự động hóa | Trung bình | 0,5–1 tuần | Nối lại phiên là phần khó nhất |
| 4. Tích hợp app | Trung bình | ~1 tuần | Phụ thuộc vào app bên thứ ba |
| 5. Giao diện | Thấp – Trung bình | 1–2 tuần | Có thể làm song song |
| 6. Tối ưu | Trung bình | 1–2 tuần, làm tiếp liên tục | |
| **Tổng** | | **~7–10 tuần** | **Bản dùng được với Discord** sau khoảng 4–5 tuần (hết Phase 3) |

Nếu làm bán thời gian thì nhân khoảng 2.

---

## 10. Rủi ro và phương án giải quyết

| # | Rủi ro | Mức | Trạng thái | Phương án |
|---|---|---|---|---|
| R1 | Process loopback thu Discord ra im lặng | **Cao** | ⚠️ báo cáo cộng đồng (Teams, build 26200) | Test ngay ở Phase 1, thử cả 2 audio subsystem của Discord. Nếu vẫn lỗi thì dùng phương án cáp ảo thứ 2 (mục 4.2) |
| R2 | Free tier Gemini không cho 2 phiên đồng thời | Trung bình | ❓ không công bố | Test từng chiều; hoặc nạp paid tier (khoảng $2.2–2.5/giờ gọi) |
| R3 | Gemini Live Translate (preview) thay đổi hoặc bị ngừng | Trung bình | ✅ đang là preview | Interface `TranslationEngine`; OpenAI `gpt-realtime-translate` là phương án thay thế |
| R4 | Độ trễ lớn hơn 3 giây, hội thoại khó chịu | Trung bình | ⚠️ | Đo từng chặng; giảm bộ đệm; A/B nhà cung cấp. Chấp nhận nói lần lượt |
| R5 | Dịch sai tên riêng hoặc thuật ngữ, không có glossary | Trung bình | ✅ Live Translate không nhận instruction | Chuyển sang pipeline có glossary (Azure hoặc LLM) nếu thực sự cần |
| R6 | Không chọn được giọng đọc | Thấp – Trung bình | ❓ | Azure hoặc pipeline TTS có giọng vi-VN chọn được |
| R7 | Lộ nội dung cuộc gọi qua free tier | Trung bình | ✅ dữ liệu free tier được dùng cải thiện sản phẩm | Free tier chỉ dùng để test; cuộc gọi thật dùng paid tier |
| R8 | Phiên bị ngắt khoảng mỗi 10 phút làm mất câu | Trung bình | ✅ giới hạn có tài liệu | Nối lại chủ động lúc im lặng, xử lý GoAway (Phase 3) |
| R9 | Bộ lọc mic của Discord (Krisp, VAD, AGC) làm méo hoặc cắt TTS | Trung bình | ⚠️ | Tắt các bộ lọc; Voice Activity với ngưỡng thủ công |
| R10 | Windows ducking hoặc Discord Attenuation làm nhỏ tiếng Việt | Thấp | ✅ | `SetDuckingPreference(TRUE)`; Attenuation 0%; Communications đặt "Do nothing" |
| R11 | App crash khi đang giảm âm Discord, Discord nhỏ mãi | Thấp | ✅ volume được lưu vĩnh viễn | MVP: chỉnh tay. Phase 6: lưu volume gốc ra file và khôi phục khi khởi động |
| R12 | Giảm âm Discord làm nhỏ luôn tín hiệu thu loopback | Thấp – Trung bình | ✅ **đã đo 04/11**: có, giảm đúng tỉ lệ (volume 0,25 → −12 dB), xem [poc-results.md](poc-results.md) T8 | Pipeline B nhân bù gain `1/volume` trước khi gửi AI; giữ volume ≥ 0,2 |
| R13 | Messenger chỉ còn bản web, thu lẫn tab khác | Thấp | ✅ khai tử 15/12/2025 | Dùng một trình duyệt riêng chỉ để gọi |
| R14 | VB-Cable tự thành thiết bị mặc định sau khi cài | Thấp | ✅ manual | Bước kiểm tra trong hướng dẫn cài đặt và trong trình kiểm tra của app |
| R15 | Lỗi luồng hoặc bộ nhớ qua FFI làm crash app | Trung bình | ⚠️ | Bộ đệm do native sở hữu, quy tắc giải phóng rõ ràng; test chạy dài 1 giờ |
| R16 | Lộ API key | Thấp | – | Máy cá nhân; secure storage; giới hạn key trong Google Cloud Console; đặt cảnh báo ngân sách khi dùng paid tier |

---

## 11. Danh sách công việc đầu tiên để bắt đầu Phase 1

**Chuẩn bị (nửa ngày)**
1. Cài **Visual Studio 2022 Build Tools** (workload "Desktop development with C++") kèm Windows SDK. Cài Flutter stable. Cài Audacity.
2. Chuẩn bị **thiết bị thứ 2** (điện thoại) cài Discord bằng một tài khoản khác để làm "đối phương".
3. Cài **VB-Cable**: chạy setup bằng quyền Administrator, rồi **khởi động lại máy**. Kiểm tra lại thiết bị mặc định của Windows (tai nghe và mic thật). Đặt Sound → Communications → **"Do nothing"**.
4. Cấu hình Discord theo bảng 4.3. Riêng Input device: lúc đầu giữ mic thật, chuyển sang CABLE Output ở bước 9.

**Viết `poc/audio_probe` (C++ console, CMake), test từng lệnh**

5. Lệnh `list`: liệt kê thiết bị thu và phát, cùng các session đang phát âm thanh (PID, tên process). Kết quả cần có: thấy được Discord.exe khi đang gọi.
6. Lệnh `rec-mic <device>`: thu mic ra WAV 16 kHz mono (dùng `AUTOCONVERTPCM`).
7. Lệnh `rec-app <pid>`: process loopback `INCLUDE_TARGET_PROCESS_TREE` với PID Discord gốc, ghi ra WAV, **in RMS mỗi giây** để phát hiện im lặng.
   - Gọi Discord từ điện thoại; điện thoại phát một podcast tiếng Anh.
   - **Test với cả audio subsystem Standard và Legacy.**
   - Đây là bài test quyết định của cả dự án.
8. Lệnh `rec-both`: thu mic và Discord đồng thời trong 30 phút ra 2 file WAV; kiểm tra không rớt khung.
9. Lệnh `play <wav> <device>`: phát file tiếng Anh vào **CABLE Input**, lúc này Discord đã dùng CABLE Output làm mic. Kiểm tra người ở điện thoại nghe có rõ không, và đo trễ thô bằng cách vỗ tay.
10. Trong lúc `rec-app` đang chạy, phát một WAV tiếng Việt ra tai nghe. Kiểm tra WAV thu Discord **không** chứa tiếng Việt đó.
11. Thử giảm volume session Discord bằng `ISimpleAudioVolume`: xem mức thu của `rec-app` có giảm theo không (rủi ro R12), rồi **khôi phục volume gốc**.
12. **Nếu bước 7 thất bại:** kiểm tra license của VB-CABLE A+B hoặc Voicemeeter, cài một cáp ảo thứ 2, đặt Output device của Discord sang cáp đó, thu và phát lại vào tai nghe, rồi đo trễ.

**Smoke test AI (song song, khoảng 1 ngày, không xây dựng app)**

13. Lấy API key ở Google AI Studio. Viết `poc/gemini_probe` (Dart CLI):
    - gửi một file WAV tiếng Việt tới `gemini-3.5-live-translate-preview` với `targetLanguageCode="en"`;
    - lưu WAV kết quả và transcript;
    - đo **thời gian tới byte âm thanh đầu tiên**;
    - mở **2 phiên đồng thời** để biết giới hạn của free tier;
    - kiểm tra dùng API key trực tiếp từ client có được không (Google khuyên dùng ephemeral token cho client-side, ⚠️).

    Chỉ dùng file ghi âm thử.

**Kết thúc Phase 1**

14. Ghi kết quả vào `docs/poc-results.md`: RMS, ảnh dạng sóng, độ trễ, giới hạn phiên. **Chốt phương án thu âm cuộc gọi.** Cập nhật lại tài liệu này nếu có giả thuyết bị bác bỏ.

---

## Phụ lục: Nguồn tham khảo

**Windows audio (Microsoft)**
- Process loopback params: https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ns-audioclientactivationparams-audioclient_process_loopback_params
- PROCESS_LOOPBACK_MODE: https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ne-audioclientactivationparams-process_loopback_mode
- ActivateAudioInterfaceAsync: https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nf-mmdeviceapi-activateaudiointerfaceasync
- Sample ApplicationLoopback: https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/ · https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/ApplicationLoopback
- GetMixFormat không hỗ trợ trên process loopback (trả lời của Microsoft): https://learn.microsoft.com/en-us/answers/a/1183153
- Báo cáo thu ra im lặng (cộng đồng): https://github.com/microsoft/Windows-classic-samples/issues/414
- Loopback recording: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording
- AUDCLNT_STREAMFLAGS (AUTOCONVERTPCM): https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants
- IAudioSessionManager2: https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nn-audiopolicy-iaudiosessionmanager2
- Audio sessions (khuyến nghị không chỉnh volume app khác): https://learn.microsoft.com/en-us/windows/win32/coreaudio/audio-sessions
- ISimpleAudioVolume (volume được lưu vĩnh viễn): https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nn-audioclient-isimpleaudiovolume
- Stream attenuation / ducking: https://learn.microsoft.com/en-us/windows/win32/coreaudio/stream-attenuation · https://learn.microsoft.com/en-us/windows/win32/coreaudio/disabling-the-ducking-experience
- Tham khảo cách OBS dùng process loopback: https://github.com/obsproject/obs-studio/blob/master/plugins/win-wasapi/win-wasapi.cpp

**VB-Cable, Discord, Messenger, Zalo**
- VB-Cable: https://vb-audio.com/Cable/ · manual: https://vb-audio.com/Cable/VBCABLE_ReferenceManual.pdf
- Discord nhiều process: https://support.discord.com/hc/en-us/articles/225733808
- Discord voice troubleshooting: https://support.discord.com/hc/en-us/articles/360045138471
- Discord input sensitivity: https://support.discord.com/hc/en-us/articles/211376518
- Discord attenuation: https://support.discord.com/hc/en-us/articles/206342888
- WebRTC Windows audio (shared mode, Communications category): https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_device/win/core_audio_utility_win.cc
- Messenger desktop bị khai tử: https://techcrunch.com/2025/10/16/meta-to-shut-down-messenger-desktop-apps-for-mac-and-windows/ · https://www.facebook.com/help/messenger-app/1789649698300122

**Flutter / Dart**
- Bind native code (package_ffi, legacy plugin_ffi): https://docs.flutter.dev/platform-integration/bind-native-code
- NativeCallable.listener: https://api.dart.dev/stable/dart-ffi/NativeCallable/NativeCallable.listener.html
- Platform channels (yêu cầu main thread): https://docs.flutter.dev/platform-integration/platform-channels
- flutter_bloc: https://pub.dev/packages/flutter_bloc

**AI**
- Gemini Live Translate: https://ai.google.dev/gemini-api/docs/live-api/live-translate
- Gemini pricing: https://ai.google.dev/gemini-api/docs/pricing
- Gemini models: https://ai.google.dev/gemini-api/docs/models
- Live API session limits: https://ai.google.dev/gemini-api/docs/live-session
- Ephemeral tokens: https://ai.google.dev/gemini-api/docs/ephemeral-tokens
- OpenAI realtime translation: https://developers.openai.com/api/docs/guides/realtime-translation · pricing: https://developers.openai.com/api/docs/pricing
- Azure Speech pricing: https://azure.microsoft.com/en-us/pricing/details/speech/ · quotas: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits · languages: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-support
- Google Cloud STT Chirp 3: https://docs.cloud.google.com/speech-to-text/docs/models/chirp-3 · TTS Chirp 3 HD: https://docs.cloud.google.com/text-to-speech/docs/chirp3-hd
- Deepgram: https://deepgram.com/pricing · https://developers.deepgram.com/docs/models-languages-overview
- ElevenLabs models: https://elevenlabs.io/docs/overview/models
- Soniox: https://soniox.com/pricing
