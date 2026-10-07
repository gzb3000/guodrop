import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/protocol.dart';
import '../app_state.dart';

/// 设置页 — 设备名、接收目录、诊断信息
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _sectionHeader(theme, '设备'),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('设备名称'),
            subtitle: Text(state.selfDevice?.alias ?? '—'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _editAlias(context, state),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('设备指纹'),
            subtitle: Text(
              state.selfDevice?.fingerprint ?? '—',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            isThreeLine: true,
          ),

          const Divider(height: 32),
          _sectionHeader(theme, '接收'),

          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('接收目录'),
            subtitle: Text(
              state.downloadDir.isEmpty ? '—' : state.downloadDir,
            ),
            isThreeLine: true,
          ),

          SwitchListTile(
            secondary: const Icon(Icons.bolt_outlined),
            title: const Text('自动接收'),
            subtitle: const Text('不再询问，收到文件直接保存'),
            value: false,
            onChanged: (_) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('该功能将在后续版本开放')),
              );
            },
          ),

          const Divider(height: 32),
          _sectionHeader(theme, '网络诊断'),

          ListTile(
            leading: Icon(
              state.isRunning ? Icons.check_circle_outline : Icons.error_outline,
              color: state.isRunning
                  ? const Color(0xFF3B9E6E)
                  : const Color(0xFFD0504E),
            ),
            title: Text(state.isRunning ? '服务运行中' : '服务未运行'),
            subtitle: Text(
              '组播 ${Protocol.multicastGroup}:${Protocol.defaultPort}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.lan_outlined),
            title: const Text('局域网地址'),
            subtitle: Text(
              state.localIp ?? '未检测到',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.wifi_tethering),
            title: const Text('已发现设备'),
            subtitle: Text('${state.devices.length} 台'),
          ),

          const Divider(height: 32),
          _sectionHeader(theme, '关于'),

          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('版本'),
            subtitle: Text('0.1.0 — 兼容 LocalSend v2 协议'),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
        child: Text(
          title,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  void _editAlias(BuildContext context, AppState state) {
    final controller =
        TextEditingController(text: state.selfDevice?.alias ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改设备名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: '别人看到的名字',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              Navigator.pop(ctx);
              if (name.isEmpty) return;
              await state.updateAlias(name);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('名称已更新')),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
