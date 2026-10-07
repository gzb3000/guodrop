import 'package:flutter/material.dart';

import '../../core/models/device.dart';
import '../../core/transport/transfer_service.dart';
import '../../core/utils/shell_open.dart';

/// 接收任务卡片 — 显示进度条与来源设备
class ReceiveCard extends StatelessWidget {
  const ReceiveCard({super.key, required this.session});

  final ReceiveSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = session.isCompleted;
    final cancelled = session.isCancelled;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  done ? Icons.check_circle_outline : Icons.download_outlined,
                  size: 18,
                  color: done
                      ? const Color(0xFF3B9E6E)
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  done ? '接收完成' : (cancelled ? '已取消' : '正在接收'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text(
                  '${session.completedFiles}/${session.files.length} 个文件',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '来自 ${session.sender.alias}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: session.progress,
                minHeight: 5,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: done ? const Color(0xFF3B9E6E) : null,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${formatBytes(session.receivedBytes)}'
                    ' / ${formatBytes(session.totalBytes)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  '${(session.progress * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            // 收完之后给一个「打开所在目录」的入口。
            // 桌面端直接调文件管理器；Android 打开「下载/GUODROP」。
            if (done && _canOpen) _buildOpenButton(context, theme),
          ],
        ),
      ),
    );
  }

  /// 只有拿到真实保存路径、且平台支持时才显示入口
  bool get _canOpen {
    final p = session.files
        .map((f) => f.savedPath)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    if (p.isEmpty) return false;
    return ShellOpen.isSupported;
  }

  Widget _buildOpenButton(BuildContext context, ThemeData theme) {
    final target = session.files
        .map((f) => f.savedPath)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .first;

    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () => ShellOpen.revealFile(target),
        icon: const Icon(Icons.folder_open_outlined, size: 16),
        label: const Text('打开所在目录'),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}
