import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../widgets/device_card.dart';
import '../widgets/transfer_panel.dart';
import '../widgets/empty_state.dart';
import 'force_update_screen.dart';
import 'receive_page.dart';
import 'scan_page.dart';
import 'settings_page.dart';

/// 主页面 — 桌面端双栏，移动端单栏
///
/// 这是个 StatefulWidget 只为一件事：监听 App 生命周期。
/// 手机端用户「退出」App 时，必须在进程被杀掉之前通知对端，
/// 否则电脑端会一直留着一个已经关掉的手机，还能往它发文件。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  /// 缓存一份 AppState 引用。
  ///
  /// 为什么不在回调里用 context.read：App 被销毁时（detached），
  /// Widget 可能已经从树上摘掉，此时访问 context 会抛异常。
  /// 而这个异常会被 fire-and-forget 的调用静默吞掉，
  /// 结果就是「以为通知发了，其实没发」。
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 在这里缓存，此时 context 一定有效
    _appState = context.read<AppState>();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用缓存的引用，不用 context —— 见 _appState 的注释
    final appState = _appState;
    if (appState == null) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App 退到后台 / 正在被销毁。
        //
        // 这里**不能**调 shutdown() —— 把发现服务停了，用户切回前台
        // 就得重新初始化。只做「打个招呼」，服务保持运行。
        //
        // 手机上这一瞬间还能发网络请求（进程还没被杀），够发完 bye 包。
        appState.notifyPeersGoingAway();

      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        // 切回前台不需要做什么，服务一直在跑。
        // 顺便刷一下设备列表，把后台期间错过的广播补回来。
        if (state == AppLifecycleState.resumed) {
          appState.refreshDevices();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // 强制更新拦截 —— 优先级最高，盖住所有其他 UI。
    // 查到 minVersion 比当前版本高时，用户无法进入任何功能。
    if (state.needsForceUpdate) {
      return ForceUpdateScreen(result: state.updateResult!);
    }

    // 可选更新（latestVersion 更高但不低于 minVersion，且 forceUpdate=false）：
    // 用同一个更新页，但允许「以后再说」。
    if (state.hasOptionalUpdate) {
      return ForceUpdateScreen(
        result: state.updateResult!,
        onSkip: state.dismissOptionalUpdate,
      );
    }

    if (state.isInitializing) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;

        return Scaffold(
          body: SafeArea(
            child: isWide
                ? _DesktopLayout(state: state)
                : _MobileLayout(state: state),
          ),
        );
      },
    );
  }
}

/// 桌面端布局：左侧设备列表，右侧传输面板
class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 380,
          child: _DevicePane(state: state),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: TransferPanel(state: state),
        ),
      ],
    );
  }
}

/// 移动端布局：设备列表为首页，传输进度用底部弹层
class _MobileLayout extends StatelessWidget {
  const _MobileLayout({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _DevicePane(state: state),
        if (state.hasActiveTransfer)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _FloatingTransferBar(state: state),
          ),
      ],
    );
  }
}

/// 设备列表面板
class _DevicePane extends StatelessWidget {
  const _DevicePane({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部：本机信息
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.selfDevice?.alias ?? '本机',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      state.localIp != null
                          ? '${state.localIp}:53317'
                          : '未连接到局域网',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                ),
              ),
            ],
          ),
        ),

        // 操作按钮行
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ScanPage()),
                  ),
                  icon: const Icon(Icons.qr_code_scanner, size: 20),
                  label: const Text('扫码连接'),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                tooltip: '刷新设备',
                onPressed: state.refreshDevices,
                icon: const Icon(Icons.refresh, size: 20),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                tooltip: '收件箱',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ReceivePage()),
                ),
                icon: const Icon(Icons.inbox_outlined, size: 20),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // 区域标题
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Text(
                '附近设备',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              if (state.devices.isEmpty)
                Text(
                  '搜索中...',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${state.devices.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // 设备列表
        Expanded(
          child: state.devices.isEmpty
              ? EmptyState(
                  icon: Icons.wifi_find_outlined,
                  title: '没有发现其他设备',
                  description: '确保双方连着同一个 WiFi，并都已打开本应用。\n'
                      '也可以点「扫码连接」直接配对。',
                  actionLabel: '刷新',
                  onAction: state.refreshDevices,
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  itemCount: state.devices.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final device = state.devices[i];
                    return DeviceCard(device: device, state: state);
                  },
                ),
        ),
      ],
    );
  }
}

/// 移动端悬浮传输条
class _FloatingTransferBar extends StatelessWidget {
  const _FloatingTransferBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final receiving = state.receiveSessions
        .where((s) => !s.isCompleted && !s.isCancelled)
        .toList();
    final sending = state.sendTasks.where((t) => !t.isDone && !t.isFailed);

    final activeCount = receiving.length + sending.length;
    if (activeCount == 0) return const SizedBox.shrink();

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      color: theme.colorScheme.inverseSurface,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ReceivePage()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '正在传输 $activeCount 个任务',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: theme.colorScheme.onInverseSurface,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
