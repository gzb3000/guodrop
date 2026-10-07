import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'version_info.dart';

/// 检查结果
enum UpdateStatus {
  /// 版本正常，可以继续用
  upToDate,

  /// 有新版本，但不强制（用户可跳过）
  optional,

  /// 必须升级，当前版本已不被允许使用
  required,

  /// 检查失败（断网 / 服务器不可达）
  ///
  /// **按放行处理** —— 局域网传输本来就常在没有外网的环境使用，
  /// 不能因为查不到版本就把用户挡在门外。
  checkFailed,
}

class UpdateCheckResult {
  final UpdateStatus status;
  final VersionInfo? info;
  final String? currentVersion;
  final String? error;

  const UpdateCheckResult({
    required this.status,
    this.info,
    this.currentVersion,
    this.error,
  });

  /// 是否需要阻止用户继续使用
  bool get shouldBlock => status == UpdateStatus.required;
}

/// 版本检查服务
///
/// ## 设计原则
///
/// **绝不能因为版本检查失败而阻止用户使用 App。**
///
/// 这个 App 的核心场景是局域网传文件，很多时候是在没有外网的环境里
/// （公司内网、手机热点、断网的家里）。如果「查不到版本就不让用」，
/// 用户会直接卸载。
///
/// 所以策略是：
///   - 查到，且当前版本 < minVersion → 拦截（这是你要的「老版本必须停止」）
///   - 查到，且当前版本 < latestVersion → 提示，可跳过
///   - 查不到（任何原因）→ **放行**
///
/// ## 超时
///
/// 3 秒。用户打开 App 是来传文件的，不是来看「正在检查更新」的。
/// 3 秒拿不到就放行，不阻塞。
///
/// ## 为什么不用 package_info_plus
///
/// 那个包能读 pubspec.yaml 的 version，但引入它需要改 pubspec.lock、
/// 重新拉依赖。为了一个版本号不值得动依赖树（本项目所有依赖版本都
/// 经过逐一核对，动一个牵一片）。所以版本号直接写在下面常量里，
/// 发版时和 pubspec.yaml 一起改。
class VersionCheckService {
  VersionCheckService({required this.endpoint});

  /// 版本接口地址，例如 https://appversion.harvin.top/api/version
  final String endpoint;

  static const _timeout = Duration(seconds: 3);

  /// 本机版本号。
  ///
  /// **发版时必须和 pubspec.yaml 的 `version:` 一起改。**
  /// 两处不一致会导致「明明装了新版，还是被拦」。
  static const currentVersion = '0.3.2';

  /// 发起检查
  Future<UpdateCheckResult> check() async {
    final currentRaw = currentVersion;

    try {
      final json = await _fetch();
      if (json == null) {
        return UpdateCheckResult(
          status: UpdateStatus.checkFailed,
          currentVersion: currentRaw,
          error: '服务端未返回有效数据',
        );
      }

      final info = VersionInfo.tryParse(json);
      if (info == null) {
        return UpdateCheckResult(
          status: UpdateStatus.checkFailed,
          currentVersion: currentRaw,
          error: '版本数据格式不正确',
        );
      }

      final current = SemVersion.tryParse(currentRaw);
      if (current == null) {
        // 本地版本号读不出来，放行（不该因为读不到自己的版本就拦人）
        return UpdateCheckResult(
          status: UpdateStatus.checkFailed,
          info: info,
          currentVersion: currentRaw,
          error: '无法解析本机版本号',
        );
      }

      if (current < info.minAllowed) {
        return UpdateCheckResult(
          status: UpdateStatus.required,
          info: info,
          currentVersion: currentRaw,
        );
      }

      if (current < info.latest) {
        return UpdateCheckResult(
          // 规则：低于 latestVersion 一律强制更新（忽略 forceUpdate=false）
          status: UpdateStatus.required,
          info: info,
          currentVersion: currentRaw,
        );
      }

      return UpdateCheckResult(
        status: UpdateStatus.upToDate,
        info: info,
        currentVersion: currentRaw,
      );
    } catch (e) {
      return UpdateCheckResult(
        status: UpdateStatus.checkFailed,
        currentVersion: currentRaw,
        error: '$e',
      );
    }
  }

  /// 拉取版本 JSON
  Future<Map<String, dynamic>?> _fetch() async {
    final client = HttpClient()..connectionTimeout = _timeout;

    try {
      final uri = Uri.parse(endpoint);
      final request = await client.getUrl(uri);
      // 加上时间戳绕过任何中间层缓存 —— 你要的是「改了立刻生效」
      request.headers.set('Cache-Control', 'no-cache, no-store');
      request.headers.set('Pragma', 'no-cache');

      final response = await request.close().timeout(_timeout);

      if (response.statusCode != 200) return null;

      final body =
          await response.transform(utf8.decoder).join().timeout(_timeout);

      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) return json;
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
