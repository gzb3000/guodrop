import 'dart:io';

import 'public_storage.dart';

/// 用系统文件管理器打开一个目录 / 文件。
///
/// 各平台的做法完全不同，所以这里按平台分支：
///   - Windows : explorer.exe "<path>"   （explorer 对路径里的空格很敏感，必须带引号）
///   - macOS   : open "<path>"
///   - Linux   : xdg-open "<path>"
///   - Android : 走 PublicStorage（原生 Intent 打开「下载/GUODROP」，
///               失败时依次退回下载管理器），见 MainActivity.kt
///   - iOS     : 同上，返回 false。
///
/// 返回值：是否成功把打开动作交给系统。
/// 注意：这个返回值只代表「进程启动成功」，不代表窗口真的弹出来了
/// （explorer 即使路径不存在也常常返回 0）。
class ShellOpen {
  ShellOpen._();

  /// 当前平台是否支持「用文件管理器打开目录」。
  ///
  /// 桌面三平台支持；Android / iOS 上没有通用方案，返回 false，
  /// 调用方据此隐藏入口按钮，退回到显示路径文本。
  static bool get isSupported =>
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isAndroid;

  /// 在系统文件管理器中打开目录（并尽量选中它）
  static Future<bool> openDirectory(String path) async {
    if (Platform.isAndroid) return PublicStorage.openFolder();
    if (path.trim().isEmpty) return false;
    return open(path, select: false);
  }

  /// 打开文件所在目录，并把这个文件选中高亮
  static Future<bool> revealFile(String filePath) async {
    if (Platform.isAndroid) return PublicStorage.openFolder();
    if (filePath.trim().isEmpty) return false;
    return open(filePath, select: true);
  }

  /// 用系统默认应用打开一个已收到的文件
  static Future<bool> openFile(String? path, {String? uri, String? mime}) async {
    if (Platform.isAndroid) {
      return PublicStorage.openFile(uri: uri, path: path, mime: mime);
    }
    final p = path?.trim() ?? '';
    if (p.isEmpty) return false;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', <String>[p]);
        return true;
      }
      if (Platform.isMacOS) {
        return (await Process.run('open', <String>[p])).exitCode == 0;
      }
      if (Platform.isLinux) {
        return (await Process.run('xdg-open', <String>[p])).exitCode == 0;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// 用系统默认浏览器打开一个网址。
  ///
  /// 各平台都用「让系统自己决定用什么打开」的方式：
  ///   - Windows : `rundll32 url.dll,FileProtocolHandler <url>`
  ///               （比 `start` 可靠 —— start 是 cmd 内建命令，
  ///                 直接调会报「找不到文件」）
  ///   - macOS   : `open <url>`
  ///   - Linux   : `xdg-open <url>`
  ///   - Android : 由原生侧接管（Intent.ACTION_VIEW），见下方说明
  ///   - iOS     : 同上
  ///
  /// 返回值：是否成功把打开动作交给系统。
  static Future<bool> openUrl(String url) async {
    final u = url.trim();
    if (u.isEmpty) return false;

    // 只放行 http/https，避免被注入 file:// 之类的危险 scheme
    final lower = u.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }

    try {
      if (Platform.isWindows) {
        await Process.run(
          'rundll32.exe',
          <String>['url.dll,FileProtocolHandler', u],
        );
        return true;
      }

      if (Platform.isMacOS) {
        final r = await Process.run('open', <String>[u]);
        return r.exitCode == 0;
      }

      if (Platform.isLinux) {
        final r = await Process.run('xdg-open', <String>[u]);
        return r.exitCode == 0;
      }
    } catch (_) {
      return false;
    }

    // Android / iOS 需要平台通道（Intent / UIApplication.open）。
    // 手机上更可靠的做法是「复制链接让用户自己在浏览器粘贴」，
    // 所以这里返回 false，由调用方退回到复制方案。
    return false;
  }

  /// 底层实现
  ///
  /// [select] 为 true 时，尽量在文件管理器里选中目标（而不是只打开父目录）。
  static Future<bool> open(String path, {bool select = false}) async {
    final p = path.trim();
    if (p.isEmpty) return false;

    try {
      if (Platform.isWindows) {
        // /select, 与路径之间必须有一个空格，且只能有一个；
        // explorer 对这两个参数的分隔非常挑剔，写成 "/select," 会打开文档目录。
        final args = select ? <String>['/select,', p] : <String>[p];
        await Process.run('explorer.exe', args);
        // explorer.exe 打开成功时退出码常常是 1（甚至 0），不能靠退出码判断，
        // 只要没抛异常就认为已经把请求交给系统了。
        return true;
      }

      if (Platform.isMacOS) {
        final args = select ? <String>['-R', p] : <String>[p];
        final r = await Process.run('open', args);
        return r.exitCode == 0;
      }

      if (Platform.isLinux) {
        // 文件管理器无法可靠地「选中文件」，退化为打开父目录
        final target = select ? File(p).parent.path : p;
        final r = await Process.run('xdg-open', <String>[target]);
        return r.exitCode == 0;
      }
    } catch (_) {
      // 命令不存在 / 权限不足 / 无 GUI 会话，都算失败
      return false;
    }

    // Android / iOS：没有可靠方案
    return false;
  }
}
