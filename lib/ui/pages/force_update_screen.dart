import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/apk_downloader.dart';
import '../../core/utils/apk_installer.dart';
import '../../core/utils/shell_open.dart';
import '../../core/utils/windows_updater.dart';
import '../../core/version/version_check_service.dart';

/// 更新阶段
enum UpdatePhase { idle, needPermission, downloading, downloaded, installing, failed }

/// 强制更新页
///
/// 规则：只要服务端有更高的 latestVersion，就整页盖住 App，只能更新或退出
/// （没有「以后再说」）。
///
/// 按平台的「立即更新」行为：
///   - Android：App 内下载 APK（进度条、可取消）→ 拉起系统安装器
///     （用户仍需点「安装」「打开」，系统不允许静默安装）
///   - Windows：若下载地址是安装器 exe → App 内下载 → 运行安装器并退出，
///     安装完成后自动重启新版；否则用浏览器打开下载地址
///   - 其他平台：浏览器打开下载地址 / 复制链接
class ForceUpdateScreen extends StatefulWidget {
  const ForceUpdateScreen({
    super.key,
    required this.result,
    this.onExit,
  });

  final UpdateCheckResult result;

  /// 点「退出」时的回调（不传就不显示）
  final VoidCallback? onExit;


  @override
  State<ForceUpdateScreen> createState() => _ForceUpdateScreenState();
}

class _ForceUpdateScreenState extends State<ForceUpdateScreen>
    with WidgetsBindingObserver {
  UpdatePhase _phase = UpdatePhase.idle;
  DownloadProgress? _progress;
  String? _error;
  String? _savedPath;
  bool _cancelRequested = false;

  String? get _url => widget.result.info?.urlForCurrentPlatform;

  bool get _inAppAndroid => ApkInstaller.isSupported;

  bool get _inAppWindows =>
      WindowsUpdater.isSupported &&
      _url != null &&
      WindowsUpdater.isInstallerUrl(_url!);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _cancelRequested = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 用户从「安装未知应用」设置页返回时复查授权
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_phase == UpdatePhase.needPermission) {
      ApkInstaller.canInstall().then((ok) {
        if (!mounted || !ok) return;
        if (_savedPath != null) {
          _install();
        } else {
          _startDownload();
        }
      });
    }
  }

  // ==================== 动作 ====================

  Future<void> _onUpdatePressed() async {
    final url = _url;
    if (url == null || url.trim().isEmpty) {
      await _copyLink();
      return;
    }
    if (_inAppAndroid) {
      if (!await ApkInstaller.canInstall()) {
        if (!mounted) return;
        setState(() => _phase = UpdatePhase.needPermission);
        return;
      }
      await _startDownload();
      return;
    }
    if (_inAppWindows) {
      await _startDownload();
      return;
    }
    final ok = await ShellOpen.openUrl(url);
    if (!ok && mounted) await _copyLink();
  }

  Future<void> _startDownload() async {
    final url = _url;
    if (url == null) return;
    setState(() {
      _phase = UpdatePhase.downloading;
      _progress = null;
      _error = null;
      _savedPath = null;
      _cancelRequested = false;
    });

    final latest = widget.result.info?.latest.toString() ?? 'latest';
    final fileName = Platform.isWindows
        ? 'lan_share-$latest-setup.exe'
        : 'lan_share-$latest.apk';

    final res = await ApkDownloader.download(
      urls: [url],
      fileName: fileName,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
      shouldCancel: () async => _cancelRequested,
    );
    if (!mounted) return;

    if (res.cancelled) {
      setState(() {
        _phase = UpdatePhase.idle;
        _progress = null;
      });
      return;
    }
    if (!res.success || res.filePath == null) {
      setState(() {
        _phase = UpdatePhase.failed;
        _error = res.error ?? '下载失败';
      });
      return;
    }
    _savedPath = res.filePath;
    await _install();
  }

  Future<void> _install() async {
    final path = _savedPath;
    if (path == null) return;

    if (Platform.isAndroid && !await ApkInstaller.canInstall()) {
      if (mounted) setState(() => _phase = UpdatePhase.needPermission);
      return;
    }
    if (mounted) setState(() => _phase = UpdatePhase.installing);

    final err = Platform.isWindows
        ? await WindowsUpdater.runInstallerAndExit(path)
        : await ApkInstaller.install(path);
    if (!mounted) return;
    setState(() {
      if (err == null) {
        _phase = UpdatePhase.downloaded;
      } else {
        _phase = UpdatePhase.failed;
        _error = err;
      }
    });
  }

  Future<void> _copyLink() async {
    final url = _url ?? '';
    if (url.trim().isEmpty) {
      _toast('暂时没有下载链接，请联系发布者');
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    _toast('下载链接已复制，请在浏览器打开');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.result.info;
    final current = widget.result.currentVersion ?? '未知';
    final latest = info?.latest.toString() ?? '未知';

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.system_update_alt_rounded,
                    size: 64,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '需要更新才能继续使用',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '当前版本 $current 已停止服务，'
                    '请更新到 $latest 后继续使用。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                  if (info != null && info.message.trim().isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '更新说明',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            info.message,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(height: 1.6),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  ..._phaseSection(theme),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _copyLink,
                    child: const Text('复制下载链接'),
                  ),
                  if (widget.onExit != null) ...[
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: widget.onExit,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurfaceVariant,
                      ),
                      child: const Text('退出'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _phaseSection(ThemeData theme) {
    final btnStyle = FilledButton.styleFrom(minimumSize: const Size(0, 48));
    final inApp = _inAppAndroid || _inAppWindows;

    switch (_phase) {
      case UpdatePhase.idle:
        return [
          FilledButton.icon(
            onPressed: _onUpdatePressed,
            icon: const Icon(Icons.download_rounded, size: 20),
            label: Text(inApp ? '立即更新' : '去下载新版本'),
            style: btnStyle,
          ),
        ];

      case UpdatePhase.needPermission:
        return [
          Text(
            '需要先允许本应用「安装未知应用」，才能安装更新。\n'
            '授权后返回本应用即可继续。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: ApkInstaller.requestInstallPermission,
            icon: const Icon(Icons.security_rounded, size: 20),
            label: const Text('去授权'),
            style: btnStyle,
          ),
          TextButton(
            onPressed: () async {
              if (await ApkInstaller.canInstall()) {
                if (_savedPath != null) {
                  await _install();
                } else {
                  await _startDownload();
                }
              } else {
                _toast('还没有授权，请在系统设置中打开开关');
              }
            },
            child: const Text('我已授权，继续'),
          ),
        ];

      case UpdatePhase.downloading:
        final p = _progress;
        final hasTotal = p != null && p.total > 0;
        return [
          LinearProgressIndicator(value: hasTotal ? p.fraction : null),
          const SizedBox(height: 8),
          Text(
            p == null
                ? '正在连接…'
                : hasTotal
                    ? '${(p.fraction * 100).toStringAsFixed(0)}%  '
                        '${_fmt(p.received)} / ${_fmt(p.total)}'
                    : '已下载 ${_fmt(p.received)}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => setState(() => _cancelRequested = true),
            child: const Text('取消'),
          ),
        ];

      case UpdatePhase.installing:
        return [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 12),
          Text(
            Platform.isWindows ? '正在启动安装程序，应用将自动关闭并重启…' : '正在打开安装界面…',
            textAlign: TextAlign.center,
          ),
        ];

      case UpdatePhase.downloaded:
        return [
          Text(
            '已打开系统安装界面，请按提示点击「安装」，完成后点「打开」启动新版本。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _install,
            icon: const Icon(Icons.install_mobile_rounded, size: 20),
            label: const Text('重新打开安装界面'),
            style: btnStyle,
          ),
        ];

      case UpdatePhase.failed:
        return [
          Text(
            _error ?? '更新失败',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error, height: 1.6),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _startDownload,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text('重试'),
            style: btnStyle,
          ),
        ];
    }
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
