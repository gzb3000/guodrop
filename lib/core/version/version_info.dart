import 'dart:convert';
import 'dart:io';

/// 三段式版本号，如 `1.2.3`
///
/// 为什么不用字符串直接比大小：`"1.10.0"` 和 `"1.9.0"` 按字符串比
/// 会得出 `1.10 < 1.9`（因为 '1' < '9'），是错的。必须拆成整数逐段比。
class SemVersion implements Comparable<SemVersion> {
  final int major;
  final int minor;
  final int patch;

  const SemVersion(this.major, this.minor, this.patch);

  /// 解析 `1.2.3` / `1.2` / `1` 形式；容忍 `v` 前缀和 `+build` 后缀
  static SemVersion? tryParse(String? raw) {
    if (raw == null) return null;

    var s = raw.trim();
    if (s.isEmpty) return null;

    // 去掉 v 前缀（v1.2.3）
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);

    // 去掉构建号后缀（1.2.3+4）
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);

    final parts = s.split('.');
    if (parts.isEmpty) return null;

    int at(int i) {
      if (i >= parts.length) return 0;
      return int.tryParse(parts[i].trim()) ?? 0;
    }

    return SemVersion(at(0), at(1), at(2));
  }

  @override
  int compareTo(SemVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(SemVersion o) => compareTo(o) < 0;
  bool operator <=(SemVersion o) => compareTo(o) <= 0;
  bool operator >(SemVersion o) => compareTo(o) > 0;
  bool operator >=(SemVersion o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) =>
      other is SemVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// 从服务端读到的版本公告
class VersionInfo {
  /// 最新版本号
  final SemVersion latest;

  /// 允许使用的最低版本号。
  ///
  /// 当前版本低于它 → 强制拦截，不能用。
  final SemVersion minAllowed;

  /// 展示给用户的更新说明
  final String message;

  /// 各平台的下载地址
  final String? androidUrl;
  final String? windowsUrl;
  final String? iosUrl;
  final String? macosUrl;

  /// 是否允许用户跳过本次更新（仅当只是「有新版本」而非「必须升级」时有效）
  final bool forceUpdate;

  const VersionInfo({
    required this.latest,
    required this.minAllowed,
    this.message = '',
    this.androidUrl,
    this.windowsUrl,
    this.iosUrl,
    this.macosUrl,
    this.forceUpdate = true,
  });

  /// 从服务端 JSON 解析
  ///
  /// 支持两种字段命名风格：
  ///   - latestVersion / minVersion
  ///   - latest / minimum
  /// 这样你在 Cloudflare KV 里怎么写都行。
  static VersionInfo? tryParse(Map<String, dynamic> json) {
    final latestRaw = json['latestVersion'] ?? json['latest'];
    final minRaw = json['minVersion'] ?? json['minimum'];

    final latest = SemVersion.tryParse(latestRaw?.toString());
    if (latest == null) return null;

    // minVersion 缺省时视为等于 latest —— 即「必须升到最新」
    final minAllowed =
        SemVersion.tryParse(minRaw?.toString()) ?? latest;

    final urls = json['urls'];
    String? pick(String key) {
      if (urls is Map) {
        final v = urls[key];
        if (v != null && v.toString().trim().isNotEmpty) {
          return v.toString().trim();
        }
        return null;
      }
      // 也支持平铺写法：androidUrl / windowsUrl
      final flat = json['${key}Url'];
      if (flat != null && flat.toString().trim().isNotEmpty) {
        return flat.toString().trim();
      }
      return null;
    }

    return VersionInfo(
      latest: latest,
      minAllowed: minAllowed,
      message: (json['message'] ?? '').toString(),
      androidUrl: pick('android'),
      windowsUrl: pick('windows'),
      iosUrl: pick('ios'),
      macosUrl: pick('macos'),
      forceUpdate: json['forceUpdate'] != false,
    );
  }

  /// 按当前平台挑下载地址
  String? get urlForCurrentPlatform {
    if (Platform.isAndroid) return androidUrl;
    if (Platform.isIOS) return iosUrl;
    if (Platform.isMacOS) return macosUrl;
    if (Platform.isWindows) return windowsUrl;
    // Linux 暂时不提供（没做安装包）
    return windowsUrl;
  }

  /// 静态兜底：从本地 asset 解析（服务端拿不到时用）
  static VersionInfo? parseJsonString(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return tryParse(json);
    } catch (_) {
      // 格式不对就当没有
    }
    return null;
  }
}
