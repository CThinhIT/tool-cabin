import 'package:flutter/material.dart';

import '../../domain/translation_engine.dart';

/// Horizontal level meter, -60..0 dBFS.
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.db, this.label});

  final double db;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = ((db + 60) / 60).clamp(0.0, 1.0);
    final color =
        db > -3
            ? scheme.error
            : db > -12
            ? Colors.amber.shade700
            : Colors.green.shade600;
    return Row(
      children: [
        if (label != null)
          SizedBox(
            width: 64,
            child: Text(label!, style: Theme.of(context).textTheme.bodySmall),
          ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 8,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(
            db <= -99 ? '—' : '${db.toStringAsFixed(0)} dB',
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final EngineStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (text, color) = switch (status) {
      EngineStatus.idle => ('Chưa chạy', scheme.outline),
      EngineStatus.connecting => ('Đang kết nối', Colors.blue),
      EngineStatus.ready => ('Đang dịch', Colors.green.shade700),
      EngineStatus.reconnecting => ('Đang nối lại', Colors.orange.shade800),
      EngineStatus.closed => ('Đã dừng', scheme.outline),
      EngineStatus.failed => ('Lỗi', scheme.error),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A warning or error line with an icon.
class Notice extends StatelessWidget {
  const Notice(this.text, {super.key, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.error : Colors.orange.shade800;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.warning_amber_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dropdown of devices by id; keeps a missing (unplugged) selection visible.
class DevicePicker extends StatelessWidget {
  const DevicePicker({
    super.key,
    required this.label,
    required this.devices,
    required this.selectedId,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final List<({String id, String name})> devices;
  final String? selectedId;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final present = devices.any((d) => d.id == selectedId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        isExpanded: true,
        value: present ? selectedId : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          errorText:
              selectedId != null && !present ? 'Thiết bị đã chọn không còn' : null,
        ),
        items: [
          for (final d in devices)
            DropdownMenuItem(
              value: d.id,
              child: Text(d.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: enabled ? (id) => id == null ? null : onChanged(id) : null,
      ),
    );
  }
}
