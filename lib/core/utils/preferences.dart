import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/protocol.dart';
import 'device_info_helper.dart';

/// 本机身份信息
class LocalIdentity {
  final String fingerprint;
  final String alias;

  const LocalIdentity({required this.fingerprint, required this.alias});
}

/// 本地持久化
///
/// 用 shared_preferences 而非自建文件：它在全部六个平台都有实现，
/// 而且在 web 上退化到 localStorage，不用担心平台差异。
class AppPreferences {
  static const _keyFingerprint = 'device_fingerprint';
  static const _keyAlias = 'device_alias';
  static const _keyReceiveDir = 'receive_dir';
  static const _keyAutoAccept = 'auto_accept';

  /// 加载或生成身份
  ///
  /// fingerprint 一旦生成就永久保留。它是设备在局域网里的身份证，
  /// 变了会导致对端把你认成新设备。
  static Future<LocalIdentity> loadOrCreateIdentity() async {
    final prefs = await SharedPreferences.getInstance();

    var fingerprint = prefs.getString(_keyFingerprint);
    if (fingerprint == null || fingerprint.isEmpty) {
      fingerprint = _generateFingerprint();
      await prefs.setString(_keyFingerprint, fingerprint);
    }

    var alias = prefs.getString(_keyAlias);
    if (alias == null || alias.isEmpty) {
      alias = await _generateDefaultAlias();
      await prefs.setString(_keyAlias, alias);
    }

    return LocalIdentity(fingerprint: fingerprint, alias: alias);
  }

  static Future<void> saveAlias(String alias) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAlias, alias);
  }

  static Future<void> saveReceiveDir(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyReceiveDir, path);
  }

  static Future<String?> loadReceiveDir() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyReceiveDir);
  }

  /// 是否自动接收文件（不弹确认）
  ///
  /// 默认 false。局域网里谁都可能给你发东西，默认应该问一下。
  static Future<bool> loadAutoAccept() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoAccept) ?? false;
  }

  static Future<void> saveAutoAccept(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoAccept, value);
  }

  /// 生成设备指纹：20 位十六进制随机串
  static String _generateFingerprint() {
    final rand = Random.secure();
    return List.generate(
      20,
      (_) => rand.nextInt(16).toRadixString(16),
    ).join();
  }

  /// 生成默认别名
  static Future<String> _generateDefaultAlias() async {
    final model = await DeviceInfoHelper.deviceModel();
    final type = DeviceInfoHelper.currentDeviceType();

    if (model.isNotEmpty) {
      return '$model (${type.label})';
    }
    return '${type.label} ${_shortId()}';
  }

  static String _shortId() {
    final rand = Random.secure();
    return List.generate(4, (_) => rand.nextInt(10)).join();
  }

  /// 在桌面端探测可用端口
  ///
  /// 53317 被占用时（比如同时装了 LocalSend），往后顺延。
  static Future<int> findAvailablePort() async {
    for (var p = Protocol.defaultPort; p < Protocol.defaultPort + 20; p++) {
      try {
        final socket = await ServerSocket.bind(InternetAddress.anyIPv4, p);
        await socket.close();
        return p;
      } catch (_) {
        continue;
      }
    }
    return Protocol.defaultPort;
  }
}
