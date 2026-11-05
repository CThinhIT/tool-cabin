# audio_probe: PoC âm thanh Phase 1

Ứng dụng console C++ (WASAPI), **không phụ thuộc Flutter**. Dùng để chứng minh các khối âm thanh trong [ARCHITECTURE.md](../../docs/ARCHITECTURE.md) mục 11 trước khi viết app.

## Build

Cần Visual Studio 2022 (workload *Desktop development with C++*) và CMake (máy này đã có sẵn cả hai).

```powershell
.\build.ps1          # → build\Release\audio_probe.exe
```

## Lệnh

| Lệnh | Việc |
|---|---|
| `list [--ids]` | Liệt kê thiết bị thu/phát, các session đang phát (PID, exe, volume), PID gốc của Discord/Zalo/trình duyệt, kiểm tra VB-Cable |
| `rec-mic [--device SEL] [--out mic.wav]` | Thu một thiết bị capture (mic thật) |
| `rec-dev --device SEL` | Giống `rec-mic`, dùng cho phương án dự phòng (thu "CABLE-B Output") |
| `rec-loopback [--device SEL]` | Thu toàn bộ mix của một thiết bị phát (để so sánh, không dùng trong kiến trúc) |
| `rec-app --name Discord.exe \| --pid N [--exclude] [--no-pad]` | **Process loopback**: chỉ thu âm thanh của cây tiến trình đó |
| `rec-both --mic SEL --name Discord.exe` | Thu mic và app **đồng thời**, ra 2 file WAV |
| `play --in file.wav \| --tone HZ [--beep] [--device SEL] [--gain G] [--loop]` | Phát vào **một thiết bị cụ thể** (ví dụ "CABLE Input") |
| `volume --name exe [--set 0..1]` / `volume --restore` | Đọc/đặt volume session của app khác. Volume gốc được lưu vào `%LOCALAPPDATA%\audio_probe\volume_backup.txt` |

Tùy chọn chung khi thu: `--seconds N` (mặc định chạy tới khi bấm Ctrl+C), `--rate 16000`, `--channels 1`.
`SEL` có thể là số thứ tự trong `list`, một phần tên thiết bị (`"CABLE Input"`), `default` hoặc `comm`.

Mỗi giây, các lệnh thu in ra RMS và peak (dBFS), số gói và số lần mất liên tục (`disc`). Khi kết thúc, chúng in `SUMMARY`:
- `NO DATA`: không nhận được gói nào trong giây đó.
- `silence`: có gói nhưng mức dưới −60 dBFS.
- `pad`: số mili giây im lặng được chèn thêm để file WAV khớp với đồng hồ thật. Process loopback không gửi gói khi app im, nên cần chèn.

File WAV thu ra là PCM16 16 kHz mono, đúng định dạng AI cần, nhờ `AUTOCONVERTPCM`. Mở bằng Audacity để xem dạng sóng.

## Kịch bản test Phase 1 (theo mục 11 của ARCHITECTURE.md)

Chuẩn bị: cài VB-Cable (chạy setup bằng quyền Admin, **khởi động lại máy**), điện thoại cài Discord bằng tài khoản thứ 2, và cấu hình Discord theo bảng 4.3.

```powershell
$p = ".\build\Release\audio_probe.exe"

# B5 - đang trong cuộc gọi Discord: phải thấy Discord.exe trong danh sách session
& $p list

# B6 - thu mic thật 10 giây
& $p rec-mic --device "Microphone" --seconds 10 --out b6_mic.wav

# B7 - BÀI TEST QUYẾT ĐỊNH: điện thoại phát podcast tiếng Anh vào cuộc gọi
& $p rec-app --name Discord.exe --seconds 30 --out b7_discord_standard.wav
#      Đổi Discord → Voice & Video → Audio Subsystem = Legacy, rồi thu lại:
& $p rec-app --name Discord.exe --seconds 30 --out b7_discord_legacy.wav

# B8 - thu mic + Discord đồng thời 30 phút (1800 s), kiểm tra disc = 0 và device audio ≈ 100%
& $p rec-both --mic "Microphone" --name Discord.exe --seconds 1800

# B9 - Discord Input device = "CABLE Output". Phát tiếng Anh vào CABLE Input, người ở điện thoại phải nghe rõ
& $p play --in en_sample.wav --device "CABLE Input"
& $p play --tone 1000 --beep --device "CABLE Input" --seconds 20    # tiếng bíp mỗi giây để ước lượng trễ

# B10 - trong lúc rec-app chạy, phát tiếng ra tai nghe ở cửa sổ khác. File Discord KHÔNG được chứa tiếng đó
& $p rec-app --name Discord.exe --seconds 20 --out b10.wav
& $p play --in vi_sample.wav --device "<tên tai nghe>"

# B11 - giảm âm Discord, sau đó LUÔN khôi phục
& $p volume --name Discord.exe --set 0.3
& $p volume --restore
```

Tạo file mẫu tiếng Anh bằng giọng TTS có sẵn của Windows:

```powershell
Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.SetOutputToWaveFile("$PWD\en_sample.wav"); $s.Speak("Hello, can you hear me clearly? This is a translation test."); $s.Dispose()
```

Kết quả ghi vào [docs/poc-results.md](../../docs/poc-results.md).
