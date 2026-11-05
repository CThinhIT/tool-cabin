# gemini_probe: smoke test Gemini Live Translate (Phase 1)

Công cụ dòng lệnh Dart thuần (không dùng Flutter). Nó gửi một file WAV tới **Gemini Live Translate** qua WebSocket thô, đúng như app thật sẽ làm, để trả lời các câu hỏi của Phase 1 (ARCHITECTURE.md §2.1 mục 4–6, §6, §11 bước 13):

| Câu hỏi | Lệnh trả lời |
|---|---|
| Dịch vi↔en có chạy không, chất lượng ra sao | `translate` (lưu WAV kết quả và transcript JSON) |
| **Thời gian tới byte âm thanh đầu tiên** (TTFA) và độ trễ theo từng câu | `translate` (in bảng timing) |
| Free tier có cho **2 phiên đồng thời** không | `concurrency` |
| Dùng API key trực tiếp có được không, hay phải dùng ephemeral token | `--auth header` / `--auth query` / `--auth ephemeral` |
| Live Translate có hỗ trợ session resumption không | `--resumption` |

> **Lưu ý về dữ liệu:** ở **free tier**, Google ghi rõ *"Used to improve our products: Yes"* ([bảng giá](https://aistudio.google.com/docs/pricing#gemini-3.5-live-translate-preview)). **Chỉ dùng file ghi âm thử**, không dùng cuộc gọi thật, tên người thật, số điện thoại hay bất kỳ thông tin nhạy cảm nào.

---

## 1. Chuẩn bị

Cần Dart 3.7 (đi kèm Flutter 3.29 trên máy này). Mở PowerShell:

```powershell
cd E:\Tool\Trans\poc\gemini_probe
$dart = "C:\Users\FASTBOY MARKETING\flutter\bin\dart.bat"
& $dart pub get
& $dart run bin/gemini_probe.dart --help
```

### Đặt `GEMINI_API_KEY` (chỉ cho phiên PowerShell hiện tại)

Công cụ **chỉ** đọc key từ biến môi trường `GEMINI_API_KEY`. Key không bao giờ được in ra, ghi vào log hay vào file kết quả.

Cách khuyên dùng (key không bị lưu vào lịch sử lệnh của PowerShell):

```powershell
$s = Read-Host "Gemini API key" -AsSecureString
$env:GEMINI_API_KEY = [System.Net.NetworkCredential]::new('', $s).Password
Remove-Variable s
```

Cách nhanh (lưu ý: PSReadLine sẽ lưu dòng lệnh này, kèm key, vào file lịch sử):

```powershell
$env:GEMINI_API_KEY = "AIza..."
```

Biến chỉ tồn tại trong cửa sổ PowerShell đó. Đóng cửa sổ là mất. Muốn xóa ngay thì chạy `Remove-Item Env:GEMINI_API_KEY`. **Không** dùng `setx`, vì `setx` lưu key vĩnh viễn.

Lấy key ở Google AI Studio. Lưu ý: giới hạn rate limit tính **theo project, không theo key** ([rate limits](https://aistudio.google.com/docs/rate-limits)), nên tạo 2 key trong cùng một project không giúp mở được thêm phiên.

---

## 2. Các lệnh

Mỗi lệnh có `--help` riêng, ví dụ `& $dart run bin/gemini_probe.dart translate --help`.

### `prepare`: offline, không cần key

Đọc WAV, trộn về mono và resample về 16 kHz giống hệt lúc gửi đi, rồi in thông số: thời lượng, số khung 100 ms, vị trí bắt đầu và kết thúc tiếng nói.

```powershell
& $dart run bin/gemini_probe.dart prepare --in samples/en_dialog_48k_stereo.wav --out out/dialog_16k.wav
```

### `translate`: dịch một file

```powershell
# Anh -> Việt (dùng file mẫu có sẵn)
& $dart run bin/gemini_probe.dart translate --in samples/en_dialog_48k_stereo.wav --target vi --out out/dialog_vi.wav --transcript out/dialog_vi.json

# Việt -> Anh (dùng file bạn tự ghi âm, xem mục 4)
& $dart run bin/gemini_probe.dart translate --in samples/vi_test.wav --target en --out out/vi_en.wav --transcript out/vi_en.json
```

Công cụ làm theo các bước sau:

1. Đọc WAV PCM ở mọi sample rate và số kênh (16/24/32-bit, 8-bit, float), trộn về mono rồi resample tuyến tính về **16 kHz PCM16**.
2. Kết nối, gửi `setup`, chờ `setupComplete`.
3. Gửi audio thành khung **100 ms, đúng tốc độ thời gian thực**, giống micro thật: khung thứ *i* được gửi lúc *(i+1) × 100 ms*, tức là khi micro thật vừa thu đủ khung đó.
4. Gửi tiếp 2 giây im lặng (`--tail-silence-ms`), rồi gửi `realtimeInput.audioStreamEnd` (tắt bằng `--no-stream-end`).
5. Tiếp tục nhận cho tới khi không có `serverContent` mới trong 5 giây (`--idle-timeout-ms`), với mức trần 60 giây (`--max-wait-ms`), hoặc tới khi server đóng kết nối.
6. Lưu audio nhận được ra WAV **24 kHz mono PCM16** (sample rate lấy theo `mimeType` server trả về), và lưu transcript vào/ra kèm mốc thời gian ra JSON.

Nhấn Ctrl+C một lần để dừng có kiểm soát: công cụ đóng phiên và vẫn ghi file kết quả. Nhấn lần hai để thoát ngay.

### `concurrency`: 2 phiên đồng thời

```powershell
# Cùng một file cho cả 2 phiên (A: target en, B: target vi), giữ cả hai phiên mở ít nhất 60 giây
& $dart run bin/gemini_probe.dart concurrency --in samples/en_dialog_48k_stereo.wav --echo --min-seconds 60 --out-dir out/conc

# Mỗi phiên một file, đúng như app thật: A nhận tiếng Việt, B nhận tiếng Anh
& $dart run bin/gemini_probe.dart concurrency --in-a samples/vi_test.wav --in-b samples/en_dialog_48k_stereo.wav --min-seconds 60 --out-dir out/conc
```

- Hai phiên được mở **cùng lúc**. Dùng `--stagger-ms` nếu muốn phiên B mở trễ hơn A.
- Kết quả là dòng `RESULT:` ở cuối:
  - `BOTH_OK`: cả 2 phiên được chấp nhận và không bị server cắt (exit code 0);
  - `ONE_REJECTED`: một phiên bị từ chối hoặc bị cắt, có in **close code và reason chính xác** (exit code 2);
  - `BOTH_FAILED`: cả hai đều hỏng (exit code 3). Khi đó hãy kiểm tra key và model bằng lệnh `translate` trước.
- Công cụ in thêm khoảng thời gian **cả hai phiên cùng mở** (overlap), để chứng minh hai phiên thật sự chạy song song.
- Vì sao ví dụ đầu có `--echo`: với `echoTargetLanguage=false` (mặc định, cũng là cấu hình của app), phiên A có target `en` nhận tiếng Anh thì **im lặng theo đúng tài liệu**. `--echo` buộc cả hai phiên cùng sinh audio, tức là tải gần với thực tế hơn.

### Tùy chọn chung (đều có trong `--help`)

| Tùy chọn | Ý nghĩa |
|---|---|
| `--echo` | `translationConfig.echoTargetLanguage = true` (mặc định `false`) |
| `--auth header` (mặc định) | Key nằm trong header `x-goog-api-key` lúc bắt tay WebSocket, giống cách SDK chính thức `python-genai` làm. Key không bao giờ xuất hiện trong URL |
| `--auth query` | Key nằm trong `?key=`, đúng như ví dụ trong tài liệu WebSocket |
| `--auth ephemeral` | Tạo token qua `POST /v1beta/auth_tokens`, rồi nối tới `BidiGenerateContentConstrained` với header `Authorization: Token …` |
| `--transcription-in setup` (mặc định) hoặc `generation-config` | Vị trí đặt `inputAudioTranscription`/`outputAudioTranscription`. Hai trang tài liệu chính thức mâu thuẫn nhau ở điểm này, xem mục 6 |
| `--resumption` | Thêm `sessionResumption: {}` và đếm số message `sessionResumptionUpdate` nhận được |
| `--no-stream-end` | Không gửi `audioStreamEnd`. Dùng khi server đóng kết nối ngay sau `audioStreamEnd` |
| `--chunk-ms 100` | Kích thước khung audio |
| `--min-seconds N` | Lặp file (mỗi lần cách nhau 1 giây) cho tới khi đã gửi ít nhất N giây audio |
| `-v`, `--verbose` | In JSON `setup` và **loại** của mọi message server gửi về. Không in nội dung audio, không in key |

### Exit code

| Code | Ý nghĩa |
|---|---|
| 0 | OK (phiên lên và không bị server cắt; với `concurrency`: cả 2 phiên) |
| 2 | Phiên lỗi hoặc bị cắt (`concurrency`: một phiên bị từ chối) |
| 3 | `concurrency`: cả 2 phiên lỗi |
| 64 | Sai tham số |
| 66 | Không đọc được file WAV |
| 78 | Chưa đặt `GEMINI_API_KEY` |

---

## 3. Đọc kết quả

**Mốc thời gian:** `t=0` là lúc "micro ảo" bắt đầu thu. Âm thanh ở vị trí *p* ms trong file coi như được nói lúc `t = p` ms. Các dòng có dạng `c=…` là thời gian tính từ lúc bắt đầu kết nối, tức là trước khi bắt đầu stream.

| Dòng trong bảng `== timing ==` | Ý nghĩa |
|---|---|
| `connect` | DNS + TCP + TLS + bắt tay WebSocket |
| `setup sent -> setupComplete` | Thời gian server chấp nhận cấu hình |
| `first chunk sent -> first audio byte` | **TTFA**: từ khung audio đầu tiên được gửi tới byte audio dịch đầu tiên nhận về |
| `speech onset -> first audio` | Từ lúc **bắt đầu có tiếng nói** trong file (năng lượng > −40 dBFS) tới audio dịch đầu tiên. Đây là con số gần nhất với độ trễ người dùng cảm nhận, đã gồm 100 ms gom khung, nhưng chưa gồm bộ đệm phát, VB-Cable và Discord |
| `first IN transcript -> first audio` | Từ transcript đầu vào đầu tiên tới audio dịch đầu tiên |
| `speech end -> last audio` | Từ lúc người nói dứt câu cuối tới byte audio dịch cuối cùng (độ trễ đuôi) |
| `pacing: max send lateness` | Khung gửi trễ nhất so với lịch thời gian thực. Nếu con số này lớn hơn khoảng 20 ms thì máy đang quá tải và các số đo trễ khác bị phóng đại |

Bảng `== segments ==` đo độ trễ **theo từng đoạn**. Một đoạn mới bắt đầu khi server gửi `turnComplete`, hoặc khi audio ra bị ngắt quãng ≥ 800 ms (chỉnh bằng `--segment-gap-ms`). Đây là **heuristic**: Live Translate dịch liên tục chứ không theo lượt, nên một câu có thể bị tách thành nhiều đoạn.

File JSON (`--transcript`, hoặc trong `--out-dir`) chứa:

- `setup` đã gửi, `timing`, `segments`;
- `events`: từng transcript vào/ra, từng gói audio (chỉ ghi số byte), `turnComplete`, `goAway`, …, mỗi mục có `tMs`;
- `session`: close code/reason, ai đóng phiên, đóng ở giai đoạn nào, lỗi;
- `messageTypeCounts`.

JSON luôn là UTF-8 đúng dấu tiếng Việt. Nếu tiếng Việt bị vỡ dấu trên cửa sổ console, chạy `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` trước.

---

## 4. File mẫu (`samples/`)

| File | Nguồn | Định dạng | Nội dung |
|---|---|---|---|
| `en_short.wav` | Windows TTS (giọng Zira) | 22,05 kHz, mono, 16-bit, 2,6 giây | "Hello, how are you today?" |
| `en_dialog_48k_stereo.wav` | Windows TTS (giọng David) | **48 kHz stereo** 16-bit (giống định dạng mặc định của VB-Cable), 12,6 giây | 3 câu, mỗi câu cách nhau 1,5 giây: "Hi, thanks for joining the call today." · "Can you hear me clearly?" · "Let us review the project timeline and the budget for next month." Dùng để thử đường downmix/resample và đo trễ theo từng câu |

**Chưa có file tiếng Việt**, vì máy này chỉ cài giọng TTS en-US (David, Zira). Để test chiều vi→en, hãy tự ghi 10–20 giây tiếng Việt có ngắt câu bằng Audacity (xuất *WAV, signed 16-bit PCM*, sample rate nào cũng được), lưu thành `samples/vi_test.wav`. Nhớ chỉ đọc nội dung thử, không có thông tin cá nhân.

Google cũng có một file mẫu chính thức dài 85 giây (24 kHz mono, đã đọc thử bằng `prepare`):

```powershell
Invoke-WebRequest https://storage.googleapis.com/generativeai-downloads/gemini-cookbook/audio/gemini-live-translate-sample.wav -OutFile samples\google_live_translate_sample.wav
```

---

## 5. Giao thức đã kiểm chứng (đọc tài liệu chính thức ngày 04/11/2026)

> Tài liệu `ai.google.dev/gemini-api/docs/...` hiện **chuyển hướng 301** sang `aistudio.google.com/docs/...`. Link trong ARCHITECTURE.md vẫn mở được nhờ chuyển hướng.

| Hạng mục | Giá trị | Nguồn |
|---|---|---|
| Endpoint | `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent` (v1beta). Đã gọi thử bằng **key giả**: server nâng cấp WebSocket rồi đóng với `1007 "API key not valid. Please pass a valid API key."`, cả với header `x-goog-api-key` lẫn `?key=` | [Live API reference](https://aistudio.google.com/api-reference/live/bidi-generate-content) · [WebSocket guide](https://aistudio.google.com/docs/live-api/get-started-websocket) |
| Xác thực | Tài liệu: `?key=API_KEY`. SDK `python-genai` dùng header `x-goog-api-key` | [WebSocket guide](https://aistudio.google.com/docs/live-api/get-started-websocket) · [mã nguồn SDK](https://github.com/googleapis/python-genai/blob/main/google/genai/live.py) |
| Model | `gemini-3.5-live-translate-preview` (preview, cập nhật 06/2026). Chỉ nhận audio vào, cho ra audio và transcript. Không hỗ trợ function calling hay thinking | [Live Translate](https://aistudio.google.com/docs/live-api/live-translate) · [Trang model](https://aistudio.google.com/docs/models/gemini-3.5-live-translate-preview) |
| Message đầu tiên | `{"setup": {"model": "models/gemini-3.5-live-translate-preview", "generationConfig": {"responseModalities": ["AUDIO"], "translationConfig": {"targetLanguageCode": "vi", "echoTargetLanguage": false}}, "inputAudioTranscription": {}, "outputAudioTranscription": {}}}`. Sau đó chờ `setupComplete` rồi mới gửi tiếp | [Live API reference](https://aistudio.google.com/api-reference/live) |
| `targetLanguageCode` | Mã BCP-47, có `vi` và `en`. Trang hướng dẫn ghi mặc định là `"en"`, còn trang reference ghi là *Required* | [Live Translate](https://aistudio.google.com/docs/live-api/live-translate) |
| `echoTargetLanguage` | Mặc định `false`: nếu đầu vào đã là ngôn ngữ đích thì model **im lặng**. `true` thì model nhại lại | như trên |
| Audio vào | `{"realtimeInput": {"audio": {"data": "<base64>", "mimeType": "audio/pcm;rate=16000"}}}`, PCM16 little-endian 16 kHz mono. Trang Live Translate khuyên **khung 100 ms** | [Live Translate](https://aistudio.google.com/docs/live-api/live-translate) |
| Audio ra | `serverContent.modelTurn.parts[].inlineData.data` (base64), PCM16 little-endian **24 kHz** mono | như trên · [Capabilities](https://aistudio.google.com/docs/live-api/capabilities) |
| Transcript | Bật bằng `inputAudioTranscription: {}` / `outputAudioTranscription: {}`. Nhận về qua sự kiện `serverContent.inputTranscription` / `serverContent.outputTranscription`, mỗi sự kiện có `text`, `languageCode`. Ngoài ra còn có `interimInputTranscription` | [Live API reference](https://aistudio.google.com/api-reference/live) |
| Kết thúc audio | `{"realtimeInput": {"audioStreamEnd": true}}`: *"When the audio stream is paused for more than a second … should be sent to flush any cached audio"*. Ví dụ CLI dịch chính thức của Google thì không gửi tín hiệu này, chỉ chờ 4 giây | [Capabilities](https://aistudio.google.com/docs/live-api/capabilities) · [ví dụ translate.py](https://github.com/google-gemini/gemini-live-api-examples/blob/main/command-line/python/translate.py) |
| Tín hiệu từ server | `generationComplete`, `turnComplete`, `interrupted`, `waitingForInput`, `goAway.timeLeft`, `sessionResumptionUpdate`, `usageMetadata`. Tài liệu không nói rõ frame dạng text hay binary (SDK đọc frame dưới dạng bytes), nên công cụ xử lý được cả hai | [Live API reference](https://aistudio.google.com/api-reference/live) |
| Giới hạn phiên | Kết nối khoảng **10 phút**. Phiên chỉ có audio tối đa **15 phút** nếu không bật nén ngữ cảnh. Token resumption có hiệu lực **2 giờ**. Server gửi `GoAway` (kèm `timeLeft`) trước khi đóng kết nối | [Session management](https://aistudio.google.com/docs/live-api/session-management) |
| Ephemeral token | `POST https://generativelanguage.googleapis.com/v1beta/auth_tokens` (header `x-goog-api-key`), mặc định `uses: 1`, phải mở phiên trong 1 phút, token hết hạn sau 30 phút. Nối tới `…BidiGenerateContentConstrained` bằng `?access_token=` hoặc header `Authorization: Token <token>`. Live Translate **bắt buộc dùng v1beta**. Đã gọi thử bằng key giả: nhận `400 INVALID_ARGUMENT API_KEY_INVALID`, nghĩa là endpoint có tồn tại | [Ephemeral tokens](https://aistudio.google.com/docs/live-api/ephemeral-tokens) · [Live Translate](https://aistudio.google.com/docs/live-api/live-translate) |
| Giá / free tier | Free tier: "Free of charge", *Used to improve our products: **Yes***. Paid: $0.0053/phút vào, $0.0315/phút ra | [Pricing](https://aistudio.google.com/docs/pricing#gemini-3.5-live-translate-preview) |
| Số phiên đồng thời | **Không công bố** ở đâu cả. Rate limit tính theo project, xem trong AI Studio. Model preview bị giới hạn chặt hơn | [Rate limits](https://aistudio.google.com/docs/rate-limits) |

### Chưa kiểm chứng (cần key thật để chạy lệnh)

- Vị trí `inputAudioTranscription` mà server chấp nhận: ở cấp `setup` (mặc định của công cụ) hay trong `generationConfig`.
- Model translate có nhận `audioStreamEnd` không.
- Model translate có gửi `turnComplete` hay `sessionResumptionUpdate` không.
- Ý nghĩa thực tế của các close code. Gợi ý in kèm close code (1007/1008/1011) là kinh nghiệm cộng đồng, chỉ có `1007 API key not valid` đã thấy thật.
- Free tier có cho 2 phiên đồng thời không. Đó là việc của lệnh `concurrency`.

---

## 6. Khác với ARCHITECTURE.md

1. `targetLanguageCode` và `echoTargetLanguage` không nằm ở cấp `setup` mà nằm trong `setup.generationConfig.translationConfig`.
2. `inputAudioTranscription` / `outputAudioTranscription` là **trường cấu hình** trong `setup`, không phải tên sự kiện. Sự kiện nhận về tên là `serverContent.inputTranscription` / `serverContent.outputTranscription`.
3. Chính tài liệu của Google mâu thuẫn nhau: ví dụ WebSocket trong trang Live Translate đặt hai trường transcription **trong** `generationConfig`, còn API reference và SDK đặt ở **cấp `setup`**. Công cụ mặc định theo API reference/SDK và có `--transcription-in generation-config` để thử cách còn lại.
4. "Send audio in chunks of 100ms" đúng với trang Live Translate. Trang Best practices chung của Live API lại khuyên **20–40 ms** (và 20–100 ms ở một đoạn khác). Có thể so sánh bằng `--chunk-ms 40`.
5. Trang Capabilities ghi API **tự resample nếu `mimeType` khai báo đúng rate**, tức là có thể gửi 48 kHz. Trang Best practices thì vẫn khuyên resample về 16 kHz trước khi gửi. Kế hoạch dùng `AUTOCONVERTPCM` về 16 kHz trong ARCHITECTURE.md vẫn hợp lệ.
6. Giới hạn 10 phút / 15 phút / 2 giờ và `GoAway` là tài liệu chung của Live API. Trang Live Translate không nhắc tới, nên chưa chắc model translate có hỗ trợ session resumption và nén ngữ cảnh (thử bằng `--resumption`).
7. Thư mục tài liệu đã chuyển từ `ai.google.dev` sang `aistudio.google.com` (có chuyển hướng 301).

---

## 7. Kiểm thử (không cần key)

```powershell
& $dart analyze
& $dart test
```

Bộ test gồm:

- đọc, ghi, trộn kênh, resample WAV (16/24-bit, float, EXTENSIBLE, chunk lạ, header streaming) và hai file mẫu;
- đúng hình dạng JSON của `setup`, audio, `audioStreamEnd`;
- parse message server;
- che key;
- một **server WebSocket giả lập trên localhost**, dùng để kiểm tra trọn luồng: nhịp gửi thời gian thực, nhận audio/transcript, `GoAway`, server từ chối lúc setup (1011), server cắt giữa chừng (1008), 2 phiên đồng thời trong đó một phiên bị từ chối, và bắt tay bị trả HTTP 403.

## 8. Cấu trúc

```
bin/gemini_probe.dart      CLI (package:args)
lib/src/commands.dart      lệnh translate / concurrency / prepare
lib/src/probe_run.dart     stream theo thời gian thực, đo trễ, gom đoạn, JSON
lib/src/live_session.dart  WebSocket (dart:io), bắt tay, setup, đóng, ephemeral token
lib/src/protocol.dart      endpoint, message setup/audio, parse message server
lib/src/wav.dart           đọc/ghi WAV, downmix, resample tuyến tính, dò tiếng nói
lib/src/secrets.dart       đọc GEMINI_API_KEY, che key trong mọi output
test/                      unit test + server giả lập
samples/                   WAV tiếng Anh tạo bằng Windows TTS
```
