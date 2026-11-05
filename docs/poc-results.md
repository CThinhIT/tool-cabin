# Kết quả PoC Phase 1

> Máy test: Windows 11 Pro build 26200, VS 2022 (MSVC 14.44), Windows SDK 10.0.26100.
> Công cụ: [poc/audio_probe](../poc/audio_probe/README.md).

## 1. Tự kiểm tra ngày 04/11/2026 (chưa có cuộc gọi Discord, chưa cài VB-Cable)

Các test dưới đây chạy tự động trên máy, **không** có cuộc gọi thật. Chúng chứng minh code và API hoạt động. Chúng **chưa** trả lời được câu hỏi quyết định: "process loopback có thu được giọng đối phương trong cuộc gọi Discord không".

| # | Test | Kết quả | Ý nghĩa |
|---|---|---|---|
| T1 | `rec-app --name opera.exe`: process loopback một trình duyệt Chromium đang phát nhạc | ✅ RMS −23 đến −27 dBFS, 100 gói/giây, `disc 0`, 99,4% thời gian thực | Process loopback **hoạt động trên build 26200** với app nền Chromium (Discord cũng là Chromium/Electron). Rủi ro R1 giảm nhưng chưa loại bỏ: stream *Communications* trong cuộc gọi có thể khác |
| T2 | Định dạng xin cho process loopback: 16 kHz, mono, PCM16 + `AUTOCONVERTPCM` | ✅ Được chấp nhận ngay lần thử đầu | Không cần thư viện resample (đúng thiết kế mục 3.1) |
| T3 | `rec-mic` (mic ảo DeskIn, mic mặc định hiện tại) 16 kHz mono | ✅ Chạy. Có 1 lần `disc` lúc khởi động (bình thường) | Đường thu mic hoạt động. **Máy hiện không có mic thật nào đang bật**: mic Realtek và webcam C270 ở trạng thái không hoạt động |
| T4 | `rec-both` mic + Opera đồng thời, 3 giây | ✅ Cả hai luồng chạy song song, không lỗi | Thu 2 nguồn cùng lúc được. Bài 30 phút vẫn chờ chạy (B8) |
| T5 | Cách ly: phát tone 440 Hz ra "Realtek Digital Output", đồng thời process-loopback Discord | ✅ File Discord = im lặng (−96,7 dBFS) trong khi loopback của thiết bị đó thấy tone | Âm thanh app mình phát **không lọt** vào bản thu của app khác (đúng giả định ở mục 2.2 câu 7) |
| T6 | `play` 24 kHz mono (định dạng TTS của AI) vào một thiết bị cụ thể | ✅ `AUTOCONVERTPCM` chấp nhận, buffer 100 ms; `SetDuckingPreference(TRUE)` thành công | Đường phát vào một thiết bị chọn trước hoạt động |
| T7 | `volume --set 0.5` rồi `--restore` | ✅ Đặt và khôi phục đúng, file backup bị xóa sau khi khôi phục | Cơ chế khôi phục volume (R11) hoạt động |
| T8 | **R12**: process-loopback tiến trình phát tone, giảm volume session của nó xuống 0,25 | ⚠️ **Mức thu giảm đúng 12 dB** (−13,5 → −25,5 dBFS), về lại khi khôi phục | Process loopback lấy âm thanh **sau** volume session. Giảm âm Discord thì tín hiệu gửi lên AI cũng nhỏ theo. Xem mục 2 |

Quan sát phụ: loopback của cả thiết bị "Realtek Digital Output" cho mức cao hơn tín hiệu gốc khoảng 8 dB, có thể do xử lý (APO) của driver. Kiến trúc không dùng loopback thiết bị nên không ảnh hưởng.

## 2. Hệ quả thiết kế đã rút ra

- **R12 đã được xác nhận.** Nếu giảm âm Discord bằng `ISimpleAudioVolume`, Pipeline B phải nhân bù gain `1/volume` trước khi gửi lên AI.
  - Volume 0,25 tương đương −12 dB. PCM16 vẫn còn đủ dải động, nhưng nên giữ volume ≥ 0,2.
  - Cách khác: không giảm âm Discord. Người dùng tự kéo âm lượng Discord trong Windows Volume Mixer và app bù theo giá trị đọc được.
- **Thiết kế định dạng (mục 3.1) đúng.** Thu 16 kHz mono và phát 24 kHz mono đều chạy bằng `AUTOCONVERTPCM`, không cần resampler.

## 3. Còn phải làm (cần bạn thao tác, xem docs/TASKS.md)

| Tiêu chí nghiệm thu Phase 1 | Trạng thái |
|---|---|
| ① WAV thu từ Discord nghe rõ giọng đối phương (B7, Standard và Legacy) | ⏳ cần cuộc gọi thật |
| ② Thu mic + Discord 30 phút không rớt khung (B8) | ⏳ cần mic thật và cuộc gọi |
| ③ Người ở điện thoại nghe rõ file tiếng Anh phát vào CABLE (B9) | ⏳ cần cài VB-Cable |
| ④ WAV thu Discord không lẫn âm thanh app phát ra tai nghe (B10) | ✅ đã chứng minh ngoài cuộc gọi (T5); test lại trong cuộc gọi |
| ⑤ Free tier Gemini có cho 2 phiên đồng thời không | ✅ **Có** (B13, mục 4): 2 phiên vi→en và en→vi chạy song song 70 giây, không bị cắt |

## 4. B13: Gemini Live Translate với key thật (05/11/2026, free tier)

Chạy bằng `poc/gemini_probe` (`with_key.ps1`). Đầu vào là file TTS tiếng Anh `en_dialog_48k_stereo.wav` (3 câu). Máy không có giọng TTS tiếng Việt, nên đầu vào tiếng Việt là bản dịch tiếng Việt Gemini vừa trả về, cắt còn 13 giây. Kết quả nằm trong `poc/gemini_probe/out/`.

| # | Hạng mục | Kết quả |
|---|---|---|
| G1 | Kết nối, xác thực | Bắt tay WebSocket 0,13–0,21 s, `setupComplete` 0,3–0,9 s. Key đặt trong header `x-goog-api-key` dùng được |
| G2 | Vị trí cài đặt transcript | Đặt ở cấp `setup` (mặc định của app): nhận được cả `inputTranscription` lẫn `outputTranscription`. Không cần thử cách còn lại |
| G3 | Dạng transcript | **Từng mẩu để nối vào**, có khoảng trắng đầu (`"Hi. Thanks for joining the"` rồi `" call today."`). Mẩu dịch đến sau mẩu gốc tương ứng 0,15–0,45 s. **Không có** `interimInputTranscription`, **không có** `turnComplete` |
| G4 | Audio ra | **Luồng liên tục, đúng nhịp thời gian thực**: mỗi gói 250 ms (12.000 byte, 24 kHz). Server luôn gửi trước khoảng **570 ms** và giữ nguyên mức đó (trễ không cộng dồn). Khoảng lặng là **số 0 tuyệt đối**. Sau `audioStreamEnd` server vẫn gửi im lặng cho tới khi client đóng |
| G5 | Trễ từng câu: bắt đầu nói → audio dịch có tiếng về tới máy | en→vi: **3,08 / 2,36 / 2,81 s**. vi→en: thời gian tới audio đầu tiên 3,1 s, các câu sau tương tự. Gemini dịch "nói đuổi" với độ trễ gần như cố định |
| G6 | 2 phiên đồng thời (vi→en + en→vi, 70 giây) | ✅ `BOTH_OK`: cả hai được nhận và không bị cắt, dịch đúng suốt 5 vòng lặp |
| G7 | `sessionResumptionUpdate` | Nhận 8–40 message **dù không bật** `sessionResumption`. Phase 3 có thể dùng cơ chế nối lại phiên chính thức (cần kiểm tra handle) |
| G8 | Chất lượng | Tự nhiên cả hai chiều: "Can you hear me clearly?" ↔ "Bạn có nghe rõ tôi (nói) không?"; "project timeline and the budget" → "tiến độ dự án và ngân sách" |

Ghi chú:
- Trong bài 2 phiên, khoảng giây thứ 37 cả hai phiên cùng bị *gửi trễ 842 ms*. Nguyên nhân nằm ở máy client (cả hai cùng khựng một lúc), không phải server. Một mẩu dịch bị mất ("ngân sách"). Cần theo dõi trong app.
- Cột "segments" của probe gộp mọi câu vào một đoạn, vì audio ra liên tục, không có khoảng ngắt ≥ 800 ms. Số ở G5 được tính lại theo năng lượng của file vào và file ra.

**Hệ quả cho app (đã sửa ngày 05/11, có test dựng lại đúng các mốc thời gian trên):**
- **Bỏ các gói im lặng tuyệt đối** thay vì phát chúng. Nếu không, 570 ms gửi trước nằm lại trong bộ đệm phát thành trễ thêm suốt cuộc gọi. Bộ phát tự phát im lặng khi rỗng, nên nhịp không đổi.
- Chỉ đo trễ theo các gói **có tiếng**, có tính vị trí bắt đầu có tiếng bên trong gói.
- Phụ đề tách dòng khi câu trước kết thúc bằng `. ? !` và mẩu mới đến sau ≥ 0,7 s.

**Hệ quả cho kế hoạch:** chỉ riêng model đã trễ khoảng 2,4–3,1 s, cao hơn ước lượng 0,8–1,5 s ở mục 4.4. Cộng thêm VB-Cable và Discord, tổng thời gian tới tai đối phương ước khoảng 2,6–3,6 s. Tiêu chí Phase 2 "trễ p90 ≤ 3 giây" **có nguy cơ không đạt, và nguyên nhân nằm ở model chứ không ở app**. Cần đo lại trong hội thoại thật (Phase 2 mục 7). Nếu đúng như vậy, có hai hướng: nới tiêu chí, hoặc so sánh với OpenAI `gpt-realtime-translate` (Phase 6).
