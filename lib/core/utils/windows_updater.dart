import 'dart:io';

/// Windows 自动更新：运行下载好的 Inno Setup 安装器，然后退出自己。
///
/// 采用 HANDOFF 第七节推荐的「单文件 exe 安装器」方案（不做 zip 覆盖）：
///   - 安装器按用户级安装（`PrivilegesRequired=lowest`，装在
///     `%LOCALAPPDATA%\Programs\lan_share`），不需要管理员权限
///   - `/SILENT` 只显示进度条；`/CLOSEAPPLICATIONS` 让安装器等待/关闭旧进程
///   - 安装器 [Run] 段在装完后自动重新启动 lan_share.exe
///   - 日志写到 `%TEMP%\lan_share_update.log`
///
/// 安装失败时旧版本文件保持不变（Inno Setup 自带回滚），不会把 App 弄残。
class WindowsUpdater {
  WindowsUpdater._();

  static bool get isSupported => Platform.isWindows;

  /// 下载地址是否是安装器 exe（zip 等其它格式只能走浏览器下载）
  static bool isInstallerUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.exe');
  }

  /// 启动安装器并退出当前进程。返回非 null 表示启动失败（当前进程不退出）。
  static Future<String?> runInstallerAndExit(String installerPath) async {
    if (!Platform.isWindows) return '当前平台不支持';
    try {
      final log =
          '${Platform.environment['TEMP'] ?? Directory.systemTemp.path}\\lan_share_update.log';
      await Process.start(
        installerPath,
        [
          '/SILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
          '/LOG=$log',
        ],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      return '启动安装程序失败：$e';
    }
    // 给安装器一点时间起来，然后让出文件锁
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}
