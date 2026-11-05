import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/engines/gemini/gemini_protocol.dart';
import '../../data/settings/app_settings.dart';
import '../../data/settings/settings_repository.dart';
import '../app.dart';
import '../cubits/devices_cubit.dart';
import '../cubits/settings_cubit.dart';
import '../cubits/translator_cubit.dart';
import '../widgets/common.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final running = context.select<TranslatorCubit, bool>(
      (c) => c.state.phase != TranslatorPhase.idle,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (running)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Notice('Đang dịch: thay đổi sẽ áp dụng ở lần bắt đầu sau.'),
                ),
              const _ApiKeySection(),
              const _CallCaptureSection(),
              const _ModelSection(),
              SectionCard(
                title: 'Log',
                children: [
                  SelectableText(
                    context.read<AppInfo>().logPath ?? 'Không ghi được file log',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Gửi file này khi báo lỗi. API key đã được che trong log.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApiKeySection extends StatefulWidget {
  const _ApiKeySection();

  @override
  State<_ApiKeySection> createState() => _ApiKeySectionState();
}

class _ApiKeySectionState extends State<_ApiKeySection> {
  final _controller = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    setState(() => _saving = true);
    try {
      await context.read<SettingsCubit>().saveApiKey(key);
      _controller.clear();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = context.select<SettingsCubit, ApiKeySource>(
      (c) => c.state.keySource,
    );
    return SectionCard(
      title: 'Gemini API key',
      children: [
        Text(switch (source) {
          ApiKeySource.stored => '✓ Đã lưu key (mã hóa trên máy này).',
          ApiKeySource.environment =>
            '✓ Đang dùng key từ biến môi trường ${SettingsRepository.apiKeyEnvVar}.',
          ApiKeySource.none => 'Chưa có key. Lấy key ở Google AI Studio.',
        }),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Dán API key mới',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Lưu'),
            ),
          ],
        ),
        if (source == ApiKeySource.stored)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context.read<SettingsCubit>().deleteApiKey(),
              child: const Text('Xóa key đã lưu'),
            ),
          ),
        const SizedBox(height: 8),
        const Notice(
          'Free tier: Google dùng dữ liệu gửi lên để cải thiện sản phẩm. Chỉ dùng '
          'cho cuộc gọi thử, không dùng cho cuộc gọi có thông tin nhạy cảm.',
        ),
      ],
    );
  }
}

class _CallCaptureSection extends StatelessWidget {
  const _CallCaptureSection();

  @override
  Widget build(BuildContext context) {
    final s = context.select<SettingsCubit, AppSettings>((c) => c.state.settings);
    final captures = context.select<DevicesCubit, List<({String id, String name})>>(
      (c) => [for (final d in c.state.captureDevices) (id: d.id, name: d.name)],
    );
    final cubit = context.read<SettingsCubit>();
    return SectionCard(
      title: 'Thu âm thanh cuộc gọi',
      children: [
        RadioListTile<CallCaptureMode>(
          contentPadding: EdgeInsets.zero,
          value: CallCaptureMode.processLoopback,
          groupValue: s.callCaptureMode,
          onChanged: (m) => cubit.update((x) => x.copyWith(callCaptureMode: m)),
          title: const Text('Thu trực tiếp từ app gọi (phương án chính)'),
          subtitle: const Text(
            'Process loopback: chỉ lấy âm thanh của app gọi, bạn vẫn nghe Discord bình thường.',
          ),
        ),
        RadioListTile<CallCaptureMode>(
          contentPadding: EdgeInsets.zero,
          value: CallCaptureMode.device,
          groupValue: s.callCaptureMode,
          onChanged: (m) => cubit.update((x) => x.copyWith(callCaptureMode: m)),
          title: const Text('Thu từ thiết bị (phương án dự phòng)'),
          subtitle: const Text(
            'Dùng khi phương án chính thu ra im lặng: Discord phát vào cáp ảo thứ 2 '
            '(CABLE-B), app thu từ "CABLE-B Output". Chưa có chế độ phát lại tiếng gốc.',
          ),
        ),
        if (s.callCaptureMode == CallCaptureMode.device)
          DevicePicker(
            label: 'Thiết bị thu âm thanh cuộc gọi',
            devices: captures,
            selectedId: s.callCaptureDeviceId,
            onChanged:
                (id) => cubit.update((x) => x.copyWith(callCaptureDeviceId: () => id)),
          ),
      ],
    );
  }
}

class _ModelSection extends StatefulWidget {
  const _ModelSection();

  @override
  State<_ModelSection> createState() => _ModelSectionState();
}

class _ModelSectionState extends State<_ModelSection> {
  late final TextEditingController _model = TextEditingController(
    text: context.read<SettingsCubit>().state.settings.geminiModel,
  );

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.select<SettingsCubit, AppSettings>((c) => c.state.settings);
    final cubit = context.read<SettingsCubit>();
    return SectionCard(
      title: 'AI (Gemini Live Translate)',
      children: [
        TextField(
          controller: _model,
          decoration: InputDecoration(
            labelText: 'Model',
            helperText: 'Mặc định: $defaultGeminiModel',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted:
              (v) => cubit.update(
                (x) => x.copyWith(
                  geminiModel: v.trim().isEmpty ? defaultGeminiModel : v.trim(),
                ),
              ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<TranscriptionPlacement>(
          isExpanded: true,
          value: s.transcriptionPlacement,
          decoration: const InputDecoration(
            labelText: 'Vị trí cài đặt transcript trong setup',
            border: OutlineInputBorder(),
            isDense: true,
            helperText:
                '⚠️ Hai trang tài liệu Google mâu thuẫn. Nếu không có phụ đề, đổi sang cách còn lại.',
            helperMaxLines: 2,
          ),
          items: const [
            DropdownMenuItem(
              value: TranscriptionPlacement.setup,
              child: Text('setup (theo API reference)', overflow: TextOverflow.ellipsis),
            ),
            DropdownMenuItem(
              value: TranscriptionPlacement.generationConfig,
              child: Text('setup.generationConfig (theo ví dụ Live Translate)', overflow: TextOverflow.ellipsis),
            ),
          ],
          onChanged:
              (p) => cubit.update((x) => x.copyWith(transcriptionPlacement: p)),
        ),
      ],
    );
  }
}
