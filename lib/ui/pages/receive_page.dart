import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/shell_open.dart';
import '../app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/receive_card.dart';

/// 收件箱 — 全部接收记录
class ReceivePage extends StatelessWidget {
  const ReceivePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sessions = state.receiveSessions;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('收件箱'),
        actions: [
          IconButton(
            tooltip: '接收目录',
            icon: const Icon(Icons.folder_outlined),
            onPressed: () => _openFolder(context, state.downloadDir),
          ),
        ],
      ),
      body: sessions.isEmpty
          ? const EmptyState(
              icon: Icons.inbox_outlined,
              title: '还没有收到文件',
              description: '别人给你传的文件会出现在这里。\n'
                  '传输时不需要你手动确认。',
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          state.downloadDir,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    itemCount: sessions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final s = sessions[i];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ReceiveCard(session: s),
                          if (s.completedFiles > 0)
                            Padding(
                              padding: const EdgeInsets.only(left: 16, top: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final f in s.files.take(5))
                                    InkWell(
                                      onTap: f.savedPath == null
                                          ? null
                                          : () => _openFile(context, f.savedPath,
                                              f.savedUri, f.mimeType),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 4),
                                        child: Text(
                                          '· ${f.fileName}'
                                          '${f.savedPath != null ? '' : (s.isCancelled ? ' (未接收)' : ' (待接收)')}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            color: f.savedPath != null
                                                ? theme.colorScheme.primary
                                                : theme.colorScheme
                                                    .onSurfaceVariant,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  if (s.files.length > 5)
                                    Text(
                                      '... 还有 ${s.files.length - 5} 个文件',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  /// 直接在系统文件管理器打开保存目录；实在打不开才退回显示路径
  static Future<void> _openFolder(BuildContext context, String dir) async {
    final ok = await ShellOpen.openDirectory(dir);
    if (ok || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('文件保存位置'),
        content: SelectableText('无法自动打开文件管理器，请手动前往：\n$dir'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  static Future<void> _openFile(
      BuildContext context, String? path, String? uri, String? mime) async {
    final ok = await ShellOpen.openFile(path, uri: uri, mime: mime);
    if (ok || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('没有可以打开此文件的应用：${path ?? ''}')),
    );
  }
}
