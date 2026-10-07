import 'package:flutter/material.dart';

import '../../core/scan/scan_service.dart';
import '../../core/utils/shell_open.dart';
import '../app_state.dart';
import 'receive_card.dart';
import 'send_card.dart';

/// 传输面板 — 桌面端右栏，展示收发进度
class TransferPanel extends StatelessWidget {
  const TransferPanel({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final receives = state.receiveSessions;
    final sends = state.sendTasks;
    final qr = state.qrSession;
    final hasAny = receives.isNotEmpty || sends.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
          child: Row(
            children: [
              Text(
                hasAny ? '传输中' : '等待传输',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (state.downloadDir.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _openDir(context),
                  icon: const Icon(Icons.folder_outlined, size: 16),
                  label: const Text('打开接收目录'),
                ),
            ],
          ),
        ),
        Expanded(
          child: hasAny
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  children: [
                    for (final s in receives)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ReceiveCard(session: s),
                      ),
                    for (final t in sends)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SendCard(task: t),
                      ),
                  ],
                )
              : _IdlePlaceholder(qr: qr, state: state),
        ),
      ],
    );
  }

  /// 打开接收目录。
  ///
  /// 桌面端直接调系统文件管理器；移动端（Android/iOS）没有可靠的
  /// 「打开文件管理器到指定目录」能力，所以退回弹窗显示路径。
  Future<void> _openDir(BuildContext context) async {
    final dir = state.downloadDir;
    final ok = await ShellOpen.openDirectory(dir);

    if (!context.mounted) return;
    if (ok) return; // 已交给系统，不再打扰用户

    // 兜底：告诉用户路径在哪，并支持复制
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('接收目录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('文件保存在下面这个目录：'),
            const SizedBox(height: 12),
            SelectableText(dir),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

/// 空闲状态 — 展示二维码入口
class _IdlePlaceholder extends StatelessWidget {
  const _IdlePlaceholder({required this.qr, required this.state});

  final QrSession? qr;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ip = state.localIp;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.swap_horiz_rounded,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              '选择左侧设备即可发送文件',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '对方不需要点「接收」，传过来会自动保存',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
            if (ip != null) ...[
              const SizedBox(height: 28),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Text(
                      '手机没装应用？让浏览器访问',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      'http://$ip:53317',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
