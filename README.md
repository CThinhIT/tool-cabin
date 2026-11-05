# PROMPT: XÂY DỰNG AI PHIÊN DỊCH GIỌNG NÓI THỜI GIAN THỰC TRÊN WINDOWS

## 1. Vai trò của bạn

Bạn là Senior Software Architect, Senior Flutter Developer và Windows Audio Engineer, có kinh nghiệm xây dựng:

- Ứng dụng Flutter Desktop trên Windows.
- Xử lý âm thanh bằng Windows Audio APIs.
- Audio capture, audio playback, audio routing và echo cancellation.
- AI Speech-to-Text, Text Translation và Text-to-Speech.
- Realtime Speech-to-Speech.
- WebSocket và streaming audio.

Bạn cần tư vấn, thiết kế kiến trúc và lập kế hoạch phát triển một ứng dụng AI phiên dịch cá nhân.

Hãy tư duy như một kỹ sư phần mềm thực tế. Ưu tiên tính khả thi, độ ổn định, độ trễ thấp và khả năng mở rộng. Không đề xuất kiến trúc phức tạp không cần thiết.

---

## 2. Mô tả sản phẩm

Tôi muốn xây dựng một ứng dụng AI phiên dịch giọng nói hai chiều theo thời gian thực trên Windows.

Mục đích là sử dụng ứng dụng trong khi giao tiếp với người nước ngoài thông qua những nền tảng có sẵn như:

- Facebook Messenger.
- Zalo.
- Discord.
- Các ứng dụng gọi thoại hoặc video khác trên Windows.

Đây là công cụ cá nhân. Chỉ có tôi cài đặt và sử dụng ứng dụng.

**Người đối thoại không cần cài ứng dụng, không cần tạo tài khoản, không cần tham gia phòng chat và không cần thực hiện bất kỳ thao tác cài đặt nào.**

Ứng dụng hoạt động độc lập bên cạnh Messenger, Zalo hoặc phần mềm gọi điện đang sử dụng.

## 3. Hai luồng phiên dịch chính

### Luồng A: Tôi nói tiếng Việt → Người kia nghe tiếng Anh

1. Tôi nói tiếng Việt qua microphone.
2. Ứng dụng thu âm giọng nói của tôi.
3. AI nhận diện nội dung tiếng Việt.
4. AI dịch sang tiếng Anh.
5. AI tạo giọng nói tiếng Anh tự nhiên.
6. Ứng dụng phát âm thanh tiếng Anh ra loa hoặc thiết bị đầu ra mà người đối thoại có thể nghe được.

### Luồng B: Người kia nói tiếng Anh → Tôi nghe tiếng Việt

1. Người đối thoại nói tiếng Anh trong cuộc gọi.
2. Ứng dụng thu được âm thanh từ cuộc gọi trên Windows.
3. AI nhận diện nội dung tiếng Anh.
4. AI dịch sang tiếng Việt.
5. AI tạo giọng nói tiếng Việt.
6. Ứng dụng phát tiếng Việt vào tai nghe của tôi.

### Yêu cầu bổ sung

- Tự động nhận diện ngôn ngữ Việt và Anh.
- Tự động xác định chiều phiên dịch.
- Hạn chế yêu cầu người dùng bấm nút chuyển chiều.
- Có phụ đề song ngữ theo thời gian thực.
- Hiển thị nội dung gốc và nội dung đã dịch.
- Hạn chế độ trễ tối đa có thể.
- Giọng nói đầu ra tự nhiên, dễ nghe.
- Xử lý được các câu nói liên tục, ngắt quãng và hội thoại thông thường.

Không yêu cầu xử lý nhiều người dùng cùng lúc.

---

## 4. Yêu cầu kỹ thuật

### Desktop Application

Ưu tiên sử dụng:

- Flutter Windows.
- Dart.
- Bloc để quản lý trạng thái.
- Kiến trúc Clean Architecture hoặc kiến trúc phân lớp phù hợp.

### Windows Audio Engine

Đây là phần quan trọng nhất của dự án.

Cần nghiên cứu và lựa chọn công nghệ có thể:

- Thu âm microphone.
- Thu âm thanh đầu ra của hệ thống Windows (WASAPI Loopback hoặc phương án tương đương).
- Phân biệt nguồn âm thanh microphone và âm thanh cuộc gọi.
- Chọn thiết bị đầu vào.
- Chọn thiết bị đầu ra.
- Phát âm thanh phiên dịch ra loa ngoài.
- Phát âm thanh phiên dịch vào tai nghe.
- Hạn chế tiếng vọng và hiện tượng microphone thu lại giọng phiên dịch.
- Hoạt động ổn định trong khi Messenger/Zalo đang gọi thoại hoặc video.

Có thể sử dụng C++ Native Windows Module nếu Flutter không đáp ứng đủ khả năng xử lý âm thanh.

Không cố gắng xử lý toàn bộ Windows Audio Routing bằng các Flutter plugin thông thường nếu chúng không đáp ứng yêu cầu.

### AI Engine

Nghiên cứu các phương án:

- Realtime Speech-to-Speech.
- Streaming Speech-to-Text → Translation → Text-to-Speech.
- Các API AI có hỗ trợ tiếng Việt và tiếng Anh.
- Khả năng streaming hai chiều.
- Độ trễ.
- Chi phí sử dụng.
- Chất lượng nhận diện giọng nói.
- Khả năng tự động nhận diện ngôn ngữ.

Ưu tiên giải pháp có khả năng xử lý realtime, nhưng cần so sánh với kiến trúc STT → Translation → TTS để lựa chọn phù hợp.

Không tự giả định một API hoặc model có khả năng hỗ trợ tất cả tính năng. Hãy kiểm tra tài liệu chính thức trước khi đưa ra kết luận.

### Backend

Có thể sử dụng Node.js nếu cần.

Backend chỉ phục vụ những nhiệm vụ cần thiết như:

- Bảo vệ API key.
- Cấp thông tin xác thực tạm thời cho client.
- Quản lý kết nối AI nếu cần.
- Xử lý những nghiệp vụ không nên đặt trực tiếp trong ứng dụng desktop.

Không xây dựng hệ thống tài khoản, phòng chat, hệ thống nhiều người dùng hoặc database lớn trong MVP.

---

## 5. Các vấn đề bắt buộc phải nghiên cứu

Trước khi đề xuất kiến trúc cuối cùng, hãy phân tích kỹ những vấn đề sau:

1. Windows có thể lấy âm thanh từ cuộc gọi Messenger, Zalo và Discord bằng cách nào?
2. WASAPI Loopback có thể thu âm thanh đầu ra của các ứng dụng này không?
3. Có cần sử dụng Windows Audio Session API để phân biệt âm thanh từng ứng dụng không?
4. Có thể thu âm microphone và âm thanh hệ thống đồng thời không?
5. Làm sao xác định giọng nói nào là của tôi và giọng nói nào là của đối phương?
6. Làm sao tránh microphone thu lại âm thanh phiên dịch được phát ra loa?
7. Làm sao phát tiếng Anh cho đối phương nghe được nhưng tiếng Việt chỉ phát vào tai nghe của tôi?
8. Làm sao tự động nhận diện chiều dịch khi hai người thay phiên nói?
9. Làm sao xử lý trường hợp hai người nói cùng lúc?
10. Có thể hoạt động với cả cuộc gọi thoại và video không?

Nếu có giới hạn kỹ thuật đối với Messenger hoặc Zalo, hãy nói rõ. Không được khẳng định rằng mọi ứng dụng đều tương thích nếu chưa có cơ sở kiểm chứng.

---

## 6. Roadmap dự kiến

Hãy xây dựng kế hoạch theo các giai đoạn:

### Phase 1: Research & Proof of Concept

Kiểm chứng khả năng thu âm microphone và âm thanh hệ thống Windows.

### Phase 2: AI Translation Engine

Xây dựng phiên dịch hai chiều Việt ↔ Anh.

### Phase 3: Automatic Detection

Tự động nhận diện ngôn ngữ, nguồn âm thanh và chiều dịch.

### Phase 4: Application Integration

Kiểm thử với Messenger, Zalo, Discord và các ứng dụng gọi thoại/video.

### Phase 5: Windows Desktop Application

Hoàn thiện giao diện, cấu hình âm thanh, phụ đề và các chức năng cần thiết.

### Phase 6: Optimization

Tối ưu độ trễ, chất lượng giọng nói, độ ổn định và chi phí AI.

Với từng phase, hãy xác định:

- Mục tiêu.
- Công việc cụ thể.
- Công nghệ cần sử dụng.
- Kết quả đầu ra.
- Tiêu chí nghiệm thu.
- Rủi ro kỹ thuật.
- Những phụ thuộc cần giải quyết trước.

---

## 7. Giao diện dự kiến

Ứng dụng có giao diện đơn giản, hiện đại, dễ sử dụng.

Các thành phần chính:

- Trạng thái kết nối AI.
- Trạng thái microphone.
- Trạng thái thu âm hệ thống.
- Lựa chọn thiết bị microphone.
- Lựa chọn thiết bị phát tiếng Anh.
- Lựa chọn thiết bị phát tiếng Việt.
- Bật/tắt phiên dịch.
- Bật/tắt phụ đề.
- Hiển thị nội dung gốc và nội dung dịch.
- Điều chỉnh âm lượng.
- Cấu hình giọng nói AI.

Không cần thiết kế quá nhiều màn hình ở giai đoạn MVP.

---

## 8. Nguyên tắc làm việc

Đây là những yêu cầu rất quan trọng:

1. Hiện tại chỉ cần phân tích, thiết kế kiến trúc và lập kế hoạch. Chưa viết code.
2. Không tự ý bắt đầu triển khai toàn bộ dự án.
3. Không tạo quá nhiều module hoặc layer không cần thiết.
4. Không đề xuất những công nghệ chỉ vì chúng phổ biến.
5. Mọi lựa chọn công nghệ phải có lý do rõ ràng.
6. Nếu có nhiều phương án, hãy so sánh ưu nhược điểm và đề xuất một phương án phù hợp nhất.
7. Ưu tiên tài liệu chính thức của Microsoft, Flutter và nhà cung cấp AI.
8. Phân biệt rõ tính năng đã được kiểm chứng và tính năng mới chỉ là giả thuyết.
9. Nếu có rủi ro khiến sản phẩm không thể hoạt động đúng yêu cầu, phải nêu ra ngay.
10. Không mở rộng phạm vi thành SaaS hoặc nền tảng chat nhiều người dùng.

---

## 9. Kết quả tôi muốn nhận được

Hãy trả lời theo cấu trúc:

1. Đánh giá tính khả thi của sản phẩm.
2. Những giới hạn kỹ thuật quan trọng nhất.
3. Kiến trúc tổng thể đề xuất.
4. Sơ đồ luồng dữ liệu âm thanh.
5. Công nghệ cụ thể cho từng thành phần.
6. So sánh các phương án AI.
7. Cấu trúc project ở mức thư mục/module, chưa cần code.
8. Roadmap từng phase.
9. Ước tính độ khó và thời gian phát triển.
10. Rủi ro và phương án giải quyết.
11. Danh sách công việc đầu tiên cần làm để bắt đầu Phase 1.

**Ưu tiên số một: Chứng minh khả năng thu được âm thanh cuộc gọi và microphone đồng thời trên Windows, sau đó mới xây dựng AI phiên dịch.**

Hãy đưa ra một kiến trúc thực tế, có thể triển khai bởi một developer Flutter với sự hỗ trợ của AI coding assistant.