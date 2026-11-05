import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:win_audio/win_audio.dart';

import '../../data/settings/app_settings.dart';
import '../../domain/direction.dart';
import '../../domain/subtitle_line.dart';
import '../../domain/translation_engine.dart';
import '../../translator/direction_pipeline.dart';
import '../../translator/translator_controller.dart';
import '../cubits/devices_cubit.dart';
import '../cubits/settings_cubit.dart';
import '../cubits/subtitles_cubit.dart';
import '../cubits/translator_cubit.dart';
import '../widgets/common.dart';
import 'settings_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Phiên dịch Việt ↔ Anh'),
        actions: [
          IconButton(
            tooltip: 'Làm mới danh sách thiết bị',
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<DevicesCubit>().refresh(),
          ),
          IconButton(
            tooltip: 'Cài đặt',
            icon: const Icon(Icons.settings_outlined),
            onPressed:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          const controls = [_ControlCard(), _DevicesCard(), _StatsCard()];
          if (c.maxWidth < 900) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ...controls,
                const SizedBox(height: 480, child: _SubtitlesPanel()),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 440,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: controls,
                ),
              ),
              const VerticalDivider(width: 1),
              const Expanded(child: _SubtitlesPanel()),
            ],
          );
        },
      ),
    );
  }
}

class _ControlCard extends StatelessWidget {
  const _ControlCard();

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TranslatorCubit>().state;
    final settings = context.watch<SettingsCubit>().state.settings;
    final snap = t.snapshot;
    return SectionCard(
      title: 'Điều khiển',
      children: [
        SizedBox(
          height: 44,
          child:
              t.isRunning
                  ? FilledButton.tonalIcon(
                    onPressed: () => context.read<TranslatorCubit>().stop(),
                    icon: const Icon(Icons.stop),
                    label: const Text('Dừng'),
                  )
                  : FilledButton.icon(
                    onPressed:
                        t.isBusy
                            ? null
                            : () => context.read<TranslatorCubit>().start(
                              context.read<SettingsCubit>().state.settings,
                            ),
                    icon:
                        t.isBusy
                            ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : const Icon(Icons.play_arrow),
                    label: Text(
                      t.phase == TranslatorPhase.starting
                          ? 'Đang kết nối...'
                          : 'Bắt đầu dịch',
                    ),
                  ),
        ),
        if (t.error != null) ...[
          const SizedBox(height: 8),
          Notice(t.error!, isError: true),
        ],
        const SizedBox(height: 12),
        for (final d in Direction.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(child: Text(d.label)),
                if (t.isRunning && snap != null)
                  StatusChip(status: snap.of(d).status)
                else
                  const Text('—'),
              ],
            ),
          ),
        if (t.isRunning && snap != null)
          for (final d in Direction.values)
            if (snap.of(d).statusMessage != null &&
                snap.of(d).status != EngineStatus.ready)
              Notice('${d.shortLabel}: ${snap.of(d).statusMessage}'),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: snap?.bypass ?? false,
          onChanged:
              t.isRunning
                  ? (on) => context.read<TranslatorCubit>().setBypass(on)
                  : null,
          title: const Text('Khẩn cấp: gửi giọng thật'),
          subtitle: const Text(
            'Tạm tắt dịch Việt → Anh. Đối phương nghe giọng bạn qua CABLE.',
          ),
        ),
        _VolumeSlider(
          label: 'Âm lượng tiếng Việt (tai nghe)',
          value: settings.vietnameseVolume,
          onChanged: (v) {
            context.read<SettingsCubit>().update(
              (s) => s.copyWith(vietnameseVolume: v),
            );
            context.read<TranslatorCubit>().setVolumes(vietnamese: v);
          },
        ),
        _VolumeSlider(
          label: 'Âm lượng tiếng Anh (gửi đối phương)',
          value: settings.englishVolume,
          onChanged: (v) {
            context.read<SettingsCubit>().update(
              (s) => s.copyWith(englishVolume: v),
            );
            context.read<TranslatorCubit>().setVolumes(english: v);
          },
        ),
      ],
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ${(value * 100).round()}%',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Slider(
          value: value.clamp(0.0, 2.0),
          max: 2.0,
          divisions: 40,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _DevicesCard extends StatelessWidget {
  const _DevicesCard();

  @override
  Widget build(BuildContext context) {
    final dev = context.watch<DevicesCubit>().state;
    final settings = context.watch<SettingsCubit>().state.settings;
    final running = context.select<TranslatorCubit, bool>(
      (c) => c.state.phase != TranslatorPhase.idle,
    );
    final cubit = context.read<SettingsCubit>();

    List<({String id, String name})> items(List<AudioDeviceInfo> list) => [
      for (final d in list)
        (id: d.id, name: d.isDefault ? '${d.name}  (mặc định)' : d.name),
    ];
    String? orDefault(String? id, List<AudioDeviceInfo> list) =>
        id ?? list.where((d) => d.isDefault).firstOrNull?.id;

    final micId = orDefault(settings.micDeviceId, dev.captureDevices);
    final headsetId = orDefault(settings.headsetDeviceId, dev.renderDevices);
    final cableId = settings.cableDeviceId ?? dev.cableInput?.id;
    final mic = dev.captureDevices.where((d) => d.id == micId).firstOrNull;
    final headset = dev.renderDevices.where((d) => d.id == headsetId).firstOrNull;

    return SectionCard(
      title: 'Thiết bị',
      children: [
        if (dev.error != null) Notice(dev.error!, isError: true),
        DevicePicker(
          label: 'Mic của bạn',
          devices: items(dev.captureDevices),
          selectedId: micId,
          enabled: !running,
          onChanged: (id) => cubit.update((s) => s.copyWith(micDeviceId: () => id)),
        ),
        if (mic != null && mic.isVirtualCable)
          const Notice('Mic đang là cáp ảo. Chọn mic thật của tai nghe.', isError: true),
        if (settings.callCaptureMode == CallCaptureMode.processLoopback)
          _CallAppPicker(enabled: !running)
        else
          Notice(
            'Chế độ dự phòng: thu âm thanh cuộc gọi từ thiết bị '
            '"${dev.captureDevices.where((d) => d.id == settings.callCaptureDeviceId).firstOrNull?.name ?? 'chưa chọn'}" '
            '(đổi trong Cài đặt).',
          ),
        DevicePicker(
          label: 'Bạn nghe tiếng Việt qua',
          devices: items(dev.renderDevices),
          selectedId: headsetId,
          enabled: !running,
          onChanged:
              (id) => cubit.update((s) => s.copyWith(headsetDeviceId: () => id)),
        ),
        if (headset != null && headset.isVirtualCable)
          const Notice(
            'Đang chọn cáp ảo: đối phương sẽ nghe cả tiếng Việt. Chọn tai nghe thật.',
            isError: true,
          ),
        DevicePicker(
          label: 'Đối phương nghe tiếng Anh qua',
          devices: items(dev.renderDevices),
          selectedId: cableId,
          enabled: !running,
          onChanged:
              (id) => cubit.update((s) => s.copyWith(cableDeviceId: () => id)),
        ),
        if (dev.cableInput == null)
          const Notice(
            'Chưa thấy VB-Cable. Cài VB-Cable bằng quyền Administrator rồi khởi động lại máy.',
          ),
        if (dev.cableInput != null)
          const Text(
            'Trong Discord: Voice & Video → Input Device = "CABLE Output".',
            style: TextStyle(fontSize: 12),
          ),
      ],
    );
  }
}

class _CallAppPicker extends StatelessWidget {
  const _CallAppPicker({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final apps = context.select<DevicesCubit, List<String>>(
      (c) => [
        for (final a in c.state.callApps)
          if (!a.exe.startsWith('(')) a.exe,
      ],
    );
    final playing = context.select<DevicesCubit, Set<String>>(
      (c) => {
        for (final a in c.state.callApps)
          if (a.isPlaying) a.exe.toLowerCase(),
      },
    );
    final current = context.select<SettingsCubit, String>(
      (c) => c.state.settings.callAppExe,
    );
    final names = <String>{current, ...apps}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        isExpanded: true,
        value: current,
        decoration: const InputDecoration(
          labelText: 'Âm thanh cuộc gọi lấy từ app',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final n in names)
            DropdownMenuItem(
              value: n,
              child: Text(
                playing.contains(n.toLowerCase()) ? '$n  (đang phát)' : n,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged:
            enabled
                ? (exe) {
                  if (exe != null) {
                    context.read<SettingsCubit>().update(
                      (s) => s.copyWith(callAppExe: exe),
                    );
                  }
                }
                : null,
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard();

  @override
  Widget build(BuildContext context) {
    final s = context.select<TranslatorCubit, TranslatorSnapshot?>(
      (c) => c.state.snapshot,
    );
    if (s == null) return const SizedBox.shrink();
    final callVolume = s.callAppVolume;
    return SectionCard(
      title: 'Đo lường',
      children: [
        for (final d in Direction.values) ...[
          Text(d.label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          _DirectionStats(stats: s.of(d)),
          if (d == Direction.incoming && callVolume != null)
            Text(
              'Volume app gọi: ${(callVolume * 100).round()}% '
              '→ bù ×${s.incoming.inputGain.toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 12),
        ],
        Text(
          'Rớt dữ liệu thu (discontinuity): mic ${s.micDiscontinuities}, cuộc gọi ${s.callDiscontinuities}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _DirectionStats extends StatelessWidget {
  const _DirectionStats({required this.stats});

  final PipelineStats stats;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    String ms(int? v) => v == null ? '—' : '${(v / 1000).toStringAsFixed(1)} s';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LevelMeter(label: 'Vào', db: stats.inputDb),
        const SizedBox(height: 4),
        LevelMeter(label: 'Bản dịch', db: stats.outputDb),
        const SizedBox(height: 4),
        Text(
          'Trễ: lần cuối ${ms(stats.lastLagMs)} · p50 ${ms(stats.p50LagMs)} · '
          'p90 ${ms(stats.p90LagMs)} (${stats.lagSamples} câu)',
          style: small,
        ),
        Text(
          'Chờ phát: ${stats.bufferedMs} ms'
          '${stats.droppedOutputMs > 0 ? ' · mất ${stats.droppedOutputMs} ms do đầy bộ đệm' : ''}',
          style: small,
        ),
      ],
    );
  }
}

class _SubtitlesPanel extends StatefulWidget {
  const _SubtitlesPanel();

  @override
  State<_SubtitlesPanel> createState() => _SubtitlesPanelState();
}

class _SubtitlesPanelState extends State<_SubtitlesPanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _followBottom() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent - pos.pixels < 120) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Text('Phụ đề', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: () => context.read<SubtitlesCubit>().clear(),
                icon: const Icon(Icons.clear_all, size: 18),
                label: const Text('Xóa'),
              ),
            ],
          ),
        ),
        Expanded(
          child: BlocConsumer<SubtitlesCubit, SubtitlesState>(
            listener: (_, __) => _followBottom(),
            builder: (context, state) {
              if (state.lines.isEmpty) {
                return Center(
                  child: Text(
                    'Phụ đề song ngữ sẽ hiện ở đây khi bắt đầu dịch.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                );
              }
              return ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: state.lines.length,
                itemBuilder: (_, i) => _SubtitleTile(line: state.lines[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SubtitleTile extends StatelessWidget {
  const _SubtitleTile({required this.line});

  final SubtitleLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = line.direction == Direction.outgoing;
    final accent = mine ? theme.colorScheme.primary : theme.colorScheme.tertiary;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: accent, width: 3)),
        color: theme.colorScheme.surfaceContainerLow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            mine ? 'Bạn · Vi → En' : 'Đối phương · En → Vi',
            style: theme.textTheme.labelSmall?.copyWith(color: accent),
          ),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: line.source),
                if (line.interimSource.isNotEmpty)
                  TextSpan(
                    text: line.interimSource,
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
              ],
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (line.translated.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              line.translated,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
