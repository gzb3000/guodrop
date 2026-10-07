import 'package:flutter/material.dart';

import '../../core/models/device.dart';
import '../app_state.dart';

/// 发送任务卡片
class SendCard extends StatelessWidget {
  const SendCard({super.key, required this.task});

  final SendTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final IconData icon;
    final Color color;
    final String title;

    if (task.isDone) {
      icon = Icons.check_circle_outline;
      color = const Color(0xFF3B9E6E);
      title = '发送完成';
    } else if (task.isFailed) {
      icon = Icons.error_outline;
      color = const Color(0xFFD0504E);
      title = '发送失败';
    } else {
      icon = Icons.upload_outlined;
      color = theme.colorScheme.primary;
      title = '正在发送';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text(
                  '${task.files.length} 个文件',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '发送到 ${task.target.alias}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (task.error != null) ...[
              const SizedBox(height: 6),
              Text(
                task.error!,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ],
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.progress,
                minHeight: 5,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${formatBytes(task.sentBytes)}'
                    ' / ${formatBytes(task.totalBytes)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  '${(task.progress * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
