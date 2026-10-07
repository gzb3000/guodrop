import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/device.dart';
import '../../core/models/protocol.dart';
import '../app_state.dart';

/// 设备卡片 — 点击即选择文件并发送
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.device, required this.state});

  final Device device;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _handleSend(context),
        onLongPress: () => _showDeviceMenu(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              _deviceIcon(theme),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.alias,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device.ip}:${device.port}'
                      '${device.deviceModel.isNotEmpty ? ' · ${device.deviceModel}' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.send_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deviceIcon(ThemeData theme) {
    final (icon, color) = switch (device.deviceType) {
      DeviceType.mobile => (Icons.smartphone, const Color(0xFF6B8FD4)),
      DeviceType.desktop => (Icons.computer, const Color(0xFF4C9E8A)),
      DeviceType.web => (Icons.language, const Color(0xFFC08A3E)),
      DeviceType.headless => (Icons.dns_outlined, const Color(0xFF8B8B8B)),
      DeviceType.unknown => (Icons.devices_other, const Color(0xFF8B8B8B)),
    };

    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, size: 22, color: color),
    );
  }

  /// 核心交互：选文件 → 发送
  Future<void> _handleSend(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);

    // 桌面端和移动端都用 file_picker，它会自动适配原生选择器
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withReadStream: false,
    );

    if (result == null || result.files.isEmpty) return;

    final files = <FileMeta>[];
    for (final f in result.files) {
      if (f.path == null) continue;
      files.add(FileMeta(
        id: const Uuid().v4(),
        fileName: f.name,
        size: f.size,
        mimeType: lookupMimeType(f.name),
        localPath: f.path,
      ));
    }

    if (files.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('无法读取所选文件')),
      );
      return;
    }

    final totalSize = files.fold<int>(0, (s, f) => s + f.size);

    // 发送前确认
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认发送'),
        content: Text(
          '向「${device.alias}」发送 ${files.length} 个文件，'
          '共 ${formatBytes(totalSize)}。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text('正在发送到 ${device.alias}...'),
        duration: const Duration(seconds: 2),
      ),
    );

    final ok = await state.sendFiles(device, files);

    messenger.showSnackBar(
      SnackBar(
        content: Text(ok
            ? '已发送 ${files.length} 个文件到 ${device.alias}'
            : '发送失败，请检查对方是否在线'),
        backgroundColor: ok ? const Color(0xFF3B9E6E) : const Color(0xFFD0504E),
      ),
    );
  }

  void _showDeviceMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.send_outlined),
              title: const Text('发送文件'),
              onTap: () {
                Navigator.pop(ctx);
                _handleSend(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('从列表移除'),
              onTap: () {
                Navigator.pop(ctx);
                state.removeDevice(device);
              },
            ),
          ],
        ),
      ),
    );
  }
}
